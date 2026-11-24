# frozen_string_literal: true

module ForumFortress
  module RegistrationRequestContext
    def self.prepended(controller)
      # OAuth/SSO/invite creation can bypass UsersController#create. Capture the
      # inbound header at the common HTTP boundary, before any model validation.
      controller.before_action :forum_fortress_capture_client_agent
    end

    private

    def forum_fortress_capture_client_agent
      # RequestStore expires with this inbound request. Background/imported
      # registrations have no client header and must not use the API transport UA.
      RequestStore.store[:forum_fortress_registration_user_agent] = request.user_agent.to_s.byteslice(0, 1024).to_s.scrub
    end
  end
end
