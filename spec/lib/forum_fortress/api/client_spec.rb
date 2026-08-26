# frozen_string_literal: true

ForumFortressClientSettingsDouble =
  Struct.new(
    :forum_fortress_enabled,
    :forum_fortress_fail_open,
    :forum_fortress_api_key,
    :forum_fortress_site_id,
    :forum_fortress_bootstrap_token,
    :forum_fortress_api_region,
    :forum_fortress_allow_global_fallback,
    :forum_fortress_timeout,
    :forum_fortress_preferred_endpoint,
    :forum_fortress_endpoint_state,
  ) do
    attr_reader :writes

    def set(name, value)
      (@writes ||= []) << [name, value]
      public_send("#{name}=", value)
    end
  end

class ForumFortressTransportDouble
  attr_reader :requests
  attr_accessor :post_response, :get_response, :post_error, :get_error

  def initialize
    @requests = []
  end

  def post_json(base, path, payload, **options)
    @requests << { method: :post, base:, path:, payload:, options: }
    raise post_error if post_error
    post_response || { "decision" => "allow" }
  end

  def get_json(base, path, **options)
    @requests << { method: :get, base:, path:, options: }
    raise get_error if get_error
    get_response || { "status" => "ok" }
  end
end

RSpec.describe ForumFortress::Api::Client do
  let(:settings) do
    ForumFortressClientSettingsDouble.new(
      true,
      true,
      "ff_test_key",
      "site-1",
      "",
      "eu",
      false,
      5,
      "",
      "{}",
    )
  end
  let(:transport) { ForumFortressTransportDouble.new }
  let(:logger) { instance_double(Logger, warn: nil) }
  let(:client) { described_class.new(settings:, transport:, logger:, domain: "community.example") }

  it "sends the established common payload to the selected check endpoint" do
    response = client.check("topic", "content" => "hello", "links" => [])

    expect(response["decision"]).to eq("allow")
    request = transport.requests.first
    expect(request[:base]).to eq("https://api-eu.ffapi.net")
    expect(request[:path]).to eq("/v1/check/topic")
    expect(request[:payload]).to include(
      "api_key" => "ff_test_key",
      "site_id" => "site-1",
      "domain" => "community.example",
      "platform" => "discourse",
      "plugin_version" => "0.1.0-alpha.1",
      "content" => "hello",
    )
  end

  it "persists a bootstrap identity without exposing it in the result state" do
    settings.forum_fortress_api_key = ""
    settings.forum_fortress_site_id = ""
    transport.post_response = {
      "api_key" => "ff_bootstrapped_key",
      "site_id" => "site-2",
      "decision" => "allow",
    }

    client.check("register", "username" => "new-user")

    expect(settings.forum_fortress_api_key).to eq("ff_bootstrapped_key")
    expect(settings.forum_fortress_site_id).to eq("site-2")
    expect(settings.forum_fortress_endpoint_state).not_to include("ff_bootstrapped_key")
  end

  it "allows a first bootstrap response a separate bounded provisioning budget" do
    settings.forum_fortress_api_key = ""
    settings.forum_fortress_site_id = ""
    transport.post_response = { "api_key" => "ff_bootstrapped_key", "site_id" => "site-2" }

    client.bootstrap_if_needed

    expect(transport.requests.first.dig(:options, :timeout)).to be > 29
  end

  it "uses and clears a short-lived bootstrap token for an existing site" do
    settings.forum_fortress_api_key = ""
    settings.forum_fortress_site_id = ""
    settings.forum_fortress_bootstrap_token = "ff_bs1_#{"a" * 48}"
    transport.post_response = { "api_key" => "ff_recovered_key", "site_id" => "site-recovered" }

    client.bootstrap_if_needed(force: true)

    request = transport.requests.first
    expect(request[:path]).to eq("/v1/site/bootstrap")
    expect(request[:payload]["bootstrap_token"]).to eq("ff_bs1_#{"a" * 48}")
    expect(settings.forum_fortress_api_key).to eq("ff_recovered_key")
    expect(settings.forum_fortress_bootstrap_token).to eq("")
  end

  it "fails open on transport errors by default" do
    transport.post_error = ForumFortress::Api::RequestError.new("hidden", code: "timeout")

    expect(client.check("reply", "content" => "hello")).to be_nil
    expect(settings.forum_fortress_endpoint_state).to include("timeout")
    expect(logger).to have_received(:warn).with("Forum Fortress check/reply failed (timeout)")
  end

  it "raises a safe unavailable error when fail-open is disabled" do
    settings.forum_fortress_fail_open = false
    transport.post_error =
      ForumFortress::Api::RequestError.new("raw payload must not escape", code: "timeout")

    error = nil
    expect { client.check("reply", "content" => "hello") }.to raise_error(
      ForumFortress::Api::Unavailable,
    ) { |raised| error = raised }
    expect(error.message).not_to include("raw payload")
  end

  it "treats an invalid decision as a service failure" do
    transport.post_response = { "decision" => "challenge" }

    expect(client.check("reply", "content" => "hello")).to be_nil
    expect(settings.forum_fortress_endpoint_state).to include("invalid_decision_response")
  end

  it "tests both the regional health endpoint and control-plane site status" do
    transport.get_response = { "site_id" => "site-1", "status" => "ok" }

    result = client.connection_test

    expect(result).to include(ok: true, health: true, site_status: true)
    status_request = transport.requests.find { |request| request[:path] == "/v1/site/status" }
    expect(status_request[:options][:headers]).to eq("X-FF-Key" => "ff_test_key")
  end

  it "requests a short-lived portal launch from the control plane" do
    transport.post_response = { "portal_url" => "https://portal.forumfortress.com/launch/test" }

    result = client.portal_launch

    expect(result["portal_url"]).to eq("https://portal.forumfortress.com/launch/test")
    request = transport.requests.first
    expect(request[:base]).to eq("https://fortress.ffapi.net")
    expect(request[:path]).to eq("/v1/site/portal")
    expect(request[:payload]).to include(
      "api_key" => "ff_test_key",
      "site_id" => "site-1",
      "domain" => "community.example",
    )
  end

  it "deprovisions the current site through the established control-plane contract" do
    transport.post_response = { "status" => "ok" }

    expect(client.deprovision_site).to eq("status" => "ok")

    request = transport.requests.first
    expect(request[:base]).to eq("https://fortress.ffapi.net")
    expect(request[:path]).to eq("/v1/site/deprovision")
    expect(request[:payload]).to include(
      "api_key" => "ff_test_key",
      "site_id" => "site-1",
      "domain" => "community.example",
      "reason" => "plugin_uninstall",
    )
  end

  it "treats an already deleted remote site as a completed deprovision" do
    transport.post_error =
      ForumFortress::Api::RequestError.new("gone", status: 410, code: "site_not_found")

    expect(client.deprovision_site).to eq("status" => "already_removed")
  end

  it "does not contact Forum Fortress when there is no complete local identity" do
    settings.forum_fortress_site_id = ""

    expect(client.deprovision_site).to eq("status" => "no_identity")
    expect(transport.requests).to be_empty
  end

  it "uses the global fallback only when it is enabled" do
    settings.forum_fortress_allow_global_fallback = true
    transport.post_error = ForumFortress::Api::RequestError.new("down", code: "timeout")
    response = nil

    transport.define_singleton_method(:post_json) do |base, path, payload, **options|
      @requests << { method: :post, base:, path:, payload:, options: }
      if base == "https://api-eu.ffapi.net"
        raise ForumFortress::Api::RequestError.new("down", code: "timeout")
      end
      response = { "decision" => "allow" }
    end

    response = client.check("reply", "content" => "hello")

    expect(response["decision"]).to eq("allow")
    expect(transport.requests.map { |request| request[:base] }).to include("https://api.ffapi.net")
  end

  it "does not reuse a preferred endpoint from another selected region" do
    settings.forum_fortress_api_region = "us"
    settings.forum_fortress_preferred_endpoint = "https://api-eu.ffapi.net"

    client.check("reply", "content" => "hello")

    expect(transport.requests.first[:base]).to eq("https://api-us.ffapi.net")
  end

  it "makes an endpoint attempt with the minimum one-second timeout" do
    settings.forum_fortress_timeout = 1

    response = client.check("reply", "content" => "hello")

    expect(response["decision"]).to eq("allow")
    expect(transport.requests.length).to eq(1)
  end

  it "reuses one check request id across endpoint failover" do
    settings.forum_fortress_allow_global_fallback = true
    payloads = []
    transport.define_singleton_method(:post_json) do |base, _path, payload, **_options|
      payloads << payload
      if base == "https://api-eu.ffapi.net"
        raise ForumFortress::Api::RequestError.new("down", code: "timeout")
      end

      { "decision" => "allow" }
    end

    client.check("reply", "content" => "hello")

    expect(payloads.length).to eq(2)
    expect(payloads.map { |payload| payload["check_request_id"] }.uniq.length).to eq(1)
    expect(payloads.first["check_request_id"]).to match(/\A[0-9a-f]{32}\z/)
  end

  it "drops an invalid key before attempting identity recovery" do
    requests = []
    transport.define_singleton_method(:post_json) do |base, path, payload, **options|
      requests << { base:, path:, payload:, options: }
      case requests.length
      when 1
        raise ForumFortress::Api::RequestError.new("invalid", status: 401, code: "invalid_api_key")
      when 2
        { "api_key" => "ff_recovered", "site_id" => "site-recovered" }
      else
        { "decision" => "allow" }
      end
    end

    expect(client.check("reply", "content" => "hello")["decision"]).to eq("allow")

    bootstrap_request = requests.second
    expect(bootstrap_request[:path]).to eq("/v1/site/bootstrap")
    expect(bootstrap_request[:payload]).not_to include("api_key")
    expect(settings.forum_fortress_api_key).to eq("ff_recovered")
  end

  it "keeps a valid key while repairing only a stale site identifier" do
    requests = []
    transport.define_singleton_method(:post_json) do |base, path, payload, **options|
      requests << { base:, path:, payload:, options: }
      case requests.length
      when 1
        raise ForumFortress::Api::RequestError.new("stale", status: 409, code: "stale_site")
      when 2
        { "site_id" => "site-repaired", "api_key" => "ff_test_key" }
      else
        { "decision" => "allow" }
      end
    end

    expect(client.check("reply", "content" => "hello")["decision"]).to eq("allow")

    bootstrap_request = requests.second
    expect(bootstrap_request[:payload]).to include("api_key" => "ff_test_key")
    expect(bootstrap_request[:payload]).not_to include("site_id")
    expect(settings.forum_fortress_site_id).to eq("site-repaired")
  end

  it "replaces a blank check request id" do
    client.check("reply", "content" => "hello", "check_request_id" => "  ")

    request_id = transport.requests.first[:payload]["check_request_id"]
    expect(request_id).to match(/\A[0-9a-f]{32}\z/)
  end

  it "applies fail-open behavior when a caller supplies an invalid payload" do
    expect(client.check("reply", nil)).to be_nil
    expect(logger).to have_received(:warn).with(
      "Forum Fortress check/reply failed (connection_failed)",
    )
  end

  it "uses a valid preferred endpoint first in global mode" do
    settings.forum_fortress_api_region = "global"
    settings.forum_fortress_preferred_endpoint = "https://api-uk.ffapi.net"

    client.check("reply", "content" => "hello")

    expect(transport.requests.first[:base]).to eq("https://api-uk.ffapi.net")
  end

  it "does not write unchanged identity or endpoint state" do
    settings.forum_fortress_api_region = "global"
    settings.forum_fortress_preferred_endpoint = "https://api.ffapi.net"

    client.check("reply", "content" => "hello")

    expect(settings.writes).to be_nil
  end

  it "rejects a malformed successful site status response" do
    transport.get_response = { "status" => "ok" }

    result = client.connection_test

    expect(result).to include(ok: false, site_status: false, error_code: "invalid_site_status")
  end
end
