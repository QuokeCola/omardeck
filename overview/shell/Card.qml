import QtQuick
import qs.Commons as Commons
import "../../look" as Looks

// One window's card. All of its motion lives here: where it stands, blended with
// where it goes, and where it flies when dropped on another desktop.
//
// `waiting`, `shown` and `stacked` stay on this root: the surface's `captured` and
// `floatStack` read them through Repeater.itemAt, which does not notify, and depend
// on those being captured as they are read.
Item {
  id: card

  required property var surface
  readonly property var overlay: card.surface.overlay
  required property var modelData
  // Where the window really is right now, which can be fresher than the
  // snapshot the card was built from.
  readonly property var real: overlay.geo[card.modelData.key] || card.modelData
  readonly property bool focusedWindow: card.real.active === true
  // Which layer it is in: floating over tiled, as Hyprland stacks them,
  // so each card's blur has the right things behind it.
  readonly property bool floating: card.modelData.floating === true
  // Whether the window has a panel of its own on the desktop. A maximized or fullscreen
  // one doesn't, so giving its card one would change its tone as the overview opens.
  readonly property bool ownPanel: card.floating && card.modelData.fullscreen !== true
  // Hidden on the desktop, under a maximized window (see `under` in
  // WindowSnapshot.qml): its card comes in as the cards spread, and goes as they
  // close, rather than standing whole where no window shows.
  readonly property bool under: card.real.under === true
  readonly property real reveal: card.under ? Math.min(1, card.along * 2.5) : 1
  // Standing in for a window that is actually on this screen right now.
  // A scrolling layout keeps windows parked off either edge; those
  // cover nothing, and some never produce a frame to wait for.
  readonly property bool onScreen: card.shown
                                   && card.real.x < surface.width && card.real.x + card.real.w > 0
                                   && card.real.y < surface.height && card.real.y + card.real.h > 0
  // Shown, but nothing captured to show yet.
  readonly property bool waiting: card.onScreen && !shot.hasContent && !surface.missed[card.modelData.key]
  readonly property var slot: surface.slots[card.modelData.key] || null
  // On the desktop being shown, which peeking changes without rebuilding
  // anything: the card is already here, it just fades in.
  readonly property bool here: overlay.everything || surface.searching
                               || (surface.sliding ? Math.abs(card.lane) < 1
                                                   : overlay.wsOf(card.modelData) === surface.shownWorkspace)
  // How many screens over this card's desktop is while sliding.
  readonly property real lane: surface.following ? overlay.laneOf(overlay.wsOf(card.modelData)) : 0
  readonly property real shift: surface.sliding && card.tracking ? card.lane * surface.width : 0
  // The card stands in a page of its own, the size of the screen, which is what
  // slides and what it is cut to (see `cardDelegate` in SurfaceStage.qml): a
  // window that hangs off the edge of its desktop is off screen there, and has
  // no business over the desktop sliding in beside it. `carried` is how far the
  // page has taken it, which its own `x` then leaves out. Picked up or thrown, it
  // is anywhere on the screen and the page stays put.
  readonly property real carried: card.dragging || card.flying ? 0 : card.shift
  // Where it is on the screen, page and all: `x` is within the page.
  readonly property real stageX: card.x + card.carried
  // Searching or showing one app's windows, cards from every desktop
  // share the spread, but closing lands on one desktop. The others leave
  // toward their own desktop's side as the overview closes (and come in
  // from it as it opens) instead of flying home over the wrong desktop.
  // In screen widths: one screen off the side its desktop is on (enough
  // to be fully out of view when closed), a little further for each
  // desktop further away, so two desktops' windows don't arrive as one
  // clump yet are in view for most of the move. One not on this
  // screen's strip stays put.
  readonly property real awayLane: surface.searching && surface.following
                                   && Math.abs(card.lane) >= 0.5 && Math.abs(card.lane) < 10
                                   ? Math.sign(card.lane) * (0.85 + 0.15 * Math.min(3, Math.abs(card.lane))) : 0
  readonly property bool shown: card.here && overlay.matches(card.modelData)
  // Opened on one app: the other windows of the desktop you are on fade
  // out where they stand as the overview opens (and back in if it closes
  // onto this desktop), rather than vanishing the moment it starts.
  // Likewise the ones a search left out: closing onto their desktop,
  // they fade back in with `t` rather than popping in whole once the
  // overview has gone.
  readonly property bool fading: !card.shown && surface.searching
                                 && overlay.wsOf(card.modelData) === surface.shownWorkspace
  // Still one of the floating windows on screen, as the blur and the stacking
  // see it: shown, or left out by a search or an app's overview and not yet
  // faded away. A card dropped from the stack the moment it was left out fell
  // under every other floating card, so it vanished at once wherever one
  // covered it, and the see-through cards over it stopped blurring it. A
  // property of its own, read by `floatStack`: `opacity` changes every frame of
  // the fade, and a stack rebuilt every frame rebuilds every blur with it.
  readonly property bool stacked: card.shown || (card.fading && card.opacity > 0.01)
  readonly property bool hovered: hover.hovered && overlay.active
  readonly property bool picked: card.hovered || overlay.selectedKey === card.modelData.key
  readonly property bool dragging: dragger.active
  readonly property bool landing: overlay.dropOnKey === card.modelData.key
  // Let go on another screen, and gone there: hidden here until the
  // card on that screen takes over and this one is taken away.
  property bool handedOver: false
  // Carried here from another screen: hidden until it has a frame, with
  // the stand-in (`visitor`) showing where it was let go meanwhile.
  readonly property bool awaited: overlay.arrival !== null && overlay.arrival.key === card.modelData.key
                                  && overlay.arrival.screen === surface.monitorName
  // Where it is as held, scaled about its middle, in layout coordinates:
  // where the other screens draw it.
  readonly property rect heldRect: {
    if (!card.dragging) return Qt.rect(0, 0, 0, 0)
    const w = card.width * card.scale
    const h = card.height * card.scale
    const ox = surface.monitor ? surface.monitor.x : 0
    const oy = surface.monitor ? surface.monitor.y : 0
    return Qt.rect(ox + card.stageX + (card.width - w) / 2, oy + card.y + (card.height - h) / 2, w, h)
  }
  onHeldRectChanged: if (card.dragging) overlay.dragRect = card.heldRect

  /** Carried here from another screen and let go: from where it was let
      go, into its place here — its slot, or its desktop's tile. */
  function arrive() {
    const r = overlay.arrival.rect
    const ox = surface.monitor ? surface.monitor.x : 0
    const oy = surface.monitor ? surface.monitor.y : 0
    const from = Qt.rect(r.x - ox, r.y - oy, r.width, r.height)
    if (card.here) {
      card.backFrom = from
      card.back = 0
      comingBack.restart()
    } else {
      card.flyFrom = from
      card.released = true
      card.leftAway = true
      card.fly = 0
      flight.restart()
    }
    card.tookOver = true
    overlay.arrival = null
    Qt.callLater(() => card.tookOver = false)
  }
  Component.onCompleted: if (card.awaited && shot.hasContent) card.arrive()
  // Taking over from the stand-in in one frame: faded in, it showed a
  // gap where the window had just been let go.
  property bool tookOver: false
  // Resolved once per card rather than per frame: a desktop-entry search
  // is a directory walk.
  readonly property string icon: overlay.iconFor(card.modelData.appId)

  // The whole animation: where it is, blended with where it goes — plus
  // however far it has been dragged since it was picked up.
  // Up to fully open, the window's place blended with its slot. Past
  // it — the fingers still pushing — the card goes on shrinking about
  // its own middle and drifting up toward the strip, rather than
  // carrying on along the same line, which would shrink a big window
  // with a small slot to nothing.
  // Only for a card that can be seen. The rest would otherwise work out
  // their whole place again every frame of a swipe, for nothing; held
  // at open, they pick `t` back up the moment they matter, and their
  // place never eases there (see the Behaviors on x/y: off while `t`
  // is moving).
  readonly property bool tracking: card.shown || card.fading || card.flying || card.opacity > 0.01
  readonly property real along: card.tracking ? Math.min(1, overlay.t) : 1
  readonly property real beyond: card.tracking ? Math.max(0, overlay.t - 1) : 0
  readonly property real squeeze: 1 - card.beyond * 0.7
  // The window's own size, in the pixels its buffer actually has when
  // that is within a pixel or two of what Hyprland reports: drawn at
  // exactly that size, a card is a one-to-one copy of the window rather
  // than one resampled a pixel larger or smaller, which reads as the
  // text going soft for a frame as the card takes over.
  readonly property real ownW: {
    const px = shot.sourceSize.width
    return px > 0 && Math.abs(px - card.real.w * surface.hyprScale) <= 2 ? px / surface.hyprScale : card.real.w
  }
  readonly property real ownH: {
    const px = shot.sourceSize.height
    return px > 0 && Math.abs(px - card.real.h * surface.hyprScale) <= 2 ? px / surface.hyprScale : card.real.h
  }
  readonly property real baseW: card.slot ? card.ownW + (card.slot.w - card.ownW) * card.along : card.ownW
  readonly property real baseH: card.slot ? card.ownH + (card.slot.h - card.ownH) * card.along : card.ownH

  // Dropped on another desktop's tile, the way a Mac does it: the card
  // flies from where it was let go into the tile, shrinking to exactly
  // where the window now sits in that desktop, and stays there, a live
  // miniature, while the spread closes up around the gap. The spot is
  // read live, so as Hyprland lays that desktop out again the card
  // follows. Peek at that desktop and it comes back out to its slot.
  property bool leftAway: false
  property rect lastDrag: Qt.rect(0, 0, 0, 0)

  // Held over another desktop's tile, the card is already the size it
  // will be there, so letting go only settles it into place — rather
  // than landing a different size from the one carried over.
  readonly property real tileScale: {
    const target = overlay.dragTarget
    const here = overlay.synced ? overlay.wsOf(card.modelData) : overlay.focusedDesk
    if (!(target > 0) || target === here || card.width <= 0 || card.height <= 0) return 0.4
    const r = surface.landingRect(card.modelData.key, target, card.real, card.floating)
    return Math.max(0.05, Math.min(r.width / card.width, r.height / card.height))
  }

  // Picked up, the card slides so its middle is under the pointer while
  // it shrinks — it shrinks about its middle, so held by a corner it
  // would otherwise shrink away from the pointer, further still over a
  // tile — and stays there however small it gets.
  property real grabX: 0
  property real grabY: 0
  property real centering: 0
  NumberAnimation {
    id: centeringOn
    target: card
    property: "centering"
    from: 0
    to: 1
    duration: 160
    easing.type: Easing.OutCubic
  }
  property rect flyFrom: Qt.rect(0, 0, 0, 0)
  property real fly: 0
  property bool released: false
  readonly property bool flying: card.leftAway && !card.here && surface.leading
  // In the tile, and so wherever the tile is: as the overview closes the
  // strip slides up out of sight, and a card left where the tile used to
  // be hung there on its own until the overview had gone.
  readonly property rect flyTo: {
    if (!card.leftAway) return Qt.rect(0, 0, 0, 0)
    const r = surface.landingRect(card.modelData.key, overlay.wsOf(card.modelData), card.real, card.floating)
    return Qt.rect(r.x, r.y - surface.stripHeight * (1 - overlay.veil), r.width, r.height)
  }
  // Sent to another desktop and not on its way back: never seen again
  // where its window was, even for the moment its flight ends.
  readonly property bool parked: card.leftAway && !card.here

  NumberAnimation {
    id: flight
    target: card
    property: "fly"
    from: 0
    to: 1
    duration: 340
    easing.type: Easing.OutCubic
  }

  /** Let go over another desktop's tile. */
  function flyAway() {
    // From exactly what was on screen: the card as held, shrunk about
    // its middle.
    // Held at the size it will have in the tile (see `tileScale`); read
    // that rather than `scale`, which may already have let go by now.
    const held = card.tileScale
    const r = card.lastDrag
    card.flyFrom = Qt.rect(r.x + r.width * (1 - held) / 2, r.y + r.height * (1 - held) / 2,
                           r.width * held, r.height * held)
    card.released = true
    card.leftAway = true
    card.fly = 0
    flight.restart()
  }

  onFlyingChanged: {
    overlay.setFlown(card.modelData.key, card.flying)
    if (!card.flying && card.leftAway) {
      // Where it was in the tile, from the flight itself: by now the
      // card's own position may already have moved on.
      card.backFrom = Qt.rect(card.blend(card.flyFrom.x, card.flyTo.x, card.fly),
                              card.blend(card.flyFrom.y, card.flyTo.y, card.fly),
                              card.blend(card.flyFrom.width, card.flyTo.width, card.fly),
                              card.blend(card.flyFrom.height, card.flyTo.height, card.fly))
      card.back = 0
      comingBack.restart()
    }
    // Back into the tile after a peek: from wherever the card is now.
    if (card.flying && !card.released) {
      // From where it stood in the spread, worked out rather than read
      // back, for the same reason.
      const k = card.back
      card.flyFrom = Qt.rect(k < 1 ? card.blend(card.backFrom.x, card.homeX, k) : card.homeX,
                             k < 1 ? card.blend(card.backFrom.y, card.homeY, k) : card.homeY,
                             k < 1 ? card.blend(card.backFrom.width, card.homeW, k) : card.homeW,
                             k < 1 ? card.blend(card.backFrom.height, card.homeH, k) : card.homeH)
      comingBack.stop()
      card.back = 1
      card.fly = 0
      flight.restart()
    }
    card.released = false
  }

  Connections {
    target: overlay
    function onOpenedChanged() {
      if (overlay.opened) return
      flight.stop()
      card.leftAway = false
    }
  }

  readonly property real homeX: surface.snap((card.slot ? card.real.x + (card.slot.x - card.real.x) * card.along : card.real.x)
     + card.baseW * (1 - card.squeeze) / 2
     + card.shift
     + card.awayLane * surface.width * (1 - card.along)
     + (card.dragging ? dragger.activeTranslation.x + (card.grabX - card.homeW / 2) * card.centering : 0))
  readonly property real homeY: surface.snap((card.slot ? card.real.y + (card.slot.y - card.real.y) * card.along : card.real.y)
     + card.baseH * (1 - card.squeeze) / 2
     - card.beyond * surface.height * 0.12
     + (card.dragging ? dragger.activeTranslation.y + (card.grabY - card.homeH / 2) * card.centering : 0))
  readonly property real homeW: surface.snap(card.baseW * card.squeeze)
  readonly property real homeH: surface.snap(card.baseH * card.squeeze)

  // Out of a tile again — its desktop is being peeked at, or gone to —
  // the card glides from the tile to where it belongs, rather than
  // appearing there.
  property rect backFrom: Qt.rect(0, 0, 0, 0)
  property real back: 1
  NumberAnimation {
    id: comingBack
    target: card
    property: "back"
    from: 0
    to: 1
    duration: 300
    easing.type: Easing.OutCubic
  }
  function blend(from, to, k) { return from + (to - from) * k }

  x: (card.flying ? card.blend(card.flyFrom.x, card.flyTo.x, card.fly)
      : (card.back < 1 ? card.blend(card.backFrom.x, card.homeX, card.back) : card.homeX)) - card.carried
  y: card.flying ? card.blend(card.flyFrom.y, card.flyTo.y, card.fly)
     : (card.back < 1 ? card.blend(card.backFrom.y, card.homeY, card.back) : card.homeY)
  width: card.flying ? card.blend(card.flyFrom.width, card.flyTo.width, card.fly)
         : (card.back < 1 ? card.blend(card.backFrom.width, card.homeW, card.back) : card.homeW)
  height: card.flying ? card.blend(card.flyFrom.height, card.flyTo.height, card.fly)
          : (card.back < 1 ? card.blend(card.backFrom.height, card.homeH, card.back) : card.homeH)

  Behavior on x { enabled: overlay.active && !card.dragging && !card.flying && card.back >= 1 && !overlay.moving && !overlay.settling; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
  Behavior on y { enabled: overlay.active && !card.dragging && !card.flying && card.back >= 1 && !overlay.moving && !overlay.settling; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
  Behavior on width { enabled: overlay.active && !card.dragging && !card.flying && card.back >= 1 && !overlay.moving && !overlay.settling; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
  Behavior on height { enabled: overlay.active && !card.dragging && !card.flying && card.back >= 1 && !overlay.moving && !overlay.settling; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

  // Floating cards stack as their windows do; see `floatStack`.
  // One fading out keeps its place among them until it has gone.
  z: card.dragging || card.flying ? 100
     : card.floating && card.stacked ? 1 + surface.floatStack.indexOf(card.modelData.key)
     : card.fading ? 0
     : (card.picked ? 2 : 1)
  // Held, it shrinks the way a thing you have picked up does — and
  // shrinks further over somewhere it would land, so it stops covering
  // what it is about to drop into.
  // Grown under the pointer only once the overview is open. The window
  // you were using starts out selected, and growing it from the first
  // frame made it the one card that did not match its window.
  scale: card.flying ? 1
       : card.dragging ? (overlay.dragTarget > 0 ? card.tileScale : (overlay.dropOnKey !== "" ? 0.4 : 0.82))
       : (card.picked && overlay.active ? 1.035 : 1)
  opacity: card.handedOver || card.awaited ? 0
         : card.flying ? overlay.veil
         : card.shown ? (card.dragging ? 0.94 : 1) * card.reveal
         : card.fading ? Math.max(overlay.appOnly !== "" ? 1 - surface.appVeil : 0, 1 - card.along * 2.5) : 0
  visible: card.opacity > 0.01
  // Not as it takes off: the card swaps its shrink for its size in the
  // same frame, and animating one of them would show the seam.
  Behavior on scale { enabled: !card.flying; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
  // Sliding carries a desktop off the screen rather than fading it: one
  // that is still dissolving as it goes reads as lag.
  // Nor a card parked in a tile when its flight ends: faded from where
  // it stood, it showed the window back on its old desktop for a moment.
  // Nor one fading with the overview: that follows `t` every frame, and a
  // Behavior restarted every frame never leaves where it started — the
  // window popped in whole once the overview had gone. Held open, though,
  // a card the search has just left out still eases away.
  // Nor one coming in from under a maximized window, for the same reason.
  Behavior on opacity { enabled: !surface.sliding && !card.parked && ((!card.fading && !card.under) || overlay.still) && !card.awaited && !card.tookOver; NumberAnimation { duration: 150 } }

  // Hyprland's rounding on the desktop, the overview's own once spread,
  // never rounder than Hyprland's.
  readonly property real radius: card.flying ? surface.rounded(3) + (surface.rounded(14) - surface.rounded(3)) * (1 - card.fly)
                               : overlay.deco.rounding + (surface.rounded(14) - overlay.deco.rounding) * overlay.dress

  // Hyprland's shadow and border, which the card wears while it still
  // stands in for the window, and sheds as it becomes a card. Drawn by
  // ports of Hyprland's own shaders, at the sizes Hyprland works them
  // out in — physical pixels, rounded where it rounds — so that as the
  // card takes over from the window not a pixel of its outline moves.
  readonly property int pxW: Math.round(card.width * surface.hyprScale)
  readonly property int pxH: Math.round(card.height * surface.hyprScale)
  readonly property real pxRound: card.radius * surface.hyprScale
  readonly property real dressedAway: 1 - overlay.dress
  // The window's titlebar, above the card and outside its own rectangle, as it is
  // on the desktop: as tall as the card is scaled. Border and shadow go round both.
  readonly property real barH: overlay.look.cardTitlebars && card.real.bar > 0 && card.real.w > 0
                               ? card.real.bar * card.width / card.real.w : 0
  readonly property int pxBar: Math.round(card.barH * surface.hyprScale)

  CardDressing { card: card }

  // Backed by the blur behind it. A look can leave this to the cards it wants it on.
  readonly property bool frostedGlass: overlay.look.frostsCard(card.ownPanel) && surface.glass && overlay.wallpaper !== "" && shot.hasContent

  // A sibling of the frame, not in it (see CardFrost.qml).
  CardFrost {
    card: card
    frame: shot
  }

  Looks.LookSlot {
    anchors.fill: parent
    file: overlay.look.cardUnderlay(card.ownPanel)
    given: ({ card: card })
  }

  CardCapture {
    id: shot
    card: card
  }

  CardTitlebar { card: card }

  // Hairline at rest, accent ring under the pointer, bright ring for a
  // window something is about to be dropped onto.
  Rectangle {
    id: ring
    // A hairline lies on the card's own edge. Anything wider is put on round
    // the outside of it, its corner grown by as much: drawn inward, a wide
    // ring on a small corner left almost no curve on its inner edge, and it
    // covered the edge of the window.
    readonly property real wide: overlay.look.ringWidth(card.flying, card.landing, card.picked)
    readonly property real out: ring.wide > 1 ? ring.wide : 0
    anchors.fill: parent
    anchors.margins: -ring.out
    anchors.topMargin: -card.barH - ring.out
    radius: card.radius > 0 ? card.radius + ring.out : 0
    color: "transparent"
    // In a tile it is a miniature, not a card you can pick: the tile's
    // own hairline is the only outline.
    border.width: ring.wide
    border.color: card.landing ? overlay.look.ink("#F2EFE7") : (card.picked ? Commons.Color.accent : Qt.rgba(1, 1, 1, 0.14))
    opacity: overlay.dress
  }

  Looks.LookSlot {
    anchors.fill: parent
    file: overlay.look.cardOverlay
    given: ({ card: card })
  }

  HoverHandler {
    id: hover
    enabled: overlay.active && card.shown
    cursorShape: card.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
    onHoveredChanged: {
      if (hover.hovered) {
        overlay.selectedKey = card.modelData.key
        overlay.hoverFocus(card.modelData.key)
      } else if (overlay.selectedKey === card.modelData.key && !card.dragging && overlay.dragKey === "") {
        // Off the window, onto nothing: nothing is picked. (Hyprland
        // keeps its focus — it has no way to focus nothing — but the
        // overview stops saying so.)
        overlay.selectedKey = ""
      }
    }
  }

  TapHandler {
    enabled: overlay.active && card.shown
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    onTapped: function (point, button) {
      if (button === Qt.MiddleButton) overlay.closeWindow(card.modelData.key)
      else overlay.focusWindow(card.modelData.key)
    }
  }

  // Pick a window up: drop it on a workspace to send it there, or on
  // another window to trade places with it.
  DragHandler {
    id: dragger
    enabled: overlay.active && card.shown
    target: null

    onActiveChanged: {
      if (dragger.active) {
        overlay.dragHome = surface.monitorName
        overlay.dragScreen = surface.monitorName
        overlay.dragCapture = card.modelData.capture
        overlay.dragOpacity = card.real.opacity ?? 1
        overlay.dragRect = card.heldRect
        overlay.dragKey = card.modelData.key
        overlay.selectedKey = card.modelData.key
        card.grabX = dragger.centroid.pressPosition.x
        card.grabY = dragger.centroid.pressPosition.y
        card.centering = 0
        centeringOn.restart()
      } else if (overlay.dragScreen !== "" && overlay.dragScreen !== surface.monitorName) {
        // Let go over another screen: the window goes there, and its
        // card there takes over (see `arrive`) — or, if it could not
        // go, back to its place here.
        if (overlay.drop(card.modelData.key)) {
          card.handedOver = true
        } else {
          card.backFrom = card.lastDrag
          card.back = 0
          comingBack.restart()
        }
        overlay.dragKey = ""
      } else {
        const here = overlay.synced ? overlay.wsOf(card.modelData) : overlay.focusedDesk
        if (overlay.dragTarget > 0 && overlay.dragTarget !== here) {
          card.flyAway()
        } else {
          // Back to its place — or to the other window's, if they are
          // trading — from exactly where it was let go, rather than
          // jumping: the eased Behaviors switch on in the same moment the
          // drag ends, and which of the two Qt sees first is not given.
          card.backFrom = card.lastDrag
          card.back = 0
          comingBack.restart()
        }
        overlay.drop(card.modelData.key)
        overlay.dragKey = ""
      }
    }

    onCentroidChanged: {
      if (!dragger.active) return
      card.lastDrag = Qt.rect(card.stageX, card.y, card.width, card.height)
      const at = dragger.centroid.scenePosition
      // Still this surface's, even off its edge: the pointer stays with
      // where the button went down. Over another screen, that screen's
      // strip is what it can be dropped on.
      const ox = surface.monitor ? surface.monitor.x : 0
      const oy = surface.monitor ? surface.monitor.y : 0
      const over = overlay.surfaceAt(ox + at.x, oy + at.y)
      if (over && over.stage !== surface) {
        const lx = ox + at.x - over.monitor.x
        const ly = oy + at.y - over.monitor.y
        overlay.dragScreen = over.monitorName
        overlay.aimDrag(over.workspaceAtPoint(lx, ly), "")
        return
      }
      if (over) overlay.dragScreen = surface.monitorName
      overlay.aimDrag(surface.workspaceAtPoint(at.x, at.y), surface.cardAtPoint(at.x, at.y))
    }
  }

  CardChrome { card: card }
}
