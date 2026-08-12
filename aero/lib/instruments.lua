--- One fix, from whatever the hull could tell us.
--
-- Pure. Takes the raw table lib/hull.read built and the time, and returns the
-- single answer to "where is this ship and what is it doing" that everything
-- downstream uses. No APIs, no clock -- so the whole of dead reckoning is
-- testable as arithmetic, which is the only way anyone is going to trust it.
--
-- ## Why this is not just a rename of the raw readings
--
-- Three things the instruments do not supply and something has to:
--
--   * **A velocity vector.** velocity_sensor.getVelocity is a scalar with no
--     direction. Cross-track, arrival and dead reckoning all need components, so
--     position is differenced across the sweep to get them.
--   * **Vertical speed.** Nothing reports it. The altitude PID needs it as its
--     derivative term, and taking the derivative inside the PID instead would
--     mean the ship's rate of climb existed in only one place and could not be
--     shown on the dashboard or used by the descent profile.
--   * **A position at all, sometimes.** The navigation table returns nothing
--     when the sub-level it refers to is not loaded, and a GPS fix needs
--     satellites in range. Both go away in normal flight.
--
-- ## The three sources, in order
--
--   nav     the navigation table's projected world position. Authoritative.
--   gps     a gps.locate() result, passed in by the caller rather than read
--           here, because this module touches no APIs. Used when nav is silent.
--   reckon  last known position advanced along last known heading at last known
--           speed.
--
-- Dead reckoning has no way to correct itself: it integrates a heading that may
-- be wrong and a scalar speed that says nothing about drift, so its error grows
-- without bound and nothing here can tell you by how much. Past
-- config.reckonLimit seconds the fix is marked **not usable** and lib/flight
-- stops navigating on it. Hanging in the air waiting for the navigation table to
-- answer is strictly better than flying a guess into a hillside, and a program
-- that quietly kept navigating on a twenty-second-old estimate would do exactly
-- that while looking, from the dashboard, entirely healthy.

local config = require("lib.config")
local nav    = require("lib.nav")

local instruments = {}

--------------------------------------------------------------------------------

--- A first fix, for a ship that has just booted and knows nothing.
function instruments.blank()
  return {
    x = nil, y = nil, z = nil,
    alt = nil, heading = nil,
    speed = 0, vx = 0, vz = 0, vs = 0,
    pitch = nil, roll = nil,
    clearance = nil, docked = nil,
    source = "none", fixAge = math.huge, altAge = math.huge,
    usable = false, levelled = false,
    at = nil,
  }
end

--- Smooth a derivative a little.
--
-- Position comes back quantised -- the navigation table reports block
-- coordinates as well as exact ones, and either way a sweep is 0.2s, so a ship
-- doing four blocks a second moves 0.8 of a block between reads. Differencing
-- that raw gives a vertical speed that jumps between 0 and 8 depending on which
-- side of a block boundary the sample landed, and a PID fed that derivative
-- shakes the ship apart.
--
-- A first-order filter over about half a second is enough. Heavier smoothing
-- costs lag, and lag in a derivative is what turns damping into oscillation.
local SMOOTH = 0.35

local function blend(old, new)
  if old == nil then return new end
  if new == nil then return old end
  return old + (new - old) * SMOOTH
end

--------------------------------------------------------------------------------

