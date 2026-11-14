pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "Preferences.js" as Preferences
import "components"

Item {
  id: root
  required property var settings
  property bool saving: false
  property string error: ""
  // Holographic theme. Off is the plain look, untouched.
  property bool holo: false
  property string monoFamily: Style.font.family
  // Where this page's section line sits, for the frame's marks.
  readonly property real ruleY: settingsHeader.height - 1
  readonly property color secondary: Qt.tint(Commons.Color.popups.background, Qt.alpha(Commons.Color.popups.text, 0.7))
  readonly property int padding: Style.space(20)
  implicitHeight: settingsHeader.height + settingsBody.implicitHeight
  signal save(string key, var value)
  signal back()
  function focusBack() { backButton.forceActiveFocus() }
  function resetScroll() { settingsScroll.contentY = 0 }
  Keys.onEscapePressed: root.back()

  // Keep native Tab focus visible when the complete settings page needs to scroll.
  function keepFocusVisible(item) {
    if (!visible || !item) return
    var ancestor = item
    while (ancestor && ancestor !== settingsScroll.contentItem) ancestor = ancestor.parent
    if (!ancestor) return
    var point = item.mapToItem(settingsScroll.contentItem, 0, 0)
    if (point.y < settingsScroll.contentY) settingsScroll.contentY = Math.max(0, point.y - Style.space(8))
    else if (point.y + item.height > settingsScroll.contentY + settingsScroll.height)
      settingsScroll.contentY = Math.max(0, Math.min(settingsScroll.contentHeight - settingsScroll.height, point.y + item.height - settingsScroll.height + Style.space(8)))
  }
  Connections {
    target: root.Window.window
    function onActiveFocusItemChanged() { root.keepFocusVisible(target.activeFocusItem) }
  }
  Item {
    id: settingsHeader
    width: parent.width
    height: headerRow.implicitHeight + root.padding * 2
    RowLayout {
      id: headerRow
      anchors.centerIn: parent
      width: root.width - root.padding * 2
      NotificationAction {
        id: backButton
        objectName: "settingsBack"
        iconName: "back"
        foreground: root.secondary
        tooltipText: "Back"
        onClicked: root.back()
      }
      Text {
        text: "Settings"
        color: root.holo ? Commons.Color.popups.text : root.secondary
        font.family: "sans-serif"
        font.bold: root.holo
        font.pixelSize: root.holo ? Style.font.title : Style.space(13)
        Layout.fillWidth: true
      }
      Text {
        visible: root.saving
        text: "Saving…"
        color: Commons.Color.pick("holo.text-dim", root.secondary)
        font.family: root.holo ? root.monoFamily : "sans-serif"
        font.pixelSize: root.holo ? Style.font.caption : Style.space(11)
      }
    }
    Rectangle {
      visible: root.holo
      anchors.bottom: parent.bottom
      width: parent.width
      height: 1
      color: Qt.alpha(Commons.Color.pick("holo.line", root.secondary), Commons.Color.pickAlpha("holo.line-alpha", 0.12))
    }
  }
  Flickable {
    id: settingsScroll
    objectName: "settingsScroll"
    anchors.top: settingsHeader.bottom
    anchors.bottom: parent.bottom
    width: parent.width
    contentWidth: width
    contentHeight: settingsBody.implicitHeight
    clip: true
    flickableDirection: Flickable.VerticalFlick
    boundsBehavior: Flickable.StopAtBounds
    onContentHeightChanged: contentY = Math.max(0, Math.min(contentY, contentHeight - height))
    onHeightChanged: contentY = Math.max(0, Math.min(contentY, contentHeight - height))
    Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
    Column {
      id: settingsBody
      width: parent.width
      leftPadding: root.padding
      rightPadding: root.padding
      bottomPadding: root.padding
      spacing: Style.space(14)
      Text {
        width: root.width - root.padding * 2
        visible: root.error !== ""
        text: root.error
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Commons.Color.pick("holo.text-alert", Commons.Color.urgent)
        font.family: "sans-serif"
        font.pixelSize: Style.space(12)
        Accessible.role: Accessible.AlertMessage
      }
      Text {
        objectName: "settingsSectionLabel"
        topPadding: root.holo ? Style.space(14) : 0
        text: "Notification Center"
        color: Commons.Color.pick("holo.text-dim", root.secondary)
        font.family: root.holo ? root.monoFamily : "sans-serif"
        font.pixelSize: root.holo ? Style.font.caption : Style.space(13)
      }
      Repeater {
        model: Preferences.fields
        SettingsField {
          required property var modelData
          width: root.width - root.padding * 2
          field: modelData
          settings: root.settings
          enabled: !root.saving
          opacity: enabled ? 1 : 0.55
          onSave: function(value) { root.save(field.key, value) }
        }
      }
    }
  }
}
