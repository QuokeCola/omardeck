import QtQuick

// The blurs the cards are frosted with, all of them for one screen. Nothing here
// reaches the screen but through a card sampling an output (see HyprBlur.qml).
Item {
  id: blurs

  required property var surface
  readonly property var overlay: blurs.surface.overlay
  // The desktop and the strip.
  required property Item sourceBase
  // Those and the tiled windows' cards: what the first floating window has behind it.
  required property Item sourceLower

  readonly property alias wallOutput: wallBlur.output
  readonly property alias baseOutput: baseBlur.output

  /** The blur behind a floating window: its level's. */
  function floatBlurFor(key) {
    const at = blurs.surface.floatStack.indexOf(key)
    const level = at >= 0 ? floatLevels.itemAt(at) : null
    return level ? level.output : wallBlur.output
  }

  // Behind a tiled window, as the compositor has it: the wallpaper. Which
  // does not change while the overview is up, so this is blurred once as it
  // opens rather than on every frame of the swipe — the strip sliding in and
  // the bar fading made `base` new each frame, and the whole chain ran again
  // for a picture no card at rest is ever over.
  Item {
    id: backdrop
    anchors.fill: parent

    Image {
      anchors.fill: parent
      source: overlay.wallpaperUrl
      visible: overlay.wallpaper !== ""
      fillMode: surface.wallImage.fillMode
      sourceSize: surface.wallImage.sourceSize
      smooth: true
      asynchronous: true
      cache: true
    }
  }

  HyprBlur {
    id: wallBlur
    anchors.fill: parent
    sourceItem: backdrop
    hideSource: true
    live: surface.glass && overlay.opened
    pixelSize: baseBlur.pixelSize
    size: baseBlur.size
    passes: baseBlur.passes
    noise: baseBlur.noise
    contrast: baseBlur.contrast
    brightness: baseBlur.brightness
    vibrancy: baseBlur.vibrancy
    vibrancyDarkness: baseBlur.vibrancyDarkness
  }

  // The desktop and the strip, live: what a window carried over the strip
  // has behind it. Only while one is.
  HyprBlur {
    id: baseBlur
    anchors.fill: parent
    sourceItem: blurs.sourceBase
    live: surface.glass && overlay.opened && surface.overStrip
    pixelSize: Qt.size(Math.round(surface.width * surface.hyprScale), Math.round(surface.height * surface.hyprScale))
    // Hyprland's blur size as configured. Checked against screenshots of
    // Hyprland frosting a see-through terminal over a static page: with the
    // blur run at the monitor's own scale (see `hyprScale`) the port matches
    // best with no correction at all.
    size: overlay.deco.blurSize
    passes: overlay.deco.blurPasses
    noise: overlay.deco.blurNoise
    contrast: overlay.deco.blurContrast
    brightness: overlay.deco.blurBrightness
    vibrancy: overlay.deco.blurVibrancy
    vibrancyDarkness: overlay.deco.blurVibrancyDarkness
  }

  // Behind each floating window: everything below it — the desktop, the
  // tiled windows, and the floating windows under it — the way Hyprland
  // blurs a see-through window with xray off. One level per floating window
  // on screen, bottom to top: each level's blur reads the level below's
  // `stack`, which is that level's picture plus its own window, drawn as the
  // card is. Nothing runs when no floating window is on screen.
  Repeater {
    id: floatLevels
    model: surface.glass ? surface.floatStack : []

    delegate: Item {
      id: level
      required property string modelData
      required property int index
      anchors.fill: parent

      readonly property Item below: {
        if (level.index === 0) return blurs.sourceLower
        const under = floatLevels.itemAt(level.index - 1)
        return under ? under.stack : blurs.sourceLower
      }
      readonly property Item cardItem: surface.floatCardFor(level.modelData)
      readonly property Item output: levelBlur.output
      readonly property alias stack: stack

      // What the next window up has behind it: this level's picture, and
      // this window over it — border and shadow too, hence the margin.
      Item {
        id: stack
        width: surface.width
        height: surface.height
        visible: false

        ShaderEffectSource {
          anchors.fill: parent
          sourceItem: level.below
          live: true
        }

        ShaderEffectSource {
          readonly property real margin: 24
          visible: level.cardItem !== null
          sourceItem: level.cardItem
          x: level.cardItem ? level.cardItem.x - margin : 0
          y: level.cardItem ? level.cardItem.y - margin : 0
          width: level.cardItem ? level.cardItem.width + 2 * margin : 0
          height: level.cardItem ? level.cardItem.height + 2 * margin : 0
          sourceRect: level.cardItem ? Qt.rect(-margin, -margin, level.cardItem.width + 2 * margin,
                                               level.cardItem.height + 2 * margin) : Qt.rect(0, 0, 0, 0)
          opacity: level.cardItem ? level.cardItem.opacity : 0
          live: true
        }
      }

      HyprBlur {
        id: levelBlur
        anchors.fill: parent
        sourceItem: level.below
        live: surface.glass && overlay.opened
        pixelSize: baseBlur.pixelSize
        size: baseBlur.size
        passes: baseBlur.passes
        noise: baseBlur.noise
        contrast: baseBlur.contrast
        brightness: baseBlur.brightness
        vibrancy: baseBlur.vibrancy
        vibrancyDarkness: baseBlur.vibrancyDarkness
      }
    }
  }
}
