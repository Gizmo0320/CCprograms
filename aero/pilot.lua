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
local sable       = require("lib.sable")
local instruments = require("lib.instruments")
local autopilot   = require("lib.autopilot")
local nav         = require("lib.nav")
local flight      = require("lib.flight")
local terrain     = require("lib.terrain")
local ui          = require("lib.ui")

local pilot = {
  fix       = instruments.blank(),
  raw       = {},
  ap        = nil,       -- autopilot state
  fl        = nil,       -- flight state
  waypoints = {},        -- cached from the server, see below
  terrain   = nil,       -- the fleet's height map, cached the same way
  home      = nil,
  server    = nil,       -- computer id of the server, when one has spoken
  serverAt  = -math.huge,
  update    = nil,       -- set by the listener, run after parallel returns
  stop      = false,
  events    = {},        -- to be sent, oldest first
  gpsAt     = -math.huge,
  target    = nil,       -- what the data link was last told, to avoid rewriting it
  gps       = nil,
  lastState = nil,
}

local function now() return os.clock() end

local function label()
  return os.getComputerLabel() or hull.name or ("ship-" .. os.getComputerID())
end

--------------------------------------------------------------------------------
-- The cockpit
--------------------------------------------------------------------------------

-- Nobody is standing at this computer while the ship is flying -- the pocket is
-- where you look from the ground. What this is for is the moment you climb up to
-- a ship that is sitting somewhere it should not be, and want to know what it
-- thinks is going on. So it is an instrument panel rather than a log: the state,
-- what it is being told to do, and every reading that could explain the
-- difference.
--
-- Laid out for a 51x19 computer and folded down to a 26x20 pocket. Colour is
-- used to say things a glance can catch -- red guard, orange loiter -- and never
-- to say something the text does not.

local function cockpitWide(w, h)
  local fix = pilot.fix
  local goal = pilot.fl.goal or {}
  local leg = nav.current(pilot.fl.plan)

  -- Left: the artificial horizon, which is the only instrument here that is
  -- read as a picture rather than a number.
  ui.panel(1, 2, 17, 8, "attitude", ui.theme.panel)
  ui.horizon(1, 3, 17, 7, fix.pitch, fix.roll)

  ui.at(1, 10, ui.fit(("tilt %s  spin %s")
    :format(ui.num(fix.tilt), ui.num(fix.spin)), 17, true),
    (fix.tilt and fix.tilt > 25) and ui.theme.bad or ui.theme.dim)

  -- Middle: altitude tape, with the target marked.
  ui.panel(19, 2, 11, 8, "alt", ui.theme.panel)
  local rows = ui.tapeRows(fix.alt, 7, 10)
  for i, row in ipairs(rows) do
    local target = goal.alt
    local marked = target and math.abs(row.value - target) < 5
    ui.at(20, 2 + i,
          ui.fit(("%s%5d"):format(row.here and ">" or (marked and "*" or " "),
                                  row.value), 9, true),
          row.here and ui.theme.select or (marked and ui.theme.ok or ui.theme.dim))
  end

  ui.at(19, 10, ui.fit(("vs %s"):format(ui.num(fix.vs, "%+.1f")), 11, true),
        ui.theme.dim)

  -- Right: everything that is a number and nothing else.
  ui.panel(31, 2, w - 30, 8, "flight", ui.theme.panel)

  local right = {
    { "state", pilot.fl.state, ui.stateColour[pilot.fl.state] or ui.theme.text },
    { "why", tostring(pilot.fl.why), ui.theme.dim },
    { "speed", ("%.1f / %s"):format(fix.speed or 0, ui.num(goal.speed)), ui.theme.text },
    { "hdg", ("%s / %s"):format(ui.num(fix.heading), ui.num(goal.heading)), ui.theme.text },
    { "clear", ui.num(fix.clearance), ui.theme.text },
    { "ahead", ui.num(fix.ahead), fix.ahead and ui.theme.warn or ui.theme.dim },
    { "leg", leg and ("%s %sm"):format(leg.name, ui.num(nav.distance(fix, leg)))
             or "-", ui.theme.text },
  }

  for i, entry in ipairs(right) do
    if 2 + i > 9 then break end
    ui.at(32, 2 + i, ui.fit(entry[1], 6, true), ui.theme.dim)
    ui.at(38, 2 + i, ui.fit(entry[2], w - 38, true), entry[3])
  end

  return 11
end

local function cockpitNarrow(w, h)
  local fix = pilot.fix
  local goal = pilot.fl.goal or {}

  ui.at(1, 2, ui.fit(("alt %s / %s"):format(ui.num(fix.alt), ui.num(goal.alt)),
        w, true), ui.theme.text)
  ui.at(1, 3, ui.fit(("vs  %s   tilt %s"):format(ui.num(fix.vs, "%+.1f"),
        ui.num(fix.tilt)), w, true), ui.theme.dim)
  ui.at(1, 4, ui.fit(("hdg %s / %s"):format(ui.num(fix.heading),
        ui.num(goal.heading)), w, true), ui.theme.text)
  ui.at(1, 5, ui.fit(("spd %s   ahead %s"):format(ui.num(fix.speed, "%.1f"),
        ui.num(fix.ahead)), w, true), ui.theme.dim)
  ui.at(1, 6, ui.compassStrip(fix.heading, w), ui.theme.accent)

  return 8
end

