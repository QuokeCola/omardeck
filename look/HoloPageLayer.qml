import QtQuick
import QtQuick.Effects
import Quickshell.Hyprland

// The holographic overlay on one screen's page: the wallpaper blurred as the
// desktop blurs it under windows, and over it the same overlay the desktop draws.
// Loaded only while the theme is on.
Item {
  id: page

  // The Surface. Used: overlay monitor reserved glass following monitorName
  // screenInfo spaceHere() width height wallImage wallBlurOutput
  required property var surface
  readonly property var overlay: page.surface.overlay

  // Whether a real workspace has windows.
  function spaceHasWindows(id) {
    const all = Hyprland.toplevels.values
    for (let i = 0; i < all.length; i++) {
      const ipc = all[i].lastIpcObject
      if (ipc && ipc.workspace && ipc.workspace.id === id) return 1
    }
    return 0
  }

  // On with the overview, on an empty desktop too. In a desktop swipe it goes by
  // whether the desktops either side have windows, so it fades on the way into or
  // out of an empty one. Worked out per screen: desktop 3 is workspace 3 on one
  // screen and 13 on another, each with its own windows, and asking about the wrong
  // one blinks the overlay off.
  readonly property real deskLevel: {
    const surface = page.surface
    const overlay = page.overlay
    const here = surface.monitor && surface.monitor.activeWorkspace ? surface.monitor.activeWorkspace.id : -1
    const lanes = overlay.lanes
    if (!surface.following || lanes.length === 0 || overlay.stageIndex < 0)
      return page.spaceHasWindows(here)
    const position = Math.max(0, Math.min(lanes.length - 1, overlay.stageIndex + overlay.shownSlide))
    const i = Math.min(Math.max(0, lanes.length - 2), Math.floor(position))
    const from = page.spaceHasWindows(surface.spaceHere(lanes[i]))
    if (lanes.length === 1) return from
    return from + (page.spaceHasWindows(surface.spaceHere(lanes[i + 1])) - from) * (position - i)
  }
  readonly property real level: Math.max(page.deskLevel, page.overlay.deskSliding ? 0 : page.overlay.veil)

  // Only if the Hyprland blur below is unavailable.
  MultiEffect {
    anchors.fill: parent
    source: page.surface.wallImage
    visible: page.overlay.wallpaper !== "" && page.level > 0.001 && !page.surface.glass
    opacity: page.level
    blurEnabled: true
    blur: 1
    blurMax: 12
    autoPaddingEnabled: false
    layer.enabled: true
  }

  // The picture is the whole screen's, but shown only inside the window area while
  // the overview is barely up, so a desktop swipe leaves the bar uncovered. It opens
  // out to the whole screen as the overview comes in, as the wallpaper does.
  Item {
    id: clipped
    readonly property real out: 1 - page.overlay.veil
    x: page.surface.reserved[0] * out
    y: page.surface.reserved[1] * out
    width: page.surface.width - x - page.surface.reserved[2] * out
    height: page.surface.height - y - page.surface.reserved[3] * out
    clip: true

    Item {
      x: -clipped.x
      y: -clipped.y
      width: page.surface.width
      height: page.surface.height

      // The wallpaper behind the overlay, through the port of Hyprland's own blur
      // with its live settings, so it matches what the desktop shows under windows.
      ShaderEffect {
        anchors.fill: parent
        visible: page.surface.glass && page.level > 0.001
        opacity: page.level
        property var source: page.surface.wallBlurOutput
        property vector4d area: Qt.vector4d(0, 0, 1, 1)
        property vector2d size: Qt.vector2d(width, height)
        property real radius: 0
        property real glass: 0
        property real bezel: 0
        property real refraction: 0
        property real dispersion: 0
        property real specular: 0
        property vector2d lightDir: Qt.vector2d(1, 0)
        property real glassBrightness: 1
        property real saturation: 1
        fragmentShader: Qt.resolvedUrl("../overview/shell/blur/frost.frag.qsb")
      }

      // Keeps the desktop's overlay, showing in the bar's strip, in step with a swipe.
      Loader {
        source: Qt.resolvedUrl("../../quokecola.hud/holo/HoloSwipeLink.qml")
        onLoaded: {
          item.screen = page.surface.monitorName
          item.level = Qt.binding(() => page.overlay.deskSliding ? page.deskLevel : -1)
        }
      }

      // The same overlay the desktop draws under its windows (see quokecola.hud).
      Loader {
        anchors.fill: parent
        visible: page.level > 0.001
        opacity: page.level
        source: Qt.resolvedUrl("../../quokecola.hud/holo/HoloOverlay.qml")
        onLoaded: item.screenInfo = page.surface.screenInfo
      }
    }
  }
}
