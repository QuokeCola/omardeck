pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Controls as Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

import "." as Plugin
import "Model.js" as Model
import "BrowserIdentity.js" as BrowserIdentity
import "Preferences.js" as Preferences
import "components"

// A notification center for Omarchy: everything you were sent, still there
// when you go back for it.
//
// Omarchy already writes every notification to disk: one JSON file per popup
// under ~/.local/state/omarchy/notifications/, moved into history/ when it
// leaves the screen. That is where these come from, and nothing here writes to
// those directories. What it is not is a history you can read: it holds ten
// files, deletes the eleventh, and deletes the icon it was keeping for it at
// the same time. Ten is the right number for a service whose job is replaying
// the toasts you just missed, and far too few for the question this panel
// exists to answer, which is "what did that say".
//
// So `bin/notification-center` copies each file out of there the moment it
// lands, into an archive kept for as long as you asked for, icon and all. It
// follows the directory with inotify rather than polling it, so a notification
// is in the archive before its toast has finished appearing.
//
// Glyphs are \u escapes rather than literal characters, so the source survives
// editors and patches that mangle private-use codepoints.
Panel {
  id: root
  objectName: "notificationCenterPanel"

  function open() {
    preparePopup()
    // Build and lay out the list before mapping so the first frame has its final height.
    if (rowsDirty) rebuild(true)
    if (list) list.forceLayout()
    controller.show()
  }

  moduleName: "quokecola.omardeck"
  ipcTarget: "quokecola.omardeck.notifications"

  readonly property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  readonly property color foreground: Commons.Color.popups.text
  readonly property bool holo: holoFrame.item ? holoFrame.item.active : false
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // Sentences read in the sans under the holographic theme; the bar's mono stays
  // for what is measured or short. The family is what the toasts resolve to here.
  readonly property string copyFamily: holo ? "sans-serif" : fontFamily
  readonly property color errorText: Commons.Color.pick("holo.text-alert", Commons.Color.urgent)
  // A theme's urgent isn't promised to read as small text, so only this theme's is used.
  readonly property color confirmInk: holo ? errorText : foreground
  readonly property color dimText: Commons.Color.pick("holo.text-dim", Util.alpha(foreground, 0.6))
  readonly property color sectionLine: Qt.alpha(Commons.Color.pick("holo.line", foreground), Commons.Color.pickAlpha("holo.line-alpha", 0.12))

  // ----------------------------------------------------------------- settings

  readonly property int panelWidth: setting("panelWidth", 420)
  readonly property int listHeight: setting("listHeight", 0)
  readonly property string badge: setting("badge", "Dot")
  readonly property int keepDays: setting("keepDays", 30)
  readonly property int maxItems: setting("maxItems", 1000)
  readonly property string clickAction: setting("clickAction", "Auto")
  readonly property bool compact: setting("compact", false)
  readonly property bool useBrowserFavicons: setting("useBrowserFavicons", true)
  readonly property string browserGrouping: setting("browserGrouping", "browser")
  onBrowserGroupingChanged: { expandedGroups = ({}); rebuild() }
  onUseBrowserFaviconsChanged: rebuild()
  readonly property bool showBody: setting("showBody", true)
  readonly property bool showPreview: setting("showPreview", true)

  // ------------------------------------------------------------- the service

  readonly property bool dnd: store ? store.doNotDisturb : false
  function toggleDnd() { if (store) store.toggleDnd() }

  property bool editingSettings: false
  property string settingsError: ""
  property var pendingPreferences: ({})
  property var preferenceActive: null

  function openSettings() {
    moreMenu.close()
    endSearch()
    dropConfirm()
    editingSettings = true
    settingsError = ""
    settingsPane.resetScroll()
    Qt.callLater(function() { if (root.opened) settingsPane.focusBack() })
  }
  function closeSettings() {
    editingSettings = false
    Qt.callLater(function() { if (root.opened) moreButton.forceActiveFocus() })
  }
  function savePreference(key, value) {
    if (!Preferences.valid(key, value)) { settingsError = "Invalid setting."; return }
    settingsError = ""
    // Serialize edits across the widget and service; collapse queued edits to the same key.
    pendingPreferences[key] = {key:key,value:value}
    flushPreferences()
  }
  function flushPreferences() {
    if (preferenceActive !== null) return
    var keys = Object.keys(pendingPreferences)
    if (!keys.length) return
    var next = pendingPreferences[keys[0]]
    delete pendingPreferences[keys[0]]
    preferenceActive = next
    preferencesSave.command = Preferences.saveCommand(next.key, next.value)
    preferencesSave.running = true
  }
  function finishPreference(code, status, output) {
    var active = preferenceActive
    if (!active) return
    if (code !== 0 || status !== 0 || output.trim() !== "ok") {
      settingsError = "Could not save settings. Try again."
      console.warn("Notification center: settings save failed for", active.key)
    }
    preferenceActive = null
    Qt.callLater(root.flushPreferences)
  }
  Process {
    id: preferencesSave
    stdout: StdioCollector { id: preferenceOutput; waitForEnd: true }
    onExited: function(code, status) { root.finishPreference(code, status, preferenceOutput.text) }
  }
  Timer {
    interval: 5000
    running: root.preferenceActive !== null
    onTriggered: {
      if (preferencesSave.running) preferencesSave.signal(9)
      else root.finishPreference(1, 0, "")
    }
  }

  // ------------------------------------------------------------- the store
  //
  // The archive is a shell service, not a child of this widget. Omarchy
  // builds a bar per monitor, and a Process in here would be one watcher
  // per screen: unread and clear would stick to whichever copy you clicked.
  readonly property var store: Plugin.ServiceRegistry.instance

  onStoreChanged: {
    // Let dependent bindings and the row model finish initializing first.
    Qt.callLater(function() { root.pushSettings(); root.rebuild() })
  }

  function pushSettings() {
    if (!store) return
    store.keepDays = keepDays
    store.maxItems = maxItems
    store.showPreview = showPreview
  }

  onKeepDaysChanged: pushSettings()
  onMaxItemsChanged: pushSettings()
  onShowPreviewChanged: pushSettings()

  Connections {
    target: root.store
    function onEntryAdded(entry) { root.handleEntryAdded(entry) }
    function onEntriesReset() { root.rebuild() }
    function onSwipe(kind, progress, velocity) { root.followSwipe(kind, progress, velocity) }
    function onBrowserIconsUpdated() { root.rebuild() }
  }

  // ------------------------------------------------------------------ swipe
  //
  // The store streams trackpad swipes (see bin/edge-swipe). "open" starts at
  // the right edge with the panel shut; "close" is any rightward swipe while
  // it is open. Progress is 1 for a full panel width along the swipe; the
  // sheet tracks it and, on release, settles where the distance or the flick
  // says. Only the panel on the focused monitor answers.
  property string swipeKind: ""

  function onFocusedScreen() {
    var focused = Hyprland.focusedMonitor
    return !!popup.screen && !!focused && focused.name === popup.screen.name
  }

  function followSwipe(kind, progress, velocity) {
    if (kind === "begin-open") {
      swipeKind = !root.opened && onFocusedScreen() ? "open" : ""
    } else if (kind === "begin-close") {
      swipeKind = root.opened && onFocusedScreen() ? "close" : ""
    } else if (kind === "move") {
      if (swipeKind === "open") popup.dragTo(progress)
      else if (swipeKind === "close") popup.dragTo(1 - progress)
    } else if (kind === "end" && swipeKind !== "") {
      // Past a third of the way, or flicked, it goes; a flick back the other
      // way cancels even past the halfway mark.
      var go = velocity > 0.9 || (progress > 0.35 && velocity > -0.6)
      var toOpen = swipeKind === "open" ? go : !go
      swipeKind = ""
      popup.release(toOpen)
      if (toOpen && !root.opened) root.open()
      else if (!toOpen && root.opened) root.close()
    }
  }

  // ----------------------------------------------------------------- overview
  //
  // Swiping Aerial's overview up while the sheet is out slides the sheet off
  // the edge under the same fingers, and back if the swipe is let go short;
  // once the overview has opened, the center closes. Opened from a key, the
  // overview takes the sheet with it on a curve of its own. Opened while the
  // overview is already up, the sheet stays on top of it. See the store.
  property bool aboveOverview: false
  property real overviewYield: 0
  readonly property real overviewFingers: store ? store.overviewFingers : -1
  readonly property bool overviewShowing: store ? store.overviewShowing : false

  function settleYield(target) {
    yieldSettle.stop()
    yieldSettle.to = target
    yieldSettle.duration = Style.duration(Math.max(120, 300 * Math.abs(target - overviewYield)))
    yieldSettle.start()
  }

  NumberAnimation {
    id: yieldSettle
    target: root
    property: "overviewYield"
    easing.type: Easing.OutCubic
  }

  onOverviewFingersChanged: {
    if (overviewFingers < 0 || aboveOverview) return
    yieldSettle.stop()
    overviewYield = overviewFingers
  }

  onOverviewShowingChanged: {
    if (overviewShowing) {
      // From a key: no fingers to follow.
      if (!aboveOverview && overviewFingers < 0) settleYield(1)
    } else {
      aboveOverview = false
      settleYield(0)
    }
  }

  Connections {
    target: root.store
    function onOverviewLanding(opening) {
      if (!root.aboveOverview) root.settleYield(opening ? 1 : 0)
    }
    function onOverviewStateChanged() {
      if (root.store.overviewOpen && root.opened && !root.aboveOverview) root.close()
    }
  }

  // -------------------------------------------------------------------- state

  readonly property var entries: store ? store.entries : []
  property string filter: ""
  // What the rows are marked against. Opening the center makes everything in
  // it read, so marking against `lastSeen` would mean the list never once
  // shows you which of these you had not seen, because the marks would be gone by the
  // time it finished drawing. This holds the reading from the moment before
  // you opened it, which is the question you were asking.
  property double readMark: 0
  readonly property bool loaded: store ? store.loaded : false
  property bool searching: false
  property double now: Date.now()

  readonly property int unread: store ? store.unread : 0
  readonly property bool hasCriticalUnread: store ? store.hasCriticalUnread : false
  readonly property double lastSeen: store ? store.lastSeen : 0

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.now = Date.now()
  }

  function startSearch() {
    dropConfirm()
    searching = true
    Qt.callLater(function() { if (root.opened && root.searching && search) search.forceActiveFocus() })
  }

  function endSearch() {
    searching = false
    filter = ""
    if (search) search.text = ""
    Qt.callLater(function() { if (root.opened && keyCatcher) keyCatcher.forceActiveFocus() })
  }

  // ------------------------------------------------------------ app colours
  //
  // Urgent cards are marked in the colour of the app that sent them, except
  // under the holographic theme, where a green or cyan critical would say
  // the wrong thing and they all wear the theme's red. Each icon is drawn once into a small hidden canvas and read back; the result,
  // or null for an icon with no colour of its own, is kept for the session.
  property var appTints: ({})
  property int appTintsVersion: 0
  property var tintQueue: []

  function iconUrl(value) {
    value = String(value || "")
    if (!value) return ""
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    return Quickshell.iconPath(value, true)
  }

  function tintFor(group) {
    appTintsVersion
    var url = group ? iconUrl(group.appIcon) : ""
    if (!url) return Commons.Color.urgent
    if (!(url in appTints)) {
      if (tintQueue.indexOf(url) < 0) tintQueue.push(url)
      Qt.callLater(function() { tinter.next() })
      return Commons.Color.urgent
    }
    return appTints[url] || Commons.Color.urgent
  }

  function storeTint(url, rgb) {
    var next = Object.assign({}, appTints)
    if (rgb) {
      // Keep the hue, but hold saturation and lightness where a thin line
      // and a faint wash both read on a dark surface.
      var c = Qt.rgba(rgb.r, rgb.g, rgb.b, 1)
      next[url] = Qt.hsla(c.hslHue, Math.max(0.55, c.hslSaturation),
                          Math.min(0.68, Math.max(0.55, c.hslLightness)), 1)
    } else next[url] = null
    appTints = next
    appTintsVersion++
  }
  Connections {
    target: root.store
    function onFocusCompleted() { root.close() }
  }

  function remove(key) {
    if (store) store.remove(key)
  }

  function clearAll() {
    if (store) store.clearAll()
  }

  // ------------------------------------------------------------- confirmation
  //
  // Clear-all and dismissing a whole stack can't be undone, so they ask once, in
  // the row they would act on. The sheet stays live around the question: scrolling,
  // opening a card and dismissing another still work. A single notification never
  // asks, whichever way it is dismissed.
  property bool confirmAll: false
  property string confirmGroup: ""
  property double confirmArmedAt: 0
  // Whether Keep should hand focus back to the Clear-all button or to the list.
  property bool confirmFromButton: false
  readonly property bool confirmOpen: confirmAll || confirmGroup !== ""

  function requestClearAll() {
    if (entries.length === 0) return
    confirmFromButton = clearButton.activeFocus
    confirmGroup = ""
    confirmAll = true
    confirmArmedAt = Date.now()
  }

  function requestRemoveGroup(group) {
    if (!Model.removalNeedsConfirm(group)) { removeGroup(group); return }
    confirmFromButton = false
    confirmAll = false
    confirmGroup = group.key
    confirmArmedAt = Date.now()
  }

  // Put the question away and leave the keyboard somewhere that works.
  function dropConfirm() {
    if (!confirmOpen) return
    var toButton = confirmFromButton && confirmAll
    confirmAll = false
    confirmGroup = ""
    confirmFromButton = false
    if (!root.opened) return
    if (toButton) clearButton.forceActiveFocus()
    else keyCatcher.forceActiveFocus()
  }

  function answerConfirm() {
    if (!Model.confirmSettled(confirmArmedAt, Date.now())) return
    var everything = confirmAll
    var key = confirmGroup
    confirmFromButton = false
    dropConfirm()
    if (everything) clearAll()
    else {
      var header = rows.find(function(row) { return row.kind === "header" && row.group.key === key })
      if (header) removeGroup(header.group)
    }
  }

  // The stack it was asking about has gone: emptied elsewhere, or scrolled away.
  function confirmTargetGone(key) {
    if (confirmGroup === key) dropConfirm()
  }

  // Esc walks back one thing at a time before it closes the sheet.
  function stepBack() {
    if (confirmOpen) dropConfirm()
    else if (headerFocused()) keyCatcher.forceActiveFocus()
    else if (searching) endSearch()
    else close()
  }

  // ---------------------------------------------------------- header by keyboard
  //
  // Tab belongs to the bar (it switches panels), so the header actions are reached
  // the way the list is: Up from the top of the list, Left and Right between them,
  // Down back into the list. They hold real focus, so their own ring and key
  // handling are the same ones a pointer-opened menu returns to.
  function headerFocused() {
    return clearButton.activeFocus || moreButton.activeFocus
  }

  function focusHeaderActions() {
    keyboardNavigation = false
    cursorIndex = -1
    cursorDismiss = false
    if (clearButton.enabled) clearButton.forceActiveFocus()
    else moreButton.forceActiveFocus()
  }

  function handleEntryAdded(entry) {
    if (!entry || !entry.key) return
    if (root.opened && store) store.markSeen()
    rebuild()
    if (root.opened && list && list.atYBeginning) Qt.callLater(function() {
      if (root.opened && list) list.positionViewAtBeginning()
    })
  }

  // ----------------------------------------------------------------- the list

  readonly property NotificationList list: listLoader.item
  readonly property real listAvailableHeight: {
    var chrome = header.height + (removalError.visible ? removalError.implicitHeight : 0)
      + content.spacing * (1 + Number(removalError.visible)) + Style.space(10)
    return Math.max(Style.space(100), popup.usableCardHeight - popup.verticalContentInset - chrome)
  }
  property bool rowsDirty: true
  property var rows: []
  property var expandedGroups: ({})
  property int cursorIndex: -1
  property bool cursorDismiss: false
  property bool keyboardNavigation: false
  // A header action holds the keyboard. Only for what the subtitle says: the
  // handlers ask headerFocused(), which reads the same focus at the moment of the key.
  readonly property bool headerKeys: clearButton.activeFocus || moreButton.activeFocus

  function rebuild(forOpening) {
    // The archive and unread count stay live; display groups are needed only while open.
    if (!root.opened && forOpening !== true) { rowsDirty = true; return }
    rowsDirty = false
    var focused = cursorIndex >= 0 && cursorIndex < rows.length ? rows[cursorIndex].id : ""
    var next = Model.stackRows(entries, expandedGroups, filter, browserGrouping, BrowserIdentity)
    var index = next.findIndex(function(row) { return row.id === focused })
    var headers = next.filter(function(row) { return row.kind === "header" })
    headers.forEach(function(row) {
      row.group.favicon = root.useBrowserFavicons && store ? store.faviconSource(row.group.iconEntry) : ""
    })
    rows = next
    if (confirmAll && entries.length === 0) dropConfirm()
    if (confirmGroup !== "" && !next.some(function(row) {
      return row.kind === "header" && row.group.key === confirmGroup && Model.removalNeedsConfirm(row.group)
    })) dropConfirm()
    if (useBrowserFavicons && store) store.warmBrowserIcons(headers.map(function(row) { return row.group.iconEntry }).filter(Boolean))
    cursorIndex = index >= 0 ? index : Math.min(cursorIndex, rows.length - 1)
  }

  function toggleGroup(key) {
    var next = Object.assign(Object.create(null), expandedGroups)
    next[key] = !next[key]
    expandedGroups = next
    // Rows this rebuild adds or drops belong to the stack, not to arrivals or
    // dismissals: they slide out from under the card above, or back beneath it.
    if (list) list.stackingGroup = key
    stackingDone.restart()
    rebuild()
  }

  Timer {
    id: stackingDone
    // Longer than the staggered motion of a tall stack's visible cards.
    interval: 800
    onTriggered: if (root.list) root.list.stackingGroup = ""
  }

  function removeGroup(group) {
    if (store) store.removeMany(group.entries.map(function(entry) { return entry.key }))
  }

  function moveCursor(dx, dy) {
    dropConfirm()
    if (headerFocused()) {
      if (dy < 0) return
      if (dx) {
        if (clearButton.activeFocus) moreButton.forceActiveFocus()
        else if (clearButton.enabled) clearButton.forceActiveFocus()
        return
      }
      if (rows.length === 0) return
      keyCatcher.forceActiveFocus()
      cursorIndex = -1
    } else if (rows.length === 0 || (dy < 0 && cursorIndex <= 0)) {
      if (dy) focusHeaderActions()
      return
    }
    keyboardNavigation = true
    if (dy) {
      cursorIndex = Math.max(0, Math.min(rows.length - 1, cursorIndex + dy))
      cursorDismiss = false
    } else {
      if (cursorIndex < 0) cursorIndex = 0
      cursorDismiss = dx > 0
    }
    list.positionViewAtIndex(cursorIndex, ListView.Contain)
  }

  function activateCursor(removeOnly) {
    if (cursorIndex < 0 || cursorIndex >= rows.length) return
    var row = rows[cursorIndex]
    if (removeOnly || cursorDismiss) {
      if (row.kind === "header") requestRemoveGroup(row.group)
      else remove(row.entry.key)
    } else if (row.kind === "header" || isFolded(row)) {
      if (row.group.entries.length > 1) toggleGroup(row.group.key)
    } else activate(row.entry)
  }

  function isFolded(row) {
    return !!row && row.kind === "message" && !row.expanded && row.group.entries.length > 1
  }

  onFilterChanged: rebuild()

  // --------------------------------------------------------------- activating

  function activate(row) {
    if (!row || clickAction === "Nothing") return
    if (store) store.focusNotification(row, clickAction === "Auto")
  }

  // ---------------------------------------------------------------- lifecycle

  Component.onCompleted: pushSettings()

  onOpenedChanged: {
    // Action feedback belongs to this panel visit, not the persistent archive.
    if (store) store.focusError = ""
    if (!opened) {
      dropConfirm()
      moreMenu.close()
      editingSettings = false
      searching = false
      filter = ""
      if (search) search.text = ""
      return
    }
    // Opened over the overview, the sheet belongs on top of it.
    aboveOverview = overviewShowing
    if (aboveOverview) { yieldSettle.stop(); overviewYield = 0 }
    now = Date.now()
    keyboardNavigation = false
    cursorIndex = -1
    cursorDismiss = false
    if (store) store.load()
    readMark = lastSeen
    if (store) store.markSeen()
    if (rowsDirty) rebuild()
  }

  // --------------------------------------------------------------------- bar

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    bar: root.bar

    // A bell, and a bell with a line through it while notifications are
    // silenced. The second is the same glyph the shell's own DND indicator
    // uses, so the bar never shows two different pictures of one state.
    // U+F009B (bell-off) and U+F009A (bell), written as surrogate pairs so the
    // source survives editors that mangle private-use codepoints. The first is
    // the glyph the shell's own DND indicator uses, so the bar never shows two
    // different pictures of one state.
    text: root.dnd ? "\uDB80\uDC9B" : "\uDB80\uDC9A"
    dimmed: root.dnd

    // The Highlight marker: no shape added beside the bell, the bell itself
    // recoloured. BarIconButton already draws its glyph in activeColor while
    // active, which is the same mechanism the bar's own indicators use to say
    // a thing wants you, so this is that state rather than a second drawing of
    // it. Accent instead of the inherited urgent, because unread mail is not
    // an emergency.
    active: root.badge === "Highlight" && root.unread > 0
    activeColor: Commons.Color.accent
    tooltipText: {
      if (root.dnd) return root.unread > 0
        ? "Silenced · " + root.unread + " new" : "Notifications silenced"
      if (root.unread === 1) return "1 new notification"
      if (root.unread > 1) return root.unread + " new notifications"
      return "Notifications"
    }

    onPressed: function(b) {
      // Right-click silences without opening anything, because deciding you
      // want quiet and wanting to read the backlog are opposite impulses.
      if (b === Qt.RightButton) {
        root.toggleDnd()
        return
      }
      root.toggle()
    }
  }

  // Where the panel hangs from: a zero-width point far past the right edge of
  // any screen. Invisible, in the layout for nothing, and read only for its
  // position; see the anchor comment on the panel itself.
  Item {
    id: rightAnchor
    anchors.top: button.top
    anchors.bottom: button.bottom
    x: 1000000
    width: 1
    visible: false
  }

  // The Dot marker, drawn over the bell rather than beside it: a bar that
  // changes width every time a message arrives is a bar that twitches all day.
  Rectangle {
    id: dot
    visible: root.badge === "Dot" && root.unread > 0
    anchors.right: button.right
    anchors.rightMargin: Style.space(6)
    anchors.top: button.top
    anchors.topMargin: Style.space(10)
    // Critical is also a longer bar under the holographic theme: not only a colour.
    width: Style.space(root.holo && root.hasCriticalUnread ? 12 : 6)
    height: Style.space(6)
    radius: root.holo ? 0 : height / 2
    color: root.hasCriticalUnread ? root.urgent : Commons.Color.accent
  }

  Rectangle {
    id: countBadge
    visible: root.badge === "Count" && root.unread > 0
    anchors.right: button.right
    anchors.rightMargin: Style.space(1)
    anchors.top: button.top
    anchors.topMargin: Style.space(3)
    width: Math.max(countText.implicitWidth + Style.space(6), Style.space(12))
    height: Style.space(12)
    radius: root.holo ? 0 : height / 2
    color: Commons.Color.accent

    Text {
      textFormat: Text.PlainText
      id: countText
      anchors.centerIn: parent
      // Past ninety-nine the number has stopped being information and the
      // badge is only saying "a lot", which it can say in three characters.
      text: root.unread > 99 ? "99+" : String(root.unread)
      font.family: root.fontFamily
      font.pixelSize: Math.max(root.holo ? 9 : 8, Style.font.caption - Style.space(3))
      font.bold: true
      color: Commons.Color.background
    }
  }

  // ------------------------------------------------------------------- panel

  // Keep the controller alive; release only the view after close animations finish.
  property bool popupContentActive: false
  function preparePopup() {
    popupUnload.stop()
    popupContentActive = true
  }
  Connections {
    target: root
    function onOpenedChanged() {
      if (root.opened) root.preparePopup()
      else popupUnload.restart()
    }
  }
  Timer {
    id: popupUnload
    interval: 1000
    onTriggered: {
      if (!root.opened && !popup.visible) {
        root.popupContentActive = false
        root.rows = []
        root.expandedGroups = ({})
        root.cursorIndex = -1
        root.rowsDirty = true
      }
    }
  }
  NotificationPopup {
    id: popup
    objectName: "notificationCenterPopup"
    // Anchored to a point past the right edge of the screen rather than to the
    // bell. KeyboardPanel clamps its card inside the screen, so an anchor out
    // there always resolves to hard against the right edge, whatever the bar
    // has been rearranged into since. This is the one panel in the bar with a
    // fixed home: a notification center that opened in a different place
    // depending on how many widgets were to its left would be a notification
    // center you have to look for.
    anchorItem: rightAnchor
    bar: root.bar
    owner: root
    open: root.opened
    yieldTo: root.overviewYield
    focusTarget: root.editingSettings ? settingsPane : keyCatcher
    padding: 0
    // A sheet along the screen edge: square, flush with the bar, the side
    // and the bottom, and it slides in from that edge rather than fading.
    margin: 0
    gap: 0
    cornerRadius: 0
    slideIn: true
    borderSpec: root.holo ? Border.flat("transparent", 0) : Border.flat(Qt.alpha(Commons.Color.popups.text, 0.15), 1)
    // With frosted glass on (the overview's setting, shared with this
    // panel), translucent so the compositor's blur shows through; cards stay
    // opaque on top of it.
    surfaceColor: root.holo ? "transparent" : Qt.alpha(Commons.Color.popups.background, root.setting("frost", true) !== false ? 0.72 : 1)
    contentWidth: popup.fittedContentWidth(Style.space(root.panelWidth))
    // A column down the whole side of the screen, from under the bar to the
    // bottom, whatever it holds. A listHeight setting still opts back into a
    // card that fits its content: fittedContentHeight() clamps against
    // availableCardHeight, which collapses to its 120px minimum under a
    // screen-sized bar window (see usableCardHeight below), so that fit is
    // done here against the corrected ceiling.
    contentHeight: root.listHeight > 0
      ? Math.round(Math.min(
          Math.max(popup.verticalContentInset, content.implicitHeight + Style.space(10) + popup.verticalContentInset),
          popup.usableCardHeight))
      : Math.round(popup.usableCardHeight)

    Behavior on contentHeight {
      enabled: root.opened && root.listHeight > 0
      NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic }
    }

    // The stock omarchy bar window is only as tall as the bar strip, so the
    // screen minus that window is the space a panel has. Some bars draw their
    // strip inside a screen-sized window instead, which makes KeyboardPanel
    // mistake the whole screen for the bar and collapse to its 120px safety
    // minimum - a card a few entries tall no matter how much room there is.
    // Measure the strip itself when the window is screen-sized; both bars
    // expose barSize, so this works under either host.
    readonly property real usableCardHeight: {
      if (barH >= screenH && root.bar && Number(root.bar.barSize) > 0)
        return Math.max(120, screenH - (Number(root.bar.barSize) + gap + margin))
      return availableCardHeight
    }
    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the search field has the focus it owns every key, including the
      // ones this would otherwise read as navigation.
      blocked: search.activeFocus || root.editingSettings || moreMenu.visible
      onCloseRequested: root.stepBack()
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor(false)
      onDeleteRequested: root.activateCursor(true)
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        // "/" is the only key that starts a search, because a panel that
        // started filtering on any keypress would be a panel that swallows
        // whatever you were typing in the window underneath.
        if (text === "/") root.startSearch()
      }

      // Draws one queued icon at a time for tintFor(). Invisible, but it has
      // to stay in the scene for the canvas to paint.
      Canvas {
        id: tinter
        width: 32
        height: 32
        opacity: 0
        property string current: ""
        function next() {
          if (current || root.tintQueue.length === 0) return
          current = root.tintQueue.shift()
          tintTimeout.restart()
          if (isImageLoaded(current)) requestPaint()
          else loadImage(current)
        }
        function finish(rgb) {
          tintTimeout.stop()
          var url = current
          current = ""
          if (url) root.storeTint(url, rgb)
          Qt.callLater(next)
        }
        onImageLoaded: if (current && isImageLoaded(current)) requestPaint()
        onPaint: {
          if (!current || !isImageLoaded(current)) return
          var ctx = getContext("2d")
          ctx.reset()
          ctx.drawImage(current, 0, 0, width, height)
          finish(Model.dominantColor(ctx.getImageData(0, 0, width, height).data))
        }
        Timer {
          id: tintTimeout
          // An icon that never loads keeps the default colour.
          interval: 2000
          onTriggered: tinter.finish(null)
        }
      }

      // The holographic theme's shared panel (see quokecola.hud).
      // Bleeding past the top like every other side puts the frame's full density
      // behind the header. The clip is what keeps it off the bar, and takes the
      // frame's top marks with it.
      Item {
        id: holoClip
        readonly property int bleed: holoFrame.item ? holoFrame.item.pad : 0
        anchors.fill: parent
        anchors.leftMargin: -bleed
        anchors.rightMargin: -bleed
        anchors.bottomMargin: -bleed
        clip: root.holo
        Loader {
          id: holoFrame
          anchors.fill: parent
          anchors.topMargin: -holoClip.bleed
          source: Qt.resolvedUrl("../../quokecola.hud/holo/HoloFrame.qml")
        }
      }
      // The frame's side marks land on whichever section line is showing.
      Binding {
        target: holoFrame.item
        when: !!holoFrame.item
        property: "dividerY"
        value: holoClip.bleed + (root.editingSettings ? settingsPane.ruleY : header.height - 1)
      }

      Column {
        id: content
        anchors.fill: parent
        spacing: Style.space(8)

        // -------------------------------------------------------- header

        Item {
          id: header
          visible: !root.editingSettings
          width: parent.width
          height: Style.space(58)

          Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: root.sectionLine
          }

          Repeater {
            model: root.confirmAll ? 1 : 0
            NotificationConfirm {
              objectName: "notificationClearConfirm"
              required property int index
              readonly property var question: Model.clearAllQuestion(root.entries.length)
              anchors.left: header.left
              anchors.leftMargin: Style.space(16)
              anchors.right: header.right
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: header.verticalCenter
              height: implicitHeight
              message: question.message
              actionLabel: question.action
              foreground: root.foreground
              danger: root.confirmInk
              fontFamily: root.copyFamily
              messageSize: root.holo ? Style.font.body : Style.font.caption
              buttonSize: root.holo ? Style.font.bodySmall : Style.font.caption
              onConfirmed: root.answerConfirm()
              onKept: root.dropConfirm()
            }
          }

          Column {
            id: title
            anchors.left: parent.left
            anchors.leftMargin: Style.space(16)
            width: Math.max(0, searchControl.x - x - Style.space(8))
            opacity: root.searching ? 0 : 1
            visible: opacity > 0 && !root.confirmAll
            Behavior on opacity { NumberAnimation { duration: Style.duration(100) } }
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            Text {
              textFormat: Text.PlainText
              width: parent.width
              elide: Text.ElideRight
              text: "Notifications"
              font.bold: true
              color: root.foreground
              font.family: root.copyFamily
              font.pixelSize: root.holo ? Style.font.title : Style.font.body
            }
            Text {
              textFormat: Text.PlainText
              width: parent.width
              elide: Text.ElideRight
              objectName: "notificationSubtitle"
              text: {
                if (root.holo && root.headerKeys) return "\u2190 \u2192 move  \u2193 list  Enter select"
                if (root.holo && root.keyboardNavigation) return "\u2191 actions  Enter open  x dismiss"
                var count = Model.unreadState(root.entries, root.readMark).unread
                if (root.dnd) return root.holo ? "Do not disturb \u00B7 " + count + " unread" : "Do not disturb"
                return count + " unread"
              }
              color: root.dimText
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Row {
            id: actions
            visible: !root.confirmAll
            anchors.right: parent.right
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            NotificationAction {
              id: clearButton
              objectName: "clearAllNotifications"
              iconName: "trash"
              tooltipText: "Clear all notifications"
              foreground: Qt.alpha(root.foreground, 0.65)
              hoverForeground: Commons.Color.urgent
              enabled: root.entries.length > 0
              onClicked: root.requestClearAll()
            }
            NotificationAction {
              id: moreButton
              objectName: "notificationMore"
              iconName: "more"
              tooltipText: "More options"
              foreground: Qt.alpha(root.foreground, 0.65)
              onClicked: moreMenu.visible ? moreMenu.close() : moreMenu.open()
            }
          }

          Controls.Menu {
            id: moreMenu
            objectName: "notificationOverflowMenu"
            x: Math.max(0, header.width - width - Style.space(12))
            y: header.height - Style.space(6)
            width: Math.min(Style.space(248), header.width - Style.space(24))
            padding: Style.space(5)
            closePolicy: Controls.Popup.CloseOnEscape | Controls.Popup.CloseOnPressOutside
            onClosed: Qt.callLater(function() { if (root.opened && !root.editingSettings) moreButton.forceActiveFocus() })
            background: BorderSurface { color: Commons.Color.popups.background; borderSpec: Border.flat(Qt.alpha(root.foreground, 0.15), 1); radius: Style.cornerRadius * 2 }
            Controls.MenuItem {
              id: muteItem
              objectName: "notificationMute"
              text: root.dnd ? "Allow notifications" : "Silence notifications"
              enabled: !!root.store && !root.store.dndBusy
              implicitHeight: Style.space(42)
              contentItem: RowLayout {
                spacing: Style.space(10)
                NotificationAction { iconName: root.dnd ? "bellOff" : "bell"; size: Style.space(24); foreground: root.dnd ? Commons.Color.accent : root.foreground; enabled: false; opacity: 1; Accessible.ignored: true }
                Text { text: muteItem.text; textFormat: Text.PlainText; font.family: root.copyFamily; font.pixelSize: Style.font.caption; color: root.foreground; Layout.fillWidth: true; wrapMode: Text.WordWrap }
              }
              background: Rectangle { color: muteItem.highlighted ? Qt.alpha(root.foreground, 0.08) : "transparent"; radius: Style.cornerRadius * 2 }
              onTriggered: root.toggleDnd()
            }
            Controls.MenuItem {
              id: settingsItem
              objectName: "notificationSettings"
              text: "Settings"
              implicitHeight: Style.space(42)
              contentItem: RowLayout {
                spacing: Style.space(10)
                NotificationAction { iconName: "settings"; size: Style.space(24); foreground: root.foreground; enabled: false; opacity: 1; Accessible.ignored: true }
                Text { text: settingsItem.text; textFormat: Text.PlainText; font.family: root.copyFamily; font.pixelSize: Style.font.caption; color: root.foreground; Layout.fillWidth: true }
              }
              background: Rectangle { color: settingsItem.highlighted ? Qt.alpha(root.foreground, 0.08) : "transparent"; radius: Style.cornerRadius * 2 }
              onTriggered: root.openSettings()
            }
          }

          Rectangle {
            id: searchControl
            visible: !root.confirmAll
            anchors.right: actions.left
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            width: root.searching ? actions.x - Style.space(20) : Style.space(32)
            height: Style.space(32)
            radius: Math.min(Style.space(7), Style.cornerRadius)
            color: root.searching ? Qt.alpha(root.foreground, 0.055) : "transparent"
            border.width: search.activeFocus ? 1 : 0
            border.color: Commons.Color.accent
            // Clipping this rounded surface cuts off its antialiased focus outline.
            antialiasing: true
            border.pixelAligned: false
            Behavior on width { NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }

            NotificationAction {
              iconName: "search"
              tooltipText: "Search notifications  ( / )"
              foreground: root.searching ? Commons.Color.accent : Qt.alpha(root.foreground, 0.65)
              onClicked: root.startSearch()
            }
            TextField {
              id: search
              objectName: "notificationSearch"
              x: Style.space(32)
              width: Math.max(0, parent.width - Style.space(64))
              height: parent.height
              visible: root.searching
              enabled: root.searching
              placeholderText: "Search"
              foreground: root.foreground
              placeholderTextColor: Qt.alpha(root.foreground, 0.45)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              leftPadding: 0
              rightPadding: 0
              topPadding: 0
              bottomPadding: 0
              verticalAlignment: TextInput.AlignVCenter
              background: Item {}
              onTextChanged: root.filter = text
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) { event.accepted = true; root.endSearch() }
                else if (event.key === Qt.Key_Down) {
                  event.accepted = true
                  keyCatcher.forceActiveFocus()
                  root.cursorIndex = -1
                  root.moveCursor(0, 1)
                }
              }
              // Keep the query while handing keyboard navigation to its results.
              onAccepted: {
                keyCatcher.forceActiveFocus()
                root.cursorIndex = -1
                root.moveCursor(0, 1)
              }
            }
            NotificationAction {
              anchors.right: parent.right
              visible: root.searching
              iconName: "close"
              tooltipText: "Close search  ( Esc )"
              foreground: Qt.alpha(root.foreground, 0.65)
              onClicked: root.endSearch()
            }
          }
        }

        Text {
          id: removalError
          x: Style.space(14)
          width: parent.width - Style.space(28)
          textFormat: Text.PlainText
          text: root.store ? root.store.dndError || root.store.focusError || root.store.loadError || root.store.removalError : ""
          visible: !root.editingSettings && text !== ""
          color: root.errorText
          font.family: root.copyFamily
          font.pixelSize: root.holo ? Style.font.body : Style.font.caption
          wrapMode: Text.WordWrap
        }

        // ---------------------------------------------------------- list

        Loader {
          id: listLoader
          width: parent.width
          active: true
          visible: !root.editingSettings && (root.rows.length > 0 || (item && item.contentHeight > 0))
          // Keep the lightweight list; detach its model to release delegates after fade-out.
          sourceComponent: Component {
            NotificationList {
              id: list
              width: parent.width
              // Construct only visible rows when restoring the detached model.
              cacheBuffer: 0
              wheelStep: Style.space(96)
              scrollbarWidth: Style.space(6)
              scrollbarInset: Style.space(2)
              // The flattened model keeps expanded stacks within the same virtualized list.
              readonly property int cap: root.listHeight > 0
                ? Math.min(Style.space(root.listHeight), root.listAvailableHeight) : root.listAvailableHeight

              implicitHeight: root.listHeight > 0
                ? Math.min(Math.max(contentHeight, root.rows.length > 0 ? Style.space(100) : 0), cap) : cap
              visible: root.rows.length > 0 || contentHeight > 0
              rows: root.rows
              contentActive: root.popupContentActive
              animateChanges: root.opened
              entranceDistance: Style.space(8)
              spacing: 0

              delegate: Item {
                id: delegateRoot
                required property string rowId
                // Qt can deliver removal after the source map has already advanced.
                property var retainedData: null
                property var modelData: list.rowsById[rowId] || retainedData
                onModelDataChanged: if (modelData) retainedData = modelData
                required property int index
                property real entranceOffset: 0
                property bool retired: false
                // 1 is laid out in the list, 0 is tucked behind the front card of
                // its stack. The slot height, the slide and the shrink are all
                // linear in this one value, so they can never drift apart.
                property real reveal: 1
                // Position within the stack: 0 is the front card (and headers).
                readonly property int stackDepth: modelData && modelData.kind === "message"
                  ? modelData.depth || 0 : 0
                readonly property bool stacking: !!modelData && modelData.kind === "message"
                  && list.stackingGroup !== "" && modelData.group.key === list.stackingGroup
                readonly property real cardHeight: rowLoader.item && rowLoader.item.cardHeight !== undefined
                  ? rowLoader.item.cardHeight : rowLoader.implicitHeight
                // Only looked up while the card is, or may start, moving: every
                // other use is scaled by (1 - reveal). Keeps a row registering
                // elsewhere in the list from re-evaluating every card.
                readonly property var front: (stacking || reveal < 1) && stackDepth > 0
                  ? list.liveRow("entry:" + modelData.group.entries[0].key) : null
                // Tucked geometry, shared with the folded edges NotificationRow
                // draws, so a card that finishes folding lands exactly on them.
                readonly property real tuckScale: stackDepth === 1 ? 0.94 : 0.88
                readonly property real tuckPeek: Style.space(stackDepth === 1 ? 7 : 13)
                // How far the card moves, in list coordinates, to put its bottom
                // just below the front card's. Without a front card on screen it
                // slides out of its own slot instead.
                readonly property real tuckShift: front
                  ? front.y + front.cardHeight + tuckPeek - cardHeight - y
                  : -rowLoader.implicitHeight
                // A card taller than the front one is cut to its height while
                // tucked, so it never shows above the stack.
                readonly property real hiddenTop: front
                  ? Math.max(0, cardHeight - front.cardHeight) * (1 - reveal) : 0

                // Shallower cards paint over deeper ones, so cards pass behind.
                z: -stackDepth
                clip: reveal < 1 && !front
                enabled: !retired
                transform: Translate { y: delegateRoot.entranceOffset }
                Component.onCompleted: {
                  list.registerRow(rowId, delegateRoot)
                  if (stacking && stackDepth > 0) {
                    reveal = 0
                    unstackMotion.start()
                  }
                }
                Component.onDestruction: list.unregisterRow(rowId, delegateRoot)
                SequentialAnimation {
                  id: unstackMotion
                  PauseAnimation { duration: Style.duration(Math.max(0, Math.min(delegateRoot.stackDepth - 1, 5)) * 30) }
                  NumberAnimation { target: delegateRoot; property: "reveal"; to: 1; duration: Style.duration(340); easing.type: Easing.BezierSpline; easing.bezierCurve: [0.8, 0, 0.2, 1, 1, 1] }
                }
                ListView.delayRemove: root.popupContentActive && (exitMotion.running || stackMotion.running)
                ListView.onRemove: {
                  // An invisible window does not advance row exit animations.
                  if (!root.popupContentActive) return
                  // Freeze departing content until Qt finishes its removal transition.
                  modelData = modelData
                  retired = true
                  if (stacking) {
                    unstackMotion.stop()
                    stackMotion.start()
                  } else exitMotion.start()
                }
                SequentialAnimation {
                  id: exitMotion
                  NumberAnimation { target: delegateRoot; property: "opacity"; to: 0; duration: Style.duration(120); easing.type: Easing.OutCubic }
                  // Let ListView lay out the shrinking space, including its scroll extent.
                  NumberAnimation { target: delegateRoot; property: "height"; to: 0; duration: Style.duration(140); easing.type: Easing.OutCubic }
                }
                SequentialAnimation {
                  id: stackMotion
                  // Deeper cards set off first, so each one goes behind a card
                  // that is still there to hide it.
                  PauseAnimation { duration: Style.duration(Math.max(0, 4 - Math.min(delegateRoot.stackDepth - 1, 4)) * 20) }
                  NumberAnimation { target: delegateRoot; property: "reveal"; to: 0; duration: Style.duration(300); easing.type: Easing.BezierSpline; easing.bezierCurve: [0.8, 0, 0.2, 1, 1, 1] }
                }
                width: list.width
                height: rowLoader.implicitHeight * reveal

                Item {
                  id: stackWindow
                  // Full width, so a clipped card still shows its urgent line in
                  // the margin beside it.
                  y: delegateRoot.hiddenTop
                  width: parent.width
                  height: rowLoader.implicitHeight - y
                  clip: delegateRoot.hiddenTop > 0
                  transform: [
                    Scale {
                      readonly property real s: 1 - (1 - delegateRoot.reveal) * (1 - delegateRoot.tuckScale)
                      origin.x: stackWindow.width / 2
                      origin.y: delegateRoot.cardHeight - delegateRoot.hiddenTop
                      xScale: s
                      yScale: s
                    },
                    Translate { y: (1 - delegateRoot.reveal) * delegateRoot.tuckShift }
                  ]

                  Loader {
                    id: rowLoader
                    // ListView positions delegates; inset their content instead of the delegate itself.
                    x: Style.space(14)
                    y: -delegateRoot.hiddenTop
                    width: parent.width - Style.space(28)
                    sourceComponent: delegateRoot.modelData.kind === "header" ? headerDelegate : messageDelegate
                  }
                }
                Component {
                  id: headerDelegate
                  NotificationStackHeader {
                    compact: root.compact
                    group: delegateRoot.modelData.group
                    expanded: delegateRoot.modelData.expanded
                    now: root.now
                    readMark: root.readMark
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    holo: root.holo
                    copyFamily: root.copyFamily
                    danger: root.confirmInk
                    confirming: root.confirmGroup !== "" && root.confirmGroup === group.key
                    hasCursor: root.keyboardNavigation && root.cursorIndex === delegateRoot.index
                    dismissHasCursor: hasCursor && root.cursorDismiss
                    onPointerUsed: root.keyboardNavigation = false
                    onToggleRequested: root.toggleGroup(group.key)
                    onRemoveRequested: root.requestRemoveGroup(group)
                    onConfirmed: root.answerConfirm()
                    onKept: root.dropConfirm()
                    Component.onDestruction: if (confirming) root.confirmTargetGone(group.key)
                  }
                }
                Component {
                  id: messageDelegate
                  NotificationRow {
                    compact: root.compact
                    entry: delegateRoot.modelData.entry
                    first: delegateRoot.modelData.first
                    last: delegateRoot.modelData.last
                    layered: delegateRoot.modelData.layered
                    // Only the last card of a folded stack draws the edges.
                    tuckedCardsLive: delegateRoot.modelData.last && delegateRoot.modelData.layered
                      && list.hasTuckedCards(delegateRoot.modelData.group)
                    expanded: delegateRoot.modelData.expanded
                    groupCritical: delegateRoot.modelData.group.critical
                    groupEntries: delegateRoot.modelData.group.entries
                    accent: root.holo ? Commons.Color.urgent : root.tintFor(delegateRoot.modelData.group)
                    holo: root.holo
                    copyFamily: root.copyFamily
                    readMark: root.readMark
                    settle: delegateRoot.reveal
                    now: root.now
                    showBody: root.showBody
                    showPreview: root.showPreview
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    hasCursor: root.keyboardNavigation && root.cursorIndex === delegateRoot.index
                    dismissHasCursor: hasCursor && root.cursorDismiss
                    onPointerUsed: root.keyboardNavigation = false
                    // A folded stack's front card unfolds it; once open, each
                    // card acts on its own notification.
                    onClicked: root.isFolded(delegateRoot.modelData)
                      ? root.toggleGroup(delegateRoot.modelData.group.key)
                      : root.activate(entry)
                    onRemoveRequested: root.remove(entry.key)
                  }
                }
              }
            }
          }
        }

        // --------------------------------------------------------- empty

        Text {
          textFormat: Text.PlainText
          x: Style.space(14)
          width: parent.width - Style.space(28)
          visible: !root.editingSettings && root.rows.length === 0 && (!list || list.contentHeight <= 0)
          horizontalAlignment: Text.AlignHCenter
          topPadding: Style.space(22)
          bottomPadding: Style.space(22)
          objectName: "notificationEmptyState"
          text: root.holo
              ? Model.emptyCopy(root.loaded, root.filter, root.store ? root.store.loadError : "")
              : !root.loaded ? "Reading the archive…"
              : root.filter !== "" ? "Nothing matches “" + root.filter + "”"
              : "Nothing has come in yet"
          wrapMode: Text.WordWrap
          font.family: root.copyFamily
          font.pixelSize: root.holo ? Style.font.body : Style.font.caption
          color: root.holo ? root.dimText : root.foreground
          opacity: root.holo ? 1 : 0.55
        }

        SettingsPane {
          id: settingsPane
          objectName: "notificationSettingsPane"
          width: parent.width
          height: Math.min(implicitHeight, Math.max(Style.space(100), popup.usableCardHeight - popup.verticalContentInset - Style.space(10)))
          visible: root.editingSettings
          settings: root.settings
          saving: root.preferenceActive !== null
          holo: root.holo
          monoFamily: root.fontFamily
          error: root.settingsError
          onSave: function(key, value) { root.savePreference(key, value) }
          onBack: root.closeSettings()
        }

      }
    }
  }

}
