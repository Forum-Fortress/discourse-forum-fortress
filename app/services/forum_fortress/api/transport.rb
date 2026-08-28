# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "timeout"
require "uri"

module ForumFortress
  module Api
    class Transport
      MAX_RESPONSE_BYTES = 1_000_000
      USER_AGENT = "ForumFortress-Discourse/0.1.0-alpha.2"

      def get_json(base, path, query: {}, headers: {}, timeout:)
        request(base, path, method: :get, query:, headers:, timeout:)
      end

      def post_json(base, path, payload, headers: {}, timeout:)
        request(
          base,
          path,
          method: :post,
          body: JSON.generate(payload),
          headers: headers.merge("Content-Type" => "application/json"),
          timeout:,
        )
      end

      private

      def request(base, path, method:, body: nil, query: {}, headers:, timeout:)
        uri = URI.parse("#{base}#{path}")
        unless uri.is_a?(URI::HTTPS)
          raise RequestError.new("invalid endpoint", code: "invalid_endpoint")
        end

        uri.query = URI.encode_www_form(query) unless query.empty?
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        bounded_timeout = [[timeout.to_f, 0.1].max, 30].min
        http.open_timeout = bounded_timeout
        http.read_timeout = bounded_timeout
        http.write_timeout = bounded_timeout if http.respond_to?(:write_timeout=)

        request_class = method == :post ? Net::HTTP::Post : Net::HTTP::Get
        request = request_class.new(uri)
        request["Accept"] = "application/json"
        request["User-Agent"] = USER_AGENT
        headers.each { |key, value| request[key] = value.to_s }
        request.body = body if body

        response = nil
        response_body = +""
        Timeout.timeout(bounded_timeout, Net::ReadTimeout) do
          http.start do |connection|
            connection.request(request) do |remote_response|
              response = remote_response
              remote_response.read_body do |chunk|
                if response_body.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES
                  raise RequestError.new(
                          "response too large",
                          status: remote_response.code,
                          code: "response_too_large",
                        )
                end
                response_body << chunk
              end
            end
          end
        end

        unless response.is_a?(Net::HTTPSuccess)
          raise RequestError.new(
                  "remote request rejected",
                  status: response.code,
                  code: response_error_code(response_body),
                )
        end

        return {} if response_body.strip.empty?

        decoded = JSON.parse(response_body)
        unless decoded.is_a?(Hash)
          raise RequestError.new(
                  "invalid response",
                  status: response.code,
                  code: "invalid_response",
                )
        end

        decoded
      rescue RequestError
        raise
      rescue JSON::ParserError
        raise RequestError.new("invalid response", code: "invalid_response")
      rescue StandardError => error
        raise RequestError.new("transport failure", code: transport_error_code(error))
      end

      def response_error_code(body)
        parsed = JSON.parse(body)
        value =
          if parsed.is_a?(Hash)
            detail = parsed["detail"]
            detail_error = detail.is_a?(Hash) ? (detail["error"] || detail["code"]) : nil
            parsed["error"] || detail_error || parsed["code"]
          end
        safe_code(value) || "remote_error"
      rescue JSON::ParserError
        "remote_error"
      end

      def transport_error_code(error)
        case error
        when Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
          "timeout"
        when SocketError
          "dns_or_socket_error"
        when OpenSSL::SSL::SSLError
          "tls_error"
        else
          "transport_error"
        end
      end

      def safe_code(value)
        value = value.to_s.strip.downcase
        value.match?(/\A[a-z0-9_.-]{1,80}\z/) ? value : nil
      end
    end
  end
end
