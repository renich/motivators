require "../spec_helper"

describe Motivator do
  it "defines exactly the ten Moving Motivators cards" do
    Motivator.values.size.should eq(10)
  end

  it "lists them in the canonical order" do
    Motivator.values.map(&.to_s).should eq(%w[
      Curiosity Honor Acceptance Mastery Power
      Freedom Relatedness Order Goal Status
    ])
  end
end
