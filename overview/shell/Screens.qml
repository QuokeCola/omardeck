import QtQuick
import Quickshell.Io
import Quickshell.Hyprland
import "../app/Desks.js" as Desks
import "../app/HyprLua.js" as HyprLua

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

  property alias active: keys.active

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
    onTriggered: {
      screens.followFocus = false
      screens.look()
    }
  }

  function soon() { if (screens.active) settle.restart() }

  // ------------------------------------------------ one screen went somewhere

  // A desktop chosen on one screen by anything that is not ours — the bar's
  // workspace buttons, SUPER + Tab, a script — changes only that screen.
  // Bring the others along: once the workspace events have stopped, every
  // screen goes to the desktop the focused one is on. Our own switches leave
  // every screen on one desktop already, so they find nothing to do.
  //
  // Not while screens are coming and going: a screen just plugged in is
  // focused on whatever workspace was free, and that is not a choice.
  property bool followFocus: false

  Timer {
    id: follow
    interval: 150
    onTriggered: {
      if (!screens.active || settle.running) return
      screens.followFocus = true
      screens.look()
    }
  }

  onActiveChanged: {
    screens.soon()
    if (screens.active) screens.bindKeys()
    else screens.unbindKeys()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      const name = event.name || ""
      if (name === "monitoradded" || name === "monitoraddedv2"
          || name === "monitorremoved" || name === "monitorremovedv2"
          || name === "configreloaded")
        screens.soon()
      else if (screens.active && (name === "workspacev2" || name === "workspace"))
        follow.restart()
      // A reload forgets the number keys; after one has settled, bind them again.
      if (name === "configreloaded" && screens.active) keys.loadSoon()
    }
  }

  Process {
    id: query
    command: ["/usr/bin/hyprctl", "-j", "--batch", "monitors; clients"]
    stdout: StdioCollector {
      onStreamFinished: screens.takeAnswer(text)
    }
  }

  function look() {
    if (!screens.active) return
    if (query.running) {
      if (screens.followFocus) {
        screens.followFocus = false
        follow.restart()
      } else settle.restart()
      return
    }
    query.running = true
  }

  function takeAnswer(text) {
    const answers = text.split("\n\n\n").map(s => { try { return JSON.parse(s) } catch (e) { return null } })
    const lead = screens.followFocus ? "focused" : "laptop"
    screens.followFocus = false
    if (Array.isArray(answers[0]) && Array.isArray(answers[1])) screens.align(answers[0], answers[1], lead)
  }

  /** The windows to their workspaces and every screen to the desktop of the
      laptop — or, with `lead` "focused", of the screen in use — all in one go,
      with the pointer left where it is. */
  function align(monitors, clients, lead) {
    const plan = Desks.planFold(monitors, clients, screens.folded, screens.lastOrder)
    if (!plan) return
    screens.folded = plan.folded
    screens.lastOrder = plan.lastOrder

    const to = Desks.deskToShow(plan.order, lead)
    if (!to.lagging && plan.moves.length === 0) return
    dispatch.command = ["/usr/bin/hyprctl", "eval", HyprLua.alignScript(plan.order, plan.moves, to.desk, to.focused.name)]
    dispatch.running = true
  }

  Process { id: dispatch }

  // ------------------------------------------------------- the number keys

  // SUPER + number switches every screen to that desktop (see app/synced.lua),
  // loaded into Hyprland's Lua while the setting is on. Off until asked: `active`
  // is an alias of this module's, so it is already set when onActiveChanged loads.
  LuaModule {
    id: keys
    file: Qt.resolvedUrl("../app/synced.lua")
    guard: "__omardeck_synced"
    goneMessage: "omardeck: keys gone"
    active: false
    onEvaluated: (code) => { if (code === 0) screens.bound = true }
  }

  property bool bound: false

  function bindKeys() { keys.load() }

  // Back to whatever the config binds to the number keys.
  function unbindKeys() {
    if (!screens.bound) return
    screens.bound = false
    unbinder.running = true
  }

  Process {
    id: unbinder
    command: ["/usr/bin/hyprctl", "reload"]
  }
}
