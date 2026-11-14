const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")
const test = require("node:test")
const Model = require("../Model.js")

const root = path.join(__dirname, "..")
const read = file => fs.readFileSync(path.join(root, file), "utf8")
const panel = read("Panel.qml")
const qmlFiles = ["Panel.qml", "NotificationPopup.qml", "SettingsPane.qml", "Service.qml",
  ...fs.readdirSync(path.join(root, "components")).filter(f => f.endsWith(".qml")).map(f => "components/" + f)]

// Lift functions out of Panel.qml, as they are written, into a stand-in for the panel.
function functions(...names) {
  return names.map(name => {
    const start = panel.indexOf(`  function ${name}(`)
    assert.notEqual(start, -1, name)
    return panel.slice(start, panel.indexOf("\n  }\n", start) + 4)
  }).join("\n")
}

function sheet(rows, clock = { now: 1000000 }) {
  const state = vm.createContext({
    Model, opened: true, rows, entries: rows.filter(r => r.kind === "message").map(r => r.entry),
    confirmAll: false, confirmGroup: "", confirmArmedAt: 0, confirmFromButton: false,
    cursorIndex: 0, cursorDismiss: false,
    get confirmOpen() { return this.confirmAll || this.confirmGroup !== "" },
    cleared: 0, removedGroups: [], removed: [], toggled: [], focus: [],
    clearButton: { activeFocus: false, forceActiveFocus() { state.focus.push("clear") } },
    keyCatcher: { forceActiveFocus() { state.focus.push("catcher") } },
    clearAll() { state.cleared++ }, removeGroup(group) { state.removedGroups.push(group.key) },
    remove(key) { state.removed.push(key) }, toggleGroup(key) { state.toggled.push(key) },
    isFolded() { return false }, activate() {},
    Date: { now: () => clock.now }
  })
  state.root = state
  vm.runInContext(functions("requestClearAll", "requestRemoveGroup", "dropConfirm", "answerConfirm", "confirmTargetGone", "activateCursor"), state)
  return state
}

const entry = (key, stamp, urgency = 1) => ({ key, timestamp: stamp, urgency, app: "App" })
const header = (key, entries) => ({ kind: "header", group: { key, entries } })
const message = (group, e) => ({ kind: "message", group, entry: e })
function fixture() {
  const single = header("Single", [entry("1-1", 10)])
  const stack = header("Stack", [entry("2-1", 20), entry("3-1", 30), entry("4-1", 40)])
  return [single, message(single.group, single.group.entries[0]), stack, message(stack.group, stack.group.entries[0])]
}

// ------------------------------------------------------------------ confirmation

test("clear-all asks first and removes nothing until it is answered", () => {
  const clock = { now: 1000000 }
  const s = sheet(fixture(), clock)
  s.requestClearAll()
  assert.equal(s.confirmAll, true)
  assert.equal(s.cleared, 0)
  clock.now += Model.CONFIRM_GUARD_MS
  s.answerConfirm()
  assert.equal(s.cleared, 1)
  assert.equal(s.confirmAll, false)
})

test("a second press inside the guard is the same gesture, not an answer", () => {
  const clock = { now: 1000000 }
  const s = sheet(fixture(), clock)
  s.requestClearAll()
  clock.now += Model.CONFIRM_GUARD_MS - 1
  s.answerConfirm()
  assert.equal(s.cleared, 0)
  assert.equal(s.confirmAll, true)
})

test("Keep removes nothing, and hands focus back to where it came from", () => {
  const s = sheet(fixture())
  s.clearButton.activeFocus = true
  s.requestClearAll()
  s.dropConfirm()
  assert.equal(s.cleared, 0)
  assert.equal(s.confirmAll, false)
  assert.deepEqual(s.focus, ["clear"])

  const t = sheet(fixture())
  t.requestClearAll()
  t.dropConfirm()
  assert.deepEqual(t.focus, ["catcher"])
})

test("clear-all with nothing to clear does not ask", () => {
  const s = sheet([])
  s.requestClearAll()
  assert.equal(s.confirmAll, false)
})

