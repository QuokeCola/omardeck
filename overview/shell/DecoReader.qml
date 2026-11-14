import QtQuick
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

  property var deco: Deco.DEFAULTS
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
  function take(text) { reader.deco = Deco.parse(text) }

  function read() {
    if (!readDeco.running) readDeco.running = true
  }
}
