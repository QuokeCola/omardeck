import QtQuick
import Quickshell
import Quickshell.Io

// The desktop's own wallpaper, which the overview sits on and every workspace
// tile is a small picture of. Omarchy keeps it behind a symlink that moves
// when the theme changes, so resolve it rather than remember it — but never
// while a swipe is running: this looks it up at startup and whenever the
// overview closes, so it is already known by the time one opens.
Item {
  id: wallpaper

  property string path: ""

  // Resolved in QML rather than by a shell, and `readlink` by absolute path:
  // a plugin runs unsandboxed, so it should not be spawning shells to expand a
  // variable it can read itself.
  readonly property string link: {
    const state = String(Quickshell.env("XDG_STATE_HOME") || "")
    const home = String(Quickshell.env("HOME") || "")
    const base = state !== "" ? state : (home !== "" ? home + "/.local/state" : "")
    return base === "" ? "" : base + "/omarchy/current/background"
  }

  Process {
    id: findWallpaper
    command: ["/usr/bin/readlink", "-f", wallpaper.link]
    stdout: StdioCollector {
      onStreamFinished: {
        const path = text.trim()
        // Only ever a path the compositor's own theme points at, and only used
        // as an image source.
        if (path.startsWith("/")) wallpaper.path = path
      }
    }
  }

  function resolve() {
    if (wallpaper.link === "" || findWallpaper.running) return
    findWallpaper.running = true
  }
}
