# frozen_string_literal: true

require "json"
require "securerandom"
require "uri"

module ForumFortress
  module Api
    class Unavailable < StandardError
      attr_reader :cause

      def initialize(message = "Forum Fortress is temporarily unavailable", cause: nil)
        @cause = cause
        super(message)
      end
    end

    class Client
      PLUGIN_VERSION = "1.0.1"
      PLATFORM = "discourse"
      CONTROL_BASE_URL = "https://api.ffapi.net"
      API_BASE_URLS = {
        "global" => "https://api.ffapi.net",
        "uk" => "https://api-uk.ffapi.net",
        "eu" => "https://api-eu.ffapi.net",
        "us" => "https://api-us.ffapi.net",
      }.freeze
      CHECK_ENDPOINT_TIMEOUT_SECONDS = 1
      # Bootstrap is idempotent until this client confirms the returned key on
      # an authenticated request. Keep a separate provisioning budget while
      # ordinary anti-spam checks retain their short configured timeout.
      BOOTSTRAP_TOTAL_TIMEOUT_SECONDS = 30
      BOOTSTRAP_ENDPOINT_TIMEOUT_SECONDS = 30
      MIN_TIMEOUT_SECONDS = 1
      MAX_TIMEOUT_SECONDS = 30
      BOOTSTRAP_RETRY_BACKOFF_SECONDS = 300
      IDENTITY_LOCK_VALIDITY_SECONDS = 60
      STANDARD_HEARTBEAT_INTERVAL_SECONDS = 3600
      PRO_HEARTBEAT_INTERVAL_SECONDS = 600

      def initialize(settings: nil, transport: nil, logger: nil, clock: nil, domain: nil)
        @settings = settings || SiteSetting
        @transport = transport || Transport.new
        @logger = logger || (defined?(Rails) ? Rails.logger : nil)
        @clock = clock || -> { Time.now.to_i }
        @domain_override = domain
      end

      class << self
        def fallback_mutexes
          @fallback_mutexes ||= {}
        end

        def fallback_mutexes_guard
          @fallback_mutexes_guard ||= Mutex.new
        end
      end

      def enabled?
        read_boolean(:forum_fortress_enabled, false)
      end

      def fail_open?
        read_boolean(:forum_fortress_fail_open, true)
      end

      def api_key
        read(:forum_fortress_api_key, "").to_s.strip
      end

      def site_id
        read(:forum_fortress_site_id, "").to_s.strip
      end

      def bootstrap_token
        read(:forum_fortress_bootstrap_token, "").to_s.strip
      end

      def domain
        raw = @domain_override
        raw ||= Discourse.base_url if defined?(Discourse) && Discourse.respond_to?(:base_url)
        raw = raw.to_s.strip
        raw = "//#{raw}" unless raw.empty? || raw.include?("://")
        host = URI.parse(raw).host.to_s.downcase
        host.empty? ? "localhost" : host
      rescue URI::InvalidURIError
        "localhost"
      end

      def check(event_type, payload)
        return nil unless enabled?

        rebootstrap_attempted = false
        begin
          request_payload ||= payload.transform_keys(&:to_s)
          if request_payload["check_request_id"].to_s.strip.empty?
            request_payload["check_request_id"] = SecureRandom.hex(16)
          end
          bootstrap_if_needed
          response, endpoint = request_check(event_type, request_payload)
          Decision.assert_valid!(response)
          best_effort_state_update("check_identity") { persist_identity(response, endpoint:) }
          best_effort_state_update("clear_error") { clear_error }
          response
        rescue RequestError => error
          if !rebootstrap_attempted && stale_identity_error?(error)
            rebootstrap_attempted = true
            begin
              recover_identity(error)
            rescue StandardError => recovery_error
              return handle_failure("check/#{event_type}", recovery_error)
            end
            retry
          end

          handle_failure("check/#{event_type}", error)
        rescue StandardError => error
          handle_failure("check/#{event_type}", error)
        end
      end

      def bootstrap_if_needed(force: false)
        return nil unless enabled?
        with_identity_lock { bootstrap_if_needed_unlocked(force:) }
      end

      def bootstrap_if_needed_unlocked(force: false)
        offline_rebootstrap = offline_bootstrap_key? && (force || offline_rebootstrap_due?)
        if !force && !api_key.empty?
          unless offline_rebootstrap
            site_status(lock: false) if site_id.empty?
            return nil
          end
        end

        state = endpoint_state
        last_failure = state["last_bootstrap_failure_at"].to_i
        if !force && last_failure.positive? && now - last_failure < BOOTSTRAP_RETRY_BACKOFF_SECONDS
          raise RequestError.new("bootstrap is waiting before retry", code: "bootstrap_backoff")
        end

        state["last_bootstrap_attempt_at"] = now
        best_effort_state_update("bootstrap_attempt") { save_endpoint_state(state) }

        payload = bootstrap_payload
        payload["bootstrap_token"] = bootstrap_token unless bootstrap_token.empty?
        candidates =
          if offline_rebootstrap
            offline_rebootstrap_candidates
          else
            check_candidates
          end
        deadline = monotonic_now + BOOTSTRAP_TOTAL_TIMEOUT_SECONDS
        last_error = nil

        candidates.each do |base|
          remaining = deadline - monotonic_now
          break if remaining <= 0

          begin
            response =
              @transport.post_json(
                base,
                "/v1/site/bootstrap",
                payload,
                timeout: [BOOTSTRAP_ENDPOINT_TIMEOUT_SECONDS, remaining].min,
              )
            if response["api_key"].to_s.strip.empty?
              raise RequestError.new(
                      "bootstrap did not return an API key",
                      code: "bootstrap_missing_key",
                    )
            end

            persist_identity(response, endpoint: base, lock: false)
            if api_key.empty?
              raise RequestError.new(
                      "bootstrap identity could not be stored",
                      code: "bootstrap_identity_not_stored",
                    )
            end
            best_effort_state_update("clear_bootstrap_token") do
              write_if_changed(:forum_fortress_bootstrap_token, "")
            end
            state = endpoint_state
            state.delete("last_bootstrap_failure_at")
            best_effort_state_update("bootstrap_success") { save_endpoint_state(state) }
            return response
          rescue StandardError => error
            last_error = error
            raise unless retryable_request_error?(error, allow_node_mismatch: offline_rebootstrap)
          end
        end

        state = endpoint_state
        state["last_bootstrap_failure_at"] = now
        best_effort_state_update("bootstrap_failure") { save_endpoint_state(state) }
        raise(
          last_error ||
            RequestError.new("no bootstrap endpoint available", code: "bootstrap_unavailable"),
        )
      end

      def site_status(lock: true)
        return nil unless enabled?
        return nil if api_key.empty?

        return with_identity_lock { site_status(lock: false) } if lock

        status, endpoint =
          get_across_candidates(
            "/v1/site/status",
            query: {
              domain: domain,
            },
            headers: {
              "X-FF-Key" => api_key,
            },
            timeout: [timeout_budget, 2].min,
          )
        if status["site_id"].to_s.strip.empty?
          raise RequestError.new("invalid site status", code: "invalid_site_status")
        end

        persist_identity(status, endpoint:, lock: false)
        status
      end

      # Scheduled independently of protected traffic so a quiet forum can
      # recover a lost bootstrap response and complete the two-way handshake.
      # Background failures are recorded but never affect forum availability.
      def heartbeat(force: false)
        return nil unless enabled?

        rebootstrap_attempted = false
        begin
          bootstrap_if_needed
          return nil if api_key.empty? || site_id.empty?

          state = endpoint_state
          last_attempt = state["heartbeat_last_attempt_at"].to_i
          plan = state["plan_name"].to_s.downcase
          interval =
            (
              if %w[pro multimod].include?(plan)
                PRO_HEARTBEAT_INTERVAL_SECONDS
              else
                STANDARD_HEARTBEAT_INTERVAL_SECONDS
              end
            )
          return nil if !force && last_attempt.positive? && now - last_attempt < interval
          with_identity_lock do
            state = endpoint_state
            state["heartbeat_last_attempt_at"] = now
            best_effort_state_update("heartbeat_attempt") { save_endpoint_state(state) }
          end

          response, endpoint =
            post_across_candidates(
              "/v1/site/ping",
              common_payload,
              timeout: [timeout_budget, 3].min,
            )
          best_effort_state_update("heartbeat_identity") { persist_identity(response, endpoint:) }
          best_effort_state_update("heartbeat_success") do
            with_identity_lock do
              state = endpoint_state
              state["last_site_ping_at"] = now
              state.delete("last_error_code")
              state.delete("last_error_at")
              save_endpoint_state(state)
            end
          end
          response
        rescue RequestError => error
          if !rebootstrap_attempted && stale_identity_error?(error)
            rebootstrap_attempted = true
            begin
              recover_identity(error)
            rescue StandardError => recovery_error
              return handle_background_failure("site/ping", recovery_error)
            end
            retry
          end

          handle_background_failure("site/ping", error)
        rescue StandardError => error
          handle_background_failure("site/ping", error)
        end
      end

      def status_summary
        {
          enabled: enabled?,
          configured: !api_key.empty?,
          bootstrap_authorized: !bootstrap_token.empty?,
          site_registered: !site_id.empty?,
          region: region,
          global_fallback: global_fallback?,
          fail_open: fail_open?,
          timeout: timeout_budget,
          preferred_endpoint:
            if offline_bootstrap_key?
              safe_endpoint(endpoint_state["offline_preferred_endpoint"]) ||
                safe_endpoint(read(:forum_fortress_preferred_endpoint, ""))
            else
              API_BASE_URLS.fetch(region, API_BASE_URLS["global"])
            end,
          last_error_code: endpoint_state["last_error_code"],
          protections: {
            registration: true,
            public_posts: true,
            post_edits: true,
            profiles: true,
          },
        }
      end

      def connection_test
        unless enabled?
          return { ok: false, error_code: "disabled", health: false, site_status: false }
        end

        if api_key.empty?
          bootstrap_if_needed(force: true)
        else
          bootstrap_if_needed
        end

        heartbeat_response = heartbeat(force: true)
        status = site_status
        best_effort_state_update("connection_identity") { persist_identity(status) }
        best_effort_state_update("clear_error") { clear_error }
        { ok: !heartbeat_response.nil?, health: !heartbeat_response.nil?, site_status: true }
      rescue StandardError => error
        best_effort_state_update("connection_test_failure") { remember_error(error) }
        { ok: false, health: false, site_status: false, error_code: error_code(error) }
      end

      def portal_launch
        raise Unavailable, "Forum Fortress is disabled" unless enabled?

        rebootstrap_attempted = false
        begin
          bootstrap_if_needed
          response, =
            post_across_candidates(
              "/v1/site/portal",
              common_payload,
              timeout: [timeout_budget, 3].min,
            )
          best_effort_state_update("clear_error") { clear_error }
          response
        rescue RequestError => error
          if !rebootstrap_attempted && stale_identity_error?(error)
            rebootstrap_attempted = true
            begin
              recover_identity(error)
            rescue StandardError => recovery_error
              raise_portal_unavailable(recovery_error)
            end
            retry
          end

          raise_portal_unavailable(error)
        rescue Unavailable
          raise
        rescue StandardError => error
          raise_portal_unavailable(error)
        end
      end

      def deprovision_site(reason: "plugin_uninstall")
        normalized_reason = reason.to_s
        if %w[plugin_uninstall manual_disconnect].exclude?(normalized_reason)
          raise ArgumentError, "unsupported Forum Fortress deprovision reason"
        end

        return { "status" => "no_identity" } if api_key.empty? || site_id.empty?

        response, =
          post_across_candidates(
            "/v1/site/deprovision",
            common_payload.merge("reason" => normalized_reason),
            timeout: [timeout_budget, 3].min,
          )
        response
      rescue RequestError => error
        if error.status == 410 && error.code == "site_not_found"
          return { "status" => "already_removed" }
        end

        raise
      end

      private

      def raise_portal_unavailable(error)
        best_effort_state_update("portal_failure") { remember_error(error) }
        log_failure("site/portal", error)
        raise Unavailable.new(cause: error)
      end

      def post_across_candidates(path, payload, timeout:)
        last_error = nil
        check_candidates.each do |base|
          begin
            return @transport.post_json(base, path, payload, timeout:), base
          rescue StandardError => error
            last_error = error
            raise unless retryable_request_error?(error)
          end
        end
        raise(last_error || RequestError.new("no endpoint available", code: "endpoint_unavailable"))
      end

      def get_across_candidates(path, query:, headers:, timeout:)
        last_error = nil
        check_candidates.each do |base|
          begin
            return @transport.get_json(base, path, query:, headers:, timeout:), base
          rescue StandardError => error
            last_error = error
            raise unless retryable_request_error?(error)
          end
        end
        raise(last_error || RequestError.new("no endpoint available", code: "endpoint_unavailable"))
      end

      def request_check(event_type, payload)
        request_payload = common_payload.merge(payload)
        deadline = monotonic_now + timeout_budget
        last_error = nil

        check_candidates.each do |base|
          remaining = deadline - monotonic_now
          break if remaining <= 0

          begin
            return [
              @transport.post_json(
                base,
                "/v1/check/#{URI::DEFAULT_PARSER.escape(event_type.to_s)}",
                request_payload,
                timeout: [CHECK_ENDPOINT_TIMEOUT_SECONDS, remaining].min,
              ),
              base
            ]
          rescue StandardError => error
            last_error = error
            raise unless retryable_request_error?(error)
          end
        end

        raise(
          last_error || RequestError.new("no check endpoint available", code: "check_unavailable"),
        )
      end

      def common_payload
        payload = {
          "api_key" => api_key,
          "site_id" => site_id,
          "domain" => domain,
          "platform" => PLATFORM,
          "platform_version" => platform_version,
          "plugin_version" => PLUGIN_VERSION,
        }
        payload.reject { |_key, value| value.to_s.empty? }
      end

      def bootstrap_payload
        payload = common_payload
        return payload unless offline_bootstrap_key?

        state = endpoint_state
        issuer_node_id = state["issuer_node_id"].to_s.strip
        payload["offline_issuer_node_id"] = issuer_node_id unless issuer_node_id.empty?
        payload["offline_site_id"] = site_id unless site_id.empty?
        payload
      end

      def platform_version
        if defined?(Discourse::VERSION::STRING)
          Discourse::VERSION::STRING
        elsif defined?(Discourse::VERSION)
          Discourse::VERSION.to_s
        else
          "unknown"
        end
      end

      def check_candidates
        configured = API_BASE_URLS.fetch(region, API_BASE_URLS["global"])
        if offline_bootstrap_key?
          state = endpoint_state
          offline_preferred =
            safe_endpoint(state["offline_preferred_endpoint"]) ||
              safe_endpoint(read(:forum_fortress_preferred_endpoint, ""))
          # An offline-scoped key is only valid on its issuer. Do not silently
          # send it to a GeoDNS endpoint when its pin is missing or malformed.
          return offline_preferred ? [offline_preferred] : []
        end

        # GeoDNS chooses the serving edge. Fallbacks are retried only within
        # this request, so the next request immediately fails back to GeoDNS.
        candidates = [configured]
        if region == "global"
          candidates << CONTROL_BASE_URL
        elsif global_fallback?
          candidates.concat([API_BASE_URLS["global"], CONTROL_BASE_URL])
        end
        candidates.compact.uniq
      end

      def offline_rebootstrap_candidates
        state = endpoint_state
        fallback =
          Array(state["fallback_bootstrap_endpoints"]).filter_map { |value| safe_endpoint(value) }
        configured = API_BASE_URLS.fetch(region, API_BASE_URLS["global"])
        (fallback + [configured, CONTROL_BASE_URL]).compact.uniq
      end

      def region
        value = read(:forum_fortress_api_region, "global").to_s.downcase
        API_BASE_URLS.key?(value) ? value : "global"
      end

      def global_fallback?
        read_boolean(:forum_fortress_allow_global_fallback, false)
      end

      def timeout_budget
        value = read(:forum_fortress_timeout, 5).to_i
        [[value, MIN_TIMEOUT_SECONDS].max, MAX_TIMEOUT_SECONDS].min
      end

      def offline_bootstrap_key?
        api_key.start_with?("ff_ob_")
      end

      def offline_rebootstrap_due?
        return false unless offline_bootstrap_key?

        rebootstrap_at = endpoint_state["offline_rebootstrap_at"].to_i
        rebootstrap_at.positive? && now >= rebootstrap_at
      end

      def retryable_request_error?(error, allow_node_mismatch: false)
        return true unless error.is_a?(RequestError)

        status = error.status.to_i
        return true if [408, 425, 500, 502, 503, 504].include?(status)
        return true if allow_node_mismatch && status == 403 && error.code.to_s == "node_mismatch"

        status.zero? &&
          %w[timeout dns_or_socket_error tls_error transport_error].include?(error.code.to_s)
      end

      def stale_identity_error?(error)
        stale_codes = %w[
          invalid_key
          invalid_api_key
          invalid_key_format
          node_mismatch
          stale_site
          site_not_found
          unknown_site
        ]
        error.status.to_i == 401 || stale_codes.include?(error.code)
      end

      def identity_snapshot
        {
          api_key: api_key,
          site_id: site_id,
          preferred_endpoint: read(:forum_fortress_preferred_endpoint, "").to_s,
        }
      end

      def restore_identity(snapshot)
        write_if_changed(:forum_fortress_api_key, snapshot[:api_key])
        write_if_changed(:forum_fortress_site_id, snapshot[:site_id])
        write_if_changed(:forum_fortress_preferred_endpoint, snapshot[:preferred_endpoint])
      end

      def recover_identity(error)
        with_identity_lock do
          snapshot = identity_snapshot
          begin
            prepare_identity_recovery(error)
            bootstrap_if_needed_unlocked(force: true)
          rescue StandardError
            best_effort_state_update("restore_stale_identity") { restore_identity(snapshot) }
            raise
          end
        end
      end

      def clear_site_identity
        write_if_changed(:forum_fortress_site_id, "")
        write_if_changed(:forum_fortress_preferred_endpoint, "")
      end

      def prepare_identity_recovery(error)
        # A node mismatch is the expected signal that a node-scoped offline
        # token reached the wrong edge. Keep the token and its offline site
        # metadata so the forced bootstrap can try the advertised fallback
        # issuers and reconcile it when control is reachable.
        if offline_bootstrap_key? && error.respond_to?(:code) && error.code.to_s == "node_mismatch"
          return
        end

        clear_site_identity
        return if error.respond_to?(:code) && error.code.to_s.downcase == "stale_site"

        write_if_changed(:forum_fortress_api_key, "")
      end

      def persist_identity(response, endpoint: nil, lock: true)
        return with_identity_lock { persist_identity(response, endpoint:, lock: false) } if lock

        api_key_value = response["api_key"].to_s.strip
        site_id_value = response["site_id"].to_s.strip
        write_if_changed(:forum_fortress_api_key, api_key_value) unless api_key_value.empty?
        unless site_id_value.empty?
          best_effort_state_update("site_identity") do
            write_if_changed(:forum_fortress_site_id, site_id_value)
          end
        end

        effective_key = api_key_value.empty? ? api_key : api_key_value
        offline_response =
          response["key_type"].to_s == "offline_bootstrap" || effective_key.start_with?("ff_ob_")
        candidate = safe_endpoint(response["preferred_endpoint"])
        candidate ||= safe_endpoint(endpoint) unless offline_response
        state = endpoint_state
        original_state = state.dup
        if offline_response
          if candidate
            state["offline_pinned"] = true
            state["offline_preferred_endpoint"] = candidate
            state["issuer_node_id"] = response["issuer_node_id"].to_s.strip
            state["offline_canonical_domain"] = response["canonical_domain"].to_s.strip
            state["offline_rebootstrap_at"] = now +
              [response["rebootstrap_after_seconds"].to_i, 60].max
            state["fallback_bootstrap_endpoints"] = Array(
              response["fallback_bootstrap_endpoints"],
            ).filter_map { |value| safe_endpoint(value) }
            state["key_type"] = "offline_bootstrap"
            best_effort_state_update("preferred_endpoint") do
              write_if_changed(:forum_fortress_preferred_endpoint, candidate)
            end
          end
        elsif !effective_key.empty?
          state.delete("offline_pinned")
          state.delete("issuer_node_id")
          state.delete("offline_preferred_endpoint")
          state.delete("offline_rebootstrap_at")
          state.delete("offline_canonical_domain")
          state.delete("fallback_bootstrap_endpoints")
          response_key_type = response["key_type"].to_s.strip
          if response_key_type.empty?
            state.delete("key_type")
          else
            state["key_type"] = response_key_type
          end
          write_if_changed(
            :forum_fortress_preferred_endpoint,
            API_BASE_URLS.fetch(region, API_BASE_URLS["global"]),
          )
        end
        if !response["plan"].to_s.strip.empty?
          state["plan_name"] = response["plan"].to_s.strip.downcase
        end
        save_endpoint_state(state) unless state == original_state
      end

      def clear_error
        with_identity_lock do
          state = endpoint_state
          next unless state.key?("last_error_code") || state.key?("last_error_at")

          state.delete("last_error_code")
          state.delete("last_error_at")
          save_endpoint_state(state)
        end
      end

      def handle_failure(operation, error)
        best_effort_state_update("failure_state") { remember_error(error) }
        log_failure(operation, error)
        return nil if fail_open?

        raise Unavailable.new(cause: error)
      end

      def handle_background_failure(operation, error)
        best_effort_state_update("background_failure_state") { remember_error(error) }
        log_failure(operation, error)
        nil
      end

      def remember_error(error)
        with_identity_lock do
          state = endpoint_state
          state["last_error_code"] = error_code(error)
          state["last_error_at"] = now
          save_endpoint_state(state)
        end
      end

      def log_failure(operation, error)
        return unless @logger

        @logger.warn("Forum Fortress #{operation} failed (#{error_code(error)})")
      rescue StandardError
        nil
      end

      def error_code(error)
        value = error.respond_to?(:code) ? error.code.to_s : ""
        value = value.downcase
        value.match?(/\A[a-z0-9_.-]{1,80}\z/) ? value : "connection_failed"
      end

      def endpoint_state
        value = read(:forum_fortress_endpoint_state, "{}")
        parsed = JSON.parse(value.to_s)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError, TypeError
        {}
      end

      def save_endpoint_state(state)
        write_if_changed(:forum_fortress_endpoint_state, JSON.generate(state))
      end

      def best_effort_state_update(operation)
        yield
      rescue StandardError => error
        log_failure(operation, error)
        nil
      end

      def with_identity_lock
        key = "forum_fortress:identity:#{domain}"
        if defined?(DistributedMutex)
          DistributedMutex.synchronize(key, validity: IDENTITY_LOCK_VALIDITY_SECONDS) { yield }
        else
          mutex =
            self.class.fallback_mutexes_guard.synchronize do
              self.class.fallback_mutexes[key] ||= Mutex.new
            end
          mutex.synchronize { yield }
        end
      end

      def write_if_changed(name, value)
        return if read(name, nil).to_s == value.to_s

        write(name, value)
      end

      def safe_endpoint(value)
        value = value.to_s.strip.chomp("/")
        return nil if value.empty?

        uri = URI.parse(value)
        return nil unless uri.is_a?(URI::HTTPS) && !uri.host.to_s.empty?
        return nil if uri.user || uri.password || uri.query || uri.fragment

        value
      rescue URI::InvalidURIError
        nil
      end

      def now
        @clock.call.to_i
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def read(name, default)
        return @settings.public_send(name) if @settings.respond_to?(name)
        predicate = "#{name}?"
        return @settings.public_send(predicate) if @settings.respond_to?(predicate)

        if @settings.respond_to?(:[])
          value = @settings[name] || @settings[name.to_s]
          return value unless value.nil?
        end

        default
      end

      def read_boolean(name, default)
        value = read(name, default)
        return value if value == true || value == false

        !%w[0 false no off].include?(value.to_s.downcase)
      end

      def write(name, value)
        if @settings.respond_to?(:set)
          @settings.set(name, value)
        elsif @settings.respond_to?("#{name}=")
          @settings.public_send("#{name}=", value)
        elsif @settings.respond_to?(:[]=)
          @settings[name] = value
        end
      end
    end
  end
end
