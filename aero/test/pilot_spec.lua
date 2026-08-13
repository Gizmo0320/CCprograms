--- Drives pilot.lua's real loops against a mock hull.
--
-- The control laws are flown in fly_spec.lua; this is about the wiring around
-- them -- that an order off the wire reaches lib/flight, that a bad one is
-- refused rather than crashing the ship, that an update is refused in the air,
-- and above all that the hull is handed back on every way out of the program.
--
-- The pilot runs two coroutines under parallel.waitForAny, both pulling every
-- event, so the harness scripts it by queueing the events a modem and a timer
-- would produce and letting the real loops process them. Three things are ours:
--
--   aero_test_clock <t>    move os.clock() to t
--   os.startTimer          stubbed to a constant id, so the script can queue
--                          { "timer", 1 } and drive a sweep on demand. The
--                          control loop is timer-driven and nothing else --
--                          unlike redstone/node.lua there is no `redstone` event
--                          to lean on, because nothing in CC announces that a
--                          ship has drifted.
--   gps.locate             stubbed to nothing. The real one blocks for its
--                          timeout and, worse, uses os.startTimer -- which this
--                          harness has just taken over.
--
-- aero_test_clock is picked up by a wrapper around net.decode, the one function
-- both loops call for every single event. The sweep runs before the listener for
-- any one event, so a clock change takes effect on the *next* one, which is why
-- cases that move time follow it with a timer.
--
-- Each case ends with a queued `terminate`, which unwinds both coroutines
-- however the pilot happens to be sitting. Anything else -- draining the queue,
-- waiting for it to notice -- turns a crash into a hang.

