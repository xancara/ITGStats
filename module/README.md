# TwitchStats.lua — Simply Love module

Streams live session stats from ITGmania to the ITG Stats Twitch extension backend.
One self-contained file; nothing secret lives in it.

**Requires:** ITGmania ≥ 1.2.0, Simply Love ≥ 5.8.1

## Install (streamer)

1. Copy `TwitchStats.lua` into `Themes/Simply Love/Modules/` (create the folder if needed).
2. On Twitch, open the extension's **config page** and generate your key — it shows a
   pre-filled `TwitchStats.ini` to copy. Save it as `Save/TwitchStats.ini`.
3. Add the stats server host to `HttpAllowHosts` in `Save/Preferences.ini` (comma-separated;
   keep the existing entries), and make sure `HttpEnabled=1`. Edit while the game is closed —
   these preferences are read once at startup.
4. Start ITGmania and play — by default the module runs silently with no on-screen UI.
   To verify or troubleshoot the connection, add `Debug=true` to the ini (see below): the
   song select screen then shows a small status indicator in the top-left corner — green
   **TwitchStats: connected**, yellow **connecting...** (retrying with backoff), red **off**
   (dormant — check the messages/log for why).

`Save/TwitchStats.ini` reference (comments must use `#`):

```ini
[TwitchStats]
ApiKey=itgs_…                      # from the config page; shown exactly once
Url=wss://ebs.example.com/ingest
SendProgress=1                     # 1 = live mid-song updates (throttled to 1 per 2 s)
ShareProfileNames=0                # 1 = send profile display names to viewers
#Debug=true                        # optional, hand-add: show the song-wheel connection
                                   # indicator. Absent/false = hidden (normal play). The
                                   # config page never writes this line.
```

The config page only generates the first four keys. `Debug` is a hidden flag you add by
hand when you want the connection indicator on the song wheel; leave it out for a clean
screen during normal streaming.

## Troubleshooting

The song-wheel status indicator referenced below only appears when `Debug=true` is in the
ini — add it (see Install step 4) before relying on the indicator to diagnose anything.

| Message / symptom | Fix |
|---|---|
| `no Save/TwitchStats.ini found` | Copy it from the extension config page; save in `Save/`. |
| `missing ApiKey or Url` | Re-copy the ini from the config page; don't hand-edit the key. |
| `ITGmania blocked the connection… HttpAllowHosts` | Add the EBS host `*.smreqquests.com` to `HttpAllowHosts` in `Save/Preferences.ini` (game closed), keep `HttpEnabled=1`. Example: `HttpAllowHosts=*.groovestats.com,*.itgmania.com,*.smrequests.com,*.arrowcloud.dance`|
| `API key rejected` | Key was mistyped or never issued — re-copy from the config page. |
| `API key was revoked/rotated` | Someone clicked Regenerate — update the ini with the new key. |
| Overlay frozen mid-song | Harmless: the module reconnects with backoff and re-sends what it can (last ~50 events, newest 5 detail blobs). |
| Module silent after repeated failures | It goes dormant rather than spam-reconnecting; restart ITGmania after fixing the cause. |
| Indicator stuck on yellow `connecting...` | The connection never completes: server down, TLS problem, or the proxy is not passing WebSocket upgrades. Check `https://<host>/healthz` (with `DIAG_ALLOW_IPS` set, it lists every connection attempt and why it failed). |
| Indicator red `off` | The module went dormant — the SystemMessage at startup / `Logs/log.txt` says why (bad key, blocked host, etc.). Fix, then restart ITGmania. |

Notes: Course Mode and demonstration/attract are intentionally not recorded. Casual game
mode sends scores but no per-play detail (Simply Love doesn't track offsets there).
Non-ASCII titles/names are truncated bytewise at protocol limits — a rare multi-byte
character may be clipped at the boundary. Course Mode support will be released sometime in the future.
