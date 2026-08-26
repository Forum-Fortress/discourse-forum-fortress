# frozen_string_literal: true

module ForumFortress
  module Api
    module Decision
      ALLOW = "allow"
      REVIEW = "review"
      BLOCK = "block"
      VALID = [ALLOW, REVIEW, BLOCK].freeze

      class InvalidResponse < StandardError
        def code
          "invalid_decision_response"
        end
      end

      module_function

      def value(response)
        decision = (response["decision"] || response[:decision] if response.respond_to?(:[]))

        decision = decision.to_s.strip.downcase
        if VALID.exclude?(decision)
          raise InvalidResponse, "Forum Fortress returned an invalid decision"
        end

        decision
      end

      def assert_valid!(response)
        value(response)
      end

      def allowed?(response)
        [ALLOW, REVIEW].include?(value(response))
      end

      def blocked?(response)
        value(response) == BLOCK
      end
    end
  end
end
