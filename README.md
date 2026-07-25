# Moving Motivators

[![Live demo](https://img.shields.io/badge/live%20demo-motivators.yoteau.fr-c85a3b)](https://motivators.yoteau.fr)

Ephemeral, real-time [Moving Motivators](https://management30.com/practice/moving-motivators/)
sessions for a team — built with Crystal and Kemal. In-memory only, no
database, ships as a **~14 MB** container built `FROM scratch` and running as
an unprivileged user.

A facilitator opens a session and gets a short join code. Participants join
with that code and privately rank ten motivator cards from most to least
important to them. When everyone is ready, the facilitator triggers a **reveal**
and all rankings appear side by side for discussion.

> Part of the **Happy** tutorial suite — small self-hosted team-ritual tools,
> each built with a framework matched to its problem size. A full build-along
> write-up lives in [`TUTORIAL.md`](TUTORIAL.md).

## Key properties

- **Ephemeral.** State lives in memory and nowhere else. Sessions expire after
  a few hours and are swept. Nothing to back up, nothing to leak from disk.
- **Private until reveal.** A ranking stays hidden from the other participants
  until the facilitator reveals — enforced on the server, not just in the UI.
  The payload sent to a participant never contains another's ranking before the
  reveal.
- **Real-time** over WebSocket: joins, ready state, and the reveal itself.

## Quick start

Try it now on the [live instance](https://motivators.yoteau.fr), or run it
yourself with Docker or Podman Compose:

```bash
docker compose up   # or: podman-compose up
```

Then open <http://localhost:3000>, click **Start a session** in one tab, and
**Join** with the code from another tab.

Or run the published image directly:

```bash
docker run -p 3000:3000 ghcr.io/jadekharats/motivators:latest
```

## Local development

```bash
shards install
crystal spec              # run the spec suite
crystal run src/motivators.cr   # serve on :3000
```

Quality tooling used on the domain:

- `crystal spec` — 33 examples, domain and state machine plus an end-to-end
  WebSocket test that proves confidentiality on the wire
- `ameba` — lint, clean
- `crytic` — **100% mutation score** on the domain

## How it's built

The domain — session, participant, ranking, and the two-phase state machine —
is pure Crystal with zero framework dependency, so it's tested without booting
an HTTP server. Kemal is only the adapter that turns HTTP and WebSocket traffic
into calls on that domain.

**One deliberate limit:** state lives in a single process's memory, so this runs
as **one replica only** — a second container would have its own separate
sessions. That's the right trade for a tool a team spins up for a half-hour
retro; scaling out behind a shared pub/sub is a possible extension, not the
default. See [`TUTORIAL.md`](TUTORIAL.md) for the full reasoning.

## License

[MIT](LICENSE) © 2026 David D. YOTEAU
