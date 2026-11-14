import QtQuick
import Quickshell.Wayland

// A window being carried over this screen from another one. Its card
// stays with the screen it was picked up on, which has the pointer until
// the button comes up; here it is drawn again where it is, from its own
// capture, so it crosses the gap between screens as one card. Held after
// the drop, where it was let go, until the window's new card here has a
// frame to take over with.
Item {
  id: visitor

  required property var surface
  readonly property var overlay: visitor.surface.overlay

  readonly property bool carried: overlay.dragKey !== "" && overlay.dragHome !== surface.monitorName
  readonly property bool landing: overlay.arrival !== null && overlay.arrival.screen === surface.monitorName
  readonly property rect at: visitor.landing ? overlay.arrival.rect : overlay.dragRect
  readonly property real originX: surface.monitor ? surface.monitor.x : 0
  readonly property real originY: surface.monitor ? surface.monitor.y : 0
  x: visitor.at.x - visitor.originX
  y: visitor.at.y - visitor.originY
  width: visitor.at.width
  height: visitor.at.height
  visible: (visitor.carried || visitor.landing) && visitor.width > 0
           && visitor.x < surface.width && visitor.x + visitor.width > 0
           && visitor.y < surface.height && visitor.y + visitor.height > 0
  opacity: 0.94

  Rectangle {
    id: visitorFrame
    anchors.fill: parent
    readonly property real corner: surface.rounded(14)
    layer.enabled: visitorFrame.corner > 0.5
    layer.effect: ShaderEffect {
      property vector2d size: Qt.vector2d(visitorFrame.width, visitorFrame.height)
      property real radius: visitorFrame.corner
      fragmentShader: Qt.resolvedUrl("deco/clip.frag.qsb")
    }
    opacity: overlay.dragOpacity
    color: overlay.look.plainCards ? "transparent" : "#101014"

    ScreencopyView {
      id: visitorShot
      anchors.fill: parent
      // From the moment anything is picked up, on every screen it might
      // be carried to, so the first frame is in before it arrives.
      captureSource: visitor.carried || visitor.landing ? overlay.dragCapture : null
      live: visitor.carried || visitor.landing
      opacity: 0.999
    }
  }

  Rectangle {
    anchors.fill: parent
    radius: visitorFrame.corner
    color: "transparent"
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.22)
  }
}
