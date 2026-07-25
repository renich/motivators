# Building Moving Motivators with Crystal and Kemal

A build-along tutorial. We write a small, real-time, self-hosted app for
running a *Moving Motivators* session with a group — and we let the problem
size dictate every technical choice, rather than reaching for the biggest tool
we know.

The finished app is ~290 lines of Crystal plus a single-file frontend. It has
no database, no ORM, no build pipeline, and ships as a ~14 MB container. The
whole point is to show that this is *enough* for the problem, and that keeping
it this small is a feature, not a limitation.

Each chapter mirrors one step of the build. The commits follow the same order,
so you can read the history alongside the prose.

---

## What we're building

A facilitator opens a session and gets a short join code. Participants join
with that code and privately rank ten motivator cards — Curiosity, Honor,
Acceptance, Mastery, Power, Freedom, Relatedness, Order, Goal, Status — from
most to least important to them. When everyone is ready, the facilitator
triggers a **reveal** and all rankings appear side by side for discussion.

Two properties drive the whole design:

- **Ephemeral.** State lives in memory and nowhere else. Sessions expire after
  a few hours and are swept. There is nothing to back up and nothing to leak
  from disk.
- **Private until reveal.** A participant's ranking must stay hidden from the
  others until the facilitator reveals. Not "the UI hides it" — the server must
  never put another participant's ranking in a payload before that moment.

That second property is the interesting one, and we make it an invariant of the
domain rather than a rule scattered across the UI.

---

## Chapter 1 — Why Kemal

Kemal is a Sinatra-style micro-framework: routes, a request/response cycle,
WebSockets, static files. That is the entire feature list, and it is exactly
the feature list this app needs.

We deliberately do **not** use a full-stack framework here. There is no
database, so an ORM would be dead weight. There is no asset build, so a pipeline
would be ceremony. Everything the app remembers, it remembers in a process's
memory for a few hours. Kemal is the framework whose size matches the problem.

The rule we hold throughout: **the framework is an adapter.** All the actual
rules of the game live in plain Crystal objects that never import Kemal. Kemal
only translates HTTP and WebSocket traffic into calls on those objects. This is
what lets us test the whole domain without booting a server.

---

## Chapter 2 — The domain first

We start with the smallest, most certain piece: the ten cards.

```crystal
# src/domain/motivator.cr
enum Motivator
  Curiosity
  Honor
  Acceptance
  Mastery
  Power
  Freedom
  Relatedness
  Order
  Goal
  Status
end
```

A test pins down what "the ten cards" means, so a later accidental edit can't
silently change the game:

```crystal
# spec/domain/motivator_spec.cr
it "lists them in the canonical order" do
  Motivator.values.map(&.to_s).should eq(%w[
    Curiosity Honor Acceptance Mastery Power
    Freedom Relatedness Order Goal Status
  ])
end
```

Next, a **ranking**. A ranking is not just "a list of cards" — it is a complete
ordering of all ten, with no duplicates and no gaps. We make that a value
object that enforces its own invariants at construction, so an invalid ranking
simply cannot exist:

```crystal
# src/domain/ranking.cr
struct Ranking
  getter order : Array(Motivator)

  def initialize(@order : Array(Motivator))
    validate!
  end

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
```

Because construction validates, every other method can trust the invariant.
`position` uses `index!` (the raising variant) without a nil check, and that's
safe *by design* — the card is guaranteed present.

This is the TDD rhythm for the whole domain: write the spec that states the
rule, watch it fail, write the smallest code that satisfies it, refactor. The
domain never imports a framework, so the specs run in under a millisecond.

---

## Chapter 3 — Participant and the phase state machine

