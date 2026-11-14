import QtQuick

// A floating window has its own panel on the desktop, drawn by the holobackdrop
// plugin, as the shared overlay is behind everything else. The same panel here, so
// it doesn't vanish as the overview takes over from the real window.
Item {
  id: underlay

  // The Card. Used: flying
  required property var card

  Loader {
    id: frame
    anchors.fill: parent
    anchors.margins: frame.item ? -frame.item.pad : 0
    visible: !underlay.card.flying
    source: Qt.resolvedUrl("../../quokecola.hud/holo/HoloFrame.qml")
    onLoaded: item.ticks = false
  }
}
