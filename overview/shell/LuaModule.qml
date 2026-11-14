import QtQuick
import Quickshell.Io

// A Lua file kept loaded in Hyprland. Its Lua state is forgotten on every config
// reload, and sometimes with no event to say so, so loading it once is not enough:
// this loads it, loads it again if asked while a load is in flight, and afterwards
// asks the Lua state a few times whether the file's flag is still there.
//
//   file         the .lua; must set the global `guard` when it has run
//   guard        that global's name
//   goneMessage  what the check errors with; only ever seen in hyprctl's answer
//   active       off: load() and the checks do nothing. Does not unload anything
//   retries      a failed eval (Hyprland not answering yet) tries again, as loadSoon
//   running      an eval is in flight
//   load()       now, or straight after the one in flight
//   loadSoon()   after a reload has settled; call again to wait from now
//
//   evaluated(code)  every eval, as it exits
//   done()           an eval is over and no other is queued; the checks start after
//   reloading()      loadSoon's wait is over and its load() was called
Item {
  id: module

  property url file
  property string guard: ""
  property string goneMessage: ""
  property bool active: true
  property bool retries: false

  readonly property string path: {
    const url = module.file.toString()
    return url.startsWith("file://") ? url.slice(7) : url
  }
  readonly property alias running: lua.running

  signal evaluated(int code)
  signal done()
  signal reloading()

  // Asked to load again while an eval was still in flight. At login a monitor
  // daemon reloads Hyprland while the first eval waits on a modeset; dropping the
  // second ask left the reloaded Lua state without the file.
  property bool again: false

  Process {
    id: lua
    onExited: (code) => {
      module.evaluated(code)
      if (code !== 0 && module.retries) module.loadSoon()
    }
    onRunningChanged: if (!running) {
      if (module.again) {
        module.again = false
        module.load()
        return
      }
      module.done()
      module.checksLeft = 5
      check.restart()
    }
  }

  // Whether the file is still loaded, a few times after each load. At login a
  // monitor daemon rewrites monitors.lua, and the autoreload that follows can land
  // after our eval without its `configreloaded` reaching us: nothing would ever
  // load it again. So ask the Lua state itself, which forgets the flag the file
  // sets the moment it forgets what the file did.
  property int checksLeft: 0

  Timer {
    id: check
    interval: 2000
    onTriggered: if (module.active && !lua.running && !probe.running) probe.running = true
  }

  Process {
    id: probe
    command: ["/usr/bin/hyprctl", "eval",
              'if not _G.' + module.guard + ' then error("' + module.goneMessage + '") end']
    onExited: (code) => {
      if (code !== 0) module.load()
      else if (--module.checksLeft > 0) check.restart()
    }
  }

  function load() {
    if (!module.active) return
    if (lua.running) {
      module.again = true
      return
    }
    const path = module.path.replace(/\\/g, "\\\\").replace(/"/g, '\\"')
    lua.command = ["/usr/bin/hyprctl", "eval", 'dofile("' + path + '")']
    lua.running = true
  }

  function loadSoon() { soon.restart() }

  Timer {
    id: soon
    interval: 600
    onTriggered: {
      module.load()
      module.reloading()
    }
  }
}
