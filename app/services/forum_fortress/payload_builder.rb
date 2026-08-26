# frozen_string_literal: true

require "uri"

module ForumFortress
  class PayloadBuilder
    MAX_CONTENT_BYTES = 100_000
    URL_PATTERN = %r{https?://[^\s<>"')]+}i

    def initialize(domain: nil, clock: nil)
      @domain = domain
      @clock = clock || -> { Time.now.to_i }
    end

    def registration(user)
      fields = profile_fields(user)
      user_payload(
        user,
        "ip" =>
          nonblank(attribute(user, :registration_ip_address)) ||
            nonblank(attribute(user, :ip_address)),
        "content" => bounded(fields.values.join("\n")),
        "profile_fields" => fields,
      )
    end

    def new_post(manager)
      args = manager.args
      raw = bounded(args[:raw])
      title = bounded(args[:title])
      content = if nonblank(args[:topic_id])
        raw
      else
        bounded([title, raw].reject { |value| value.strip.empty? }.join("\n\n"))
      end

      user_payload(
        manager.user,
        "content" => content,
        "links" => external_links(content),
        "thread_id" => nonblank(args[:topic_id]),
        "action" => "create",
        "ip" => nonblank(args[:ip_address]),
        "user_agent" => nonblank(args[:user_agent].to_s.byteslice(0, 500)),
      )
    end

    def post_edit(post, actor: post.user)
      first_post = post.respond_to?(:post_number) && post.post_number.to_i == 1
      title = first_post ? attribute(post.topic, :title).to_s : ""
      content = bounded(
        [title, attribute(post, :raw).to_s].reject { |value| value.strip.empty? }.join("\n\n"),
      )

      user_payload(
        actor,
        "content" => content,
        "links" => external_links(content),
        "content_id" => nonblank(attribute(post, :id)),
        "thread_id" => nonblank(attribute(post, :topic_id)),
        "action" => "edit",
      )
    end

    def topic_edit(topic, first_post, actor:)
      content = bounded(
        [attribute(topic, :title).to_s, attribute(first_post, :raw).to_s]
          .reject { |value| value.strip.empty? }
          .join("\n\n"),
      )

      user_payload(
        actor,
        "content" => content,
        "links" => external_links(content),
        "content_id" => nonblank(attribute(first_post, :id)),
        "thread_id" => nonblank(attribute(topic, :id)),
        "action" => "edit",
      )
    end

    def profile(user, profile: nil, fields: nil)
      fields ||= profile_fields(user, profile)
      content = bounded(fields.values.map(&:to_s).join("\n"))

      user_payload(
        user,
        "content" => content,
        "links" => external_links(content),
        "profile_fields" => fields,
      )
    end

    def user_payload(user, extra = {})
      created_at = attribute(user, :created_at) || attribute(user, :joined_at)
      created_at = created_at.to_i if created_at.respond_to?(:to_i)
      age = created_at ? [@clock.call.to_i - created_at, 0].max : 0
      payload = {
        "username" => attribute(user, :username).to_s,
        "email" => attribute(user, :email).to_s,
        "account_age_seconds" => age,
        "post_count" => new_record?(user) ? 0 : attribute(user, :post_count).to_i,
      }

      payload.merge(extra).reject do |_key, value|
        value.nil? || (value.respond_to?(:empty?) && value.empty?)
      end
    end

    def profile_fields(user, profile = nil)
      profile ||= attribute(user, :user_profile)
      fields = {
        "username" => attribute(user, :username).to_s,
        "name" => attribute(user, :name).to_s,
      }
      if profile
        if respond_to_attribute?(profile, :bio_raw)
          fields["bio"] = attribute(profile, :bio_raw).to_s
        end
        if respond_to_attribute?(profile, :website)
          fields["website"] = attribute(profile, :website).to_s
        end
      end
      fields.reject { |_key, value| value.empty? }
    end

    def external_links(content)
      seen = {}
      content.to_s.scan(URL_PATTERN).filter_map do |candidate|
        value = candidate.sub(/[),.;!?]+\z/, "")
        uri = URI.parse(value)
        host = uri.host.to_s.downcase
        next if host.empty? || forum_host?(host) || uri.userinfo
        next if seen[value]

        seen[value] = true
        value
      rescue URI::InvalidURIError
        nil
      end
    end

    private

    def bounded(value)
      value.to_s.byteslice(0, MAX_CONTENT_BYTES).to_s.scrub
    end

    def nonblank(value)
      value = value.to_s
      value unless value.strip.empty?
    end

    def forum_host?(host)
      forum_host = @domain.to_s.downcase
      return false if forum_host.empty?

      host == forum_host || host.end_with?(".#{forum_host}")
    end

    def attribute(object, name)
      return nil unless object && object.respond_to?(name)

      object.public_send(name)
    end

    def respond_to_attribute?(object, name)
      object.respond_to?(name)
    end

    def new_record?(object)
      object.respond_to?(:new_record?) && object.new_record?
    end
  end
end
