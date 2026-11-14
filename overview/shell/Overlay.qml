import QtQuick
import Quickshell
import Quickshell.Hyprland
import "../../look" as Looks

// The overview: every window, live, spread out — one surface per screen.
//
// Nothing here is a screenshot. Each thumbnail is a ScreencopyView of the real
// toplevel, so a video keeps playing and a terminal keeps scrolling while you
// look for it.
//
// This half holds what all the screens share, in parts of its own: DeskMap,
// CaptureClock, DeskRoster, WindowSnapshot, DragState, Interaction, SlideController.
// What is left here is the shell's contract, how far open the overview is, and the
// order things happen in as it opens and closes. Surface.qml draws one screen's
// worth, and reaches everything by name on this object, which is why every part's
// public members are forwarded below.
Scope {
  id: root

  // How it looks: see look/Look.qml.
  Looks.ActiveLook {
    id: activeLook
    service: root.service
  }
  readonly property alias look: activeLook

  // The shell hands these to an overlay when it loads it. The service may not
  // exist yet when the overlay does, so it is looked up again until it does.
  property var shell: null
  property var manifest: null
  property var service: null
  // The shell injects this plugin's whole service here; the overview is one part of it.
  onServiceChanged: if (root.service && root.service.overview) root.service = root.service.overview

  function findService() {
    if (root.service || !root.shell || typeof root.shell.serviceFor !== "function") return
    const found = root.shell.serviceFor(root.manifest ? root.manifest.id : "quokecola.omardeck")
    // Looked up mid-construction, the service is there before its parts are.
    root.service = found && found.overview ? found.overview : null
  }

  onShellChanged: root.findService()

  Timer {
    interval: 800
    repeat: true
    running: !root.service
    triggeredOnStart: true
    onTriggered: root.findService()
  }

  // What the shell calls when something asks for the overview by name.
  function open(payload) { if (root.service) root.service.show() }
  function close() { if (root.service) root.service.hide() }
  function toggle() { if (root.service) root.service.toggle() }

  function dismiss() { if (root.service) root.service.hide() }

  readonly property bool opened: root.service ? root.service.showing : false
  // Where the overview is drawn: `t`, held at nothing until the overview is
  // ready to appear, then let catch up. The fingers have moved on by the
  // time every capture is in, and appearing where they now are would be a
  // jump; appearing exactly on the desktop and catching up is not.
  property real reveal: 0
  readonly property real t: root.settleIn((root.service ? root.service.t : 0) * root.reveal)

  // Within the last few percent of closed, eased the rest of the way down to
  // exactly nothing. The overview is put away once `t` is all but zero, and a
  // card even a thousandth of the way to its slot is a pixel or two off its
  // window — which, on the frame the window takes back over, is a twitch.
  // Continuous with `t` above the knee, so nothing jumps.
  readonly property real knee: 0.03
  function settleIn(v) { return v < root.knee ? v * v / root.knee : v }

  NumberAnimation {
    id: revealing
    target: root
    property: "reveal"
    to: 1
    duration: 40
    easing.type: Easing.OutCubic
  }

  /** The overview is on screen, matching the desktop exactly: start moving. */
  function revealed() { if (root.reveal < 1 && !revealing.running) revealing.restart() }
  readonly property bool active: root.service ? root.service.open : false
  // `t` is changing every frame, and cards must follow it, not ease after it.
  readonly property bool settling: root.service ? root.service.animating : false
  readonly property bool everything: root.service ? root.service.everything : false
  readonly property string leadMonitor: root.service ? root.service.monitorName : ""
  readonly property string appOnly: root.service ? root.service.appOnly : ""

  // ------------------------------------------------- every screen as one desktop

  DeskMap {
    id: deskMap
    overlay: root
    service: root.service
  }
  readonly property alias synced: deskMap.synced
  readonly property alias screenOrder: deskMap.screenOrder
  readonly property alias focusedDesk: deskMap.focusedDesk
  readonly property alias deskSwitching: deskMap.deskSwitching
  function deskOfId(id) { return deskMap.deskOfId(id) }
  function spaceOn(desk, monitorName) { return deskMap.spaceOn(desk, monitorName) }
  function switchDesk(desk, address) { deskMap.switchDesk(desk, address) }
  function everyScreenOn(desk) { return deskMap.everyScreenOn(desk) }

  // The real windows stay mapped underneath, so the veil is what hides them. It
  // ramps faster than `t`: by the time a thumbnail has visibly moved off its
  // window, the window it came from is already gone.
  readonly property real veil: Math.pow(Math.min(1, Math.max(0, root.t)), 0.65)

  readonly property string wallpaper: root.service ? root.service.wallpaper : ""
  readonly property var deco: root.service ? root.service.deco : ({ rounding: 0, border: 0, shadow: false })
  readonly property bool frost: root.service ? root.service.frost : true

  // How far the cards have left the windows they stand in for, for crossfading
  // Hyprland's look (rounding, border, shadow) into the overview's. Done by
  // the time the spread is half out, so the windows read as cards, not as
  // shrinking desktops.
  readonly property real dress: Math.min(1, Math.max(0, root.t / 0.6))
  readonly property url wallpaperUrl: root.wallpaper ? Qt.resolvedUrl("file://" + root.wallpaper) : ""

  CaptureClock {
    id: captureClock
    overlay: root
  }
  readonly property alias beat: captureClock.beat
  readonly property alias priming: captureClock.priming
  readonly property alias still: captureClock.still
  function prime() { captureClock.prime() }
  onTChanged: captureClock.followT()

  // ------------------------------------------------------------- what is there

  WindowSnapshot {
    id: windowSnapshot
    overlay: root
  }
  property alias shot: windowSnapshot.shot
  property alias moved: windowSnapshot.moved
  property alias movedScreen: windowSnapshot.movedScreen
  readonly property alias geo: windowSnapshot.geo
  readonly property alias rects: windowSnapshot.rects
  readonly property alias livePlans: windowSnapshot.livePlans
  readonly property alias zOrder: windowSnapshot.zOrder
  function kept(old, fresh) { return windowSnapshot.kept(old, fresh) }
  function isActive(top) { return windowSnapshot.isActive(top) }
  function screenOf(win) { return windowSnapshot.screenOf(win) }
  function spaceOf(win) { return windowSnapshot.spaceOf(win) }
  function wsOf(win) { return windowSnapshot.wsOf(win) }

  function sync() {
    root.forgetRealDesks()
    windowSnapshot.take()
    root.workspaces = root.liveWorkspaces()
    if (root.stageId <= 0 && root.focusedDesk > 0) root.stageId = root.focusedDesk
    // And a fresh frame of each, now: the one they kept is from last time.
    root.prime()

    // Start on the window you were already using, so pressing enter straight
    // away puts you back rather than nowhere.
    if (root.selectedKey === "") {
      const active = root.shot.find(w => root.geo[w.key] && root.geo[w.key].active)
      if (active) root.selectedKey = active.key
    }
  }

  function forget() {
    // Not the snapshot: the cards stay, ready for next time.
    root.workspaces = []
    root.selectedKey = ""
    root.dragKey = ""
    root.dragTarget = -1
    root.dropOnKey = ""
    root.dragScreen = ""
    root.arrival = null
    root.filter = ""
    root.peek = -1
    root.peekWanted = -1
    root.noPeekId = -1
    root.flown = ({})
    slideController.reset()
  }

  Connections {
    target: root.service
    function onArming() { root.sync() }
    function onSideSwipe(phase, value, velocity, cancelled) { root.onSide(phase, value, velocity, cancelled) }
    function onJumpRequested(address) { root.jumpToWindow(address) }
    function onDeskRequested(desk) { root.jumpToDesk(desk) }
    function onStepRequested(step) { slideController.step(step) }
  }

  onOpenedChanged: if (!root.opened) {
    revealing.stop()
    root.reveal = 0
    root.forget()
  }

  // A window that has just been sent elsewhere or closed should leave the
  // spread, but only once the compositor has confirmed it.
  Timer {
    id: resettle
    interval: 220
    onTriggered: if (root.opened) root.sync()
  }

  function resettleSoon() { resettle.restart() }

  // ------------------------------------------------------------- what you did

  Interaction {
    id: interaction
    overlay: root
    service: root.service
  }
  property alias selectedKey: interaction.selectedKey
  property alias filter: interaction.filter
  property alias peek: interaction.peek
  property alias peekWanted: interaction.peekWanted
  property alias noPeekId: interaction.noPeekId
  property alias leadSurface: interaction.leadSurface
  function endPeek() { interaction.endPeek() }
  function hoverWorkspace(id, entered) { interaction.hoverWorkspace(id, entered) }
  function matches(win) { return interaction.matches(win) }
  function iconFor(appId) { return interaction.iconFor(appId) }
  function appNameFor(appId) { return interaction.appNameFor(appId) }
  function focusWindow(address) { interaction.focusWindow(address) }
  function goToWorkspace(id, monitorName) { interaction.goToWorkspace(id, monitorName) }
  function leadTo(name) { interaction.leadTo(name) }
  function hoverFocus(key) { interaction.hoverFocus(key) }
  function closeWindow(address) { interaction.closeWindow(address) }
  function onKey(event) { interaction.onKey(event) }

  // The pointer can reach another screen while the overview is still on its
  // way up, when following it (see Interaction) does not count. Once open, catch up: only the
  // leading screen takes the keyboard, and Hyprland gives the pointer to no
  // other surface while one has it exclusively, so the screen you went to
  // ignored the pointer altogether.
  onActiveChanged: if (root.active && Hyprland.focusedMonitor) root.leadTo(Hyprland.focusedMonitor.name)

  DragState {
    id: dragState
    overlay: root
    service: root.service
  }
  property alias dragKey: dragState.dragKey
  property alias dragTarget: dragState.dragTarget
  property alias dropOnKey: dragState.dropOnKey
  property alias dragScreen: dragState.dragScreen
  property alias dragHome: dragState.dragHome
  property alias dragRect: dragState.dragRect
  property alias dragCapture: dragState.dragCapture
  property alias dragOpacity: dragState.dragOpacity
  property alias arrival: dragState.arrival
  property alias flown: dragState.flown
  readonly property alias surfaces: dragState.surfaces
  function setFlown(key, on) { dragState.setFlown(key, on) }
  function enrol(surface, name) { dragState.enrol(surface, name) }
  function surfaceAt(gx, gy) { return dragState.surfaceAt(gx, gy) }
  function aimDrag(workspaceId, cardKey) { dragState.aimDrag(workspaceId, cardKey) }
  function drop(address) { return dragState.drop(address) }

  // ------------------------------------------------------ sliding sideways

  SlideController {
    id: slideController
    overlay: root
    service: root.service
  }
  property alias stageId: slideController.stageId
  readonly property alias stageWorkspace: slideController.stageWorkspace
  readonly property alias lanes: slideController.lanes
  readonly property alias stageIndex: slideController.stageIndex
  readonly property alias slide: slideController.slide
  readonly property alias shownSlide: slideController.shownSlide
  readonly property alias moving: slideController.moving
  // Fingers down on a slide.
  readonly property alias sliding: slideController.sliding
  readonly property alias canSlide: slideController.canSlide
  readonly property alias deskSliding: slideController.deskSliding
  function laneOf(workspaceId) { return slideController.laneOf(workspaceId) }
  function laneTile(position) { return slideController.laneTile(position) }
  function onSide(phase, value, velocity, cancelled) { slideController.onSide(phase, value, velocity, cancelled) }
  function slideBy(step) { slideController.slideBy(step) }
  function jumpToDesk(desk) { slideController.jumpToDesk(desk) }
  function jumpToWindow(address) { slideController.jumpToWindow(address) }
  function endDeskSlide() { slideController.endDeskSlide() }
  onRevealChanged: slideController.followReveal()

  DeskRoster {
    id: deskRoster
    overlay: root
    onDeskAdded: (id, grew) => root.deskAdded(id, grew)
  }
  property alias workspaces: deskRoster.workspaces
  readonly property alias justAdded: deskRoster.justAdded
  signal deskAdded(int id, int grew)
  function liveWorkspaces() { return deskRoster.liveWorkspaces() }
  function forgetRealDesks() { deskRoster.forgetRealDesks() }
  function addWorkspace(id) { deskRoster.addWorkspace(id) }
  // Here, with the overlay's other listeners: see `lastDesk`, which is a binding on
  // this same property until the first time this runs.
  onFocusedDeskChanged: deskRoster.followDesk()

  // One overview per screen. A second monitor that merely dimmed while you look
  // for a window on it would be worse than not covering it at all.
  Variants {
    model: Quickshell.screens

    delegate: Surface {
      required property var modelData
      overlay: root
      screenInfo: modelData
      onLeadingChanged: if (leading) root.leadSurface = this
      Component.onCompleted: {
        if (leading) root.leadSurface = this
        root.enrol(this, monitorName)
      }
      Component.onDestruction: root.enrol(null, monitorName)
    }
  }
}