A **participant** is one person. They are identified by a secret token, never
by an account — this is an anonymous, ephemeral tool. They hold a ranking
(once they've submitted one) and a ready flag.

One rule matters here: you cannot be *ready* without having submitted a
ranking, and changing your mind (re-submitting) drops you back to not-ready.

```crystal
# src/domain/participant.cr
def submit(ranking : Ranking) : Nil
  @ranking = ranking
  @ready = false
end

def mark_ready : Nil
  raise NotRankedYet.new("Cannot be ready before submitting a ranking") if @ranking.nil?
  @ready = true
end
```

The **session** owns the state machine. It has exactly two phases:

```
        ┌─────────┐   facilitator.reveal   ┌──────────┐
   ───▶ │  LOBBY  │ ─────────────────────▶ │ REVEALED │
        └─────────┘                        └──────────┘
```

`LOBBY` is where people join, submit, and toggle ready. `REVEALED` is terminal.
The session guards every mutation so no rule can be bypassed:

```crystal
# src/domain/session.cr
def reveal(token : String) : Nil
  raise Forbidden.new("Only the facilitator can reveal") unless token == @facilitator_token
  guard_lobby!
  @phase = Phase::Revealed
end

private def guard_lobby! : Nil
  raise WrongPhase.new("Session is already revealed") if revealed?
end
```

Two design questions get answered here, and both fall out of keeping the machine
to two states:

- **Is reveal reversible?** No. There is no transition out of `REVEALED`. You
  don't un-reveal a group discussion, and a terminal state is simpler to reason
  about and to test.
- **Can someone join after the reveal?** They can join, but the phase guards
  stop them submitting — they *observe only*. Their ranking would not have
  informed the discussion, so admitting it afterwards would falsify the group
  snapshot.

Notice the session never calls `Time.now` itself. The caller passes the current
time in. That keeps expiry logic deterministic and trivially testable:

```crystal
# spec/domain/session_spec.cr
session.expired?(Time.utc(2026, 1, 1, 2, 59)).should be_false
session.expired?(Time.utc(2026, 1, 1, 3, 1)).should be_true
```

---

## Chapter 4 — Confidentiality as a server invariant

This is the chapter that justifies the whole architecture.

The requirement is not "hide other rankings in the UI." It is "the server must
never *serialise* another participant's ranking before reveal." So we build the
exact view a given participant is allowed to see, and we build it in the
domain — the one place that can't be bypassed by a forgetful route handler:

```crystal
# src/domain/session.cr
def public_view(for viewer_id : String) : SessionView
  views = @participants.values.map do |participant|
    visible = revealed? || participant.id == viewer_id
    ranking = visible ? participant.ranking : nil
    ParticipantView.new(participant.id, participant.name, participant.ready?, ranking)
  end
  SessionView.new(@phase, @code, views)
end
```

A ranking makes it into the view only when the session is revealed **or** it is
the viewer's own. Everyone else's `ranking` is `nil`. The test asserts exactly
that:

```crystal
# spec/domain/session_spec.cr
view = session.public_view(for: "me")
mine = view.participants.find! { |entry| entry.id == "me" }
hers = view.participants.find! { |entry| entry.id == "her" }

mine.ranking.should_not be_nil
hers.ranking.should be_nil
```

Because confidentiality is decided here, no downstream layer has to remember to
enforce it. The serializer and the WebSocket hub just faithfully transmit
whatever the view contains — and the view already withholds what must stay
secret.

---

## Chapter 5 — Keeping sessions in memory, and sweeping them

`SessionStore` is the whole persistence layer: a hash in one process.

```crystal
# src/domain/session_store.cr
CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
CODE_LENGTH   = 4

def open(now : Time = Time.utc) : Session
  session = Session.new(
    code: fresh_code,
    facilitator_token: Random::Secure.hex(16),
    created_at: now,
    ttl: @ttl,
  )
  @sessions[session.code] = session
end
```

Two small decisions worth calling out:

- The join **code** uses an alphabet with no `0/O` and no `1/I`, so a code read
  aloud across a room is unambiguous. It is short and not secret.
- The **facilitator token** is a long random hex string, and it *is* secret.
  These are two different things on purpose (more on that in Chapter 6).

Sweeping expired sessions is a plain method, again taking the time as an
argument:

```crystal
def sweep(now : Time = Time.utc) : Int32
  expired = @sessions.select { |_, session| session.expired?(now) }
  expired.each_key { |code| @sessions.delete(code) }
  expired.size
end
```

The domain is now complete and fully tested — with no framework anywhere in
sight. Everything from here on is adapter.

---

## Chapter 6 — Kemal as an adapter

Now we let Kemal translate HTTP into calls on the domain. Every handler is thin
glue: parse the request, call the domain, return the result.

```crystal
# src/web/app.cr
post "/sessions" do |env|
  session = STORE.open
  env.response.content_type = "application/json"
  {code: session.code, facilitator_token: session.facilitator_token}.to_json
end
```

That single response carries the two separate secrets. The **code** is what the
facilitator reads out to the room; the **facilitator token** is what the
facilitator's own browser keeps to authorise the reveal later. Keeping them
separate means the token never has to appear on a screen that's being shared —
the classic way a "secret in the URL" leaks.

Joining is just as thin, with basic validation:

```crystal
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
```

The wire format lives in its own module, so the routes stay about routing. The
serializer only *reflects* what the view decided — a hidden ranking is `nil`,
so it becomes JSON `null`, and the card names are never written:

```crystal
# src/web/payload.cr
json.field "ranking" do
  ranking = participant.ranking
  if ranking.nil?
    json.null
  else
    json.array { ranking.order.each { |card| json.string(card.to_s) } }
  end
end
```

We test the wire directly, with belt and suspenders: not only should a hidden
ranking be `null`, no card name from it may appear anywhere in the bytes.

```crystal
# spec/web/payload_spec.cr
raw = Payload.session(session.public_view(for: "me"))
raw.should contain(%("ranking":null))
Motivator.values.each do |card|
  raw.includes?(%("#{card}")).should be_false
end
```

---

## Chapter 7 — Real time with a WebSocket hub

After joining, every state change travels over a WebSocket. A participant sends
`submit`, `ready`, or `reveal`; the server applies it to the domain and pushes
the new state to everyone.

The subtle part is the push. A single broadcast must produce a *different*
payload per viewer, because each viewer is allowed to see different things. So
the hub sends every socket its **own** `public_view`:

```crystal
# src/web/hub.cr
def broadcast(session : Session) : Nil
  @mutex.synchronize do
    @connections[session.code].each do |conn|
      conn.socket.send(Payload.session(session.public_view(for: conn.id)))
    end
  end
end
```

Confidentiality is not re-implemented here. The hub trusts the view; the view
already withheld what must stay secret. That's the payoff of Chapter 4.

The message dispatch turns a client frame into one domain call, then
broadcasts. Any refusal from the domain — wrong phase, wrong token, an invalid
ranking — is sent back to *that one socket* as an error, never broadcast:

```crystal
# src/web/app.cr
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
```

A note on **presence**: closing a socket does *not* remove the participant.
Their ranking survives a dropped connection so they reappear at reveal — the
right behaviour for a ritual, where someone who lost wifi still counts. The
socket is only the live channel, not the source of who is in the room.

The highest-value test in the suite boots a real server and drives two live
sockets end to end, proving confidentiality on the actual wire:

```crystal
# spec/web/app_spec.cr
grace.send({type: "submit", order: full_order})
hidden = ada.wait_for { |json| participant(json, "Grace")["ready"] == false }
participant(hidden, "Grace")["ranking"].raw.should be_nil   # secret before reveal

grace.send({type: "reveal", token: token})
shown = ada.wait_for { |json| json["phase"] == "revealed" }
participant(shown, "Grace")["ranking"].as_a.size.should eq(10) # visible after
```

---

## Chapter 8 — A frontend with no build step

The frontend is three static files under `public/`, served by Kemal — plain
HTML, one CSS file, one JS file. No framework, no bundler, no transpile.

It is a tiny single-page app with three screens toggled in JavaScript: home
(start or join), the room (lobby), and the revealed results. All state changes
go over the same WebSocket the server already speaks.

The ranking editor is a list with up/down buttons rather than drag-and-drop:
keyboard-accessible, no library, and trivial to reason about.

```javascript
// public/app.js
function moveCard(index, dir) {
  const target = index + dir;
  const order = state.order;
  [order[index], order[target]] = [order[target], order[index]];
  renderEditor();
}
```

The facilitator's browser holds the token from Chapter 6 in memory and sends it
only with the reveal message:

```javascript
$("reveal").addEventListener("click", () => {
  send({ type: "reveal", token: state.token });
});
```

The facilitator is a pure observer plus the reveal button. Because they are not
a participant, their `public_view` shows presence and ready state but no
rankings — until they reveal, at which point everyone's appears. The server's
one confidentiality rule gives the facilitator exactly the right view for free.

---

## Chapter 9 — A hardened container built `FROM scratch`

The image should contain nothing but what runs, and should run as an
unprivileged user. We borrow the approach from
[spider-gazelle's Dockerfile](https://github.com/spider-gazelle/spider-gazelle/blob/master/Dockerfile):
build a **dynamically** linked binary, then ship exactly the shared libraries
`ldd` says it needs. Each library can then be patched independently of the
application, and a scanner sees real package versions rather than one opaque
static blob.

The build stage compiles a dynamic release binary, strips it, and creates the
unprivileged user (so its `/etc/passwd` entry can be reused in the final image):

```dockerfile
FROM crystallang/crystal:1.21.0-alpine AS build
ARG IMAGE_UID=10001
ENV UID=$IMAGE_UID
ENV APP_USER=appuser
RUN apk add --no-cache --update git ca-certificates
RUN adduser -D -g "" -H -s /sbin/nologin -u "${UID}" "${APP_USER}"
WORKDIR /app
COPY shard.yml shard.lock ./
RUN shards install --production --skip-postinstall
COPY src ./src
COPY public ./public
RUN shards build --release --production --no-debug && \
    strip bin/motivators
```

Then the key step — walk the binary's dependencies with `ldd` and copy each
one into a `deps/` tree that mirrors its absolute path:

```dockerfile
RUN for binary in /app/bin/*; do \
      ldd "$binary" | tr -s '[:blank:]' '\n' | grep '^/' | \
      xargs -I % sh -c 'mkdir -p $(dirname "deps%"); cp "%" "deps%";'; \
    done
```

For this app that collects seven libraries: the musl loader, OpenSSL
(`libssl`/`libcrypto`), the garbage collector, `libgcc_s`, PCRE2 and zlib.

The final stage is `scratch` with just the identity files, the libraries, the
binary and the assets — and it runs as `appuser`:

```dockerfile
FROM scratch
ENV KEMAL_ENV=production
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
COPY --from=build /etc/passwd /etc/passwd
COPY --from=build /etc/group /etc/group
COPY --from=build /etc/hosts /etc/hosts
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /app/deps /
COPY --from=build /app/bin/motivators /motivators
COPY --from=build /app/public /public
USER appuser:appuser
EXPOSE 3000
ENTRYPOINT ["/motivators"]
CMD ["-b", "0.0.0.0", "-p", "3000"]
```

The result is about **14 MB**. That's a few MB more than a fully static build
would be — the copied OpenSSL is larger than what static stripping would fold
in — but in exchange the image runs unprivileged and its libraries are visible
and patchable. Port 3000 is above 1024, so the non-root user can bind it with
no extra capability.

One thing we *don't* add: a `HEALTHCHECK`. Spider-gazelle's binary has a
built-in `-c URL` self-check it can call, but Kemal doesn't, and a `scratch`
image has no shell or `curl` to run one. So health checking is left to the
orchestrator hitting `/` over HTTP.

`docker-compose.yml` is the reference deployment readers copy:

```yaml
services:
  motivators:
    build: .
    image: ghcr.io/OWNER/motivators:latest
    ports:
      - "3000:3000"
    environment:
      KEMAL_ENV: production
    restart: unless-stopped
```

---

## Chapter 10 — CI/CD

Two workflows. `ci.yml` runs specs and a format check on every push, and lints
with ameba. (The current tagged ameba release doesn't build on Crystal 1.21
yet, so CI builds ameba from master; ameba is intentionally *not* a shard
dependency, which keeps `shards install` clean.) A weekly scheduled run rebuilds
everything to catch upstream breakage before a reader does.

On pull requests, a third job runs **incremental mutation testing**: it diffs
the branch, and for each changed `src/domain/*.cr` file it runs crytic and fails
below a 90% mutation score. Only the domain is gated — it's the pure logic worth
holding to that bar; the Kemal adapter is glue the integration spec already
exercises. Like ameba, crytic is built in CI (with its ameba dependency pinned
to master) rather than added as a shard dependency.

`release.yml` fires on a `v*` tag and pushes the image to GHCR, tagged with the
semantic version and `latest`:

```yaml
on:
  push:
    tags: ["v*"]
# ...
- uses: docker/build-push-action@v6
  with:
    context: .
    push: true
    tags: ${{ steps.meta.outputs.tags }}
```

---

## Chapter 11 — The one limit: a single process

Everything the app knows lives in one process's memory. That is what makes it
so small — and it is also its one hard limit: **you cannot run more than one
replica.** A second container would have its own, separate set of sessions, and
a participant load-balanced to the "wrong" one would find their session missing.

For a tool a team spins up for a half-hour retro, this is completely fine. If
you genuinely needed horizontal scale, the shape of the change is clear: move
the session state and the broadcast fan-out behind a shared pub/sub (Redis, or
Postgres `LISTEN/NOTIFY`), so any replica can serve any participant. That is a
bonus chapter, not the default — and reaching for it before you need it would
be exactly the over-engineering this whole tutorial argues against.

The app you have is the right size for the problem. That was the point.
