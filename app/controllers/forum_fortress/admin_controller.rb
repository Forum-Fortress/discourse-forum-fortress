# frozen_string_literal: true

require "uri"

module ForumFortress
  class AdminController < ::Admin::AdminController
    requires_plugin ForumFortress::PLUGIN_NAME

    def status
      render json: ForumFortress::Api::Client.new.status_summary
    end

    def test
      result = ForumFortress::Api::Client.new.connection_test
      render json: result, status: result[:ok] ? :ok : :service_unavailable
    end

    def portal
      result = ForumFortress::Api::Client.new.portal_launch
      url = result["portal_url"].to_s.strip
      raise ForumFortress::Api::Unavailable unless trusted_portal_url?(url)

      redirect_to url, allow_other_host: true
    rescue ForumFortress::Api::Unavailable
      render plain: I18n.t("forum_fortress.errors.portal_unavailable"), status: :bad_gateway
    end

    private

    def trusted_portal_url?(url)
      uri = URI.parse(url)
      host = uri.host.to_s.downcase
      trusted_host =
        host == "forumfortress.com" || host.end_with?(".forumfortress.com") ||
          host == "ffapi.net" || host.end_with?(".ffapi.net")

      uri.scheme.to_s.downcase == "https" && trusted_host && uri.userinfo.nil?
    rescue URI::InvalidURIError
      false
    end
  end
end
