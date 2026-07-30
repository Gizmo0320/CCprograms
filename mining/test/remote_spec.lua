--- Drives remote.lua's real event loop.
--
-- remote.lua is a single program with no seams, so it is tested the way it
-- actually runs: queue the events a user, a server and a turtle would generate,
-- let it process them, and inspect the rednet traffic it produced. That also
-- proves draw() survives every state it can be asked to render, which on a
-- pocket computer is the difference between a UI and a crash.

local out = {}
local function say(s)
  out[#out + 1] = tostring(s)
  local f = fs.open("/test-remote-results.txt", "w")
  for _, l in ipairs(out) do f.writeLine(l) end
  f.close()
end

local pass, fail = 0, 0
local function check(ok, label, extra)
  if ok then
    pass = pass + 1
    say("  ok   " .. label)
  else
    fail = fail + 1
    say("  FAIL " .. label .. (extra and ("  <" .. tostring(extra) .. ">") or ""))
  end
end

local loaded = {}
function _G.require(name)
  if loaded[name] then return loaded[name] end
  local path = "/" .. name:gsub("%.", "/") .. ".lua"
  local fn, err = loadfile(path)
  if not fn then error("cannot load " .. path .. ": " .. tostring(err), 0) end
  local m = fn()
  loaded[name] = m
  return m
end

local config = require("lib.config")
local specs  = require("lib.specs")

periphemu.create("back", "modem")

-- CraftOS-PC's emulated modem reports isWireless() == false and remote.lua
-- accepts wireless only. Present it as wireless for the duration rather than
-- loosening the program to suit the emulator. Restored at the end of the file:
-- every case below loads remote.lua again and would exit at the modem check.
local realCall = peripheral.call
peripheral.call = function(side, method, ...)
  if method == "isWireless" and peripheral.getType(side) == "modem" then return true end
  return realCall(side, method, ...)
end

-- There is no GPS cluster in an emulator, and the anchor button needs one.
local realLocate = gps.locate
local gpsFix = { x = 120, y = 64, z = -30 }
gps.locate = function()
  if not gpsFix then return nil end
  return gpsFix.x, gpsFix.y, gpsFix.z
end

-- Every case runs at pocket dimensions. The headless terminal is 51 wide, and
-- remote.lua lays buttons out relative to the screen width, so a click at
-- column 24 lands somewhere completely different on a 51 column terminal than
-- on the 26 column screen this program is actually for.
local POCKET_W, POCKET_H = 26, 20
local realSize = term.getSize
term.getSize = function() return POCKET_W, POCKET_H end

local realSend, realBroadcast = rednet.send, rednet.broadcast

--- Run remote.lua against a scripted set of events, capturing the wire.
local function runRemote(events)
  local sent = {}
  rednet.send = function(id, msg) sent[#sent + 1] = { to = id, msg = msg } return true end
  rednet.broadcast = function(msg) sent[#sent + 1] = { to = "broadcast", msg = msg } return true end

  for _, e in ipairs(events) do os.queueEvent(table.unpack(e)) end
  os.queueEvent("char", "q")

  local ok, err = pcall(dofile, "/remote.lua")
  rednet.send, rednet.broadcast = realSend, realBroadcast
  return sent, ok, err
end

local function find(sent, pred)
  for _, s in ipairs(sent) do
    if type(s.msg) == "table" and pred(s) then return s end
  end
end

local function statusOf(id, state)
  return { type = "status", id = id, label = "T" .. id, state = state or "idle",
           fuel = 5000, pos = { x = 1, y = -2, z = 3 }, facing = "S", gps = true,
           mined = 40, progress = 0.5, pattern = "quarry" }
end

local function fleetOf(...)
  local turtles = {}
  for _, id in ipairs({ ... }) do
    turtles[#turtles + 1] = { id = id, label = "T" .. id, state = "idle",
                              fuel = 5000, progress = 0.25 }
  end
  return { type = "fleet", id = 50, turtles = turtles,
           jobs = { { id = "J1", pattern = "quarry", state = "running",
                      turtle = turtles[1] and turtles[1].id, lane = 1, lanes = 2 },
                    { id = "J2", pattern = "quarry", state = "pending",
                      lane = 2, lanes = 2 } },
           counts = { pending = 1, running = 1 } }
end

--------------------------------------------------------------------------------
say("remote: discovers, and says which route it is on")
--------------------------------------------------------------------------------
do
  local sent, ok, err = runRemote({})
  check(ok, "it runs and exits cleanly", err)
  check(sent[1] and sent[1].to == "broadcast", "opening with a broadcast",
    sent[1] and sent[1].to)
  local asked = find(sent, function(s) return s.msg.type == "fleet?" end)
  check(asked ~= nil, "asking for a fleet server")
  local pinged = find(sent, function(s) return s.msg.type == "status" end)
  check(pinged ~= nil, "and for turtles directly, so either can answer first")
end

--------------------------------------------------------------------------------
say("remote: DIRECT mode commands turtles itself")
--------------------------------------------------------------------------------
do
  local sent, ok, err = runRemote({
    { "rednet_message", 7, statusOf(7, "mining"), config.protocol },
    { "rednet_message", 9, statusOf(9, "idle"), config.protocol },
    { "char", "p" },                     -- no selection: pause everyone
  })
  check(ok, "it runs", err)

  local p7 = find(sent, function(s) return s.msg.type == "pause" and s.to == 7 end)
  local p9 = find(sent, function(s) return s.msg.type == "pause" and s.to == 9 end)
  check(p7 ~= nil and p9 ~= nil, "with no server, pause reaches every turtle directly")
  check(find(sent, function(s) return s.msg.type == "command" end) == nil,
    "and nothing is addressed to a server that is not there")
end

--------------------------------------------------------------------------------
say("remote: selecting a turtle narrows the target")
--------------------------------------------------------------------------------
do
  -- Roster rows start at y=4 on the fleet screen (1 tabs, 2 rule, 3 header).
  local sent, ok, err = runRemote({
    { "rednet_message", 7, statusOf(7, "mining"), config.protocol },
    { "rednet_message", 9, statusOf(9, "idle"), config.protocol },
    { "mouse_click", 1, 3, 4 },          -- tap the first roster row (turtle 7)
    { "char", "c" },                     -- recall
  })
  check(ok, "it runs", err)
  check(find(sent, function(s) return s.msg.type == "return" and s.to == 7 end) ~= nil,
    "the selected turtle is recalled")
  check(find(sent, function(s) return s.msg.type == "return" and s.to == 9 end) == nil,
    "and the other one is left alone")
end

--------------------------------------------------------------------------------
say("remote: SERVER mode routes everything through the server")
--------------------------------------------------------------------------------
do
  local sent, ok, err = runRemote({
    { "rednet_message", 50, fleetOf(7, 9), config.protocol },
    { "char", "p" },
  })
  check(ok, "it runs", err)

  local cmd = find(sent, function(s) return s.msg.type == "command" end)
  check(cmd ~= nil, "a command message is sent")
  check(cmd and cmd.to == 50, "to the server", cmd and cmd.to)
  check(cmd and cmd.msg.action == "pause", "naming the action", cmd and cmd.msg.action)
  check(cmd and cmd.msg.target == "all", "and the target", cmd and cmd.msg.target)
  check(find(sent, function(s) return s.msg.type == "pause" and s.to ~= 50 end) == nil,
    "and no turtle is commanded behind the server's back")
end

--------------------------------------------------------------------------------
say("remote: submitting a split job")
--------------------------------------------------------------------------------
do
  -- Deploy screen rows: 1 tabs, 2 rule, 3 anchor, 4 mode, 5..7 quarry params,
  -- 8 lanes. x=15 is inside a value field.
  local sent, ok, err = runRemote({
    { "rednet_message", 50, fleetOf(7, 9), config.protocol },
    { "key", keys.tab },                 -- to DEPLOY
    { "mouse_click", 1, 24, 3 },         -- SET anchor
    { "mouse_click", 1, 15, 5 },         -- click Width
    { "char", "1" }, { "char", "6" },
    { "key", keys.enter },
    { "mouse_click", 1, 15, 8 },         -- click Lanes
    { "char", "2" },
    { "key", keys.enter },
    { "char", "s" },                     -- submit
  })
  check(ok, "it runs", err)

  local sub = find(sent, function(s) return s.msg.type == "submit" end)
  check(sub ~= nil, "a submit is sent")
  check(sub and sub.to == 50, "to the server", sub and sub.to)
  check(sub and sub.msg.pattern == "quarry", "naming the pattern")
  check(sub and sub.msg.params and sub.msg.params.w == 16,
    "with the typed width", sub and sub.msg.params and sub.msg.params.w)
  check(sub and sub.msg.lanes == 2, "and the typed lane count",
    sub and sub.msg.lanes)
  check(sub and sub.msg.anchor and sub.msg.anchor.x == 120,
    "and the anchor the SET button stamped",
    sub and sub.msg.anchor and sub.msg.anchor.x)

  -- The server's own splitter has to accept what the pocket sends, or the
  -- submit is rejected at the far end for reasons the user never sees.
  local fleet = require("lib.fleet")
  local jobs, why = fleet.split(sub.msg.anchor, sub.msg.pattern,
    sub.msg.params, sub.msg.lanes)
  check(jobs ~= nil and #jobs == 2, "which the server's splitter accepts", why)
end

--------------------------------------------------------------------------------
say("remote: refuses to submit a placed job with no anchor")
--------------------------------------------------------------------------------
do
  gpsFix = nil
  local sent, ok, err = runRemote({
    { "rednet_message", 50, fleetOf(7), config.protocol },
    { "key", keys.tab },
    { "mouse_click", 1, 24, 3 },         -- SET, but there is no fix
    { "char", "s" },
  })
  gpsFix = { x = 120, y = 64, z = -30 }
  check(ok, "it runs", err)
  check(find(sent, function(s) return s.msg.type == "submit" end) == nil,
    "nothing is submitted without an anchor")
end

--------------------------------------------------------------------------------
say("remote: cancelling from the queue screen")
--------------------------------------------------------------------------------
do
  local sent, ok, err = runRemote({
    { "rednet_message", 50, fleetOf(7, 9), config.protocol },
    { "key", keys.tab }, { "key", keys.tab },   -- to QUEUE
    -- 1 tabs, 2 rule, 3 counts, 4 first job row.
    { "mouse_click", 1, 3, 4 },
  })
  check(ok, "it runs", err)
  local cancel = find(sent, function(s) return s.msg.type == "cancel" end)
  check(cancel ~= nil, "a cancel is sent")
  check(cancel and cancel.msg.jobId == "J1", "for the job that was tapped",
    cancel and cancel.msg.jobId)

  -- And the row below it is the next job, so the list is in queue order rather
  -- than whatever order the table happened to iterate in.
  local sent2 = runRemote({
    { "rednet_message", 50, fleetOf(7, 9), config.protocol },
    { "key", keys.tab }, { "key", keys.tab },
    { "mouse_click", 1, 3, 5 },
  })
  local second = find(sent2, function(s) return s.msg.type == "cancel" end)
  check(second and second.msg.jobId == "J2", "the second row is the second job",
    second and second.msg.jobId)
end

--------------------------------------------------------------------------------
say("remote: the layout fits a pocket screen on every screen and pattern")
--------------------------------------------------------------------------------
do
  -- The pocket computer is 26x20 and every screen is a fixed column, so the
  -- widest pattern on the busiest screen decides whether the buttons survive.
  local W, H = POCKET_W, POCKET_H
  local realPos, realWrite = term.setCursorPos, term.write

  local lowest, overflow = 0, nil
  local cx, cy = 1, 1
  term.setCursorPos = function(x, y) cx, cy = x, y return realPos(x, y) end
  term.write = function(text)
    if cy > lowest then lowest = cy end
    -- A write starting at cx runs to cx + #text - 1; anything past W is clipped
    -- by the terminal and silently lost, which is how a line loses its tail.
    local right = cx + #tostring(text) - 1
    if right > W and not overflow then
      overflow = ("row %d ends at col %d: %q"):format(cy, right, tostring(text))
    end
    cx = right + 1
    return realWrite(text)
  end

  -- A full roster, so the fleet table is drawn at its tallest.
  local big = fleetOf(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)
  local events = { { "rednet_message", 50, big, config.protocol } }
  -- Visit every screen, and on DEPLOY every pattern.
  for _ = 1, 3 do
    events[#events + 1] = { "key", keys.tab }
    for _ = 1, #specs.order do
      events[#events + 1] = { "key", keys.right }
    end
  end

  local _, ok, err = runRemote(events)

  term.setCursorPos, term.write = realPos, realWrite

  check(ok, "it renders every screen and pattern without erroring", err)
  check(lowest <= H, "and never writes below row " .. H, lowest)
  check(not overflow, "and never writes past the right edge", overflow)

  local widest, widestName = 0, nil
  for _, name in ipairs(specs.order) do
    local n = #specs.get(name).params
    if n > widest then widest, widestName = n, name end
  end
  check(widest >= 5, "the widest pattern really does have 5+ params ("
    .. tostring(widestName) .. ")", widest)
end

--------------------------------------------------------------------------------
say("remote: q does not quit while a value is being typed")
--------------------------------------------------------------------------------
do
  local sent, ok, err = runRemote({
    { "rednet_message", 50, fleetOf(7), config.protocol },
    { "key", keys.tab },
    { "mouse_click", 1, 24, 3 },         -- anchor
    { "mouse_click", 1, 15, 5 },         -- edit Width
    { "char", "q" },                     -- must be swallowed by the editor
    { "char", "7" },
    { "key", keys.enter },
    { "char", "s" },                     -- and only now does anything happen
  })
  check(ok, "it runs to the end", err)

  -- Had 'q' reached the shortcut handler the program would have exited before
  -- the submit, so this is what proves the editor swallowed it.
  local sub = find(sent, function(s) return s.msg.type == "submit" end)
  check(sub ~= nil, "the submit after the edit still went out")
  check(sub and sub.msg.params.w == 7, "and 'q' was typed at, not acted on",
    sub and sub.msg.params.w)
end

peripheral.call = realCall
gps.locate = realLocate
term.getSize = realSize

say("")
say(("%d passed, %d failed"):format(pass, fail))
say("=== REMOTE TESTS DONE ===")
return fail
