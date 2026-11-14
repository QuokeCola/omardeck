import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "../app/HyprLua.js" as HyprLua
import "../app/Layout.js" as Layout

// What you do in the overview: the selection, what you typed, peeking at a desktop
// from the strip, the keyboard, and going where you pointed.
Scope {
  id: root

  // The overlay this is part of, for what the other parts hold.
  required property var overlay
  property var service: null

  // The window the keyboard is on. The pointer sets it too, so the ring never
  // has to be in two places at once.
  property string selectedKey: ""
  property string filter: ""
  property int peek: -1
  property int peekWanted: -1

  // The surface you are working on, which is the one that answers questions
  // about where things are.
  property var leadSurface: null

  /** Hovering a workspace shows you what is on it, without going there. */
  //
  // Not while a window is being dragged, though: carrying one to a tile would
  // swap the whole spread for that desktop under the pointer, the windows you
  // are moving it away from vanishing mid-drag — and not over the tile one was
  // just dropped on, until the pointer has left it, or the spread flips to
  // that desktop the moment the window lands.
  property int noPeekId: -1

  function endPeek() {
    peeking.stop()
    root.peekWanted = -1
    root.peek = -1
  }

  function hoverWorkspace(id, entered) {
    const here = overlay.stageWorkspace
    if (entered) {
      if (id === here || overlay.moving || overlay.dragKey !== "" || id === root.noPeekId) return
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

  function matches(win) {
    if (overlay.appOnly !== "" && String(win.appId || "").toLowerCase() !== overlay.appOnly) return false
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

  /** What Omarchy's titlebar says for a window of this class: the name of the app
      that claims it, as omarchy-hyprland-titlebars works it out (appName.cpp) --
      the desktop entry whose StartupWMClass is the class, or failing that whose id
      is, whatever the case. "" when none does, and the bar shows the window's title. */
  function appNameFor(appId) {
    if (!appId) return ""
    const entries = DesktopEntries.applications.values || []
    for (const entry of entries) if (entry.startupClass === appId && entry.name) return entry.name
    const wanted = String(appId).toLowerCase()
    for (const entry of entries) if (String(entry.id).toLowerCase() === wanted && entry.name) return entry.name
    return ""
  }

  // ------------------------------------------------------------ acting on it

  // The exclusive layer restores its previous focus when it closes. Apply
  // the chosen window again after the surface has relinquished that grab.
  property string pendingFocus: ""
  Timer {
    interval: 50
    running: root.pendingFocus !== "" && !overlay.opened
    onTriggered: {
      const address = root.pendingFocus
      root.pendingFocus = ""
      Hyprland.dispatch('hl.dsp.focus({ window = "address:0x' + address + '" })')
    }
  }

  // Going somewhere from the overview makes that desktop the one the overview
  // is showing before it closes, so it closes onto what the screen will
  // actually show: that desktop's windows fly home, not the ones of the
  // desktop it was opened on.
  function focusWindow(address) {
    if (!address) return
    root.pendingFocus = address
    const win = overlay.shot.find(w => w.key === address)
    if (win) overlay.stageId = overlay.wsOf(win)
    root.peek = -1
    // Every screen to that window's desktop, not just the one it is on.
    if (overlay.synced && win) overlay.switchDesk(overlay.wsOf(win), address)
    else Hyprland.dispatch('hl.dsp.focus({ window = "address:0x' + address + '" })')
    overlay.dismiss()
  }

  function goToWorkspace(id, monitorName) {
    // The "+" at the end makes another desktop and stays in the overview.
    const tile = overlay.workspaces.find(w => w.id === id)
    if (tile && tile.fresh) {
      overlay.addWorkspace(id)
      return
    }
    overlay.stageId = id
    root.peek = -1
    if (overlay.synced) {
      overlay.switchDesk(id)
      overlay.dismiss()
      return
    }
    // A desktop that does not exist yet is made on whichever screen has
    // focus: the one whose tile was clicked, then.
    const exists = (Hyprland.workspaces.values || []).some(w => w.id === id)
    if (!exists && monitorName) Hyprland.dispatch('hl.dsp.focus({ monitor = "' + monitorName + '" })')
    Hyprland.dispatch('hl.dsp.focus({ workspace = "' + id + '" })')
    overlay.dismiss()
  }

  // ------------------------------------------------------ the screen in use

  /** The pointer has moved to another screen: that screen leads now — the
      keyboard, the strip's peeking and dropping, sliding through its own
      desktops — rather than leaving it a picture you can only look at. */
  function leadTo(name) {
    if (!name || !root.service || name === overlay.leadMonitor) return
    if (overlay.moving || overlay.dragKey !== "" || !overlay.active) return
    const mon = (Hyprland.monitors.values || []).find(m => m.name === name)
    peeking.stop()
    root.peek = -1
    root.peekWanted = -1
    root.noPeekId = -1
    // One desktop across every screen: changing screens does not change it.
    if (!overlay.synced || overlay.stageId <= 0)
      overlay.stageId = mon && mon.activeWorkspace ? overlay.deskOfId(mon.activeWorkspace.id) : -1
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
      if (overlay.deskSwitching) return
      if (overlay.active && Hyprland.focusedMonitor) root.leadTo(Hyprland.focusedMonitor.name)
    }
  }

  /** Pointing at a window focuses it, so the overview closes onto the window
      you were last looking at — but only one on the desktop its screen is
      showing: focusing a window elsewhere would switch that screen's desktop
      underneath the overview. */
  function hoverFocus(key) {
    if (!overlay.active || overlay.dragKey !== "" || overlay.moving) return
    const top = (Hyprland.toplevels.values || []).find(t => t.address === key)
    if (!top || !top.workspace || !top.monitor) return
    const showing = top.monitor.activeWorkspace
    if (!showing || showing.id !== top.workspace.id || overlay.isActive(top)) return
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
    quietFocus.command = ["/usr/bin/hyprctl", "eval", HyprLua.quiet(HyprLua.focusWindow(key))]
    quietFocus.running = true
  }

  function closeWindow(address) {
    if (!address) return
    Hyprland.dispatch('hl.dsp.window.close({ window = "address:0x' + address + '" })')
    if (root.selectedKey === address) root.selectedKey = ""
    if (root.service) root.service.refreshModels()
    overlay.resettleSoon()
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
      else overlay.dismiss()
      break
    case Qt.Key_Backspace:
      root.filter = root.filter.slice(0, -1)
      break
    case Qt.Key_Left:
      if (event.modifiers & Qt.ControlModifier) overlay.slideBy(-1)
      else root.moveSelection(-1, 0)
      break
    case Qt.Key_Right:
      if (event.modifiers & Qt.ControlModifier) overlay.slideBy(1)
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
      if (event.modifiers & Qt.ControlModifier) overlay.dismiss()
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
}
