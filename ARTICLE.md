---
title: "Building a real-time Crystal app with Kemal — where privacy is a server invariant"
published: true
description: "A small, ephemeral, real-time Moving Motivators app in Crystal. Pure-domain design, confidentiality enforced on the server, and a 14 MB hardened scratch image."
tags: crystal, webdev, tutorial, docker
series: "Happy: right-sizing frameworks in Crystal"
---

<!-- In-repo copy of the dev.to article (suite convention: keep it next to the code).
     Published at: https://dev.to/jadekharats/building-a-real-time-crystal-app-with-kemal-where-privacy-is-a-server-invariant-5hch -->

I'm building **Happy**, a suite of small self-hosted team-ritual tools. There's a
twist: each app deliberately uses a *different* framework, to make one point over
and over — **framework choice should match problem size**, not habit.

The first one to ship is **Moving Motivators**: a facilitator opens a session,
participants join with a short code and privately rank ten motivation cards, and
when everyone's ready the facilitator triggers a **reveal** so all rankings
appear side by side for discussion.

Two properties make it interesting:

- **Ephemeral.** State lives in memory and nowhere else. Sessions expire after a
  few hours and get swept. No database, no ORM, no migrations.
- **Private until reveal.** A participant's ranking must stay hidden from the
  others until the reveal. Not "the UI hides it" — *the server must never put
  another participant's ranking in a payload* before that moment.

That second property is the one that shaped the whole design. Let's build it.

