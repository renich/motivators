require "spec"
require "http/web_socket"
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
  it "sends every connected socket a payload" do
    hub = Hub.new
    session = a_session
    session.join(id: "ada", name: "Ada")
    session.join(id: "bob", name: "Bob")

    ada_io = IO::Memory.new
    bob_io = IO::Memory.new
    hub.join(session.code, "ada", HTTP::WebSocket.new(ada_io))
    hub.join(session.code, "bob", HTTP::WebSocket.new(bob_io))

    hub.broadcast(session)

    ada_io.size.should be > 0
    bob_io.size.should be > 0
  end

  it "keeps broadcasting to healthy sockets when an earlier one is broken" do
    hub = Hub.new
    session = a_session
    session.join(id: "broken", name: "Bob")
    session.join(id: "healthy", name: "Ada")

    # A socket over a closed buffer: every send raises IO::Error.
    broken_io = IO::Memory.new
    broken = HTTP::WebSocket.new(broken_io)
    broken_io.close

    healthy_io = IO::Memory.new
    healthy = HTTP::WebSocket.new(healthy_io)

    # The broken socket is joined first, so without the per-socket rescue the
    # broadcast loop would raise before it ever reaches the healthy one.
    hub.join(session.code, "broken", broken)
    hub.join(session.code, "healthy", healthy)

    hub.broadcast(session)

    healthy_io.size.should be > 0
  end
end
