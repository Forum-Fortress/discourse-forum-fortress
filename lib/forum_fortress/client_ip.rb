# frozen_string_literal: true

require "ipaddr"

module ForumFortress
  module ClientIp
    HEADERS = %w[
      HTTP_X_FORWARDED_FOR
      HTTP_FORWARDED
      HTTP_X_REAL_IP
      HTTP_CF_CONNECTING_IP
      HTTP_TRUE_CLIENT_IP
    ].freeze

    NON_PUBLIC = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
      172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15
      198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
      ::/128 ::1/128 100::/64 2001:db8::/32 fc00::/7 fe80::/10 ff00::/8
    ].map { |range| IPAddr.new(range) }.freeze

    def self.resolve(request, native_ip = nil)
      native = address(native_ip)
      return native.to_s if native && !non_public?(native)

      framework_ip = address(request&.remote_ip)
      return framework_ip.to_s if framework_ip && !non_public?(framework_ip)

      peer = address(request&.get_header("REMOTE_ADDR"))
      fallback = native || framework_ip || peer
      return fallback&.to_s unless peer && non_public?(peer)

      HEADERS.each do |header|
        value = request.get_header(header)
        next unless value.is_a?(String) && !value.empty? && value.bytesize <= 8192

        chain =
          case header
          when "HTTP_X_FORWARDED_FOR"
            value.split(",", -1).map { |node| forwarded_node(node) }
          when "HTTP_FORWARDED"
            forwarded_chain(value)
          else
            [address(value)]
          end

        if chain.all?
          visitor = chain.reverse_each.find { |ip| ip != peer }
          return visitor.to_s if visitor
        end
      end

      fallback&.to_s
    end

    def self.non_public?(ip)
      NON_PUBLIC.any? { |range| range.include?(ip) }
    end

    def self.address(value)
      ip = value.to_s.strip
      return if ip.empty? || ip.match?(/[\/%]/)

      IPAddr.new(ip).native
    rescue IPAddr::InvalidAddressError
      nil
    end

    def self.forwarded_node(value)
      node = value.strip
      ip = address(node)
      return ip if ip

      match = node.match(/\A\[([^\]]+)\](?::(\d{1,5}))?\z/) || node.match(/\A([^:]+):(\d{1,5})\z/)
      host, port = match&.captures
      address(host) if host && port.to_i <= 65_535
    end

    def self.split_quoted(value, separator)
      value.scan(/"[^"]*"|[^",;]+|[,;]/).each_with_object([""]) do |token, parts|
        if token == separator
          parts << ""
        else
          parts.last << token
        end
      end
    end

    def self.forwarded_chain(header)
      return [] if header.match?(/[^\x09\x20-\x7e]|[\\]/) || header.count('"').odd?

      split_quoted(header, ",").map do |element|
        parameters = split_quoted(element, ";").map do |parameter|
          parameter.strip.match(/\A([a-z0-9_-]+)=(?:"([^"]*)"|([^"\s]+))\z/i)
        end
        next unless parameters.all?

        matches = parameters.select { |pair| pair[1].casecmp?("for") }
        forwarded_node(matches.first[2] || matches.first[3]) if matches.one?
      end
    end

    private_class_method :non_public?, :address, :forwarded_node, :split_quoted, :forwarded_chain
  end
end
