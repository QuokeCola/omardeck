"use strict";
// The fold, against what the compositor really answers.
//
// fixtures/docked.batch.txt is the real answer to the query Screens.qml makes, on a
// laptop with two external screens, from fixtures/capture.py. Nothing has been seen
// of a real unplug: everything after "docked" here takes those real records and
// changes what Screens.qml's own comments say Hyprland changes: a gone screen's
// windows keep their workspace id and are handed to a screen that is left. That is
// the assumption a live test with a real dock has to check. capture.py can save the
// real thing to replace it.
//
// "KNOWN:" tests pin behaviour that looks wrong, so that a fix is a decision and not
// an accident. They are not a statement that it is right.
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const Desks = require("../app/Desks.js");
const HyprLua = require("../app/HyprLua.js");

const SYNCED = path.join(__dirname, "../app/synced.lua");
const RAW = fs.readFileSync(path.join(__dirname, "fixtures/docked.batch.txt"), "utf8");

// As Screens.qml splits it.
const [MONITORS, CLIENTS] = RAW.split("\n\n\n").map(s => JSON.parse(s));

const LAPTOP = "LG Display 0x07C8";
const WIDE = "LG Electronics LG ULTRAWIDE SERIAL-1";
const DELL = "Dell Inc. DELL P2423 SERIAL-2";
const ORDER = [LAPTOP, DELL, WIDE];

// The windows, by where they really were: the ultrawide (DP-1) is block 2 although
// it has monitor id 1, because the Dell (DP-2) is further left.
const WIDE_ON_2 = "55ac81e4d960"; // 22
const FOOT = "55ac8238dd20"; //      1
const WIDE_ON_1 = "55ac822d8a10"; // 21
const DELL_ON_1 = "55ac823fd640"; // 11

const LAPTOP_ID = 0, WIDE_ID = 1, DELL_ID = 2;

const clone = x => JSON.parse(JSON.stringify(x));

function screens(...names) {
  return clone(MONITORS).filter(m => names.indexOf(m.name) >= 0);
}

/** The real clients, with some handed to another monitor or workspace. */
function windows(changes) {
  return clone(CLIENTS).filter(c => (changes[key(c)] || {}).closed !== true).map(c => {
    const to = changes[key(c)] || {};
    if (to.monitor !== undefined) c.monitor = to.monitor;
    if (to.ws !== undefined) c.workspace = { id: to.ws, name: String(to.ws) };
    return c;
  });
}

function key(c) { return c.address.replace(/^0x/, ""); }

/** Every one of the real windows handed to one monitor, ids kept. */
function allOn(monitor, changes) {
  const out = {};
  for (const c of CLIENTS) out[key(c)] = Object.assign({ monitor: monitor }, (changes || {})[key(c)]);
  return out;
}

const byKey = moves => Object.fromEntries(moves.map(m => [m.key, m.ws]));

/** What the first look after pulling the whole dock leaves behind. */
function undocked() {
  return Desks.planFold(screens("eDP-1"), windows(allOn(LAPTOP_ID)), {}, ORDER);
}

/** What the screen looks like once the plan has been carried out. */
function placed(clients, plan) {
  const to = byKey(plan.moves);
  return clients.map(c => {
    const ws = to[key(c)];
    if (ws === undefined) return c;
    c.workspace = { id: ws, name: String(ws) };
    c.monitor = plan.order[Math.floor((ws - 1) / 10)].id;
    return c;
  });
}

