import QtQuick

// Where a look may draw something (see `pageLayer` and the others in Look.qml):
// a Loader that hands the file what it needs before any of its bindings run.
// An empty slot makes nothing at all.
Loader {
  id: slot

  // The file, or "".
  property url file: ""
  // Its required properties.
  property var given: ({})

  function refresh() {
    if (slot.file.toString() === "") slot.source = ""
    else slot.setSource(slot.file, slot.given)
  }
  onFileChanged: if (slot.ready) slot.refresh()

  // Not before `given` has its value, and the host its children.
  property bool ready: false
  Component.onCompleted: {
    slot.ready = true
    if (slot.file.toString() !== "") slot.refresh()
  }
}
