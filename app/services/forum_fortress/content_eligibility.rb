# frozen_string_literal: true

module ForumFortress
  class ContentEligibility
    def new_post?(manager)
      args = manager.args
      return false if private_message_args?(args)

      topic_id = argument(args, :topic_id)
      if present?(topic_id)
        topic = Topic.find_by(id: topic_id)
        return topic?(topic)
      end

      category_id = argument(args, :category)
      if present?(category_id)
        return category?(resolve_category(normalize_destination(category_id)))
      end

      default_category_ids =
        [
          SiteSetting.default_composer_category,
          SiteSetting.uncategorized_category_id,
        ].select { |value| present?(value) }.uniq
      default_category_ids.any? &&
        default_category_ids.all? { |value| category?(resolve_category(value)) }
    rescue StandardError
      false
    end

    def edit?(topic, current_category_id: nil, intended_category_id: nil, category_change: false)
      return false unless topic
      return false if topic.respond_to?(:private_message?) && topic.private_message?

      current =
        if current_category_id.nil?
          topic.respond_to?(:category) ? topic.category : nil
        else
          resolve_category(current_category_id)
        end
      return false unless category?(current)
      return true unless category_change

      category?(resolve_category(normalize_destination(intended_category_id)))
    rescue StandardError
      false
    end

    private

    def topic?(topic)
      return false unless topic
      return false if topic.respond_to?(:private_message?) && topic.private_message?

      category?(topic.respond_to?(:category) ? topic.category : nil)
    end

    def category?(category)
      category && category.respond_to?(:read_restricted?) && !category.read_restricted?
    end

    def resolve_category(value)
      return value if value.is_a?(Category)
      return nil unless value.is_a?(Integer) || value.to_s.match?(/\A\d+\z/)

      Category.find_by(id: value.to_i)
    end

    def normalize_destination(value)
      numeric = value.is_a?(Integer) || value.to_s.match?(/\A\d+\z/)
      return value unless numeric
      return SiteSetting.uncategorized_category_id if value.to_i.zero?

      value
    end

    def private_message_args?(args)
      argument(args, :archetype).to_s == Archetype.private_message.to_s
    end

    def argument(args, name)
      return args[name] if args.respond_to?(:key?) && args.key?(name)

      string_name = name.to_s
      return args[string_name] if args.respond_to?(:key?) && args.key?(string_name)

      nil
    end

    def present?(value)
      !value.to_s.strip.empty?
    end
  end
end
