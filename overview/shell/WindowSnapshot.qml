import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

// What is on the desktop: the snapshot the overview draws, and live beside it,
// where each window is and how Hyprland draws it. `geo` reads `alphas` and the
// cards read `geo`, handed back as the very same objects when nothing changed,
// so all of this lives together.
Scope {
  id: root

  // The overlay this is part of, for what the other parts hold.
  required property var overlay

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
        fullscreen: ((top.lastIpcObject || {}).fullscreen || 0) > 0,
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
      // A titlebar above it (see `bars` in Deco.js), which Hyprland leaves out of
      // the window's own rectangle. Not on a fullscreen window; a maximized one
      // keeps it.
      const deco = root.overlay.deco
      const barred = deco.bars === true && ((top.lastIpcObject || {}).fullscreen || 0) < 2
                  && (deco.barTag === "" || tags.some(t => String(t).replace(/\*$/, "") === deco.barTag))
      const entry = root.kept(before[top.address], {
        x: rect.x - mon.x,
        y: rect.y - mon.y,
        w: rect.w,
        h: rect.h,
        active: active,
        floating: (top.lastIpcObject || {}).floating === true,
        fullscreen: ((top.lastIpcObject || {}).fullscreen || 0) > 0,
        opacity: alpha ? (active ? alpha.active : alpha.inactive) : (tagged ? (active ? 0.985 : 0.96) : 1),
        // Omarchy turns the global shadow on for floating workspaces and opts
        // every other window out, so the option alone doesn't say who has one.
        shadow: alpha ? alpha.shadow : false,
        bar: barred ? deco.barHeight : 0,
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

  // What the overview is drawing: the snapshot, never the live models.
  property var shot: []

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
      if (!y || root.spaceOf(x) !== y.workspace || root.screenOf(x) !== y.monitor || x.floating !== y.floating)
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

  // The same, for windows carried to another screen: the screen they went
  // to. A window's card belongs to its screen's surface; moved there, its card
  // is built anew on that screen and nothing else is rebuilt.
  property var movedScreen: ({})

  /** The screen a window is on, as far as the overview is concerned. */
  function screenOf(win) {
    const to = root.movedScreen[win.key]
    return to !== undefined ? to : win.monitor
  }

  /** The workspace a window is on, as far as the overview is concerned. */
  function spaceOf(win) {
    const to = root.moved[win.key]
    return to !== undefined ? to : win.workspace
  }

  /** The desktop a window is on: its workspace, or with every screen as one
      desktop, the desktop that workspace is part of. */
  function wsOf(win) { return overlay.deskOfId(root.spaceOf(win)) }

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
  readonly property var alphaProps: ["opacity", "opacity_override", "opacity_inactive", "opacity_inactive_override", "no_shadow"]
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
          const count = root.alphaProps.length
          const a = answers.slice(3 + i * count, 3 + (i + 1) * count)
          // A window that closed meanwhile answers in words, not JSON.
          if (a.length < count || a.some(x => !x)) return
          const active = Math.max(0, Math.min(1, a[1].opacity_override ? a[0].opacity : a[0].opacity * decoActive))
          const inactive = Math.max(0, Math.min(1, a[3].opacity_inactive_override ? a[2].opacity_inactive : a[2].opacity_inactive * decoInactive))
          out[key] = root.kept(root.alphas[key], { active: active, inactive: inactive, shadow: !a[4].no_shadow })
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

  // A new look at what is there, for `sync()`: how Hyprland draws everything, asked
  // for, and the snapshot replaced if something changed.
  function take() {
    root.askAlphas()
    const next = root.liveShot()
    if (!root.sameWindows(root.shot, next)) {
      root.shot = next
      root.moved = ({})
      root.movedScreen = ({})
    }
  }
}
