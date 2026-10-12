# frozen_string_literal: true

module Jobs
  class ForumFortressRepeatOffender < ::Jobs::Base
    def execute(args)
      # Disabling the feature while the job is queued cancels enforcement.
      return unless SiteSetting.forum_fortress_enabled
      return unless SiteSetting.forum_fortress_repeat_offender_action == "suspend"

      member = ::User.find_by(id: args[:user_id].to_i)
      return unless ::ForumFortress::RepeatOffenders.safe_member?(member)
      return if member.suspended?

      # Native Discourse staff audit, session revocation and expiry handling.
      ::UserSuspender.new(
        member,
        suspended_till: 7.days.from_now,
        reason: "Two high-confidence Forum Fortress spam blocks within 24 hours",
        by_user: Discourse.system_user,
      ).suspend
    end
  end
end
