import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "plugins/quokecola.omardeck/overview/shell" as O

// The whole overview on a private X server: Service, Overlay and a Surface, under
// whichever theme the run asked for. Nothing is captured here (no Wayland), so a
// card is its frame and decorations; what this catches is wiring: bindings that
// throw, things that never come ready, and, through TEST_OUT, what a frame looks
// like before and after a refactor.
ShellRoot {
  id: root

  readonly property string theme: Quickshell.env("TEST_THEME")
  readonly property bool holoTheme: root.theme === "death-stranding"
  readonly property string out: Quickshell.env("TEST_OUT")

  O.Service { id: s }
  O.Overlay { id: overlay; service: s }

  property var failures: []
  function check(ok, what) {
    if (ok) return
    root.failures.push(what)
    console.log("  FAIL " + what)
  }

  FileView { id: logFile; path: "/tmp/hypr.log"; blockLoading: true; printErrors: false }
  function logged(pattern) {
    logFile.reload()
    logFile.waitForJob()
    return logFile.text().split("\n").filter(l => l.indexOf(pattern) >= 0).length
  }

  readonly property var surface: {
    const all = Object.keys(overlay.surfaces)
    return all.length ? overlay.surfaces[all[0]] : null
  }

  // What the sandbox's fake compositor says is there, as the snapshot would have
  // it had there been Wayland toplevels to capture.
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

  function grab(name, then) {
    if (root.out === "") { then(); return }
    // Asks for a frame, so it works on a window that is otherwise idle.
    root.surface.contentItem.children[0].grabToImage(result => {
      const ok = result.saveToFile(root.out + "/" + root.theme + "-" + name + ".png")
      root.check(ok, "saving " + name)
      then()
    })
  }

  // Every card's opacity is a number, and the one the fixtures work out to. A NaN
  // draws as nothing in particular and fails nothing else, so frames taken with one
  // look fine and compare fine; and falling back to 1 would pass a NaN check alone.
  function checkOpacities() {
    const wanted = { a1: 0.9 * 0.95, a2: 0.8 * 0.9, a3: 0.6 }
    root.check(Object.keys(overlay.geo).length === 3, "every window has its geo")
    for (const key in wanted) {
      const got = overlay.geo[key] ? overlay.geo[key].opacity : undefined
      root.check(typeof got === "number" && !isNaN(got), "opacity of " + key + " is not NaN, got " + got)
      root.check(Math.abs(got - wanted[key]) < 1e-6, "opacity of " + key + ": got " + got + ", wanted " + wanted[key])
    }
  }

  // The look answers for this theme, and for a plain one what the plain look says.
  function checkLook(on) {
    const look = overlay.look
    const same = (a, b, what) => root.check(a === b, "look " + (on ? "on" : "off") + ": " + what + ": got " + a + ", wanted " + b)
    same(look.active, on, "active")
    same(look.plainCards, on, "plainCards")
    same(look.hidesPlainDim, on, "hidesPlainDim")
    same(look.handbackDelay, on ? 48 : 0, "handbackDelay")
    same(look.pageLayer.toString() !== "", on, "pageLayer")
    same(look.cardOverlay.toString() !== "", on, "cardOverlay")
    same(look.cardUnderlay(true).toString() !== "", on, "cardUnderlay, floating")
    same(look.cardUnderlay(false).toString(), "", "cardUnderlay, tiled")
    same(look.frostsCard(true), true, "frosts floating")
    same(look.frostsCard(false), !on, "frosts tiled")
    if (on) {
      same(look.ink("#123456") === "#123456", false, "ink comes from the theme")
      same(look.dim("#123456") === "#123456", false, "dim comes from the theme")
      same(look.base("#123456") === "#123456", false, "base comes from the theme")
      same(look.alert("#123456") === "#123456", false, "alert comes from the theme")
      same(look.ringWidth(false, true, false), 1, "ring, landing")
      same(look.ringWidth(false, false, true), 0, "ring, picked")
      same(look.ringWidth(false, false, false), 0, "ring")
    } else {
      same(look.ink("#123456"), "#123456", "ink")
      same(look.dim("#123456"), "#123456", "dim")
      same(look.base("#123456"), "#123456", "base")
      same(look.alert("#123456"), "#123456", "alert")
      same(look.ringWidth(false, true, false), 3, "ring, landing")
      same(look.ringWidth(false, false, true), 3, "ring, picked")
      same(look.ringWidth(false, false, false), 1, "ring")
    }
    same(look.ringWidth(true, true, true), 0, "ring, flying")
  }

  Process { id: writer }
  function setTheme(name) {
    writer.command = ["/bin/sh", "-c", "printf '%s\\n' " + name + " > \"$HOME/.local/state/omarchy/current/theme.name\""]
    writer.running = true
  }

  property int step: 0
  function next(ms) { stepper.interval = ms; stepper.start() }
  Timer { id: stepper; onTriggered: root.advance() }
  Timer { interval: 600; running: true; onTriggered: root.advance() }

  function advance() {
    switch (root.step++) {
    case 0:
      root.checkLook(root.holoTheme)
      root.check(root.surface !== null, "a surface was made and enrolled")
      s.onGesture("up-begin")
      s.onGesture("up-move:0.9000")
      root.next(50)
      break
    case 1:
      s.onGesture("up-end:0.9000:0.1000:0:0.5000")
      root.next(1200)
      break
    case 2:
      root.check(root.surface.leading, "that surface leads")
      root.check(s.open, "the overview opened")
      root.check(root.surface.ready, "the surface came ready")
      root.check(overlay.reveal === 1, "the overview revealed")
      root.check(overlay.workspaces.length >= 5, "the strip is there")
      overlay.shot = root.windows()
      root.next(600)
      break
    case 3:
      root.checkOpacities()
      root.check(root.surface.shownWindows.length === 2, "two windows on this desktop")
      root.check(Object.keys(root.surface.slots).length === 3, "every window has a slot")
      overlay.selectedKey = "a1"
      root.grab("open", () => root.advance())
      break
    case 4:
      // Across a slide, which is every card's lane and `shift` at work.
      overlay.slideBy(1)
      root.next(900)
      break
    case 5:
      root.check(overlay.stageId === 2, "the slide landed on the next desktop")
      root.grab("slid", () => root.advance())
      break
    case 6:
      s.onGesture("down-begin")
      s.onGesture("down-move:0.9000")
      root.next(50)
      break
    case 7:
      s.onGesture("down-end:0.9000:0.1000:0:0.5000")
      root.next(1100)
      break
    case 8:
      root.check(!s.showing, "the overview closed")
      root.check(!root.surface.ready, "the gate reset")
      root.check(root.logged('holo,overview:1') === 1, "said the overview is up, once")
      root.check(root.logged('holo,overview:0') === 1, "said the overview is away, once")
      // A desktop slide lands through the hand-back.
      s.onGesture("go:next")
      root.next(1500)
      break
    case 9:
      root.check(!s.deskSlide, "the desktop slide handed back")
      // The theme changes under a loaded overview, and everything follows it.
      root.setTheme(root.holoTheme ? "plain" : "death-stranding")
      root.next(500)
      break
    case 10:
      root.checkLook(!root.holoTheme)
      // Open and shut under the other theme, slots loading or unloading on the way.
      s.onGesture("up-begin")
      s.onGesture("up-move:0.9000")
      root.next(50)
      break
    case 11:
      s.onGesture("up-end:0.9000:0.1000:0:0.5000")
      root.next(1000)
      break
    case 12:
      root.check(s.open, "opened under the other theme")
      overlay.shot = root.windows()
      root.next(400)
      break
    case 13:
      root.grab("switched", () => root.advance())
      break
    case 14:
      root.setTheme(root.theme)
      root.next(500)
      break
    case 15:
      root.checkLook(root.holoTheme)
      s.hide()
      root.next(900)
      break
    case 16:
      root.check(!s.showing, "closed")
      console.log("VERDICT " + (root.failures.length === 0 ? "ok" : root.failures.length + " failing"))
      Qt.quit()
      break
    }
  }
}
