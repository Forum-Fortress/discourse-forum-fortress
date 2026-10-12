# frozen_string_literal: true

require "digest"

module ForumFortress
  # Site-local, opt-in account moderation triggered only by explicit
  # server-certified high-confidence BLOCKs. Never sends local user IDs to
  # Forum Fortress. All moderation runs in a separate native Discourse job.
  class RepeatOffenders
    WINDOW_SECONDS = 24.hours.to_i

    def self.record(user:, response:)
      return false unless SiteSetting.forum_fortress_enabled
      return false unless SiteSetting.forum_fortress_repeat_offender_action == "suspend"
      return false unless safe_member?(user)
      return false unless response.is_a?(Hash)
      return false unless (response["decision"] || response[:decision]) == "block"
      return false unless (response["escalation_eligible"] || response[:escalation_eligible]) == true

      reference = response["decision_reference"] || response[:decision_reference] ||
                  response["correlation_id"] || response[:correlation_id] ||
                  response["decision_id"] || response[:decision_id]
      return false if reference.to_s.strip.empty? || reference.to_s == "0"

      prefix = "forum-fortress:repeat-offender:#{user.id}"
      digest = Digest::SHA256.hexdigest(reference.to_s)
      redis = Discourse.redis

      # Atomic across Discourse web workers. Duplicate/retried checks never
      # increment the account counter twice.
      return false unless redis.set("#{prefix}:event:#{digest}", "1", nx: true, ex: WINDOW_SECONDS)
      count = redis.incr("#{prefix}:count")
      redis.expire("#{prefix}:count", WINDOW_SECONDS) if count == 1
      return false if count < 2
      return false unless redis.set("#{prefix}:enforced", "1", nx: true, ex: WINDOW_SECONDS)

      # Not executed in the model validation callback, avoiding mutation of
      # the active posting transaction. The worker rechecks the member.
      Jobs.enqueue_in(5.seconds, :forum_fortress_repeat_offender, user_id: user.id)
      true
    rescue StandardError => error
      Rails.logger.warn("Forum Fortress repeat-offender accounting skipped: #{error.class}")
      false
    end

    def self.safe_member?(user)
      return false if user.nil? || user.new_record? || user.staff? || user.staged? || user.bot?
      return false if user.respond_to?(:is_system_user?) && user.is_system_user?
      return false unless user.id.to_i.positive?
      return false unless user.created_at && user.created_at.between?(7.days.ago, Time.zone.now)
      user.post_count.to_i <= 10
    end
  end
end