local out = {}
local function say(s)
  out[#out + 1] = tostring(s)
  local f = fs.open("/test-pilot-results.txt", "w")
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
local function section(name) say("") say(name) end

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

local unpack = table.unpack or unpack

local config = require("lib.config")
local net    = require("lib.net")
local mock   = dofile("/test/mockperipheral.lua")

-- The boot log prints, and worse, holds the screen waiting for a key when a
-- program came up with problems -- which several cases here deliberately cause.
-- It escaped only because every case ends with a queued terminate that its wait
-- loop happens to break on, which is luck rather than design.
require("lib.boot").quiet = true

-- The module cache is deliberately *not* cleared between cases. pilot.lua is
-- dofile'd fresh each time and resets everything that carries state -- the hull
-- through hull.load, the plan through state.open -- while lib/net is the module
-- this file has replaced the guts of. Reloading it would quietly restore the
-- real transport and every case would sit waiting for a modem.
--
-- `--script` runs outside the shell, so there is no `shell` global to borrow
-- from. pilot.lua only reaches for it on the update path, which is stubbed
-- below -- but it has to be reachable for the stub to replace anything.
_G.shell = _G.shell or {}

local realOpen      = net.open
local realSend      = net.send
local realBroadcast = net.broadcast
local realDecode    = net.decode
local realClock     = os.clock
local realTimer     = os.startTimer
local realCancel    = os.cancelTimer
local realRun       = shell.run
local realGps       = _G.gps

-- Put back rather than cleared. install_spec.lua runs last and install.lua
-- calls peripheral.getNames() to look for a modem; a suite that left the
-- global nil would break it from three files away.
local realPeripheral = _G.peripheral

local realLabel     = os.getComputerLabel()

local clock = 0
os.clock = function() return clock end

local TIMER = 1
os.startTimer = function() return TIMER end
os.cancelTimer = function() end
_G.gps = { locate = function() return nil end }

--------------------------------------------------------------------------------

local POCKET = 42        -- the pocket computer asking for things
local TOWER  = 7

local function writeFile(path, body)
  local f = fs.open(path, "w")
  f.write(body)
  f.close()
end

--- A modem_message event carrying a lib/net frame, so the pilot decodes it the
--- same way it would decode one off a real modem.
local function frame(from, body)
  return { "modem_message", "back", config.channel, config.channel,
           { aero = config.protocol, from = from, to = "*", body = body } }
end

local function tick() return { "timer", TIMER } end

--- Move the clock on.
--
-- Needed more often than it looks. Telemetry is rate limited to one frame every
-- config.heartbeat *of ship time*, so a script that queues twenty timers without
-- moving the clock gets exactly one telemetry frame -- from the first sweep,
-- before anything in the script has happened.
local function clockTo(t) return { "aero_test_clock", t } end

--- Empty the event queue, so one case's leftovers are not the next one's script.
local function drain()
  os.queueEvent("aero_drain")
  while true do
    if os.pullEventRaw() == "aero_drain" then return end
  end
end

local CRAFT = {
  name = "Kestrel",
  controls = {
    lift = { kind = "bearing", peripheral = "lift0", group = "all" },
    main = { kind = "bearing", peripheral = "main0", group = "all",
             pivot = { min = -30, max = 30 } },
  },
  instruments = { nav = "nav0", alt = "alt0", vel = "vel0", ground = "opt0",
                  dock = "dock0", gimbal = false, stick = false, link = false },
  limits = { cruise = 12, climb = 4, descend = 3, clearance = 8 },
  mix = {
    { demand = "lift",    control = "lift", as = "throttle" },
    { demand = "forward", control = "main", as = "throttle" },
    { demand = "yaw",     control = "main", as = "pivot", scale = 30 },
  },
}

--- Boot a pilot with the given hull and saved state, feed it a script of
--- events, and hand back everything it put on the wire.
local function runPilot(opts)
  opts = opts or {}
  drain()

  local world = mock.new{ lift = "lift0", main = "main0",
                          x = opts.x or 0, y = opts.y or 64, z = opts.z or 0 }
  world.bearing("lift0", { count = 4 })
  world.bearing("main0", { count = 2 })
  world.navTable("nav0")
  world.altimeter("alt0")
  world.velocimeter("vel0")
  world.optical("opt0", { range = 40 })
  world.dockPort("dock0")
  if opts.navDark then world.device("nav0").available = false end
  _G.peripheral = world.api

  fs.delete(config.craftFile)
  fs.delete(config.stateFile)
  if opts.craft ~= false then
    writeFile(config.craftFile, "return " .. textutils.serialize(opts.craft or CRAFT))
  end
  if opts.state then
    writeFile(config.stateFile, textutils.serialize(opts.state))
  end

  local sent, casts, ran = {}, {}, {}
  clock = opts.at or 0

  net.open = function()
    if opts.noModem then return nil end
    net.channel = config.channel
    net.id      = os.getComputerID()
    return "back"
  end
  net.send = function(id, msg)
    if opts.noModem then return false end
    sent[#sent + 1] = { to = id, msg = msg }
    return true
  end
  net.broadcast = function(msg)
    if opts.noModem then return false end
    casts[#casts + 1] = msg
    return true
  end
  net.decode = function(event, a, b, c, d)
    if event == "aero_test_clock" then clock = a return nil end
    return realDecode(event, a, b, c, d)
  end

  -- The update path reboots into /update.lua, which would try to download the
  -- whole tree over http. Record the call instead.
  shell.run = function(...) ran[#ran + 1] = { ... } return true end

  for _, event in ipairs(opts.script or {}) do os.queueEvent(unpack(event)) end
  os.queueEvent("terminate")

  local ok, err = pcall(dofile, "/pilot.lua")

  net.open, net.send, net.broadcast, net.decode =
    realOpen, realSend, realBroadcast, realDecode
  shell.run = realRun

  local crash = nil
  if not ok and not tostring(err):find("Terminated", 1, true) then crash = tostring(err) end
  return { sent = sent, casts = casts, world = world, ran = ran, crash = crash }
end

--- The first reply of a type sent to one computer.
local function replyOf(r, type_)
  for _, s in ipairs(r.sent) do
    if s.msg.type == type_ then return s.msg end
  end
  return nil
end

--- The last real telemetry frame.
--
-- Deliberately skips the `gone` farewell the pilot broadcasts on its way out.
-- That frame carries no state at all -- it exists only to drop the ship from the
-- roster at once -- and taking it as the latest reading makes every assertion
-- about what the ship was doing come back nil.
local function lastTelemetry(r)
  local found = nil
  for _, msg in ipairs(r.casts) do
    if msg.type == "tlm" and not msg.gone then found = msg end
  end
  return found
end

local function readFile(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local body = f.readAll()
  f.close()
  return body
end

--------------------------------------------------------------------------------
section("boot")
--------------------------------------------------------------------------------

do
  local r = runPilot{ script = { tick(), tick() } }
  check(r.crash == nil, "a pilot boots against a mock hull", r.crash)

  local tlm = lastTelemetry(r)
  check(tlm ~= nil, "and says where it is, unprompted")
  check(tlm and tlm.flight and tlm.flight.state == "idle",
        "parked, having been given no plan", tlm and tlm.flight and tlm.flight.state)
  check(tlm and tlm.alt == 64, "with an altitude", tlm and tlm.alt)

  -- The most important line in the whole program. A ship that boots with a
  -- surviving override still held has a control loop computing corrections
  -- against a throttle it did not set.
  check(r.world.device("lift0").override == false,
        "and the hull handed back to redstone before anything else")

  -- Parked means parked: nothing is driven at all.
  check(r.world.device("lift0").throttle == 0, "with nothing driven",
        r.world.device("lift0").throttle)
end

do
  -- No craft file at all. This has to be survivable: the installer deliberately
  -- does not write one, so the very first boot of every ship hits this path.
  local r = runPilot{ craft = false, script = { tick() } }
  check(r.crash == nil, "no /craft.cfg is a warning, not a crash", r.crash)
end

--------------------------------------------------------------------------------
section("orders")
--------------------------------------------------------------------------------

do
  -- The tower's broadcast carries the waypoints, and the pilot caches them: this
  -- is what lets a ship already in the air be sent to a named pad after base has
  -- unloaded, and what lets the bingo guard know where home is.
  local waypoints = {
    base = { name = "base", x = 0, y = 64, z = 0, kind = "pad" },
    quarry = { name = "quarry", x = 0, y = 64, z = 300, kind = "pad" },
  }

  local r = runPilot{
    script = {
      frame(TOWER, { type = "net", waypoints = waypoints, home = "base" }),
      tick(),
      frame(POCKET, { type = "fly", names = { "quarry" }, alt = 100 }),
      tick(), clockTo(5), tick(),
    },
  }

  check(r.crash == nil, "a fly order does not crash it", r.crash)
  check(replyOf(r, "ack") ~= nil, "and is acknowledged")

  local tlm = lastTelemetry(r)
  check(tlm and tlm.flight and tlm.flight.state ~= "idle",
        "the ship is no longer parked", tlm and tlm.flight and tlm.flight.state)

  -- Cached to disk, not merely held in memory. The whole point is surviving the
  -- chunk unloading.
  local saved = textutils.unserialize(readFile(config.stateFile) or "")
  check(saved and saved.waypoints and saved.waypoints.quarry ~= nil,
        "and the waypoints are written to disk")
  check(saved and saved.home == "base", "along with where home is")
end

do
  -- An order naming a waypoint nobody has heard of is refused with a reason, not
  -- swallowed. A pocket computer that got no answer would have no way to tell a
  -- rejected order from a lost one.
  local r = runPilot{
    script = {
      frame(POCKET, { type = "fly", names = { "atlantis" }, alt = 100 }),
      tick(),
    },
  }
  local err = replyOf(r, "error")
  check(err ~= nil, "an unknown waypoint is refused")
  check(err and tostring(err.reason):find("atlantis", 1, true),
        "and the reason names it", err and err.reason)
end

do
  -- A message that makes no sense at all must not take the ship down. The
  -- listener is a different coroutine from the control loop, and the control
  -- loop is what is holding the ship up.
  local r = runPilot{
    script = {
      frame(POCKET, { type = "fly", names = "not a list" }),
      frame(POCKET, { type = "nonsense", nested = { deeply = {} } }),
      tick(), tick(),
    },
  }
  check(r.crash == nil, "a malformed order does not crash the ship", r.crash)
  check(lastTelemetry(r) ~= nil, "and it carries on reporting")
end

do
  local r = runPilot{
    script = { frame(POCKET, { type = "rename", name = "Kestrel-II" }), tick() },
  }
  check(os.getComputerLabel() == "Kestrel-II", "rename sets the computer label",
        os.getComputerLabel())
  check(replyOf(r, "ack") ~= nil, "and is acknowledged")
  os.setComputerLabel(realLabel)
end

do
  local r = runPilot{
    script = { frame(POCKET, { type = "hull?" }), tick() },
  }
  local reply = replyOf(r, "hull")
  check(reply ~= nil, "a hull enquiry is answered")
  check(reply and reply.hull and #reply.hull.controls == 2,
        "with every control, so the pocket needs no craft file of its own",
        reply and reply.hull and #reply.hull.controls)
end

--------------------------------------------------------------------------------
section("altitude and the conn")
--------------------------------------------------------------------------------

do
  -- Raising a parked ship with no plan at all: the case that did not exist.
  local r = runPilot{
    script = {
      frame(POCKET, { type = "alt", alt = 140, who = "Anna" }),
      tick(), clockTo(5), tick(),
    },
  }
  check(replyOf(r, "ack") ~= nil, "a parked ship accepts an altitude")

  local tlm = lastTelemetry(r)
  check(tlm and tlm.flight and tlm.flight.state ~= "idle",
        "and leaves the ground for it", tlm and tlm.flight and tlm.flight.state)
  check(tlm and tlm.flight and tlm.flight.alt == 140,
        "holding the altitude it was given", tlm and tlm.flight and tlm.flight.alt)
  check(tlm and tlm.commanderName == "Anna",
        "and the sender now has control", tlm and tlm.commanderName)
end

do
  -- Two people. The second is refused by name rather than obeyed, which is the
  -- whole point: a ship that took both orders would do whichever arrived last
  -- and nobody could say why.
  local BEN = 43

  local r = runPilot{
    script = {
      frame(POCKET, { type = "alt", alt = 140, who = "Anna" }),
      tick(),
      frame(BEN, { type = "stop", who = "Ben" }),
      clockTo(5), tick(),
    },
  }

  local refusal = nil
  for _, s in ipairs(r.sent) do
    if s.to == BEN and s.msg.type == "error" then refusal = s.msg end
  end
  check(refusal ~= nil, "a second person is refused")
  check(refusal and tostring(refusal.reason):find("Anna", 1, true) ~= nil,
        "and told who has it", refusal and refusal.reason)

  local tlm = lastTelemetry(r)
  check(tlm and tlm.flight and tlm.flight.state ~= "emergency",
        "and the ship does not act on the order",
        tlm and tlm.flight and tlm.flight.state)
end

do
  -- Taking over is always allowed, and logged with both names.
  local BEN = 43

  local r = runPilot{
    script = {
      frame(POCKET, { type = "alt", alt = 140, who = "Anna" }),
      tick(),
      frame(BEN, { type = "take", who = "Ben" }),
      frame(BEN, { type = "alt", by = -20, who = "Ben" }),
      clockTo(5), tick(),
    },
  }

  local tlm = lastTelemetry(r)
  check(tlm and tlm.commanderName == "Ben", "anyone may take control",
        tlm and tlm.commanderName)
  check(tlm and tlm.flight and tlm.flight.alt == 120,
        "and then command", tlm and tlm.flight and tlm.flight.alt)

  local handover = nil
  for _, msg in ipairs(r.casts) do
    if msg.type == "event" and msg.what == "control" then handover = msg end
  end
  check(handover ~= nil, "the handover is broadcast for the log")
  check(handover and handover.from == "Anna" and handover.to == "Ben",
        "naming both people", handover and (tostring(handover.from) .. ">"
          .. tostring(handover.to)))
end

do
  -- The tower relays, and stamps the *original* sender. Without that every
  -- relayed order would look like it came from the same place, and one person
  -- taking control would silently hand it to everybody.
  local BEN = 43

  local r = runPilot{
    script = {
      -- Anna, through the tower.
      frame(TOWER, { type = "alt", alt = 140, sender = POCKET, who = "Anna" }),
      tick(),
      -- Ben, also through the tower, must still be refused.
      frame(TOWER, { type = "stop", sender = BEN, who = "Ben" }),
      clockTo(5), tick(),
    },
  }

  local tlm = lastTelemetry(r)
  check(tlm and tlm.commanderName == "Anna",
        "a relayed order holds the conn for the person, not the tower",
        tlm and tlm.commanderName)

  -- The sender field is `sender` and not `by`, and this is why. `by` is the
  -- relative altitude on an `alt` order, and when the two shared a name a
  -- relative altitude of -20 set the sender to -20 -- so the ship refused its
  -- own commander his own order, and only the round trip through here showed it.
  local by = runPilot{
    script = {
      frame(POCKET, { type = "alt", alt = 140, who = "Anna" }),
      tick(),
      frame(POCKET, { type = "alt", by = -20, who = "Anna" }),
      clockTo(5), tick(),
    },
  }
  local moved = lastTelemetry(by)
  check(moved and moved.flight and moved.flight.alt == 120,
        "a relative altitude is an altitude, not a sender",
        moved and moved.flight and moved.flight.alt)
  check(tlm and tlm.flight and tlm.flight.state ~= "emergency",
        "so somebody else relaying through the same tower is still refused",
        tlm and tlm.flight and tlm.flight.state)
end

--------------------------------------------------------------------------------
section("updates")
--------------------------------------------------------------------------------

do
  -- Parked, so it is allowed.
  local r = runPilot{
    script = { frame(POCKET, { type = "update", branch = "main" }), tick() },
  }
  check(#r.ran == 1, "an update on the ground runs the updater", #r.ran)
  check(r.ran[1] and r.ran[1][1] == "/update.lua", "which is update.lua")
  check(replyOf(r, "ack") ~= nil, "and is acknowledged")

  -- And the hull is still handed back on the way out, because the updater is
  -- about to reboot the computer.
  check(r.world.device("lift0").override == false,
        "with the hull released before the reboot")
end

do
  -- Airborne. A saved plan comes back as `loiter`, which is flying.
  local r = runPilot{
    state = {
      plan = { alt = 100, leg = 1,
               legs = { { name = "quarry", x = 0, y = 64, z = 300, kind = "pad" } } },
      alt = 100,
    },
    script = { tick(), frame(POCKET, { type = "update", branch = "main" }), tick() },
  }

  check(#r.ran == 0, "an update in the air is refused", #r.ran)
  local err = replyOf(r, "error")
  check(err and err.reason == "flying", "with a reason", err and err.reason)
end

do
  -- A ship that was flying when the chunk unloaded comes back **loitering**, not
  -- cruising. It has no fix yet and no idea how long it was away, and the first
  -- thing it would do at cruise is push the throttle up on a stale position.
  --
  -- With the navigation table still dark it stays there, which is the case that
  -- matters: this is a ship that has just reappeared several minutes and an
  -- unknown distance from where its state file says it was.
  local dark = runPilot{
    y = 120, navDark = true,
    state = {
      plan = { alt = 100, leg = 1,
               legs = { { name = "quarry", x = 0, y = 64, z = 300, kind = "pad" } } },
      alt = 100,
    },
    script = { tick(), clockTo(5), tick(), clockTo(10), tick() },
  }

  local tlm = lastTelemetry(dark)
  check(tlm and tlm.flight and tlm.flight.state == "loiter",
        "a rebooted ship with no fix holds rather than cruising",
        tlm and tlm.flight and tlm.flight.state)
  check(tlm and tlm.flight and tlm.flight.legs == 1,
        "with the plan it had before", tlm and tlm.flight and tlm.flight.legs)

  -- And once the fix is there it picks the plan straight back up, because
  -- loiter is a wait rather than an abort.
  local lit = runPilot{
    y = 120,
    state = {
      plan = { alt = 100, leg = 1,
               legs = { { name = "quarry", x = 0, y = 64, z = 300, kind = "pad" } } },
      alt = 100,
    },
    script = { tick(), clockTo(5), tick() },
  }

  local tlm2 = lastTelemetry(lit)
  check(tlm2 and tlm2.flight and tlm2.flight.state == "cruise",
        "and resumes the moment it knows where it is",
        tlm2 and tlm2.flight and tlm2.flight.state)
end

--------------------------------------------------------------------------------
section("the way out")
--------------------------------------------------------------------------------

do
  -- Flying, then terminated. Every exit path releases; this is the one a player
  -- causes by holding Ctrl-T, and it is the one most likely to happen while the
  -- ship is in the air.
  local r = runPilot{
    y = 120,
    state = {
      plan = { alt = 140, leg = 1,
               legs = { { name = "far", x = 0, y = 120, z = 900 } } },
      alt = 140,
    },
    script = { tick(), tick(), tick(), tick() },
  }

  check(r.world.device("lift0").override == false,
        "terminate hands the throttle back")
  check(r.world.device("lift0").mode == "redstone",
        "and the bearing with it", r.world.device("lift0").mode)
  check(r.world.device("main0").override == false, "every bearing, not just one")

  -- And it says goodbye, so the tower drops it from the roster at once rather
  -- than showing it in red for fifteen seconds looking lost.
  local farewell = nil
  for _, msg in ipairs(r.casts) do
    if msg.type == "tlm" and msg.gone then farewell = msg end
  end
  check(farewell ~= nil, "and tells the network it has gone")
end

do
  -- No modem. A ship with no radio still flies its own plan -- that is the whole
  -- design -- and must not crash trying to say so.
  local r = runPilot{ noModem = true, script = { tick(), tick() } }
  check(r.crash == nil, "a pilot with no modem still runs", r.crash)
  check(#r.casts == 0, "and sends nothing")
end

--------------------------------------------------------------------------------

os.clock = realClock
os.startTimer = realTimer
os.cancelTimer = realCancel
_G.gps = realGps
_G.peripheral = realPeripheral
os.setComputerLabel(realLabel)

say("")
say(("%d passed, %d failed"):format(pass, fail))

_G.AERO_TOTALS = _G.AERO_TOTALS or {}
_G.AERO_TOTALS.pilot = { pass = pass, fail = fail }
