require "http/web_socket"
require "../domain/session"
require "./payload"

# Keeps the live WebSocket connections for each session and pushes updates.
# The point of confidentiality: every socket is sent its OWN public_view, so
# one broadcast produces a different payload per viewer — a participant only
# ever receives rankings they are allowed to see.
class Hub
  private record Conn, id : String, socket : HTTP::WebSocket

  def initialize
    @connections = Hash(String, Array(Conn)).new { |hash, code| hash[code] = [] of Conn }
    @mutex = Mutex.new
  end

  def join(code : String, id : String, socket : HTTP::WebSocket) : Nil
    @mutex.synchronize { @connections[code] << Conn.new(id, socket) }
  end

  def leave(code : String, socket : HTTP::WebSocket) : Nil
    @mutex.synchronize do
      @connections[code].reject! { |conn| conn.socket == socket }
    end
  end

  # Send each connected participant the session as they are allowed to see it.
  def broadcast(session : Session) : Nil
    targets = @mutex.synchronize { @connections[session.code].dup }
    targets.each do |conn|
      conn.socket.send(Payload.session(session.public_view(for: conn.id)))
    rescue ex : IO::Error
      # Ignore broken socket IO error during broadcast so remaining clients receive updates
    end
  end
end
