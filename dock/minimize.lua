-- Omardeck's dock: minimize with the genie.
--
-- Points SUPER+M and the titlebar's minimize button at dock/bin/minimize, which
-- has the dock play a window into its icon before Omarchy's own command takes it
-- away. Load from ~/.config/hypr/looknfeel.lua, anywhere in it:
--
--   dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/quokecola.omardeck/dock/minimize.lua")
--
-- Without this the dock still restores with the genie; only minimizing is plain.

local config_home = os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")
local minimize = config_home .. "/omarchy/plugins/quokecola.omardeck/dock/bin/minimize"
local stock = "omarchy-hyprland-window-minimize"

o.rebind("SUPER + M", "Minimize window to the dock", minimize)

-- Omarchy adds the titlebar's buttons after the user's config, and again whenever
-- a workspace starts floating, so its calls are adjusted as it makes them. The
-- plugin's table is only there once the plugin is loaded: looked for on each
-- hl.config until it is. If Omarchy changes those calls, the plain button returns.
-- The picture that stands in for the window while it is poured (Genie.qml). Blurred
-- behind like a window, so a see-through one keeps its frost, and only where the
-- picture is: the rest of that surface is empty, and the blur follows the shape.
-- The picture wears the window's shadow, which is not to be blurred behind: it is
-- fainter than the 0.5 here, and a see-through window's own pixels are not.
hl.layer_rule({
  match = { namespace = "^omarchy-dock-genie$" },
  blur = true,
  ignore_alpha = 0.5,
  no_anim = true,
})

-- ── The titlebar's look ─────────────────────────────────────────────────────────
-- Omarchy's titlebar (the hyprbars plugin, set up in default/hypr/workspace-modes.lua)
-- comes with its title at the left in the terminal's type and three typed
-- characters for buttons. This has it read as a titlebar: the title in the
-- middle, a little smaller and heavier, and the bar of a window that is not in
-- use a shade back, in the theme's own colours.
--
-- The buttons are round, each a drawn icon on a faint disc the size Omarchy's
-- buttons are, and each eases into its own colour under the pointer: red to close, green to maximize, yellow to minimize,
-- as the theme has them. Omarchy's plugin cannot draw that, so its buttons are
-- left where they are, unseen, to take the clicks, and Omardeck's Hyprland plugin
-- draws them (glass/src/buttons.inc), from the second note written below. Without
-- that plugin (it is built on this machine, and may not have been) the buttons
-- are plain drawn icons instead: glass/glass-ctl leaves a mark when it loads, and
-- reloads Hyprland when that changes.
-- `omardeck_titlebar = false` before this file is loaded leaves Omarchy's as it is.
--
-- What is settled here is written down for the shell, which draws the same bar on
-- the overview's cards and cannot ask the plugin what its buttons are.
local restyle = rawget(_G, "omardeck_titlebar") ~= false
local runtime = os.getenv("XDG_RUNTIME_DIR")
local note = runtime and (runtime .. "/omardeck-titlebar.json") or nil
local buttons_note = runtime and (runtime .. "/omardeck-buttons.conf") or nil
local bar = { buttons = {} }

local ICONS = { ["×"] = "󰅖", ["□"] = "󰖯", ["−"] = "󰖰" }
-- The theme's colour for each, by name and then by its terminal colour.
local ROLES = { ["×"] = { "red", "color1" }, ["□"] = { "green", "color2" }, ["−"] = { "yellow", "color3" } }
-- As wide as the button's own square, the size Omarchy gives it.
local DOT = 20

local function exists(path)
  local file = io.open(path, "r")
  if file then file:close() end
  return file ~= nil
end
local cache = os.getenv("XDG_CACHE_HOME") or (os.getenv("HOME") .. "/.cache")
local round = restyle and exists(cache .. "/omardeck/plugin-ok")

local function theme_color(key)
  local file = io.open(os.getenv("HOME") .. "/.local/state/omarchy/current/theme/colors.toml", "r")
  if not file then return nil end
  local found
  for line in file:lines() do
    local k, v = line:match('^%s*([%w_]+)%s*=%s*"#(%x%x%x%x%x%x)"')
    if k == key then found = "rgb(" .. v .. ")" end
  end
  file:close()
  return found
end

-- Two "rgb(RRGGBB)" colours mixed: `share` of the first, the rest of the second.
local function mixed(a, b, share)
  local ar, ag, ab = tostring(a):match("^rgb%((%x%x)(%x%x)(%x%x)%)$")
  local br, bg, bb = tostring(b):match("^rgb%((%x%x)(%x%x)(%x%x)%)$")
  if not ar or not br then return a end
  local function mix(x, y) return math.floor(tonumber(x, 16) * share + tonumber(y, 16) * (1 - share) + 0.5) end
  return string.format("rgb(%02X%02X%02X)", mix(ar, br), mix(ag, bg), mix(ab, bb))
end

local function quoted(value)
  return '"' .. tostring(value):gsub('[\\"]', "\\%0") .. '"'
end

local function hex(color)
  return tostring(color or ""):match("^rgba?%((%x+)%)$") or ""
end

