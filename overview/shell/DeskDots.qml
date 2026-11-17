import QtQuick
import qs.Commons as Commons

// Where a desktop swipe is.
//
// Swiping between desktops from the desktop slides only the windows, so
// between two empty ones nothing on screen moved. A row of dots, one for
// each desktop you can slide to, with a mark that follows the fingers;
// hollow where a desktop has nothing on it. Outside `stage`, which is
// hidden the moment the slide lands, so it can linger and fade.
Item {
  id: deskDots

  required property var surface
  readonly property var overlay: deskDots.surface.overlay

  readonly property bool wanted: surface.following && overlay.deskSliding && !overlay.active
  readonly property real dot: 8
  readonly property real step: 18
  // What it last showed, held while it fades: the overview forgets its
  // desktops the moment the slide is put away.
  property var lanes: []
  property real position: 0
  readonly property var liveLanes: overlay.lanes
  readonly property real livePosition: overlay.stageIndex + overlay.shownSlide
  onLiveLanesChanged: if (deskDots.liveLanes.length > 0) deskDots.lanes = deskDots.liveLanes
  onLivePositionChanged: if (overlay.stageIndex >= 0 && deskDots.liveLanes.length > 0)
    deskDots.position = Math.max(0, Math.min(deskDots.liveLanes.length - 1, deskDots.livePosition))
  readonly property int count: deskDots.lanes.length

  // The mark's span, read straight off how far the slide is between two
  // dots, so it moves with the fingers and the landing spring alike and
  // never on a clock of its own. Over the first half of the way the
  // leading edge reaches across to the next dot; over the second half the
  // trailing edge catches up. Backwards, the same in reverse.
  readonly property int markBase: Math.floor(deskDots.position)
  readonly property real markPart: deskDots.position - deskDots.markBase
  readonly property real markFrom: deskDots.markBase + Math.max(0, 2 * deskDots.markPart - 1)
  readonly property real markTo: deskDots.markBase + Math.min(1, 2 * deskDots.markPart)
  // Fades in rising a little, and out sinking back.
  property real shown: deskDots.wanted || dotsLinger.running ? 1 : 0
  Behavior on shown { NumberAnimation { duration: Commons.Style.duration(deskDots.wanted ? 220 : 260); easing.type: Easing.OutCubic } }
  visible: deskDots.shown > 0.01 && deskDots.count > 1
  opacity: deskDots.shown
  transform: Translate { y: (1 - deskDots.shown) * 10 }
  onWantedChanged: if (!deskDots.wanted) dotsLinger.restart()
  Timer { id: dotsLinger; interval: 450 }

  width: deskDots.count * deskDots.step + 16
  height: 30
  x: (surface.width - width) / 2
  // Above a dock along the bottom edge, when one says it is there.
  readonly property real dockCover: overlay.service && overlay.service.dockCovers
                                    ? (overlay.service.dockCovers[surface.monitorName] || 0) : 0
  property real lift: Math.max(64, deskDots.dockCover + 14)
  Behavior on lift { NumberAnimation { duration: Commons.Style.duration(260); easing.type: Easing.OutCubic } }
  y: surface.height - height - deskDots.lift

  // Frosted the way the dock and the panels are when Hyprland blurs: the
  // slide under the pill, blurred with Hyprland's own settings (see
  // HyprBlur.qml), and bent into a lens at its rim with liquid glass on —
  // the same frost the cards wear. Hyprland cannot do it for us: what is
  // under the pill is this surface's own slide, not the desktop.
  //
  // Live while the slide is on screen; held as the dots linger after it is
  // put away, when the desktop shows exactly what the last frame did.
  readonly property bool frosted: surface.glass === true
  readonly property bool frostLive: deskDots.frosted && deskDots.wanted && surface.visible
  // Fully round wherever Hyprland rounds at all, however small its radius: a
  // pill with 6px corners reads as a box. Square setups (rounding 0) stay square.
  function pill(r) { return overlay.deco.rounding > 0 ? r : 0 }
  readonly property real radius: deskDots.pill(height / 2)
  // Room around the pill for the blur to reach in from, as far as Hyprland's
  // passes spread it.
  readonly property real reach: Math.max(8, Math.min(96,
    overlay.deco.blurSize * Math.pow(2, Math.min(4, overlay.deco.blurPasses)) / surface.hyprScale))

  Item {
    id: dotsBehind
    visible: false
    width: deskDots.width + 2 * deskDots.reach
    height: deskDots.height + 2 * deskDots.reach
    ShaderEffectSource {
      anchors.fill: parent
      sourceItem: deskDots.frosted ? deskDots.surface : null
      sourceRect: Qt.rect(deskDots.x - deskDots.reach, deskDots.y - deskDots.reach,
                          dotsBehind.width, dotsBehind.height)
      textureSize: Qt.size(Math.max(1, Math.round(dotsBehind.width * surface.hyprScale)),
                           Math.max(1, Math.round(dotsBehind.height * surface.hyprScale)))
      live: deskDots.frostLive
    }
  }

  HyprBlur {
    id: dotsBlur
    width: dotsBehind.width
    height: dotsBehind.height
    sourceItem: deskDots.frosted ? dotsBehind : null
    live: deskDots.frostLive
    pixelSize: Qt.size(Math.max(1, Math.round(dotsBehind.width * surface.hyprScale)),
                       Math.max(1, Math.round(dotsBehind.height * surface.hyprScale)))
    size: overlay.deco.blurSize
    passes: overlay.deco.blurPasses
    noise: overlay.deco.blurNoise
    contrast: overlay.deco.blurContrast
    brightness: overlay.deco.blurBrightness
    vibrancy: overlay.deco.blurVibrancy
    vibrancyDarkness: overlay.deco.blurVibrancyDarkness
  }

  ShaderEffect {
    anchors.fill: parent
    visible: deskDots.frosted
    property var source: dotsBlur.output
    property vector4d area: Qt.vector4d(deskDots.reach / dotsBehind.width, deskDots.reach / dotsBehind.height,
                                        deskDots.width / dotsBehind.width, deskDots.height / dotsBehind.height)
    property vector2d size: Qt.vector2d(width, height)
    property real radius: deskDots.radius
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

  Rectangle {
    anchors.fill: parent
    radius: deskDots.radius
    // Lighter over the frost, so the glass shows; as it was without.
    color: Qt.rgba(0.04, 0.04, 0.05, deskDots.frosted ? 0.4 : 0.72)
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.14)
  }

  // The mark: a block of the accent under the dots, one dot wide at rest,
  // stretched across to the next one as the slide moves.
  readonly property real markPad: 3
  Rectangle {
    x: 8 + deskDots.markFrom * deskDots.step + (deskDots.step - deskDots.dot) / 2 - deskDots.markPad
    anchors.verticalCenter: parent.verticalCenter
    width: (deskDots.markTo - deskDots.markFrom) * deskDots.step + deskDots.dot + 2 * deskDots.markPad
    height: deskDots.dot + 2 * deskDots.markPad
    radius: deskDots.pill(height / 2)
    color: Commons.Color.accent
  }

  // Dots on the block take the colour that reads against the accent: dark on
  // a light accent, light on a dark one.
  readonly property color accent: Commons.Color.accent
  readonly property bool accentLight: 0.2126 * deskDots.accent.r + 0.7152 * deskDots.accent.g
                                      + 0.0722 * deskDots.accent.b > 0.55
  readonly property color onMark: deskDots.accentLight ? Qt.rgba(0.04, 0.04, 0.05, 1) : Qt.rgba(1, 1, 1, 1)

  Repeater {
    model: deskDots.lanes
    delegate: Rectangle {
      id: laneDot
      required property var modelData
      required property int index
      readonly property bool filled: surface.monitorWindows.some(w => overlay.wsOf(w) === laneDot.modelData)
      // How much of the dot the block covers, 0 to 1, so it changes colour as
      // the block's edge passes over it rather than all at once.
      readonly property real outside: Math.max(0, deskDots.markFrom - laneDot.index,
                                               laneDot.index - deskDots.markTo) * deskDots.step
      readonly property real covered: Math.max(0, Math.min(1,
        (deskDots.dot + deskDots.markPad - laneDot.outside) / deskDots.dot))
      function tint(off, on) {
        const c = laneDot.covered
        return Qt.rgba(off.r + (on.r - off.r) * c, off.g + (on.g - off.g) * c,
                       off.b + (on.b - off.b) * c, off.a + (on.a - off.a) * c)
      }
      x: 8 + laneDot.index * deskDots.step + (deskDots.step - width) / 2
      anchors.verticalCenter: parent.verticalCenter
      width: deskDots.dot
      height: deskDots.dot
      radius: deskDots.pill(width / 2)
      color: laneDot.filled ? laneDot.tint(Qt.rgba(1, 1, 1, 0.55), Qt.alpha(deskDots.onMark, 0.85))
                            : "transparent"
      border.width: laneDot.filled ? 0 : 1
      border.color: laneDot.tint(Qt.rgba(1, 1, 1, 0.45), Qt.alpha(deskDots.onMark, 0.75))
    }
  }
}
