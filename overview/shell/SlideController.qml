import QtQuick
import Quickshell
import Quickshell.Hyprland

// Sliding sideways through the desktops: the stage, the lanes, the spring, jumps
// over several, and handing back to the desktop when a slide on it lands.
Scope {
  id: root

  // The overlay this is part of, for what the other parts hold.
  required property var overlay
  property var service: null

  // Three fingers left or right with the overview open slides the whole spread
  // over to the next workspace, and the one after it comes in from the side —
  // following the fingers, so stopping half way shows half of each, and
  // letting go there goes back. The strip's ring slides with it.
  //
  // Nothing is rebuilt to do this. Every workspace's cards already exist and
  // are already laid out in the same area (that is what makes peeking a
  // cross-fade); sliding only moves each one sideways by how many workspaces
  // it is away from the middle of the screen.

  // The workspace the spread is centred on. Set when the overview opens and
  // moved by sliding, rather than read from the compositor, because the
  // compositor only hears about a switch after the slide has shown it.
  property int stageId: -1
  readonly property int stageWorkspace: root.stageId > 0 ? root.stageId : overlay.focusedDesk

  // The workspaces you can slide through: the strip, less the "+" at its end.
  //
  // Only this screen's, as Hyprland's own swipe does: the ones already on it,
  // and the ones that do not exist yet (switching to one makes it here). A
  // workspace on the other screen is not the next desktop here — going to it
  // moves focus to that screen, and the slide on this one snaps back.
  readonly property var lanes: overlay.workspaces
    .filter(w => !w.fresh && (w.monitor === "" || w.monitor === overlay.leadMonitor))
    .map(w => w.id)

  /** Where the strip's ring sits for a position along `lanes`, which can fall
      between two tiles that are not next to each other in the strip. */
  function laneTile(position) {
    const count = root.lanes.length
    if (count === 0) return 0
    const tileOf = id => Math.max(0, overlay.workspaces.findIndex(w => w.id === id))
    if (count === 1) return tileOf(root.lanes[0])
    const i = Math.max(0, Math.min(count - 2, Math.floor(position)))
    const from = tileOf(root.lanes[i])
    const to = tileOf(root.lanes[i + 1])
    return from + (to - from) * (position - i)
  }
  readonly property int stageIndex: root.lanes.indexOf(root.stageWorkspace)

  // How far through the slide, in workspaces: 0.3 is a third of the way to the
  // next one, -1 is all the way to the previous.
  property real slide: 0
  // Fingers down on a slide.
  property bool sliding: false
  // Sliding or settling: the cards must follow `slide` exactly rather than
  // animate toward it.
  readonly property bool moving: root.sliding || slider.running
  // Whether the swipe in progress is one this overview took on.
  property bool sideOwned: false
  property real slideFrom: 0

  /** Where a workspace's spread sits, in screen widths from the middle. */
  function laneOf(workspaceId) {
    const index = root.lanes.indexOf(workspaceId)
    if (index < 0 || root.stageIndex < 0) return 99
    return index - (root.stageIndex + root.shownSlide)
  }

  // Where the slide is drawn: held at nothing until the overview can appear,
  // then let catch up, for the same reason as `t` — on the desktop the fingers
  // are already a fair way across by the time every capture is in.
  readonly property real shownSlide: root.slide * overlay.reveal

  // Sliding is for the one-desktop spread. Every window at once, or a search
  // across every desktop, has nothing to slide between.
  readonly property bool canSlide: (overlay.active || root.deskSliding) && !overlay.everything && overlay.filter === "" && overlay.appOnly === ""
                                   && overlay.dragKey === "" && root.stageIndex >= 0
  // Sliding on the bare desktop, the overview up at no zoom just for it.
  readonly property bool deskSliding: root.service ? root.service.deskSlide : false

  // The desktop slide is over, landed or sprung back: put the overview away,
  // which hands the screen back to the real windows exactly where the cards
  // stand.
  function endDeskSlide() {
    if (!root.service || !root.service.deskSlide) return
    // Not until the compositor is on the desktop the slide landed on, or for a
    // frame the old one shows through as the overview goes.
    if (root.stageId > 0 && !overlay.everyScreenOn(root.stageId)) {
      if (!switchWait.running) switchWait.start()
      return
    }
    switchWait.stop()
    if (overlay.look.handbackDelay > 0) {
      if (!handback.running) handback.start()
      return
    }
    root.service.deskSlide = false
  }
  Timer {
    id: handback
    interval: overlay.look.handbackDelay
    onTriggered: if (root.service && !root.moving) root.service.deskSlide = false
  }

  Connections {
    target: Hyprland
    function onFocusedWorkspaceChanged() { if (switchWait.running) root.endDeskSlide() }
  }

  // However long the compositor takes, not longer than this.
  Timer {
    id: switchWait
    interval: 400
    onTriggered: if (root.service) root.service.deskSlide = false
  }
  Timer {
    interval: 16
    repeat: true
    running: switchWait.running
    onTriggered: {
      Hyprland.refreshMonitors()
      root.endDeskSlide()
    }
  }

  // Past the first or last workspace, and past one workspace per swipe, it
  // gives a little and no more, the way a scroll view does at its ends.
  // The same stretch as swiping up past open: one-to-one at first, then less
  // and less, springing back when the fingers lift.
  readonly property real give: 0.3
  function stretched(over) { return root.give * (1 - 1 / (1 + over / root.give)) }
  function bounded(value) {
    const low = Math.max(-1, -root.stageIndex)
    const high = Math.min(1, root.lanes.length - 1 - root.stageIndex)
    if (value > high) return high + root.stretched(value - high)
    if (value < low) return low - root.stretched(low - value)
    return value
  }

  /** A shortcut asked for the next or previous desktop. */
  function step(by) {
    if (!root.canSlide) {
      root.endDeskSlide()
      return
    }
    root.slideBy(by)
    // Nowhere to go that way: nothing moved, so nothing will land.
    if (!root.moving) root.endDeskSlide()
  }

  function onSide(phase, value, velocity, cancelled) {
    switch (phase) {
    case "begin":
      root.sideOwned = root.canSlide
      if (!root.sideOwned) {
        root.endDeskSlide()
        return
      }
      // Caught mid-settle: finish that slide where it was heading first, so
      // this one starts from a whole workspace.
      if (slider.running) {
        slider.stop()
        root.finishSlide(slider.target)
      }
      overlay.endPeek()
      overlay.prime()
      root.slideFrom = root.slide
      root.slideGoal = root.slide
      root.slideSpeed = 0
      root.slideAt = 0
      slider.hold()
      slider.value = root.slide
      slider.velocity = 0
      root.sliding = true
      sideWatchdog.restart()
      break

    case "move":
      if (!root.sideOwned) return
      root.slideGoal = root.bounded(root.slideFrom + value)
      slider.chase(root.slideGoal, root.chaseSpeed)
      {
        const now = Date.now()
        const dt = (now - root.slideAt) / 1000
        root.slideSpeed = root.slideAt > 0 && dt > 0 && dt < 0.1
          ? root.slideSpeed * 0.6 + 0.4 * (root.slideGoal - root.slideLast) / dt : 0
        root.slideLast = root.slideGoal
        root.slideAt = now
      }
      sideWatchdog.restart()
      break

    case "end":
      if (!root.sideOwned) return
      root.sideOwned = false
      sideWatchdog.stop()
      // The speed the spread had on screen as the fingers lifted, the same
      // as swiping up: none if they had come to rest first.
      //
      // Or the gesture's own measure, if that is faster: it is taken over the
      // last 90ms, where the on-screen speed is smoothed from zero, which on a
      // swipe only a few events long reads a real flick as a slow drag.
      {
        const resting = Date.now() - root.slideAt > 80
        const seen = resting ? 0 : root.slideSpeed
        const measured = resting ? 0 : velocity
        root.releaseSlide(cancelled ? 0 : (Math.abs(measured) > Math.abs(seen) ? measured : seen), cancelled)
      }
      break
    }
  }

  // Past half way it goes on; short of it, a flick in the same direction
  // still does. A flick back the other way always wins.
  // In workspaces per second, so it scales with how far a workspace is.
  readonly property real slideFlick: 1.2
  // The fastest the spread follows the fingers sideways, in workspaces a
  // second: an ordinary swipe is 2 to 5, a flick 30 and more. See
  // Spring.chase.
  readonly property real chaseSpeed: 7
  // Where the fingers have put the slide, and how fast it was moving on
  // screen, in workspaces per second.
  property real slideGoal: 0
  property real slideSpeed: 0
  property real slideLast: 0
  property double slideAt: 0

  function releaseSlide(velocity, cancelled) {
    const at = root.slideGoal
    let to = 0
    if (!cancelled) {
      const dir = at !== 0 ? Math.sign(at) : Math.sign(velocity)
      const flung = Math.abs(velocity) > root.slideFlick
      if (flung && Math.sign(velocity) !== dir) to = 0
      else if (Math.abs(at) > 0.5 || (flung && Math.abs(at) > 0.03)) to = dir
    }
    // A jump goes all the way, through the desktops in between.
    if (root.jumpTo !== 0 && !cancelled) to = root.jumpTo
    root.jumpTo = 0
    const next = root.stageIndex + to
    if (next < 0 || next >= root.lanes.length) to = 0

    // Let go, the spring loosens and lands with a bounce, keeping the speed
    // it had — topped up by a flick faster than it had caught up to.
    root.slideGoal = to
    if (!slider.running) slider.value = root.slide
    slider.stiffness = 52
    slider.damping = 2.0
    // Still catching up with a flick: on at the speed it is moving.
    slider.velocity = Math.max(-6, Math.min(6, slider.lagging ? slider.velocity : velocity))
    // Running before the fingers are let go of, so the cards never see a
    // frame where neither is moving them.
    slider.follow(to)
    root.sliding = false
  }

  // A jump in progress: how many desktops over to land, and the window to
  // focus when it does (address without 0x).
  property int jumpTo: 0
  property string landOn: ""
  property string pendingJump: ""
  property int pendingDesk: 0
  function followReveal() {
    if (overlay.reveal < 1) return
    if (root.pendingJump !== "") {
      const address = root.pendingJump
      root.pendingJump = ""
      jumpWait.stop()
      root.jumpToWindow(address)
    } else if (root.pendingDesk > 0) {
      const desk = root.pendingDesk
      root.pendingDesk = 0
      jumpWait.stop()
      root.jumpToDesk(desk)
    }
  }
  // Never ready: go there without the slide.
  Timer {
    id: jumpWait
    interval: 500
    onTriggered: {
      if (root.pendingJump !== "") {
        const address = root.pendingJump
        root.pendingJump = ""
        root.endDeskSlide()
        Hyprland.dispatch('hl.dsp.focus({ window = "address:0x' + address + '" })')
      }
      if (root.pendingDesk > 0) {
        const desk = root.pendingDesk
        root.pendingDesk = 0
        root.endDeskSlide()
        root.goStraight(desk)
      }
    }
  }

  /** Slide, however many desktops over, to desktop `desk` (SUPER + number).
      One this screen cannot slide to — not made yet, or the overview showing
      something it cannot slide through — is switched to straight away. */
  function jumpToDesk(desk) {
    if (overlay.reveal < 1) {
      root.pendingDesk = desk
      jumpWait.restart()
      return
    }
    // Mid-landing from the last key: land it first, so the count of desktops
    // to go starts from where the stage really is.
    if (slider.running && !root.sliding) {
      slider.stop()
      root.finishSlide(slider.target)
    }
    const index = root.lanes.indexOf(desk)
    const step = index - root.stageIndex
    if (step === 0 && index >= 0) {
      root.endDeskSlide()
      return
    }
    if (!root.canSlide || root.sliding || index < 0 || root.stageIndex < 0) {
      root.goStraight(desk)
      root.endDeskSlide()
      return
    }
    root.jumpTo = step
    root.slideBy(Math.sign(step))
    if (!root.moving) {
      root.jumpTo = 0
      root.goStraight(desk)
      root.endDeskSlide()
    }
  }

  /** To a desktop with no slide: every screen, or just this one. */
  function goStraight(desk) {
    if (overlay.active) root.stageId = desk
    if (overlay.synced) overlay.switchDesk(desk)
    else Hyprland.dispatch('hl.dsp.focus({ workspace = "' + desk + '" })')
  }

  /** Slide, however many desktops over, to the one a window is on, and land
      on that window. Its own desktop, or one this screen cannot slide to:
      just focus it. */
  function jumpToWindow(address) {
    // Not before the overview is up and matching the desktop: a gesture
    // catches up with the fingers, but a jump started now would have slid a
    // desktop over unseen by the time the captures are in, and open on a cut.
    if (overlay.reveal < 1) {
      root.pendingJump = address
      jumpWait.restart()
      return
    }
    const top = (Hyprland.toplevels.values || []).find(t => t.address === address)
    const ws = top && top.workspace ? top.workspace.id : 0
    const index = ws > 0 ? root.lanes.indexOf(overlay.deskOfId(ws)) : -1
    const step = index - root.stageIndex
    if (!root.canSlide || root.sliding || index < 0 || root.stageIndex < 0 || step === 0) {
      root.endDeskSlide()
      Hyprland.dispatch('hl.dsp.focus({ window = "address:0x' + address + '" })')
      return
    }
    root.landOn = address
    root.jumpTo = step
    root.slideBy(Math.sign(step))
    if (!root.moving) {
      root.jumpTo = 0
      root.landOn = ""
      root.endDeskSlide()
    }
  }

  /** Slide one workspace over from the keyboard. */
  function slideBy(step) {
    if (!root.canSlide || root.sliding) return
    if (slider.running) {
      slider.stop()
      root.finishSlide(slider.target)
    }
    overlay.peek = -1
    root.slideFrom = 0
    // As if the fingers had carried it just past half way: the spring still
    // starts from where the spread is, and does the whole trip itself.
    root.slideGoal = step * 0.51
    root.releaseSlide(step * 4, false)
  }

  // Landed: the neighbour is now the middle. Moving the stage and zeroing the
  // slide leaves every card exactly where it already was.
  function finishSlide(to) {
    if (to !== 0) {
      const next = root.lanes[root.stageIndex + to]
      if (next !== undefined) {
        // Only now, with the slide landed and the overview covering all of
        // it. Told at the lift, the compositor switched at once — and on a
        // short swipe the overview was not up yet, so the desktop simply
        // vanished before the slide it was meant to be hidden behind.
        const address = root.landOn
        if (overlay.synced) overlay.switchDesk(next, address)
        else {
          Hyprland.dispatch('hl.dsp.focus({ workspace = "' + next + '" })')
          if (address !== "") Hyprland.dispatch('hl.dsp.focus({ window = "address:0x' + address + '" })')
        }
        root.stageId = next
        // The selection moves to the desktop you are looking at, so enter
        // goes somewhere on it.
        const active = overlay.shot.find(w => overlay.wsOf(w) === next && w.active)
                    || overlay.shot.find(w => overlay.wsOf(w) === next)
        overlay.selectedKey = active ? active.key : ""
      }
    }
    root.slide = 0
    root.landOn = ""
  }

  Spring {
    id: slider
    onValueChanged: root.slide = slider.value
    // Fingers resting mid-slide let the spring settle too; that is not a
    // landing.
    onSettled: if (!root.sliding) {
      root.finishSlide(slider.target)
      root.endDeskSlide()
    }
  }

  // A lift that never arrives must not leave the spread half way between two
  // desktops.
  Timer {
    id: sideWatchdog
    interval: 1400
    onTriggered: if (root.sliding) {
      root.sideOwned = false
      root.releaseSlide(0, false)
    }
  }

  // The overview has gone: from `forget()`, in this order.
  function reset() {
    slider.stop()
    slider.value = 0
    slider.velocity = 0
    root.slide = 0
    root.slideGoal = 0
    root.sliding = false
    root.sideOwned = false
    root.stageId = -1
  }
}
