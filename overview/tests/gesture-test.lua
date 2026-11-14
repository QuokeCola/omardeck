-- The Lua halves, against a pretend `hl`: what they register and what they say.
--
--   lua tests/gesture-test.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local app = here .. "/../app/"

local said, gestures, binds, unbinds, submaps, rules

local function fresh()
  said, gestures, binds, unbinds, submaps, rules = {}, {}, {}, {}, {}, {}
  for _, k in ipairs({ "__aerial_registered", "__aerial_h", "__aerial_layer", "__aerial_submap",
                       "__aerial_horizontal", "__omardeck_synced" }) do
    _G[k] = nil
  end
end

_G.hl = {
  dispatch = function(what) said[#said + 1] = what end,
  gesture = function(g) gestures[#gestures + 1] = g end,
  layer_rule = function(r) rules[#rules + 1] = r end,
  define_submap = function(name, fn) submaps[#submaps + 1] = name; fn() end,
  bind = function(key, what) binds[key] = what end,
  unbind = function(key) unbinds[#unbinds + 1] = key end,
  get_monitors = function()
    return { { name = "DP-1", x = 1600, focused = true }, { name = "eDP-1", x = 0, focused = false } }
  end,
  dsp = {
    event = function(s) return "event:" .. s end,
    submap = function(s) return "submap:" .. s end,
    no_op = function() return "noop" end,
    window = { move = function(t) return "move:" .. t.workspace end },
  },
}

local failed = 0
local function test(name, run)
  fresh()
  local ok, err = pcall(run)
  if ok then
    print("  ok   " .. name)
  else
    failed = failed + 1
    print("  FAIL " .. name .. "\n       " .. tostring(err))
  end
end

local function eq(a, b, what)
  if a ~= b then error((what or "") .. ": got " .. tostring(a) .. ", wanted " .. tostring(b), 2) end
end

local function find(fingers, direction)
  for _, g in ipairs(gestures) do
    if g.fingers == fingers and g.direction == direction and type(g.action) == "table" then return g.action end
  end
end

test("gesture.lua registers up and down, for three and four fingers", function()
  dofile(app .. "gesture.lua")
  eq(#gestures, 4, "gestures")
  for _, f in ipairs({ 3, 4 }) do
    for _, d in ipairs({ "up", "down" }) do
      assert(find(f, d), f .. " " .. d)
    end
  end
  eq(_G.__aerial_registered, true, "flag")
  eq(submaps[1], "aerial-record", "submap")
  eq(rules[1].match.namespace, "^omarchy-aerial$", "layer rule")
  eq(rules[2].match.namespace, "^omardeck-panel$", "layer rule")
end)

test("loading it again takes the old gestures off first, and adds rules once", function()
  dofile(app .. "gesture.lua")
  local before = #gestures
  dofile(app .. "gesture.lua")
  local unset = 0
  for i = before + 1, #gestures do
    if gestures[i].action == "unset" then unset = unset + 1 end
  end
  eq(unset, 4, "unset")
  eq(#gestures, before + 8, "gestures")
  eq(#rules, 2, "rules")
  eq(#submaps, 1, "submaps")
end)

test("a swipe says begin, progress and the lift, in the wire format", function()
  dofile(app .. "gesture.lua")
  local g = find(3, "up")
  g.start({ time_ms = 1000 })
  g.update({ delta = { x = 0, y = -50 }, time_ms = 1010 })
  g.update({ delta = { x = 0, y = -75 }, time_ms = 1020 })
  g.finish({ cancelled = false, time_ms = 1030 })
  eq(said[1], "event:aerial,up-begin", "begin")
  eq(said[2], "event:aerial,up-move:0.2000", "first move")
  eq(said[3], "event:aerial,up-move:0.5000", "learns the sign from the first move")
  eq(said[4]:match("^event:aerial,up%-end:0%.5000:[%d.]+:0:[%d.]+$") ~= nil, true, "end: " .. said[4])
  eq(#said, 4, "events")
end)

test("a cancelled lift says so; both spellings of the lift report", function()
  dofile(app .. "gesture.lua")
  local g = find(4, "down")
  eq(g["end"], g.finish, "end and finish")
  g.start({})
  g.finish({ cancelled = true })
  eq(said[2]:match("^event:aerial,alldown%-end:[%d.]+:[%d.]+:1:[%d.-]+$") ~= nil, true, "end: " .. said[2])
end)

test("a payload it cannot read leaves one note", function()
  dofile(app .. "gesture.lua")
  local g = find(3, "up")
  g.update({ nothing = 1 })
  g.update({ nothing = 1 })
  local notes = 0
  for _, s in ipairs(said) do
    if s:find("aerial,shape:", 1, true) then notes = notes + 1 end
  end
  eq(notes, 1, "notes")
end)

test("__aerial_horizontal is idempotent and can hand back", function()
  dofile(app .. "gesture.lua")
  local base = #gestures
  __aerial_horizontal("slide")
  eq(#gestures, base + 1, "registered")
  eq(_G.__aerial_h, "slide", "remembered")
  __aerial_horizontal("slide")
  eq(#gestures, base + 1, "not twice")
  __aerial_horizontal("none")
  eq(gestures[#gestures].action, "unset", "taken off")
  eq(_G.__aerial_h, nil, "forgotten")
  __aerial_horizontal("none")
  eq(#gestures, base + 2, "nothing to take off")
end)

test("side swipes say signed travel toward the next desktop", function()
  dofile(app .. "gesture.lua")
  __aerial_horizontal("slide")
  local g = gestures[#gestures].action
  g.start({})
  g.update({ delta = { x = -55, y = 0 } })
  eq(said[2], "event:aerial,side-move:0.1000", "left is next")
  g.update({ delta = { x = 110, y = 0 } })
  eq(said[3], "event:aerial,side-move:-0.1000", "right is previous")
end)

test("synced.lua binds every number and sets its flag", function()
  dofile(app .. "synced.lua")
  eq(_G.__omardeck_synced, true, "flag")
  for n = 1, 10 do
    local key = "code:" .. tostring(n + 9)
    assert(binds["SUPER + " .. key], "SUPER " .. n)
    assert(binds["SUPER + SHIFT + " .. key], "SHIFT " .. n)
    assert(binds["SUPER + SHIFT + ALT + " .. key], "ALT " .. n)
  end
  eq(#unbinds, 30, "the old ones off first")
  binds["SUPER + code:12"]()
  eq(said[1], "event:aerial,desk:3", "says the desktop")
  said = {}
  -- The focused screen is the second in block order: desktop 3 there is 13.
  binds["SUPER + SHIFT + ALT + code:12"]()
  eq(said[1], "move:13", "the block of the focused screen")
end)

test("gesture.lua applies the saved shortcuts again, over whatever took those keys", function()
  local real_open = io.open
  local section = '-- >>> aerial\nhl.unbind("SUPER + TAB")\no.bind("SUPER + TAB", "Overview", "toggle")\n-- <<< aerial\no.bind("SUPER + X", "Mine", "x")\n'
  io.open = function(path, mode)
    if tostring(path):match("/hypr/bindings%.lua$") then
      return { read = function() return section end, close = function() end }
    end
    return real_open(path, mode)
  end
  local bound = {}
  _G.o = { bind = function(key, _, what) bound[key] = what end }
  local ok, err = pcall(dofile, app .. "gesture.lua")
  io.open, _G.o = real_open, nil
  if not ok then error(err) end
  eq(bound["SUPER + TAB"], "toggle", "section key")
  eq(bound["SUPER + X"], nil, "line outside the section")
end)

test("gesture.lua leaves the keys alone when the section is broken", function()
  local real_open = io.open
  io.open = function(path, mode)
    if tostring(path):match("/hypr/bindings%.lua$") then
      return { read = function() return '-- >>> aerial\no.bind("SUPER + TAB", "x", "y")\n' end, close = function() end }
    end
    return real_open(path, mode)
  end
  local bound = 0
  _G.o = { bind = function() bound = bound + 1 end }
  local ok, err = pcall(dofile, app .. "gesture.lua")
  io.open, _G.o = real_open, nil
  if not ok then error(err) end
  eq(bound, 0, "binds")
end)

test("gesture.lua registers the gestures even when the shortcuts section raises", function()
  local real_open = io.open
  io.open = function(path, mode)
    if tostring(path):match("/hypr/bindings%.lua$") then
      return { read = function() return '-- >>> aerial\nerror("boom")\n-- <<< aerial\n' end, close = function() end }
    end
    return real_open(path, mode)
  end
  local ok, err = pcall(dofile, app .. "gesture.lua")
  io.open = real_open
  if not ok then error(err) end
  eq(#gestures, 4, "gestures")
end)

print(failed > 0 and (failed .. " failing") or "all passing")
os.exit(failed > 0 and 1 or 0)
