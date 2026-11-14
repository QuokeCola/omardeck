import QtQuick

// The same marks the desktop draws around a window (see quokecola.hud), so they
// stay on it as it spreads out and slides. Not on a miniature in a tile.
Item {
  id: marks

  // The Card. Used: overlay flying focusedWindow picked modelData.appId
  required property var card
  readonly property var overlay: marks.card.overlay

  // One card lit: what Enter would act on. Keyboard selection doesn't move real focus,
  // and arrows can leave the pointer resting on another card, so while a selection
  // stands only it is lit. Not on the way out (`active` is off by then), where the
  // desktop's own marks are about to take over.
  readonly property bool lit: marks.overlay.active && marks.overlay.selectedKey !== ""
    ? marks.overlay.selectedKey === marks.card.modelData.key
    : marks.card.focusedWindow || marks.card.picked

  Loader {
    anchors.fill: parent
    visible: !marks.card.flying
    // As on the desktop to start with, and readable once it has become a card.
    opacity: marks.lit ? 1 : 0.6 + 0.25 * marks.overlay.dress
    source: Qt.resolvedUrl("../../quokecola.hud/holo/HoloMarks.qml")
    onLoaded: {
      // Hovering shows the corner blocks too, in place of a hard outline.
      item.focused = Qt.binding(() => marks.lit)
      item.title = Qt.binding(() => {
        const name = String(marks.card.modelData.appId || "window").split(".").pop()
        return name.charAt(0).toUpperCase() + name.slice(1)
      })
    }
  }
}
