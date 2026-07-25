# Moving Motivators (Crystal / Kemal)

See ../CLAUDE.md for suite-wide conventions.

Second app of the suite, but the first to ship: smallest scope, fully
autonomous, publishable on its own. It exists to prove the format before I
invest in the bigger apps.

## What it does

A facilitator opens a session and gets a short access code. Participants join
via that code and privately rank 10 motivator cards from most to least
important to them:

Curiosity, Honor, Acceptance, Mastery, Power, Freedom, Relatedness, Order,
Goal, Status

When everyone is ready, the facilitator triggers a reveal and all rankings are
shown side by side for group discussion.

## Key properties

- Fully ephemeral: in-memory only. No database, no ORM, no migrations.
- Sessions expire after a few hours; expired sessions are swept.
- Individual rankings stay hidden until reveal. The server must not serialise
  another participant's ranking before that point — not "the UI hides it",
  the payload must not contain it.
- Real-time over WebSocket: participants joining and leaving, ready state,
  and the reveal itself.

## Constraints specific to this app

- Kemal only. No ORM, no asset pipeline. Plain JS and CSS if the frontend
  needs anything at all.
- The domain — session, participant, ranking, phase state machine — is pure
  Crystal, testable without booting an HTTP server. Kemal is the adapter.
- Target 150–300 lines of application code. Past that, we've scope-crept.
  Tell me instead of continuing.
- Single process, in-memory state. Document that this breaks with more than
  one replica; the pub/sub version is a bonus chapter, not the default.

## Deliverables

- The app
- A spec suite covering the domain and the state machine
- Multi-stage Dockerfile → GHCR
- docker-compose.yml
- TUTORIAL.md, written alongside the code rather than after, with chapters
  mirroring the build order

## Start here

Propose, then stop for review:

1. The domain model and the phase state machine
2. The file and directory layout
3. The tutorial chapter outline

## Open questions — challenge me on these

- Facilitator identity across reconnects, without accounts. I'm assuming a
  secret token in the URL. Argue against it if you have something better.
- Is reveal irreversible?
- Does a late joiner get to participate after reveal, or only observe?
- App name: `motivators` is the directory, not necessarily the product name.
