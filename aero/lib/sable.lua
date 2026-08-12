--- The physics object itself, through CC: Sable.
--
-- Create Aeronautics is built on Sable, and CC: Sable exposes the sub-level a
-- computer is riding on directly: its pose, its real velocity, its angular
-- velocity, its mass. That is a strictly better class of information than any
-- sensor block, and where it is available this module is preferred over all of
-- them.
--
-- It is the second module here that touches an API, and the only other one --
-- `sublevel` and `aero` are globals rather than peripherals, so lib/hull has no
-- way to reach them. Like lib/hull it reads the globals at call time rather than
-- capturing them at load, so the test harness can substitute a ship.
--
-- ## What this buys, and it is a lot
--
--   * **A real velocity vector.** lib/instruments differentiates position to get
--     one, smoothed, which costs lag in the derivative the altitude loop uses
--     for damping. getLinearVelocity is the actual number.
--   * **Real attitude.** An orientation quaternion, rather than sixteen steps of
--     redstone or two angles from a gimbal block.
--   * **Angular velocity**, which nothing else here can measure at all, and
--     which is what tells a tumbling ship from a banking one.
--   * **Mass**, and the dimension's gravity and drag.
--
-- ## Everything here can fail, and normally does
--
-- Every sublevel call throws "This computer is not on a Sub-Level!" when the
-- contraption is unassembled -- which is its state on the pad, while you are
-- building it, and every time it is taken apart. That is not an error
-- condition, it is half the ship's life, so every call is wrapped and the whole
-- module degrades to nil rather than to a fault.
--
-- The calls are also all `mainThread = true`, so they yield. That is fine inside
-- the control loop's coroutine and is worth knowing before anyone calls one from
-- somewhere that cannot yield.

local nav = require("lib.nav")

local sable = {}

sable.available = nil     -- nil = not yet asked, then true/false
sable.problems  = {}

--------------------------------------------------------------------------------
-- Maths
--------------------------------------------------------------------------------

-- Pure, and separated out precisely so it can be tested: this is the part where
-- a sign error puts the ship's "up" somewhere it is not, and no amount of
-- staring at a quaternion tells you whether it is right.

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

--- Attitude from an orientation quaternion `{x, y, z, w}`.
--
-- Returns tilt, pitch, roll, heading -- all in degrees, or nil for a quaternion
-- that is not one.
--
-- The three axes of the ship in world coordinates are the columns of the
-- rotation matrix the quaternion describes:
--
--   right (local +X) = ( 1-2(y²+z²),  2(xy+wz),    2(xz-wy)  )
--   up    (local +Y) = ( 2(xy-wz),    1-2(x²+z²),  2(yz+wx)  )
--   fwd   (local +Z) = ( 2(xz+wy),    2(yz-wx),    1-2(x²+y²) )
--
-- **`tilt` is the one that matters** and it is deliberately not an Euler angle:
-- it is the angle between the ship's own up and the world's, straight out of the
-- dot product, which is `up.y`. No convention to argue about, no gimbal lock,
-- and one number that answers "how far from level is this thing" whichever way
-- it is facing. Everything the attitude guard does is built on it.
--
-- pitch is positive nose-down and roll positive right-side-down, matching the
-- redstone gimbal reader in lib/hull so the two sources cannot disagree about
-- which way round they are.
function sable.attitude(q)
  if type(q) ~= "table" then return nil end
  local x, y, z, w = tonumber(q.x), tonumber(q.y), tonumber(q.z), tonumber(q.w)
  if not (x and y and z and w) then return nil end

  local upY    = 1 - 2 * (x * x + z * z)
  local fwdX   = 2 * (x * z + w * y)
  local fwdY   = 2 * (y * z - w * x)
  local fwdZ   = 1 - 2 * (x * x + y * y)
  local rightY = 2 * (x * y + w * z)

  local tilt  = math.deg(math.acos(clamp(upY, -1, 1)))
  local pitch = -math.deg(math.asin(clamp(fwdY, -1, 1)))
  local roll  = -math.deg(math.asin(clamp(rightY, -1, 1)))

  -- The ship's own +Z, which is whichever way it happened to be built facing.
  -- Useful as a heading of last resort and nothing more: it may sit at a
  -- constant offset from what the navigation table calls the heading, and
  -- lib/instruments prefers the table for exactly that reason.
  local heading = nil
  if not (fwdX == 0 and fwdZ == 0) then
    heading = nav.norm(math.deg(math.atan2 and math.atan2(-fwdX, fwdZ)
                                or math.atan(-fwdX, fwdZ)))
  end

  return tilt, pitch, roll, heading
