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
  for _, word in ipairs({ "probe", "craft.cfg", "balloon", "hold = true",
                          "wireless modem", "tether", "guard", "bingo",
                          "hover", "waypoint" }) do
    checkQuiet(#guide.search(word) > 0, "the manual mentions " .. word)
  end
  check(#guide.search("probe") > 0 and #guide.search("bingo") > 0,
        "and covers what somebody in trouble would search for")

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
                          "beacon", "range", "plate", "swivel" }) do
    checkQuiet(hull.instruments[role] ~= nil, "found " .. role, role)
  end
  check(hull.instruments.beacon ~= nil and hull.instruments.range ~= nil,
        "the two linked receivers are found by their real type names")
  check(hull.instruments.plate ~= nil, "and so is the nameplate")

  local raw = hull.read(1)
  check(raw.beacon == 135, "a directional link gives a bearing to the nearest link",
        raw.beacon)
  check(raw.beaconRange == 42.5, "and a modulating one gives the range",
        raw.beaconRange)
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
section("probe")
--------------------------------------------------------------------------------

-- probe.lua writes the file every ship depends on, and it is the first thing
-- anyone runs. The check that matters is the round trip: whatever it generates
-- has to be a file lib/hull can actually load, because the alternative is a
-- syntax error discovered on an assembled contraption with no working copy of
-- anything to fall back on.
do
  local mock = require("test.mockperipheral")
  local hull = require("lib.hull")
  local config = require("lib.config")

  local w = mock.new{}
  w.bearing("thruster_bearing_0", { count = 2 })
  w.bearing("thruster_bearing_1", { count = 4 })
  w.navTable("navigation_table_0")
  w.altimeter("altitude_sensor_0")
  w.optical("optical_sensor_0")
  w.orientation("virtual_orientation_source_0")
  _G.peripheral = w.api

  fs.delete(config.craftFile)
  fs.delete(config.craftFile .. ".new")
  fs.delete(config.surveyFile)

  local ok = pcall(dofile, "/probe.lua")
  check(ok, "probe runs")
  check(fs.exists(config.surveyFile), "and writes a survey")
  check(fs.exists(config.craftFile), "and a craft file")

  local body = (function()
    local f = fs.open(config.surveyFile, "r") local b = f.readAll() f.close() return b
  end)()
  check(body:find("thruster_bearing", 1, true) ~= nil,
        "naming what it found, for a human squinting at a hull that will not fly")

  -- The round trip.
  local loadedOk, problems = hull.load(config.craftFile)
  check(loadedOk, "the generated craft file loads clean",
        problems and problems[1])
  check(hull.get("lift") ~= nil, "with a lift control")
  check(hull.get("main") ~= nil, "and a main one, from the second bearing")
  check(#hull.mix >= 3, "and a mix that drives them", #hull.mix)
  check(hull.instruments.nav ~= nil, "with the navigation table found")

  -- Never overwritten. A generated file replacing a hull somebody tuned over an
  -- evening would be the most annoying thing this program could do.
  local kept = "-- mine\nreturn { controls = {}, mix = {} }\n"
  writeFile(config.craftFile, kept)
  pcall(dofile, "/probe.lua")

  local after = (function()
    local f = fs.open(config.craftFile, "r") local b = f.readAll() f.close() return b
  end)()
  check(after == kept, "a second run does not overwrite an existing craft file")
  check(fs.exists(config.craftFile .. ".new"),
        "and leaves its suggestion beside it instead")

  fs.delete(config.craftFile)
  fs.delete(config.craftFile .. ".new")
  fs.delete(config.surveyFile)
  _G.peripheral = realPeripheral
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
