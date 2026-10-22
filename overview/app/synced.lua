-- SUPER + number with "All screens together" on: every screen to that
-- desktop at once.
--
-- Each screen owns a block of ten workspaces — the laptop's panel 1-10, the
-- others left to right 11-20, 21-30 — and desktop 3 is workspace 3, 13 and 23.
-- Omarchy's own bindings go to workspace 3 on the screen you are on, which on
-- an external screen is another screen's block. These replace them while the
-- setting is on; turning it off reloads the config, which puts back whatever
-- was bound before.
--
-- Loaded by the shell (see Screens.qml), again after every config reload,
-- which forgets these the same way it forgets the gestures.

local function screens()
  local list = {}
  for _, m in ipairs(hl.get_monitors()) do
    list[#list + 1] = m
  end
  table.sort(list, function(a, b)
    local al, bl = a.name:match("^eDP") ~= nil, b.name:match("^eDP") ~= nil
    if al ~= bl then
      return al
    end
    return a.x < b.x
  end)
  return list
end

-- Desktop n's workspace on the screen you are on.
local function here(n)
  for i, m in ipairs(screens()) do
    if m.focused then
      return n + 10 * (i - 1)
    end
  end
  return n
end

-- Every screen to desktop n, the one you are on last so it keeps focus.
-- Focusing each screen would drag the pointer across all of them; warps are
-- off for the trip.
local function switch(n)
  local warps = hl.get_config("cursor.no_warps")
  hl.config({ cursor = { no_warps = true } })
  local focused
  for i, m in ipairs(screens()) do
    if m.focused then
      focused = m.name
    end
    hl.dispatch(hl.dsp.focus({ monitor = m.name }))
    hl.dispatch(hl.dsp.focus({ workspace = tostring(n + 10 * (i - 1)), on_current_monitor = true }))
  end
  if focused then
    hl.dispatch(hl.dsp.focus({ monitor = focused }))
  end
  hl.config({ cursor = { no_warps = warps } })
end

for n = 1, 10 do
  local key = "code:" .. tostring(n + 9)
  hl.unbind("SUPER + " .. key)
  hl.unbind("SUPER + SHIFT + " .. key)
  hl.unbind("SUPER + SHIFT + ALT + " .. key)
  hl.bind("SUPER + " .. key, function()
    switch(n)
  end, { description = "Switch all screens to desktop " .. n })
  hl.bind("SUPER + SHIFT + " .. key, function()
    hl.dispatch(hl.dsp.window.move({ workspace = tostring(here(n)), follow = false }))
    switch(n)
  end, { description = "Move window to desktop " .. n })
  hl.bind("SUPER + SHIFT + ALT + " .. key, function()
    hl.dispatch(hl.dsp.window.move({ workspace = tostring(here(n)), follow = false }))
  end, { description = "Move window silently to desktop " .. n })
end

_G.__omardeck_synced = true
