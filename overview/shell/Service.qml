import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "../app/Wire.js" as Wire

// The state the overview is in, and the two ways it gets there.
//
// `t` is the whole animation: 0 is the desktop as it is, 1 is the overview
// fully open, and every thumbnail's position, size and opacity is a blend of
// the two at `t`. A keypress animates it; a trackpad swipe *sets* it, frame by
// frame, which is why the gesture feels attached to your fingers rather than
// like a button that plays a video.
//
// Hyprland drives the gesture end: app/gesture.lua registers a three-finger
// gesture whose update callback emits a fraction on the event socket, which
// arrives here as a custom event. No compositor plugin, no daemon, nothing to
// rebuild when Hyprland updates.
Item {
  id: service

  property var shell: null
  property var manifest: null

  // Who moves `t`: the fingers, or the spring. All of this is OpenGesture's.
  OpenGesture {
    id: gesture
    // Synchronously: the overlay takes its snapshot on this frame.
    onArmRequested: {
      service.aim()
      service.arming()
      service.refreshModels()
    }
    onLanding: (opening) => service.landing(opening)
  }
  property alias t: gesture.t
  property alias open: gesture.open
  property alias goal: gesture.goal
  property alias scrub: gesture.scrub
  property alias everything: gesture.everything
  property alias scrubFrom: gesture.scrubFrom
  property alias upFingers: gesture.upFingers
  property alias handSpeed: gesture.handSpeed
  property alias lastGoal: gesture.lastGoal
  property alias lastAt: gesture.lastAt
  readonly property alias stretch: gesture.stretch
  readonly property alias chaseSpeed: gesture.chaseSpeed
  readonly property alias landStiffness: gesture.landStiffness
  readonly property alias landDamping: gesture.landDamping
  readonly property alias flickFloor: gesture.flickFloor
  readonly property alias flickSpeed: gesture.flickSpeed
  readonly property alias animating: gesture.animating
  function show() { gesture.show() }
  function hide() { gesture.hide() }
  function toggle() { gesture.toggle() }
  function rubber(value) { return gesture.rubber(value) }
  function track(goal) { gesture.track(goal) }
  function glideTo(wantOpen, velocity) { gesture.glideTo(wantOpen, velocity) }
  function grab() { gesture.grab() }
  function flicked(fraction, speed) { return gesture.flicked(fraction, speed) }

  // Not "visible": Item declares that FINAL, and shadowing it stops the whole
  // plugin loading with "Cannot override FINAL property".
  readonly property bool showing: t > 0.001 || service.deskSlide

  // Three fingers sideways on the bare desktop, sliding between workspaces.
  // The overview is up for it, at no zoom at all: every card standing exactly
  // on its window, the next desktop's alongside, and the spread slides the
  // way it does when the overview is open. See `deskSwipe` below for why
  // this is the plugin's to do rather than Hyprland's.
  property bool deskSlide: false

  // How much of each screen's bottom edge the dock covers, by monitor name,
  // so the desktop dots can sit above it. Bound to the dock by the plugin.
  property var dockCovers: ({})

  // One app's windows only, from every desktop, when the overview was opened
  // for an app (the dock does, on an icon with several windows). Its app id,
  // lower-cased; "" for the ordinary overview.
  property string appOnly: ""

  /** Open on one app's windows: called by the dock, and reachable as
      hl.dsp.event("aerial,app:<appId>"). */
  function showApp(appId) {
    const id = String(appId || "").toLowerCase()
    if (id === "" || service.scrub !== "") return
    service.appOnly = id
    service.everything = false
    if (!service.open) service.show()
  }

  // Which monitor the overview belongs to — the one the pointer was on.
  property string monitorName: ""

  // "Get ready" — raised before `t` leaves zero, so the overlay can take its
  // snapshot of the windows on a frame where nothing is moving yet.
  signal arming()
  // The fingers lifted from an up swipe, and which way it is headed: the
  // notification sheet makes way. See `upFingers` in OpenGesture.qml.
  signal landing(bool opening)

  // Three fingers sideways while the overview is open. The overlay owns the
  // workspaces, so it decides what a sideways swipe means; this only relays it.
  // `phase` is "begin", "move" or "end"; `value` is how many workspaces the
  // fingers have travelled, positive toward the next; `velocity` is the same
  // per second.
  signal sideSwipe(string phase, real value, real velocity, bool cancelled)

  // A shortcut asked for the next (+1) or previous (-1) desktop. The overlay
  // slides there the way a swipe would, overview open or not.
  signal stepRequested(int step)
  // Slide to the desktop a window is on, however far, and focus it there.
  signal jumpRequested(string address)
  // Slide to a desktop by its number (1-10), however far.
  signal deskRequested(int desk)

  /** Called by the dock when you click an app whose one window is on another
      desktop; also reachable as hl.dsp.event("aerial,goto:<address>"). */
  function gotoWindow(address) {
    const key = String(address || "").replace(/^0x/, "")
    // An address and nothing else: it goes into the Lua that Hyprland runs,
    // and any client of its socket can send this event.
    if (!/^[0-9a-fA-F]+$/.test(key)) return
    if (!service.open) {
      if (service.showing || service.scrub !== "") return
      service.beginDeskSlide()
    }
    service.jumpRequested(key)
  }

  /** Slide one desktop over, from a key. Bound in Hyprland as
      hl.dsp.event("aerial,go:next") or "aerial,go:prev", which reaches here
      without starting a process for every keypress. */
  function go(where) {
    const step = where === "next" ? 1 : (where === "prev" ? -1 : 0)
    if (step === 0) return
    if (!service.open) {
      // Mid-swipe, or half open or closed: not now.
      if (service.showing || service.scrub !== "") return
      service.beginDeskSlide()
    }
    service.stepRequested(step)
  }

  /** Slide to desktop n, from a key: SUPER + number with "All screens
      together" on (see app/synced.lua), as hl.dsp.event("aerial,desk:<n>").
      Unlike `go`, never dropped: where the overview cannot slide, the
      overlay switches straight there instead. */
  function desk(n) {
    const d = parseInt(n, 10)
    if (!(d >= 1 && d <= 10)) return
    if (!service.open && !service.showing && service.scrub === "") {
      service.beginDeskSlide()
    }
    service.deskRequested(d)
  }

  // ---------------------------------------------------------------- opening

  /** The overview up at no zoom, to slide: snapshot first, as for a swipe. */
  function beginDeskSlide() {
    service.deskSlide = true
    service.aim()
    service.arming()
    service.refreshModels()
  }

  function aim() {
    service.monitorName = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
  }

  // Ask the compositor what is really there. Quickshell's model is filled from
  // events, and a window that opened while nothing was watching has no
  // geometry and the wrong workspace — which is an empty overview.
  function refreshModels() {
    Hyprland.refreshMonitors()
    Hyprland.refreshWorkspaces()
    Hyprland.refreshToplevels()
    // Settings changed with `hyprctl eval` raise no event; read them again so
    // the cards' blur and glass match what the compositor draws now.
    service.readDecoration()
  }

  // ---------------------------------------------------------------- the swipe

  // app/gesture.lua in Hyprland, and what three fingers sideways mean there. See
  // HyprGestures.qml.
  HyprGestures {
    id: gestures
    sideways: service.sideways
    // A reload put the glass plugin's settings back to their defaults; off
    // was said at once, and on waits for the reload to settle.
    onReloading: if (service.liquidGlass) service.applyGlass()
  }
  readonly property alias gestureFile: gestures.path
  property alias registerAgain: gestures.again
  property alias checksLeft: gestures.checksLeft
  function registerGesture() { gestures.load() }

  readonly property string sideways: service.open || service.deskSwipe ? "slide"
                                   : (!service.showing ? "none" : "")
  property alias sidewaysSent: gestures.sidewaysSent
  function sendSideways() { gestures.sendSideways() }

  // The desktop's own wallpaper, which the overview sits on. See Wallpaper.qml.
  Wallpaper { id: desktopWallpaper }
  property alias wallpaper: desktopWallpaper.path
  readonly property alias backgroundLink: desktopWallpaper.link
  function findTheWallpaper() { desktopWallpaper.resolve() }

  // Where the overview is, for the parts that make way for it.
  readonly property string announced: service.open ? "open"
                                    : service.t > 0.001 ? "showing"
                                    : service.deskSlide ? "sliding" : "hidden"

  onShowingChanged: {
    if (service.showing) return
    // Put away however it went, lift heard or not.
    service.upFingers = -1
    service.findTheWallpaper()
    // Reset once it is fully away, not while it is still closing, or the
    // spread rearranges itself on the way out.
    service.everything = false
    service.appOnly = ""
  }

  // ------------------------------------------------------------ decoration

  // How Hyprland dresses a window. See DecoReader.qml.
  DecoReader { id: decoReader }
  property alias deco: decoReader.deco
  readonly property alias decoOptions: decoReader.options
  function colourOf(entry) { return decoReader.colourOf(entry) }
  function vecOf(entry, i) { return decoReader.vecOf(entry, i) }
  function takeDeco(text) { decoReader.take(text) }
  function readDecoration() { decoReader.read() }

  // Three fingers sideways slide between workspaces, overview open or not.
  //
  // Hyprland has a workspace swipe of its own, and it follows the fingers
  // well enough — but Omarchy turns workspace animations off, so switching
  // with the keyboard is instant, and that leaves the swipe nothing to finish
  // with: let go and the desktop snaps, forward or back, from wherever it was.
  // Turning the animation back on would make every SUPER+number switch slide
  // too. So the swipe on the desktop is this plugin's, finished with the same
  // spring as the overview's, and the keyboard is left alone.
  //
  // Set from the settings panel; false leaves three fingers sideways alone
  // on the desktop.
  property bool deskSwipe: true

  // Frost see-through windows' cards with Hyprland's own blur, live. Set from
  // the settings panel; it costs GPU time while the overview is up.
  property bool frost: true
  // Counts Hyprland's config reloads, for whoever has something to read again.
  property int reloads: 0

  // Liquid glass, set from the settings panel. See GlassControl.qml.
  GlassControl {
    id: glass
    // The cards follow the compositor's glass.
    onFinished: service.readDecoration()
  }
  property alias liquidGlass: glass.want
  property alias glassState: glass.status
  property alias glassError: glass.error
  property alias glassAgain: glass.again
  readonly property alias glassCtl: glass.ctl
  function applyGlass() { glass.apply() }

  // Every screen is one desktop: sliding, or picking one from the strip,
  // switches all of them together. See `synced` in the overlay. Set from the
  // settings panel.
  property bool syncScreens: false

  // Which keeps every screen one desktop as screens come and go.
  Screens { active: service.syncScreens }

  // ---------------------------------------------------------- recording keys

  // The settings panel is listening for a shortcut: Hyprland's bindings are
  // parked in an empty submap meanwhile (see app/gesture.lua), so a combination
  // that is already taken reaches the panel instead of running.
  property bool recording: false

  Process { id: submapLua }

  function setRecording(on) {
    service.recording = on
    submapLua.command = ["/usr/bin/hyprctl", "eval",
                         'hl.dispatch(hl.dsp.submap("' + (on ? "aerial-record" : "reset") + '"))']
    submapLua.running = true
    if (on) recordingLimit.restart()
    else recordingLimit.stop()
  }

  // Never left in the submap: however the panel stops listening — or fails
  // to — the keyboard comes back.
  Timer {
    id: recordingLimit
    interval: 10000
    onTriggered: service.setRecording(false)
  }

  // What the Lua half sends, one fraction at a time.
  function onGesture(data) {
    const wire = Wire.parse(data)
    const what = wire.what
    const rest = wire.rest

    if (what === "shape") {
      // Only ever sent when the Lua half could not find the movement in what
      // Hyprland gave it, which means this plugin needs updating.
      console.warn("aerial: cannot read the swipe — Hyprland's gesture payload is now " + rest)
      return
    }

    if (what === "go") {
      service.go(rest)
      return
    }
    if (what === "desk") {
      service.desk(rest)
      return
    }
    if (what === "app") {
      service.showApp(rest)
      return
    }
    if (what === "goto") {
      service.gotoWindow(rest)
      return
    }

    // "allup-move" is the four-finger version of "up-move", and so on.
    if (what.indexOf("-") < 0) return

    if (wire.who === "side") {
      if (wire.phase === "begin" && !service.open) {
        // Half open or half closed, a sideways swipe means nothing.
        if (service.showing) return
        if (!service.deskSwipe) {
          // It reached us, so Hyprland thinks it is still ours — a shell
          // restarted mid-reload can leave it that way. Hand it back.
          service.sidewaysSent = ""
          service.sendSideways()
          return
        }
        // On the desktop: put the overview up, at no zoom, to slide.
        service.beginDeskSlide()
      }
      service.sideSwipe(wire.phase, wire.raw, wire.velocity, wire.cancelled)
      return
    }
    gesture.handle(wire)
  }

  // ---------------------------------------------------------------- listening

  // Events that change what the overview would show. Refreshing on these keeps
  // the model warm, so opening never has to wait for the compositor to answer.
  readonly property var stirring: [
    "openwindow", "closewindow", "movewindow", "movewindowv2",
    "workspace", "workspacev2", "createworkspace", "createworkspacev2",
    "destroyworkspace", "destroyworkspacev2", "fullscreen",
    "changefloatingmode", "focusedmon", "monitoraddedv2", "monitorremoved",
  ]

  Connections {
    target: Hyprland

    function onRawEvent(event) {
      const name = event.name || ""

      // Left the recording submap some other way (Escape does, in the
      // compositor): stop listening.
      if (name === "submap" && service.recording && event.data !== "aerial-record") {
        service.recording = false
        recordingLimit.stop()
        return
      }

      if (name === "configreloaded") {
        service.reloads++
        // A reload drops runtime gestures the same way it drops runtime binds.
        gestures.loadSoon()
        service.readDecoration()
        // A theme change reloads Hyprland and moves the wallpaper's link, in
        // either order: looked up now and once more when it has settled, so the
        // first overview after it is not on the last theme's wallpaper.
        service.findTheWallpaper()
        wallpaperSettle.restart()
        // And it puts the glass plugin's options back to their defaults. Its
        // default is on, so a loaded plugin is told right away that the glass
        // is off, rather than showing for as long as `loadSoon` waits.
        if (!service.liquidGlass) service.applyGlass()
        return
      }

      // hl.dsp.event("aerial,…") arrives as custom>>aerial,…
      const data = event.data || ""
      if (name === "aerial") {
        service.onGesture(data)
        return
      }
      if (name === "custom" && data.startsWith("aerial,")) {
        service.onGesture(data.slice(7))
        return
      }

      if (service.stirring.indexOf(name) >= 0) freshen.restart()
    }
  }

  Timer { id: wallpaperSettle; interval: 2500; onTriggered: if (!service.showing) service.findTheWallpaper() }

  Timer {
    id: freshen
    interval: 180
    onTriggered: service.refreshModels()
  }

  Component.onCompleted: {
    service.registerGesture()
    service.findTheWallpaper()
    service.readDecoration()
  }
}
