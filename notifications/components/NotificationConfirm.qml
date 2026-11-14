import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The one question before a removal that takes more than one notification with
// it. It sits in the row it asks about, so the rest of the sheet stays usable
// behind it: nothing here is modal. Focus lands on Keep, so a key held down or
// pressed twice can't take the action; Left and Right move between the two.
Item {
  id: root
  required property string message
  required property string actionLabel
  property color foreground: Commons.Color.popups.text
  property color danger: Commons.Color.urgent
  property string fontFamily: Style.font.family
  property int messageSize: Style.font.caption
  property int buttonSize: Style.font.caption
  signal confirmed()
  signal kept()

  implicitHeight: Style.space(29)

  Component.onCompleted: Qt.callLater(function() { if (keep) keep.forceActiveFocus() })

  component ConfirmButton: Rectangle {
    id: button
    required property string label
    property color ink: root.foreground
    property Item other: null
    signal activated()

    width: buttonText.implicitWidth + Style.space(16)
    height: parent.height
    radius: Math.min(Style.space(7), Style.cornerRadius)
    color: pointer.containsMouse || activeFocus ? Qt.alpha(ink, pointer.pressed ? 0.24 : 0.12) : "transparent"
    // Two pixels and the accent: the ring has to read as focus, not as the outline.
    border.width: activeFocus ? 2 : 1
    border.color: activeFocus ? Commons.Color.accent : Qt.alpha(ink, 0.5)
    activeFocusOnTab: false
    Accessible.role: Accessible.Button
    Accessible.name: label
    Accessible.onPressAction: activated()

    Text {
      id: buttonText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: button.label
      color: button.ink
      font.family: root.fontFamily
      font.pixelSize: root.buttonSize
    }
    MouseArea {
      id: pointer
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: button.activated()
    }
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Left || event.key === Qt.Key_Right || event.text === "h" || event.text === "l") {
        if (button.other) button.other.forceActiveFocus()
        event.accepted = true
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
        button.activated()
        event.accepted = true
      } else if (event.key === Qt.Key_Escape) {
        root.kept()
        event.accepted = true
      } else if (event.key === Qt.Key_Delete || event.text === "x" || event.text === "X") {
        // A second Delete is not an answer: only the button says yes.
        event.accepted = true
      }
      // Anything else goes on to the sheet, which puts the question away first.
    }
  }

  Text {
    anchors.left: parent.left
    anchors.right: buttons.left
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: root.message
    elide: Text.ElideRight
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: root.messageSize
  }
  Row {
    id: buttons
    anchors.right: parent.right
    height: parent.height
    spacing: Style.space(6)
    ConfirmButton {
      id: action
      objectName: "confirmAction"
      label: root.actionLabel
      ink: root.danger
      other: keep
      onActivated: root.confirmed()
    }
    ConfirmButton {
      id: keep
      objectName: "confirmKeep"
      label: "Keep"
      other: action
      onActivated: root.kept()
    }
  }
}
