import QtQuick
import Quickshell
import "overview/shell" as Overview
import "notifications" as Notifications
import "dock" as Dock

// The one service the shell mounts for this plugin, holding the three parts.
//
// Each part keeps the service it had as a plugin of its own; the bar widget
// and the overlay reach them through this one by name. The parts are handed
// each other here: the dock asks the overview for an app's windows or to
// slide to one, the overview keeps its desktop dots above the dock, and the
// notification sheet makes way for the overview.
Item {
  id: root
  width: 0
  height: 0
  visible: false

  property var shell: null
  property var manifest: null
  property var pluginRegistry: null
  property var barWidgetRegistry: null
  property string omarchyPath: ""

  readonly property alias overview: overview
  readonly property alias notifications: notifications
  readonly property alias dock: dock

  Overview.Service {
    id: overview
    shell: root.shell
    manifest: root.manifest
    dockCovers: dock.covers
  }

  Notifications.Service {
    id: notifications
    shell: root.shell
    manifest: root.manifest
    pluginRegistry: root.pluginRegistry
    barWidgetRegistry: root.barWidgetRegistry
    omarchyPath: root.omarchyPath
    overview: root.overview
  }

  Dock.Service {
    id: dock
    shell: root.shell
    overview: root.overview
  }

  // Once per user: the glass switches are put in the Omarchy menu, where the
  // rest of the look is set, and the menu is opened there (bin/omardeck-menu).
  // After the shell has settled, so the menu is there to be opened.
  Timer {
    interval: 4000
    running: true
    onTriggered: {
      const url = Qt.resolvedUrl("bin/omardeck-menu").toString()
      Quickshell.execDetached([url.startsWith("file://") ? url.slice(7) : url, "first-run"])
    }
  }
}
