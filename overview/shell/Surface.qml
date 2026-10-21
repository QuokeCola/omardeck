import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Widgets
import qs.Commons
import qs.Commons as Commons
import "../app/Layout.js" as Layout

// One screen's worth of overview.
//
// Every monitor gets one of these, each spreading its own workspace's windows,
// because a second screen that merely dims while you are looking for a window
// on it is worse than no overview at all. The workspace strip belongs to the
// screen you were pointing at; the others are just their own windows.
PanelWindow {
  id: surface

  required property var overlay
  required property var screenInfo

  screen: surface.screenInfo
  // Mapped for good rather than per swipe, empty and click-through while the
  // overview is away. Mapping a layer surface is a round trip with the
  // compositor, fresh buffers, and every texture the overview draws with
  // allocated again: 60 to 100ms in which the fingers had moved and the
  // overview had not, and then it jumped to catch up. Kept mapped, a swipe
  // draws on the next frame.
  //
  // Except over a fullscreen window: a surface on top of one, even an empty
  // one, stops the compositor scanning that window straight out, which is
  // what a fullscreen video wants. There the overview maps when asked.
  visible: overlay.opened || !surface.fullscreenHere
  readonly property bool fullscreenHere: !!(surface.monitor && surface.monitor.activeWorkspace
                                            && surface.monitor.activeWorkspace.hasFullscreen)
  color: "transparent"
  WlrLayershell.namespace: "omarchy-aerial"
  WlrLayershell.layer: WlrLayer.Overlay
  exclusionMode: ExclusionMode.Ignore
  anchors { top: true; bottom: true; left: true; right: true }

  // Only the screen you swiped on grabs the keyboard; two surfaces both
  // claiming it exclusively is a fight nobody wins. And only once the overview
  // is actually open — a swipe still in progress must not take keys from the
  // window underneath.
  WlrLayershell.keyboardFocus: surface.leading && overlay.active
                               ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

  // A swipe in progress should not swallow clicks meant for the desktop.
  mask: overlay.active ? null : emptyRegion
  Region { id: emptyRegion }

  readonly property string monitorName: surface.screenInfo ? surface.screenInfo.name : ""
  readonly property var monitor: (Hyprland.monitors.values || []).find(m => m.name === surface.monitorName) || null
  readonly property bool leading: surface.monitorName === overlay.leadMonitor
  // Showing what the screen swiped on shows — the same desktop, peeked at or
  // slid to with it — rather than only its own: the leading screen, or every
  // screen when they are one desktop.
  readonly property bool following: surface.leading || overlay.synced

  /** This screen's workspace for a desktop in the strip. */
  function spaceHere(desk) { return overlay.spaceOn(desk, surface.monitorName) }

  // The desktop this screen is on, as Hyprland has it.
  readonly property int ownDesk: surface.monitor && surface.monitor.activeWorkspace
                                 ? overlay.deskOfId(surface.monitor.activeWorkspace.id) : -1

  // How soft the wallpaper behind the spread is, 0 to 1. At 0 it is the
  // wallpaper itself, sharp, exactly as the desktop shows it.
  readonly property real blur: 0
  // How much it is darkened behind the spread, 0 to 1. At 0 it is not.
  readonly property real dim: 0

  // Frosted windows. A terminal drawn partly see-through, with the compositor
  // blurring what is behind it, captures as see-through and nothing more: the
  // blur is the compositor's, not the window's. So every card is backed by
  // Hyprland's own blur of whatever is behind it — computed here the way
  // Hyprland computes it, with its settings, so the glass does not change as
  // the window hands over to its card. See HyprBlur.qml.
  //
  // Blurred once as the overview opens for the tiled windows, which have only
  // the wallpaper behind them, and live for floating ones and for a window
  // being carried over the strip, whose backdrop moves with them.
  readonly property bool glass: overlay.deco.blur === true && overlay.frost

  // Corners follow Hyprland's decoration:rounding: each shape keeps its own
  // radius as a ceiling, so square-cornered setups (rounding 0) get square
  // tiles and cards, and rounded ones look as they always have.
  function rounded(r) { return Math.min(r, overlay.deco.rounding) }
  // Hyprland's blur size as configured. Checked against screenshots of
  // Hyprland frosting a see-through terminal over a static page: with the
  // blur run at the monitor's own scale (see `hyprScale`) the port matches
  // best with no correction at all.
  readonly property real blurScale: 1

  // The floating windows' cards on screen, bottom to top, in the order
  // Hyprland draws them (see `zOrder`).
  readonly property var floatStack: {
    const out = []
    for (let i = 0; i < floatCards.count; i++) {
      const card = floatCards.itemAt(i)
      if (!card || !card.shown) continue
      const z = overlay.zOrder[card.modelData.key]
      out.push({ key: card.modelData.key, z: typeof z === "number" ? z : -1 })
    }
    out.sort((a, b) => a.z - b.z)
    return out.map(e => e.key)
  }

  function floatCardFor(key) {
    for (let i = 0; i < floatCards.count; i++) {
      const card = floatCards.itemAt(i)
      if (card && card.modelData.key === key) return card
    }
    return null
  }

  /** The blur behind a floating window: its level's. */
  function floatBlurFor(key) {
    const at = surface.floatStack.indexOf(key)
    const level = at >= 0 ? floatLevels.itemAt(at) : null
    return level ? level.output : wallBlur.output
  }

  // The part of the screen windows live in: all of it, less what the bar and
  // anything else exclusive has reserved. Hyprland reports that as
  // [left, top, right, bottom].
  readonly property var reserved: {
    const r = surface.monitor && surface.monitor.lastIpcObject ? surface.monitor.lastIpcObject.reserved : null
    // A list from C++, which is not a JS Array as far as isArray is concerned.
    if (!r || r.length !== 4) return [0, 0, 0, 0]
    return [Number(r[0]) || 0, Number(r[1]) || 0, Number(r[2]) || 0, Number(r[3]) || 0]
  }

  // Not drawn at all until it can take the desktop's place in one frame:
  // every card on screen captured, the wallpaper decoded, and a frame more
  // for anything drawn from those. Drawn any sooner, the first frames of a
  // swipe show the real windows through cards that are still empty — two of
  // everything — and then flash as it all arrives. It is a few milliseconds;
  // then it appears already following the fingers. Never longer than
  // `giveUp`, whatever does not arrive.
  property bool ready: false
  // Cards that once held the overview back the whole of `giveUp`, by key.
  property var missed: ({})
  readonly property bool canShow: overlay.opened && surface.captured
                                  && (overlay.wallpaper === "" || solid.status === Image.Ready)
  // Counted in presented frames, not guessed with a timer. The cards still
  // hold what their windows showed the last time the overview was up; the
  // fresh frame asked for as the swipe began comes back two or three frames
  // later. Shown sooner, a video or a busy terminal jumps back in time for
  // those frames and then snaps to the present — at the start of a flick,
  // with the cards already moving, that reads as the windows changing.
  // Meanwhile the real windows are on screen, so nothing looks held up.
  readonly property int settleFrames: 3
  property int settled: 0
  property bool settling: false
  onCanShowChanged: if (surface.canShow && !surface.ready) {
    surface.settled = 0
    surface.settling = true
    stage.Window.window.update()
  }
  Connections {
    target: surface.settling ? stage.Window.window : null
    function onFrameSwapped() {
      if (++surface.settled < surface.settleFrames) {
        stage.Window.window.update()
        return
      }
      surface.settling = false
      if (surface.canShow) surface.ready = true
    }
  }

  Timer {
    id: giveUp
    interval: 250
    running: overlay.opened && !surface.ready
    onTriggered: {
      // Whatever kept it waiting this time is not waited for again until it
      // has shown a frame: some windows never give the shell one (Zoom's
      // meeting window, under XWayland), and each swipe past them stalled.
      const missed = Object.assign({}, surface.missed)
      for (const list of [tiledCards, floatCards])
        for (let i = 0; i < list.count; i++) {
          const c = list.itemAt(i)
          if (c && c.waiting) missed[c.modelData.key] = true
        }
      surface.missed = missed
      surface.ready = true
    }
  }

  // The screen swiped on decides when the overview starts to move.
  onReadyChanged: if (surface.ready && (surface.leading || overlay.leadMonitor === "")) overlay.revealed()

  Connections {
    target: overlay
    function onOpenedChanged() {
      if (overlay.opened) return
      surface.ready = false
      surface.settling = false
    }
  }

  // Every card on screen has its first frame. Until then the desktop behind
  // must stay visible, or a window whose capture is late blinks out.
  readonly property bool captured: {
    for (const list of [tiledCards, floatCards]) {
      for (let i = 0; i < list.count; i++) {
        const card = list.itemAt(i)
        if (card && card.waiting) return false
      }
    }
    return true
  }

  // The scale Hyprland draws this monitor at. Not Qt's pixel ratio: the shell
  // renders its surfaces at a whole-number ratio (2 here, for a 1.25 screen)
  // and lets the compositor scale them down, so every size that has to match
  // what Hyprland draws — borders, shadows, the pixel grid — is worked out in
  // Hyprland's pixels, not Qt's.
  readonly property real hyprScale: surface.monitor && surface.monitor.scale > 0 ? surface.monitor.scale : surface.pixelRatio

  // To the screen's real pixel grid, the way Hyprland places windows. At a
  // fractional scale a window at logical 47 sits on pixel 58.75, which the
  // compositor rounds and a card would not: resampled half a pixel off, every
  // edge and every letter of text shifts as the card takes over.
  function snap(v) { return Math.round(v * surface.hyprScale) / surface.hyprScale }

  readonly property real pixelRatio: surface.screenInfo && surface.screenInfo.devicePixelRatio > 0
                                     ? surface.screenInfo.devicePixelRatio : 1

  // Which workspace this screen is showing. Peeking at a tile swaps it without
  // going there.
  readonly property int shownWorkspace: {
    if (surface.following && overlay.peek > 0) return overlay.peek
    if (surface.following && overlay.stageWorkspace > 0) return overlay.stageWorkspace
    return surface.ownDesk
  }

  // The desktop this screen's strip marks as current.
  readonly property int ringWorkspace: surface.following ? overlay.stageWorkspace : surface.ownDesk

  // Sliding between workspaces moves every desktop's spread sideways together,
  // so this screen is a window onto a row of them.
  readonly property bool sliding: surface.following && overlay.moving
                                  && !overlay.everything && !surface.searching

  // Every window on this screen, whichever desktop it is on. This is what the
  // cards are built from, and it deliberately does not depend on which
  // workspace is being shown: a new array makes the Repeater throw away every
  // delegate and build new ones, and rebuilding a live capture is exactly the
  // hitch the snapshot above exists to avoid. Peeking used to do it on every
  // hover, which is why the strip felt slow and flashed the desktop you were
  // already on while the new captures caught up.
  readonly property var monitorWindows: {
    const out = []
    for (const win of overlay.shot) {
      if (win.monitor !== surface.monitorName) continue
      out.push(win)
    }
    return out
  }

  // The ones the spread is laid out from: this desktop's, or every one of them.
  // Typing is a search, not a filter. Asking "where is that terminal" and being
  // told only about this desktop is the wrong answer to the question -- the
  // window you cannot find is, almost by definition, not the one in front of
  // you. So the moment there is something to search for, every desktop is in
  // scope; clear the text and it narrows back to where you are.
  readonly property bool searching: !overlay.everything && (overlay.filter !== "" || overlay.appOnly !== "")

  // Opened on one app, the other windows of this desktop fade out on a clock
  // of their own. Tied to `t`, they were gone within a frame or two: the
  // spring that opens the overview covers most of the way at once. Closing
  // still brings them back with `t`, which already reads well, so the veil
  // stays up until the app is let go.
  property real appVeil: 0
  readonly property bool appOpening: overlay.appOnly !== "" && overlay.service !== null && overlay.service.goal > 0
  onAppOpeningChanged: if (surface.appOpening) appVeilIn.restart()
  readonly property bool appCleared: overlay.appOnly === ""
  onAppClearedChanged: if (surface.appCleared) {
    appVeilIn.stop()
    surface.appVeil = 0
  }
  NumberAnimation {
    id: appVeilIn
    target: surface
    property: "appVeil"
    to: 1
    duration: 260
    easing.type: Easing.OutCubic
  }

  readonly property var windows: {
    if (overlay.everything || surface.searching) return surface.monitorWindows
    const out = []
    for (const win of surface.monitorWindows) {
      if (overlay.wsOf(win) !== surface.shownWorkspace) continue
      out.push(win)
    }
    return out
  }

  // What the filter leaves standing. The card for a window that does not match
  // stays alive but steps out of the spread, so typing does not tear down and
  // rebuild a live capture on every keystroke.
  readonly property var shownWindows: surface.windows.filter(w => overlay.matches(w))

  // Everything on this screen that the filter leaves standing, whichever
  // desktop it is on. What the slots are laid out from.
  //
  // With each window where it is now: the cards outlive the overview between
  // openings (see `sync`), so the snapshot they were built from can be older
  // than the last time a window moved.
  readonly property var matching: surface.monitorWindows.filter(w => overlay.matches(w)).map(w => {
    const now = overlay.rects[w.key]
    return now ? Object.assign({}, w, { x: now.x, y: now.y, w: now.w, h: now.h }) : w
  })

  // Room for the workspace strip along the top, the way Mission Control does.
  // On every screen — each is somewhere you might be working — and the same
  // height on each, so the spread does not move when the pointer changes
  // screens.
  readonly property real stripHeight: Math.max(96, surface.height * 0.15)
  readonly property real padding: 32

  // The strip is laid out from these and hit-tested from these, so a dragged
  // window lands on the tile it looks like it is over.
  readonly property real tileWidth: Math.max(96, surface.height * 0.15) * 0.92
  readonly property real tileHeight: surface.tileWidth * (surface.height / Math.max(1, surface.width))
  readonly property real tileGap: 16
  readonly property real tileTop: (surface.stripHeight - surface.tileHeight) / 2
  readonly property real tileLeft: {
    const count = overlay.workspaces.length
    const total = count * surface.tileWidth + Math.max(0, count - 1) * surface.tileGap
    return (surface.width - total) / 2
  }

  function tileX(index) { return surface.tileLeft + index * (surface.tileWidth + surface.tileGap) }

  /** Where a window sits in a workspace's tile: its block in the tile, from
      where Hyprland has actually put it — or, until Hyprland has said, where
      it will: a floating window keeps its place and size, a window going to
      an empty desktop fills it, and otherwise the middle of the tile at the
      window's shape. */
  function landingRect(key, spaceId, real, floating) {
    const index = overlay.workspaces.findIndex(w => w.id === spaceId)
    if (index < 0) return Qt.rect(surface.width / 2, surface.tileTop, 1, 1)
    const tx = surface.tileX(index)
    const ty = surface.tileTop
    const tw = surface.tileWidth
    const th = surface.tileHeight
    const plan = (overlay.livePlans[surface.spaceHere(spaceId)] || []).find(p => p.key === key)
    if (plan) return Qt.rect(tx + plan.x * tw, ty + plan.y * th, Math.max(3, plan.w * tw), Math.max(3, plan.h * th))
    const sw = Math.max(1, surface.width)
    const sh = Math.max(1, surface.height)
    if (floating && real && real.w > 0)
      return Qt.rect(tx + real.x / sw * tw, ty + real.y / sh * th, Math.max(3, real.w / sw * tw), Math.max(3, real.h / sh * th))
    const others = (overlay.livePlans[surface.spaceHere(spaceId)] || []).filter(p => p.key !== key)
    if (others.length === 0) {
      // Alone there, it will fill the desktop: the work area, less the gaps
      // Hyprland leaves around it.
      const gap = 0.02
      const top = surface.reserved[1] / sh
      return Qt.rect(tx + tw * gap, ty + th * (top + gap), tw * (1 - 2 * gap), th * (1 - top - 2 * gap))
    }
    const aspect = real && real.h > 0 ? real.w / real.h : 1.5
    let w = tw * 0.6
    let h = w / aspect
    if (h > th * 0.6) { h = th * 0.6; w = h * aspect }
    return Qt.rect(tx + (tw - w) / 2, ty + (th - h) / 2, w, h)
  }

  /** Which workspace is under this point, or -1. Generous by a few pixels: a
   *  drop that looks like it is on a tile should count as one. */
  function workspaceAtPoint(px, py) {
    const slack = 10
    if (py < surface.tileTop - slack || py > surface.tileTop + surface.tileHeight + slack) return -1
    for (let i = 0; i < overlay.workspaces.length; i++) {
      const left = surface.tileX(i)
      if (px >= left - slack && px <= left + surface.tileWidth + slack) return overlay.workspaces[i].id
    }
    return -1
  }

  /** Which window's card is under this point, ignoring the one being dragged. */
  function cardAtPoint(px, py) {
    for (const win of surface.shownWindows) {
      const slot = surface.slots[win.key]
      if (!slot || win.key === overlay.dragKey) continue
      if (px >= slot.x && px <= slot.x + slot.w && py >= slot.y && py <= slot.y + slot.h) return win.key
    }
    return ""
  }

  // The last `slots`, so that what has not moved is handed back as the very
  // object it was (see `geo` in Overlay.qml): a card whose slot is the same
  // object is not worked out again.
  readonly property var slotMemo: ({ slots: ({}) })

  /** `fresh`, keeping each slot that has not changed — and the whole of the
      last answer if none has. */
  function keptSlots(fresh) {
    const before = surface.slotMemo.slots
    let changed = false
    let count = 0
    const out = ({})
    for (const key in fresh) {
      out[key] = overlay.kept(before[key], fresh[key])
      if (out[key] !== before[key]) changed = true
      count++
    }
    if (!changed && count === Object.keys(before).length) return before
    surface.slotMemo.slots = out
    return out
  }

  readonly property var slots: {
    if (surface.matching.length === 0 || surface.width <= 0) return surface.keptSlots(({}))
    const area = {
      width: surface.width - surface.padding * 2,
      height: surface.height - surface.stripHeight - surface.padding * 2,
    }
    const options = { gap: 26, rowGap: 62, maxScale: 0.78 }

    const byKey = ({})

    // While searching, the matches are one set and get one spread. Peeking lays
    // every desktop into this same area so switching between them is a
    // crossfade -- which is right until two desktops are on screen at once, and
    // then it stacks them on top of each other.
    if (surface.searching) {
      for (const slot of Layout.spread(surface.matching, area, options)) {
        byKey[slot.key] = {
          x: slot.x + surface.padding,
          y: slot.y + surface.stripHeight + surface.padding,
          w: slot.w,
          h: slot.h,
        }
      }
      return surface.keptSlots(byKey)
    }

    if (!overlay.everything) {
      // Every desktop is laid out, not just the one on screen, each into the
      // same area. A card is therefore already standing exactly where it will
      // be when you peek at its desktop, so peeking is a cross-fade and
      // nothing moves.
      //
      // That is not only tidier, it is the whole bug: a card that animates
      // into place travels from where the window really is, which crosses the
      // workspace strip, which takes the pointer's hover off the tile you are
      // pointing at, which cancels the peek, which sends the card back — and
      // round it goes. It also means this no longer depends on which desktop
      // is shown, so hovering the strip recomputes no layout at all.
      for (const group of Layout.groupBy(surface.matching, w => overlay.wsOf(w))) {
        for (const slot of Layout.spread(group.windows, area, options)) {
          byKey[slot.key] = {
            x: slot.x + surface.padding,
            y: slot.y + surface.stripHeight + surface.padding,
            w: slot.w,
            h: slot.h,
          }
        }
      }
      return surface.keptSlots(byKey)
    }

    // Every window on this screen, kept in its workspace's own column so the
    // answer to "where is it" is still "on that desktop".
    const groups = Layout.groupBy(surface.shownWindows, w => overlay.wsOf(w))
    for (const column of Layout.columns(groups, area, options)) {
      for (const slot of column.slots) {
        byKey[slot.key] = {
          x: slot.x + column.x + surface.padding,
          y: slot.y + surface.stripHeight + surface.padding + Layout.LABEL_SPACE,
          w: slot.w,
          h: slot.h,
        }
      }
    }
    return surface.keptSlots(byKey)
  }

  readonly property var columnLabels: {
    if (!overlay.everything || surface.shownWindows.length === 0 || surface.width <= 0) return []
    const area = {
      width: surface.width - surface.padding * 2,
      height: surface.height - surface.stripHeight - surface.padding * 2,
    }
    const groups = Layout.groupBy(surface.shownWindows, w => overlay.wsOf(w))
    return Layout.columns(groups, area, { gap: 26, rowGap: 62, maxScale: 0.78 }).map(column => ({
      key: column.key,
      x: column.x + surface.padding,
      width: column.width,
    }))
  }

  Item {
    id: stage
    anchors.fill: parent
    visible: overlay.opened
    opacity: surface.ready ? 1 : 0
    focus: surface.leading

    Keys.onPressed: function (event) { if (surface.leading) overlay.onKey(event) }

    // Every card is frosted with a live blur of whatever is behind it, the
    // way Hyprland draws a see-through window, and stacked the way Hyprland
    // stacks them, so a floating window blurs the tiled ones beneath it too:
    //
    //   base        the desktop and the strip — behind every card
    //   tiledLayer  tiled windows' cards, which never overlap one another
    //   floatLayer  floating windows' cards, over all of it
    //
    // Each card samples the blur of what is behind it: the wallpaper's, done
    // once per opening, or a live one where what is behind it moves.
    Item {
      id: lower
      anchors.fill: parent

      // The desktop and the strip: what is behind every card.
      Item {
        id: base
        anchors.fill: parent

        // The desktop goes away: the windows you are about to see spread out are
        // still sitting there underneath, and two of everything reads as a mess.
        //
        // So from the very first frame the part of the screen windows live in is
        // painted over with the wallpaper exactly as the desktop draws it — same
        // image, same crop — and the cards, standing exactly where their windows
        // are and dressed the way Hyprland dresses them, take the windows' place.
        // Nothing fades: the desktop you were looking at simply becomes the
        // overview, and only then starts to move. The bar's strip is left to fade,
        // since there is no card standing in for the bar.
        //
        // Then the blur comes in over it. Loaded at the screen's real resolution
        // and blurred properly, into a layer drawn once, since the wallpaper does
        // not change while the overview is open.
        Item {
          anchors.fill: parent
          visible: overlay.wallpaper !== ""

          // One image, decoded once: the three below share it through the image
          // cache, since source and size are the same.
          Image {
            id: wall
            anchors.fill: parent
            visible: false
            source: overlay.wallpaperUrl
            fillMode: Image.PreserveAspectCrop
            // From the screen, not the surface: a hidden surface is no size at
            // all, and a size that changes each time the overview opens throws
            // the decoded wallpaper away and decodes it again, every time.
            sourceSize.width: Math.ceil((surface.screenInfo ? surface.screenInfo.width : surface.width) * surface.pixelRatio)
            sourceSize.height: Math.ceil((surface.screenInfo ? surface.screenInfo.height : surface.height) * surface.pixelRatio)
            smooth: true
            asynchronous: true
            cache: true
          }

          // The whole screen, bar strip included, fading with the swipe.
          Image {
            anchors.fill: parent
            source: wall.source
            opacity: overlay.veil
            fillMode: wall.fillMode
            sourceSize: wall.sourceSize
            smooth: true
            asynchronous: true
            cache: true
          }

          // Where the windows are: solid from the first frame, as soon as every
          // card is ready to stand in for its window.
          Item {
            id: workArea
            x: surface.reserved[0]
            y: surface.reserved[1]
            width: surface.width - surface.reserved[0] - surface.reserved[2]
            height: surface.height - surface.reserved[1] - surface.reserved[3]
            clip: true
            opacity: overlay.opened && surface.captured && solid.status === Image.Ready ? 1 : overlay.veil

            Image {
              id: solid
              x: -workArea.x
              y: -workArea.y
              width: surface.width
              height: surface.height
              source: wall.source
              fillMode: wall.fillMode
              sourceSize: wall.sourceSize
              smooth: true
              asynchronous: true
              cache: true
            }
          }

          MultiEffect {
            anchors.fill: parent
            source: wall
            visible: surface.blur > 0
            opacity: overlay.veil
            blurEnabled: true
            blur: 1
            blurMax: Math.round(64 * surface.blur)
            autoPaddingEnabled: false
            layer.enabled: true
          }
        }

        Rectangle {
          anchors.fill: parent
          color: "#07070A"
          opacity: (overlay.wallpaper === "" ? 0.93 : surface.dim) * overlay.veil
        }

        MouseArea {
          anchors.fill: parent
          onClicked: overlay.dismiss()
        }

        // ------------------------------------------------------------ the strip
        Item {
          id: strip
          width: parent.width
          height: surface.stripHeight
          y: -height * (1 - overlay.veil)
          opacity: overlay.veil

          // The strip is centred, so a desktop added at its end moves every
          // tile half a tile over: started where they were, and eased there.
          transform: Translate { id: stripNudge }
          NumberAnimation { id: nudging; target: stripNudge; property: "x"; to: 0; duration: 320; easing.type: Easing.OutCubic }
          Connections {
            target: overlay
            function onDeskAdded(id, grew) {
              stripNudge.x = grew * (surface.tileWidth + surface.tileGap) / 2
              nudging.restart()
            }
          }

          Repeater {
            model: overlay.workspaces

            delegate: Item {
              id: space
              required property var modelData
              required property int index
              // The desktop the spread is showing, which sliding moves before the
              // compositor has caught up.
              readonly property bool focused: space.modelData.id === surface.ringWorkspace
              readonly property bool targeted: overlay.dragTarget === space.modelData.id
              readonly property bool peeked: overlay.peek === space.modelData.id
              // Live while open, so a window dropped here shows up where
              // Hyprland actually puts it, and the others make room.
              readonly property var plan: (overlay.opened ? overlay.livePlans : overlay.plans)[surface.spaceHere(space.modelData.id)] || []

              x: surface.tileX(space.index)
              y: surface.tileTop
              width: surface.tileWidth
              height: surface.tileHeight

              scale: space.targeted ? 1.12 : (space.peeked ? 1.06 : 1)
              Behavior on scale { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

              // A desktop just added from "+" drops in from above the strip,
              // and the next "+" fades in behind it.
              transform: Translate { id: arrival }
              SequentialAnimation {
                id: dropIn
                ParallelAnimation {
                  NumberAnimation { target: arrival; property: "y"; from: -(surface.tileTop + surface.tileHeight); to: 0; duration: 420; easing.type: Easing.OutBack; easing.overshoot: 1.2 }
                  NumberAnimation { target: space; property: "opacity"; from: 0; to: 1; duration: 220 }
                }
              }
              SequentialAnimation {
                id: fadeIn
                PropertyAction { target: space; property: "opacity"; value: 0 }
                PauseAnimation { duration: 180 }
                NumberAnimation { target: space; property: "opacity"; to: 1; duration: 240 }
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
                color: "#0B0B0E"

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
                  opacity: space.focused || space.peeked ? 0.85 : 0.5
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
                  // Window titles are somebody else's string: a browser tab can put
                  // anything in one. Rendered literally, never interpreted as markup.
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  visible: space.plan.length === 0
                  text: space.modelData.fresh ? "\u002b" : "empty"
                  color: Qt.rgba(1, 1, 1, space.modelData.fresh ? 0.5 : 0.34)
                  font.family: Style.font.family
                  font.pixelSize: space.modelData.fresh
                                  ? Math.round(Style.font.body * 1.6) : Style.font.caption
                }
              }

              Rectangle {
                anchors.fill: parent
                radius: tile.radius
                color: "transparent"
                // The accent ring for the current desktop is drawn once, below,
                // so it can travel between tiles as you slide.
                border.width: space.targeted || space.peeked ? 2 : 1
                border.color: space.targeted ? "#F2EFE7"
                            : space.peeked ? Qt.rgba(1, 1, 1, 0.5)
                            : Qt.rgba(1, 1, 1, 0.14)
              }

              Text {
                // Window titles are somebody else's string: a browser tab can put
                // anything in one. Rendered literally, never interpreted as markup.
                textFormat: Text.PlainText
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.bottom
                anchors.topMargin: 6
                text: space.modelData.name
                color: space.focused ? "#F2EFE7" : "#8D8880"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
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
            Behavior on x { enabled: !overlay.moving; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
          }
        }

        // ------------------------------------------------------- column labels
        Repeater {
          model: surface.columnLabels

          delegate: Text {
            required property var modelData
            x: modelData.x
            y: surface.stripHeight + surface.padding
            width: modelData.width
            horizontalAlignment: Text.AlignHCenter
            text: modelData.key
            color: Qt.rgba(1, 1, 1, 0.45)
            opacity: overlay.veil
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.weight: Font.DemiBold
          }
        }
      }

      Item {
        id: tiledLayer
        anchors.fill: parent

        Repeater {
          id: tiledCards
          model: surface.monitorWindows.filter(w => !w.floating)
          delegate: cardDelegate
        }
      }
    }

    Item {
      id: floatLayer
      anchors.fill: parent

      Repeater {
        id: floatCards
        model: surface.monitorWindows.filter(w => w.floating)
        delegate: cardDelegate
      }
    }

    // Behind a tiled window, as the compositor has it: the wallpaper. Which
    // does not change while the overview is up, so this is blurred once as it
    // opens rather than on every frame of the swipe — the strip sliding in and
    // the bar fading made `base` new each frame, and the whole chain ran again
    // for a picture no card at rest is ever over.
    Item {
      id: backdrop
      anchors.fill: parent

      Image {
        anchors.fill: parent
        source: overlay.wallpaperUrl
        visible: overlay.wallpaper !== ""
        fillMode: wall.fillMode
        sourceSize: wall.sourceSize
        smooth: true
        asynchronous: true
        cache: true
      }
    }

    HyprBlur {
      id: wallBlur
      anchors.fill: parent
      sourceItem: backdrop
      hideSource: true
      live: surface.glass && overlay.opened
      pixelSize: baseBlur.pixelSize
      size: baseBlur.size
      passes: baseBlur.passes
      noise: baseBlur.noise
      contrast: baseBlur.contrast
      brightness: baseBlur.brightness
      vibrancy: baseBlur.vibrancy
      vibrancyDarkness: baseBlur.vibrancyDarkness
    }

    // The desktop and the strip, live: what a window carried over the strip
    // has behind it. Only while one is.
    readonly property bool overStrip: overlay.dragKey !== ""
    HyprBlur {
      id: baseBlur
      anchors.fill: parent
      sourceItem: base
      live: surface.glass && overlay.opened && stage.overStrip
      pixelSize: Qt.size(Math.round(surface.width * surface.hyprScale), Math.round(surface.height * surface.hyprScale))
      size: overlay.deco.blurSize * surface.blurScale
      passes: overlay.deco.blurPasses
      noise: overlay.deco.blurNoise
      contrast: overlay.deco.blurContrast
      brightness: overlay.deco.blurBrightness
      vibrancy: overlay.deco.blurVibrancy
      vibrancyDarkness: overlay.deco.blurVibrancyDarkness
    }

    // Behind each floating window: everything below it — the desktop, the
    // tiled windows, and the floating windows under it — the way Hyprland
    // blurs a see-through window with xray off. One level per floating window
    // on screen, bottom to top: each level's blur reads the level below's
    // `stack`, which is that level's picture plus its own window, drawn as the
    // card is. Nothing runs when no floating window is on screen.
    Repeater {
      id: floatLevels
      model: surface.glass ? surface.floatStack : []

      delegate: Item {
        id: level
        required property string modelData
        required property int index
        anchors.fill: parent

        readonly property Item below: {
          if (level.index === 0) return lower
          const under = floatLevels.itemAt(level.index - 1)
          return under ? under.stack : lower
        }
        readonly property Item cardItem: surface.floatCardFor(level.modelData)
        readonly property Item output: levelBlur.output
        readonly property alias stack: stack

        // What the next window up has behind it: this level's picture, and
        // this window over it — border and shadow too, hence the margin.
        Item {
          id: stack
          width: surface.width
          height: surface.height
          visible: false

          ShaderEffectSource {
            anchors.fill: parent
            sourceItem: level.below
            live: true
          }

          ShaderEffectSource {
            readonly property real margin: 24
            visible: level.cardItem !== null
            sourceItem: level.cardItem
            x: level.cardItem ? level.cardItem.x - margin : 0
            y: level.cardItem ? level.cardItem.y - margin : 0
            width: level.cardItem ? level.cardItem.width + 2 * margin : 0
            height: level.cardItem ? level.cardItem.height + 2 * margin : 0
            sourceRect: level.cardItem ? Qt.rect(-margin, -margin, level.cardItem.width + 2 * margin,
                                                 level.cardItem.height + 2 * margin) : Qt.rect(0, 0, 0, 0)
            opacity: level.cardItem ? level.cardItem.opacity : 0
            live: true
          }
        }

        HyprBlur {
          id: levelBlur
          anchors.fill: parent
          sourceItem: level.below
          live: surface.glass && overlay.opened
          pixelSize: baseBlur.pixelSize
          size: baseBlur.size
          passes: baseBlur.passes
          noise: baseBlur.noise
          contrast: baseBlur.contrast
          brightness: baseBlur.brightness
          vibrancy: baseBlur.vibrancy
          vibrancyDarkness: baseBlur.vibrancyDarkness
        }
      }
    }

    // ------------------------------------------------------------ the windows
    // One card, drawn in whichever layer its window belongs to.
    Component {
      id: cardDelegate

      Item {
        id: card
        required property var modelData
        // Where the window really is right now, which can be fresher than the
        // snapshot the card was built from.
        readonly property var real: overlay.geo[card.modelData.key] || card.modelData
        readonly property bool focusedWindow: card.real.active === true
        // Which layer it is in: floating over tiled, as Hyprland stacks them,
        // so each card's blur has the right things behind it.
        readonly property bool floating: card.modelData.floating === true
        // Shown, but nothing captured to show yet.
        // Standing in for a window that is actually on this screen right now.
        // A scrolling layout keeps windows parked off either edge; those
        // cover nothing, and some never produce a frame to wait for.
        readonly property bool onScreen: card.shown
                                         && card.real.x < surface.width && card.real.x + card.real.w > 0
                                         && card.real.y < surface.height && card.real.y + card.real.h > 0
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
        readonly property bool fading: !card.shown && overlay.appOnly !== ""
                                       && overlay.wsOf(card.modelData) === surface.shownWorkspace
        readonly property bool hovered: hover.hovered && overlay.active
        readonly property bool picked: card.hovered || overlay.selectedKey === card.modelData.key
        readonly property bool dragging: dragger.active
        readonly property bool landing: overlay.dropOnKey === card.modelData.key
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

        x: card.flying ? card.blend(card.flyFrom.x, card.flyTo.x, card.fly)
           : (card.back < 1 ? card.blend(card.backFrom.x, card.homeX, card.back) : card.homeX)
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
        z: card.dragging || card.flying ? 100
           : card.fading ? 0
           : (card.floating ? 1 + surface.floatStack.indexOf(card.modelData.key) : (card.picked ? 2 : 1))
        // Held, it shrinks the way a thing you have picked up does — and
        // shrinks further over somewhere it would land, so it stops covering
        // what it is about to drop into.
        // Grown under the pointer only once the overview is open. The window
        // you were using starts out selected, and growing it from the first
        // frame made it the one card that did not match its window.
        scale: card.flying ? 1
             : card.dragging ? (overlay.dragTarget > 0 ? card.tileScale : (overlay.dropOnKey !== "" ? 0.4 : 0.82))
             : (card.picked && overlay.active ? 1.035 : 1)
        opacity: card.flying ? overlay.veil
               : card.shown ? (card.dragging ? 0.94 : 1)
               : card.fading ? Math.max(1 - surface.appVeil, 1 - card.along * 2.5) : 0
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
        // window popped in whole once the overview had gone.
        Behavior on opacity { enabled: !surface.sliding && !card.parked && !card.fading; NumberAnimation { duration: 150 } }

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

        ShaderEffect {
          id: shadowEffect
          readonly property int reach: Math.round((overlay.deco.border + overlay.deco.shadowRange) * surface.hyprScale)
          readonly property int corner: Math.floor((card.radius + overlay.deco.border) * surface.hyprScale)
          readonly property int spread: Math.floor(overlay.deco.shadowRange * surface.hyprScale)
          readonly property color tint: card.focusedWindow ? overlay.deco.shadowColor : overlay.deco.shadowColorInactive
          x: -reach / surface.hyprScale + overlay.deco.shadowOffsetX
          y: -reach / surface.hyprScale + overlay.deco.shadowOffsetY
          width: (card.pxW + 2 * reach) / surface.hyprScale
          height: (card.pxH + 2 * reach) / surface.hyprScale
          z: -1
          opacity: card.dressedAway
          visible: overlay.deco.shadow && spread > 0 && opacity > 0.01 && !card.dragging
          property vector4d color: Qt.vector4d(tint.r, tint.g, tint.b, tint.a)
          property vector2d fullSize: Qt.vector2d(card.pxW + 2 * reach, card.pxH + 2 * reach)
          property vector2d topLeft: Qt.vector2d(spread + corner, spread + corner)
          property vector2d bottomRight: Qt.vector2d(card.pxW + 2 * reach - (spread + corner), card.pxH + 2 * reach - (spread + corner))
          property real radius: corner
          property real range: spread
          property real shadowPower: overlay.deco.shadowPower
          property real roundingPower: overlay.deco.roundingPower
          fragmentShader: Qt.resolvedUrl("deco/shadow.frag.qsb")
        }

        ShaderEffect {
          readonly property int thickness: Math.round(overlay.deco.border * surface.hyprScale)
          readonly property color tint: card.focusedWindow ? overlay.deco.activeBorder : overlay.deco.inactiveBorder
          x: -thickness / surface.hyprScale
          y: -thickness / surface.hyprScale
          width: (card.pxW + 2 * thickness) / surface.hyprScale
          height: (card.pxH + 2 * thickness) / surface.hyprScale
          z: -1
          opacity: card.dressedAway
          visible: thickness > 0 && opacity > 0.01 && !card.dragging
          property vector4d color: Qt.vector4d(tint.r, tint.g, tint.b, tint.a)
          property vector2d fullSize: Qt.vector2d(card.pxW + 2 * thickness, card.pxH + 2 * thickness)
          property real radius: card.pxRound > 0 ? card.pxRound + thickness : 0
          property real radiusOuter: (card.radius + overlay.deco.border) * surface.hyprScale
          property real thick: thickness
          property real roundingPower: overlay.deco.roundingPower
          fragmentShader: Qt.resolvedUrl("deco/border.frag.qsb")
        }

        // What the compositor blurs behind this window: the piece of the
        // blurred screen the card is over, cut to its shape. Tiled windows
        // take it from the desktop's blur; floating ones from the blur that
        // has the tiled windows in it too, the way Hyprland stacks them.
        //
        // Outside the frame, not in it: the frame draws its contents through
        // a copy of its own, and textures read inside that never update.
        readonly property bool frostedGlass: surface.glass && overlay.wallpaper !== "" && shot.hasContent

        ShaderEffect {
          anchors.fill: parent
          visible: card.frostedGlass
          // Hyprland draws the blur whole under a see-through window unless
          // told not to; faded with the card, the sharp desktop shows through.
          opacity: overlay.deco.blurIgnoreOpacity === false ? frame.opacity : 1
          property var source: card.floating ? surface.floatBlurFor(card.modelData.key)
                             : (stage.overStrip ? baseBlur.output : wallBlur.output)
          // Where the card is on screen, scaled about its middle as it is
          // drawn, as a fraction of the screen.
          property vector4d area: {
            const w = card.width * card.scale
            const h = card.height * card.scale
            const x = card.x + (card.width - w) / 2
            const y = card.y + (card.height - h) / 2
            return Qt.vector4d(x / Math.max(1, surface.width), y / Math.max(1, surface.height),
                               w / Math.max(1, surface.width), h / Math.max(1, surface.height))
          }
          property vector2d size: Qt.vector2d(width, height)
          property real radius: card.radius
          fragmentShader: Qt.resolvedUrl("blur/frost.frag.qsb")
        }

        // Drawn as it is when its corners are square. Rounded, it goes
        // through one layer and is cut to shape on the way out — not a
        // ClippingRectangle, which keeps a second layer for the shape, and
        // reallocates and redraws both on every frame a card changes size,
        // which in a swipe is every frame, for every card.
        Rectangle {
          id: frame
          anchors.fill: parent
          layer.enabled: card.radius > 0.5
          layer.effect: ShaderEffect {
            property vector2d size: Qt.vector2d(frame.width, frame.height)
            property real radius: card.radius
            fragmentShader: Qt.resolvedUrl("deco/clip.frag.qsb")
          }
          // As see-through as Hyprland draws the window, the whole way out:
          // a card is the window, so it does not turn solid as it spreads.
          // Not in `geo` yet (Hyprland has not reported its size): the
          // snapshot it falls back to carries no opacity.
          opacity: card.real.opacity ?? 1
          // Under the capture, so a window whose first frame has not arrived
          // yet reads as a tile and not as a hole — but only as the overview
          // comes in. At the start of a swipe the card sits exactly on its
          // real window, which is still showing, so an empty card should let
          // that window through rather than flash a dark block over it.
          // Not under a see-through window's capture: square, the frame is
          // not drawn through a layer, so the backing and the capture are
          // each faded on their own and the one fills in what the other
          // lets through.
          color: card.frostedGlass || (shot.hasContent && card.real.opacity < 1) ? "transparent"
               : shot.hasContent ? "#101014" : Qt.rgba(0.063, 0.063, 0.078, overlay.veil)

          ScreencopyView {
            id: shot
            anchors.fill: parent
            captureSource: shot.cut ? null : card.modelData.capture
            // A capture that fails stays failed: nothing else asks again
            // (`captureFrame` only runs once there is a frame) and the card
            // is never rebuilt while its window stays put, so it sat as an
            // empty tile — and see-through mid-swipe — until the shell
            // restarted. Dropping the source for a moment starts a fresh one.
            property bool cut: false
            property int restarts: 0
            function restart(why) {
              if (!card.modelData.capture || shot.restarts >= 5) return
              shot.restarts++
              console.warn("aerial-capture restart " + card.modelData.key + " " + card.modelData.appId
                           + ": " + why + " (#" + shot.restarts + ")")
              shot.cut = true
              Qt.callLater(() => shot.cut = false)
            }
            onStopped: shot.restart("stopped")
            onHasContentChanged: if (shot.hasContent) {
              shot.restarts = 0
              if (surface.missed[card.modelData.key]) {
                const missed = Object.assign({}, surface.missed)
                delete missed[card.modelData.key]
                surface.missed = missed
              }
            }
            // Never quite opaque. A capture is drawn as an opaque texture —
            // copied over what is behind it, alpha and all — and a terminal's
            // see-through background then punches a hole through the
            // overview to the real windows under it, rather than showing the
            // frosted glass. Short of 1, Qt blends it like anything else. (The
            // ClippingRectangle this used to sit in hid that by drawing it
            // through a layer first.)
            opacity: 0.999
            // Never live, not even for the window under the pointer. A live
            // capture is a texture that changes every frame, and one of those
            // makes the compositor redraw this whole surface sixty times a
            // second — the wallpaper, every tile, every icon — which cost more
            // than all eight captures put together. On the clock instead, they
            // still read as alive and the surface redraws a dozen times a
            // second rather than sixty.
            // Not even at either end of a swipe, where the card hands over to
            // its window: one fresh frame is asked for as the swipe begins
            // and another as a closing card nears home (see `beat`), which is
            // as current as live was, without capturing every window on
            // screen on every frame of the swipe.
            //
            // Live only until its first frame is in: a card waits for its
            // capture before the overview can appear, and live, the first
            // frame arrives as soon as the compositor can give it.
            live: card.shown && overlay.opened && !shot.hasContent
          }

          // Failing without saying so: on screen, open, and still no frame.
          Timer {
            interval: 1000
            repeat: true
            running: card.onScreen && overlay.opened && !shot.hasContent
            onTriggered: shot.restart("no frame after 1s")
          }

          Connections {
            target: overlay
            // Only the cards you can actually see are worth a frame; the rest
            // are kept alive purely so that showing them is instant. And only
            // once they have a first frame: until then they are live anyway,
            // and asking a capture that has not started yet for a frame only
            // gets a warning back.
            function onBeatChanged() {
              if (!shot.hasContent) return
              if (card.shown || card.flying || card.fading || (overlay.priming && Math.abs(card.lane) < 1.5)) shot.captureFrame()
            }
          }

          // Coming into view does not wait for the next beat. Without this a
          // card that has just been peeked at shows its placeholder until the
          // clock comes round, which is the blank tile people saw.
          Connections {
            target: card
            function onShownChanged() { if (card.shown && shot.hasContent) shot.captureFrame() }
          }
        }

        // Hairline at rest, accent ring under the pointer, bright ring for a
        // window something is about to be dropped onto.
        Rectangle {
          anchors.fill: parent
          radius: card.radius
          color: "transparent"
          // In a tile it is a miniature, not a card you can pick: the tile's
          // own hairline is the only outline.
          border.width: card.flying ? 0 : (card.landing ? 3 : (card.picked ? 3 : 1))
          border.color: card.landing ? "#F2EFE7" : (card.picked ? Commons.Color.accent : Qt.rgba(1, 1, 1, 0.14))
          opacity: overlay.dress
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
              overlay.dragKey = card.modelData.key
              overlay.selectedKey = card.modelData.key
              card.grabX = dragger.centroid.pressPosition.x
              card.grabY = dragger.centroid.pressPosition.y
              card.centering = 0
              centeringOn.restart()
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
            card.lastDrag = Qt.rect(card.x, card.y, card.width, card.height)
            const at = dragger.centroid.scenePosition
            overlay.aimDrag(surface.workspaceAtPoint(at.x, at.y), surface.cardAtPoint(at.x, at.y))
          }
        }

        // Close it from here, rather than going there to close it.
        Rectangle {
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: 8
          width: 26
          height: 26
          radius: 13
          color: shut.hovered ? "#D2604F" : Qt.rgba(0, 0, 0, 0.62)
          border.width: 1
          border.color: Qt.rgba(1, 1, 1, 0.22)
          visible: overlay.active && card.picked && !card.dragging && !card.flying
          opacity: visible ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 110 } }

          Text {
            // Window titles are somebody else's string: a browser tab can put
            // anything in one. Rendered literally, never interpreted as markup.
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: "×"
            color: "#F4F1E9"
            font.family: Style.font.family
            font.pixelSize: Math.round(Style.font.body * 1.1)
          }

          HoverHandler { id: shut }

          TapHandler {
            onTapped: overlay.closeWindow(card.modelData.key)
          }
        }

        // The name of the window, under it, the way a caption sits under a
        // photograph — with the app's own icon, because at thumbnail size the
        // icon is what you recognise before you have read anything.
        Rectangle {
          id: captionPill
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.top: parent.bottom
          anchors.topMargin: 10
          width: Math.min(caption.implicitWidth + 20, parent.width)
          height: caption.implicitHeight + 10
          radius: height / 2
          color: card.picked ? Qt.rgba(0, 0, 0, 0.78) : Qt.rgba(0, 0, 0, 0.5)
          opacity: overlay.active && !card.flying ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 120 } }

          Row {
            id: caption
            anchors.centerIn: parent
            spacing: 7

            IconImage {
              anchors.verticalCenter: parent.verticalCenter
              implicitSize: Math.round(Style.font.caption * 1.35)
              source: card.icon
              visible: card.icon !== ""
            }

            // Which desktop a match came from, shown only when that is news:
            // while searching, and only for a window that is not on the one you
            // are already looking at.
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              visible: surface.searching
                       && overlay.wsOf(card.modelData) !== surface.shownWorkspace
              implicitWidth: elsewhere.implicitWidth + 12
              implicitHeight: elsewhere.implicitHeight + 4
              radius: surface.rounded(4)
              color: Qt.rgba(1, 1, 1, 0.14)

              Text {
                id: elsewhere
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: overlay.wsOf(card.modelData)
                color: "#F7F4EC"
                font.family: Style.font.family
                font.pixelSize: Math.round(Style.font.caption * 0.9)
                font.weight: Font.DemiBold
              }
            }

            Text {
              // Window titles are somebody else's string: a browser tab can put
              // anything in one. Rendered literally, never interpreted as markup.
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, card.width - 40)
              // Live while it can be seen, from the window itself; not
              // listening otherwise, so a retitle with the overview put away
              // costs nothing.
              text: captionPill.opacity > 0 && card.real !== card.modelData
                    ? ((card.modelData.top && card.modelData.top.title) || "") : card.modelData.title
              elide: Text.ElideRight
              color: card.picked ? "#F7F4EC" : "#C9C3B9"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }

    // ------------------------------------------------------ an empty desktop
    // Says so, and slides with the rest, so a desktop with nothing on it
    // arrives as a place rather than as a gap.
    Repeater {
      model: surface.following ? overlay.lanes : []

      delegate: Text {
        id: nothing
        required property var modelData
        readonly property real lane: overlay.laneOf(nothing.modelData)
        textFormat: Text.PlainText
        visible: overlay.active && !overlay.everything && !surface.searching && overlay.peek <= 0
                 && Math.abs(nothing.lane) < 1
                 && !surface.monitorWindows.some(w => overlay.wsOf(w) === nothing.modelData)
        x: (surface.width - nothing.width) / 2 + nothing.lane * surface.width
        y: surface.stripHeight + (surface.height - surface.stripHeight - nothing.height) / 2
        text: "No windows on " + nothing.modelData
        color: Qt.rgba(1, 1, 1, 0.42)
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }

    // ----------------------------------------------------------- the filter
    // Only ever on the screen you are typing at, and only once you have typed.
    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      y: surface.stripHeight + 14
      visible: surface.leading && (overlay.filter !== "" || overlay.appOnly !== "")
      width: query.implicitWidth + 34
      height: query.implicitHeight + 20
      radius: height / 2
      color: Qt.rgba(0, 0, 0, 0.72)
      border.width: 1
      border.color: Qt.rgba(1, 1, 1, 0.16)
      opacity: overlay.veil

      Text {
        // Window titles are somebody else's string: a browser tab can put
        // anything in one. Rendered literally, never interpreted as markup.
        textFormat: Text.PlainText
        id: query
        anchors.centerIn: parent
        // Opened for one app: its name stands where the typing would.
        readonly property string appName: {
          if (overlay.appOnly === "") return ""
          const entry = DesktopEntries.heuristicLookup(overlay.appOnly)
          return entry && entry.name ? entry.name : overlay.appOnly
        }
        text: (overlay.filter !== "" ? overlay.filter : appName) + "   " + surface.shownWindows.length
              + (surface.shownWindows.length === 1 ? " window" : " windows")
        color: surface.shownWindows.length === 0 ? "#D2604F" : "#F2EFE7"
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }
  }

  // ------------------------------------------------ where a desktop swipe is
  // Swiping between desktops from the desktop slides only the windows, so
  // between two empty ones nothing on screen moved. A row of dots, one for
  // each desktop you can slide to, with a mark that follows the fingers;
  // hollow where a desktop has nothing on it. Outside `stage`, which is
  // hidden the moment the slide lands, so it can linger and fade.
  Item {
    id: deskDots
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
    Behavior on shown { NumberAnimation { duration: deskDots.wanted ? 220 : 260; easing.type: Easing.OutCubic } }
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
    Behavior on lift { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
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
}
