require "./participant"

# What a participant is allowed to see of a session at a given moment.
# Built by Session#public_view so confidentiality is enforced at the source:
# before reveal, another participant's ranking is simply not put in the payload.
struct ParticipantView
  getter name : String
  getter? ready : Bool
  getter ranking : Ranking?

  def initialize(@name : String, @ready : Bool, @ranking : Ranking?)
  end
end

struct SessionView
  getter phase : Session::Phase
  getter code : String
  getter participants : Array(ParticipantView)

  def initialize(@phase, @code, @participants)
  end
end

# An ephemeral ranking session. Owns the two-phase state machine and guards
# every mutation. Pure Crystal: no HTTP, no clock of its own — the caller
# passes the current time.
class Session
  enum Phase
    Lobby
    Revealed
  end

  # Reveal attempted without the facilitator token.
  class Forbidden < Exception
  end

  # An action asked for in the wrong phase (reveal twice, submit after reveal).
  class WrongPhase < Exception
  end

  getter code : String
  getter facilitator_token : String
  getter phase : Phase

  def initialize(
    @code : String,
    @facilitator_token : String,
    created_at : Time,
    ttl : Time::Span,
  )
    @expires_at = created_at + ttl
    @phase = Phase::Lobby
    @participants = {} of String => Participant
  end

  def revealed? : Bool
    @phase.revealed?
  end

  def expired?(now : Time) : Bool
    now >= @expires_at
  end

  def participant(id : String) : Participant?
    @participants[id]?
  end

  # A newcomer after reveal is admitted, but the phase guards keep them from
  # submitting — they observe only.
  def join(id : String, name : String) : Participant
    @participants[id] ||= Participant.new(id, name)
  end

  def submit(id : String, ranking : Ranking) : Nil
    guard_lobby!
    with_participant(id, &.submit(ranking))
  end

  def mark_ready(id : String) : Nil
    guard_lobby!
    with_participant(id, &.mark_ready)
  end

  def reveal(token : String) : Nil
    raise Forbidden.new("Only the facilitator can reveal") unless token == @facilitator_token
    guard_lobby!
    @phase = Phase::Revealed
  end

  # Confidentiality lives here: a ranking is placed in the view only when the
  # session is revealed or when it belongs to the viewer themselves.
  def public_view(for viewer_id : String) : SessionView
    views = @participants.values.map do |participant|
      visible = revealed? || participant.id == viewer_id
      ranking = visible ? participant.ranking : nil
      ParticipantView.new(participant.name, participant.ready?, ranking)
    end
    SessionView.new(@phase, @code, views)
  end

  private def guard_lobby! : Nil
    raise WrongPhase.new("Session is already revealed") if revealed?
  end

  private def with_participant(id : String, & : Participant ->) : Nil
    p = @participants[id]?
    raise KeyError.new("Unknown participant #{id}") if p.nil?
    yield p
  end
end
