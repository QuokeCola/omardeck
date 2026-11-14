// The Lua the overview hands Hyprland, in one place.
//
// All of it runs inside the compositor, and what goes into it comes from window
// classes, event payloads and monitor names, so anything that is not plainly an
// address, a monitor name or a workspace number is refused here: the statement
// comes back empty rather than quoted.

const ADDRESS = /^[0-9a-fA-F]+$/;
const MONITOR = /^[A-Za-z0-9_-]+$/;
const WORKSPACE = /^[0-9]+$/;

function address(value) {
  const key = String(value === undefined || value === null ? "" : value).replace(/^0x/, "");
  return ADDRESS.test(key) ? key : "";
}

/** `body` with pointer warps off, and put back as they were, in one go. */
function quiet(body) {
  return "local w = hl.get_config('cursor.no_warps'); hl.config({ cursor = { no_warps = true } }); "
       + body
       + "hl.config({ cursor = { no_warps = w } })";
}

function focusWindow(addr) {
  const key = address(addr);
  return key ? "hl.dispatch(hl.dsp.focus({ window = 'address:0x" + key + "' })); " : "";
}

function focusMonitor(name) {
  return MONITOR.test(String(name)) ? "hl.dispatch(hl.dsp.focus({ monitor = '" + name + "' })); " : "";
}

function focusSpace(ws, onCurrent) {
  if (!WORKSPACE.test(String(ws))) return "";
  return "hl.dispatch(hl.dsp.focus({ workspace = '" + ws + "'" + (onCurrent ? ", on_current_monitor = true" : "") + " })); ";
}

/** Without following it: moving a window takes the screen along by default. */
function moveWindow(addr, ws) {
  const key = address(addr);
  if (!key || !WORKSPACE.test(String(ws))) return "";
  return "hl.dispatch(hl.dsp.window.move({ window = 'address:0x" + key + "', workspace = '" + ws + "', follow = false })); ";
}

/**
 * Every screen to a desktop, in the order given (the one you are on last, so that
 * it keeps focus), and then, if asked, to a window on it.
 *
 * @param names   monitor names, in the order to visit them
 * @param spaceOf name to the workspace that desktop is there
 * @param addr    a window to focus at the end, or nothing
 */
function switchScript(names, spaceOf, addr) {
  let body = "";
  for (const name of names) {
    const focus = focusMonitor(name);
    if (focus) body += focus + focusSpace(spaceOf(name), true);
  }
  if (addr) body += focusWindow(addr);
  return quiet(body);
}

/**
 * The windows to their workspaces and every screen to `desk`, with the pointer
 * left where it is. A window can only be sent to a workspace on a screen that has
 * it: one not made yet is made wherever focus is, and an empty one is gone again
 * as soon as focus leaves it. So on each screen with windows coming, each of their
 * workspaces is made there and filled before moving on.
 *
 * @param order   monitors in block order, with `.name`
 * @param moves   [{key, ws}]
 * @param desk    the desktop every screen ends on
 * @param focused the monitor name to leave focus on
 */
function alignScript(order, moves, desk, focused) {
  let body = "";
  const into = {};
  for (const m of moves) (into[m.ws] = into[m.ws] || []).push(m.key);
  order.forEach((m, i) => {
    const focus = focusMonitor(m.name);
    if (!focus) return;
    body += focus;
    for (const ws in into) {
      if (!WORKSPACE.test(ws) || Math.floor((ws - 1) / 10) !== i) continue;
      body += focusSpace(ws, true);
      // Moving a window hands focus back to the screen it left.
      for (const key of into[ws]) body += moveWindow(key, ws) + focus;
    }
    body += focusSpace(desk + 10 * i, true);
  });
  body += focusMonitor(focused);
  return quiet(body);
}

if (typeof module !== "undefined") {
  module.exports = { address, quiet, focusWindow, focusMonitor, focusSpace, moveWindow, switchScript, alignScript };
}
