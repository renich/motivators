require "spec"
require "json"
require "../../src/domain/**"
require "../../src/web/payload"

private def a_session
  Session.new(
    code: "ABCD",
    facilitator_token: "secret",
    created_at: Time.utc(2026, 1, 1),
    ttl: 3.hours,
  )
end

describe Payload do
  it "serialises phase and code" do
    json = JSON.parse(Payload.session(a_session.public_view(for: "nobody")))
    json["phase"].should eq("lobby")
    json["code"].should eq("ABCD")
  end

  it "renders a visible ranking as an array of card names" do
    session = a_session
    session.join(id: "me", name: "Ada")
    session.submit("me", Ranking.new(Motivator.values))

    json = JSON.parse(Payload.session(session.public_view(for: "me")))
    mine = json["participants"].as_a.first
    mine["name"].should eq("Ada")
    mine["ready"].as_bool.should be_false
    mine["ranking"].as_a.first.should eq("Curiosity")
    mine["ranking"].as_a.size.should eq(10)
  end

  it "never puts a hidden ranking on the wire" do
    session = a_session
    session.join(id: "me", name: "Ada")
    session.join(id: "her", name: "Grace")
    session.submit("her", Ranking.new(Motivator.values))

    raw = Payload.session(session.public_view(for: "me"))

    # Not just null: no card name from Grace's ranking may appear at all.
    raw.should contain(%("ranking":null))
    Motivator.values.each do |card|
      # "her" ranking is the only ranking present; if any card name leaks,
      # the payload betrayed a hidden ranking.
      raw.includes?(%("#{card}")).should be_false
    end
  end
end
