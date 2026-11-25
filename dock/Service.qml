import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Widgets
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bottom dock: pinned apps, then running apps that aren't pinned. Window state
// comes from Quickshell's Hyprland IPC (refreshed on Hyprland events), so window
// geometry is known and the dock can hide only when a window actually overlaps it.
//
// Config: ~/.config/omarchy/dock.json (watched; the dock rewrites `pinned`
// when you pin/unpin from the right-click menu or by dragging an icon).
//   pinned    desktop ids, without ".desktop"
//   iconSize  px at rest
//   height    panel height in px (independent of iconSize)
//   magnify   hovered icon scale (1 = off)
//   autohide  "smart" (hide when a window overlaps), "always", "never" (always
//             there: the dock keeps its strip of the screen to itself, so tiled
//             windows stop short of it; it steps aside only for a fullscreen one)
//   slideToWindow  clicking an app whose one window is on another desktop:
//             true (default) has Aerial slide there; false switches at once
//   genie         minimizing pours the window into its icon, and restoring
//                 pours it back out (default true)
//   hoverWindows  resting the pointer on an app with several windows lists
//                 them above its icon, to pick one (default true)
//   windowPicker  clicking an app with several windows: "aerial" opens
//             Aerial's overview on just that app's windows; "cycle" focuses
//             them in turn
//   classAliases  {"<regex on window class>": "<desktop id>"} for apps whose
//             class matches no desktop entry (e.g. MATLAB's versioned class)
Item {
  id: root
  width: 0
  height: 0
  visible: false

  property var shell: null
  // The window overview, handed in by the plugin; null without one.
  property var overview: null

  // The holographic theme's look. `[holo]` keys exist only in its shell.toml, so
  // under any other theme this is false and the plain branches below are the dock.
  readonly property bool holo: Commons.Color.pick("holo.line", "") !== ""

  // Omarchy minimizes a window by moving it here (omarchy-hyprland-window-minimize).
  readonly property string minimizedWorkspace: "special:minimized"

  // ------------------------------------------------------------------ config
  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/dock.json"
  property var config: ({})
  readonly property var pinned: Array.isArray(config.pinned) ? config.pinned : []
  readonly property var classAliases: config.classAliases && typeof config.classAliases === "object" ? config.classAliases : ({})
  onClassAliasesChanged: { idCache = ({}); scheduleRebuild() }
  // Under the holographic theme everything here is whole tiles: the config's icon size comes
  // to the nearest, and the height follows from it (see dockHeight).
  readonly property int tile: 6
  readonly property int iconSize: {
    const asked = Math.max(24, Number(config.iconSize) || 38)
    return holo ? Math.round(asked / tile) * tile : asked
  }
  readonly property real magnify: Math.max(1, Math.min(2, Number(config.magnify) || 1.45))
  readonly property bool slideToWindow: config.slideToWindow !== false
  readonly property string windowPicker: config.windowPicker === "cycle" ? "cycle" : "aerial"
  // Resting the pointer on an app brings up one panel: its windows to pick from,
  // or its name when it has none.
  readonly property bool hoverWindows: config.hoverWindows !== false
  readonly property int hoverDelay: 350
  // Between the dock's top edge and the panel that hover brings up.
  readonly property int hoverGap: 8
  readonly property string autohide: ["smart", "always", "never"].indexOf(config.autohide) >= 0 ? config.autohide : "smart"

  // The panel's height is set on its own, so smaller icons get more air
  // rather than a thinner dock. Icons sit centred above a strip for the dots (not under the
  // holographic theme, below).
  readonly property int dotZone: 10
  // Holographic, in tiles: 3 of air, the icon, 3 of air, so the icon sits centred. Its marks
  // (a hairline with a square per window) are drawn in the lower air, not given a strip.
  readonly property int dockHeight: holo ? iconSize + tile * 6 : Math.max(iconSize + dotZone + 4, Number(config.height) || 63)
  readonly property int padding: holo ? tile * 3 : Math.round((dockHeight - dotZone - iconSize) / 2) + 1
  readonly property int sidePadding: holo ? tile * 2 : Math.max(padding, Math.round(iconSize * 0.3))
  // The holographic dock's ends, in tiles: its bracket a tile in from the edge, then two of
  // air before the first icon. The same on the right.
  readonly property int leadLeft: holo ? tile * 3 : sidePadding
  readonly property int leadRight: holo ? tile * 3 : sidePadding
  readonly property int spacing: holo ? tile * 2 : Math.round(iconSize * 0.26)
  // Flush with the screen edge.
  readonly property int edgeGap: 0
  readonly property int separatorWidth: holo ? tile * 2 : spacing + 1
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
  Timer { id: remapTimer; interval: 50; onTriggered: root.remapping = false }
  Timer { interval: 2000; running: true; onTriggered: root.restack() }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var n = event.name
      if (n === "genie") {
        var said = String(event.data).trim().split(",")
        if (said[0] === "out") root.genieLanded(said[1])
      }
      else if (n === "openlayer" && String(event.data).trim() === "omarchy-aerial") root.restack()
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
    for (var re in root.classAliases) {
      try { if (new RegExp(re).test(cls)) entry = root.entryFor(String(root.classAliases[re])) } catch (e) {}
      if (entry) break
    }
    if (!entry) try { entry = DesktopEntries.heuristicLookup(cls) } catch (e) {}
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
    // An installed desktop entry may name an image file; a window class is
    // chosen by the app itself, so only an icon-theme name is looked up from
    // one, never a path for the shell's image decoder to open.
    var icon = e ? String(e.icon || "") : key.replace(/^class:/, "")
    if (e && icon.charAt(0) === "/") return "file://" + icon
    if (!/^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$/.test(icon)) return Quickshell.iconPath("application-x-executable", true)
    var p = Quickshell.iconPath(icon, true)
    if (!p) p = Quickshell.iconPath(icon.toLowerCase(), true)
    return p || Quickshell.iconPath("application-x-executable", true)
  }

  property var windowsByKey: ({})
  property var runningOrder: []
  property var items: []       // [{ key, separator }]
  property string itemsSig: ""

  // What the dock draws: `items` plus icons still shrinking away. Kept as a
  // keyed ListModel so surviving icons keep their delegates and only the
  // changed ones grow in or shrink out (pin, unpin, apps opening/closing).
  ListModel { id: cells }
  property int cellUid: 0
  property bool cellsReady: false

  function syncCells(next) {
    var live = []
    for (var i = 0; i < cells.count; i++) {
      var c = cells.get(i)
      if (!c.leaving) live.push({ row: i, t: next.findIndex(function(it) { return it.key === c.key }) })
    }
    // Keep the longest run of icons already in the right order; everything
    // else leaves and re-enters at its new place (a pin moves the icon from
    // the running group to the end of the pinned ones).
    var len = [], prev = []
    for (var a = 0; a < live.length; a++) {
      len[a] = live[a].t < 0 ? 0 : 1; prev[a] = -1
      if (live[a].t < 0) continue
      for (var b = 0; b < a; b++)
        if (live[b].t >= 0 && live[b].t < live[a].t && len[b] + 1 > len[a]) { len[a] = len[b] + 1; prev[a] = b }
    }
    var best = -1
    for (var m = 0; m < live.length; m++) if (best < 0 || len[m] > len[best]) best = m
    var kept = {}
    for (var k = best; k >= 0 && len[k] > 0; k = prev[k]) kept[live[k].row] = true
    var rowOf = {}
    for (var r = 0; r < cells.count; r++) {
      var cr = cells.get(r)
      if (cr.leaving) continue
      if (kept[r]) rowOf[next.findIndex(function(it) { return it.key === cr.key })] = r
      else cells.setProperty(r, "leaving", true)
    }
    // Insert the rest right after their predecessor in the new order.
    for (var t = 0; t < next.length; t++) {
      if (rowOf[t] !== undefined) continue
      var at = t > 0 ? rowOf[t - 1] + 1 : 0
      cells.insert(at, { key: next[t].key, separator: next[t].separator, leaving: false, uid: ++root.cellUid })
      for (var q in rowOf) if (rowOf[q] >= at) rowOf[q]++
      rowOf[t] = at
    }
    root.cellsReady = true
  }

  function dropCell(uid) {
    for (var i = 0; i < cells.count; i++)
      if (cells.get(i).uid === uid) { cells.remove(i); return }
  }

  function itemIndex(key) { return root.items.findIndex(function(it) { return it.key === key }) }

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
    // and animation state) survive ordinary window events. Mid-drag the cells
    // are the dragger's to rearrange; the order catches up on the drop.
    var sig = next.map(function(it) { return it.key }).join("|")
    if (sig !== root.itemsSig && !root.dragKey) {
      root.itemsSig = sig
      root.items = next
      root.syncCells(next)
    }
  }

  // ------------------------------------------------------------------ drag
  // An icon being dragged, while it is (one panel drags at a time).
  property string dragKey: ""

  // Take the dragged-into order from the cells: what's left of the divider
  // is pinned, what's right of it is the running apps' order. `removed` is a
  // pinned icon dropped off the dock.
  function commitOrder(key, removed) {
    var before = [], after = [], seen = false
    for (var i = 0; i < cells.count; i++) {
      var c = cells.get(i)
      if (c.leaving) continue
      if (c.separator) seen = true
      else (seen ? after : before).push(c.key)
    }
    // No divider: everything is pinned, or nothing is.
    if (!seen && !root.pinned.length) { after = before; before = [] }
    if (removed) before = before.filter(function(k) { return k !== key })
    var pins = before.filter(function(k) { return k.indexOf("class:") !== 0 })
    root.runningOrder = after.concat(root.runningOrder.filter(function(k) { return after.indexOf(k) < 0 }))
    root.dragKey = ""
    if (pins.join("|") !== root.pinned.join("|")) root.setPinned(pins)
    else root.rebuild()
  }

  // A drag cut short: put the cells back where the apps belong.
  function revertOrder() {
    root.dragKey = ""
    root.itemsSig = ""
    root.rebuild()
  }

  // Centres of each item in the un-magnified layout, used to drive the
  // magnification without feedback from the growing icons.
  readonly property var baseCenters: {
    var out = []
    var x = root.leadLeft
    for (var i = 0; i < root.items.length; i++) {
      var w = root.items[i].separator ? root.separatorWidth : root.iconSize
      out.push(x + w / 2)
      x += w + (i < root.items.length - 1 ? root.spacing : 0)
    }
    return out
  }
  readonly property real baseWidth: {
    var w = root.leadLeft + root.leadRight
    for (var i = 0; i < root.items.length; i++)
      w += (root.items[i].separator ? root.separatorWidth : root.iconSize) + (i ? root.spacing : 0)
    return w
  }

  // How much of each screen's bottom edge the dock covers, by monitor name.
  property var covers: ({})
  function setCover(monitor, px) {
    if (root.covers[monitor] === px) return
    var next = Object.assign({}, root.covers)
    next[monitor] = px
    root.covers = next
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
    } else if (key.indexOf("class:") !== 0) {
      Quickshell.execDetached(["uwsm-app", "--", key])
    } else {
      // A window class is whatever the app called itself: never something to
      // run. The menu offers no "New Window" for one either.
      return
    }
    root.launched(key)
  }

  function activate(key) {
    var wins = root.windowsByKey[key] || []
    if (!wins.length) { root.launch(key); return }
    // Several windows: let Aerial lay them out to pick from; choosing one
    // takes you to its desktop the way the overview always does.
    // A minimized window comes back first, one per click: the icon is the only way
    // to it, and the overview has no desktop to show it on.
    var waiting = wins.filter(root.isMinimized)
    if (waiting.length) { root.restoreWindow(waiting[0]); return }
    if (wins.length > 1 && root.windowPicker === "aerial" && root.overview) {
      root.overview.showApp(String(wins[0].class))
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
    var next = stable[(at + 1) % stable.length]
    if (root.isMinimized(next)) root.restoreWindow(next)
    else root.focusWindow(next.address)
  }

  // ------------------------------------------------------------------ genie
  // Minimizing pours the window into its icon and restoring pours it back out
  // (see Genie.qml). Either falls back to the plain move whenever a picture of
  // the window or a place for it can't be had.
  readonly property bool genieOn: config.genie !== false
  Genie { id: genie }
  readonly property string genieScreen: genie.active ? genie.screenName : ""

  function monitorById(id) { return (Hyprland.monitors.values || []).find(function(m) { return m.id === id }) || null }
  function panelOn(name) {
    var all = panels.instances || []
    for (var i = 0; i < all.length; i++) if (all[i].modelData.name === name) return all[i]
    return null
  }
  function keyOfWindow(addr) {
    for (var k in root.windowsByKey) {
      var wins = root.windowsByKey[k]
      for (var i = 0; i < wins.length; i++) if (wins[i].address === addr) return k
    }
    return ""
  }
  function clientAt(addr) { return root.clients.find(function(c) { return c.address === addr }) || null }
  // What the genie needs to play `win` on `mon`: null when any of it is missing.
  // `at` is the window's corner in the layout, as Hyprland reports it.
  function genieJob(win, mon, at, size) {
    if (!root.genieOn || !win || !mon || !win.tl || !win.tl.wayland || !(size[0] > 1 && size[1] > 1)) return null
    var panel = root.panelOn(mon.name)
    var sink = panel ? panel.iconRect(root.keyOfWindow(win.address)) : null
    if (!sink) return null
    var deco = root.overview && root.overview.deco ? root.overview.deco : null
    return {
      screen: mon.name, capture: win.tl.wayland, sink: sink,
      win: Qt.rect(at[0] - mon.x, at[1] - mon.y, size[0], size[1]),
      barH: deco && deco.bars ? deco.barHeight : 0,
      barColor: deco ? deco.barColor : "transparent",
      rounding: deco ? deco.rounding : 0,
      deco: deco, title: root.nameFor(root.keyOfWindow(win.address)),
      address: win.address, scale: mon.scale > 0 ? mon.scale : 1
    }
  }
  // The genie changes the window and its picture over behind a cover, and holds
  // the cover until the window is seen to have moved (Genie.qml): seen here, in
  // the windows as Hyprland last reported them.
  function genieWatch() {
    if (genie.awaiting === "") return
    var win = root.clientAt(genie.address)
    if (!win) { genie.confirm(); return }
    if ((genie.awaiting === "gone") === root.isMinimized(win)) genie.confirm()
  }
  onClientsChanged: root.genieWatch()
  function setNoAnim(addr, on) {
    root.hypr('hl.dsp.window.set_prop({ prop = "no_anim", value = "' + (on ? "1" : "unset") + '", window = "address:' + addr + '" })')
  }
  function stockMinimize(addr) { Quickshell.execDetached(["omarchy-hyprland-window-minimize", addr]) }

  IpcHandler {
    target: "quokecola.omardeck.dock"
    // From dock/bin/minimize, which has checked the window may be minimized and
    // read where it is: a floating window moves without an event, so what this
    // service last heard may be stale. "ok" means the dock has taken it on; on
    // any other answer the caller minimizes it the plain way.
    function minimize(address: string, x: int, y: int, w: int, h: int): string {
      if (!/^0x[0-9a-f]+$/.test(address)) return "error: invalid address"
      var win = root.clientAt(address)
      var job = win ? root.genieJob(win, root.monitorById(win.monitor), [x, y], [w, h]) : null
      if (!job) return "no"
      job.minimizing = true
      job.ready = function() { root.setNoAnim(address, true); root.stockMinimize(address) }
      job.fallback = function() { root.stockMinimize(address) }
      job.done = function() { restoreSettle.targets = restoreSettle.targets.concat(['window = "address:' + address + '"']); restoreSettle.restart() }
      // Hyprland bends the window itself when it can; the picture is for when it
      // can't. Either way the window is taken away once it is in the icon.
      root.compositorGenie("out", job, function() { job.ready(); job.done() }, function() { genie.play(job) })
      return "ok"
    }
    // Bring a minimized window back, as a click on its icon does.
    function restore(address: string): string {
      if (!/^0x[0-9a-f]+$/.test(address)) return "error: invalid address"
      var win = root.clientAt(address)
      if (!win || !root.isMinimized(win)) return "no"
      root.restoreWindow(win)
      return "ok"
    }
  }

  function isMinimized(win) { return !!win && !!win.workspace && win.workspace.name === root.minimizedWorkspace }

  // A minimized window waits on a special workspace. Focusing it there would only
  // show that workspace over the desktop, the window still on it: it is moved back
  // to the workspace in front of the user first, as Omarchy's own dock does, then
  // focused and raised. Without animating in: it is simply there again.
  function restoreWindow(win) {
    var mon = Hyprland.focusedMonitor
    var workspace = mon && mon.activeWorkspace ? mon.activeWorkspace.id : -1
    if (!(workspace >= 1)) return
    // Poured out of the icon first, to where the window will stand: a floating
    // window keeps its place, carried over when it comes back on another monitor.
    var from = root.monitorById(win.monitor)
    var at = from && from.id !== mon.id ? [win.at[0] - from.x + mon.x, win.at[1] - from.y + mon.y] : win.at
    var job = root.genieJob(win, mon, at, win.size)
    if (!job) { root.placeWindow(win, workspace); return }
    job.minimizing = false
    job.done = function() { root.placeWindow(win, workspace) }
    job.fallback = job.done
    // Armed first, so the window is already being poured the first time
    // Hyprland draws it back on the desktop.
    root.compositorGenie("in", job, job.done, function() { genie.play(job) })
  }

  // The genie as Hyprland's own (glass/src/genie.inc): the window itself is bent,
  // live, with its frost and shadow, so there is no picture to change places
  // with. `then` runs when the window is in the icon ("out") or as soon as it is
  // armed ("in"); `otherwise` when the plugin is not there to do it.
  readonly property bool genieInCompositor: root.overview && root.overview.deco && root.overview.deco.genie === true
  property var genieWaits: ({})
  function compositorGenie(way, job, then, otherwise) {
    if (!root.genieInCompositor || genieCmd.running) { otherwise(); return }
    var s = job.sink
    var ms = Math.max(1, Style.duration(genie.duration))
    genieCmd.way = way
    genieCmd.address = job.address
    genieCmd.then = then
    genieCmd.otherwise = otherwise
    genieCmd.ms = ms
    genieCmd.command = ["/usr/bin/hyprctl", "genie", way, job.address,
      String(Math.round(s.x)), String(Math.round(s.x + s.width)), String(Math.round(s.y + s.height)), String(Math.round(ms))]
    genieCmd.running = true
  }
  Process {
    id: genieCmd
    property string way: ""
    property string address: ""
    property var then: null
    property var otherwise: null
    property real ms: 500
    stdout: StdioCollector { id: genieSaid }
    onExited: (code) => {
      var ok = code === 0 && String(genieSaid.text || "").trim() === "ok"
      var then = genieCmd.then, otherwise = genieCmd.otherwise
      genieCmd.then = null
      genieCmd.otherwise = null
      if (!ok) { if (otherwise) otherwise(); return }
      if (genieCmd.way === "in") { if (then) then(); return }
      // "out": the plugin says when the window is in (the `genie` event below),
      // and if it never does the window is taken anyway.
      var waits = Object.assign({}, root.genieWaits)
      waits[genieCmd.address] = then
      root.genieWaits = waits
      genieOverdue.address = genieCmd.address
      genieOverdue.interval = genieCmd.ms + 500
      genieOverdue.restart()
    }
  }
  Timer { id: genieOverdue; property string address: ""; onTriggered: root.genieLanded(address) }
  function genieLanded(address) {
    var then = root.genieWaits[address]
    if (!then) return
    var waits = Object.assign({}, root.genieWaits)
    delete waits[address]
    root.genieWaits = waits
    then()
  }
  function placeWindow(win, workspace) {
    var target = 'window = "address:' + win.address + '"'
    root.hypr('hl.dsp.window.set_prop({ prop = "no_anim", value = "1", ' + target + ' })')
    root.hypr('hl.dsp.window.move({ workspace = "' + workspace + '", ' + target + ' })')
    root.hypr('hl.dsp.focus({ ' + target + ' })')
    root.hypr('hl.dsp.window.alter_zorder({ mode = "top", ' + target + ' })')
    restoreSettle.targets = restoreSettle.targets.concat([target])
    restoreSettle.restart()
  }
  Timer {
    id: restoreSettle
    property var targets: []
    interval: 400
    onTriggered: {
      for (var i = 0; i < targets.length; i++)
        root.hypr('hl.dsp.window.set_prop({ prop = "no_anim", value = "unset", ' + targets[i] + ' })')
      targets = []
    }
  }

  // Off on another desktop: the overview slides there. Mid-swipe or
  // half open it can't, and the window is focused straight away instead.
  function goToWindow(win) {
    if (root.isMinimized(win)) { root.restoreWindow(win); return }
    var mon = null
    for (var m = 0; m < root.monitors.length; m++) if (root.monitors[m].id === win.monitor) mon = root.monitors[m]
    var here = mon && mon.activeWorkspace && mon.activeWorkspace.id === win.workspace.id
    var ov = root.overview
    var canSlide = ov && !(!ov.open && (ov.showing || ov.scrub !== ""))
    if (!root.slideToWindow || here || win.workspace.id <= 0 || !canSlide) { root.focusWindow(win.address); return }
    ov.gotoWindow(win.address)
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
          var out = { fixed: false, floating: false, floatingHere: false, fullscreen: false }
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
            // Really fullscreen, not maximized: that one stops at the dock's strip.
            if (c.fullscreen >= 2) out.fullscreen = true
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

        // Where an app's icon is on this screen, for the genie to pour into. On the
        // screen's bottom edge while the dock is slid away. Null with no such icon.
        function iconRect(key) {
          if (!key) return null
          for (var i = 0; i < cellRepeater.count; i++) {
            var slot = cellRepeater.itemAt(i)
            if (!slot || slot.key !== key || slot.leaving) continue
            var p = slot.cellItem.mapToItem(panel.contentItem, 0, 0)
            var sw = panel.screen ? panel.screen.width : panel.width
            var sh = panel.screen ? panel.screen.height : panel.height
            var y = Math.min(sh - 2, sh - panel.height + p.y)
            return Qt.rect((sw - panel.width) / 2 + p.x, y, slot.cellItem.width, Math.min(slot.cellItem.height, sh - y))
          }
          return null
        }
        // Never hiding still gives way to a fullscreen window, as the bar does.
        readonly property bool wantHidden: root.autohide === "always" || (root.autohide === "smart" && overlapped)
                                           || (root.autohide === "never" && coverage.fullscreen)
        readonly property bool revealed: !wantHidden || hovered || lingering || menuKey !== "" || peekKey !== "" || dragUid >= 0
                                        || root.genieScreen === modelData.name

        onHoveredChanged: if (!hovered) { lingering = true; lingerTimer.restart() }

        // How much of this screen's bottom edge the dock covers (0 when
        // hidden), in `covers` by monitor: the overview lifts its desktop
        // dots above it.
        readonly property int covers: revealed && visible ? Math.ceil(root.edgeGap + root.dockHeight) : 0
        onCoversChanged: root.setCover(modelData.name, panel.covers)
        Component.onCompleted: root.setCover(modelData.name, panel.covers)
        Timer { id: lingerTimer; interval: 350; onTriggered: panel.lingering = false }

        // Over a fullscreen window, unmap once slid away: any surface above
        // it, even an empty one, stops the compositor scanning it out directly.
        readonly property var hyprMonitor: (Hyprland.monitors.values || []).find(m => m.name === modelData.name) || null
        readonly property bool fullscreenHere: !!(hyprMonitor && hyprMonitor.activeWorkspace
                                                  && hyprMonitor.activeWorkspace.hasFullscreen)
        visible: root.items.length > 0 && !root.remapping && !(fullscreenHere && !revealed && !slider.visible)
        color: "transparent"
        // Always there, the dock has its strip to itself: Hyprland lays tiled and
        // maximized windows out above it. The same whether or not it is on screen
        // just now, so a fullscreen window coming and going doesn't re-lay the desktop.
        readonly property bool keepsStrip: root.autohide === "never"
        exclusionMode: panel.keepsStrip ? ExclusionMode.Normal : ExclusionMode.Ignore
        exclusiveZone: panel.keepsStrip ? Math.ceil(root.edgeGap + root.dockHeight) : 0
        WlrLayershell.namespace: "omarchy-dock"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors.bottom: true
        // The window's, as a screen's is rounded up to a whole number under a fractional scale.
        readonly property real dpr: devicePixelRatio || 1
        // Snap logical lengths onto the device-pixel grid (0.75 px steps at
        // 1.33) so resting icons land on whole pixels instead of smearing.
        function snap(v) { return Math.round(v * dpr) / dpr }
        readonly property real restIcon: snap(root.iconSize)
        // Room above the dock for an icon lifted off it. Always there: growing
        // the surface as a drag began made the dock jump while the compositor
        // caught up with the new size. It's transparent and outside the input
        // mask, so it costs nothing.
        readonly property real headroom: root.iconSize * (root.magnify - 1) + 40 + root.iconSize * 2.5
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

        // ------------------------------------------------------------ drag
        // Drag an icon along the dock to move it; left of the divider pins
        // it, right of it unpins it. Lift a pinned icon off the dock to
        // remove it. The cells reorder as it passes and the icons it passes
        // slide over; the order is written on the drop.
        property int dragUid: -1
        property var dragSlot: null
        property real dragX: 0       // the dragged icon's left/top, in row coordinates
        property real dragY: 0
        property real grabX: 0
        property real grabY: 0
        property bool canRemove: false
        property bool removing: false

        function dragRow() {
          for (var i = 0; i < cells.count; i++) if (cells.get(i).uid === panel.dragUid) return i
          return -1
        }

        function startDrag(slot, cell, p) {
          panel.closeMenu()
          panel.closePeek()
          var c = cell.mapToItem(row, 0, 0)
          // Pressed on a magnified icon: keep the same spot of it in hand
          // as it shrinks back to its resting size.
          var k = cell.width > 0 ? panel.restIcon / cell.width : 1
          panel.grabX = (p.x - c.x) * k
          panel.grabY = (p.y - c.y) * k
          panel.dragSlot = slot
          panel.canRemove = root.pinned.indexOf(slot.key) >= 0
          panel.removing = false
          panel.dragUid = slot.uid
          root.dragKey = slot.key
        }

        function dragTo(p) {
          panel.dragX = p.x - panel.grabX
          panel.dragY = p.y - panel.grabY
          var lift = (row.height - panel.restIcon) - panel.dragY
          panel.removing = panel.canRemove && lift > root.iconSize * 1.2
          if (!panel.removing) panel.retarget(panel.dragX + panel.restIcon / 2)
        }

        // Move the dragged cell to where its centre now falls among the
        // others; class-only apps can't be pinned, so stay right of the divider.
        function retarget(center) {
          var from = panel.dragRow()
          var self = from >= 0 ? cellRepeater.itemAt(from) : null
          if (!self) return
          var w = self.width
          // Laid out from the widths, not the Row: it repositions on the
          // next frame, and two moves can come in before then.
          var n = 0, seen = 0, sep = -1, x = 0
          for (var k = 0; k < cells.count; k++) {
            if (k === from) continue
            var s = cellRepeater.itemAt(k)
            var c = cells.get(k)
            if (c.separator && !c.leaving) sep = seen
            if (s && x + s.iconCenter < center) n = seen + 1
            if (s) x += s.width
            seen++
          }
          if (self.key.indexOf("class:") === 0 && sep >= 0) n = Math.max(n, sep + 1)
          if (n === from) return
          cells.move(from, n, 1)
          // The cells it passed each shift by its width: start them where
          // they were and let them slide over.
          for (var a = Math.min(from, n + 1); a <= Math.max(from, n - 1); a++) {
            var moved = cellRepeater.itemAt(a)
            if (moved && moved !== self) moved.nudge(n > from ? w : -w)
          }
        }

        function endDrag(cancelled) {
          var slot = panel.dragSlot
          var removed = panel.removing && !cancelled
          slot.hold()
          panel.dragUid = -1
          panel.dragSlot = null
          panel.removing = false
          if (cancelled) root.revertOrder()
          else root.commitOrder(slot.key, removed)
          // Gone from the dock: fade out where it was let go. Otherwise
          // settle into its place.
          if (removed && slot.leaving) slot.collapsed = true
          else slot.settle()
        }

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
            readonly property bool holo: holoFrame.item ? holoFrame.item.active : false
            readonly property real hiddenOffset: root.edgeGap + root.dockHeight + 6
            property real offset: panel.revealed ? 0 : hiddenOffset
            // `offset` and the bindings on `panel.revealed` update in an order that isn't promised.
            // Measured, the plain branch's animation starts on the previous direction's numbers,
            // so its slide in really runs 420 ms on the slide-out curve, and its slide out 620 ms
            // on the other. That is today's plain look, and it stays by these bindings staying
            // as they are: routing them through another property swaps it. Under the holographic
            // theme the Behavior's own target says which way, as it is set before the animation starts.
            Behavior on offset {
              id: slide
              NumberAnimation {
                // Shorter under the holographic theme: every frame of this redraws the dock
                // and makes the compositor blur behind it again.
                duration: Style.duration(slider.holo ? (slide.targetValue === 0 ? 180 : 280) : (panel.revealed ? 620 : 420))
                easing.type: Easing.BezierSpline
                easing.bezierCurve: slider.holo
                  ? (slide.targetValue === 0 ? Style.easeOut : [0.2, 0, 0, 1, 1, 1])
                  : (panel.revealed ? [1, 0, 0.8, 1, 1, 1] : [0.2, 0, 0, 1, 1, 1])
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
              width: Math.max(0, row.width - panel.snap(root.spacing)) + panel.snap(root.leadLeft) + panel.snap(root.leadRight)
              // Flush against the screen edge, only the top corners round: the bottom
              // ones would cut notches out of the edge.
              readonly property real corner: root.holo ? 0 : Math.min(14, Style.cornerRadius)
              topLeftRadius: corner
              topRightRadius: corner
              bottomLeftRadius: root.edgeGap > 0 ? corner : 0
              bottomRightRadius: root.edgeGap > 0 ? corner : 0
              color: slider.holo ? "transparent" : Commons.Color.bar.background
              border.width: slider.holo ? 0 : 1
              border.color: Util.alpha(Commons.Color.bar.text, 0.12)
            }

            // The holographic theme's shared panel, as on the bar's panels (see quokecola.hud).
            // The bottom runs off the screen.
            Loader {
              id: holoFrame
              anchors.fill: dock
              anchors.margins: holoFrame.item ? -holoFrame.item.pad : 0
              source: Qt.resolvedUrl("../../quokecola.hud/holo/HoloFrame.qml")
              // Loaded for `active`, which says the theme is on. The dock draws no panel under
              // it: a bracket at each end and a keyline under each icon, below.
              visible: !slider.holo
            }

            // The holographic dock's ends: a tall bracket each side, a tile in from the
            // dock's edge, its feet a tile long and pointing inward. One device pixel.
            Item {
              id: ends
              visible: slider.holo
              readonly property color pale: Commons.Color.pick("holo.line", Commons.Color.bar.text)
              readonly property real inset: panel.snap(root.tile)
              readonly property real foot: panel.snap(root.tile)
              readonly property real hair: 1 / panel.dpr
              readonly property real tall: panel.snap(root.dockHeight) - inset * 2
              Repeater {
                model: 2
                Item {
                  required property int index
                  readonly property bool atRight: index === 1
                  x: atRight ? dock.x + dock.width - ends.inset - width : dock.x + ends.inset
                  y: dock.y + ends.inset
                  width: ends.foot
                  height: ends.tall
                  Rectangle { x: parent.atRight ? parent.width - width : 0; width: ends.hair; height: parent.height; color: ends.pale }
                  Rectangle { width: parent.width; height: ends.hair; color: ends.pale }
                  Rectangle { y: parent.height - height; width: parent.width; height: ends.hair; color: ends.pale }
                }
              }
            }

            Row {
              id: row
              x: dock.x + panel.snap(root.leadLeft)
              y: dock.y + panel.snap(root.padding) + panel.restIcon - height
              // Each slot carries its own trailing gap so a growing or
              // shrinking icon opens and closes the space smoothly.
              spacing: 0

              Repeater {
                id: cellRepeater
                model: cells

                delegate: Item {
                  id: slot
                  required property string key
                  required property bool separator
                  required property bool leaving
                  required property int uid

                  // 0 -> 1 as the icon arrives, back to 0 as it leaves.
                  property real grow: root.cellsReady ? 0 : 1
                  Component.onCompleted: grow = Qt.binding(function() { return slot.leaving ? 0 : 1 })
                  Behavior on grow { NumberAnimation { duration: Style.duration(300); easing.type: Easing.OutCubic } }
                  onGrowChanged: if (leaving && grow <= 0) Qt.callLater(root.dropCell, uid)

                  // Collapses while its icon is held off the dock to remove it.
                  property bool collapsed: false
                  property real room: collapsed || (cell.dragged && panel.removing) ? 0 : 1
                  Behavior on room { NumberAnimation { duration: Style.duration(200); easing.type: Easing.OutCubic } }

                  width: (cell.width + panel.snap(root.spacing)) * grow * room
                  height: cell.height
                  anchors.bottom: parent.bottom
                  z: cell.dragged ? 1 : 0
                  readonly property real iconCenter: cell.width / 2

                  // Slides over from where it was when a dragged icon passes it.
                  property real shift: 0
                  transform: Translate { x: slot.shift }
                  NumberAnimation { id: shiftAnim; target: slot; property: "shift"; to: 0; duration: Style.duration(220); easing.type: Easing.OutCubic }
                  function nudge(dx) { shiftAnim.stop(); slot.shift += dx; shiftAnim.from = slot.shift; shiftAnim.start() }

                  // Let go of: keep the icon where it was dropped, then glide home.
                  function hold() { cell.dropX = cell.liftX; cell.dropY = cell.liftY; cell.settleT = 1 }
                  function settle() { settleAnim.restart() }
                  NumberAnimation { id: settleAnim; target: cell; property: "settleT"; from: 1; to: 0; duration: Style.duration(260); easing.type: Easing.OutCubic }

                  readonly property alias cellItem: cell
                  Item {
                    id: cell
                    readonly property string key: slot.key
                    readonly property bool isSep: slot.separator
                    readonly property int index: root.itemIndex(key)
                    scale: slot.grow
                    opacity: slot.grow
                    transformOrigin: Item.Bottom
                    // Following the pointer while dragged, gliding back after.
                    readonly property bool dragged: panel.dragUid === slot.uid
                    property real dropX: 0
                    property real dropY: 0
                    property real settleT: 0
                    readonly property real liftX: dragged ? panel.dragX - slot.x - slot.shift : dropX * settleT
                    readonly property real liftY: dragged ? panel.dragY - slot.y - cell.y : dropY * settleT
                    transform: Translate { x: cell.liftX; y: cell.liftY }
                    readonly property var wins: root.windowsByKey[key] || []
                    readonly property bool isActive: {
                      for (var i = 0; i < wins.length; i++) if (wins[i].address === root.activeAddress) return true
                      return false
                    }

                    // One letter per mark, at most three: f focused, r running, m minimized.
                    // Sorted, not in focus order, and a string so that a focus change
                    // elsewhere rebuilds nothing. A minimized window keeps a slot however
                    // many others there are, since this is the one sign of it.
                    readonly property string tickStates: {
                      var f = "", r = "", m = ""
                      for (var i = 0; i < wins.length; i++) {
                        if (wins[i].address === root.activeAddress) f += "f"
                        else if (wins[i].workspace.name === root.minimizedWorkspace) m += "m"
                        else r += "r"
                      }
                      return (f + r.slice(0, Math.max(0, 3 - f.length - (m ? 1 : 0))) + m).slice(0, 3)
                    }

                    readonly property real target: {
                      if (isSep || slot.leaving || !panel.hovered || root.magnify <= 1 || panel.menuKey !== "" || panel.dragUid >= 0) return 1
                      var d = (panel.pointerX - (root.baseCenters[index] || 0)) / (root.iconSize + root.spacing)
                      return 1 + (root.magnify - 1) * Math.exp(-d * d / 1.6)
                    }
                    property real zoom: target
                    Behavior on zoom { NumberAnimation { duration: Style.duration(110); easing.type: Easing.OutCubic } }

                    width: isSep ? panel.snap(root.separatorWidth) : panel.snap(root.iconSize * zoom)
                    height: isSep ? panel.restIcon : panel.snap(root.iconSize * zoom)
                    anchors.bottom: parent.bottom
                    x: 0

                    Rectangle {
                      visible: cell.isSep
                      anchors.centerIn: parent
                      width: root.holo ? 1 / panel.dpr : 1
                      // Under the holographic theme a column rule, the same height as the ends.
                      height: root.holo ? panel.snap(root.dockHeight) - panel.snap(root.tile) * 2 : root.iconSize * 0.7
                      color: root.holo ? Util.alpha(Commons.Color.pick("holo.line", Commons.Color.bar.text), Commons.Color.pickAlpha("holo.line-alpha", 0.4))
                                       : Util.alpha(Commons.Color.bar.text, 0.2)
                    }

                    // Under the holographic theme each icon sits on a keyline, the construction
                    // grid an icon is drawn on: its outer square, a line every tile, the two
                    // diagonals and three circles, all one device pixel and faint, on a frosted square, so the icon,
                    // a tile smaller than its cell all round, reads on top of it.
                    Item {
                      id: keyline
                      visible: root.holo && !cell.isSep
                      y: -cell.hop
                      width: cell.width
                      height: cell.height
                      readonly property real hair: 1 / panel.dpr
                      readonly property color pale: Commons.Color.pick("holo.line", Commons.Color.bar.text)
                      readonly property real step: panel.snap(root.tile * cell.zoom)
                      readonly property int lines: Math.max(0, Math.round(width / Math.max(1, step)) - 1)
                      // A thin dark wash inside the square, just opaque enough (the layer rule's
                      // ignore_alpha is 0.2) for the compositor to frost what is behind the icon.
                      Rectangle {
                        anchors.fill: parent
                        color: Util.alpha(Commons.Color.pick("holo.ink", "#0B161D"), 0.3)
                        border.width: keyline.hair
                        border.color: Util.alpha(keyline.pale, 0.4)
                      }
                      Repeater {
                        model: keyline.lines * 2
                        Rectangle {
                          required property int index
                          readonly property bool across: index % 2 === 0
                          readonly property real at: panel.snap((Math.floor(index / 2) + 1) * keyline.width / (keyline.lines + 1))
                          x: across ? 0 : at
                          y: across ? at : 0
                          width: across ? keyline.width : keyline.hair
                          height: across ? keyline.hair : keyline.height
                          color: Util.alpha(keyline.pale, 0.1)
                        }
                      }
                      Shape {
                        anchors.fill: parent
                        preferredRendererType: Shape.CurveRenderer
                        readonly property real w: keyline.width
                        readonly property real c: w / 2
                        ShapePath {
                          strokeWidth: keyline.hair
                          strokeColor: Util.alpha(keyline.pale, 0.16)
                          fillColor: "transparent"
                          startX: 0; startY: 0
                          PathLine { x: keyline.width; y: keyline.height }
                          PathMove { x: keyline.width; y: 0 }
                          PathLine { x: 0; y: keyline.height }
                          PathAngleArc { centerX: keyline.width / 2; centerY: keyline.height / 2; radiusX: keyline.width * 0.42; radiusY: radiusX; startAngle: 0; sweepAngle: 360; moveToStart: true }
                          PathAngleArc { centerX: keyline.width / 2; centerY: keyline.height / 2; radiusX: keyline.width * 0.26; radiusY: radiusX; startAngle: 0; sweepAngle: 360; moveToStart: true }
                          PathAngleArc { centerX: keyline.width / 2; centerY: keyline.height / 2; radiusX: keyline.width * 0.1; radiusY: radiusX; startAngle: 0; sweepAngle: 360; moveToStart: true }
                        }
                      }
                    }

                    // Hover where magnification is off and nothing else would answer: the
                    // cursor the panels' rows use, around the icon. No scale, so no relayout
                    // and no re-raster. It stays on the icon a context menu belongs to.
                    Rectangle {
                      id: hoverCue
                      readonly property string ink: Commons.Color.pick("controls.hover-cursor-color", Commons.Color.accent)
                      readonly property bool wanted: root.holo && !cell.isSep && !slot.leaving && root.magnify <= 1
                        && (panel.menuKey !== "" ? panel.menuKey === cell.key : mouse.containsMouse && panel.dragUid < 0)
                      anchors.fill: icon
                      anchors.margins: -panel.snap(root.tile / 2)    // on the state frame
                      visible: opacity > 0
                      opacity: wanted ? 1 : 0
                      color: Util.alpha(ink, Commons.Color.pickAlpha("controls.hover-cursor-fill-alpha", 0.1))
                      readonly property color edge: mouse.pressed ? ink : Util.alpha(ink, Commons.Color.pickAlpha("controls.hover-cursor-border-alpha", 0.6))
                      // A bracket a tile long at each corner, one device pixel thick, which a
                      // border can't be at a fractional scale.
                      Repeater {
                        model: 8
                        Rectangle {
                          required property int index
                          readonly property bool across: index % 2 === 0
                          readonly property bool atRight: (index >> 1) % 2 === 1
                          readonly property bool low: index >= 4
                          readonly property real len: panel.snap(root.tile)
                          readonly property real hair: 1 / panel.dpr
                          width: across ? len : hair
                          height: across ? hair : len
                          x: atRight ? hoverCue.width - width : 0
                          y: low ? hoverCue.height - height : 0
                          color: hoverCue.edge
                        }
                      }
                      Behavior on opacity {
                        NumberAnimation {
                          duration: Style.duration(160)
                          easing.type: Easing.BezierSpline
                          easing.bezierCurve: Style.easeOut
                        }
                      }
                    }

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
                      opacity: (mouse.pressed && !cell.dragged) || (cell.launching && Style.reduceMotion && !root.holo) ? 0.7 : 1
                      readonly property string src: cell.isSep ? "" : root.iconFor(cell.key)
                      readonly property bool big: cell.zoom > 1.01
                      // Under the holographic theme the icon keeps a tile clear of its keyline.
                      readonly property real inset: root.holo ? panel.snap(root.tile * cell.zoom) : 0

                      Image {
                        anchors.fill: parent
                        anchors.margins: icon.inset
                        visible: !icon.big || bigImg.status !== Image.Ready
                        source: icon.src
                        sourceSize.width: Math.round((panel.restIcon - (root.holo ? panel.snap(root.tile) * 2 : 0)) * panel.dpr)
                        sourceSize.height: Math.round((panel.restIcon - (root.holo ? panel.snap(root.tile) * 2 : 0)) * panel.dpr)
                        fillMode: Image.PreserveAspectFit
                        // Must stay async: a synchronous image://icon load
                        // crashes the whole shell inside QIcon::pixmap.
                        asynchronous: true
                        smooth: true
                      }
                      Image {
                        id: bigImg
                        anchors.fill: parent
                        anchors.margins: icon.inset
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

                    // Launch feedback until a window shows up, or for the same 1.86 s either
                    // way: the icon hops, or under the holographic theme its mark pulses. With
                    // reduced motion nothing moves, and the mark or a dimmed icon holds instead.
                    property bool launching: false
                    property real hop: 0
                    SequentialAnimation {
                      id: bounce
                      loops: 3
                      NumberAnimation { target: cell; property: "hop"; to: root.iconSize * 0.3; duration: 280; easing.type: Easing.OutQuad }
                      NumberAnimation { target: cell; property: "hop"; to: 0; duration: 340; easing.type: Easing.OutBounce }
                    }
                    SequentialAnimation {
                      id: tickPulse
                      loops: Animation.Infinite
                      NumberAnimation { target: ticks; property: "opacity"; to: 0.35; duration: 310; easing.type: Easing.OutQuad }
                      NumberAnimation { target: ticks; property: "opacity"; to: 1; duration: 310; easing.type: Easing.OutQuad }
                    }
                    Timer { id: launchEnd; interval: 1860; onTriggered: cell.endLaunch() }
                    function startLaunch() {
                      cell.launching = true
                      launchEnd.restart()
                      // Both animations stay out of reduced motion by this guard.
                      if (Style.reduceMotion) return
                      if (root.holo) tickPulse.restart()
                      else bounce.restart()
                    }
                    function endLaunch() {
                      cell.launching = false
                      launchEnd.stop()
                      bounce.stop()
                      tickPulse.stop()
                      cell.hop = 0
                      ticks.opacity = 1
                    }
                    Connections {
                      target: root
                      function onLaunched(k) { if (k === cell.key && !cell.isSep) cell.startLaunch() }
                    }
                    onWinsChanged: if (wins.length && cell.launching) cell.endLaunch()

                    // A dot per window. Under the holographic theme instead the marks the desktop
                    // puts on a window: a hairline the icon's width, one tile below it, and on it
                    // a small square per window (at most three), centred on the line. The square
                    // is the accent for the focused window, pale for a running one and dim for a
                    // minimized one. Placed by hand to land on device pixels.
                    Row {
                      id: dots
                      readonly property real gap: Math.max(2, (root.dockHeight - root.padding - root.iconSize - 4) / 2 - 1)
                      visible: !cell.isSep && !root.holo
                      anchors.horizontalCenter: parent.horizontalCenter
                      anchors.top: parent.bottom
                      anchors.topMargin: gap
                      spacing: 3
                      Repeater {
                        model: root.holo ? 0 : Math.min(3, cell.wins.length)
                        Rectangle {
                          width: 4
                          height: 4
                          radius: 2
                          color: cell.isActive ? Commons.Color.accent : Util.alpha(Commons.Color.bar.text, 0.6)
                        }
                      }
                    }
                    // Under the holographic theme, a frame of four corner brackets round the
                    // icon while the app has windows, and nothing while it has none. Its colour
                    // is the app's state: the accent with the focused window, pale while any is
                    // open, faint when every one is minimized. One device pixel, a tile long.
                    Item {
                      id: ticks
                      readonly property string state: cell.tickStates.indexOf("f") >= 0 ? "f"
                        : cell.tickStates.indexOf("r") >= 0 ? "r"
                        : cell.tickStates.length > 0 ? "m" : (cell.launching ? "r" : "")
                      readonly property real hair: 1 / panel.dpr
                      readonly property real arm: panel.snap(root.tile)
                      // Half a tile out from the icon, so neighbouring frames keep a tile between them.
                      readonly property real out: panel.snap(root.tile / 2)
                      readonly property color pale: Commons.Color.pick("holo.line", Commons.Color.bar.text)
                      readonly property color ink: state === "f" ? Commons.Color.accent
                        : state === "r" ? Util.alpha(pale, 0.7) : Util.alpha(pale, 0.3)
                      visible: root.holo && !cell.isSep && state !== ""
                      x: -out
                      y: -out
                      width: cell.width + out * 2
                      height: cell.height + out * 2
                      Repeater {
                        model: 8
                        Rectangle {
                          required property int index
                          readonly property bool across: index % 2 === 0
                          readonly property bool atRight: (index >> 1) % 2 === 1
                          readonly property bool low: index >= 4
                          width: across ? ticks.arm : ticks.hair
                          height: across ? ticks.hair : ticks.arm
                          x: atRight ? ticks.width - width : 0
                          y: low ? ticks.height - height : 0
                          color: ticks.ink
                          Behavior on color { ColorAnimation { duration: Style.duration(160) } }
                        }
                      }
                    }

                    Rectangle {
                      id: tip
                      readonly property bool removing: cell.dragged && panel.removing
                      // The window list stands in for the name once the app has windows.
                      readonly property bool listed: panel.peeks(cell)
                      visible: removing || (!cell.isSep && mouse.containsMouse && panel.menuKey === "" && !tip.listed && !mouse.pressed && panel.dragUid < 0)
                      anchors.horizontalCenter: parent.horizontalCenter
                      anchors.bottom: icon.top
                      // Under the holographic theme, clear of the panel's top edge and its marks.
                      anchors.bottomMargin: root.holo ? panel.snap(root.padding + root.tile) : 8
                      width: root.holo ? Math.ceil((tipText.implicitWidth + root.tile * 2) / (root.tile * 2)) * root.tile * 2 : tipText.implicitWidth + 28
                      height: root.holo ? root.tile * 4 : tipText.implicitHeight + 18
                      radius: root.holo ? 0 : Math.min(12, Style.cornerRadius)
                      color: root.holo ? Util.alpha(Commons.Color.pick("holo.ink", "#0B161D"), 0.85) : Commons.Color.menu.background
                      border.width: root.holo ? 0 : 1
                      // The theme's plate is pale, and its own border pale on it: use the ink,
                      // or the plate has no edge over a light window.
                      border.color: root.holo ? Util.alpha(Commons.Color.tooltip.text, 0.6) : Commons.Color.menu.border
                      Text {
                        id: tipText
                        anchors.centerIn: parent
                        text: tip.removing ? "Remove from Dock" : cell.isSep ? "" : root.nameFor(cell.key)
                        textFormat: Text.PlainText
                        color: root.holo ? Commons.Color.pick("holo.line", Commons.Color.tooltip.text) : Commons.Color.menu.text
                        font.family: root.holo ? Style.font.family : Style.font.menuFamily
                        font.pixelSize: root.holo ? Math.max(9, Style.font.body) : Style.font.body
                      }
                      // Under the holographic theme, a bracket at each corner, a tile long. After
                      // the text, which stays this item's first child.
                      Repeater {
                        model: root.holo ? 8 : 0
                        Rectangle {
                          required property int index
                          readonly property bool across: index % 2 === 0
                          readonly property bool atRight: (index >> 1) % 2 === 1
                          readonly property bool low: index >= 4
                          readonly property real len: panel.snap(root.tile)
                          readonly property real hair: 1 / panel.dpr
                          width: across ? len : hair
                          height: across ? hair : len
                          x: atRight ? tip.width - width : 0
                          y: low ? tip.height - height : 0
                          color: Commons.Color.pick("holo.line", Commons.Color.tooltip.text)
                        }
                      }
                    }

                    MouseArea {
                      id: mouse
                      enabled: !cell.isSep && !slot.leaving
                      anchors.fill: parent
                      anchors.margins: -root.spacing / 2
                      // Down to the screen edge, where a thrown pointer lands. Every theme.
                      anchors.bottomMargin: row.y + row.height - panel.height
                      hoverEnabled: true
                      acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                      preventStealing: true
                      // A left press that travels past the drag distance
                      // picks the icon up instead of clicking it.
                      property bool moved: false
                      property point pressAt
                      onPressed: function(ev) {
                        moved = false
                        pressAt = mapToItem(row, ev.x, ev.y)
                      }
                      onPositionChanged: function(ev) {
                        if (!(ev.buttons & Qt.LeftButton) || panel.dragUid >= 0 && !cell.dragged) return
                        var p = mapToItem(row, ev.x, ev.y)
                        if (!moved) {
                          if (Math.hypot(p.x - pressAt.x, p.y - pressAt.y) < Qt.styleHints.startDragDistance) return
                          moved = true
                          panel.startDrag(slot, cell, pressAt)
                        }
                        panel.dragTo(p)
                      }
                      onContainsMouseChanged: containsMouse ? panel.peekEnter(cell) : panel.peekLeave(cell)
                      onReleased: if (moved && cell.dragged) panel.endDrag(false)
                      onCanceled: if (moved && cell.dragged) panel.endDrag(true)
                      onClicked: function(ev) {
                        if (moved) return
                        panel.closePeek()
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
          panel.closePeek()
          panel.menuCell = cell
          panel.menuKey = cell.key
          menu.visible = true
        }

        // -------------------------------------------------------- hover panel
        // Resting on an icon brings up one panel above the dock: the app's windows
        // to pick from, or its name when it has none. No focus grab: it is there
        // while the pointer is on the icon or the panel, and a beat after, long
        // enough to cross the gap between the two.
        //
        // One surface for the whole dock, as wide as it, mapped once. Moving to
        // another icon glides the card along and resizes it while what it lists
        // fades over, rather than closing one popup and opening the next.
        property string peekKey: ""    // the icon it belongs to
        property string peekShown: ""  // whose windows it lists: peekKey, a fade behind
        property real peekX: 0         // the centre of the icon it is over, across this surface
        property real peekNextX: 0     // and of the one it is about to move to
        // The holographic theme keeps its own name plate for an app without windows.
        function peeks(cell) { return root.hoverWindows && !cell.isSep && (cell.wins.length > 0 || !root.holo) }
        function closePeek() { peekOpen.stop(); peekClose.stop(); peek.visible = false }
        function openPeek(cell) {
          if (!cell || !panel.peeks(cell) || panel.menuKey !== "" || panel.dragUid >= 0) return
          // Where it is going. Taken up with what it lists, not before: the card's
          // place and its size then leave together and arrive together.
          panel.peekNextX = cell.mapToItem(panel.contentItem, cell.width / 2, 0).x
          panel.peekKey = cell.key
          if (peek.visible) {
            if (panel.peekShown !== cell.key) peekSwap.restart()
            return
          }
          // Fresh: in place at once, nothing to glide from.
          peekCard.glide = false
          peekSwap.stop()
          peekCol.opacity = 1
          panel.peekShown = cell.key
          panel.peekX = panel.peekNextX
          peek.anchor.rect.x = 0
          peek.anchor.rect.y = dock.mapToItem(panel.contentItem, 0, 0).y - root.hoverGap + peek.spare
          peek.anchor.rect.width = panel.width
          peek.anchor.rect.height = 1
          peek.visible = true
          Qt.callLater(function() { peekCard.glide = true })
        }
        function peekEnter(cell) {
          if (!panel.peeks(cell) || panel.dragUid >= 0) return
          if (panel.peekKey === cell.key) { peekOpen.stop(); peekClose.stop(); return }
          peekOpen.cell = cell
          // Already up: follow the pointer along the dock without the wait.
          peekOpen.interval = peek.visible ? 30 : root.hoverDelay
          peekOpen.restart()
        }
        function peekLeave(cell) {
          if (peekOpen.cell === cell) peekOpen.stop()
          if (peek.visible) peekClose.restart()
        }
        Timer {
          id: peekOpen
          property var cell: null
          onTriggered: {
            if (cell && panel.peeks(cell)) { peekClose.stop(); panel.openPeek(cell) }
            else panel.closePeek()
          }
        }
        Timer { id: peekClose; interval: 260; onTriggered: peek.visible = false }

        // To another icon: what is listed fades out, then in one step changes and the
        // card sets off for its new place and size, and the new list fades in on the
        // way. Place and size share a start, a duration and a curve, so each edge of
        // the card travels straight to where it ends up; started apart, the edges
        // overshot and came back.
        SequentialAnimation {
          id: peekSwap
          NumberAnimation { target: peekCol; property: "opacity"; to: 0; duration: Style.duration(50) }
          ScriptAction {
            script: {
              panel.peekShown = panel.peekKey
              panel.peekX = panel.peekNextX
            }
          }
          NumberAnimation { target: peekCol; property: "opacity"; to: 1; duration: Style.duration(150) }
        }

        PopupWindow {
          id: peek
          anchor.window: panel
          anchor.edges: Edges.Top
          anchor.gravity: Edges.Top
          color: "transparent"
          // Below the card, for it to rise out of as it appears.
          readonly property int spare: 6
          // As tall as the longest list any icon here would bring up, and kept at
          // that: the card changes height inside it. Sized to the card instead, the
          // surface was resized under it at every other icon, and for a frame the
          // card stood where the old size put it — a jump up and back.
          readonly property int mostRows: {
            var most = 1
            for (var k in root.windowsByKey) most = Math.max(most, root.windowsByKey[k].length)
            return most
          }
          readonly property real room: mostRows * 32 + (mostRows - 1) * peekCol.spacing + 2 * peekCard.padding
          implicitWidth: panel.width
          implicitHeight: Math.ceil(room) + spare
          // Only the card takes the pointer: the rest of this surface is empty.
          mask: Region {
            x: Math.floor(peekCard.x)
            y: Math.floor(peekCard.y)
            width: Math.ceil(peekCard.width)
            height: Math.ceil(peekCard.height) + peek.spare
          }
          onVisibleChanged: {
            if (visible) { peekCard.shown = 0; peekIn.restart() }
            else { peekSwap.stop(); panel.peekKey = ""; panel.peekShown = "" }
          }
          readonly property var wins: root.windowsByKey[panel.peekShown] || []

          ParallelAnimation {
            id: peekIn
            NumberAnimation {
              target: peekCard; property: "shown"; from: 0; to: 1; duration: Style.duration(200)
              easing.type: Easing.BezierSpline; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1]
            }
            NumberAnimation {
              target: peekCard; property: "opacity"; from: 0; to: 1; duration: Style.duration(100)
              easing.type: Easing.BezierSpline; easing.bezierCurve: [0.5, 0.5, 0.75, 1, 1, 1]
            }
          }

          BorderSurface {
            id: peekCard
            property real shown: 1
            // Off while it is put in place, so it doesn't fly in from where it last was.
            property bool glide: false
            scale: 0.94 + 0.06 * shown
            transformOrigin: Item.Bottom
            transform: Translate { y: 6 * (1 - peekCard.shown) }
            padding: Math.round(Style.space(6))
            radius: root.holo ? 0 : Math.min(12, Style.cornerRadius)
            color: Commons.Color.menu.background
            borderSpec: Border.surfaceSpec("menu", "border", Commons.Color.menu.border, 1)
            clip: true

            // The size what it lists asks for. Each row's own width is asked, not the
            // column's, which only ever reports the width it was given.
            readonly property real rowsW: {
              var w = 0
              for (var i = 0; i < peekRows.count; i++) {
                var row = peekRows.itemAt(i)
                if (row) w = Math.max(w, row.implicitWidth)
              }
              return w
            }
            readonly property int count: peek.wins.length
            readonly property real wantW: Math.round(count ? Math.max(232, Math.min(380, rowsW + 2 * padding))
                                                           : peekName.implicitWidth + 24 + 2 * padding)
            readonly property real wantH: Math.round((count ? count * 32 + (count - 1) * peekCol.spacing : 28) + 2 * padding)
            // Its left edge at rest, on a whole pixel. The edge is what glides: were the
            // centre to, the edge would follow both it and the width.
            readonly property real wantX: Math.round(Math.max(0, Math.min(peek.width - wantW, panel.peekX - wantW / 2)))
            width: wantW
            height: wantH
            x: wantX
            y: peek.height - peek.spare - height
            Behavior on x { enabled: peekCard.glide; NumberAnimation { duration: Style.duration(240); easing.type: Easing.OutCubic } }
            Behavior on width { enabled: peekCard.glide; NumberAnimation { duration: Style.duration(240); easing.type: Easing.OutCubic } }
            Behavior on height { enabled: peekCard.glide; NumberAnimation { duration: Style.duration(240); easing.type: Easing.OutCubic } }

            HoverHandler {
              onHoveredChanged: {
                if (hovered) peekClose.stop()
                else if (peek.visible) peekClose.restart()
              }
            }

            // Laid out at the size the card is heading for, and clipped by it on the
            // way: rows don't re-elide their titles every frame.
            // Kept in the card's middle on the way, which at rest is its padding:
            // held to the corner, a name sat up in the top left of a card still
            // shrinking round it.
            Column {
              id: peekCol
              x: (peekCard.width - width) / 2
              y: (peekCard.height - (peekCard.wantH - 2 * peekCard.padding)) / 2
              width: peekCard.wantW - 2 * peekCard.padding
              spacing: 2
              // No windows: the app's name, where its windows would be listed.
              Item {
                visible: peekCard.count === 0
                width: parent.width
                height: visible ? 28 : 0
                Text {
                  id: peekName
                  anchors.centerIn: parent
                  text: panel.peekShown ? root.nameFor(panel.peekShown) : ""
                  textFormat: Text.PlainText
                  color: Commons.Color.menu.text
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.body
                }
              }
              Repeater {
                id: peekRows
                model: peek.wins
                MenuRow {
                  required property var modelData
                  label: (modelData.tl ? modelData.tl.title : "") || modelData.class
                  current: modelData.address === root.activeAddress
                  badge: root.isMinimized(modelData) ? "minimized"
                       : modelData.workspace && modelData.workspace.id > 0 ? String(modelData.workspace.name) : ""
                  // Act, then close: closing empties the list, and this row with it,
                  // after which nothing here can be named any more.
                  onTriggered: { root.goToWindow(modelData); panel.closePeek() }
                }
              }
            }
          }
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
              target: card; property: "shown"; from: 0; to: 1; duration: Style.duration(270)
              easing.type: Easing.BezierSpline; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1]
            }
            NumberAnimation {
              target: card; property: "opacity"; from: 0; to: 1; duration: Style.duration(115)
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
            radius: root.holo ? 0 : Math.min(12, Style.cornerRadius)
            color: Commons.Color.menu.background
            borderSpec: Border.surfaceSpec("menu", "border", Commons.Color.menu.border, 1)

            // Under the holographic theme, the dock's own frame: a hairline all round and a
            // bracket a tile long at each corner, as on the icon it belongs to.
            Item {
              id: cardFrame
              visible: root.holo
              anchors.fill: parent
              z: 1
              readonly property real hair: 1 / (card.QsWindow.window ? card.QsWindow.window.devicePixelRatio : 1)
              readonly property color pale: Commons.Color.pick("holo.line", Commons.Color.menu.text)
              readonly property color rule: Util.alpha(pale, Commons.Color.pickAlpha("holo.line-alpha", 0.44))
              Rectangle { width: parent.width; height: cardFrame.hair; color: cardFrame.rule }
              Rectangle { y: parent.height - height; width: parent.width; height: cardFrame.hair; color: cardFrame.rule }
              Rectangle { width: cardFrame.hair; height: parent.height; color: cardFrame.rule }
              Rectangle { x: parent.width - width; width: cardFrame.hair; height: parent.height; color: cardFrame.rule }
              Repeater {
                model: 8
                Rectangle {
                  required property int index
                  readonly property bool across: index % 2 === 0
                  readonly property bool atRight: (index >> 1) % 2 === 1
                  readonly property bool low: index >= 4
                  width: across ? root.tile * 2 : cardFrame.hair * 2
                  height: across ? cardFrame.hair * 2 : root.tile * 2
                  x: atRight ? cardFrame.width - width : 0
                  y: low ? cardFrame.height - height : 0
                  color: cardFrame.pale
                }
              }
            }

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
                      textFormat: Text.PlainText
                      color: Commons.Color.menu.text
                      font.family: Style.font.menuFamily
                      font.pixelSize: Style.font.subtitle
                      font.weight: Font.DemiBold
                    }
                    Text {
                      text: menu.wins.length === 0 ? "Not running"
                          : menu.wins.length === 1 ? "1 window" : menu.wins.length + " windows"
                      textFormat: Text.PlainText
                      color: Commons.Color.pick("holo.text-dim", Util.alpha(Commons.Color.menu.text, 0.5))
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
                  badge: root.isMinimized(modelData) ? "minimized"
                       : modelData.workspace && modelData.workspace.id > 0 ? String(modelData.workspace.name) : ""
                  // Act, then close: closing empties the list, and this row with it,
                  // after which nothing here can be named any more.
                  onTriggered: {
                    if (root.isMinimized(modelData)) root.restoreWindow(modelData)
                    else root.focusWindow(modelData.address)
                    menu.visible = false
                  }
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
      color: Util.alpha(Commons.Color.menu.text, 0.1)
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
    readonly property color ink: danger ? Commons.Color.urgent : (hot ? Commons.Color.menu.selectedText : Commons.Color.menu.text)
    width: parent ? parent.width : 200
    implicitWidth: 36 + mlabel.implicitWidth + (badge ? mbadge.width + 16 : 12)
    height: visible ? 32 : 0
    radius: root.holo ? 0 : Math.min(8, Style.cornerRadius)
    color: hot ? (danger ? Util.alpha(Commons.Color.urgent, 0.14) : Commons.Color.menu.selectedBackground) : "transparent"
    Behavior on color { ColorAnimation { duration: Style.duration(90) } }

    Item {
      id: lead
      x: 6
      width: 22
      height: parent.height
      Text {
        anchors.centerIn: parent
        visible: mrow.glyph !== ""
        text: mrow.glyph
        textFormat: Text.PlainText
        color: mrow.ink
        font.family: Style.fontFamily
        font.pixelSize: Style.font.heading
      }
      Rectangle {
        anchors.centerIn: parent
        visible: mrow.glyph === ""
        width: 6; height: 6; radius: root.holo ? 0 : 3
        color: mrow.current ? Commons.Color.accent : Util.alpha(Commons.Color.menu.text, 0.25)
      }
    }
    Text {
      id: mlabel
      anchors.verticalCenter: parent.verticalCenter
      x: 36
      width: parent.width - x - (mrow.badge ? mbadge.width + 16 : 10)
      elide: Text.ElideRight
      text: mrow.label
      textFormat: Text.PlainText
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
      radius: root.holo ? 0 : Math.min(5, Style.cornerRadius)
      color: Util.alpha(Commons.Color.menu.text, mrow.hot ? 0.14 : 0.08)
      Text {
        id: btext
        anchors.centerIn: parent
        text: mrow.badge
        textFormat: Text.PlainText
        color: Util.alpha(Commons.Color.menu.text, 0.7)
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
