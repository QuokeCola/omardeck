import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Widgets
import qs.Commons
import qs.Ui

// Bottom dock: pinned apps, then running apps that aren't pinned. Window state
// comes from `hyprctl -j` (refreshed on Hyprland events), so window geometry is
// known and the dock can hide only when a window actually overlaps it.
//
// Config: ~/.config/omarchy/dock.json (watched; the dock rewrites `pinned`
// when you pin/unpin from the right-click menu).
//   pinned    desktop ids, without ".desktop"
//   iconSize  px at rest
//   height    panel height in px (independent of iconSize)
//   magnify   hovered icon scale (1 = off)
//   autohide  "smart" (hide when a window overlaps), "always", "never"
//   slideToWindow  clicking an app whose one window is on another desktop:
//             true (default) has Aerial slide there; false switches at once
//   windowPicker  clicking an app with several windows: "aerial" opens
//             Aerial's overview on just that app's windows; "cycle" focuses
//             them in turn
Item {
  id: root
  width: 0
  height: 0
  visible: false

  property var shell: null

  // ------------------------------------------------------------------ config
  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/dock.json"
  property var config: ({})
  readonly property var pinned: Array.isArray(config.pinned) ? config.pinned : []
  readonly property int iconSize: Math.max(24, Number(config.iconSize) || 38)
  readonly property real magnify: Math.max(1, Math.min(2, Number(config.magnify) || 1.45))
  readonly property bool slideToWindow: config.slideToWindow !== false
  readonly property string windowPicker: config.windowPicker === "cycle" ? "cycle" : "aerial"
  readonly property string autohide: ["smart", "always", "never"].indexOf(config.autohide) >= 0 ? config.autohide : "smart"

  // The panel's height is set on its own, so smaller icons get more air
  // rather than a thinner dock. Icons sit centred above a strip for the dots.
  readonly property int dotZone: 10
  readonly property int dockHeight: Math.max(iconSize + dotZone + 4, Number(config.height) || 63)
  readonly property int padding: Math.round((dockHeight - dotZone - iconSize) / 2) + 1
  readonly property int sidePadding: Math.max(padding, Math.round(iconSize * 0.3))
  readonly property int spacing: Math.round(iconSize * 0.26)
  // Flush with the screen edge.
  readonly property int edgeGap: 0
  readonly property int separatorWidth: spacing + 1
  // Edge strip that reveals a hidden dock. Kept a few px tall: thinner input
  // regions get lost to rounding at fractional scale.
  readonly property int triggerHeight: 4

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.config = JSON.parse(text()) || {} } catch (e) { console.warn("dock: bad dock.json:", e) }
      root.rebuild()
    }
  }

  function setPinned(list) {
    var next = {}
    for (var k in root.config) next[k] = root.config[k]
    next.pinned = list
    root.config = next
    configFile.setText(JSON.stringify(next, null, 2) + "\n")
    root.rebuild()
  }

  function togglePin(key) {
    if (key.indexOf("class:") === 0) return
    var list = root.pinned.slice()
    var i = list.indexOf(key)
    if (i >= 0) list.splice(i, 1)
    else list.push(key)
    root.setPinned(list)
  }

  // ----------------------------------------------------------- window state
  // Read from Quickshell's own Hyprland connection: requests go over the
  // socket in-process, titles and the active window arrive as events. (It
  // used to run bash + 3x hyprctl per event — ~3.5% CPU while a terminal
  // title spinner ticked.)
  property var clients: []     // plain objects; `tl` is the live toplevel
  property var monitors: []
  readonly property string activeAddress: Hyprland.activeToplevel ? "0x" + Hyprland.activeToplevel.address : ""

  // Most recently focused first, kept from focus events rather than asking
  // Hyprland for focusHistoryID on every focus change.
  property var mru: []
  onActiveAddressChanged: {
    if (!root.activeAddress) return
    var next = root.mru.filter(function(a) { return a !== root.activeAddress })
    next.unshift(root.activeAddress)
    root.mru = next.slice(0, 64)
  }

  // Ask for fresh geometry/workspaces only when they can have changed.
  readonly property var refreshEvents: ["openwindow", "closewindow", "movewindow", "movewindowv2",
    "changefloatingmode", "fullscreen", "workspace", "workspacev2", "focusedmon", "focusedmonv2",
    "moveworkspace", "moveworkspacev2", "activespecial", "activespecialv2", "monitoradded",
    "monitoraddedv2", "monitorremoved", "monitorremovedv2", "togglegroup", "moveintogroup",
    "moveoutofgroup", "pin", "minimized", "configreloaded"]
  function refresh() { refreshTimer.restart() }
  Timer {
    id: refreshTimer
    interval: 30
    onTriggered: { Hyprland.refreshToplevels(); Hyprland.refreshMonitors() }
  }
  Component.onCompleted: refresh()

  function scheduleRebuild() { Qt.callLater(root.rebuild) }
  Instantiator {
    model: Hyprland.toplevels
    delegate: Connections {
      required property var modelData
      target: modelData
      function onLastIpcObjectChanged() { root.scheduleRebuild() }
    }
  }
  Instantiator {
    model: Hyprland.monitors
    delegate: Connections {
      required property var modelData
      target: modelData
      function onLastIpcObjectChanged() { root.scheduleRebuild() }
      function onActiveWorkspaceChanged() { root.scheduleRebuild() }
    }
  }
  Connections {
    target: Hyprland.toplevels
    function onValuesChanged() { root.scheduleRebuild() }
  }

  // The dock shares the Overlay layer with Aerial's full-screen surface so a
  // desktop swipe doesn't paint over it. On one layer the last surface mapped
  // stacks on top, so remap the dock whenever Aerial maps (startup, leaving a
  // fullscreen window) and once shortly after start.
  property bool remapping: false
  function restack() { root.remapping = true; remapTimer.restart() }
  // Also the moment to re-announce the dock's size: Aerial may just have
  // started and missed it.
  signal restackDone()
  Timer { id: remapTimer; interval: 50; onTriggered: { root.remapping = false; root.restackDone() } }
  Timer { interval: 2000; running: true; onTriggered: root.restack() }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var n = event.name
      if (n === "openlayer" && String(event.data).trim() === "omarchy-aerial") root.restack()
      else if (n === "custom" && String(event.data).indexOf("aerial-state,") === 0) {
        // Aerial took the jump (or finished one): no fallback needed.
        if (root.jumpPending) { root.jumpPending = ""; jumpFallback.stop() }
      }
      else if (root.refreshEvents.indexOf(n) >= 0) root.refresh()
    }
  }

  // Dragging a floating window emits no event, so poll slowly while one could
  // change whether a dock hides: a floating window on a screen's visible
  // workspace that no tiled or fullscreen window already covers the dock on
  // (tiles only move with events). Windows only: monitors don't change.
  Timer {
    interval: 1200
    repeat: true
    running: root.autohide === "smart" && panels.instances.some(function(p) { return p.needsPoll })
    onTriggered: Hyprland.refreshToplevels()
  }

  // ------------------------------------------------------------- app model
  property var idCache: ({})
  // A desktop-entry scan reports each entry separately (~100 at startup):
  // coalesce into one rebuild.
  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { root.idCache = ({}); root.scheduleRebuild() }
  }

  function keyForClass(cls) {
    if (root.idCache[cls] !== undefined) return root.idCache[cls]
    var entry = null
    try { entry = DesktopEntries.heuristicLookup(cls) } catch (e) {}
    var key = entry ? String(entry.id).replace(/\.desktop$/, "") : "class:" + cls
    root.idCache[cls] = key
    return key
  }

  function entryFor(key) {
    if (!key || key.indexOf("class:") === 0) return null
    return DesktopEntries.byId(key) || DesktopEntries.byId(key + ".desktop")
  }

  function nameFor(key) {
    var e = entryFor(key)
    if (e && e.name) return e.name
    var w = root.windowsByKey[key]
    if (w && w.length) return (w[0].tl ? w[0].tl.title : "") || w[0].class
    return key.replace(/^class:/, "")
  }

  function iconFor(key) {
    var e = entryFor(key)
    var icon = e ? String(e.icon || "") : key.replace(/^class:/, "")
    if (icon.charAt(0) === "/") return "file://" + icon
    var p = Quickshell.iconPath(icon, true)
    if (!p) p = Quickshell.iconPath(icon.toLowerCase(), true)
    return p || Quickshell.iconPath("application-x-executable", true)
  }

  property var windowsByKey: ({})
  property var runningOrder: []
  property var items: []       // [{ key, separator }]
  property string itemsSig: ""

  property string clientsSig: ""
  property string monitorsSig: ""
  property string windowsSig: ""

  function snapshot() {
    var mons = []
    var ms = Hyprland.monitors.values || []
    for (var m = 0; m < ms.length; m++) {
      var hm = ms[m]
      var ipc = hm.lastIpcObject || {}
      mons.push({
        id: hm.id, name: hm.name,
        activeWorkspace: { id: hm.activeWorkspace ? hm.activeWorkspace.id : (ipc.activeWorkspace ? ipc.activeWorkspace.id : -999) },
        specialWorkspace: { id: ipc.specialWorkspace ? ipc.specialWorkspace.id : 0 }
      })
    }
    var sigM = JSON.stringify(mons)
    if (sigM !== root.monitorsSig) { root.monitorsSig = sigM; root.monitors = mons }

    var cl = []
    var ts = Hyprland.toplevels.values || []
    for (var i = 0; i < ts.length; i++) {
      var o = ts[i].lastIpcObject || {}
      if (!o.class || !o.address) continue
      cl.push({
        address: o.address, class: o.class, mapped: o.mapped !== false, hidden: !!o.hidden,
        workspace: { id: o.workspace ? o.workspace.id : 0, name: o.workspace ? String(o.workspace.name) : "" },
        monitor: o.monitor, at: o.at || [0, 0], size: o.size || [0, 0],
        floating: !!o.floating, fullscreen: o.fullscreen || 0, focusHistoryID: o.focusHistoryID || 0
      })
    }
    var sigC = JSON.stringify(cl)
    var changed = sigC !== root.clientsSig
    if (changed) {
      root.clientsSig = sigC
      // The live toplevel rides along for titles (not part of the signature).
      for (var j = 0; j < cl.length; j++) {
        for (var t = 0; t < ts.length; t++)
          if ((ts[t].lastIpcObject || {}).address === cl[j].address) { cl[j].tl = ts[t]; break }
      }
      root.clients = cl
    }
  }

  function mruRank(addr, fallback) {
    var i = root.mru.indexOf(addr)
    return i >= 0 ? i : 1000 + fallback
  }

  function rebuild() {
    root.snapshot()
    var byKey = {}
    for (var i = 0; i < root.clients.length; i++) {
      var c = root.clients[i]
      if (!c.mapped || !c.class) continue
      var key = root.keyForClass(c.class)
      if (!byKey[key]) byKey[key] = []
      byKey[key].push(c)
    }
    for (var k in byKey) byKey[k].sort(function(a, b) {
      return root.mruRank(a.address, a.focusHistoryID) - root.mruRank(b.address, b.focusHistoryID)
    })
    var sigW = JSON.stringify(Object.keys(byKey).sort().map(function(k) {
      return [k, byKey[k].map(function(w) { return w.address + "@" + w.workspace.id })]
    })) + "|" + root.clientsSig.length + root.clientsSig.slice(-64)
    if (sigW !== root.windowsSig) { root.windowsSig = sigW; root.windowsByKey = byKey }
    else {
      // Same windows; only the most-recent order may differ. Re-sort in place
      // so activate() picks the right one without waking every binding.
      for (var k3 in byKey) root.windowsByKey[k3] = byKey[k3]
    }

    var order = root.runningOrder.filter(function(k) { return !!byKey[k] })
    for (var k2 in byKey) if (order.indexOf(k2) < 0) order.push(k2)
    root.runningOrder = order

    var next = []
    for (var p = 0; p < root.pinned.length; p++) next.push({ key: root.pinned[p], separator: false })
    var extra = order.filter(function(k) { return root.pinned.indexOf(k) < 0 })
    if (extra.length && next.length) next.push({ key: "--sep--", separator: true })
    for (var x = 0; x < extra.length; x++) next.push({ key: extra[x], separator: false })

    // Only swap the model when the set changes, so delegates (and their hover
    // and animation state) survive ordinary window events.
    var sig = next.map(function(it) { return it.key }).join("|")
    if (sig !== root.itemsSig) {
      root.itemsSig = sig
      root.items = next
    }
  }

  // Centres of each item in the un-magnified layout, used to drive the
  // magnification without feedback from the growing icons.
  readonly property var baseCenters: {
    var out = []
    var x = root.sidePadding
    for (var i = 0; i < root.items.length; i++) {
      var w = root.items[i].separator ? root.separatorWidth : root.iconSize
      out.push(x + w / 2)
      x += w + (i < root.items.length - 1 ? root.spacing : 0)
    }
    return out
  }
  readonly property real baseWidth: {
    var w = root.sidePadding * 2
    for (var i = 0; i < root.items.length; i++)
      w += (root.items[i].separator ? root.separatorWidth : root.iconSize) + (i ? root.spacing : 0)
    return w
  }

  // ---------------------------------------------------------------- actions
  // Over the shell's own socket connection: no hyprctl process per click.
  function hypr(lua) { Hyprland.dispatch(lua) }
  function focusWindow(addr) { root.hypr('hl.dsp.focus({ window = "address:' + addr + '" })') }
  function closeWindow(addr) { root.hypr('hl.dsp.window.close({ window = "address:' + addr + '" })') }

  signal launched(string key)

  function launch(key) {
    var e = root.entryFor(key)
    if (e) {
      Quickshell.execDetached(["uwsm-app", "--", "gtk-launch", String(e.id).replace(/\.desktop$/, "") + ".desktop"])
    } else {
      Quickshell.execDetached(["uwsm-app", "--", key.replace(/^class:/, "")])
    }
    root.launched(key)
  }

  function activate(key) {
    var wins = root.windowsByKey[key] || []
    if (!wins.length) { root.launch(key); return }
    // Several windows: let Aerial lay them out to pick from; choosing one
    // takes you to its desktop the way the overview always does.
    if (wins.length > 1 && root.windowPicker === "aerial") {
      Hyprland.dispatch('hl.dsp.event("aerial,app:' + String(wins[0].class).replace(/[^A-Za-z0-9._-]/g, "") + '")')
      return
    }
    var idx = -1
    for (var i = 0; i < wins.length; i++) if (wins[i].address === root.activeAddress) idx = i
    if (idx < 0) { root.goToWindow(wins[0]); return }
    if (wins.length < 2) return
    // Cycle in a stable order (by address) so repeated clicks visit every window.
    var stable = wins.slice().sort(function(a, b) { return a.address < b.address ? -1 : 1 })
    var at = 0
    for (var j = 0; j < stable.length; j++) if (stable[j].address === root.activeAddress) at = j
    root.focusWindow(stable[(at + 1) % stable.length].address)
  }

  // Off on another desktop: ask Aerial to slide there. If it doesn't start
  // sliding promptly (not installed, or busy), just switch.
  property string jumpPending: ""
  function goToWindow(win) {
    var mon = null
    for (var m = 0; m < root.monitors.length; m++) if (root.monitors[m].id === win.monitor) mon = root.monitors[m]
    var here = mon && mon.activeWorkspace && mon.activeWorkspace.id === win.workspace.id
    if (!root.slideToWindow || here || win.workspace.id <= 0) { root.focusWindow(win.address); return }
    root.jumpPending = win.address
    jumpFallback.restart()
    Hyprland.dispatch('hl.dsp.event("aerial,goto:' + String(win.address).replace(/^0x/, "") + '")')
  }
  Timer {
    id: jumpFallback
    interval: 400
    onTriggered: if (root.jumpPending) { root.focusWindow(root.jumpPending); root.jumpPending = "" }
  }

  function quit(key) {
    var wins = root.windowsByKey[key] || []
    for (var i = 0; i < wins.length; i++) root.closeWindow(wins[i].address)
  }

  // ----------------------------------------------------------------- surface
  Variants {
    id: panels
    model: Quickshell.screens

    delegate: Component {
      PanelWindow {
        id: panel
        required property var modelData
        screen: modelData

        readonly property var monitor: {
          for (var i = 0; i < root.monitors.length; i++)
            if (root.monitors[i].name === modelData.name) return root.monitors[i]
          return null
        }

        // Does any window on this monitor's visible workspace cover the dock?
        // Tiled/fullscreen and floating windows counted apart: only floating
        // ones move without an event (see the poll timer).
        readonly property var coverage: {
          var out = { fixed: false, floating: false, floatingHere: false }
          var mon = panel.monitor
          if (!mon) return out
          var ws = mon.activeWorkspace ? mon.activeWorkspace.id : -999
          var sp = mon.specialWorkspace && mon.specialWorkspace.id ? mon.specialWorkspace.id : -999
          var left = modelData.x + (modelData.width - root.baseWidth) / 2
          var right = left + root.baseWidth
          var bottom = modelData.y + modelData.height
          var top = bottom - root.edgeGap - root.dockHeight
          for (var i = 0; i < root.clients.length; i++) {
            var c = root.clients[i]
            if (!c.mapped || c.monitor !== mon.id) continue
            if (c.workspace.id !== ws && c.workspace.id !== sp) continue
            var fixed = !c.floating || !!c.fullscreen
            if (!fixed) out.floatingHere = true
            if (c.hidden) continue
            if (c.fullscreen || (c.at[0] < right && c.at[0] + c.size[0] > left && c.at[1] < bottom && c.at[1] + c.size[1] > top)) {
              if (fixed) out.fixed = true
              else out.floating = true
            }
          }
          return out
        }
        readonly property bool overlapped: coverage.fixed || coverage.floating
        readonly property bool needsPoll: coverage.floatingHere && !coverage.fixed

        property bool hovered: false
        property bool lingering: false
        property string menuKey: ""
        readonly property bool wantHidden: root.autohide === "always" || (root.autohide === "smart" && overlapped)
        readonly property bool revealed: !wantHidden || hovered || lingering || menuKey !== ""

        onHoveredChanged: if (!hovered) { lingering = true; lingerTimer.restart() }

        // Tell other shell plugins how much of this screen's bottom edge the
        // dock covers (0 when hidden), on Hyprland's event socket:
        // custom>>dock-state,<monitor>,<px>. Aerial lifts its desktop dots
        // above it.
        readonly property int covers: revealed && visible ? Math.ceil(root.edgeGap + root.dockHeight) : 0
        function announce() {
          Hyprland.dispatch('hl.dsp.event("dock-state,' + modelData.name + ',' + panel.covers + '")')
        }
        onCoversChanged: announce()
        Connections {
          target: root
          function onRestackDone() { panel.announce() }
        }
        Timer { id: lingerTimer; interval: 350; onTriggered: panel.lingering = false }

        // Over a fullscreen window, unmap once slid away: any surface above
        // it, even an empty one, stops the compositor scanning it out directly.
        readonly property var hyprMonitor: (Hyprland.monitors.values || []).find(m => m.name === modelData.name) || null
        readonly property bool fullscreenHere: !!(hyprMonitor && hyprMonitor.activeWorkspace
                                                  && hyprMonitor.activeWorkspace.hasFullscreen)
        visible: root.items.length > 0 && !root.remapping && !(fullscreenHere && !revealed && !slider.visible)
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "omarchy-dock"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors.bottom: true
        readonly property real dpr: modelData.devicePixelRatio || 1
        // Snap logical lengths onto the device-pixel grid (0.75 px steps at
        // 1.33) so resting icons land on whole pixels instead of smearing.
        function snap(v) { return Math.round(v * dpr) / dpr }
        readonly property real restIcon: snap(root.iconSize)
        readonly property real headroom: root.iconSize * (root.magnify - 1) + 40
        implicitWidth: Math.ceil(root.baseWidth + root.iconSize * (root.magnify - 1) * 3 + 160)
        implicitHeight: Math.ceil(root.edgeGap + root.dockHeight + headroom)

        // Input: the dock itself (plus the magnified icons while hovered), or a
        // thin strip at the screen edge while hidden.
        // Plain numeric bindings: a Region tracking an item didn't follow the
        // item's later moves, so the hidden-state strip never took input.
        readonly property real hitTop: revealed
          ? (hovered ? dock.y - root.iconSize * (root.magnify - 1) : dock.y)
          : height - root.triggerHeight
        mask: Region {
          x: Math.floor(dock.x)
          y: Math.floor(panel.hitTop)
          width: Math.ceil(dock.width)
          height: Math.ceil(panel.height - panel.hitTop)
        }

        // Mouse x in the dock's un-magnified coordinates.
        readonly property real pointerX: frame.mouseX - (dock.x + dock.width / 2) + root.baseWidth / 2

        // Hover tracking lives on an Item that contains the dock: a handler
        // declared straight on the PanelWindow never receives events.
        MouseArea {
          id: frame
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.NoButton
          onContainsMouseChanged: panel.hovered = containsMouse

          Item {
            id: slider
            anchors.fill: parent
            // Slide in: cubic-bezier(1, 0, 0.8, 1). Slide out: cubic-bezier(0.2, 0, 0, 1).
            readonly property real hiddenOffset: root.edgeGap + root.dockHeight + 6
            property real offset: panel.revealed ? 0 : hiddenOffset
            Behavior on offset {
              NumberAnimation {
                duration: panel.revealed ? 620 : 420
                easing.type: Easing.BezierSpline
                easing.bezierCurve: panel.revealed
                  ? [1, 0, 0.8, 1, 1, 1]
                  : [0.2, 0, 0, 1, 1, 1]
              }
            }
            transform: Translate { y: slider.offset }
            // Fully parked: drop the content so nothing (or its blur) lingers.
            visible: offset < hiddenOffset - 0.5

            Rectangle {
              id: dock
              x: panel.snap((parent.width - width) / 2)
              y: panel.snap(parent.height - root.edgeGap - height)
              height: panel.snap(root.dockHeight)
              width: row.width + panel.snap(root.sidePadding) * 2
              radius: Math.min(14, Style.cornerRadius)
              color: Color.bar.background
              border.width: 1
              border.color: Util.alpha(Color.bar.text, 0.12)
            }

            Row {
              id: row
              x: dock.x + panel.snap(root.sidePadding)
              y: dock.y + panel.snap(root.padding) + panel.restIcon - height
              spacing: panel.snap(root.spacing)

              Repeater {
                model: root.items

                delegate: Item {
                  id: cell
                  required property var modelData
                  required property int index
                  readonly property string key: modelData.key
                  readonly property bool isSep: modelData.separator
                  readonly property var wins: root.windowsByKey[key] || []
                  readonly property bool isActive: {
                    for (var i = 0; i < wins.length; i++) if (wins[i].address === root.activeAddress) return true
                    return false
                  }

                  readonly property real target: {
                    if (isSep || !panel.hovered || root.magnify <= 1 || panel.menuKey !== "") return 1
                    var d = (panel.pointerX - (root.baseCenters[index] || 0)) / (root.iconSize + root.spacing)
                    return 1 + (root.magnify - 1) * Math.exp(-d * d / 1.6)
                  }
                  property real zoom: target
                  Behavior on zoom { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }

                  width: isSep ? panel.snap(root.separatorWidth) : panel.snap(root.iconSize * zoom)
                  height: isSep ? panel.restIcon : panel.snap(root.iconSize * zoom)
                  anchors.bottom: parent.bottom

                  Rectangle {
                    visible: cell.isSep
                    anchors.centerIn: parent
                    width: 1
                    height: root.iconSize * 0.7
                    color: Util.alpha(Color.bar.text, 0.2)
                  }

                  // Rasterised once at the largest magnified size in device pixels,
                  // then scaled down. IconImage ties sourceSize to its logical
                  // size, so at 1.33 it rendered 44px icons blurry and reloaded
                  // (blinked) on every magnification frame.
                  // Two rasters, both loaded once: one at exactly the resting
                  // device-pixel size (1:1, crisp) and one at the magnified size,
                  // shown only while the icon is enlarged. IconImage instead tied
                  // sourceSize to its logical size, so it was soft at 1.33 and
                  // reloaded (blinked) on every magnification frame.
                  Item {
                    id: icon
                    visible: !cell.isSep
                    width: parent.width
                    height: parent.height
                    y: -cell.hop
                    opacity: mouse.pressed ? 0.7 : 1
                    readonly property string src: cell.isSep ? "" : root.iconFor(cell.key)
                    readonly property bool big: cell.zoom > 1.01

                    Image {
                      anchors.fill: parent
                      visible: !icon.big || bigImg.status !== Image.Ready
                      source: icon.src
                      sourceSize.width: Math.round(panel.restIcon * panel.dpr)
                      sourceSize.height: Math.round(panel.restIcon * panel.dpr)
                      fillMode: Image.PreserveAspectFit
                      // Must stay async: a synchronous image://icon load
                      // crashes the whole shell inside QIcon::pixmap.
                      asynchronous: true
                      smooth: true
                    }
                    Image {
                      id: bigImg
                      anchors.fill: parent
                      visible: icon.big && status === Image.Ready
                      source: root.magnify > 1 ? icon.src : ""
                      sourceSize.width: Math.ceil(root.iconSize * root.magnify * panel.dpr)
                      sourceSize.height: Math.ceil(root.iconSize * root.magnify * panel.dpr)
                      fillMode: Image.PreserveAspectFit
                      asynchronous: true
                      smooth: true
                      mipmap: true
                    }
                  }

                  // Launch feedback: hop until a window shows up (or ~2.5s).
                  property real hop: 0
                  SequentialAnimation {
                    id: bounce
                    loops: 3
                    NumberAnimation { target: cell; property: "hop"; to: root.iconSize * 0.3; duration: 280; easing.type: Easing.OutQuad }
                    NumberAnimation { target: cell; property: "hop"; to: 0; duration: 340; easing.type: Easing.OutBounce }
                  }
                  Connections {
                    target: root
                    function onLaunched(k) { if (k === cell.key && !cell.isSep) bounce.restart() }
                  }
                  onWinsChanged: if (wins.length && bounce.running) { bounce.stop(); hop = 0 }

                  Row {
                    visible: !cell.isSep
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.bottom
                    anchors.topMargin: Math.max(2, (root.dockHeight - root.padding - root.iconSize - 4) / 2 - 1)
                    spacing: 3
                    Repeater {
                      model: Math.min(3, cell.wins.length)
                      Rectangle {
                        width: 4
                        height: 4
                        radius: 2
                        color: cell.isActive ? Color.accent : Util.alpha(Color.bar.text, 0.6)
                      }
                    }
                  }

                  Rectangle {
                    id: tip
                    visible: !cell.isSep && mouse.containsMouse && panel.menuKey === "" && !mouse.pressed
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: icon.top
                    anchors.bottomMargin: 8
                    width: tipText.implicitWidth + 16
                    height: tipText.implicitHeight + 8
                    radius: Math.min(6, Style.cornerRadius)
                    color: Color.tooltip.background
                    border.width: 1
                    border.color: Util.alpha(Color.tooltip.border, 0.3)
                    Text {
                      id: tipText
                      anchors.centerIn: parent
                      text: cell.isSep ? "" : root.nameFor(cell.key)
                      color: Color.tooltip.text
                      font.pixelSize: Style.font.body
                    }
                  }

                  MouseArea {
                    id: mouse
                    enabled: !cell.isSep
                    anchors.fill: parent
                    anchors.margins: -root.spacing / 2
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                    onClicked: function(ev) {
                      if (ev.button !== Qt.RightButton) panel.closeMenu()
                      if (ev.button === Qt.LeftButton) root.activate(cell.key)
                      else if (ev.button === Qt.MiddleButton) root.launch(cell.key)
                      else panel.openMenu(cell)
                    }
                  }
                }
              }
            }
          }
        }

        // -------------------------------------------------------- context menu
        property var menuCell: null
        function closeMenu() { menu.visible = false }
        function openMenu(cell) {
          var p = cell.mapToItem(panel.contentItem, 0, 0)
          menu.anchor.rect.x = p.x
          menu.anchor.rect.y = p.y - 6
          menu.anchor.rect.width = cell.width
          menu.anchor.rect.height = 1
          panel.menuCell = cell
          panel.menuKey = cell.key
          menu.visible = true
        }

        PopupWindow {
          id: menu
          anchor.window: panel
          anchor.edges: Edges.Top
          anchor.gravity: Edges.Top
          color: "transparent"
          implicitWidth: card.width
          implicitHeight: card.height + 4
          onVisibleChanged: {
            if (visible) { card.shown = 0; popin.restart(); keys.forceActiveFocus(); armGrab.restart() }
            else { grab.active = false; panel.menuKey = "" }
          }

          // Dismissed the way Omarchy's own popups are: a Hyprland focus grab
          // over the menu and the dock, cleared by a click anywhere else. Not
          // PopupWindow.grabFocus — Qt then believes a popup is still open
          // after the compositor dismisses it and eats the next click.
          // Armed a beat after the popup maps: armed with it, the grab was
          // built before the popup's surface existed, so it covered only the
          // dock and every click on the menu counted as outside.
          HyprlandFocusGrab {
            id: grab
            active: false
            windows: [menu, panel]
            onCleared: menu.visible = false
          }
          Timer { id: armGrab; interval: 60; onTriggered: grab.active = menu.visible }

          readonly property string key: panel.menuKey
          readonly property var wins: root.windowsByKey[key] || []
          readonly property bool isPinned: root.pinned.indexOf(key) >= 0
          readonly property bool hasEntry: !!root.entryFor(key)

          function run(fn) { menu.visible = false; fn() }

          Item {
            id: keys
            focus: true
            Keys.onEscapePressed: menu.visible = false
          }

          // Pops up out of the icon: grows from 94% at its bottom edge and
          // fades in, on the Super menu's curves.
          ParallelAnimation {
            id: popin
            NumberAnimation {
              target: card; property: "shown"; from: 0; to: 1; duration: 270
              easing.type: Easing.BezierSpline; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1]
            }
            NumberAnimation {
              target: card; property: "opacity"; from: 0; to: 1; duration: 115
              easing.type: Easing.BezierSpline; easing.bezierCurve: [0.5, 0.5, 0.75, 1, 1, 1]
            }
          }

          BorderSurface {
            id: card
            property real shown: 1
            scale: 0.94 + 0.06 * shown
            transformOrigin: Item.Bottom
            transform: Translate { y: 6 * (1 - card.shown) }
            width: Math.round(Math.max(232, Math.min(340, col.implicitWidth + 2 * padding)))
            height: Math.round(col.implicitHeight + 2 * padding)
            padding: Math.round(Style.space(6))
            radius: Math.min(12, Style.cornerRadius)
            color: Color.menu.background
            borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, 1)

            Column {
              id: col
              x: card.padding
              y: card.padding
              width: card.width - 2 * card.padding
              spacing: 2

              // Header: the app's icon and name, and whether it is running.
              Item {
                width: parent.width
                implicitWidth: head.implicitWidth + 16
                height: 44
                Row {
                  id: head
                  x: 6
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 10
                  Image {
                    width: 30; height: 30
                    anchors.verticalCenter: parent.verticalCenter
                    source: menu.key ? root.iconFor(menu.key) : ""
                    sourceSize.width: Math.round(30 * panel.dpr)
                    sourceSize.height: Math.round(30 * panel.dpr)
                    asynchronous: true
                    smooth: true
                  }
                  Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1
                    Text {
                      text: menu.key ? root.nameFor(menu.key) : ""
                      color: Color.menu.text
                      font.family: Style.font.menuFamily
                      font.pixelSize: Style.font.subtitle
                      font.weight: Font.DemiBold
                    }
                    Text {
                      text: menu.wins.length === 0 ? "Not running"
                          : menu.wins.length === 1 ? "1 window" : menu.wins.length + " windows"
                      color: Util.alpha(Color.menu.text, 0.5)
                      font.family: Style.font.menuFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                  }
                }
              }

              MenuSeparator { visible: menu.wins.length > 0 }

              Repeater {
                model: menu.wins
                MenuRow {
                  required property var modelData
                  label: (modelData.tl ? modelData.tl.title : "") || modelData.class
                  current: modelData.address === root.activeAddress
                  badge: modelData.workspace && modelData.workspace.id > 0 ? String(modelData.workspace.name) : ""
                  onTriggered: menu.run(function() { root.focusWindow(modelData.address) })
                }
              }

              MenuSeparator {}

              MenuRow {
                visible: menu.hasEntry || menu.wins.length === 0
                glyph: menu.wins.length ? "\u{F0415}" : "\u{F14DE}"
                label: menu.wins.length ? "New Window" : "Open"
                onTriggered: { var k = menu.key; menu.run(function() { root.launch(k) }) }
              }
              MenuRow {
                visible: menu.hasEntry
                glyph: menu.isPinned ? "\u{F0931}" : "\u{F0403}"
                label: menu.isPinned ? "Unpin from Dock" : "Keep in Dock"
                onTriggered: { var k = menu.key; menu.run(function() { root.togglePin(k) }) }
              }
              MenuRow {
                visible: menu.wins.length > 0
                glyph: "\u{F0156}"
                label: menu.wins.length > 1 ? "Close All " + menu.wins.length + " Windows" : "Close Window"
                danger: true
                onTriggered: { var k = menu.key; menu.run(function() { root.quit(k) }) }
              }
            }
          }
        }
      }
    }
  }

  component MenuSeparator: Item {
    width: parent ? parent.width : 0
    height: visible ? 9 : 0
    Rectangle {
      anchors.centerIn: parent
      width: parent.width - 12
      height: 1
      color: Util.alpha(Color.menu.text, 0.1)
    }
  }

  // A menu row: a glyph (or, for a window, a dot that lights for the focused
  // one), the label, and an optional workspace badge on the right.
  component MenuRow: Rectangle {
    id: mrow
    property string label: ""
    property string glyph: ""
    property string badge: ""
    property bool current: false
    property bool danger: false
    signal triggered()
    readonly property bool hot: marea.containsMouse
    readonly property color ink: danger ? Color.urgent : (hot ? Color.menu.selectedText : Color.menu.text)
    width: parent ? parent.width : 200
    implicitWidth: 36 + mlabel.implicitWidth + (badge ? mbadge.width + 16 : 12)
    height: visible ? 32 : 0
    radius: Math.min(8, Style.cornerRadius)
    color: hot ? (danger ? Util.alpha(Color.urgent, 0.14) : Color.menu.selectedBackground) : "transparent"
    Behavior on color { ColorAnimation { duration: 90 } }

    Item {
      id: lead
      x: 6
      width: 22
      height: parent.height
      Text {
        anchors.centerIn: parent
        visible: mrow.glyph !== ""
        text: mrow.glyph
        color: mrow.ink
        font.family: Style.fontFamily
        font.pixelSize: Style.font.heading
      }
      Rectangle {
        anchors.centerIn: parent
        visible: mrow.glyph === ""
        width: 6; height: 6; radius: 3
        color: mrow.current ? Color.accent : Util.alpha(Color.menu.text, 0.25)
      }
    }
    Text {
      id: mlabel
      anchors.verticalCenter: parent.verticalCenter
      x: 36
      width: parent.width - x - (mrow.badge ? mbadge.width + 16 : 10)
      elide: Text.ElideRight
      text: mrow.label
      color: mrow.ink
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.body
      font.weight: mrow.current ? Font.DemiBold : Font.Normal
    }
    Rectangle {
      id: mbadge
      visible: mrow.badge !== ""
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right
      anchors.rightMargin: 8
      width: Math.max(20, btext.implicitWidth + 10)
      height: 18
      radius: Math.min(5, Style.cornerRadius)
      color: Util.alpha(Color.menu.text, mrow.hot ? 0.14 : 0.08)
      Text {
        id: btext
        anchors.centerIn: parent
        text: mrow.badge
        color: Util.alpha(Color.menu.text, 0.7)
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.caption
      }
    }
    MouseArea {
      id: marea
      anchors.fill: parent
      hoverEnabled: true
      onClicked: mrow.triggered()
    }
  }
}
