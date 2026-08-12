--- Drives remote.lua's real event loop on a pocket-sized screen.
--
-- The remote renders what the protocol already provides and holds no
-- authoritative state, so what is worth checking is the part that is easy to get
-- wrong and invisible until you are standing in a field: that both link modes
-- work, that a ship gone quiet reads LOST rather than showing its last position,
-- and that a tap lands on the row it was drawn on.
--
-- The terminal is forced to **26x20**, the size of a pocket computer. The
-- headless terminal is 51 wide and every layout here is relative to the screen
-- width, so a click at column 24 on a 51-wide screen lands somewhere completely
-- different from where it lands in your hand. Drawing into a window of the right
-- size also gives getLine, which the headless terminal does not have.
--
-- remote.lua clears the terminal on its way out, so screens are captured
-- mid-run with `aero_test_snap`.
--
-- Text is cut to the column it is drawn in, so assertions are on what fits, not
-- on the whole string.

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

local realOpen      = net.open
local realSend      = net.send
local realBroadcast = net.broadcast
local realDecode    = net.decode
local realClock     = os.clock
local realGps       = _G.gps

local clock = 0
os.clock = function() return clock end

local W, H = 26, 20

local SHIP   = 11
local SHIP2  = 12
local TOWER  = 7

local function frame(from, body)
  return { "modem_message", "back", config.channel, config.channel,
           { aero = config.protocol, from = from, to = "*", body = body } }
end

local function click(x, y) return { "mouse_click", 1, x, y } end
local function key(k) return { "key", k } end
local function snap() return { "aero_test_snap" } end
local function clockTo(t) return { "aero_test_clock", t } end

local function drain()
  os.queueEvent("aero_drain")
  while true do
    if os.pullEventRaw() == "aero_drain" then return end
  end
end

--- The tabs are six columns apart along the bottom row, so this is where a
--- thumb goes for each one.
local TAB_X = { fleet = 1, fly = 7, nav = 13, log = 19 }
local function tab(name) return click(TAB_X[name], H) end

