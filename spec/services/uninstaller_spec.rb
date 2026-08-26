# frozen_string_literal: true

RSpec.describe ForumFortress::Uninstaller do
  let(:settings) do
    Class.new do
      attr_reader :removed

      def initialize
        @removed = []
      end

      def remove_override!(name)
        @removed << name
      end
    end.new
  end
  let(:client) { instance_double(ForumFortress::Api::Client) }
  let(:uninstaller) { described_class.new(settings:, client:) }

  it "deprovisions remotely before removing every local setting override" do
    allow(client).to receive(:deprovision_site).and_return("status" => "ok")

    result = uninstaller.uninstall!

    expect(result).to eq(remote_status: "ok", local_settings_cleared: 10)
    expect(settings.removed).to eq(described_class::SETTING_NAMES)
  end

  it "keeps local identity available for retry when remote removal fails" do
    allow(client).to receive(:deprovision_site).and_raise(ForumFortress::Api::RequestError)

    expect { uninstaller.uninstall! }.to raise_error(ForumFortress::Api::RequestError)
    expect(settings.removed).to be_empty
  end

  it "supports an explicit local-only cleanup during a remote outage" do
    allow(client).to receive(:deprovision_site).and_raise(ForumFortress::Api::RequestError)

    result = uninstaller.uninstall!(force_local_cleanup: true)

    expect(result).to eq(remote_status: "unconfirmed", local_settings_cleared: 10)
    expect(settings.removed).to eq(described_class::SETTING_NAMES)
  end
end
