import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

// Autoduck: while a browser tab is playing music, mute it whenever another
// browser tab starts actually producing sound, and unmute it once that sound
// has stopped.
//
// Detection is loudness-based (PwNodePeakMonitor), not stream-based: muted
// autoplay videos open silent PipeWire streams and must not trigger ducking,
// and some sites (e.g. X) keep their stream open for seconds after the video
// stops, so stream existence is wrong in both directions.
//
// Only streams whose application.name is in `browserApps` participate, as
// music or as trigger. Games, VoIP, system sounds, and every other audio
// source are ignored entirely.
Item {
  id: root

  property var shell: null

  // --- Configuration ---------------------------------------------------
  property var browserApps: [
    "Brave", "brave",
    "Chromium", "chromium",
    "Google Chrome", "google-chrome", "Google Chrome Beta",
    "Vivaldi", "vivaldi",
    "Microsoft Edge", "microsoft-edge",
    "Firefox", "firefox", "LibreWolf", "librewolf", "Zen"
  ]
  // Peak level (0..1) above which a stream counts as audibly playing.
  property real peakThreshold: 0.01
  // Music resumes after the other tab has been this quiet for this long...
  property int silenceMs: 2500
  // ...or this long after its stream corked or closed (definitive stop).
  property int stopConfirmMs: 800
  // Sound must stay loud this long before it ducks, so notification pings
  // and hover previews from quick tab-switching don't trigger.
  property int duckConfirmMs: 250
  // Extra resume delay while other browser streams still linger, bridging
  // the gap between one video ending and the next starting.
  property int resumeHoldMs: 600
  // New sound this soon after a resume re-ducks instantly (skipping
  // duckConfirmMs): it is a continuation, not a new interruption.
  property int reduckGraceMs: 2000
  // Pausing music kills its stream a few seconds later; a brand-new browser
  // stream within this window is adopted as the music instead of re-electing
  // the oldest stream (which by then would be the video).
  property int musicAdoptMs: 30000

  // --- State ------------------------------------------------------------
  property bool enabled: true
  property var duckedNode: null
  readonly property bool ducked: duckedNode !== null
  property double lastLoudAt: 0
  property double lastOthersUncorkedAt: 0
  // Start of the current burst of interrupter sound; loud samples separated
  // by more than loudEpisodeGapMs count as separate bursts.
  property double loudEpisodeStartAt: 0
  readonly property int loudEpisodeGapMs: 500
  // Until when new sound re-ducks without waiting out duckConfirmMs.
  property double graceUntil: 0
  // Set when the user unmutes ducked music themselves; cleared once the
  // interrupting sound has been quiet for silenceMs.
  property bool duckSuppressed: false
  // When the music stream vanished, and the stream adopted in its place.
  property double musicVacantAt: 0
  property real lastMusicSerial: -1
  property var pinnedMusicNode: null
  // Serials seen in the previous browserStreams pass, to spot newcomers.
  property var knownSerials: ({})
  // Streams (by serial) already checked for a leftover restored mute.
  property var healedSerials: ({})

  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []

  // Browser playback streams, oldest first. Bound via PwObjectTracker so
  // their properties stay live and audio.muted is writable.
  readonly property var browserStreams: {
    var out = []
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i]
      if (node && node.isStream && node.isSink) {
        var app = String((node.properties || {})["application.name"] || "")
        if (browserApps.indexOf(app) !== -1) out.push(node)
      }
    }
    out.sort(function (a, b) { return serialOf(a) - serialOf(b) })
    return out
  }

  // The background music: whatever is ducked, else a stream adopted after a
  // pause/resume, else the oldest browser stream (it started first).
  readonly property var musicNode: duckedNode
    || (pinnedMusicNode && nodeAlive(pinnedMusicNode) ? pinnedMusicNode
        : ((browserStreams || []).length > 0 ? browserStreams[0] : null))

  // Every other browser stream is a potential interrupter. Their loudness is
  // watched whenever the plugin is enabled and music exists.
  readonly property var otherStreams: {
    var music = musicNode
    return (browserStreams || []).filter(function (n) { return n !== music })
  }

  PwObjectTracker { objects: root.browserStreams }

  onBrowserStreamsChanged: {
    var streams = browserStreams || []
    var current = ({})
    for (var i = 0; i < streams.length; i++) current[serialOf(streams[i])] = true

    if (pinnedMusicNode && !nodeAlive(pinnedMusicNode)) pinnedMusicNode = null
    if (lastMusicSerial >= 0 && !current[lastMusicSerial]) musicVacantAt = Date.now()

    // Music resuming after a pause comes back as a brand-new stream. Without
    // adoption the video would now be the oldest stream, get elected as
    // music, and be muted by the resuming music.
    if (!duckedNode && Date.now() - musicVacantAt < musicAdoptMs) {
      for (var j = 0; j < streams.length; j++) {
        var n = streams[j]
        if (knownSerials[serialOf(n)]) continue
        var hasOthers = false
        for (var k = 0; k < streams.length; k++)
          if (streams[k] !== n && isUncorked(streams[k])) hasOthers = true
        if (hasOthers) { pinnedMusicNode = n; musicVacantAt = 0; break }
      }
    }

    knownSerials = current
    var m = musicNode
    lastMusicSerial = m ? serialOf(m) : -1
  }

  function serialOf(node) {
    var serial = Number((node.properties || {})["object.serial"])
    return isNaN(serial) ? Number(node.id || 0) : serial
  }

  function isUncorked(node) {
    if (!node || !node.ready) return false
    var corked = (node.properties || {})["pulse.corked"]
    return !(corked === true || corked === "true")
  }

  function nodeAlive(node) {
    return node !== null && (browserStreams || []).indexOf(node) !== -1
  }

  // Called with the current peak of one interrupter stream.
  function onOtherStreamPeak(level) {
    if (!enabled || level < peakThreshold) return
    var now = Date.now()
    // Quiet for silenceMs means whatever sound the user overrode has ended;
    // this loud sample is a new interruption and ducking applies again.
    if (duckSuppressed && now - lastLoudAt > silenceMs) duckSuppressed = false
    if (now - lastLoudAt > loudEpisodeGapMs) loudEpisodeStartAt = now
    lastLoudAt = now
    if (duckedNode || duckSuppressed) return
    if (now < graceUntil || now - loudEpisodeStartAt >= duckConfirmMs) duck()
  }

  function duck() {
    var music = musicNode
    if (!music || !isUncorked(music) || !music.audio) return
    music.audio.muted = true
    duckedNode = music
    lastLoudAt = Date.now()
    lastOthersUncorkedAt = Date.now()
  }

  function unduck() {
    var n = duckedNode
    duckedNode = null
    graceUntil = Date.now() + reduckGraceMs
    // Best-effort even if the stream already left the list: stream-restore
    // persists mute per application.name, so a mute left behind here would
    // resurrect on every future stream of that app.
    try { if (n && n.audio) n.audio.muted = false } catch (e) {}
  }

  function setEnabled(on) {
    if (enabled === on) return
    if (!on) unduck()
    else { duckSuppressed = false; graceUntil = 0 }
    enabled = on
  }

  function toggle() {
    setEnabled(!enabled)
    return enabled ? "enabled" : "disabled"
  }

  // Panic button: drop every bit of duck state and unmute all browser
  // streams, for when something still ends up stuck muted.
  function reset() {
    duckedNode = null
    duckSuppressed = false
    pinnedMusicNode = null
    graceUntil = 0
    musicVacantAt = 0
    var streams = browserStreams || []
    var count = 0
    for (var i = 0; i < streams.length; i++) {
      var n = streams[i]
      try {
        if (n && n.audio && n.audio.muted) { n.audio.muted = false; count++ }
      } catch (e) {}
    }
    return count
  }

  Component.onDestruction: unduck()

  // One peak monitor per interrupter stream. A monitor emits peakChanged
  // frequently while its stream renders audio, so ducking reacts in well
  // under a second.
  Instantiator {
    model: root.enabled ? root.otherStreams : []
    delegate: PwNodePeakMonitor {
      required property var modelData
      node: modelData
      enabled: true
      onPeakChanged: root.onOtherStreamPeak(peak)
    }
  }

  // Safety net: stream-restore remembers mute per application.name, so a
  // stream lost while ducked (tab closed mid-duck, shell crash) leaves every
  // future stream of that app born muted. Browsers never create their own
  // streams muted, so a browser stream that shows up already muted is a
  // leftover duck: clear it. Checked once per stream, polling briefly
  // because the restored mute can land moments after the node appears.
  Instantiator {
    model: root.browserStreams
    delegate: Timer {
      required property var modelData
      property int tries: 0
      interval: 250
      running: true
      repeat: true
      onTriggered: {
        var n = modelData
        if (++tries > 8 || !root.nodeAlive(n)) { running = false; return }
        if (!n.ready || !n.audio) return
        var serial = root.serialOf(n)
        if (!root.healedSerials[serial]) {
          root.healedSerials[serial] = true
          if (n !== root.duckedNode && n.audio.muted) n.audio.muted = false
        }
        running = false
      }
    }
  }

  // While ducked, decide when to resume.
  Timer {
    interval: 300
    repeat: true
    running: root.ducked
    onTriggered: {
      if (!root.nodeAlive(root.duckedNode)) {
        // Music tab was closed or its stream ended while ducked. Still try
        // to clear the mute: stream-restore persists it per app otherwise.
        root.unduck()
        return
      }
      if (root.duckedNode.audio && root.duckedNode.audio.muted === false) {
        // The user unmuted the ducked music themselves. Respect it: drop
        // the duck and stand down until the interrupting sound has faded.
        root.duckSuppressed = true
        root.duckedNode = null
        return
      }
      var now = Date.now()
      var uncorkedOthers = root.otherStreams.filter(root.isUncorked)
      if (uncorkedOthers.length > 0) root.lastOthersUncorkedAt = now
      // While other streams still linger, wait a little longer: stopping
      // one video and starting the next should not blip the music between.
      var stopWait = root.stopConfirmMs
        + (root.otherStreams.length > 0 ? root.resumeHoldMs : 0)
      if (now - root.lastOthersUncorkedAt > stopWait
          || now - root.lastLoudAt > root.silenceMs)
        root.unduck()
    }
  }

  IpcHandler {
    target: "autoduck"

    function status(): string {
      return JSON.stringify({
        enabled: root.enabled,
        ducked: root.ducked,
        suppressed: root.duckSuppressed,
        adoptedMusic: root.pinnedMusicNode !== null,
        browserStreams: root.browserStreams.length,
        watching: root.otherStreams.length
      })
    }
    function enable(): string { root.setEnabled(true); return "enabled" }
    function disable(): string { root.setEnabled(false); return "disabled" }
    function toggle(): string { return root.toggle() }
    function reset(): string {
      return "reset, unmuted " + root.reset() + " stream(s)"
    }
  }
}
