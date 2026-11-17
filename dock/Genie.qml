import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import QtQuick.Shapes
import qs.Commons
import qs.Commons as Commons

// The genie: a window poured into its dock icon as it is minimized, and back out
// as the dock restores it.
//
// Hyprland cannot bend a window, so for the length of the animation a picture of
// it stands in: a capture of the window, with the titlebar Omarchy gives floating
// workspaces' windows drawn above it (a capture is the window's own pixels, and
// the bar is not among them), on a surface over the whole screen that takes no
// input, between the windows and the dock. The real window is taken away under the picture's first frame, or put
// back under its last.
//
//   play({ screen, capture, win, barH, barColor, rounding, sink, minimizing,
//          ready, done, fallback })
//     win, sink   rectangles on that screen: the window (without its bar) and the icon
//     ready()     minimizing: the picture is up, take the window away now
//     done()      the animation is over
//     fallback()  no picture came in time: do it without one
Scope {
  id: genie

  property bool active: false
  property bool pictured: false
  property string screenName: ""
  property var capture: null
  property rect win
  property rect sink
  property real barH: 0
  property color barColor: "transparent"
  property real rounding: 0
  // The window's frame, as Hyprland draws it: `deco` is the overview's reading of
  // its settings (app/Deco.js), null when there is none to go by.
  property var deco: null
  property string title: ""
  readonly property real border: deco ? deco.border : 0
  property bool minimizing: true
  // 0 the window in place .. 1 gone into the icon.
  property real p: 0
  property var job: null

  readonly property int duration: 500
  // Minimizing eases in: the window leaves slowly and is quickest as it goes into
  // the icon. Restoring eases out: it comes quickly out of the icon and settles
  // slowly into place.
  readonly property var curveIn: [0.8, 0, 0.8, 1, 1, 1]
  readonly property var curveOut: [0.5, 0, 0.2, 1, 1, 1]

  function play(o) {
    if (genie.active) genie.end(true)
    genie.job = o
    genie.screenName = o.screen
    genie.win = o.win
    genie.sink = o.sink
    genie.barH = o.barH || 0
    genie.barColor = o.barColor || "transparent"
    genie.rounding = o.rounding || 0
    genie.deco = o.deco || null
    genie.title = o.title || ""
    genie.minimizing = !!o.minimizing
    genie.p = genie.minimizing ? 0 : 1
    genie.pictured = false
    genie.capture = o.capture
    genie.active = true
    patience.restart()
  }

  // Cut short by the next one: whatever this one still owed is done at once.
  function end(cut) {
    var o = genie.job
    genie.job = null
    patience.stop(); settle.stop(); run.stop(); linger.stop()
    if (o && cut) {
      if (!genie.pictured) { if (o.fallback) o.fallback() }
      else if (o.done) o.done()
    }
    genie.active = false
    genie.pictured = false
    genie.capture = null
  }

  function arrived() {
    if (!genie.active || genie.pictured || settle.running) return
    patience.stop()
    // A frame on, so the picture is on screen before the window under it goes.
    settle.restart()
  }

  // No frame of the window: do without the picture.
  Timer {
    id: patience
    interval: 300
    onTriggered: { var o = genie.job; genie.job = null; genie.end(false); if (o && o.fallback) o.fallback() }
  }
  Timer {
    id: settle
    interval: 34
    onTriggered: {
      genie.pictured = true
      if (genie.job && genie.job.ready) genie.job.ready()
      run.from = genie.minimizing ? 0 : 1
      run.to = genie.minimizing ? 1 : 0
      run.restart()
    }
  }
  NumberAnimation {
    id: run
    target: genie
    property: "p"
    duration: Style.duration(genie.duration)
    easing.type: Easing.BezierSpline
    easing.bezierCurve: genie.minimizing ? genie.curveIn : genie.curveOut
    onFinished: {
      var o = genie.job
      if (o && o.done) o.done()
      // Restored: the picture goes in the same breath as the window comes, and no
      // later. Held over it for longer, a see-through window showed doubled up
      // under its own picture, darker for those frames; a frame early, the
      // desktop would show through instead. A turn of the event loop, so the
      // request to place the window is on its way first.
      if (genie.minimizing) genie.end(false)
      else linger.restart()
    }
  }
  Timer { id: linger; interval: 1; onTriggered: genie.end(false) }

  Variants {
    model: Quickshell.screens

    delegate: Component {
      PanelWindow {
        id: stage
        required property var modelData
        screen: modelData
        readonly property bool mine: genie.active && genie.screenName === modelData.name
        visible: stage.mine
        color: "transparent"
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "omarchy-dock-genie"
        // Over the windows and under the dock, which is on the overlay layer: the
        // window goes down behind the dock, not across its face.
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        // Only to look at.
        mask: Region {}

        // The window as it stands on screen: its border, its bar with the title and
        // buttons Omarchy gives it, then its own pixels, cut to its rounded corners.
        // The bar's buttons are Omarchy's three (default/hypr/workspace-modes.lua);
        // the plugin doesn't say which it has. Only to look at.
        ClippingRectangle {
          id: picture
          x: genie.win.x - genie.border
          y: genie.win.y - genie.barH - genie.border
          width: genie.win.width + 2 * genie.border
          height: genie.win.height + genie.barH + 2 * genie.border
          radius: genie.rounding > 0 ? genie.rounding + genie.border : 0
          color: "transparent"
          border.width: genie.border
          border.color: genie.deco ? genie.deco.activeBorder : "transparent"

          Item {
            anchors.fill: parent
            Rectangle {
              id: bar
              visible: genie.barH > 0.5
              width: parent.width
              height: genie.barH
              color: genie.barColor
              readonly property real pad: genie.deco ? genie.deco.barPadding : 10
              Text {
                visible: !genie.deco || genie.deco.barTitle
                anchors.left: parent.left
                anchors.leftMargin: bar.pad
                anchors.right: glyphs.left
                anchors.rightMargin: bar.pad
                anchors.verticalCenter: parent.verticalCenter
                text: genie.title
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: genie.deco ? genie.deco.barText : "white"
                font.family: genie.deco ? genie.deco.barFont : "monospace"
                font.pixelSize: genie.deco ? genie.deco.barTextSize : 12
              }
              Row {
                id: glyphs
                anchors.right: parent.right
                anchors.rightMargin: bar.pad
                anchors.verticalCenter: parent.verticalCenter
                spacing: genie.deco ? genie.deco.barButtonPadding : 8
                layoutDirection: Qt.RightToLeft
                Repeater {
                  model: ["×", "□", "−"]
                  Text {
                    required property string modelData
                    width: 20
                    height: 20
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: modelData
                    textFormat: Text.PlainText
                    color: genie.deco ? genie.deco.barText : "white"
                    font.family: genie.deco ? genie.deco.barFont : "monospace"
                    font.pixelSize: 14
                  }
                }
              }
            }
            // The window's own pixels, its top corners rounded under the bar as
            // Hyprland rounds them, with the bar's colour in the two gaps that
            // leaves: the shape the window has on screen. Squared off, the top
            // edge of a see-through window jumped as its picture took over.
            Repeater {
              model: genie.barH > 0.5 && genie.rounding > 0.5 ? 2 : 0
              Shape {
                required property int index
                x: index === 0 ? 0 : body.width
                y: genie.barH
                transform: Scale { xScale: index === 0 ? 1 : -1 }
                ShapePath {
                  strokeWidth: -1
                  fillColor: genie.barColor
                  startX: 0; startY: 0
                  PathLine { x: genie.rounding + 0.5; y: 0 }
                  PathArc {
                    x: 0; y: genie.rounding + 0.5
                    radiusX: genie.rounding + 0.5; radiusY: genie.rounding + 0.5
                    direction: PathArc.Counterclockwise
                  }
                  PathLine { x: 0; y: 0 }
                }
              }
            }
            ClippingRectangle {
              id: body
              y: genie.barH
              width: genie.win.width
              height: genie.win.height
              radius: genie.rounding
              color: "transparent"
              ScreencopyView {
                id: shot
                anchors.fill: parent
                captureSource: stage.mine ? genie.capture : null
                // A see-through window, a terminal say, stays as see-through in its
                // picture, and Hyprland blurs what is behind this surface wherever the
                // picture is drawn (the layer rule in minimize.lua): the frost bends
                // with the window, from the compositor's own blur. Never quite opaque,
                // so that Qt blends it and its alpha reaches the surface as it is.
                opacity: 0.999
                // One frame is the picture: the window is not looked at again.
                live: stage.mine && !shot.hasContent
                onHasContentChanged: if (shot.hasContent && stage.mine) genie.arrived()
              }
            }
            // With liquid glass on, the bright line the lens leaves along the
            // window's rim. The lens itself bends the compositor's blur, which this
            // surface gets plain: the line is the part of it that shows as an edge.
            Rectangle {
              visible: genie.deco !== null && genie.deco.glass === true
              y: genie.barH
              width: genie.win.width
              height: genie.win.height
              radius: genie.rounding
              color: "transparent"
              border.width: 1
              border.color: Qt.rgba(1, 1, 1, genie.deco ? genie.deco.glassSpecular * 0.4 : 0)
            }
          }
        }
        ShaderEffectSource {
          id: source
          sourceItem: picture
          hideSource: true
          live: true
          visible: false
        }

        // The box holding the window and, at its bottom edge, the icon's foot: the
        // window runs on down behind the dock to there.
        readonly property real left: Math.min(picture.x, genie.sink.x)
        readonly property real right: Math.max(picture.x + picture.width, genie.sink.x + genie.sink.width)
        readonly property real top: picture.y
        readonly property real bottom: Math.max(picture.y + picture.height, genie.sink.y + genie.sink.height)

        ShaderEffect {
          visible: genie.pictured
          x: stage.left
          y: stage.top
          width: Math.max(1, stage.right - stage.left)
          height: Math.max(1, stage.bottom - stage.top)
          property var source: source
          property vector4d win: Qt.vector4d((picture.x - x) / width, 0,
                                             (picture.x + picture.width - x) / width, picture.height / height)
          property vector2d sink: Qt.vector2d((genie.sink.x - x) / width, (genie.sink.x + genie.sink.width - x) / width)
          // The sides come in first; the window is already on its way down as they do.
          readonly property real b: Math.max(0, Math.min(1, genie.p / 0.5))
          readonly property real s: Math.max(0, Math.min(1, (genie.p - 0.12) / 0.88))
          property real bend: b * b * (3 - 2 * b)
          // Straight from `p`, which carries the curve: eased again here, the way
          // down would no longer be the curve that was asked for.
          property real slide: s
          fragmentShader: Qt.resolvedUrl("genie.frag.qsb")
        }
      }
    }
  }
}
