const assert = require("node:assert/strict")
const { spawn, spawnSync } = require("node:child_process")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const test = require("node:test")

const script = path.join(__dirname, "../bin/notification-center")

// inotifywait ignores SIGPIPE, so nothing but a signal ends it once its reader is gone.
async function killWatchWith(t, signal) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "notification-watcher-"))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  const source = path.join(dir, "state/notifications")
  const watch = spawn(script, ["watch"], {
    env: { ...process.env, NC_SRC_DIR: source, NC_SRC_HISTORY: path.join(source, "history"), NC_STORE: path.join(dir, "store") },
    stdio: ["ignore", "pipe", "ignore"],
  })
  await new Promise((resolve, reject) => {
    watch.stdout.on("data", data => { if (String(data).includes("storeChanged")) resolve() })
    watch.on("exit", () => reject(new Error("watch exited before it was ready")))
  })
  const child = Number(spawnSync("pgrep", ["-P", String(watch.pid), "-x", "inotifywait"], { encoding: "utf8" }).stdout.trim())
  assert.ok(child > 0, "watch has an inotifywait child")
  t.after(() => { try { process.kill(child, "SIGKILL") } catch {} })

  watch.removeAllListeners("exit")
  const gone = new Promise(resolve => watch.on("exit", resolve))
  watch.kill(signal)
  await gone
  const alive = () => { try { process.kill(child, 0); return true } catch { return false } }
  for (let i = 0; i < 40 && alive(); i++) await new Promise(resolve => setTimeout(resolve, 50))
  assert.equal(alive(), false, `inotifywait outlived a watch killed with ${signal}`)
}

test("inotifywait exits when its watch is killed outright", t => killWatchWith(t, "SIGKILL"))
test("inotifywait exits when its watch is asked to stop", t => killWatchWith(t, "SIGTERM"))