test("the stack X asks first, by pointer and by key", () => {
  const clock = { now: 1000000 }
  const rows = fixture()
  const s = sheet(rows, clock)
  s.requestRemoveGroup(rows[2].group)
  assert.equal(s.confirmGroup, "Stack")
  assert.deepEqual(s.removedGroups, [])

  s.dropConfirm()
  s.cursorIndex = 2
  s.activateCursor(true)
  assert.equal(s.confirmGroup, "Stack", "Delete on a stack heading")
  assert.deepEqual(s.removedGroups, [])

  clock.now += Model.CONFIRM_GUARD_MS
  s.answerConfirm()
  assert.deepEqual(s.removedGroups, ["Stack"])
  assert.equal(s.confirmGroup, "")
})

test("the answer acts on the stack as it now stands, not as it was asked about", () => {
  const clock = { now: 1000000 }
  const rows = fixture()
  const s = sheet(rows, clock)
  s.requestRemoveGroup(rows[2].group)
  s.rows = rows.filter(r => r.kind === "message" || r.group.key !== "Stack")
  clock.now += Model.CONFIRM_GUARD_MS
  s.answerConfirm()
  assert.deepEqual(s.removedGroups, [], "the stack went while it was asking")
})

test("a single row goes in one action, whichever way", () => {
  const rows = fixture()
  const s = sheet(rows)
  s.requestRemoveGroup(rows[0].group)
  assert.deepEqual(s.removedGroups, ["Single"])
  assert.equal(s.confirmGroup, "")

  const t = sheet(rows)
  t.cursorIndex = 0
  t.activateCursor(true)
  assert.deepEqual(t.removedGroups, ["Single"], "Delete on a single's heading")
  assert.equal(t.confirmGroup, "")

  const u = sheet(rows)
  u.cursorIndex = 3
  u.activateCursor(true)
  assert.deepEqual(u.removed, ["2-1"], "Delete on a card takes that card")
  assert.equal(u.confirmGroup, "")
})

test("a stack scrolled out of the list stops asking", () => {
  const rows = fixture()
  const s = sheet(rows)
  s.requestRemoveGroup(rows[2].group)
  s.confirmTargetGone("Other")
  assert.equal(s.confirmGroup, "Stack")
  s.confirmTargetGone("Stack")
  assert.equal(s.confirmGroup, "")
  assert.deepEqual(s.focus, ["catcher"], "and the keyboard is not left nowhere")
})

test("the questions say how many, and from whom", () => {
  assert.equal(Model.clearAllQuestion(412).message, "Clear all 412 notifications?")
  assert.equal(Model.clearAllQuestion(1).message, "Clear all 1 notification?")
  assert.equal(Model.dismissStackQuestion("Build", 3).message, "Dismiss all 3 from Build?")
  assert.equal(Model.removalNeedsConfirm({ entries: [{}] }), false)
  assert.equal(Model.removalNeedsConfirm({ entries: [{}, {}] }), true)
  assert.equal(Model.removalNeedsConfirm(null), false)
})

test("the question holds focus on Keep, and a second Delete is no answer", () => {
  const confirm = read("components/NotificationConfirm.qml")
  assert.match(confirm, /keep\.forceActiveFocus\(\)/)
  assert.doesNotMatch(confirm, /action\.forceActiveFocus\(\)/)
  assert.match(confirm, /Qt\.Key_Delete[\s\S]{0,200}event\.accepted = true/)
  // Non-modal: a row in the sheet, not a popup or a dialog over it.
  assert.doesNotMatch(confirm, /Popup|Dialog|modal: /)
})

// ------------------------------------------------------------------ critical label

test("a critical says so in words, loud until read and quiet after", () => {
  const critical = entry("1-1", 200, 2)
  assert.equal(Model.criticalLabel(critical, 100), "CRITICAL")
  assert.equal(Model.criticalState(critical, 100), "unread")
  assert.equal(Model.criticalLabel(critical, 300), "CRITICAL", "the word stays once it is read")
  assert.equal(Model.criticalState(critical, 300), "read")
  assert.equal(Model.criticalState(critical, 200), "read", "the mark itself counts as seen")
})

