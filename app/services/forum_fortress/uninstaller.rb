# frozen_string_literal: true

module ForumFortress
  class Uninstaller
    SETTING_NAMES = %i[
      forum_fortress_enabled
      forum_fortress_api_key
      forum_fortress_bootstrap_token
      forum_fortress_site_id
      forum_fortress_api_region
      forum_fortress_allow_global_fallback
      forum_fortress_timeout
      forum_fortress_fail_open
      forum_fortress_preferred_endpoint
      forum_fortress_endpoint_state
    ].freeze
    SUCCESS_STATUSES = %w[ok already_removed no_identity].freeze

    def initialize(settings: SiteSetting, client: nil)
      @settings = settings
      @client = client || ForumFortress::Api::Client.new(settings:)
    end

    def uninstall!(force_local_cleanup: false)
      remote_status = @client.deprovision_site.fetch("status", "invalid_response").to_s
      if SUCCESS_STATUSES.exclude?(remote_status)
        raise ForumFortress::Api::Unavailable,
              "Forum Fortress did not confirm remote deprovisioning"
      end

      clear_local_settings!
      { remote_status:, local_settings_cleared: SETTING_NAMES.length }
    rescue StandardError
      raise unless force_local_cleanup

      clear_local_settings!
      { remote_status: "unconfirmed", local_settings_cleared: SETTING_NAMES.length }
    end

    private

    def clear_local_settings!
      SETTING_NAMES.each { |name| @settings.remove_override!(name) }
    end
  end
end
