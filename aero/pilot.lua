--- The flight computer. Runs on a computer riding the contraption.
--
-- Owns the control loop and the whole flight plan. The server and the pocket
-- computer only ever set goals: if both vanish -- and they will, because chunks
-- unload and modems have a range -- this program keeps flying the plan it
-- already has and lands itself at the end of it.
--
-- Two loops under parallel.waitForAny:
--
--   flyTask       the control loop, driven by a timer and nothing else
--   listenerTask  orders in, telemetry out
--
-- Unlike redstone/node.lua there is no event to react to. Nothing in CC raises
-- an event because a ship has drifted off heading, so the timer is the whole
-- clock and every derivative in lib/instruments is taken across it.
--
-- ## The release epilogue
--
-- Every actuator write is an override that outlives this program. A pilot that
-- exited with the lift bearing at 0.8 would leave a ship climbing with nobody
-- flying it, for as long as the chunk stays loaded. So `hull.release` runs on
-- **every** exit path -- clean stop, terminate, uncaught error, update -- which
-- is why the whole of the run is inside one pcall and the release is after it
-- rather than at the end of the loop.
--
-- Note the boot order below: release comes *before* the listener starts, not
-- after. A ship rebooting mid-flight comes back with whatever override survived
-- the restart still held, and claiming the hull on top of that would have the
-- first sweep's PID reacting to a throttle it did not set.

local config      = require("lib.config")
local net         = require("lib.net")
local state       = require("lib.state")
local hull        = require("lib.hull")
local instruments = require("lib.instruments")
local autopilot   = require("lib.autopilot")
local nav         = require("lib.nav")
local flight      = require("lib.flight")

local pilot = {
  fix       = instruments.blank(),
  raw       = {},
  ap        = nil,       -- autopilot state
  fl        = nil,       -- flight state
  waypoints = {},        -- cached from the server, see below
  home      = nil,
  server    = nil,       -- computer id of the server, when one has spoken
  serverAt  = -math.huge,
  update    = nil,       -- set by the listener, run after parallel returns
  stop      = false,
  events    = {},        -- to be sent, oldest first
  gpsAt     = -math.huge,
  gps       = nil,
  lastState = nil,
}

local function now() return os.clock() end

local function label()
  return os.getComputerLabel() or hull.name or ("ship-" .. os.getComputerID())
end

--------------------------------------------------------------------------------
-- Screen
--------------------------------------------------------------------------------

-- A pilot has no UI worth the name -- nobody is standing at this computer while
-- the ship is flying, and the pocket computer is where you look. What it does
-- have is enough on screen to answer "is this thing alive" when you climb up to
-- it, which is a different question from the one the dashboard answers.

local function colour(fg, bg)
  if term.isColour and term.isColour() then
    if fg then term.setTextColour(fg) end
    if bg then term.setBackgroundColour(bg) end
  end
end

