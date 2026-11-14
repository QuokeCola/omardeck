const assert = require("node:assert/strict")
const { spawnSync } = require("node:child_process")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const test = require("node:test")

const script = path.join(__dirname, "../bin/notification-center")

function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "notification-ingest-"))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  const source = path.join(dir, "notifications")
  fs.mkdirSync(path.join(source, "history"), { recursive: true })
  const store = path.join(dir, "store")
  const env = { ...process.env, NC_SRC_DIR: source, NC_SRC_HISTORY: path.join(source, "history"), NC_STORE: store, NC_PREVIEWS: "0" }
  const run = (...args) => {
    const result = spawnSync(script, args, { env, encoding: "utf8", timeout: 5000 })
    assert.equal(result.status, 0, result.stderr)
    return JSON.parse(result.stdout)
  }
  return {
    run,
    write(name, value) { fs.writeFileSync(path.join(source, name), typeof value === "string" ? value : JSON.stringify(value)) },
    archive: () => fs.readFileSync(path.join(store, "archive.jsonl"), "utf8"),
  }
}

// The fields of Store.js STORED in Omarchy 4.5, plus what a closed history row adds.
function stockRow(fields = {}) {
  return { key: "row01", originalId: 2, senderPid: 1234, execArgv: "", execActions: "", glyph: "", app: "Test", appIcon: "test-app",
    summary: "Subject", body: "Text", rawBody: "", source: "", groupKey: "test", urgency: 1, expireTimeout: 0, duration: 5000,
    ts: Date.now() / 1000 - 5, ...fields }
}
const keyOf = row => `${Math.floor(row.ts * 1000)}-${row.originalId}`

test("a stock live row becomes an archive row keyed by its arrival and id", t => {
  const f = fixture(t), row = stockRow({ execArgv: '["bash","-c","sender command"]', urgency: 2 })
  f.write("live.json", [row])
  f.run("sync")
  const [entry, ...rest] = f.run("list")
  assert.equal(rest.length, 0)
  assert.equal(entry.key, keyOf(row))
  assert.match(entry.key, /^[0-9]+-[0-9]+$/)
  assert.equal(entry.timestamp, Math.floor(row.ts * 1000))
  for (const field of ["app", "appIcon", "summary", "body", "urgency"]) assert.equal(entry[field], row[field])
  assert.equal(entry.imageFormat, 1)
  // The archive keeps its own shape, not the row's, so the command goes with the rest.
  for (const field of ["ts", "originalId", "execArgv", "execActions", "rawBody", "senderPid", "groupKey"]) assert.equal(Object.hasOwn(entry, field), false, field)
})

test("a stock history row is read the same way, and a screenshot keeps its fixed intent", t => {
  const f = fixture(t), file = "/tmp/screen shot.png"
  const row = stockRow({ execArgv: JSON.stringify(["tensaku-edit", file]), closed_ts: Date.now() / 1000, closed_reason: 1 })
  f.write("history.json", [row])
  f.run("sync")
  const [entry] = f.run("list")
  assert.equal(entry.key, keyOf(row))
  assert.equal(entry.file, file)
  assert.equal(entry.fileAction, "edit-screenshot")
})

test("a row moving from live to history stays one archive row, even under a new stock key", t => {
  const f = fixture(t), row = stockRow()
  f.write("live.json", [row])
  f.run("sync")
  const archived = f.archive()
  f.write("live.json", [])
  f.write("history.json", [{ ...row, key: "replayed01", closed_ts: Date.now() / 1000, closed_reason: 1 }])
  f.run("sync")
  assert.equal(f.archive(), archived)
  assert.equal(f.run("list").length, 1)
})

test("a live row updated in place replaces its archive row; a history row never does", t => {
  const f = fixture(t), row = stockRow()
  f.write("live.json", [row])
  f.run("sync")
  f.write("live.json", [{ ...row, body: "Updated" }])
  f.run("sync")
  assert.deepEqual(f.run("list").map(entry => entry.body), ["Updated"])
  f.write("live.json", [])
  f.write("history.json", [{ ...row, body: "Cut short by the history limit" }])
  f.run("sync")
  assert.deepEqual(f.run("list").map(entry => entry.body), ["Updated"])
})

test("a removed row does not come back from history or live", t => {
  const f = fixture(t), row = stockRow()
  f.write("history.json", [row])
  f.run("sync")
  f.run("remove", keyOf(row))
  f.run("sync")
  assert.deepEqual(f.run("list"), [])
  f.write("live.json", [row])
  f.run("sync")
  assert.deepEqual(f.run("list"), [])
})

test("quiet.json is not read as notifications", t => {
  const f = fixture(t)
  f.write("quiet.json", [stockRow()])
  f.run("sync")
  assert.deepEqual(f.run("list"), [])
  f.write("quiet.json", { doNotDisturb: true })
  f.run("sync")
  assert.deepEqual(f.run("list"), [])
})

test("rawBody wins over body when the sender's text differs, and body is used otherwise", t => {
  const f = fixture(t), base = Date.now() / 1000 - 10
  f.write("history.json", [
    stockRow({ ts: base, originalId: 1, body: "Hello", rawBody: "example.org\nHello" }),
    stockRow({ ts: base + 1, originalId: 2, body: "Plain", rawBody: "" }),
    stockRow({ ts: base + 2, originalId: 3, body: "No raw field", rawBody: undefined }),
  ])
  f.run("sync")
  assert.deepEqual(f.run("list").map(entry => entry.body).sort(), ["No raw field", "Plain", "example.org\nHello"])
})

test("rows and files that aren't the expected shape are skipped, and the rest still arrive", t => {
  const f = fixture(t), good = stockRow()
  f.write("history.json", [{ ...good, ts: 0 }, { ...good, ts: "soon" }, { app: "No timestamp" }, "text", 3, good])
  f.run("sync")
  assert.deepEqual(f.run("list").map(entry => entry.key), [keyOf(good)])
  for (const bad of ["{ cut off", '{"rows":[]}', ""]) {
    f.write("live.json", bad)
    f.run("sync")
    assert.equal(f.run("list").length, 1)
  }
})

test("a sender's update moves ts but keeps the archive row, read from the service's key", t => {
  const f = fixture(t)
  const created = Date.now() - 60000
  const key = "n" + created.toString(36) + "7"
  const row = stockRow({ key, ts: created / 1000, summary: "First" })
  f.write("live.json", [row])
  f.run("sync")
  f.write("live.json", [{ ...row, ts: created / 1000 + 30, summary: "Second" }])
  f.run("sync")
  const rows = f.run("list")
  assert.equal(rows.length, 1)
  assert.equal(rows[0].key, `${created}-7`)
  assert.equal(rows[0].summary, "Second")
})
