import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland

// One screen's worth of overview.
//
// Every monitor gets one of these, each spreading its own workspace's windows,
// because a second screen that merely dims while you are looking for a window
// on it is worse than no overview at all. The workspace strip belongs to the
// screen you were pointing at; the others are just their own windows.
PanelWindow {
  id: surface

  required property var overlay
  required property var screenInfo

  screen: surface.screenInfo
  // Mapped for good rather than per swipe, empty and click-through while the
  // overview is away. Mapping a layer surface is a round trip with the
  // compositor, fresh buffers, and every texture the overview draws with
  // allocated again: 60 to 100ms in which the fingers had moved and the
  // overview had not, and then it jumped to catch up. Kept mapped, a swipe
  // draws on the next frame.
  //
  // Except over a fullscreen window: a surface on top of one, even an empty
  // one, stops the compositor scanning that window straight out, which is
  // what a fullscreen video wants. There the overview maps when asked.
  visible: overlay.opened || !surface.fullscreenHere
  // Really fullscreen, that is. Hyprland says `hasFullscreen` of a workspace with a
  // maximized window too, and that one is laid out like any other: under the bar,
  // above the dock's strip. Taken for fullscreen, the overview mapped only as it
  // opened, the dock remapped to stay on top of it (see `restack` in the dock),
  // and for that moment the dock's strip was nobody's: the maximized window grew
  // down into it and back, under cards placed from wherever it was by then.
  readonly property bool fullscreenHere: {
    const space = surface.monitor ? surface.monitor.activeWorkspace : null
    if (!space || !space.hasFullscreen) return false
    return (Hyprland.toplevels.values || []).some(top =>
      top.workspace === space && ((top.lastIpcObject || {}).fullscreen || 0) >= 2)
  }
  color: "transparent"
  WlrLayershell.namespace: "omarchy-aerial"
  // Under the bar, which stays where it is on the desktop: above the windows, and
  // so above their cards. Over a fullscreen window nothing on that layer shows, the
  // bar included, so there it is on the one above.
  WlrLayershell.layer: surface.fullscreenHere ? WlrLayer.Overlay : WlrLayer.Top
  exclusionMode: ExclusionMode.Ignore
  anchors { top: true; bottom: true; left: true; right: true }

  // Only the screen you swiped on grabs the keyboard; two surfaces both
  // claiming it exclusively is a fight nobody wins. And only once the overview
  // is actually open — a swipe still in progress must not take keys from the
  // window underneath.
  WlrLayershell.keyboardFocus: surface.leading && overlay.active
                               ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

  // A swipe in progress should not swallow clicks meant for the desktop.
  mask: overlay.active ? null : emptyRegion
  Region { id: emptyRegion }

  // What others ask of a screen. `stage` is what its cards know it as.
  readonly property alias stage: stage
  readonly property alias monitorName: stage.monitorName
  readonly property alias monitor: stage.monitor
  readonly property alias leading: stage.leading
  readonly property alias ready: stage.ready
  readonly property alias shownWorkspace: stage.shownWorkspace
  readonly property alias shownWindows: stage.shownWindows
  readonly property alias slots: stage.slots
  function workspaceAtPoint(px, py) { return stage.workspaceAtPoint(px, py) }

  SurfaceStage {
    id: stage
    anchors.fill: parent
    overlay: surface.overlay
    screenInfo: surface.screenInfo
  }

  // Outside `stage`, which is hidden the moment the slide lands, so it can
  // linger and fade.
  DeskDots { surface: stage }
}
