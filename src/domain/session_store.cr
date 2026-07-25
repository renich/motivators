require "./session"

# In-memory registry of live sessions. Single process, no persistence:
# this is the constraint that a multi-replica deploy would break.
class SessionStore
  # Unambiguous alphabet: no 0/O, no 1/I, so a code read aloud is unmistakable.
  CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  CODE_LENGTH   = 4

  def initialize(@ttl : Time::Span = 3.hours)
    @sessions = {} of String => Session
  end

  def open(now : Time = Time.utc) : Session
    session = Session.new(
      code: fresh_code,
      facilitator_token: Random::Secure.hex(16),
      created_at: now,
      ttl: @ttl,
    )
    @sessions[session.code] = session
  end

  def find(code : String) : Session?
    @sessions[code]?
  end

  # Removes every expired session and returns how many were dropped.
  def sweep(now : Time = Time.utc) : Int32
    expired = @sessions.select { |_, session| session.expired?(now) }
    expired.each_key { |code| @sessions.delete(code) }
    expired.size
  end

  private def fresh_code : String
    loop do
      code = String.build do |io|
        CODE_LENGTH.times { io << CODE_ALPHABET[Random.rand(CODE_ALPHABET.size)] }
      end
      return code unless @sessions.has_key?(code)
    end
  end
end
