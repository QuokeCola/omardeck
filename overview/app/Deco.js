// How Hyprland dresses a window, read from `hyprctl getoption`.
//
// At the start of a swipe every card sits exactly on top of its window, so a card
// has to look like the window it stands in for, or the first frame of every swipe
// is a visible jump.

const DEFAULTS = {
  rounding: 0,
  border: 0,
  activeBorder: "transparent",
  inactiveBorder: "transparent",
  shadow: false,
  shadowRange: 0,
  shadowColor: "transparent",
  shadowColorInactive: "transparent",
  shadowOffsetX: 0,
  shadowOffsetY: 0,
  blur: false,
  blurSize: 8,
  blurPasses: 1,
  blurNoise: 0,
  blurContrast: 1,
  blurBrightness: 1,
  blurVibrancy: 0,
  blurVibrancyDarkness: 0,
  blurIgnoreOpacity: true,
  shadowPower: 1,
  roundingPower: 2,
  // The liquidglass Hyprland plugin's lens over the blur, when it is loaded.
  glass: false,
  glassBezel: 40,
  glassRefraction: 45,
  glassDispersion: 0.25,
  glassSpecular: 0.16,
  glassLightAngle: 225,
  glassBrightness: 1.04,
  glassSaturation: 1.15,
  // The titlebars Omarchy puts on floating workspaces' windows (hyprbars), when
  // that plugin is loaded. `barTag` is the window tag that gets one; "" is all.
  bars: false,
  barHeight: 0,
  barColor: "transparent",
  barText: "transparent",
  barTextSize: 12,
  barFont: "monospace",
  barPadding: 10,
  barButtonPadding: 8,
  barTitle: true,
  barTag: "",
};

const OPTIONS = [
  "decoration:rounding", "general:border_size",
  "general:col.active_border", "general:col.inactive_border",
  "decoration:shadow:enabled", "decoration:shadow:range",
  "decoration:shadow:color", "decoration:shadow:color_inactive",
  "decoration:blur:enabled", "decoration:blur:size", "decoration:blur:passes",
  "decoration:blur:noise", "decoration:blur:contrast", "decoration:blur:brightness",
  "decoration:blur:vibrancy", "decoration:blur:vibrancy_darkness",
  "decoration:blur:ignore_opacity",
  "decoration:shadow:render_power", "decoration:rounding_power",
  "decoration:shadow:offset",
  // Not there unless the plugin is loaded, which reads as no glass.
  "plugin:liquidglass:enabled", "plugin:liquidglass:windows",
  "plugin:liquidglass:bezel", "plugin:liquidglass:refraction",
  "plugin:liquidglass:dispersion", "plugin:liquidglass:specular",
  "plugin:liquidglass:light_angle", "plugin:liquidglass:brightness",
  "plugin:liquidglass:saturation",
  // Likewise: no plugin, no titlebars.
  "plugin:hyprbars:enabled", "plugin:hyprbars:bar_height",
  "plugin:hyprbars:bar_color", "plugin:hyprbars:col.text",
  "plugin:hyprbars:bar_text_size", "plugin:hyprbars:bar_text_font",
  "plugin:hyprbars:bar_padding", "plugin:hyprbars:bar_button_padding",
  "plugin:hyprbars:bar_title_enabled", "plugin:hyprbars:workspace_tag",
];

// Hyprland prints colours as AARRGGBB, which is what Qt reads after a "#". A
// gradient is a list of them and an angle; the first colour stands for it.
function colourOf(entry) {
  const raw = entry && (entry.gradient || entry.color || entry.str);
  // A gradient can come back with its angle run straight on, as in
  // "143a332a0deg": the colour is the first eight hex digits either way.
  const hex = /^\s*([0-9a-fA-F]{8})/.exec(String(raw || ""));
  return hex ? "#" + hex[1] : "transparent";
}

// A plugin's colours come back as one number, AARRGGBB.
function intColourOf(entry) {
  if (!entry || typeof entry.int !== "number") return colourOf(entry);
  return "#" + (entry.int >>> 0).toString(16).padStart(8, "0");
}

function vecOf(entry, i) {
  const v = entry && entry.vec2;
  return v && v.length > i ? Number(v[i]) || 0 : 0;
}

