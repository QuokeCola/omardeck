"""Exercise the real panel against disposable configuration."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

from favicon_test import png

source = Path(__file__).resolve().parents[1]
base = Path(tempfile.mkdtemp(prefix="foamy-center-settings-"))
app = base / "app"
app.mkdir()
for name in ["Commons", "Ui"]:
    (app / name).symlink_to("/usr/share/omarchy/shell/" + name, target_is_directory=True)
(app / "plugin").symlink_to(source, target_is_directory=True)
home = base / "home"
config = home / ".config/omarchy/shell.json"
config.parent.mkdir(parents=True)
original = {"version": 1, "other": "preserved", "bar": {"layout": {"right": [{"id": "quokecola.omardeck", "browserGrouping": "hostname"}]}}}
config.write_text(json.dumps(original))
cli = base / "bin"
cli.mkdir()
(cli / "python3").symlink_to("/usr/bin/python3")
(cli / "omarchy-shell").write_text("#!/bin/sh\nexec qs ipc -n -p " + str(app) + " call \"$@\"\n")
(cli / "omarchy-shell").chmod(0o755)
image = home / "screenshot with spaces.png"
image.write_bytes(png())
(home / "editor-ready").write_text("")
(cli / "tensaku-edit").write_text('#!/bin/bash\ngrep -q ready "$HOME/editor-ready" || exit 3\nprintf "%s" "$1" > "$HOME/editor-opened"\nsleep 1\n')
(cli / "tensaku-edit").chmod(0o755)
history = home / ".local/state/omarchy/notifications/history"
history.mkdir(parents=True)
stamp = int(time.time() * 1000)
(history / f"{stamp}-1.json").write_text(json.dumps({"timestamp":stamp,"app":"omarchy-action","summary":"Screenshot saved to clipboard and file","body":"Edit with Super + Alt + , (or click this)","image":str(image),"execArgv":json.dumps(["tensaku-edit",str(image)])}))
(app / "shell.qml").write_text('''pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons as Commons
import "plugin" as Plugin
ShellRoot {
  id: root
  property var config: ({})
  property bool failSave: false
  property bool finished: false
  property bool dnd: false
  Component.onCompleted: {
    Commons.Color.background = "#24273a"; Commons.Color.foreground = "#cad3f5"; Commons.Color.accent = "#8aadf4"
  }
  IpcHandler {
    target: "notifications"
    function isDnd(): string { return root.dnd ? "on" : "off" }
    function toggleDnd(): string { root.dnd = !root.dnd; return root.dnd ? "on" : "off" }
  }
  FileView {
    id: configFile
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.config = JSON.parse(text())
  }
  // Model the host's widget endpoint.
  IpcHandler {
    target: "shell"
    function setBarWidget(id: string, key: string, valueJson: string, selectorJson: string): string {
      if (root.failSave) return "fixture save failure"
      var next = JSON.parse(configFile.text())
      if (id !== "quokecola.omardeck") return "invalid widget"
      next.bar.layout.right[0][key] = JSON.parse(valueJson)
      configFile.setText(JSON.stringify(next))
      root.config = next
      return "ok"
    }
  }
  Plugin.Service { id: store }
  FileView { id: editorReady; path: Quickshell.env("HOME") + "/editor-ready" }
  PanelWindow {
    id: window
    visible: true
    screen: Quickshell.screens[0]
    implicitHeight: 32
    anchors { top: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "foamy-settings-test-bar"
    color: Commons.Color.background
    Item {
      id: bar
      width: parent.width
      height: 32
      property string position: "top"
      property int barSize: 32
      property string fontFamily: "sans-serif"
      property color barForeground: Commons.Color.foreground
      property color urgent: Commons.Color.urgent
      property bool vertical: false
      property bool hideLabels: false
      property bool foregroundAnimationEnabled: false
      property var activePopout: false
      function requestPopout(key) { activePopout = key }
      function releasePopout(key) { if (activePopout === key) activePopout = false }
      Plugin.Panel {
        id: panel
        bar: bar
        settings: root.config.bar ? root.config.bar.layout.right[0] : ({})
      }
    }
    property bool ready: false
    Timer { interval: 500; running: true; onTriggered: window.ready = true }
    TestCase {
      name: "NotificationSettings"
      when: window.ready
      function control(name) {
        var item = findChild(panel, name)
        var pane = findChild(panel, "notificationSettingsPane")
        if (item === null && pane) item = findChild(pane, name)
        if (item === null) console.log("MISSING_CONTROL", name)
        verify(item !== null, "Missing " + name)
        return item
      }
      function capture(item, name) {
        var done = false
        item.grabToImage(function(result) { verify(result.saveToFile(Qt.resolvedUrl(name + ".png").toString().replace("file://", ""))); done = true })
        tryVerify(function() { return done })
      }
      function init() { panel.open(); tryCompare(panel, "opened", true); wait(200) }
      function cleanup() { panel.close(); wait(200) }
      function test_01_menu_and_settings_save() {
        try {
        var more = control("notificationMore"), menu = control("notificationOverflowMenu")
        mouseClick(more)
        tryCompare(menu, "visible", true)
        compare(menu.count, 2)
        verify(control("clearAllNotifications").visible)
        wait(150); capture(menu.contentItem.parent, "overflow-menu")
        control("notificationMute").triggered()
        tryCompare(root, "dnd", true)
        tryCompare(panel, "dnd", true)
        more.forceActiveFocus(); keyClick(Qt.Key_Return)
        tryCompare(menu, "visible", true)
        control("notificationSettings").triggered()
        tryCompare(panel, "editingSettings", true)
        var pane = control("notificationSettingsPane")
        wait(250)
        verify(pane.height > 500, "The full settings view must fit on this fixture screen")
        waitForRendering(pane)
        var card = pane.parent.parent.parent.parent
        capture(card, "settings-wide-dark")
        var compact = control("center-compact")
        compact.clicked()
        tryVerify(function() { return panel.preferenceActive === null && root.config.bar.layout.right[0].compact === true })
        tryCompare(panel, "compact", true)
        panel.savePreference("keepDays", 15)
        tryVerify(function() { return root.config.bar.layout.right[0].keepDays === 15 })
        tryCompare(control("center-keepDays"), "value", 15)
        compare(root.config.other, "preserved")
        panel.settings = Object.assign({}, panel.settings, {panelWidth:320})
        wait(200); compare(pane.width, 318)
        capture(card, "settings-narrow-dark")
        Commons.Color.background = "#eff1f5"; Commons.Color.foreground = "#4c4f69"; Commons.Color.accent = "#1e66f5"
        wait(200); capture(card, "settings-narrow-light")
        panel.settings = Qt.binding(function() { return root.config.bar.layout.right[0] })
        var back = control("settingsBack")
        back.forceActiveFocus(); keyClick(Qt.Key_Escape)
        tryCompare(panel, "editingSettings", false)
        tryVerify(function() { return more.activeFocus })
        } catch (error) { console.log("SETTINGS_FAILURE menu/save", error.message, error.stack); throw error }
      }
      function test_02_invalid_and_failed_saves() {
        try {
        panel.openSettings()
        panel.savePreference("keepDays", 0)
        verify(panel.settingsError !== "")
        compare(panel.preferenceActive, null)
        root.failSave = true
        panel.savePreference("compact", false)
        tryVerify(function() { return panel.preferenceActive === null })
        verify(panel.settingsError !== "")
        compare(panel.compact, true)
        var grouping = control("center-browserGrouping")
        grouping.open(); tryCompare(grouping, "popupOpen", true); keyClick(Qt.Key_Down); keyClick(Qt.Key_Return)
        tryCompare(grouping, "popupOpen", false)
        tryVerify(function() { return panel.settingsError !== "" && panel.preferenceActive === null })
        compare(grouping.value, "hostname")
        capture(control("notificationSettingsPane").parent.parent.parent.parent, "settings-save-error")
        root.failSave = false
        grouping.open(); tryCompare(grouping, "popupOpen", true); keyClick(Qt.Key_Down); keyClick(Qt.Key_Return)
        tryCompare(grouping, "popupOpen", false)
        tryCompare(panel, "browserGrouping", "none")
        tryCompare(grouping, "value", "none")
        grouping.open(); tryCompare(grouping, "popupOpen", true); keyClick(Qt.Key_Up); keyClick(Qt.Key_Return)
        tryCompare(grouping, "popupOpen", false)
        tryCompare(panel, "browserGrouping", "hostname")
        panel.savePreference("compact", false)
        tryVerify(function() { return panel.preferenceActive === null })
        compare(panel.settingsError, "")
        tryCompare(panel, "compact", false)
        var days = control("center-keepDays")
        tryVerify(function() { return days.enabled })
        days.field.forceActiveFocus(); keyClick(Qt.Key_A, Qt.ControlModifier)
        keyClick(Qt.Key_1); keyClick(Qt.Key_2); keyClick(Qt.Key_Return)
        tryVerify(function() { return root.config.bar.layout.right[0].keepDays === 12 })
        } catch (error) { console.log("SETTINGS_FAILURE errors", error.message, error.stack); throw error }
      }
      function test_03_scroll_focus() {
        try {
        panel.openSettings()
        var pane = control("notificationSettingsPane"), scroll = control("settingsScroll")
        wait(200)
        pane.height = 320
        control("center-maxItems").field.forceActiveFocus()
        tryVerify(function() { return scroll.contentY > 0 })
        verify(control("center-maxItems").enabled)
        } catch (error) { console.log("SETTINGS_FAILURE scroll", error.message, error.stack); throw error }
      }
      function test_06_search_keys() {
        panel.startSearch()
        var search = control("notificationSearch")
        tryCompare(search, "activeFocus", true)
        keyClick(Qt.Key_A)
        compare(panel.filter, "a")
        keyClick(Qt.Key_Down)
        tryCompare(search, "activeFocus", false)
        search.forceActiveFocus()
        keyClick(Qt.Key_Return)
        tryCompare(search, "activeFocus", false)
        search.forceActiveFocus()
        keyClick(Qt.Key_Escape)
        compare(panel.searching, false)
        compare(panel.filter, "")
      }
      function test_07_archived_screenshot_action_and_retry() {
        try {
        panel.editingSettings = false
        panel.searching = false
        panel.filter = ""
        tryVerify(function() { return store.entries.length === 1 })
        var row = store.entries[0]
        compare(row.fileAction, "edit-screenshot")
        wait(200)
        capture(control("notificationSearch").parent.parent.parent, "screenshot-history")
        panel.activate(row)
        tryVerify(function() { return store.focusError.indexOf("Could not open the image") === 0 })
        compare(store.entries.length, 1)
        compare(panel.opened, true)
        capture(control("notificationSearch").parent.parent.parent, "screenshot-open-error")
        editorReady.setText("ready")
        wait(100)
        panel.activate(row)
        tryCompare(panel, "opened", false)
        compare(store.entries.length, 0)
        } catch (error) { console.log("SETTINGS_FAILURE screenshot", error.message, error.stack); throw error }
      }
      onCompletedChanged: if (completed) { console.log("SETTINGS_UI", qtest_results.passCount, "passed", qtest_results.failCount, "failed"); root.finished = true }
    }
  }
}
''')
# Avoid starting desktop portal daemons on the disposable test bus.
env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"), XDG_CACHE_HOME=str(home / ".cache"), XDG_STATE_HOME=str(home / ".local/state"), PATH=str(cli) + ":" + os.environ["PATH"], QT_QPA_PLATFORM="wayland", QT_QUICK_BACKEND="rhi", QT_QPA_PLATFORMTHEME="basic", QT_NO_XDG_DESKTOP_PORTAL="1", OMARCHY_PATH="/usr/share/omarchy")
process = subprocess.Popen(["dbus-run-session", "--", "qs", "-p", str(app), "--no-color"], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
try:
    output = process.communicate(timeout=30)[0]
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGTERM)
    output = process.communicate(timeout=3)[0]
print(output)
print("Settings captures:", app)
assert process.returncode == 0 and "SETTINGS_UI 5 passed 0 failed" in output
