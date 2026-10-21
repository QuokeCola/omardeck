import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "../app/Layout.js" as Layout

// The overview: every window, live, spread out — one surface per screen.
//
// Nothing here is a screenshot. Each thumbnail is a ScreencopyView of the real
// toplevel, so a video keeps playing and a terminal keeps scrolling while you
// look for it.
//
// This half holds what all the screens share: the snapshot of what is on the
// desktop, what you have selected, typed or picked up, and the arithmetic for
// acting on it. Surface.qml draws one screen's worth.
Scope {
  id: root

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

  // ------------------------------------------------- every screen as one desktop

  // With "All screens together" on, each screen keeps a block of ten
  // workspaces — the laptop's own panel 1-10, the others left to right 11-20,
  // 21-30 — and a desktop is the same number in every block: desktop 3 is
  // workspace 3 on the laptop, 13 on the screen left of the rest, 23 on the
  // next. The overview thinks in desktops (the strip, the slide, `wsOf`) and
  // turns one into a workspace only to talk to Hyprland. The SUPER+number
  // bindings that switch every screen at once number them the same way.
  readonly property bool synced: root.service ? root.service.syncScreens : false

  readonly property var screenOrder: (Hyprland.monitors.values || [])
    .map(m => ({ name: m.name, x: m.x, laptop: /^eDP/.test(m.name) }))
    .sort((a, b) => a.laptop !== b.laptop ? (a.laptop ? -1 : 1) : a.x - b.x)
    .map(m => m.name)

  /** The desktop a workspace id is, or the id itself when screens are apart. */
  function deskOfId(id) { return root.synced && id > 0 ? (id - 1) % 10 + 1 : id }

  /** The workspace that is a desktop on a given screen. */
  function spaceOn(desk, monitorName) {
    if (!root.synced || desk <= 0) return desk
    return desk + 10 * Math.max(0, root.screenOrder.indexOf(monitorName))
  }

  readonly property int focusedDesk: Hyprland.focusedWorkspace ? root.deskOfId(Hyprland.focusedWorkspace.id) : -1

  // Every screen to a desktop in one go, the screen you are on last so that it
  // keeps focus — and then, if asked, to a window on it. Pointer warps are off
  // for the trip, as in `focusQuietly`: focusing each screen in turn would
  // otherwise drag the pointer across all of them.
  property var deskWanted: null
  // Running, and a moment after: the focus changes it causes can reach here
  // after hyprctl has already returned.
  readonly property bool deskSwitching: deskSwitch.running || deskSwitchTail.running
  Timer {
    id: deskSwitchTail
    interval: 300
  }
  Process {
    id: deskSwitch
    onRunningChanged: if (!running) {
      deskSwitchTail.restart()
      if (root.deskWanted) {
        const next = root.deskWanted
        root.deskWanted = null
        root.switchDesk(next.desk, next.window)
      }
    }
  }
  function switchDesk(desk, address) {
    if (deskSwitch.running) {
      root.deskWanted = { desk: desk, window: address || "" }
      return
    }
    const lead = root.leadMonitor !== "" ? root.leadMonitor
               : (Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "")
    const names = root.screenOrder.filter(n => n !== lead)
    if (lead !== "") names.push(lead)
    let lua = "local w = hl.get_config('cursor.no_warps'); hl.config({ cursor = { no_warps = true } }); "
    for (const name of names) {
      lua += "hl.dispatch(hl.dsp.focus({ monitor = '" + name + "' })); "
           + "hl.dispatch(hl.dsp.focus({ workspace = '" + root.spaceOn(desk, name) + "', on_current_monitor = true })); "
    }
    if (address) lua += "hl.dispatch(hl.dsp.focus({ window = 'address:0x" + address + "' })); "
    lua += "hl.config({ cursor = { no_warps = w } })"
    deskSwitch.command = ["/usr/bin/hyprctl", "eval", lua]
    deskSwitch.running = true
  }

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

  // Every thumbnail refreshes off this one clock rather than running live.
  // Twelve frames a second is plenty to recognise a window by, and it is what
  // keeps the overview at a few percent of a core instead of half of one.
  property int beat: 0

  // A beat that also reaches the desktops either side of this one, as a slide
  // begins: they come into view a moment later, and a card still showing what
  // its window looked like last time is a window that visibly jumps.
  property bool priming: false
  function prime() {
    root.priming = root.deskSliding || root.active
    root.beat++
    root.priming = false
  }

  // And not at all while the overview is moving. Every capture that lands is
  // a texture upload and a redraw of everything over it, frosted glass
  // included, on frames that are already the busiest there are; a window
  // playing video in the middle of a swipe was paying for both. Nobody reads
  // a thumbnail in flight, so while the fingers are down or a spring is
  // settling the cards hold their frame, and catch up the moment it lands.
  readonly property bool still: root.opened && !root.settling && !root.moving && !root.deskSliding

  Timer {
    interval: 80
    repeat: true
    running: root.still
    onTriggered: root.beat++
  }

  onStillChanged: if (root.still) root.beat++

  // One fresh frame on the way home, though: a closing card hands over to its
  // window in the next few frames, and one a whole swipe stale would show
  // the window jump to the present as it did. Asked for once, as it nears.
  property bool nearHome: false
  property real lastT: 0
  onTChanged: {
    const near = root.opened && root.t < 0.2 && root.t < root.lastT
    if (near && !root.nearHome) root.beat++
    root.nearHome = near
    root.lastT = root.t
  }

  // ------------------------------------------------------------- what is there

  /** Whether a window has focus: first in Hyprland's focus history. Its own
      `activated` can lag a focus change, and a card that thinks the wrong
      window is focused draws the wrong border and glow on the one frame that
      has to match exactly. */
  function isActive(top) {
    const ipc = top.lastIpcObject || {}
    if (ipc.focusHistoryID !== undefined) return ipc.focusHistoryID === 0
    return top.activated === true
  }

  /** The rectangle a window occupies, in its own monitor's logical pixels. */
  function rectOf(top) {
    const ipc = top.lastIpcObject || {}
    const at = ipc.at || [0, 0]
    const size = ipc.size || [0, 0]
    if (size[0] <= 0 || size[1] <= 0) return null
    return { x: at[0], y: at[1], w: size[0], h: size[1], appId: ipc.class || "" }
  }

  // Every window there is, in a plain form the layout can work with.
  //
  // Recomputed whenever Hyprland's model changes, which must never happen while
  // the overview is moving: a new array means the Repeater throws away every
  // delegate and builds new ones, and rebuilding a live capture halfway through
  // a swipe is a visible hitch. So the overview draws from a snapshot taken on
  // the frame the gesture arms, and `sync()` is the only thing that replaces it.
  //
  // Asked for, not bound: only `sync()` reads it, and as a binding it was
  // rebuilt on every change the compositor reported, open or not.
  function liveShot() {
    const out = []
    for (const top of (Hyprland.toplevels.values || [])) {
      if (!top.wayland || !top.workspace || top.workspace.id <= 0) continue
      const rect = root.rectOf(top)
      if (!rect) continue
      const mon = top.monitor
      if (!mon) continue
      out.push({
        key: top.address,
        // The capture handle, not Hyprland's wrapper: ScreencopyView wants the
        // Wayland toplevel, and paints nothing at all if given anything else.
        capture: top.wayland,
        // Hyprland's own, for the caption's live title (see Surface.qml):
        // `geo` leaves the title out, so a window retitling itself — a
        // terminal, every keystroke — does not run it, or anything drawn
        // from it, again.
        top: top,
        title: top.title || "",
        appId: rect.appId,
        workspace: top.workspace.id,
        monitor: mon.name,
        active: root.isActive(top),
        floating: (top.lastIpcObject || {}).floating === true,
        // Hyprland reports global coordinates; a surface covers one monitor.
        x: rect.x - mon.x,
        y: rect.y - mon.y,
        w: rect.w,
        h: rect.h,
      })
    }
    return out
  }

  // Where every window is right now, by address, and how Hyprland is drawing
  // it. The cards take their resting place from here rather than from the
  // snapshot: this changes without rebuilding anything, so a window whose
  // geometry was stale when the swipe began snaps to the truth within a frame
  // or two, and a closing overview flies each card home to wherever its window
  // actually is by then.
  //
  // Rebuilt whenever the compositor answers, which it does on the first frame
  // of every swipe, and mostly with nothing new to say. So what has not
  // changed is handed back as the very object it was: QML passes on no change
  // for that, and nothing drawn from it — every card, the whole layout — runs
  // again. With a dozen windows, running it all again was a 30ms stall right
  // as the overview started to move.
  readonly property var memo: ({ geo: ({}), rects: ({}), plans: ({}) })

  /** `fresh`, or `old` if it says exactly the same thing. Flat objects. */
  function kept(old, fresh) {
    if (!old) return fresh
    for (const k in fresh) if (old[k] !== fresh[k]) return fresh
    for (const k in old) if (!(k in fresh)) return fresh
    return old
  }

  readonly property var geo: {
    const before = root.memo.geo
    let changed = false
    let count = 0
    const out = ({})
    for (const top of (Hyprland.toplevels.values || [])) {
      const rect = root.rectOf(top)
      const mon = top.monitor
      if (!rect || !mon) continue
      const active = root.isActive(top)
      // As Hyprland draws it (see `alphas`). Until it has answered, Omarchy's
      // default: 0.985 focused, 0.96 not, for every window wearing its tag.
      const alpha = root.alphas[top.address]
      const tags = (top.lastIpcObject || {}).tags || []
      const tagged = tags.some(t => String(t).replace(/\*$/, "") === "default-opacity")
      const entry = root.kept(before[top.address], {
        x: rect.x - mon.x,
        y: rect.y - mon.y,
        w: rect.w,
        h: rect.h,
        active: active,
        floating: (top.lastIpcObject || {}).floating === true,
        opacity: alpha ? (active ? alpha.active : alpha.inactive) : (tagged ? (active ? 0.985 : 0.96) : 1),
      })
      if (entry !== before[top.address]) changed = true
      out[top.address] = entry
      count++
    }
    if (!changed && count === Object.keys(before).length) return before
    root.memo.geo = out
    return out
  }

  // Where each window is and nothing else, which is all the layout needs: a
  // terminal retitling itself, or focus moving, changes `geo` but not this,
  // and the spread is not laid out again for it.
  readonly property var rects: {
    const before = root.memo.rects
    const out = ({})
    let changed = false
    let count = 0
    for (const key in root.geo) {
      const g = root.geo[key]
      const entry = root.kept(before[key], { x: g.x, y: g.y, w: g.w, h: g.h })
      if (entry !== before[key]) changed = true
      out[key] = entry
      count++
    }
    if (!changed && count === Object.keys(before).length) return before
    root.memo.rects = out
    return out
  }

  function liveWorkspaces() {
    // Hyprland only makes a workspace once something is on it, so the ones that
    // exist are not the ones you can use. Always offer the first five — the
    // rule the bar follows too — plus any other that exists, so there is
    // somewhere to drag a window to before you have ever been there.
    // With every screen as one desktop, the strip is of desktops: each is
    // somewhere on every screen, and there if any screen has been there.
    const ids = [1, 2, 3, 4, 5]
    for (const id of root.addedDesks) if (ids.indexOf(id) === -1) ids.push(id)
    const existing = Hyprland.workspaces.values || []
    for (const space of existing) {
      const id = root.deskOfId(space.id)
      if (id > 0 && id <= 10 && (root.synced || space.id <= 10) && ids.indexOf(id) === -1) ids.push(id)
    }
    ids.sort((a, b) => a - b)

    const here = root.focusedDesk
    const out = ids.map(id => {
      const real = existing.find(w => w.id > 0 && root.deskOfId(w.id) === id) || null
      return {
        id: id,
        name: !root.synced && real && real.name ? real.name : String(id),
        focused: id === here,
        real: real !== null,
        fresh: false,
        // Which screen it is on, if it exists yet. One that does not will be
        // made on whichever screen switches to it. A desktop is on all of them.
        monitor: !root.synced && real && real.monitor ? real.monitor.name : "",
      }
    })

    // And somewhere to put things when five desktops are not enough.
    const next = ids[ids.length - 1] + 1
    if (next <= 10) {
      out.push({ id: next, name: "+", focused: false, real: false, fresh: true })
    }
    return out
  }

  // What each workspace holds, as fractions of its monitor, so a strip tile can
  // draw the shape of a desktop you are not looking at.
  readonly property var livePlans: {
    const before = root.memo.plans
    const out = ({})
    for (const top of (Hyprland.toplevels.values || [])) {
      const space = top.workspace
      if (!space || space.id <= 0) continue
      const rect = root.rectOf(top)
      if (!rect) continue
      const mon = top.monitor
      if (!mon || mon.scale <= 0) continue
      const width = mon.width / mon.scale
      const height = mon.height / mon.scale
      if (width <= 0 || height <= 0) continue
      if (!out[space.id]) out[space.id] = []
      out[space.id].push({
        x: (rect.x - mon.x) / width,
        y: (rect.y - mon.y) / height,
        w: rect.w / width,
        h: rect.h / height,
        appId: rect.appId,
        active: root.isActive(top),
        key: top.address,
      })
    }
    // The same, as the same objects; see `geo`.
    let changed = Object.keys(out).length !== Object.keys(before).length
    for (const id in out) {
      const was = before[id]
      const now = out[id]
      const same = !!was && was.length === now.length
                   && now.every((p, i) => root.kept(was[i], p) === was[i])
      if (same) out[id] = was
      else changed = true
    }
    if (!changed) return before
    root.memo.plans = out
    return out
  }

  // Windows whose card has flown into a workspace tile and stands in the tile
  // as a live miniature, by address: the tile does not also draw its block.
  property var flown: ({})
  function setFlown(key, on) {
    if ((root.flown[key] === true) === on) return
    const next = Object.assign({}, root.flown)
    if (on) next[key] = true
    else delete next[key]
    root.flown = next
  }

  // What the overview is drawing: the snapshot, never the live models.
  property var shot: []
  property var workspaces: []
  property var plans: ({})

  // The cards are kept between openings, not rebuilt each time: building one
  // opens a capture of its window, and the first frame of a new capture takes
  // long enough that a short swipe was over before the overview could appear.
  // So the snapshot is only replaced when what is there has changed — a
  // window opened, closed, or moved to another desktop — and otherwise the
  // cards, their captures and their last frames are all still there. Where
  // each window is, and what it is called, come from the live model anyway.
  function sameWindows(a, b) {
    if (a.length !== b.length) return false
    // By address, not position: the compositor's list can come back in
    // another order with nothing else changed.
    const byKey = ({})
    for (const y of b) byKey[y.key] = y
    for (const x of a) {
      const y = byKey[x.key]
      if (!y || root.spaceOf(x) !== y.workspace || x.monitor !== y.monitor || x.floating !== y.floating)
        return false
      // Same address, new Wayland toplevel: a window hidden and shown again
      // (Zoom's meeting window around a screen share) keeps its address but
      // gets a new handle, and the old one reads null once it is gone. Kept,
      // that card captures nothing for the rest of the session.
      if (x.capture !== y.capture) return false
    }
    return true
  }

  // Windows sent to another desktop from here, by address: the desktop they
  // went to. Replacing the snapshot to say so would rebuild every card, and a
  // rebuilt card is a blank one until its capture comes back — every window
  // on screen flashing because one of them moved. So the move is written down
  // here instead, and everything asks `wsOf` where a window is.
  property var moved: ({})

  /** The workspace a window is on, as far as the overview is concerned. */
  function spaceOf(win) {
    const to = root.moved[win.key]
    return to !== undefined ? to : win.workspace
  }

  /** The desktop a window is on: its workspace, or with every screen as one
      desktop, the desktop that workspace is part of. */
  function wsOf(win) { return root.deskOfId(root.spaceOf(win)) }

  // How Hyprland stacks windows, by address: 0 at the bottom. Focus does not
  // raise a floating window in Hyprland, so the focus history is not the
  // stacking order; the order `hyprctl clients` lists them in is — it is the
  // order they are drawn in. Asked for each time the overview opens, in the
  // same call as `alphas`.
  property var zOrder: ({})

  // How see-through Hyprland draws each window, by address: { active,
  // inactive }. A capture is the window's own pixels, solid; the opacity is
  // put on in the compositor, so the cards have to put it back on themselves.
  // Asked for rather than guessed from tags: any window rule can set it (a
  // browser at 0.8, an overlay at 0), and only Hyprland knows the result. A
  // rule's value multiplies the decoration's unless it is an override.
  // Asked for each time the overview opens, along with `zOrder`: one hyprctl
  // run rather than two.
  property var alphas: ({})
  readonly property var alphaProps: ["opacity", "opacity_override", "opacity_inactive", "opacity_inactive_override"]
  Process {
    id: alphaQuery
    property var keys: []
    stdout: StdioCollector {
      onStreamFinished: {
        const answers = text.split("\n\n\n").map(s => { try { return JSON.parse(s) } catch (e) { return null } })
        // First, `hyprctl clients`: the order they are drawn in.
        if (Array.isArray(answers[0])) {
          const order = ({})
          answers[0].forEach((c, i) => { order[String(c.address).replace(/^0x/, "")] = i })
          // Only when it changed; see `geo`.
          if (root.kept(root.zOrder, order) !== root.zOrder) root.zOrder = order
        }
        const deco = k => answers[k] && typeof answers[k].float === "number" ? answers[k].float : 1
        const decoActive = deco(1)
        const decoInactive = deco(2)
        const out = ({})
        alphaQuery.keys.forEach((key, i) => {
          const a = answers.slice(3 + i * 4, 7 + i * 4)
          // A window that closed meanwhile answers in words, not JSON.
          if (a.length < 4 || a.some(x => !x)) return
          const active = Math.max(0, Math.min(1, a[1].opacity_override ? a[0].opacity : a[0].opacity * decoActive))
          const inactive = Math.max(0, Math.min(1, a[3].opacity_inactive_override ? a[2].opacity_inactive : a[2].opacity_inactive * decoInactive))
          out[key] = root.kept(root.alphas[key], { active: active, inactive: inactive })
        })
        // Only when it changed; see `geo`.
        const same = Object.keys(out).length === Object.keys(root.alphas).length
                  && Object.keys(out).every(k => out[k] === root.alphas[k])
        if (!same) root.alphas = out
      }
    }
  }

  function askAlphas() {
    if (alphaQuery.running) return
    const keys = (Hyprland.toplevels.values || []).map(t => t.address)
    const asks = ["clients", "getoption decoration:active_opacity", "getoption decoration:inactive_opacity"]
    keys.forEach(k => root.alphaProps.forEach(p => asks.push("getprop address:0x" + k + " " + p)))
    alphaQuery.keys = keys
    alphaQuery.command = ["/usr/bin/hyprctl", "-j", "--batch", asks.join("; ")]
    alphaQuery.running = true
  }

  function sync() {
    root.forgetRealDesks()
    root.askAlphas()
    const next = root.liveShot()
    if (!root.sameWindows(root.shot, next)) {
      root.shot = next
      root.moved = ({})
    }
    root.workspaces = root.liveWorkspaces()
    root.plans = root.livePlans
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
    root.plans = ({})
    root.selectedKey = ""
    root.dragKey = ""
    root.dragTarget = -1
    root.dropOnKey = ""
    root.filter = ""
    root.peek = -1
    root.peekWanted = -1
    root.noPeekId = -1
    root.flown = ({})
    slider.stop()
    slider.value = 0
    slider.velocity = 0
    root.slide = 0
    root.slideGoal = 0
    root.sliding = false
    root.sideOwned = false
    root.stageId = -1
  }

  Connections {
    target: root.service
    function onArming() { root.sync() }
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

  // ------------------------------------------------------------- what you did

  // The window the keyboard is on. The pointer sets it too, so the ring never
  // has to be in two places at once.
  property string selectedKey: ""
  property string dragKey: ""
  property int dragTarget: -1
  property string dropOnKey: ""
  property string filter: ""
  property int peek: -1
  property int peekWanted: -1

  // The surface you are working on, which is the one that answers questions
  // about where things are.
  property var leadSurface: null

  // Picking a window up ends any peek: it is carried over the desktop it
  // came from.
  onDragKeyChanged: if (root.dragKey !== "") {
    peeking.stop()
    root.peekWanted = -1
    root.peek = -1
  }

  function aimDrag(workspaceId, cardKey) {
    root.dragTarget = workspaceId
    // A workspace under the pointer wins: it is the larger, deliberate target.
    root.dropOnKey = workspaceId > 0 ? "" : cardKey
  }

  /** Hovering a workspace shows you what is on it, without going there. */
  //
  // Not while a window is being dragged, though: carrying one to a tile would
  // swap the whole spread for that desktop under the pointer, the windows you
  // are moving it away from vanishing mid-drag — and not over the tile one was
  // just dropped on, until the pointer has left it, or the spread flips to
  // that desktop the moment the window lands.
  property int noPeekId: -1

  function hoverWorkspace(id, entered) {
    const here = root.stageWorkspace
    if (entered) {
      if (id === here || root.moving || root.dragKey !== "" || id === root.noPeekId) return
      root.peekWanted = id
      peeking.restart()
    } else if (id === root.noPeekId) {
      root.noPeekId = -1
    } else if (root.peekWanted === id) {
      peeking.stop()
      root.peekWanted = -1
      root.peek = -1
    }
  }

  // Long enough that crossing the strip on the way somewhere does not flick
  // through every desktop you pass, and no longer. It used to be 320ms, from
  // when a peek tore down every card and rebuilt it: the wait hid the rebuild.
  // The cards survive a peek now, so the only thing left to cover is the
  // pointer passing over a tile it was never aiming at.
  Timer {
    id: peeking
    interval: 130
    onTriggered: root.peek = root.peekWanted
  }

  // ------------------------------------------------------ sliding sideways

  // Three fingers left or right with the overview open slides the whole spread
  // over to the next workspace, and the one after it comes in from the side —
  // following the fingers, so stopping half way shows half of each, and
  // letting go there goes back. The strip's ring slides with it.
  //
  // Nothing is rebuilt to do this. Every workspace's cards already exist and
  // are already laid out in the same area (that is what makes peeking a
  // cross-fade); sliding only moves each one sideways by how many workspaces
  // it is away from the middle of the screen.

  // The workspace the spread is centred on. Set when the overview opens and
  // moved by sliding, rather than read from the compositor, because the
  // compositor only hears about a switch after the slide has shown it.
  property int stageId: -1
  readonly property int stageWorkspace: root.stageId > 0 ? root.stageId : root.focusedDesk

  // The workspaces you can slide through: the strip, less the "+" at its end.
  //
  // Only this screen's, as Hyprland's own swipe does: the ones already on it,
  // and the ones that do not exist yet (switching to one makes it here). A
  // workspace on the other screen is not the next desktop here — going to it
  // moves focus to that screen, and the slide on this one snaps back.
  readonly property var lanes: root.workspaces
    .filter(w => !w.fresh && (w.monitor === "" || w.monitor === root.leadMonitor))
    .map(w => w.id)

  /** Where the strip's ring sits for a position along `lanes`, which can fall
      between two tiles that are not next to each other in the strip. */
  function laneTile(position) {
    const count = root.lanes.length
    if (count === 0) return 0
    const tileOf = id => Math.max(0, root.workspaces.findIndex(w => w.id === id))
    if (count === 1) return tileOf(root.lanes[0])
    const i = Math.max(0, Math.min(count - 2, Math.floor(position)))
    const from = tileOf(root.lanes[i])
    const to = tileOf(root.lanes[i + 1])
    return from + (to - from) * (position - i)
  }
  readonly property int stageIndex: root.lanes.indexOf(root.stageWorkspace)

  // How far through the slide, in workspaces: 0.3 is a third of the way to the
  // next one, -1 is all the way to the previous.
  property real slide: 0
  // Fingers down on a slide.
  property bool sliding: false
  // Sliding or settling: the cards must follow `slide` exactly rather than
  // animate toward it.
  readonly property bool moving: root.sliding || slider.running
  // Whether the swipe in progress is one this overview took on.
  property bool sideOwned: false
  property real slideFrom: 0

  /** Where a workspace's spread sits, in screen widths from the middle. */
  function laneOf(workspaceId) {
    const index = root.lanes.indexOf(workspaceId)
    if (index < 0 || root.stageIndex < 0) return 99
    return index - (root.stageIndex + root.shownSlide)
  }

  // Where the slide is drawn: held at nothing until the overview can appear,
  // then let catch up, for the same reason as `t` — on the desktop the fingers
  // are already a fair way across by the time every capture is in.
  readonly property real shownSlide: root.slide * root.reveal

  // Sliding is for the one-desktop spread. Every window at once, or a search
  // across every desktop, has nothing to slide between.
  readonly property bool canSlide: (root.active || root.deskSliding) && !root.everything && root.filter === "" && root.appOnly === ""
                                   && root.dragKey === "" && root.stageIndex >= 0
  // Sliding on the bare desktop, the overview up at no zoom just for it.
  readonly property bool deskSliding: root.service ? root.service.deskSlide : false

  // The desktop slide is over, landed or sprung back: put the overview away,
  // which hands the screen back to the real windows exactly where the cards
  // stand.
  function endDeskSlide() {
    if (!root.service || !root.service.deskSlide) return
    // Not until the compositor is on the desktop the slide landed on, or for a
    // frame the old one shows through as the overview goes.
    const here = root.focusedDesk
    if (root.stageId > 0 && here !== root.stageId) {
      switchWait.restart()
      return
    }
    switchWait.stop()
    root.service.deskSlide = false
  }

  Connections {
    target: Hyprland
    function onFocusedWorkspaceChanged() { if (switchWait.running) root.endDeskSlide() }
  }

  // However long the compositor takes, not longer than this.
  Timer {
    id: switchWait
    interval: 250
    onTriggered: if (root.service) root.service.deskSlide = false
  }

  // Past the first or last workspace, and past one workspace per swipe, it
  // gives a little and no more, the way a scroll view does at its ends.
  // The same stretch as swiping up past open: one-to-one at first, then less
  // and less, springing back when the fingers lift.
  readonly property real give: 0.3
  function stretched(over) { return root.give * (1 - 1 / (1 + over / root.give)) }
  function bounded(value) {
    const low = Math.max(-1, -root.stageIndex)
    const high = Math.min(1, root.lanes.length - 1 - root.stageIndex)
    if (value > high) return high + root.stretched(value - high)
    if (value < low) return low - root.stretched(low - value)
    return value
  }

  Connections {
    target: root.service
    function onSideSwipe(phase, value, velocity, cancelled) { root.onSide(phase, value, velocity, cancelled) }
    function onJumpRequested(address) { root.jumpToWindow(address) }
    function onStepRequested(step) {
      if (!root.canSlide) {
        root.endDeskSlide()
        return
      }
      root.slideBy(step)
      // Nowhere to go that way: nothing moved, so nothing will land.
      if (!root.moving) root.endDeskSlide()
    }
  }

  function onSide(phase, value, velocity, cancelled) {
    switch (phase) {
    case "begin":
      root.sideOwned = root.canSlide
      if (!root.sideOwned) {
        root.endDeskSlide()
        return
      }
      // Caught mid-settle: finish that slide where it was heading first, so
      // this one starts from a whole workspace.
      if (slider.running) {
        slider.stop()
        root.finishSlide(slider.target)
      }
      peeking.stop()
      root.peek = -1
      root.peekWanted = -1
      root.prime()
      root.slideFrom = root.slide
      root.slideGoal = root.slide
      root.slideSpeed = 0
      root.slideAt = 0
      slider.hold()
      slider.value = root.slide
      slider.velocity = 0
      root.sliding = true
      sideWatchdog.restart()
      break

    case "move":
      if (!root.sideOwned) return
      root.slideGoal = root.bounded(root.slideFrom + value)
      slider.chase(root.slideGoal, root.chaseSpeed)
      {
        const now = Date.now()
        const dt = (now - root.slideAt) / 1000
        root.slideSpeed = root.slideAt > 0 && dt > 0 && dt < 0.1
          ? root.slideSpeed * 0.6 + 0.4 * (root.slideGoal - root.slideLast) / dt : 0
        root.slideLast = root.slideGoal
        root.slideAt = now
      }
      sideWatchdog.restart()
      break

    case "end":
      if (!root.sideOwned) return
      root.sideOwned = false
      sideWatchdog.stop()
      // The speed the spread had on screen as the fingers lifted, the same
      // as swiping up: none if they had come to rest first.
      //
      // Or the gesture's own measure, if that is faster: it is taken over the
      // last 90ms, where the on-screen speed is smoothed from zero, which on a
      // swipe only a few events long reads a real flick as a slow drag.
      {
        const resting = Date.now() - root.slideAt > 80
        const seen = resting ? 0 : root.slideSpeed
        const measured = resting ? 0 : velocity
        root.releaseSlide(cancelled ? 0 : (Math.abs(measured) > Math.abs(seen) ? measured : seen), cancelled)
      }
      break
    }
  }

  // Past half way it goes on; short of it, a flick in the same direction
  // still does. A flick back the other way always wins.
  // In workspaces per second, so it scales with how far a workspace is.
  readonly property real slideFlick: 1.2
  // The fastest the spread follows the fingers sideways, in workspaces a
  // second: an ordinary swipe is 2 to 5, a flick 30 and more. See
  // Spring.chase.
  readonly property real chaseSpeed: 7
  // Where the fingers have put the slide, and how fast it was moving on
  // screen, in workspaces per second.
  property real slideGoal: 0
  property real slideSpeed: 0
  property real slideLast: 0
  property double slideAt: 0

  function releaseSlide(velocity, cancelled) {
    const at = root.slideGoal
    let to = 0
    if (!cancelled) {
      const dir = at !== 0 ? Math.sign(at) : Math.sign(velocity)
      const flung = Math.abs(velocity) > root.slideFlick
      if (flung && Math.sign(velocity) !== dir) to = 0
      else if (Math.abs(at) > 0.5 || (flung && Math.abs(at) > 0.03)) to = dir
    }
    // A jump goes all the way, through the desktops in between.
    if (root.jumpTo !== 0 && !cancelled) to = root.jumpTo
    root.jumpTo = 0
    const next = root.stageIndex + to
    if (next < 0 || next >= root.lanes.length) to = 0


    // Let go, the spring loosens and lands with a bounce, keeping the speed
    // it had — topped up by a flick faster than it had caught up to.
    root.slideGoal = to
    if (!slider.running) slider.value = root.slide
    slider.stiffness = 52
    slider.damping = 2.0
    // Still catching up with a flick: on at the speed it is moving.
    slider.velocity = Math.max(-6, Math.min(6, slider.lagging ? slider.velocity : velocity))
    // Running before the fingers are let go of, so the cards never see a
    // frame where neither is moving them.
    slider.follow(to)
    root.sliding = false
  }

  // A jump in progress: how many desktops over to land, and the window to
  // focus when it does (address without 0x).
  property int jumpTo: 0
  property string landOn: ""
  property string pendingJump: ""
  onRevealChanged: if (root.reveal >= 1 && root.pendingJump !== "") {
    const address = root.pendingJump
    root.pendingJump = ""
    jumpWait.stop()
    root.jumpToWindow(address)
  }
  // Never ready: go there without the slide.
  Timer {
    id: jumpWait
    interval: 500
    onTriggered: if (root.pendingJump !== "") {
      const address = root.pendingJump
      root.pendingJump = ""
      root.endDeskSlide()
      Hyprland.dispatch('hl.dsp.focus({ window = "address:0x' + address + '" })')
    }
  }

  /** Slide, however many desktops over, to the one a window is on, and land
      on that window. Its own desktop, or one this screen cannot slide to:
      just focus it. */
  function jumpToWindow(address) {
    // Not before the overview is up and matching the desktop: a gesture
    // catches up with the fingers, but a jump started now would have slid a
    // desktop over unseen by the time the captures are in, and open on a cut.
    if (root.reveal < 1) {
      root.pendingJump = address
      jumpWait.restart()
      return
    }
    const top = (Hyprland.toplevels.values || []).find(t => t.address === address)
    const ws = top && top.workspace ? top.workspace.id : 0
    const index = ws > 0 ? root.lanes.indexOf(root.deskOfId(ws)) : -1
    const step = index - root.stageIndex
    if (!root.canSlide || root.sliding || index < 0 || root.stageIndex < 0 || step === 0) {
      root.endDeskSlide()
      Hyprland.dispatch('hl.dsp.focus({ window = "address:0x' + address + '" })')
      return
    }
    root.landOn = address
    root.jumpTo = step
    root.slideBy(Math.sign(step))
    if (!root.moving) {
      root.jumpTo = 0
      root.landOn = ""
      root.endDeskSlide()
    }
  }

  /** Slide one workspace over from the keyboard. */
  function slideBy(step) {
    if (!root.canSlide || root.sliding) return
    if (slider.running) {
      slider.stop()
      root.finishSlide(slider.target)
    }
    root.peek = -1
    root.slideFrom = 0
    // As if the fingers had carried it just past half way: the spring still
    // starts from where the spread is, and does the whole trip itself.
    root.slideGoal = step * 0.51
    root.releaseSlide(step * 4, false)
  }

  // Landed: the neighbour is now the middle. Moving the stage and zeroing the
  // slide leaves every card exactly where it already was.
  function finishSlide(to) {
    if (to !== 0) {
      const next = root.lanes[root.stageIndex + to]
      if (next !== undefined) {
        // Only now, with the slide landed and the overview covering all of
        // it. Told at the lift, the compositor switched at once — and on a
        // short swipe the overview was not up yet, so the desktop simply
        // vanished before the slide it was meant to be hidden behind.
        const landOn = root.landOn
        if (root.synced) root.switchDesk(next, landOn)
        else {
          Hyprland.dispatch('hl.dsp.focus({ workspace = "' + next + '" })')
          if (landOn !== "") Hyprland.dispatch('hl.dsp.focus({ window = "address:0x' + landOn + '" })')
        }
        root.stageId = next
        // The selection moves to the desktop you are looking at, so enter
        // goes somewhere on it.
        const active = root.shot.find(w => root.wsOf(w) === next && w.active)
                    || root.shot.find(w => root.wsOf(w) === next)
        root.selectedKey = active ? active.key : ""
      }
    }
    root.slide = 0
    root.landOn = ""
  }

  Spring {
    id: slider
    onValueChanged: root.slide = slider.value
    // Fingers resting mid-slide let the spring settle too; that is not a
    // landing.
    onSettled: if (!root.sliding) {
      root.finishSlide(slider.target)
      root.endDeskSlide()
    }
  }

  // A lift that never arrives must not leave the spread half way between two
  // desktops.
  Timer {
    id: sideWatchdog
    interval: 1400
    onTriggered: if (root.sliding) {
      root.sideOwned = false
      root.releaseSlide(0, false)
    }
  }

  readonly property string appOnly: root.service ? root.service.appOnly : ""

  function matches(win) {
    if (root.appOnly !== "" && String(win.appId || "").toLowerCase() !== root.appOnly) return false
    if (root.filter === "") return true
    const needle = root.filter.toLowerCase()
    return String(win.title || "").toLowerCase().indexOf(needle) >= 0
        || String(win.appId || "").toLowerCase().indexOf(needle) >= 0
  }

  /**
   * The icon an app id resolves to, or "". Only a plain icon-theme name is looked up: the window class is chosen by
   * the app itself, and an absolute path there (or in a desktop entry found by it) would hand the shell's image
   * decoder whatever file that app likes. Anything else gets the generic icon.
   */
  function iconName(name) {
    return typeof name === "string" && /^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$/.test(name) ? name : ""
  }

  function iconFor(appId) {
    if (!appId) return ""
    const entry = DesktopEntries.heuristicLookup(appId)
    const name = root.iconName(entry && entry.icon ? entry.icon : appId)
    return name ? (Quickshell.iconPath(name, true) || "") : ""
  }

  // ------------------------------------------------------------ acting on it

  function dismiss() { if (root.service) root.service.hide() }

  // Going somewhere from the overview makes that desktop the one the overview
  // is showing before it closes, so it closes onto what the screen will
  // actually show: that desktop's windows fly home, not the ones of the
  // desktop it was opened on.
  function focusWindow(address) {
    if (!address) return
    const win = root.shot.find(w => w.key === address)
    if (win) root.stageId = root.wsOf(win)
    root.peek = -1
    // Every screen to that window's desktop, not just the one it is on.
    if (root.synced && win) root.switchDesk(root.wsOf(win), address)
    else Hyprland.dispatch('hl.dsp.focus({ window = "address:0x' + address + '" })')
    root.dismiss()
  }

  // Desktops added from the strip's "+" that nothing is on yet. Hyprland
  // only keeps a workspace with something on it, so they are the overview's
  // to remember: there to drag a window to, or slide to, until then.
  property var addedDesks: []
  // The one just added, for the strip to drop its tile in, and how many tiles
  // longer the strip got (none once "+" has run out at 10).
  property int justAdded: -1
  signal deskAdded(int id, int grew)
  Timer { id: addedSettle; interval: 700; onTriggered: root.justAdded = -1 }

  // Once you have been on an added desktop and left, it is Hyprland's: kept
  // if something is on it, gone if not, as any other workspace would be.
  // Likewise once a window has been put on it, which makes it a real one.
  property int lastDesk: root.focusedDesk
  onFocusedDeskChanged: {
    const left = root.lastDesk
    root.lastDesk = root.focusedDesk
    if (root.addedDesks.indexOf(left) !== -1) root.addedDesks = root.addedDesks.filter(id => id !== left)
  }
  function forgetRealDesks() {
    const real = (Hyprland.workspaces.values || []).filter(w => w.id > 0).map(w => root.deskOfId(w.id))
    const kept = root.addedDesks.filter(id => real.indexOf(id) === -1)
    if (kept.length !== root.addedDesks.length) root.addedDesks = kept
  }

  function addWorkspace(id) {
    if (id <= 0 || id > 10 || root.addedDesks.indexOf(id) !== -1) return
    const before = root.workspaces.length
    root.addedDesks = root.addedDesks.concat([id])
    root.justAdded = id
    addedSettle.restart()
    root.workspaces = root.liveWorkspaces()
    root.deskAdded(id, root.workspaces.length - before)
  }

  function goToWorkspace(id, monitorName) {
    // The "+" at the end makes another desktop and stays in the overview.
    const tile = root.workspaces.find(w => w.id === id)
    if (tile && tile.fresh) {
      root.addWorkspace(id)
      return
    }
    root.stageId = id
    root.peek = -1
    if (root.synced) {
      root.switchDesk(id)
      root.dismiss()
      return
    }
    // A desktop that does not exist yet is made on whichever screen has
    // focus: the one whose tile was clicked, then.
    const exists = (Hyprland.workspaces.values || []).some(w => w.id === id)
    if (!exists && monitorName) Hyprland.dispatch('hl.dsp.focus({ monitor = "' + monitorName + '" })')
    Hyprland.dispatch('hl.dsp.focus({ workspace = "' + id + '" })')
    root.dismiss()
  }

  // ------------------------------------------------------ the screen in use

  /** The pointer has moved to another screen: that screen leads now — the
      keyboard, the strip's peeking and dropping, sliding through its own
      desktops — rather than leaving it a picture you can only look at. */
  function leadTo(name) {
    if (!name || !root.service || name === root.leadMonitor) return
    if (root.moving || root.dragKey !== "" || !root.active) return
    const mon = (Hyprland.monitors.values || []).find(m => m.name === name)
    peeking.stop()
    root.peek = -1
    root.peekWanted = -1
    root.noPeekId = -1
    // One desktop across every screen: changing screens does not change it.
    if (!root.synced || root.stageId <= 0)
      root.stageId = mon && mon.activeWorkspace ? root.deskOfId(mon.activeWorkspace.id) : -1
    root.service.monitorName = name
  }

  // Hyprland moves its focused monitor to whichever screen the pointer is
  // on, so that is the one to follow.
  Connections {
    target: Hyprland
    function onFocusedMonitorChanged() {
      // Not while `switchDesk` is walking focus across every screen: that is
      // not the pointer going anywhere, and following it handed the lead to
      // each screen in turn, still on the desktop it was leaving.
      if (root.deskSwitching) return
      if (root.active && Hyprland.focusedMonitor) root.leadTo(Hyprland.focusedMonitor.name)
    }
  }

  // The pointer can reach another screen while the overview is still on its
  // way up, when the move above does not count. Once open, catch up: only the
  // leading screen takes the keyboard, and Hyprland gives the pointer to no
  // other surface while one has it exclusively, so the screen you went to
  // ignored the pointer altogether.
  onActiveChanged: if (root.active && Hyprland.focusedMonitor) root.leadTo(Hyprland.focusedMonitor.name)

  /** Pointing at a window focuses it, so the overview closes onto the window
      you were last looking at — but only one on the desktop its screen is
      showing: focusing a window elsewhere would switch that screen's desktop
      underneath the overview. */
  function hoverFocus(key) {
    if (!root.active || root.dragKey !== "" || root.moving) return
    const top = (Hyprland.toplevels.values || []).find(t => t.address === key)
    if (!top || !top.workspace || !top.monitor) return
    const showing = top.monitor.activeWorkspace
    if (!showing || showing.id !== top.workspace.id || root.isActive(top)) return
    root.focusQuietly(key)
  }

  // Focusing a window makes Hyprland warp the pointer to the middle of the
  // real window — which, under the overview, is somewhere else entirely, and
  // likely over another card. So pointer warps are switched off for exactly
  // that one dispatch, and put back as they were, in one go.
  property string focusWanted: ""
  Process {
    id: quietFocus
    onRunningChanged: if (!running && root.focusWanted !== "") root.focusQuietly(root.focusWanted)
  }
  function focusQuietly(key) {
    if (quietFocus.running) {
      root.focusWanted = key
      return
    }
    root.focusWanted = ""
    quietFocus.command = ["/usr/bin/hyprctl", "eval",
      "local w = hl.get_config('cursor.no_warps'); hl.config({ cursor = { no_warps = true } }); "
      + "hl.dispatch(hl.dsp.focus({ window = 'address:0x" + key + "' })); "
      + "hl.config({ cursor = { no_warps = w } })"]
    quietFocus.running = true
  }

  function closeWindow(address) {
    if (!address) return
    Hyprland.dispatch('hl.dsp.window.close({ window = "address:0x' + address + '" })')
    if (root.selectedKey === address) root.selectedKey = ""
    if (root.service) root.service.refreshModels()
    resettle.restart()
  }

  function drop(address) {
    const space = root.dragTarget
    const onto = root.dropOnKey
    root.dragTarget = -1
    root.dropOnKey = ""
    if (!address) return

    // With every screen as one desktop, a tile is that desktop on the screen
    // the window is on: dropped there, it changes desktop, not screen.
    const win = root.shot.find(w => w.key === address)
    const here = root.synced && win ? root.wsOf(win) : root.focusedDesk
    const target = root.synced && win ? root.spaceOn(space, win.monitor) : space
    if (space > 0 && space !== here) {
      // Without following it: moving a window takes the screen to its new
      // desktop by default, which switched the real desktop underneath the
      // overview — flashing as it went, and handing back to the wrong desktop
      // when the overview closed.
      Hyprland.dispatch('hl.dsp.window.move({ window = "address:0x' + address
                        + '", workspace = "' + target + '", follow = false })')
      root.noPeekId = space
      // Nothing left selected on this desktop that has gone to another.
      if (root.selectedKey === address) root.selectedKey = ""
      // Gone from this desktop now, not when the compositor has said so.
      const next = Object.assign({}, root.moved)
      next[address] = target
      root.moved = next
    } else if (onto && onto !== address) {
      // Dropped on another window: they trade places in the tiling layout.
      Hyprland.dispatch('hl.dsp.window.swap({ window = "address:0x' + address
                        + '", target = "address:0x' + onto + '" })')
    } else {
      return
    }
    // The overview stays open, the way it does on a Mac: you are usually
    // moving more than one thing.
    if (root.service) root.service.refreshModels()
    resettle.restart()
  }

  function moveSelection(dx, dy) {
    const surface = root.leadSurface
    if (!surface) return
    const placed = []
    for (const win of surface.shownWindows) {
      const slot = surface.slots[win.key]
      if (slot) placed.push({ key: win.key, x: slot.x, y: slot.y, w: slot.w, h: slot.h })
    }
    const next = Layout.nextIn(placed, root.selectedKey, dx, dy)
    if (next) root.selectedKey = next
  }

  /** What enter acts on: the selection, as long as the filter leaves it
      standing, and otherwise the first window that it does.

      The selection is seeded with the window you were already using, so that
      enter straight away puts you back. Typing has to move it: a selection left
      behind on a window the filter has hidden is invisible, and enter on an
      invisible selection re-focuses the window you started from -- which is
      what "type a name, press enter" used to do, silently, whenever the window
      you were looking for was on another desktop. */
  function enterTarget() {
    const surface = root.leadSurface
    if (!surface) return root.selectedKey
    const shown = surface.shownWindows
    if (!shown.length) return ""            // nothing matches: enter has nothing to act on
    if (root.selectedKey && shown.some(w => w.key === root.selectedKey)) return root.selectedKey
    return shown[0].key
  }

  // Typing moves the selection with it, so what enter will do is also what you
  // can see highlighted, rather than something decided off-screen.
  onFilterChanged: {
    const target = root.enterTarget()
    if (target) root.selectedKey = target
  }

  function onKey(event) {
    const plain = !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))

    switch (event.key) {
    case Qt.Key_Escape:
      // Clear what you typed first; the second press puts the overview away.
      if (root.filter !== "") root.filter = ""
      else root.dismiss()
      break
    case Qt.Key_Backspace:
      root.filter = root.filter.slice(0, -1)
      break
    case Qt.Key_Left:
      if (event.modifiers & Qt.ControlModifier) root.slideBy(-1)
      else root.moveSelection(-1, 0)
      break
    case Qt.Key_Right:
      if (event.modifiers & Qt.ControlModifier) root.slideBy(1)
      else root.moveSelection(1, 0)
      break
    case Qt.Key_Up:
      root.moveSelection(0, -1)
      break
    case Qt.Key_Down:
      root.moveSelection(0, 1)
      break
    case Qt.Key_Return:
    case Qt.Key_Enter:
      // Typing until one window is left and pressing enter is the fastest way
      // through here, so that case does not need aiming first.
      root.focusWindow(root.enterTarget())
      break
    case Qt.Key_W:
      if (event.modifiers & Qt.ControlModifier) root.closeWindow(root.selectedKey)
      else if (plain && event.text) root.filter += event.text
      else return
      break
    case Qt.Key_Q:
      if (event.modifiers & Qt.ControlModifier) root.dismiss()
      else if (plain && event.text) root.filter += event.text
      else return
      break
    default:
      // Anything else you can type narrows the spread.
      if (plain && event.text && event.text.length === 1 && event.text >= " ") {
        root.filter += event.text
      } else {
        return
      }
    }
    event.accepted = true
  }

  // One overview per screen. A second monitor that merely dimmed while you look
  // for a window on it would be worse than not covering it at all.
  Variants {
    model: Quickshell.screens

    delegate: Surface {
      required property var modelData
      overlay: root
      screenInfo: modelData
      onLeadingChanged: if (leading) root.leadSurface = this
      Component.onCompleted: if (leading) root.leadSurface = this
    }
  }
}
