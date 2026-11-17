import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import "../../look" as Looks
import "../app/Layout.js" as Layout

// What one screen's overview is, and draws: when it can show, what it shows, where
// the spread and the strip go, and the stack of everything in it, in paint order.
// Surface.qml is the window around it.
//
// Its id is `surface` because that is what it is to all it holds: each of them takes
// this as `surface`.
Item {
  id: surface

  required property var overlay
  required property var screenInfo

  readonly property string monitorName: surface.screenInfo ? surface.screenInfo.name : ""
  readonly property var monitor: (Hyprland.monitors.values || []).find(m => m.name === surface.monitorName) || null
  readonly property bool leading: surface.monitorName === overlay.leadMonitor
  // Showing what the screen swiped on shows — the same desktop, peeked at or
  // slid to with it — rather than only its own: the leading screen, or every
  // screen when they are one desktop.
  readonly property bool following: surface.leading || overlay.synced

  /** This screen's workspace for a desktop in the strip. */
  function spaceHere(desk) { return overlay.spaceOn(desk, surface.monitorName) }

  // For what the look draws on this screen's page (see look/Look.qml).
  readonly property alias wallImage: backdrop.wall
  readonly property alias wallBlurOutput: blurs.wallOutput
  readonly property alias baseBlurOutput: blurs.baseOutput

  // The desktop this screen is on, as Hyprland has it.
  readonly property int ownDesk: surface.monitor && surface.monitor.activeWorkspace
                                 ? overlay.deskOfId(surface.monitor.activeWorkspace.id) : -1

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
  // A window being carried: what it has behind it moves, over the strip.
  readonly property bool overStrip: overlay.dragKey !== ""

  // For a delegate that takes the surface: from inside one, `surface` is its own
  // property of that name, ahead of the id.
  readonly property var thisSurface: surface

  // Corners follow Hyprland's decoration:rounding: each shape keeps its own
  // radius as a ceiling, so square-cornered setups (rounding 0) get square
  // tiles and cards, and rounded ones look as they always have.
  function rounded(r) { return Math.min(r, overlay.deco.rounding) }

  // The floating windows' cards on screen, bottom to top, in the order
  // Hyprland draws them (see `zOrder`). One fading out stays among them until
  // it has gone (see `stacked` in Card.qml).
  readonly property var floatStack: {
    const out = []
    for (let i = 0; i < floatCards.count; i++) {
      const card = floatCards.itemAt(i)
      if (!card || !card.stacked) continue
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
  function floatBlurFor(key) { return blurs.floatBlurFor(key) }

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
                                  && (overlay.wallpaper === "" || backdrop.ready)
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
    surface.Window.window.update()
  }
  Connections {
    target: surface.settling ? surface.Window.window : null
    function onFrameSwapped() {
      if (++surface.settled < surface.settleFrames) {
        surface.Window.window.update()
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
      if (overlay.screenOf(win) !== surface.monitorName) continue
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
    // Even at both ends: eased out only, most of the fade was over in the
    // first few frames and the windows seemed to blink away.
    duration: 320
    easing.type: Easing.InOutQuad
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

      // The wallpaper (see Backdrop.qml).
      Backdrop {
        id: backdrop
        surface: surface
      }

      Rectangle {
        anchors.fill: parent
        visible: !overlay.look.hidesPlainDim
        color: "#07070A"
        opacity: (overlay.wallpaper === "" ? 0.93 : 0) * overlay.veil
      }

      Looks.LookSlot {
        anchors.fill: parent
        file: overlay.look.pageLayer
        given: ({ surface: surface })
      }

      MouseArea {
        anchors.fill: parent
        onClicked: overlay.dismiss()
      }

      // ------------------------------------------------------------ the strip
      Strip { surface: surface }

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
          color: overlay.look.dim(Qt.rgba(1, 1, 1, 0.45))
          opacity: overlay.veil
          font.family: Style.font.family
          font.pixelSize: overlay.look.primaryText(Style.font.caption)
          font.weight: Font.DemiBold
        }
      }
    }

    Item {
      id: tiledLayer
      anchors.fill: parent

      // Diffed rather than replaced: a window carried here from another
      // screen adds its own card, and every other card keeps its capture.
      Repeater {
        id: tiledCards
        model: ScriptModel { values: surface.monitorWindows.filter(w => !w.floating) }
        delegate: cardDelegate
      }
    }
  }

  Item {
    id: floatLayer
    anchors.fill: parent

    Repeater {
      id: floatCards
      model: ScriptModel { values: surface.monitorWindows.filter(w => w.floating) }
      delegate: cardDelegate
    }
  }

  DragVisitor { surface: surface }

  // What frosts the cards (see BlurStack.qml): only ever drawn into textures,
  // here so as to be in the scene.
  BlurStack {
    id: blurs
    anchors.fill: parent
    surface: surface
    sourceBase: base
    sourceLower: lower
  }

  // ------------------------------------------------------------ the windows
  // One card, drawn in whichever layer its window belongs to.
  Component {
    id: cardDelegate

    Card {
      surface: thisSurface
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
      color: overlay.look.dim(Qt.rgba(1, 1, 1, 0.42))
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
    radius: overlay.look.corner(height / 2)
    color: Qt.rgba(0, 0, 0, 0.72)
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.16)
    opacity: overlay.veil

    Text {
      // What was typed, or a window's app id: never interpreted as markup.
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
      color: surface.shownWindows.length === 0 ? overlay.look.alertText("#D2604F") : overlay.look.ink("#F2EFE7")
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
  }
}
