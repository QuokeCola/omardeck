import QtQuick
import Quickshell
import Quickshell.Hyprland

// A window picked up and carried, within a screen or across to another, and what
// happens when it is let go. The cards write what they are carrying here.
Scope {
  id: root

  // The overlay this is part of, for what the other parts hold.
  required property var overlay
  property var service: null

  // The window in hand, and what it is over.
  property string dragKey: ""
  property int dragTarget: -1
  property string dropOnKey: ""

  // Picking a window up ends any peek: it is carried over the desktop it
  // came from.
  onDragKeyChanged: if (root.dragKey !== "") overlay.endPeek()

  // A window carried off its own screen. The card stays on the surface it
  // was picked up on, which keeps the pointer for as long as the button is
  // held, wherever it goes; every other screen draws a stand-in for it where
  // it is (see `visitor` in Surface.qml), so it reads as one card crossing
  // over. In layout coordinates, as Hyprland places monitors.
  property string dragScreen: ""
  property string dragHome: ""
  property rect dragRect: Qt.rect(0, 0, 0, 0)
  property var dragCapture: null
  property real dragOpacity: 1

  // Let go on another screen: where it was let go, until its new card there
  // has a frame and can take over from the stand-in.
  property var arrival: null
  Timer {
    id: arrivalWatchdog
    interval: 600
    onTriggered: root.arrival = null
  }

  // Every screen's surface, by monitor name.
  property var surfaces: ({})
  function enrol(surface, name) {
    const next = Object.assign({}, root.surfaces)
    if (surface) next[name] = surface
    else delete next[name]
    root.surfaces = next
  }

  /** The surface under a point in layout coordinates, or null. */
  function surfaceAt(gx, gy) {
    for (const name in root.surfaces) {
      const s = root.surfaces[name]
      const mon = s.monitor
      if (!mon) continue
      if (gx >= mon.x && gx < mon.x + s.width && gy >= mon.y && gy < mon.y + s.height) return s
    }
    return null
  }

  function aimDrag(workspaceId, cardKey) {
    root.dragTarget = workspaceId
    // A workspace under the pointer wins: it is the larger, deliberate target.
    root.dropOnKey = workspaceId > 0 ? "" : cardKey
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

  function drop(address) {
    const space = root.dragTarget
    const onto = root.dropOnKey
    const screen = root.dragScreen
    root.dragTarget = -1
    root.dropOnKey = ""
    root.dragScreen = ""
    if (!address) return false

    const win = overlay.shot.find(w => w.key === address)
    if (win && screen !== "" && screen !== overlay.screenOf(win))
      return root.dropOnScreen(win, screen, space)

    // With every screen as one desktop, a tile is that desktop on the screen
    // the window is on: dropped there, it changes desktop, not screen.
    const here = overlay.synced && win ? overlay.wsOf(win) : overlay.focusedDesk
    const target = overlay.synced && win ? overlay.spaceOn(space, win.monitor) : space
    if (space > 0 && space !== here) {
      // Without following it: moving a window takes the screen to its new
      // desktop by default, which switched the real desktop underneath the
      // overview — flashing as it went, and handing back to the wrong desktop
      // when the overview closed.
      Hyprland.dispatch('hl.dsp.window.move({ window = "address:0x' + address
                        + '", workspace = "' + target + '", follow = false })')
      overlay.noPeekId = space
      // Nothing left selected on this desktop that has gone to another.
      if (overlay.selectedKey === address) overlay.selectedKey = ""
      // Gone from this desktop now, not when the compositor has said so.
      const next = Object.assign({}, overlay.moved)
      next[address] = target
      overlay.moved = next
    } else if (onto && onto !== address) {
      // Dropped on another window: they trade places in the tiling layout.
      Hyprland.dispatch('hl.dsp.window.swap({ window = "address:0x' + address
                        + '", target = "address:0x' + onto + '" })')
    } else {
      return false
    }
    // The overview stays open, the way it does on a Mac: you are usually
    // moving more than one thing.
    if (root.service) root.service.refreshModels()
    overlay.resettleSoon()
    return true
  }

  /** Let go over another screen: to the desktop tile it is over there, or
      else to the desktop that screen is showing. True if it went. */
  function dropOnScreen(win, screen, space) {
    const there = root.surfaces[screen]
    if (!there) return false
    const desk = space > 0 ? space : there.shownWorkspace
    if (!(desk > 0)) return false
    const target = overlay.synced ? overlay.spaceOn(desk, screen) : desk
    // Apart, a tile is a workspace wherever it is; one not made yet is made
    // where it is asked for.
    const real = (Hyprland.workspaces.values || []).find(w => w.id === target)
    const lands = !overlay.synced && real && real.monitor ? real.monitor.name : screen
    if (target === overlay.spaceOf(win) && lands === overlay.screenOf(win)) return false

    Hyprland.dispatch('hl.dsp.window.move({ window = "address:0x' + win.key
                      + '", workspace = "' + target + '", follow = false })')
    if (space > 0) overlay.noPeekId = space
    root.arrival = { key: win.key, screen: lands, rect: root.dragRect }
    arrivalWatchdog.restart()
    const next = Object.assign({}, overlay.moved)
    next[win.key] = target
    overlay.moved = next
    // Not from inside the drag that is ending: moving the window takes its
    // card off this screen, and that card is the one still handling it.
    Qt.callLater(() => {
      const away = Object.assign({}, overlay.movedScreen)
      away[win.key] = lands
      overlay.movedScreen = away
      // The pointer is over there now, and so is the work.
      overlay.leadTo(screen)
    })
    if (root.service) root.service.refreshModels()
    overlay.resettleSoon()
    return true
  }
}
