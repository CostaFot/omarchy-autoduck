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
- Any other browser stream loud → music muted at the PipeWire level
  (`audio.muted = true`).
- While ducked, a 300 ms timer decides when to resume: every other stream
  quiet for `silenceMs` (2500 ms), or `stopConfirmMs` (800 ms) after they
  have all corked (`pulse.corked`) or closed — whichever comes first.
- If the music stream itself disappears while ducked, state just resets.
- Music is muted, not paused: Chromium exposes a single MPRIS player for the
  whole browser and reassigns it to the last-interacted media, so pause
  cannot be targeted at a specific tab.

## IPC

`IpcHandler` target `autoduck`: `status` (JSON), `enable`, `disable`,
`toggle` — surfaced as `omarchy-shell autoduck <cmd>`.

Config properties (`browserApps`, `peakThreshold`, `silenceMs`,
`stopConfirmMs`) sit at the top of `Service.qml`; the shell hot-reloads on
save.
