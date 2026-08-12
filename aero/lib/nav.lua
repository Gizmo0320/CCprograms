--- Waypoints, legs and the geometry between them.
--
-- Pure. Touches no APIs, reads no clock, and takes `now` as a parameter where it
-- needs one -- the same rule as redstone/lib/rules.lua and mining/lib/fleet.lua,
-- and for the same reason: this is where a sign error puts a ship into a
-- mountain, and it has to be testable as arithmetic rather than by flying.
--
-- ## The heading convention, spelled out
--
-- Heading is **Minecraft yaw**: degrees clockwise from +Z, so 0 is south, 90 is
-- west, 180 is north, 270 is east. That is what navigation_table.getCurrentAngle
-- reports and it is what everything here means by a heading.
--
-- The forward unit vector for heading h is therefore **(-sin h, cos h)**, and
-- the bearing from one point to another is **atan2(-dx, dz)**. Both are written
-- out below rather than inlined, because a sign error in either is invisible in
-- the numbers -- the ship flies confidently in the wrong direction -- and
-- test/mockperipheral.lua's flight model uses the same two formulas so that a
-- disagreement shows up as a test failure rather than as a lost ship.
--
-- Everything here is **planar**. Distance ignores altitude, because a leg's
-- horizontal length is what decides fuel and arrival, and a waypoint forty
-- blocks below is one you have arrived at and now need to descend into.

local config = require("lib.config")

local nav = {}

-- Cobalt is Lua 5.2, where math.atan2 exists; 5.3 deprecated it in favour of a
-- two-argument math.atan and 5.4 removed it. Bound once here so the file runs
-- under a stock Lua as well as in game, and so there is one place to look when
-- every bearing comes back wrong.
local atan2 = math.atan2 or math.atan

--------------------------------------------------------------------------------
-- Angles
--------------------------------------------------------------------------------

--- Fold to [0, 360).
function nav.norm(deg)
  deg = deg % 360
  if deg < 0 then deg = deg + 360 end
  return deg
end

--- The signed turn from `from` to `to`, in [-180, 180].
--
-- Negative is left, positive is right. This is the function the heading PID
-- takes its error from, and the wrap is the whole point of it: a ship on 350
-- asked for 10 must turn 20 degrees right, not 340 degrees left. Getting this
-- wrong is a ship that goes the long way round every single time and looks, from
-- the ground, exactly like a ship with a gain problem.
function nav.turn(from, to)
  local d = nav.norm(to - from + 180) - 180
  -- norm() returns [0,360) so the line above gives (-180, 180]. An exact -180
  -- can only arrive as +180, which is the same turn and a fine answer.
  return d
end

--- The unit vector a ship on this heading is pointing along.
function nav.forward(heading)
  local h = math.rad(heading)
  return -math.sin(h), math.cos(h)
end

--------------------------------------------------------------------------------
-- Points
--------------------------------------------------------------------------------

--- Anything with x/y/z, or nil. Waypoints, fixes and raw tables all go through
--- here so the rest of the file can stop asking.
function nav.point(p)
  if type(p) ~= "table" then return nil end
  local x, y, z = tonumber(p.x), tonumber(p.y), tonumber(p.z)
  if not (x and z) then return nil end
  return { x = x, y = y, z = z }
end

--- Planar distance, in blocks.
function nav.distance(a, b)
  a, b = nav.point(a), nav.point(b)
  if not (a and b) then return nil end
  local dx, dz = b.x - a.x, b.z - a.z
  return math.sqrt(dx * dx + dz * dz)
end

--- The heading that would take you from a to b.
function nav.bearing(a, b)
  a, b = nav.point(a), nav.point(b)
  if not (a and b) then return nil end
  local dx, dz = b.x - a.x, b.z - a.z
  if dx == 0 and dz == 0 then return nil end
  return nav.norm(math.deg(atan2(-dx, dz)))
end