local function runRemote(opts)
  opts = opts or {}
  drain()

  local sent, casts, screens = {}, {}, {}
  clock = opts.at or 0

  net.open = function()
    if opts.noModem then return nil end
    net.channel, net.id = config.channel, os.getComputerID()
    return "back"
  end
  net.send = function(id, msg) sent[#sent + 1] = { to = id, msg = msg } return true end
  net.broadcast = function(msg) casts[#casts + 1] = msg return true end

  local window_
  net.decode = function(event, a, b, c, d)
    if event == "aero_test_clock" then clock = a return nil end
    if event == "aero_test_snap" then
      local lines = {}
      for y = 1, H do lines[#lines + 1] = window_.getLine(y) end
      screens[#screens + 1] = lines
      return nil
    end
    return realDecode(event, a, b, c, d)
  end

  _G.gps = { locate = function()
    if opts.noGps then return nil end
    return 100, 70, 200
  end }

  for _, event in ipairs(opts.script or {}) do os.queueEvent(unpack(event)) end
  os.queueEvent("key", keys.q)

  window_ = window.create(term.current(), 1, 1, W, H, true)
  local old = term.redirect(window_)
  local ok, err = pcall(dofile, "/remote.lua")
  term.redirect(old)

  net.open, net.send, net.broadcast, net.decode =
    realOpen, realSend, realBroadcast, realDecode
  _G.gps = realGps

  local crash = nil
  if not ok and not tostring(err):find("Terminated", 1, true) then crash = tostring(err) end
  return { sent = sent, casts = casts, screens = screens, crash = crash }
end

local function onScreen(screen, text)
  for _, line in ipairs(screen or {}) do
    if tostring(line):find(text, 1, true) then return true end
  end
  return false
end

local function rowOf(screen, text)
  for y, line in ipairs(screen or {}) do
    if tostring(line):find(text, 1, true) then return y end
  end
  return nil
end

local function sentOf(r, type_)
  for _, s in ipairs(r.sent) do
    if s.msg.type == type_ then return s.msg, s.to end
  end
  return nil
end

--- A tower broadcast carrying a fleet and a waypoint table.
local function towerNet(ships, waypoints, home)
  return frame(TOWER, {
    type = "net",
    ships = ships or {},
    waypoints = waypoints or {},
    home = home,
  })
end

--------------------------------------------------------------------------------
section("link modes")
--------------------------------------------------------------------------------

do
  local r = runRemote{ script = { snap() } }
  check(r.crash == nil, "the remote boots", r.crash)
  check(onScreen(r.screens[1], "LOST"),
        "and says LOST when nothing at all is answering")
  check(#r.casts > 0, "having asked", #r.casts)
end

do
  local r = runRemote{
    script = {
      towerNet({ { id = SHIP, label = "Kestrel", alt = 120,
                   flight = { state = "cruise" } } }),
      snap(),
    },
  }
  check(onScreen(r.screens[1], "TOWER"), "a tower answering reads TOWER")
  check(onScreen(r.screens[1], "Kestrel"), "and its roster is drawn")
  check(onScreen(r.screens[1], "cruise"), "with what each ship is doing")
end

do
  -- Direct mode: nothing at base, but the ships are talking. Every command still
  -- works, which is the part that matters when you are standing in a field
  -- watching one circle.
  local r = runRemote{
    script = {
      frame(SHIP, { type = "tlm", label = "Kestrel", alt = 120,
                    flight = { state = "loiter" } }),
      snap(),
    },
  }
  check(onScreen(r.screens[1], "DIRECT"), "ships without a tower read DIRECT")
  check(onScreen(r.screens[1], "Kestrel"), "and are still listed")
end

do
  -- The whole job of this program is telling you what is happening now. A ship
  -- that has gone quiet must never have its last position drawn as though it
  -- were live.
  local r = runRemote{
    script = {
      frame(SHIP, { type = "tlm", label = "Kestrel", alt = 120,
                    flight = { state = "cruise" } }),
      clockTo(config.heartbeatTimeout + 5),
      -- Something has to make it redraw. The clock event is swallowed by the
      -- decode wrapper and matches none of the loop's branches, so on its own it
      -- moves time without the screen noticing. Re-tapping the tab we are
      -- already on is the least intrusive way to ask for a draw.
      tab("fleet"),
      snap(),
    },
  }
  check(onScreen(r.screens[1], "LOST"), "a silent ship reads LOST")
  check(not onScreen(r.screens[1], "cruise"),
        "and its last state is not shown as though it were current")
end

do
  local r = runRemote{ noModem = true, script = {} }
  check(r.crash == nil, "no modem is a message, not a crash", r.crash)
  check(#r.casts == 0, "and nothing is sent")
end

--------------------------------------------------------------------------------
section("commanding")
--------------------------------------------------------------------------------

do
  -- Through the tower when one is answering, so the log stays whole: a command
  -- sent straight to a ship is invisible to the tower, and the log then shows a
  -- ship changing its mind for no recorded reason.
  local ships = { { id = SHIP, label = "Kestrel", flight = { state = "cruise" } } }

  local r = runRemote{
    script = { towerNet(ships), snap() },
  }
  local y = rowOf(r.screens[1], "HOLD")
  check(y ~= nil, "the fleet screen offers HOLD")

  local r2 = runRemote{
    script = { towerNet(ships), snap(), click(2, y or 1) },
  }
  local msg, to = sentOf(r2, "command")
  check(msg ~= nil, "tapping it sends a command")
  check(to == TOWER, "to the tower", to)
  check(msg and msg.body and msg.body.type == "hold", "and it is a hold",
        msg and msg.body and msg.body.type)
  check(msg and msg.target == nil, "for the whole fleet when none is selected")
end

do
  -- Selecting a ship narrows every command to it. Tapping the selected one again
  -- clears the selection, which is how you get back to the whole fleet without a
  -- separate control.
  local ships = {
    { id = SHIP,  label = "Kestrel", flight = { state = "cruise" } },
    { id = SHIP2, label = "Merlin",  flight = { state = "cruise" } },
  }

  -- Probed twice, and the second probe is the point: picking a ship adds its
  -- own panel to the list, so every action row below moves down by one. Reading
  -- a row position off the unselected layout and clicking it on the selected one
  -- lands on the wrong button -- which is what happened here, and is exactly why
  -- rows carry their own handler rather than being matched on coordinates.
  local probe = runRemote{ script = { towerNet(ships), snap() } }
  local shipRow = rowOf(probe.screens[1], "Merlin")
  check(shipRow ~= nil, "the ship is listed", shipRow)

  local after = runRemote{
    script = { towerNet(ships), click(2, shipRow or 1), snap() },
  }
  local stopRow = rowOf(after.screens[1], "STOP")
  check(stopRow ~= nil, "and the actions are drawn once it is picked", stopRow)

  local r = runRemote{
    script = {
      towerNet(ships),
      click(2, shipRow or 1),
      click(2, stopRow or 1),
    },
  }
  local msg = sentOf(r, "command")
  check(msg and msg.target == SHIP2, "a selected ship gets the command alone",
        msg and msg.target)
  check(msg and msg.body.type == "stop", "and STOP is a controlled descent order",
        msg and msg.body.type)
end

do
  -- With no tower, commands go straight to the ships.
  local r = runRemote{
    script = {
      frame(SHIP, { type = "tlm", label = "Kestrel", flight = { state = "cruise" } }),
      snap(),
    },
  }
  local y = rowOf(r.screens[1], "RTB")
  local r2 = runRemote{
    script = {
      frame(SHIP, { type = "tlm", label = "Kestrel", flight = { state = "cruise" } }),
      snap(), click(2, y or 1),
    },
  }
  local msg, to = sentOf(r2, "rtb")
  check(msg ~= nil, "in direct mode the order goes to the ship itself")
  check(to == SHIP, "addressed to it", to)
end

--------------------------------------------------------------------------------
section("flying somewhere")
--------------------------------------------------------------------------------

do
  local waypoints = {
    quarry = { name = "quarry", x = 0, y = 70, z = 300, kind = "point" },
    base   = { name = "base",   x = 0, y = 64, z = 0,   kind = "pad" },
  }
  local ships = { { id = SHIP, label = "Kestrel", flight = { state = "idle" } } }

  local probe = runRemote{
    script = { towerNet(ships, waypoints, "base"), tab("fly"), snap() },
  }
  check(onScreen(probe.screens[1], "quarry"), "the fly screen lists the waypoints")
  check(onScreen(probe.screens[1], "FLY IT"), "and offers to fly them")

  local quarryRow = rowOf(probe.screens[1], "quarry")
  local flyRow    = rowOf(probe.screens[1], "FLY IT")

  local r = runRemote{
    script = {
      towerNet(ships, waypoints, "base"), tab("fly"), snap(),
      click(2, quarryRow or 1),
      snap(),
      click(2, flyRow or 1),
    },
  }

  -- Adding a leg redraws the route, so FLY IT has moved down by a row. The
  -- second snapshot is where its new position is read from -- which is the whole
  -- reason rows carry their own click handler rather than being matched on
  -- coordinates.
  local msg = sentOf(r, "command")
  if not msg then
    local flyRow2 = rowOf(r.screens[2], "FLY IT")
    r = runRemote{
      script = {
        towerNet(ships, waypoints, "base"), tab("fly"), snap(),
        click(2, quarryRow or 1),
        snap(),
        click(2, flyRow2 or 1),
      },
    }
    msg = sentOf(r, "command")
  end

  check(msg ~= nil, "tapping a waypoint and then FLY IT sends a plan")
  check(msg and msg.body and msg.body.type == "fly", "which is a fly order",
        msg and msg.body and msg.body.type)
  check(msg and msg.body and msg.body.names and msg.body.names[1] == "quarry",
        "naming the waypoint that was tapped")
  check(msg and msg.body and tonumber(msg.body.alt) ~= nil,
        "with an altitude, which lib/flight refuses a plan without")
end

do
  -- Nothing to fly to. Saying so beats an empty screen with a button on it.
  local r = runRemote{
    script = { towerNet({}, {}), tab("fly"), snap() },
  }
  check(onScreen(r.screens[1], "No waypoints"), "an empty waypoint table says so")
end

--------------------------------------------------------------------------------
section("waypoints")
--------------------------------------------------------------------------------

do
  local probe = runRemote{
    script = { towerNet({}, {}), tab("nav"), snap() },
  }
  local addRow = rowOf(probe.screens[1], "+ pad here")
  check(addRow ~= nil, "the nav screen offers to put a pad down where you are")

  -- Typed rather than read(): read blocks the event loop, telemetry stops
  -- arriving and the link reads LOST while you type.
  local r = runRemote{
    script = {
      towerNet({}, {}), tab("nav"), snap(),
      click(2, addRow or 1),
      { "char", "p" }, { "char", "a" }, { "char", "d" },
      key(keys.enter),
    },
  }

  local msg, to = sentOf(r, "wp!")
  check(msg ~= nil, "typing a name and pressing enter sends a waypoint")
  check(msg and msg.name == "pad", "with the name that was typed", msg and msg.name)
  check(msg and msg.kind == "pad", "and the kind that was chosen", msg and msg.kind)
  check(msg and msg.x == 100 and msg.z == 200,
        "positioned where the pocket computer is, from GPS",
        msg and (msg.x .. "," .. msg.z))
  check(to == TOWER, "sent to the tower, which owns the waypoint table")
end

do
  -- No GPS. Refusing with a message beats sending a waypoint at nil, nil, nil.
  local probe = runRemote{ script = { towerNet({}, {}), tab("nav"), snap() } }
  local addRow = rowOf(probe.screens[1], "+ waypoint here")

  local r = runRemote{
    noGps = true,
    script = {
      towerNet({}, {}), tab("nav"), snap(),
      click(2, addRow or 1),
      { "char", "x" },
      key(keys.enter),
      snap(),
    },
  }
  check(sentOf(r, "wp!") == nil, "no GPS fix sends nothing")
  check(onScreen(r.screens[2], "GPS"), "and says why", r.screens[2] and r.screens[2][H - 1])
end

do
  -- Waypoints live on the tower, so in direct mode there is nothing to add them
  -- to. Saying so is better than a button that does nothing.
  local probe = runRemote{
    script = {
      frame(SHIP, { type = "tlm", label = "Kestrel", flight = { state = "idle" } }),
      tab("nav"), snap(),
    },
  }
  local addRow = rowOf(probe.screens[1], "+ pad here")
  local r = runRemote{
    script = {
      frame(SHIP, { type = "tlm", label = "Kestrel", flight = { state = "idle" } }),
      tab("nav"), snap(), click(2, addRow or 1), snap(),
    },
  }
  check(sentOf(r, "wp!") == nil, "with no tower, no waypoint is sent")
  check(onScreen(r.screens[2], "tower"), "and it says the tower is needed")
end

--------------------------------------------------------------------------------
section("one ship's panel")
--------------------------------------------------------------------------------

-- Everything that belongs to one ship rather than to the fleet: its gauges, the
-- hull it is made of, and the gains that decide how it flies. All three were
-- reachable in the protocol and by nothing a thumb could press.
do
  local ships = { { id = SHIP, label = "Kestrel", alt = 120,
                    flight = { state = "cruise", alt = 120 } } }

  -- Probed in steps, each a complete run of its own. Nesting one runRemote
  -- inside another's script table tangles the event queue -- the inner run
  -- drains it -- and the suite hangs rather than failing, which is the one
  -- outcome test/run.lua cannot report.
  local probe = runRemote{ script = { towerNet(ships), snap() } }
  local shipRow = rowOf(probe.screens[1], "Kestrel")

  local picked = runRemote{
    script = { towerNet(ships), click(2, shipRow or 1), snap() },
  }
  local openRow = rowOf(picked.screens[1], "SHIP")
  check(openRow ~= nil, "picking a ship offers its own panel", openRow)

  local opened = runRemote{
    script = { towerNet(ships), click(2, shipRow or 1),
               click(2, openRow or 1), snap() },
  }

  -- Opening the panel asks the ship what it is made of. The pocket has no
  -- /craft.cfg of its own -- it learns by asking.
  check(sentOf(opened, "hull?") ~= nil, "opening a ship's panel asks for its hull")
  check(onScreen(opened.screens[1], "asking"),
        "and says so while it waits", opened.screens[1] and opened.screens[1][8])

  -- With an answer, the controls and the gains are both on screen.
  local HULL = {
    name = "Kestrel",
    controls = {
      { name = "lift", kind = "bearing", ok = true },
      { name = "main", kind = "bearing", ok = false },
    },
    gains = { hover = 0.5, altP = 0.35, vsP = 0.07, vsI = 0.05,
              hdgP = 0.015, spdP = 0.18 },
    problems = {},
  }

  local full = runRemote{
    script = { towerNet(ships), click(2, shipRow or 1), click(2, openRow or 1),
               frame(SHIP, { type = "hull", hull = HULL }), snap() },
  }

  check(onScreen(full.screens[1], "lift"), "the hull's controls are listed")
  check(onScreen(full.screens[1], "FAULT"),
        "and a control that is not answering says so, which is the quickest way "
        .. "to find the bearing you thought was attached")
  check(onScreen(full.screens[1], "hover"), "the gains are listed too")

  -- Tuning. Reinstalling to try 0.4 instead of 0.35 is not a tuning loop
  -- anybody will use, so it happens from the thing in your hand.
  local gainRow = rowOf(full.screens[1], "hover")
  local tuned = runRemote{
    script = { towerNet(ships), click(2, shipRow or 1), click(2, openRow or 1),
               frame(SHIP, { type = "hull", hull = HULL }),
               snap(),
               -- The far right of the row is the plus; the column matters,
               -- because one row carries two gestures.
               click(26, gainRow or 1) },
  }

  local tune, to = sentOf(tuned, "tune")
  check(tune ~= nil, "tapping + on a gain sends a tune")
  check(to == SHIP, "straight to the ship, which owns its own gains", to)
  check(tune and tune.gains and tune.gains.hover > 0.5,
        "raising it raises it", tune and tune.gains and tune.gains.hover)

  local lowered = runRemote{
    script = { towerNet(ships), click(2, shipRow or 1), click(2, openRow or 1),
               frame(SHIP, { type = "hull", hull = HULL }),
               snap(), click(24, gainRow or 1) },
  }
  local down = sentOf(lowered, "tune")
  check(down and down.gains and down.gains.hover < 0.5,
        "and the minus lowers it", down and down.gains and down.gains.hover)

  -- A gain is never sent negative: a negative gain is a loop that drives the
  -- ship away from what it was asked for.
  local ZERO = { controls = {}, gains = { hover = 0 }, problems = {} }
  local floorTest = runRemote{
    script = { towerNet(ships), click(2, shipRow or 1), click(2, openRow or 1),
               frame(SHIP, { type = "hull", hull = ZERO }), snap() },
  }
  local zeroRow = rowOf(floorTest.screens[1], "hover")
  local pushed = runRemote{
    script = { towerNet(ships), click(2, shipRow or 1), click(2, openRow or 1),
               frame(SHIP, { type = "hull", hull = ZERO }),
               snap(), click(24, zeroRow or 1) },
  }
  local floored = sentOf(pushed, "tune")
  check(floored and floored.gains.hover >= 0, "and never below zero",
        floored and floored.gains.hover)
end

--------------------------------------------------------------------------------
section("altitude and control")
--------------------------------------------------------------------------------

do
  local ships = { { id = SHIP, label = "Kestrel", alt = 120,
                    flight = { state = "loiter", alt = 120 } } }

  -- Raising and lowering, which is the thing wanted most often and had no
  -- control at all: every altitude used to arrive attached to a flight plan.
  local probe = runRemote{ script = { towerNet(ships), snap() } }
  local altRow = rowOf(probe.screens[1], "ALT")
  check(altRow ~= nil, "the fleet screen offers altitude", altRow)

  local up = runRemote{
    script = { towerNet(ships), snap(), click(26, altRow or 1) },
  }
  local raised = sentOf(up, "command")
  check(raised and raised.body and raised.body.type == "alt",
        "the right of the row sends an altitude order",
        raised and raised.body and raised.body.type)
  check(raised and raised.body.by ~= nil and raised.body.alt == nil,
        "relative rather than absolute, which is what a pair of buttons means",
        raised and raised.body.by)
  check(raised and (raised.body.by or 0) > 0, "and upwards",
        raised and raised.body.by)

  local down = runRemote{
    script = { towerNet(ships), snap(), click(24, altRow or 1) },
  }
  local lowered = sentOf(down, "command")
  check(lowered and lowered.body and (lowered.body.by or 0) < 0,
        "and the left of the row sends it downwards",
        lowered and lowered.body and lowered.body.by)

  -- Every order says who sent it, so a ship can hold the conn for a person
  -- rather than for whichever computer relayed it.
  check(raised and raised.body.who ~= nil,
        "orders carry who sent them", raised and raised.body.who)

  ------------------------------------------------------------------------------
  -- The conn.

  local shipRow = rowOf(probe.screens[1], "Kestrel")
  local picked = runRemote{
    script = { towerNet(ships), click(2, shipRow or 1), snap() },
  }
  local openRow = rowOf(picked.screens[1], "SHIP")

  local HULL = { controls = {}, gains = {}, problems = {} }

  local free = runRemote{
    script = { towerNet(ships), click(2, shipRow or 1), click(2, openRow or 1),
               frame(SHIP, { type = "hull", hull = HULL }), snap() },
  }
  check(onScreen(free.screens[1], "nobody"),
        "a ship nobody is flying says so")
  check(onScreen(free.screens[1], "TAKE control"),
        "and offers to take it")

  local takeRow = rowOf(free.screens[1], "TAKE control")
  local taken = runRemote{
    script = { towerNet(ships), click(2, shipRow or 1), click(2, openRow or 1),
               frame(SHIP, { type = "hull", hull = HULL }),
               snap(), click(2, takeRow or 1) },
  }
  local take, to = sentOf(taken, "take")
  check(take ~= nil, "tapping it takes control")
  check(to == SHIP, "straight to the ship, which owns the conn", to)
  check(take and take.who ~= nil, "saying who is taking it", take and take.who)

  -- Somebody else already has it: the panel names them, and the fleet list
  -- marks the ship, because that is what you need before you touch anything.
  local held = { { id = SHIP, label = "Kestrel", alt = 120,
                   flight = { state = "loiter", alt = 120,
                              commander = 99, commanderName = "Anna" } } }

  local heldProbe = runRemote{ script = { towerNet(held), snap() } }
  check(onScreen(heldProbe.screens[1], "*"),
        "a ship somebody else is flying is marked in the fleet list")

  local heldShipRow = rowOf(heldProbe.screens[1], "Kestrel")
  local heldPicked = runRemote{
    script = { towerNet(held), click(2, heldShipRow or 1), snap() },
  }
  local heldOpen = rowOf(heldPicked.screens[1], "SHIP")

  local panel = runRemote{
    script = { towerNet(held), click(2, heldShipRow or 1), click(2, heldOpen or 1),
               frame(SHIP, { type = "hull", hull = HULL }), snap() },
  }
  check(onScreen(panel.screens[1], "Anna"),
        "and the panel names whoever has it",
        panel.screens[1] and panel.screens[1][10])
  check(onScreen(panel.screens[1], "TAKE control from"),
        "and offers to take it from them by name")
end

--------------------------------------------------------------------------------
section("routes and deleting")
--------------------------------------------------------------------------------

do
  local waypoints = {
    quarry = { name = "quarry", x = 0, y = 70, z = 300, kind = "point" },
    base   = { name = "base",   x = 0, y = 64, z = 0,   kind = "pad" },
  }
  local ships = { { id = SHIP, label = "Kestrel", flight = { state = "idle" } } }

  -- Deleting a waypoint is the more dangerous of the two gestures on the row,
  -- so it lives in the last column and tapping the name does the harmless one.
  local probe = runRemote{
    script = { towerNet(ships, waypoints, "base"), tab("nav"), snap() },
  }
  local quarryRow = rowOf(probe.screens[1], "quarry")
  check(quarryRow ~= nil, "the nav tab lists waypoints", quarryRow)

  local homed = runRemote{
    script = { towerNet(ships, waypoints, "base"), tab("nav"),
               snap(), click(2, quarryRow or 1) },
  }
  check(sentOf(homed, "home!") ~= nil, "tapping the name sets home")
  check(sentOf(homed, "wp-") == nil, "and deletes nothing")

  local deleted = runRemote{
    script = { towerNet(ships, waypoints, "base"), tab("nav"),
               snap(), click(26, quarryRow or 1) },
  }
  local gone = sentOf(deleted, "wp-")
  check(gone ~= nil, "tapping the x deletes it")
  check(gone and gone.name == "quarry", "the one that was tapped", gone and gone.name)

  -- A saved route is two taps to fly, which is the point of saving one.
  local routes = { run = { name = "run", names = { "quarry", "base" }, alt = 140 } }
  local withRoutes = runRemote{
    script = { frame(TOWER, { type = "net", ships = ships,
                              waypoints = waypoints, routes = routes,
                              home = "base" }),
               tab("fly"), snap() },
  }
  check(onScreen(withRoutes.screens[1], "run"), "saved routes are listed")

  local routeRow = rowOf(withRoutes.screens[1], "run")
  local loaded = runRemote{
    script = { frame(TOWER, { type = "net", ships = ships,
                              waypoints = waypoints, routes = routes,
                              home = "base" }),
               tab("fly"), snap(), click(2, routeRow or 1), snap() },
  }
  check(onScreen(loaded.screens[2], "1 quarry"),
        "and tapping one loads its legs", loaded.screens[2] and loaded.screens[2][6])
end

--------------------------------------------------------------------------------
section("the log tab")
--------------------------------------------------------------------------------

do
  local r = runRemote{
    script = { towerNet({}, {}), tab("log") },
  }
  local msg = sentOf(r, "log?")
  check(msg ~= nil, "opening the log asks the tower for it")

  local r2 = runRemote{
    script = {
      towerNet({}, {}), tab("log"),
      frame(TOWER, { type = "log", entries = {
        { at = { day = 1, clock = 19000 }, ship = SHIP, name = "Kestrel",
          what = "state", from = "cruise", to = "rtb", why = "bingo" },
      } }),
      snap(),
    },
  }
  check(onScreen(r2.screens[1], "bingo"),
        "and the reason survives being cut to 26 columns",
        r2.screens[1] and r2.screens[1][3])
end

--------------------------------------------------------------------------------

os.clock = realClock
_G.gps = realGps

say("")
say(("%d passed, %d failed"):format(pass, fail))

_G.AERO_TOTALS = _G.AERO_TOTALS or {}
_G.AERO_TOTALS.remote = { pass = pass, fail = fail }
