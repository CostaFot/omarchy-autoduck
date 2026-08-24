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
Quickshell's native PipeWire bindings — no daemons, no polling subprocesses),
and detection is **loudness-based**: each non-music browser stream gets a peak
monitor, because stream existence lies in both directions — muted autoplay
videos open silent streams, and some sites (X) keep their stream open for
seconds after playback stops.

- The **oldest** browser stream is taken to be your background music (it
  started first).
- The moment any other browser stream is actually loud, the music is muted at
  the PipeWire level (well under a second).
- The music is unmuted once every other browser stream has been quiet for
  `silenceMs` (default 2.5 s), or shortly after they all cork/close
  (`stopConfirmMs`, default 0.8 s) — whichever comes first.
- Muted autoplay videos (like X's scroll-by previews) never trigger it: their
  streams exist but stay silent.

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
- `peakThreshold` — loudness (0..1) above which a stream counts as playing
  (default 0.01).
- `silenceMs` — how long the other tab must stay quiet before music resumes
  (default 2500 ms). Also stops flapping while you scroll between videos.
  Raise it if videos with long silent passages bounce your music back in.
- `stopConfirmMs` — resume delay after every other stream has corked or
  closed outright (default 800 ms).

## Notes and limitations

- "Older stream = music" is a heuristic. It matches the natural flow (music
  first, then browsing); if you instead start music *while* a video is
  already playing, the video is treated as the music and gets muted.
- Music is muted, not paused, so the track keeps advancing silently. Muting
  is the only reliable per-tab control: Chromium exposes a single MPRIS
  player for the whole browser and reassigns it to whatever media you
  interacted with last, so pause/play cannot be targeted at a specific tab.
- Resume latency is typically 1–3 s after the other tab's sound actually
  stops, independent of how long the site keeps its audio stream open.
- A video you keep watching that goes fully silent for longer than
  `silenceMs` will briefly bring the music back until its sound resumes.
