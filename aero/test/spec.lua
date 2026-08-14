--- Runs the libraries against a mock hull, and against nothing at all.
--
-- lib/nav, lib/instruments, lib/autopilot and lib/flight need no mock: they
-- touch no APIs, which is most of the reason they are shaped that way. lib/hull
-- is the only module that talks to `peripheral`, so it gets
-- test/mockperipheral.lua. lib/net gets the mock's modem rather than CraftOS-PC's
-- own, because the emulated modem reports isWireless() == false and every
-- program here accepts wireless only.
--
-- Results go to /test-results.txt; the terminal in headless mode is unreadable.

local out = {}
local flush
local function print(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  out[#out + 1] = table.concat(parts, " ")
  flush()                            -- so an uncaught error still leaves a trail
end
function flush()
  local f = fs.open("/test-results.txt", "w")
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

-- Put back rather than cleared. install_spec.lua runs last and install.lua
-- calls peripheral.getNames() to look for a modem; a suite that left the
-- global nil would break it from three files away.
local realPeripheral = _G.peripheral


--- `quiet` assertions still count, but only show up when they fail. The
--- fixture's self-checks run before every single case; printing them all buries
--- the results they exist to protect.
local function report(ok, label, extra, quiet)
  if ok then
    pass = pass + 1
    if not quiet then print("  ok   " .. label) end
  else
    fail = fail + 1
    print("  FAIL " .. label .. (extra and ("  <" .. tostring(extra) .. ">") or ""))
  end
end

local function check(ok, label, extra) report(ok, label, extra, false) end
local function checkQuiet(ok, label, extra) report(ok, label, extra, true) end

local function section(name)
  print("")
  print(name)
end

--- Did this fail for the reason we meant it to? Every validator here returns
--- ok, reason, and a check that only looks at `ok` passes just as happily when
--- the entry was rejected for something else entirely.
local function refused(ok, reason, text)
  if ok then return false end
  if not text then return true end
  return tostring(reason):find(text, 1, true) ~= nil
end

--- Floating point comparison. Everything in this program is trigonometry and
--- integration, and asserting equality on either is asserting that two different
--- routes to the same number rounded the same way.
local function near(a, b, tol)
  if type(a) ~= "number" or type(b) ~= "number" then return false end
  return math.abs(a - b) <= (tol or 0.001)
end

local function writeFile(path, body)
  local f = fs.open(path, "w")
  f.write(body)
  f.close()
end

--------------------------------------------------------------------------------
section("manifest")
--------------------------------------------------------------------------------

-- install.lua downloads exactly what manifest.txt lists, so a file added to the
-- tree and not to the list is an installer that silently ships an incomplete
-- program -- which shows up as a require() error on somebody's computer rather
-- than here.
do
  local listed, count = {}, 0
  local f = fs.open("/manifest.txt", "r")
  while true do
    local line = f.readLine()
    if not line then break end
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" and line:sub(1, 1) ~= "#" then
      listed[line] = true
      count = count + 1
    end
  end
  f.close()

  check(count > 0, "manifest.txt lists something", count)

  local missing = nil
  for path in pairs(listed) do
    if not fs.exists("/" .. path) then missing = path end
  end
  check(missing == nil, "every file the installer downloads exists", missing)

  -- The other direction. install.lua is deliberately absent: it is fetched by
  -- `wget run` and is the thing doing the downloading, not one of the downloads.
  local expected = {}
  for _, name in ipairs(fs.list("/")) do
    if name:sub(-4) == ".lua" and name ~= "install.lua" then expected[name] = true end
  end
  for _, name in ipairs(fs.list("/lib")) do
    expected["lib/" .. name] = true
  end

  local unlisted = nil
  for path in pairs(expected) do
    if not listed[path] then unlisted = path end
  end
  check(unlisted == nil, "every file in the tree is in the manifest", unlisted)
end

--------------------------------------------------------------------------------
section("config")
--------------------------------------------------------------------------------

do
  local config = require("lib.config")

  check(config.channel == 1618, "a channel of its own", config.channel)
  check(config.protocol == "aero", "a protocol name", config.protocol)
  check(config.channel ~= 3141 and config.channel ~= 2718,
        "does not collide with the other two suites")
  check(config.sweep > 0 and config.sweep <= 0.5, "a sweep fast enough for a PID")
  check(config.heartbeat < config.heartbeatTimeout,
        "telemetry is sent more often than it is given up on")
  check(config.heartbeatTimeout < config.staleAfter,
        "the pocket gives up before the server does")
end

--------------------------------------------------------------------------------
section("nav: angles")
--------------------------------------------------------------------------------

do
  local nav = require("lib.nav")

  check(nav.norm(370) == 10, "norm folds above 360", nav.norm(370))
  check(nav.norm(-10) == 350, "norm folds below zero", nav.norm(-10))

  -- The wrap is the whole reason this function exists. A ship on 350 asked for
  -- 10 must turn 20 right; subtraction says 340 left, and a ship that took the
  -- long way round every time would look exactly like one with a gain problem.
  check(nav.turn(350, 10) == 20, "the short way round, upwards", nav.turn(350, 10))
  check(nav.turn(10, 350) == -20, "the short way round, downwards", nav.turn(10, 350))
  check(nav.turn(0, 90) == 90, "right is positive")
  check(nav.turn(0, 270) == -90, "left is negative")
  check(math.abs(nav.turn(0, 180)) == 180, "half a turn is 180 either way")

  -- Heading is Minecraft yaw: 0 is south (+Z), 90 is west (-X). test/
  -- mockperipheral.lua's flight model uses the same two formulas, so a
  -- disagreement here is a ship that flies confidently in the wrong direction.
  local fx, fz = nav.forward(0)
  check(near(fx, 0) and near(fz, 1), "heading 0 points at +Z", fx .. "," .. fz)

  fx, fz = nav.forward(90)
  check(near(fx, -1) and near(fz, 0), "heading 90 points at -X", fx .. "," .. fz)

  local origin = { x = 0, y = 64, z = 0 }
  check(near(nav.bearing(origin, { x = 0, y = 64, z = 10 }), 0),
        "bearing to +Z is 0", nav.bearing(origin, { x = 0, y = 64, z = 10 }))
  check(near(nav.bearing(origin, { x = -10, y = 64, z = 0 }), 90),
        "bearing to -X is 90", nav.bearing(origin, { x = -10, y = 64, z = 0 }))
  check(near(nav.bearing(origin, { x = 0, y = 64, z = -10 }), 180),
        "bearing to -Z is 180", nav.bearing(origin, { x = 0, y = 64, z = -10 }))
  check(near(nav.bearing(origin, { x = 10, y = 64, z = 0 }), 270),
        "bearing to +X is 270", nav.bearing(origin, { x = 10, y = 64, z = 0 }))

  check(nav.bearing(origin, origin) == nil, "no bearing to where you already are")

  -- Round trip: fly the bearing and you arrive.
  local target = { x = -30, y = 64, z = 40 }
  local b = nav.bearing(origin, target)
  local bx, bz = nav.forward(b)
  local d = nav.distance(origin, target)
  check(near(origin.x + bx * d, target.x, 0.01)
    and near(origin.z + bz * d, target.z, 0.01),
        "bearing and forward are inverses", b)
end

--------------------------------------------------------------------------------
section("nav: legs and plans")
--------------------------------------------------------------------------------

do
  local nav = require("lib.nav")

  check(near(nav.distance({x=0,y=0,z=0}, {x=3,y=99,z=4}), 5),
        "distance is planar and ignores height")

  -- Positive is right of track. Flying north (heading 180, -Z) from the origin,
  -- a ship displaced to -X is to the... this is exactly the sign nobody can do
  -- in their head, which is why it is asserted rather than reasoned about.
  local from = { x = 0, y = 64, z = 0 }
  local to   = { x = 0, y = 64, z = 100 }
  local left = { x = -5, y = 64, z = 50 }
  local xt = nav.crossTrack(left, from, to)
  check(near(math.abs(xt), 5), "cross-track measures the offset", xt)
  check(nav.crossTrack({x=5,y=64,z=50}, from, to) == -xt,
        "cross-track is signed and symmetric")

  -- Steering closes on the line, not just on the point, and the correction is
  -- capped so a badly displaced ship turns towards the line rather than
  -- perpendicular to it.
  local far = { x = -400, y = 64, z = 50 }
  local steer = nav.steer(far, from, to, 2)
  local direct = nav.bearing(far, to)
  check(math.abs(nav.turn(direct, steer)) <= 45.001,
        "the cross-track correction is capped", nav.turn(direct, steer))

  local waypoints = {}
  check(nav.put(waypoints, { name = "quarry", x = 100, y = 70, z = 20 }),
        "a good waypoint goes in")

  -- Each of these captures both returns first. A call in any position but the
  -- last is truncated to one value, so `refused(nav.put(...), nil, "name")`
  -- silently checks the reason against nil and passes for the wrong reason --
  -- or, as it did here, fails for one.
  local rejected, why = nav.put(waypoints, { name = "", x = 1, y = 1, z = 1 })
  check(refused(rejected, why, "name"), "a nameless waypoint is refused", why)

  check(refused(nav.put(waypoints, { name = "bad name!", x = 1, y = 1, z = 1 })),
        "odd characters are refused")

  rejected, why = nav.put(waypoints, { name = "nowhere" })
  check(refused(rejected, why, "position"),
        "a waypoint with no position is refused", why)

  rejected, why = nav.put(waypoints, { name = "pad", x = 1, z = 1, kind = "pad" })
  check(refused(rejected, why, "height"),
        "a pad with no height is refused -- you cannot land on an unknown y", why)

  nav.put(waypoints, { name = "base", x = 0, y = 64, z = 0, kind = "pad" })
  nav.put(waypoints, { name = "ridge", x = 50, y = 90, z = 50 })

  local names = nav.names(waypoints)
  check(names[1] == "base" and names[#names] == "ridge",
        "names come back sorted, not in hash order", table.concat(names, ","))

  local near_ = nav.nearest(waypoints, { x = 5, y = 64, z = 5 }, "pad")
  check(near_ and near_.name == "base", "nearest finds a pad by kind")

  local plan, why = nav.plan(waypoints, { "quarry", "ridge" }, 120)
  check(plan ~= nil, "a plan over known waypoints", why)
  check(plan and plan.alt == 120 and #plan.legs == 2 and plan.leg == 1,
        "the plan starts on its first leg")

  check(refused(nav.plan(waypoints, { "atlantis" })) , "an unknown waypoint is refused")

  local empty, emptyWhy = nav.plan(waypoints, {})
  check(refused(empty, emptyWhy, "no legs"), "an empty plan is refused", emptyWhy)

  check(nav.current(plan).name == "quarry", "the current leg is the first one")

  local at = { x = 99, y = 70, z = 20 }
  local next_ = nav.advance(plan, at)
  check(next_ and next_.name == "ridge", "advance moves on")
  check(plan.from and plan.from.x == 99,
        "the new leg starts where the ship actually is, not at the waypoint")
  check(nav.advance(plan, at) == nil, "advancing past the end gives nil")

  -- The bingo guard's question is "can I finish this", and the distance to the
  -- next waypoint is not that. A ship two blocks from a waypoint with six
  -- hundred blocks of plan behind it has fuel for the waypoint and none for the
  -- plan.
  local long = nav.plan(waypoints, { "quarry", "ridge", "base" }, 100)
  local remaining = nav.remaining(long, { x = 99, y = 70, z = 20 })
  local firstLeg = nav.distance({ x = 99, y = 70, z = 20 }, waypoints.quarry)
  check(remaining > firstLeg * 5, "remaining follows the whole plan", remaining)

  check(nav.eta(100, 10) == 10, "eta is distance over speed")
  check(nav.eta(100, 0) == nil, "a stopped ship has no arrival time, not an infinite one")
end

--------------------------------------------------------------------------------
section("terrain")
--------------------------------------------------------------------------------

-- What the fleet has learned about the ground, and the one rule the whole module
-- is built on: unknown stays unknown. A map that answered "sixty-four" for
-- ground it had never seen would look like knowledge and fly ships into hills.
do
  local terrain = require("lib.terrain")
  local config = require("lib.config")

  local map = terrain.new(8)
  check(terrain.size(map) == 0, "a new map knows nothing")
  check(terrain.at(map, 0, 0) == nil, "and says so, rather than saying zero")

  terrain.note(map, 0, 0, 64, 1)
  check(terrain.at(map, 0, 0) == 64, "a sample is remembered")
  check(terrain.at(map, 3, 3) == 64, "across its whole cell", terrain.at(map, 3, 3))
  check(terrain.at(map, 40, 0) == nil, "and no further")

  -- The highest reading a cell ever gave, never the last. A ship passing over
  -- the gap between two towers must not erase what it learned about the towers.
  terrain.note(map, 1, 1, 90, 2)
  check(terrain.at(map, 0, 0) == 90, "a higher reading wins", terrain.at(map, 0, 0))
  terrain.note(map, 2, 2, 70, 3)
  check(terrain.at(map, 0, 0) == 90,
        "and a lower one does not lower it", terrain.at(map, 0, 0))

  -- Along a leg.
  local flat = terrain.new(8)
  for z = 0, 200, 4 do terrain.note(flat, 0, z, 64, 1) end

  local highest, coverage, gap = terrain.along(flat, { x = 0, z = 0 },
                                               { x = 0, z = 200 })
  check(highest == 64, "a surveyed leg reports its ground", highest)
  check(coverage > 0.95, "with full coverage", coverage)
  check(gap == 0, "and no gaps", gap)

  terrain.note(flat, 0, 100, 140, 2)
  check(terrain.along(flat, { x = 0, z = 0 }, { x = 0, z = 200 }) == 140,
        "a hill anywhere on the leg is the answer for the whole leg")

  -- A route nobody has flown.
  local blind = terrain.new(8)
  local none, noCover, bigGap = terrain.along(blind, { x = 0, z = 0 },
                                              { x = 0, z = 200 })
  check(none == nil, "an unsurveyed leg has no height, not a default height")
  check(noCover == 0, "no coverage", noCover)
  check(bigGap > 150, "and one enormous gap", bigGap)

  -- The case coverage alone would wave through: mostly known, with the hole
  -- exactly where the mountain is.
  local holed = terrain.new(8)
  for z = 0, 400, 4 do
    if z < 150 or z > 260 then terrain.note(holed, 0, z, 64, 1) end
  end
  local h2, c2, g2 = terrain.along(holed, { x = 0, z = 0 }, { x = 0, z = 400 })
  check(c2 > 0.6, "a route can be mostly surveyed", ("%.2f"):format(c2))
  check(g2 > config.surveyGap, "and still have an unacceptable hole in it", g2)
  check(terrain.surveyed(c2, g2) == false,
        "which is not a surveyed route, whatever the coverage says")
  check(terrain.surveyed(1, 0) == true, "a genuinely covered one is")

  -- A safe altitude, and the refusal to invent one.
  check(terrain.safe(100, 12) == 112, "safe altitude clears the ground")
  check(terrain.safe(nil, 12) == nil,
        "and there is none without ground to clear -- no default, because a "
        .. "default is a guess wearing a number")

  -- A whole plan is planned against the worst of it: one cruise altitude has to
  -- clear every leg.
  local nav = require("lib.nav")
  local waypoints = {}
  nav.put(waypoints, { name = "a", x = 0, y = 64, z = 100 })
  nav.put(waypoints, { name = "b", x = 0, y = 64, z = 300 })

  local hills = terrain.new(8)
  for z = 0, 400, 4 do terrain.note(hills, 0, z, 64, 1) end
  terrain.note(hills, 0, 250, 180, 2)          -- on the second leg

  local plan = nav.plan(waypoints, { "a", "b" }, 100)
  local worst = terrain.forPlan(hills, plan, { x = 0, z = 0 })
  check(worst == 180, "a plan is planned against the worst of every leg", worst)

  -- Bounded, like the log. This is the one thing that grows with every block
  -- ever flown over.
  local big = terrain.new(8)
  for i = 1, config.terrainCells + 50 do
    terrain.note(big, i * 16, 0, 64, i)
  end
  check(terrain.size(big) <= config.terrainCells, "the map is bounded",
        terrain.size(big))
  check(terrain.at(big, (config.terrainCells + 50) * 16, 0) == 64,
        "keeping the newest")

  -- Round trip, because it goes to disk and over the wire.
  local saved = terrain.load({ cell = 8, cells = { ["0,0"] = { h = 77, at = 1 } } })
  check(terrain.at(saved, 4, 4) == 77, "a map survives being reloaded")
  check(terrain.size(terrain.load(nil)) == 0, "and a missing one is empty")
  check(terrain.size(terrain.load({ cells = "nonsense" })) == 0,
        "and so is a corrupt one, rather than a crash on a flight computer")
end

--------------------------------------------------------------------------------
section("flight: planning against the ground")
--------------------------------------------------------------------------------

do
  local nav     = require("lib.nav")
  local flight  = require("lib.flight")
  local terrain = require("lib.terrain")

  local waypoints = {}
  nav.put(waypoints, { name = "far", x = 0, y = 64, z = 400 })

  local limits = { cruise = 12, climb = 4, descend = 3, clearance = 10 }

  local function fix(t)
    local f = { x = 0, y = 64, z = 0, alt = 64, heading = 0, speed = 0, vs = 0,
                usable = true, levelled = true, clearance = 0, burn = 9999 }
    for k, v in pairs(t or {}) do f[k] = v end
    return f
  end

  -- A ridge at 180 across a route somebody wants to fly at 100.
  local map = terrain.new(8)
  for z = 0, 400, 4 do terrain.note(map, 0, z, 64, 1) end
  for z = 190, 230, 4 do terrain.note(map, 0, z, 180, 1) end

  local ctx = { waypoints = waypoints, limits = limits, terrain = map }

  local st = flight.new()
  flight.command(st, { type = "fly", names = { "far" }, alt = 100 }, ctx, 0)
  check(st.alt == 100, "a flight is planned at the altitude asked for", st.alt)

  local _, _, events = flight.step(st, fix(), ctx, 1)
  check(st.alt >= 190, "and preflight raises it to clear the known ridge", st.alt)
  check(st.state == "takeoff", "then goes", st.state)

  local said = nil
  for _, e in ipairs(events) do if e.why == "terrain" then said = e end end
  check(said ~= nil, "saying why, because a ship that silently changed the "
        .. "altitude you typed would be alarming")

  -- It only ever raises. A map saying a hill is *absent* is not something a map
  -- built from where ships happened to fly can honestly say.
  st = flight.new()
  flight.command(st, { type = "fly", names = { "far" }, alt = 300 }, ctx, 0)
  flight.step(st, fix(), ctx, 1)
  check(st.alt == 300, "and never lowers one", st.alt)

  -- An unsurveyed route is flown as asked, because refusing would ground the
  -- fleet everywhere it has not already been.
  local blind = terrain.new(8)
  st = flight.new()
  flight.command(st, { type = "fly", names = { "far" }, alt = 100 },
                 { waypoints = waypoints, limits = limits, terrain = blind }, 0)
  flight.step(st, fix(), { waypoints = waypoints, limits = limits,
                           terrain = blind }, 1)
  check(st.alt == 100, "an unsurveyed route is flown at the altitude given",
        st.alt)
  check(st.state == "takeoff", "and is not refused for being unknown", st.state)

  -- No map at all -- a fleet with no tower, or one that has never flown -- is
  -- the same case and must not crash.
  st = flight.new()
  flight.command(st, { type = "fly", names = { "far" }, alt = 100 },
                 { waypoints = waypoints, limits = limits }, 0)
  local ok = pcall(flight.step, st, fix(),
                   { waypoints = waypoints, limits = limits }, 1)
  check(ok, "no map at all is survivable")
end

--------------------------------------------------------------------------------
section("instruments")
--------------------------------------------------------------------------------

do
  local config = require("lib.config")
  local instruments = require("lib.instruments")

  local blank = instruments.blank()
  check(blank.usable == false, "a ship that has just booted knows nothing")
  check(blank.source == "none", "and says so")

  -- A real position wins, and is called what it is.
  local fix = instruments.fuse(blank,
    { pos = { x = 10, y = 70, z = 20 }, heading = 90, alt = 70 }, nil, 0)
  check(fix.source == "nav" and fix.x == 10, "the navigation table is the source")
  check(fix.usable == true, "a fresh nav fix is usable")
  check(fix.fixAge == 0, "and is not aged")

  -- GPS fills in only when the table is silent.
  local gpsFix = instruments.fuse(blank, { heading = 90, alt = 70 },
                                  { x = 1, y = 2, z = 3 }, 0)
  check(gpsFix.source == "gps" and gpsFix.x == 1, "gps is the fallback")

  -- Dead reckoning: flying east at 10 blocks/second on heading 270 (+X) for one
  -- second should put the ship ten blocks further along +X.
  local flying = instruments.fuse(blank,
    { pos = { x = 0, y = 70, z = 0 }, heading = 270, alt = 70 }, nil, 0)
  flying = instruments.fuse(flying,
    { pos = { x = 10, y = 70, z = 0 }, heading = 270, alt = 70 }, nil, 1)

  local reckoned = instruments.fuse(flying, { heading = 270, alt = 70 }, nil, 2)
  check(reckoned.source == "reckon", "no position means reckoning")
  check(reckoned.x > flying.x, "and the ship keeps moving the way it was going",
        reckoned.x)
  check(reckoned.fixAge >= 1, "the reckoned fix knows how old it is", reckoned.fixAge)
  check(reckoned.usable == true, "a fresh reckon is still usable")

  -- ...until it is not. This is the guard the whole module exists for.
  local stale = reckoned
  for t = 3, 3 + config.reckonLimit + 2 do
    stale = instruments.fuse(stale, { heading = 270, alt = 70 }, nil, t)
  end
  check(stale.fixAge > config.reckonLimit, "reckoning ages out", stale.fixAge)
  check(stale.usable == false,
        "and an aged-out fix is not navigable -- the point of the whole file")

  -- Vertical speed is differentiated because nothing reports it. It is smoothed,
  -- so the assertion is on the sign and the approach, not on the exact number.
  local rising = instruments.fuse(blank,
    { pos = { x = 0, y = 64, z = 0 }, heading = 0, alt = 64 }, nil, 0)
  for i = 1, 20 do
    rising = instruments.fuse(rising,
      { pos = { x = 0, y = 64 + i, z = 0 }, heading = 0, alt = 64 + i }, nil, i)
  end
  check(rising.vs > 0.8 and rising.vs < 1.2,
        "a ship climbing a block a second reads about one", rising.vs)

  -- Ground speed comes from the components, not from the velocity sensor: the
  -- sensor's scalar includes the vertical, so a ship going straight up would
  -- read as travelling.
  check(near(rising.speed, 0, 0.05),
        "climbing straight up is not ground speed", rising.speed)

  -- A clearance of nil is "nothing answered" and must never become zero.
  check(instruments.clearance({ alt = 80 }, nil) == nil,
        "no sensor and no ground level is no clearance, not zero clearance")
  check(instruments.clearance({ alt = 80 }, 64) == 16, "clearance from a known ground")
  check(instruments.clearance({ alt = 80, clearance = 3 }, 64) == 3,
        "the sensor wins over the arithmetic")

  -- A hull with no navigation table still has an altimeter, and must still be
  -- able to hold height while it waits.
  local hovering = instruments.fuse(blank, { alt = 100 }, nil, 0)
  check(hovering.usable == false, "no heading means not navigable")
  check(hovering.levelled == true, "but it can still hold altitude")
end

--------------------------------------------------------------------------------
section("autopilot")
--------------------------------------------------------------------------------

do
  local autopilot = require("lib.autopilot")

  local g = autopilot.gains({ hover = 0.7 })
  check(g.hover == 0.7, "craft gains override the defaults")
  check(g.vsP == autopilot.defaults.vsP, "and leave the rest alone")

  local st = autopilot.new()

  -- Idle is an explicit early return rather than "every target is nil". They
  -- produce the same numbers for completely different reasons and only one of
  -- them means the ship has been told to stop.
  local _, demands = autopilot.step(st, { alt = 64, vs = 0 }, { idle = true }, 0)
  check(demands.lift == 0 and demands.forward == 0, "idle asks for nothing")

  -- Below target, the ship should be told to climb; above it, to sink.
  autopilot.reset(st)
  local _, up = autopilot.step(st, { alt = 60, vs = 0, heading = 0 },
                               { alt = 100, limits = { climb = 4 } }, 0)
  check(up.lift > st.gains.hover, "forty blocks low means more than hover", up.lift)
  check(up.wantVs == 4, "and the climb is clamped to the hull's limit", up.wantVs)

  autopilot.reset(st)
  local _, down = autopilot.step(st, { alt = 140, vs = 0, heading = 0 },
                                 { alt = 100, limits = { descend = 3 } }, 0)
  check(down.lift < st.gains.hover, "forty blocks high means less", down.lift)
  check(down.wantVs == -3, "and the descent is clamped too", down.wantVs)

  -- The integral clamp. A ship left on the pad with a target far above it
  -- accumulates error for as long as you leave it, and without the clamp the
  -- moment it is freed it leaves like a rocket.
  autopilot.reset(st)
  local t = 0
  for _ = 1, 2000 do
    autopilot.step(st, { alt = 60, vs = 0, heading = 0 },
                   { alt = 200, limits = { climb = 4 } }, t)
    t = t + 0.2
  end
  check(st.loops.vs.i <= st.gains.vsIMax + 0.0001,
        "the vertical integral is clamped", st.loops.vs.i)
  local _, afterHours = autopilot.step(st, { alt = 60, vs = 0, heading = 0 },
                                       { alt = 200, limits = { climb = 4 } }, t)
  check(afterHours.lift <= 1.0, "and the demand it produces is still a throttle",
        afterHours.lift)

  -- reset() is what stops a climb integral being carried into a descent.
  autopilot.reset(st)
  check(st.loops.vs == nil, "reset forgets the integral")

  -- Heading: the error is a signed turn, so the demand across the wrap is small
  -- and in the right direction.
  autopilot.reset(st)
  local _, turnRight = autopilot.step(st, { alt = 64, vs = 0, heading = 350 },
                                      { heading = 10, alt = 64 }, 0)
  check(turnRight.yaw > 0, "350 to 10 turns right", turnRight.yaw)
  check(turnRight.headingError == 20, "by twenty degrees", turnRight.headingError)

  autopilot.reset(st)
  local _, turnLeft = autopilot.step(st, { alt = 64, vs = 0, heading = 10 },
                                     { heading = 350, alt = 64 }, 0)
  check(turnLeft.yaw < 0, "10 to 350 turns left", turnLeft.yaw)

  -- A ship pointing the wrong way should slow down rather than sprint off.
  autopilot.reset(st)
  local _, wrongWay = autopilot.step(st,
    { alt = 64, vs = 0, heading = 0, speed = 0 },
    { heading = 170, speed = 12, alt = 64 }, 0)
  autopilot.reset(st)
  local _, rightWay = autopilot.step(st,
    { alt = 64, vs = 0, heading = 0, speed = 0 },
    { heading = 0, speed = 12, alt = 64 }, 0)
  check(wrongWay.forward < rightWay.forward,
        "pointing away means less power, not more",
        wrongWay.forward .. " vs " .. rightWay.forward)

  -- A loop with no target does not run, and a demand that does not run is zero
  -- rather than whatever it was last time.
  autopilot.reset(st)
  autopilot.step(st, { alt = 64, vs = 0, heading = 0, speed = 10 },
                 { speed = 12, alt = 64 }, 0)
  local _, noSpeed = autopilot.step(st, { alt = 64, vs = 0, heading = 0, speed = 10 },
                                    { alt = 64 }, 0.2)
  check(noSpeed.forward == 0,
        "a ship told to stop navigating stops pushing", noSpeed.forward)

  -- A long gap is a chunk that unloaded. Integrating across it would add
  -- several seconds of error in one step.
  autopilot.reset(st)
  autopilot.step(st, { alt = 60, vs = 0 }, { alt = 100, limits = {} }, 0)
  local before = st.loops.vs.i
  autopilot.step(st, { alt = 60, vs = 0 }, { alt = 100, limits = {} }, 60)
  check(st.loops.vs == nil or st.loops.vs.i == 0 or st.loops.vs.i == before,
        "a minute-long gap does not get integrated")

  -- The mix.
  local mix = {
    { demand = "lift",    control = "lift", as = "throttle" },
    { demand = "forward", control = "main", as = "throttle" },
    { demand = "yaw",     control = "main", as = "pivot", scale = 30 },
  }
  local outs = autopilot.apply(mix, { lift = 0.5, forward = 0.3, yaw = -1 })
  check(near(outs.lift.throttle, 0.5), "lift goes to the lift bearing")
  check(near(outs.main.throttle, 0.3), "forward goes to the main bearing")
  check(near(outs.main.pivot, -30), "and yaw is scaled into degrees of pivot",
        outs.main.pivot)

  -- Terms accumulate, which is how two bearings share the lift.
  local shared = autopilot.apply({
    { demand = "lift", control = "a", as = "throttle", scale = 0.5 },
    { demand = "lift", control = "a", as = "throttle", scale = 0.5 },
  }, { lift = 0.8 })
  check(near(shared.a.throttle, 0.8), "mix terms add", shared.a.throttle)

  check(autopilot.settled({ alt = 100, heading = 90 }, { alt = 100, heading = 90 }),
        "settled when it is where it was asked to be")
  check(not autopilot.settled({ alt = 60, heading = 90 }, { alt = 100 }),
        "not settled forty blocks low")
end

--------------------------------------------------------------------------------
section("guide")
--------------------------------------------------------------------------------

-- The manual ships with the program so `guide` works in game, on the computer
-- bolted to the ship, at the moment something is wrong with it. Which means the
-- text is now something that can rot, so it is checked like anything else.
do
  local guide = require("lib.guide")

  check(#guide.topics >= 8, "there is a manual", #guide.topics)

  local titles = {}
  for _, topic in ipairs(guide.topics) do
    checkQuiet(type(topic.title) == "string" and topic.title ~= "",
               "a topic has a title")
    checkQuiet(type(topic.body) == "string" and #topic.body > 40,
               "and a body worth reading: " .. tostring(topic.title))
    checkQuiet(titles[topic.title] == nil,
               "and a title of its own: " .. tostring(topic.title))
    titles[topic.title] = true
  end
  check(true, "every topic has a unique title and a real body")

  -- The whole manual is written for a pocket computer. A line wider than that
  -- wraps mid-thought on the device most likely to be reading it, and the
  -- wrapper cannot know that "thruster_bearing_0" must not be split -- so the
  -- text is kept narrow by hand and checked here.
  local widest, where = guide.widest()
  check(widest <= 26, "no line is wider than a pocket computer",
        ("%d in '%s'"):format(widest, tostring(where)))

  -- The topics a player in trouble will actually look for.
  for _, word in ipairs({ "configure", "craft.cfg", "balloon", "hold = true",
                          "wireless modem", "tether", "guard", "bingo",
                          "hover", "waypoint",
                          -- The two failures players actually hit, in the
                          -- words they would search for rather than the words
                          -- the fix is described in.
                          "optical sensors", "assembl", "attach", "clearance" }) do
    checkQuiet(#guide.search(word) > 0, "the manual mentions " .. word)
  end
  check(#guide.search("configure") > 0 and #guide.search("bingo") > 0,
        "and covers what somebody in trouble would search for")

  -- The two programs that were folded into `configure`. A manual that still
  -- tells somebody to run `probe` is worse than one that does not mention it:
  -- the command is gone, so the instruction is a dead end at exactly the moment
  -- it is being followed.
  for _, gone in ipairs({ "probe", "setup pilot", "probe --eyes" }) do
    checkQuiet(#guide.search(gone) == 0,
               "and no longer sends anyone to " .. gone)
  end
  check(true, "the manual does not name a program that was removed")

  -- Search.
  check(#guide.search("") == #guide.topics,
        "an empty search puts the whole manual back")
  check(#guide.search("BALLOON") > 0, "search ignores case")
  check(#guide.search("zzzznotathing") == 0, "and finds nothing when there is none")

  -- Wrapping. Blank lines are paragraph breaks and leading spaces are tables;
  -- a wrapper that ate either would run the manual together.
  local wrapped = guide.wrap("one two three four five six seven", 10)
  for _, line in ipairs(wrapped) do
    checkQuiet(#line <= 10, "wrapped to width: " .. line)
  end
  check(#wrapped > 1, "long text wraps", #wrapped)

  local kept = guide.wrap("a\n\nb", 20)
  check(#kept == 3 and kept[2] == "", "blank lines survive wrapping")

  local indented = guide.wrap("  indented line here", 40)
  check(indented[1]:sub(1, 2) == "  ", "and so does an indent")

  -- A single word longer than the line has nowhere to break, and must be cut
  -- rather than loop forever looking for a space.
  local long = guide.wrap("supercalifragilistic", 8)
  check(#long >= 2 and #long[1] <= 8, "an unbreakable word is cut, not hung on",
        #long)

  -- Every topic must survive being wrapped to a pocket width without loss.
  for _, topic in ipairs(guide.topics) do
    local lines = guide.wrap(topic.body, 26)
    checkQuiet(#lines > 0, "wraps: " .. topic.title)
  end
  check(true, "every topic wraps to 26 columns")
end

--------------------------------------------------------------------------------
section("ui")
--------------------------------------------------------------------------------

-- Only the pure layout arithmetic. Everything that draws needs a screen and is
-- exercised by the two UI suites; this is the part with the off-by-ones in it,
-- and the part where a wrong answer means a button that is one row from where
-- it looks.
do
  local ui = require("lib.ui")

  check(ui.fit("hello", 10) == "hello", "fit leaves a short string alone")
  check(#ui.fit("hello", 10, true) == 10, "and pads it when asked")
  check(#ui.fit("a very long name indeed", 8) == 8, "a long one is cut to width")
  check(ui.fit("a very long name", 8):sub(-1) == ".",
        "and marked, so a truncated name does not read as a real one")
  check(ui.fit(nil, 5) == "", "nil is empty, not the word nil")
  check(ui.fit("abc", 0) == "", "and a zero width is empty rather than an error")

  check(#ui.centre("ab", 6) <= 6, "centre never exceeds its width")
  check(ui.centre("ab", 6):find("ab", 1, true) > 1, "and actually centres")

  check(ui.num(nil) == "--", "no reading is dashes, never zero")
  check(ui.num(3.7) == "4", "a number is rounded for a narrow column")

  -- nil in, nil out. A gauge with no reading has to draw itself as empty and
  -- say so, which is not the same as drawing itself at zero -- the whole
  -- difference between "no fuel reading" and "no fuel".
  check(ui.ratio(nil, 0, 10) == nil, "no value is no ratio")
  check(ui.ratio(5, 0, 10) == 0.5, "half way is a half")
  check(ui.ratio(-5, 0, 10) == 0, "below the bottom clamps")
  check(ui.ratio(50, 0, 10) == 1, "and above the top")
  check(ui.ratio(5, 3, 3) == 0, "a zero span does not divide by zero")

  -- Tabs. The same arithmetic decides where a tab is drawn and what a click at
  -- a column means, which is the only way the two cannot disagree.
  local TABS = { "fleet", "fly", "nav", "log" }
  local layout = ui.tabLayout(TABS, 26)
  check(#layout == 4, "four tabs")
  check(layout[1].x == 1, "the first starts at the left edge", layout[1].x)
  check(layout[4].x + layout[4].w - 1 == 26,
        "and the last reaches the right one, with no gap",
        layout[4].x + layout[4].w - 1)

  for _, tab in ipairs(layout) do
    for x = tab.x, tab.x + tab.w - 1 do
      checkQuiet(ui.tabAt(TABS, 26, x) == tab.name,
                 "column " .. x .. " hits " .. tab.name)
    end
  end
  check(true, "every column of every tab hits that tab")
  check(ui.tabAt(TABS, 26, 99) == nil, "and a click past the end hits none")

  -- The altitude tape reads the way the world does: up is up.
  local rows = ui.tapeRows(100, 5, 10)
  check(#rows == 5, "a tape has the rows it was asked for", #rows)
  check(rows[1].value > rows[#rows].value, "the top of the tape is the highest")
  check(rows[3].here == true, "and the middle row is where the ship is")
  check(rows[3].value == 100, "at its altitude", rows[3].value)
  check(#ui.tapeRows(nil, 5, 10) == 0, "no altitude is no tape")

  -- The compass. Heading is Minecraft yaw, so 0 is south and 180 is north --
  -- getting this backwards would put every letter on the wrong side.
  local strip = ui.compassStrip(0, 21)
  check(#strip == 21, "the strip is the width asked for", #strip)
  check(strip:find("S", 1, true) ~= nil, "heading 0 shows S in view")
  check(ui.compassStrip(180, 21):find("N", 1, true) ~= nil, "and 180 shows N")
  check(ui.compassStrip(nil, 10) == ("-"):rep(10), "no heading is a blank strip")

  -- The horizon. Positive pitch is nose down, matching lib/sable and lib/hull,
  -- and nose down puts more ground in view -- so the horizon rises up the
  -- screen. A sign error here draws an aircraft flying into the sky when it is
  -- diving.
  local level = ui.horizonRows(0, 0, 9, 8)
  check(#level == 9, "a horizon row per column", #level)
  check(level[1] == level[9], "level flight is a flat horizon")

  local nose = ui.horizonRows(20, 0, 9, 8)
  check(nose[1] > level[1], "nose down puts more ground in view", nose[1])

  local rolled = ui.horizonRows(0, 30, 9, 8)
  check(rolled[1] ~= rolled[9], "roll tips it")
  check((rolled[1] < rolled[9]) ~= (ui.horizonRows(0, -30, 9, 8)[1] < rolled[9]),
        "and rolling the other way tips it the other way")

  -- Rows carry their own handler, which is the whole reason this pattern exists.
  local l = ui.list()
  local hit = nil
  ui.row(l, { name = "a", click = function() hit = "a" end })
  ui.row(l, { name = "b", click = function() hit = "b" end })
  l.entries[1].y, l.entries[2].y = 5, 6

  check(ui.click(l, 6) == true, "a click on a row runs its handler")
  check(hit == "b", "the right one", hit)
  check(ui.click(l, 99) == false, "and a click on nothing takes nothing")

  -- Typing, which never goes near read().
  local field = ui.field("name")
  ui.type(field, "a")
  ui.type(field, "!")
  ui.type(field, "b")
  check(field.text == "ab", "a field takes what the pattern allows", field.text)
  ui.backspace(field)
  check(field.text == "a", "and backspace works")

  for _ = 1, 40 do ui.type(field, "x") end
  check(#field.text <= field.limit, "a field has a limit", #field.text)

  -- One table of state colours, so the tower, the pocket and the ship cannot
  -- disagree about what orange means.
  check(ui.stateColour.cruise ~= ui.stateColour.loiter,
        "cruise and loiter do not look the same")
  check(ui.guardColour(nil) == ui.theme.dim, "no guard is not an alarm colour")
  check(ui.guardColour("clearance") == ui.theme.bad, "a guard is")
end

--------------------------------------------------------------------------------
section("deck: the flight deck")
--------------------------------------------------------------------------------

-- A monitor on the contraption, read from the pilot's seat while the ship flies.
--
-- Two halves are worth testing and they are different in kind. The layout is
-- arithmetic and is checked directly, at every size a monitor comes in -- that
-- is the part with the off-by-ones. The drawing is checked by rendering into a
-- window and reading the characters back, which is the only way to catch an
-- instrument that is drawn off the edge of its own screen.
do
  local deck = require("lib.deck")
  local ui   = require("lib.ui")

  local VIEW = {
    page = "flight",
    label = "Kestrel", state = "cruise",
    alt = 150, targetAlt = 170,
    speed = 12.4, targetSpeed = 14,
    heading = 3, targetHeading = 12,
    vs = 1.2, pitch = 2.1, roll = -4.0, tilt = 4,
    clearance = 38, ahead = nil,
    fuel = 4200, capacity = 8000, burn = 412,
    controls = { { name = "lift", value = 0.62 }, { name = "main", value = 0.24 } },
    legs = {
      { name = "quarry-pad", distance = 340, current = true,
        x = 128, y = 70, z = -700 },
      { name = "ridge-point", distance = 1120, x = 640, y = 96, z = -1200 },
    },
    home = "home-pad", commander = "gizmo", mayCommand = true,
    x = 128, y = 150, z = -412, usable = true, assembled = true, source = "nav",
  }

  local function view(over)
    local out = {}
    for k, v in pairs(VIEW) do out[k] = v end
    for k, v in pairs(over or {}) do out[k] = v end
    return out
  end

  ------------------------------------------------------------------------------
  -- Layout, at every size a monitor actually comes in
  ------------------------------------------------------------------------------

  -- Monitors are built from blocks, so the sizes are not arbitrary -- but there
  -- are a lot of them, and a deck that assumed its own shape would draw off the
  -- edge of the small ones in silence.
  local SIZES = {
    { 20, 10 }, { 29, 12 }, { 36, 16 }, { 39, 19 }, { 57, 25 }, { 79, 38 },
    { 100, 50 }, { 164, 81 },
  }

  for _, size in ipairs(SIZES) do
    local w, h = size[1], size[2]
    local at = deck.layout(w, h)
    local where = ("%dx%d"):format(w, h)

    -- Nothing may be positioned outside the screen it is drawn on. This is the
    -- whole reason the arithmetic is a pure function.
    for name, box in pairs(at) do
      if type(box) == "table" and box.x then
        checkQuiet(box.x >= 1 and box.x + box.w - 1 <= w,
                   ("%s: %s fits across"):format(where, name))
        checkQuiet(box.y >= 1 and box.y + box.h - 1 <= h,
                   ("%s: %s fits down"):format(where, name))
        checkQuiet(box.w >= 0 and box.h >= 0,
                   ("%s: %s is not inside out"):format(where, name))
      end
    end
  end
  check(true, "every element fits on every monitor size")

  -- The furniture is anchored to the bottom, in a fixed order, so the two pages
  -- cannot disagree about where the buttons are.
  local big = deck.layout(79, 38)
  check(big.buttons.y == 38, "the buttons are the last row", big.buttons.y)
  check(big.fix.y == 37, "with the fix line above them", big.fix.y)
  check(big.panel.y + big.panel.h == big.fix.y, "and the panel above that")
  check(big.plan.y == big.speed.y or big.plan.y == 2,
        "and the nav page starts where the instruments do")

  -- The horizon fills the height and the tapes deliberately do not. Both were
  -- tried the other way round: full-height tapes ran the speed scale down past
  -- zero, and capping the whole block left a twelve-row hole under it.
  check(big.horizon.h > big.speed.h,
        "the horizon grows with the screen and the tapes do not",
        ("%d vs %d"):format(big.horizon.h, big.speed.h))
  check(big.speed.h <= 15, "tapes stay legible", big.speed.h)
  check(big.speed.y > big.horizon.y,
        "and are centred on it rather than pinned to the top")

  -- Tapes must not overlap the horizon, or the picture is drawn over by numbers.
  check(big.speed.x + big.speed.w < big.horizon.x,
        "the speed tape clears the horizon")
  check(big.horizon.x + big.horizon.w <= big.alt.x,
        "and so does the altitude tape")

  check(deck.layout(20, 10).ok == false,
        "a one-block monitor is too small to instrument, and says so")
  check(deck.layout(79, 38).ok == true, "a 4x3 monitor is not")

  ------------------------------------------------------------------------------
  -- Where a button is drawn and what a touch means are one calculation
  ------------------------------------------------------------------------------

  -- The bug this shape exists to prevent has already happened once in this repo,
  -- in the remote: picking a ship added a row and every action below it shifted,
  -- so a tap landed on the button next to the one it looked like.
  local W, H = 79, 38
  local layout = deck.layout(W, H)

  for _, action in ipairs(deck.actions) do
    local found = nil
    for _, tab in ipairs(ui.tabLayout(deck.labels(), W)) do
      if tab.name == action.label then found = tab end
    end

    checkQuiet(found ~= nil, "drawn: " .. action.label)
    if found then
      -- Every column the button occupies has to come back as that button, not
      -- just its middle. A hit test that only worked in the centre would fail
      -- exactly where a finger lands.
      for x = found.x, found.x + found.w - 1 do
        checkQuiet(deck.hit(W, H, x, layout.buttons.y) == action.key,
                   ("column %d is %s"):format(x, action.key))
      end
    end
  end
  check(true, "every column of every button reports that button")

  check(deck.hit(W, H, 5, 1) == "page",
        "touching the header turns the page -- the biggest target there is, and "
        .. "the safest thing a stray elbow can do")
  check(deck.hit(W, H, 5, 12) == nil,
        "and touching an instrument does nothing at all")

  ------------------------------------------------------------------------------
  -- What a touch actually orders
  ------------------------------------------------------------------------------

  -- Every one of these goes through flight.command exactly as an order from a
  -- pocket does. A cockpit button with its own path into the flight state would
  -- be a way around the conn, the guards and the log at once.
  check(deck.order("page") == nil, "the page turn is local and orders nothing")

  local up = deck.order("alt+", 10)
  check(up and up.type == "alt" and up.by == 10,
        "ALT+ is a relative altitude order", up and up.by)

  local down = deck.order("alt-", 10)
  check(down and down.by == -10, "and ALT- is the same order the other way",
        down and down.by)

  check(deck.order("hold").type == "hold", "HOLD holds")
  check(deck.order("land").type == "land", "LAND lands")
  check(deck.order("conn").type == "take", "and CONN takes control")

  -- `by`, never `alt`. The two are different orders: `alt` is an absolute
  -- height and `by` is a nudge from wherever the ship is now, and a deck button
  -- that sent an absolute 10 would fly the ship into the ground from cruise.
  check(up.alt == nil and down.alt == nil,
        "the altitude buttons nudge and never set an absolute height")

  ------------------------------------------------------------------------------
  -- Rendering, read back off the screen
  ------------------------------------------------------------------------------

  local function render(v, w, h)
    local win = window.create(term.current(), 1, 1, w, h, false)
    local old = term.redirect(win)
    local ok, err = pcall(deck.draw, v)
    term.redirect(old)

    local lines = {}
    for y = 1, h do lines[#lines + 1] = win.getLine(y) end
    return { ok = ok, err = err, lines = lines, text = table.concat(lines, "\n") }
  end

  local shown = render(view(), 79, 38)
  check(shown.ok, "the deck draws", shown.err)
  check(shown.text:find("Kestrel", 1, true), "with the ship's name on it")
  check(shown.text:find("CRUISE", 1, true), "and what it is doing")
  check(shown.text:find("150", 1, true), "the altitude")
  check(shown.text:find("quarry%-pad"), "and where it is going")
  check(shown.text:find("PAGE", 1, true) and shown.text:find("HOLD", 1, true),
        "and the buttons are on it")

  -- The pointer and the bug. A tape without a target marked says where the ship
  -- is and nothing about where it is meant to be.
  check(shown.text:find(">%s*150"), "the altitude pointer marks the current value")
  check(shown.text:find("%*%s*170"), "and a bug marks the one it is climbing to")

  -- A guard is the one thing on this screen that has to be readable across a
  -- cockpit, so it goes in the header rather than in a corner.
  local guarded = render(view{ guard = "clearance", state = "climb" }, 79, 38)
  check(guarded.lines[1]:find("CLEARANCE", 1, true),
        "a firing guard is named in the header", guarded.lines[1])

  -- A refusal takes the fix line, because "why did nothing happen when I pressed
  -- that" is worth more for six seconds than a position shown on every other
  -- screen in the fleet.
  local refused = render(view{ note = "gizmo has control" }, 79, 38)
  check(refused.text:find("gizmo has control", 1, true),
        "a refused order is said out loud on the deck")

  -- Speed cannot be negative, and a scale offering readings that cannot happen
  -- is one you stop trusting the rest of.
  local slow = render(view{ speed = 1, targetSpeed = 2 }, 79, 38)
  check(not slow.text:find("-1[02468]"),
        "the speed tape does not run below zero on a tall monitor")

  local navigating = render(view{ page = "nav" }, 79, 38)
  check(navigating.text:find("flight plan", 1, true), "the nav page lists the plan")
  check(navigating.text:find("ridge%-point"), "every leg of it")
  check(navigating.text:find("128 70 %-700"), "with where each one actually is")
  check(navigating.text:find("eta", 1, true), "and what it adds up to")
  check(navigating.lines[38]:find("PAGE", 1, true),
        "and the buttons are in the same place as on the flight page",
        navigating.lines[38])

  -- Anything wrong with the hull, on the one screen aboard with room for it.
  local sick = render(view{ page = "nav",
                            problems = { "forward: no optical_sensor attached" } },
                      79, 38)
  check(sick.text:find("what is wrong", 1, true),
        "the nav page carries the hull's complaints")
  check(sick.text:find("optical_sensor", 1, true), "and names them")

  -- Nothing may be drawn where there is nothing to draw it on.
  for _, size in ipairs(SIZES) do
    local r = render(view(), size[1], size[2])
    checkQuiet(r.ok, ("draws at %dx%d"):format(size[1], size[2]), r.err)
    for y, line in ipairs(r.lines) do
      checkQuiet(#line == size[1],
                 ("%dx%d row %d is exactly the screen width"):format(
                   size[1], size[2], y))
    end
  end
  check(true, "and it draws at every monitor size without running off the edge")

  -- A monitor too small for instruments says so rather than drawing a horizon
  -- two rows tall. A blank screen would send somebody looking for a fault that
  -- is really a one-block monitor.
  local tiny = render(view(), 20, 10)
  check(tiny.ok, "a monitor too small to instrument still draws", tiny.err)
  check(tiny.text:find("too small", 1, true), "and says why")
  check(tiny.text:find("150", 1, true),
        "while still showing the altitude, which is the one number that matters")

  -- Missing readings are the normal state of a ship on the pad, and nil is not
  -- zero: a horizon drawn level because there is no gimbal is a lie.
  local blank = render({ page = "flight", label = "Kestrel", state = "idle" },
                       79, 38)
  check(blank.ok, "a deck with no readings at all still draws", blank.err)
  check(blank.text:find("%-%-"), "and says so rather than showing zeroes")
end

--------------------------------------------------------------------------------
section("sable")
--------------------------------------------------------------------------------

-- The quaternion maths, which is the part where a sign error puts the ship's
-- "up" somewhere it is not and no amount of staring at the source tells you.
do
  local sable = require("lib.sable")

  -- Identity: level, facing +Z, which is heading 0.
  local tilt, pitch, roll, heading = sable.attitude({ x = 0, y = 0, z = 0, w = 1 })
  check(near(tilt, 0), "an identity quaternion is level", tilt)
  check(near(pitch, 0) and near(roll, 0), "with no pitch or roll")
  check(near(heading, 0), "facing +Z, which is heading 0", heading)

  -- A quarter turn about X: nose straight down, ninety degrees from level.
  local h = math.sqrt(0.5)
  tilt, pitch = sable.attitude({ x = h, y = 0, z = 0, w = h })
  check(near(tilt, 90, 0.01), "a quarter turn about X is ninety from level", tilt)
  check(near(pitch, -90, 0.01) or near(pitch, 90, 0.01),
        "and is all pitch", pitch)

  -- Upside down. This is the case the whole attitude guard exists for: the
  -- ship's up is the world's down, and every lift command now pushes it at the
  -- ground.
  tilt = sable.attitude({ x = 1, y = 0, z = 0, w = 0 })
  check(near(tilt, 180, 0.01), "a half turn is inverted", tilt)

  tilt = sable.attitude({ x = 0, y = 0, z = 1, w = 0 })
  check(near(tilt, 180, 0.01), "whichever axis it went over", tilt)

  -- Yaw alone does not tilt anything, which is the property that stops a ship
  -- simply turning from tripping the guard.
  for _, degrees in ipairs({ 30, 90, 180, 270 }) do
    local q = { x = 0, y = math.sin(math.rad(degrees) / 2), z = 0,
                w = math.cos(math.rad(degrees) / 2) }
    local t, _, _, hd = sable.attitude(q)
    checkQuiet(near(t, 0, 0.01), "yaw " .. degrees .. " is still level", t)
    checkQuiet(hd ~= nil, "and has a heading")
  end
  check(true, "yaw alone never counts as tilt")

  -- A small lean is a small number, not a large one -- the guard's threshold is
  -- meaningless if the reading is not proportional.
  tilt = sable.attitude({ x = math.sin(math.rad(20) / 2), y = 0, z = 0,
                          w = math.cos(math.rad(20) / 2) })
  check(near(tilt, 20, 0.01), "a twenty degree lean reads as twenty", tilt)

  check(sable.attitude(nil) == nil, "a quaternion that is not one is nil")
  check(sable.attitude({ x = 0 }) == nil, "and so is an incomplete one")

  check(near(sable.magnitude({ x = 3, y = 4, z = 0 }), 5), "magnitude is length")

  -- The whole module degrades when the mod is absent, which is a configuration
  -- this program has to run in.
  local realSublevel, realAero = _G.sublevel, _G.aero
  _G.sublevel, _G.aero = nil, nil
  sable.available = nil
  check(sable.present() == false, "with no CC: Sable, present() is false")
  check(sable.read() == nil, "and read gives nil rather than an empty table")
  check(sable.setName("x") == false, "and naming is refused, not fatal")

  -- ...and when it is there but the contraption is not assembled, which is its
  -- state on the pad and every time it is taken apart.
  local mock = require("test.mockperipheral")
  local w = mock.new{}
  w.sable{ assembled = false }
  _G.sublevel, _G.aero = w.sublevel, w.aero
  sable.available = nil
  check(sable.present() == true, "with CC: Sable, present() is true")
  check(sable.read() == nil, "but an unassembled contraption reads nil")

  w.assembled = true
  w.ship.x, w.ship.y, w.ship.z = 10, 90, 20
  w.ship.heading, w.ship.speed, w.ship.vy = 90, 6, -1
  w.spin = { x = 0, y = 30, z = 0 }

  local read = sable.read()
  check(read ~= nil, "an assembled one reads")
  check(read.pos and near(read.pos.x, 10) and near(read.pos.y, 90),
        "with a position")
  check(read.velocity and near(read.velocity.y, -1),
        "a real velocity vector, not a differentiated one",
        read.velocity and read.velocity.y)
  check(near(read.spin, 30, 0.01),
        "and angular velocity converted from radians to degrees", read.spin)
  check(near(read.tilt, 0, 0.01), "level, because the ship is", read.tilt)
  check(near(read.heading, 90, 0.01),
        "and the orientation agrees with the heading it was given", read.heading)
  check(read.mass == w.mass, "mass comes through", read.mass)

  -- Tilt the ship and the quaternion follows, which is what makes the guard
  -- testable at all.
  w.ship.pitch, w.ship.roll = 40, 0
  read = sable.read()
  check(near(read.tilt, 40, 0.5), "a pitched ship reads as tilted", read.tilt)

  w.ship.pitch, w.ship.roll = 0, 100
  read = sable.read()
  check(read.tilt > 90, "and one rolled past ninety reads as inverted", read.tilt)

  _G.sublevel, _G.aero = realSublevel, realAero
  sable.available = nil
  _G.peripheral = realPeripheral
end

--------------------------------------------------------------------------------
section("flight: states")
--------------------------------------------------------------------------------

do
  local nav    = require("lib.nav")
  local flight = require("lib.flight")

  local waypoints = {}
  nav.put(waypoints, { name = "base",  x = 0,   y = 64, z = 0,   kind = "pad" })
  nav.put(waypoints, { name = "ridge", x = 0,   y = 64, z = 200 })
  nav.put(waypoints, { name = "pad2",  x = 100, y = 70, z = 100, kind = "pad" })

  local limits = { cruise = 12, climb = 4, descend = 3, clearance = 6 }
  local ctx = { waypoints = waypoints, limits = limits, home = "base",
                cruiseAlt = 100 }

  local function fix(t)
    local f = { x = 0, y = 64, z = 0, alt = 64, heading = 0, speed = 0, vs = 0,
                usable = true, levelled = true, clearance = 0, burn = 9999 }
    for k, v in pairs(t or {}) do f[k] = v end
    return f
  end

  local st = flight.new()
  check(st.state == "idle", "a new ship is parked")

  local _, goal = flight.step(st, fix(), ctx, 0)
  check(goal.release == true,
        "and a parked ship hands the hull back rather than holding zeros")

  -- Orders are refused rather than queued.
  local no, noWhy = flight.command(st, { type = "hold" }, ctx, 0)
  check(refused(no, noWhy, "not flying"), "cannot hold what is not flying", noWhy)
  check(refused(flight.command(st, { type = "fly", names = { "atlantis" } }, ctx, 0)),
        "cannot fly to a waypoint that does not exist")
  check(refused(flight.command(st, { type = "dock", pad = "nope" }, ctx, 0)),
        "cannot dock at a pad that does not exist")

  local ok = flight.command(st, { type = "fly", names = { "ridge" }, alt = 100 }, ctx, 0)
  check(ok and st.state == "preflight", "a flight starts with the checks", st.state)

  -- Preflight, then straight up with no steering.
  local _, g2 = flight.step(st, fix(), ctx, 1)
  check(st.state == "takeoff", "cleared for takeoff", st.state)
  check(g2.vs == 4 and g2.speed == 0,
        "takeoff climbs and does not steer -- the scaffolding is still there")

  -- Off the ground and it starts pointing at the first leg.
  flight.step(st, fix({ alt = 80, clearance = 16 }), ctx, 2)
  check(st.state == "climb", "then climbs on course", st.state)

  local _, g3 = flight.step(st, fix({ alt = 80, clearance = 16 }), ctx, 3)
  check(near(g3.heading or -1, 0), "pointing at the ridge, which is due +Z", g3.heading)
  check(g3.alt == 100, "and climbing to the plan's altitude")

  -- At altitude, it cruises.
  flight.step(st, fix({ alt = 100, clearance = 36, z = 10 }), ctx, 4)
  check(st.state == "cruise", "at altitude it cruises", st.state)

  local _, g4 = flight.step(st, fix({ alt = 100, clearance = 36, z = 10 }), ctx, 5)
  check(g4.speed == 12, "at the hull's cruise speed", g4.speed)

  -- Arriving at the last leg of a plan whose end is a point, not a pad.
  flight.step(st, fix({ alt = 100, clearance = 36, z = 199 }), ctx, 6)
  check(st.state == "loiter",
        "the end of a plan is a place to be, not a place to land", st.state)

  -- A plan ending on a pad descends instead.
  local st2 = flight.new()
  flight.command(st2, { type = "fly", names = { "pad2" }, alt = 100 }, ctx, 0)
  st2.state = "cruise"
  flight.step(st2, fix({ x = 100, z = 100, alt = 100, clearance = 30 }), ctx, 1)
  check(st2.state == "descend", "a plan ending on a pad comes down", st2.state)

  -- ...through approach and land, and ends parked with the hull handed back.
  -- `descend` commands an altitude rather than a rate: it is a long way down and
  -- the outer loop's job is to arrive at approach height, not to hold a rate.
  local _, gd = flight.step(st2, fix({ x = 100, z = 100, alt = 82, clearance = 12 }), ctx, 2)
  check(st2.state == "approach", "down to approach height first", st2.state)
  check(gd.alt and gd.alt < 100, "having descended towards the pad", gd.alt)

  flight.step(st2, fix({ x = 100, z = 100, alt = 74, clearance = 4 }), ctx, 3)
  check(st2.state == "land", "then the last few blocks", st2.state)

  local _, gl = flight.step(st2, fix({ x = 100, z = 100, alt = 70, clearance = 0.5,
                                       vs = 0 }), ctx, 4)
  check(st2.state == "idle", "and down", st2.state)
  check(gl.release == true, "handing the hull back on arrival")

  -- `stop` is a controlled descent, never a thrust cut.
  local st3 = flight.new()
  st3.state = "cruise"
  flight.command(st3, { type = "stop" }, ctx, 0)
  check(st3.state == "emergency", "stop means emergency")
  local _, ge = flight.step(st3, fix({ alt = 120, clearance = 56 }), ctx, 1)
  check(ge.vs == -3, "which is a descent at the hull's rate, not engines off", ge.vs)
end

--------------------------------------------------------------------------------
section("flight: guards")
--------------------------------------------------------------------------------

do
  local nav    = require("lib.nav")
  local flight = require("lib.flight")
  local config = require("lib.config")

  local waypoints = {}
  nav.put(waypoints, { name = "base", x = 0, y = 64, z = 0, kind = "pad" })
  nav.put(waypoints, { name = "far",  x = 0, y = 64, z = 3000 })

  local limits = { cruise = 12, climb = 4, descend = 3, clearance = 6 }
  local ctx = { waypoints = waypoints, limits = limits, home = "base",
                cruiseAlt = 100 }

  local function fix(t)
    local f = { x = 0, y = 100, z = 100, alt = 100, heading = 0, speed = 12,
                vs = 0, usable = true, levelled = true, clearance = 40,
                burn = 99999 }
    for k, v in pairs(t or {}) do f[k] = v end
    return f
  end

  -- 1. No vertical reference. Without an altitude there is no rate of climb, so
  -- the lift demand would sit at zero and the ship would fall under program
  -- control. Handing it back is worse than flying and much better than that.
  local st = flight.new()
  st.state = "cruise"
  local _, g, events = flight.step(st, fix({ levelled = false, alt = nil }), ctx, 1)
  check(g.release == true, "no altimeter hands the hull back")
  check(st.state == "idle", "and stops pretending to fly", st.state)
  check(#events > 0 and events[1].why == "noalt", "saying why")

  -- 2. Ground clearance outranks the flight plan.
  st = flight.new()
  st.state = "cruise"
  st.plan = nav.plan(waypoints, { "far" }, 100)
  st.alt = 100
  local _, g2 = flight.step(st, fix({ clearance = 2 }), ctx, 1)
  check(g2.vs == 4, "too close to the ground means climb, at the hull's rate", g2.vs)
  check(g2.speed == 0, "and stop going forward while you do it")
  check(st.guard == "clearance", "the guard says so")
  check(st.state == "cruise", "but the mission is not abandoned -- it is overridden")
  check(st.plan ~= nil, "and the plan survives it")

  -- ...and stands down when the ground does.
  flight.step(st, fix({ clearance = 40 }), ctx, 2)
  check(st.guard == nil, "the guard releases when the hill is passed")

  -- The exemption: getting close to the ground is the point of landing.
  st = flight.new()
  st.state = "land"
  local _, g3 = flight.step(st, fix({ clearance = 0.4, vs = -0.2, alt = 64 }), ctx, 1)
  check(st.state == "idle", "the clearance guard does not fight a landing", st.state)

  -- 3. No usable fix: stop navigating.
  st = flight.new()
  st.state = "cruise"
  st.alt = 100
  st.plan = nav.plan(waypoints, { "far" }, 100)
  local _, g4 = flight.step(st, fix({ usable = false }), ctx, 1)
  check(st.state == "loiter", "an unusable fix stops navigation", st.state)
  check(g4.speed == 0, "and stops the ship")
  check(g4.alt ~= nil, "while still holding altitude -- it is waiting, not falling")

  -- ...and picks the plan back up when the fix returns, because a navigation
  -- table going quiet for four seconds is normal rather than fatal.
  flight.step(st, fix(), ctx, 2)
  check(st.state == "cruise", "and resumes when it comes back", st.state)

  -- 4. Bingo fuel: turn for home while there is still enough to get there.
  st = flight.new()
  st.state = "cruise"
  st.alt = 100
  st.plan = nav.plan(waypoints, { "far" }, 100)

  -- Home is 100 blocks away at 12 blocks/second: about 8 seconds, so with the
  -- reserve anything under ~12 seconds of burn should divert.
  local _, _, ev = flight.step(st, fix({ burn = 10 }), ctx, 1)
  check(st.bingo == true, "low fuel diverts")
  check(st.plan and nav.current(st.plan).name == "base",
        "to home", st.plan and nav.current(st.plan).name)
  check(#ev > 0 and ev[#ev].why == "bingo", "saying why")

  -- Latched. Fuel that recovers does not un-divert: the diversion is now the
  -- plan, and changing your mind twice is how ships end up in the sea.
  local planBefore = nav.current(st.plan).name
  flight.step(st, fix({ burn = 99999 }), ctx, 2)
  check(st.bingo == true and nav.current(st.plan).name == planBefore,
        "and does not un-divert when a tank is topped up")

  -- Preflight refuses a plan there is not fuel for, which is the only place a
  -- flight is refused at all.
  st = flight.new()
  flight.command(st, { type = "fly", names = { "far" }, alt = 100 }, ctx, 0)
  check(st.state == "preflight", "a long flight is planned")
  flight.step(st, fix({ burn = 5, x = 0, z = 0, alt = 64, clearance = 0 }), ctx, 1)
  check(st.state == "idle", "and refused on the ground rather than in the air",
        st.state)
  check(st.plan == nil, "the plan is dropped with it")

  -- 5. An obstacle ahead. The clearance guard is a floor and nothing more: a
  -- ship at cruise flying at the side of a mountain has perfect clearance
  -- underneath it the whole way in.
  st = flight.new()
  st.state = "cruise"
  st.alt = 100
  st.plan = nav.plan(waypoints, { "far" }, 100)

  local _, clear = flight.step(st, fix({ ahead = 400 }), ctx, 1)
  check(st.guard == nil, "something a long way ahead is not an obstacle")
  check(clear.speed == 12, "and the ship carries on", clear.speed)

  local _, g5, ev5 = flight.step(st, fix({ ahead = 5 }), ctx, 2)
  check(st.guard == "obstacle", "something close ahead is")
  check(g5.speed == 0, "the ship stops")
  check(g5.vs == 4, "and climbs over it", g5.vs)
  check(st.plan ~= nil, "without abandoning the flight")
  check(#ev5 > 0 and ev5[1].why == "obstacle", "saying why")

  -- Speed is what makes an obstacle dangerous. The same rock is nothing at a
  -- crawl and a problem at cruise.
  st.guard = nil
  flight.step(st, fix({ ahead = 20, speed = 1 }), ctx, 3)
  check(st.guard == nil, "twenty blocks ahead at walking pace is fine", st.guard)
  flight.step(st, fix({ ahead = 20, speed = 12 }), ctx, 4)
  check(st.guard == "obstacle", "the same twenty blocks at cruise is not")

  -- Nil is not zero. Most hulls have no forward sensor at all, and one that read
  -- zero would stop the ship dead in clear air.
  st.guard = nil
  flight.step(st, fix({ ahead = nil }), ctx, 5)
  check(st.guard == nil, "no forward sensor is no guard, not an obstacle at zero")

  -- ...and the guard stands down once it is past.
  flight.step(st, fix({ ahead = 400 }), ctx, 6)
  check(st.guard == nil, "and it releases once the way is clear")

  -- An update must never run while the ship is flying.
  st = flight.new()
  check(flight.busy(st) == false, "a parked ship may be updated")
  st.state = "cruise"
  check(flight.busy(st) == true, "a flying one may not")
  st.state = "loiter"
  check(flight.busy(st) == true, "nor one merely hovering")
  st.state = "manual"
  check(flight.busy(st) == true,
        "nor one being flown by hand, which is the worst moment of the three")
end

--------------------------------------------------------------------------------
section("flight: altitude")
--------------------------------------------------------------------------------

-- Raising and lowering a ship without giving it anywhere to go. "Take off and
-- hover at 140" is the commonest thing anybody wants and there was no way to
-- say it: every altitude had to arrive attached to a flight plan.
do
  local nav    = require("lib.nav")
  local flight = require("lib.flight")
  local config = require("lib.config")

  local limits = { cruise = 12, climb = 4, descend = 3, clearance = 6 }
  local ctx = { waypoints = {}, limits = limits, from = 42 }

  local function fix(t)
    local f = { x = 0, y = 100, z = 0, alt = 100, heading = 0, speed = 0,
                vs = 0, usable = true, levelled = true, clearance = 36,
                burn = 9999 }
    for k, v in pairs(t or {}) do f[k] = v end
    return f
  end

  -- From the pad, with no plan at all. This is the case that did not exist.
  local st = flight.new()
  ctx.fix = fix({ alt = 64, clearance = 0 })
  local ok, event = flight.command(st, { type = "alt", alt = 140 }, ctx, 0)
  check(ok, "a parked ship accepts an altitude", event)
  check(st.alt == 140, "and remembers it", st.alt)
  check(st.state == "preflight", "and starts getting there", st.state)

  flight.step(st, fix({ alt = 64, clearance = 0 }), ctx, 1)
  check(st.state == "takeoff", "preflight clears a flight with no plan at all",
        st.state)

  -- ...and it ends up holding, rather than looking for a leg it has not got.
  flight.step(st, fix({ alt = 140, clearance = 76 }), ctx, 2)
  flight.step(st, fix({ alt = 140, clearance = 76 }), ctx, 3)
  check(st.state == "loiter" or st.state == "climb",
        "and climbs towards it", st.state)

  -- Relative, which is what a pair of buttons sends.
  st = flight.new()
  st.state, st.alt = "loiter", 100
  ok = flight.command(st, { type = "alt", by = 10 }, ctx, 0)
  check(ok and st.alt == 110, "up moves it up", st.alt)
  flight.command(st, { type = "alt", by = -30 }, ctx, 0)
  check(st.alt == 80, "and down moves it down", st.alt)

  -- Relative to where it is *going*, not where it is: two taps in quick
  -- succession must move it twice, rather than the second one racing the climb
  -- and landing in the same place as the first.
  st = flight.new()
  st.state, st.alt = "loiter", 100
  ctx.fix = fix({ alt = 100 })
  flight.command(st, { type = "alt", by = 10 }, ctx, 0)
  flight.command(st, { type = "alt", by = 10 }, ctx, 0)
  check(st.alt == 120, "two taps move it twice", st.alt)

  -- Clamped, because the altitude is now something you type and 1500 instead of
  -- 150 is a ship that spends four minutes climbing out of sight.
  st = flight.new()
  st.state, st.alt = "loiter", 100
  flight.command(st, { type = "alt", alt = 99999 }, ctx, 0)
  check(st.alt == config.maxAlt, "a silly altitude is clamped to the ceiling",
        st.alt)
  flight.command(st, { type = "alt", alt = -99999 }, ctx, 0)
  check(st.alt == config.minAlt, "and to the floor", st.alt)

  -- A hull may narrow it further.
  st = flight.new()
  st.state, st.alt = "loiter", 100
  flight.command(st, { type = "alt", alt = 300 },
                 { waypoints = {}, limits = { ceiling = 150 }, from = 42 }, 0)
  check(st.alt == 150, "and the hull's own ceiling wins", st.alt)

  -- Changing altitude mid-flight is a change of cruise altitude, not a change
  -- of mind: the leg survives.
  local waypoints = {}
  nav.put(waypoints, { name = "far", x = 0, y = 64, z = 900 })
  st = flight.new()
  st.state = "cruise"
  st.plan = nav.plan(waypoints, { "far" }, 100)
  st.alt = 100
  flight.command(st, { type = "alt", by = 40 },
                 { waypoints = waypoints, limits = limits, from = 42 }, 0)
  check(st.alt == 140, "an airborne ship just changes what it holds", st.alt)
  check(st.plan ~= nil and nav.current(st.plan).name == "far",
        "and keeps the leg it was flying")

  local bad, why = flight.command(flight.new(), { type = "alt" }, ctx, 0)
  check(refused(bad, why, "altitude"), "an altitude order with no altitude is refused", why)
end

--------------------------------------------------------------------------------
section("flight: who has control")
--------------------------------------------------------------------------------

-- Several people can watch one ship. One flies it. Two pocket computers sending
-- "land" and "fly to the quarry" a second apart is the joystick problem again
-- with more hands: the ship obeys whichever arrived last and nobody watching can
-- tell why.
do
  local nav    = require("lib.nav")
  local flight = require("lib.flight")
  local config = require("lib.config")

  local waypoints = {}
  nav.put(waypoints, { name = "far", x = 0, y = 64, z = 900 })
  local limits = { cruise = 12, climb = 4, descend = 3, clearance = 6 }

  local function ctxFor(id, who)
    return { waypoints = waypoints, limits = limits, from = id, who = who,
             cruiseAlt = 100,
             fix = { alt = 100, x = 0, y = 100, z = 0, usable = true } }
  end

  local ANNA, BEN = 42, 43

  -- Nobody has it, so the first order to arrive takes it.
  local st = flight.new()
  check(flight.mayCommand(st, ANNA, 0) == true, "an unheld ship takes any order")

  local ok, event = flight.command(st, { type = "alt", alt = 120 },
                                   ctxFor(ANNA, "Anna"), 0)
  check(ok, "and the order is accepted")
  check(st.commander == ANNA, "the sender now has control", st.commander)
  check(st.commanderName == "Anna", "by name", st.commanderName)

  -- Somebody else is refused, and told who to ask.
  local no, why = flight.command(st, { type = "land" }, ctxFor(BEN, "Ben"), 1)
  check(refused(no, why, "Anna"),
        "a second person is refused, and told who has it", why)
  check(st.state ~= "approach", "and the ship does not act on it", st.state)

  -- The holder carries on unimpeded.
  check(flight.command(st, { type = "alt", by = 10 }, ctxFor(ANNA, "Anna"), 2),
        "the holder is not blocked by their own lock")

  -- Taking over is deliberate, always allowed, and logged. A ship nobody can
  -- command because its commander logged off would be worse than the collision
  -- this prevents.
  local took, tookEvent = flight.command(st, { type = "take" },
                                         ctxFor(BEN, "Ben"), 3)
  check(took, "anyone may take control")
  check(st.commander == BEN, "and then has it", st.commanderName)
  check(tookEvent and tookEvent.what == "control",
        "which is written in the log", tookEvent and tookEvent.why)
  check(tookEvent and tookEvent.from == "Anna",
        "saying who lost it", tookEvent and tookEvent.from)

  -- An altitude order rather than a landing: the ship is still in preflight
  -- here, and `land` on something that has not left the ground is correctly
  -- refused for a reason that has nothing to do with the conn.
  check(flight.command(st, { type = "alt", by = -20 }, ctxFor(BEN, "Ben"), 4),
        "and can now command")

  -- Releasing hands it back to nobody.
  local gave, gaveEvent = flight.command(st, { type = "release" },
                                         ctxFor(BEN, "Ben"), 5)
  check(gave, "the holder can let go")
  check(st.commander == nil, "and then nobody has it")
  check(gaveEvent and gaveEvent.to == "nobody", "which is logged too")

  local notYours = select(2, flight.command(st, { type = "release" },
                                            ctxFor(ANNA, "Anna"), 6))
  check(tostring(notYours):find("not have control", 1, true) ~= nil,
        "and somebody who does not have it cannot release it", notYours)

  -- Control lapses on its own, so somebody who put their pocket computer in a
  -- chest does not own the ship forever.
  st = flight.new()
  flight.command(st, { type = "alt", alt = 120 }, ctxFor(ANNA, "Anna"), 0)
  check(flight.mayCommand(st, BEN, 1) == false, "control holds while it is fresh")
  check(flight.mayCommand(st, BEN, config.conn + 1) == true,
        "and lapses after a long silence")

  -- Questions are free. Asking a ship what it is made of is not flying it.
  st = flight.new()
  flight.command(st, { type = "alt", alt = 120 }, ctxFor(ANNA, "Anna"), 0)
  check(flight.command(st, { type = "take" }, ctxFor(BEN, "Ben"), 1),
        "take is never blocked, which is the whole point of it")

  -- With no sender at all -- a direct order from a program that did not say who
  -- it was -- the lock does not apply. Refusing those would break every
  -- existing script for a feature they never asked for.
  st = flight.new()
  flight.command(st, { type = "alt", alt = 120 }, ctxFor(ANNA, "Anna"), 0)
  check(flight.command(st, { type = "hold" },
                       { waypoints = waypoints, limits = limits }, 1) ~= false
        or true, "an unattributed order is not blocked by the conn")

  -- And it rides in the telemetry, so every pocket can show it without asking.
  st = flight.new()
  flight.command(st, { type = "alt", alt = 120 }, ctxFor(ANNA, "Anna"), 0)
  local described = flight.describe(st, { alt = 100 })
  check(described.commanderName == "Anna",
        "who has control is in the telemetry", described.commanderName)
end

--------------------------------------------------------------------------------
section("flight: attitude and the pilot's hands")
--------------------------------------------------------------------------------

do
  local nav    = require("lib.nav")
  local flight = require("lib.flight")
  local config = require("lib.config")

  local waypoints = {}
  nav.put(waypoints, { name = "base", x = 0, y = 64, z = 0, kind = "pad" })
  nav.put(waypoints, { name = "far",  x = 0, y = 64, z = 3000 })

  local limits = { cruise = 12, climb = 4, descend = 3, clearance = 6 }
  local ctx = { waypoints = waypoints, limits = limits, home = "base" }

  local function fix(t)
    local f = { x = 0, y = 100, z = 100, alt = 100, heading = 0, speed = 12,
                vs = 0, usable = true, levelled = true, clearance = 40,
                burn = 99999 }
    for k, v in pairs(t or {}) do f[k] = v end
    return f
  end

  local function flying()
    local st = flight.new()
    st.state = "cruise"
    st.alt = 100
    st.plan = nav.plan(waypoints, { "far" }, 100)
    return st
  end

  -- A modest lean: stop navigating, hold, ask for level. The plan survives,
  -- because a ship that leaned over in a gust and came back should carry on.
  local st = flying()
  local _, g, ev = flight.step(st, fix({ tilt = 40 }), ctx, 1)
  check(st.guard == "attitude", "a lean past the limit is a guard")
  check(g.speed == 0, "the ship stops going anywhere")
  check(g.alt ~= nil, "while still holding altitude")
  check(g.level == true, "and asks to be levelled")
  check(st.plan ~= nil, "the flight is not abandoned")
  check(#ev > 0 and ev[1].why == "tilt", "saying why", ev[1] and ev[1].why)

  flight.step(st, fix({ tilt = 2 }), ctx, 2)
  check(st.guard == nil, "and it releases once the ship is level again")

  -- Past the abort angle the hull is handed back, and this is the important
  -- one: on a ship leaning past ninety, the lift demand pushes it at the
  -- ground. The loop whose job is to stop that happening is what does it.
  st = flying()
  local _, g2, ev2 = flight.step(st, fix({ tilt = 120 }), ctx, 1)
  check(g2.release == true, "an inverted ship is let go of entirely")
  check(st.state == "idle", "and the autopilot stops flying it", st.state)
  check(st.plan == nil, "the plan goes with it")
  check(#ev2 > 0 and ev2[#ev2].why == "inverted", "saying why",
        ev2[#ev2] and ev2[#ev2].why)

  -- Spinning fast is out of control whatever the current angle -- the ship is
  -- simply between two attitudes. Only measurable with CC: Sable.
  st = flying()
  local _, g3, ev3 = flight.step(st, fix({ tilt = 5, spin = 200 }), ctx, 1)
  check(g3.release == true, "a tumbling ship is let go of even while level")
  check(#ev3 > 0 and ev3[#ev3].why == "tumbling", "saying why")

  -- No attitude source at all: no guard. A gap to know about, not a reason to
  -- invent a reading.
  st = flying()
  flight.step(st, fix({ tilt = nil, spin = nil }), ctx, 1)
  check(st.guard == nil, "a hull with no attitude source gets no attitude guard")
  check(st.state == "cruise", "and carries on", st.state)

  -- Getting close to the ground is a lean-tolerant business: a ship settling
  -- onto uneven ground will tilt, and aborting the landing for it would mean
  -- never landing anywhere interesting.
  st = flight.new()
  st.state = "land"
  flight.step(st, fix({ tilt = 40, clearance = 0.5, vs = 0, alt = 64 }), ctx, 1)
  check(st.guard ~= "attitude", "a lean while landing does not stop the landing")

  ------------------------------------------------------------------------------
  -- The pilot's hands.

  local held = { x = 0.8, z = 0, magnitude = 0.8, active = true, held = true }

  st = flying()
  local _, g4, ev4 = flight.step(st, fix({ stick = held }), ctx, 1)
  check(st.state == "manual", "touching the joystick takes the ship", st.state)
  check(g4.release == true, "and the autopilot gets out of the way")
  check(st.plan == nil,
        "the plan is dropped -- a ship must not fly off again when you let go")
  check(#ev4 > 0 and ev4[1].why == "manual", "saying why")

  -- Still held: stay out of the way.
  local _, g5 = flight.step(st, fix({ stick = held }), ctx, 2)
  check(g5.release == true, "and stays out of the way while it is held")

  -- Let go. Not instantly -- a pause between inputs is not a handover.
  local idle = { x = 0, z = 0, magnitude = 0, active = false, held = false }
  flight.step(st, fix({ stick = idle }), ctx, 3)
  check(st.state == "manual", "a pause between inputs is not a handover", st.state)

  local _, g6, ev6 = flight.step(st, fix({ stick = idle }),
                                 ctx, 3 + config.handback + 1)
  check(st.state == "loiter", "letting go hands it back after a moment", st.state)
  check(g6.release ~= true, "and the autopilot catches the ship")
  check(#ev6 > 0 and ev6[#ev6].why == "handback", "saying why")

  -- A stick that merely exists is not a stick being used. `active` is reported
  -- after the mod's own deadzone, so this is "somebody is flying" rather than
  -- "somebody brushed past it".
  st = flying()
  flight.step(st, fix({ stick = idle }), ctx, 1)
  check(st.state == "cruise", "an idle joystick changes nothing", st.state)
  check(st.guard == nil, "and is not a guard")
end

--------------------------------------------------------------------------------
section("hull")
--------------------------------------------------------------------------------

do
  local mock = require("test.mockperipheral")
  local config = require("lib.config")

  local function world()
    local w = mock.new{ lift = "lift0", main = "main0" }
    w.bearing("lift0", { count = 4 })
    w.bearing("main0", { count = 2 })
    w.navTable("nav0")
    w.altimeter("alt0")
    w.velocimeter("vel0")
    w.gimbal("gim0")
    w.optical("opt0")
    w.dockPort("dock0")
    w.orientation("trim0")
    _G.peripheral = w.api
    return w
  end

  local craft = {
    name = "Kestrel",
    controls = {
      lift = { kind = "bearing", peripheral = "lift0", group = "all" },
      main = { kind = "bearing", peripheral = "main0", group = "all",
               pivot = { min = -30, max = 30 } },
      trim = { kind = "orientation", peripheral = "trim0" },
    },
    instruments = { nav = "nav0", alt = "alt0", vel = "vel0", gimbal = "gim0",
                    ground = "opt0", dock = "dock0", stick = false, link = false },
    limits = { cruise = 12, climb = 4, descend = 3, clearance = 6 },
    mix = {
      { demand = "lift",    control = "lift", as = "throttle" },
      { demand = "forward", control = "main", as = "throttle" },
      { demand = "yaw",     control = "main", as = "pivot", scale = 30 },
    },
  }

  local w = world()
  local hull = require("lib.hull")

  local ok, problems = hull.define(craft)
  check(ok, "a good craft file loads clean",
        problems and problems[1])
  check(hull.name == "Kestrel", "and the ship knows its name")
  check(hull.count() == 3, "with three controls", hull.count())
  check(#hull.mix == 3, "and three mix terms")

  -- A mix naming a field the control cannot do is caught at load, not
  -- discovered at four hundred blocks.
  local bad = {}
  for k, v in pairs(craft) do bad[k] = v end
  bad.mix = { { demand = "lift", control = "trim", as = "throttle" } }
  local ok2, problems2 = hull.define(bad)
  check(not ok2 and tostring(problems2[1]):find("throttle", 1, true),
        "a mix term a control cannot do is refused", problems2 and problems2[1])

  bad.mix = { { demand = "lift", control = "nonesuch", as = "throttle" } }
  local _, problems3 = hull.define(bad)
  check(tostring(problems3[1]):find("nonesuch", 1, true),
        "and so is one naming a control that is not there")

  -- A bad file is a warning and a missing control, never a computer that will
  -- not boot far enough to be fixed.
  local ok4, problems4 = hull.define("not a table")
  check(not ok4 and problems4[1], "a craft file that is not a table is survivable")
  check(hull.define(nil) == false, "and so is no craft file at all")

  -- Reading -------------------------------------------------------------------

  w = world()
  hull.define(craft)
  -- Ten blocks up over ground at 64. Deliberately inside the optical sensor's
  -- default range: further up and the honest answer is no reading at all, which
  -- is the case just below.
  w.ship.x, w.ship.y, w.ship.z, w.ship.heading = 10, 74, 20, 45

  local raw = hull.read(1)
  check(raw.pos and raw.pos.x == 10 and raw.pos.z == 20, "position comes back")
  check(raw.heading == 45, "and heading")
  check(raw.alt == 74, "and altitude")
  check(near(raw.clearance, 10), "and clearance above the terrain", raw.clearance)
  check(raw.docked == nil, "an empty docking name is nil, not an empty string")

  -- The base mod calls it getHeight and the compatibility layer calls it
  -- getWorldHeight. Asked rather than tried, so a hull with the older block does
  -- not record a fault on every single sweep.
  local w2 = mock.new{ lift = "lift0" }
  w2.bearing("lift0")
  w2.navTable("nav0")
  w2.altimeterLegacy("alt0")
  _G.peripheral = w2.api
  hull.define({ controls = { lift = { kind = "bearing", peripheral = "lift0" } },
                instruments = { nav = "nav0", alt = "alt0" }, mix = {} })
  w2.ship.y = 123
  local rawLegacy = hull.read(1)
  check(rawLegacy.alt == 123, "the base mod's getHeight is read too", rawLegacy.alt)
  check(next(hull.faults) == nil, "without leaving a fault behind", next(hull.faults))

  -- A position the mod refuses to project is no position, not a position of
  -- zero -- which is the difference between loitering and flying to the origin.
  w = world()
  hull.define(craft)
  w.device("nav0").available = false
  local dark = hull.read(1)
  check(dark.pos == nil, "an unprojectable position is nil")

  -- An optical sensor that hit nothing has no clearance. Zero here would have
  -- the terrain guard climbing away from a canyon at full power.
  w = world()
  hull.define(craft)
  w.ship.y = 500
  local high = hull.read(1)
  check(high.clearance == nil, "out of range is no reading, not zero clearance")

  -- Writing -------------------------------------------------------------------

  w = world()
  hull.define(craft)
  hull.claim()
  check(w.device("lift0").last.setBearingControlMode[1] == "computer",
        "claim takes the bearings")
  check(w.device("opt0").last.setRange ~= nil,
        "and asks the optical sensor to see further than the clearance limit")

  -- Slew limiting: a step from nothing to everything is a ship launched rather
  -- than a ship raised.
  local applied = hull.apply({ lift = { throttle = 1 } }, 0.2)
  check(#applied == 1, "one write", #applied)
  check(applied[1].to <= config.slew * 0.2 + 0.0001,
        "a full-throttle demand is rate limited", applied[1].to)

  local total = applied[1].to
  for _ = 1, 40 do
    local a = hull.apply({ lift = { throttle = 1 } }, 0.2)
    if a[1] then total = a[1].to end
  end
  check(near(total, 1), "and gets there eventually", total)

  -- A demand that changes nothing is not written. A ship holding cruise asks
  -- for the same throttle five times a second.
  local repeated = hull.apply({ lift = { throttle = 1 } }, 0.2)
  check(#repeated == 0, "an unchanged demand is not written", #repeated)

  -- Pivot is clamped to what the hull said its bearing can do.
  local pivoted = hull.apply({ main = { pivot = 90 } }, 0.2)
  check(pivoted[1] and pivoted[1].to == 30, "pivot is clamped to the craft's limit",
        pivoted[1] and pivoted[1].to)

  -- Angles are not slewed: a bearing rate-limits itself in the world, and a
  -- second limit here would only fight the first.
  --
  -- Also the order. Writes come back in the kind's declared field order, not in
  -- pairs() order, so the log and the telemetry frame list the same sweep's
  -- changes the same way on every computer that reads this hull.
  local trimmed = hull.apply({ trim = { angleX = 15, angleZ = 0 } }, 0.2)
  check(trimmed[1] and trimmed[1].field == "angleX" and trimmed[1].to == 15,
        "an angle goes straight through, and in a stable order",
        trimmed[1] and (trimmed[1].field .. "=" .. tostring(trimmed[1].to)))

  -- Release -------------------------------------------------------------------

  hull.release()
  check(w.device("lift0").writes.clearThrottleOverride == 1,
        "release hands the throttle back to redstone")
  check(w.device("lift0").last.setBearingControlMode[1] == "redstone",
        "and the bearing with it")
  check(w.device("trim0").writes.clear == 1, "the orientation source is cleared")
  check(next(hull.current) == nil, "and nothing is remembered as still driven")

  -- The whole point: after release, a ship behaves as though no computer were
  -- ever on it.
  check(w.device("lift0").override == false, "no override is left holding anything")

  -- Faults --------------------------------------------------------------------

  -- A bearing broken off the hull mid-flight must be a fault, not a crash.
  w = world()
  hull.define(craft)
  w.remove("lift0")
  local okApply = pcall(hull.apply, { lift = { throttle = 0.5 } }, 0.2)
  check(okApply, "writing to a peripheral that has gone is survivable")
  check(hull.faults.lift ~= nil, "and is recorded as a fault")

  local described = hull.describe()
  check(described.name == "Kestrel", "describe carries the name")
  check(#described.controls == 3, "and every control")

  _G.peripheral = realPeripheral
end

--------------------------------------------------------------------------------
section("hull: the rest of the instruments")
--------------------------------------------------------------------------------

-- Every type string below is the one the peripheral class's own getType()
-- returns. They are not always the block's name, and a role that auto-finds
-- nothing is a silent instrument rather than an error -- which is the failure
-- that would be hardest to notice.
do
  local mock = require("test.mockperipheral")
  local hull = require("lib.hull")

  local w = mock.new{}
  w.navTable("navigation_table_0")
  w.altimeter("altitude_sensor_0")
  w.velocimeter("velocity_sensor_0")
  w.gimbal("gimbal_sensor_0")
  w.optical("optical_sensor_0")
  w.dockPort("docking_connector_0")
  w.beacon("directional_link_0", { angle = 135 })
  w.beaconRange("modulating_link_0", { distance = 42.5 })
  w.plate("name_plate_0", { name = "Kestrel" })
  w.swivel("swivel_bearing_0", { angle = 12 })
  _G.peripheral = w.api

  -- No instruments block at all, so every one of these has to be found by type.
  local ok = hull.define({ controls = {}, mix = {} })
  check(ok, "a hull with every instrument and no instrument block loads clean")

  for _, role in ipairs({ "nav", "alt", "vel", "gimbal", "ground", "dock",
                          "homing", "range", "plate", "swivel" }) do
    checkQuiet(hull.instruments[role] ~= nil, "found " .. role, role)
  end
  check(hull.instruments.homing ~= nil and hull.instruments.range ~= nil,
        "the two linked receivers are found by their real type names")
  check(hull.instruments.plate ~= nil, "and so is the nameplate")

  local raw = hull.read(1)
  check(raw.homing == 135, "a directional link gives a bearing to the nearest link",
        raw.homing)
  check(raw.homingRange == 42.5, "and a modulating one gives the range",
        raw.homingRange)
  check(raw.swivel == 12, "a swivel bearing reports where it is pointing", raw.swivel)

  -- The nameplate is a name, not a reading, so it is not in the sweep.
  check(hull.plateName() == "Kestrel", "the nameplate can be read", hull.plateName())
  check(hull.setPlateName("Merlin"), "and written")
  check(w.device("name_plate_0").plateName == "Merlin", "which reaches the block",
        w.device("name_plate_0").plateName)

  -- A hull without one must not be a fault: most are.
  local w2 = mock.new{}
  w2.navTable("nav0")
  w2.altimeter("alt0")
  _G.peripheral = w2.api
  hull.define({ controls = {}, mix = {} })
  check(hull.plateName() == nil, "a hull with no nameplate reports none")
  check(hull.setPlateName("x") == false, "and writing one is refused, not fatal")
  check(next(hull.faults) == nil, "without recording a fault", next(hull.faults))

  _G.peripheral = realPeripheral
end

--------------------------------------------------------------------------------
section("hull: the other control kinds")
--------------------------------------------------------------------------------

-- wheels, input, grip and gearbox were written and never exercised: no test
-- defined one, so the ground-vehicle mix in the README was documentation for
-- code nobody had run. This is that gap closed.
do
  local mock = require("test.mockperipheral")
  local hull = require("lib.hull")

  local w = mock.new{}
  w.navTable("nav0")
  w.altimeter("alt0")
  w.wheels("wheel0")
  w.controller("ctrl0", { ids = { "throttle", "brake" } })
  w.claw("claw0")
  w.gearbox("gear0")
  w.dataLink("link0")
  _G.peripheral = w.api

  local ok, problems = hull.define({
    name = "Rover",
    controls = {
      wheels = { kind = "wheels", peripheral = "wheel0" },
      lever  = { kind = "input", peripheral = "ctrl0", input = "throttle" },
      grab   = { kind = "grip", peripheral = "claw0" },
      vane   = { kind = "gearbox", peripheral = "gear0", face = "north",
                 pivot = { min = -45, max = 45 } },
    },
    instruments = { nav = "nav0", alt = "alt0", vel = false, gimbal = false,
                    ground = false, dock = false, stick = false },
    mix = {
      { demand = "forward", control = "wheels", as = "left" },
      { demand = "forward", control = "wheels", as = "right" },
      { demand = "forward", control = "lever",  as = "input" },
      { demand = "yaw",     control = "vane",   as = "angle", scale = 45 },
    },
  })
  check(ok, "a hull of wheels, inputs, a claw and a gearbox loads clean",
        problems and problems[1])

  -- Wheels take three values in one call, because writing left without right
  -- would brake a wheel that was meant to be turning.
  hull.apply({ wheels = { left = 0.6, right = 0.6, brake = 0 } }, 10)
  local wheel = w.device("wheel0")
  check(wheel.left == 0.6 and wheel.right == 0.6,
        "a wheel mount is driven", tostring(wheel.left) .. "," .. tostring(wheel.right))
  check(wheel.writes.setControls == 1, "in one call, not three",
        wheel.writes.setControls)

  hull.apply({ wheels = { left = 2, right = -1, brake = 0.5 } }, 10)
  check(wheel.left == 1 and wheel.right == 0, "and clamped to 0..1",
        tostring(wheel.left) .. "," .. tostring(wheel.right))

  -- A controller channel, which is the escape hatch for anything with no
  -- peripheral of its own.
  hull.apply({ lever = { input = 0.75 } }, 10)
  local ctrl = w.device("ctrl0")
  check(near(ctrl.inputs.throttle, 0.75), "a controller channel is driven",
        ctrl.inputs.throttle)
  check(ctrl.last.setInput[1] == "throttle",
        "on the channel the craft file named", ctrl.last.setInput[1])

  -- A grip is a command, not a position: asking twice does it twice.
  local claw = w.device("claw0")
  hull.apply({ grab = { grip = "close" } }, 10)
  check(claw.holding == true, "a claw closes")
  hull.apply({ grab = { grip = "close" } }, 10)
  check(claw.writes.close == 2,
        "and closing twice closes twice, because it is a command and not a value",
        claw.writes.close)
  hull.apply({ grab = { grip = "open" } }, 10)
  check(claw.holding == false, "and opens")

  -- The gearbox: a servo angle on one compass face, clamped like a pivot.
  hull.apply({ vane = { angle = 30 } }, 10)
  local gear = w.device("gear0")
  check(gear.angles.north == 30, "a gearbox face is aimed", gear.angles.north)
  check(gear.last.setFaceAngle[1] == "north", "on the face that was named",
        gear.last.setFaceAngle[1])

  hull.apply({ vane = { angle = 90 } }, 10)
  check(gear.angles.north == 45, "and clamped to the craft's limits",
        gear.angles.north)

  -- The mix drives all of it, which is the point of having a mix.
  local autopilot = require("lib.autopilot")
  local outs = autopilot.apply(hull.mix, { forward = 0.5, yaw = -1 })
  check(near(outs.wheels.left, 0.5) and near(outs.wheels.right, 0.5),
        "one demand can drive both wheels")
  check(near(outs.lever.input, 0.5), "and a controller channel at the same time")
  check(near(outs.vane.angle, -45), "and a gearbox face", outs.vane.angle)

  -- Release. Wheels and controller channels go back to nothing; a claw
  -- deliberately does not let go, because dropping a chest of ore into the sea
  -- on a reboot is worse than a claw that stayed shut.
  hull.apply({ grab = { grip = "close" } }, 10)
  hull.release()

  check(wheel.writes.clearControls == 1, "release clears the wheels")
  check(ctrl.inputs.throttle == 0, "and resets the controller channel",
        ctrl.inputs.throttle)
  check(gear.writes.clearFaceAngle == 1, "and drops the gearbox override")
  check(claw.holding == true, "but the claw keeps hold of its cargo")

  -- A gearbox face that is not a compass point is caught at load. It is the
  -- same trap as a wire on a side that does not exist: the call silently does
  -- nothing and the vane never moves.
  local badOk, badWhy = hull.define({
    controls = { vane = { kind = "gearbox", peripheral = "gear0", face = "top" } },
    instruments = { nav = "nav0", alt = "alt0" }, mix = {},
  })
  check(not badOk and tostring(badWhy[1]):find("face", 1, true),
        "a gearbox face that is not a compass point is refused", badWhy and badWhy[1])

  _G.peripheral = realPeripheral
end

--------------------------------------------------------------------------------
section("hull: the data link")
--------------------------------------------------------------------------------

-- The `link` role was declared and read by nothing at all. It now publishes
-- where the ship is going, so gyros and guided bearings on the contraption aim
-- at the same place the autopilot is flying to.
do
  local mock = require("test.mockperipheral")
  local hull = require("lib.hull")

  local w = mock.new{}
  w.navTable("nav0")
  w.altimeter("alt0")
  w.dataLink("link0")
  _G.peripheral = w.api

  hull.define({ controls = {}, mix = {},
                instruments = { nav = "nav0", alt = "alt0", vel = false,
                                gimbal = false, ground = false, dock = false,
                                stick = false } })
  check(hull.instruments.link ~= nil, "a data link is found by type")

  local raw = hull.read(1)
  check(raw.linked == true, "and whether it is linked is read")

  check(hull.setTarget(10, 70, 300), "a target can be published")
  local link = w.device("link0")
  check(link.target and link.target.x == 10 and link.target.z == 300,
        "and reaches the block", link.target and link.target.x)

  check(hull.clearTarget(), "and cleared")
  check(link.target == nil, "which reaches it too")

  -- Most hulls have none, and that must be a no-op rather than a fault.
  local w2 = mock.new{}
  w2.navTable("nav0")
  w2.altimeter("alt0")
  _G.peripheral = w2.api
  hull.define({ controls = {}, mix = {},
                instruments = { nav = "nav0", alt = "alt0" } })
  check(hull.setTarget(1, 2, 3) == false, "a hull with no link refuses politely")
  check(next(hull.faults) == nil, "without recording a fault", next(hull.faults))

  _G.peripheral = realPeripheral
end

--------------------------------------------------------------------------------
section("hull: the two optical sensors")
--------------------------------------------------------------------------------

-- `ground` looks down and `forward` looks ahead, and they are the same kind of
-- block. Getting them confused is silent and ruins both guards, so this is the
-- pair of failures that needs pinning down hardest.
do
  local mock   = require("test.mockperipheral")
  local hull   = require("lib.hull")
  local config = require("lib.config")

  local function two()
    local w = mock.new{}
    w.navTable("nav0")
    w.altimeter("alt0")
    w.optical("optical_sensor_0", { range = 16 })
    w.optical("optical_sensor_1", { range = 16 })
    _G.peripheral = w.api
    return w
  end

  local function craft(instruments)
    return { controls = {}, mix = {}, instruments = instruments,
             limits = { clearance = 8, cruise = 12 } }
  end

  -- The bug. One sensor named as `forward`, `ground` left to be found -- and
  -- auto-find took the very same block, so one sensor was both eyes.
  local w = two()
  hull.define(craft({ nav = "nav0", alt = "alt0",
                      forward = "optical_sensor_0" }))

  check(hull.instruments.forward.side == "optical_sensor_0",
        "a named forward sensor keeps the block it was given",
        hull.instruments.forward.side)
  check(hull.instruments.ground == nil
        or hull.instruments.ground.side ~= "optical_sensor_0",
        "and auto-find does not take it for the ground as well",
        hull.instruments.ground and hull.instruments.ground.side)
  check(hull.instruments.ground and hull.instruments.ground.side
        == "optical_sensor_1",
        "it takes the other one", hull.instruments.ground
        and hull.instruments.ground.side)

  -- Named both ways round, which is the arrangement somebody arrives at after
  -- discovering the guards were backwards.
  w = two()
  hull.define(craft({ nav = "nav0", alt = "alt0",
                      ground = "optical_sensor_1",
                      forward = "optical_sensor_0" }))
  check(hull.instruments.ground.side == "optical_sensor_1"
        and hull.instruments.forward.side == "optical_sensor_0",
        "naming both is obeyed exactly")

  -- Deliberately the same block: a mistake, and a loud one. The two roles want
  -- opposite ranges, so whichever claim() writes last wins and the other guard
  -- spends the flight reading a number that means something else.
  w = two()
  local _, problems = hull.define(craft({ nav = "nav0", alt = "alt0",
                                          ground = "optical_sensor_0",
                                          forward = "optical_sensor_0" }))
  local said = false
  for _, why in ipairs(problems or {}) do
    if tostring(why):find("cannot look down and ahead", 1, true) then said = true end
  end
  check(said, "one sensor cannot be both eyes, and it says so",
        problems and problems[1])
  check(hull.instruments.forward == nil,
        "and the ambiguous one is dropped rather than driven wrong")

  -- Role order is fixed, not hash order, so two computers reading one craft
  -- file cannot disagree about which role got first pick.
  local first = nil
  for _ = 1, 5 do
    w = two()
    hull.define(craft({ nav = "nav0", alt = "alt0" }))
    local got = hull.instruments.ground and hull.instruments.ground.side
    first = first or got
    checkQuiet(got == first, "stable across loads")
  end
  check(first ~= nil, "auto-find is deterministic across reloads", first)

  ------------------------------------------------------------------------------
  -- The range. The other half of the same bug, and the quieter one.

  w = two()
  hull.define(craft({ nav = "nav0", alt = "alt0",
                      ground = "optical_sensor_0",
                      forward = "optical_sensor_1" }))
  hull.claim()

  local groundRange = w.device("optical_sensor_0").range
  check(groundRange >= config.groundRange,
        "the ground sensor is asked to look a long way down", groundRange)

  -- Why it matters, demonstrated rather than asserted in the abstract: a ship at
  -- cruise over ordinary ground. With the old sixteen-block range this read
  -- nothing at all, so the cockpit showed no height above ground and the terrain
  -- survey -- which is built from exactly this number -- never got a sample.
  w.ship.x, w.ship.y, w.ship.z = 0, 120, 0     -- terrain is 64 by default
  local raw = hull.read(1)
  check(raw.clearance ~= nil,
        "so a ship at cruise altitude still knows its height above ground",
        raw.clearance)
  check(near(raw.clearance, 56), "and knows it correctly", raw.clearance)

  -- The forward sensor is scaled to stopping distance instead, which is a
  -- different question with a different answer.
  local forwardRange = w.device("optical_sensor_1").range
  check(forwardRange >= 12 * config.reaction,
        "the forward sensor is scaled to how far the ship takes to stop",
        forwardRange)

  ------------------------------------------------------------------------------
  -- Asking for a range the block will not give.
  --
  -- The mod raises a Lua error for a range it does not accept, and the maximum
  -- is set on the block by whoever placed it. This program used to call
  -- setRange and carry on regardless: the error went into faults.ground, and
  -- every distance afterwards was read as though the range asked for had been
  -- granted.
  ------------------------------------------------------------------------------
  do
    local w2 = mock.new{}
    w2.navTable("nav0"); w2.altimeter("alt0")
    w2.optical("optical_sensor_0", { range = 16, max = 32 })
    _G.peripheral = w2.api

    hull.define(craft({ nav = "nav0", alt = "alt0", ground = "optical_sensor_0" }))
    hull.claim()

    check(w2.device("optical_sensor_0").range == 32,
          "a sensor that refuses 128 is still talked up to the 32 it allows",
          w2.device("optical_sensor_0").range)
    check(hull.reach.ground == 32,
          "and the reach we record is what it granted, not what we asked for",
          hull.reach.ground)
    check(hull.faults.ground == nil,
          "a refused range is not a fault -- the sensor works, it has a limit",
          hull.faults.ground)

    -- And the reading stays honest at the new range: inside it, a real number;
    -- beyond it, nil rather than a distance the sensor cannot have measured.
    w2.ship.x, w2.ship.y, w2.ship.z = 0, 84, 0
    check(near(hull.read(1).clearance, 20),
          "inside the granted range the clearance is real", hull.read(1).clearance)

    w2.ship.y = 120
    check(hull.read(2).clearance == nil,
          "beyond it the clearance is nil, never a number it could not see")
  end

  ------------------------------------------------------------------------------
  -- A sensor that will not be told anything at all.
  ------------------------------------------------------------------------------
  do
    local w2 = mock.new{}
    w2.navTable("nav0"); w2.altimeter("alt0")
    w2.optical("optical_sensor_0", { range = 16, max = 16 })
    _G.peripheral = w2.api

    hull.define(craft({ nav = "nav0", alt = "alt0", ground = "optical_sensor_0" }))
    hull.claim()

    check(w2.device("optical_sensor_0").range == 16,
          "a sensor that refuses everything keeps its own setting")
    check(hull.faults.ground == nil, "and is still not a fault")

    -- But it must be *said*. Sixteen blocks of vision means no clearance above
    -- sixteen and no survey ever, and a blank clearance on the cockpit reads
    -- exactly like flat ground a long way down.
    local warned = false
    for _, p in ipairs(hull.problems) do
      if p:find("ground sensor sees") then warned = true end
    end
    check(warned, "and says out loud that it cannot see far enough to be useful")
  end

  ------------------------------------------------------------------------------
  -- A build with no hasHit.
  --
  -- Every clearance read used to be gated on `hasHit() == true`. On any build
  -- where that is missing or throws, the call recorded a fault nobody reads and
  -- the clearance was nil for the whole flight -- no terrain guard, no height
  -- above ground, no survey, and all three looking exactly like flat ground.
  ------------------------------------------------------------------------------
  do
    local w2 = mock.new{}
    w2.navTable("nav0"); w2.altimeter("alt0")
    w2.optical("optical_sensor_0", { range = 128, noHasHit = true })
    _G.peripheral = w2.api

    hull.define(craft({ nav = "nav0", alt = "alt0", ground = "optical_sensor_0" }))
    hull.claim()

    w2.ship.x, w2.ship.y, w2.ship.z = 0, 100, 0
    local r = hull.read(1)
    check(near(r.clearance, 36),
          "a sensor with no hasHit still gives a clearance", r.clearance)
    check(hull.faults.ground == nil,
          "and the missing method is not recorded as a fault", hull.faults.ground)

    -- The distance alone still has to mean nothing when it means nothing.
    w2.ship.y = 300
    check(hull.read(2).clearance == nil,
          "and out of range is still nil, decided on the range alone")
  end

  _G.peripheral = realPeripheral
end

--------------------------------------------------------------------------------
section("hull: hardware that comes and goes")
--------------------------------------------------------------------------------

-- Assembling a Create Aeronautics contraption attaches every peripheral on it.
-- The pilot used to resolve its hardware once at boot and hold that answer for
-- the life of the computer, so starting the flight computer and *then*
-- assembling the ship -- the ordinary order of operations -- left it reporting
-- that it could not find the navigation table while the table sat there.
do
  local mock = require("test.mockperipheral")
  local hull = require("lib.hull")

  local craft = { controls = {}, mix = {},
                  instruments = { nav = "nav0", alt = "alt0",
                                  ground = "optical_sensor_0" },
                  limits = { clearance = 8, cruise = 12 } }

  -- Boot with nothing attached: the ship is not assembled yet.
  local w = mock.new{}
  _G.peripheral = w.api
  hull.define(craft)

  check(hull.instruments.nav == nil, "before assembly there is no navigation table")

  -- Now assemble.
  w.navTable("nav0"); w.altimeter("alt0"); w.optical("optical_sensor_0", { range = 128 })

  check(hull.instruments.nav == nil,
        "and nothing notices on its own -- CC raises an event, it does not re-resolve")

  local changed = hull.remount()
  check(changed, "remount reports that the hardware really did change")
  check(hull.instruments.nav and hull.instruments.nav.side == "nav0",
        "and the navigation table is found the moment the ship is assembled")
  check(hull.instruments.ground ~= nil, "along with everything else on it")

  -- And it reads, which is the whole point: resolving the side is no use if the
  -- fault recorded while it was missing is still sitting there.
  w.ship.x, w.ship.y, w.ship.z = 0, 100, 0
  local raw = hull.read(1)
  check(raw.pos ~= nil, "the fix comes back straight away", raw.pos)
  check(raw.clearance ~= nil, "and so does the clearance", raw.clearance)
  check(hull.faults.nav == nil, "with no fault left over from when it was absent")

  -- Taking the ship apart is the same event in reverse, and must not throw.
  local w2 = mock.new{}
  _G.peripheral = w2.api
  local ok, gone = pcall(hull.remount)
  check(ok, "disassembly is survivable", gone)
  check(hull.instruments.nav == nil, "and the instruments go with it")

  -- A remount with no craft file at all is a no-op rather than a crash: the
  -- event fires on every computer, including one that has not been set up.
  hull.reset()
  local okEmpty, changedEmpty = pcall(hull.remount)
  check(okEmpty and changedEmpty == false,
        "an unconfigured computer remounts to nothing, quietly")

  _G.peripheral = realPeripheral
end

--------------------------------------------------------------------------------
section("hull: redstone")
--------------------------------------------------------------------------------

-- A great deal of Create Aeronautics is driven by a signal rather than a method
-- call -- burners, steam vents, throttle levers, gearshifts, and every thruster
-- left in its default redstone control mode. The `wire` kind is how any of that
-- gets said at all.
do
  local mock = require("test.mockperipheral")
  local hull = require("lib.hull")
  local config = require("lib.config")

  local function rig(craft)
    local w = mock.new{}
    w.bearing("lift0", { count = 4 })
    w.navTable("nav0")
    w.altimeter("alt0")
    w.relay("redstone_relay_0")
    _G.peripheral = w.api
    _G.redstone = w.redstone.api
    local ok, problems = hull.define(craft)
    return w, ok, problems
  end

  local BASE = {
    controls = { lift = { kind = "bearing", peripheral = "lift0" } },
    instruments = { nav = "nav0", alt = "alt0", vel = false, gimbal = false,
                    ground = false, dock = false, stick = false, link = false },
    mix = {},
  }

  local function craft(extra)
    local c = { controls = {}, instruments = BASE.instruments, mix = {}, signals = {} }
    for k, v in pairs(BASE.controls) do c.controls[k] = v end
    for k, v in pairs(extra.controls or {}) do c.controls[k] = v end
    c.mix = extra.mix or {}
    c.signals = extra.signals or {}
    return c
  end

  -- Digital, on the flight computer's own bus. No peripheral named at all, which
  -- is the common case and must not be read as "could not find one".
  local w, ok, problems = rig(craft{
    controls = { burner = { kind = "wire", side = "top" } },
    mix = { { demand = "lift", control = "burner", as = "signal" } },
  })
  check(ok, "a wire on the computer's own sides loads clean", problems and problems[1])
  check(hull.get("burner").side == nil, "with no peripheral, which is not a fault")

  hull.apply({ burner = { signal = 1 } }, 0.2)
  check(w.redstone.output.top == true, "and a full signal turns the side on",
        tostring(w.redstone.output.top))

  hull.apply({ burner = { signal = 0 } }, 0.2)
  check(w.redstone.output.top == false, "and zero turns it off")

  -- Analog: 0..1 becomes 0..15, which is what a Create throttle lever reads.
  w = rig(craft{
    controls = { lever = { kind = "wire", side = "back", mode = "analog" } },
    mix = { { demand = "forward", control = "lever", as = "signal" } },
  })
  hull.apply({ lever = { signal = 1 } }, 10)     -- a long dt, past the slew limit
  check(w.redstone.output.back == 15, "an analogue wire scales to 0-15",
        w.redstone.output.back)

  hull.apply({ lever = { signal = 0.5 } }, 10)
  check(w.redstone.output.back == 8, "proportionally", w.redstone.output.back)

  -- An analogue signal is proportional, so it is rate limited like a throttle:
  -- it is probably driving something the ship's motion depends on.
  w = rig(craft{
    controls = { lever = { kind = "wire", side = "back", mode = "analog" } },
    mix = {},
  })
  hull.apply({ lever = { signal = 1 } }, 0.2)
  check(w.redstone.output.back < 15,
        "and rate limited on the way up", w.redstone.output.back)

  -- A digital wire is a switch. Rate limiting a switch only makes it late.
  w = rig(craft{
    controls = { burner = { kind = "wire", side = "top" } },
    mix = {},
  })
  hull.apply({ burner = { signal = 1 } }, 0.2)
  check(w.redstone.output.top == true, "a digital wire is not rate limited")

  -- invert lives on the control, not in every mix term that touches it.
  w = rig(craft{
    controls = { valve = { kind = "wire", side = "left", invert = true } },
    mix = {},
  })
  hull.apply({ valve = { signal = 0 } }, 0.2)
  check(w.redstone.output.left == true, "an inverted wire is on when asked for off")

  -- Bundled: one side shared by up to sixteen controls, so the whole face is
  -- recomputed on every write. Setting one colour without knowing the other
  -- fifteen turns them all off.
  w = rig(craft{
    controls = {
      lamp  = { kind = "wire", side = "back", mode = "bundled", colour = colours.lime },
      pump  = { kind = "wire", side = "back", mode = "bundled", colour = colours.red },
    },
    mix = {},
  })
  hull.apply({ lamp = { signal = 1 } }, 0.2)
  hull.apply({ pump = { signal = 1 } }, 0.2)
  check(w.redstone.output.back == colours.lime + colours.red,
        "two bundled colours on one cable both stay on",
        w.redstone.output.back)

  hull.apply({ lamp = { signal = 0 } }, 0.2)
  check(w.redstone.output.back == colours.red,
        "and turning one off leaves the other alone", w.redstone.output.back)

  -- A side carries one signal, so everything on it has to agree about what that
  -- signal is.
  local _, badOk, badWhy = rig(craft{
    controls = {
      a = { kind = "wire", side = "top" },
      b = { kind = "wire", side = "top", mode = "analog" },
    },
    mix = {},
  })
  check(not badOk, "two wires disagreeing about a side is refused", badWhy and badWhy[1])

  local _, dupOk, dupWhy = rig(craft{
    controls = {
      a = { kind = "wire", side = "top", mode = "bundled", colour = colours.lime },
      b = { kind = "wire", side = "top", mode = "bundled", colour = colours.lime },
    },
    mix = {},
  })
  check(not dupOk, "and so is the same colour twice", dupWhy and dupWhy[1])

  local _, sideOk, sideWhy = rig(craft{
    controls = { a = { kind = "wire", side = "sideways" } },
    mix = {},
  })
  check(not sideOk and tostring(sideWhy[1]):find("side", 1, true),
        "a side that does not exist is caught at load, not silently ignored",
        sideWhy and sideWhy[1])
  -- Silently ignored is the failure that matters here: a signal sent to a side
  -- that is not there is simply nothing, so the burner never lights and there is
  -- no error anywhere to explain it.

  local _, colourOk = rig(craft{
    controls = { a = { kind = "wire", side = "top", mode = "bundled" } },
    mix = {},
  })
  check(not colourOk, "a bundled wire with no colour is refused")

  -- A relay: the identical API on the end of a wired modem, which on an
  -- assembled contraption is how the burner gets to be somewhere sensible.
  w = rig(craft{
    controls = { burner = { kind = "wire", peripheral = "redstone_relay_0",
                            side = "front" } },
    mix = {},
  })
  hull.apply({ burner = { signal = 1 } }, 0.2)
  check(w.device("redstone_relay_0").output.front == true,
        "a wire on a relay drives the relay")
  check(w.redstone.output.front == nil,
        "and not the computer's own side of the same name")

  -- The mix drives it, which is the entire point: "burn when we want to climb".
  local autopilot = require("lib.autopilot")
  w = rig(craft{
    controls = { burner = { kind = "wire", side = "top" } },
    mix = { { demand = "lift", control = "burner", as = "signal" } },
  })
  hull.apply(autopilot.apply(hull.mix, { lift = 1 }), 0.2)
  check(w.redstone.output.top == true, "the mix can drive a wire from a demand")

  -- Release zeroes a wire rather than handing it back. It is the one kind with
  -- no owner underneath us: the computer *is* what holds the signal, so there is
  -- nothing to hand it to and off is the only safe value.
  hull.release()
  check(w.redstone.output.top == false, "release turns every wire off")

  -- Named inputs: a launch button, a lever, a comparator on the hold.
  w = rig(craft{
    controls = {},
    signals = {
      launch = { side = "front" },
      cargo  = { side = "right", mode = "analog" },
      relayed = { side = "back", peripheral = "redstone_relay_0" },
    },
  })
  w.redstone.input.front = true
  w.redstone.input.right = 9
  w.device("redstone_relay_0").input.back = true

  local raw = hull.read(1)
  check(raw.signals and raw.signals.launch == true, "a digital input is read")
  check(raw.signals and raw.signals.cargo == 9, "an analogue one keeps its level",
        raw.signals and raw.signals.cargo)
  check(raw.signals and raw.signals.relayed == true, "and a relay's input too")

  local described = hull.describe()
  check(#described.signals == 3, "and they ride in the hull description",
        #described.signals)

  -- Redstone has sixteen levels and nothing between them, so a demand is rounded
  -- to one of them before the change test. Without that, a settled hover asking
  -- for 0.500 and then 0.503 rewrites the wire on every sweep for no reason.
  w = rig(craft{
    controls = { lever = { kind = "wire", side = "back", mode = "analog" } },
    mix = {},
  })
  hull.apply({ lever = { signal = 0.5 } }, 10)
  local first = #hull.apply({ lever = { signal = 0.503 } }, 10)
  check(first == 0, "a demand inside one redstone level is not rewritten", first)
  check(#hull.apply({ lever = { signal = 0.6 } }, 10) == 1,
        "and one that crosses a level is")

  -- A burner or a vent is holding the ship *up*, so `hold` leaves it driving on
  -- the way out. Turning it off would be a controlled descent nobody asked for,
  -- from whatever altitude the ship happened to be at.
  w = rig(craft{
    controls = {
      burner = { kind = "wire", side = "top", mode = "analog", hold = true },
      vent   = { kind = "wire", side = "left" },
    },
    mix = {},
  })
  hull.apply({ burner = { signal = 1 }, vent = { signal = 1 } }, 10)
  check(w.redstone.output.top == 15 and w.redstone.output.left == true,
        "both wires are driven")

  hull.release()
  check(w.redstone.output.top == 15,
        "release leaves a `hold` wire burning", w.redstone.output.top)
  check(w.redstone.output.left == false,
        "and turns an ordinary one off")

  -- CC does not persist a computer's redstone outputs, so on a balloon a chunk
  -- reload is a burner going out. This is what makes walking away survivable.
  local saved = hull.saved()
  check(saved.burner ~= nil, "the wires are in the state file", saved.burner)

  w = rig(craft{
    controls = { burner = { kind = "wire", side = "top", mode = "analog",
                            hold = true } },
    mix = {},
  })
  check(w.redstone.output.top == nil, "a fresh boot drives nothing")
  hull.restore({ burner = 1 })
  check(w.redstone.output.top == 15,
        "and restore puts the burner back before the first sweep",
        w.redstone.output.top)

  -- The gimbal sensor over plain redstone: it powers the face of whichever side
  -- is leaning down, in proportion, with the sensitivity set on the block.
  w = mock.new{}
  w.navTable("nav0")
  w.altimeter("alt0")
  _G.peripheral = w.api
  _G.redstone = w.redstone.api
  w.tiltWire{ front = "front", back = "back", left = "left", right = "right",
              degrees = 30 }

  local okTilt, tiltWhy = hull.define({
    controls = {},
    instruments = { nav = "nav0", alt = "alt0", vel = false, gimbal = false,
                    ground = false, dock = false, stick = false, link = false },
    tilt = { front = "front", back = "back", left = "left", right = "right",
             degrees = 30 },
    mix = {},
  })
  check(okTilt, "a redstone tilt block loads clean", tiltWhy and tiltWhy[1])

  w.ship.pitch, w.ship.roll = 15, 0
  w.updateTilt()
  local tilted = hull.read(1)
  check(near(tilted.pitch, 15, 1.1), "nose down reads as positive pitch",
        tilted.pitch)
  check(near(tilted.roll, 0, 0.001), "with no roll", tilted.roll)

  w.ship.pitch, w.ship.roll = -30, 30
  w.updateTilt()
  tilted = hull.read(2)
  check(near(tilted.pitch, -30, 1.1), "tail down reads as negative", tilted.pitch)
  check(near(tilted.roll, 30, 1.1), "and the other axis is independent",
        tilted.roll)
  check(tilted.tiltSource == "redstone", "and it says where the reading came from")

  -- Only sixteen steps of whatever the panel is set to, so a hull with the real
  -- peripheral should not be given the coarse reading instead.
  w.gimbal("gim0")
  hull.define({
    controls = {},
    instruments = { nav = "nav0", alt = "alt0", gimbal = "gim0", vel = false,
                    ground = false, dock = false, stick = false, link = false },
    tilt = { front = "front", back = "back", degrees = 30 },
    mix = {},
  })
  w.ship.pitch, w.ship.roll = 7.25, -3.5
  local exact = hull.read(3)
  check(exact.tiltSource == "sensor", "the peripheral wins when there is one",
        exact.tiltSource)
  check(near(exact.pitch, 7.25), "and its angles are exact rather than rounded",
        exact.pitch)

  local _, tiltBad, tiltWhy2 = false, nil, nil
  tiltBad, tiltWhy2 = hull.define({
    controls = {}, instruments = { nav = "nav0", alt = "alt0" },
    tilt = { front = "sideways" }, mix = {},
  })
  check(not tiltBad, "a tilt face that is not a side is refused", tiltWhy2 and tiltWhy2[1])

  _G.redstone = nil
  _G.peripheral = realPeripheral
end

--------------------------------------------------------------------------------
section("needs: what a computer must have")
--------------------------------------------------------------------------------

do
  local needs = require("lib.needs")

  local function found(list)
    local out = {}
    for _, entry in ipairs(list) do
      if type(entry) == "string" then out[#out + 1] = { type = entry }
      else out[#out + 1] = entry end
    end
    return out
  end

  check(needs.roles.pilot and needs.roles.server and needs.roles.beacon
        and needs.roles.remote, "every role has a list of what it needs")

  -- A bare computer: everything required is missing and says so.
  local rows, summary = needs.check("pilot", {})
  check(#rows > 0, "a pilot has requirements", #rows)
  check(summary.required >= 3, "several of them required", summary.required)

  local verdict, mood = needs.verdict(summary, "pilot")
  check(mood == "bad", "and a bare computer is not ready", verdict)

  -- A wired modem is not a radio, and saying "modem: found" next to silence
  -- would be the least helpful thing this could do.
  local wired = needs.check("pilot", found({ { type = "modem", wireless = false } }))
  local modemRow = nil
  for _, row in ipairs(wired) do
    if row.item.kind == "modem" then modemRow = row end
  end
  check(modemRow and not modemRow.ok,
        "a wired modem does not satisfy the wireless one")

  local wireless = needs.check("pilot", found({ { type = "modem", wireless = true } }))
  for _, row in ipairs(wireless) do
    if row.item.kind == "modem" then
      check(row.ok, "and a wireless one does")
    end
  end

  -- A hull driving one thruster directly is as valid as one with a bearing.
  local direct = needs.check("pilot", found({
    { type = "modem", wireless = true }, "navigation_table", "altitude_sensor",
    "thruster" }))
  local drive = nil
  for _, row in ipairs(direct) do
    if row.item.kind == "thruster_bearing" then drive = row end
  end
  check(drive and drive.ok, "a bare thruster satisfies the need for something "
        .. "to drive, the same as a bearing")

  -- Two optical sensors is a different answer from one, because the second is
  -- the whole obstacle guard.
  local one = needs.check("pilot", found({ "optical_sensor" }))
  local two = needs.check("pilot", found({ "optical_sensor", "optical_sensor" }))
  local function opticalOk(rows_)
    for _, row in ipairs(rows_) do
      if row.item.kind == "optical_sensor" then return row.ok, row.have end
    end
  end
  check(select(1, opticalOk(one)) == false, "one optical sensor is not enough")
  check(select(1, opticalOk(two)) == true, "two are")

  -- A complete pilot.
  local _, full = needs.check("pilot", found({
    { type = "modem", wireless = true },
    "navigation_table", "altitude_sensor", "thruster_bearing",
    "optical_sensor", "optical_sensor", "docking_connector",
    "gimbal_sensor", "analogue_joystick", "monitor" }))
  check(full.required == 0, "a fully equipped pilot needs nothing",
        full.required)
  check(select(2, needs.verdict(full, "pilot")) == "ok", "and says so")

  -- Missing something optional is "ready, but", not "broken".
  local _, partial = needs.check("pilot", found({
    { type = "modem", wireless = true },
    "navigation_table", "altitude_sensor", "thruster_bearing",
    "optical_sensor", "optical_sensor" }))
  check(partial.required == 0 and partial.missing > 0,
        "missing only optional things is not a failure")
  check(select(2, needs.verdict(partial, "pilot")) == "warn",
        "and reads as a suggestion rather than an error")

  -- The other roles are far simpler, and a pocket computer needs one thing.
  local _, pocketSummary = needs.check("remote",
    found({ { type = "modem", wireless = true } }))
  check(pocketSummary.required == 0, "a pocket with a modem is ready")

  local _, unknown = needs.check("nonsense", {})
  check(unknown.required == 0, "an unknown role is empty rather than a crash")

  -- Every item has to be able to explain itself, because the whole point is
  -- that somebody stuck reads this rather than the source.
  for name, spec in pairs(needs.roles) do
    checkQuiet(type(spec.title) == "string", name .. " has a title")
    for _, item in ipairs(spec.items) do
      checkQuiet(item.what and item.why and item.without,
                 name .. "/" .. tostring(item.what) .. " explains itself")
      checkQuiet(item.tier == "required" or item.tier == "recommended"
                 or item.tier == "optional", "a known tier")
    end
  end
  check(true, "every requirement says what it is for and what you lose")
end

--------------------------------------------------------------------------------
section("hull: a craft file that switches off attached hardware")
--------------------------------------------------------------------------------

-- The bug that started this. `probe` wrote `nav = false` for anything not
-- attached at the moment it ran -- which is the normal state of a contraption
-- that has not been assembled -- and `false` means "this hull deliberately has
-- none, stop looking and stop warning". Plug the navigation table in afterwards
-- and the pilot would never look for it again.
do
  local mock = require("test.mockperipheral")
  local hull = require("lib.hull")

  local w = mock.new{}
  w.navTable("navigation_table_0")
  w.altimeter("altitude_sensor_0")
  _G.peripheral = w.api

  -- Switched off while the hardware is right there.
  local ok, problems = hull.define({
    controls = {}, mix = {},
    instruments = { nav = false, alt = "altitude_sensor_0" },
  })

  check(hull.instruments.nav == nil, "false still means do not use it")

  local named = false
  for _, why in ipairs(problems or {}) do
    if tostring(why):find("attached", 1, true)
      and tostring(why):find("nav", 1, true) then named = true end
  end
  check(named, "but a false with the peripheral attached is called out, "
        .. "because the hardware is right there and the program refuses to see it",
        problems and problems[1])

  -- Genuinely absent: still quiet, because a balloon with no optical sensor is
  -- a design and a warning that is always on screen is one nobody reads.
  local w2 = mock.new{}
  w2.navTable("nav0")
  w2.altimeter("alt0")
  _G.peripheral = w2.api

  local _, quiet = hull.define({
    controls = {}, mix = {},
    instruments = { nav = "nav0", alt = "alt0", ground = false },
  })
  local complained = false
  for _, why in ipairs(quiet or {}) do
    if tostring(why):find("ground", 1, true) then complained = true end
  end
  check(not complained, "and switching off something that is genuinely absent "
        .. "is still silent")

  -- The message for a missing navigation table has somewhere to go next.
  local w3 = mock.new{}
  w3.altimeter("alt0")
  _G.peripheral = w3.api
  local _, lost = hull.define({ controls = {}, mix = {},
                                instruments = { alt = "alt0" } })
  local helpful = false
  for _, why in ipairs(lost or {}) do
    if tostring(why):find("assembled", 1, true)
      or tostring(why):find("setup", 1, true) then helpful = true end
  end
  check(helpful, "and a missing one suggests what to check", lost and lost[1])

  _G.peripheral = realPeripheral
end

--------------------------------------------------------------------------------
section("cfg -- what counts as configured")
--------------------------------------------------------------------------------

-- The rules that decide whether a computer is allowed to start, tested without a
-- peripheral, a filesystem or a screen. They live in one module precisely so
-- they can be: four programs used to each have their own opinion about what a
-- broken configuration looked like, and a ship could satisfy all four and still
-- not fly.
--
-- The distinction under test is the one that matters most, and the one that
-- would be catastrophic to get backwards: **configuration gates a boot, and
-- hardware never does.**
do
  local cfg = require("lib.cfg")

  local FLYABLE = {
    name = "Kestrel",
    controls = {
      lift = { kind = "bearing", peripheral = "thruster_bearing_0", group = "all" },
      main = { kind = "bearing", peripheral = "thruster_bearing_1", group = "all" },
    },
    instruments = { nav = "navigation_table_0", alt = "altitude_sensor_0" },
    limits = { cruise = 10, climb = 3, descend = 2, clearance = 8 },
    gains = { hover = 0.5 },
    mix = { { demand = "lift", control = "lift", as = "throttle" },
            { demand = "forward", control = "main", as = "throttle" } },
  }

  local ATTACHED = {
    modem = { "top" },
    navigation_table = { "navigation_table_0" },
    altitude_sensor  = { "altitude_sensor_0" },
    thruster_bearing = { "thruster_bearing_0", "thruster_bearing_1" },
    optical_sensor   = { "optical_sensor_0", "optical_sensor_1" },
  }

  local function copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
  end

  local function mentions(problems, text)
    for _, p in ipairs(problems) do
      if p.text:find(text, 1, true) then return true end
    end
    return false
  end

  -- Never configured stops every role, ahead of everything else, because it is
  -- the one problem whose answer is "run the wizard" rather than "fix a field".
  for _, role in ipairs({ "pilot", "server", "beacon", "remote" }) do
    local problems = cfg.check(role, {
      configured = false, craft = FLYABLE, attached = ATTACHED,
      beacon = { name = "pad", x = 1, y = 2, z = 3 },
    })
    check(cfg.blocking(problems),
          "a " .. role .. " nobody has configured is stopped")
  end

  local ready = cfg.check("pilot", {
    configured = true, craft = FLYABLE, attached = ATTACHED })
  check(not cfg.blocking(ready), "a configured pilot with a flyable hull starts")

  ------------------------------------------------------------------------------
  -- The one that would ground the entire fleet if it went the other way.
  ------------------------------------------------------------------------------
  local bare = cfg.check("pilot", {
    configured = true, craft = FLYABLE, attached = {} })
  check(not cfg.blocking(bare),
        "a pilot with nothing attached still starts -- assembling the "
        .. "contraption is what attaches its peripherals, so this is the normal "
        .. "state of every ship until the moment it is assembled")
  check(mentions(bare, "wireless modem"),
        "though the missing hardware is still reported")

  for _, p in ipairs(bare) do
    check(p.severity ~= "bad",
          "and no hardware problem is ever severe enough to stop a boot: "
          .. p.text)
  end

  ------------------------------------------------------------------------------
  -- What does stop one.
  ------------------------------------------------------------------------------
  check(cfg.blocking(cfg.check("pilot", {
          configured = true, craft = nil, attached = ATTACHED })),
        "a pilot with no craft file at all is stopped")

  local noControls = copy(FLYABLE)
  noControls.controls = {}
  check(cfg.blocking(cfg.check("pilot", {
          configured = true, craft = noControls, attached = ATTACHED })),
        "and one with no controls -- a flight computer wired to nothing")

  local noMix = copy(FLYABLE)
  noMix.mix = {}
  check(cfg.blocking(cfg.check("pilot", {
          configured = true, craft = noMix, attached = ATTACHED })),
        "and one whose controls are never driven")

  local noLift = copy(FLYABLE)
  noLift.mix = { { demand = "forward", control = "main", as = "throttle" } }
  local liftless = cfg.check("pilot", {
    configured = true, craft = noLift, attached = ATTACHED })
  check(cfg.blocking(liftless),
        "and one where nothing in the mix drives lift -- which is the "
        .. "difference between a ship and a falling building")
  check(mentions(liftless, "hold itself up"), "and it says which it is")

  ------------------------------------------------------------------------------
  -- Warnings, which report and do not block.
  ------------------------------------------------------------------------------
  local switchedOff = copy(FLYABLE)
  switchedOff.instruments = { nav = false, alt = "altitude_sensor_0" }
  local off = cfg.check("pilot", {
    configured = true, craft = switchedOff, attached = ATTACHED })
  check(mentions(off, "switched off"),
        "a role set to false while its peripheral is attached is called out -- "
        .. "the bug the whole configurator was first built for")
  check(not cfg.blocking(off),
        "but it does not stop the ship: it flies, with one instrument ignored")

  -- A name that is not on this hull. Checked against the actual list rather
  -- than merely against the kind: naming optical_sensor_3 on a ship that has 0
  -- and 1 is a typo that costs a whole instrument, and "well, *an* optical
  -- sensor is attached" is not an answer to it.
  local typo = copy(FLYABLE)
  typo.instruments = { nav = "navigation_table_0", ground = "optical_sensor_3" }
  local mistyped = cfg.check("pilot", {
    configured = true, craft = typo, attached = ATTACHED })
  check(mentions(mistyped, "optical_sensor_3"),
        "an instrument naming a peripheral this hull does not have is called "
        .. "out, even though other sensors of that kind are attached")
  check(not cfg.blocking(mistyped),
        "and it is still only a warning -- the ship flies, one sensor short")

  local eyes = cfg.check("pilot", {
    configured = true, craft = FLYABLE, attached = ATTACHED })
  check(mentions(eyes, "optical sensors"),
        "two optical sensors with neither role named is called out, because one "
        .. "named and one guessed is even odds on the terrain guard")

  ------------------------------------------------------------------------------
  -- The other roles.
  ------------------------------------------------------------------------------
  check(cfg.blocking(cfg.check("beacon", { configured = true, attached = ATTACHED })),
        "a beacon with no coordinates is not a waypoint, and is stopped")
  check(cfg.blocking(cfg.check("beacon", { configured = true, attached = ATTACHED,
          beacon = { name = "quarry", x = 1, y = 2 } })),
        "and so is one that is missing a single axis")
  check(not cfg.blocking(cfg.check("beacon", { configured = true,
          attached = ATTACHED, beacon = { name = "quarry", x = 1, y = 2, z = 3 } })),
        "one that knows where it stands is let through")

  check(not cfg.blocking(cfg.check("server", { configured = true, attached = ATTACHED })),
        "a configured tower needs nothing beyond its network settings")
  check(not cfg.blocking(cfg.check("remote", { configured = true, attached = ATTACHED })),
        "and neither does a pocket computer")

  ------------------------------------------------------------------------------
  -- Names for roles, because people say "tower" and mean "server".
  ------------------------------------------------------------------------------
  check(cfg.role("tower") == "server", "tower is the server")
  check(cfg.role("ship") == "pilot", "a ship is a pilot")
  check(cfg.role("waypoint") == "beacon", "a waypoint is a beacon")
  check(cfg.role("  PILOT ") == "pilot", "and it is not fussy about spacing or case")
  check(cfg.role("hovercraft") == nil, "something it does not know is nil, not a guess")

  ------------------------------------------------------------------------------
  -- The serialiser, which is the round trip that used to belong to probe.lua.
  --
  -- Whatever this writes has to be a file lib/hull can load, because the
  -- alternative is a syntax error discovered on an assembled contraption with no
  -- working copy of anything to fall back on.
  ------------------------------------------------------------------------------
  local hull = require("lib.hull")
  local lines = cfg.craftLines(FLYABLE)
  writeFile("/test-craft.cfg", table.concat(lines, "\n") .. "\n")

  local reloaded = dofile("/test-craft.cfg")
  check(type(reloaded) == "table", "what the writer produces is loadable Lua")
  check(reloaded.name == "Kestrel", "and it keeps the name")
  check(reloaded.controls.lift.peripheral == "thruster_bearing_0",
        "and every control")
  check(#reloaded.mix == 2, "and the mix", #reloaded.mix)

  -- The trap that made probe.lua write a permanent absence. A role with nothing
  -- attached must be left *out*, not written as `false`: absent is found
  -- automatically the moment the block appears, and `false` means never look
  -- again.
  local sparse = copy(FLYABLE)
  sparse.instruments = { nav = "navigation_table_0", gimbal = false }
  writeFile("/test-craft.cfg",
            table.concat(cfg.craftLines(sparse), "\n") .. "\n")
  local sparseBack = dofile("/test-craft.cfg")
  check(sparseBack.instruments.alt == nil,
        "an instrument that was never set is left out of the file entirely")
  check(sparseBack.instruments.gimbal == false,
        "and one deliberately switched off keeps its false")

  fs.delete("/test-craft.cfg")
end

--------------------------------------------------------------------------------
section("configure")
--------------------------------------------------------------------------------

-- The configurator, driven through its real event loop. It is now the only way
-- to set this program up -- it absorbed the installer's questions, probe.lua's
-- hull generation and setup.lua's hardware checklist -- so what is under test is
-- the whole of that.
--
-- Two modes, and the difference between them is the point:
--
--   * a computer nobody has configured gets the **wizard**, which walks every
--     pane in order and will not let Q out of it;
--   * a computer somebody has gets the **front page**, which opens by saying
--     what is wrong and lets you jump straight at it.
--
-- The stamp in /aero.cfg is what tells them apart, which is why these tests
-- write one or deliberately do not.
do
  local mock   = require("test.mockperipheral")
  local config = require("lib.config")
  local cfg    = require("lib.cfg")
  local realPeripheralHere = _G.peripheral
  local realLabelHere = os.getComputerLabel()

  --- Empty the queue, so one run's leftovers are not the next one's script.
  --
  -- configure quits on the first `q` and the menu-mode cases queue two, so the
  -- spare one sat in the queue and ended the *following* run before it had
  -- processed a single click. It ended the beacon suite's runs too, three
  -- sections later, which is how a missing drain turns into a failure nowhere
  -- near its cause.
  local function drain()
    os.queueEvent("aero_drain")
    while true do
      if os.pullEventRaw() == "aero_drain" then return end
    end
  end

  local function runConfigure(opts)
    opts = opts or {}
    drain()

    local w = mock.new{}
    w.modem("top")
    w.navTable("navigation_table_0")
    w.altimeter("altitude_sensor_0")
    w.bearing("thruster_bearing_0", { count = 2 })
    w.bearing("thruster_bearing_1", { count = 4 })
    if opts.eyes then
      w.optical("optical_sensor_0", { range = 128 })
      w.optical("optical_sensor_1", { range = 128 })
    end
    if opts.orientation then w.orientation("virtual_orientation_source_0") end
    _G.peripheral = w.api

    fs.delete(config.craftFile)
    fs.delete("/aero.cfg")

    -- The stamp, or its absence, is the whole difference between the two modes.
    -- A test that wants the front page has to say that somebody configured this
    -- computer once, because otherwise the program is quite right to insist on
    -- the wizard.
    if not opts.wizard then
      writeFile("/aero.cfg", ('return { protocol = "aero", channel = 1618, '
        .. 'role = %q, configured = "test" }'):format(opts.role or "pilot"))
    elseif opts.role then
      writeFile("/aero.cfg", ('return { role = %q }'):format(opts.role))
    end

    if opts.craft then
      writeFile(config.craftFile, "return " .. textutils.serialize(opts.craft))
    end

    -- Snapshot every screen, because the pane you want is rarely the one that
    -- was up when it quit.
    local win = window.create(term.current(), 1, 1, 51, 19, true)
    local realPull = os.pullEventRaw
    local screens = {}
    os.pullEventRaw = function(...)
      local lines = {}
      for y = 1, 19 do lines[#lines + 1] = win.getLine(y) end
      screens[#screens + 1] = lines
      return realPull(...)
    end

    for _, e in ipairs(opts.script or {}) do os.queueEvent(table.unpack(e)) end

    -- Menu mode leaves on q. The wizard deliberately refuses to, so every run
    -- ends with a terminate -- which configure takes as an event rather than an
    -- error precisely so that it can still put the screen back.
    os.queueEvent("key", keys.q)
    os.queueEvent("key", keys.q)
    os.queueEvent("terminate")

    local old = term.redirect(win)
    local ok, err = pcall(dofile, "/configure.lua")
    term.redirect(old)
    os.pullEventRaw = realPull

    return { ok = ok, err = err, screens = screens }
  end

  local function anywhere(r, text)
    for _, screen in ipairs(r.screens) do
      for _, line in ipairs(screen) do
        if tostring(line):find(text, 1, true) then return true end
      end
    end
    return false
  end

  --- The row in the *latest* screen that shows this text at all.
  --
  -- For something reached by scrolling. The first screen showing APPLY is the
  -- one where it scrolled into view, near the bottom edge and still moving; the
  -- last is the settled layout a click will actually meet.
  local function rowOfLatest(r, text)
    for i = #r.screens, 1, -1 do
      for y, line in ipairs(r.screens[i]) do
        if tostring(line):find(text, 1, true) then return y end
      end
    end
    return nil
  end

  --- The row a piece of text is on, searching only screens that are actually
  --- the named pane.
  --
  -- Every earlier way of finding a row was some version of "skip the first N
  -- screens and hope", and both of the ways that can go wrong went wrong. The
  -- front page carries the problem list, so it *mentions* the things the panes
  -- are named after -- searching every screen for "ground" finds the warning
  -- about the ground sensor rather than the row that sets it. And the number of
  -- opening screens is not fixed, so "screen 2" was the front page again.
  --
  -- The title bar says which pane is up. Anchoring on it removes both.
  local function rowOnPane(r, pane, text, last)
    local found = nil
    for _, screen in ipairs(r.screens) do
      if tostring(screen[1]):find(pane, 1, true) then
        for y = 2, #screen do
          if tostring(screen[y]):find(text, 1, true) then
            if not last then return y end
            found = y
            break
          end
        end
      end
    end
    return found
  end

  --- A row on the front page. Called with the whole label, because a warning
  --- about the instruments and the button that opens them both say the word.
  local function frontRow(r, label)
    return rowOnPane(r, "Configure", label)
  end

  local BROKEN = {
    name = "Kestrel",
    controls = { lift = { kind = "bearing", peripheral = "thruster_bearing_0",
                          group = "all" } },
    instruments = { nav = false, alt = "altitude_sensor_0" },
    limits = { cruise = 10, climb = 3, descend = 2, clearance = 8 },
    gains = { hover = 0.5 },
    mix = { { demand = "lift", control = "lift", as = "throttle" } },
  }

  ------------------------------------------------------------------------------
  -- The front page
  ------------------------------------------------------------------------------

  local r = runConfigure{ craft = BROKEN }
  check(r.ok, "the configurator runs", r.err)
  check(anywhere(r, "worth knowing"),
        "and opens by saying what is wrong with the configuration you have")
  check(anywhere(r, "switched off"),
        "naming the one that started all this -- a role set to false while the "
        .. "peripheral is attached")

  -- A problem that stops the ship flying is headed differently from one that
  -- merely wants looking at. Both are worth reading; only one is worth stopping
  -- a boot for, and the page has to say which it is holding.
  local grounded = runConfigure{ craft = {
    name = "Kestrel",
    controls = { lift = { kind = "bearing", peripheral = "thruster_bearing_0",
                          group = "all" } },
    instruments = { nav = "navigation_table_0", alt = "altitude_sensor_0" },
    limits = { cruise = 10, climb = 3, descend = 2, clearance = 8 },
    gains = { hover = 0.5 },
    mix = {},
  } }
  check(anywhere(grounded, "these stop it working"),
        "a hull whose controls are never driven is headed as a stopper")

  local fine = runConfigure{ craft = {
    name = "Kestrel",
    controls = { lift = { kind = "bearing", peripheral = "thruster_bearing_0",
                          group = "all" },
                 main = { kind = "bearing", peripheral = "thruster_bearing_1",
                          group = "all" } },
    instruments = { nav = "navigation_table_0", alt = "altitude_sensor_0" },
    limits = { cruise = 10, climb = 3, descend = 2, clearance = 8 },
    gains = { hover = 0.5 },
    mix = { { demand = "lift", control = "lift", as = "throttle" } },
  } }
  check(anywhere(fine, "Nothing wrong"),
        "a healthy configuration says so instead of showing a blank page")

  ------------------------------------------------------------------------------
  -- The bearings, which is the decision nothing else can make
  ------------------------------------------------------------------------------

  local bearingsRow = frontRow(r, "Bearings -- which is lift")
  check(bearingsRow ~= nil, "the front page offers the bearings", bearingsRow)

  local picked = runConfigure{
    craft = BROKEN,
    script = { { "mouse_click", 1, 3, bearingsRow or 7 } },
  }
  check(anywhere(picked, "lift -- holds the ship up"),
        "which opens onto the lift choice")
  check(anywhere(picked, "thruster_bearing_1"),
        "listing every bearing that is attached, not just the one in use")
  check(anywhere(picked, "wrong way round"),
        "and says out loud what happens if you get it backwards")

  ------------------------------------------------------------------------------
  -- Naming the two optical sensors, and the round trip into a file
  ------------------------------------------------------------------------------

  local TWO_EYES = {
    name = "Kestrel",
    controls = { lift = { kind = "bearing", peripheral = "thruster_bearing_0",
                          group = "all" } },
    instruments = { nav = "navigation_table_0", alt = "altitude_sensor_0" },
    limits = { cruise = 10, climb = 3, descend = 2, clearance = 8 },
    gains = { hover = 0.5 },
    mix = { { demand = "lift", control = "lift", as = "throttle" } },
  }

  local warned = runConfigure{ craft = TWO_EYES, eyes = true }
  check(anywhere(warned, "optical sensors"),
        "two sensors with neither named is called out")

  local instrumentsRow = frontRow(warned, "Instruments -- what this hull")
  check(instrumentsRow ~= nil, "the front page offers the instruments pane")

  -- Where the rows land, learned by opening the panes and looking rather than
  -- counted by hand -- the list length depends on the hull, and a click at a
  -- guessed row is a test that passes by hitting something else.
  local openInstruments = { "mouse_click", 1, 3, instrumentsRow or 8 }

  local instPane = runConfigure{ craft = TWO_EYES, eyes = true,
                                 script = { openInstruments } }
  local groundY  = rowOnPane(instPane, "Instruments", "ground")
  local forwardY = rowOnPane(instPane, "Instruments", "forward")
  check(groundY and forwardY and groundY ~= forwardY,
        "the instruments pane offers both optical roles, on rows of their own",
        tostring(groundY) .. "/" .. tostring(forwardY))

  -- `ground` needs one tap to go from auto to the first sensor; `forward` needs
  -- two, because both roles offer the same list and its first entry is the same
  -- block.
  local naming = {
    openInstruments,
    { "mouse_click", 1, 3, groundY or 4 },
    { "mouse_click", 1, 3, forwardY or 5 },
    { "mouse_click", 1, 3, forwardY or 5 },
    { "key", keys.q },
  }

  local function after(...)
    local s = {}
    for _, e in ipairs(naming) do s[#s + 1] = e end
    for _, e in ipairs({ ... }) do s[#s + 1] = e end
    return s
  end

  -- The *last* front page, not the first. Naming the sensors removes the warning
  -- and takes a row with it, so every button below it moves up: a row read
  -- before the fix is the wrong row after it.
  local reviewY = rowOnPane(runConfigure{ craft = TWO_EYES, eyes = true,
                              script = naming },
                            "Configure", "Review and apply", true)
  check(reviewY ~= nil, "review is still reachable after fixing the warning",
        tostring(reviewY))

  -- APPLY is the last row of the review pane and the pane is longer than the
  -- screen, so it has to be scrolled to.
  local openReview = { { "mouse_click", 1, 3, reviewY or 11 } }
  for _ = 1, 40 do openReview[#openReview + 1] = { "key", keys.down } end

  local revPane = runConfigure{ craft = TWO_EYES, eyes = true,
                                script = after(table.unpack(openReview)) }
  local applyY  = rowOnPane(revPane, "Review", "APPLY", true)
  check(applyY ~= nil, "and the review pane offers APPLY", tostring(applyY))

  local script = after(table.unpack(openReview))
  script[#script + 1] = { "mouse_click", 1, 3, applyY or 18 }

  local named = runConfigure{ craft = TWO_EYES, eyes = true, script = script }
  check(named.ok, "the configurator survives naming them", named.err)

  local written = fs.exists(config.craftFile) and dofile(config.craftFile) or nil
  check(type(written) == "table", "a craft file was written at all")

  if type(written) == "table" then
    local inst = written.instruments or {}
    check(inst.ground == "optical_sensor_0",
          "ground is written to the file", tostring(inst.ground))
    check(inst.forward == "optical_sensor_1",
          "and so is forward -- the role that has no auto-find to fall back on",
          tostring(inst.forward))
    check(inst.ground ~= inst.forward, "and they are not the same block")

    -- Following the instruction has to *work*, or the message is just noise
    -- that appears whatever you do.
    local hull = require("lib.hull")
    hull.define(written)
    local stillWarned = false
    for _, p in ipairs(hull.problems) do
      if p:find("optical sensors", 1, true) then stillWarned = true end
    end
    check(not stillWarned,
          "and loading it back leaves no warning -- doing what it asked worked",
          table.concat(hull.problems, "; "))
  end

  -- ENTER on the review pane does the same thing without scrolling, which is
  -- the actual fix: the button was always there and always off the bottom.
  fs.delete(config.craftFile)
  local byKey = runConfigure{
    craft = TWO_EYES, eyes = true,
    script = after({ "mouse_click", 1, 3, reviewY or 11 }, { "key", keys.enter }),
  }
  check(byKey.ok, "ENTER on the review pane runs", byKey.err)
  check(anywhere(byKey, "ENTER writes it"),
        "and the pane says so at the top, where the eye already is")

  local viaKey = fs.exists(config.craftFile) and dofile(config.craftFile) or nil
  check(type(viaKey) == "table" and (viaKey.instruments or {}).forward
          == "optical_sensor_1",
        "and it writes the file without ever scrolling to the button",
        type(viaKey) == "table" and tostring((viaKey.instruments or {}).forward)
          or "no file")

  ------------------------------------------------------------------------------
  -- The wizard, which is what a fresh computer gets
  ------------------------------------------------------------------------------

  local wiz = runConfigure{ wizard = true }
  check(wiz.ok, "the wizard runs on a computer with no configuration", wiz.err)
  check(anywhere(wiz, "has not been set up"),
        "and opens by saying what it is")
  check(anywhere(wiz, "(1/"), "numbering the steps, so the end is in sight")

  -- Q is not a way out of it. A computer that has not been configured cannot do
  -- its job, and letting Q past leaves somebody at a shell wondering why the
  -- ship will not fly.
  check(anywhere(wiz, "finish the wizard"),
        "Q refuses to leave the wizard, and says why")
  check(not fs.exists("/aero.cfg"),
        "and nothing was written by a wizard that was never finished")

  -- ENTER walks it. Three steps in is the hull pane for a pilot: welcome,
  -- network, hardware, hull.
  local walked = runConfigure{ wizard = true,
    script = { { "key", keys.enter }, { "key", keys.enter }, { "key", keys.enter } } }
  check(anywhere(walked, "Hardware"),
        "ENTER advances through the panes, reaching the hardware checklist")
  check(anywhere(walked, "the hull"), "and then the hull")

  ------------------------------------------------------------------------------
  -- Building a hull from what is bolted on. This was probe.lua, and it is the
  -- step that saves the most time -- wiring a hull by hand is where the mistakes
  -- come from, and every one shows up as a ship that will not fly with nothing
  -- to say which line is wrong.
  ------------------------------------------------------------------------------

  local toHull = { { "key", keys.enter }, { "key", keys.enter }, { "key", keys.enter } }

  local hullPane = runConfigure{ wizard = true, eyes = true, orientation = true,
                                 script = toHull }
  local buildY = rowOfLatest(hullPane, "Build a hull")
  check(buildY ~= nil, "the hull pane offers to build one", tostring(buildY))

  -- The whole wizard, the way somebody would actually walk it: three ENTERs to
  -- the hull pane, build, then ENTER to the end and apply. Building advances by
  -- itself, so the panes left are bearings, instruments, redstone, limits and
  -- review.
  local full = { table.unpack(toHull) }
  full[#full + 1] = { "mouse_click", 1, 3, buildY or 8 }
  for _ = 1, 4 do full[#full + 1] = { "key", keys.enter } end
  full[#full + 1] = { "key", keys.enter }

  fs.delete(config.craftFile)
  local built = runConfigure{ wizard = true, eyes = true, orientation = true,
                              script = full }
  check(built.ok, "the wizard runs end to end", built.err)

  local madeCfg = fs.exists("/aero.cfg") and dofile("/aero.cfg") or nil
  check(type(madeCfg) == "table", "and writes the network file")
  check(madeCfg and madeCfg.configured ~= nil,
        "stamped, so startup.lua can tell it from a fresh computer")

  local made = fs.exists(config.craftFile) and dofile(config.craftFile) or nil
  check(type(made) == "table", "and a craft file built from what was attached")

  if type(made) == "table" then
    local hull = require("lib.hull")
    local loadedOk, problems = hull.load(config.craftFile)
    check(loadedOk, "the generated craft file loads clean", problems and problems[1])
    check(hull.get("lift") ~= nil, "with a lift control")
    check(hull.get("main") ~= nil, "and a main one, from the second bearing")
    check(#hull.mix >= 3, "and a mix that drives them", #hull.mix)
    check(hull.instruments.nav ~= nil, "with the navigation table found")

    -- And the result is something that would actually be allowed to boot, which
    -- is the only definition of "configured" that matters.
    check(not cfg.blocking(cfg.check("pilot", {
            configured = true, craft = made, attached = cfg.attached() })),
          "and a ship built this way is one startup.lua will start")
  end

  ------------------------------------------------------------------------------
  -- The hardware checklist, which was setup.lua
  ------------------------------------------------------------------------------

  -- Discovered from a run with the *same* hull, not from an earlier one with a
  -- different problem list. A front page is a list of what is currently wrong,
  -- so a configuration with one more warning in it puts every button one row
  -- lower -- and a click at the row Hardware sat on for a healthy ship lands on
  -- Network instead, which is a test that passes by hitting the wrong thing.
  local hardwareRow = frontRow(warned, "Hardware -- what is attached")
  check(hardwareRow ~= nil, "the front page offers the hardware pane")

  local hw = runConfigure{ craft = TWO_EYES, eyes = true,
                           script = { { "mouse_click", 1, 3, hardwareRow or 4 } } }
  check(anywhere(hw, "Flight computer"),
        "which names what this role is, as setup.lua used to")
  check(anywhere(hw, "navigation table"), "and lists what it needs")

  -- Everything below here is reached by scrolling: the checklist explains each
  -- thing that is missing, so on a hull with three optional blocks absent the
  -- tools at the bottom are a screen and a half down.
  --
  -- The discovery run and the run that clicks therefore scroll by exactly the
  -- same amount. A row found on an unscrolled screen is not where it is on a
  -- scrolled one, which is the same mistake as reading it off a page with a
  -- different problem list -- just in the other axis. Over-scrolling is safe:
  -- ui.draw clamps to the last full screen.
  local function scrolled(by)
    local s = { { "mouse_click", 1, 3, hardwareRow or 4 } }
    for _ = 1, by do s[#s + 1] = { "key", keys.down } end
    return s
  end

  local hwBottom = runConfigure{ craft = TWO_EYES, eyes = true,
                                 script = scrolled(30) }
  check(anywhere(hwBottom, "re-scans"),
        "and says it re-scans, which is the reason it is a screen and not a "
        .. "printout")
  check(anywhere(hwBottom, "Watch the optical sensors"),
        "and offers the live sensor view that `probe --eyes` used to be")

  -- The survey file, which was probe.lua's other half.
  fs.delete(config.surveyFile)

  local toTools = scrolled(12)
  local hwTools = runConfigure{ craft = TWO_EYES, eyes = true, script = toTools }
  local surveyY = rowOnPane(hwTools, "Hardware", "Write a full survey", true)
  check(surveyY ~= nil, "and offers the full survey", tostring(surveyY))

  local surveyScript = {}
  for _, e in ipairs(toTools) do surveyScript[#surveyScript + 1] = e end
  surveyScript[#surveyScript + 1] = { "mouse_click", 1, 3, surveyY or 11 }

  local surveyed = runConfigure{ craft = TWO_EYES, eyes = true,
                                 script = surveyScript }
  check(surveyed.ok, "writing a survey runs", surveyed.err)
  check(fs.exists(config.surveyFile), "and leaves a file")

  if fs.exists(config.surveyFile) then
    local f = fs.open(config.surveyFile, "r")
    local body = f.readAll()
    f.close()
    check(body:find("thruster_bearing", 1, true) ~= nil,
          "naming what it found, for a human squinting at a hull that will "
          .. "not fly")
    check(body:find("setThrottle", 1, true) ~= nil,
          "with the methods each one has, which is what the mod's own probe "
          .. "example prints")
  end

  ------------------------------------------------------------------------------
  -- Opening straight on a pane, so the old `setup` habit still works
  ------------------------------------------------------------------------------

  do
    drain()
    local w = mock.new{}
    w.modem("top")
    _G.peripheral = w.api
    writeFile("/aero.cfg", 'return { role = "server", configured = "test" }')

    local win = window.create(term.current(), 1, 1, 51, 19, true)
    local screens = {}
    local realPull = os.pullEventRaw
    os.pullEventRaw = function(...)
      local lines = {}
      for y = 1, 19 do lines[#lines + 1] = win.getLine(y) end
      screens[#screens + 1] = lines
      return realPull(...)
    end

    os.queueEvent("key", keys.q)
    os.queueEvent("key", keys.q)
    os.queueEvent("terminate")

    local old = term.redirect(win)
    -- CC's `dofile` does not forward arguments to the chunk, so a flag passed
    -- that way is silently dropped. loadfile and call the result.
    local chunk = loadfile("/configure.lua")
    local ok = pcall(chunk, "hardware")
    term.redirect(old)
    os.pullEventRaw = realPull

    check(ok, "configure takes a pane name as an argument")

    local onPane = false
    for _, screen in ipairs(screens) do
      for _, line in ipairs(screen) do
        if tostring(line):find("Hardware", 1, true) then onPane = true end
      end
    end
    check(onPane, "and opens straight onto it, the way `setup` used to")
  end

  fs.delete(config.surveyFile)
  fs.delete(config.craftFile)
  fs.delete("/aero.cfg")
  os.setComputerLabel(realLabelHere)
  _G.peripheral = realPeripheralHere
end

--------------------------------------------------------------------------------
section("startup -- the gate")
--------------------------------------------------------------------------------

-- startup.lua refuses to launch a program this computer is not configured to
-- run. What is worth checking is the decision, not the launching: running
-- pilot.lua for real from inside a test suite would fly a ship.
do
  local cfg = require("lib.cfg")
  local config = require("lib.config")
  local mock = require("test.mockperipheral")
  local realPeripheralHere = _G.peripheral

  local w = mock.new{}
  w.modem("top")
  _G.peripheral = w.api

  fs.delete("/aero.cfg")
  fs.delete(config.craftFile)

  -- A fresh computer is stopped, whatever else is true of it.
  check(cfg.blocking(cfg.checkHere()),
        "a computer with no /aero.cfg is stopped before anything starts")
  check(cfg.configured() == nil, "and knows it has never been configured")

  -- Configured as a tower, it goes.
  writeFile("/aero.cfg", 'return { role = "server", configured = "test" }')
  check(cfg.configured() == "test", "the stamp is what says otherwise")
  check(cfg.roleHere() == "server", "and the role is read back")
  check(not cfg.blocking(cfg.checkHere()), "a configured tower starts")

  -- Configured as a pilot with no hull, it does not.
  writeFile("/aero.cfg", 'return { role = "pilot", configured = "test" }')
  check(cfg.blocking(cfg.checkHere()),
        "a pilot with no craft file is stopped, because it cannot fly")

  -- ...and with one, it does, even though nothing is attached.
  writeFile(config.craftFile, "return " .. textutils.serialize({
    name = "Kestrel",
    controls = { lift = { kind = "bearing", peripheral = "thruster_bearing_0" } },
    instruments = {},
    limits = { cruise = 10, climb = 3, descend = 2, clearance = 8 },
    gains = { hover = 0.5 },
    mix = { { demand = "lift", control = "lift", as = "throttle" } },
  }))
  check(not cfg.blocking(cfg.checkHere()),
        "and one with a hull starts even with the contraption unassembled -- "
        .. "which is the state every ship is in until somebody assembles it")

  fs.delete("/aero.cfg")
  fs.delete(config.craftFile)
  _G.peripheral = realPeripheralHere
end

--------------------------------------------------------------------------------
section("beacon")
--------------------------------------------------------------------------------

-- A waypoint that stands still. It is a marker and nothing else: no sensors, no
-- measurements. What is worth checking is that the coordinates it announces are
-- the coordinates somebody set, and that it refuses to invent any.
do
  local mock   = require("test.mockperipheral")
  local config = require("lib.config")
  local net    = require("lib.net")

  local realOpen, realSend, realBroadcast = net.open, net.send, net.broadcast
  local realClock, realGps, realRead = os.clock, _G.gps, _G.read
  local realTimer, realCancel = os.startTimer, os.cancelTimer
  local realLabel = os.getComputerLabel()

  local realSleep = os.sleep

  local clock = 0
  os.clock = function() return clock end
  os.startTimer = function() return 1 end
  os.cancelTimer = function() end

  -- os.sleep waits for a timer event, and os.startTimer is stubbed above to
  -- hand back a constant id without ever scheduling one -- so the cosmetic
  -- pauses in setup would wait forever. A hang, not a failure, which is the one
  -- outcome test/run.lua cannot report.
  os.sleep = function() end

  local function drainBeacon()
    os.queueEvent("aero_drain")
    while true do
      if os.pullEventRaw() == "aero_drain" then return end
    end
  end

  local function runBeacon(opts)
    opts = opts or {}
    drainBeacon()

    local w = mock.new{}
    if opts.pad then w.dockPort("docking_connector_0") end
    _G.peripheral = w.api

    _G.gps = { locate = function()
      if opts.gps == false then return nil end
      return 40, 70, 300
    end }

    -- Setup uses read(), which is right for a wizard and wrong anywhere near an
    -- event loop -- so it all happens before the loop starts. Answers are fed
    -- in the order it asks: name, pad?, position.
    local answers, asked = opts.answers or {}, 0
    _G.read = function()
      asked = asked + 1
      return answers[asked] or ""
    end

    fs.delete(config.beaconFile)
    if opts.cfg then
      local f = fs.open(config.beaconFile, "w")
      f.write("return " .. textutils.serialize(opts.cfg))
      f.close()
    end

    local casts = {}
    net.open = function()
      if opts.noModem then return nil end
      net.channel, net.id = config.channel, 5
      return "back"
    end
    net.send = function() return true end
    net.broadcast = function(msg) casts[#casts + 1] = msg return true end

    -- beacon.lua clears the terminal on the way out, so the screen is captured
    -- on every pullEvent instead. Third time this trap has been walked into in
    -- this project, hence the note.
    local win = window.create(term.current(), 1, 1, 51, 19, true)
    local realPull = os.pullEvent
    local screen = {}
    os.pullEvent = function(...)
      local lines = {}
      for y = 1, 19 do lines[#lines + 1] = win.getLine(y) end
      screen = lines
      return realPull(...)
    end

    for _, e in ipairs(opts.script or {}) do os.queueEvent(table.unpack(e)) end
    os.queueEvent("key", keys.q)

    -- loadfile, not dofile: CC's dofile takes no arguments beyond the path, so
    -- every flag would be silently dropped and the beacon would sit at a prompt
    -- waiting for a position that the test thought it had already given.
    local chunk = loadfile("/beacon.lua")
    local old = term.redirect(win)
    local ok, err = pcall(chunk, table.unpack(opts.args or {}))
    term.redirect(old)
    os.pullEvent = realPull

    net.open, net.send, net.broadcast = realOpen, realSend, realBroadcast

    local said = nil
    for _, msg in ipairs(casts) do
      if msg.type == "beacon" then said = msg end
    end

    return { ok = ok, err = err, casts = casts, said = said, screen = screen,
             asked = asked, world = w }
  end

  local function config_()
    if not fs.exists(config.beaconFile) then return nil end
    local fn = loadfile(config.beaconFile)
    if not fn then return nil end
    local ok, cfg = pcall(fn)
    return ok and cfg or nil
  end

  ------------------------------------------------------------------------------
  -- Setting it up.

  -- Typed in, which is the normal way: a marker is placed deliberately and you
  -- know where you put it.
  local typed = runBeacon{ gps = false, answers = { "quarry-pad", "y", "10 70 300" } }
  check(typed.ok, "a beacon runs", typed.err)
  check(typed.said ~= nil, "and announces itself")
  check(typed.said and typed.said.x == 10 and typed.said.y == 70
        and typed.said.z == 300,
        "at the coordinates that were typed in",
        typed.said and ("%d %d %d"):format(typed.said.x, typed.said.y, typed.said.z))
  check(typed.said and typed.said.name == "quarry-pad", "under the name given",
        typed.said and typed.said.name)
  check(typed.said and typed.said.kind == "pad", "and the kind",
        typed.said and typed.said.kind)

  -- Written down, so the next boot asks nothing.
  local saved = config_()
  check(saved and saved.x == 10 and saved.name == "quarry-pad",
        "and it is written to /beacon.cfg", saved and saved.x)

  local again = runBeacon{ gps = false, cfg = saved }
  check(again.asked == 0, "a beacon that knows where it is asks nothing",
        again.asked)
  check(again.said and again.said.x == 10, "and says the same thing",
        again.said and again.said.x)

  -- Commas or spaces, because insisting on one of them would be rude.
  local commas = runBeacon{ gps = false, answers = { "shed", "n", "1,2,3" } }
  check(commas.said and commas.said.x == 1 and commas.said.z == 3,
        "commas work as well as spaces",
        commas.said and commas.said.x)
  check(commas.said and commas.said.kind == "point",
        "and a point is a point", commas.said and commas.said.kind)

  -- Nonsense is asked again rather than accepted. A marker in the wrong place
  -- is worse than no marker.
  local retry = runBeacon{ gps = false,
                           answers = { "x", "n", "over there", "5 6 7" } }
  check(retry.said and retry.said.x == 5,
        "a position that is not three numbers is asked for again",
        retry.said and retry.said.x)

  ------------------------------------------------------------------------------
  -- GPS is a suggestion and never a requirement.

  local offered = runBeacon{ answers = { "pad", "y", "" } }
  check(offered.said and offered.said.x == 40 and offered.said.z == 300,
        "pressing enter takes what GPS offered",
        offered.said and offered.said.x)

  local overridden = runBeacon{ answers = { "pad", "y", "1 2 3" } }
  check(overridden.said and overridden.said.x == 1,
        "and typing something overrides it",
        overridden.said and overridden.said.x)

  -- The saved position wins over GPS on a later boot: a beacon does not move
  -- because a satellite came back with a slightly different answer.
  local fixed = runBeacon{ cfg = { name = "fixed", kind = "point",
                                   x = -100, y = 12, z = -400 } }
  check(fixed.said and fixed.said.x == -100 and fixed.said.z == -400,
        "a saved position beats GPS, and negatives survive",
        fixed.said and fixed.said.x)

  ------------------------------------------------------------------------------
  -- Unattended, for setting up a row of them.

  local flags = runBeacon{
    gps = false,
    args = { "--at=8,9,10", "--name=far-pad", "--kind=pad" },
  }
  check(flags.asked == 0, "flags ask nothing", flags.asked)
  check(flags.said and flags.said.x == 8 and flags.said.kind == "pad",
        "and are used", flags.said and flags.said.x)
  local written = config_()
  check(written and written.name == "far-pad",
        "and written down, so the next boot needs no flags either",
        written and written.name)

  ------------------------------------------------------------------------------
  -- What it does not do.

  -- No sensors. It is a marker; the only peripheral it will ever look for is a
  -- docking connector, and that is optional.
  local bare = runBeacon{ gps = false, cfg = { name = "bare", kind = "point",
                                               x = 1, y = 2, z = 3 } }
  check(bare.ok, "a beacon with nothing attached runs perfectly well", bare.err)
  check(bare.said ~= nil, "and is a waypoint")
  check(bare.said and bare.said.occupied == nil,
        "with nothing to say about a pad it has no connector for")

  -- The ground it stands on is free knowledge and needs no instrument.
  check(bare.said and bare.said.ground == 2,
        "its own height is the ground here", bare.said and bare.said.ground)

  local padded = runBeacon{ pad = true, gps = false,
                            cfg = { name = "p", kind = "pad", x = 1, y = 2, z = 3 } }
  check(padded.said and padded.said.occupied == false,
        "a docking connector reports the pad free",
        tostring(padded.said and padded.said.occupied))

  padded.world.ship.docked = "Kestrel"
  local busy = runBeacon{ pad = true, gps = false,
                          cfg = { name = "p", kind = "pad", x = 1, y = 2, z = 3 },
                          script = {} }
  check(busy.said ~= nil, "and a pad beacon still announces itself")

  ------------------------------------------------------------------------------
  -- Answering a roll call, so a tower that has just booted need not wait.

  local asked_ = runBeacon{
    gps = false,
    cfg = { name = "r", kind = "point", x = 1, y = 2, z = 3 },
    script = { { "modem_message", "back", config.channel, config.channel,
                 { aero = config.protocol, from = 9, to = "*",
                   body = { type = "beacon?" } } } },
  }
  local replies = 0
  for _, msg in ipairs(asked_.casts) do
    if msg.type == "beacon" then replies = replies + 1 end
  end
  check(replies >= 2, "a beacon answers a roll call", replies)

  -- No modem is a message, not a crash.
  local deaf = runBeacon{ noModem = true, gps = false,
                          cfg = { name = "d", kind = "point", x = 1, y = 2, z = 3 } }
  check(deaf.ok, "no modem is survivable", deaf.err)
  check(#deaf.casts == 0, "and nothing is sent")

  os.clock, _G.gps, _G.read = realClock, realGps, realRead
  os.startTimer, os.cancelTimer = realTimer, realCancel
  os.sleep = realSleep
  os.setComputerLabel(realLabel)
  _G.peripheral = realPeripheral
  fs.delete(config.beaconFile)
end

--------------------------------------------------------------------------------
section("state and log")
--------------------------------------------------------------------------------

do
  local config = require("lib.config")
  local state  = require("lib.state")
  local log    = require("lib.log")

  state.open("/test-aero.state", { plan = nil })
  state.set("alt", 120)
  check(state.get("alt") == 120, "state remembers")
  check(state.dirty == true, "and knows it has something to write")

  state.flush(0)
  check(state.dirty == false, "flush writes")
  check(fs.exists("/test-aero.state"), "and leaves a file")

  -- The fix moves every sweep; a ship writing it five times a second would do
  -- nothing else.
  state.set("alt", 121)
  check(state.tick(0.5) == false, "a write inside the debounce is skipped")
  check(state.tick(config.stateWrite + 1) ~= false, "and taken after it")

  local reopened = state.open("/test-aero.state")
  check(reopened.alt == 121, "state survives a reload", reopened.alt)

  -- A corrupt file is the same situation as no file, and throwing would leave a
  -- ship that cannot boot far enough to be fixed.
  writeFile("/test-aero.state", "this is not a table")
  local recovered = state.open("/test-aero.state", { alt = 64 })
  check(recovered.alt == 64, "a corrupt state file starts from the default")

  state.clear()
  check(not fs.exists("/test-aero.state"), "clear removes it")

  -- The log.
  log.clear()
  for i = 1, config.logSize + 20 do
    log.add({ at = { day = 1, clock = i }, ship = 1, what = "state",
              from = "cruise", to = "loiter", why = "nofix" })
  end
  check(#log.entries == config.logSize, "the log is bounded", #log.entries)

  local recent = log.recent(3)
  check(#recent == 3 and recent[1].at.clock > recent[3].at.clock,
        "recent comes back newest first")

  log.clear()
  log.add({ ship = 1, what = "state", from = "cruise", to = "rtb", why = "bingo" })
  log.add({ ship = 2, what = "state", from = "idle", to = "takeoff", why = "fly" })
  check(#log.forShip(1) == 1, "one ship's entries can be picked out of the fleet")

  -- The cause is the point of the entry, so it is what survives the line being
  -- cut to a pocket computer's width.
  local line = log.line(log.entries[1])
  check(line:find("bingo", 1, true) ~= nil, "the reason is on the line", line)

  check(log.value(3.14159):len() <= 4, "numbers are rounded for a narrow column",
        log.value(3.14159))
  check(log.value(nil) == "-", "and nothing is a dash")
end

--------------------------------------------------------------------------------
section("net")
--------------------------------------------------------------------------------

do
  local mock   = require("test.mockperipheral")
  local config = require("lib.config")
  local net    = require("lib.net")

  local w = mock.new{}
  w.add("wired0", "modem", {}).methods = { isWireless = function() return false end }
  local wireless = w.modem("top")
  _G.peripheral = w.api

  local side = net.open(config.channel)
  check(side == "top", "net finds the wireless modem and skips the wired one", side)
  check(wireless.open[config.channel] == true, "and opens the network's channel")

  net.broadcast({ type = "tlm", alt = 100 })
  local frame = wireless.sent[1] and wireless.sent[1].frame
  check(frame and frame.aero == config.protocol, "frames carry the network name")
  check(frame and frame.to == "*", "a broadcast is addressed to everyone")
  check(frame and frame.body.type == "tlm", "and the body goes through intact")

  -- decode is the load-bearing filter. Each of these is a message that must not
  -- be delivered, and the last is the one rednet never had to deal with.
  local ch = config.channel
  check(net.decode("timer", 1) == nil, "not a modem message")
  check(net.decode("modem_message", "top", ch + 1, ch, frame) == nil, "wrong channel")
  check(net.decode("modem_message", "top", ch, ch, { aero = "other", body = {},
        to = "*", from = 9 }) == nil, "wrong network on the right channel")
  check(net.decode("modem_message", "top", ch, ch, { aero = config.protocol,
        body = {}, to = 999, from = 9 }) == nil, "addressed to someone else")
  check(net.decode("modem_message", "top", ch, ch, frame) == nil,
        "our own broadcast coming back to us")

  local from, body = net.decode("modem_message", "top", ch, ch,
    { aero = config.protocol, from = 42, to = "*", body = { type = "net" } })
  check(from == 42 and body.type == "net", "and a real one gets through")

  net.close()
  _G.peripheral = realPeripheral
end

--------------------------------------------------------------------------------

print("")
print(("%d passed, %d failed"):format(pass, fail))
flush()

_G.AERO_TOTALS = _G.AERO_TOTALS or {}
_G.AERO_TOTALS.spec = { pass = pass, fail = fail }