-- For the shell, and for the plugin that draws the round buttons.
local function write_note()
  if note then
    local buttons = {}
    for _, b in ipairs(bar.buttons) do
      buttons[#buttons + 1] = string.format('{"icon":%s,"fg":%s,"size":%d}', quoted(b.icon), quoted(b.fg or ""), tonumber(b.size) or 20)
    end
    local file = io.open(note, "w")
    if file then
      file:write(string.format('{"align":%s,"weight":%s,"size":%d,"inactive":%s,"shape":%s,"dot":%d,"rest":%s,"restInactive":%s,"glyphRest":%s,"buttons":[%s]}\n',
        quoted(bar.align or "left"), quoted(bar.weight or "normal"), tonumber(bar.size) or 12,
        quoted(bar.inactive or ""), quoted(round and "circle" or "icon"), DOT,
        quoted(bar.rest or ""), quoted(bar.rest_inactive or ""), quoted(bar.glyph_rest or ""), table.concat(buttons, ",")))
      file:close()
    end
  end
  if buttons_note then
    local file = io.open(buttons_note, "w")
    if file then
      local first = bar.buttons[1] or {}
      file:write(string.format("enabled=%d\ntag=%s\nbar_height=%s\npadding=%s\ngap=%s\nhit=%s\ndot=%d\ncount=%d\nrest=%s\nrest_inactive=%s\nglyph=%s\nglyph_rest=%s\nfont=%s\n",
        (round and #bar.buttons > 0) and 1 or 0, bar.tag or "", bar.height or 30, bar.padding or 10, bar.gap or 8,
        tonumber(first.size) or 20, DOT, #bar.buttons, hex(bar.rest), hex(bar.rest_inactive), hex(bar.glyph), hex(bar.glyph_rest), bar.font or "monospace"))
      for i, b in ipairs(bar.buttons) do
        file:write(string.format("color%d=%s\nicon%d=%s\n", i - 1, hex(b.color), i - 1, b.icon))
      end
      file:close()
    end
  end
end

-- Omarchy's own settings for the bar, as it makes them: adjusted on the way in.
local function style_bar(config)
  local bars = type(config) == "table" and type(config.plugin) == "table" and config.plugin.hyprbars
  if type(bars) ~= "table" or not bars.bar_height then return end
  if restyle then
    bars.bar_text_align = "center"
    bars.bar_text_size = 11
    bars.bar_text_weight = "medium"
    -- A shade back from the bar in use: the theme's window background, which
    -- Omarchy's bar is one step up from.
    local behind = theme_color("background")
    if behind and behind ~= bars.bar_color then bars.bar_color_inactive = behind end
    -- The buttons have no square of their own (see add_button below), on a bar in
    -- use or not: Omarchy's fill for the ones on a bar not in use is taken off.
    bars.inactive_button_color = "rgba(00000000)"
    -- Omarchy's plugin shades a button's own square under the pointer whatever
    -- colour it is given. Made round, that shade is a soft ring about the button
    -- rather than a box behind it.
    if round then bars.button_rounding = 10 end
  end
  local text = type(bars.col) == "table" and bars.col.text or nil
  bar = { buttons = {}, align = bars.bar_text_align, weight = bars.bar_text_weight,
          size = bars.bar_text_size, inactive = bars.bar_color_inactive,
          color = bars.bar_color, text = text,
          tag = bars.workspace_tag, height = bars.bar_height, padding = bars.bar_padding,
          gap = bars.bar_button_padding, font = bars.bar_text_font }
  if text and bars.bar_color then
    -- A button at rest: a little of the title's colour in the bar's own, less on
    -- a bar not in use. And the icon that shows on its colour: the bar's.
    bar.rest = mixed(text, bars.bar_color, 0.10)
    bar.rest_inactive = mixed(text, bars.bar_color_inactive or bars.bar_color, 0.06)
    bar.glyph = theme_color("background") or bars.bar_color
    -- The icon at rest: a step quieter than the title.
    bar.glyph_rest = mixed(text, bars.bar_color, 0.72)
  end
  write_note()
end

local wrapped = false
local function wrap_buttons()
  local bars = hl.plugin and hl.plugin.hyprbars
  if wrapped or type(bars) ~= "table" or type(bars.add_button) ~= "function" then
    return
  end
  local add_button = bars.add_button
  bars.add_button = function(button)
    if type(button) == "table" and type(button.action) == "string" then
      local from, to = button.action:find(stock, 1, true)
      if from == 1 then
        button.action = minimize .. button.action:sub(to + 1)
      end
    end
    if type(button) == "table" then
      local mine = { icon = button.icon, size = button.size, fg = button.fg_color }
      if restyle and ICONS[button.icon] then
        local role = ROLES[button.icon]
        mine.icon = ICONS[button.icon]
        mine.color = theme_color(role[1]) or theme_color(role[2]) or button.fg_color
        button.icon = mine.icon
        button.bg_color = "rgba(00000000)"
        if round then
          -- Unseen, and still where the clicks land.
          button.fg_color = "rgba(00000000)"
        elseif bar.text and bar.color then
          -- Drawn icons with nothing behind them, a step quieter than the title.
          button.fg_color = mixed(bar.text, bar.color, 0.72)
          mine.fg = button.fg_color
        end
      end
      bar.buttons[#bar.buttons + 1] = mine
      write_note()
    end
    return add_button(button)
  end
  wrapped = true
end

wrap_buttons()
local stock_config = hl.config
hl.config = function(config)
  wrap_buttons()
  style_bar(config)
  return stock_config(config)
end
