import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "plugins/quokecola.omardeck/overview/shell" as O

// Replays gestures through the real overview Service, and checks what it did.
//
// Timing here is wall-clock, because the spring runs on frames: end states and
// the order of events are asserted, with tolerance, not values at an instant.
ShellRoot {
  id: root

  O.Service {
    id: s
    onArming: root.note("arming")
    onLanding: (opening) => root.note("landing:" + opening)
    onSideSwipe: (phase, value, velocity, cancelled) =>
      root.note("side:" + phase + ":" + value.toFixed(2) + ":" + velocity.toFixed(2) + ":" + cancelled)
    onStepRequested: (step) => root.note("step:" + step)
    onJumpRequested: (address) => root.note("jump:" + address)
    onDeskRequested: (desk) => root.note("desk:" + desk)
  }

  // A second one, off the service's binding, to drive by hand.
  O.Screens { id: idle }

  property var seen: []
  property var failures: []
  property string current: ""
  function note(what) { root.seen.push(what) }
  function check(ok, what) {
    if (ok) return
    root.failures.push(what)
    console.log("  FAIL " + root.current + ": " + what)
  }
  function eq(a, b, what) {
    const x = JSON.stringify(a), y = JSON.stringify(b)
    root.check(x === y, what + ": got " + x + ", wanted " + y)
  }
  function near(a, b, tol, what) {
    root.check(Math.abs(a - b) <= tol, what + ": got " + a + ", wanted " + b + " +- " + tol)
  }

  FileView { id: logFile; path: "/tmp/hypr.log"; blockLoading: true; printErrors: false }
  function log() {
    logFile.reload()
    logFile.waitForJob()
    return logFile.text().split("\n").filter(l => l !== "")
  }
  function logged(pattern, since) {
    return root.log().slice(since || 0).filter(l => l.indexOf(pattern) >= 0).length
  }

  /** Lands every test on a closed overview, however the last one left it. */
  function* closed() {
    s.deskSlide = false
    s.hide()
    yield 900
    root.seen = []
  }

  function* openIt() {
    s.onGesture("up-begin")
    s.onGesture("up-move:0.9000")
    yield 30
    s.onGesture("up-end:0.9000:0.1000:0:0.5000")
    yield 900
    root.seen = []
  }

  property var tests: ({
    *"contract: every member the other parts rely on"() {
      const members = ["t", "showing", "open", "goal", "scrub", "scrubFrom", "upFingers", "everything", "deskSlide",
                       "monitorName", "appOnly", "dockCovers", "announced", "animating", "wallpaper", "deco",
                       "frost", "deskSwipe", "syncScreens", "liquidGlass", "glassState", "glassError", "recording",
                       "shell", "manifest"]
      for (const m of members) root.check(s[m] !== undefined, "no property " + m)
      const calls = ["showApp", "gotoWindow", "go", "desk", "show", "hide", "toggle", "setRecording", "refreshModels",
                     "arming", "landing", "sideSwipe", "stepRequested", "jumpRequested", "deskRequested"]
      for (const m of calls) root.eq(typeof s[m], "function", m)
    },

    *"startup: gestures registered, sideways sent, decoration read"() {
      yield 500
      root.check(root.logged('dofile(') >= 1 && root.logged('gesture.lua') >= 1, "gesture.lua was not evaled")
      root.check(root.logged('__aerial_horizontal(\\"slide\\")') >= 1, "sideways mode was not sent")
      root.check(root.logged('j/getoption decoration:rounding') >= 1, "decoration was not read")
      const d = s.deco
      root.eq(d.rounding, 8, "rounding")
      root.eq(d.border, 2, "border")
      root.eq(d.activeBorder, "#ff33ccff", "active border")
      root.eq(d.inactiveBorder, "#143a332a", "a gradient with its angle run on")
      root.eq(d.shadowColorInactive, "#ee1a1a1a", "unset inactive shadow reads the active colour")
      root.eq(d.shadowOffsetY, 4, "shadow offset")
      root.eq(d.blur, true, "blur")
      root.eq(d.blurPasses, 2, "passes")
      root.eq(d.glass, false, "no glass without its plugin")
      root.eq(d.glassBezel, 40, "glass fallback")
      root.eq(d.roundingPower, 2, "rounding power fallback")
    },

    *"up: drag past half opens"() {
      yield* root.closed()
      s.onGesture("up-begin")
      root.eq(root.seen[0], "arming", "armed first")
      root.eq(s.scrub, "up", "scrub")
      root.eq(s.upFingers, 0, "upFingers at the start")
      root.eq(s.scrubFrom, 0, "scrubFrom")
      root.eq(s.announced, "hidden", "t has not moved at the arming")
      s.onGesture("up-move:0.3000")
      root.near(s.goal, 0.3, 0.001, "goal follows")
      root.near(s.upFingers, 0.3, 0.001, "upFingers follows")
      s.onGesture("up-move:0.7000")
      yield 60
      root.check(s.t > 0, "t chases")
      root.eq(s.announced, "showing", "announced while moving")
      s.onGesture("up-end:0.7000:0.1000:0:0.5000")
      root.eq(s.scrub, "", "scrub released")
      root.eq(s.upFingers, -1, "upFingers released")
      root.eq(root.seen.filter(x => x.startsWith("landing")), ["landing:true"], "landing")
      root.eq(s.goal, 1, "goal")
      yield 900
      root.near(s.t, 1, 0.02, "t lands")
      root.eq(s.open, true, "open")
      root.eq(s.announced, "open", "announced")
    },

    *"up: short and slow falls back"() {
      yield* root.closed()
      s.onGesture("up-begin")
      s.onGesture("up-move:0.2000")
      yield 30
      s.onGesture("up-end:0.2000:0.1000:0:0.5000")
      root.eq(root.seen.filter(x => x.startsWith("landing")), ["landing:false"], "landing")
      yield 900
      root.near(s.t, 0, 0.002, "t")
      root.eq(s.showing, false, "showing")
      root.eq(s.announced, "hidden", "announced")
    },

    *"down: weak swipe springs back, strong one closes"() {
      yield* root.closed()
      yield* root.openIt()
      s.onGesture("down-begin")
      root.eq(s.scrub, "down", "scrub")
      s.onGesture("down-move:0.2000")
      root.near(s.goal, 0.8, 0.01, "goal")
      s.onGesture("down-end:0.2000:0.1000:0:0.5000")
      yield 900
      root.eq(s.open, true, "still open")
      root.near(s.t, 1, 0.02, "t")
      root.eq(root.seen.filter(x => x.startsWith("landing")), [], "no landing: it was not an up swipe")
      s.onGesture("down-begin")
      s.onGesture("down-move:0.8000")
      yield 30
      s.onGesture("down-end:0.8000:0.1000:0:0.5000")
      yield 900
      root.eq(s.open, false, "closed")
      root.eq(s.showing, false, "showing")
    },

    *"down: on the bare desktop is someone else's"() {
      yield* root.closed()
      s.onGesture("down-begin")
      root.eq(s.scrub, "", "not taken")
    },

    *"allup: every window, reset once away"() {
      yield* root.closed()
      s.onGesture("allup-begin")
      root.eq(s.everything, true, "everything")
      root.eq(s.scrub, "allup", "scrub")
      s.onGesture("allup-move:0.8000")
      yield 30
      s.onGesture("allup-end:0.8000:0.1000:0:0.5000")
      yield 900
      root.eq(s.open, true, "open")
      s.onGesture("alldown-begin")
      s.onGesture("alldown-move:0.9000")
      yield 30
      s.onGesture("alldown-end:0.9000:0.1000:0:0.5000")
      yield 900
      root.eq(s.everything, false, "everything reset")
    },

    *"cancel: stays on whichever side it was"() {
      yield* root.closed()
      s.onGesture("up-begin")
      s.onGesture("up-move:0.3000")
      yield 30
      // Fast, and it still does not count: cancelled is judged on the place alone.
      s.onGesture("up-end:0.3000:5.0000:1:9.0000")
      root.eq(s.goal, 0, "under half: closed")
      yield 900
      s.onGesture("up-begin")
      s.onGesture("up-move:0.8000")
      yield 30
      s.onGesture("up-end:0.8000:0.0000:1:0.0000")
      root.eq(s.goal, 1, "over half: open")
    },

    *"flick: fast opens from little, but not from nothing"() {
      yield* root.closed()
      s.onGesture("up-begin")
      s.onGesture("up-move:0.1000")
      yield 30
      s.onGesture("up-end:0.1000:3.0000:0:12.0000")
      root.eq(s.goal, 1, "a flick")
      yield* root.closed()
      s.onGesture("up-begin")
      s.onGesture("up-move:0.0500")
      yield 30
      s.onGesture("up-end:0.0500:3.0000:0:12.0000")
      root.eq(s.goal, 0, "under the floor")
      yield 900
    },

    *"stretch: past open gives less and less, and comes back"() {
      yield* root.closed()
      yield* root.openIt()
      s.onGesture("up-begin")
      root.eq(root.seen.indexOf("arming"), -1, "already open: not armed again")
      root.eq(s.upFingers, -1, "already open: nothing to make way for")
      s.onGesture("up-move:0.5000")
      root.check(s.goal > 1 && s.goal < 1.3, "goal in the stretch: " + s.goal)
      const small = s.goal
      s.onGesture("up-move:5.0000")
      root.check(s.goal > small && s.goal < 1.3, "more travel, less give: " + s.goal)
      yield 30
      s.onGesture("up-end:5.0000:0.1000:0:0.5000")
      root.eq(s.goal, 1, "back")
      yield 900
      root.near(s.t, 1, 0.02, "t")
      root.eq(s.open, true, "open")
    },

    *"watchdog: a lift that never comes"() {
      yield* root.closed()
      s.onGesture("up-begin")
      s.onGesture("up-move:0.7000")
      yield 1000
      root.eq(s.scrub, "up", "not yet")
      yield 700
      root.eq(s.scrub, "", "released")
      root.eq(s.goal, 1, "went the way it was going")
      root.eq(s.upFingers, -1, "upFingers")
      root.eq(root.seen.filter(x => x.startsWith("landing")), ["landing:true"], "landing")
    },

    *"go: a desktop over from the keyboard"() {
      yield* root.closed()
      s.onGesture("go:next")
      root.eq(s.deskSlide, true, "desk slide")
      root.eq(root.seen, ["arming", "step:1"], "armed, then asked")
      root.eq(s.showing, true, "showing")
      root.eq(s.announced, "sliding", "announced")
      yield* root.closed()
      s.onGesture("go:prev")
      root.eq(root.seen, ["arming", "step:-1"], "prev")
      yield* root.closed()
      s.onGesture("go:sideways")
      root.eq(root.seen, [], "nonsense")
      root.eq(s.deskSlide, false, "not started")
      yield* root.openIt()
      s.onGesture("go:next")
      root.eq(root.seen, ["step:1"], "open: no arming")
    },

    *"desk: by number, in range"() {
      yield* root.closed()
      s.onGesture("desk:3")
      root.eq(root.seen, ["arming", "desk:3"], "desk 3")
      root.eq(s.deskSlide, true, "desk slide")
      yield* root.closed()
      for (const junk of ["desk:0", "desk:11", "desk:x", "desk:"]) s.onGesture(junk)
      root.eq(root.seen, [], "out of range")
      root.eq(s.deskSlide, false, "not started")
    },

    *"goto: an address and nothing else"() {
      yield* root.closed()
      s.onGesture("goto:0xABC123")
      root.eq(root.seen, ["arming", "jump:ABC123"], "strips 0x")
      yield* root.closed()
      for (const junk of ["goto:", "goto:zz", 'goto:a1") os.execute("x', "goto:12 34"]) s.onGesture(junk)
      root.eq(root.seen, [], "rejected")
    },

    *"app: one app's windows"() {
      yield* root.closed()
      s.onGesture("app:Org.Foo")
      root.eq(s.appOnly, "org.foo", "lower-cased")
      root.eq(root.seen, ["arming"], "armed")
      yield 900
      root.eq(s.open, true, "open")
      yield* root.closed()
      root.eq(s.appOnly, "", "reset once away")
      s.onGesture("app:")
      root.eq(s.appOnly, "", "nothing")
    },

    *"side: from the desktop, and refused"() {
      yield* root.closed()
      s.onGesture("side-begin")
      root.eq(root.seen, ["arming", "side:begin:0.00:0.00:false"], "begin")
      root.eq(s.deskSlide, true, "desk slide")
      root.seen = []
      s.onGesture("side-move:-0.4000")
      root.eq(root.seen, ["side:move:-0.40:0.00:false"], "signed")
      root.seen = []
      s.onGesture("side-end:0.6000:1.2000:1:3.5000")
      root.eq(root.seen, ["side:end:0.60:3.50:true"], "end")
      root.seen = []
      s.onGesture("side-end:0.6000:1.2000:0")
      root.eq(root.seen, ["side:end:0.60:0.00:false"], "a missing velocity reads as none")
      yield* root.closed()
      s.deskSwipe = false
      yield 100
      const from = root.log().length
      s.onGesture("side-begin")
      root.eq(root.seen, [], "deskSwipe off: not ours")
      root.eq(s.deskSlide, false, "not started")
      yield 200
      root.check(root.logged('__aerial_horizontal(\\"none\\")', from) >= 1, "handed back to Hyprland")
      s.deskSwipe = true
      yield 200
    },

    *"malformed: nothing happens"() {
      yield* root.closed()
      for (const junk of ["", ":", "-", "nonsense", "up", "up-", "up-bogus", "up-move", "up-move:abc", "up-end",
                          "down-move:1", "side", "-begin", "shape:x=number"])
        s.onGesture(junk)
      root.eq(root.seen.filter(x => x !== "arming"), [], "no signals")
      root.eq(s.scrub, "", "scrub")
      root.eq(s.goal, 0, "goal")
      root.eq(s.open, false, "open")
      root.eq(s.deskSlide, false, "deskSlide")
    },

    *"events: the real raw path"() {
      yield* root.closed()
      Hyprland.dispatch('hl.dsp.event("aerial,go:next")')
      yield 200
      root.eq(root.seen, ["arming", "step:1"], "custom>>aerial,go:next")
    },

    *"recording: submap in, Escape out, limit"() {
      yield* root.closed()
      s.setRecording(true)
      root.eq(s.recording, true, "recording")
      yield 150
      root.check(root.logged('aerial-record') >= 1, "submap sent")
      Hyprland.dispatch('test/nothing')
      yield 50
      s.setRecording(false)
      yield 150
      root.check(root.logged('\\"reset\\"') >= 1, "reset sent")
    },

    *"a theme is the look's business, not the Service's"() {
      yield* root.closed()
      yield* root.openIt()
      yield* root.closed()
      root.eq(root.logged("holo,"), 0, "nothing dispatched about a theme")
    },

    *"configreloaded: gestures again, decoration again, glass told it is off"() {
      yield* root.closed()
      s.deco = ({ rounding: 99 })
      yield 200
      const from = root.log().length
      emitter.command = ["python3", "-c",
        "import socket; c=socket.socket(socket.AF_UNIX); c.connect('/run/test/hypr/test-sandbox/.socket.sock');"
        + "c.send(b'test/emit configreloaded>>'); c.recv(10)"]
      emitter.running = true
      yield 300
      root.eq(s.deco.rounding, 8, "decoration read again at once")
      root.eq(root.logged('dofile(', from), 0, "gestures wait for the reload to settle")
      yield 700
      root.check(root.logged('dofile(', from) >= 1, "gestures again")
      const glassOff = root.logged('"plugin", "list"', from)
      root.eq(glassOff, root.expectedGlassOffPerReload, "the glass told it is off, this many times")
    },

    *"configreloaded: with the glass on, it is told again once settled"() {
      s.liquidGlass = true
      yield 400
      root.eq(s.glassState, "error", "no plugin to load here")
      const from = root.log().length
      emitter.running = true
      yield 200
      root.eq(root.logged('"plugin", "list"', from), 0, "not at once")
      yield 700
      root.eq(root.logged('"plugin", "list"', from), 1, "once settled")
      s.liquidGlass = false
      yield 300
    },

    // SUPER + number. Counted per file, because gesture.lua also re-applies the saved
    // shortcuts each time it runs, so how often it runs is part of the behaviour.
    *"all screens together: the keys load, are checked, come back after a reload, and go"() {
      yield* root.closed()
      root.eq(idle.active, false, "off until asked")
      root.eq(root.logged('synced.lua'), 0, "not loaded while off")
      let from = root.log().length
      s.syncScreens = true
      yield 300
      root.eq(root.logged('synced.lua', from), 1, "loaded at once, the moment it is on")
      yield 2000
      root.check(root.logged('if not _G.__omardeck_synced then error(\\"omardeck: keys gone\\") end', from) >= 1, "not checked")
      root.eq(root.logged('synced.lua', from), 1, "the check found them, no second load")
      root.eq(root.logged('gesture.lua', from), 0, "turning it on leaves the gestures alone")

      from = root.log().length
      emitter.running = true
      yield 300
      root.eq(root.logged('synced.lua', from), 0, "waits for the reload to settle")
      yield 700
      root.eq(root.logged('synced.lua', from), 1, "keys again, once")
      root.eq(root.logged('gesture.lua', from), 1, "gestures again, once")

      from = root.log().length
      s.syncScreens = false
      yield 300
      root.eq(root.logged('"reload"', from), 1, "turning it off reloads the config")

      from = root.log().length
      emitter.running = true
      yield 1000
      root.eq(root.logged('synced.lua', from), 0, "a reload while off loads nothing")
      root.eq(root.logged('gesture.lua', from), 1, "the gestures do not care")
    },

    *"all screens together: asked again while a load is in flight, it loads again"() {
      const from = root.log().length
      idle.active = true
      idle.bindKeys()
      idle.bindKeys()
      yield 600
      root.eq(root.logged('synced.lua', from), 2, "the one in flight and one more")
      const off = root.log().length
      idle.active = false
      yield 300
      root.eq(root.logged('"reload"', off), 1, "reloaded when turned off")
    },
  })
  readonly property int expectedGlassOffPerReload: 1

  Process { id: emitter }

  // --------------------------------------------------------------- the runner
  property var names: Object.keys(root.tests)
  property int at: -1
  property var running: null

  Timer { id: tick; repeat: false; onTriggered: root.advance() }

  function advance() {
    while (true) {
      if (!root.running) {
        if (++root.at >= root.names.length) { root.finish(); return }
        root.current = root.names[root.at]
        root.running = root.tests[root.current]()
        root.failedAt = root.failures.length
      }
      let step
      try {
        step = root.running.next()
      } catch (e) {
        root.check(false, "threw " + e)
        step = { done: true }
      }
      if (step.done) {
        if (root.failures.length === root.failedAt) console.log("  PASS " + root.current)
        root.running = null
        continue
      }
      tick.interval = step.value
      tick.start()
      return
    }
  }
  property int failedAt: 0

  function finish() {
    console.log("VERDICT " + (root.failures.length === 0 ? "ok " + root.names.length + " passing" : root.failures.length + " failing"))
    Qt.quit()
  }

  Timer { interval: 300; running: true; onTriggered: root.advance() }
}