local function redraw()
  local w, h = term.getSize()
  colour(colours.white, colours.black)
  term.clear()

  colour(colours.black, term.isColour and term.isColour() and colours.cyan or colours.white)
  term.setCursorPos(1, 1)
  term.clearLine()
  term.write((" %s  %s"):format(label(), pilot.fl.state):sub(1, w))

  colour(colours.white, colours.black)

  local fix = pilot.fix
  local lines = {
    ("alt %s  vs %s"):format(
      fix.alt and ("%.0f"):format(fix.alt) or "--",
      fix.vs and ("%+.1f"):format(fix.vs) or "--"),
    ("hdg %s  spd %s"):format(
      fix.heading and ("%.0f"):format(fix.heading) or "--",
      ("%.1f"):format(fix.speed or 0)),
    ("pos %s"):format(fix.x and ("%.0f %.0f %.0f"):format(fix.x, fix.y or 0, fix.z) or "--"),
    ("fix %s"):format(instruments.age(fix, now())),
    ("tilt %s %s"):format(
      fix.pitch and ("%+.0f"):format(fix.pitch) or "--",
      fix.roll and ("%+.0f"):format(fix.roll) or "--"),
    ("why %s"):format(tostring(pilot.fl.why)),
  }

  local leg = nav.current(pilot.fl.plan)
  if leg then
    lines[#lines + 1] = ("leg %s %.0fm"):format(leg.name, nav.distance(fix, leg) or 0)
  end
  if pilot.fl.guard then
    lines[#lines + 1] = "GUARD " .. pilot.fl.guard
  end

  -- Only the signals that are actually saying something. A list of six inputs
  -- all reading off is a screen full of nothing, and this screen exists to
  -- answer "is this thing alive" from a ladder.
  local live = {}
  for _, s in ipairs(hull.inputs) do
    local v = fix.signals and fix.signals[s.name]
    if v == true then live[#live + 1] = s.name
    elseif type(v) == "number" and v > 0 then
      live[#live + 1] = ("%s=%d"):format(s.name, v)
    end
  end
  if #live > 0 then lines[#lines + 1] = "rs  " .. table.concat(live, " ") end
  for _, why in ipairs(hull.problems) do lines[#lines + 1] = why end

  for i, line in ipairs(lines) do
    if i + 1 > h then break end
    term.setCursorPos(1, i + 1)
    term.write(line:sub(1, w))
  end
end

--------------------------------------------------------------------------------
-- Telemetry
--------------------------------------------------------------------------------

local function telemetry()
  local fix = pilot.fix
  local plan = flight.describe(pilot.fl, fix)

  return {
    type   = "tlm",
    label  = label(),
    ship   = hull.name,
    pos    = fix.x and { x = fix.x, y = fix.y, z = fix.z } or nil,
    alt    = fix.alt,
    heading = fix.heading,
    speed  = fix.speed,
    vs     = fix.vs,
    clearance = fix.clearance,
    docked = fix.docked,
    fuel   = fix.fuel,
    capacity = fix.capacity,
    burn   = fix.burn,
    source = fix.source,
    fixAge = fix.fixAge,
    signals = fix.signals,
    pitch  = fix.pitch,
    roll   = fix.roll,
    beacon = fix.beacon,
    beaconRange = fix.beaconRange,
    flight = plan,
    goal   = pilot.fl.goal,
    faults = fix.faults,
    problems = hull.problems,
  }
end

--- One line for the log, sent when it happens rather than waiting for the next
--- heartbeat. The server holds the log; the pilot only reports.
local function event(entry)
  entry.type = "event"
  entry.label = label()
  entry.pos = pilot.fix.x and
    { x = pilot.fix.x, y = pilot.fix.y, z = pilot.fix.z } or nil
  net.broadcast(entry)
end

--------------------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------------------

--- What is worth surviving a reboot, and what deliberately is not.
--
-- The plan is: a ship that wakes up over open ocean with no idea where it was
-- going is a ship that is lost. The waypoint cache is, because the point of it
-- is flying to a named pad with the base's chunk unloaded. The autopilot's
-- integrals are not -- they describe a hull that was moving, and restoring them
-- onto one that has been sitting still is a kick on the first sweep.
local function save()
  state.data.plan  = pilot.fl.plan
  state.data.state = pilot.fl.state
  state.data.alt   = pilot.fl.alt
  state.data.bingo = pilot.fl.bingo
  state.data.dockTo = pilot.fl.dockTo
  state.data.waypoints = pilot.waypoints
  state.data.home  = pilot.home

  -- The redstone signals we are holding. CC does not persist a computer's
  -- outputs, so on a balloon this is the difference between a chunk reloading
  -- and a chunk reloading with the burner out.
  state.data.wires = hull.saved()
  state.mark()
end

local function restore()
  local d = state.data or {}

  pilot.waypoints = type(d.waypoints) == "table" and d.waypoints or {}
  pilot.home = d.home

  if type(d.plan) == "table" then
    pilot.fl.plan = d.plan
    pilot.fl.alt  = d.alt
    pilot.fl.bingo = d.bingo == true
    pilot.fl.dockTo = d.dockTo

    -- A ship that was flying when the chunk unloaded comes back **loitering**,
    -- not cruising. It has no fix yet, it has no idea how long it was away, and
    -- the first thing it would do at cruise is push the throttle up on a
    -- position several minutes stale. Loiter costs a few seconds and lets
    -- lib/flight pick the plan back up the moment the navigation table answers.
    pilot.fl.state = "loiter"
    pilot.fl.why   = "rebooted"
  end
end

--------------------------------------------------------------------------------
-- The control loop
--------------------------------------------------------------------------------

--- A GPS fix, at most once a second.
--
-- gps.locate blocks for its timeout while it waits for satellites to answer,
-- and a control loop that stopped for a fifth of a second every sweep would not
-- be a control loop. The timeout is deliberately shorter than the sweep so a
-- ship out of range of the constellation -- which is most of them, most of the
-- time -- costs almost nothing.
local function gpsFix(t)
  if (t - pilot.gpsAt) < 1 then return pilot.gps end
  pilot.gpsAt = t

  if not gps then pilot.gps = nil return nil end
  local ok, x, y, z = pcall(gps.locate, 0.15)
  if ok and x then
    pilot.gps = { x = x, y = y, z = z }
  else
    pilot.gps = nil
  end
  return pilot.gps
end

local function sweep(t, dt)
  pilot.raw = hull.read(t)
  pilot.fix = instruments.fuse(pilot.fix, pilot.raw, gpsFix(t), t)

  local ctx = {
    waypoints = pilot.waypoints,
    limits    = hull.limits,
    home      = pilot.home,
    cruiseAlt = pilot.fl.alt,
  }

  local _, goal, events = flight.step(pilot.fl, pilot.fix, ctx, t)

  for _, e in ipairs(events) do
    event(e)
    -- The autopilot's memory belongs to the state it was accumulated in.
    -- Carrying a climb integral into a descent is a ship that keeps going up for
    -- several seconds after being told to come down.
    if e.what == "state" then autopilot.reset(pilot.ap) end
  end

  if goal.release then
    -- Not "hold everything at zero". A parked or unflyable ship should behave
    -- exactly like one with no computer on it, which is what release means.
    if pilot.lastState ~= "released" then
      hull.release()
      pilot.lastState = "released"
    end
    return
  end

  if pilot.lastState == "released" then
    hull.claim()
    autopilot.reset(pilot.ap)
    pilot.lastState = "flying"
  end

  local _, demands = autopilot.step(pilot.ap, pilot.fix, goal, t)
  hull.apply(autopilot.apply(hull.mix, demands), dt)

  save()
  state.tick(t)
end

local function flyTask()
  local last = now()
  local beat = -math.huge
  local timer = os.startTimer(config.sweep)

  while not pilot.stop do
    local event_, id = os.pullEvent()

    if event_ == "timer" and id == timer then
      local t = now()
      local dt = t - last
      last = t
      timer = os.startTimer(config.sweep)

      sweep(t, dt)

      if (t - beat) >= config.heartbeat then
        beat = t
        net.broadcast(telemetry())
        redraw()
      end

    elseif event_ == "terminate" then
      -- Caught rather than left to unwind, so the ship is put down instead of
      -- abandoned wherever it happened to be. The epilogue after parallel still
      -- releases the hull; this makes the descent a controlled one first.
      pilot.stop = true
    end
  end
end

--------------------------------------------------------------------------------
-- The listener
--------------------------------------------------------------------------------

local function sanitise(name)
  return tostring(name or ""):gsub("[^%w%-_]", ""):sub(1, 24)
end

local function handle(from, msg)
  local ctx = {
    waypoints = pilot.waypoints,
    limits    = hull.limits,
    home      = pilot.home,
    cruiseAlt = pilot.fl.alt,
    fix       = pilot.fix,
  }

  ------------------------------------------------------------------------------
  if msg.type == "net" then
    -- The server's broadcast. Waypoints are cached to disk on arrival, so a ship
    -- already airborne when the base unloads can still be told to fly to a named
    -- pad -- and can still find its way home under the bingo guard.
    if type(msg.waypoints) == "table" then
      pilot.waypoints = msg.waypoints
    end
    pilot.home = msg.home or pilot.home
    pilot.server, pilot.serverAt = from, now()
    save()
    return
  end

  ------------------------------------------------------------------------------
  if msg.type == "hull?" then
    net.send(from, { type = "hull", label = label(), hull = hull.describe() })
    return
  end

  ------------------------------------------------------------------------------
  if msg.type == "tune" then
    if type(msg.gains) ~= "table" then
      net.send(from, { type = "error", reason = "no gains" })
      return
    end
    pilot.ap.gains = autopilot.gains(msg.gains)
    autopilot.reset(pilot.ap)
    net.send(from, { type = "ack", of = "tune" })
    event({ what = "tune", to = "gains", why = "manual" })
    return
  end

  ------------------------------------------------------------------------------
  if msg.type == "rename" then
    -- Allowed in flight. Nothing on disk changes and no control is touched -- it
    -- is the computer's label, which is also why it survives an update and a
    -- replacement disk. `update` is a different matter, below.
    local name = sanitise(msg.name)
    if name == "" then
      net.send(from, { type = "error", reason = "bad name" })
      return
    end
    os.setComputerLabel(name)

    -- ...and onto the hull's own nameplate, if it has one. The label is what
    -- the network uses; the plate is the same name made visible from outside,
    -- which is the only place it helps while you are standing on the ground
    -- watching the thing come in.
    hull.setPlateName(name)

    net.send(from, { type = "ack", of = "rename" })
    return
  end

  ------------------------------------------------------------------------------
  if msg.type == "update" then
    if flight.busy(pilot.fl) then
      net.send(from, { type = "error", reason = "flying" })
      return
    end
    pilot.update = { branch = msg.branch, repo = msg.repo }
    pilot.stop = true
    net.send(from, { type = "ack", of = "update" })
    return
  end

  ------------------------------------------------------------------------------
  -- Everything else is a flight order.
  local ok, result = flight.command(pilot.fl, msg, ctx, now())
  if not ok then
    net.send(from, { type = "error", reason = result })
    return
  end

  autopilot.reset(pilot.ap)
  save()
  state.flush(now())     -- a new plan is worth one disk hit immediately
  net.send(from, { type = "ack", of = msg.type })
  if result then event(result) end
end

local function listenerTask()
  while not pilot.stop do
    local e, a, b, c, d = os.pullEvent()

    if e == "terminate" then
      pilot.stop = true
    else
      local from, msg = net.decode(e, a, b, c, d)
      if from then
        local ok, why = pcall(handle, from, msg)
        if not ok then
          -- A malformed order must not take the ship down with it. The control
          -- loop is in the other coroutine and keeps flying while this is
          -- reported.
          net.send(from, { type = "error", reason = tostring(why) })
        end
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

local problems = select(2, hull.load())

state.open(config.stateFile, {})

pilot.ap = autopilot.new(hull.gains)
pilot.fl = flight.new()
restore()

-- Before the listener, before the first telemetry, before anything claims
-- anything: put the hull back where a hull with no computer would be. A reboot
-- mid-flight comes back with whatever override survived the restart still held,
-- and every number below is computed on the assumption that we know what the
-- controls are set to.
hull.release()
pilot.lastState = "released"

-- ...and then put the wires back, which is the opposite thing and is not a
-- contradiction. A peripheral override survives a reboot and has to be dropped;
-- a redstone output does *not* survive one and has to be restored. On a ship
-- held up by a hot air burner, the second is what stops a chunk reload being a
-- descent: the balloon's target volume is a redstone signal, and a signal that
-- came back at zero is a balloon told to empty.
hull.restore(state.data.wires)

if not net.open() then
  print("No wireless modem. Flying blind and alone.")
end

net.broadcast(telemetry())
redraw()

-- The whole run in one pcall, so that an uncaught error anywhere -- in a control
-- law, in a peripheral that vanished, in a message from a version of the pocket
-- computer this one has never met -- still reaches the release below.
local ok, err = pcall(parallel.waitForAny, flyTask, listenerTask)

hull.release()
state.flush(now())
net.broadcast({ type = "tlm", label = label(), gone = true })

term.setCursorPos(1, 1)
colour(colours.white, colours.black)
term.clear()

if not ok then
  print("pilot stopped: " .. tostring(err))
  print("The hull has been handed back to redstone.")
end

for _, why in ipairs(problems or {}) do print(why) end

-- After parallel has returned, never from inside the listener. Swapping
-- lib/hull.lua underneath a live control loop is the worst thing this program
-- could do to itself, and `flight.busy` has already refused it in the air.
if pilot.update then
  shell.run("/update.lua", pilot.update.branch or "", pilot.update.repo or "")
end
