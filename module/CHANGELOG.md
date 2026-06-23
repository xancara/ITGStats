# TwitchStats.lua — changelog & feature list

The in-game **ITGmania / Simply Love module** that streams your live session to the ITG Stats
Twitch extension. This single file is the public home for both **what the module can do (and
since which version)** and the **rolling change history**. Feedback and bug reports are
welcome — see [module/README.md](README.md) for install/troubleshooting.

The version here matches `MODULE_VERSION` at the top of
[`TwitchStats.lua`](TwitchStats.lua); it is the module's own version, independent of the
Twitch extension's version. The change history follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Requires ITGmania ≥ 1.2.0 and Simply Love ≥ 5.8.1.

---

## Feature list

| Feature | Since |
|---|---|
| Streams your live session to the ITG Stats extension over a secure WebSocket | 0.1.0 |
| Per-song results: score, grade, EX score, judgments, holds/rolls/mines, notes hit/total | 0.1.0 |
| Full evaluation detail per play: timing offsets (histogram/scatter), per-column judgments, life graph, NPS density + peak, stream breakdown, modifiers | 0.1.0 |
| Optional live in-progress updates (score, judgments, notes) while you play, throttled to ~2 s — toggled by `SendProgress` in the ini | 0.1.0 |
| Restart detection (in-gameplay Ctrl+R) and abort detection (escaping gameplay before results) | 0.1.0 |
| Session lifecycle: start, periodic summary, end — with reconnect/grace handling (5 minutes) | 0.1.0 |
| Optional profile-name sharing (`ShareProfileNames`), re-announced when a profile switches on a pad | 0.1.0 |
| Optional connection-status indicator on the song wheel (green connected / yellow connecting / red off) — opt-in via the hidden `Debug` ini flag as of 0.1.1 | 0.1.0 |
| Resilient networking: native auto-reconnect with backoff, bounded outbound queue, and dormancy on a bad/revoked key or a persistent rejection loop | 0.1.0 |
| Works in ITG, FA+, and Casual modes (Casual omits EX score and detailed evaluation data) | 0.1.0 |
| Live in-progress score reports your **EX score** when *Display EX Score* is on, matching your on-screen number | 0.1.1 |

---

## [Unreleased]

_Nothing yet. Add entries here as module changes land, then stamp this section with the
version (and bump `MODULE_VERSION`) on release._

## [0.1.1] — 2026-06-16

### Changed
- Live in-progress score updates now send your **EX score** when you have Simply Love's
  *Display EX Score* turned on, so the live number on stream matches the score on your
  screen. It's decided per player, and anyone using the standard ITG score is unaffected.
- The song-wheel connection indicator is now **off by default**. Add `Debug=true` to
  `Save/TwitchStats.ini` to show it while troubleshooting your connection; leave it out for
  a clean screen during normal play. (The config page never writes this line — add it by
  hand.)

## [0.1.0] — 2026-06-15

Initial public release.

### Added
- Streams your live ITGmania session to the ITG Stats Twitch extension: songs played,
  scores, grades, EX scores, judgment counts, restarts, holds/rolls/mines, and notes.
- Full per-song evaluation detail for the overlay's detail view: timing-offset histogram and
  scatter, density (NPS) graph with life line and fail point, per-column (per-arrow)
  judgments, stream breakdown, and active modifiers.
- Optional live in-progress updates while you play (enable `SendProgress=1` in
  `Save/TwitchStats.ini`).
- Restart and abort detection so the overlay reflects retries and bailed attempts correctly.
- Optional profile-name sharing (`ShareProfileNames=1`) with per-profile attribution.
- On-song-wheel connection indicator and resilient, self-throttling networking that goes
  quiet on a bad key rather than hammering the server.
