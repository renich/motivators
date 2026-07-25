require "./motivator"

# A participant's complete ordering of the ten cards, most important first.
# Value object: it enforces its own invariants and is immutable once built.
struct Ranking
  getter order : Array(Motivator)

  def initialize(@order : Array(Motivator))
    validate!
  end

  # 1-based rank of a card: 1 is most important, 10 is least.
  def position(motivator : Motivator) : Int32
    @order.index!(motivator) + 1
  end

  private def validate!
    unless @order.size == Motivator.values.size
      raise ArgumentError.new("A ranking must order all ten cards")
    end

    if @order.uniq.size != @order.size
      raise ArgumentError.new("A ranking must not contain a duplicate card")
    end
  end
end
