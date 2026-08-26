# frozen_string_literal: true

module ForumFortress
  module PostRevisorExtension
    REVISION_CONTEXT_KEY = :forum_fortress_post_revision_context

    def revise!(editor, fields, opts = {})
      return super unless SiteSetting.forum_fortress_enabled

      attributes = fields.with_indifferent_access
      previous_context = RequestStore.store[REVISION_CONTEXT_KEY]
      RequestStore.store[REVISION_CONTEXT_KEY] = {
        post_id: @post.id,
        title_changed: attributes.key?(:title) && attributes[:title].to_s != @topic.title.to_s,
      }

      begin
        super
      ensure
        if previous_context
          RequestStore.store[REVISION_CONTEXT_KEY] = previous_context
        else
          RequestStore.store.delete(REVISION_CONTEXT_KEY)
        end
      end
    end
  end
end