test("anything else has no label", () => {
  for (const urgency of [0, 1, undefined, "1"]) {
    assert.equal(Model.criticalLabel(entry("1-1", 200, urgency), 100), "")
    assert.equal(Model.criticalState(entry("1-1", 200, urgency), 100), "")
  }
  assert.equal(Model.criticalLabel(null, 0), "")
  assert.equal(Model.criticalLabel(entry("1-1", 200, "2"), 100), "CRITICAL", "as the archive may store it")
})

test("a folded stack says what it hides, and only what it hides", () => {
  const entries = [entry("1-1", 300, 2), entry("2-1", 250, 2), entry("3-1", 200, 1), entry("4-1", 50, 2)]
  assert.deepEqual(Model.stackTags({ entries }, 100, false), { fresh: "3 new", critical: "1 critical" })
  assert.deepEqual(Model.stackTags({ entries }, 100, true), { fresh: "3 new", critical: "" }, "open: each card speaks")
  assert.deepEqual(Model.stackTags({ entries }, 400, false), { fresh: "", critical: "" }, "all read")
  assert.deepEqual(Model.stackTags({ entries: [entry("1-1", 300)] }, 100, false), { fresh: "new", critical: "" })
})

test("the label and the theme's red are gated on the holographic theme", () => {
  const row = read("components/NotificationRow.qml")
  assert.match(row, /id: criticalTag[\s\S]{0,120}visible: root\.holo && root\.criticalState !== ""/)
  assert.match(panel, /accent: root\.holo \? Commons\.Color\.urgent : root\.tintFor\(/)
  // The wash drops only under the theme; every other keeps it.
  assert.match(row, /isUrgent\(row\) && \(!holo \|\| Model\.isUnread\(row, readMark\)\)/)
  assert.doesNotMatch(row + panel, /#E14538/i)
})

// ------------------------------------------------------------------ empty states

test("an empty sheet says something true", () => {
  assert.equal(Model.emptyCopy(true, "", ""), "No notifications")
  assert.equal(Model.emptyCopy(false, "", ""), "Reading the archive…")
  assert.equal(Model.emptyCopy(false, "", "boom"), "History unavailable")
  assert.equal(Model.emptyCopy(true, "cat", ""), "Nothing matches “cat”")
})

// ------------------------------------------------------------------ reduced motion

test("every animation in this folder goes through Style.duration", () => {
  const bare = []
  for (const file of qmlFiles) read(file).split("\n").forEach((line, i) => {
    const code = line.replace(/\/\/.*$/, "")
    if (/\bduration\s*:/.test(code) && !/duration\s*:\s*Style\.duration\(/.test(code))
      bare.push(`${file}:${i + 1}: ${line.trim()}`)
    if (/\.duration\s*=/.test(code) && !/\.duration\s*=\s*Style\.duration\(/.test(code))
      bare.push(`${file}:${i + 1}: ${line.trim()}`)
  })
  assert.deepEqual(bare, [])
})

test("the spring has a guard, the swipe stays direct, and nothing divides by a duration", () => {
  const popup = read("NotificationPopup.qml")
  const release = popup.slice(popup.indexOf("  function release("), popup.indexOf("  // Item that should take keyboard focus"))
  assert.ok(release.indexOf("Style.reduceMotion") < release.indexOf("slideSpring.start()"), "guard before the spring")
  const drag = popup.slice(popup.indexOf("  function dragTo("), popup.indexOf("  // Fingers lifted."))
  assert.doesNotMatch(drag, /reduceMotion|Style\.duration/)
  assert.deepEqual(qmlFiles.filter(f => /\/\s*[\w.]*[dD]uration\b/.test(read(f))), [])
})

// ------------------------------------------------------------------ the seam

test("holo comes through a Loader and Color.pick, never an import", () => {
  for (const file of qmlFiles) assert.doesNotMatch(read(file), /^\s*import\s+".*(hud|holo)/m, file)
})

test("the frame's bleed is the frame's own, and it is held off the bar by a clip", () => {
  assert.doesNotMatch(panel, /anchors\.margins:\s*-56/)
  assert.match(panel, /bleed: holoFrame\.item \? holoFrame\.item\.pad : 0/)
  assert.match(panel, /clip: root\.holo/)
  assert.match(panel, /property: "dividerY"/)
})
