import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bar toggle for the liquidglass Hyprland plugin (~/src/hypr-liquid-glass).
// Left click opens a small panel with the switch; right click flips it
// straight from the bar. All Hyprland work goes through glass-ctl.
Panel {
  id: root
  moduleName: "quokecola.liquid-glass"
  ipcTarget: "quokecola.liquid-glass"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property string soPath: String(setting("pluginPath", "~/src/hypr-liquid-glass/liquidglass.so"))
  readonly property string ctl: Qt.resolvedUrl("glass-ctl").toString().replace(/^file:\/\//, "")

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)

  property bool loaded: false
  property bool enabled: false
  property bool busy: false
  property string error: ""

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function setGlass(on) {
    if (busy) return
    busy = true
    error = ""
    // Optimistic: throw the switch now, statusProc corrects it afterwards.
    enabled = on
    actionProc.command = on ? [ctl, "on", soPath] : [ctl, "off"]
    actionProc.running = true
  }

  function toggleGlass() { setGlass(!enabled) }

  Component.onCompleted: refresh()
  onOpenedChanged: if (opened) refresh()

  Process {
    id: statusProc
    command: [root.ctl, "status"]
    stdout: StdioCollector {
      onStreamFinished: {
        root.loaded = /loaded=1/.test(text)
        root.enabled = /enabled=1/.test(text)
      }
    }
  }

  Process {
    id: actionProc
    stderr: StdioCollector { id: actionErr }
    onExited: function(exitCode) {
      root.busy = false
      if (exitCode !== 0) root.error = String(actionErr.text || "").trim() || "glass-ctl failed"
      root.refresh()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰖌"
    opacity: root.enabled ? 1 : 0.45
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleGlass()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(300))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onActivateRequested: root.toggleGlass()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        Item {
          width: parent.width
          implicitHeight: title.implicitHeight

          Text {
            id: title
            anchors.left: parent.left
            text: "LIQUID GLASS"
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            font.letterSpacing: 3
          }
          Text {
            anchors.right: parent.right
            anchors.baseline: title.baseline
            text: root.busy ? "…" : (root.enabled ? "ON" : (root.loaded ? "OFF" : "NOT LOADED"))
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            font.letterSpacing: 1.5
          }
        }

        Toggle {
          width: parent.width
          label: "Glass"
          description: "Refraction on the bar, dock and panels"
          checked: root.enabled
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.toggleGlass()
        }

        Text {
          width: parent.width
          visible: root.error !== ""
          text: root.error
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          color: Commons.Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
