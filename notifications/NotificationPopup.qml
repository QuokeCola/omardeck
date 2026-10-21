import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Foamy presentation hooks for the notification center; keep lifecycle fixes in
// sync with the packaged Ui/KeyboardPanel.qml when refreshing this clone.
// Layer-shell popup attached to a bar widget icon, designed for
// click-driven AND keyboard-driven panels (e.g. SUPER+CTRL+W summon).
//
// Built on PanelWindow with a brief WlrKeyboardFocus.Exclusive prime followed
// by OnDemand rather than PopupWindow (xdg-popup). The prime acquires focus
// both when the surface maps and when it reopens while still mapped for its
// fade-out. xdg-popups don't get that — they only receive keys after a
// click/hover routes focus through their parent surface — so keyboard-summoned
// popups fell flat without it.
//
// Exclusive would also grant map-time focus, but it makes Hyprland route
// *every* pointer event to the exclusive surface no matter which output
// the cursor is over, which leaves clicks on any other monitor unable to
// reach the dismissal surfaces below.
//
// API is a subset of Common.PopupCard: anchorItem, owner, bar, open,
// padding, margin, contentWidth/Height, centerOnBar, default contentItem.
// Missing on purpose (for now): triggerMode ("hover"), containsMouse.
//
// Positioning: full-screen layer-shell with the card placed inside at
// `cardOrigin`. We use the bar window's height/width for the perpendicular
// axis (away-from-bar) because mapToItem on the anchor returns
// bar-content-relative coords with internal layout offsets baked in
// (e.g. ~13px from the bar's vertical centering of its widget row). The
// parallel axis (along-the-bar) uses the anchor's content x/y since the
// bar spans full screen on that axis.
//
// Outside-click dismissal: an overlay MouseArea catches clicks, with the
// QsWindow.mask subtracting the bar strip so clicks on the bar still
// reach the bar widgets (activePopout coordinator hands off to another
// popup if the user clicks a different bar icon).
PanelWindow {
  id: root

  required property Item anchorItem
  required property QtObject bar
  property var owner: null
  // Private presentation hooks; retain the upstream focus and dismissal lifecycle.
  property real cornerRadius: Math.min(Style.space(14), Style.cornerRadius)
  property color surfaceColor: Commons.Color.popups.background
  property int margin: Style.gapsOut
  property int padding: Style.spacing.popupPadding
  property int contentWidth: Style.space(280)
  property int contentHeight: Style.space(200)
  property var borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Math.max(1, Style.space(2)))
  property bool centerOnBar: false
  property bool open: false
  property int gap: Style.gapsOut  // distance between bar edge and panel
  property bool popoutSwitching: false
  property bool popoutSwitchClosing: false
  property bool focusPrimed: false

  // Slide the card in instead of fading it: from the right screen edge, or,
  // with slideFrom "top" under a top bar, down out of the bar.
  property bool slideIn: false
  property string slideFrom: "right"
  readonly property bool fromTop: slideIn && slideFrom === "top" && barPos === "top"
  // 0 is off the screen edge, 1 in place. Past 1 the sheet is being pulled
  // further out than it rests (a trackpad overswipe), drawn as a stretch.
  // Driven imperatively rather than bound to `open`, so a trackpad swipe can
  // hold it under the fingers and hand it to a spring when they lift.
  property real slideProgress: 0
  readonly property real slideTarget: open || popoutSwitching ? 1 : 0
  property bool dragging: false
  property bool gestureSettling: false
  // How far the sheet has stepped aside for something drawn over its screen,
  // 0 to 1, on top of wherever `slideProgress` has it. Set by the owner.
  property real yieldTo: 0
  readonly property real shownProgress: slideProgress * (1 - Math.max(0, Math.min(1, yieldTo)))

  Component.onCompleted: slideProgress = slideTarget
  onSlideTargetChanged: {
    if (dragging || gestureSettling) return
    slideSpring.stop()
    slideCurve.stop()
    slideAway.stop()
    // A fading panel swaps instantly when another bar icon takes over; a
    // sliding one always slides, so the one leaving goes back where it came
    // from while the next comes in.
    if (!slideIn) { slideProgress = slideTarget; return }
    slideCurve.to = slideTarget
    slideCurve.duration = open ? 320 : 220
    slideCurve.start()
  }

  NumberAnimation {
    id: slideCurve
    target: root
    property: "slideProgress"
    // cubic-bezier(0.8, 0, 0.2, 1); Qt takes the control points followed
    // by the end point.
    easing.type: Easing.BezierSpline
    easing.bezierCurve: [0.8, 0, 0.2, 1, 1, 1]
    onStopped: root.gestureSettling = false
  }

  // Settling shut after a swipe: the fingers were already moving, so no
  // ease-in, just carry on and slow down.
  NumberAnimation {
    id: slideAway
    target: root
    property: "slideProgress"
    to: 0
    easing.type: Easing.OutCubic
    onStopped: root.gestureSettling = false
  }

  // Settling open after a swipe: a spring, so a sheet let go short of home
  // overshoots a touch and one pulled past it bounces back.
  SpringAnimation {
    id: slideSpring
    target: root
    property: "slideProgress"
    spring: 4.5
    damping: 0.34
    epsilon: 0.0015
    onStopped: root.gestureSettling = false
  }

  // Rubber band: past `1` the sheet follows the fingers with growing
  // resistance and never travels more than `limit` further.
  function rubberBand(p) {
    if (p <= 1) return Math.max(0, p)
    var limit = 0.14
    return 1 + limit * (1 - 1 / ((p - 1) * 0.55 / limit + 1))
  }

  function dragTo(p) {
    slideSpring.stop()
    slideCurve.stop()
    slideAway.stop()
    dragging = true
    slideProgress = rubberBand(p)
  }

  // Fingers lifted. The caller then opens or closes the owner; the animation
  // started here carries the sheet the rest of the way.
  function release(toOpen) {
    dragging = false
    gestureSettling = true
    slideSpring.stop()
    slideCurve.stop()
    slideAway.stop()
    if (toOpen) {
      slideSpring.to = 1
      slideSpring.start()
    } else {
      slideAway.duration = Math.max(120, 260 * Math.min(1, slideProgress))
      slideAway.start()
    }
  }

  // Item that should take keyboard focus once the panel maps. Typically a
  // PanelKeyCatcher inside the panel content. Layer-shell grants focus to the
  // surface during the Exclusive prime, but Qt still needs an active-focus
  // target inside the surface for Keys.onPressed handlers to fire. Schedule
  // the focus through Qt.callLater so it runs after the surface is fully
  // mapped and child items have completed layout.
  property Item focusTarget: null

  default property alias contentItem: contentHolder.children

  readonly property var coordinatorKey: owner || root
  readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null
  readonly property string barPos: bar ? bar.position : "top"

  function close() {
    if (owner && "close" in owner) owner.close()
    else root.open = false
  }

  function beginFocusPrime() {
    if (open && backingWindowVisible) focusPrimeTimer.restart()
  }

  // --- screen + lifetime ---------------------------------------------------

  screen: anchorWindow ? anchorWindow.screen : null
  // Not while it has stepped all the way aside: an open sheet with nothing
  // on screen must not keep a full-screen surface catching the pointer.
  readonly property bool sheetShown: slideIn ? (open || popoutSwitching || slideProgress > 0) && yieldTo < 1
                                           : (open || popoutSwitching || card.opacity > 0)
  // A sliding sheet maps only after its dismissal surface, so it is created
  // after it and stacks above it.
  visible: sheetShown && (!slideIn || dismissSurface.visible)
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore

  // A namespace of its own, for the blur and no-fade rules the plugin
  // registers (see overview/app/gesture.lua).
  WlrLayershell.namespace: "omardeck-panel"
  WlrLayershell.layer: WlrLayer.Overlay
  // Keyboard focus follows `open` (NOT `visible`). The window remains
  // mapped during the fade-out so the opacity animation has something to
  // animate, but keyboard/click ownership must release the moment the
  // logical close fires — otherwise the user is locked out for 140ms.
  //
  // Prime with Exclusive on every open, then settle on OnDemand. Hyprland
  // focuses OnDemand when a surface first maps, but not when an already-mapped
  // fade-out surface changes from None back to OnDemand. Exclusive also takes
  // focus when the previously focused application has constrained the pointer.
  // The brief prime covers both cases; OnDemand then releases compositor-wide
  // pointer hit-testing so clicks can reach the dismissal windows below.
  WlrLayershell.keyboardFocus: open
    ? (focusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive)
    : WlrKeyboardFocus.None

  onBackingWindowVisibleChanged: beginFocusPrime()

  // Full-screen layer-shell. The visible card is positioned inside via
  // `cardOrigin`. The `mask` below makes the bar area click-through (so
  // the user can click another bar icon while the panel is open and the
  // activePopout coordinator swaps to that popup); everywhere else, the
  // overlay catches the click and dismisses via the MouseArea below.
  //
  // A sliding sheet is the exception: the compositor blurs this surface, and
  // re-blurs all of it on every frame the sheet moves, so it spans only the
  // strip down the right edge the sheet can reach, overswipe stretch
  // included. Its input region is the card; everything else on the screen
  // falls through to `dismissSurface` below it, which does the dismissing.
  // Dropping from the bar, the surface instead starts at the bar's lower
  // edge and ends where the card does, so the card comes out from under it.
  anchors {
    top: true
    bottom: !fromTop
    left: !slideIn || fromTop
    right: true
  }
  margins.top: fromTop ? surfaceY : 0
  implicitWidth: slideIn && !fromTop ? stripWidth : screenW
  implicitHeight: fromTop ? Math.max(1, Math.ceil(cardOrigin.y + contentHeight - surfaceY) + 1) : screenH

  // The furthest a sheet is ever drawn past its resting place, with room to
  // spare: the rubber band stops short of 1.14, and the spring overshoots
  // by under 0.05.
  readonly property real maxShownProgress: 1.2
  readonly property int stripWidth: Math.min(screenW, Math.ceil((maxShownProgress - 1) * (screenW - cardOrigin.x) + (screenW - cardOrigin.x)) + 1)
  // Where this surface's left and top edges are on the screen.
  readonly property real surfaceX: slideIn && !fromTop ? screenW - stripWidth : 0
  readonly property real surfaceY: fromTop ? barH : 0

  // Clickable region is the whole screen. Clicks in the bar strip are
  // forwarded to registered bar buttons so switching between panel icons
  // works in one click even when the overlay surface is above the bar.
  readonly property real _barStripSize: {
    if (!bar) return 0
    var actual = (root.barPos === "top" || root.barPos === "bottom") ? root.barH : root.barW
    return Math.max(bar.barSize, actual) + root.gap
  }
  mask: Region {
    x: root.slideIn ? Math.floor(card.x + cardShift.x) : 0
    y: root.slideIn ? Math.floor(card.y + cardShift.y) : 0
    width: root.slideIn ? Math.ceil(card.width) + 1 : root.screenW
    height: root.slideIn ? Math.ceil(card.height) + 1 : root.screenH
  }

  // Track every layout change between the bar's contentItem and the
  // anchor item. `transform` updates whenever any item in that chain
  // moves/resizes, which is what makes the position binding below
  // actually reactive — mapToItem on its own is a one-shot.
  TransformWatcher {
    id: anchorWatcher
    a: anchorWindow ? anchorWindow.contentItem : null
    b: anchorItem
  }

  // Anchor item's position within the bar's content surface. For a
  // full-width top bar, the content x maps directly to screen x; the y
  // returned here has the bar's internal padding baked in (e.g. ~13px
  // from vertical centering of the widget row), which is why `cardOrigin`
  // below uses `barH` for the perpendicular axis instead of this y.
  readonly property point anchorScreenPos: {
    anchorWatcher.transform  // reactive dependency
    if (!anchorItem || !anchorWindow) return Qt.point(0, 0)
    return anchorItem.mapToItem(anchorWindow.contentItem, 0, 0)
  }
  readonly property real anchorW: anchorItem ? anchorItem.width : 0
  readonly property real anchorH: anchorItem ? anchorItem.height : 0
  readonly property real screenW: screen ? screen.width : 0
  readonly property real screenH: screen ? screen.height : 0
  readonly property real availableCardWidth: screenW > 0
    ? Math.max(120, screenW - ((barPos === "left" || barPos === "right") ? barW + gap + margin : margin * 2))
    : 0
  readonly property real availableCardHeight: screenH > 0
    ? Math.max(120, screenH - ((barPos === "top" || barPos === "bottom") ? barH + gap + margin : margin * 2))
    : 0
  readonly property real verticalContentInset: padding * 2 + Border.top(borderSpec) + Border.bottom(borderSpec)

  function fittedContentWidth(width, cap) {
    var desired = Math.max(1, Number(width) || 1)
    var maxWidth = root.availableCardWidth > 0 ? root.availableCardWidth : desired
    if (cap !== undefined && Number(cap) > 0) maxWidth = Math.min(maxWidth, Number(cap))
    return Math.round(Math.min(desired, maxWidth))
  }

  function fittedContentHeight(implicitHeight, cap) {
    var desired = Math.max(root.verticalContentInset, (Number(implicitHeight) || 0) + root.verticalContentInset)
    var maxHeight = root.availableCardHeight > 0 ? root.availableCardHeight : desired
    if (cap !== undefined && Number(cap) > 0) maxHeight = Math.min(maxHeight, Number(cap))
    return Math.round(Math.min(desired, maxHeight))
  }

  function cappedContentHeight(height) {
    var desired = Math.max(root.padding * 2, Number(height) || root.padding * 2)
    var maxHeight = root.availableCardHeight > 0 ? root.availableCardHeight : desired
    return Math.round(Math.min(desired, maxHeight))
  }

  // Desired top-left of the card in screen coordinates. For the
  // perpendicular axis (away-from-bar) we anchor to the bar window's edge
  // directly — not the anchor item's y/x — because mapToItem(barContent)
  // returns coordinates in the bar's content space, which can be offset
  // from the bar surface's screen-anchored corner by internal layout
  // (centering wrappers, padding). The bar's surface IS aligned to its
  // anchored screen edge, so using `barW`/`barH` gives the right edge
  // regardless of how the bar's internal widgets are positioned. For the
  // parallel axis (along the bar) the anchor item's reported position is
  // still consistent with the bar content origin, so it's accurate for
  // centering the card under the icon.
  readonly property real barW: anchorWindow ? anchorWindow.width : screenW
  readonly property real barH: anchorWindow ? anchorWindow.height : 0
  readonly property point cardOrigin: {
    if (!anchorItem || !bar) return Qt.point(margin, margin)
    var x = 0, y = 0
    if (centerOnBar && (barPos === "top" || barPos === "bottom")) {
      x = screenW / 2 - contentWidth / 2
      y = barPos === "bottom" ? screenH - barH - contentHeight - gap : barH + gap
    } else if (centerOnBar) {
      x = barPos === "left" ? barW + gap : screenW - barW - contentWidth - gap
      y = screenH / 2 - contentHeight / 2
    } else if (barPos === "bottom") {
      x = anchorScreenPos.x + anchorW / 2 - contentWidth / 2
      y = screenH - barH - contentHeight - gap
    } else if (barPos === "left") {
      x = barW + gap
      y = anchorScreenPos.y + anchorH / 2 - contentHeight / 2
    } else if (barPos === "right") {
      x = screenW - barW - contentWidth - gap
      y = anchorScreenPos.y + anchorH / 2 - contentHeight / 2
    } else { // "top" (default)
      x = anchorScreenPos.x + anchorW / 2 - contentWidth / 2
      y = barH + gap
    }
    x = Math.max(margin, Math.min(x, screenW - contentWidth - margin))
    y = Math.max(margin, Math.min(y, screenH - contentHeight - margin))
    return Qt.point(Math.round(x), Math.round(y))
  }


  // --- popout coordination (same-bar single-popout model) -----------------

  // Coordinate on `open`, not `visible`. `visible` lags into the fade-out
  // animation, which made ownership transfer to a sibling popup race.
  onOpenChanged: {
    if (open) {
      focusPrimed = false
      beginFocusPrime()
      if (focusTarget) Qt.callLater(function() {
        if (root.open && root.focusTarget) root.focusTarget.forceActiveFocus()
      })
    } else {
      focusPrimeTimer.stop()
      focusPrimed = false
    }
    if (!bar) return
    if (open) {
      popoutSwitchClosing = false
      popoutSwitching = bar.activePopout && bar.activePopout !== coordinatorKey
      bar.requestPopout(coordinatorKey)
      if (popoutSwitching) popoutSwitchTimer.restart()
    } else {
      popoutSwitchClosing = !!(owner && owner.popoutSwitchClosing)
      popoutSwitching = false
      if (bar.activePopout === coordinatorKey) bar.releasePopout(coordinatorKey)
      if (popoutSwitchClosing) closeSwitchTimer.restart()
    }
  }

  Timer {
    id: focusPrimeTimer
    // Leave enough time for multiple Qt/Wayland commit cycles after the
    // backing window becomes visible while keeping the compositor-wide
    // Exclusive phase imperceptibly short. This interval is covered by the
    // immediate hide/re-summon acceptance case.
    interval: 75
    onTriggered: if (root.open) root.focusPrimed = true
  }

  Timer {
    id: popoutSwitchTimer
    interval: 150
    onTriggered: root.popoutSwitching = false
  }

  Timer {
    id: closeSwitchTimer
    interval: 1
    onTriggered: root.popoutSwitchClosing = false
  }

  // --- outside-click dismissal --------------------------------------------

  // Catches clicks anywhere in the clickable region (i.e. everywhere on
  // screen except the bar strip, which is masked out). The card has its
  // own MouseArea below so clicks on it don't bubble up here. Disabled
  // during the fade-out so the dying overlay doesn't swallow clicks that
  // were meant for the apps behind it.
  Component {
    id: dismissAreaComponent
    MouseArea {
      anchors.fill: parent
      enabled: root.open
      acceptedButtons: Qt.AllButtons
      hoverEnabled: true
      property bool hoveringBar: false
      cursorShape: hoveringBar ? Qt.PointingHandCursor : Qt.ArrowCursor

      function inBarRegion(px, py) {
        if (root.barPos === "bottom") return py >= root.screenH - root._barStripSize
        if (root.barPos === "left") return px <= root._barStripSize
        if (root.barPos === "right") return px >= root.screenW - root._barStripSize
        return py <= root._barStripSize
      }

      function barPoint(px, py) {
        if (root.barPos === "bottom") return Qt.point(px, py - (root.screenH - root.barH))
        if (root.barPos === "right") return Qt.point(px - (root.screenW - root.barW), py)
        return Qt.point(px, py)
      }

      function pressTargetAt(px, py) {
        if (!root.anchorWindow || !root.anchorWindow.contentItem || !root.bar || !root.bar.clickTargets) return null
        var p = barPoint(px, py)
        var targets = root.bar.clickTargets
        for (var i = targets.length - 1; i >= 0; i--) {
          var target = targets[i]
          if (!target || !target.triggerPress || target.visible === false || target.opacity === 0 || !target.mapToItem) continue
          if (root.bar.targetBelongsToWindow && !root.bar.targetBelongsToWindow(target, root.anchorWindow)) continue
          var pos = root.anchorWindow.itemPosition(target)
          if (p.x >= pos.x && p.x <= pos.x + target.width && p.y >= pos.y && p.y <= pos.y + target.height) return target
        }
        return null
      }

      function forwardBarClick(px, py, button) {
        if (button !== Qt.LeftButton && button !== Qt.RightButton && button !== Qt.MiddleButton) return false
        var target = pressTargetAt(px, py)
        if (!target) return false
        target.triggerPress(button)
        return true
      }

      onPositionChanged: function(mouse) { hoveringBar = inBarRegion(mouse.x, mouse.y) }
      onExited: hoveringBar = false
      onClicked: function(mouse) {
        // While Exclusive is priming, Hyprland may route a click from another
        // output here with translated coordinates. Never interpret that as a
        // click on this output's bar.
        if (root.focusPrimed && inBarRegion(mouse.x, mouse.y) && forwardBarClick(mouse.x, mouse.y, mouse.button)) return
        root.close()
      }
    }
  }

  // For a sliding sheet, the dismissal area lives on a surface of its own:
  // full-screen, transparent and not blurred, so the sheet's own surface can
  // stay a strip. It sits on the sheet's output just below the sheet and
  // catches everything outside the card, bar strip included. It maps with
  // the sheet and catches the pointer for as long as the sheet is on screen,
  // as the full-screen sheet did.
  PanelWindow {
    id: dismissSurface
    screen: root.screen
    visible: root.slideIn && root.sheetShown
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore

    WlrLayershell.namespace: "omarchy-keyboard-panel-dismiss"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    anchors {
      top: true
      bottom: true
      left: true
      right: true
    }

    mask: Region {
      width: root.screenW
      height: root.screenH
    }

    Loader {
      anchors.fill: parent
      active: root.slideIn
      sourceComponent: dismissAreaComponent
    }
  }

  Loader {
    // A popup that is not a sheet keeps catching outside clicks itself.
    anchors.fill: parent
    active: !root.slideIn
    sourceComponent: dismissAreaComponent
  }

  // The panel surface only spans the anchor's screen, and the compositor
  // hit-tests pointer input per output, so the dismissal area above can never see
  // a click on another monitor. Give every other output a transparent twin
  // whose only job is to catch that click. They exist only while the panel is
  // logically open (not during the fade-out, matching `dismissArea.enabled`).
  //
  // Keyboard focus is None: these must catch the pointer without taking focus
  // from the panel when the cursor merely crosses onto their output.
  Variants {
    model: root.open ? Quickshell.screens : []

    delegate: Component {
      PanelWindow {
        required property var modelData

        screen: modelData
        // Compare by output name: the anchor screen must be known before any
        // twin maps, or a twin would cover the panel's own output.
        visible: root.open && !!root.screen && modelData.name !== root.screen.name
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore

        WlrLayershell.namespace: "omarchy-keyboard-panel-dismiss"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors {
          top: true
          bottom: true
          left: true
          right: true
        }

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.AllButtons
          onPressed: root.close()
        }
      }
    }
  }

  // --- card ----------------------------------------------------------------

  BorderSurface {
    id: card
    x: root.cardOrigin.x - root.surfaceX
    y: root.cardOrigin.y - root.surfaceY
    // An overswipe stretches the sheet leftward instead of lifting it off the
    // screen edge: the card grows by the overshoot and the content keeps its
    // width, pinned to the leading edge.
    readonly property real stretch: root.slideIn && !root.fromTop ? Math.max(0, root.shownProgress - 1) * (root.screenW - root.cardOrigin.x) : 0
    width: root.contentWidth + stretch
    height: root.contentHeight
    color: root.surfaceColor
    borderSpec: root.borderSpec
    padding: root.padding
    radius: root.cornerRadius
    opacity: root.slideIn || root.open || root.popoutSwitching ? 1.0 : 0
    transform: Translate {
      id: cardShift
      x: root.slideIn && !root.fromTop ? (1 - Math.min(1, root.shownProgress)) * (root.screenW - root.cardOrigin.x) - card.stretch : 0
      // Up under the bar, all of it, when shut.
      y: root.fromTop ? -(1 - Math.min(1, root.shownProgress)) * (card.y + card.height) : 0
    }

    Behavior on opacity {
      enabled: !root.slideIn && !root.popoutSwitching && !root.popoutSwitchClosing
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    // Swallow clicks on the card so they don't bubble to the dismissal
    // MouseArea behind us.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
    }

    Item {
      id: contentHolder
      anchors.fill: parent
      anchors.topMargin: card.contentTopInset
      anchors.rightMargin: card.contentRightInset + card.stretch
      anchors.bottomMargin: card.contentBottomInset
      anchors.leftMargin: card.contentLeftInset
      opacity: root.popoutSwitching ? (root.open ? 1.0 : 0) : 1.0

      Behavior on opacity {
        enabled: root.popoutSwitching
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
      }
    }
  }
}
