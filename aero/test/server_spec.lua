--- Drives server.lua's real event loop.
--
-- The tower has no control loop and no hull; what it has is a roster that must
-- never show a stale position as live, a waypoint table every ship depends on,
-- and a log whose whole job is answering "why did it turn round". So that is
-- what this checks, plus the two refusals that keep the fleet coherent: a second
-- tower standing down, and home not being deletable out from under a ship that
-- is relying on it.
--
-- Scripted the same way as pilot_spec: events are queued before dofile and the
-- real loop processes them. `aero_test_clock` moves os.clock and is picked up by
-- a wrapper around net.decode, and `aero_test_snap` captures the screen -- the
-- server clears the terminal on its way out, so anything read afterwards is
-- blank.
--
-- Every case ends with a queued `terminate`.

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
local log    = require("lib.log")

local realOpen      = net.open
local realSend      = net.send
local realBroadcast = net.broadcast
local realDecode    = net.decode
local realReceive   = net.receive
local realClock     = os.clock

-- Put back rather than cleared. install_spec.lua runs last and install.lua
-- calls peripheral.getNames() to look for a modem; a suite that left the
-- global nil would break it from three files away.
local realPeripheral = _G.peripheral


local clock = 0
os.clock = function() return clock end

local SHIP   = 11
local SHIP2  = 12
local POCKET = 42

local function frame(from, body)
  return { "modem_message", "back", config.channel, config.channel,
           { aero = config.protocol, from = from, to = "*", body = body } }
end

local function drain()
  os.queueEvent("aero_drain")
  while true do
    if os.pullEventRaw() == "aero_drain" then return end
  end
end

