import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons as Commons
import qs.Ui as Ui
import "plugins/quokecola.hud/holo" as H

// The holo foundation on a private X server, under whichever theme the run asked
// for: the [holo] data, tokens, reduced motion, what a frame really paints, and the
// cursor poll. Pixels are read back from real frames with magick.
ShellRoot {
  id: root

  readonly property string theme: Quickshell.env("TEST_THEME")
  readonly property bool holoTheme: root.theme === "death-stranding"
  readonly property string out: Quickshell.env("TEST_OUT")

  property var failures: []
  property int openTop: 0
  function check(ok, what) {
    console.log((ok ? "  PASS " : "  FAIL ") + what)
    if (!ok) root.failures.push(what)
  }
  function near(a, b, tol) { return Math.abs(a - b) <= tol }
  function top0() { return root.openTop }

  FloatingWindow {
    id: win
    implicitWidth: 760
    implicitHeight: 620
    color: "white"

    // A panel's tree as the clones build it: a card that clips, its content holder,
    // and the frame in a Loader, under a window's content item.
    Item {
      id: stage
      anchors.fill: parent

      // A light window under the panel, the worst case.
      Rectangle {
        anchors.fill: parent
        z: -2
        color: "white"
      }

      Ui.BorderSurface {
        id: card
        x: 120
        y: 100
        width: 300
        height: 240
        color: root.holoTheme ? "transparent" : "#808080"
        property bool cropping: false
        clip: cropping
        transform: Scale { id: cardScale; origin.x: 150; origin.y: 0; xScale: 0.97; yScale: 0.97 }

        Item {
          id: holder
          x: 10
          y: 10
          width: 280
          height: 220

          Loader {
            id: frameLoader
            z: -1
            x: -parent.x - 56
            y: -parent.y - 56
            width: parent.parent.width + 112
            height: parent.parent.height + 112
            source: Qt.resolvedUrl("plugins/quokecola.hud/holo/HoloFrame.qml")
            onLoaded: item.host = parent.parent
          }
        }
      }

      H.HoloRule { id: rule; x: 520; y: 40; width: 200 }
      H.HoloRule { id: vrule; x: 520; y: 50; height: 100; vertical: true }
      H.HoloTick { id: tick; x: 530; y: 60 }
      H.HoloLabel { id: label; x: 530; y: 80; text: "<b>A title</b>" }
      H.HoloMarks { id: marks; x: 540; y: 200; width: 180; height: 120; focused: true; title: "foot" }

      Item { id: probe; property real level: 0; property real other: 0 }
      H.HoloReveal { id: reveal; target: probe; prop: "level"; delay: H.HoloTokens.stagger }
      ParallelAnimation {
        id: staggered
        H.HoloReveal { target: probe; prop: "level" }
        H.HoloReveal { target: probe; prop: "other"; to: 0.5; delay: H.HoloTokens.stagger; duration: H.HoloTokens.dismiss }
      }
    }
  }

  readonly property Item frame: frameLoader.item

  Process {
    id: pixelReader
    property var then: null
    stdout: StdioCollector {
      onStreamFinished: {
        const nums = text.trim().split(/\s+/).map(p => (p.match(/[\d.]+/g) || []).map(Number))
        pixelReader.then(nums)
      }
    }
  }
  // [[x, y], ...] from a saved frame, as [[r, g, b], ...] in 0..255.
  function grabPixels(name, points, then) {
    const file = (root.out !== "" ? root.out : "/tmp") + "/holo-" + root.theme + "-" + name + ".png"
    stage.grabToImage(result => {
      root.check(result.saveToFile(file), "saving " + name)
      const format = points.map(p => "%[pixel:p{" + p[0] + "," + p[1] + "}]").join(" ")
      pixelReader.then = then
      pixelReader.command = ["magick", file, "-alpha", "off", "-depth", "8", "-colorspace", "sRGB", "-format", format, "info:"]
      pixelReader.running = true
    })
  }

  FileView { id: logFile; path: "/tmp/hypr.log"; blockLoading: true; printErrors: false }
  FileView { id: qsOut; path: "/tmp/qs.out"; blockLoading: true; printErrors: false }
  function count(view, pattern) {
    view.reload()
    view.waitForJob()
    return view.text().split("\n").filter(l => l.indexOf(pattern) >= 0).length
  }

  property int step: 0
  function next(ms) { stepper.interval = ms; stepper.start() }
  Timer { id: stepper; onTriggered: root.advance() }
  Timer { interval: 800; running: true; onTriggered: root.advance() }

  function advance() {
    switch (root.step++) {
    case 0: {
      // The [holo] section, as Commons.Color has read it from the theme's shell.toml.
      const C = Commons.Color
      root.check(C.pick("holo.absent", "fb") === "fb", "pick: a missing key is its fallback")
      if (root.holoTheme) {
        root.check(C.pick("holo.text-dim", "fb") === "#8FB3C0", "pick: holo.text-dim from the theme file")
        root.check(C.pick("holo.line", "fb") === "#BDEBEE", "pick: holo.line from the theme file")
        root.check(near(C.pickAlpha("holo.panel-alpha", 0.1), 0.8, 1e-9), "pickAlpha: holo.panel-alpha")
        root.check(Commons.Style.font.caption === 9, "caption 9, got " + Commons.Style.font.caption)
        root.check(Commons.Style.font.body === 10, "base-size 10, got " + Commons.Style.font.body)
        root.check(Commons.Style.hoverBorderWidth === 1, "hover-cursor width")
        root.check(near(Commons.Style.hoverBorderAlpha, 0.6, 1e-9), "hover-cursor alpha")
        root.check(near(Commons.Style.normalBorderAlpha, 0.6, 1e-9), "normal alpha")
        root.check(Commons.Style.normalBorderWidth === 0, "normal width stays 0")
        const ring = Commons.Border.controlSpec("hover-cursor", C.foreground, C.accent)
        root.check(ring.widths.top === 1 && ring.widths.left === 1, "the switch ring has an edge")
        root.check(near(ring.color.a, 0.6, 0.01), "and shows, alpha " + ring.color.a)
        root.check(Commons.Style.normalBorderFor(C.foreground, C.accent).a > 0.59, "today's outline shows")
      } else {
        root.check(C.pick("holo.text-dim", "fb") === "fb", "pick: no holo data under this theme")
        root.check(near(C.pickAlpha("holo.panel-alpha", 0.1), 0.1, 1e-9), "pickAlpha: its fallback")
      }
      // What the user's own shell.toml does on top: its keys, and only those, win.
      C.loadUserShell('[font]\nbase-size = 10\n[bar]\nbackground-alpha = 0.55\n[menu]\nbackground-alpha = 0.80\nscrim-alpha = 0\n'
                      + '[launcher]\nbackground-alpha = 0.80\nscrim-alpha = 0\n[popups]\nbackground-alpha = 0.80\n')
      root.next(50)
      break
    }
    case 1: {
      const C = Commons.Color
      if (root.holoTheme) {
        root.check(Commons.Style.font.caption === 9, "with the user's file: caption stays 9")
        root.check(near(C.pickAlpha("holo.panel-alpha", 0.1), 0.8, 1e-9), "with the user's file: panel-alpha stays")
        root.check(near(C.pickAlpha("holo.scrim-alpha", 0.1), 0.72, 1e-9), "with the user's file: scrim-alpha stays")
        root.check(C.pick("bar.background-alpha", "") === "0.55", "with the user's file: the bar's alpha is the user's")
      }
      C.loadUserShell("")
      // A theme switch reaches the shell as a payload for Color.loadShell, and bindings follow.
      root.savedTheme = root.holoTheme ? JSON.stringify(C.themeShellValues) : ""
      root.savedPale = H.HoloTokens.pale.toString()
      C.loadShell('[holo]\nline = "#112233"\nline-alpha = 0.5\n')
      root.next(50)
      break
    }
    case 2: {
      const C = Commons.Color
      root.check(H.HoloTokens.pale.toString() === "#112233", "a loaded theme reaches the tokens, got " + H.HoloTokens.pale)
      root.check(near(H.HoloTokens.line.a, 0.5, 0.01), "and the line colour's alpha")
      root.check(rule.color.toString() === H.HoloTokens.line.toString(), "and a live HoloRule")
      C.loadShell("")
      root.check(H.HoloTokens.pale.toString() === "#bdebee", "no [holo] at all: the fallback, got " + H.HoloTokens.pale)
      if (root.holoTheme) C.themeShellValues = JSON.parse(root.savedTheme)
      C.mergeShell()
      root.next(50)
      break
    }
    case 3:
      root.check(rule.height === 1 && rule.width === 200, "HoloRule: level")
      root.check(vrule.width === 1 && vrule.height === 100, "HoloRule: vertical")
      root.check(tick.width === 6 && tick.height === 6, "HoloTick")
      root.check(label.textFormat === Text.PlainText, "HoloLabel: plain text")
      root.check(marks.children.length > 0, "HoloMarks builds on them")
      root.check(H.HoloTokens.construct >= 200 && H.HoloTokens.construct <= 450, "construct in range")
      root.check(H.HoloTokens.reveal >= 120 && H.HoloTokens.reveal <= 300, "reveal in range")
      root.check(H.HoloTokens.focus >= 100 && H.HoloTokens.focus <= 200, "focus in range")
      root.check(H.HoloTokens.update >= 80 && H.HoloTokens.update <= 250, "update in range")
      root.check(H.HoloTokens.dismiss >= 120 && H.HoloTokens.dismiss <= 250, "dismiss in range")
      root.check(H.HoloTokens.stagger >= 25 && H.HoloTokens.stagger <= 70, "stagger in range")
      root.check(root.frame !== null, "the frame loaded")
      root.check(root.frame.active === root.holoTheme, "the frame is on only under its theme")
      root.check(root.frame.pad === H.HoloTokens.pad, "the frame's pad is the token")
      // With motion on, a reveal takes its time.
      probe.level = 0
      reveal.restart()
      root.next(20)
      break
    case 4:
      root.check(probe.level === 0 || probe.level < 1, "a reveal takes its time")
      root.next(400)
      break
    case 5:
      root.check(probe.level === 1, "and lands")
      probe.level = 0
      probe.other = 0
      staggered.restart()
      root.next(400)
      break
    case 6:
      root.check(probe.level === 1 && probe.other === 0.5, "two in a group land")
      // Reduced motion: every token is zero, and everything still lands, at once.
      Commons.Style.reduceMotion = true
      root.check(H.HoloTokens.construct === 0 && H.HoloTokens.reveal === 0 && H.HoloTokens.focus === 0
                 && H.HoloTokens.update === 0 && H.HoloTokens.dismiss === 0 && H.HoloTokens.stagger === 0,
                 "reduced motion: tokens are zero")
      probe.level = 0
      reveal.restart()
      root.frame.wipe()
      root.next(30)
      break
    case 7:
      root.check(probe.level === 1, "reduced motion: a reveal lands, got " + probe.level)
      root.check(root.frame.reveal === 1, "reduced motion: a wipe lands, got " + root.frame.reveal)
      Commons.Style.reduceMotion = false
      root.frame.reveal = 1
      card.cropping = false
      root.next(100)
      break
    case 8:
      // Inside the card and in the frame's soft edge, just outside it, on white.
      root.grabPixels("open", [[270, 120], [270, 320], [270, 92], [108, 200], [20, 20]], px => {
        root.pixels = px
        root.advance()
      })
      break
    case 9: {
      const [top, bottom, above, left, corner] = root.pixels
      console.log("  panel over white: top " + top + " bottom " + bottom + " edge " + above + " / " + left)
      if (root.holoTheme) {
        // panel-alpha over white, 0.8 black: about #333, and flat.
        root.check(near(top[0], 255 * 0.2 + 1, 6), "the panel is about 0.80 at the top, r=" + top[0])
        root.check(near(bottom[0], top[0], 2), "and the same at the bottom, r=" + bottom[0])
        root.check(above[0] === 255 && left[0] === 255, "nothing past the frame, r=" + above[0])
      } else {
        root.check(top[0] === 128 && bottom[0] === 128, "plain: only the card shows")
        root.check(above[0] === 255 && left[0] === 255, "plain: nothing outside the card")
      }
      root.check(corner[0] === 255, "white, away from it all")
      root.openEdge = above
      root.openTop = top[0]
      // The card crops, as it does while it morphs or rows are arriving.
      card.cropping = true
      root.next(100)
      break
    }
    case 10:
      root.grabPixels("cropped", [[270, 92], [108, 200], [270, 120]], px => {
        root.pixels = px
        root.advance()
      })
      break
    case 11: {
      const [above, left, inside] = root.pixels
      console.log("  while cropping: edge " + above + " / " + left + " inside " + inside)
      if (root.holoTheme)
        root.check(near(inside[0], top0(), 2), "the panel survives the card cropping, r=" + inside[0])
      else
        root.check(above[0] === 255, "plain: nothing outside the card")
      card.cropping = false
      // The cursor poll: Hyprland closes this socket after each reply.
      H.HoloState.cursorDemand = 1
      root.pollsBefore = root.count(logFile, "socket cursorpos")
      root.next(1800)
      break
    }
    case 12: {
      H.HoloState.cursorDemand = 0
      const polls = root.count(logFile, "socket cursorpos") - root.pollsBefore
      const errors = root.count(qsOut, "PeerClosedError")
      console.log("  " + polls + " polls, " + errors + " peer-closed warnings")
      root.check(polls >= 4, "the cursor is polled")
      root.check(H.HoloState.cursorX === 800 && H.HoloState.cursorY === 500, "and read, got " + H.HoloState.cursorX + "," + H.HoloState.cursorY)
      root.check(errors === 0, "without a warning for each one")
      console.log("VERDICT " + (root.failures.length === 0 ? "ok" : root.failures.length + " failing"))
      Qt.quit()
      break
    }
    }
  }
  property var pixels: []
  property var openEdge: []
  property string savedTheme: ""
  property string savedPale: ""
  property int pollsBefore: 0
}
