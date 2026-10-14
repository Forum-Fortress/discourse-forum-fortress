# frozen_string_literal: true

module Jobs
  class ForumFortressRepeatOffender < ::Jobs::Base
    def execute(args)
      # Disabling the feature while the job is queued cancels enforcement.
      return unless SiteSetting.forum_fortress_enabled
      action = SiteSetting.forum_fortress_repeat_offender_action
      return unless ::ForumFortress::RepeatOffenders::ACTIONS.include?(action)

      cleanup_mode = action == "suspend_and_clean"
      max_posts = cleanup_mode ? 5 : 10
      member = ::User.find_by(id: args[:user_id].to_i)
      unless ::ForumFortress::RepeatOffenders.safe_member?(
               member,
               max_posts: max_posts,
               cleanup_mode: cleanup_mode,
             )
        return
      end

      # One account lock covers the native restriction and the optional cleanup.
      # The durable plugin-store receipt lets cleanup retry independently after a
      # successful suspension, and prevents a moderator's reversal from being
      # overwritten by a stale retry.
      DistributedMutex.synchronize(
        "forum_fortress_repeat_offender_#{member.id}",
        validity: 30.minutes,
      ) do
        return unless SiteSetting.forum_fortress_enabled
        return unless SiteSetting.forum_fortress_repeat_offender_action == action
        member.reload
        unless ::ForumFortress::RepeatOffenders.safe_member?(
                 member,
                 max_posts: max_posts,
                 cleanup_mode: cleanup_mode,
               )
          return
        end

        key = "repeat_offender_ban:#{member.id}"
        ban_applied = PluginStore.get(::ForumFortress::PLUGIN_NAME, key)
        evidence_key = "repeat_offender_evidence:#{member.id}"
        evidence_key = "#{evidence_key}:cleanup" if cleanup_mode
        evidence = PluginStore.get(::ForumFortress::PLUGIN_NAME, evidence_key)
        qualified_at =
          evidence.is_a?(Hash) ? (evidence["qualified_at"] || evidence[:qualified_at]).to_i : 0
        evidence_events = evidence.is_a?(Hash) ? (evidence["events"] || evidence[:events]) : nil
        threshold = cleanup_mode ? 3 : 2
        return unless qualified_at.positive? && Array(evidence_events).uniq.length >= threshold
        return unless (evidence["cleanup_mode"] || evidence[:cleanup_mode]) == cleanup_mode
        return if !ban_applied && qualified_at < 24.hours.ago.to_i

        if ban_applied
          # A completed Forum Fortress ban that has since been lifted is a
          # moderator reversal. Stale evidence must not re-ban or clean again.
          return unless current_suspension?(member, ban_applied)
        else
          return if member.suspended?

          applied =
            ::User.transaction do
              member.lock!
              unless SiteSetting.forum_fortress_enabled &&
                       SiteSetting.forum_fortress_repeat_offender_action == action &&
                       ::ForumFortress::RepeatOffenders.safe_member?(
                         member,
                         max_posts: max_posts,
                         cleanup_mode: cleanup_mode,
                       )
                next false
              end
              next false if member.suspended?
              suspender =
                ::UserSuspender.new(
                  member,
                  suspended_till: 7.days.from_now,
                  reason:
                    (
                      if cleanup_mode
                        "Three qualifying Forum Fortress spam blocks within 24 hours"
                      else
                        "Two high-confidence Forum Fortress spam blocks within 24 hours"
                      end
                    ),
                  by_user: Discourse.system_user,
                )
              suspender.suspend
              ban_applied = suspension_receipt(member, suspender.user_history)
              PluginStore.set(::ForumFortress::PLUGIN_NAME, key, ban_applied)
              true
            end
          return unless applied
        end

        if action == "suspend_and_clean"
          cleanup_key = "repeat_offender_cleanup:#{member.id}"
          cleanup = PluginStore.get(::ForumFortress::PLUGIN_NAME, cleanup_key)
          started_at =
            cleanup.is_a?(Hash) ? (cleanup["started_at"] || cleanup[:started_at]).to_i : 0
          return if started_at.zero? && qualified_at < 24.hours.ago.to_i
          clean_public_replies(member, cleanup_key, cleanup, started_at, ban_applied)
        end
      end
    end

    private

    def suspension_receipt(member, history)
      member.reload
      unless member.suspended? && history && history.target_user_id == member.id &&
               history.acting_user_id == Discourse.system_user.id &&
               history.action == ::UserHistory.actions[:suspend_user]
        raise "Native suspension identity was not recorded"
      end
      {
        "version" => 1,
        "suspended_at" => member.suspended_at.utc.iso8601(6),
        "suspended_till" => member.suspended_till.utc.iso8601(6),
        "history_id" => history.id,
        "acting_user_id" => history.acting_user_id,
      }
    end

    def current_suspension?(member, receipt)
      # A legacy boolean proves only that a historical ban happened. It cannot
      # identify the current native suspension or authorize content cleanup.
      return false unless receipt.is_a?(Hash) && receipt["version"] == 1
      return false unless member.suspended? && member.suspended_at && member.suspended_till
      unless member.suspended_at.utc.iso8601(6) == receipt["suspended_at"] &&
               member.suspended_till.utc.iso8601(6) == receipt["suspended_till"]
        return false
      end
      history =
        ::UserHistory
          .where(target_user_id: member.id, action: ::UserHistory.actions[:suspend_user])
          .order(id: :desc)
          .first
      history && history.id == receipt["history_id"] &&
        history.acting_user_id == receipt["acting_user_id"] &&
        history.acting_user_id == Discourse.system_user.id
    end

    def clean_public_replies(member, cleanup_key, cleanup, started_at, suspension)
      # Never delete a topic's first post: Discourse's native destroyer removes
      # the whole topic with it, which could erase replies from other members.
      # Private messages, whispers, and non-regular post types are excluded.
      cleanup = { "started_at" => Time.current.to_i, "cleaned_post_ids" => [] } if started_at.zero?
      PluginStore.set(::ForumFortress::PLUGIN_NAME, cleanup_key, cleanup) if started_at.zero?
      cleaned =
        Set.new(Array(cleanup["cleaned_post_ids"] || cleanup[:cleaned_post_ids]).map(&:to_i))

      ::Post
        .where(user_id: member.id, post_type: ::Post.types[:regular])
        .joins(topic: :category)
        .where(topics: { archetype: ::Archetype.default, deleted_at: nil })
        .where(categories: { read_restricted: false })
        .where.not(post_number: 1)
        .where(deleted_at: nil)
        .order(:id)
        .limit(5)
        .each do |post|
          # Revalidate ownership and visibility immediately before the native
          # soft delete. This also skips items restored after an earlier run.
          unless SiteSetting.forum_fortress_enabled &&
                   SiteSetting.forum_fortress_repeat_offender_action == "suspend_and_clean"
            return
          end
          member.reload
          unless ::ForumFortress::RepeatOffenders.safe_member?(
                   member,
                   max_posts: 5,
                   cleanup_mode: true,
                 ) && current_suspension?(member, suspension)
            return
          end
          post.reload
          next unless post.user_id == member.id && !post.deleted_at && !post.is_first_post?
          next unless post.topic && !post.topic.private_message? && !post.topic.deleted_at
          next unless post.topic.category && !post.topic.category.read_restricted?
          next if cleaned.include?(post.id)

          deleted =
            ::Post.transaction do
              # Native moderator suspension updates lock this same user row.
              # Recheck under the lock before deleting and persisting a receipt.
              member.lock!
              next false unless current_suspension?(member, suspension)
              destroyer =
                ::PostDestroyer.new(
                  Discourse.system_user,
                  post,
                  context: "Forum Fortress repeat-spammer cleanup",
                )
              member.reload
              next false unless current_suspension?(member, suspension)
              destroyer.destroy
              raise "Native cleanup did not soft-delete the reply" unless post.reload.deleted_at

              cleaned.add(post.id)
              cleanup["cleaned_post_ids"] = cleaned.to_a
              PluginStore.set(::ForumFortress::PLUGIN_NAME, cleanup_key, cleanup)
              true
            end
          return unless deleted
        end
      cleanup["completed_at"] = Time.current.to_i
      PluginStore.set(::ForumFortress::PLUGIN_NAME, cleanup_key, cleanup)
    end
  end
end
