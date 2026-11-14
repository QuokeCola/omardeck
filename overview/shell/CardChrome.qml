import QtQuick
import Quickshell.Widgets
import qs.Commons

// What a card wears that isn't the window: a close button and a caption. Kept
// together: per-card objects multiply by windows times screens.
Item {
  required property var card
  readonly property var overlay: card.overlay
  readonly property var surface: card.surface

  anchors.fill: parent

  // Close it from here, rather than going there to close it.
  Rectangle {
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: 8
    width: 26
    height: 26
    radius: overlay.look.corner(13)
    color: shut.hovered ? overlay.look.alert("#D2604F") : Qt.rgba(0, 0, 0, 0.62)
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.22)
    visible: overlay.active && card.picked && !card.dragging && !card.flying
    opacity: visible ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Style.duration(110) } }

    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: "×"
      color: overlay.look.ink("#F4F1E9")
      font.family: Style.font.family
      font.pixelSize: Math.round(Style.font.body * 1.1)
    }

    HoverHandler { id: shut }

    TapHandler {
      onTapped: overlay.closeWindow(card.modelData.key)
    }
  }

  // The name of the window, under it, the way a caption sits under a
  // photograph — with the app's own icon, because at thumbnail size the
  // icon is what you recognise before you have read anything.
  Rectangle {
    id: captionPill
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.bottom
    anchors.topMargin: 10
    width: Math.min(caption.implicitWidth + 20, parent.width)
    height: caption.implicitHeight + 10
    radius: overlay.look.corner(height / 2)
    color: card.picked ? Qt.rgba(0, 0, 0, 0.78) : Qt.rgba(0, 0, 0, 0.5)
    border.width: overlay.look.captionEdge(card.picked)
    border.color: overlay.look.ink("transparent")
    opacity: overlay.active && !card.flying ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Style.duration(120) } }

    Row {
      id: caption
      anchors.centerIn: parent
      spacing: 7

      IconImage {
        anchors.verticalCenter: parent.verticalCenter
        implicitSize: Math.round(Style.font.caption * 1.35)
        source: card.icon
        visible: card.icon !== ""
      }

      // Which desktop a match came from, shown only when that is news:
      // while searching, and only for a window that is not on the one you
      // are already looking at.
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        visible: surface.searching
                 && overlay.wsOf(card.modelData) !== surface.shownWorkspace
        implicitWidth: elsewhere.implicitWidth + 12
        implicitHeight: elsewhere.implicitHeight + 4
        radius: surface.rounded(4)
        color: Qt.rgba(1, 1, 1, 0.14)

        Text {
          id: elsewhere
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: overlay.wsOf(card.modelData)
          color: overlay.look.ink("#F7F4EC")
          font.family: Style.font.family
          font.pixelSize: overlay.look.legible(Math.round(Style.font.caption * 0.9))
          font.weight: Font.DemiBold
        }
      }

      Text {
        // Window titles are somebody else's string: a browser tab can put
        // anything in one. Rendered literally, never interpreted as markup.
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, card.width - 40)
        // Live while it can be seen, from the window itself; not
        // listening otherwise, so a retitle with the overview put away
        // costs nothing.
        text: captionPill.opacity > 0 && card.real !== card.modelData
              ? ((card.modelData.top && card.modelData.top.title) || "") : card.modelData.title
        elide: Text.ElideRight
        color: card.picked ? overlay.look.ink("#F7F4EC") : overlay.look.dim("#C9C3B9")
        font.family: Style.font.family
        font.pixelSize: overlay.look.primaryText(Style.font.caption)
      }
    }
  }
}
