import QtQuick
import qs.Commons as Commons

// The desktops along the top of the screen, and the ring that marks where you are.
Item {
  id: strip

  required property var surface
  readonly property var overlay: strip.surface.overlay

  width: parent.width
  height: surface.stripHeight
  y: -height * (1 - overlay.veil)
  opacity: overlay.veil

  // The strip is centred, so a desktop added at its end moves every
  // tile half a tile over: started where they were, and eased there.
  transform: Translate { id: stripNudge }
  NumberAnimation { id: nudging; target: stripNudge; property: "x"; to: 0; duration: Commons.Style.duration(320); easing.type: Easing.OutCubic }
  Connections {
    target: overlay
    function onDeskAdded(id, grew) {
      stripNudge.x = grew * (surface.tileWidth + surface.tileGap) / 2
      nudging.restart()
    }
  }

  Repeater {
    model: overlay.workspaces

    delegate: StripTile {
      surface: strip.surface
    }
  }

  // Where you are, as one ring that slides along the strip with your
  // fingers rather than jumping from tile to tile when you let go. On
  // a screen that is not leading, the desktop that screen shows.
  Rectangle {
    readonly property int tile: overlay.workspaces.findIndex(w => w.id === surface.ringWorkspace)
    visible: surface.following ? overlay.stageIndex >= 0 : tile >= 0
    x: surface.following ? surface.tileX(Math.max(0, overlay.laneTile(overlay.stageIndex + overlay.slide)))
                       : surface.tileX(Math.max(0, tile))
    y: surface.tileTop
    width: surface.tileWidth
    height: surface.tileHeight
    radius: surface.rounded(8)
    color: "transparent"
    border.width: 2
    border.color: Commons.Color.accent
    Behavior on x { enabled: !overlay.moving; NumberAnimation { duration: Commons.Style.duration(180); easing.type: Easing.OutCubic } }
  }
}
