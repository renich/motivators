require "spec"
require "http/client"
require "http/web_socket"
require "../../src/web/app"

PORT = 4567

# Boot the Kemal app once for the whole file, on a fixed test port.
Spec.before_suite do
  Kemal.config.logging = false
  spawn { Kemal.run(PORT) }

  50.times do
    HTTP::Client.get("http://127.0.0.1:#{PORT}/")
    break
  rescue
    sleep 20.milliseconds
  end
end

private def base
  "http://127.0.0.1:#{PORT}"
end

private def open_session : {String, String}
  body = JSON.parse(HTTP::Client.post("#{base}/sessions").body)
  {body["code"].as_s, body["facilitator_token"].as_s}
end

private def join(code : String, name : String) : String
  response = HTTP::Client.post(
    "#{base}/sessions/#{code}/join",
    headers: HTTP::Headers{"Content-Type" => "application/json"},
    body: {name: name}.to_json,
  )
  JSON.parse(response.body)["participant_id"].as_s
end

# A WebSocket client that queues incoming frames so a test can await them.
private class Client
  getter socket : HTTP::WebSocket

  def initialize(code : String, id : String)
    @frames = Channel(String).new(32)
    @socket = HTTP::WebSocket.new("127.0.0.1", "/sessions/#{code}/ws?as=#{id}", PORT)
    @socket.on_message { |frame| @frames.send(frame) }
    spawn { @socket.run }
  end

  def send(payload) : Nil
    @socket.send(payload.to_json)
  end

  # Await the next frame satisfying the block, skipping earlier snapshots.
  def wait_for(&block : JSON::Any -> Bool) : JSON::Any
    10.times do
      frame = receive
      json = JSON.parse(frame)
      return json if block.call(json)
    end
    raise "no matching frame arrived"
  end

  private def receive : String
    select
    when frame = @frames.receive
      frame
    when timeout(2.seconds)
      raise "timed out waiting for a WebSocket frame"
    end
  end
end

private def full_order
  Motivator.values.map(&.to_s)
end

private def participant(json : JSON::Any, name : String) : JSON::Any
  json["participants"].as_a.find! { |entry| entry["name"] == name }
end

describe "Moving Motivators over HTTP + WebSocket" do
  it "opens a session and lets a participant join" do
    code, _token = open_session
    id = join(code, "Ada")
    id.should_not be_empty
  end

  it "keeps a ranking hidden on the wire until reveal, then shows it" do
    code, token = open_session
    me = join(code, "Ada")
    her = join(code, "Grace")

    ada = Client.new(code, me)
    grace = Client.new(code, her)

    grace.send({type: "submit", order: full_order})

    # Ada is told Grace is present, but Grace's ranking is not on the wire.
    hidden = ada.wait_for { |json| participant(json, "Grace")["ready"] == false }
    participant(hidden, "Grace")["ranking"].raw.should be_nil

    # Facilitator reveals; now Ada receives Grace's ranking.
    grace.send({type: "reveal", token: token})
    shown = ada.wait_for { |json| json["phase"] == "revealed" }
    participant(shown, "Grace")["ranking"].as_a.size.should eq(10)
  end

  it "never puts a participant's secret token on the wire" do
    code, _token = open_session
    me = join(code, "Ada")
    her = join(code, "Grace")

    ada = Client.new(code, me)
    frame = ada.wait_for { |json| json["participants"].as_a.size == 2 }

    # The ids are the private WebSocket credentials — leaking them would let
    # anyone reconnect as another participant and read their ranking.
    frame.to_json.should_not contain(me)
    frame.to_json.should_not contain(her)

    participant(frame, "Ada")["you"].as_bool.should be_true
    participant(frame, "Grace")["you"].as_bool.should be_false
  end

  it "rejects a reveal with the wrong token" do
    code, _token = open_session
    me = join(code, "Ada")
    ada = Client.new(code, me)

    ada.send({type: "reveal", token: "not-the-token"})
    error = ada.wait_for { |json| !json["error"]?.nil? }
    error["error"].as_s.should contain("facilitator")
  end

  it "answers 400, not a 500 page, on a malformed JSON body" do
    code, _token = open_session
    response = HTTP::Client.post(
      "#{base}/sessions/#{code}/join",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: "not json at all",
    )
    response.status_code.should eq(400)
  end

  it "rejects a name longer than the limit" do
    code, _token = open_session
    response = HTTP::Client.post(
      "#{base}/sessions/#{code}/join",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: {name: "x" * 51}.to_json,
    )
    response.status_code.should eq(422)
  end
end
