// What the Lua half says, one event at a time (see gesture.lua):
//
//   go:next   desk:3   app:<id>   goto:<address>   shape:<fields>
//   up-begin   up-move:<progress>   up-end:<progress>:<speed>:<cancelled>:<velocity>
//
// and "up" may be "down", "allup", "alldown" or "side".

/**
 * @returns {what, who, phase, rest, raw, value, speed, cancelled, velocity}.
 *          `what` is the word before the first colon and `rest` all that follows;
 *          `who` and `phase` split a word like "up-move", and are "" for a word
 *          that is not one. `raw` is the progress as sent, signed; `value` the same
 *          no less than 0; `speed` travel per ms; `velocity` progress per second.
 *          A missing or unreadable number is 0.
 */
function parse(data) {
  const cut = data.indexOf(":");
  const what = cut < 0 ? data : data.slice(0, cut);
  const rest = cut < 0 ? "" : data.slice(cut + 1);
  const parts = rest.split(":");
  const raw = parseFloat(parts[0]) || 0;
  const dash = what.lastIndexOf("-");
  return {
    what: what,
    who: dash < 0 ? "" : what.slice(0, dash),
    phase: dash < 0 ? "" : what.slice(dash + 1),
    rest: rest,
    raw: raw,
    value: Math.max(0, raw),
    speed: parseFloat(parts[1]) || 0,
    cancelled: parts[2] === "1",
    velocity: parseFloat(parts[3]) || 0,
  };
}

if (typeof module !== "undefined") {
  module.exports = { parse };
}
