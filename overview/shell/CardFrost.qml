import QtQuick

// What the compositor blurs behind a window: the piece of the blurred screen the
// card is over, cut to its shape. Tiled windows take it from the desktop's blur;
// floating ones from the blur that has the tiled windows in it too, the way
// Hyprland stacks them.
//
// Outside the frame, not in it: the frame draws its contents through a copy of its
// own, and textures read inside that never update.
ShaderEffect {
  required property var card
  // The card's frame, whose fading this may follow.
  required property Item frame
  readonly property var overlay: card.overlay
  readonly property var surface: card.surface

  anchors.fill: parent
  visible: card.frostedGlass
  // Hyprland draws the blur whole under a see-through window unless
  // told not to; faded with the card, the sharp desktop shows through.
  opacity: overlay.deco.blurIgnoreOpacity === false ? frame.opacity : 1
  property var source: card.floating ? surface.floatBlurFor(card.modelData.key)
                     : (surface.overStrip ? surface.baseBlurOutput : surface.wallBlurOutput)
  // Where the card is on screen, scaled about its middle as it is
  // drawn, as a fraction of the screen.
  property vector4d area: {
    const w = card.width * card.scale
    const h = card.height * card.scale
    const x = card.stageX + (card.width - w) / 2
    const y = card.y + (card.height - h) / 2
    return Qt.vector4d(x / Math.max(1, surface.width), y / Math.max(1, surface.height),
                       w / Math.max(1, surface.width), h / Math.max(1, surface.height))
  }
  property vector2d size: Qt.vector2d(width, height)
  property real radius: card.radius
  // The liquidglass plugin's lens, as the compositor draws it on the window.
  property real glass: overlay.deco.glass ? 1 : 0
  property real bezel: overlay.deco.glassBezel
  property real refraction: overlay.deco.glassRefraction
  property real dispersion: overlay.deco.glassDispersion
  property real specular: overlay.deco.glassSpecular
  property vector2d lightDir: Qt.vector2d(Math.cos(overlay.deco.glassLightAngle * Math.PI / 180),
                                          Math.sin(overlay.deco.glassLightAngle * Math.PI / 180))
  property real glassBrightness: overlay.deco.glassBrightness
  property real saturation: overlay.deco.glassSaturation
  fragmentShader: Qt.resolvedUrl("blur/frost.frag.qsb")
}
