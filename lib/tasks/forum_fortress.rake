# frozen_string_literal: true

unless Rake::Task.task_defined?("forum_fortress:uninstall")
  desc "Deprovision Forum Fortress and remove all local plugin setting overrides"
  task "forum_fortress:uninstall" => :environment do
    force_local_cleanup = ENV["FORUM_FORTRESS_FORCE_LOCAL_CLEANUP"] == "1"

    uninstall =
      lambda do
        result = ForumFortress::Uninstaller.new.uninstall!(force_local_cleanup:)
        puts(
          "Forum Fortress uninstall complete " \
            "(remote=#{result[:remote_status]}, local_settings=#{result[:local_settings_cleared]})",
        )
      end

    if ENV["RAILS_DB"].present?
      uninstall.call
    else
      RailsMultisite::ConnectionManagement.each_connection do |database|
        puts "Database: #{database}"
        uninstall.call
      end
    end
  end
end
