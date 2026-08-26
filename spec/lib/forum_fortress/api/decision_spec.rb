# frozen_string_literal: true

RSpec.describe ForumFortress::Api::Decision do
  describe ".value" do
    it "accepts the established allow and block decisions" do
      expect(described_class.value("decision" => "allow")).to eq("allow")
      expect(described_class.value("decision" => "block")).to eq("block")
    end

    it "keeps review compatible with older Forum Fortress clients" do
      expect(described_class.value("decision" => "review")).to eq("review")
      expect(described_class.allowed?("decision" => "review")).to eq(true)
    end

    it "rejects missing or unknown decisions" do
      expect { described_class.value({}) }.to raise_error(
        ForumFortress::Api::Decision::InvalidResponse,
      )
      expect { described_class.value("decision" => "challenge") }.to raise_error(
        ForumFortress::Api::Decision::InvalidResponse,
      )
    end
  end

  it "identifies a block without treating it as a transport failure" do
    expect(described_class.blocked?("decision" => "block")).to eq(true)
    expect(described_class.allowed?("decision" => "allow")).to eq(true)
  end
end