--- Are we there? Inside config.arriveRadius, or the leg's own radius.
--
-- Wide by default, because a ship that cannot turn tightly will orbit a point it
-- is trying to hit exactly, forever, getting closer on no pass.
function nav.arrived(at, target, radius)
  local d = nav.distance(at, target)
  if not d then return false end
  return d <= (radius or config.arriveRadius)
end

--- How far off the straight line from `from` to `to` we are, signed.
--
-- Positive is right of track. Used to nudge the heading target rather than to
-- steer directly: a ship that aims at the destination from wherever it has
-- drifted to flies a curve, which is fine, but one that also corrects back onto
-- the line flies the line, which is what you drew on the map.
function nav.crossTrack(at, from, to)
  at, from, to = nav.point(at), nav.point(from), nav.point(to)
  if not (at and from and to) then return nil end

  local lx, lz = to.x - from.x, to.z - from.z
  local len = math.sqrt(lx * lx + lz * lz)
  if len == 0 then return nil end

  -- The 2D cross product of the leg with the offset, over the leg's length.
  local ox, oz = at.x - from.x, at.z - from.z
  return (lx * oz - lz * ox) / len
end

--- The heading to fly to close on the leg, not merely on the destination.
--
-- `bearing` gets you there; this gets you there along the line. The correction
-- is capped at 45 degrees so a ship blown a long way off track turns towards the
-- line rather than perpendicular to it -- an uncapped correction on a big
-- cross-track error points the ship at right angles to where it is going, which
-- looks like a bug even though it is converging.
function nav.steer(at, from, to, gain)
  local bearing = nav.bearing(at, to)
  if not bearing then return nil end

  local xt = nav.crossTrack(at, from, to)
  if not xt then return bearing end

  local correction = -xt * (gain or 2)
  if correction >  45 then correction =  45 end
  if correction < -45 then correction = -45 end

  return nav.norm(bearing + correction)
end

--------------------------------------------------------------------------------
-- Waypoints
--------------------------------------------------------------------------------

--- Validate a waypoint. Returns ok, reason -- never throws, like every other
--- validator in this repo, because these arrive off the wire and from a pocket
--- computer keyboard.
function nav.check(wp)
  if type(wp) ~= "table" then return false, "not a table" end
  if type(wp.name) ~= "string" or wp.name == "" then return false, "no name" end
  if #wp.name > 16 then return false, "name too long" end
  if wp.name:find("[^%w%-_]") then return false, "name has odd characters" end

  if not nav.point(wp) then return false, "no position" end

  -- A pad is a place to land, which means something has to be there. A point
  -- with no y is a place to fly over and the cruise altitude decides the rest.
  if wp.kind == "pad" and tonumber(wp.y) == nil then
    return false, "a pad needs a height"
  end
  if wp.kind ~= nil and wp.kind ~= "pad" and wp.kind ~= "point" then
    return false, "kind must be 'point' or 'pad'"
  end

  return true
end

--- Install a waypoint into a table of them, replacing any of the same name.
function nav.put(waypoints, wp)
  local ok, why = nav.check(wp)
  if not ok then return false, why end

  waypoints[wp.name] = {
    name = wp.name,
    x = tonumber(wp.x), y = tonumber(wp.y), z = tonumber(wp.z),
    kind = wp.kind or "point",
    note = type(wp.note) == "string" and wp.note or nil,
  }
  return true
end

