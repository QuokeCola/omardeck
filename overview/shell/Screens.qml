import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// Every screen as one desktop, kept that way as screens come and go.
//
// With "All screens together" on, each screen owns a block of ten workspaces:
// the laptop's panel 1-10, the others left to right 11-20, 21-30. Hyprland
// knows nothing of the blocks. Unplug a screen and it hands that screen's
// workspaces to one that is left, outside that screen's block, where no
// desktop ever shows them: the strip counts workspace 13 as desktop 3, and
// going to desktop 3 on the laptop goes to an empty workspace 3. And a screen
// that is plugged in comes up on whatever workspace was free.
//
// So after every change of screens, the windows are folded into their own
// desktop on the screen they are now on (13 on the laptop to 3), and every
// screen is put on the desktop the laptop shows. A window folded away from a
// screen is remembered, and goes back to it when that screen returns — as
// long as it is still where it was folded to; one you have moved since has
// found a home of its own.
//
// Done from here rather than from Lua inside Hyprland: Hyprland forgets its
// Lua on every config reload, which is when this matters most (a monitor
// profile applied on resume), and a timer it drops is a fold that never runs.
Item {
  id: screens

  property bool enabled: false

  // Windows folded away from a screen that went, by address: the screen, by
  // its description (a dock can hand it another connector name next time),
  // the desktop it was on there, and the workspace it was folded to.
  property var folded: ({})

  // The screens in their block order the last time they were looked at, by
  // description: block 2 (workspaces 21-30) was the third of them.
  property var lastOrder: []

  // Screens settle in a burst — a dock is several of them, and a monitor
  // profile applied afterwards moves them about — so wait for the burst to
  // end, then look at what is really there.
  Timer {
    id: settle
    interval: 800
    onTriggered: screens.look()
  }

  function soon() { if (screens.enabled) settle.restart() }

  onEnabledChanged: {
    screens.soon()
    if (screens.enabled) screens.bindKeys()
    else if (screens.bound) {
      // Back to whatever the config binds to the number keys.
      screens.bound = false
      unbinder.running = true
    }
  }

  // ------------------------------------------------------- the number keys

  // SUPER + number switches every screen to that desktop (see app/synced.lua),
  // loaded into Hyprland's Lua while the setting is on.
  readonly property string keysFile: {
    const url = Qt.resolvedUrl("../app/synced.lua").toString()
    return url.startsWith("file://") ? url.slice(7) : url
  }
  property bool bound: false
  property bool bindAgain: false
  property int checksLeft: 0

  function bindKeys() {
    if (!screens.enabled) return
    if (binder.running) { screens.bindAgain = true; return }
    const path = screens.keysFile.replace(/\\/g, "\\\\").replace(/"/g, '\\"')
    binder.command = ["/usr/bin/hyprctl", "eval", 'dofile("' + path + '")']
    binder.running = true
  }

  Process {
    id: binder
    onExited: (code) => {
      if (code === 0) screens.bound = true
      if (screens.bindAgain) {
        screens.bindAgain = false
        screens.bindKeys()
        return
      }
      // A reload can land after this without its event reaching us (a
      // monitor daemon at login): look a few times whether they are still
      // there, as the gestures do.
      screens.checksLeft = 5
      keysCheck.restart()
    }
  }

  Timer {
    id: keysCheck
    interval: 2000
    onTriggered: if (screens.enabled && !binder.running && !keysProbe.running) keysProbe.running = true
  }

  Process {
    id: keysProbe
    command: ["/usr/bin/hyprctl", "eval", 'if not _G.__omardeck_synced then error("omardeck: keys gone") end']
    onExited: (code) => {
      if (code !== 0) screens.bindKeys()
      else if (--screens.checksLeft > 0) keysCheck.restart()
    }
  }

  // A reload forgets them; after one has settled, bind them again.
  Timer {
    id: rebind
    interval: 600
    onTriggered: screens.bindKeys()
  }

  Process {
    id: unbinder
    command: ["/usr/bin/hyprctl", "reload"]
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      const name = event.name || ""
      if (name === "monitoradded" || name === "monitoraddedv2"
          || name === "monitorremoved" || name === "monitorremovedv2"
          || name === "configreloaded")
        screens.soon()
      if (name === "configreloaded" && screens.enabled) rebind.restart()
    }
  }

  Process {
    id: query
    command: ["/usr/bin/hyprctl", "-j", "--batch", "monitors; clients"]
    stdout: StdioCollector {
      onStreamFinished: {
        const answers = text.split("\n\n\n").map(s => { try { return JSON.parse(s) } catch (e) { return null } })
        if (Array.isArray(answers[0]) && Array.isArray(answers[1])) screens.align(answers[0], answers[1])
      }
    }
  }

  function look() {
    if (!screens.enabled) return
    if (query.running) { settle.restart(); return }
    query.running = true
  }

  /** The laptop's panel first, then the others left to right. */
  function ordered(monitors) {
    return monitors.filter(m => !m.disabled).slice().sort((a, b) => {
      const al = /^eDP/.test(a.name), bl = /^eDP/.test(b.name)
      if (al !== bl) return al ? -1 : 1
      return a.x - b.x
    })
  }

  function screenId(m) { return String(m.description || m.name) }

  function align(monitors, clients) {
    const order = screens.ordered(monitors)
    if (order.length === 0) return
    const index = ({})
    order.forEach((m, i) => { index[m.id] = i })
    const byId = order.map(m => screens.screenId(m))
    const before = screens.lastOrder
    const kept = Object.assign({}, screens.folded)
    const moves = []

    for (const c of clients) {
      const ws = c.workspace ? c.workspace.id : 0
      const key = String(c.address || "").replace(/^0x/, "")
      if (!(ws > 0) || !/^[0-9a-fA-F]+$/.test(key)) continue
      const here = index[c.monitor]
      if (here === undefined) continue
      const desk = (ws - 1) % 10 + 1

      // Back to the screen it was folded away from, if that screen is back
      // and the window is still where it was folded to.
      const away = kept[key]
      if (away) {
        const home = byId.indexOf(away.screen)
        if (ws !== away.ws) {
          delete kept[key]
        } else if (home >= 0 && home !== here) {
          moves.push({ key: key, ws: away.desk + 10 * home })
          delete kept[key]
          continue
        }
      }

      const want = desk + 10 * here
      if (ws === want) continue
      // Outside this screen's block: from a screen that is gone, remember
      // which, so it can go back.
      const from = before[Math.floor((ws - 1) / 10)]
      if (from && byId.indexOf(from) < 0) kept[key] = { screen: from, desk: desk, ws: want }
      moves.push({ key: key, ws: want })
    }

    // Forget windows that have closed.
    const alive = ({})
    for (const c of clients) alive[String(c.address || "").replace(/^0x/, "")] = true
    for (const key in kept) if (!alive[key]) delete kept[key]

    screens.folded = kept
    screens.lastOrder = byId
    screens.run(order, moves)
  }

  Process { id: dispatch }

  /** The windows to their workspaces and every screen to the laptop's
      desktop, all in one go, with the pointer left where it is. */
  function run(order, moves) {
    const laptop = order[0]
    const shown = laptop.activeWorkspace && laptop.activeWorkspace.id > 0 ? laptop.activeWorkspace.id : 1
    const desk = (shown - 1) % 10 + 1
    const lagging = order.some((m, i) => !m.activeWorkspace || m.activeWorkspace.id !== desk + 10 * i)
    if (!lagging && moves.length === 0) return

    const focused = order.find(m => m.focused) || laptop
    let lua = "local w = hl.get_config('cursor.no_warps'); hl.config({ cursor = { no_warps = true } }); "
    // A window can only be sent to a workspace on a screen that has it: one
    // not made yet is made wherever focus is, and an empty one is gone again
    // as soon as focus leaves it. So on each screen with windows coming, each
    // of their workspaces is made there and filled before moving on.
    const into = ({})
    for (const m of moves) (into[m.ws] = into[m.ws] || []).push(m.key)
    order.forEach((m, i) => {
      if (!/^[A-Za-z0-9_-]+$/.test(m.name)) return
      lua += "hl.dispatch(hl.dsp.focus({ monitor = '" + m.name + "' })); "
      for (const ws in into) {
        if (Math.floor((ws - 1) / 10) !== i) continue
        lua += "hl.dispatch(hl.dsp.focus({ workspace = '" + ws + "', on_current_monitor = true })); "
        // Moving a window hands focus back to the screen it left.
        for (const key of into[ws])
          lua += "hl.dispatch(hl.dsp.window.move({ window = 'address:0x" + key + "', workspace = '" + ws + "', follow = false })); "
               + "hl.dispatch(hl.dsp.focus({ monitor = '" + m.name + "' })); "
      }
      lua += "hl.dispatch(hl.dsp.focus({ workspace = '" + (desk + 10 * i) + "', on_current_monitor = true })); "
    })
    if (/^[A-Za-z0-9_-]+$/.test(focused.name))
      lua += "hl.dispatch(hl.dsp.focus({ monitor = '" + focused.name + "' })); "
    lua += "hl.config({ cursor = { no_warps = w } })"
    dispatch.command = ["/usr/bin/hyprctl", "eval", lua]
    dispatch.running = true
  }
}
