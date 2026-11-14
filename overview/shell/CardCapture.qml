import QtQuick
import Quickshell.Wayland

// The window itself, in the card's frame.
//
// Drawn as it is when its corners are square. Rounded, it goes
// through one layer and is cut to shape on the way out — not a
// ClippingRectangle, which keeps a second layer for the shape, and
// reallocates and redraws both on every frame a card changes size,
// which in a swipe is every frame, for every card.
Rectangle {
  id: frame

  required property var card
  readonly property var overlay: card.overlay
  readonly property var surface: card.surface

  readonly property alias hasContent: shot.hasContent
  readonly property alias sourceSize: shot.sourceSize

  anchors.fill: parent
  layer.enabled: card.radius > 0.5
  layer.effect: ShaderEffect {
    property vector2d size: Qt.vector2d(frame.width, frame.height)
    property real radius: card.radius
    fragmentShader: Qt.resolvedUrl("deco/clip.frag.qsb")
  }
  // As see-through as Hyprland draws the window, the whole way out:
  // a card is the window, so it does not turn solid as it spreads.
  // Not in `geo` yet (Hyprland has not reported its size): the
  // snapshot it falls back to carries no opacity.
  opacity: card.real.opacity ?? 1
  // Under the capture, so a window whose first frame has not arrived
  // yet reads as a tile and not as a hole — but only as the overview
  // comes in. At the start of a swipe the card sits exactly on its
  // real window, which is still showing, so an empty card should let
  // that window through rather than flash a dark block over it.
  // Not under a see-through window's capture: square, the frame is
  // not drawn through a layer, so the backing and the capture are
  // each faded on their own and the one fills in what the other
  // lets through.
  // Nor under any card, in a look that has it just be its window.
  color: overlay.look.plainCards || card.frostedGlass || (shot.hasContent && card.real.opacity < 1) ? "transparent"
       : shot.hasContent ? "#101014" : Qt.rgba(0.063, 0.063, 0.078, overlay.veil)

  ScreencopyView {
    id: shot
    anchors.fill: parent
    captureSource: shot.cut ? null : card.modelData.capture
    // A capture that fails stays failed: nothing else asks again
    // (`captureFrame` only runs once there is a frame) and the card
    // is never rebuilt while its window stays put, so it sat as an
    // empty tile — and see-through mid-swipe — until the shell
    // restarted. Dropping the source for a moment starts a fresh one.
    property bool cut: false
    property int restarts: 0
    function restart(why) {
      if (!card.modelData.capture || shot.restarts >= 5) return
      shot.restarts++
      console.warn("aerial-capture restart " + card.modelData.key + " " + card.modelData.appId
                   + ": " + why + " (#" + shot.restarts + ")")
      shot.cut = true
      Qt.callLater(() => shot.cut = false)
    }
    onStopped: shot.restart("stopped")
    onHasContentChanged: if (shot.hasContent) {
      shot.restarts = 0
      if (card.awaited) card.arrive()
      if (surface.missed[card.modelData.key]) {
        const missed = Object.assign({}, surface.missed)
        delete missed[card.modelData.key]
        surface.missed = missed
      }
    }
    // Never quite opaque. A capture is drawn as an opaque texture —
    // copied over what is behind it, alpha and all — and a terminal's
    // see-through background then punches a hole through the
    // overview to the real windows under it, rather than showing the
    // frosted glass. Short of 1, Qt blends it like anything else. (The
    // ClippingRectangle this used to sit in hid that by drawing it
    // through a layer first.)
    opacity: 0.999
    // Never live, not even for the window under the pointer. A live
    // capture is a texture that changes every frame, and one of those
    // makes the compositor redraw this whole surface sixty times a
    // second — the wallpaper, every tile, every icon — which cost more
    // than all eight captures put together. On the clock instead, they
    // still read as alive and the surface redraws a dozen times a
    // second rather than sixty.
    // Not even at either end of a swipe, where the card hands over to
    // its window: one fresh frame is asked for as the swipe begins
    // and another as a closing card nears home (see `beat`), which is
    // as current as live was, without capturing every window on
    // screen on every frame of the swipe.
    //
    // Live only until its first frame is in: a card waits for its
    // capture before the overview can appear, and live, the first
    // frame arrives as soon as the compositor can give it.
    live: (card.shown || card.awaited) && overlay.opened && !shot.hasContent
  }

  // Failing without saying so: on screen, open, and still no frame.
  Timer {
    interval: 1000
    repeat: true
    running: card.onScreen && overlay.opened && !shot.hasContent
    onTriggered: shot.restart("no frame after 1s")
  }

  Connections {
    target: overlay
    // Only the cards you can actually see are worth a frame; the rest
    // are kept alive purely so that showing them is instant. And only
    // once they have a first frame: until then they are live anyway,
    // and asking a capture that has not started yet for a frame only
    // gets a warning back.
    function onBeatChanged() {
      if (!shot.hasContent) return
      if (card.shown || card.flying || card.fading || (overlay.priming && Math.abs(card.lane) < 1.5)) shot.captureFrame()
    }
  }

  // Coming into view does not wait for the next beat. Without this a
  // card that has just been peeked at shows its placeholder until the
  // clock comes round, which is the blank tile people saw.
  Connections {
    target: card
    function onShownChanged() { if (card.shown && shot.hasContent) shot.captureFrame() }
  }
}
