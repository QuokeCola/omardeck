import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/quokecola.omardeck/overview/shell" as O
import "plugins/quokecola.omardeck/overview/app/Desks.js" as Desks
import "plugins/quokecola.omardeck/overview/app/HyprLua.js" as HyprLua

// The pure modules agree with the QML they were taken from, on the same input,
// while that QML still has its own copy. Delete a check here once its QML uses the
// module: then there is nothing left to disagree. Also proves the modules load in
// QML, not only in node.
ShellRoot {
  id: root
  O.Service { id: s }
  O.Screens { id: screens; active: false }

  property int bad: 0
  function same(a, b, what) {
    const x = JSON.stringify(a), y = JSON.stringify(b)
    if (x === y) return
    root.bad++
    console.log("  FAIL " + what + "\n    qml    " + x + "\n    module " + y)
  }

  FileView { id: logFile; path: "/tmp/hypr.log"; blockLoading: true; printErrors: false }
  function lastEval() {
    logFile.reload()
    logFile.waitForJob()
    const lines = logFile.text().split("\n").filter(l => l.startsWith('hyprctl ["eval"') && l.indexOf("no_warps") >= 0)
    return lines.length ? JSON.parse(lines[lines.length - 1].slice(8))[1] : ""
  }

  readonly property var laptop: ({ id: 0, name: "eDP-1", description: "Laptop", x: 1920, focused: false, activeWorkspace: { id: 1 } })
  readonly property var left: ({ id: 1, name: "DP-2", description: "Left", x: 0, focused: true, activeWorkspace: { id: 14 } })
  readonly property var right: ({ id: 2, name: "DP-3", description: "Right", x: 3840, focused: false, activeWorkspace: { id: 21 } })
  readonly property var client: (address, ws, monitor) => ({ address: "0x" + address, workspace: { id: ws }, monitor: monitor })

  // Each: monitors, clients, folded before, order before, lead.
  property var folds: [
    { m: [root.laptop, root.left], c: [root.client("a", 3, 0), root.client("b", 13, 1), root.client("c", 13, 0)], f: ({}), o: [], l: "laptop" },
    { m: [root.laptop], c: [root.client("b", 13, 0)], f: ({}), o: ["Laptop", "Left"], l: "laptop" },
    { m: [root.laptop, root.left], c: [root.client("b", 3, 0)], f: ({ b: { screen: "Left", desk: 3, ws: 3 } }), o: ["Laptop"], l: "focused" },
    { m: [root.right, root.left, root.laptop], c: [root.client("a", 5, 2), root.client("b", 25, 0), root.client("c", 5, 1)], f: ({}), o: [], l: "focused" },
  ]

  // The real answer from a docked desk, the dock pulled and then put back, the
  // second carrying on from what the first left in Screens.
  FileView {
    id: dockedFile
    path: Qt.resolvedUrl("plugins/quokecola.omardeck/overview/tests/fixtures/docked.batch.txt").toString().slice(7)
    blockLoading: true
  }
  Component.onCompleted: {
    const answer = dockedFile.text().split("\n\n\n").map(s => JSON.parse(s))
    const said = (monitors, clients) => JSON.stringify(monitors) + "\n\n\n" + JSON.stringify(clients)
    const handed = answer[1].map(c => Object.assign({}, c, { monitor: 0 }))
    const folded = handed.map(c => Object.assign({}, c, { workspace: { id: (c.workspace.id - 1) % 10 + 1 } }))
    const laptop = answer[0].filter(m => m.id === 0)
    root.folds = root.folds.concat([
      { m: laptop, c: handed, f: ({}), o: Desks.orderMonitors(answer[0]).map(Desks.screenId), l: "laptop", remembered: 3, text: said(laptop, handed) },
      { m: answer[0], c: folded, l: "laptop", carry: true, remembered: 0, text: said(answer[0], folded) },
    ])
  }

  property int at: 0
  Timer {
    interval: 500
    running: true
    repeat: true
    onTriggered: root.next()
  }

  // One fold every half second through Screens, then what it kept and dispatched
  // against planFold + deskToShow + alignScript. It uses those itself now, so this
  // no longer compares two copies: it is what shows it is wired to them right, in
  // QML, where nothing else runs them.
  function next() {
    if (root.at > 0) root.compareLast()
    if (root.at >= root.folds.length) {
      root.finish()
      return
    }
    const t = root.folds[root.at++]
    if (t.carry) {
      t.f = screens.folded
      t.o = screens.lastOrder
    } else {
      screens.folded = t.f
      screens.lastOrder = t.o
    }
    // As the query's answer where there is one, through the parsing as well.
    if (t.text) screens.takeAnswer(t.text)
    else screens.align(t.m, t.c, t.l)
  }

  function compareLast() {
    const t = root.folds[root.at - 1]
    const plan = Desks.planFold(t.m, t.c, t.f, t.o)
    const to = Desks.deskToShow(plan.order, t.l)
    root.same(screens.folded, plan.folded, "folded " + root.at)
    root.same(screens.lastOrder, plan.lastOrder, "lastOrder " + root.at)
    root.same(root.lastEval(), HyprLua.alignScript(plan.order, plan.moves, to.desk, to.focused.name), "script " + root.at)
    if (t.remembered !== undefined) root.same(Object.keys(screens.folded).length, t.remembered, "remembered " + root.at)
  }

  function finish() {
    // The Service's deco is Deco.parse's now, so only the wiring is left to check,
    // on the one thing a theme relies on: an inactive shadow colour counts if `set`.
    const shadow = '{"option": "decoration:shadow:color", "color": "ee1a1a1a"}\n\n'
    s.takeDeco(shadow + '{"option": "decoration:shadow:color_inactive", "color": "ffffffff", "set": false}')
    root.same(s.deco.shadowColorInactive, "#ee1a1a1a", "unset inactive shadow")
    s.takeDeco(shadow + '{"option": "decoration:shadow:color_inactive", "color": "aa112233", "set": true}')
    root.same(s.deco.shadowColorInactive, "#aa112233", "set inactive shadow")


    console.log("VERDICT " + (root.bad === 0 ? "ok" : root.bad + " failing"))
    Qt.quit()
  }
}
