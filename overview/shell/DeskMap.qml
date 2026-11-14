import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "../app/Desks.js" as Desks
import "../app/HyprLua.js" as HyprLua

// Every screen as one desktop: which workspace is which desktop, and moving them
// all at once. The arithmetic is in app/Desks.js and the Lua in app/HyprLua.js;
// this holds what they need from the compositor and the one hyprctl in flight.
Scope {
  id: root

  // The overlay this is part of, for what the other parts hold.
  required property var overlay
  property var service: null

  // With "All screens together" on, each screen keeps a block of ten
  // workspaces — the laptop's own panel 1-10, the others left to right 11-20,
  // 21-30 — and a desktop is the same number in every block: desktop 3 is
  // workspace 3 on the laptop, 13 on the screen left of the rest, 23 on the
  // next. The overview thinks in desktops (the strip, the slide, `wsOf`) and
  // turns one into a workspace only to talk to Hyprland. The SUPER+number
  // bindings that switch every screen at once number them the same way.
  readonly property bool synced: root.service ? root.service.syncScreens : false

  readonly property var screenOrder: Desks.screenOrder(Hyprland.monitors.values || [])

  /** The desktop a workspace id is, or the id itself when screens are apart. */
  function deskOfId(id) { return Desks.deskOfId(id, root.synced) }

  /** The workspace that is a desktop on a given screen. */
  function spaceOn(desk, monitorName) {
    return Desks.spaceOn(desk, root.screenOrder.indexOf(monitorName), root.synced)
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
    const lead = overlay.leadMonitor !== "" ? overlay.leadMonitor
               : (Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "")
    const names = root.screenOrder.filter(n => n !== lead)
    if (lead !== "") names.push(lead)
    deskSwitch.command = ["/usr/bin/hyprctl", "eval", HyprLua.switchScript(names, name => root.spaceOn(desk, name), address)]
    deskSwitch.running = true
  }

  // With all screens together, each one switches on its own and a moment apart. Going
  // before the last has arrived shows that screen's old desktop as the overview leaves.
  function everyScreenOn(desk) {
    if (root.focusedDesk !== desk) return false
    if (!root.synced) return true
    const screens = Hyprland.monitors.values || []
    for (let i = 0; i < screens.length; i++) {
      const space = screens[i].activeWorkspace
      if (!space || root.deskOfId(space.id) !== desk) return false
    }
    return true
  }
}
