# Autoduck

<img src="assets/duck.png" width="200" alt="the enforcer">

An [Omarchy](https://omarchy.org) shell plugin that mutes your background
browser music while another browser tab plays audio, and unmutes it when
that audio stops. Music in a YouTube tab, you click a video on X — the
music mutes itself within a second, and comes back a few seconds after the
video ends.

Works only for browser audio.

## Install

```bash
omarchy plugin add https://github.com/CostaFot/omarchy-autoduck --enable
```

A duck icon appears in the bar: highlighted while ducked, dimmed when
disabled. Click it to toggle.

Remove with `omarchy plugin remove costafot.autoduck`.

## CLI

```bash
omarchy-shell autoduck status   # {"enabled":true,"ducked":false,...}
omarchy-shell autoduck toggle   # also: enable / disable
omarchy-shell autoduck reset    # unstick: clear all state, unmute everything
```

## Configuration

Properties at the top of `Service.qml` (restart the shell to apply —
`omarchy-restart-shell`):

- `browserApps` — which `application.name`s count as browsers.
- `peakThreshold` — loudness above which a stream counts as playing (0.01).
- `silenceMs` — quiet time before music resumes (2500 ms).
- `stopConfirmMs` — resume delay after the other streams cork/close (800 ms).
- `duckConfirmMs` — sound must stay loud this long to duck, so pings and
  hover previews don't trigger (250 ms).
- `resumeHoldMs` — extra resume delay while other streams still linger,
  bridging the gap between videos (600 ms).
- `reduckGraceMs` — new sound this soon after a resume re-ducks instantly
  (2000 ms).
- `musicAdoptMs` — window after the music stream vanishes in which a new
  stream is adopted as the music (30 000 ms).

## Limitations

- The oldest browser stream is assumed to be your music: start music for
  the *first time* while a video is already playing and the video gets muted
  instead. (Pausing and resuming music is fine — it re-attaches as music.)
- Manually unmuting ducked music is respected: ducking stands down until
  the interrupting sound has stopped.
- Music is muted, not paused — the track keeps advancing silently.
- A video that goes fully silent for longer than `silenceMs` briefly brings
  the music back.
