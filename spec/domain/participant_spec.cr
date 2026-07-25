require "../spec_helper"

describe Participant do
  it "starts with no ranking and not ready" do
    p = Participant.new(id: "tok", name: "Ada")
    p.ranking.should be_nil
    p.ready?.should be_false
  end

  it "holds a submitted ranking" do
    p = Participant.new(id: "tok", name: "Ada")
    ranking = Ranking.new(Motivator.values)
    p.submit(ranking)
    p.ranking.should eq(ranking)
  end

  it "cannot be ready without a ranking" do
    p = Participant.new(id: "tok", name: "Ada")
    expect_raises(Participant::NotRankedYet, /ranking/) do
      p.mark_ready
    end
  end

  it "becomes ready once a ranking is submitted" do
    p = Participant.new(id: "tok", name: "Ada")
    p.submit(Ranking.new(Motivator.values))
    p.mark_ready
    p.ready?.should be_true
  end

  it "drops back to not ready when the ranking is replaced" do
    p = Participant.new(id: "tok", name: "Ada")
    p.submit(Ranking.new(Motivator.values))
    p.mark_ready
    p.submit(Ranking.new(Motivator.values.shuffle!))
    p.ready?.should be_false
  end
end
