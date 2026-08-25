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

  // --- State ------------------------------------------------------------
  property bool enabled: true
  property var duckedNode: null
  readonly property bool ducked: duckedNode !== null
  property double lastLoudAt: 0
  property double lastOthersUncorkedAt: 0
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

  // The background music is the oldest browser stream (it started first);
  // while ducked, it stays whatever we muted.
  readonly property var musicNode: duckedNode
    || ((browserStreams || []).length > 0 ? browserStreams[0] : null)

  // Every other browser stream is a potential interrupter. Their loudness is
  // watched whenever the plugin is enabled and music exists.
  readonly property var otherStreams: {
    var music = musicNode
    return (browserStreams || []).filter(function (n) { return n !== music })
  }

  PwObjectTracker { objects: root.browserStreams }

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
    lastLoudAt = Date.now()
    if (!duckedNode) duck()
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
    // Best-effort even if the stream already left the list: stream-restore
    // persists mute per application.name, so a mute left behind here would
    // resurrect on every future stream of that app.
    try { if (n && n.audio) n.audio.muted = false } catch (e) {}
  }

  function setEnabled(on) {
    if (enabled === on) return
    if (!on) unduck()
    enabled = on
  }

  function toggle() {
    setEnabled(!enabled)
    return enabled ? "enabled" : "disabled"
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
      var now = Date.now()
      var uncorkedOthers = root.otherStreams.filter(root.isUncorked)
      if (uncorkedOthers.length > 0) root.lastOthersUncorkedAt = now
      if (now - root.lastOthersUncorkedAt > root.stopConfirmMs
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
        browserStreams: root.browserStreams.length,
        watching: root.otherStreams.length
      })
    }
    function enable(): string { root.setEnabled(true); return "enabled" }
    function disable(): string { root.setEnabled(false); return "disabled" }
    function toggle(): string { return root.toggle() }
  }
}
