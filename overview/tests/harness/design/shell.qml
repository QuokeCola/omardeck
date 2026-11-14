import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons as Commons
import "plugins/quokecola.omardeck/overview/shell" as O

// The overview's states that the overlay suite doesn't reach: a card selected by
// keyboard while another has focus, an empty desktop, a search, and the shell's
// reduced-motion switch. With TEST_OUT it leaves a frame of each.
ShellRoot {
  id: root

  readonly property string theme: Quickshell.env("TEST_THEME")
  readonly property bool holoTheme: root.theme === "death-stranding"
  readonly property string out: Quickshell.env("TEST_OUT")

  O.Service { id: s }
  O.Overlay { id: overlay; service: s }

  property var failures: []
  function check(ok, what) {
    console.log((ok ? "  PASS " : "  FAIL ") + what)
    if (!ok) root.failures.push(what)
  }

  readonly property var surface: {
    const all = Object.keys(overlay.surfaces)
    return all.length ? overlay.surfaces[all[0]] : null
  }

  function windows() {
    const name = root.surface.monitorName
    return [
      { key: "a1", capture: null, top: ({ title: "~/src/omarchy-holo: nvim Look.qml" }), title: "~/src/omarchy-holo: nvim Look.qml", appId: "foot", workspace: 1, monitor: name,
        active: true, floating: false, x: 12, y: 42, w: 780, h: 940 },
      { key: "a2", capture: null, top: ({ title: "~: journalctl -f" }), title: "~: journalctl -f", appId: "foot", workspace: 1, monitor: name,
        active: false, floating: false, x: 806, y: 42, w: 780, h: 940 },
      { key: "a3", capture: null, top: ({ title: "web" }), title: "web", appId: "chromium", workspace: 2, monitor: name,
        active: false, floating: false, x: 12, y: 42, w: 1576, h: 940 },
    ]
  }

  function grab(name, then) {
    if (root.out === "") { then(); return }
    root.surface.contentItem.children[0].grabToImage(result => {
      root.check(result.saveToFile(root.out + "/" + root.theme + "-" + name + ".png"), "saving " + name)
      then()
    })
  }

  // Everything under an item with the given property.
  function findAll(item, prop, into) {
    if (prop in item) into.push(item)
    for (const child of item.children) root.findAll(child, prop, into)
    return into
  }

  // The look's seam: an exact plain answer off the theme, the holo one on it.
  function checkSeam() {
    const look = overlay.look
    const on = root.holoTheme
    const same = (got, wanted, what) => root.check(got === wanted, "look: " + what + ", got " + got + ", wanted " + wanted)
    same(look.corner(13), on ? 0 : 13, "corner")
    same(look.tileWall(0.85, false), on ? 0.35 : 0.85, "tile wall, current")
    same(look.tileWall(0.5, false), on ? 0.2 : 0.5, "tile wall, other")
    same(look.tileWall(0.5, true), on ? 0 : 0.5, "tile wall, not yet a desktop")
    same(look.legible(8), on ? Math.max(8, Commons.Style.font.caption) : 8, "legible")
    same(look.primaryText(8), on ? Commons.Style.font.body : 8, "primary text")
    same(look.captionEdge(true), on ? 1 : 0, "the picked caption's edge")
    same(look.captionEdge(false), 0, "a caption's edge")
    same(look.quiet(0.45), on ? 1 : 0.45, "quiet")
    same(look.panelAlpha(0.72), on ? 0.8 : 0.72, "panel alpha")
    same(look.dim("#123456") === "#123456", !on, "dim")
    same(look.alertText("#123456") === "#123456", !on, "alert text")
  }

  // HoloCardOverlay, as the look builds it. Not there on a plain theme.
  function marksOf(key) {
    const cards = root.findAll(root.surface.contentItem, "focusedWindow", [])
    const card = cards.find(c => c.modelData.key === key)
    const overlays = root.findAll(card, "lit", [])
    return overlays.length ? overlays[0] : null
  }

  property int step: 0
  function next(ms) { stepper.interval = ms; stepper.start() }
  Timer { id: stepper; onTriggered: root.advance() }
  Timer { interval: 600; running: true; onTriggered: root.advance() }

  function advance() {
    switch (root.step++) {
    case 0:
      root.checkSeam()
      s.onGesture("up-begin")
      s.onGesture("up-move:0.9000")
      root.next(50)
      break
    case 1:
      s.onGesture("up-end:0.9000:0.1000:0:0.5000")
      root.next(1200)
      break
    case 2:
      overlay.shot = root.windows()
      root.next(600)
      break
    case 3:
      overlay.selectedKey = ""
      root.next(300)
      break
    case 4:
      if (root.holoTheme) {
        root.check(root.marksOf("a1")?.lit, "nothing selected: the focused window is the lit one")
        root.check(!root.marksOf("a2")?.lit, "and the other isn't")
      }
      root.grab("resting", () => root.advance())
      break
    case 5:
      overlay.selectedKey = "a2"
      root.next(300)
      break
    case 6:
      if (root.holoTheme) {
        root.check(!root.marksOf("a1")?.lit, "arrowed away: focus goes dark")
        root.check(root.marksOf("a2")?.lit, "and the selection is the one lit card")
      }
      root.grab("selected", () => root.advance())
      break
    case 7:
      overlay.selectedKey = ""
      overlay.filter = "journal"
      root.next(500)
      break
    case 8:
      root.grab("search", () => root.advance())
      break
    case 9:
      overlay.filter = "zzzz"
      root.next(400)
      break
    case 10:
      root.grab("nothing-found", () => root.advance())
      break
    case 11:
      overlay.filter = ""
      overlay.slideBy(2)
      root.next(900)
      break
    case 12:
      root.grab("empty", () => root.advance())
      break
    case 13:
      overlay.slideBy(-2)
      root.next(900)
      break
    case 14: {
      // Reduced motion: a state change lands in the frame it happens.
      Commons.Style.reduceMotion = true
      const tile = root.findAll(root.surface.contentItem, "peeked", [])[2]
      overlay.peek = tile.modelData.id
      root.check(tile.scale === 1.06, "reduced motion: a tile's scale lands at once, got " + tile.scale)
      overlay.peek = -1
      root.check(tile.scale === 1, "and back, got " + tile.scale)
      root.next(50)
      break
    }
    case 15: {
      if (root.holoTheme) {
        const grid = root.findAll(root.surface.contentItem, "driftX", [])
        root.check(grid.length === 1, "reduced motion: the page has its overlay")
        root.check(grid[0].driftX === 0 && grid[0].driftY === 0, "the grid is still, got " + grid[0].driftX + "," + grid[0].driftY)
        root.check(!grid[0].polling, "and asks nothing of the cursor poll")
      }
      Commons.Style.reduceMotion = false
      s.hide()
      root.next(900)
      break
    }
    case 16:
      console.log("VERDICT " + (root.failures.length === 0 ? "ok" : root.failures.length + " failing"))
      Qt.quit()
      break
    }
  }
}
