import QtQuick

// A card's shadow and border, under everything else on it. No size of its own: each
// is sized from the card and its titlebar (`tall`), in Hyprland's pixels.
Item {
  id: dressing

  required property var card
  readonly property var overlay: card.overlay
  readonly property var surface: card.surface

  z: -1

  readonly property int tall: card.pxH + card.pxBar

  // Under a titlebar, the bar's colour behind the window's top corners. Hyprland
  // rounds those corners too and the bar shows in the gap; a card's bar stops at
  // the window's top edge, and the wallpaper showed there instead. A strip as
  // deep as the corner, under the window, which covers all of it but the gaps.
  Rectangle {
    visible: card.barH > 0.5 && card.radius > 0.5
    width: card.width
    height: card.radius
    color: card.focusedWindow ? overlay.deco.barColor : overlay.deco.barColorInactive
    opacity: card.real.opacity ?? 1
  }

  ShaderEffect {
    id: shadowEffect
    readonly property int reach: Math.round((overlay.deco.border + overlay.deco.shadowRange) * surface.hyprScale)
    readonly property int corner: Math.floor((card.radius + overlay.deco.border) * surface.hyprScale)
    readonly property int spread: Math.floor(overlay.deco.shadowRange * surface.hyprScale)
    readonly property color tint: card.focusedWindow ? overlay.deco.shadowColor : overlay.deco.shadowColorInactive
    x: -reach / surface.hyprScale + overlay.deco.shadowOffsetX
    y: -reach / surface.hyprScale + overlay.deco.shadowOffsetY - card.barH
    width: (card.pxW + 2 * reach) / surface.hyprScale
    height: (dressing.tall + 2 * reach) / surface.hyprScale
    z: -1
    opacity: card.dressedAway
    visible: overlay.deco.shadow && card.real.shadow === true && spread > 0 && opacity > 0.01 && !card.dragging
    property vector4d color: Qt.vector4d(tint.r, tint.g, tint.b, tint.a)
    property vector2d fullSize: Qt.vector2d(card.pxW + 2 * reach, dressing.tall + 2 * reach)
    property vector2d topLeft: Qt.vector2d(spread + corner, spread + corner)
    property vector2d bottomRight: Qt.vector2d(card.pxW + 2 * reach - (spread + corner), dressing.tall + 2 * reach - (spread + corner))
    property real radius: corner
    property real range: spread
    property real shadowPower: overlay.deco.shadowPower
    property real roundingPower: overlay.deco.roundingPower
    fragmentShader: Qt.resolvedUrl("deco/shadow.frag.qsb")
  }

  ShaderEffect {
    readonly property int thickness: Math.round(overlay.deco.border * surface.hyprScale)
    readonly property color tint: card.focusedWindow ? overlay.deco.activeBorder : overlay.deco.inactiveBorder
    x: -thickness / surface.hyprScale
    y: -thickness / surface.hyprScale - card.barH
    width: (card.pxW + 2 * thickness) / surface.hyprScale
    height: (dressing.tall + 2 * thickness) / surface.hyprScale
    z: -1
    opacity: card.dressedAway
    visible: thickness > 0 && opacity > 0.01 && !card.dragging
    property vector4d color: Qt.vector4d(tint.r, tint.g, tint.b, tint.a)
    property vector2d fullSize: Qt.vector2d(card.pxW + 2 * thickness, dressing.tall + 2 * thickness)
    property real radius: card.pxRound > 0 ? card.pxRound + thickness : 0
    property real radiusOuter: (card.radius + overlay.deco.border) * surface.hyprScale
    property real thick: thickness
    property real roundingPower: overlay.deco.roundingPower
    fragmentShader: Qt.resolvedUrl("deco/border.frag.qsb")
  }
}
