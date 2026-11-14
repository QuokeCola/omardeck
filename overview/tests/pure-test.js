"use strict";
// The pure logic: Desks, HyprLua, Deco and Wire. The `pure` harness also checks
// these against the code in the QML they were taken from, until that is wired up
// to use them.
const assert = require("assert");
const Desks = require("../app/Desks.js");
const HyprLua = require("../app/HyprLua.js");
const Deco = require("../app/Deco.js");
const Wire = require("../app/Wire.js");

const QUIET_HEAD = "local w = hl.get_config('cursor.no_warps'); hl.config({ cursor = { no_warps = true } }); ";
const QUIET_TAIL = "hl.config({ cursor = { no_warps = w } })";

const LAPTOP = { id: 0, name: "eDP-1", description: "Laptop", x: 1920, focused: false, activeWorkspace: { id: 1 } };
const LEFT = { id: 1, name: "DP-2", description: "Left screen", x: 0, focused: true, activeWorkspace: { id: 11 } };
const RIGHT = { id: 2, name: "DP-3", description: "Right screen", x: 3840, focused: false, activeWorkspace: { id: 21 } };

function client(address, ws, monitor) {
  return { address: "0x" + address, workspace: { id: ws }, monitor: monitor };
}

const tests = {
  "desks: laptop first, then left to right, disabled left out"() {
    assert.deepStrictEqual(Desks.screenOrder([RIGHT, LEFT, LAPTOP]), ["eDP-1", "DP-2", "DP-3"]);
    assert.deepStrictEqual(Desks.screenOrder([RIGHT, Object.assign({}, LEFT, { disabled: true })]), ["DP-3"]);
    assert.deepStrictEqual(Desks.screenOrder([]), []);
  },

  "desks: a workspace's desktop, and back"() {
    assert.strictEqual(Desks.deskOfId(13, true), 3);
    assert.strictEqual(Desks.deskOfId(10, true), 10);
    assert.strictEqual(Desks.deskOfId(20, true), 10);
    assert.strictEqual(Desks.deskOfId(13, false), 13);
    assert.strictEqual(Desks.deskOfId(-99, true), -99);
    assert.strictEqual(Desks.spaceOn(3, 2, true), 23);
    assert.strictEqual(Desks.spaceOn(3, 2, false), 3);
    assert.strictEqual(Desks.spaceOn(3, -1, true), 3);
    assert.strictEqual(Desks.spaceOn(-1, 2, true), -1);
    for (let id = 1; id <= 30; id++) {
      assert.strictEqual(Desks.spaceOn(Desks.deskOfId(id, true), Math.floor((id - 1) / 10), true), id);
    }
  },

  "fold: no screens, nothing to plan"() {
    assert.strictEqual(Desks.planFold([], [], {}, []), null);
  },

  "fold: windows in their own block stay, the rest come in"() {
    const plan = Desks.planFold([LAPTOP, LEFT], [client("a", 3, 0), client("b", 13, 1), client("c", 13, 0)], {}, []);
    assert.deepStrictEqual(plan.moves, [{ key: "c", ws: 3 }]);
    assert.deepStrictEqual(plan.lastOrder, ["Laptop", "Left screen"]);
    assert.deepStrictEqual(plan.folded, {}, "nothing to remember: no screen went");
  },

  "fold: a screen unplugged and plugged back"() {
    const before = ["Laptop", "Left screen"];
    // Unplugged: its window lands on the laptop, in the left screen's block.
    const gone = Desks.planFold([LAPTOP], [client("b", 13, 0)], {}, before);
    assert.deepStrictEqual(gone.moves, [{ key: "b", ws: 3 }]);
    assert.deepStrictEqual(gone.folded, { b: { screen: "Left screen", desk: 3, ws: 3 } });
    assert.deepStrictEqual(gone.lastOrder, ["Laptop"]);
    // Plugged back, it goes home.
    const back = Desks.planFold([LAPTOP, LEFT], [client("b", 3, 0)], gone.folded, gone.lastOrder);
    assert.deepStrictEqual(back.moves, [{ key: "b", ws: 13 }]);
    assert.deepStrictEqual(back.folded, {});
    // The input was not changed.
    assert.deepStrictEqual(gone.folded, { b: { screen: "Left screen", desk: 3, ws: 3 } });
  },

  "fold: a dock under another connector name is the same screen"() {
    const back = Desks.planFold([LAPTOP, Object.assign({}, LEFT, { name: "DP-9" })], [client("b", 3, 0)],
                                { b: { screen: "Left screen", desk: 3, ws: 3 } }, ["Laptop"]);
    assert.deepStrictEqual(back.moves, [{ key: "b", ws: 13 }]);
  },

  "fold: moved since it was folded, it has a home of its own"() {
    const plan = Desks.planFold([LAPTOP, LEFT], [client("b", 5, 0)],
                                { b: { screen: "Left screen", desk: 3, ws: 3 } }, ["Laptop"]);
    assert.deepStrictEqual(plan.moves, []);
    assert.deepStrictEqual(plan.folded, {});
  },

  "fold: a closed window is forgotten"() {
    const plan = Desks.planFold([LAPTOP], [], { gone: { screen: "Left screen", desk: 3, ws: 3 } }, []);
    assert.deepStrictEqual(plan.folded, {});
  },

  "fold: what cannot be a window is left alone"() {
    const plan = Desks.planFold([LAPTOP], [client("zz;", 13, 0), client("a", -99, 0), client("b", 13, 7),
                                           { address: "0xc", monitor: 0 }], {}, []);
    assert.deepStrictEqual(plan.moves, []);
  },

  "fold: which desktop, from whom"() {
    const order = Desks.orderMonitors([LAPTOP, LEFT]);
    assert.deepStrictEqual(Desks.deskToShow(order, "laptop").desk, 1);
    const moved = [LAPTOP, Object.assign({}, LEFT, { activeWorkspace: { id: 14 } })];
    const to = Desks.deskToShow(Desks.orderMonitors(moved), "focused");
    assert.strictEqual(to.desk, 4);
    assert.strictEqual(to.lagging, true);
    assert.strictEqual(to.focused.name, "DP-2");
    assert.strictEqual(Desks.deskToShow(order, "laptop").lagging, false);
    assert.strictEqual(Desks.deskToShow([{ name: "eDP-1" }], "laptop").desk, 1);
    assert.strictEqual(Desks.deskToShow([{ name: "eDP-1" }], "laptop").lagging, true);
  },

  "lua: statements say what the code in the overlay and Screens says"() {
    assert.strictEqual(HyprLua.focusWindow("0xAB12"), "hl.dispatch(hl.dsp.focus({ window = 'address:0xAB12' })); ");
    assert.strictEqual(HyprLua.focusWindow("ab12"), "hl.dispatch(hl.dsp.focus({ window = 'address:0xab12' })); ");
    assert.strictEqual(HyprLua.focusMonitor("HDMI-A-1"), "hl.dispatch(hl.dsp.focus({ monitor = 'HDMI-A-1' })); ");
    assert.strictEqual(HyprLua.focusSpace(13, true), "hl.dispatch(hl.dsp.focus({ workspace = '13', on_current_monitor = true })); ");
    assert.strictEqual(HyprLua.focusSpace(13), "hl.dispatch(hl.dsp.focus({ workspace = '13' })); ");
    assert.strictEqual(HyprLua.moveWindow("a1", 3),
                       "hl.dispatch(hl.dsp.window.move({ window = 'address:0xa1', workspace = '3', follow = false })); ");
  },

  "lua: refuses what is not plainly an address, a name or a number"() {
    for (const bad of ["", null, undefined, "xyz", "a1' }) os.execute('x", "a1\n", "0x"]) {
      assert.strictEqual(HyprLua.focusWindow(bad), "", String(bad));
      assert.strictEqual(HyprLua.moveWindow(bad, 3), "", String(bad));
    }
    for (const bad of ["", "DP 1", "a'b", "x}) os.execute(", "é"]) assert.strictEqual(HyprLua.focusMonitor(bad), "", bad);
    for (const bad of ["", "1'", "-1", "1.5", "name"]) {
      assert.strictEqual(HyprLua.focusSpace(bad, true), "", bad);
      assert.strictEqual(HyprLua.moveWindow("a1", bad), "", bad);
    }
    // In a whole script, the bad name goes and the rest stands.
    const script = HyprLua.switchScript(["DP-2", "bad'name"], n => 1);
    assert.ok(script.indexOf("bad") < 0);
    assert.ok(script.indexOf("DP-2") > 0);
  },

  "lua: switching every screen, focus last on the one you are on"() {
    assert.strictEqual(HyprLua.switchScript(["DP-2", "eDP-1"], n => (n === "DP-2" ? 13 : 3), "a1"),
      QUIET_HEAD
      + "hl.dispatch(hl.dsp.focus({ monitor = 'DP-2' })); hl.dispatch(hl.dsp.focus({ workspace = '13', on_current_monitor = true })); "
      + "hl.dispatch(hl.dsp.focus({ monitor = 'eDP-1' })); hl.dispatch(hl.dsp.focus({ workspace = '3', on_current_monitor = true })); "
      + "hl.dispatch(hl.dsp.focus({ window = 'address:0xa1' })); "
      + QUIET_TAIL);
    assert.strictEqual(HyprLua.switchScript([], n => 1), QUIET_HEAD + QUIET_TAIL);
  },

  "lua: aligning makes each workspace on its screen, then fills it"() {
    const script = HyprLua.alignScript([{ name: "eDP-1" }, { name: "DP-2" }],
                                       [{ key: "a", ws: 3 }, { key: "b", ws: 13 }, { key: "c", ws: 13 }], 2, "DP-2");
    const f = HyprLua.focusMonitor, s = HyprLua.focusSpace, m = HyprLua.moveWindow;
    assert.strictEqual(script, QUIET_HEAD
      + f("eDP-1") + s(3, true) + m("a", 3) + f("eDP-1") + s(2, true)
      + f("DP-2") + s(13, true) + m("b", 13) + f("DP-2") + m("c", 13) + f("DP-2") + s(12, true)
      + f("DP-2") + QUIET_TAIL);
  },

  "deco: every option in the batch has a say, defaults stand for nothing"() {
    assert.strictEqual(Deco.OPTIONS.length, 39);
    const none = Deco.parse("");
    assert.strictEqual(none.rounding, 0);
    assert.strictEqual(none.blurPasses, 1);
    assert.strictEqual(none.roundingPower, 2);
    assert.strictEqual(none.blurIgnoreOpacity, true);
    assert.strictEqual(none.shadowPower, 1);
    assert.strictEqual(none.glassBezel, Deco.DEFAULTS.glassBezel);
    assert.deepStrictEqual(Object.keys(none).sort(), Object.keys(Deco.DEFAULTS).sort());
  },

  "deco: what hyprctl really prints"() {
    // Captured from `hyprctl --batch "j/getoption ...; ..."`.
    const text = '{"option": "general:col.active_border", "gradient": "ffbdebee 0deg", "set": true }\n\n\n'
      + '{"option": "general:col.inactive_border", "gradient": "143a332a0deg", "set": true }\n\n\n'
      + '{"option": "decoration:shadow:offset", "vec2": [2,4], "set": true }\n\n\n'
      + '{"option": "decoration:shadow:enabled", "bool": true, "set": true }\n\n\n'
      + '{"option": "decoration:shadow:color", "gradient": "ee1a1a1a 0deg", "set": true }\n\n\n'
      + '{"option": "decoration:shadow:color_inactive", "gradient": "ffffffff 0deg", "set": false }\n\n\n'
      + '{"option": "plugin:liquidglass:enabled", "bool": false, "set": true }\n\n\n'
      + '{"option": "decoration:rounding", "int": 8, "set": true }\n\n\n'
      + 'no such option\n\n\n';
    const d = Deco.parse(text);
    assert.strictEqual(d.activeBorder, "#ffbdebee");
    assert.strictEqual(d.inactiveBorder, "#143a332a", "angle run straight on");
    assert.strictEqual(d.shadowOffsetX, 2);
    assert.strictEqual(d.shadowOffsetY, 4);
    assert.strictEqual(d.shadow, true);
    assert.strictEqual(d.shadowColorInactive, "#ee1a1a1a", "unset reads as the active colour");
    assert.strictEqual(d.rounding, 8);
    assert.strictEqual(d.glass, false);
    assert.strictEqual(d.glassBezel, 40, "plugin not loaded");
  },

  "deco: a set inactive shadow colour is read"() {
    const d = Deco.parse('{"option": "decoration:shadow:color_inactive", "color": "aa112233", "set": true }');
    assert.strictEqual(d.shadowColorInactive, "#aa112233");
  },

  "deco: the inactive shadow colour goes by `set`, not by what it says"() {
    const active = '{"option": "decoration:shadow:color", "color": "ee1a1a1a"}\n\n';
    const inactive = set => '{"option": "decoration:shadow:color_inactive", "color": "ffffffff"' + set + "}";
    const read = text => Deco.parse(text).shadowColorInactive;
    assert.strictEqual(read(active + inactive(', "set": false')), "#ee1a1a1a", "unset: the active colour");
    assert.strictEqual(read(active + inactive("")), "#ee1a1a1a", "no flag at all: unset");
    assert.strictEqual(read(active + inactive(', "set": true')), "#ffffffff", "set: even to what unset prints");
    assert.strictEqual(read(active), "#ee1a1a1a", "not reported: the active colour");
    assert.strictEqual(read(inactive(', "set": false')), "transparent", "unset, with no active colour");
  },

  "deco: glass needs both switches"() {
    const on = n => '{"option": "plugin:liquidglass:' + n + '", "bool": true}';
    assert.strictEqual(Deco.parse(on("enabled")).glass, false);
    assert.strictEqual(Deco.parse(on("enabled") + "\n\n" + on("windows")).glass, true);
  },

  "wire: every shape of event"() {
    assert.deepStrictEqual(Wire.parse("up-begin"), { what: "up-begin", who: "up", phase: "begin", rest: "", raw: 0, value: 0,
                                                     speed: 0, cancelled: false, velocity: 0 });
    const end = Wire.parse("allup-end:0.8000:1.5000:1:-3.2500");
    assert.strictEqual(end.who, "allup");
    assert.strictEqual(end.phase, "end");
    assert.strictEqual(end.raw, 0.8);
    assert.strictEqual(end.speed, 1.5);
    assert.strictEqual(end.cancelled, true);
    assert.strictEqual(end.velocity, -3.25);
    const side = Wire.parse("side-move:-0.4000");
    assert.strictEqual(side.raw, -0.4);
    assert.strictEqual(side.value, 0, "value is never below zero");
    const go = Wire.parse("go:next");
    assert.strictEqual(go.what, "go");
    assert.strictEqual(go.who, "");
    assert.strictEqual(go.rest, "next");
    assert.strictEqual(Wire.parse("shape:a=b c=d").rest, "a=b c=d");
    assert.strictEqual(Wire.parse("goto:a:b").rest, "a:b");
  },

  "wire: rubbish is harmless"() {
    for (const junk of ["", ":", "-", "::::", "up-move:abc:def", "é"]) {
      const w = Wire.parse(junk);
      assert.strictEqual(w.raw, 0, junk);
      assert.strictEqual(w.speed, 0, junk);
      assert.strictEqual(w.velocity, 0, junk);
    }
  },
};

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
