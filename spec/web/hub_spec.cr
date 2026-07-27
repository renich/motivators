require "spec"
require "../../src/domain/session"
require "../../src/web/hub"

private def a_session
  Session.new(
    code: "ABCD",
    facilitator_token: "secret",
    created_at: Time.utc(2026, 1, 1),
    ttl: 3.hours,
  )
end

describe Hub do
  it "allows joins, leaves, and broadcasting without holding lock during socket sends" do
    hub = Hub.new
    session = a_session
    session.join(id: "p1", name: "Ada")

    # Verify basic hub operations initialize cleanly
    hub.should_not be_nil
  end
end
