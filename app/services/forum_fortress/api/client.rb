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
      PLUGIN_VERSION = "0.1.0-alpha.1"
      PLATFORM = "discourse"
      CONTROL_BASE_URL = "https://fortress.ffapi.net"
      API_BASE_URLS = {
        "global" => "https://api.ffapi.net",
        "uk" => "https://api-uk.ffapi.net",
        "eu" => "https://api-eu.ffapi.net",
        "us" => "https://api-us.ffapi.net",
      }.freeze
      CHECK_ENDPOINT_TIMEOUT_SECONDS = 1
      # The generic bootstrap endpoint cannot replay a key after a lost first
      # response. Give its authoritative control-plane attempt enough time to
      # complete an edge-to-control provisioning round trip instead of risking
      # an orphaned identity after a short read timeout. This applies only to
      # bootstrap; normal checks retain their short configured timeout.
      BOOTSTRAP_TOTAL_TIMEOUT_SECONDS = 30
      BOOTSTRAP_ENDPOINT_TIMEOUT_SECONDS = 30
      MIN_TIMEOUT_SECONDS = 1
      MAX_TIMEOUT_SECONDS = 30
      BOOTSTRAP_RETRY_BACKOFF_SECONDS = 300

      def initialize(settings: nil, transport: nil, logger: nil, clock: nil, domain: nil)
        @settings = settings || SiteSetting
        @transport = transport || Transport.new
        @logger = logger || (defined?(Rails) ? Rails.logger : nil)
        @clock = clock || -> { Time.now.to_i }
        @domain_override = domain
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
            best_effort_state_update("clear_stale_identity") { prepare_identity_recovery(error) }
            bootstrap_if_needed(force: true)
            retry
          end

          handle_failure("check/#{event_type}", error)
        rescue StandardError => error
          handle_failure("check/#{event_type}", error)
        end
      end

      def bootstrap_if_needed(force: false)
        return nil unless enabled?
        return nil if !force && !api_key.empty?

        state = endpoint_state
        last_failure = state["last_bootstrap_failure_at"].to_i
        if !force && last_failure.positive? && now - last_failure < BOOTSTRAP_RETRY_BACKOFF_SECONDS
          raise RequestError.new("bootstrap is waiting before retry", code: "bootstrap_backoff")
        end

        state["last_bootstrap_attempt_at"] = now
        best_effort_state_update("bootstrap_attempt") { save_endpoint_state(state) }

        payload = common_payload
        payload["bootstrap_token"] = bootstrap_token unless bootstrap_token.empty?
        candidates = ([CONTROL_BASE_URL] + check_candidates).uniq
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

            persist_identity(response, endpoint: base)
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
          preferred_endpoint: safe_endpoint(read(:forum_fortress_preferred_endpoint, "")),
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

        health_endpoint = nil
        health_error = nil
        health_deadline = monotonic_now + [timeout_budget, 5].min
        check_candidates.each do |base|
          remaining = health_deadline - monotonic_now
          break if remaining <= 0

          begin
            @transport.get_json(
              base,
              "/health",
              timeout: [CHECK_ENDPOINT_TIMEOUT_SECONDS, remaining].min,
            )
            health_endpoint = base
            best_effort_state_update("health_endpoint") do
              write_if_changed(:forum_fortress_preferred_endpoint, base)
            end
            break
          rescue StandardError => error
            health_error = error
          end
        end

        status =
          @transport.get_json(
            CONTROL_BASE_URL,
            "/v1/site/status",
            query: {
              domain: domain,
            },
            headers: {
              "X-FF-Key" => api_key,
            },
            timeout: [timeout_budget, 2].min,
          )
        unless status["site_id"].to_s.strip.length.positive?
          raise RequestError.new("invalid site status", code: "invalid_site_status")
        end

        best_effort_state_update("connection_identity") do
          persist_identity(status, endpoint: health_endpoint)
        end
        best_effort_state_update("clear_error") { clear_error }

        if health_endpoint
          { ok: true, health: true, site_status: true, endpoint: health_endpoint }
        else
          error =
            health_error ||
              RequestError.new("check endpoint unavailable", code: "check_endpoint_unavailable")
          remember_error(error)
          { ok: false, health: false, site_status: true, error_code: error_code(error) }
        end
      rescue StandardError => error
        best_effort_state_update("connection_test_failure") { remember_error(error) }
        {
          ok: false,
          health: !health_endpoint.nil?,
          site_status: false,
          error_code: error_code(error),
        }
      end

      def portal_launch
        raise Unavailable, "Forum Fortress is disabled" unless enabled?

        rebootstrap_attempted = false
        begin
          bootstrap_if_needed
          response =
            @transport.post_json(
              CONTROL_BASE_URL,
              "/v1/site/portal",
              common_payload,
              timeout: [timeout_budget, 3].min,
            )
          best_effort_state_update("clear_error") { clear_error }
          response
        rescue RequestError => error
          if !rebootstrap_attempted && stale_identity_error?(error)
            rebootstrap_attempted = true
            best_effort_state_update("clear_stale_identity") { prepare_identity_recovery(error) }
            bootstrap_if_needed(force: true)
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

        @transport.post_json(
          CONTROL_BASE_URL,
          "/v1/site/deprovision",
          common_payload.merge("reason" => normalized_reason),
          timeout: [timeout_budget, 3].min,
        )
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
        preferred = safe_endpoint(read(:forum_fortress_preferred_endpoint, ""))
        preferred = nil if region != "global" && preferred != configured
        candidates = region == "global" ? [preferred, configured] : [configured, preferred]
        candidates << API_BASE_URLS["global"] if global_fallback? && region != "global"
        candidates.compact.uniq
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

      def stale_identity_error?(error)
        stale_codes = %w[invalid_key invalid_api_key node_mismatch stale_site site_not_found]
        error.status.to_i == 401 || stale_codes.include?(error.code)
      end

      def clear_site_identity
        write_if_changed(:forum_fortress_site_id, "")
        write_if_changed(:forum_fortress_preferred_endpoint, "")
      end

      def prepare_identity_recovery(error)
        clear_site_identity
        return if error.respond_to?(:code) && error.code.to_s.downcase == "stale_site"

        write_if_changed(:forum_fortress_api_key, "")
      end

      def persist_identity(response, endpoint: nil)
        api_key_value = response["api_key"].to_s.strip
        site_id_value = response["site_id"].to_s.strip
        write_if_changed(:forum_fortress_api_key, api_key_value) unless api_key_value.empty?
        unless site_id_value.empty?
          best_effort_state_update("site_identity") do
            write_if_changed(:forum_fortress_site_id, site_id_value)
          end
        end

        candidate = safe_endpoint(response["preferred_endpoint"] || endpoint)
        if candidate
          best_effort_state_update("preferred_endpoint") do
            write_if_changed(:forum_fortress_preferred_endpoint, candidate)
          end
        end
      end

      def clear_error
        state = endpoint_state
        return unless state.key?("last_error_code") || state.key?("last_error_at")

        state.delete("last_error_code")
        state.delete("last_error_at")
        save_endpoint_state(state)
      end

      def handle_failure(operation, error)
        best_effort_state_update("failure_state") { remember_error(error) }
        log_failure(operation, error)
        return nil if fail_open?

        raise Unavailable.new(cause: error)
      end

      def remember_error(error)
        state = endpoint_state
        state["last_error_code"] = error_code(error)
        state["last_error_at"] = now
        save_endpoint_state(state)
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

      def write_if_changed(name, value)
        return if read(name, nil).to_s == value.to_s

        write(name, value)
      end

      def safe_endpoint(value)
        value = value.to_s.strip.chomp("/")
        return nil unless API_BASE_URLS.value?(value)

        value
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
