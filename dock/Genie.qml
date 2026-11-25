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
// input, between the windows and the dock.
//
// The picture and the window can't change places in one frame: one is this
// shell's surface and the other is Hyprland's to move, and a frame with both is a
// see-through window doubled up, darker, while a frame with neither is a hole.
// So they change places behind a cover: a capture of that part of the screen,
// which is opaque and looks like whatever is under it. Minimizing, the cover goes
// up, the window is taken away under it, and the picture takes over from the
// cover once the window is known to be gone. Restoring, the cover goes up over
// the picture's last frame, the window is put back under it, and the cover comes
// down once the window is known to be there. However long Hyprland takes, there
// is nothing to see.
//
//   play({ screen, capture, win, barH, barColor, rounding, sink, minimizing,
//          ready, done, fallback })
//     win, sink   rectangles on that screen: the window (without its bar) and the icon
//     address     the window, for confirm() to be told about (see `awaiting`)
//     scale       the monitor's scale, for the shadow's pixels
//     ready()     minimizing: the cover is up, take the window away now
//     done()      minimizing: the animation is over. Restoring: the cover is up,
//                 put the window back now
//     fallback()  no picture came in time: do it without one
Scope {
  id: genie

  property bool active: false
  property bool pictured: false
  // The cover is up (see the top of the file), and whether a capture for it is
  // being asked for.
  property bool covered: false
  property bool covering: false
  // What the cover is waiting to hear through confirm(): "gone", the window has
  // left for the minimized workspace, or "back", it stands on the desktop again.
  // The dock service watches Hyprland for it; `address` is the window.
  property string awaiting: ""
  property string address: ""
  property real scale: 1
  // Restoring: the animation is over, and the cover is on its way.
  property bool landed: false
  // The window has been asked for: taken away (minimizing) or put back.
  property bool handed: false
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
    genie.covered = false
    genie.landed = false
    genie.handed = false
    genie.awaiting = ""
    genie.address = o.address || ""
    genie.scale = o.scale > 0 ? o.scale : 1
    genie.capture = o.capture
    genie.covering = genie.minimizing
    genie.active = true
    patience.restart()
  }

  // Cut short by the next one: whatever this one still owed is done at once.
  function end(cut) {
    var o = genie.job
    genie.job = null
    patience.stop(); settle.stop(); run.stop(); linger.stop(); waiting.stop(); coverPatience.stop(); coverSettle.stop()
    if (o && cut) {
      // Minimizing, the window is taken at `ready`: once that is past there is
      // nothing left to take: only what follows the animation is still owed.
      if (genie.minimizing) { if (genie.handed) { if (o.done) o.done() } else if (o.fallback) o.fallback() }
      else if (!genie.handed && o.done) o.done()
    }
    genie.handed = false
    genie.active = false
    genie.pictured = false
    genie.covered = false
    genie.covering = false
    genie.landed = false
    genie.awaiting = ""
    genie.capture = null
  }

  // A capture has come in: `have` says which are in hand on the screen in use.
  function arrived(havePicture, haveCover) {
    if (!genie.active) return
    if (genie.landed) {
      // Restored, and the cover has come: it goes up in place of the picture, the
      // same pixels, and the window is put back under it.
      if (!haveCover || genie.covered) return
      coverPatience.stop()
      genie.covered = true
      genie.pictured = false
      // Not before the cover is on screen: asked for now, Hyprland has the window
      // back a frame ahead of it, under the picture.
      coverSettle.restart()
      return
    }
    if (genie.pictured || genie.covered || settle.running) return
    if (!havePicture || (genie.minimizing && !haveCover)) return
    patience.stop()
    if (genie.minimizing) genie.covered = true
    // A frame on, so what was put up is on screen before anything under it moves.
    settle.restart()
  }

  // From the dock service: what `awaiting` named has happened.
  function confirm() {
    if (!genie.active || genie.awaiting === "") return
    var what = genie.awaiting
    genie.awaiting = ""
    waiting.stop()
    if (what === "gone") {
      genie.pictured = true
      genie.covered = false
      run.from = 0
      run.to = 1
      run.restart()
    } else {
      // A frame for the window to be drawn under the cover, then the cover goes.
      linger.restart()
    }
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
      if (genie.minimizing) {
        genie.awaiting = "gone"
        waiting.restart()
        genie.handed = true
        if (genie.job && genie.job.ready) genie.job.ready()
        return
      }
      genie.pictured = true
      run.from = 1
      run.to = 0
      run.restart()
    }
  }
  Timer {
    id: coverSettle
    interval: 50
    onTriggered: {
      var o = genie.job
      genie.awaiting = "back"
      waiting.restart()
      genie.handed = true
      if (o && o.done) o.done()
    }
  }
  // Nobody said: carry on as if they had. Long enough for Omarchy's own command,
  // which asks Hyprland several things before it moves the window.
  Timer { id: waiting; interval: 400; onTriggered: genie.confirm() }
  // Restored, and no capture of the screen came for the cover: the window is put
  // back under the picture itself, which then goes at once, as it did before
  // there was a cover.
  Timer {
    id: coverPatience
    interval: 150
    onTriggered: {
      var o = genie.job
      genie.landed = false
      genie.covering = false
      genie.handed = true
      if (o && o.done) o.done()
      linger.restart()
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
      if (genie.minimizing) {
        if (o && o.done) o.done()
        genie.end(false)
        return
      }
      // Restored: the screen is captured as it now stands, picture and all, for
      // the cover the window comes back under (see arrived()).
      genie.landed = true
      genie.covering = true
      coverPatience.restart()
    }
  }
  Timer { id: linger; interval: 34; onTriggered: genie.end(false) }

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
        Item {
          id: frame
          // Room round the picture for the window's shadow, which bends with it.
          readonly property bool shadowed: genie.deco !== null && genie.deco.shadow === true && genie.deco.shadowRange > 0
          readonly property real pad: frame.shadowed
            ? Math.ceil(genie.deco.shadowRange + Math.max(Math.abs(genie.deco.shadowOffsetX), Math.abs(genie.deco.shadowOffsetY))) + 1 : 0
          x: genie.win.x - genie.border - frame.pad
          y: genie.win.y - genie.barH - genie.border - frame.pad
          width: picture.width + 2 * frame.pad
          height: picture.height + 2 * frame.pad

          // Hyprland's shadow, from the shader the overview's cards wear it with,
          // and like Hyprland's not drawn under the window itself, which may be
          // see-through: four strips of it, one for each side of the window.
          Repeater {
            model: frame.shadowed ? 4 : 0
            Item {
              id: strip
              required property int index
              readonly property bool across: index < 2
              x: across ? 0 : (index === 2 ? 0 : picture.x + picture.width)
              y: across ? (index === 0 ? 0 : picture.y + picture.height) : picture.y
              width: across ? frame.width : frame.pad
              height: across ? frame.pad : picture.height
              clip: true
              ShaderEffect {
                readonly property real k: genie.scale
                readonly property int reach: Math.round((genie.border + genie.deco.shadowRange) * k)
                readonly property int corner: Math.floor((genie.rounding + genie.border) * k)
                readonly property int spread: Math.floor(genie.deco.shadowRange * k)
                readonly property real pxW: genie.win.width * k
                readonly property real pxH: (genie.win.height + genie.barH) * k
                readonly property color tint: genie.deco.shadowColor
                x: picture.x + genie.border - reach / k + genie.deco.shadowOffsetX - strip.x
                y: picture.y + genie.border - reach / k + genie.deco.shadowOffsetY - strip.y
                width: (pxW + 2 * reach) / k
                height: (pxH + 2 * reach) / k
                property vector4d color: Qt.vector4d(tint.r, tint.g, tint.b, tint.a)
                property vector2d fullSize: Qt.vector2d(pxW + 2 * reach, pxH + 2 * reach)
                property vector2d topLeft: Qt.vector2d(spread + corner, spread + corner)
                property vector2d bottomRight: Qt.vector2d(pxW + 2 * reach - (spread + corner), pxH + 2 * reach - (spread + corner))
                property real radius: corner
                property real range: spread
                property real shadowPower: genie.deco.shadowPower
                property real roundingPower: genie.deco.roundingPower
                fragmentShader: Qt.resolvedUrl("../overview/shell/deco/shadow.frag.qsb")
              }
            }
          }

        ClippingRectangle {
          id: picture
          x: frame.pad
          y: frame.pad
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
                readonly property bool centred: genie.deco !== null && genie.deco.barAlign === "center"
                anchors.left: parent.left
                anchors.leftMargin: centred ? glyphs.width + 2 * bar.pad : bar.pad
                anchors.right: glyphs.left
                anchors.rightMargin: bar.pad
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: centred ? Text.AlignHCenter : Text.AlignLeft
                font.weight: genie.deco ? genie.deco.barWeight : 400
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
                  model: genie.deco ? genie.deco.barButtons : []
                  Text {
                    required property var modelData
                    width: modelData.size
                    height: modelData.size
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.icon
                    textFormat: Text.PlainText
                    color: modelData.fg || genie.deco.barText
                    font.family: genie.deco.barFont
                    font.pixelSize: Math.round(modelData.size * 0.7)
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
                onHasContentChanged: if (shot.hasContent && stage.mine) genie.arrived(true, cover.hasContent)
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
        }
        ShaderEffectSource {
          id: source
          sourceItem: frame
          hideSource: true
          live: true
          visible: false
        }

        // The box holding the window and, at its bottom edge, the icon's foot: the
        // window runs on down behind the dock to there.
        readonly property real left: Math.min(frame.x, genie.sink.x)
        readonly property real right: Math.max(frame.x + frame.width, genie.sink.x + genie.sink.width)
        readonly property real top: frame.y
        readonly property real bottom: Math.max(frame.y + frame.height, genie.sink.y + genie.sink.height)

        ShaderEffect {
          visible: genie.pictured
          x: stage.left
          y: stage.top
          width: Math.max(1, stage.right - stage.left)
          height: Math.max(1, stage.bottom - stage.top)
          property var source: source
          property vector4d win: Qt.vector4d((frame.x - x) / width, 0,
                                             (frame.x + frame.width - x) / width, frame.height / height)
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

        // The cover: this part of the screen as it stands, opaque, over the
        // window and its shadow while the window and its picture change places.
        Item {
          x: frame.x
          y: frame.y
          width: frame.width
          height: frame.height
          clip: true
          visible: genie.covered
          // Made anew for each capture: a view that has had one keeps saying so.
          Loader {
            id: cover
            readonly property bool hasContent: cover.item !== null && cover.item.hasContent
            x: -parent.x
            y: -parent.y
            width: stage.width
            height: stage.height
            active: stage.mine && genie.covering
            onHasContentChanged: if (cover.hasContent && stage.mine) genie.arrived(shot.hasContent, true)
            sourceComponent: ScreencopyView {
              captureSource: stage.modelData
              paintCursor: false
              live: !hasContent
            }
          }
        }
      }
    }
  }
}
