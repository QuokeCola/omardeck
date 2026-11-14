import QtQuick
import Quickshell
import Quickshell.Io

// Compile gate: every QML file the overview is made of loads. No instances.
ShellRoot {
  FileView { id: list; path: Quickshell.env("TEST_ROOT") + "/files.txt"; blockLoading: true }
  Timer {
    interval: 300
    running: true
    onTriggered: {
      let bad = 0
      const files = list.text().split("\n").filter(f => f !== "")
      for (const f of files) {
        const c = Qt.createComponent("file://" + f, Component.PreferSynchronous)
        if (c.status === Component.Ready) continue
        bad++
        console.log("  FAIL " + f + "\n" + c.errorString())
      }
      console.log("VERDICT " + (bad === 0 && files.length > 0 ? "ok " + files.length + " files" : bad + " failing"))
      Qt.quit()
    }
  }
}
