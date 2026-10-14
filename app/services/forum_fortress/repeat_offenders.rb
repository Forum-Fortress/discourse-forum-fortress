# frozen_string_literal: true

require "digest"

module ForumFortress
  # Site-local, opt-in account moderation triggered only by explicit
  # server-certified high-confidence BLOCKs. Never sends local user IDs to
  # Forum Fortress. All moderation runs in a separate native Discourse job.
  class RepeatOffenders
    WINDOW_SECONDS = 24.hours.to_i
    ACTIONS = %w[suspend suspend_and_clean].freeze

    def self.record(user:, response:, content: "")
      return false unless SiteSetting.forum_fortress_enabled
      action = SiteSetting.forum_fortress_repeat_offender_action
      return false unless ACTIONS.include?(action)
      cleanup_mode = action == "suspend_and_clean"
      unless safe_member?(user, max_posts: cleanup_mode ? 5 : 10, cleanup_mode: cleanup_mode)
        return false
      end
      return false unless response.is_a?(Hash)
      return false unless (response["decision"] || response[:decision]) == "block"
      advisory = cleanup_mode ? "repeat_cleanup_eligible" : "escalation_eligible"
      return false unless (response[advisory] || response[advisory.to_sym]) == true

      reference =
        response["decision_reference"] || response[:decision_reference] ||
          response["decision_id"] || response[:decision_id]
      return false if reference.to_s.strip.empty? || reference.to_s == "0"

      prefix = "forum-fortress:repeat-offender:#{user.id}"
      prefix = "#{prefix}:cleanup" if cleanup_mode
      digest = Digest::SHA256.hexdigest(reference.to_s)
      redis = Discourse.redis

      # Atomic across Discourse web workers. Duplicate/retried checks never
      # increment the account counter twice.
      return false unless redis.set("#{prefix}:event:#{digest}", "1", nx: true, ex: WINDOW_SECONDS)
      body = content.to_s.strip
      unless body.empty?
        body_digest = Digest::SHA256.hexdigest(body)
        unless redis.set("#{prefix}:body:#{body_digest}", "1", nx: true, ex: WINDOW_SECONDS)
          return false
        end
      end
      redis.sadd("#{prefix}:events", digest)
      redis.expire("#{prefix}:events", WINDOW_SECONDS)
      count = redis.incr("#{prefix}:count")
      redis.expire("#{prefix}:count", WINDOW_SECONDS) if count == 1
      threshold = cleanup_mode ? 3 : 2
      return false if count < threshold
      evidence_events = Array(redis.smembers("#{prefix}:events")).uniq
      return false if evidence_events.length < threshold
      evidence_key = "repeat_offender_evidence:#{user.id}"
      evidence_key = "#{evidence_key}:cleanup" if cleanup_mode
      PluginStore.set(
        ::ForumFortress::PLUGIN_NAME,
        evidence_key,
        {
          qualified_at: Time.current.to_i,
          events: evidence_events.sort.first(10),
          cleanup_mode: cleanup_mode,
        },
      )
      return false unless redis.set("#{prefix}:enforced", "1", nx: true, ex: WINDOW_SECONDS)

      # Not executed in the model validation callback, avoiding mutation of
      # the active posting transaction. The worker rechecks the member.
      begin
        Jobs.enqueue_in(5.seconds, :forum_fortress_repeat_offender, user_id: user.id)
      rescue StandardError
        # Let a later independent qualifying event retry the durable enqueue.
        redis.del("#{prefix}:enforced")
        raise
      end
      true
    rescue StandardError => error
      Rails.logger.warn("Forum Fortress repeat-offender accounting skipped: #{error.class}")
      false
    end

    # Discourse user_stat.post_count excludes topic starters and can be stale.
    # Cleanup uses the actual current regular forum posts, including starters
    # and restricted categories; private messages and whispers are excluded.
    def self.cleanup_post_count(user)
      ::Post
        .where(user_id: user.id, post_type: ::Post.types[:regular])
        .joins(:topic)
        .where(topics: { archetype: ::Archetype.default })
        .count
    end

    def self.safe_member?(user, max_posts: 10, cleanup_mode: false)
      return false if user.nil? || user.new_record? || user.staff? || user.staged? || user.bot?
      return false if user.respond_to?(:is_system_user?) && user.is_system_user?
      return false unless user.id.to_i.positive?
      return false unless user.created_at && user.created_at.between?(7.days.ago, Time.zone.now)
      posts = cleanup_mode ? cleanup_post_count(user) : user.post_count.to_i
      posts <= max_posts
    end
  end
end
