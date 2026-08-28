# frozen_string_literal: true

RSpec.describe Jobs::ForumFortressHeartbeat do
  it "runs the recovery heartbeat when Forum Fortress is enabled" do
    SiteSetting.forum_fortress_enabled = true
    client = instance_double(ForumFortress::Api::Client, heartbeat: { "status" => "ok" })
    allow(ForumFortress::Api::Client).to receive(:new).and_return(client)

    described_class.new.execute

    expect(client).to have_received(:heartbeat).once
  end

  it "does not contact the API while the plugin is disabled" do
    SiteSetting.forum_fortress_enabled = false
    allow(ForumFortress::Api::Client).to receive(:new)

    described_class.new.execute

    expect(ForumFortress::Api::Client).not_to have_received(:new)
  end
end
