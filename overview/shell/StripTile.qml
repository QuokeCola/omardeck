import QtQuick
import Quickshell.Widgets
import qs.Commons

// One desktop in the strip.
Item {
  id: space

  required property var surface
  readonly property var overlay: space.surface.overlay
  required property var modelData
  required property int index
  // The desktop the spread is showing, which sliding moves before the
  // compositor has caught up.
  readonly property bool focused: space.modelData.id === surface.ringWorkspace
  // On the screen the window is over: every screen has a tile for
  // each desktop.
  readonly property bool targeted: overlay.dragTarget === space.modelData.id
                                   && overlay.dragScreen === surface.monitorName
  readonly property bool peeked: overlay.peek === space.modelData.id
  // Live, so a window dropped here shows up where Hyprland actually
  // puts it, and the others make room.
  readonly property var plan: overlay.livePlans[surface.spaceHere(space.modelData.id)] || []

  x: surface.tileX(space.index)
  y: surface.tileTop
  width: surface.tileWidth
  height: surface.tileHeight

  scale: space.targeted ? 1.12 : (space.peeked ? 1.06 : 1)
  Behavior on scale { NumberAnimation { duration: Style.duration(130); easing.type: Easing.OutCubic } }

  // A desktop just added from "+" drops in from above the strip,
  // and the next "+" fades in behind it.
  transform: Translate { id: dropOffset }
  SequentialAnimation {
    id: dropIn
    ParallelAnimation {
      NumberAnimation { target: dropOffset; property: "y"; from: -(surface.tileTop + surface.tileHeight); to: 0; duration: Style.duration(420); easing.type: Easing.OutBack; easing.overshoot: 1.2 }
      NumberAnimation { target: space; property: "opacity"; from: 0; to: 1; duration: Style.duration(220) }
    }
  }
  SequentialAnimation {
    id: fadeIn
    PropertyAction { target: space; property: "opacity"; value: 0 }
    PauseAnimation { duration: Style.duration(180) }
    NumberAnimation { target: space; property: "opacity"; to: 1; duration: Style.duration(240) }
  }
  Component.onCompleted: {
    if (overlay.justAdded <= 0) return
    if (space.modelData.id === overlay.justAdded) dropIn.start()
    else if (space.modelData.fresh) fadeIn.start()
  }

  ClippingRectangle {
    id: tile
    anchors.fill: parent
    radius: surface.rounded(8)
    color: overlay.look.base("#0B0B0E")

    // Each desktop is a small picture of the desktop: the same
    // wallpaper, with a block where each window sits.
    Image {
      anchors.fill: parent
      source: overlay.wallpaperUrl
      visible: overlay.wallpaper !== ""
      fillMode: Image.PreserveAspectCrop
      sourceSize.width: Math.ceil(surface.tileWidth * surface.pixelRatio * 1.5)
      smooth: true
      asynchronous: true
      cache: true
      opacity: overlay.look.tileWall(space.focused || space.peeked ? 0.85 : 0.5, space.modelData.fresh)
    }

    Rectangle {
      anchors.fill: parent
      color: space.targeted ? Qt.rgba(1, 1, 1, 0.16) : "transparent"
    }

    Repeater {
      model: space.plan

      delegate: Rectangle {
        id: mini
        // Its card is standing here itself, live.
        visible: !overlay.flown[mini.modelData.key]
        required property var modelData
        x: mini.modelData.x * tile.width
        y: mini.modelData.y * tile.height
        width: Math.max(3, mini.modelData.w * tile.width)
        height: Math.max(3, mini.modelData.h * tile.height)
        radius: surface.rounded(3)
        // Dark enough to read as a window against any wallpaper, rather
        // than a grey square that could be anything.
        color: mini.modelData.active ? Qt.rgba(0.10, 0.10, 0.13, 0.94)
                                     : Qt.rgba(0.07, 0.07, 0.09, 0.84)
        border.width: 1
        border.color: mini.modelData.active ? Qt.rgba(1, 1, 1, 0.34)
                                            : Qt.rgba(1, 1, 1, 0.16)

        IconImage {
          anchors.centerIn: parent
          implicitSize: Math.round(Math.min(18, Math.min(mini.width, mini.height) * 0.62))
          source: overlay.iconFor(mini.modelData.appId)
          visible: source !== "" && mini.width > 16 && mini.height > 14
          opacity: space.focused || space.peeked ? 0.95 : 0.7
        }
      }
    }

    // An untouched workspace says so, instead of looking broken — and
    // the one past the end offers itself.
    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      visible: space.plan.length === 0
      text: space.modelData.fresh ? "\u002b" : "empty"
      // The current tile shows more wallpaper, so it needs the stronger ink to read.
      readonly property color quiet: Qt.rgba(1, 1, 1, space.modelData.fresh ? 0.5 : 0.34)
      color: space.focused ? overlay.look.ink(quiet) : overlay.look.dim(quiet)
      font.family: Style.font.family
      font.pixelSize: space.modelData.fresh
                      ? Math.round(Style.font.body * 1.6) : overlay.look.legible(Style.font.caption)
    }
  }

  Rectangle {
    anchors.fill: parent
    radius: tile.radius
    color: "transparent"
    // The accent ring for the current desktop is drawn once, below,
    // so it can travel between tiles as you slide.
    border.width: space.targeted || space.peeked ? 2 : 1
    border.color: space.targeted ? overlay.look.ink("#F2EFE7")
                : space.peeked ? Qt.rgba(1, 1, 1, 0.5)
                : Qt.rgba(1, 1, 1, 0.14)
  }

  Text {
    // A desktop's name is whatever the config called it.
    textFormat: Text.PlainText
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.bottom
    anchors.topMargin: 6
    text: space.modelData.name
    color: space.focused ? overlay.look.ink("#F2EFE7") : overlay.look.dim("#8D8880")
    font.family: Style.font.family
    font.pixelSize: overlay.look.primaryText(Style.font.caption)
    font.weight: space.focused ? Font.DemiBold : Font.Normal
  }

  HoverHandler {
    enabled: overlay.active && !overlay.everything
    cursorShape: Qt.PointingHandCursor
    onHoveredChanged: overlay.hoverWorkspace(space.modelData.id, hovered)
  }

  TapHandler {
    enabled: overlay.active
    onTapped: overlay.goToWorkspace(space.modelData.id, surface.monitorName)
  }
}
