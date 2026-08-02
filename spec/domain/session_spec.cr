require "../spec_helper"

private def a_ranking
  Ranking.new(Motivator.values.shuffle!)
end

private def a_session
  Session.new(
    code: "ABCD",
    facilitator_token: "secret",
    created_at: Time.utc(2026, 1, 1),
    ttl: 3.hours,
  )
end

describe Session do
  describe "initial state" do
    it "starts in the lobby, not revealed" do
      a_session.phase.should eq(Session::Phase::Lobby)
      a_session.revealed?.should be_false
    end
  end

  describe "joining" do
    it "adds a participant and returns it" do
      session = a_session
      p = session.join(id: "p1", name: "Ada")
      p.name.should eq("Ada")
      session.participant("p1").should eq(p)
    end
  end

  describe "reveal transition" do
    it "moves to revealed for the facilitator" do
      session = a_session
      session.reveal("secret")
      session.revealed?.should be_true
    end

    it "refuses reveal with the wrong token" do
      session = a_session
      expect_raises(Session::Forbidden) { session.reveal("wrong") }
      session.revealed?.should be_false
    end

    it "is irreversible: revealing twice is refused" do
      session = a_session
      session.reveal("secret")
      expect_raises(Session::WrongPhase) { session.reveal("secret") }
    end
  end

  describe "mutations after reveal" do
    it "refuses new rankings once revealed" do
      session = a_session
      session.join(id: "p1", name: "Ada")
      session.reveal("secret")
      expect_raises(Session::WrongPhase) { session.submit("p1", a_ranking) }
    end
  end

  describe "expiry" do
    it "is expired past its ttl" do
      session = a_session
      session.expired?(Time.utc(2026, 1, 1, 2, 59)).should be_false
      session.expired?(Time.utc(2026, 1, 1, 3, 1)).should be_true
    end
  end

  describe "#public_view — the confidentiality invariant" do
    it "hides other participants' rankings before reveal" do
      session = a_session
      session.join(id: "me", name: "Ada")
      session.join(id: "her", name: "Grace")
      session.submit("me", a_ranking)
      session.submit("her", a_ranking)

      view = session.public_view(for: "me")
      mine = view.participants.find!(&.you?)
      hers = view.participants.find! { |entry| !entry.you? }

      mine.ranking.should_not be_nil
      hers.ranking.should be_nil
    end

    it "marks only the viewer's own entry with the you flag" do
      session = a_session
      session.join(id: "me", name: "Ada")
      session.join(id: "her", name: "Grace")

      view = session.public_view(for: "me")

      view.participants.count(&.you?).should eq(1)
      view.participants.find! { |entry| entry.name == "Ada" }.you?.should be_true
      view.participants.find! { |entry| entry.name == "Grace" }.you?.should be_false
    end

    it "reveals every ranking after reveal" do
      session = a_session
      session.join(id: "me", name: "Ada")
      session.join(id: "her", name: "Grace")
      session.submit("me", a_ranking)
      session.submit("her", a_ranking)
      session.reveal("secret")

      view = session.public_view(for: "me")
      view.participants.all? { |entry| !entry.ranking.nil? }.should be_true
    end
  end
end
