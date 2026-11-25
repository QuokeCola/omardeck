import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../app/Shortcuts.js" as Shortcuts
import "../../notifications" as Notifications
import "../../look" as Looks

// Aerial's settings, from a button on the bar.
//
// Four switches that take effect at once — frosted glass, liquid glass,
// swiping between desktops, and every screen switching desktop together — and
// Aerial's keyboard shortcuts, which are Hyprland bindings and so live in the
// user's Omarchy bindings file, in a section of their own (see app/Shortcuts.js).
// Shortcuts are edited here and only written on Save.
Panel {
  id: root
  moduleName: "quokecola.omardeck"
  ipcTarget: "quokecola.omardeck.overview"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property var service: root.bar && root.bar.shell && typeof root.bar.shell.serviceFor === "function"
                                 ? root.bar.shell.serviceFor(root.moduleName)?.overview ?? null : null

  // No overlay out here on the bar, so its own copy of the look.
  Looks.ActiveLook { id: look }

  // ------------------------------------------------------------- switches

  readonly property bool frost: root.setting("frost", true) !== false
  readonly property bool deskSwipe: root.setting("deskSwipe", true) !== false
  readonly property bool syncScreens: root.setting("syncScreens", false) === true
  // Under frosted glass: the overview's cards and these panels only bend what the
  // frost blurs, so without it the glass would be on in some places and not others.
  // What was chosen is kept, and comes back with the frost.
  readonly property bool liquidGlassChosen: root.setting("liquidGlass", false) === true
  readonly property bool liquidGlass: root.frost && root.liquidGlassChosen

  function setSetting(key, value) {
    const next = Object.assign({}, root.settings || {})
    next[key] = value
    root.settings = next
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, next)
  }

  // The service owns the behaviour; this only tells it what the user chose,
  // whenever either side comes or goes.
  function pushSettings() {
    if (!root.service) return
    root.service.frost = root.frost
    root.service.deskSwipe = root.deskSwipe
    root.service.syncScreens = root.syncScreens
    root.service.liquidGlass = root.liquidGlass
  }
  onServiceChanged: root.pushSettings()
  onFrostChanged: { root.pushSettings(); root.syncSystemGlass() }

  // ------------------------------------------------------- the system's glass
  // Frosted glass is one setting with Omarchy's own Window Opacity (Appearance >
  // Windows in its menu, omarchy-hyprland-window-transparency): "glassy" there is
  // the frost here. Glassy is what blurs behind see-through windows and gives the
  // terminals their see-through background, so the switch here turns all of it on
  // and off together, and a change made in Omarchy's menu shows here.
  //
  // Omarchy's side is read at the start and after every Hyprland reload, which
  // its command ends with, and is the one that is right when the two differ: it
  // is what is on screen. Turning the frost off goes back to whichever of
  // Omarchy's other two (opaque, transparent) was last seen, kept as `frostOff`.
  // Without that command (an older Omarchy) none of this happens.
  readonly property string glassCommand: "omarchy-hyprland-window-transparency"
  // What Omarchy last said: "opaque", "transparent", "glassy", or "" for not known.
  property string systemGlass: ""
  Process {
    id: readGlass
    command: [root.glassCommand]
    stdout: StdioCollector { onStreamFinished: root.tookSystemGlass(String(text || "").trim()) }
  }
  Process {
    id: writeGlass
    onExited: readGlass.running = true
  }
  function readSystemGlass() { if (!readGlass.running && !writeGlass.running) readGlass.running = true }
  function tookSystemGlass(mode) {
    if (!root.settled || !/^(opaque|transparent|glassy)$/.test(mode)) return
    root.systemGlass = mode
    if (mode !== "glassy" && root.setting("frostOff", "transparent") !== mode) root.setSetting("frostOff", mode)
    if ((mode === "glassy") !== root.frost) root.setSetting("frost", mode === "glassy")
  }
  function syncSystemGlass() {
    if (root.systemGlass === "" || writeGlass.running) return
    if (root.frost === (root.systemGlass === "glassy")) return
    const off = root.setting("frostOff", "transparent")
    writeGlass.command = [root.glassCommand, root.frost ? "glassy" : (off === "opaque" ? "opaque" : "transparent")]
    root.systemGlass = ""
    writeGlass.running = true
  }
  // Not before the bar has handed over this widget's settings: saving one from
  // an empty set would write the others away.
  readonly property bool settled: root.bar !== null && root.settings !== null && root.settings !== undefined && root.moduleName !== ""
  Timer { interval: 1500; running: root.settled; onTriggered: root.readSystemGlass() }
  readonly property int reloads: root.service ? root.service.reloads : 0
  onReloadsChanged: root.readSystemGlass()
  onDeskSwipeChanged: root.pushSettings()
  onSyncScreensChanged: root.pushSettings()
  onLiquidGlassChanged: root.pushSettings()

  // ------------------------------------------------------------ shortcuts

  readonly property string bindingsPath: {
    const config = String(Quickshell.env("XDG_CONFIG_HOME") || "")
    const home = String(Quickshell.env("HOME") || "")
    return (config !== "" ? config : home + "/.config") + "/hypr/bindings.lua"
  }

  // What the file says, and what is being edited.
  property var saved: ({})
  property var draft: ({})
  readonly property bool dirty: JSON.stringify(root.draft) !== JSON.stringify(root.saved)
  // The action a key combination is being recorded for, or "".
  property string recordingId: ""
  // Every binding Hyprland has, for spotting clashes.
  property var binds: []
  property string status: ""

  FileView {
    id: bindingsFile
    path: root.bindingsPath
    watchChanges: true
    printErrors: false
    onFileChanged: bindingsFile.reload()
    onLoaded: {
      root.bindingsKnown = true
      root.readBindings()
    }
    onLoadFailed: (error) => root.bindingsKnown = error === FileViewError.FileNotFound
  }

  // Whether the file's contents are known: it was read, or it is not there. Until
  // then text() is empty, and a save from that would replace the whole file.
  property bool bindingsKnown: false

  function readBindings() {
    let text = ""
    try { text = bindingsFile.text() } catch (e) { text = "" }
    const found = Shortcuts.read(text || "")
    const wasClean = !root.dirty
    root.saved = found
    if (wasClean) root.draft = Object.assign({}, found)
  }

  Process {
    id: bindsQuery
    command: ["/usr/bin/hyprctl", "binds", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.binds = JSON.parse(text) } catch (e) { root.binds = [] }
      }
    }
  }

  function refreshBinds() { if (!bindsQuery.running) bindsQuery.running = true }

  /** What else a draft shortcut would collide with: another Aerial action,
      or something already bound in Hyprland. */
  function clashesFor(actionId) {
    const combo = root.draft[actionId]
    if (!combo) return []
    const out = []
    for (const act of Shortcuts.ACTIONS) {
      if (act.id !== actionId && root.draft[act.id] && root.draft[act.id].toLowerCase() === combo.toLowerCase())
        out.push({ description: act.label, ours: true })
    }
    // What Hyprland has on it now — unless that is this very binding, saved.
    if (root.saved[actionId] !== combo) {
      for (const c of Shortcuts.conflicts(root.binds, combo)) out.push({ description: c.description, ours: false })
    }
    return out
  }

  readonly property bool blocked: {
    for (const act of Shortcuts.ACTIONS) {
      if (root.clashesFor(act.id).some(c => c.ours)) return true
    }
    return false
  }

  function startRecording(actionId) {
    root.recordingId = actionId
    root.status = ""
    if (root.service) root.service.setRecording(true)
    recorder.forceActiveFocus()
  }

  function stopRecording() {
    if (root.recordingId === "") return
    root.recordingId = ""
    if (root.service && root.service.recording) root.service.setRecording(false)
    keyCatcher.forceActiveFocus()
  }

  function setDraft(actionId, combo) {
    const next = Object.assign({}, root.draft)
    if (combo) next[actionId] = combo
    else delete next[actionId]
    root.draft = next
  }

  function save() {
    if (root.blocked) return
    let text = null
    if (root.bindingsKnown) {
      try { text = bindingsFile.text() || "" } catch (e) { text = null }
    }
    if (text === null) {
      root.status = "Not saved: the bindings file could not be read. Nothing was changed."
      return
    }
    const written = Shortcuts.write(text, root.draft)
    if (written === null) {
      root.status = Shortcuts.problem(text)
      return
    }
    bindingsFile.setText(written)
    root.saved = Object.assign({}, root.draft)
    root.status = "Saved — Hyprland picks it up by itself."
    // Hyprland reloads the file on its own; ask for the bindings again once
    // it has, so the warnings reflect it.
    rebindsLater.restart()
  }

  Timer {
    id: rebindsLater
    interval: 700
    onTriggered: root.refreshBinds()
  }

  function discard() {
    root.stopRecording()
    root.draft = Object.assign({}, root.saved)
    root.status = ""
  }

  onOpenedChanged: {
    if (root.opened) {
      root.refreshBinds()
      bindingsFile.reload()
    } else {
      root.stopRecording()
      root.cursor = ""
    }
  }

  // The keyboard came back to Hyprland some other way (Escape does, in the
  // compositor, and the service gives up after a while): stop listening.
  Connections {
    target: root.service
    function onRecordingChanged() { if (!root.service.recording && root.recordingId !== "") root.stopRecording() }
  }

  // --------------------------------------------------------------- keyboard

  // The control the arrow keys have reached, or "" until one is pressed. Tab stays the
  // bar's, for the next panel, so this is a cursor rather than focus: the same one the
  // stock panels have.
  property string cursor: ""
  // Top to bottom. Only what can be used: Save and Discard leave as they turn off.
  readonly property var cursorOrder: {
    const order = root.frost ? ["frost", "liquidGlass", "deskSwipe", "syncScreens"]
                             : ["frost", "deskSwipe", "syncScreens"]
    for (const act of Shortcuts.ACTIONS) order.push("shortcut:" + act.id)
    if (root.dirty) order.push("discard")
    if (root.dirty && !root.blocked && root.recordingId === "") order.push("save")
    return order
  }
  onCursorOrderChanged: {
    if (root.cursor !== "" && root.cursorOrder.indexOf(root.cursor) < 0)
      root.cursor = root.cursorOrder[root.cursorOrder.length - 1]
  }

  function moveCursor(step) {
    const order = root.cursorOrder
    const at = order.indexOf(root.cursor)
    if (at < 0) root.cursor = order[step > 0 ? 0 : order.length - 1]
    else root.cursor = order[Math.max(0, Math.min(order.length - 1, at + step))]
  }

  function cursorShortcut() {
    return root.cursor.indexOf("shortcut:") === 0 ? root.cursor.slice("shortcut:".length) : ""
  }

  function activateCursor() {
    const shortcut = root.cursorShortcut()
    if (shortcut !== "") root.startRecording(shortcut)
    else if (root.cursor === "discard") root.discard()
    else if (root.cursor === "save") root.save()
    else if (root.cursor !== "") root.setSetting(root.cursor, !root[root.cursor])
  }

  // ----------------------------------------------------------------- button

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰕰"
    tooltipText: "Overview"
    onPressed: function(b) {
      if (b === Qt.RightButton) {
        if (root.service) root.service.toggle()
      } else {
        root.toggle()
      }
    }
  }

  // ------------------------------------------------------------------ panel

  // The notification center's popup, dropping out of the bar the way its
  // sheet slides in from the edge, and see-through with frosted glass on.
  Notifications.NotificationPopup {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    slideIn: true
    slideFrom: "top"
    surfaceColor: Qt.alpha(Commons.Color.popups.background, root.frost ? look.panelAlpha(0.72) : 1)
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While recording, every key is the shortcut being recorded.
      blocked: root.recordingId !== ""
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { root.moveCursor(dx + dy) }
      onActivateRequested: root.activateCursor()
      onDeleteRequested: if (root.cursorShortcut() !== "") root.setDraft(root.cursorShortcut(), "")

      // Listens for the combination being recorded.
      Item {
        id: recorder
        focus: root.recordingId !== ""
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          event.accepted = true
          if (root.recordingId === "") return
          if (Shortcuts.isModifierKey(event.key)) return   // wait for the key itself
          if (event.key === Qt.Key_Escape && !(event.modifiers & (Qt.MetaModifier | Qt.ControlModifier | Qt.AltModifier | Qt.ShiftModifier))) {
            root.stopRecording()
            return
          }
          const name = Shortcuts.keyName(event.key)
          if (name === "") {
            root.status = "That key cannot be a shortcut."
            return
          }
          const mask = Shortcuts.maskOf(event.modifiers)
          if (mask === 0) {
            root.status = "Hold at least one modifier — Super, Ctrl, Alt or Shift."
            return
          }
          root.setDraft(root.recordingId, Shortcuts.format(mask, name))
          root.status = ""
          root.stopRecording()
        }
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- title
        Row {
          spacing: Style.space(12)

          Text {
            textFormat: Text.PlainText
            text: "󰕰"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: "Overview"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              text: "Window overview and desktop swipes"
              color: look.dim(root.bar.foreground)
              opacity: look.quiet(0.6)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        Item { width: 1; height: look.sectionGap; visible: look.sectionGap > 0 }

        PanelSeparator { width: parent.width; foreground: root.bar.foreground }

        // ---------- switches
        PanelSectionHeader {
          text: "BEHAVIOUR"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          fontSize: look.primaryText(Style.font.caption)
          font.letterSpacing: look.headerTracking
        }

        Toggle {
          width: parent.width
          label: "Frosted glass"
          description: "Glassy windows, as in Omarchy's Appearance menu: blur behind see-through windows and terminals, this panel and the notification sheet. Uses more GPU."
          checked: root.frost
          hasCursor: root.cursor === "frost"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          onHovered: function(isHovered) { if (isHovered) root.cursor = "" }
          onClicked: root.setSetting("frost", !root.frost)
        }

        Toggle {
          // A step in, under the switch it depends on, and out of reach without it.
          x: Style.spacing.rowPaddingX * 2
          width: parent.width - x
          enabled: root.frost
          opacity: root.frost ? 1 : 0.45
          label: "Liquid glass"
          readonly property string glassState: root.service ? root.service.glassState : "off"
          description: !root.frost ? "Needs frosted glass."
                     : glassState === "working" ? "Starting… the first time, and after Hyprland updates, it is built for your Hyprland, which takes a few seconds."
                     : glassState === "error" ? root.service.glassError
                     : "Whatever Hyprland blurs bends like glass at its edges: see-through windows, the bar, the dock, these panels and the overview's cards. Turns Hyprland's blur down while on."
          checked: root.liquidGlass
          hasCursor: root.cursor === "liquidGlass"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          onHovered: function(isHovered) { if (isHovered) root.cursor = "" }
          onClicked: root.setSetting("liquidGlass", !root.liquidGlassChosen)
        }

        Toggle {
          width: parent.width
          label: "Swipe between desktops"
          description: "Three fingers sideways on the desktop slide to the next one."
          checked: root.deskSwipe
          hasCursor: root.cursor === "deskSwipe"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          onHovered: function(isHovered) { if (isHovered) root.cursor = "" }
          onClicked: root.setSetting("deskSwipe", !root.deskSwipe)
        }

        Toggle {
          width: parent.width
          label: "All screens together"
          description: "Every screen switches desktop at once. Workspaces come in blocks of ten a screen: 1-10 on the laptop, then 11-20, 21-30 on the others from left to right."
          checked: root.syncScreens
          hasCursor: root.cursor === "syncScreens"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          onHovered: function(isHovered) { if (isHovered) root.cursor = "" }
          onClicked: root.setSetting("syncScreens", !root.syncScreens)
        }

        Item { width: 1; height: look.sectionGap; visible: look.sectionGap > 0 }

        PanelSeparator { width: parent.width; foreground: root.bar.foreground }

        // ---------- shortcuts
        PanelSectionHeader {
          text: "SHORTCUTS"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          fontSize: look.primaryText(Style.font.caption)
          font.letterSpacing: look.headerTracking
        }

        Repeater {
          model: Shortcuts.ACTIONS

          delegate: Column {
            id: row
            required property var modelData
            readonly property string combo: root.draft[row.modelData.id] || ""
            readonly property bool listening: root.recordingId === row.modelData.id
            readonly property var clashes: root.clashesFor(row.modelData.id)
            readonly property bool hasCursor: root.cursor === "shortcut:" + row.modelData.id
            width: parent.width
            spacing: Style.space(4)

            Rectangle {
              width: parent.width
              height: Style.spacing.popupRowHeight + Style.space(6)
              radius: Style.cornerRadius
              color: row.listening ? Style.selectedFill
                   : (rowMouse.containsMouse || row.hasCursor ? Style.hoverFill : "transparent")
              border.width: row.listening || row.hasCursor ? 1 : 0
              border.color: Commons.Color.accent

              Text {
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: row.modelData.label
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: clear.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: row.listening ? "Press keys…  (Esc to cancel)"
                      : (row.combo !== "" ? row.combo : "Not set")
                color: row.listening ? Commons.Color.accent
                       : (row.clashes.some(c => c.ours) ? look.alertText(root.bar.urgent)
                          : (row.combo === "" ? look.dim(root.bar.foreground) : root.bar.foreground))
                opacity: row.combo === "" && !row.listening ? look.quiet(0.5) : 1
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.bold: row.combo !== "" && !row.listening
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                anchors.rightMargin: clear.width + Style.space(8)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: if (rowMouse.containsMouse) root.cursor = ""
                onClicked: row.listening ? root.stopRecording() : root.startRecording(row.modelData.id)
              }

              PanelActionButton {
                id: clear
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅖"
                tooltipText: "Clear"
                foreground: root.bar.foreground
                hoverColor: root.bar.urgent
                fontFamily: root.bar.fontFamily
                enabled: row.combo !== ""
                opacity: enabled ? 1 : 0.3
                onClicked: root.setDraft(row.modelData.id, "")
              }
            }

            // What it would collide with.
            Repeater {
              model: row.clashes

              delegate: Text {
                required property var modelData
                textFormat: Text.PlainText
                width: row.width
                leftPadding: Style.space(10)
                wrapMode: Text.WordWrap
                text: modelData.ours
                      ? "Same as " + modelData.description + " — pick another."
                      : "Also " + modelData.description + " — saving takes it over."
                color: modelData.ours ? look.alertText(root.bar.urgent) : look.dim(Qt.darker(root.bar.foreground, 1.15))
                opacity: modelData.ours ? 1 : look.quiet(0.75)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.status !== ""
          wrapMode: Text.WordWrap
          text: root.status
          color: look.dim(root.bar.foreground)
          opacity: look.quiet(0.7)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.WordWrap
          text: "Saved to the Aerial section of " + root.bindingsPath.replace(String(Quickshell.env("HOME") || ""), "~")
          color: look.dim(root.bar.foreground)
          opacity: look.quiet(0.45)
          font.family: root.bar.fontFamily
          font.pixelSize: look.legible(Style.font.caption)
        }

        // ---------- save / discard
        Row {
          anchors.right: parent.right
          spacing: Style.space(8)

          Button {
            text: "Discard"
            enabled: root.dirty
            opacity: enabled ? 1 : 0.4
            hasCursor: root.cursor === "discard"
            bordered: hasCursor
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            onHovered: function(isHovered) { if (isHovered) root.cursor = "" }
            onClicked: root.discard()
          }

          Button {
            text: "Save"
            enabled: root.dirty && !root.blocked && root.recordingId === ""
            opacity: enabled ? 1 : 0.4
            foreground: root.bar.foreground
            accent: Commons.Color.accent
            selected: enabled
            hasCursor: root.cursor === "save"
            bordered: hasCursor
            fontFamily: root.bar.fontFamily
            onHovered: function(isHovered) { if (isHovered) root.cursor = "" }
            onClicked: root.save()
          }
        }
      }
    }
  }
}