local function redraw()
  local w, h = term.getSize()
  local fix = pilot.fix

  ui.paint(ui.theme.text, ui.theme.bg)
  term.clear()

  -- The header says the two things worth knowing from across a room: which ship
  -- this is, and whether it is flying itself.
  local banner = pilot.fl.guard and ui.guardColour(pilot.fl.guard)
    or (ui.stateColour[pilot.fl.state] or ui.theme.accent)
  ui.fill(1, 1, w, 1, banner)
  ui.at(1, 1, ui.fit((" %s  %s%s"):format(label(), pilot.fl.state,
        pilot.fl.guard and ("  " .. pilot.fl.guard:upper()) or ""), w, true),
        ui.theme.bg, banner)

  local y = (w >= 44) and cockpitWide(w, h) or cockpitNarrow(w, h)

  -- Controls, as bars. What the autopilot is actually asking the hull for is
  -- the one thing that is invisible from outside and explains most of the
  -- surprises -- a ship sitting on the ground with the lift bearing at full is
  -- a different problem from one with it at nothing.
  for _, name in ipairs(hull.order) do
    if y > h - 1 then break end
    local held = hull.current[name] or {}
    local value = held.throttle or held.signal or held.left
    if value ~= nil then
      ui.bar(1, y, math.min(w, 24), value, 0, 1, ui.theme.ok,
             (" %s %3d%%"):format(ui.fit(name, 8, true), value * 100))
      y = y + 1
    end
  end

  -- Fuel, when the hull reports any.
  if fix.capacity and fix.capacity > 0 and y <= h - 1 then
    local low = fix.burn and fix.burn < 120
    ui.bar(1, y, math.min(w, 24), fix.fuel, 0, fix.capacity,
           low and ui.theme.bad or ui.theme.cold,
           (" fuel %ss"):format(ui.num(fix.burn)))
    y = y + 1
  end

  -- The bottom line is the fix, because everything above it is worthless if the
  -- ship does not know where it is.
  local source = instruments.age(fix, now())
  ui.at(1, h, ui.fit((" %s  %s%s"):format(source,
        fix.x and ("%d %d %d"):format(fix.x, fix.y or 0, fix.z) or "no position",
        fix.assembled and "" or "  UNASSEMBLED"), w, true),
        fix.usable and ui.theme.dim or ui.theme.bad,
        ui.theme.bg)

  -- Anything actually wrong goes over the top of the panel, because a warning
  -- nobody sees is not a warning.
  local rowY = h - 1
  for _, why in ipairs(hull.problems) do
    if rowY <= y then break end
    ui.at(1, rowY, ui.fit(why, w, true), ui.theme.warn, ui.theme.bg)
    rowY = rowY - 1
  end

  ui.paint(ui.theme.text, ui.theme.bg)
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
    homing = fix.homing,
    homingRange = fix.homingRange,
    tilt   = fix.tilt,
    spin   = fix.spin,
    pressure = fix.pressure,
    linked = fix.linked,
    ahead  = fix.ahead,
    mass   = fix.mass,
    assembled = fix.assembled,
    commander     = pilot.fl.commander,
    commanderName = pilot.fl.commanderName,
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
  state.data.terrain = pilot.terrain

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
  if type(d.terrain) == "table" then pilot.terrain = terrain.load(d.terrain) end

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

  -- CC: Sable, when there is one and the contraption is assembled. Merged into
  -- the same raw table rather than passed separately, so lib/instruments has one
  -- argument to reason about and the preference order lives in one place.
  pilot.raw.sable = sable.read()
  pilot.fix = instruments.fuse(pilot.fix, pilot.raw, gpsFix(t), t)

  local ctx = {
    waypoints = pilot.waypoints,
    limits    = hull.limits,
    home      = pilot.home,
    cruiseAlt = pilot.fl.alt,
    terrain   = pilot.terrain,
  }

  local _, goal, events = flight.step(pilot.fl, pilot.fix, ctx, t)

  -- Publish where we are going to the data link, so gyros and guided bearings
  -- on the contraption aim at the same place the autopilot is flying to rather
  -- than at whatever was last set by hand. Only on a change: it is a peripheral
  -- call and the destination changes once a leg, not five times a second.
  local leg = nav.current(pilot.fl.plan)
  local target = leg and (leg.name .. ":" .. tostring(leg.x) .. "," .. tostring(leg.z))
  if target ~= pilot.target then
    pilot.target = target
    if leg then
      hull.setTarget(leg.x, leg.y or (pilot.fl.alt or 0), leg.z)
    else
      hull.clearTarget()
    end
  end

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

    -- Who is asking. `sender` is set by the tower when it relays and carries the
    -- pocket computer that originally sent the order, so the conn belongs to the
    -- person holding it rather than to the tower that passed it on.
    --
    -- Deliberately not called `by`: that is the relative altitude on an `alt`
    -- order, and sharing the name meant `alt by = -20` set the sender to -20 and
    -- the ship refused its own commander his own order.
    from = msg.sender or from,
    who  = msg.who,
    terrain = pilot.terrain,
  }

  ------------------------------------------------------------------------------
  if msg.type == "net" then
    -- The server's broadcast. Waypoints are cached to disk on arrival, so a ship
    -- already airborne when the base unloads can still be told to fly to a named
    -- pad -- and can still find its way home under the bingo guard.
    if type(msg.waypoints) == "table" then
      pilot.waypoints = msg.waypoints
    end
    if type(msg.terrain) == "table" then
      -- Cached like the waypoints, and for the same reason: a ship that has it
      -- can check its own route with the tower's chunk unloaded.
      pilot.terrain = terrain.load(msg.terrain)
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

    -- Tuning is flying. Two people moving the same gain in opposite directions
    -- would be the conn problem with a slower fuse.
    local may, held = flight.mayCommand(pilot.fl, ctx.from, now())
    if not may then
      net.send(from, { type = "error", reason = held })
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

    -- ...and onto the physics object itself, which is what Sable shows for the
    -- contraption. Three places for one name looks like a lot until you are
    -- looking for a particular ship among six.
    sable.setName(name)

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
ui.paint(ui.theme.text, ui.theme.bg)
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
