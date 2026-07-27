require "../spec_helper"

describe SessionStore do
  it "opens new sessions with unique codes" do
    store = SessionStore.new
    session1 = store.open
    session2 = store.open

    session1.code.should_not eq(session2.code)
    store.find(session1.code).should eq(session1)
    store.find(session2.code).should eq(session2)
  end

  it "sweeps expired sessions safely" do
    store = SessionStore.new(ttl: 0.seconds)
    session = store.open
    store.sweep.should eq(1)
    store.find(session.code).should be_nil
  end

  it "handles concurrent fiber access safely" do
    store = SessionStore.new(ttl: 1.hour)
    channel = Channel(Nil).new

    10.times do
      spawn do
        s = store.open
        store.find(s.code)
        store.sweep
        channel.send(nil)
      end
    end

    10.times { channel.receive }
    store.should_not be_nil
  end
end
