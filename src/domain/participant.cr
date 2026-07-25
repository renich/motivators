require "./ranking"

# One person in a session. Identified by a secret token, never by account.
# Holds their private ranking until the facilitator reveals.
class Participant
  # Raised when a participant tries to mark ready before ranking the cards.
  class NotRankedYet < Exception
  end

  getter id : String
  getter name : String
  getter ranking : Ranking?

  def initialize(@id : String, @name : String)
    @ranking = nil
    @ready = false
  end

  def ready? : Bool
    @ready
  end

  # Submitting (or replacing) a ranking always clears the ready flag:
  # a changed mind must be re-confirmed.
  def submit(ranking : Ranking) : Nil
    @ranking = ranking
    @ready = false
  end

  def mark_ready : Nil
    raise NotRankedYet.new("Cannot be ready before submitting a ranking") if @ranking.nil?
    @ready = true
  end
end
