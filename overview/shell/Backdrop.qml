import QtQuick

// The desktop goes away: the windows you are about to see spread out are
// still sitting there underneath, and two of everything reads as a mess.
//
// So from the very first frame the part of the screen windows live in is
// painted over with the wallpaper exactly as the desktop draws it — same
// image, same crop — and the cards, standing exactly where their windows
// are and dressed the way Hyprland dresses them, take the windows' place.
// Nothing fades: the desktop you were looking at simply becomes the
// overview, and only then starts to move. The bar's strip is left to fade,
// since there is no card standing in for the bar.
//
// Then the blur comes in over it. Loaded at the screen's real resolution
// and blurred properly, into a layer drawn once, since the wallpaper does
// not change while the overview is open.
Item {
  id: wallpaper

  required property var surface
  readonly property var overlay: wallpaper.surface.overlay
  // For what is drawn from the same picture elsewhere.
  readonly property alias wall: wall
  // Decoded, and on screen where the windows are.
  readonly property bool ready: solid.status === Image.Ready

  anchors.fill: parent
  visible: overlay.wallpaper !== ""

  // One image, decoded once: the three below share it through the image
  // cache, since source and size are the same.
  Image {
    id: wall
    anchors.fill: parent
    visible: false
    source: overlay.wallpaperUrl
    fillMode: Image.PreserveAspectCrop
    // From the screen, not the surface: a hidden surface is no size at
    // all, and a size that changes each time the overview opens throws
    // the decoded wallpaper away and decodes it again, every time.
    sourceSize.width: Math.ceil((surface.screenInfo ? surface.screenInfo.width : surface.width) * surface.pixelRatio)
    sourceSize.height: Math.ceil((surface.screenInfo ? surface.screenInfo.height : surface.height) * surface.pixelRatio)
    smooth: true
    asynchronous: true
    cache: true
  }

  // The whole screen, bar strip included, fading with the swipe.
  Image {
    anchors.fill: parent
    source: wall.source
    opacity: overlay.veil
    fillMode: wall.fillMode
    sourceSize: wall.sourceSize
    smooth: true
    asynchronous: true
    cache: true
  }

  // Where the windows are: solid from the first frame, as soon as every
  // card is ready to stand in for its window.
  Item {
    id: workArea
    x: surface.reserved[0]
    y: surface.reserved[1]
    width: surface.width - surface.reserved[0] - surface.reserved[2]
    height: surface.height - surface.reserved[1] - surface.reserved[3]
    clip: true
    opacity: overlay.opened && surface.captured && solid.status === Image.Ready ? 1 : overlay.veil

    Image {
      id: solid
      x: -workArea.x
      y: -workArea.y
      width: surface.width
      height: surface.height
      source: wall.source
      fillMode: wall.fillMode
      sourceSize: wall.sourceSize
      smooth: true
      asynchronous: true
      cache: true
    }
  }
}