const tests = {
  "fixture: real shape, personal text gone"() {
    assert.strictEqual(RAW.split("\n\n\n").length, 2);
    assert.strictEqual(MONITORS.length, 3);
    assert.strictEqual(CLIENTS.length, 4);
    for (const c of CLIENTS) {
      assert.ok(/^window-\d+$/.test(c.title), c.title);
      assert.ok(/^window-\d+$/.test(c.initialTitle), c.initialTitle);
      assert.ok(/^0x[0-9a-f]+$/.test(c.address));
      assert.strictEqual(typeof c.workspace.id, "number");
      assert.strictEqual(typeof c.monitor, "number");
    }
    for (const m of MONITORS) {
      assert.strictEqual(typeof m.x, "number");
      assert.strictEqual(typeof m.focused, "boolean");
      assert.strictEqual(typeof m.disabled, "boolean");
      assert.ok(m.serial === "" || /^SERIAL-\d+$/.test(m.serial), m.serial);
    }
  },

  "blocks: the laptop 1-10, the others left to right 11-20, 21-30"() {
    assert.deepStrictEqual(Desks.screenOrder(MONITORS), ["eDP-1", "DP-2", "DP-1"]);
    for (const m of MONITORS) {
      const i = Desks.screenOrder(MONITORS).indexOf(m.name);
      assert.strictEqual(Math.floor((m.activeWorkspace.id - 1) / 10), i, m.name);
      assert.strictEqual(Desks.spaceOn(Desks.deskOfId(m.activeWorkspace.id, true), i, true), m.activeWorkspace.id);
    }
  },

  "docked and settled: nothing to do"() {
    const plan = Desks.planFold(MONITORS, CLIENTS, {}, []);
    assert.deepStrictEqual(plan.moves, []);
    assert.deepStrictEqual(plan.folded, {});
    assert.deepStrictEqual(plan.lastOrder, ORDER);
    assert.strictEqual(Desks.deskToShow(plan.order, "laptop").lagging, false);
    assert.strictEqual(Desks.deskToShow(plan.order, "focused").lagging, false);
    assert.strictEqual(Desks.deskToShow(plan.order, "focused").focused.name, "DP-2");
  },

  "unplug the dock: every window into its own desktop on the laptop, remembered"() {
    const plan = undocked();
    assert.deepStrictEqual(byKey(plan.moves), { [WIDE_ON_2]: 2, [WIDE_ON_1]: 1, [DELL_ON_1]: 1 });
    assert.deepStrictEqual(plan.folded, {
      [WIDE_ON_2]: { screen: WIDE, desk: 2, ws: 2 },
      [WIDE_ON_1]: { screen: WIDE, desk: 1, ws: 1 },
      [DELL_ON_1]: { screen: DELL, desk: 1, ws: 1 },
    });
    assert.deepStrictEqual(plan.lastOrder, [LAPTOP]);
  },

  "unplug the dock: the script fills each desktop, then shows the laptop's"() {
    const plan = undocked();
    const to = Desks.deskToShow(plan.order, "laptop");
    assert.strictEqual(to.desk, 1);
    assert.strictEqual(to.focused.name, "eDP-1");
    const f = HyprLua.focusMonitor, s = HyprLua.focusSpace, m = HyprLua.moveWindow;
    assert.strictEqual(HyprLua.alignScript(plan.order, plan.moves, to.desk, to.focused.name), HyprLua.quiet(
      f("eDP-1")
      + s(1, true) + m(WIDE_ON_1, 1) + f("eDP-1") + m(DELL_ON_1, 1) + f("eDP-1")
      + s(2, true) + m(WIDE_ON_2, 2) + f("eDP-1")
      + s(1, true)
      + f("eDP-1")));
  },

  "looking again while undocked changes nothing (every workspace switch looks)"() {
    const first = undocked();
    const again = Desks.planFold(screens("eDP-1"), placed(windows(allOn(LAPTOP_ID)), first), first.folded, first.lastOrder);
    assert.deepStrictEqual(again.moves, []);
    assert.deepStrictEqual(again.folded, first.folded);
  },

  "plug the dock back: every window home, nothing left to remember"() {
    const first = undocked();
    const clients = placed(windows(allOn(LAPTOP_ID)), first);
    const back = Desks.planFold(MONITORS, clients, first.folded, first.lastOrder);
    assert.deepStrictEqual(byKey(back.moves), { [WIDE_ON_2]: 22, [WIDE_ON_1]: 21, [DELL_ON_1]: 11 });
    assert.deepStrictEqual(back.folded, {});
    assert.deepStrictEqual(back.lastOrder, ORDER);
    const f = HyprLua.focusMonitor, s = HyprLua.focusSpace, m = HyprLua.moveWindow;
    assert.strictEqual(HyprLua.alignScript(back.order, back.moves, 1, "eDP-1"), HyprLua.quiet(
      f("eDP-1") + s(1, true)
      + f("DP-2") + s(11, true) + m(DELL_ON_1, 11) + f("DP-2") + s(11, true)
      + f("DP-1") + s(21, true) + m(WIDE_ON_1, 21) + f("DP-1") + s(22, true) + m(WIDE_ON_2, 22) + f("DP-1") + s(21, true)
      + f("eDP-1")));
  },

  "plug the dock back under other connectors and ids: the same screens"() {
    const first = undocked();
    const clients = placed(windows(allOn(LAPTOP_ID)), first);
    const monitors = clone(MONITORS);
    monitors[1].name = "DP-7"; monitors[1].id = 5;
    monitors[2].name = "DP-8"; monitors[2].id = 4;
    const back = Desks.planFold(monitors, clients, first.folded, first.lastOrder);
    assert.deepStrictEqual(byKey(back.moves), { [WIDE_ON_2]: 22, [WIDE_ON_1]: 21, [DELL_ON_1]: 11 });
    assert.deepStrictEqual(back.order.map(m => m.name), ["eDP-1", "DP-8", "DP-7"]);
  },

  "screens returning one at a time, left one first"() {
    const first = undocked();
    let clients = placed(windows(allOn(LAPTOP_ID)), first);
    const dell = Desks.planFold(screens("eDP-1", "DP-2"), clients, first.folded, first.lastOrder);
    assert.deepStrictEqual(byKey(dell.moves), { [DELL_ON_1]: 11 });
    assert.deepStrictEqual(Object.keys(dell.folded).sort(), [WIDE_ON_2, WIDE_ON_1].sort());
    clients = placed(clients, dell);
    const all = Desks.planFold(MONITORS, clients, dell.folded, dell.lastOrder);
    assert.deepStrictEqual(byKey(all.moves), { [WIDE_ON_2]: 22, [WIDE_ON_1]: 21 });
    assert.deepStrictEqual(all.folded, {});
  },

  "screens returning one at a time, right one first: it borrows block 1, then moves up"() {
    const first = undocked();
    let clients = placed(windows(allOn(LAPTOP_ID)), first);
    const wide = Desks.planFold(screens("eDP-1", "DP-1"), clients, first.folded, first.lastOrder);
    assert.deepStrictEqual(byKey(wide.moves), { [WIDE_ON_2]: 12, [WIDE_ON_1]: 11 });
    assert.deepStrictEqual(Object.keys(wide.folded), [DELL_ON_1]);
    clients = placed(clients, wide);
    const all = Desks.planFold(MONITORS, clients, wide.folded, wide.lastOrder);
    assert.deepStrictEqual(byKey(all.moves), { [WIDE_ON_2]: 22, [WIDE_ON_1]: 21, [DELL_ON_1]: 11 });
    assert.deepStrictEqual(all.folded, {});
  },

  "a window moved while away has found a home of its own"() {
    const first = undocked();
    const clients = placed(windows(allOn(LAPTOP_ID)), first).map(c => {
      if (key(c) === WIDE_ON_2) c.workspace = { id: 5, name: "5" };
      return c;
    });
    const back = Desks.planFold(MONITORS, clients, first.folded, first.lastOrder);
    assert.deepStrictEqual(byKey(back.moves), { [WIDE_ON_1]: 21, [DELL_ON_1]: 11 });
    assert.deepStrictEqual(back.folded, {});
  },

  "a window closed while away is forgotten"() {
    const first = undocked();
    const clients = placed(windows(allOn(LAPTOP_ID, { [WIDE_ON_2]: { closed: true } })), first);
    const again = Desks.planFold(screens("eDP-1"), clients, first.folded, first.lastOrder);
    assert.deepStrictEqual(Object.keys(again.folded).sort(), [WIDE_ON_1, DELL_ON_1].sort());
  },

  "only the outer screen goes: the Dell's windows stay, the ultrawide's fold and return"() {
    const left = screens("eDP-1", "DP-2");
    const away = windows({ [WIDE_ON_2]: { monitor: LAPTOP_ID }, [WIDE_ON_1]: { monitor: LAPTOP_ID } });
    const gone = Desks.planFold(left, away, {}, ORDER);
    assert.deepStrictEqual(byKey(gone.moves), { [WIDE_ON_2]: 2, [WIDE_ON_1]: 1 });
    assert.deepStrictEqual(Object.keys(gone.folded).sort(), [WIDE_ON_2, WIDE_ON_1].sort());
    const back = Desks.planFold(MONITORS, placed(away, gone), gone.folded, gone.lastOrder);
    assert.deepStrictEqual(byKey(back.moves), { [WIDE_ON_2]: 22, [WIDE_ON_1]: 21 });
  },

  "only the outer screen goes, its windows handed to the other external: same"() {
    const left = screens("eDP-1", "DP-2");
    const away = windows({ [WIDE_ON_2]: { monitor: DELL_ID }, [WIDE_ON_1]: { monitor: DELL_ID } });
    const gone = Desks.planFold(left, away, {}, ORDER);
    assert.deepStrictEqual(byKey(gone.moves), { [WIDE_ON_2]: 12, [WIDE_ON_1]: 11 });
    const back = Desks.planFold(MONITORS, placed(away, gone), gone.folded, gone.lastOrder);
    assert.deepStrictEqual(byKey(back.moves), { [WIDE_ON_2]: 22, [WIDE_ON_1]: 21 });
  },

  "only the middle screen goes: the outer one closes up, and opens again"() {
    const left = screens("eDP-1", "DP-1");
    const away = windows({ [DELL_ON_1]: { monitor: LAPTOP_ID } });
    const gone = Desks.planFold(left, away, {}, ORDER);
    assert.deepStrictEqual(byKey(gone.moves), { [WIDE_ON_2]: 12, [WIDE_ON_1]: 11, [DELL_ON_1]: 1 });
    assert.deepStrictEqual(Object.keys(gone.folded), [DELL_ON_1]);
    const back = Desks.planFold(MONITORS, placed(away, gone), gone.folded, gone.lastOrder);
    assert.deepStrictEqual(byKey(back.moves), { [WIDE_ON_2]: 22, [WIDE_ON_1]: 21, [DELL_ON_1]: 11 });
    assert.deepStrictEqual(back.folded, {});
  },

  "a profile swaps the externals: the blocks follow x"() {
    const monitors = clone(MONITORS);
    monitors[1].x = -3440; // the ultrawide now furthest left
    const plan = Desks.planFold(monitors, CLIENTS, {}, ORDER);
    assert.deepStrictEqual(byKey(plan.moves), { [WIDE_ON_2]: 12, [WIDE_ON_1]: 11, [DELL_ON_1]: 21 });
    assert.deepStrictEqual(plan.folded, {}, "no screen went");
    assert.deepStrictEqual(plan.lastOrder, [LAPTOP, WIDE, DELL]);
  },

  "a disabled screen is no screen"() {
    const monitors = clone(MONITORS);
    monitors[1].disabled = true;
    assert.deepStrictEqual(Desks.screenOrder(monitors), ["eDP-1", "DP-2"]);
  },

  "what is not a window on a screen is left alone"() {
    const clients = clone(CLIENTS);
    clients[0].workspace = { id: -98, name: "special:x" };
    clients[2].monitor = -1;
    assert.deepStrictEqual(Desks.planFold(screens("eDP-1"), clients, {}, ORDER).moves
      .filter(m => m.key === WIDE_ON_2 || m.key === WIDE_ON_1), []);
  },

  "digit guard: nothing but a whole number ever reaches a workspace"() {
    const order = Desks.orderMonitors(MONITORS);
    const none = HyprLua.alignScript(order, [], 1, "eDP-1");
    for (const bad of ["3'", "x", "1.5", "-1", "1 })", NaN]) {
      assert.strictEqual(HyprLua.alignScript(order, [{ key: "a1", ws: bad }], 1, "eDP-1"), none, String(bad));
    }
    assert.strictEqual(HyprLua.alignScript(order, [{ key: "not hex", ws: 3 }], 1, "eDP-1").indexOf("not hex"), -1);
  },

  "a monitor name that is not plainly one is skipped, and the rest stands"() {
    const script = HyprLua.alignScript([{ name: "eDP-1" }, { name: "x'y" }, { name: "DP-1" }], [], 1, "x'y");
    assert.strictEqual(script.indexOf("x'y"), -1);
    assert.ok(script.indexOf(HyprLua.focusSpace(21, true)) > 0, "the third keeps its block");
    assert.strictEqual(script.indexOf(HyprLua.focusSpace(11, true)), -1);
  },

  "synced.lua: the same blocks as Desks.js, the same keys as ever"() {
    const seen = runLua(MONITORS);
    assert.strictEqual(Object.keys(seen.desc).length, 30);
    for (let n = 1; n <= 10; n++) {
      const key = "code:" + (n + 9);
      assert.strictEqual(seen.desc["SUPER + " + key], "Switch all screens to desktop " + n);
      assert.strictEqual(seen.desc["SUPER + SHIFT + " + key], "Move window to desktop " + n);
      assert.strictEqual(seen.desc["SUPER + SHIFT + ALT + " + key], "Move window silently to desktop " + n);
    }
    // SUPER+N sends the desktop and nothing else, for the overview to move every screen.
    assert.deepStrictEqual(seen.press["SUPER + code:12"], ["event:aerial,desk:3"]);
    const order = Desks.screenOrder(MONITORS);
    for (const m of MONITORS) {
      const here = clone(MONITORS).map(o => Object.assign(o, { focused: o.name === m.name }));
      const said = runLua(here);
      const space = String(Desks.spaceOn(3, order.indexOf(m.name), true));
      assert.deepStrictEqual(said.press["SUPER + SHIFT + ALT + code:12"], ["move:" + space], m.name);
      assert.deepStrictEqual(said.press["SUPER + SHIFT + code:12"], ["move:" + space, "event:aerial,desk:3"], m.name);
    }
  },

  // ---------------------------------------------------------------- KNOWN

  "KNOWN: handed to a screen that takes over its block number, a window is not remembered"() {
    // The Dell goes, its window lands on the ultrawide, which closes up into block 1
    // where the window already is. Nothing moves it, so it is not remembered, and
    // when the Dell returns it follows the ultrawide to 21 and stays there.
    const left = screens("eDP-1", "DP-1");
    const away = windows({ [DELL_ON_1]: { monitor: WIDE_ID } });
    const gone = Desks.planFold(left, away, {}, ORDER);
    assert.deepStrictEqual(gone.folded, {});
    assert.strictEqual(byKey(gone.moves)[DELL_ON_1], undefined);
    const back = Desks.planFold(MONITORS, placed(away, gone), gone.folded, gone.lastOrder);
    assert.strictEqual(byKey(back.moves)[DELL_ON_1], 21);
  },

  "KNOWN: closing the laptop's panel: its windows are not remembered either"() {
    // Block 0 is whichever screen is first, so with the panel off the Dell takes 1-10
    // and a laptop window handed to it is already "home".
    const left = screens("DP-2", "DP-1");
    const away = windows({ [FOOT]: { monitor: DELL_ID } });
    const gone = Desks.planFold(left, away, {}, ORDER);
    assert.deepStrictEqual(gone.folded, {});
    const back = Desks.planFold(MONITORS, placed(away, gone), gone.folded, gone.lastOrder);
    assert.strictEqual(byKey(back.moves)[FOOT], 11, "ends up on the Dell, not the panel");
  },

  "KNOWN: two screens going in two steps: only the second is remembered"() {
    const one = Desks.planFold(screens("eDP-1", "DP-2"),
                               windows({ [WIDE_ON_2]: { monitor: DELL_ID }, [WIDE_ON_1]: { monitor: DELL_ID } }), {}, ORDER);
    const clients = placed(windows({ [WIDE_ON_2]: { monitor: DELL_ID }, [WIDE_ON_1]: { monitor: DELL_ID } }), one)
      .map(c => Object.assign(c, { monitor: LAPTOP_ID }));
    const two = Desks.planFold(screens("eDP-1"), clients, one.folded, one.lastOrder);
    assert.strictEqual(two.folded[WIDE_ON_2].screen, DELL, "was the ultrawide's");
  },

  "KNOWN: what is remembered does not outlive the shell"() {
    // A restart while undocked starts from nothing, so a window still outside its
    // block folds without a record.
    const plan = Desks.planFold(screens("eDP-1"), windows(allOn(LAPTOP_ID)), {}, []);
    assert.deepStrictEqual(byKey(plan.moves), { [WIDE_ON_2]: 2, [WIDE_ON_1]: 1, [DELL_ON_1]: 1 });
    assert.deepStrictEqual(plan.folded, {});
  },
};

