import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../Model.js" as Model

Item {
  id: root
  required property var group
  property bool compact: false
  property bool expanded: false
  property bool hasCursor: false
  property bool dismissHasCursor: false
  property double now: 0
  property double readMark: 0
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  // Holographic theme. Off is the plain look, untouched.
  property bool holo: false
  property string copyFamily: fontFamily
  // Set while this stack is waiting on "dismiss them all?".
  property bool confirming: false
  property color danger: Commons.Color.urgent
  signal confirmed()
  signal kept()
  signal toggleRequested()
  signal removeRequested()
  signal pointerUsed()

  implicitHeight: Math.max(Style.space(root.compact ? 28 : 36), labels.implicitHeight + Style.space(root.compact ? 8 : 14))
  readonly property bool expandable: group.entries.length > 1
  readonly property var tags: Model.stackTags(group, readMark, expanded)
  // An app's raw id reads worse than its name; search still matches the raw id.
  readonly property string displayName: {
    var label = group.label || group.app
    if (!holo || label !== group.app) return label
    var desktop = DesktopEntries.byId(group.app)
    return desktop && desktop.name ? desktop.name : label
  }
  readonly property color dimText: Commons.Color.pick("holo.text-dim", Util.alpha(foreground, 0.65))
  readonly property string iconSource: {
    var value = String(group.appIcon || "")
    if (!value) return ""
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    return Quickshell.iconPath(value, true)
  }

  HoverHandler { id: hover; onHoveredChanged: if (hovered) root.pointerUsed() }
  // No frame: the app's name sits on the panel above its cards.
  Rectangle {
    anchors.fill: headingMouse
    visible: root.hasCursor && !root.dismissHasCursor && !root.confirming
    color: root.holo ? Style.selectedFillFor(root.foreground, Commons.Color.accent, Commons.Color.urgent) : "transparent"
    border.width: root.holo ? 0 : 1
    border.color: Commons.Color.accent
    radius: root.holo ? 0 : Math.min(Style.space(6), Style.cornerRadius)
    Rectangle {
      visible: root.holo
      width: Math.max(1, Style.space(2))
      height: parent.height
      color: Style.selectedBorderFor(root.foreground, Commons.Color.accent, Commons.Color.urgent)
    }
  }
  MouseArea {
    id: headingMouse
    anchors.fill: parent
    anchors.rightMargin: dismiss.width + (root.expandable ? fold.width : 0) + Style.space(8)
    enabled: !root.confirming
    cursorShape: root.expandable ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: { root.pointerUsed(); if (root.expandable) root.toggleRequested() }
  }
  Item {
    id: avatar
    anchors.left: parent.left
    anchors.leftMargin: Style.space(4)
    anchors.verticalCenter: parent.verticalCenter
    width: Style.space(root.compact ? 14 : 18)
    height: width
    Image {
      id: appIcon
      objectName: "notificationAppIcon"
      anchors.fill: parent
      source: root.iconSource
      sourceSize.width: width * 2
      sourceSize.height: height * 2
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      visible: status === Image.Ready && faviconIcon.status !== Image.Ready
    }
    Image {
      id: faviconIcon
      objectName: "notificationFavicon"
      anchors.fill: parent
      source: String(root.group.favicon || "").indexOf("file://") === 0 ? root.group.favicon : ""
      sourceSize.width: width * 2
      sourceSize.height: height * 2
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      visible: status === Image.Ready
    }
    // A letter is a stand-in for an icon, so give it an icon's weight.
    Rectangle {
      anchors.fill: parent
      visible: root.holo && appIcon.status !== Image.Ready && faviconIcon.status !== Image.Ready
      color: "transparent"
      border.width: 1
      border.color: Qt.alpha(Commons.Color.pick("holo.line", root.foreground), Commons.Color.pickAlpha("holo.line-alpha", 0.4))
    }
    Text {
      anchors.centerIn: parent
      visible: appIcon.status !== Image.Ready && faviconIcon.status !== Image.Ready
      textFormat: Text.PlainText
      text: root.group.glyph || root.group.app.charAt(0).toUpperCase()
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: root.holo ? Style.font.bodySmall : Style.font.body
    }
  }
  Text {
    id: labels
    visible: !root.confirming
    anchors.left: avatar.right
    anchors.leftMargin: Style.space(9)
    anchors.right: metadata.left
    anchors.rightMargin: Style.space(9)
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: root.displayName
    elide: Text.ElideRight
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: root.holo ? Style.font.bodySmall : Style.font.caption
  }
  Row {
    id: metadata
    visible: !root.confirming
    // Under the holographic theme the chevron's slot is held on every row, so the
    // time sits in one column down the sheet.
    anchors.right: root.expandable || root.holo ? fold.left : dismiss.left
    anchors.rightMargin: Style.space(5)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(6)
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      visible: !root.holo && root.group.timestamp > root.readMark
      width: Style.space(4)
      height: width
      radius: width / 2
      color: Commons.Color.accent
    }
    Text {
      objectName: "notificationHeaderCritical"
      visible: root.holo && text !== ""
      textFormat: Text.PlainText
      text: root.tags.critical
      color: Commons.Color.pick("holo.text-alert", Commons.Color.urgent)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      objectName: "notificationHeaderNew"
      visible: root.holo && text !== ""
      textFormat: Text.PlainText
      text: root.tags.fresh
      color: Commons.Color.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      visible: root.holo && root.expandable
      textFormat: Text.PlainText
      text: "\u00D7" + root.group.entries.length
      color: root.dimText
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      objectName: "notificationHeaderTime"
      textFormat: Text.PlainText
      text: root.holo ? Model.relativeTime(root.group.timestamp, root.now)
                      : root.group.entries.length + " · " + Model.relativeTime(root.group.timestamp, root.now)
      color: root.dimText
      font.family: root.fontFamily
      font.pixelSize: root.holo ? Style.font.bodySmall : Style.font.caption
    }
  }
  // Fold / unfold. Always shown on a stack, unlike the hover-only dismiss: it
  // is how you find out a stack opens. The chevron turns to point up while
  // the stack is open.
  NotificationAction {
    id: fold
    visible: root.expandable && !root.confirming
    anchors.right: dismiss.left
    anchors.rightMargin: Style.space(root.holo ? 7 : 2)
    anchors.verticalCenter: parent.verticalCenter
    iconName: "chevron"
    size: Style.space(root.holo ? 29 : 26)
    iconSize: Style.space(14)
    focusable: false
    foreground: root.foreground
    rotation: root.expanded ? 180 : 0
    Behavior on rotation { NumberAnimation { duration: Style.duration(220); easing.type: Easing.OutCubic } }
    tooltipText: root.expanded ? "Show less" : "Show all"
    onClicked: { root.pointerUsed(); root.toggleRequested() }
  }
  NotificationAction {
    id: dismiss
    objectName: "notificationStackDismiss"
    visible: !root.confirming
    anchors.right: parent.right
    anchors.rightMargin: Style.space(6)
    anchors.verticalCenter: parent.verticalCenter
    iconName: "close"
    size: Style.space(root.holo ? 29 : 26)
    iconSize: Style.space(14)
    focusable: false
    foreground: root.foreground
    hoverForeground: root.holo ? Commons.Color.urgent : foreground
    hasCursor: root.dismissHasCursor
    opacity: hover.hovered || root.hasCursor ? 1 : 0
    tooltipText: root.group.entries.length === 1 ? "Dismiss 1 notification" : "Dismiss " + root.group.entries.length + " notifications"
    onClicked: { root.pointerUsed(); root.removeRequested() }
  }
  // Built only while it is asked: a heading is on screen far more often than this.
  Repeater {
    model: root.confirming ? 1 : 0
    NotificationConfirm {
      objectName: "notificationStackConfirm"
      required property int index
      readonly property var question: Model.dismissStackQuestion(root.displayName, root.group.entries.length)
      anchors.left: avatar.right
      anchors.leftMargin: Style.space(9)
      anchors.right: root.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: root.verticalCenter
      height: implicitHeight
      message: question.message
      actionLabel: question.action
      foreground: root.foreground
      danger: root.danger
      fontFamily: root.copyFamily
      messageSize: root.holo ? Style.font.bodySmall : Style.font.caption
      buttonSize: root.holo ? Style.font.bodySmall : Style.font.caption
      onConfirmed: root.confirmed()
      onKept: root.kept()
    }
  }
}
