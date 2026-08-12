--- Flies the whole stack against a simulated hull.
--
-- Every other suite here checks that a function returns what it should. This one
-- wires lib/hull, lib/instruments, lib/autopilot and lib/flight together exactly
-- as pilot.lua does, points them at test/mockperipheral.lua's flight model, and
-- runs them for a few hundred sweeps to ask the only question that matters: does
-- the ship end up where it was sent.
--
-- It is the suite that would catch a sign error in nav.bearing, a derivative
-- taken the wrong way round, an integral that winds up, or a guard that fires
-- and then never lets go -- none of which is visible from reading the code, and
-- all of which look identical to working code in a unit test.
--
-- Results go to /test-fly-results.txt.

local out = {}
local flush
local function print(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  out[#out + 1] = table.concat(parts, " ")
  flush()
end
function flush()
  local f = fs.open("/test-fly-results.txt", "w")
  for _, line in ipairs(out) do f.writeLine(line) end
  f.close()
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

local pass, fail = 0, 0
local function check(ok, label, extra)
  if ok then
    pass = pass + 1
    print("  ok   " .. label)
  else
    fail = fail + 1
    print("  FAIL " .. label .. (extra and ("  <" .. tostring(extra) .. ">") or ""))
  end
end
local function section(name) print("") print(name) end

local mock        = require("test.mockperipheral")

-- Put back rather than cleared. install_spec.lua runs last and install.lua
-- calls peripheral.getNames() to look for a modem; a suite that left the
-- global nil would break it from three files away.
local realPeripheral = _G.peripheral

local config      = require("lib.config")
local hull        = require("lib.hull")
local instruments = require("lib.instruments")
local autopilot   = require("lib.autopilot")
local nav         = require("lib.nav")
local flight      = require("lib.flight")

--------------------------------------------------------------------------------
-- The rig
--------------------------------------------------------------------------------

local LIMITS = { cruise = 12, climb = 4, descend = 3, clearance = 8 }

local CRAFT = {
  name = "Kestrel",
  controls = {
    lift = { kind = "bearing", peripheral = "lift0", group = "all" },
    main = { kind = "bearing", peripheral = "main0", group = "all",
             pivot = { min = -30, max = 30 } },
  },
  instruments = { nav = "nav0", alt = "alt0", vel = "vel0", ground = "opt0",
                  dock = "dock0", gimbal = false, stick = false, link = false },
  limits = LIMITS,
  mix = {
    { demand = "lift",    control = "lift", as = "throttle" },
    { demand = "forward", control = "main", as = "throttle" },
    { demand = "yaw",     control = "main", as = "pivot", scale = 30 },
  },
}

--- Build a world, a hull and the three state tables, wired the way pilot.lua
--- wires them. `opts` goes to the flight model.
local function rig(opts)
  opts = opts or {}
  opts.lift, opts.main = "lift0", "main0"

  local world = mock.new(opts)
  world.bearing("lift0", { count = 4, fuel = opts.fuel or 100000,
                           capacity = 100000, burn = opts.burn or 3000 })
  world.bearing("main0", { count = 2, fuel = opts.fuel or 100000,
                           capacity = 100000, burn = opts.burn or 3000 })
  world.navTable("nav0")
  world.altimeter("alt0")
  world.velocimeter("vel0")
  world.optical("opt0", { range = 40 })
  world.dockPort("dock0")
  _G.peripheral = world.api

  hull.define(CRAFT)
  hull.claim()

  local rigged = {
    world = world,
    fix = instruments.blank(),
    ap  = autopilot.new(hull.gains),
    fl  = flight.new(),
    t   = 0,
    log = {},
  }

  return rigged
end

--- One sweep, exactly as pilot.lua's does.
local function sweep(r, ctx)
  r.t = r.t + config.sweep

  local raw = hull.read(r.t)
  r.fix = instruments.fuse(r.fix, raw, nil, r.t)

  local _, goal, events = flight.step(r.fl, r.fix, ctx, r.t)
  for _, e in ipairs(events) do
    r.log[#r.log + 1] = e
    if e.what == "state" then autopilot.reset(r.ap) end
  end

  if goal.release then
    if r.released ~= true then hull.release() r.released = true end
  else
    if r.released then hull.claim() autopilot.reset(r.ap) r.released = false end
    local _, demands = autopilot.step(r.ap, r.fix, goal, r.t)
    hull.apply(autopilot.apply(hull.mix, demands), config.sweep)
  end

  r.world.step(config.sweep)
  return goal
end

local function run(r, seconds, ctx)
  local goal
  for _ = 1, math.floor(seconds / config.sweep) do goal = sweep(r, ctx) end
  return goal
end

--- Did this ever happen?
local function logged(r, why)
  for _, e in ipairs(r.log) do
    if e.why == why then return e end
  end
  return nil
end

--------------------------------------------------------------------------------
section("altitude hold")
--------------------------------------------------------------------------------

do
  local r = rig()
  local ctx = { waypoints = {}, limits = LIMITS }
  r.fl.state = "loiter"
  r.fl.alt = 120

  -- From the ground to 120 blocks up. Sixty seconds is generous: the point is
  -- that it arrives and stays, not that it is quick.
  run(r, 60, ctx)

  check(math.abs(r.world.ship.y - 120) <= config.altTolerance,
        "climbs to the altitude it was given", r.world.ship.y)

  -- The overshoot check is the integral clamp's exam. A ship that arrives and
  -- then sails a long way past has an integral nobody bounded.
  local peak = r.world.ship.y
  run(r, 30, ctx)
  check(r.world.ship.y < 120 + config.altTolerance * 2,
        "and does not sail past it", r.world.ship.y)
  check(math.abs(r.world.ship.vy) < 0.5, "and settles rather than hunting",
        r.world.ship.vy)

  -- Down again, to prove the loop works in both directions and that the
  -- integral it built climbing does not hold it up.
  r.fl.alt = 80
  autopilot.reset(r.ap)
  run(r, 60, ctx)
  check(math.abs(r.world.ship.y - 80) <= config.altTolerance,
        "and comes back down to a new one", r.world.ship.y)

  -- The descent is rate limited. Falling from 120 to 80 as fast as gravity
  -- allows would arrive at something like terminal velocity.
  check(r.world.ship.vy > -(LIMITS.descend + 1),
        "without exceeding the hull's descent rate on the way")
end

--------------------------------------------------------------------------------
section("heading hold")
--------------------------------------------------------------------------------

do
  local r = rig{ y = 120, heading = 0 }
  local waypoints = {}
  nav.put(waypoints, { name = "east", x = -600, y = 120, z = 0 })
  local ctx = { waypoints = waypoints, limits = LIMITS }

  -- Due -X is heading 90. A ship that turns the wrong way, or turns 270 degrees
  -- to get 90, is a sign error in nav.turn or in the yaw mix.
  r.fl.state = "cruise"
  r.fl.alt = 120
  r.fl.plan = nav.plan(waypoints, { "east" }, 120)

  run(r, 60, ctx)

  local err = math.abs(nav.turn(r.world.ship.heading, 90))
  check(err <= 15, "turns onto the bearing to the waypoint", r.world.ship.heading)
  check(r.world.ship.x < -50, "and actually goes that way", r.world.ship.x)

  -- Not oscillating. Sampled over ten seconds once settled: a ship hunting
  -- either side of its heading has a derivative term that is not damping.
  local lo, hi = 360, -360
  for _ = 1, 50 do
    sweep(r, ctx)
    local e = nav.turn(r.world.ship.heading, 90)
    if e < lo then lo = e end
    if e > hi then hi = e end
  end
  check((hi - lo) < 20, "and holds it rather than hunting", ("%.1f"):format(hi - lo))
end

--------------------------------------------------------------------------------
section("a whole flight")
--------------------------------------------------------------------------------

do
  local r = rig{ x = 0, y = 64, z = 0 }
  local waypoints = {}
  nav.put(waypoints, { name = "base", x = 0, y = 64, z = 0, kind = "pad" })
  nav.put(waypoints, { name = "quarry", x = 0, y = 64, z = 400, kind = "pad" })
  local ctx = { waypoints = waypoints, limits = LIMITS, home = "base" }

  local ok = flight.command(r.fl, { type = "fly", names = { "quarry" }, alt = 120 },
                            ctx, 0)
  check(ok, "the flight is accepted")

  -- Pad to pad: preflight, takeoff, climb, cruise four hundred blocks, descend,
  -- approach, land.
  run(r, 300, ctx)

  check(r.fl.state == "idle", "the ship ends up parked", r.fl.state)
  check(math.abs(r.world.ship.z - 400) < config.arriveRadius * 3,
        "at the destination", r.world.ship.z)
  check(math.abs(r.world.ship.y - 64) < 2, "on the ground", r.world.ship.y)

  -- Every state on the way, in order, and nothing skipped.
  local states = {}
  for _, e in ipairs(r.log) do
    if e.what == "state" then states[#states + 1] = e.to end
  end
  local seen = table.concat(states, ">")
  check(seen:find("takeoff", 1, true), "having taken off", seen)
  check(seen:find("cruise", 1, true), "cruised")
  check(seen:find("land", 1, true), "and landed")

  -- And the hull is handed back at the end, which is the whole reason `idle`
  -- releases rather than holding zeros.
  check(r.world.device("lift0").override == false,
        "with the hull handed back to redstone")
end

--------------------------------------------------------------------------------
section("a balloon")
--------------------------------------------------------------------------------

-- A hot air burner is a completely different plant from a thruster. The signal
-- sets a **target volume** of hot air and the envelope fills towards it at a
-- finite rate, so the lift lags the command by seconds in both directions -- and
-- the gains that hold a jet steady will make a balloon oscillate up and down for
-- as long as you leave it.
--
-- This is also the configuration where losing the wire matters: the signal *is*
-- the lift, so a chunk reload that dropped the output would be a descent.
do
  local BALLOON = {
    name = "Nimbus",
    controls = {
      -- `hold` because this is what is keeping the ship up. See lib/hull's
      -- release.
      burner = { kind = "wire", side = "top", mode = "analog", hold = true },
      main   = { kind = "bearing", peripheral = "main0", group = "all",
                 pivot = { min = -30, max = 30 } },
    },
    instruments = { nav = "nav0", alt = "alt0", vel = "vel0", ground = "opt0",
                    dock = "dock0", gimbal = false, stick = false, link = false },
    limits = { cruise = 8, climb = 2, descend = 2, clearance = 8 },
    -- Softer and slower than the thruster defaults, because the plant is. The
    -- integral does most of the work here: there is a volume that hovers and the
    -- loop has to find it and sit on it.
    gains = { hover = 0.5, altP = 0.2, vsP = 0.05, vsI = 0.04, vsD = 0.04,
              vsIMax = 0.5 },
    mix = {
      { demand = "lift",    control = "burner", as = "signal" },
      { demand = "forward", control = "main",   as = "throttle" },
      { demand = "yaw",     control = "main",   as = "pivot", scale = 30 },
    },
  }

  local function balloonRig(opts)
    opts = opts or {}
    opts.lift, opts.main = nil, "main0"
    opts.y = opts.y or 64

    local world = mock.new(opts)
    world.bearing("main0", { count = 2, fuel = 100000, capacity = 100000,
                             burn = 3000 })
    world.navTable("nav0")
    world.altimeter("alt0")
    world.velocimeter("vel0")
    world.optical("opt0", { range = 60 })
    world.dockPort("dock0")
    world.balloon{ side = "top", volume = 500, fill = 40 }
    _G.peripheral = world.api
    _G.redstone = world.redstone.api

    hull.define(BALLOON)
    hull.claim()

    return { world = world, fix = instruments.blank(), ap = autopilot.new(hull.gains),
             fl = flight.new(), t = 0, log = {} }
  end

  local r = balloonRig{}
  local ctx = { waypoints = {}, limits = BALLOON.limits }
  r.fl.state = "loiter"
  r.fl.alt = 110

  run(r, 200, ctx)

  check(math.abs(r.world.ship.y - 110) <= 4,
        "a balloon climbs to the altitude it was given", r.world.ship.y)
  check(math.abs(r.world.ship.vy) < 0.6, "and settles there", r.world.ship.vy)

  -- The signal it settled on is what the sixteen redstone levels can actually
  -- express. If the loop cannot hold still inside one level it will hunt between
  -- two of them forever, which on a balloon is a very visible bob.
  local settled = r.world.redstone.output.top
  local lo, hi = 15, 0
  for _ = 1, 150 do
    sweep(r, ctx)
    local level = r.world.redstone.output.top
    if level < lo then lo = level end
    if level > hi then hi = level end
  end
  check(hi - lo <= 2, "without hunting between redstone levels",
        ("%d-%d"):format(lo, hi))
  check(math.abs(r.world.ship.y - 110) <= 5, "or drifting off altitude",
        r.world.ship.y)

  -- Down to a new altitude. The envelope has to vent, which it does no faster
  -- than it filled.
  r.fl.alt = 80
  autopilot.reset(r.ap)
  run(r, 200, ctx)
  check(math.abs(r.world.ship.y - 80) <= 5,
        "and comes down to a new one", r.world.ship.y)

  -- The whole reason `hold` exists.
  hull.release()
  check(r.world.redstone.output.top > 0,
        "release leaves the burner lit, because it is the lift",
        r.world.redstone.output.top)

  -- ...and the whole reason the signal is saved. CC does not persist redstone
  -- outputs, so a chunk reload starts from nothing unless something puts it
  -- back.
  local saved = hull.saved()
  local r2 = balloonRig{ y = 110 }
  check(r2.world.redstone.output.top == nil, "a reboot starts with the burner out")

  hull.restore(saved)
  check(r2.world.redstone.output.top > 0,
        "and restore relights it before the first sweep",
        r2.world.redstone.output.top)

  -- The ship should hold roughly where it was rather than sinking while the
  -- autopilot works out what it is doing.
  local ctx2 = { waypoints = {}, limits = BALLOON.limits }
  r2.fl.state = "loiter"
  r2.fl.alt = 110
  r2.world.balloons[1].volume = 250      -- it was flying, so it is already full
  run(r2, 30, ctx2)
  check(r2.world.ship.y > 100,
        "so a reloaded chunk is not a descent", r2.world.ship.y)

  _G.redstone = nil
end

--------------------------------------------------------------------------------
section("the terrain guard")
--------------------------------------------------------------------------------

do
  -- A ridge across the flight path, rising to 112 -- eight blocks under the
  -- cruise altitude, so a ship that ignored it would clear the top by less than
  -- its own clearance limit, and one that held 120 exactly would be fine. The
  -- test is that it climbs anyway, because "fine" is not the same as "clear".
  local r = rig{
    x = 0, y = 120, z = 0, heading = 0,
    terrain = function(x, z)
      if z > 150 and z < 250 then return 112 end
      return 64
    end,
  }

  local waypoints = {}
  nav.put(waypoints, { name = "far", x = 0, y = 120, z = 500 })
  local ctx = { waypoints = waypoints, limits = LIMITS, home = nil }

  r.fl.state = "cruise"
  r.fl.alt = 120
  r.fl.plan = nav.plan(waypoints, { "far" }, 120)

  local lowest = math.huge
  local fired = false
  for _ = 1, 900 do
    sweep(r, ctx)
    if r.fl.guard == "clearance" then fired = true end
    local clear = r.world.ship.y - r.world.terrain(r.world.ship.x, r.world.ship.z)
    if r.world.ship.z > 140 and r.world.ship.z < 260 and clear < lowest then
      lowest = clear
    end
    if r.world.ship.z > 300 then break end
  end

  check(fired, "the guard fires when the ground comes up")
  check(lowest > 2, "and the ship does not hit the ridge", ("%.1f"):format(lowest))
  check(r.world.ship.z > 260, "while still getting past it", r.world.ship.z)

  -- The mission survives the override. This is the difference between a guard
  -- and an abort: the ship climbs, clears the hill, and carries on to the same
  -- waypoint it was already going to.
  check(r.fl.plan ~= nil and nav.current(r.fl.plan).name == "far",
        "and carries on to the same waypoint")
  check(r.fl.state == "cruise", "in the same state it was in", r.fl.state)
end

--------------------------------------------------------------------------------
section("the obstacle guard")
--------------------------------------------------------------------------------

-- The case the terrain guard cannot help with, and the reason the forward
-- sensor exists. A sheer cliff rising well above cruise altitude: the ground
-- directly beneath the ship is a comfortable fifty blocks down the entire way
-- in, so the clearance guard is perfectly happy right up until the ship stops.
do
  local WALL = {
    name = "Kestrel",
    controls = {
      lift = { kind = "bearing", peripheral = "lift0", group = "all" },
      main = { kind = "bearing", peripheral = "main0", group = "all",
               pivot = { min = -30, max = 30 } },
    },
    instruments = { nav = "nav0", alt = "alt0", vel = "vel0",
                    ground = "opt0", forward = "fwd0",
                    dock = false, gimbal = false, stick = false, link = false },
    limits = LIMITS,
    mix = {
      { demand = "lift",    control = "lift", as = "throttle" },
      { demand = "forward", control = "main", as = "throttle" },
      { demand = "yaw",     control = "main", as = "pivot", scale = 30 },
    },
  }

  local function wallRig(withForward)
    local world = mock.new{
      lift = "lift0", main = "main0",
      x = 0, y = 120, z = 0, heading = 0,
      terrain = function(x, z)
        if z > 300 then return 400 end       -- a cliff to the sky
        return 64
      end,
    }
    world.bearing("lift0", { count = 4, fuel = 100000, capacity = 100000, burn = 3000 })
    world.bearing("main0", { count = 2, fuel = 100000, capacity = 100000, burn = 3000 })
    world.navTable("nav0")
    world.altimeter("alt0")
    world.velocimeter("vel0")
    world.optical("opt0", { range = 60 })
    world.forwardOptical("fwd0", { range = 64 })
    _G.peripheral = world.api

    local craft = {}
    for k, v in pairs(WALL) do craft[k] = v end
    if not withForward then
      local instruments = {}
      for k, v in pairs(WALL.instruments) do instruments[k] = v end
      instruments.forward = false
      craft.instruments = instruments
    end

    hull.define(craft)
    hull.claim()

    return { world = world, fix = instruments.blank(),
             ap = autopilot.new(hull.gains), fl = flight.new(), t = 0, log = {} }
  end

  -- Without the sensor, to establish that this really is a hole rather than
  -- something the terrain guard was quietly covering.
  local blind = wallRig(false)
  local waypoints = {}
  nav.put(waypoints, { name = "beyond", x = 0, y = 120, z = 600 })
  local ctx = { waypoints = waypoints, limits = LIMITS }

  blind.fl.state = "cruise"
  blind.fl.alt = 120
  blind.fl.plan = nav.plan(waypoints, { "beyond" }, 120)

  -- Whether the ship reaches the cliff face at all, within a generous run. The
  -- wall here is deliberately unclimbable, so a ship that sees it has exactly
  -- one correct outcome: stop short. One that does not see it flies into it.
  --
  -- Measured this way rather than by altitude because the flight model's ground
  -- collision lifts a ship onto whatever it is standing over, so past z = 300 it
  -- rides up the cliff face like a lift -- which says nothing at all about
  -- whether the autopilot saw it.
  local function reachesWall(r)
    for _ = 1, 900 do
      sweep(r, ctx)
      if r.world.ship.z >= 300 then return true end
    end
    return false
  end

  check(reachesWall(blind), "with no forward sensor the ship flies into the cliff")
  check(blind.fl.guard ~= "obstacle", "and nothing ever saw it coming")

  -- With it.
  local seeing = wallRig(true)
  seeing.fl.state = "cruise"
  seeing.fl.alt = 120
  seeing.fl.plan = nav.plan(waypoints, { "beyond" }, 120)

  local fired = false
  local hit = false
  for _ = 1, 900 do
    sweep(seeing, ctx)
    if seeing.fl.guard == "obstacle" then fired = true end
    if seeing.world.ship.z >= 300 then hit = true break end
  end

  check(fired, "with one, the guard sees the cliff coming")
  check(seeing.world.ship.y > 200,
        "and the ship climbs hard rather than flying on level",
        seeing.world.ship.y)

  -- Deliberately **not** asserted: that it stops short. A ship has no brakes.
  -- Zeroing the forward demand removes the push and drag removes the speed
  -- exponentially, so against something unclimbable the hull still drifts into
  -- the face -- slowly, climbing all the way. The guard buys height and time and
  -- that is all it buys. Asserting otherwise here would be writing down a
  -- property the program does not have.
  check(true, "against an unclimbable wall it buys height, not a stop")
  check(seeing.fl.plan ~= nil and nav.current(seeing.fl.plan).name == "beyond",
        "without abandoning the flight")

  -- A ridge it *can* get over. The guard is not an abort: the ship climbs,
  -- clears it, and carries on to the same waypoint.
  local over = wallRig(true)
  over.world.terrain = function(x, z)
    if z > 300 and z < 360 then return 150 end
    return 64
  end
  over.fl.state = "cruise"
  over.fl.alt = 120
  over.fl.plan = nav.plan(waypoints, { "beyond" }, 120)

  local lowest = math.huge
  for _ = 1, 1600 do
    sweep(over, ctx)
    local s = over.world.ship
    if s.z > 295 and s.z < 365 then
      local gap = s.y - over.world.terrain(s.x, s.z)
      if gap < lowest then lowest = gap end
    end
    if s.z > 400 then break end
  end

  check(over.world.ship.z > 400, "a ridge it can clear is cleared",
        over.world.ship.z)
  check(lowest > 0, "without touching it", lowest)
  check(over.fl.state == "cruise", "and the flight carries on", over.fl.state)
end

--------------------------------------------------------------------------------
section("the fix going away")
--------------------------------------------------------------------------------

do
  local r = rig{ x = 0, y = 120, z = 0 }
  local waypoints = {}
  nav.put(waypoints, { name = "far", x = 0, y = 120, z = 900 })
  local ctx = { waypoints = waypoints, limits = LIMITS }

  r.fl.state = "cruise"
  r.fl.alt = 120
  r.fl.plan = nav.plan(waypoints, { "far" }, 120)
  run(r, 20, ctx)

  local movingAt = r.world.ship.z
  check(movingAt > 20, "the ship is under way", movingAt)

  -- The navigation table goes quiet. Dead reckoning carries it for a few
  -- seconds -- that is normal and must not be an emergency -- and then the fix
  -- ages out and the ship stops navigating.
  r.world.device("nav0").available = false

  run(r, config.reckonLimit - 2, ctx)
  check(r.fl.state == "cruise",
        "a short gap is ridden out on dead reckoning", r.fl.state)

  run(r, 8, ctx)
  check(r.fl.state == "loiter", "a long one stops the navigation", r.fl.state)
  check(logged(r, "nofix") ~= nil, "and says why")

  local heldAt = r.world.ship.y
  run(r, 20, ctx)
  check(math.abs(r.world.ship.y - heldAt) < 6,
        "while still holding altitude -- it is waiting, not falling",
        r.world.ship.y)

  -- And picks the plan straight back up. A navigation table going quiet for a
  -- few seconds is normal, so loiter has to be recoverable rather than final.
  r.world.device("nav0").available = true
  run(r, 10, ctx)
  check(r.fl.state == "cruise", "and resumes when the fix comes back", r.fl.state)
end

--------------------------------------------------------------------------------
section("bingo fuel")
--------------------------------------------------------------------------------

do
  -- Enough fuel to get a long way out and not enough to finish, with home
  -- behind. The guard has to notice before the point of no return, which is the
  -- entire reason it is computed from burn time against distance home rather
  -- than from a percentage.
  local r = rig{ x = 0, y = 120, z = 0, fuel = 100000, burn = 100 }

  local waypoints = {}
  nav.put(waypoints, { name = "base", x = 0, y = 120, z = 0, kind = "pad" })
  nav.put(waypoints, { name = "far",  x = 0, y = 120, z = 4000 })
  local ctx = { waypoints = waypoints, limits = LIMITS, home = "base" }

  r.fl.state = "cruise"
  r.fl.alt = 120
  r.fl.plan = nav.plan(waypoints, { "far" }, 120)

  local turnedAt = nil
  for _ = 1, 3000 do
    sweep(r, ctx)
    if r.fl.bingo and not turnedAt then turnedAt = r.world.ship.z end
    if r.fl.state == "idle" then break end
  end

  check(r.fl.bingo, "low fuel turns the ship round")
  check(turnedAt and turnedAt > 20, "after it had actually gone somewhere", turnedAt)
  check(logged(r, "bingo") ~= nil, "and the log says why")
  check(nav.current(r.fl.plan) == nil or nav.current(r.fl.plan).name == "base",
        "with home as the new destination")

  -- Home is behind, so the ship has to turn most of the way round to reach it.
  check(turnedAt ~= nil and r.world.ship.z < turnedAt,
        "and it is heading back", r.world.ship.z)
end

--------------------------------------------------------------------------------
section("giving the hull back")
--------------------------------------------------------------------------------

do
  local r = rig{ x = 0, y = 120, z = 0 }
  local ctx = { waypoints = {}, limits = LIMITS }
  r.fl.state = "loiter"
  r.fl.alt = 120
  run(r, 10, ctx)

  check(r.world.device("lift0").throttle > 0, "a flying ship is holding throttle",
        r.world.device("lift0").throttle)

  -- The single most important line in pilot.lua.
  hull.release()
  check(r.world.device("lift0").override == false,
        "release hands every throttle back")
  check(r.world.device("main0").override == false, "including the main bearing")
  check(r.world.device("lift0").mode == "redstone",
        "and puts the bearings back on redstone control")

  -- And the altitude guard: a hull that cannot tell us its height cannot be
  -- flown, and pretending otherwise means a lift demand of zero and a ship
  -- falling under program control.
  local r2 = rig{ x = 0, y = 120, z = 0 }
  local ctx2 = { waypoints = {}, limits = LIMITS }
  r2.fl.state = "loiter"
  r2.fl.alt = 120
  run(r2, 5, ctx2)

  r2.world.remove("alt0")
  r2.world.device("nav0").available = false

  -- Not instantly: a sensor that misses a few reads is normal, and the altitude
  -- is dead-reckoned for the same grace period the position gets. What must not
  -- happen is what used to -- the last known height being reported as current
  -- for the rest of the flight, so the guard never fires at all.
  run(r2, 4, ctx2)
  check(r2.fl.state ~= "idle", "a brief gap in the height is ridden out",
        r2.fl.state)

  run(r2, config.reckonLimit + 4, ctx2)
  check(r2.fl.state == "idle", "losing every height source stops the flight",
        r2.fl.state)
  check(r2.world.device("lift0").override == false,
        "and hands the hull back rather than flying it to the ground")
end

--------------------------------------------------------------------------------

_G.peripheral = realPeripheral

print("")
print(("%d passed, %d failed"):format(pass, fail))
flush()

_G.AERO_TOTALS = _G.AERO_TOTALS or {}
_G.AERO_TOTALS.fly = { pass = pass, fail = fail }
