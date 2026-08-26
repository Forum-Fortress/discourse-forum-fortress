# frozen_string_literal: true

RSpec.describe ForumFortress::Api::Transport do
  subject(:transport) { described_class.new }

  it "posts JSON over HTTPS and decodes an object response" do
    request =
      stub_request(:post, "https://api.example/v1/check/reply").with(
        headers: {
          "Accept" => "application/json",
          "Content-Type" => "application/json",
          "User-Agent" => "ForumFortress-Discourse/0.1.0-alpha.1",
        },
        body: '{"content":"hello"}',
      ).to_return(status: 200, body: '{"decision":"allow"}')

    response =
      transport.post_json(
        "https://api.example",
        "/v1/check/reply",
        { "content" => "hello" },
        timeout: 1,
      )

    expect(response).to eq("decision" => "allow")
    expect(request).to have_been_requested.once
  end

  it "rejects non-HTTPS endpoints" do
    expect { transport.get_json("http://api.example", "/health", timeout: 1) }.to raise_error(
      ForumFortress::Api::RequestError,
    ) { |error| expect(error.code).to eq("invalid_endpoint") }
  end

  it "reduces remote errors to a safe code" do
    stub_request(:get, "https://api.example/health").to_return(
      status: 401,
      body: '{"detail":{"error":"invalid_api_key"}}',
    )

    expect { transport.get_json("https://api.example", "/health", timeout: 1) }.to raise_error(
      ForumFortress::Api::RequestError,
    ) { |error|
      expect(error.status).to eq(401)
      expect(error.code).to eq("invalid_api_key")
    }
  end

  it "maps a whole-request timeout to the established safe code" do
    stub_request(:get, "https://api.example/health").to_timeout

    expect { transport.get_json("https://api.example", "/health", timeout: 0.1) }.to raise_error(
      ForumFortress::Api::RequestError,
    ) { |error| expect(error.code).to eq("timeout") }
  end

  it "rejects malformed and oversized responses" do
    stub_request(:get, "https://api.example/malformed").to_return(status: 200, body: "not-json")
    stub_request(:get, "https://api.example/oversized").to_return(
      status: 200,
      body: "x" * (described_class::MAX_RESPONSE_BYTES + 1),
    )

    expect { transport.get_json("https://api.example", "/malformed", timeout: 1) }.to raise_error(
      ForumFortress::Api::RequestError,
    ) { |error| expect(error.code).to eq("invalid_response") }
    expect { transport.get_json("https://api.example", "/oversized", timeout: 1) }.to raise_error(
      ForumFortress::Api::RequestError,
    ) { |error| expect(error.code).to eq("response_too_large") }
  end
end
