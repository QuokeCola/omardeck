import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Widgets
import qs.Commons

// Bottom dock: pinned apps, then running apps that aren't pinned. Window state
// comes from `hyprctl -j` (refreshed on Hyprland events), so window geometry is
// known and the dock can hide only when a window actually overlaps it.
//
// Config: ~/.config/omarchy/dock.json (watched; the dock rewrites `pinned`
// when you pin/unpin from the right-click menu).
//   pinned    desktop ids, without ".desktop"
//   iconSize  px at rest
//   magnify   hovered icon scale (1 = off)
//   autohide  "smart" (hide when a window overlaps), "always", "never"
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
  readonly property int iconSize: Math.max(24, Number(config.iconSize) || 44)
  readonly property real magnify: Math.max(1, Math.min(2, Number(config.magnify) || 1.45))
  readonly property string autohide: ["smart", "always", "never"].indexOf(config.autohide) >= 0 ? config.autohide : "smart"

  readonly property int spacing: Math.round(iconSize * 0.18)
  readonly property int padding: Math.round(iconSize * 0.2)
  readonly property int dotRow: 7
  readonly property int dockHeight: iconSize + padding + Math.max(padding, dotRow + 3)
  readonly property int edgeGap: Math.max(4, Style.gapsOut * 2)
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
  property var clients: []
  property var monitors: []
  property string activeAddress: ""

  Process {
    id: stateProc
    command: ["bash", "-c", "hyprctl -j clients; echo; echo @@; hyprctl -j monitors; echo; echo @@; hyprctl -j activewindow"]
    stdout: StdioCollector { onStreamFinished: root.parseState(text) }
  }

  function parseState(raw) {
    var parts = String(raw).split("\n@@\n")
    try { root.clients = JSON.parse(parts[0]) } catch (e) {}
    try { root.monitors = JSON.parse(parts[1]) } catch (e) {}
    try { root.activeAddress = String((JSON.parse(parts[2]) || {}).address || "") } catch (e) { root.activeAddress = "" }
    root.rebuild()
  }

  function refresh() { refreshTimer.restart() }
  Timer {
    id: refreshTimer
    interval: 30
    onTriggered: if (!stateProc.running) stateProc.running = true; else root.refresh()
  }
  Component.onCompleted: refresh()

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var n = event.name
      if (n === "openlayer" || n === "closelayer" || n === "activelayout" || n === "windowtitle") {
        if (n === "windowtitle") root.refresh()
        return
      }
      root.refresh()
    }
  }

  // Dragging a floating window emits no event, so poll slowly while one is on
  // a visible workspace.
  property bool floatingVisible: false
  Timer {
    interval: 1200
    repeat: true
    running: root.floatingVisible && root.autohide === "smart"
    onTriggered: root.refresh()
  }

  // ------------------------------------------------------------- app model
  property var idCache: ({})
  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { root.idCache = ({}); root.rebuild() }
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
    if (w && w.length) return w[0].title || w[0].class
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

  function rebuild() {
    var byKey = {}
    var floating = false
    var visibleWs = {}
    for (var m = 0; m < root.monitors.length; m++) {
      var mon = root.monitors[m]
      if (mon.activeWorkspace) visibleWs[mon.activeWorkspace.id] = true
      if (mon.specialWorkspace && mon.specialWorkspace.id) visibleWs[mon.specialWorkspace.id] = true
    }
    for (var i = 0; i < root.clients.length; i++) {
      var c = root.clients[i]
      if (!c.mapped || !c.class) continue
      var key = root.keyForClass(c.class)
      if (!byKey[key]) byKey[key] = []
      byKey[key].push(c)
      if (c.floating && visibleWs[c.workspace.id]) floating = true
    }
    for (var k in byKey) byKey[k].sort(function(a, b) { return a.focusHistoryID - b.focusHistoryID })
    root.floatingVisible = floating
    root.windowsByKey = byKey

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
    var x = root.padding
    for (var i = 0; i < root.items.length; i++) {
      var w = root.items[i].separator ? root.separatorWidth : root.iconSize
      out.push(x + w / 2)
      x += w + (i < root.items.length - 1 ? root.spacing : 0)
    }
    return out
  }
  readonly property real baseWidth: {
    var w = root.padding * 2
    for (var i = 0; i < root.items.length; i++)
      w += (root.items[i].separator ? root.separatorWidth : root.iconSize) + (i ? root.spacing : 0)
    return w
  }

  // ---------------------------------------------------------------- actions
  function hypr(lua) { Quickshell.execDetached(["hyprctl", "dispatch", lua]) }
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
    var idx = -1
    for (var i = 0; i < wins.length; i++) if (wins[i].address === root.activeAddress) idx = i
    if (idx < 0) { root.focusWindow(wins[0].address); return }
    if (wins.length < 2) return
    // Cycle in a stable order (by address) so repeated clicks visit every window.
    var stable = wins.slice().sort(function(a, b) { return a.address < b.address ? -1 : 1 })
    var at = 0
    for (var j = 0; j < stable.length; j++) if (stable[j].address === root.activeAddress) at = j
    root.focusWindow(stable[(at + 1) % stable.length].address)
  }

  function quit(key) {
    var wins = root.windowsByKey[key] || []
    for (var i = 0; i < wins.length; i++) root.closeWindow(wins[i].address)
  }

  // ----------------------------------------------------------------- surface
  Variants {
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
        readonly property bool overlapped: {
          var mon = panel.monitor
          if (!mon) return false
          var ws = mon.activeWorkspace ? mon.activeWorkspace.id : -999
          var sp = mon.specialWorkspace && mon.specialWorkspace.id ? mon.specialWorkspace.id : -999
          var left = modelData.x + (modelData.width - root.baseWidth) / 2
          var right = left + root.baseWidth
          var bottom = modelData.y + modelData.height
          var top = bottom - root.edgeGap - root.dockHeight
          for (var i = 0; i < root.clients.length; i++) {
            var c = root.clients[i]
            if (!c.mapped || c.hidden || c.monitor !== mon.id) continue
            if (c.workspace.id !== ws && c.workspace.id !== sp) continue
            if (c.fullscreen) return true
            if (c.at[0] < right && c.at[0] + c.size[0] > left && c.at[1] < bottom && c.at[1] + c.size[1] > top) return true
          }
          return false
        }

        property bool hovered: false
        property bool lingering: false
        property string menuKey: ""
        readonly property bool wantHidden: root.autohide === "always" || (root.autohide === "smart" && overlapped)
        readonly property bool revealed: !wantHidden || hovered || lingering || menuKey !== ""

        onHoveredChanged: if (!hovered) { lingering = true; lingerTimer.restart() }
        Timer { id: lingerTimer; interval: 350; onTriggered: panel.lingering = false }

        visible: root.items.length > 0
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "omarchy-dock"
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors.bottom: true
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
            property real offset: panel.revealed ? 0 : root.edgeGap + root.dockHeight + 6
            Behavior on offset {
              NumberAnimation {
                duration: panel.revealed ? 280 : 200
                easing.type: panel.revealed ? Easing.OutQuint : Easing.InCubic
              }
            }
            transform: Translate { y: slider.offset }
            opacity: panel.revealed ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: panel.revealed ? 160 : 220 } }

            Rectangle {
              id: dock
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.bottom: parent.bottom
              anchors.bottomMargin: root.edgeGap
              height: root.dockHeight
              width: row.width + root.padding * 2
              radius: Math.min(14, Style.cornerRadius)
              color: Color.bar.background
              border.width: 1
              border.color: Util.alpha(Color.bar.text, 0.12)
            }

            Row {
              id: row
              anchors.horizontalCenter: dock.horizontalCenter
              anchors.bottom: dock.bottom
              anchors.bottomMargin: dock.height - root.padding - root.iconSize
              spacing: root.spacing

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

                  width: isSep ? root.separatorWidth : root.iconSize * zoom
                  height: isSep ? root.iconSize : root.iconSize * zoom
                  anchors.bottom: parent.bottom

                  Rectangle {
                    visible: cell.isSep
                    anchors.centerIn: parent
                    width: 1
                    height: root.iconSize * 0.7
                    color: Util.alpha(Color.bar.text, 0.2)
                  }

                  IconImage {
                    id: icon
                    visible: !cell.isSep
                    width: parent.width
                    height: parent.height
                    y: -cell.hop
                    source: cell.isSep ? "" : root.iconFor(cell.key)
                    asynchronous: true
                    mipmap: true
                    opacity: mouse.pressed ? 0.7 : 1
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
          grabFocus: true
          color: "transparent"
          implicitWidth: card.width
          implicitHeight: card.height
          onVisibleChanged: if (!visible) panel.menuKey = ""

          readonly property var wins: root.windowsByKey[panel.menuKey] || []
          readonly property bool isPinned: root.pinned.indexOf(panel.menuKey) >= 0
          readonly property bool hasEntry: !!root.entryFor(panel.menuKey)

          function run(fn) { menu.visible = false; fn() }

          Rectangle {
            id: card
            width: Math.max(200, Math.min(340, col.implicitWidth + 12))
            height: col.implicitHeight + 12
            radius: Math.min(10, Style.cornerRadius)
            color: Color.menu.background
            border.width: 1
            border.color: Util.alpha(Color.menu.border, 0.25)

            Column {
              id: col
              x: 6
              y: 6
              width: card.width - 12

              Text {
                text: panel.menuKey ? root.nameFor(panel.menuKey) : ""
                color: Util.alpha(Color.menu.text, 0.55)
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                leftPadding: 8
                topPadding: 4
                bottomPadding: 6
              }

              Repeater {
                model: menu.wins
                MenuRow {
                  required property var modelData
                  label: modelData.title || modelData.class
                  marked: modelData.address === root.activeAddress
                  onTriggered: menu.run(function() { root.focusWindow(modelData.address) })
                }
              }
              Rectangle {
                visible: menu.wins.length > 0
                width: parent.width; height: 9; color: "transparent"
                Rectangle { anchors.centerIn: parent; width: parent.width - 12; height: 1; color: Util.alpha(Color.menu.text, 0.12) }
              }
              MenuRow {
                visible: menu.hasEntry || menu.wins.length === 0
                label: menu.wins.length ? "New Window" : "Open"
                onTriggered: { var k = panel.menuKey; menu.run(function() { root.launch(k) }) }
              }
              MenuRow {
                visible: menu.hasEntry
                label: menu.isPinned ? "Unpin from Dock" : "Pin to Dock"
                onTriggered: { var k = panel.menuKey; menu.run(function() { root.togglePin(k) }) }
              }
              MenuRow {
                visible: menu.wins.length > 0
                label: menu.wins.length > 1 ? "Close " + menu.wins.length + " Windows" : "Close"
                danger: true
                onTriggered: { var k = panel.menuKey; menu.run(function() { root.quit(k) }) }
              }
            }
          }
        }
      }
    }
  }

  component MenuRow: Rectangle {
    id: mrow
    property string label: ""
    property bool marked: false
    property bool danger: false
    signal triggered()
    width: parent ? parent.width : 200
    implicitWidth: mlabel.implicitWidth + 40
    height: visible ? 28 : 0
    radius: Math.min(6, Style.cornerRadius)
    color: marea.containsMouse ? Color.menu.selectedBackground : "transparent"
    Rectangle {
      visible: mrow.marked
      width: 4; height: 4; radius: 2
      anchors.verticalCenter: parent.verticalCenter
      x: 8
      color: Color.accent
    }
    Text {
      id: mlabel
      anchors.verticalCenter: parent.verticalCenter
      x: 20
      width: parent.width - 28
      elide: Text.ElideRight
      text: mrow.label
      color: mrow.danger ? Color.urgent : (marea.containsMouse ? Color.menu.selectedText : Color.menu.text)
      font.pixelSize: Style.font.subtitle
    }
    MouseArea {
      id: marea
      anchors.fill: parent
      hoverEnabled: true
      onClicked: mrow.triggered()
    }
  }
}