end

--- Length of an `{x, y, z}`.
function sable.magnitude(v)
  if type(v) ~= "table" then return nil end
  local x, y, z = tonumber(v.x) or 0, tonumber(v.y) or 0, tonumber(v.z) or 0
  return math.sqrt(x * x + y * y + z * z)
end

--------------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------------

--- Call a CC: Sable function, and never throw.
--
-- The globals are looked up on every call rather than captured, both so a test
-- can substitute them and because a mod being absent is a perfectly ordinary
-- configuration for this program to run in.
local function get(api, method, ...)
  local t = _G[api]
  if type(t) ~= "table" or type(t[method]) ~= "function" then return nil end

  local ok, result = pcall(t[method], ...)
  if not ok then return nil end
  return result
end

--- Is CC: Sable installed at all? Asked once; the answer cannot change without
--- the world restarting, and every program here would restart with it.
function sable.present()
  if sable.available == nil then
    sable.available = type(_G.sublevel) == "table"
      and type(_G.sublevel.isInPlotGrid) == "function"
  end
  return sable.available
end

--- Everything the physics engine will tell us, or nil if it will not.
--
-- Returns nil rather than an empty table when the computer is not on an
-- assembled sub-level, so the caller can tell "no data" from "data that happens
-- to be zero" -- which on a velocity is the difference between stationary and
-- unknown.
function sable.read()
  if not sable.present() then return nil end

  -- Cheap, does not throw, and false is the normal answer on a pad. Asking it
  -- first means the unassembled case costs one call rather than a dozen failed
  -- ones every sweep.
  if get("sublevel", "isInPlotGrid") ~= true then return nil end

  local out = { on = true }

  local pose = get("sublevel", "getLogicalPose")
  if type(pose) == "table" then
    if type(pose.position) == "table" then
      out.pos = { x = tonumber(pose.position.x),
                  y = tonumber(pose.position.y),
                  z = tonumber(pose.position.z) }
      if not (out.pos.x and out.pos.y and out.pos.z) then out.pos = nil end
    end

    out.tilt, out.pitch, out.roll, out.heading = sable.attitude(pose.orientation)
  end

  local linear = get("sublevel", "getLinearVelocity")
  if type(linear) == "table" then
    out.velocity = { x = tonumber(linear.x) or 0,
                     y = tonumber(linear.y) or 0,
                     z = tonumber(linear.z) or 0 }
  end

  local angular = get("sublevel", "getAngularVelocity")
  if type(angular) == "table" then
    -- Radians per second out of the physics engine, degrees per second
    -- everywhere in this program. A spin rate in the wrong unit is a tumble
    -- guard that fires at fifty-seven times the intended angle.
    out.spin = math.deg(sable.magnitude(angular) or 0)
  end

  out.mass = tonumber(get("sublevel", "getMass"))
  out.name = get("sublevel", "getName")
  if type(out.name) ~= "string" or out.name == "" then out.name = nil end

  return out
end

--- The dimension's own physics, which does not change and is read once.
--
-- Chiefly for the dashboard and for anyone tuning a hull: knowing that gravity
-- here is 9.8 and universal drag is 0.02 explains a great deal about why a set
-- of gains that worked in the overworld does nothing in the end.
function sable.world()
  if not sable.present() then return nil end
  if type(_G.aero) ~= "table" then return nil end

  local gravity = get("aero", "getGravity")
  return {
    gravity = gravity and sable.magnitude(gravity) or nil,
    gravityVector = gravity,
    drag = tonumber(get("aero", "getUniversalDrag")),
    north = get("aero", "getMagneticNorth"),
  }
end

--- Name the sub-level itself, so the ship is labelled in the world and not only
--- on the dashboard. Companion to hull.setPlateName.
function sable.setName(name)
  if not sable.present() then return false end
  local t = _G.sublevel
  if type(t) ~= "table" or type(t.setName) ~= "function" then return false end
  return pcall(t.setName, tostring(name))
end

return sable
