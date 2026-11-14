import QtQuick

// Who moves `t`, the whole animation: the fingers, frame by frame, or the spring
// when they lift, a key is pressed or the watchdog fires. The Service forwards all
// of this and owns what is not about `t`. The overlay has a state machine of its
// own for the sideways slide; the two share little and mean different things.
Item {
  id: gesture

  // 0 = closed, 1 = open. Anything between is a swipe in progress.
  property real t: 0

  // How far up the fingers have pulled the closed overview, 0 to 1, or -1
  // when no such swipe is under way; and, as they lift, which way it is
  // headed. For whatever has to make way for it: the notification sheet
  // slides aside under the same fingers.
  property real upFingers: -1
  signal landing(bool opening)

  // True once the user has committed: clicks land, keys are grabbed.
  // With a hysteresis: the spring lands with a bounce, and an overview that
  // dipped to 0.98 on the rebound must not drop the keyboard and grab it
  // again — or swap what three fingers sideways mean — on the way.
  property bool open: false
  onTChanged: {
    if (gesture.t > 0.995) gesture.open = true
    else if (gesture.t < 0.9) gesture.open = false
  }

  // Where the fingers have put the overview, which `t` chases. Decisions —
  // open or not, when they lift — are made on this, not on the spring lagging
  // behind it.
  property real goal: 0

  // Which gesture currently owns `t`: "", "up", "down", "allup" or "alldown".
  property string scrub: ""
  // Three fingers shows this workspace; four shows every window there is.
  property bool everything: false
  // Where `t` was when the fingers landed, so a gesture continues from what is
  // on screen instead of snapping to an end first.
  property real scrubFrom: 0

  // About to leave zero, on a frame where nothing is moving yet. Handled
  // synchronously: the overlay's snapshot, then the fresh answers, come before
  // anything else here runs.
  signal armRequested()

  function show() {
    gesture.armRequested()
    // Let the answers arrive before the thumbnails start flying, or they fly
    // from nowhere. Short enough to be invisible, long enough for one round
    // trip; the gesture skips it because at the start of a swipe the
    // thumbnails are still sitting exactly on top of their windows.
    settle.restart()
  }

  Timer {
    id: settle
    interval: 70
    onTriggered: gesture.glideTo(true, undefined, true)
  }

  function hide() {
    settle.stop()
    gesture.scrub = ""
    gesture.glideTo(false, undefined, true)
  }

  // Past fully open the overview keeps going with the fingers — the cards go
  // on shrinking toward the strip — but gives less and less for each
  // centimetre, the way a scroll view does past its end, and springs back to
  // its proper size when they lift. Starts out one-to-one, so there is no
  // point where it visibly catches; `stretch` is how far it could ever get.
  readonly property real stretch: 0.3
  function rubber(value) {
    if (value <= 1) return value
    const over = value - 1
    return 1 + gesture.stretch * (1 - 1 / (1 + over / gesture.stretch))
  }

  function toggle() { gesture.goal > 0.5 ? gesture.hide() : gesture.show() }

  // The fastest the overview follows the fingers, in `t` a second: a full
  // open in an eighth of a second. See Spring.chase.
  readonly property real chaseSpeed: 8

  // How it lands once the fingers lift: back from a stretch, or the rest of
  // the way open or closed.
  readonly property real landStiffness: 56
  readonly property real landDamping: 2.0

  // How it opens and closes with no fingers involved. The landing spring reaches full
  // speed in a few milliseconds, which is right for a window already moving under the
  // fingers. From a standstill that spends a fifth of the way in one 60 Hz frame, a jump
  // wherever windows travel far. This one gathers speed first and takes about as long.
  readonly property real startStiffness: 24
  readonly property real startDamping: 1.0

  // Fingers down or the spring still moving: `t` is changing every frame and
  // everything drawn from it must follow it exactly, not ease toward it.
  readonly property bool animating: tSpring.running || gesture.scrub !== ""

  // How fast the fingers were moving `t` when last seen, in `t` per second —
  // measured on what is on screen, stretch and all, so the spring picks up at
  // exactly the speed the overview already had.
  property real handSpeed: 0
  property real lastGoal: 0
  property double lastAt: 0

  function track(goal) {
    const now = Date.now()
    const dt = (now - gesture.lastAt) / 1000
    if (gesture.lastAt > 0 && dt > 0 && dt < 0.1) {
      const v = (goal - gesture.lastGoal) / dt
      // Smoothed over a few events: single samples at 125 a second are noisy.
      gesture.handSpeed = gesture.handSpeed * 0.6 + v * 0.4
    } else {
      gesture.handSpeed = 0
    }
    gesture.lastGoal = goal
    gesture.lastAt = now
  }

  // Head for open or closed. The spring already has whatever speed the
  // fingers gave it, so letting go is only a change of target; `velocity` (in
  // `t` per second) tops that up when the fingers were faster than the spring
  // had caught up to — a flick — and only in the direction it is going.
  function glideTo(wantOpen, velocity, fromRest) {
    const target = wantOpen ? 1 : 0
    gesture.goal = target
    if (!tSpring.running) tSpring.value = gesture.t
    tSpring.stiffness = fromRest ? gesture.startStiffness : gesture.landStiffness
    tSpring.damping = fromRest ? gesture.startDamping : gesture.landDamping
    // Straight on at the speed it had, whichever way that was: flung past
    // open it carries on a little and comes back, let go mid-stretch it
    // eases back from wherever it was heading. Starting from a standstill
    // instead is the stall you feel as lag.
    if (velocity !== undefined) tSpring.velocity = Math.max(-8, Math.min(8, velocity))
    tSpring.follow(target)
  }

  // Fingers down: the overview is theirs, exactly, until they lift.
  function grab() {
    tSpring.hold()
    tSpring.velocity = 0
    gesture.goal = gesture.t
    gesture.handSpeed = 0
    gesture.lastAt = 0
  }

  Spring {
    id: tSpring
    floor: 0
    onValueChanged: gesture.t = tSpring.value
  }

  // A swipe shorter than this cannot open the overview however fast it was:
  // a flick has to be deliberate, not a brush against the pad.
  readonly property real flickFloor: 0.08
  // Travel per millisecond, as the Lua half measures it.
  readonly property real flickSpeed: 2.0

  /** Was that swipe thrown rather than dragged? */
  function flicked(fraction, speed) {
    return speed >= gesture.flickSpeed && fraction >= gesture.flickFloor
  }

  /** One up or down event, as Wire.parse read it. */
  function handle(wire) {
    const { who, phase, value, speed, cancelled } = wire
    const opening = who === "up" || who === "allup"
    const wantsEverything = who === "allup" || who === "alldown"

    switch (phase) {
    case "begin":
      if (opening && gesture.open) {
        // Already open: swiping up again is only the stretch, and springs
        // back. Nothing is re-read, so nothing on screen is rebuilt.
      } else if (opening) {
        gesture.upFingers = 0
        gesture.everything = wantsEverything
        // The snapshot this asks for is what the cards are built from; where
        // each window really is right now arrives a few milliseconds later and
        // the cards follow it, so a window resized since the last event starts
        // the swipe at its true size.
        gesture.armRequested()
      } else {
        // Swiping down puts the overview away from anywhere it is visible,
        // including halfway through opening. On the bare desktop the gesture
        // belongs to whoever else wants it.
        if (gesture.t < 0.05) return
      }
      settle.stop()
      gesture.grab()
      gesture.scrubFrom = gesture.t
      gesture.scrub = who
      break

    case "move":
      if (gesture.scrub !== who) return
      if (opening) {
        // The first full swipe's worth of travel covers whatever was left to
        // open; everything past it is stretch. Already open, it is all stretch.
        const from = gesture.scrubFrom
        const travelled = from >= 0.999 ? 1 + value
                        : value <= 1 ? from + (1 - from) * value
                        : 1 + (value - 1)
        gesture.goal = gesture.rubber(travelled)
        if (gesture.upFingers >= 0) gesture.upFingers = Math.min(1, value)
      } else {
        gesture.goal = gesture.scrubFrom * (1 - Math.min(1, value))
      }
      tSpring.chase(gesture.goal, gesture.chaseSpeed)
      gesture.track(gesture.goal)
      break

    case "end":
      if (gesture.scrub !== who) return
      // Judged on where it ended up, not on the swipe alone, so a gesture that
      // carried on from a half-open overview is measured from what you saw.
      {
        let wantOpen
        if (cancelled) wantOpen = gesture.goal > 0.5
        else if (opening) wantOpen = gesture.goal > 0.5 || gesture.flicked(value, speed)
        else wantOpen = !(gesture.goal < 0.5 || gesture.flicked(value, speed))

        // The speed the overview had on screen as the fingers lifted — none,
        // if they had come to rest first.
        const resting = Date.now() - gesture.lastAt > 80
        // Still catching up with a flick, it goes on at the speed it is
        // actually moving on screen.
        const carry = tSpring.lagging ? tSpring.velocity
                    : (cancelled || resting ? 0 : gesture.handSpeed)
        // Spring running before the fingers are let go of, so nothing ever
        // sees a frame where neither is moving the overview.
        gesture.glideTo(wantOpen, carry)
        if (gesture.upFingers >= 0) {
          gesture.upFingers = -1
          gesture.landing(wantOpen)
        }
      }
      gesture.scrub = ""
      break

    default:
      return
    }

    watchdog.restart()
  }

  // A gesture that stops sending without a lift — a reload mid-swipe, a
  // compositor restart — must not strand the overview at 40%. Hyprland does
  // report the lift, so this is a net and nothing more: at 450ms it was firing
  // during ordinary pauses and snapping the animation out from under the hand.
  Timer {
    id: watchdog
    interval: 1400
    onTriggered: {
      if (gesture.scrub === "") return
      const wasMostlyOpen = gesture.goal > 0.5
      gesture.scrub = ""
      gesture.glideTo(wasMostlyOpen)
      if (gesture.upFingers >= 0) {
        gesture.upFingers = -1
        gesture.landing(wasMostlyOpen)
      }
    }
  }
}
