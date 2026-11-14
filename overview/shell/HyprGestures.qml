import QtQuick
import Quickshell.Io

// The swipes, registered in Hyprland: app/gesture.lua, and what three fingers
// sideways currently mean.
LuaModule {
  id: gestures

  file: Qt.resolvedUrl("../app/gesture.lua")
  guard: "__aerial_registered"
  goneMessage: "aerial: gestures gone"
  retries: true

  // "slide", "none", or "" for in between: keep whatever is there.
  property string sideways: ""
  property string sidewaysSent: ""

  // Registering the gestures resets nothing sideways, but a fresh Lua state
  // after a config reload has nothing registered at all: say it again.
  onDone: {
    gestures.sidewaysSent = ""
    gestures.sendSideways()
  }

  // In an eval of its own, after the gestures exist: if the user already has
  // a horizontal swipe, Hyprland refuses ours and that refusal must not take
  // the up and down gestures with it.
  Process {
    id: sidewaysLua
    onRunningChanged: if (!running && gestures.sidewaysSent !== gestures.sideways) gestures.sendSideways()
  }

  function sendSideways() {
    if (gestures.running || sidewaysLua.running) return
    const mode = gestures.sideways
    if (mode === "") return   // in between: keep whatever is there
    gestures.sidewaysSent = mode
    sidewaysLua.command = ["/usr/bin/hyprctl", "eval", '__aerial_horizontal("' + mode + '")']
    sidewaysLua.running = true
  }

  onSidewaysChanged: gestures.sendSideways()
}
