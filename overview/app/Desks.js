// Every screen as one desktop, as arithmetic.
//
// With "All screens together" on, each screen keeps a block of ten workspaces —
// the laptop's own panel 1-10, the others left to right 11-20, 21-30 — and a
// desktop is the same number in every block. synced.lua says the same in Lua.
//
// Pure functions over plain data, so they can be tested without a compositor.

/** The laptop's panel first, then the others left to right. Monitors as given. */
function orderMonitors(monitors) {
  return monitors.filter(m => !m.disabled).slice().sort((a, b) => {
    const al = /^eDP/.test(a.name), bl = /^eDP/.test(b.name);
    if (al !== bl) return al ? -1 : 1;
    return a.x - b.x;
  });
}

/** The same, as names. */
function screenOrder(monitors) {
  return orderMonitors(monitors).map(m => m.name);
}

/** The desktop a workspace id is, or the id itself when screens are apart. */
function deskOfId(id, synced) {
  return synced && id > 0 ? (id - 1) % 10 + 1 : id;
}

/** The workspace that is a desktop on the screen at `index` in the block order. */
function spaceOn(desk, index, synced) {
  if (!synced || desk <= 0) return desk;
  return desk + 10 * Math.max(0, index);
}

/** A screen, as something that survives a dock handing it another connector. */
function screenId(monitor) {
  return String(monitor.description || monitor.name);
}

/**
 * After a change of screens: where each window has to go so that it is on its
 * own desktop on the screen it is now on. A window folded away from a screen is
 * remembered, and goes back when that screen returns, as long as it is still
 * where it was folded to; one moved since has found a home of its own.
 *
 * @param monitors  `hyprctl -j monitors`
 * @param clients   `hyprctl -j clients`
 * @param folded    by address (no 0x): {screen, desk, ws}, as returned last time
 * @param lastOrder screens by screenId, as returned last time
 * @returns null with no screens, otherwise {order, moves, folded, lastOrder},
 *          where order is the monitors in block order, and moves [{key, ws}].
 */
function planFold(monitors, clients, folded, lastOrder) {
  const order = orderMonitors(monitors);
  if (order.length === 0) return null;
  const index = {};
  order.forEach((m, i) => { index[m.id] = i; });
  const byId = order.map(screenId);
  const kept = Object.assign({}, folded);
  const moves = [];

  for (const c of clients) {
    const ws = c.workspace ? c.workspace.id : 0;
    const key = String(c.address || "").replace(/^0x/, "");
    if (!(ws > 0) || !/^[0-9a-fA-F]+$/.test(key)) continue;
    const here = index[c.monitor];
    if (here === undefined) continue;
    const desk = (ws - 1) % 10 + 1;

    // Back to the screen it was folded away from, if that screen is back and
    // the window is still where it was folded to.
    const away = kept[key];
    if (away) {
      const home = byId.indexOf(away.screen);
      if (ws !== away.ws) {
        delete kept[key];
      } else if (home >= 0 && home !== here) {
        moves.push({ key: key, ws: away.desk + 10 * home });
        delete kept[key];
        continue;
      }
    }

    const want = desk + 10 * here;
    if (ws === want) continue;
    // Outside this screen's block: from a screen that is gone, remember which,
    // so it can go back.
    const from = lastOrder[Math.floor((ws - 1) / 10)];
    if (from && byId.indexOf(from) < 0) kept[key] = { screen: from, desk: desk, ws: want };
    moves.push({ key: key, ws: want });
  }

  // Forget windows that have closed.
  const alive = {};
  for (const c of clients) alive[String(c.address || "").replace(/^0x/, "")] = true;
  for (const key in kept) if (!alive[key]) delete kept[key];

  return { order: order, moves: moves, folded: kept, lastOrder: byId };
}

/**
 * What to do about the screens once windows are placed: the desktop every screen
 * should be on, from the laptop's, or with `lead` "focused" the screen in use's,
 * and whether any screen is not there yet. `order` as from planFold.
 */
function deskToShow(order, lead) {
  const laptop = order[0];
  const leader = lead === "focused" ? (order.find(m => m.focused) || laptop) : laptop;
  const shown = leader.activeWorkspace && leader.activeWorkspace.id > 0 ? leader.activeWorkspace.id : 1;
  const desk = Number.isInteger(shown) ? (shown - 1) % 10 + 1 : 1;
  const lagging = order.some((m, i) => !m.activeWorkspace || m.activeWorkspace.id !== desk + 10 * i);
  return { desk: desk, lagging: lagging, focused: order.find(m => m.focused) || laptop };
}

if (typeof module !== "undefined") {
  module.exports = { orderMonitors, screenOrder, deskOfId, spaceOn, screenId, planFold, deskToShow };
}
