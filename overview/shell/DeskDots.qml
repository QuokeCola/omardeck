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

  Rectangle {
    anchors.fill: parent
    radius: surface.rounded(height / 2)
    color: Qt.rgba(0.04, 0.04, 0.05, 0.72)
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.14)
  }

  Repeater {
    model: deskDots.lanes
    delegate: Rectangle {
      id: laneDot
      required property var modelData
      required property int index
      readonly property bool filled: surface.monitorWindows.some(w => overlay.wsOf(w) === laneDot.modelData)
      x: 8 + laneDot.index * deskDots.step + (deskDots.step - width) / 2
      anchors.verticalCenter: parent.verticalCenter
      width: deskDots.dot
      height: deskDots.dot
      radius: surface.rounded(width / 2)
      color: laneDot.filled ? Qt.rgba(1, 1, 1, 0.55) : "transparent"
      border.width: laneDot.filled ? 0 : 1
      border.color: Qt.rgba(1, 1, 1, 0.45)
    }
  }

  // The mark, between two dots while the fingers are.
  Rectangle {
    x: 8 + deskDots.position * deskDots.step + (deskDots.step - width) / 2
    anchors.verticalCenter: parent.verticalCenter
    width: deskDots.dot + 6
    height: deskDots.dot + 6
    radius: surface.rounded(width / 2)
    color: "transparent"
    border.width: 2
    border.color: Commons.Color.accent
  }
}
