import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

// Autoduck: while a browser tab is playing music, mute it whenever a second
// browser tab starts producing audio, and unmute it once that audio stops.
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
  // How long the other tab must stay silent before music resumes.
  property int resumeDelayMs: 2000

  // --- State ------------------------------------------------------------
  property bool enabled: true
  property var duckedNode: null
  readonly property bool ducked: duckedNode !== null

  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []

  // Browser playback streams, bound so their properties and audio state
  // stay live and audio.muted is writable.
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

  PwObjectTracker { objects: root.browserStreams }

  function serialOf(node) {
    var serial = Number((node.properties || {})["object.serial"])
    return isNaN(serial) ? Number(node.id || 0) : serial
  }

  // A stream that exists but is corked (paused media element) is not
  // producing audio; only uncorked streams matter.
  function isAudible(node) {
    if (!node || !node.ready) return false
    var corked = (node.properties || {})["pulse.corked"]
    return !(corked === true || corked === "true")
  }

  function audibleStreams() {
    return (browserStreams || []).filter(isAudible)
  }

  function nodeAlive(node) {
    return node !== null && (browserStreams || []).indexOf(node) !== -1
  }

  function evaluate() {
    if (!enabled) return

    if (duckedNode && !nodeAlive(duckedNode)) {
      // Music tab was closed or its stream ended while ducked.
      duckedNode = null
      resumeTimer.stop()
    }

    var active = audibleStreams()

    if (duckedNode) {
      var others = active.filter(function (n) { return n !== duckedNode })
      if (others.length === 0) {
        if (!resumeTimer.running) resumeTimer.start()
      } else {
        resumeTimer.stop()
      }
      return
    }

    // Two browser tabs audible at once: the older stream is the background
    // music, the newer one is what the user just started watching.
    if (active.length >= 2) {
      var music = active[0]
      if (music.audio) {
        music.audio.muted = true
        duckedNode = music
      }
    }
  }

  function unduck() {
    if (duckedNode && nodeAlive(duckedNode) && duckedNode.audio)
      duckedNode.audio.muted = false
    duckedNode = null
    resumeTimer.stop()
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

  onNodesChanged: evaluate()
  Component.onDestruction: unduck()

  Timer {
    id: resumeTimer
    interval: root.resumeDelayMs
    repeat: false
    onTriggered: {
      var others = root.audibleStreams().filter(function (n) { return n !== root.duckedNode })
      if (others.length === 0) root.unduck()
    }
  }

  // pulse.corked changes don't retrigger declarative bindings reliably, so
  // poll cheaply (in-process property reads) while browser audio exists.
  Timer {
    interval: 1000
    repeat: true
    running: root.enabled && (root.browserStreams.length > 0 || root.ducked)
    onTriggered: root.evaluate()
  }

  IpcHandler {
    target: "autoduck"

    function status(): string {
      return JSON.stringify({
        enabled: root.enabled,
        ducked: root.ducked,
        browserStreams: root.browserStreams.length,
        audible: root.audibleStreams().length
      })
    }
    function enable(): string { root.setEnabled(true); return "enabled" }
    function disable(): string { root.setEnabled(false); return "disabled" }
    function toggle(): string { return root.toggle() }
  }
}
