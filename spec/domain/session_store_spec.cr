require "../spec_helper"

private def now
  Time.utc(2026, 1, 1)
end

describe SessionStore do
  it "opens a session findable by its code" do
    store = SessionStore.new(ttl: 3.hours)
    session = store.open(now)
    store.find(session.code).should eq(session)
  end

  it "returns nil for an unknown code" do
    SessionStore.new.find("ZZZZ").should be_nil
  end

  it "gives each session a distinct code" do
    store = SessionStore.new
    codes = Array.new(20) { store.open(now).code }
    codes.uniq.size.should eq(codes.size)
  end

  it "gives each session a distinct, non-empty facilitator token" do
    store = SessionStore.new
    first = store.open(now).facilitator_token
    second = store.open(now).facilitator_token
    first.should_not be_empty
    first.should_not eq(second)
  end

  it "defaults to a multi-hour ttl" do
    session = SessionStore.new.open(Time.utc(2026, 1, 1))
    session.expired?(Time.utc(2026, 1, 1, 2, 0)).should be_false
    session.expired?(Time.utc(2026, 1, 1, 4, 0)).should be_true
  end

  it "sweeps expired sessions and keeps live ones" do
    store = SessionStore.new(ttl: 3.hours)
    old = store.open(Time.utc(2026, 1, 1))
    fresh = store.open(Time.utc(2026, 1, 1, 2, 0))

    swept = store.sweep(Time.utc(2026, 1, 1, 3, 30))

    swept.should eq(1)
    store.find(old.code).should be_nil
    store.find(fresh.code).should eq(fresh)
  end
end
