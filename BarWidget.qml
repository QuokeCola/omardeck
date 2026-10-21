import QtQuick
import "notifications" as Notifications
import "overview/shell" as Overview

// The bell and, beside it, the overview's settings button.
//
// A plugin has one bar widget, and Omarchy writes a widget's settings to every
// entry with its id, so the two cannot be placed apart: they share this entry
// and its settings. Each is the panel it was as a plugin of its own; this only
// hands them what the bar hands it.
Row {
  id: root

  // Injected by the bar.
  property QtObject bar: null
  property string moduleName: ""
  property var settings: ({})

  readonly property bool overviewButton: !settings || settings.overviewButton !== false

  // What the bar asks of a panel widget. The bell is the panel the widget
  // stands for; the overview's settings have their own IPC target.
  readonly property bool opened: bell.opened || (overviewLoader.item ? overviewLoader.item.opened : false)
  function open() { bell.open() }
  function close() {
    bell.close()
    if (overviewLoader.item) overviewLoader.item.close()
  }
  function toggle() { opened ? close() : open() }

  Loader {
    id: overviewLoader
    active: root.overviewButton
    visible: active
    sourceComponent: Overview.Panel {
      bar: root.bar
      moduleName: root.moduleName
      // A panel assigns its settings when it saves one; a Binding, unlike a
      // plain binding, survives that and keeps handing over the bar's.
      Binding on settings { value: root.settings }
    }
  }

  Notifications.Panel {
    id: bell
    bar: root.bar
    moduleName: root.moduleName
    Binding on settings { value: root.settings }
  }
}