--- Names in a stable order. pairs() over a map is hash order, so without this
--- the same waypoint list draws differently on the server and on the pocket.
function nav.names(waypoints)
  local out = {}
  for name in pairs(waypoints or {}) do out[#out + 1] = name end
  table.sort(out)
  return out
end

--- The nearest waypoint of a kind to a point. How "land" with no argument finds
--- a pad, and how the bingo-fuel guard finds somewhere to go.
function nav.nearest(waypoints, at, kind)
  local best, bestDistance = nil, nil
  for _, name in ipairs(nav.names(waypoints)) do
    local wp = waypoints[name]
    if not kind or wp.kind == kind then
      local d = nav.distance(at, wp)
      if d and (bestDistance == nil or d < bestDistance) then
        best, bestDistance = wp, d
      end
    end
  end
  return best, bestDistance
end

--------------------------------------------------------------------------------
-- Plans
--------------------------------------------------------------------------------

--- Build a flight plan: a list of legs to fly in order.
--
-- A plan is data, like a rule in the redstone network, for the same three
-- reasons -- it crosses the wire, it is edited on a pocket computer, and it has
-- to survive a reboot. Nothing here is a closure or a coroutine.
--
--   { alt = 90, legs = { {name="quarry", x=.., y=.., z=.., kind="point"}, ... },
--     leg = 1, from = {x,y,z} }
--
-- `from` is where the current leg started, which cross-track needs and which
-- cannot be recovered afterwards -- by the time you are halfway along a leg,
-- where you set off from is gone unless it was written down.
function nav.plan(waypoints, names, alt)
  local legs, missing = {}, {}

  for _, name in ipairs(names or {}) do
    local wp = waypoints[name]
    if wp then
      -- A **copy**, not the waypoint itself. Two reasons, and both have teeth:
      --
      --   * a plan is a snapshot. Moving a pad while a ship is on its way to it
      --     should not silently move the ship's destination underneath it.
      --   * the plan and the waypoint table are written to the same state file,
      --     and textutils.serialize refuses a table that appears twice. Sharing
      --     the reference made every save throw -- from inside the control
      --     loop, on a ship in the air.
      legs[#legs + 1] = {
        name = wp.name, x = wp.x, y = wp.y, z = wp.z,
        kind = wp.kind, note = wp.note,
      }
    else
      missing[#missing + 1] = name
    end
  end

  if #missing > 0 then
    return nil, "no waypoint named " .. table.concat(missing, ", ")
  end
  if #legs == 0 then
    return nil, "a plan with no legs is not a plan"
  end

  return { alt = tonumber(alt), legs = legs, leg = 1, from = nil }
end

--- The leg being flown, or nil when the plan is finished.
function nav.current(plan)
  if type(plan) ~= "table" or type(plan.legs) ~= "table" then return nil end
  return plan.legs[plan.leg or 1]
end

--- Move to the next leg. Returns the new leg, or nil at the end of the plan.
--
-- `at` becomes the new leg's origin. Taken from where the ship actually is
-- rather than from the waypoint just passed, because it passed within
-- arriveRadius of it and not through it, and a cross-track computed from a point
-- the ship was never at starts every leg with an error it then corrects.
function nav.advance(plan, at)
  if type(plan) ~= "table" then return nil end
  plan.leg = (plan.leg or 1) + 1
  plan.from = nav.point(at)
  return nav.current(plan)
end

--- How far is left to fly, following the plan from where we are now.
--
-- The bingo-fuel guard's question is "can I finish this", and the answer is not
-- the distance to the next waypoint -- a ship two blocks from a waypoint with
-- six hundred blocks of plan behind it has plenty of fuel to reach the waypoint
-- and none to reach the end.
function nav.remaining(plan, at)
  local leg = nav.current(plan)
  if not leg then return 0 end

  local total = nav.distance(at, leg) or 0
  local previous = leg

  for i = (plan.leg or 1) + 1, #plan.legs do
    total = total + (nav.distance(previous, plan.legs[i]) or 0)
    previous = plan.legs[i]
  end

  return total
end

--- How long that takes at a speed, in seconds. `nil` when stopped, rather than
--- infinity: a ship that is not moving has no arrival time, and a guard
--- comparing infinity to a fuel figure would turn every hover into a mayday.
function nav.eta(distance, speed)
  if not distance then return nil end
  if not speed or speed <= 0.1 then return nil end
  return distance / speed
end

return nav
