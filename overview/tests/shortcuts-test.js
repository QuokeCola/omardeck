"use strict";
// app/Shortcuts.js: reading and rewriting the `>>> aerial` section of bindings.lua.
// Strings and temp files only; nothing here opens a real bindings file. run.sh picks
// this file up by its name.
const assert = require("assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const vm = require("vm");

// `.pragma library` is QML, not JavaScript, so require() cannot load the file.
const source = fs.readFileSync(path.join(__dirname, "../app/Shortcuts.js"), "utf8");
const context = vm.createContext({});
vm.runInContext(source.replace(/^\.pragma library$/m, ""), context, { filename: "Shortcuts.js" });
const S = context;

const eq = (actual, expected) => assert.deepStrictEqual(JSON.parse(JSON.stringify(actual)), expected);
const count = (text, what) => text.split(what).length - 1;

const OVERVIEW = '"omarchy-shell shell toggle quokecola.omardeck"';
const USER_TOP = '-- mine\no.bind("SUPER + B", "Browser", "chromium")\n';
const USER_BOTTOM = '\n-- also mine, "quoted" and $& odd\no.bind("SUPER + M", "Music", "spotify")\n';

function fileWith(body) {
  return USER_TOP + "\n-- >>> aerial — any header text\n" + body + "\n-- <<< aerial\n" + USER_BOTTOM;
}

// The form a save with every combination taken over leaves on disk, under a header
// an earlier version wrote.
const ON_DISK = fileWith([
  'hl.unbind("SUPER + TAB")',
  'o.bind("SUPER + TAB", "Aerial: Overview", ' + OVERVIEW + ")",
  'hl.unbind("SUPER + CTRL + Left")',
  'o.bind("SUPER + CTRL + Left", "Aerial: Previous desktop", hl.dsp.event("aerial,go:prev"))',
].join("\n"));

const tests = {
  "frozen: markers, ids and descriptions, which a user's file depends on"() {
    assert.strictEqual(S.BEGIN, "-- >>> aerial");
    assert.strictEqual(S.END, "-- <<< aerial");
    eq(S.ACTIONS.map((a) => [a.id, a.description]), [
      ["overview", "Aerial: Overview"],
      ["prev", "Aerial: Previous desktop"],
      ["next", "Aerial: Next desktop"],
    ]);
  },

  "read: the section, ignoring its unbind lines"() {
    eq(S.read(ON_DISK), { overview: "SUPER + TAB", prev: "SUPER + CTRL + Left" });
  },

  "read: nothing without a whole section, or with the markers swapped"() {
    const line = 'o.bind("SUPER + A", "Aerial: Overview", ' + OVERVIEW + ")";
    eq(S.read(""), {});
    eq(S.read(USER_TOP), {});
    eq(S.read(line), {});
    eq(S.read("-- >>> aerial\n" + line + "\n"), {});
    eq(S.read(line + "\n-- <<< aerial\n"), {});
    eq(S.read("-- <<< aerial\n" + line + "\n-- >>> aerial\n"), {});
  },

  "read: an Aerial binding outside the section is not ours"() {
    const text = 'o.bind("SUPER + A", "Aerial: Overview", ' + OVERVIEW + ")\n"
      + fileWith('o.bind("SUPER + N", "Aerial: Next desktop", hl.dsp.event("aerial,go:next"))');
    eq(S.read(text), { next: "SUPER + N" });
  },

  "read: unknown and hand-edited lines in the section are skipped"() {
    eq(S.read(fileWith([
      '-- o.bind("SUPER + A", "Aerial: Overview", ' + OVERVIEW + ")",
      'o.bind("SUPER + Z", "Mine, not Aerial", "foot")',
      'o.bind("SUPER + Y", "Aerial: Something new", "foot")',
      "local anything = 1",
      "o.bind(combo, 'Aerial: Overview', x)",
      "not lua at all (",
      '   o.bind( "SUPER + N" ,  "Aerial: Next desktop", whatever)',
    ].join("\n"))), { next: "SUPER + N" });
  },

  "read: the last of two lines for one action wins"() {
    eq(S.read(fileWith([
      'o.bind("SUPER + A", "Aerial: Overview", x)',
      'o.bind("SUPER + B", "Aerial: Overview", x)',
    ].join("\n"))), { overview: "SUPER + B" });
  },

  "whitelist: a combination outside it never gets out of the file"() {
    for (const combo of [
      'SUPER + A") os.execute("x") o.bind("SUPER + B',
      "SUPER + A; rm -rf",
      "SUPER + (A)",
      "SUPER + A\\n",
      "SUPER + A-B",
      "SUPER + $A",
      "SÜPER + A",
    ]) {
      const text = fileWith('o.bind("' + combo + '", "Aerial: Overview", ' + OVERVIEW + ")");
      eq(S.read(text), {});
      assert.ok(!S.write(text, S.read(text)).includes(combo), combo);
    }
  },

  "whitelist: takes what Hyprland can be given, code: keys and bare mods included"() {
    for (const combo of ["SUPER + code:10", "SUPER + F12", "ALT + Prior", "A", "SUPER + mouse_down"]) {
      eq(S.read(fileWith('o.bind("' + combo + '", "Aerial: Overview", x)')), { overview: combo });
    }
  },

  "whitelist: every key the recorder can produce survives a save and a read"() {
    const keys = [];
    for (let k = 0x20; k <= 0x5d; k++) keys.push(k);
    for (let k = 0x01000000; k <= 0x01000061; k++) keys.push(k);
    let seen = 0;
    for (const key of keys) {
      const name = S.keyName(key);
      if (name === "") continue;
      seen++;
      for (let mask = 1; mask < 128; mask++) {
        if (mask & ~(64 | 4 | 8 | 1)) continue;
        const combo = S.format(mask, name);
        eq(S.read(S.write("", { next: combo })), { next: combo });
        eq(JSON.parse(JSON.stringify(S.parse(combo))), { mask, key: name });
      }
    }
    assert.ok(seen > 40, "only " + seen + " keys");
  },

  "write: replaces the section and nothing else"() {
    const out = S.write(ON_DISK, { overview: "SUPER + A" });
    assert.ok(out.startsWith(USER_TOP + "\n-- >>> aerial"));
    assert.ok(out.endsWith("-- <<< aerial\n" + USER_BOTTOM));
    eq(S.read(out), { overview: "SUPER + A" });
    assert.ok(!out.includes("SUPER + TAB"));
    assert.ok(out.includes('o.bind("SUPER + A", "Aerial: Overview", ' + OVERVIEW + ")"));
  },

  "write: only the marker is matched, so an old header is replaced"() {
    assert.ok(!S.write(ON_DISK, { overview: "SUPER + A" }).includes("any header text"));
  },

  "write: hand edits inside the section are overwritten"() {
    const out = S.write(fileWith([
      'o.bind("SUPER + A", "Aerial: Overview", "my-own-command")',
      'o.bind("SUPER + Z", "Mine, not Aerial", "foot")',
      "local anything = 1",
    ].join("\n")), { overview: "SUPER + A" });
    assert.ok(out.includes('"Aerial: Overview", ' + OVERVIEW));
    for (const gone of ["my-own-command", "SUPER + Z", "anything"]) assert.ok(!out.includes(gone), gone);
  },

  "write: adds a section at the end when there is none"() {
    const line = 'o.bind("SUPER + A", "Aerial: Overview", ' + OVERVIEW + ")\n-- <<< aerial\n";
    for (const text of ["-- mine", "-- mine\n", "-- mine\n\n\n"]) {
      const out = S.write(text, { overview: "SUPER + A" });
      assert.ok(out.startsWith("-- mine\n\n-- >>> aerial"), JSON.stringify(out));
      assert.ok(out.endsWith(line));
    }
    eq(S.read(S.write("", { overview: "SUPER + A" })), { overview: "SUPER + A" });
  },

  "write: an empty save removes the section, and adds none where there is none"() {
    assert.strictEqual(S.write(USER_TOP, {}), USER_TOP);
    assert.strictEqual(S.write(S.write(USER_TOP, { next: "SUPER + N" }), {}), USER_TOP);
    const out = S.write(ON_DISK, {});
    assert.ok(!out.includes("aerial"));
    assert.ok(out.startsWith(USER_TOP));
    assert.ok(out.endsWith(USER_BOTTOM));
    eq(S.read(out), {});
  },

  "write: ignores ids it does not know, and empty combinations"() {
    assert.strictEqual(S.write(USER_TOP, { nonsense: "SUPER + Q", prev: "" }), USER_TOP);
    assert.ok(!S.write(USER_TOP, { nonsense: "SUPER + Q", next: "SUPER + N" }).includes("SUPER + Q"));
  },

  "write: actions always come out in the same order"() {
    assert.strictEqual(
      S.section({ next: "SUPER + N", overview: "SUPER + A", prev: "SUPER + P" }),
      S.section({ overview: "SUPER + A", prev: "SUPER + P", next: "SUPER + N" }));
  },

  "write: every combination is unbound right before its own bind"() {
    const out = S.write(USER_TOP, { overview: "SUPER + A", next: "SUPER + N" });
    assert.strictEqual(count(out, "hl.unbind"), 2);
    assert.ok(out.includes('hl.unbind("SUPER + A")\no.bind("SUPER + A", "Aerial: Overview"'));
    assert.ok(out.includes('hl.unbind("SUPER + N")\no.bind("SUPER + N", "Aerial: Next desktop"'));
    // No combination, nothing to unbind.
    assert.strictEqual(count(S.write(USER_TOP, { next: "" }), "hl.unbind"), 0);
  },

  "write: saving twice changes nothing the second time"() {
    const shortcuts = { overview: "SUPER + TAB", prev: "SUPER + CTRL + Left", next: "SUPER + CTRL + Right" };
    for (const text of ["", "-- mine", USER_TOP, ON_DISK, fileWith("junk (")]) {
      const once = S.write(text, shortcuts);
      assert.strictEqual(S.write(once, shortcuts), once);
      assert.strictEqual(count(once, S.BEGIN), 1);
      assert.strictEqual(count(once, S.END), 1);
    }
    const empty = S.write(ON_DISK, {});
    assert.strictEqual(S.write(empty, {}), empty);
  },

  "write: reading it back gives the same shortcuts, and they can be saved again"() {
    const shortcuts = { overview: "SUPER + TAB", next: "SUPER + CTRL + Right" };
    const once = S.write(USER_TOP, shortcuts);
    eq(S.read(once), shortcuts);
    assert.strictEqual(S.write(once, S.read(once)), once);
  },

  // read() does not report unbind lines, and a save of an unchanged combination sees
  // no clash, so a save has to put them back by itself.
  "unbinds: re-saving keeps one for every combination, and adds the missing ones"() {
    const out = S.write(ON_DISK, S.read(ON_DISK));
    assert.strictEqual(count(ON_DISK, "hl.unbind"), 2);
    assert.strictEqual(count(out, "hl.unbind"), 2);
    assert.ok(out.includes('hl.unbind("SUPER + TAB")\no.bind("SUPER + TAB"'));
    assert.ok(out.includes('hl.unbind("SUPER + CTRL + Left")\no.bind("SUPER + CTRL + Left"'));
    const older = fileWith('o.bind("SUPER + N", "Aerial: Next desktop", hl.dsp.event("aerial,go:next"))');
    assert.ok(S.write(older, S.read(older)).includes('hl.unbind("SUPER + N")\no.bind("SUPER + N"'));
  },

  "unbinds: a changed combination leaves no unbind of the old one behind"() {
    const out = S.write(ON_DISK, { overview: "SUPER + A" });
    assert.strictEqual(count(out, "hl.unbind"), 1);
    assert.ok(!out.includes('hl.unbind("SUPER + TAB")'));
  },

  "malformed: refused, every shape, whatever is being saved"() {
    const bind = 'o.bind("SUPER + A", "Aerial: Overview", ' + OVERVIEW + ")\n";
    const shapes = {
      "no end": USER_TOP + "-- >>> aerial\n" + bind + USER_BOTTOM,
      "no begin": USER_TOP + bind + "-- <<< aerial\n" + USER_BOTTOM,
      "swapped": USER_TOP + "-- <<< aerial\n" + bind + "-- >>> aerial\n" + USER_BOTTOM,
      "two sections": fileWith(bind) + fileWith(bind),
      "two begins": USER_TOP + "-- >>> aerial\n-- >>> aerial\n" + bind + "-- <<< aerial\n",
      "two ends": USER_TOP + "-- >>> aerial\n" + bind + "-- <<< aerial\n-- <<< aerial\n",
      "a mention in a comment": '-- see "-- >>> aerial" below\n' + fileWith(bind),
      "words after the end": USER_TOP + "-- >>> aerial\n" + bind + "-- <<< aerial my words\n" + USER_BOTTOM,
    };
    for (const [name, text] of Object.entries(shapes)) {
      assert.strictEqual(S.write(text, { next: "SUPER + N" }), null, name);
      assert.strictEqual(S.write(text, {}), null, name + ", emptied");
      const said = S.problem(text);
      assert.ok(said.startsWith("Not saved:") && said.includes("Nothing was changed"), name + ": " + said);
      eq(S.read(text), {});
    }
  },

  "malformed: each shape is told apart"() {
    assert.ok(S.problem("-- >>> aerial\n").includes('with no "-- <<< aerial"'));
    assert.ok(S.problem("-- <<< aerial\n").includes('with no "-- >>> aerial"'));
    assert.ok(S.problem("-- <<< aerial\n-- >>> aerial\n").includes("wrong way round"));
    assert.ok(S.problem(fileWith("") + fileWith("")).includes("more than one"));
    assert.ok(S.problem("-- >>> aerial\n-- <<< aerial words\n").includes("on its line"));
  },

  "malformed: nothing to say about a whole section, or none"() {
    for (const text of ["", USER_TOP, ON_DISK, S.write(USER_TOP, { next: "SUPER + N" })]) {
      assert.strictEqual(S.problem(text), "");
      assert.notStrictEqual(S.write(text, { next: "SUPER + N" }), null);
    }
  },

  // The data loss this used to be: with the end marker gone the first save added a
  // section, and the second replaced everything from the orphan on, user's lines too.
  "malformed: a section with no end marker costs no lines, however many saves"() {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "shortcuts-test-"));
    try {
      const file = path.join(dir, "bindings.lua");
      const before = "-- >>> aerial\n-- user line after the broken section\n";
      fs.writeFileSync(file, before);
      for (let i = 0; i < 3; i++) {
        const out = S.write(fs.readFileSync(file, "utf8"), { next: "SUPER + N" });
        if (out !== null) fs.writeFileSync(file, out);
      }
      assert.strictEqual(fs.readFileSync(file, "utf8"), before);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  },

  "write: what is outside a whole section comes through byte for byte"() {
    for (const shortcuts of [{ next: "SUPER + N" }, {}]) {
      const out = S.write(ON_DISK, shortcuts);
      assert.ok(out.startsWith(USER_TOP));
      assert.ok(out.endsWith(USER_BOTTOM));
    }
    const sameLine = 'mine() -- >>> aerial\n-- <<< aerial\nmore()\n';
    const out = S.write(sameLine, { next: "SUPER + N" });
    assert.ok(out.startsWith("mine() -- >>> aerial"));
    assert.ok(out.endsWith("-- <<< aerial\nmore()\n"));
  },

  "conflicts: same key and mods, locks ignored, Aerial's own left out"() {
    const binds = [
      { modmask: 64, key: "TAB", description: "Next workspace", dispatcher: "__lua", arg: "" },
      { modmask: 64 | 2 | 16, key: "tab", description: "With locks", dispatcher: "__lua", arg: "" },
      { modmask: 64, key: "TAB", description: "Aerial: Overview", dispatcher: "__lua", arg: "" },
      { modmask: 64, key: "TAB", description: "", dispatcher: "__lua", arg: "" },
      { modmask: 64, key: "TAB", description: "", dispatcher: "exec", arg: "foot" },
      { modmask: 65, key: "TAB", description: "Other mods", dispatcher: "__lua", arg: "" },
      { modmask: 64, key: "TAB", description: "A mouse bind", mouse: true },
      { modmask: 64, key: "TAB", description: "A submap", submap: "resize" },
    ];
    eq(S.conflicts(binds, "SUPER + TAB").map((c) => c.description),
      ["Next workspace", "With locks", "an unnamed binding", "exec foot"]);
    eq(S.conflicts(binds, ""), []);
    eq(S.conflicts(binds, "SUPER +"), []);
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
