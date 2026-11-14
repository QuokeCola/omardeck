import QtQuick
import Quickshell
import Quickshell.Hyprland

// Which desktops the overview offers: the strip's tiles.
Scope {
  id: root

  // The overlay this is part of, for what the other parts hold.
  required property var overlay

  // The strip, as of the last sync: never the live model. Every desktop on it, and
  // the "+" at its end.
  property var workspaces: []

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
      const id = overlay.deskOfId(space.id)
      if (id > 0 && id <= 10 && (overlay.synced || space.id <= 10) && ids.indexOf(id) === -1) ids.push(id)
    }
    ids.sort((a, b) => a - b)

    const here = overlay.focusedDesk
    const out = ids.map(id => {
      const real = existing.find(w => w.id > 0 && overlay.deskOfId(w.id) === id) || null
      return {
        id: id,
        name: !overlay.synced && real && real.name ? real.name : String(id),
        focused: id === here,
        real: real !== null,
        fresh: false,
        // Which screen it is on, if it exists yet. One that does not will be
        // made on whichever screen switches to it. A desktop is on all of them.
        monitor: !overlay.synced && real && real.monitor ? real.monitor.name : "",
      }
    })

    // And somewhere to put things when five desktops are not enough.
    const next = ids[ids.length - 1] + 1
    if (next <= 10) {
      out.push({ id: next, name: "+", focused: false, real: false, fresh: true })
    }
    return out
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
  property int lastDesk: overlay.focusedDesk
  function followDesk() {
    const left = root.lastDesk
    root.lastDesk = overlay.focusedDesk
    if (root.addedDesks.indexOf(left) !== -1) root.addedDesks = root.addedDesks.filter(id => id !== left)
  }
  function forgetRealDesks() {
    const real = (Hyprland.workspaces.values || []).filter(w => w.id > 0).map(w => overlay.deskOfId(w.id))
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
}
