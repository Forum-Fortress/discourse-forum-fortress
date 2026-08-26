# frozen_string_literal: true

module ForumFortress
  module SiteSettingLabelExtension
    def humanized_name(setting)
      super.sub(/\AForum fortress\b/, "Forum Fortress")
    end
  end
end
