import QtQuick
import Quickshell
import Quickshell.Io
import "../app/Deco.js" as Deco

// How Hyprland dresses a window: its rounding, border and shadow. At the
// start of a swipe every card sits exactly on top of its window, and the
// desktop behind has already been painted over, so a card has to look like
// the window it stands in for — not like a square screenshot of its
// contents — or the first frame of every swipe is a visible jump.
//
// This asks; app/Deco.js says what the answer means.
Item {
  id: reader

  // What Hyprland answered, and over it what the titlebar's note says.
  property var asked: Deco.DEFAULTS
  property var barStyle: ({})
  readonly property var deco: Object.assign({}, reader.asked, reader.barStyle)
  readonly property var options: Deco.OPTIONS

  Process {
    id: readDeco
    command: ["/usr/bin/hyprctl", "--batch",
              reader.options.map(o => "j/getoption " + o).join("; ")]
    stdout: StdioCollector {
      onStreamFinished: reader.take(text)
    }
  }

  function colourOf(entry) { return Deco.colourOf(entry) }
  function vecOf(entry, i) { return Deco.vecOf(entry, i) }
  function take(text) { reader.asked = Deco.parse(text) }

  // The titlebar's style, which dock/minimize.lua writes down as it sets it: the
  // plugin has no way to be asked for its buttons.
  FileView {
    id: barNote
    path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omardeck-titlebar.json"
    watchChanges: true
    printErrors: false
    onFileChanged: barNote.reload()
    onLoaded: reader.barStyle = Deco.barStyle(barNote.text())
    onLoadFailed: reader.barStyle = ({})
  }

  function read() {
    if (!readDeco.running) readDeco.running = true
  }
}
