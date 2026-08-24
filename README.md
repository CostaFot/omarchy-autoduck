# Autoduck

An [Omarchy](https://omarchy.org) shell plugin that automatically mutes your
background browser music while another browser tab plays audio, and unmutes
it when that audio stops.

The scenario: music playing in a YouTube tab, you're scrolling X/Twitter (or
anything else) and tap a video. Normally you'd have to go mute the music tab
first. With Autoduck, the music mutes itself about a second after the video's
sound starts, and unmutes a few seconds after the video pauses or ends.

## How it works

Every browser tab that produces sound is a separate PipeWire stream. The
plugin's service watches those streams from inside `omarchy-shell` (via
Quickshell's native PipeWire bindings — no daemons, no polling subprocesses):

- When two browser streams are audible at once, the **older** stream is taken
  to be your background music and gets muted at the PipeWire level.
- When every other browser stream has been silent (paused, ended, or closed)
  for a couple of seconds, the music stream is unmuted.
- Muted autoplay videos (like X's scroll-by previews) never trigger it,
  because they don't produce an audible stream.

Only streams belonging to a browser (`application.name` allowlist, see
`browserApps` in `Service.qml`) participate — as music or as trigger. Games,
VoIP calls, system sounds, and every other audio source are ignored entirely:
they are never muted and never cause muting.

## Install

```bash
omarchy plugin add https://github.com/CostaFot/omarchy-autoduck --enable
```

A duck icon appears in the bar: normal while armed, highlighted while music
is ducked, dimmed when disabled. Click it to toggle the whole feature on/off.

## Uninstall

```bash
omarchy plugin remove costafot.autoduck
```

## CLI

```bash
omarchy-shell autoduck status   # {"enabled":true,"ducked":false,...}
omarchy-shell autoduck toggle
omarchy-shell autoduck enable
omarchy-shell autoduck disable
```

## Configuration

Edit the properties at the top of `Service.qml` (the shell hot-reloads on
save):

- `browserApps` — which `application.name`s count as browsers. Defaults cover
  Brave, Chromium/Chrome, Vivaldi, Edge, Firefox, LibreWolf, and Zen.
- `resumeDelayMs` — how long the other tab must stay silent before music
  resumes (default 2000 ms). This also stops the mute from flapping while you
  scroll from one video to the next.

## Notes and limitations

- "Older stream = music" is a heuristic. It matches the natural flow (music
  first, then browsing); if you instead start music *while* a video is
  already playing, the video is treated as the music and gets muted.
- Music is muted, not paused, so the track keeps advancing silently. Muting
  is the only reliable per-tab control: Chromium exposes a single MPRIS
  player for the whole browser and reassigns it to whatever media you
  interacted with last, so pause/play cannot be targeted at a specific tab.
- Chromium browsers keep a paused tab's stream around (corked) for ~5
  seconds. Resume latency is typically 2–4 s after the video actually
  pauses; up to ~7 s if the tab is closed outright.
