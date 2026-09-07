# frozen_string_literal: true

module ForumFortress
  module PostRevisorExtension
    REVISION_CONTEXT_KEY = :forum_fortress_post_revision_context

    def revise!(editor, fields, opts = {})
      return super unless SiteSetting.forum_fortress_enabled

      attributes = fields.with_indifferent_access
      current_category_id = @topic.category_id
      intended_category_id =
        (forum_fortress_category_id(attributes[:category_id]) if attributes.key?(:category_id))
      previous_context = RequestStore.store[REVISION_CONTEXT_KEY]
      RequestStore.store[REVISION_CONTEXT_KEY] = {
        post_id: @post.id,
        title_changed: attributes.key?(:title) && attributes[:title].to_s != @topic.title.to_s,
        current_category_id: current_category_id,
        intended_category_id: intended_category_id,
        category_changed:
          attributes.key?(:category_id) && intended_category_id.to_i != current_category_id.to_i,
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

    private

    def forum_fortress_category_id(value)
      numeric = value.is_a?(Integer) || value.to_s.match?(/\A\d+\z/)
      return value unless numeric

      requested = value.to_i
      requested.zero? ? SiteSetting.uncategorized_category_id : requested
    end
  end
end
