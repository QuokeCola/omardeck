import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/quokecola.omardeck/overview/shell" as O

// The settings popout on a private X server, driven through the signals its key
// catcher emits. The keys themselves are PanelKeyCatcher's, a stock file.
ShellRoot {
  id: root

  readonly property string theme: Quickshell.env("TEST_THEME")
  readonly property string out: Quickshell.env("TEST_OUT")

  property var failures: []
  function check(ok, what) {
    console.log((ok ? "  PASS " : "  FAIL ") + what)
    if (!ok) root.failures.push(what)
  }

  QtObject {
    id: fakeBar
    readonly property color foreground: "#D5F2F5"
    readonly property color barForeground: "#D5F2F5"
    readonly property color urgent: "#EC4F5E"
    readonly property string fontFamily: "Noto Sans"
    readonly property string position: "top"
    readonly property int barSize: 26
    readonly property var shell: null
    property var activePopout: null
    function requestPopout(key) { fakeBar.activePopout = key }
    function releasePopout(key) { fakeBar.activePopout = null }
  }

  FloatingWindow {
    id: host
    implicitWidth: 60
    implicitHeight: 30
    visible: true
    O.Panel { id: panel; bar: fakeBar }
  }

  readonly property var popup: {
    for (const o of panel.data) if (o.focusTarget !== undefined) return o
    return null
  }
  readonly property var keys: root.popup ? root.popup.focusTarget : null

  function grab(name, then) {
    if (root.out === "") { then(); return }
    // Up to just below the window's own two items, which can't be grabbed: the popup's
    // contentItem is the list of what it was given.
    let top = root.keys
    while (top.parent && top.parent.parent && top.parent.parent.parent) top = top.parent
    top.grabToImage(result => {
      root.check(result.saveToFile(root.out + "/" + root.theme + "-settings-" + name + ".png"), "saving " + name)
      then()
    })
  }

  property int step: 0
  function next(ms) { stepper.interval = ms; stepper.start() }
  Timer { id: stepper; onTriggered: root.advance() }
  Timer { interval: 600; running: true; onTriggered: root.advance() }

  function advance() {
    switch (root.step++) {
    case 0:
      root.check(root.popup !== null, "the popout was made")
      panel.open()
      root.next(900)
      break
    case 1:
      root.check(panel.cursor === "", "no cursor until a key asks for one")
      root.grab("rest", () => root.advance())
      break
    case 2:
      root.keys.moveRequested(0, 1)
      root.check(panel.cursor === "frost", "down lands on the first switch, got " + panel.cursor)
      root.next(200)
      break
    case 3:
      root.grab("cursor-switch", () => root.advance())
      break
    case 4: {
      const was = panel.frost
      root.keys.activateRequested()
      root.check(panel.frost === !was, "enter flips it")
      root.keys.activateRequested()
      root.check(panel.frost === was, "and back")
      root.keys.moveRequested(0, 1)
      root.check(panel.cursor === "liquidGlass", "down goes on, got " + panel.cursor)
      root.keys.moveRequested(0, -1)
      root.keys.moveRequested(0, -1)
      root.check(panel.cursor === "frost", "up stops at the first, got " + panel.cursor)
      panel.cursor = ""
      for (let i = 0; i < 5; i++) root.keys.moveRequested(0, 1)
      root.check(panel.cursor.indexOf("shortcut:") === 0, "past the switches: a shortcut row, got " + panel.cursor)
      root.next(200)
      break
    }
    case 5:
      root.grab("cursor-row", () => root.advance())
      break
    case 6: {
      const id = panel.cursor.slice("shortcut:".length)
      root.keys.activateRequested()
      root.check(panel.recordingId === id, "enter records that shortcut, got " + panel.recordingId)
      root.check(root.keys.blocked, "and the catcher lets the keys through")
      root.next(200)
      break
    }
    case 7:
      root.grab("recording", () => root.advance())
      break
    case 8: {
      const id = panel.recordingId
      panel.stopRecording()
      root.check(panel.cursor === "shortcut:" + id, "stopping leaves the cursor on its row")
      panel.setDraft(id, "SUPER + F9")
      root.check(panel.dirty, "a change makes it dirty")
      root.keys.deleteRequested()
      root.check(!panel.draft[id], "delete clears the row's shortcut")
      panel.setDraft(id, "SUPER + F9")
      panel.cursor = ""
      for (let i = 0; i < 40; i++) root.keys.moveRequested(0, 1)
      root.check(panel.cursor === "save", "the end of the list is Save, got " + panel.cursor)
      root.next(200)
      break
    }
    case 9:
      root.grab("cursor-button", () => root.advance())
      break
    case 10:
      panel.discard()
      root.check(!panel.dirty, "discarded")
      root.check(panel.cursorOrder.indexOf(panel.cursor) >= 0, "a cursor on a button that went away finds its way back, got " + panel.cursor)
      panel.close()
      root.next(600)
      break
    case 11:
      root.check(panel.cursor === "", "closing forgets the cursor")
      console.log("VERDICT " + (root.failures.length === 0 ? "ok" : root.failures.length + " failing"))
      Qt.quit()
      break
    }
  }
}
