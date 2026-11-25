import QtQuick
import Quickshell.Io

// Liquid glass: the liquidglass Hyprland plugin (glass/), which turns
// Hyprland's blur into a lens at the edges of whatever it blurs; the
// overview's cards draw the same lens (see blur/frost.frag). glass/glass-ctl
// builds the plugin for the running Hyprland the first time, loads it and
// switches it.
Item {
  id: glass

  property bool want: false
  // "off", "working" (building or loading), "on", or "error" with `error`.
  property string status: "off"
  property string error: ""
  property bool again: false
  readonly property string ctl: {
    const url = Qt.resolvedUrl("../../glass/glass-ctl").toString()
    return url.startsWith("file://") ? url.slice(7) : url
  }

  // glass-ctl has finished, and nothing is waiting to run it again.
  signal finished()

  onWantChanged: glass.apply()

  // The plugin is wanted with the glass off too: it also pours windows into the
  // dock and fades the ones under a maximized window (glass/src/genie.inc). So
  // it is seen to once at the start, whatever the switch says.
  Timer { interval: 1500; running: true; onTriggered: glass.apply() }

  function apply() {
    if (glassProc.running) {
      glass.again = true
      return
    }
    glass.status = glass.want ? "working" : "off"
    glass.error = ""
    glassProc.command = [glass.ctl, glass.want ? "on" : "off"]
    glassProc.running = true
  }

  Process {
    id: glassProc
    stderr: StdioCollector { id: glassErr }
    onExited: (code) => {
      if (glass.again) {
        glass.again = false
        glass.apply()
        return
      }
      if (code !== 0 && glass.want) {
        glass.status = "error"
        glass.error = String(glassErr.text || "").trim() || "The glass did not start."
      } else {
        glass.status = glass.want ? "on" : "off"
      }
      glass.finished()
    }
  }
}
