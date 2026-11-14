import QtQuick
import Quickshell
import Quickshell.Hyprland
import "plugins/quokecola.omardeck/overview/shell" as O

// A swipe held early on, the only time a card wears Hyprland's shadow: it fades out
// with `dress`, gone by t = 0.6, so no frame of the open overview has one. In the
// fixtures a1 (focused) has opted out, and a2 (not focused) has a shadow, under a
// color_inactive reported as an unset ffffffff, which used to make a white card.
ShellRoot {
  id: root

  readonly property string theme: Quickshell.env("TEST_THEME")
  readonly property string out: Quickshell.env("TEST_OUT")

  O.Service { id: s }
  O.Overlay { id: overlay; service: s }

  property var failures: []
  function check(ok, what) {
    if (ok) return
    root.failures.push(what)
    console.log("  FAIL " + what)
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

  // A card's shadow, by its window's address. The effect has no id to reach it by,
  // but it is the only thing on a card with a shadowPower.
  function shadowOf(key) {
    const search = (item, card) => {
      const here = item.modelData && item.modelData.key !== undefined ? item : card
      if (here && here.modelData.key === key && item.shadowPower !== undefined) return item
      for (const child of item.children) {
        const found = search(child, here)
        if (found) return found
      }
      return null
    }
    return search(root.surface.contentItem, null)
  }

  property int step: 0
  property int tries: 0
  function next(ms) { stepper.interval = ms; stepper.start() }
  Timer { id: stepper; onTriggered: root.advance() }
  Timer { interval: 600; running: true; onTriggered: root.advance() }

  function advance() {
    switch (root.step++) {
    // Once all the way open and shut first. The first frame under the holo look
    // takes llvmpipe over 1400ms, the gesture's watchdog for a lost lift goes off
    // behind it, and the swipe being held falls back shut.
    case 0:
      s.onGesture("up-begin")
      s.onGesture("up-move:0.9000")
      root.next(50)
      break
    case 1:
      s.onGesture("up-end:0.9000:0.1000:0:0.5000")
      root.next(1200)
      break
    case 2:
      s.hide()
      root.next(900)
      break
    case 3:
      s.onGesture("up-begin")
      s.onGesture("up-move:0.2000")
      root.next(100)
      break
    case 4:
      overlay.shot = root.windows()
      root.next(100)
      break
    case 5:
      // Until the spring has got there. The fingers keep reporting, for the watchdog.
      s.onGesture("up-move:0.2000")
      if (root.tries++ < 100 && Math.abs(overlay.t - 0.2) > 1e-4) {
        root.step = 5
        root.next(100)
        break
      }
      root.next(500)
      break
    case 6: {
      console.log("  held at t=" + overlay.t + " dress=" + overlay.dress + " after " + root.tries + " tries")
      root.check(Math.abs(overlay.t - 0.2) <= 1e-4, "the swipe is held where it was put, t " + overlay.t)
      root.check(overlay.dress < 1, "held early enough to wear a shadow, dress " + overlay.dress)
      root.check(overlay.deco.shadow === true, "shadows are on")
      const focused = root.shadowOf("a1")
      const other = root.shadowOf("a2")
      root.check(focused !== null && other !== null, "found the shadows")
      if (focused && other) {
        root.check(focused.visible === false, "a window opted out with no_shadow has no shadow")
        root.check(other.visible === true, "a window with a shadow has it")
        // The white-card bug: unset, color_inactive reads ffffffff and means the
        // active colour.
        const t = other.tint
        root.check(!(t.r > 0.99 && t.g > 0.99 && t.b > 0.99), "the unfocused card's shadow is not white, got " + t)
        root.check(Qt.colorEqual(t, overlay.deco.shadowColor), "it is the active colour, got " + t)
      }
      if (root.out === "") { root.advance(); break }
      root.surface.contentItem.children[0].grabToImage(result => {
        root.check(result.saveToFile(root.out + "/" + root.theme + "-mid.png"), "saving mid")
        root.advance()
      })
      break
    }
    case 7:
      s.hide()
      root.next(900)
      break
    case 8:
      console.log("VERDICT " + (root.failures.length === 0 ? "ok" : root.failures.length + " failing"))
      Qt.quit()
      break
    }
  }
}
