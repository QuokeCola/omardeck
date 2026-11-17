import QtQuick

// The titlebar Omarchy gives windows on a floating workspace (the hyprbars
// plugin), drawn on the window's card. A capture is the window's own pixels, and
// the titlebar is not among them: without this the card stood in for the window
// without it, so it vanished as the overview opened.
//
// Laid out at the window's own size from what the plugin was told (see `bars` in
// app/Deco.js) and scaled with the card. Only to look at: the card's own close
// button and drag do the work.
Item {
  id: bar

  required property var card
  readonly property var overlay: card.overlay
  readonly property var deco: bar.overlay.deco

  // The plugin's buttons, right to left. Omarchy's three (see
  // default/hypr/workspace-modes.lua); the plugin doesn't say which it has.
  readonly property var buttons: ["×", "□", "−"]
  readonly property real buttonSize: 20
  readonly property string appName: bar.overlay.appNameFor(bar.card.modelData.appId)

  visible: bar.card.barH > 0.5
  x: 0
  y: -bar.card.barH
  width: bar.card.width
  height: bar.card.barH
  opacity: bar.card.real.opacity ?? 1

  Rectangle {
    id: face
    width: Math.max(1, bar.card.real.w)
    height: Math.max(1, bar.card.real.bar || 0)
    transformOrigin: Item.TopLeft
    scale: bar.card.width / face.width
    color: bar.deco.barColor
    // The card's own corner, whatever size the card is drawn at (the face is laid
    // out at the window's size and scaled), and a little tighter than it: the bar
    // then runs just under the border's rounded corner. Cut to the very same arc,
    // the two antialias apart, and a dark seam of the shadow shows between them.
    readonly property real corner: Math.max(0, bar.card.radius - 1.5) / Math.max(0.01, face.scale)
    topLeftRadius: face.corner
    topRightRadius: face.corner

    Text {
      textFormat: Text.PlainText
      visible: bar.deco.barTitle
      anchors.left: parent.left
      anchors.leftMargin: bar.deco.barPadding
      anchors.right: glyphs.left
      anchors.rightMargin: bar.deco.barPadding
      anchors.verticalCenter: parent.verticalCenter
      // What the real bar says: the app's name, and the window's title only when
      // no launcher claims it. The card's caption has the title.
      text: bar.appName !== "" ? bar.appName
          : (bar.card.modelData.top ? (bar.card.modelData.top.title || "") : (bar.card.modelData.title || ""))
      elide: Text.ElideRight
      color: bar.deco.barText
      font.family: bar.deco.barFont
      font.pixelSize: bar.deco.barTextSize
    }

    Row {
      id: glyphs
      anchors.right: parent.right
      anchors.rightMargin: bar.deco.barPadding
      anchors.verticalCenter: parent.verticalCenter
      spacing: bar.deco.barButtonPadding
      layoutDirection: Qt.RightToLeft

      Repeater {
        model: bar.buttons
        Text {
          required property string modelData
          textFormat: Text.PlainText
          width: bar.buttonSize
          height: bar.buttonSize
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          text: modelData
          color: bar.deco.barText
          font.family: bar.deco.barFont
          font.pixelSize: Math.round(bar.buttonSize * 0.7)
        }
      }
    }
  }
}
