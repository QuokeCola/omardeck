import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../Translations.js" as Translations

Item {
  id: root
  required property var entry
  property bool last: false
  property bool first: false
  property bool layered: false
  property bool expanded: false
  property bool groupCritical: false
  // The stack's messages, newest first, so the folded edges can wear the
  // colours of the cards they stand for.
  property var groupEntries: []
  // The colour urgent messages are marked in: the app's own, when its icon
  // has one, else the theme's urgent colour.
  property color accent: Commons.Color.urgent
  // A real card of this stack is on screen in the folded position, so the
  // drawn edges stand aside for it.
  property bool tuckedCardsLive: false
  property bool hasCursor: false
  property bool dismissHasCursor: false
  property bool compact: false
  property bool showBody: true
  property bool showPreview: true
  property double now: 0
  property string language: "en"
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  signal clicked()
  signal removeRequested()
  signal pointerUsed()

  readonly property bool critical: Number(entry.urgency) === 2
  // Cards pass behind one another while a stack folds, so they must hide
  // what is under them: the theme's popup colour, without its alpha.
  readonly property color cardFill: Qt.rgba(Commons.Color.popups.background.r, Commons.Color.popups.background.g, Commons.Color.popups.background.b, 1)
  readonly property color urgentFill: Qt.tint(cardFill, Util.alpha(accent, 0.14))
  // Card outlines, likewise opaque: the 18% foreground line pre-blended onto
  // the fill it borders. Folding tucks every card past the second into the
  // same place, and translucent outlines there would add up to a white edge.
  function outline(fill) { return Qt.tint(fill, Util.alpha(root.foreground, 0.18)) }
  function isUrgent(entry) { return !!entry && Number(entry.urgency) === 2 }
  // How far this card is out of its stack: 1 laid out, 0 tucked behind the
  // front card. Panel.qml drives it while a stack folds or unfolds.
  property real settle: 1
  // Urgent messages are marked by a line of their own, in the list's margin
  // just left of the card. It lives behind the card and slides out as the
  // card unfolds, so a folding card simply takes it back with it.
  readonly property real markerWidth: Style.space(3)
  readonly property real markerOut: -(markerWidth + Style.space(6))
  readonly property real markerIn: Style.space(10)
  readonly property real verticalPadding: Style.space(compact ? 8 : 12)
  readonly property real cardHeight: texts.implicitHeight + verticalPadding * 2
  readonly property bool hasPreview: showPreview && String(entry.preview || "") !== "" && previewImage.status !== Image.Error
  // The space under a card: a small gap inside a stack, more after its last
  // card, enough there to hold the folded edges. Eased on the same curve as
  // the cards folding and unfolding around it, so the list never jumps.
  property real trailing: !last ? Style.space(6)
    : Style.space(!layered ? 14 : groupEntries.length > 2 ? 24 : 18)
  Behavior on trailing {
    NumberAnimation { duration: root.layered ? 300 : 340; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.8, 0, 0.2, 1, 1, 1] }
  }
  implicitHeight: cardHeight + trailing

  // Sender-controlled markup must never load resources from notification text.
  function plain(value) {
    return String(value || "").replace(/<img[^>]*>/gi, "").replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim()
  }

  // The folded cards' edges, drawn where a tucked card ends up: scaled
  // about the card's bottom and showing just below it. Panel.qml tucks real
  // cards with the same numbers, which is what makes the hand-over seamless.
  Repeater {
    // One edge per card behind the front one, at most two, so unfolding
    // a pair never shows a third card that is not there.
    model: !root.last || !root.layered || root.tuckedCardsLive ? []
      : root.groupEntries.length > 2 ? [2, 1] : [1]
    delegate: Rectangle {
      required property int modelData
      readonly property real s: modelData === 1 ? 0.94 : 0.88
      readonly property real peek: Style.space(modelData === 1 ? 7 : 13)
      width: card.width * s
      x: card.x + (card.width - width) / 2
      height: Style.space(30)
      y: root.cardHeight + peek - height
      radius: Math.min(Style.space(10), Style.cornerRadius) * s
      color: root.isUrgent(root.groupEntries[modelData]) ? root.urgentFill : root.cardFill
      border.width: 1
      border.color: root.outline(color)
    }
  }
  Rectangle {
    id: marker
    visible: root.critical
    x: root.markerIn + (root.markerOut - root.markerIn) * root.settle
    width: root.markerWidth
    radius: width / 2
    height: root.cardHeight
    color: root.accent
    Behavior on color { ColorAnimation { duration: 300 } }
  }
  Item {
    id: card
    width: parent.width
    height: root.cardHeight
    HoverHandler { id: hover; onHoveredChanged: if (hovered) root.pointerUsed() }
    Rectangle {
      anchors.fill: parent
      radius: Math.min(Style.space(10), Style.cornerRadius)
      color: root.critical ? root.urgentFill : root.cardFill
      border.width: 1
      border.color: root.outline(color)
      Behavior on color { ColorAnimation { duration: 300; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.8, 0, 0.2, 1, 1, 1] } }
    }
    Rectangle {
      anchors.fill: parent
      anchors.margins: Style.space(3)
      color: "transparent"
      border.width: root.hasCursor && !root.dismissHasCursor ? 1 : 0
      border.color: Commons.Color.accent
      radius: Math.min(Style.space(4), Style.cornerRadius)
    }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: function(mouse) {
        root.pointerUsed()
        if (mouse.button === Qt.RightButton) root.removeRequested()
        else root.clicked()
      }
    }
    Column {
      id: texts
      x: Style.space(13)
      y: root.verticalPadding
      width: parent.width - Style.space(26)
      spacing: Style.space(4)
      // The time shares the subject's line and its space is always kept,
      // so it fades in and out with the stack instead of pushing the card
      // taller. The dismiss button takes its place while hovered.
      Item {
        width: parent.width
        height: summary.implicitHeight
        Text {
          id: summary
          width: parent.width - Math.max(stamp.implicitWidth, Style.space(26)) - Style.space(8)
          textFormat: Text.PlainText
          text: root.plain(root.entry.summary)
          elide: Text.ElideRight
          maximumLineCount: 1
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
        Text {
          id: stamp
          anchors.right: parent.right
          anchors.baseline: summary.baseline
          textFormat: Text.PlainText
          text: Translations.relativeTime(Number(root.entry.timestamp || 0), root.now, root.language)
          color: Util.alpha(root.foreground, 0.6)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          opacity: root.expanded && !(dismissButton.visible && dismissButton.opacity > 0) ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        }
      }
      Text {
        width: parent.width
        visible: root.showBody && text !== ""
        textFormat: Text.PlainText
        text: root.plain(root.entry.body)
        wrapMode: Text.WordWrap
        elide: Text.ElideRight
        maximumLineCount: 2
        color: Util.alpha(root.foreground, 0.75)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      Image {
        id: previewImage
        width: parent.width
        height: root.hasPreview ? Math.min(width * 9 / 16, Style.space(104)) : 0
        visible: root.hasPreview
        source: root.showPreview ? String(root.entry.preview || "") : ""
        sourceSize.width: Math.round(width * 2)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        // Rounding the preview costs an offscreen layer and an effect; most
        // cards have no preview, so they pay for neither.
        layer.enabled: root.hasPreview
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: previewMask
          maskThresholdMin: 0.5
          maskSpreadAtMin: 1.0
        }
      }

    }
    Rectangle {
      id: previewMask
      width: previewImage.width
      height: previewImage.height
      radius: Math.min(Style.space(8), Style.cornerRadius)
      color: "black"
      visible: false
      layer.enabled: root.hasPreview
    }
    NotificationAction {
      id: dismissButton
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      y: root.verticalPadding + summary.implicitHeight / 2 - height / 2
      visible: root.expanded || root.dismissHasCursor
      opacity: hover.hovered || root.hasCursor ? 1 : 0
      iconName: "close"
      size: Style.space(26)
      iconSize: Style.space(14)
      focusable: false
      tooltipText: Translations.text("Dismiss notification", root.language)
      foreground: root.foreground
      hasCursor: root.dismissHasCursor
      onClicked: { root.pointerUsed(); root.removeRequested() }
    }
  }
}
