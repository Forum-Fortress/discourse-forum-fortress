# frozen_string_literal: true

RSpec.describe ForumFortress do
  def plugin_setting_names
    ForumFortress::Uninstaller::SETTING_NAMES
  end

  it "capitalizes the product name in site-setting labels while disabled" do
    SiteSetting.forum_fortress_enabled = false

    expect(plugin_setting_names.map { |name| SiteSetting.humanized_name(name) }).to all(
      start_with("Forum Fortress"),
    )
  end

  it "capitalizes the product name in site-setting labels while enabled" do
    enable_current_plugin

    expect(plugin_setting_names.map { |name| SiteSetting.humanized_name(name) }).to all(
      start_with("Forum Fortress"),
    )
  end
end