/** synced.lua against a pretend `hl`, with these monitors: its binds and what a few say. */
function runLua(monitors) {
  const table = monitors.map(m => `{ name = ${JSON.stringify(m.name)}, x = ${m.x}, focused = ${m.focused} }`).join(", ");
  const lua = `
    local desc, said = {}, {}
    local binds = {}
    _G.hl = {
      dispatch = function(what) said[#said + 1] = what end,
      bind = function(key, what, opts) binds[key] = what; desc[key] = opts.description end,
      unbind = function() end,
      get_monitors = function() return { ${table} } end,
      dsp = { event = function(s) return "event:" .. s end,
              window = { move = function(t) return "move:" .. t.workspace end } },
    }
    dofile(${JSON.stringify(SYNCED)})
    for key, d in pairs(desc) do print("desc\\t" .. key .. "\\t" .. d) end
    for _, key in ipairs({ "SUPER + code:12", "SUPER + SHIFT + code:12", "SUPER + SHIFT + ALT + code:12" }) do
      said = {}
      binds[key]()
      print("press\\t" .. key .. "\\t" .. table.concat(said, "|"))
    end`;
  const run = spawnSync("lua", ["-"], { input: lua, encoding: "utf8" });
  assert.strictEqual(run.status, 0, run.stderr);
  const out = { desc: {}, press: {} };
  for (const line of run.stdout.trim().split("\n")) {
    const [kind, name, value] = line.split("\t");
    out[kind][name] = kind === "press" ? value.split("|") : value;
  }
  return out;
}

let failed = 0;
for (const [name, run] of Object.entries(tests)) {
  try {
    run();
    console.log("  ok   " + name);
  } catch (e) {
    failed++;
    console.log("  FAIL " + name + "\n       " + e.message);
  }
}
console.log(failed ? `${failed} failing` : `${Object.keys(tests).length} passing`);
process.exit(failed ? 1 : 0);
