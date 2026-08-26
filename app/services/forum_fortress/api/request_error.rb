# frozen_string_literal: true

module ForumFortress
  module Api
    class RequestError < StandardError
      attr_reader :status, :code

      def initialize(message = "Forum Fortress request failed", status: 0, code: nil)
        @status = status.to_i
        normalized_code = code.to_s.strip.downcase
        @code = normalized_code unless normalized_code.empty?
        super(message)
      end
    end
  end
end
