const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

test("prune retains valid records after corruption and clear preserves the archive", () => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), "notification-archive-test-"));
  try {
    const state = path.join(temp, "omarchy-notification-center");
    fs.mkdirSync(state, { recursive: true });
    const env = { ...process.env, HOME: temp, XDG_CONFIG_HOME: path.join(temp, "config"), XDG_STATE_HOME: temp, NC_KEEP_DAYS: "30", NC_MAX_ITEMS: "1000" };
    const script = path.join(__dirname, "../bin/notification-center");
    const run = (...args) => {
      const result = spawnSync("bash", [script, ...args], { env, encoding: "utf8" });
      assert.equal(result.status, 0, result.stderr);
      return result.stdout;
    };
    run("list");
    const archive = path.join(state, "archive.jsonl");
    const timestamp = Date.now() - 1000;
    const records = [1, 2].map(i => ({ key: `${timestamp}-${i}`, timestamp, summary: `record ${i}` }));
    fs.writeFileSync(archive, JSON.stringify(records[0]) + "\ncorrupt\n" + JSON.stringify(records[1]) + "\n");
    run("sync");
    assert.deepEqual(JSON.parse(run("list")).map(row => row.key).sort(), records.map(row => row.key));
    const before = fs.readFileSync(archive, "utf8");
    run("clear");
    assert.deepEqual(JSON.parse(run("list")), []);
    assert.equal(fs.readFileSync(archive, "utf8"), before);
  } finally {
    fs.rmSync(temp, { recursive: true, force: true });
  }
});
