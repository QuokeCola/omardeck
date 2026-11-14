pragma ComponentBehavior: Bound
import QtQuick
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "../Preferences.js" as Preferences

Column {
  id: root
  objectName: "center-" + field.key + "Field"
  required property var field
  required property var settings
  readonly property var current: Preferences.value(settings, field.key)
  signal save(var value)
  Loader {
    width: parent.width
    active: root.field.type === "enum"
    visible: active
    sourceComponent: Component {
      Dropdown {
        id: dropdown
        objectName: "center-" + root.field.key
        width: parent.width
        label: root.field.label
        fontFamily: "sans-serif"
        value: String(root.current)
        options: root.field.options.map(function(value) { return {value:value,label:Preferences.optionLabel(value)} })
        onChanged: function(next) {
          // Dropdown assigns the choice to value; keep showing what is saved instead.
          dropdown.value = Qt.binding(function() { return String(root.current) })
          root.save(next)
        }
      }
    }
  }
  Loader {
    width: parent.width
    active: root.field.type === "boolean"
    visible: active
    sourceComponent: Component {
      Toggle {
        objectName: "center-" + root.field.key
        width: parent.width
        implicitHeight: Style.space(36)
        color: "transparent"
        borderSpec: activeFocus ? Border.flat(Commons.Color.accent, 1) : Border.none()
        radius: Style.cornerRadius * 2
        foreground: Commons.Color.popups.text
        fontFamily: "sans-serif"
        titleSize: Style.space(13)
        label: root.field.label
        checked: root.current === true
        Accessible.role: Accessible.CheckBox
        Accessible.name: label
        Accessible.checkable: true
        Accessible.checked: checked
        Accessible.onToggleAction: if (enabled) root.save(!checked)
        onClicked: root.save(!checked)
      }
    }
  }
  Loader {
    width: parent.width
    active: root.field.type === "integer"
    visible: active
    sourceComponent: Component {
      NumberField {
        objectName: "center-" + root.field.key
        label: root.field.label
        value: root.current
        from: root.field.min
        to: root.field.max
        foreground: Commons.Color.popups.text
        fontFamily: "sans-serif"
        fontSize: Style.space(12)
        onModified: function(next) { root.save(next) }
      }
    }
  }
}
