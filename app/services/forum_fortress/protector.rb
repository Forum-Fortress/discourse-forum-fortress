# frozen_string_literal: true

module ForumFortress
  class Protector
    def initialize(client: nil, builder: nil)
      @client = client || Api::Client.new
      @builder = builder || PayloadBuilder.new(domain: @client.domain)
    end

    def validate_user(user)
      return unless protection_enabled?

      actor = profile_actor
      return if ignored_user?(user) || (actor && ignored_user?(actor))

      if user.new_record?
        enforce(user, "register") { @builder.registration(user) }
      elsif changed?(user, :username) || changed?(user, :name)
        return unless actor

        fields = {}
        fields["username"] = user.username.to_s if changed?(user, :username)
        fields["name"] = user.name.to_s if changed?(user, :name)
        enforce(user, "profile_edit") { @builder.profile(user, fields:) }
      end
    end

    def validate_user_profile(profile)
      return unless protection_enabled?

      user = profile.respond_to?(:user) ? profile.user : nil
      actor = profile_actor
      if !user || !actor || ignored_user?(user) || ignored_user?(actor) || profile.new_record?
        return
      end
      return unless changed?(profile, :bio_raw) || changed?(profile, :website)

      fields = {}
      fields["bio"] = profile.bio_raw.to_s if changed?(profile, :bio_raw)
      fields["website"] = profile.website.to_s if changed?(profile, :website)
      enforce(profile, "profile_edit") { @builder.profile(user, fields:) }
    end

    def validate_new_post(manager)
      return unless protection_enabled?

      user = manager.user
      args = manager.args
      return if ignored_user?(user) || private_message_args?(args)

      raw = args[:raw].to_s.strip
      return if raw.empty?

      event = nonblank?(args[:topic_id]) ? "reply" : "topic"
      outcome = outcome_for(event) { @builder.new_post(manager) }
      return if outcome == :allow

      new_post_result(outcome)
    end

    def validate_post_edit(post)
      return unless protection_enabled?

      actor = acting_user(post)
      return if !actor || ignored_user?(actor) || !post.persisted?
      return if post.respond_to?(:topic) && post.topic&.private_message?
      return unless changed?(post, :raw)
      return if first_post_title_edit_in_progress?(post)

      event = post.post_number.to_i == 1 ? "topic_edit" : "reply_edit"
      outcome = outcome_for(event) { @builder.post_edit(post, actor:) }
      add_error(post, outcome)
    end

    def validate_topic_edit(topic)
      return unless protection_enabled?

      actor = acting_user(topic)
      return if !actor || ignored_user?(actor) || !topic.persisted?
      return if topic.respond_to?(:private_message?) && topic.private_message?
      return unless changed?(topic, :title)

      first_post = topic.posts.find_by(post_number: 1)
      return unless first_post

      outcome = outcome_for("topic_edit") { @builder.topic_edit(topic, first_post, actor:) }
      add_error(topic, outcome)
    end

    private

    def check(event, payload)
      response = @client.check(event, payload)
      return :allow if response.nil? || Api::Decision.allowed?(response)
      return :block if Api::Decision.blocked?(response)

      :unavailable
    rescue Api::Unavailable
      :unavailable
    rescue StandardError
      @client.respond_to?(:fail_open?) && !@client.fail_open? ? :unavailable : :allow
    end

    def outcome_for(event)
      check(event, yield)
    rescue StandardError
      fail_open? ? :allow : :unavailable
    end

    def enforce(record, event, &block)
      add_error(record, outcome_for(event, &block))
    end

    def add_error(record, outcome)
      case outcome
      when :block
        record.errors.add(
          :base,
          translation(
            "forum_fortress.errors.blocked",
            "This submission was blocked by Forum Fortress.",
          ),
        )
      when :unavailable
        record.errors.add(
          :base,
          translation(
            "forum_fortress.errors.unavailable",
            "Forum Fortress is temporarily unavailable. Please try again shortly.",
          ),
        )
      end
    end

    def new_post_result(outcome)
      return nil if outcome == :allow

      result = NewPostResult.new(:forum_fortress, false)
      message =
        if outcome == :block
          translation(
            "forum_fortress.errors.blocked",
            "This submission was blocked by Forum Fortress.",
          )
        else
          translation(
            "forum_fortress.errors.unavailable",
            "Forum Fortress is temporarily unavailable. Please try again shortly.",
          )
        end
      result.errors.add(:base, message)
      result
    end

    def ignored_user?(user)
      return true unless user
      return true if user.respond_to?(:staff?) && user.staff?
      return true if user.respond_to?(:staged?) && user.staged?
      return true if user.respond_to?(:is_system_user?) && user.is_system_user?
      return true if user.respond_to?(:bot?) && user.respond_to?(:id) && user.id && user.bot?

      false
    end

    def private_message_args?(args)
      return true if args[:archetype].to_s == Archetype.private_message.to_s
      return false unless nonblank?(args[:topic_id])

      Topic.where(id: args[:topic_id], archetype: Archetype.private_message).exists?
    end

    def protection_enabled?
      !@client.respond_to?(:enabled?) || @client.enabled?
    rescue StandardError
      false
    end

    def fail_open?
      !@client.respond_to?(:fail_open?) || @client.fail_open?
    rescue StandardError
      true
    end

    def acting_user(record)
      return nil unless record.instance_variable_defined?(:@acting_user)

      record.instance_variable_get(:@acting_user)
    end

    def profile_actor
      return nil unless defined?(RequestStore)

      RequestStore.store[:forum_fortress_profile_actor]
    end

    def first_post_title_edit_in_progress?(post)
      return false unless post.post_number.to_i == 1 && defined?(RequestStore)

      context = RequestStore.store[ForumFortress::PostRevisorExtension::REVISION_CONTEXT_KEY]
      context.is_a?(Hash) && context[:post_id].to_i == post.id.to_i && context[:title_changed]
    end

    def changed?(record, attribute)
      method = "will_save_change_to_#{attribute}?"
      return record.public_send(method) if record.respond_to?(method)

      method = "#{attribute}_changed?"
      return record.public_send(method) if record.respond_to?(method)

      record.respond_to?(:changes) && record.changes.key?(attribute.to_s)
    end

    def translation(key, fallback)
      return fallback unless defined?(I18n)

      I18n.t(key, default: fallback)
    end

    def nonblank?(value)
      !value.to_s.strip.empty?
    end
  end
end
