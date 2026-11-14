import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/quokecola.omardeck/overview/shell" as O

// Drives the Overlay's own behaviour on a private X server and reads back what it
// told the fake compositor: sliding, jumps, dragging, the selection, the snapshot.
// No frames here (the overlay suite has those). Spring timing is wall-clock, so
// everything waits for an outcome rather than a time.
ShellRoot {
  id: root

  O.Service { id: s }
  O.Overlay { id: overlay; service: s }

  // Every member the Surface and the look's slot files read from the overlay. The
  // Surface reaches all of these by name, in a `var`, so nothing else would notice
  // one going missing until its binding ran.
  readonly property var members: [
    "active", "appOnly", "arrival", "beat", "deco", "deskSliding", "dragCapture", "dragHome", "dragKey", "dragOpacity",
    "dragRect", "dragScreen", "dragTarget", "dress", "dropOnKey", "everything", "filter", "flown", "focusedDesk", "frost",
    "geo", "justAdded", "lanes", "leadMonitor", "livePlans", "look", "moving", "opened", "peek", "priming", "rects",
    "selectedKey", "service", "settling", "shot", "shownSlide", "slide", "stageIndex", "stageWorkspace", "still",
    "surfaces", "synced", "t", "veil", "wallpaper", "wallpaperUrl", "workspaces", "zOrder",
  ]
  readonly property var methods: [
    "aimDrag", "closeWindow", "deskOfId", "dismiss", "drop", "focusWindow", "goToWorkspace", "hoverFocus", "hoverWorkspace",
    "iconFor", "kept", "laneOf", "laneTile", "matches", "onKey", "revealed", "screenOf", "setFlown", "spaceOn", "surfaceAt", "wsOf",
  ]

  property var failures: []
  function check(ok, what) {
    if (ok) return
    root.failures.push(what)
    console.log("  FAIL " + what)
  }
  function same(a, b, what) {
    const x = JSON.stringify(a), y = JSON.stringify(b)
    root.check(x === y, what + ": got " + x + ", wanted " + y)
  }

  FileView { id: logFile; path: "/tmp/hypr.log"; blockLoading: true; printErrors: false }
  property int logMark: 0
  function logLines() {
    logFile.reload()
    logFile.waitForJob()
    return logFile.text().split("\n")
  }
  function mark() { root.logMark = root.logLines().length - 1 }
  /** What was asked since mark(): how many lines hold `pattern`. */
  function asked(pattern) {
    return root.logLines().slice(root.logMark).filter(l => l.indexOf(pattern) >= 0).length
  }
  // Dispatches and hyprctl runs arrive when they arrive: this waits for `count` of
  // them before the next step, and then says whether there are more than that.
  property var expects: []
  function expect(pattern, count, what) {
    root.expects.push({ pattern: pattern, count: count, what: what, from: root.logMark })
  }
  function settleExpects(giveUp) {
    const lines = root.logLines()
    root.expects = root.expects.filter(e => {
      const got = lines.slice(e.from).filter(l => l.indexOf(e.pattern) >= 0).length
      if (got < e.count && !giveUp) return true
      root.same(got, e.count, e.what)
      return false
    })
    return root.expects.length === 0
  }

  readonly property var surface: {
    const all = Object.keys(overlay.surfaces)
    return all.length ? overlay.surfaces[all[0]] : null
  }

  function windows() {
    const name = root.surface.monitorName
    return [
      { key: "a1", capture: null, top: null, title: "term", appId: "foot", workspace: 1, monitor: name,
        active: true, floating: false, x: 12, y: 42, w: 780, h: 940 },
      { key: "a2", capture: null, top: null, title: "files", appId: "org.gnome.Nautilus", workspace: 1, monitor: name,
        active: false, floating: true, x: 806, y: 42, w: 780, h: 940 },
      { key: "a3", capture: null, top: null, title: "web", appId: "chromium", workspace: 2, monitor: name,
        active: false, floating: false, x: 12, y: 42, w: 1576, h: 940 },
    ]
  }

  function key(code, modifiers, text) {
    const event = { key: code, modifiers: modifiers || 0, text: text || "", accepted: false }
    overlay.onKey(event)
    return event.accepted
  }

  readonly property bool atRest: !overlay.moving && overlay.slide === 0

  property var beats: []
  Connections {
    target: overlay
    function onBeatChanged() { root.beats.push(overlay.priming) }
  }

  property var added: []
  Connections {
    target: overlay
    function onDeskAdded(id, grew) { root.added.push([id, grew]) }
  }

  property var geoBefore: null
  property var rectsBefore: null
  property int waited: 0
  function waitTicks(n) {
    root.waited = 0
    return () => ++root.waited > n
  }

  QtObject {
    id: fakeScreen
    property var monitor: null
    property int width: 0
    property int height: 0
    property int shownWorkspace: 7
  }

  // switchDesk and focusQuietly, as Hyprland gets them.
  function quiet(body) {
    return JSON.stringify("local w = hl.get_config('cursor.no_warps'); hl.config({ cursor = { no_warps = true } }); "
                          + body + "hl.config({ cursor = { no_warps = w } })")
  }

  // Each step: do something, and return what to wait for, if anything.
  readonly property var steps: [
    () => {
      for (const name of root.members) root.check(overlay[name] !== undefined, "overlay." + name + " is there")
      for (const name of root.methods) root.same(typeof overlay[name], "function", "overlay." + name)
      s.onGesture("up-begin")
      s.onGesture("up-move:0.9000")
      s.onGesture("up-end:0.9000:0.1000:0:0.5000")
      return () => root.surface !== null && s.open && overlay.reveal === 1 && root.surface.ready
    },
    () => {
      overlay.shot = root.windows()
      return () => overlay.still
    },

    // The snapshot's live half: what `hyprctl` said about each window, as asked at
    // arming. `shadow` comes from no_shadow, true for a1 in the fixtures and false
    // for a2. The opacities: a rule's value times the decoration's, unless overridden.
    () => {
      root.same(overlay.zOrder, { a1: 0, a2: 1, a3: 2 }, "stacking, from clients")
      root.same(overlay.geo.a1 && overlay.geo.a1.shadow, false, "geo has the opt-out from a shadow")
      root.same(overlay.geo.a2 && overlay.geo.a2.shadow, true, "geo has the shadow")
      root.check(Math.abs(overlay.geo.a1.opacity - 0.9 * 0.95) < 1e-6, "focused opacity, " + overlay.geo.a1.opacity)
      root.check(Math.abs(overlay.geo.a2.opacity - 0.8 * 0.9) < 1e-6, "unfocused opacity, " + overlay.geo.a2.opacity)
      root.check(Math.abs(overlay.geo.a3.opacity - 0.6) < 1e-6, "overriding opacity, " + overlay.geo.a3.opacity)
      root.same(overlay.rects.a2, { x: 806, y: 42, w: 780, h: 940 }, "rects")
      root.same((overlay.livePlans[1] || []).length, 2, "the plan of a desktop")
      root.same(overlay.focusedDesk, 1, "focused desk")
      root.same(overlay.lanes, [1, 2, 3, 4, 5], "lanes")
      root.same(overlay.stageIndex, 0, "stage index")
      root.same(overlay.laneOf(2), 1, "lane of the next desktop")
      root.same(overlay.laneOf(99), 99, "lane of nothing")
      root.same(overlay.laneTile(1.5), 1.5, "tile for a lane position")
      root.same(overlay.spaceOn(3, "screen"), 3, "a desktop is its workspace, apart")
      root.same(overlay.deskOfId(13), 13, "and a workspace its desktop")
      overlay.selectedKey = "a1"
      root.geoBefore = overlay.geo
      root.rectsBefore = overlay.rects
      root.mark()
      overlay.sync()
      return root.waitTicks(20)
    },
    // Asked again and told the same, nothing changed identity, so nothing reruns.
    () => {
      root.check(root.asked("--batch") > 0, "asked for alphas at sync")
      root.check(root.asked("getprop address:0xa1 no_shadow") > 0, "and for who has a shadow")
      root.check(overlay.geo === root.geoBefore, "geo kept its identity across a sync")
      root.check(overlay.rects === root.rectsBefore, "rects kept its identity across a sync")
      root.same(overlay.selectedKey, "a1", "selection survives a sync")
      // A sync here finds no windows, there being no Wayland: put them back.
      overlay.shot = root.windows()
      root.beats = []
      overlay.prime()
      root.same(root.beats, [true], "prime is a priming beat")
      root.same(overlay.priming, false, "and over at once")
    },

    // A beat every 80ms, at rest. None in a slide.
    () => {
      root.beats = []
      return root.waitTicks(25)
    },
    () => {
      root.check(root.beats.length >= 3, "beats at rest, " + root.beats.length)
      root.same(root.beats.indexOf(true), -1, "not priming beats")

      // A short swipe springs back and tells nobody.
      root.mark()
      s.sideSwipe("begin", 0, 0, false)
      root.check(overlay.moving, "moving, fingers down")
      root.check(!overlay.still, "not still, fingers down")
      root.beats = []
      s.sideSwipe("move", 0.2, 0, false)
      return root.waitTicks(8)
    },
    () => {
      root.same(root.beats, [], "no beats mid-slide")
      root.check(overlay.slide > 0 && overlay.slide <= 0.2, "follows the fingers, " + overlay.slide)
      s.sideSwipe("end", 0, 0, false)
      return () => root.atRest
    },
    () => {
      root.same(overlay.stageWorkspace, 1, "a short swipe goes back")
      root.same(root.asked("hl.dsp.focus"), 0, "and says nothing")

      // Cancelled goes back from any distance.
      s.sideSwipe("begin", 0, 0, false)
      s.sideSwipe("move", 0.8, 0, false)
      s.sideSwipe("end", 0, 9, true)
      return () => root.atRest
    },
    () => {
      root.same(overlay.stageWorkspace, 1, "a cancelled swipe goes back")
      root.same(root.asked("hl.dsp.focus"), 0, "and says nothing")

      // Past the first desktop it gives, and no more.
      s.sideSwipe("begin", 0, 0, false)
      s.sideSwipe("move", -5, 0, false)
      return root.waitTicks(15)
    },
    () => {
      root.check(overlay.slide < 0 && overlay.slide > -0.3, "stretch stops short, " + overlay.slide)
      s.sideSwipe("end", 0, 0, false)
      return () => root.atRest
    },

    // Past half way, it lands: stage, selection, compositor.
    () => {
      root.same(overlay.stageWorkspace, 1, "stretch came back")
      root.mark()
      s.sideSwipe("begin", 0, 0, false)
      s.sideSwipe("move", 0.7, 0, false)
      s.sideSwipe("end", 0, 0, false)
      return () => root.atRest && overlay.stageWorkspace === 2
    },
    () => {
      root.expect('hl.dsp.focus({ workspace = "2" })', 1, "told to go to desktop 2")
      root.same(overlay.selectedKey, "a3", "selection came along")
      root.same(overlay.stageIndex, 1, "stage index")

      // The keyboard, back.
      root.mark()
      root.check(root.key(Qt.Key_Left, Qt.ControlModifier), "ctrl+left taken")
      return () => root.atRest && overlay.stageWorkspace === 1
    },
    () => {
      root.expect('hl.dsp.focus({ workspace = "1" })', 1, "told to go to desktop 1")

      // Over two desktops in one trip.
      root.mark()
      overlay.jumpToDesk(3)
      return () => root.atRest && overlay.stageWorkspace === 3
    },
    () => {
      root.expect('hl.dsp.focus({ workspace = "3" })', 1, "jumped to desktop 3")

      // Onto a window on another desktop.
      root.mark()
      overlay.jumpToWindow("a3")
      return () => root.atRest && overlay.stageWorkspace === 2
    },
    () => {
      root.expect('hl.dsp.focus({ workspace = "2" })', 1, "jumped to that window's desktop")
      root.expect('hl.dsp.focus({ window = "address:0xa3" })', 1, "and focused it")

      // Asked of the service.
      s.stepRequested(-1)
      return () => root.atRest && overlay.stageWorkspace === 1
    },

    // All screens together: the Lua, exactly.
    () => {
      s.syncScreens = true
      root.mark()
      overlay.jumpToDesk(2)
      return () => root.atRest && overlay.stageWorkspace === 2 && !overlay.deskSwitching
    },
    () => {
      root.same(overlay.synced, true, "synced")
      root.same(overlay.spaceOn(3, "screen"), 3, "first screen's block")
      root.same(overlay.spaceOn(3, "nowhere"), 3, "unknown screen")
      root.same(overlay.deskOfId(13), 3, "a workspace's desktop")
      root.expect(root.quiet("hl.dispatch(hl.dsp.focus({ monitor = 'screen' })); "
                                      + "hl.dispatch(hl.dsp.focus({ workspace = '2', on_current_monitor = true })); "),
                  1, "switchDesk's Lua")
      root.mark()
      overlay.jumpToWindow("a1")
      return () => root.atRest && overlay.stageWorkspace === 1 && !overlay.deskSwitching
    },
    () => {
      root.expect(root.quiet("hl.dispatch(hl.dsp.focus({ monitor = 'screen' })); "
                                      + "hl.dispatch(hl.dsp.focus({ workspace = '1', on_current_monitor = true })); "
                                      + "hl.dispatch(hl.dsp.focus({ window = 'address:0xa1' })); "),
                  1, "switchDesk's Lua, with a window")
      s.syncScreens = false
      overlay.selectedKey = "a1"

      // Pointing at a window focuses it, quietly.
      root.mark()
      overlay.hoverFocus("a2")
      return root.waitTicks(10)
    },
    () => {
      root.expect(root.quiet("hl.dispatch(hl.dsp.focus({ window = 'address:0xa2' })); "), 1, "focusQuietly's Lua")

      // Peeking, and picking a window up ending it.
      overlay.hoverWorkspace(2, true)
      return () => overlay.peek === 2
    },
    () => {
      overlay.hoverWorkspace(2, false)
      root.same(overlay.peek, -1, "leaving the tile ends the peek")
      overlay.hoverWorkspace(3, true)
      return () => overlay.peek === 3
    },
    () => {
      overlay.dragKey = "a1"
      root.same(overlay.peek, -1, "a drag ends the peek")
      overlay.hoverWorkspace(2, true)
      return root.waitTicks(12)
    },
    () => {
      root.same(overlay.peek, -1, "no peeking with a window in hand")

      // Let go on a tile.
      root.mark()
      overlay.aimDrag(3, "a2")
      root.same(overlay.dragTarget, 3, "aimed at the tile")
      root.same(overlay.dropOnKey, "", "a tile wins over a card")
      overlay.selectedKey = "a1"
      root.same(overlay.drop("a1"), true, "dropped on a tile")
      overlay.dragKey = ""
      root.expect('hl.dsp.window.move({ window = "address:0xa1", workspace = "3", follow = false })', 1, "moved, not followed")
      root.same(overlay.wsOf(overlay.shot[0]), 3, "the overview knows at once")
      root.same(overlay.selectedKey, "", "nothing left selected")
      root.same(overlay.dragTarget, -1, "aim reset")

      // Let go on another window.
      root.mark()
      overlay.aimDrag(-1, "a2")
      root.same(overlay.dropOnKey, "a2", "aimed at a card")
      root.same(overlay.drop("a3"), true, "dropped on a window")
      root.expect('hl.dsp.window.swap({ window = "address:0xa3", target = "address:0xa2" })', 1, "swapped")

      // Let go on nothing.
      overlay.aimDrag(-1, "")
      root.same(overlay.drop("a2"), false, "dropped on nothing")
      root.same(overlay.drop(""), false, "dropped nothing")

      // Other screens.
      root.check(overlay.surfaceAt(10, 10) === root.surface, "surface under a point")
      root.check(overlay.surfaceAt(99999, 10) === null, "and none off screen")
      overlay.setFlown("a2", true)
      root.same(overlay.flown, { a2: true }, "flown")
      overlay.setFlown("a2", false)
      root.same(overlay.flown, {}, "landed")

      // Typing: what enter will act on follows, and escape clears it first.
      overlay.shot = root.windows()
      overlay.selectedKey = "a1"
      root.check(overlay.matches(overlay.shot[1]), "no filter, matches")
      for (const c of "file") root.key(c.toUpperCase().charCodeAt(0), 0, c)
      root.same(overlay.filter, "file", "typed")
      root.same(overlay.matches(overlay.shot[0]), false, "filtered out")
      root.check(overlay.matches(overlay.shot[1]), "filtered in")
      root.key(Qt.Key_W, 0, "w")
      root.same(overlay.filter, "filew", "a plain w is a letter")
      root.key(Qt.Key_Backspace)
      root.same(overlay.filter, "file", "backspace")
      root.same(root.key(Qt.Key_Escape), true, "escape taken")
      root.same(overlay.filter, "", "escape clears it")
      root.same(root.key(Qt.Key_F1), false, "a key that means nothing is passed on")
      root.check(s.open, "escape only cleared")

      // Closing a window.
      overlay.selectedKey = "a2"
      root.mark()
      root.key(Qt.Key_W, Qt.ControlModifier)
      root.same(overlay.selectedKey, "", "closed: unselected")
      root.expect('hl.dsp.window.close({ window = "address:0xa2" })', 1, "closed")

      // The "+" tile adds a desktop and stays open.
      const fresh = overlay.workspaces.find(w => w.fresh)
      root.same(fresh && fresh.id, 6, "a + tile")
      overlay.goToWorkspace(6, "")
      root.same(root.added, [[6, 1]], "added, and the strip grew by one")
      root.same(overlay.justAdded, 6, "just added")
      root.same(overlay.lanes, [1, 2, 3, 4, 5, 6], "a desktop to slide to")
      root.check(s.open, "the overview stayed")
      root.same(overlay.iconFor("no/such/icon"), "", "a path is no icon name")
      return () => overlay.justAdded === -1
    },

    // Over a stand-in second screen: a card crossing, then its arrival.
    () => {
      overlay.selectedKey = "a1"
      overlay.shot = root.windows()
      overlay.enrol(fakeScreen, "elsewhere")
      root.mark()
      overlay.aimDrag(-1, "")
      overlay.dragScreen = "elsewhere"
      overlay.dragRect = Qt.rect(1, 2, 3, 4)
      root.same(overlay.drop("a1"), true, "dropped on another screen")
      root.expect('hl.dsp.window.move({ window = "address:0xa1", workspace = "7", follow = false })', 1, "to what that screen shows")
      root.same(overlay.arrival && overlay.arrival.screen, "elsewhere", "arriving there")
      // Before `resettle` runs sync, which here (no Wayland) finds no windows.
      const carried = overlay.shot[0]
      return () => overlay.screenOf(carried) === "elsewhere"
    },
    () => {
      root.same(overlay.leadMonitor, "elsewhere", "the work went with it")
      overlay.enrol(null, "elsewhere")
      return () => overlay.arrival === null
    },
    () => {
      s.monitorName = root.surface.monitorName
      overlay.shot = root.windows()

      // Enter: the selection, focused and closed on, and focused again after.
      overlay.selectedKey = "a2"
      root.mark()
      root.key(Qt.Key_Return)
      root.expect('hl.dsp.focus({ window = "address:0xa2" })', 1, "enter focuses the selection")
      return () => !s.showing
    },
    () => root.waitTicks(10),
    () => {
      root.expect('hl.dsp.focus({ window = "address:0xa2" })', 2, "and again once the surface lets go")
      // Everything an opening leaves behind is gone.
      root.same(overlay.workspaces, [], "strip")
      root.same(overlay.selectedKey, "", "selection")
      root.same(overlay.dragKey, "", "drag")
      root.same(overlay.filter, "", "filter")
      root.same(overlay.peek, -1, "peek")
      root.same(overlay.flown, {}, "flown")
      root.same(overlay.slide, 0, "slide")
      root.same(overlay.stageWorkspace, overlay.focusedDesk, "stage")
      root.same(overlay.shot.length, 3, "but the cards stay")
    },
  ]

  property int at: 0
  property var waitingFor: null
  property int patience: 0
  Timer {
    interval: 20
    repeat: true
    running: true
    onTriggered: {
      if (root.waitingFor) {
        if (!root.waitingFor()) {
          if (++root.patience < 300) return
          root.check(false, "step " + root.at + " never got there")
        }
        root.waitingFor = null
      }
      if (root.expects.length > 0 && !root.settleExpects(root.patience >= 300)) {
        root.patience++
        return
      }
      if (root.at >= root.steps.length) {
        running = false
        console.log("VERDICT " + (root.failures.length === 0 ? "ok" : root.failures.length + " failing"))
        Qt.quit()
        return
      }
      root.patience = 0
      const wait = root.steps[root.at++]()
      if (wait) root.waitingFor = wait
    }
  }
}
