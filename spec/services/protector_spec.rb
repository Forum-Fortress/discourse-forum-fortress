# frozen_string_literal: true

RSpec.describe ForumFortress::Protector do
  fab!(:post)

  class ForumFortressErrorCollection
    attr_reader :messages

    def initialize
      @messages = []
    end

    def add(_attribute, message)
      @messages << message
    end
  end

  class ForumFortressUserDouble
    attr_accessor :email, :ip_address, :name, :username
    attr_reader :errors

    def initialize(new_record: true, staff: false)
      @new_record = new_record
      @staff = staff
      @errors = ForumFortressErrorCollection.new
      @email = "person@example.com"
      @ip_address = "192.0.2.10"
      @name = "Example Person"
      @username = "example_person"
    end

    def bot?
      false
    end

    def is_system_user?
      false
    end

    def new_record?
      @new_record
    end

    def staff?
      @staff
    end

    def staged?
      false
    end
  end

  class ForumFortressClientDouble
    attr_accessor :response
    attr_reader :checks

    def initialize(response, enabled: true, fail_open: true)
      @checks = []
      @enabled = enabled
      @fail_open = fail_open
      @response = response
    end

    def check(event, payload)
      @checks << [event, payload]
      response
    end

    def domain
      "community.example"
    end

    def enabled?
      @enabled
    end

    def fail_open?
      @fail_open
    end
  end

  after { RequestStore.store.delete(:forum_fortress_profile_actor) }

  it "blocks a denied registration" do
    client = ForumFortressClientDouble.new({ "decision" => "block" })
    user = ForumFortressUserDouble.new

    described_class.new(client: client).validate_user(user)

    expect(client.checks.first.first).to eq("register")
    expect(user.errors.messages).to contain_exactly(I18n.t("forum_fortress.errors.blocked"))
  end

  it "runs registration protection through the registered User validator" do
    candidate = Fabricate.build(:user)
    enable_current_plugin
    client = ForumFortressClientDouble.new({ "decision" => "block" })
    allow(ForumFortress::Api::Client).to receive(:new).and_return(client)

    expect(candidate).not_to be_valid
    expect(candidate.errors.full_messages).to include(I18n.t("forum_fortress.errors.blocked"))
    expect(client.checks.map(&:first)).to include("register")
  end

  it "fails open when registration payload construction raises" do
    client = ForumFortressClientDouble.new({ "decision" => "allow" })
    user = ForumFortressUserDouble.new
    builder = instance_double(ForumFortress::PayloadBuilder)
    allow(builder).to receive(:registration).and_raise(ArgumentError, "bad input")
    protector = described_class.new(client: client, builder: builder)

    expect { protector.validate_user(user) }.not_to raise_error
    expect(user.errors.messages).to be_empty
    expect(client.checks).to be_empty
  end

  it "fails closed when registration payload construction raises and fail-open is disabled" do
    client =
      ForumFortressClientDouble.new(
        { "decision" => "allow" },
        fail_open: false,
      )
    user = ForumFortressUserDouble.new
    builder = instance_double(ForumFortress::PayloadBuilder)
    allow(builder).to receive(:registration).and_raise(ArgumentError, "bad input")
    protector = described_class.new(client: client, builder: builder)

    protector.validate_user(user)

    expect(user.errors.messages).to contain_exactly(I18n.t("forum_fortress.errors.unavailable"))
  end

  it "does no post work when protection is disabled" do
    client =
      ForumFortressClientDouble.new(
        { "decision" => "allow" },
        enabled: false,
      )
    builder = instance_double(ForumFortress::PayloadBuilder)
    protector = described_class.new(client: client, builder: builder)
    manager = instance_double(NewPostManager)

    expect(protector.validate_new_post(manager)).to be_nil
    expect(client.checks).to be_empty
  end

  it "blocks a new public topic through the NewPostManager handler" do
    user = Fabricate(:user, refresh_auto_groups: true)
    enable_current_plugin
    client = ForumFortressClientDouble.new({ "decision" => "block" })
    allow(ForumFortress::Api::Client).to receive(:new).and_return(client)
    manager =
      NewPostManager.new(
        user,
        title: "A public topic that should be checked",
        raw: "This public topic body is long enough to pass core validation.",
      )

    result = manager.perform

    expect(result).not_to be_success
    expect(client.checks.map(&:first)).to include("topic")
  end

  it "checks a supported profile edit when the request actor is known" do
    user = Fabricate(:user)
    profile = user.user_profile
    profile.bio_raw = "A newly submitted profile link https://outside.example"
    RequestStore.store[:forum_fortress_profile_actor] = user
    client = ForumFortressClientDouble.new({ "decision" => "block" })

    described_class.new(client: client).validate_user_profile(profile)

    expect(client.checks.first.first).to eq("profile_edit")
    expect(client.checks.first.last["profile_fields"]).to eq(
      "bio" => "A newly submitted profile link https://outside.example",
    )
    expect(profile.errors.full_messages).to include(I18n.t("forum_fortress.errors.blocked"))
  end

  it "skips an out-of-band profile save with no trustworthy acting user" do
    user = Fabricate(:user)
    profile = user.user_profile
    profile.bio_raw = "An out-of-band profile change"
    client = ForumFortressClientDouble.new({ "decision" => "block" })

    described_class.new(client: client).validate_user_profile(profile)

    expect(client.checks).to be_empty
  end

  it "checks a reply edit as the acting editor" do
    editor = ForumFortressUserDouble.new
    author = ForumFortressUserDouble.new
    edited_post =
      instance_double(
        Post,
        acting_user: editor,
        errors: ForumFortressErrorCollection.new,
        persisted?: true,
        post_number: 2,
        raw_changed?: true,
        topic: instance_double(Topic, private_message?: false),
        user: author,
      )
    edited_post.instance_variable_set(:@acting_user, editor)
    client = ForumFortressClientDouble.new({ "decision" => "allow" })
    builder = instance_double(ForumFortress::PayloadBuilder, post_edit: {})
    protector = described_class.new(client: client, builder: builder)

    protector.validate_post_edit(edited_post)

    expect(builder).to have_received(:post_edit).with(edited_post, actor: editor)
    expect(client.checks.first.first).to eq("reply_edit")
  end

  it "skips an out-of-band post save with no trustworthy acting user" do
    post.raw = "An out-of-band body update that should not trigger a remote request."
    client = ForumFortressClientDouble.new({ "decision" => "block" })

    described_class.new(client: client).validate_post_edit(post)

    expect(client.checks).to be_empty
  end

  it "skips a post edit made by staff even when the author is not staff" do
    editor = ForumFortressUserDouble.new(staff: true)
    edited_post =
      instance_double(
        Post,
        acting_user: editor,
        persisted?: true,
        post_number: 2,
        raw_changed?: true,
        topic: instance_double(Topic, private_message?: false),
        user: ForumFortressUserDouble.new,
      )
    edited_post.instance_variable_set(:@acting_user, editor)
    client = ForumFortressClientDouble.new({ "decision" => "allow" })
    protector = described_class.new(client: client)

    protector.validate_post_edit(edited_post)

    expect(client.checks).to be_empty
  end

  it "blocks and rolls back a title-only edit through the native topic validator" do
    enable_current_plugin
    client = ForumFortressClientDouble.new({ "decision" => "block" })
    allow(ForumFortress::Api::Client).to receive(:new).and_return(client)
    original_title = post.topic.title

    result = PostRevisor.new(post).revise!(post.user, title: "A blocked title-only edit")

    expect(result).to be_falsey
    expect(post.topic.reload.title).to eq(original_title)
    expect(client.checks.map(&:first)).to include("topic_edit")
  end

  it "blocks and rolls back a reply-body edit through the native post validator" do
    reply = Fabricate(:post, topic: post.topic, user: post.user)
    enable_current_plugin
    client = ForumFortressClientDouble.new({ "decision" => "block" })
    allow(ForumFortress::Api::Client).to receive(:new).and_return(client)
    original_raw = reply.raw

    result =
      PostRevisor.new(reply).revise!(
        reply.user,
        raw: "A blocked edited reply body that is long enough for validation.",
      )

    expect(result).to be_falsey
    expect(reply.reload.raw).to eq(original_raw)
    expect(client.checks.map(&:first)).to include("reply_edit")
  end

  it "sends the final title and body for a combined first-post edit" do
    enable_current_plugin
    client = ForumFortressClientDouble.new({ "decision" => "allow" })
    allow(ForumFortress::Api::Client).to receive(:new).and_return(client)

    result =
      PostRevisor.new(post).revise!(
        post.user,
        title: "The final edited topic title",
        raw: "The final edited topic body is long enough to be accepted.",
      )

    expect(result).to be_truthy
    event, payload = client.checks.reverse.find { |check| check.first == "topic_edit" }
    expect(event).to eq("topic_edit")
    expect(client.checks.count { |check| check.first == "topic_edit" }).to eq(1)
    expect(payload.fetch("content")).to start_with("The final edited topic title\n")
    expect(payload.fetch("content")).to include("The final edited topic body")
  end
end
