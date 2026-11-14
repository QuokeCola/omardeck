pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import qs.Commons as Commons
import "plugins/quokecola.omardeck/notifications" as Plugin

// The real panel and the real store (see sheet-harness.sh for what it runs on): what
// the states look like, saved for looking at, and the behaviour that only exists
// in the running tree. Named s00...s99 so they run in this order.
ShellRoot {
  id: root
  readonly property string theme: Quickshell.env("TEST_THEME")
  readonly property string out: Quickshell.env("TEST_OUT")
  readonly property bool holoTheme: theme === "death-stranding"
  Plugin.Service { id: store }
  // The Xvfb screen as drawn: the backdrop, then the sheet composited over it.
  Process { id: grabber }
  PanelWindow {
    id: window
    visible: true
    screen: Quickshell.screens[0]
    implicitHeight: 32
    anchors { top: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "#808080"
    Item {
      id: bar
      width: parent.width
      height: 32
      property string position: "top"
      property int barSize: 32
      property string fontFamily: "JetBrainsMono Nerd Font"
      property color barForeground: Commons.Color.foreground
      property color urgent: Commons.Color.urgent
      property bool vertical: false
      property bool hideLabels: false
      property bool foregroundAnimationEnabled: false
      property var activePopout: false
      function requestPopout(key) { activePopout = key }
      function releasePopout(key) { if (activePopout === key) activePopout = false }
      Plugin.Panel { id: panel; bar: bar; settings: ({}) }
    }
    property bool ready: false
    Timer { interval: 1200; running: true; onTriggered: window.ready = true }
    TestCase {
      id: tc
      name: "Sheet"
      when: window.ready
      // QtTest keeps its messages to itself here: say what failed before it does.
      function cmp(a, b, what) {
        if (a !== b) console.log("FAIL! " + (what || "") + ": got " + a + ", wanted " + b)
        compare(a, b, what)
      }
      function chk(ok, what) {
        if (!ok) console.log("FAIL! " + (what || "unnamed check"))
        verify(ok, what)
      }
      function waitFor(cond, ms, what) {
        var left = ms || 2000
        while (!cond() && left > 0) { wait(20); left -= 20 }
        chk(cond(), what)
      }
      function control(name) {
        var item = findChild(panel, name)
        // A Repeater's items are only reachable through the visual tree.
        if (item === null && name !== "notificationSearch") {
          var walk = function(from) {
            if (from.objectName === name) return from
            for (var i = 0; i < from.children.length; i++) {
              var hit = walk(from.children[i])
              if (hit) return hit
            }
            return null
          }
          item = walk(control("notificationSearch").Window.contentItem)
        }
        chk(item !== null, "Missing " + name)
        return item
      }
      function maybe(name) { return findChild(panel, name) }
      function shot(name, colour) {
        var content = control("notificationSearch").Window.contentItem
        var back = Qt.createQmlObject('import QtQuick; Rectangle { anchors.fill: parent; z: -1000; color: "' + (colour || "#ffffff") + '" }', content)
        wait(120)
        grabber.command = ["import", "-window", "root", root.out + "/" + root.theme + "-" + name + ".png"]
        grabber.running = true
        wait(50)
        waitFor(function() { return !grabber.running }, 5000)
        back.destroy()
        wait(20)
      }
      // Rows as they stand: everything named `name` inside the list.
      function rowItems(name) {
        var found = []
        function walk(item) {
          if (!item) return
          if (item.objectName === name && item.visible) found.push(item)
          var kids = item.children
          for (var i = 0; i < kids.length; i++) walk(kids[i])
        }
        walk(panel.list.contentItem)
        return found
      }
      function headerRow(app) {
        for (var i = 0; i < panel.rows.length; i++)
          if (panel.rows[i].kind === "header" && panel.rows[i].group.app === app) return i
        return -1
      }
      // QtTest aims keys at the focus window, or failing that its own. X with no window
      // manager has no focus window, and this case lives in the bar's, so the keys
      // go through a case that lives in the sheet's.
      property var sheetKeys: null
      function press(key) {
        if (!sheetKeys)
          sheetKeys = Qt.createQmlObject('import QtTest; TestCase { name: "SheetKeys"; when: false; optional: true }', control("notificationSearch").Window.contentItem)
        sheetKeys.keyClick(key)
        wait(30)
      }
      function focusedName() {
        var item = control("notificationSearch").Window.activeFocusItem
        return item ? item.objectName : "(none)"
      }

      function initTestCase() {
        panel.open()
        waitFor(function() { return panel.opened === true }, 5000, "opened of panel")
        waitFor(function() { return store.entries.length === 10 })
        wait(700)
        control("notificationSearch").Window.window.requestActivate()
        wait(100)
        console.log("INFO scale", Commons.Style.space(100), "urgent", Commons.Color.urgent, "caption", Commons.Style.font.caption, "holo", panel.holo, "rows", panel.rows.length)
        cmp(panel.holo, root.holoTheme)
      }

      function test_s00_render_normal() {
        shot("normal-white", "#ffffff")
        shot("normal-cloud", "#D0D8E0")
        shot("normal-dark", "#10202c")
        panel.toggleGroup("Build")
        wait(600)
        shot("stack-open-white", "#ffffff")
        panel.toggleGroup("Build")
        wait(600)
      }

      function test_s10_time_column() {
        var times = rowItems("notificationHeaderTime")
        chk(times.length >= 5, "got " + times.length)
        var edges = times.map(function(t) { return Math.round(t.mapToItem(panel.list, t.width, 0).x) })
        console.log("MEASURE time column right edges", JSON.stringify(edges))
        if (root.holoTheme) cmp(Math.max.apply(null, edges), Math.min.apply(null, edges), "one column")
        else chk(Math.max.apply(null, edges) - Math.min.apply(null, edges) > 0, "plain keeps its layout")
      }

      function test_s11_critical_label() {
        var tags = rowItems("notificationCriticalTag")
        if (!root.holoTheme) { cmp(tags.length, 0); return }
        cmp(tags.length, 2, "one unread and one read critical on screen")
        var header = rowItems("notificationHeaderCritical")
        cmp(header.length, 1, "the fold says what it hides")
        cmp(header[0].text, "1 critical")
        var loud = tags.filter(function(t) { return t.color.a > 0 })
        cmp(loud.length, 1, "only the unread one is filled")
      }

      function test_s12_unread_mark() {
        var marks = rowItems("notificationUnreadMark")
        if (!root.holoTheme) { cmp(marks.length, 0); return }
        cmp(marks.length, 3, "the front card of each of the three unread rows")
        var tags = rowItems("notificationHeaderNew")
        cmp(tags.length, 3)
        chk(tags.some(function(t) { return t.text === "3 new" }))
        chk(tags.some(function(t) { return t.text === "new" }))
      }

      function test_s13_font_floor() {
        // No text below 9 under the theme.
        if (!root.holoTheme) return
        var low = []
        function walk(item) {
          if (!item) return
          if (item.font !== undefined && item.text !== undefined && item.visible && item.text !== "" && item.font.pixelSize < 9) low.push(item.text)
          var kids = item.children
          for (var i = 0; i < kids.length; i++) walk(kids[i])
        }
        walk(control("notificationSearch").Window.contentItem)
        cmp(low.length, 0, "below the floor: " + low.join(", "))
      }

      function test_s20_hover_x_on_single() {
        panel.list.positionViewAtBeginning()
        wait(50)
        var buttons = rowItems("notificationCardDismiss")
        if (!root.holoTheme) { cmp(buttons.length, 0); return }
        cmp(buttons.length, 7 - 2, "the singles, not the two folded stacks")
        cmp(buttons[0].opacity, 0)
        var card = buttons[0].parent
        mouseMove(card, 20, 10)
        tryCompare(buttons[0], "opacity", 1)
        shot("hover-single-white", "#ffffff")
        mouseMove(panel.list, -40, 2)
        wait(40)
      }

      function test_s30_clear_all_asks_first() {
        var before = store.entries.length
        mouseClick(control("clearAllNotifications"))
        cmp(panel.confirmAll, true)
        cmp(store.entries.length, before, "nothing yet")
        wait(50)
        // The sheet is still live underneath.
        chk(panel.list.enabled)
        var keep = control("confirmKeep")
        waitFor(function() { return keep.activeFocus }, 1000, "focus on Keep")
        shot("confirm-clear-white", "#ffffff")
        // A double click on the trash lands inside the guard: not an answer.
        panel.confirmArmedAt = Date.now()
        panel.answerConfirm()
        cmp(panel.confirmAll, true, "a second press this soon does nothing")
        press(Qt.Key_Escape)
        cmp(panel.confirmAll, false, "Esc keeps")
        cmp(panel.opened, true, "and does not close the sheet")
        cmp(store.entries.length, before)
      }

      function test_s31_keyboard_reaches_header() {
        // Up from the top of the list.
        panel.keyboardNavigation = false
        panel.cursorIndex = -1
        var clear = control("clearAllNotifications"), more = control("notificationMore")
        waitFor(function() { return panel.confirmOpen === false }, 5000, "confirmOpen of panel")
        panel.moveCursor(0, 1)
        cmp(panel.cursorIndex, 0)
        panel.moveCursor(0, -1)
        waitFor(function() { return clear.activeFocus })
        cmp(clear.border.width, 1, "the focus ring shows")
        shot("focus-clear-white", "#ffffff")
        press(Qt.Key_Right)
        waitFor(function() { return more.activeFocus }, 1000, "Right moves to More, focus on " + focusedName())
        cmp(more.border.width, 1)
        press(Qt.Key_Return)
        var menu = control("notificationOverflowMenu")
        waitFor(function() { return menu.visible === true }, 5000, "visible of menu")
        wait(150)
        shot("menu-white", "#ffffff")
        press(Qt.Key_Escape)
        waitFor(function() { return menu.visible === false }, 5000, "visible of menu")
        waitFor(function() { return more.activeFocus })
        press(Qt.Key_Left)
        waitFor(function() { return clear.activeFocus })
        press(Qt.Key_Return)
        cmp(panel.confirmAll, true, "Return on Clear-all asks")
        var keep = control("confirmKeep"), action = control("confirmAction")
        waitFor(function() { return keep.activeFocus })
        press(Qt.Key_Delete)
        cmp(panel.confirmAll, true, "a second Delete is no answer")
        cmp(store.entries.length, 10)
        press(Qt.Key_Left)
        waitFor(function() { return action.activeFocus })
        press(Qt.Key_Right)
        waitFor(function() { return keep.activeFocus })
        press(Qt.Key_Return)
        cmp(panel.confirmAll, false, "Keep")
        waitFor(function() { return clear.activeFocus }, 1000, "focus returns to the button")
        cmp(store.entries.length, 10)
        press(Qt.Key_Down)
        waitFor(function() { return !clear.activeFocus })
        cmp(panel.cursorIndex, 0, "Down goes back to the list")
      }

      function test_s32_stack_x_asks_and_single_does_not() {
        panel.keyboardNavigation = true
        var build = headerRow("Build")
        chk(build >= 0)
        panel.cursorIndex = build
        panel.activateCursor(true)
        cmp(panel.confirmGroup, "Build", "Delete on a stack asks")
        cmp(store.entries.length, 10)
        wait(100)
        shot("confirm-stack-white", "#ffffff")
        // The rest of the sheet still answers: a card elsewhere can be dismissed.
        panel.dropConfirm()
        cmp(panel.confirmGroup, "")

        // Through the pointer, and said yes to.
        panel.requestRemoveGroup(panel.rows[build].group)
        cmp(panel.confirmGroup, "Build")
        panel.confirmArmedAt = Date.now() - 1000
        panel.answerConfirm()
        waitFor(function() { return store.entries.length === 7 }, 3000, "the stack went, got " + store.entries.length)
        cmp(panel.confirmGroup, "")

        // A single row goes in one action, by the same key.
        var backup = headerRow("Backup")
        panel.cursorIndex = backup
        panel.activateCursor(true)
        cmp(panel.confirmGroup, "", "a single row does not ask")
        waitFor(function() { return store.entries.length === 6 }, 3000)
      }

      function test_s40_error_and_settings() {
        store.removalError = "Could not dismiss notifications. Try again."
        wait(80)
        shot("error-white", "#ffffff")
        store.removalError = ""
        panel.openSettings()
        wait(400)
        shot("settings-white", "#ffffff")
        panel.closeSettings()
        wait(200)
        keyCatcherFocus()
      }
      function keyCatcherFocus() { panel.startSearch(); wait(60); panel.endSearch(); wait(60) }

      function test_s50_overswipe() {
        // Stretch the sheet as a trackpad overswipe does: the frame's clip must hold.
        var popup = findChild(panel, "notificationCenterPopup")
        chk(popup !== null, "the popup")
        popup.dragTo(1.4)
        chk(popup.slideProgress > 1 && popup.slideProgress < 1.15, "rubber band, got " + popup.slideProgress)
        shot("overswipe-white", "#ffffff")
        popup.release(true)
        waitFor(function() { return !popup.gestureSettling }, 4000, "the spring settles")
        cmp(Math.abs(popup.slideProgress - 1) < 0.01, true, "and lands home, got " + popup.slideProgress)
      }

      function test_s60_no_results() {
        panel.startSearch()
        wait(100)
        control("notificationSearch").text = "zzzz"
        wait(400)
        shot("no-results-white", "#ffffff")
        panel.endSearch()
        wait(300)
      }

      function test_s70_reduced_motion() {
        Commons.Style.reduceMotion = true
        wait(30)
        // A stack folds and unfolds at once.
        var key = "Chat"
        panel.toggleGroup(key)
        wait(40)
        var row = rowItems("notificationCardDismiss")
        chk(row.length > 0)
        panel.toggleGroup(key)
        wait(40)
        // A row removal lands in one go.
        var before = store.entries.length
        var cal = headerRow("Calendar")
        panel.requestRemoveGroup(panel.rows[cal].group)
        waitFor(function() { return store.entries.length === before - 1 }, 3000)
        wait(60)
        cmp(panel.list.count, panel.rows.length, "the row is out of the list already")
        chk(panel.list.contentHeight > 0 && isFinite(panel.list.contentHeight), "no NaN reaches the layout")
        // Following the fingers stays direct; what comes after they lift lands at once.
        var popup = findChild(panel, "notificationCenterPopup")
        popup.dragTo(0.5)
        cmp(popup.slideProgress, 0.5, "the swipe still tracks")
        popup.release(true)
        cmp(popup.slideProgress, 1, "no spring")
        cmp(popup.gestureSettling, false, "and nothing left settling")
        popup.dragTo(0.5)
        popup.release(false)
        cmp(popup.slideProgress, 0, "no settle")
        popup.release(true)
        // By key: no travel either way.
        panel.close()
        wait(30)
        cmp(panel.opened, false)
        cmp(popup.slideProgress, 0, "shut at once")
        panel.open()
        wait(40)
        cmp(panel.opened, true)
        cmp(popup.slideProgress, 1, "open at once")
        Commons.Style.reduceMotion = false
        wait(30)
      }

      function test_s80_clear_all_answered_then_empty() {
        panel.requestClearAll()
        cmp(panel.confirmAll, true)
        panel.confirmArmedAt = Date.now() - 1000
        panel.answerConfirm()
        waitFor(function() { return store.entries.length === 0 }, 3000, "cleared, got " + store.entries.length)
        wait(600)
        cmp(panel.confirmAll, false)
        var empty = control("notificationEmptyState")
        chk(empty.visible)
        if (root.holoTheme) cmp(empty.text, "No notifications")
        shot("empty-white", "#ffffff")
        shot("empty-dark", "#10202c")
        // Nothing to clear, so the keyboard lands on More.
        panel.moveCursor(0, -1)
        waitFor(function() { return control("notificationMore").activeFocus })
        keyCatcherFocus()
      }

      function test_s81_loading_and_failed_load() {
        store.loaded = false
        wait(80)
        shot("loading-white", "#ffffff")
        store.loadError = "Could not refresh notification history. Reopen the center to retry."
        wait(80)
        if (root.holoTheme) cmp(control("notificationEmptyState").text, "History unavailable")
        shot("load-error-white", "#ffffff")
        store.loaded = true
        store.loadError = ""
      }

      onCompletedChanged: if (completed) {
        console.log("VERDICT " + (qtest_results.failCount === 0 ? "ok" : qtest_results.failCount + " failing"))
        Qt.quit()
      }
    }
  }
}
