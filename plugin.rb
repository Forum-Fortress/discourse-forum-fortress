# frozen_string_literal: true
# Copyright (c) 2026 Marscastle Ltd trading as Forum Fortress
# SPDX-License-Identifier: GPL-2.0-or-later

# name: discourse-forum-fortress
# about: Forum Fortress anti-spam protection for Discourse
# version: 0.1.0-alpha.3
# authors: Forum Fortress
# url: https://github.com/Forum-Fortress/discourse
# required_version: 2026.8.0

require "request_store"

enabled_site_setting :forum_fortress_enabled
add_admin_route "forum_fortress.admin.title", "discourse-forum-fortress", use_new_show_route: true
register_asset "stylesheets/common/forum-fortress.scss"
register_svg_icon "arrow-up-right-from-square"
register_svg_icon "shield-halved"

module ::ForumFortress
  PLUGIN_NAME = "discourse-forum-fortress"
end

require_relative "lib/forum_fortress/engine"

after_initialize do
  reloadable_patch { ::PostRevisor.prepend(ForumFortress::PostRevisorExtension) }
  reloadable_patch do
    formatter = ::SiteSettings::LabelFormatter.singleton_class
    extension = ForumFortress::SiteSettingLabelExtension
    formatter.prepend(extension) if formatter.ancestors.exclude?(extension)
  end

  register_modifier(:users_controller_update_user_params) do |attributes, actor, _params|
    RequestStore.store[:forum_fortress_profile_actor] = actor
    attributes
  end

  validate(:user, :forum_fortress_validate_user) do
    ForumFortress::Protector.new.validate_user(self)
  end

  validate(:user_profile, :forum_fortress_validate_user_profile) do
    ForumFortress::Protector.new.validate_user_profile(self)
  end

  validate(:post, :forum_fortress_validate_post_edit) do
    ForumFortress::Protector.new.validate_post_edit(self)
  end

  validate(:topic, :forum_fortress_validate_topic_edit) do
    ForumFortress::Protector.new.validate_topic_edit(self)
  end

  NewPostManager.add_handler(1) do |manager|
    ForumFortress::Protector.new.validate_new_post(manager)
  end
end
