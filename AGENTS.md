# Autoduck — technical notes

Omarchy shell plugin (Quickshell/QML). Three files:

- `Service.qml` — all the logic; runs inside `omarchy-shell` (`keepLoaded`).
- `BarWidget.qml` — duck icon; reads and toggles the service via
  `bar.shell.serviceFor("costafot.autoduck")`.
- `manifest.json` — plugin id `costafot.autoduck`, entry points for both.

## Detection

Every browser tab producing sound is a separate PipeWire stream
(`Quickshell.Services.Pipewire`). Only streams whose `application.name` is
in `browserApps` participate, as music or as trigger; all other audio is
ignored entirely.

Detection is loudness-based, not stream-based, because stream existence lies
in both directions: muted autoplay videos open silent streams, and some
sites (X) keep their stream open for seconds after playback stops. Each
non-music browser stream gets a `PwNodePeakMonitor` (via an `Instantiator`,
only while enabled); a peak above `peakThreshold` counts as audibly playing.

## Ducking

- Music = the oldest browser stream (sorted by `object.serial`, falling back
  to node id), or whatever is currently ducked. A `PwObjectTracker` keeps
  stream properties live and `audio.muted` writable.
- Any other browser stream loud for `duckConfirmMs` (250 ms, one continuous
  burst — gaps over 500 ms reset it) → music muted at the PipeWire level
  (`audio.muted = true`). Within `reduckGraceMs` (2000 ms) of a resume, one
  loud sample re-ducks instantly.
- While ducked, a 300 ms timer decides when to resume: every other stream
  quiet for `silenceMs` (2500 ms), or `stopConfirmMs` (800 ms) after they
  have all corked (`pulse.corked`) or closed — whichever comes first. While
  other browser streams still exist, the cork path waits `resumeHoldMs`
  (600 ms) longer so the music doesn't blip between two videos.
- Music identity survives pause/resume: pausing kills the stream ~5 s later,
  which marks the music slot vacant; for `musicAdoptMs` (30 s) a brand-new
  browser stream appearing while another is uncorked is pinned as music,
  instead of re-electing the oldest stream (by then the video).
- If the user unmutes ducked music themselves (mixer), the duck is dropped
  and ducking stands down until the interrupter has been quiet `silenceMs`.
- If the music stream itself disappears while ducked, unmute is still
  attempted, because PipeWire's stream-restore persists mute per
  `application.name` — a mute left behind resurrects on every future stream
  of that app (born muted). As a safety net for shell crashes, any browser
  stream that shows up already muted is unmuted once (leftover duck; browsers
  never create their own streams muted).
- Music is muted, not paused: Chromium exposes a single MPRIS player for the
  whole browser and reassigns it to the last-interacted media, so pause
  cannot be targeted at a specific tab.

## IPC

`IpcHandler` target `autoduck`: `status` (JSON), `enable`, `disable`,
`toggle`, `reset` (clear all duck state, unmute every browser stream) —
surfaced as `omarchy-shell autoduck <cmd>`.

Config properties (`browserApps`, `peakThreshold`, `silenceMs`,
`stopConfirmMs`) sit at the top of `Service.qml`. The shell does NOT reliably hot-reload the
symlinked plugin on save — run `omarchy-restart-shell` to load new code.
