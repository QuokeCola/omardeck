import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons as Commons
import "plugins/quokecola.omardeck/dock" as D

// The real dock on a private X server, stripped of its layer-shell lines by run-qs.sh,
// with a real pointer from xdotool and clicks reaching the fake compositor. Window state
// is injected over the fixtures' clients, as the fixtures can't say "minimized".
// TEST_OUT=<dir> leaves what it draws there, with a transparent background.
ShellRoot {
  id: root

  readonly property bool holoTheme: Quickshell.env("TEST_THEME") === "death-stranding"
  readonly property string out: Quickshell.env("TEST_OUT") || ""
  readonly property string home: Quickshell.env("HOME")

  property var failures: []
  function check(ok, what) {
    console.log((ok ? "  PASS " : "  FAIL ") + what)
    if (!ok) root.failures.push(what)
  }
  function note(what) { console.log("  NOTE " + what) }

  Process {
    id: writer
    running: true
    command: ["sh", "-c", 'mkdir -p "$HOME/.config/omarchy" && printf %s \'{"pinned":["foot","chromium","org.gnome.Nautilus","not.running.app"],"iconSize":38,"height":63,"magnify":1,"autohide":"never"}\' >"$HOME/.config/omarchy/dock.json"']
    onExited: loader.active = true
  }
  Loader {
    id: loader
    active: false
    sourceComponent: Component { D.Service {} }
    onLoaded: runner.begin()
  }
  readonly property var dock: loader.item

  Process { id: emitter }
  function emit(line) {
    emitter.command = ["python3", "-c",
      "import socket; c=socket.socket(socket.AF_UNIX); c.connect('/run/test/hypr/test-sandbox/.socket.sock');"
      + "c.send(b'test/emit " + line + "'); c.recv(10)"]
    emitter.running = true
  }
  Process { id: pointer }
  function xdo(args) {
    pointer.running = false
    pointer.command = ["xdotool"].concat(args)
    pointer.running = true
  }
  // A point in the panel's own coordinates, in X's device pixels. The last row of the
  // screen is exactly the place the dock used to ignore.
  function moveTo(px, py) {
    const g = root.panel.contentItem.mapToGlobal(px, py)
    root.xdo(["mousemove", String(Math.round(g.x * root.panel.dpr)), String(Math.round(g.y * root.panel.dpr))])
  }
  function moveToScreenBottom(px) {
    const g = root.panel.contentItem.mapToGlobal(px, 0)
    const s = root.panel.modelData
    root.xdo(["mousemove", String(Math.round(g.x * root.panel.dpr)), String(Math.ceil(s.height * root.panel.dpr) - 1)])
  }

  FileView { id: logFile; path: "/tmp/hypr.log"; blockLoading: true; printErrors: false }
  function logged(pattern) {
    logFile.reload()
    logFile.waitForJob()
    return logFile.text().split("\n").filter(l => l.indexOf(pattern) >= 0).length
  }

  // --------------------------------------------------------- finding the parts
  property var panel: null
  function walk(item, test, acc) {
    if (test(item)) acc.push(item)
    const kids = item.children || []
    for (let i = 0; i < kids.length; i++) root.walk(kids[i], test, acc)
    return acc
  }
  function cells() { return root.walk(root.panel.contentItem, i => i.wins !== undefined && i.zoom !== undefined, []) }
  function cellOf(key) { return root.cells().find(c => c.key === key) || null }
  function kid(cell, test) { return Array.from(cell.children).find(test) || null }
  function mouseOf(cell) { return root.kid(cell, i => i.preventStealing !== undefined) }
  function tipOf(cell) { return root.kid(cell, i => i.removing !== undefined) }
  function cueOf(cell) { return root.kid(cell, i => i.wanted !== undefined) }
  // The marks this theme draws: the dots, or under the holographic theme the corner brackets
  // round the icon, inside an Item that pulses on launch and shows only while there is a state.
  function rowOf(cell) { return root.kid(cell, i => i.spacing !== undefined) }
  function frameOf(cell) { return root.kid(cell, i => i.arm !== undefined) }
  function pulseOf(cell) { return root.holoTheme ? root.frameOf(cell) : root.rowOf(cell) }
  function marks(cell) {
    if (!root.holoTheme) return Array.from(root.rowOf(cell).children).filter(c => c.radius !== undefined)
    const frame = root.frameOf(cell)
    return frame.visible ? Array.from(frame.children).filter(c => c.radius !== undefined) : []
  }
  function slider() { return root.walk(root.panel.contentItem, i => i.hiddenOffset !== undefined, [])[0] }

  function client(addr, cls, wsId, wsName) {
    return { address: addr, class: cls, mapped: true, hidden: false, workspace: { id: wsId, name: wsName },
             monitor: 0, at: [0, 0], size: [100, 100], floating: true, fullscreen: 0, focusHistoryID: 0 }
  }
  readonly property var fixtureClients: [
    client("0xa1", "foot", 1, "1"),                                  // focused
    client("0xb1", "foot", 1, "1"),                                  // and a second, running
    client("0xa3", "chromium", 2, "2"),                              // running, elsewhere
    client("0xa2", "org.gnome.Nautilus", 1, "1"),                    // running
    client("0xb2", "org.gnome.Nautilus", -99, "special:minimized"),  // and minimized
    client("0xc1", "mpv", -99, "special:minimized"),                 // only minimized
    client("0xd1", "kitty", 1, "1"), client("0xd2", "kitty", 1, "1"), client("0xd3", "kitty", 2, "2"),
    client("0xd4", "kitty", 2, "2"), client("0xd5", "kitty", -99, "special:minimized")  // over the cap
  ]
  function inject(list) { root.dock.clients = list; root.dock.rebuild() }

  // Sampled off a timer, so times are from the trigger, not the frames.
  property var samples: []
  property var sampleFn: null
  property real sampleStart: 0
  Timer {
    id: sampler
    interval: 4
    repeat: true
    onTriggered: root.samples.push([Date.now() - root.sampleStart, root.sampleFn()])
  }
  function startSampling(fn) { root.samples = []; root.sampleFn = fn; root.sampleStart = Date.now(); sampler.start() }
  function stopSampling() { sampler.stop(); return root.samples }
  function at(samples, ms) {
    let v = samples.length ? samples[0][1] : NaN
    for (const s of samples) { if (s[0] <= ms) v = s[1]; else break }
    return v
  }
  function settledAt(samples, goal) {
    for (const s of samples) if (Math.abs(s[1] - goal) < 0.01) return s[0]
    return -1
  }

  function snap(name) {
    if (root.out === "") return
    const label = name + "-" + Math.round(root.panel.dpr * 100)
    root.slider().parent.grabToImage(r => {
      root.check(r.saveToFile(root.out + "/dock-" + Quickshell.env("TEST_THEME") + "-" + label + ".png"), "saving " + label)
    })
  }

  // ------------------------------------------------------------------ the run
  QtObject {
    id: runner
    property var gen: null
    function begin() { gen = root.script(); step() }
    function step() {
      let r
      try { r = gen.next() } catch (e) { root.check(false, "threw: " + e + "\n" + e.stack); r = { done: true } }
      if (r.done) { root.finish(); return }
      tick.interval = r.value
      tick.start()
    }
  }
  Timer { id: tick; onTriggered: runner.step() }
  Timer { interval: 55000; running: true; onTriggered: { root.check(false, "timed out"); root.finish() } }

  function finish() {
    console.log("VERDICT " + (root.failures.length === 0 ? "ok" : root.failures.length + " failing"))
    Qt.quit()
  }

  function* script() {
    const dock = root.dock
    while (!dock.resources || !Array.from(dock.resources).find(r => r.instances && r.instances.length)) yield 50
    root.panel = Array.from(dock.resources).find(r => r.instances && r.instances.length).instances[0]
    const panel = root.panel
    const H = root.holoTheme

    // The fixtures arrive, and the dock's restack at 2 s passes, before anything is staged.
    while (dock.clients.length < 3) yield 50
    yield 2400
    root.inject(root.fixtureClients)
    root.emit("activewindowv2>>a1")
    yield 700
    root.check(dock.activeAddress === "0xa1", "focus came through the event socket: " + dock.activeAddress)

    const fkey = dock.keyForClass("foot"), nkey = dock.keyForClass("org.gnome.Nautilus")
    const mkey = dock.keyForClass("mpv"), kkey = dock.keyForClass("kitty"), ckey = dock.keyForClass("chromium")

    // ------------------------------------------------------------- state signals
    const foot = root.cellOf(fkey), naut = root.cellOf(nkey), mpv = root.cellOf(mkey)
    const kitty = root.cellOf(kkey), idle = root.cellOf("not.running.app")
    root.check(foot && naut && mpv && kitty && idle, "the fixture apps are all on the dock")
    if (H) {
      root.check(foot.tickStates === "fr", "focused and running: " + foot.tickStates)
      root.check(naut.tickStates === "rm", "running and minimized: " + naut.tickStates)
      root.check(mpv.tickStates === "m", "only minimized: " + mpv.tickStates)
      root.check(kitty.tickStates === "rrm", "over the cap, the minimized one still shows: " + kitty.tickStates)
      root.check(root.marks(idle).length === 0, "not running: no mark")
    } else if (foot.tickStates !== undefined) {
      root.check(root.marks(foot).length === 2 && root.marks(kitty).length === 3, "plain: one dot per window, up to three")
    }
    const widths = cell => root.marks(cell).map(m => m.width + "x" + m.height + "r" + m.radius)
    root.note("marks foot " + widths(foot) + "; nautilus " + widths(naut) + "; mpv " + widths(mpv))
    const dpr = panel.dpr
    const w = (cell, i) => Math.round(root.marks(cell)[i].width * dpr)
    if (H) {
      // Four corner brackets, a hairline thick, coloured by the app's state.
      root.check(root.marks(foot).length === 8, "eight arms: a bracket at each corner")
      root.check(root.marks(foot).every(m => Math.round(Math.min(m.width, m.height) * dpr) === 1), "each a device pixel thick")
      root.check(root.marks(foot)[0].color.toString() === Commons.Color.accent.toString(), "the focused app's frame is the accent")
      const c = cell => root.marks(cell)[0].color.toString()
      root.check(c(foot) !== c(naut) && c(naut) !== c(mpv), "focused, running and minimized differ by colour")
      for (const m of root.marks(foot).concat(root.marks(naut))) {
        const g = m.mapToItem(panel.contentItem, 0, 0)
        const onGrid = v => Math.abs(v * dpr - Math.round(v * dpr)) < 0.02
        root.check(onGrid(g.x) && onGrid(g.y) && onGrid(m.width) && onGrid(m.height),
                   "a tick lands on device pixels: " + g.x + "," + g.y)
      }
    } else {
      root.check(root.marks(foot).every(m => m.width === 4 && m.height === 4 && m.radius === 2), "plain: today's 4 px round dot")
      root.check(root.marks(foot)[0].color.toString() === Commons.Color.accent.toString(), "plain: an active app's dots are accent")
    }
    root.snap("states")
    yield 300

    // ------------------------------------------------------------------ hit area
    const nmouse = root.mouseOf(naut)
    const centre = naut.mapToItem(panel.contentItem, naut.width / 2, 0).x
    root.moveToScreenBottom(centre)
    yield 300
    root.note("pointer on the last screen row: icon hit area contains it: " + nmouse.containsMouse)
    root.check(nmouse.containsMouse, "the screen's last row is the icon's hit area")
    const before = root.logged("hl.dsp.focus")
    root.xdo(["click", "1"])
    yield 300
    root.check(root.logged("hl.dsp.focus") === before + 1, "and a click there reaches the app")
    const b = nmouse.mapToItem(panel.contentItem, 0, nmouse.height)
    root.note("hit area bottom " + b.y + ", panel height " + panel.height)

    // --------------------------------------------------------------- hover and tip
    const cue = root.cueOf(naut), tip = root.tipOf(naut)
    root.moveTo(centre, 0)
    yield 300
    const mid = naut.mapToItem(panel.contentItem, naut.width / 2, naut.height / 2)
    if (cue) root.startSampling(() => cue.opacity)
    root.moveTo(mid.x, mid.y)
    yield 400
    root.check(nmouse.containsMouse, "hover on the icon")
    if (cue) {
      const s = root.stopSampling()
      const first = s.findIndex(x => x[1] > 0)
      const full = s.findIndex(x => x[1] > 0.99)
      const span = first >= 0 && full >= 0 ? s[full][0] - s[first][0] : -1
      root.note("hover cue: " + span + " ms to full")
      if (H) {
        root.check(cue.opacity === 1, "the hover cue is on")
        root.check(span >= 40 && span <= 200, "within the protocol's focus range: " + span + " ms")
        root.check(naut.width === panel.restIcon, "and nothing scaled")
      } else {
        root.check(cue.opacity === 0, "plain: no hover cue")
      }
    }
    root.check(tip.visible, "the name tooltip shows")
    const text = Array.from(tip.children)[0]
    root.note("tooltip: " + text.font.pixelSize + " px, family '" + text.font.family + "', radius " + tip.radius
              + ", " + tip.width + "x" + tip.height + ", '" + text.text + "'")
    if (H) {
      root.check(text.font.pixelSize >= 9, "tooltip at or above the floor")
      root.check(tip.radius === 0, "tooltip square")
      root.check(text.font.family === Commons.Style.font.family, "tooltip in the panels' font")
      const top = root.slider().children[0].y
      const tb = tip.mapToItem(panel.contentItem, 0, tip.height).y
      root.check(tb <= top, "tooltip clear of the panel's top edge: " + tb + " <= " + top)
    } else {
      root.check(tip.radius === Math.min(6, Commons.Style.cornerRadius), "plain: tooltip radius as today")
      root.check(tip.anchors.bottomMargin === 8, "plain: tooltip margin as today")
    }
    root.snap("hover")
    yield 300

    // ----------------------------------------------------------------- context menu
    panel.openMenu(naut)
    yield 500
    const menu = Array.from(panel.data).find(d => d.anchor !== undefined && d.implicitWidth !== undefined)
    if (menu && menu.visible && root.out !== "") {
      root.walk(menu.contentItem, i => i.shown !== undefined, [])[0].grabToImage(r => r.saveToFile(root.out + "/dock-" + Quickshell.env("TEST_THEME") + "-menu-" + Math.round(dpr * 100) + ".png"))
      yield 200
    }
    root.note("menu visible: " + (menu && menu.visible))
    if (cue && H) root.check(cue.opacity === 1, "the cue stays on the menu's icon")
    panel.closeMenu()
    yield 200
    root.moveTo(10, 10)
    yield 300

    // ---------------------------------------------------------------------- launch
    root.inject(root.fixtureClients.filter(c => c.class !== "foot"))
    yield 100
    const pinnedFoot = root.cellOf(fkey)
    const row = root.pulseOf(pinnedFoot)
    root.startSampling(() => [row.opacity, pinnedFoot.hop])
    dock.launched(fkey)
    yield 900
    const ls = root.stopSampling()
    const minOpacity = Math.min.apply(null, ls.map(x => x[1][0])), maxHop = Math.max.apply(null, ls.map(x => x[1][1]))
    root.note("launch: tick opacity down to " + minOpacity.toFixed(2) + ", hop up to " + maxHop.toFixed(1))
    if (H) {
      root.check(minOpacity < 0.5 && maxHop === 0, "launch: the mark pulses and the icon stays put")
      root.check(root.marks(pinnedFoot).length > 0, "launch: a mark while nothing is running")
    } else {
      root.check(maxHop > 5 && minOpacity === 1, "plain: launch hops as today")
    }
    root.inject(root.fixtureClients)
    yield 200
    root.check(pinnedFoot.hop === 0 && row.opacity === 1, "a window arriving ends it")

    // ---------------------------------------------------------------------- reveal
    const sl = root.slider()
    const hidden = sl.hiddenOffset
    const frac = v => (hidden - v) / hidden
    const nh = dock.config
    const hideNow = function*() {
      const c = Object.assign({}, nh); c.autohide = "always"; dock.config = c
    }
    yield* hideNow()
    yield 1000
    root.check(Math.abs(sl.offset - hidden) < 0.01, "autohide: parked off the screen")
    root.startSampling(() => sl.offset)
    panel.hovered = true
    yield 800
    let s = root.stopSampling()
    const rEnd = root.settledAt(s, 0)
    root.note("reveal: " + [50, 100, 150, 200, 300].map(ms => ms + " ms " + Math.round(frac(root.at(s, ms)) * 100) + "%").join(", ") + "; all there at " + rEnd + " ms")
    if (H) {
      root.check(frac(root.at(s, 100)) >= 0.9, "reveal: nearly there by 100 ms")
      root.check(rEnd >= 120 && rEnd <= 300, "reveal: in the protocol's range: " + rEnd + " ms")
    } else {
      // As measured on the plain branch before this pass, which doesn't touch it.
      root.check(rEnd > 380 && rEnd < 480, "plain: reveal as today, about 420 ms: " + rEnd + " ms")
    }
    root.snap("mid")
    root.startSampling(() => sl.offset)
    panel.hovered = false
    yield 1100
    s = root.stopSampling()
    const hEnd = root.settledAt(s, hidden)
    root.note("hide after the 350 ms linger: done at " + hEnd + " ms; takes " + (hEnd - 350) + " ms")
    if (H) root.check(hEnd - 350 > 230 && hEnd - 350 < 340, "hide: its own 280 ms, not the reveal's numbers")
    else root.check(hEnd - 350 > 570 && hEnd - 350 < 680, "plain: hide as today, about 620 ms")

    // Through the real strip, with a real pointer.
    root.moveToScreenBottom(centre)
    yield 900
    root.check(panel.hovered && Math.abs(sl.offset) < 0.01, "the 4 px strip reveals it")
    const stayed = root.mouseOf(root.cellOf(nkey)).containsMouse
    root.check(stayed, "and the pointer that revealed it is on the icon")
    root.moveTo(10, 10)
    yield 900

    // ------------------------------------------------------------------ smart hide
    const smart = Object.assign({}, nh); smart.autohide = "smart"; dock.config = smart
    yield 700
    root.check(!panel.overlapped && panel.revealed, "smart: nothing over it, it stays")
    const covering = root.fixtureClients.slice()
    const big = root.client("0xe1", "foot", 1, "1"); big.at = [0, 0]; big.size = [1600, 1000]; big.floating = false
    covering.push(big)
    root.inject(covering)
    yield 700
    root.check(panel.overlapped && !panel.revealed, "smart: a window over it hides it")
    root.inject(root.fixtureClients)
    dock.config = nh
    yield 900

    // -------------------------------------------------------------- reduced motion
    Commons.Style.reduceMotion = true
    yield* hideNow()
    root.startSampling(() => sl.offset)
    yield 300
    s = root.stopSampling()
    root.check(s.every(x => Math.abs(x[1] - hidden) < 0.01 || Math.abs(x[1]) < 0.01) && isFinite(sl.offset), "reduced: hides without travel")
    panel.hovered = true
    root.startSampling(() => sl.offset)
    yield 200
    s = root.stopSampling()
    root.check(s.every(x => Math.abs(x[1] - hidden) < 0.01 || Math.abs(x[1]) < 0.01) && Math.abs(sl.offset) < 0.01, "reduced: reveals without travel")
    panel.hovered = false
    dock.config = nh
    yield 500

    root.moveTo(mid.x, mid.y)
    if (cue) {
      root.startSampling(() => cue.opacity)
      yield 300
      s = root.stopSampling()
      root.check(s.every(x => x[1] === 0 || x[1] === 1), "reduced: the hover cue snaps")
    } else yield 300
    root.moveTo(10, 10)
    yield 200

    root.inject(root.fixtureClients.filter(c => c.class !== "foot"))
    yield 100
    root.startSampling(() => [row.opacity, pinnedFoot.hop])
    dock.launched(fkey)
    yield 400
    const rs = root.stopSampling()
    root.check(rs.every(x => x[1][0] === 1 && x[1][1] === 0), "reduced: launch moves nothing")
    root.check(H ? root.marks(pinnedFoot).length > 0 : root.kid(pinnedFoot, i => i.src !== undefined).opacity === 0.7,
               "reduced: launch still shows")
    yield 1700
    root.check(pinnedFoot.launching === false, "reduced: and it still ends on its own")
    root.inject(root.fixtureClients)
    yield 100

    // A closing app leaves at once.
    root.inject(root.fixtureClients.filter(c => c.class !== "mpv"))
    yield 100
    root.check(root.cellOf(mkey) === null, "reduced: an icon's exit is instant, and its cell is gone")
    root.inject(root.fixtureClients)
    yield 100

    panel.openMenu(root.cellOf(ckey))
    yield 100
    const card = menu ? root.walk(menu.contentItem, i => i.shown !== undefined, [])[0] : null
    if (card) root.check(card.shown === 1 && card.opacity === 1, "reduced: the menu's pop-in is instant")
    panel.closeMenu()
    Commons.Style.reduceMotion = false
    yield 200
    root.check([sl.offset, naut.width, naut.zoom].every(isFinite), "no NaN anywhere after all that")
  }
}
