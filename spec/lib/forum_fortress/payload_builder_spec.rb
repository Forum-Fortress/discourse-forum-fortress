# frozen_string_literal: true

ForumFortressPayloadUserDouble =
  Struct.new(
    :username,
    :email,
    :created_at,
    :post_count,
    :registration_ip_address,
    :name,
    :new_record,
    keyword_init: true,
  ) do
    def new_record?
      new_record == true
    end
  end
ForumFortressPayloadManagerDouble = Struct.new(:user, :args, keyword_init: true)

RSpec.describe ForumFortress::PayloadBuilder do
  it "keeps same-site links private while preserving external links" do
    builder = described_class.new(domain: "community.example")
    links =
      builder.external_links(
        "https://community.example/topic/1 " \
          "https://cdn.community.example/file https://outside.example/a",
      )

    expect(links).to eq(["https://outside.example/a"])
  end

  it "builds a topic payload with title, body, request IP, and user agent" do
    user =
      ForumFortressPayloadUserDouble.new(
        username: "new-user",
        email: "user@example.com",
        created_at: Time.at(0),
        post_count: 0,
        registration_ip_address: "192.0.2.10",
        name: "New User",
      )
    manager =
      ForumFortressPayloadManagerDouble.new(
        user:,
        args: {
          title: "A title",
          raw: "A body",
          ip_address: "198.51.100.3",
          user_agent: "Test",
        },
      )
    builder = described_class.new(domain: "community.example", clock: -> { 100 })

    payload = builder.new_post(manager)

    expect(payload).to include(
      "content" => "A title\n\nA body",
      "ip" => "198.51.100.3",
      "user_agent" => "Test",
      "action" => "create",
    )
  end

  it "uses zero posts for a new Discourse user without reading post_count" do
    user =
      ForumFortressPayloadUserDouble.new(
        username: "new-user",
        email: "user@example.com",
        created_at: Time.now,
        registration_ip_address: "192.0.2.10",
        name: "New User",
        new_record: true,
      )
    allow(user).to receive(:post_count).and_raise("post_count is not safe before persistence")

    payload = described_class.new.registration(user)

    expect(payload["post_count"]).to eq(0)
  end
end
