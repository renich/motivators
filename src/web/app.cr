require "kemal"
require "../domain/session_store"
require "./hub"
require "./payload"

# The Kemal adapter. Every route is thin glue: parse the request, call the
# pure domain, broadcast the result. No business rule lives here — the phase
# guards and confidentiality all sit in src/domain.
STORE = SessionStore.new
HUB   = Hub.new

# Periodic sweep of expired sessions. Single process, in-memory state: this
# is the design that a multi-replica deploy would break (see TUTORIAL.md).
spawn do
  loop do
    sleep 10.minutes
    STORE.sweep
  end
end

# A facilitator opens a session and receives the short join code plus their
# private facilitator token — the two secrets are deliberately separate.
post "/sessions" do |env|
  session = STORE.open
  env.response.content_type = "application/json"
  {code: session.code, facilitator_token: session.facilitator_token}.to_json
end

# A participant joins by code and gets back their own secret id.
post "/sessions/:code/join" do |env|
  session = STORE.find(env.params.url["code"])
  name = env.params.json["name"]?.as?(String)

  if session.nil?
    halt env, status_code: 404, response: %({"error":"unknown session"})
  elsif name.nil? || name.blank?
    halt env, status_code: 422, response: %({"error":"name required"})
  else
    id = Random::Secure.hex(8)
    session.join(id, name)
    HUB.broadcast(session)
    env.response.content_type = "application/json"
    {participant_id: id}.to_json
  end
end

# The live channel. All state changes after joining travel over here.
ws "/sessions/:code/ws" do |socket, env|
  code = env.params.url["code"]
  id = env.params.query["as"]?
  session = STORE.find(code)

  if session.nil? || id.nil?
    socket.close(HTTP::WebSocket::CloseCode::NormalClosure, "unknown session")
  else
    HUB.join(code, id, socket)
    HUB.broadcast(session)

    socket.on_message { |raw| handle(session, id, socket, raw) }
    socket.on_close do
      HUB.leave(code, socket)
      HUB.broadcast(session)
    end
  end
end

# Dispatch one client message to the domain, then broadcast. Any domain
# refusal (wrong phase, bad token, invalid ranking) is sent back to that one
# socket, never broadcast.
private def handle(session : Session, id : String, socket : HTTP::WebSocket, raw : String) : Nil
  message = JSON.parse(raw)
  case message["type"]?.try(&.as_s)
  when "submit"
    order = message["order"].as_a.map { |name| Motivator.parse(name.as_s) }
    session.submit(id, Ranking.new(order))
  when "ready"
    session.mark_ready(id)
  when "reveal"
    session.reveal(message["token"].as_s)
  else
    return socket.send(%({"error":"unknown message type"}))
  end
  HUB.broadcast(session)
rescue ex : ArgumentError | Session::WrongPhase | Session::Forbidden | Participant::NotRankedYet | JSON::ParseException | KeyError
  socket.send({error: ex.message}.to_json)
end