/** The answers to OPTIONS from one `hyprctl --batch`, as a decoration. */
function parse(text) {
  const byName = {};
  for (const chunk of String(text).split(/\n\s*\n/)) {
    try {
      const entry = JSON.parse(chunk);
      if (entry && entry.option) byName[entry.option] = entry;
    } catch (e) {}
  }
  const num = name => {
    const e = byName[name];
    return e ? Number(e.int !== undefined ? e.int : (e.float !== undefined ? e.float : 0)) : 0;
  };
  const shadowOn = byName["decoration:shadow:enabled"];
  const blurOn = byName["decoration:blur:enabled"];
  const ignoreOpacity = byName["decoration:blur:ignore_opacity"];
  const inactive = byName["decoration:shadow:color_inactive"];
  const on = name => { const e = byName[name]; return !!(e && (e.bool === true || e.int === 1)); };
  const or = (name, fallback) => byName[name] ? num(name) : fallback;
  return {
    rounding: Math.max(0, num("decoration:rounding")),
    border: Math.max(0, num("general:border_size")),
    activeBorder: colourOf(byName["general:col.active_border"]),
    inactiveBorder: colourOf(byName["general:col.inactive_border"]),
    shadow: !!(shadowOn && (shadowOn.bool === true || shadowOn.int === 1)),
    shadowRange: Math.max(0, num("decoration:shadow:range")),
    shadowColor: colourOf(byName["decoration:shadow:color"]),
    // Hyprland reports this one as ffffffff when it is unset, which means "same
    // as the active colour", so `set` says which to read.
    shadowColorInactive: colourOf(inactive && inactive.set ? inactive : byName["decoration:shadow:color"]),
    // Where Hyprland moves the shadow from under the window, in logical pixels:
    // a theme that drops it a little below has to be matched, or the shadow
    // jumps as the windows take back over.
    shadowOffsetX: vecOf(byName["decoration:shadow:offset"], 0),
    shadowOffsetY: vecOf(byName["decoration:shadow:offset"], 1),
    blur: !!(blurOn && (blurOn.bool === true || blurOn.int === 1)),
    blurSize: Math.max(0, num("decoration:blur:size")),
    blurPasses: Math.max(1, num("decoration:blur:passes")),
    blurNoise: num("decoration:blur:noise"),
    blurContrast: byName["decoration:blur:contrast"] ? num("decoration:blur:contrast") : 1,
    blurBrightness: byName["decoration:blur:brightness"] ? num("decoration:blur:brightness") : 1,
    blurVibrancy: num("decoration:blur:vibrancy"),
    blurVibrancyDarkness: num("decoration:blur:vibrancy_darkness"),
    // Whether the blur behind a see-through window is see-through too, or drawn
    // whole under it. Hyprland's default is whole.
    blurIgnoreOpacity: !ignoreOpacity || ignoreOpacity.bool === true || ignoreOpacity.int === 1,
    shadowPower: Math.max(1, Math.min(4, num("decoration:shadow:render_power") || 1)),
    roundingPower: byName["decoration:rounding_power"] ? num("decoration:rounding_power") : 2,
    glass: on("plugin:liquidglass:enabled") && on("plugin:liquidglass:windows"),
    glassBezel: or("plugin:liquidglass:bezel", 40),
    glassRefraction: or("plugin:liquidglass:refraction", 45),
    glassDispersion: or("plugin:liquidglass:dispersion", 0.25),
    glassSpecular: or("plugin:liquidglass:specular", 0.16),
    glassLightAngle: or("plugin:liquidglass:light_angle", 225),
    glassBrightness: or("plugin:liquidglass:brightness", 1.04),
    glassSaturation: or("plugin:liquidglass:saturation", 1.15),
    bars: on("plugin:hyprbars:enabled") && num("plugin:hyprbars:bar_height") > 0,
    barHeight: Math.max(0, num("plugin:hyprbars:bar_height")),
    barColor: intColourOf(byName["plugin:hyprbars:bar_color"]),
    barText: intColourOf(byName["plugin:hyprbars:col.text"]),
    barTextSize: or("plugin:hyprbars:bar_text_size", 12),
    barFont: (byName["plugin:hyprbars:bar_text_font"] || {}).str || "monospace",
    barPadding: or("plugin:hyprbars:bar_padding", 10),
    barButtonPadding: or("plugin:hyprbars:bar_button_padding", 8),
    // Hyprland's default is on; unset, it reads as that.
    barTitle: !byName["plugin:hyprbars:bar_title_enabled"] || on("plugin:hyprbars:bar_title_enabled"),
    barTag: (byName["plugin:hyprbars:workspace_tag"] || {}).str || "",
  };
}

if (typeof module !== "undefined") {
  module.exports = { DEFAULTS, OPTIONS, colourOf, intColourOf, vecOf, parse };
}
