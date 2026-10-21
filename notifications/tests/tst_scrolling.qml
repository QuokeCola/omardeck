import QtQuick
import QtTest
import QtQuick.Controls
import "../components"

Item {
  width: 420
  height: 400
  NotificationList {
    id: list
    anchors.fill: parent
    model: 30
    delegate: Item {
      x: 14
      width: list.width - 28
      height: 120
      MouseArea { anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton }
    }
  }
  TestCase {
    name: "NotificationScrolling"
    when: windowShown
    function init() { list.scrollBy(-100000, false); wait(150) }
    function test_cardAndBothGutters() {
      for (var x of [100, 4, 409]) {
        var start = list.contentY
        mouseWheel(list, x, 100, 0, -120, Qt.NoButton)
        wait(160)
        fuzzyCompare(list.contentY - start, list.wheelStep, 1)
      }
    }
    function test_scrollbarAtOuterEdge() {
      var bar = list.ScrollBar.vertical
      compare(bar.x + bar.width, list.width - list.scrollbarInset)
      compare(bar.height, list.height)
      verify(bar.active)
      compare(bar.availableWidth, list.scrollbarWidth)
    }
    function test_fastTicksAccumulate() {
      for (var i = 0; i < 4; i++) mouseWheel(list, 100, 100, 0, -120, Qt.NoButton)
      wait(160)
      fuzzyCompare(list.contentY, list.originY + 4 * list.wheelStep, 1)
    }
    function test_edgesAndPixelMovement() {
      list.scrollBy(-1000, false)
      compare(list.contentY, list.originY)
      list.scrollBy(23, false)
      compare(list.contentY, list.originY + 23)
      list.scrollBy(100000, false)
      compare(list.contentY, list.originY + list.contentHeight - list.height)
      mouseWheel(list, 100, 100, 0, -120, Qt.NoButton)
      wait(160)
      compare(list.contentY, list.originY + list.contentHeight - list.height)
    }
    function test_shortListDoesNotScroll() {
      list.model = 1; wait(100)
      mouseWheel(list, 100, 100, 0, -120, Qt.NoButton)
      wait(160)
      compare(list.contentY, list.originY)
      list.model = 30
    }
  }
}
