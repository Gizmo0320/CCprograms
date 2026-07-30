--- Drives server.lua's real loops.
--
-- lib/fleet is tested on its own; this is about the wiring around it. It runs
-- the actual program with queued rednet events and inspects what it puts on the
-- wire: that a heartbeat leads to a dispatch, that the same job is not sent
-- twice, and that a turtle going idle puts its job back.

local out = {}
local function say(s)
  out[#out + 1] = tostring(s)
  local f = fs.open("/test-server-results.txt", "w")
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

periphemu.create("back", "modem")

-- CraftOS-PC's emulated modem reports isWireless() == false and the server
-- accepts wireless only. Present it as wireless rather than loosening the
-- program to suit the emulator.
local realCall = peripheral.call
peripheral.call = function(side, method, ...)
  if method == "isWireless" and peripheral.getType(side) == "modem" then return true end
  return realCall(side, method, ...)
end

-- The programs now talk through lib/net (raw modem channels), so that is what
-- the harness stands in for. Loading it here gives the same module table
-- server.lua will require, so replacing its functions replaces the transport.
local net = require("lib.net")
local realSend, realBroadcast, realReceive = net.send, net.broadcast, net.receive
local realOpen = net.open

--- Run server.lua against a scripted conversation.
--
-- The server's listener blocks in rednet.receive, so rather than queueing
-- events we replace it with a script: each entry is a message the server should
-- believe it received, and when the script runs out we stop the program by
-- making every loop's `running` check fail -- which is what returning from
-- listenerTask does, since it is inside parallel.waitForAny.
--- Run server.lua against a scripted conversation.
--
-- `probeAnswer` is an existing server replying to the startup check. Without
-- one the probe is left to time out, which is what a lone server sees.
--
-- The probe window has to be modelled rather than ignored. The server spends
-- its first two seconds asking "is anyone already serving this fleet?", calling
-- receive in a loop; a stub that answered instantly from the script would feed
-- the whole conversation to the probe and leave the listener with nothing.
local function runServer(script, probeAnswer)
  local sent, broadcasts = {}, {}
  local step = 0
  local probeUntil = os.clock() + 2.05

  net.open = function()
    net.channel = config.channel
    net.id = os.getComputerID()
    return "back"
  end
  net.send = function(id, msg) sent[#sent + 1] = { to = id, msg = msg } return true end
  net.broadcast = function(msg) broadcasts[#broadcasts + 1] = msg return true end
  net.receive = function(timeout)
    if os.clock() < probeUntil then
      if probeAnswer then
        local answer = probeAnswer
        probeAnswer = nil
        return answer.from, answer.msg
      end
      os.sleep(timeout or 0.25)         -- real sleep: let the probe time out
      return nil
    end

    step = step + 1
    local entry = script[step]
    if not entry then
      -- Nothing left to say: unwind out of the program.
      error("__done__", 0)
    end
    if entry.wait then os.sleep(entry.wait) end
    return entry.from, entry.msg
  end

  fs.delete(config.fleetFile)
  local ok, err = pcall(dofile, "/server.lua")
  net.send, net.broadcast, net.receive, net.open =
    realSend, realBroadcast, realReceive, realOpen

  if not ok and not tostring(err):find("__done__") then
    return sent, broadcasts, tostring(err)
  end
  return sent, broadcasts, nil
end

local function statusOf(id, state, jobId)
  return {
    type = "status", id = id, label = "T" .. id, state = state,
    fuel = 100000, pos = { x = 0, y = 64, z = 0 }, gps = true,
    mined = 0, progress = 0, jobId = jobId,
  }
end

local function find(sent, pred)
  for _, s in ipairs(sent) do
    if type(s.msg) == "table" and pred(s) then return s end
  end
end

local function countOf(sent, pred)
  local n = 0
  for _, s in ipairs(sent) do
    if type(s.msg) == "table" and pred(s) then n = n + 1 end
  end
  return n
end

--------------------------------------------------------------------------------
say("server: refuses to start if another server owns the fleet")
--------------------------------------------------------------------------------
do
  -- rednet.host errors when a hostname is taken. Two servers on one fleet would
  -- both dispatch to the same turtles and nothing would look broken until two
  -- of them turned up in the same lane, so this has to be a hard stop.
  -- Startup broadcasts "server?" and waits. An existing server answers
  -- "server!", and that answer is what makes this one stand down.
  local sent, _, err = runServer({
    { from = 7, msg = statusOf(7, "idle") },
    { from = 99, msg = { type = "submit", pattern = "quarry",
        params = { w = 8, d = 8, h = 4 }, anchor = { x = 0, y = 64, z = 0 },
        lanes = 1 } },
  }, { from = 42, msg = { type = "server!", id = 42 } })

  check(err == nil, "it exits cleanly rather than crashing", err)
  check(countOf(sent, function(s2) return s2.msg.type == "start" end) == 0,
    "and dispatches nothing", #sent)
  check(find(sent, function(s2) return s2.msg.type == "ack" end) == nil,
    "and acks nothing -- it never got as far as listening")
end

--------------------------------------------------------------------------------
say("server: accepts a submit and dispatches it to an idle turtle")
--------------------------------------------------------------------------------
do
  local sent, broadcasts, err = runServer({
    { from = 7, msg = statusOf(7, "idle") },
    { from = 99, msg = { type = "submit", pattern = "quarry",
        params = { w = 8, d = 8, h = 4 }, anchor = { x = 10, y = 64, z = 10 },
        lanes = 1 } },
    { wait = 1.2, from = 7, msg = statusOf(7, "idle") },
    { wait = 1.2, from = 7, msg = statusOf(7, "idle") },
  })
  check(err == nil, "the server runs", err)

  local ack = find(sent, function(s) return s.msg.type == "ack" and s.msg.of == "submit" end)
  check(ack ~= nil, "the submit is acked")
  check(ack and ack.to == 99, "to the pocket that sent it", ack and ack.to)
  check(ack and type(ack.msg.jobs) == "table" and #ack.msg.jobs == 1,
    "naming the job it created")

  local start = find(sent, function(s) return s.msg.type == "start" end)
  check(start ~= nil, "a start reaches a turtle")
  check(start and start.to == 7, "the idle one", start and start.to)
  check(start and start.msg.pattern == "quarry", "with the pattern")
  check(start and start.msg.w == 8 and start.msg.h == 4, "and the parameters",
    start and start.msg.w)
  check(start and type(start.msg.origin) == "table", "and a world origin")
  check(start and start.msg.jobId ~= nil, "and a job id to report back")

  -- The turtle's own validator has to accept what the server sends, or the
  -- dispatch is silently rejected at the far end.
  local specs = require("lib.specs")
  local params, why = specs.readParams(specs.get("quarry"), start and start.msg or {})
  check(params ~= nil, "which the turtle's validator accepts", why)

  check(#broadcasts > 0, "and it broadcasts a fleet summary")
  local f = broadcasts[#broadcasts]
  check(f and f.type == "fleet", "of the right type", f and f.type)
end

--------------------------------------------------------------------------------
say("server: does not dispatch the same job twice")
--------------------------------------------------------------------------------
do
  local sent, _, err = runServer({
    { from = 7, msg = statusOf(7, "idle") },
    { from = 99, msg = { type = "submit", pattern = "quarry",
        params = { w = 4, d = 4, h = 2 }, anchor = { x = 0, y = 64, z = 0 },
        lanes = 1 } },
    -- Several more idle heartbeats: the turtle has taken the job but has not
    -- started reporting it yet, which is the window a naive dispatcher would
    -- use to send the same work again.
    { wait = 1.2, from = 7, msg = statusOf(7, "idle") },
    { wait = 1.2, from = 7, msg = statusOf(7, "idle") },
    { wait = 1.2, from = 7, msg = statusOf(7, "idle") },
  })
  check(err == nil, "the server runs", err)
  local starts = countOf(sent, function(s) return s.msg.type == "start" end)
  check(starts == 1, "exactly one start is sent", starts)
end

--------------------------------------------------------------------------------
say("server: splits a submit into lanes, one dispatch each")
--------------------------------------------------------------------------------
do
  local sent, _, err = runServer({
    { from = 7, msg = statusOf(7, "idle") },
    { from = 9, msg = statusOf(9, "idle") },
    { from = 99, msg = { type = "submit", pattern = "quarry",
        params = { w = 16, d = 8, h = 4 }, anchor = { x = 0, y = 64, z = 0 },
        lanes = 2 } },
    { wait = 1.2, from = 7, msg = statusOf(7, "mining", "J1") },
    { wait = 1.2, from = 9, msg = statusOf(9, "idle") },
    { wait = 1.2, from = 9, msg = statusOf(9, "idle") },
  })
  check(err == nil, "the server runs", err)

  local starts = {}
  for _, s in ipairs(sent) do
    if type(s.msg) == "table" and s.msg.type == "start" then starts[#starts + 1] = s end
  end
  check(#starts == 2, "two lanes go to two turtles", #starts)

  if #starts == 2 then
    check(starts[1].to ~= starts[2].to, "different turtles",
      starts[1].to .. "/" .. starts[2].to)
    check(starts[1].msg.w + starts[2].msg.w == 16, "widths add back up to the whole",
      starts[1].msg.w .. "+" .. starts[2].msg.w)
    check(starts[1].msg.origin.x ~= starts[2].msg.origin.x,
      "at different origins", starts[1].msg.origin.x)
  end
end

--------------------------------------------------------------------------------
say("server: a turtle that goes idle mid-job gets it dispatched again")
--------------------------------------------------------------------------------
do
  -- The real grace is several seconds, which would mean sleeping that long in
  -- the test. The suite shares the cached config table with the program, so
  -- shorten it rather than pad the script out with waits.
  local realGrace = config.dispatchGrace
  config.dispatchGrace = 0.5

  local sent, _, err = runServer({
    { from = 7, msg = statusOf(7, "idle") },
    { from = 99, msg = { type = "submit", pattern = "quarry",
        params = { w = 4, d = 4, h = 2 }, anchor = { x = 0, y = 64, z = 0 },
        lanes = 1 } },
    { wait = 1.2, from = 7, msg = statusOf(7, "mining", "J1") },
    -- Rebooted: idle again, no jobId. The work never finished.
    { wait = 1.2, from = 7, msg = statusOf(7, "idle") },
    { wait = 1.2, from = 7, msg = statusOf(7, "idle") },
    { wait = 1.2, from = 7, msg = statusOf(7, "idle") },
  })
  config.dispatchGrace = realGrace

  check(err == nil, "the server runs", err)
  local starts = countOf(sent, function(s) return s.msg.type == "start" end)
  check(starts >= 2, "the job is handed out again", starts)
end

--------------------------------------------------------------------------------
say("server: a scout's ore report becomes harvest jobs for miners")
--------------------------------------------------------------------------------
do
  local function scoutStatus(id, state)
    local s = statusOf(id, state)
    s.role = "scout"
    return s
  end

  local oreReport = {
    type = "ore", id = 9,
    blocks = 14, scans = 5,
    clusters = {
      { x = 100, y = 30, z = 40, count = 9, name = "minecraft:diamond_ore" },
      { x = 160, y = 30, z = 40, count = 5, name = "minecraft:iron_ore" },
    },
  }

  local sent, broadcasts, err = runServer({
    { from = 7, msg = statusOf(7, "idle") },          -- a miner
    { from = 9, msg = scoutStatus(9, "idle") },       -- and the scout
    { from = 9, msg = oreReport },
    -- The same seams again from an overlapping scan sphere.
    { wait = 1.2, from = 9, msg = oreReport },
    { wait = 1.2, from = 7, msg = statusOf(7, "mining", "J1") },
    { wait = 1.2, from = 7, msg = statusOf(7, "mining", "J1") },
  })
  check(err == nil, "the server runs", err)

  local starts = {}
  for _, s in ipairs(sent) do
    if type(s.msg) == "table" and s.msg.type == "start" then starts[#starts + 1] = s end
  end
  check(#starts >= 1, "a harvest is dispatched", #starts)
  check(starts[1] and starts[1].msg.pattern == "harvest", "of the harvest pattern",
    starts[1] and starts[1].msg.pattern)
  check(starts[1] and starts[1].to == 7, "to the miner, not the scout that found it",
    starts[1] and starts[1].to)
  check(starts[1] and starts[1].msg.origin
    and starts[1].msg.origin.x == 100, "at the seam",
    starts[1] and starts[1].msg.origin and starts[1].msg.origin.x)

  -- The scout reported the same two seams twice. Overlapping scan spheres do
  -- that constantly, and four jobs would mean two turtles sent to each hole.
  local last = broadcasts[#broadcasts]
  local harvests = 0
  for _, job in ipairs(last and last.jobs or {}) do
    if job.pattern == "harvest" then harvests = harvests + 1 end
  end
  check(harvests == 2, "the repeat report does not queue the seams again", harvests)

  -- Nothing is ever sent to the scout, which has no pickaxe.
  check(countOf(sent, function(s) return s.msg.type == "start" and s.to == 9 end) == 0,
    "and the scout is never asked to mine")
end

--------------------------------------------------------------------------------
say("server: dispatches a survey to a scout and a quarry to a miner")
--------------------------------------------------------------------------------
do
  local scout = statusOf(9, "idle"); scout.role = "scout"

  local sent, _, err = runServer({
    { from = 7, msg = statusOf(7, "idle") },
    { from = 9, msg = scout },
    { from = 99, msg = { type = "submit", pattern = "survey",
        params = { depth = 32, radius = 8, step = 6 },
        anchor = { x = 0, y = 64, z = 0 }, lanes = 1 } },
    { wait = 1.2, from = 7, msg = statusOf(7, "idle") },
    { wait = 1.2, from = 9, msg = statusOf(9, "idle") },
  })
  check(err == nil, "the server runs", err)

  local start = find(sent, function(s) return s.msg.type == "start" end)
  check(start ~= nil, "the survey is dispatched")
  check(start and start.to == 9, "to the scout", start and start.to)
  check(start and start.msg.pattern == "survey", "as a survey",
    start and start.msg.pattern)
end

--------------------------------------------------------------------------------
say("server: relays commands and rejects nonsense")
--------------------------------------------------------------------------------
do
  local sent, _, err = runServer({
    { from = 7, msg = statusOf(7, "mining", "J1") },
    { from = 9, msg = statusOf(9, "mining", "J2") },
    { from = 99, msg = { type = "command", target = "all", action = "pause" } },
    { from = 99, msg = { type = "command", target = 7, action = "return" } },
    { from = 99, msg = { type = "command", target = 7, action = "explode" } },
    { from = 99, msg = { type = "command", target = 4242, action = "pause" } },
    { wait = 0.2, from = 7, msg = statusOf(7, "mining", "J1") },
  })
  check(err == nil, "the server runs", err)

  local paused = countOf(sent, function(s) return s.msg.type == "pause" end)
  check(paused == 2, "'all' reaches every turtle", paused)
  check(find(sent, function(s) return s.msg.type == "return" and s.to == 7 end) ~= nil,
    "a targeted command reaches just that turtle")

  local errors = countOf(sent, function(s) return s.msg.type == "error" end)
  check(errors == 2, "an unknown action and an unknown turtle are both refused",
    errors)
end

--------------------------------------------------------------------------------
say("server: relays a fleet-wide update, carrying branch and repo")
--------------------------------------------------------------------------------
do
  local sent, _, err = runServer({
    { from = 7, msg = statusOf(7, "idle") },
    { from = 9, msg = statusOf(9, "idle") },
    { from = 99, msg = { type = "command", target = "all", action = "update" } },
    { from = 99, msg = { type = "command", target = 7, action = "update",
                         branch = "testing", repo = "someone/fork" } },
    { wait = 0.2, from = 7, msg = statusOf(7, "idle") },
  })
  check(err == nil, "the server runs", err)

  local updates = countOf(sent, function(s) return s.msg.type == "update" end)
  check(updates == 3, "every turtle gets it, then the targeted one", updates)

  local forked = find(sent, function(s)
    return s.msg.type == "update" and s.msg.branch == "testing"
  end)
  check(forked ~= nil, "a branch and repo are forwarded")
  check(forked and forked.msg.repo == "someone/fork",
    "so a fleet can be pointed at a fork without reinstalling",
    forked and forked.msg.repo)
  check(forked and forked.to == 7, "to just the targeted turtle", forked and forked.to)
end

--------------------------------------------------------------------------------
say("server: relays a rename, but never to the whole fleet")
--------------------------------------------------------------------------------
do
  local sent, _, err = runServer({
    { from = 7, msg = statusOf(7, "idle") },
    { from = 9, msg = statusOf(9, "idle") },
    { from = 99, msg = { type = "command", target = 7, action = "rename",
                         name = "Digger" } },
    -- Naming every turtle the same thing is the opposite of what naming is for.
    { from = 99, msg = { type = "command", target = "all", action = "rename",
                         name = "Digger" } },
    { wait = 0.2, from = 7, msg = statusOf(7, "idle") },
  })
  check(err == nil, "the server runs", err)

  local renames = countOf(sent, function(s) return s.msg.type == "rename" end)
  check(renames == 1, "exactly one turtle is renamed", renames)

  local one = find(sent, function(s) return s.msg.type == "rename" end)
  check(one and one.to == 7, "the targeted one", one and one.to)
  check(one and one.msg.name == "Digger", "with the name forwarded",
    one and one.msg.name)

  check(find(sent, function(s) return s.msg.type == "error"
    and tostring(s.msg.reason):find("one turtle") end) ~= nil,
    "and renaming 'all' is refused with a reason")
end

--------------------------------------------------------------------------------
say("server: cancelling a running job recalls its turtle")
--------------------------------------------------------------------------------
do
  local sent, _, err = runServer({
    { from = 7, msg = statusOf(7, "idle") },
    { from = 99, msg = { type = "submit", pattern = "quarry",
        params = { w = 4, d = 4, h = 2 }, anchor = { x = 0, y = 64, z = 0 },
        lanes = 1 } },
    { wait = 1.2, from = 7, msg = statusOf(7, "mining", "J1") },
    { from = 99, msg = { type = "cancel", jobId = "J1" } },
    { from = 99, msg = { type = "cancel", jobId = "nope" } },
    { wait = 0.2, from = 7, msg = statusOf(7, "mining", "J1") },
  })
  check(err == nil, "the server runs", err)
  check(find(sent, function(s) return s.msg.type == "return" and s.to == 7 end) ~= nil,
    "the turtle is told to come home")
  check(find(sent, function(s) return s.msg.type == "ack" and s.msg.of == "cancel" end) ~= nil,
    "and the cancel is acked")
  check(find(sent, function(s) return s.msg.type == "error" end) ~= nil,
    "while an unknown job id is refused")
end

--------------------------------------------------------------------------------
say("server: refuses a submit it cannot split")
--------------------------------------------------------------------------------
do
  local sent, _, err = runServer({
    { from = 7, msg = statusOf(7, "idle") },
    { from = 99, msg = { type = "submit", pattern = "quarry",
        params = { w = 2, d = 2, h = 2 }, anchor = { x = 0, y = 64, z = 0 },
        lanes = 9 } },
    { from = 99, msg = { type = "submit", pattern = "quarry",
        params = { w = 8, d = 8, h = 4 }, lanes = 1 } },   -- no anchor
    { wait = 0.2, from = 7, msg = statusOf(7, "idle") },
  })
  check(err == nil, "the server runs", err)
  check(countOf(sent, function(s) return s.msg.type == "error" end) == 2,
    "too many lanes and a missing anchor are both refused")
  check(countOf(sent, function(s) return s.msg.type == "start" end) == 0,
    "and nothing is dispatched")
end

peripheral.call = realCall
fs.delete(config.fleetFile)

say("")
say(("%d passed, %d failed"):format(pass, fail))
say("=== SERVER TESTS DONE ===")
return fail
