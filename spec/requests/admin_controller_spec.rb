# frozen_string_literal: true

RSpec.describe ForumFortress::AdminController do
  fab!(:admin)

  before do
    enable_current_plugin
    SiteSetting.forum_fortress_api_key = "server-only-test-key"
    sign_in(admin)
  end

  it "returns a local status summary without serializing the API key" do
    get "/forum-fortress/status.json"

    expect(response.status).to eq(200)
    expect(response.parsed_body["enabled"]).to eq(true)
    expect(response.parsed_body["configured"]).to eq(true)
    expect(response.body).not_to include("server-only-test-key")
  end

  it "does not expose plugin routes when the plugin is disabled" do
    SiteSetting.forum_fortress_enabled = false

    get "/forum-fortress/status.json"

    expect(response.status).to eq(404)
  end

  it "redirects an administrator to a trusted short-lived portal URL" do
    client =
      instance_double(
        ForumFortress::Api::Client,
        portal_launch: {
          "portal_url" => "https://portal.forumfortress.com/launch/test",
        },
      )
    allow(ForumFortress::Api::Client).to receive(:new).and_return(client)

    get "/forum-fortress/portal.json"

    expect(response).to redirect_to("https://portal.forumfortress.com/launch/test")
  end

  it "refuses a portal redirect outside Forum Fortress hosts" do
    client =
      instance_double(
        ForumFortress::Api::Client,
        portal_launch: {
          "portal_url" => "https://attacker.example/launch/test",
        },
      )
    allow(ForumFortress::Api::Client).to receive(:new).and_return(client)

    get "/forum-fortress/portal.json"

    expect(response.status).to eq(502)
    expect(response.location).to be_nil
  end
end
