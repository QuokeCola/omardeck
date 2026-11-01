-- SUPER + number with "All screens together" on: every screen to that
-- desktop at once, sliding there the way SUPER + CTRL + arrows do. The slide
-- is the overview's: the key sends it hl.dsp.event("aerial,desk:<n>"), and
-- where it cannot slide it switches every screen straight there instead
-- (`switchDesk` in Overlay.qml).
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

for n = 1, 10 do
  local key = "code:" .. tostring(n + 9)
  hl.unbind("SUPER + " .. key)
  hl.unbind("SUPER + SHIFT + " .. key)
  hl.unbind("SUPER + SHIFT + ALT + " .. key)
  hl.bind("SUPER + " .. key, function()
    hl.dispatch(hl.dsp.event("aerial,desk:" .. n))
  end, { description = "Switch all screens to desktop " .. n })
  hl.bind("SUPER + SHIFT + " .. key, function()
    hl.dispatch(hl.dsp.window.move({ workspace = tostring(here(n)), follow = false }))
    hl.dispatch(hl.dsp.event("aerial,desk:" .. n))
  end, { description = "Move window to desktop " .. n })
  hl.bind("SUPER + SHIFT + ALT + " .. key, function()
    hl.dispatch(hl.dsp.window.move({ workspace = tostring(here(n)), follow = false }))
  end, { description = "Move window silently to desktop " .. n })
end

_G.__omardeck_synced = true
