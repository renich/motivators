require "../spec_helper"

# A valid ranking: every card exactly once, in some order.
def a_full_order
  Motivator.values.shuffle!
end

describe Ranking do
  it "accepts a complete order of the ten cards" do
    order = a_full_order
    Ranking.new(order).order.should eq(order)
  end

  it "rejects an incomplete order" do
    partial = Motivator.values.first(9)
    expect_raises(ArgumentError, /ten/) do
      Ranking.new(partial)
    end
  end

  it "rejects a duplicated card" do
    dupes = Motivator.values.dup
    dupes[9] = dupes[0]
    expect_raises(ArgumentError, /duplicate/i) do
      Ranking.new(dupes)
    end
  end

  it "rejects extra cards beyond the ten" do
    too_many = Motivator.values + [Motivator::Curiosity]
    expect_raises(ArgumentError, /ten/) do
      Ranking.new(too_many)
    end
  end

  it "reports the position of a card, most important first" do
    order = Motivator.values
    ranking = Ranking.new(order)
    ranking.position(Motivator::Curiosity).should eq(1)
    ranking.position(Motivator::Status).should eq(10)
  end
end
