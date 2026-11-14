import QtQuick
import Quickshell

// When the cards refresh their captures: a beat they all share.
Scope {
  id: root

  // The overlay this is part of, for what the other parts hold.
  required property var overlay

  // Every thumbnail refreshes off this one clock rather than running live.
  // Twelve frames a second is plenty to recognise a window by, and it is what
  // keeps the overview at a few percent of a core instead of half of one.
  property int beat: 0

  // A beat that also reaches the desktops either side of this one, as a slide
  // begins: they come into view a moment later, and a card still showing what
  // its window looked like last time is a window that visibly jumps.
  property bool priming: false
  function prime() {
    root.priming = overlay.deskSliding || overlay.active
    root.beat++
    root.priming = false
  }

  // And not at all while the overview is moving. Every capture that lands is
  // a texture upload and a redraw of everything over it, frosted glass
  // included, on frames that are already the busiest there are; a window
  // playing video in the middle of a swipe was paying for both. Nobody reads
  // a thumbnail in flight, so while the fingers are down or a spring is
  // settling the cards hold their frame, and catch up the moment it lands.
  readonly property bool still: overlay.opened && !overlay.settling && !overlay.moving && !overlay.deskSliding

  Timer {
    interval: 80
    repeat: true
    running: root.still
    onTriggered: root.beat++
  }

  onStillChanged: if (root.still) root.beat++

  // One fresh frame on the way home, though: a closing card hands over to its
  // window in the next few frames, and one a whole swipe stale would show
  // the window jump to the present as it did. Asked for once, as it nears.
  property bool nearHome: false
  property real lastT: 0
  function followT() {
    const near = overlay.opened && overlay.t < 0.2 && overlay.t < root.lastT
    if (near && !root.nearHome) root.beat++
    root.nearHome = near
    root.lastT = overlay.t
  }
}