> Full source: [github.com/JadeKharats/motivators](https://github.com/JadeKharats/motivators)
> · a chapter-by-chapter [`TUTORIAL.md`](https://github.com/JadeKharats/motivators/blob/main/TUTORIAL.md) walks the whole thing.

## Why Kemal

[Kemal](https://kemalcr.com/) is a Sinatra-style micro-framework: routes, a
request/response cycle, WebSockets, static files. That's the entire feature
list — and it's exactly the feature list this app needs.

There's no database, so an ORM would be dead weight. There's no asset build, so a
pipeline would be ceremony. The rule I hold throughout: **the framework is an
adapter.** All the actual rules of the game live in plain Crystal objects that
never import Kemal. That's what lets me test the whole domain without booting a
server.

## 1. The domain, framework-free

Start with the smallest certain thing and build up. A **ranking** isn't "a list
of cards" — it's a complete ordering of all ten, no duplicates, no gaps. Make
that a value object that enforces its own invariants at construction, so an
invalid ranking simply can't exist:

```crystal
struct Ranking
  getter order : Array(Motivator)

  def initialize(@order : Array(Motivator))
    validate!
  end

  # 1 is most important, 10 is least.
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

Because construction validates, every other method can trust the invariant —
`position` uses `index!` (the raising variant) with no nil check, and that's safe
*by design*.

The **session** owns a two-phase state machine — `Lobby` → `Revealed` — and it's
terminal: you don't un-reveal a group discussion. It guards every mutation, so no
rule can be bypassed:

```crystal
def reveal(token : String) : Nil
  raise Forbidden.new("Only the facilitator can reveal") unless token == @facilitator_token
  guard_lobby!
  @phase = Phase::Revealed
end

private def guard_lobby! : Nil
  raise WrongPhase.new("Session is already revealed") if revealed?
end
```

The session never calls the clock itself — the caller passes the current time in,
which keeps expiry logic deterministic and trivial to test.

## 2. Confidentiality as a server invariant

Here's the chapter that justifies the architecture.

The requirement isn't "hide other rankings in the UI." It's "the server must
never *serialise* another participant's ranking before reveal." So I build the
exact view a given participant is allowed to see, and I build it **in the
domain** — the one place a forgetful route handler can't bypass:

```crystal
def public_view(for viewer_id : String) : SessionView
  views = @participants.values.map do |participant|
    mine = participant.id == viewer_id
    visible = revealed? || mine
    ranking = visible ? participant.ranking : nil
    ParticipantView.new(participant.name, participant.ready?, ranking, you: mine)
  end
  SessionView.new(@phase, @code, views)
end
```

A ranking makes it into the view only when the session is revealed **or** it's
the viewer's own. Everyone else's `ranking` is `nil`. Because confidentiality is
decided *here*, no downstream layer has to remember to enforce it — the
serializer and the WebSocket hub just faithfully transmit whatever the view
contains. Note what the view *omits*: the participant's `id` is their secret
WebSocket token, so it marks the viewer with a plain `you` flag rather than
handing every client everyone else's credentials.

And I test the wire directly, with belt and suspenders — not only should a hidden
ranking be `null`, no card name from it may appear anywhere in the bytes:

```crystal
raw = Payload.session(session.public_view(for: "me"))
raw.should contain(%("ranking":null))
Motivator.values.each do |card|
  raw.includes?(%("#{card}")).should be_false
end
```

## 3. Real time with a WebSocket hub

After joining, every state change travels over a WebSocket. The subtle part is
the push: a single broadcast must produce a *different* payload per viewer,
because each viewer may see different things. So the hub sends every socket its
**own** `public_view`:

```crystal
def broadcast(session : Session) : Nil
  @mutex.synchronize do
    @connections[session.code].each do |conn|
      conn.socket.send(Payload.session(session.public_view(for: conn.id)))
    end
  end
end
```

Confidentiality is not re-implemented here. The hub trusts the view; the view
already withheld what must stay secret. That's the payoff of step 2.

The highest-value test in the suite boots a *real* server and drives two live
sockets end to end, proving confidentiality on the actual wire:

```crystal
grace.send({type: "submit", order: full_order})
hidden = ada.wait_for { |json| participant(json, "Grace")["ready"] == false }
participant(hidden, "Grace")["ranking"].raw.should be_nil   # secret before reveal

grace.send({type: "reveal", token: token})
shown = ada.wait_for { |json| json["phase"] == "revealed" }
participant(shown, "Grace")["ranking"].as_a.size.should eq(10) # visible after
```

## 4. A hardened 14 MB image, `FROM scratch`

Crystal compiles to a single native binary, so the container can be tiny. I
borrow the approach from
[spider-gazelle's Dockerfile](https://github.com/spider-gazelle/spider-gazelle/blob/master/Dockerfile):
build a **dynamically** linked binary, then ship exactly the shared libraries
`ldd` says it needs — so each library is patchable independently, and a scanner
sees real package versions instead of one opaque static blob.

The trick is one `RUN` that walks the binary's dependencies and copies each into
a tree mirroring its absolute path:

```dockerfile
RUN for binary in /app/bin/*; do \
      ldd "$binary" | tr -s '[:blank:]' '\n' | grep '^/' | \
      xargs -I % sh -c 'mkdir -p $(dirname "deps%"); cp "%" "deps%";'; \
    done
```

For this app that's seven libraries — the musl loader, OpenSSL, the GC,
`libgcc_s`, PCRE2 and zlib. The final stage is `scratch` with just the identity
files, those libraries, the binary and the assets — and it runs as an
**unprivileged user**:

```dockerfile
FROM scratch
ENV KEMAL_ENV=production
COPY --from=build /etc/passwd /etc/passwd
COPY --from=build /app/deps /
COPY --from=build /app/bin/motivators /motivators
COPY --from=build /app/public /public
USER appuser:appuser
EXPOSE 3000
ENTRYPOINT ["/motivators"]
CMD ["-b", "0.0.0.0", "-p", "3000"]
```

Port 3000 is above 1024, so the non-root user binds it with no extra capability.
The result is ~14 MB — a few MB more than a fully static build, traded for a
non-root, patchable-libs posture.

```bash
docker run -p 3000:3000 ghcr.io/jadekharats/motivators:latest
```

## How good are the tests, really?

Line coverage tells you which lines ran. It doesn't tell you whether your
assertions would catch a bug. So I ran [crytic](https://github.com/hanneskaeufler/crytic)
mutation testing on the domain — and even with a green suite, it surfaced three
real assertion gaps. My favourite: mutating `Random::Secure.hex(16)` to `hex(0)`
produced an **empty facilitator token**, meaning `reveal("")` would authorise
*anyone*. No spec caught it. A genuine security hole that coverage was blind to.

After closing the gaps, the domain sits at **100% mutation score**, and CI runs an
incremental mutation gate on every pull request.

## The point

The finished app is ~290 lines of Crystal plus a single-file, no-build frontend.
No database, no ORM, no pipeline. It does exactly what a half-hour team ritual
needs and not one thing more — and keeping it that small is the feature.

It has one honest limit: state lives in a single process, so it runs as **one
replica**. For this problem, that's the right trade; scaling out behind a shared
pub/sub is a possible extension, not the default. Reaching for it before you need
it would be exactly the over-engineering the whole Happy suite argues against.

Next in the series: **kudos**, where the problem *does* call for a bigger tool —
auth, uploads, history — and so it's built on Lucky. Same lesson, opposite
conclusion. That's the point.

- **Repo:** https://github.com/JadeKharats/motivators
- **Full tutorial:** [`TUTORIAL.md`](https://github.com/JadeKharats/motivators/blob/main/TUTORIAL.md)
- **Image:** `ghcr.io/jadekharats/motivators`

If you'd right-size differently, I'd genuinely like to hear it — tell me in the
comments.