--- Boot a tower, feed it a script, hand back the wire and a screen snapshot.
local function runServer(opts)
  opts = opts or {}
  drain()

  fs.delete(config.fleetFile)
  if opts.state then
    local f = fs.open(config.fleetFile, "w")
    f.write(textutils.serialize(opts.state))
    f.close()
  end

  -- No peripherals, so the monitor loop finds nothing and draws only to the
  -- terminal. That is the interesting configuration anyway: the monitor path is
  -- term.redirect around the same render, precisely so it cannot differ.
  local world = { getNames = function() return {} end,
                  getType = function() return nil end,
                  isPresent = function() return false end }
  _G.peripheral = world

  local sent, casts, screens = {}, {}, {}
  clock = opts.at or 0

  net.open = function()
    if opts.noModem then return nil end
    net.channel, net.id = config.channel, os.getComputerID()
    return "back"
  end
  net.send = function(id, msg) sent[#sent + 1] = { to = id, msg = msg } return true end
  net.broadcast = function(msg) casts[#casts + 1] = msg return true end

  -- The anti-duplicate handshake: the tower broadcasts `server?` and stands down
  -- if anything answers `server!`. Two towers would both relay commands and both
  -- keep a log, and the log would then be half the story in two places.
  net.receive = function()
    if opts.otherServer then return 99, { type = "server!" } end
    return nil
  end

  net.decode = function(event, a, b, c, d)
    if event == "aero_test_clock" then clock = a return nil end
    if event == "aero_test_snap" then
      local w, h = term.getSize()
      local lines = {}
      for y = 1, h do
        local ok, line = pcall(function() return select(1, term.current().getLine(y)) end)
        lines[#lines + 1] = ok and line or ""
      end
      screens[#screens + 1] = lines
      return nil
    end
    return realDecode(event, a, b, c, d)
  end

  for _, event in ipairs(opts.script or {}) do os.queueEvent(unpack(event)) end
  os.queueEvent("terminate")

  -- A window of a known size, so the dashboard has somewhere to draw that can be
  -- read back afterwards. The headless terminal has no getLine.
  local window = window.create(term.current(), 1, 1, 51, 19, true)
  local old = term.redirect(window)
  local ok, err = pcall(dofile, "/server.lua")
  term.redirect(old)

  net.open, net.send, net.broadcast, net.decode, net.receive =
    realOpen, realSend, realBroadcast, realDecode, realReceive

  local crash = nil
  if not ok and not tostring(err):find("Terminated", 1, true) then crash = tostring(err) end
  return { sent = sent, casts = casts, screens = screens, crash = crash,
           window = window }
end

local function lastCast(r, type_)
  local found = nil
  for _, msg in ipairs(r.casts) do
    if msg.type == type_ then found = msg end
  end
  return found
end

local function replyTo(r, id, type_)
  for _, s in ipairs(r.sent) do
    if s.to == id and s.msg.type == type_ then return s.msg end
  end
  return nil
end

--- Is this word anywhere on the captured screen?
local function onScreen(screen, text)
  for _, line in ipairs(screen or {}) do
    if tostring(line):find(text, 1, true) then return true end
  end
  return false
end

--------------------------------------------------------------------------------
section("standing up")
--------------------------------------------------------------------------------

do
  local r = runServer{ script = {} }
  check(r.crash == nil, "a tower boots", r.crash)
  check(lastCast(r, "net") ~= nil, "and broadcasts the network at once")
end

do
  -- Another tower is already up. This one stands down rather than competing.
  local r = runServer{ otherServer = true, script = {} }
  check(r.crash == nil, "a second tower does not crash", r.crash)
  check(lastCast(r, "net") == nil, "and does not start broadcasting")
end

--------------------------------------------------------------------------------
section("the roster")
--------------------------------------------------------------------------------

do
  local r = runServer{
    script = {
      frame(SHIP, { type = "tlm", label = "Kestrel", alt = 120,
                    pos = { x = 0, y = 120, z = 40 }, speed = 11,
                    flight = { state = "cruise", leg = "quarry" } }),
      { "aero_test_snap" },
      -- Telemetry arriving does not itself trigger a broadcast -- the tower
      -- beats on its own timer -- so the roster is asked for explicitly rather
      -- than read out of the boot broadcast, which went out before this ship
      -- had said anything.
      frame(POCKET, { type = "net?" }),
    },
  }

  local net_ = lastCast(r, "net")
  check(net_ and net_.ships and #net_.ships == 1, "a ship that reports joins the roster",
        net_ and net_.ships and #net_.ships)
  check(net_ and net_.ships[1] and net_.ships[1].label == "Kestrel", "by name")
  check(onScreen(r.screens[1], "Kestrel"), "and appears on the dashboard")
  check(onScreen(r.screens[1], "cruise"), "with what it is doing")
end

do
  -- Silence. The tower must say LOST rather than drawing the last known position
  -- as though it were live -- somebody will go and look there.
  local r = runServer{
    script = {
      frame(SHIP, { type = "tlm", label = "Kestrel", alt = 120,
                    pos = { x = 0, y = 120, z = 40 },
                    flight = { state = "cruise" } }),
      { "aero_test_clock", config.staleAfter + 5 },
      frame(SHIP2, { type = "tlm", label = "Other", flight = { state = "idle" } }),
      { "aero_test_snap" },
    },
  }

  check(onScreen(r.screens[1], "LOST"), "a silent ship is marked lost")
  check(not onScreen(r.screens[1], "cruise"),
        "and its last state is not drawn as though it were current")
end

do
  -- A pilot saying goodbye is dropped at once rather than left to time out, so a
  -- ship that landed and was switched off does not sit in red looking lost.
  local r = runServer{
    script = {
      frame(SHIP, { type = "tlm", label = "Kestrel", flight = { state = "idle" } }),
      frame(SHIP, { type = "tlm", label = "Kestrel", gone = true }),
      frame(POCKET, { type = "net?" }),
    },
  }
  local net_ = lastCast(r, "net")
  check(net_ and #net_.ships == 0, "a ship that says goodbye leaves the roster",
        net_ and #net_.ships)
end

--------------------------------------------------------------------------------
section("waypoints")
--------------------------------------------------------------------------------

do
  local r = runServer{
    script = {
      frame(POCKET, { type = "wp!", name = "quarry", x = 10, y = 70, z = 300 }),
      frame(POCKET, { type = "wp!", name = "base", x = 0, y = 64, z = 0, kind = "pad" }),
      frame(POCKET, { type = "home!", name = "base" }),
    },
  }

  check(replyTo(r, POCKET, "ack") ~= nil, "a waypoint is accepted")

  local net_ = lastCast(r, "net")
  check(net_ and net_.waypoints and net_.waypoints.quarry ~= nil,
        "and goes out to every ship immediately, not in two seconds")
  check(net_ and net_.home == "base", "so does home")

  -- Written through, because every ship's bingo guard depends on this table and
  -- the tower's chunk is the one most likely to unload.
  check(fs.exists(config.fleetFile), "and it is on disk")
end

do
  local r = runServer{
    script = {
      frame(POCKET, { type = "wp!", name = "bad name!", x = 1, y = 1, z = 1 }),
      frame(POCKET, { type = "wp!", name = "nopad", x = 1, z = 1, kind = "pad" }),
    },
  }
  local err = replyTo(r, POCKET, "error")
  check(err ~= nil, "a bad waypoint is refused with a reason", err and err.reason)
end

do
  -- Home is not deletable. A ship already out there is relying on it to know
  -- where to divert, and deleting it turns the bingo guard from a diversion into
  -- an emergency descent wherever the ship happens to be.
  local r = runServer{
    state = { waypoints = { base = { name = "base", x = 0, y = 64, z = 0, kind = "pad" } },
              routes = {}, log = {}, home = "base" },
    script = { frame(POCKET, { type = "wp-", name = "base" }) },
  }
  local err = replyTo(r, POCKET, "error")
  check(err and tostring(err.reason):find("home", 1, true),
        "home cannot be deleted", err and err.reason)
end

--------------------------------------------------------------------------------
section("the dashboard")
--------------------------------------------------------------------------------

do
  -- The header is the alarm as well as the title. A tower with a ship on a
  -- guard should be readable across a room before anybody has read a word.
  local r = runServer{
    script = {
      frame(SHIP, { type = "tlm", label = "Kestrel", alt = 120,
                    pos = { x = 0, y = 120, z = 40 },
                    flight = { state = "cruise", guard = "clearance" } }),
      { "aero_test_snap" },
    },
  }
  check(onScreen(r.screens[1], "CLEARANCE"),
        "a ship on a guard is shouted about in the header",
        r.screens[1] and r.screens[1][1])

  -- The map is the one thing a tower can do that a pocket cannot: everything at
  -- once, with north up and a scale.
  local mapped = runServer{
    state = { waypoints = { base = { name = "base", x = 0, y = 64, z = 0,
                                     kind = "pad" } },
              routes = {}, log = {}, home = "base" },
    script = {
      frame(SHIP, { type = "tlm", label = "Kestrel", pos = { x = 40, y = 120, z = 40 },
                    heading = 90, flight = { state = "cruise" } }),
      { "mouse_click", 1, 30, 1 },      -- the header cycles the view
      { "aero_test_snap" },
    },
  }
  local anyMap = false
  for _, line in ipairs(mapped.screens[1] or {}) do
    if tostring(line):find("across", 1, true) then anyMap = true end
  end
  check(anyMap or onScreen(mapped.screens[1], "base"),
        "the header cycles to a view that draws the world")

  -- The waypoint table lives here and every ship depends on it, so reading it
  -- without a pocket computer in hand is worth a view.
  local navView = runServer{
    state = { waypoints = { quarry = { name = "quarry", x = 10, y = 70, z = 300,
                                       kind = "point" } },
              routes = {}, log = {}, home = nil },
    script = {
      { "key", keys.tab }, { "key", keys.tab }, { "key", keys.tab },
      { "aero_test_snap" },
    },
  }
  check(onScreen(navView.screens[1], "quarry"),
        "and the waypoints can be read from the tower itself")
end

--------------------------------------------------------------------------------
section("the log")
--------------------------------------------------------------------------------

do
  local r = runServer{
    script = {
      frame(SHIP, { type = "event", label = "Kestrel", what = "state",
                    from = "cruise", to = "rtb", why = "bingo" }),
      frame(POCKET, { type = "log?", n = 10 }),
      { "aero_test_snap" },
    },
  }

  local reply = replyTo(r, POCKET, "log")
  check(reply and #reply.entries == 1, "an event is logged and can be asked for",
        reply and #reply.entries)
  check(reply and reply.entries[1].why == "bingo",
        "with the cause, which is the whole point of the log")
end

do
  -- The log survives a restart, because the question it answers is always about
  -- something that already happened.
  local r = runServer{
    state = { waypoints = {}, routes = {}, home = nil,
              log = { { at = { day = 1, clock = 100 }, ship = SHIP, name = "Kestrel",
                        what = "state", from = "cruise", to = "loiter", why = "nofix" } } },
    script = { frame(POCKET, { type = "log?", n = 10 }) },
  }
  local reply = replyTo(r, POCKET, "log")
  check(reply and #reply.entries == 1, "the log is read back from disk on boot",
        reply and #reply.entries)
end

--------------------------------------------------------------------------------
section("relaying")
--------------------------------------------------------------------------------

do
  -- Commands route through the tower so the log stays complete. A command sent
  -- straight to a ship is invisible here, and the log then shows a ship changing
  -- its mind for no recorded reason.
  local r = runServer{
    script = {
      frame(SHIP,  { type = "tlm", label = "Kestrel", flight = { state = "cruise" } }),
      frame(SHIP2, { type = "tlm", label = "Merlin",  flight = { state = "cruise" } }),
      frame(POCKET, { type = "command", body = { type = "hold" } }),
    },
  }

  local held = 0
  for _, s in ipairs(r.sent) do
    if s.msg.type == "hold" then held = held + 1 end
  end
  check(held == 2, "a command with no target reaches the whole fleet", held)

  local ack = replyTo(r, POCKET, "ack")
  check(ack and ack.sent == 2, "and the pocket is told how many heard it",
        ack and ack.sent)
end

do
  local r = runServer{
    script = {
      frame(SHIP,  { type = "tlm", label = "Kestrel", flight = { state = "cruise" } }),
      frame(SHIP2, { type = "tlm", label = "Merlin",  flight = { state = "cruise" } }),
      frame(POCKET, { type = "command", target = SHIP2, body = { type = "land" } }),
    },
  }

  local to = nil
  for _, s in ipairs(r.sent) do
    if s.msg.type == "land" then to = s.to end
  end
  check(to == SHIP2, "and a targeted one reaches only that ship", to)
end

do
  local r = runServer{
    script = { frame(POCKET, { type = "command", body = { type = "hold" } }) },
  }
  check(replyTo(r, POCKET, "error") ~= nil,
        "commanding an empty fleet says so rather than silently succeeding")
end

--------------------------------------------------------------------------------

os.clock = realClock
_G.peripheral = realPeripheral

say("")
say(("%d passed, %d failed"):format(pass, fail))

_G.AERO_TOTALS = _G.AERO_TOTALS or {}
_G.AERO_TOTALS.server = { pass = pass, fail = fail }
