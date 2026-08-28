# frozen_string_literal: true

module Jobs
  class ForumFortressHeartbeat < ::Jobs::Scheduled
    every 10.minutes
    sidekiq_options retry: false

    def execute(_args = nil)
      return unless SiteSetting.forum_fortress_enabled

      ::ForumFortress::Api::Client.new.heartbeat
    end
  end
end
