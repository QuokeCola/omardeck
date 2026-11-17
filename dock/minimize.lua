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
hl.layer_rule({
  match = { namespace = "^omarchy-dock-genie$" },
  blur = true,
  ignore_alpha = 0.1,
  no_anim = true,
})

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
    return add_button(button)
  end
  wrapped = true
end

wrap_buttons()
local stock_config = hl.config
hl.config = function(config)
  wrap_buttons()
  return stock_config(config)
end