--- Build the current fix. `prev` is the last one, `raw` is lib/hull.read's
--- table, `gps` is an {x,y,z} from gps.locate or nil, `now` is the clock.
function instruments.fuse(prev, raw, gps, now)
  prev = prev or instruments.blank()
  raw  = raw or {}
  now  = now or 0

  -- CC: Sable, when the ship is an assembled sub-level. Strictly better than
  -- every sensor here -- real velocity, real orientation, real angular velocity
  -- -- so it is taken first and the derived versions fill in behind it.
  local phys = raw.sable

  local fix = {
    at = now,
    pitch = raw.pitch, roll = raw.roll,
    clearance = raw.clearance, ground = raw.ground,
    ahead = raw.ahead, aheadBlock = raw.aheadBlock,
    docked = raw.docked, stick = raw.stick, signals = raw.signals,
    beacon = raw.beacon, beaconRange = raw.beaconRange, swivel = raw.swivel,
    tiltSource = raw.tiltSource,
    pressure = raw.pressure, linked = raw.linked,
    fuel = raw.fuel, capacity = raw.capacity, burn = raw.burn,
    thrust = raw.thrust, lift = raw.lift,
    faults = raw.faults,
    mass = phys and phys.mass or nil,
    assembled = phys ~= nil,
  }

  -- Attitude. The physics engine's is exact and complete; the gimbal sensor's is
  -- two angles; the redstone reader's is sixteen steps of those. Taken in that
  -- order, and `tilt` -- the single angle from level, which is what the attitude
  -- guard runs on -- only exists at all with CC: Sable, so without it the guard
  -- falls back to whichever of pitch and roll is worse.
  if phys and phys.tilt then
    fix.tilt, fix.pitch, fix.roll = phys.tilt, phys.pitch, phys.roll
    fix.tiltSource = "sable"
  elseif fix.pitch or fix.roll then
    fix.tilt = math.max(math.abs(fix.pitch or 0), math.abs(fix.roll or 0))
  end

  -- Angular velocity, which nothing but CC: Sable can measure. A ship can be
  -- perfectly level and still be a quarter of a second from being upside down.
  fix.spin = phys and phys.spin or nil

  local dt = prev.at and (now - prev.at) or nil
  if dt and dt <= 0 then dt = nil end

  -- Position -----------------------------------------------------------------

  -- The navigation table first even though the physics pose is arguably more
  -- exact: the table reports a *projected world* position, which is the frame
  -- every waypoint is written in, and a sub-level's own pose is not necessarily
  -- the same numbers. Mixing two frames in one fix would be a ship that jumps
  -- several blocks whenever one source drops out.
  local position = nav.point(raw.pos) or nav.point(gps)
    or (phys and nav.point(phys.pos))
  local source = nav.point(raw.pos) and "nav"
    or (nav.point(gps) and "gps"
    or (phys and nav.point(phys.pos) and "sable" or nil))

  if position then
    fix.x, fix.y, fix.z = position.x, position.y, position.z
    fix.source = source
    fix.fixAge = 0

  elseif prev.x and dt then
    -- Reckon. Along the last heading at the last speed, which is the best that
    -- can be done and is not very good.
    local fx, fz = nav.forward(prev.heading or 0)
    fix.x = prev.x + fx * (prev.speed or 0) * dt
    fix.z = prev.z + fz * (prev.speed or 0) * dt
    fix.y = (prev.y or 0) + (prev.vs or 0) * dt
    fix.source = "reckon"
    fix.fixAge = (prev.fixAge or 0) + dt

  else
    fix.x, fix.y, fix.z = prev.x, prev.y, prev.z
    fix.source = prev.x and "reckon" or "none"
    fix.fixAge = math.huge
  end

  -- Heading ------------------------------------------------------------------

  -- The navigation table is the only thing that knows which way the ship is
  -- pointing. Course made good from two positions is not the same quantity --
  -- a ship being pushed sideways has one heading and a different course -- so it
  -- is not substituted here. A hull with no navigation table simply has no
  -- heading, and lib/flight refuses to navigate rather than steering on a guess.
  --
  -- CC: Sable's orientation gives a heading too, but it is the sub-level's own
  -- +Z -- whichever way the ship happened to be built facing -- so it may sit at
  -- a constant offset from what the table calls the heading. Good enough to fly
  -- on when there is nothing else, wrong to prefer when there is.
  fix.heading = tonumber(raw.heading)
    or (phys and phys.heading)
    or prev.heading

  -- Altitude -----------------------------------------------------------------

  -- The altitude sensor is preferred over the position's y. It is a direct
  -- reading rather than a projection, it survives the navigation table going
  -- quiet, and the altitude hold is the one loop that has to keep working when
  -- everything else has stopped -- a ship that cannot navigate can still hover.
  --
  -- **Altitude is aged separately from position**, and this is not fussiness.
  -- The altitude used to be `raw.alt or fix.y`, and fix.y falls back to the
  -- previous fix's y when reckoning -- so a ship that lost its altimeter *and*
  -- its navigation table kept reporting the last height it ever knew, forever,
  -- and the guard that exists to catch exactly that never fired. A remembered
  -- altitude is every bit as dangerous as a remembered position, and rather
  -- more so: the vertical loop is the one holding the ship up.
  local altitude = tonumber(raw.alt)

  if altitude then
    fix.alt, fix.altAge = altitude, 0
  elseif position then
    -- No altimeter, but a fresh position, so its y is current.
    fix.alt, fix.altAge = fix.y, 0
  elseif prev.alt and dt then
    fix.alt = prev.alt + (prev.vs or 0) * dt
    fix.altAge = (prev.altAge or 0) + dt
  else
    fix.alt, fix.altAge = prev.alt, math.huge
  end

  -- Velocity -----------------------------------------------------------------

  -- The real thing when there is one. Differentiating position is smoothed, and
  -- smoothing costs lag in exactly the derivative the altitude loop uses for
  -- damping -- so a measured velocity is not a small improvement here, it is a
  -- better-behaved control loop.
  if phys and phys.velocity then
    fix.vx, fix.vz = phys.velocity.x, phys.velocity.z
    fix.vs = phys.velocity.y
    fix.velocitySource = "sable"

  elseif dt and prev.x and fix.x then
    fix.vx = blend(prev.vx, (fix.x - prev.x) / dt)
    fix.vz = blend(prev.vz, (fix.z - prev.z) / dt)
    fix.vs = (dt and prev.alt and fix.alt)
      and blend(prev.vs, (fix.alt - prev.alt) / dt) or (prev.vs or 0)
    fix.velocitySource = "derived"

  else
    fix.vx, fix.vz = prev.vx or 0, prev.vz or 0
    fix.vs = (dt and prev.alt and fix.alt)
      and blend(prev.vs, (fix.alt - prev.alt) / dt) or (prev.vs or 0)
    fix.velocitySource = "derived"
  end

  -- Ground speed from the components rather than from the velocity sensor: the
  -- sensor's scalar includes the vertical, so a ship climbing straight up reads
  -- as moving at four blocks a second when it is not going anywhere.
  fix.speed = math.sqrt(fix.vx * fix.vx + fix.vz * fix.vz)

  -- The sensor's reading is kept anyway. It is the only independent check on the
  -- differentiated figures, and on the dashboard a large disagreement between
  -- the two is the clearest sign that the position source is lying.
  fix.sensedSpeed = tonumber(raw.speed)

  -- Usable? ------------------------------------------------------------------

  -- Two separate questions, deliberately not collapsed into one. `usable` is
  -- "may this fix be navigated on", and `flying` is "does this ship know its own
  -- altitude" -- a hull whose navigation table has gone quiet still has an
  -- altimeter and can still hold height while it waits.
  fix.usable = fix.x ~= nil
    and fix.heading ~= nil
    and (fix.fixAge or math.huge) <= config.reckonLimit

  fix.levelled = fix.alt ~= nil
    and (fix.altAge or math.huge) <= config.reckonLimit

  return fix
end

--------------------------------------------------------------------------------

--- Ground clearance, preferring the optical sensor and falling back to the
--- altitude above a known ground height.
--
-- Returns nil when neither is available, and nil must stay nil: a clearance of
-- zero is a ship on the ground, and the terrain guard reading zero over a canyon
-- because nothing answered would climb away from nothing at full power.
function instruments.clearance(fix, groundLevel)
  if fix.clearance ~= nil then return fix.clearance end
  if fix.alt ~= nil and tonumber(groundLevel) then
    return fix.alt - groundLevel
  end
  return nil
end

--- How stale, in words, for a status line. The dashboard's job is to never show
--- a stale value as though it were live.
function instruments.age(fix, now)
  if not fix or not fix.at then return "no fix" end
  local age = (now or fix.at) - fix.at
  if fix.source == "nav" then return "nav" end
  if fix.source == "gps" then return "gps" end
  if fix.source == "none" then return "no fix" end
  return ("dr %ds"):format(math.floor((fix.fixAge or age) + 0.5))
end

return instruments
