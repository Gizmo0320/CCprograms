--- The hold laws, and the mix that turns them into control positions.
--
-- Pure. Takes a fix, a goal and the time; returns demands. Touches no APIs and
-- reads no clock, which is what lets test/fly_spec.lua fly it against a
-- simulated hull for two hundred sweeps and ask whether it settles. A PID that
-- oscillates looks exactly like one that does not when you are reading the
-- source, and "setThrottle was called with 0.63" asserts nothing about whether
-- the ship arrives.
--
-- ## Demands are abstract, and that is the point
--
-- The loops produce four numbers -- lift, forward, yaw, pitch -- and know
-- nothing about thrusters. The **mix** in /craft.cfg maps those onto whatever
-- this hull actually has, which is why a jet, a balloon and a truck can share
-- one autopilot: they disagree about what a bearing does, not about what
-- "climb" means.
--
--   mix = {
--     { demand = "lift",    control = "lift", as = "throttle" },
--     { demand = "forward", control = "main", as = "throttle" },
--     { demand = "yaw",     control = "main", as = "pivot",  scale = 30 },
--     { demand = "pitch",   control = "trim", as = "angleX", scale = 15 },
--   }
--
-- ## Cascade, not one loop
--
-- Altitude does not drive the throttle. It drives a **desired rate of climb**,
-- which drives the throttle. Two reasons, and the second is the important one:
--
--   * the climb and descent limits in /craft.cfg are then a clamp on one number
--     in one place, rather than something the gains have to be chosen to imply
--   * a single altitude→throttle loop has to be tuned soft enough not to
--     overshoot from a hundred blocks below, which makes it far too soft to hold
--     altitude in gusty air. The inner loop is tuned for holding and the outer
--     for approaching, and neither compromises for the other.
--
-- ## What every loop here has to get right
--
--   * **Clamped integral.** A ship sitting on the pad accumulates altitude error
--     all night, and then leaves like a rocket. The clamp bounds it, and
--     `reset` clears it on every change of flight state.
--   * **Derivative on measurement, not on error.** A new target changes the
--     error instantly; differentiating that gives an unbounded kick on every
--     command. Differentiating the measurement gives the same damping with no
--     kick, which is why the sign below looks backwards and is not.
--   * **Heading error is a signed turn.** nav.turn, not subtraction: a ship on
--     350 asked for 10 must turn 20 right, not 340 left.
--   * **Heading has no integral at all.** A turning ship accumulates heading
--     error for as long as the turn takes, and an integral would hold the rudder
--     over past the roll-out every time.

local config = require("lib.config")
local nav    = require("lib.nav")

local autopilot = {}

--------------------------------------------------------------------------------
-- Gains
--------------------------------------------------------------------------------

-- Tuned against test/mockperipheral.lua's flight model -- a hull that hovers at
-- half throttle, reaches full thrust in about a second and has enough drag to
-- settle. A real Create ship will want its own numbers, which is why these are
-- overridable from /craft.cfg and tunable live from the pocket computer: nobody
-- is going to reinstall the program to try 0.4 instead of 0.35.
autopilot.defaults = {
  -- Altitude (outer): blocks of error -> blocks/second of desired climb.
  altP = 0.35,

  -- Climb rate (inner): blocks/second of error -> throttle.
  vsP = 0.07, vsI = 0.05, vsD = 0.02, vsIMax = 0.45,

  -- Where the throttle sits when the ship is neither climbing nor sinking. Only
  -- a starting guess: vsI finds the true value within a few seconds and holds
  -- it, which is the whole reason the inner loop has an integral. Getting it
  -- roughly right just means the ship does not sink while that happens.
  hover = 0.5,

  -- Heading: degrees of error -> yaw demand. No integral, see above.
  --
  -- Scaled so that a full yaw demand is about 36 degrees a second on the model
  -- hull: 45 degrees of error asks for roughly two thirds of the available
  -- authority, which turns onto a new heading in a couple of seconds without
  -- arriving sideways.
  --
  -- hdgD is small on purpose, and was ten times this to begin with. Yaw drives
  -- a *rate* of turn, so the plant is very nearly a pure integrator and needs
  -- almost no damping to be stable. At 0.05 the derivative term reached 1.8 on
  -- a turn already in progress -- larger than the entire output range -- and
  -- the ship rolled out of the turn, overshot the other way, and hunted across
  -- forty-six degrees forever. It looked exactly like a gain that was too high.
  hdgP = 0.015, hdgD = 0.006,

  -- Ground speed: blocks/second of error -> forward throttle.
  spdP = 0.18, spdI = 0.06, spdIMax = 0.6,

  -- How much of the yaw demand also goes to pitch/roll trim, for hulls with a
  -- virtual orientation source. Purely cosmetic on most ships -- it banks into
  -- the turn -- so it is small and never load-bearing.
  bank = 0.5,
}

--- Merge /craft.cfg's gains over the defaults. Unknown keys are kept rather
--- than dropped, so a hull can carry gains for a mix term this file has never
--- heard of without them being silently thrown away on every load.
function autopilot.gains(custom)
  local g = {}
  for k, v in pairs(autopilot.defaults) do g[k] = v end
  for k, v in pairs(custom or {}) do
    if tonumber(v) then g[k] = tonumber(v) end
  end
  return g
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

function autopilot.new(gains)
  return {
    gains = autopilot.gains(gains),
    loops = {},         -- [name] = { i = , lastM = }
    at    = nil,        -- when we last stepped, for dt
    demands = { lift = 0, forward = 0, yaw = 0, pitch = 0 },
  }
end

--- Forget the integrals and the derivative history.
--
-- Called on every change of flight state. Carrying a climb integral into a
-- descent is a ship that keeps climbing for several seconds after being told to
-- come down, and carrying a derivative across a gap in the sweep produces one
-- enormous spurious rate from a dt that was never real.
function autopilot.reset(st)
  st.loops = {}
  st.at = nil
  return st
end

--------------------------------------------------------------------------------

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

--- One PID step. `measure` is what the derivative is taken of.
local function pid(st, name, err, measure, p, i, d, iMax, dt)
  local loop = st.loops[name]
  if not loop then
    loop = { i = 0, lastM = measure }
    st.loops[name] = loop
  end

  local out = p * err

  if i and i ~= 0 and dt then
    loop.i = clamp(loop.i + err * dt, -(iMax or 1), (iMax or 1))
    out = out + i * loop.i
  end

  if d and d ~= 0 and dt and loop.lastM ~= nil then
    -- Negative because this is the derivative of the *measurement*: a
    -- measurement rising towards its target is an error falling, and the damping
    -- term has to oppose the rise.
    out = out - d * (measure - loop.lastM) / dt
  end

  loop.lastM = measure
  return out
end

--------------------------------------------------------------------------------
-- The laws
--------------------------------------------------------------------------------

--- Work out what the controls should be doing.
--
-- `goal` is what lib/flight.lua decided, and every field is optional:
--
--   alt      hold this altitude
--   vs       climb or descend at this rate, overriding alt
--   heading  point this way
--   speed    make this good over the ground
--   idle     true: hands off, everything to zero
--
-- Anything absent is a loop that does not run, and a loop that does not run
-- leaves its demand at zero rather than at whatever it was last sweep. A ship
-- told to stop navigating must actually stop pushing, not coast on the last
-- forward demand until something else happens to write one.
function autopilot.step(st, fix, goal, now)
  goal = goal or {}
  local g = st.gains
  local limits = goal.limits or {}

  local dt = st.at and (now - st.at) or nil
  if dt and (dt <= 0 or dt > 2) then
    -- A gap that long is a chunk that unloaded or a program that was paused.
    -- Integrating across it would add several seconds of error in one step and
    -- differentiate a rate that never happened.
    dt = nil
    autopilot.reset(st)
  end
  st.at = now

  local demands = { lift = 0, forward = 0, yaw = 0, pitch = 0 }

  if goal.idle then
    -- Not a special case in the loops -- an explicit early return, so that
    -- "idle" cannot quietly become "every target is nil and therefore zero",
    -- which is the same demands for a completely different reason.
    st.demands = demands
    return st, demands
  end

  -- Vertical -----------------------------------------------------------------

  local climbLimit   = tonumber(limits.climb)   or 4
  local descendLimit = tonumber(limits.descend) or 3

  local wantVs = tonumber(goal.vs)

  if wantVs == nil and tonumber(goal.alt) and fix.alt then
    local err = goal.alt - fix.alt
    wantVs = g.altP * err
  end

  if wantVs ~= nil then
    wantVs = clamp(wantVs, -descendLimit, climbLimit)
    demands.wantVs = wantVs        -- carried for the dashboard, not used below

    local vs  = fix.vs or 0
    local err = wantVs - vs

    demands.lift = clamp(
      g.hover + pid(st, "vs", err, vs, g.vsP, g.vsI, g.vsD, g.vsIMax, dt),
      0, 1)
  end

  -- Heading ------------------------------------------------------------------

  if tonumber(goal.heading) and fix.heading then
    local err = nav.turn(fix.heading, goal.heading)

    -- The derivative is taken of the heading error rather than of the heading
    -- itself, because heading wraps: a ship crossing 360 would show a
    -- derivative of minus three hundred and sixty degrees per sweep and slam the
    -- rudder to the stop. The error is continuous across the wrap and the kick
    -- this normally causes cannot happen here, because the target is a heading
    -- that changes smoothly rather than a setpoint someone types.
    demands.yaw = clamp(
      pid(st, "hdg", err, -err, g.hdgP, 0, g.hdgD, 0, dt),
      -1, 1)

    -- `level` is the attitude guard asking for wings level. Banking into a turn
    -- is a nicety; banking a hull that is already leaning further than the guard
    -- is happy with is the opposite of what was asked for.
    demands.pitch = goal.level and 0 or clamp(demands.yaw * g.bank, -1, 1)
    demands.headingError = err
  end

  -- Speed --------------------------------------------------------------------

  if tonumber(goal.speed) then
    local speed = fix.speed or 0
    local err   = goal.speed - speed

    demands.forward = clamp(
      pid(st, "spd", err, speed, g.spdP, g.spdI, g.spdD, g.spdIMax, dt),
      0, 1)

    -- A ship pointing a long way from where it wants to go should slow down
    -- rather than sprint off in the wrong direction and correct later. Below
    -- about sixty degrees of error this costs almost nothing; above it, the
    -- ship turns nearly on the spot, which is what you would do.
    if demands.headingError then
      local off = math.abs(demands.headingError)
      if off > 20 then
        demands.forward = demands.forward * clamp(1 - (off - 20) / 70, 0.1, 1)
      end
    end
  end

  st.demands = demands
  return st, demands
end

--------------------------------------------------------------------------------
-- The mix
--------------------------------------------------------------------------------

--- Turn demands into the control positions lib/hull.apply writes.
--
-- Terms accumulate, so two thrusters can both take a share of lift and one
-- control can take both forward and yaw. `bias` is added once per term and
-- `scale` multiplies the demand, which between them cover every case the hulls
-- here need: a throttle that idles at 0.2, a pivot that swings thirty degrees
-- for a full yaw demand.
function autopilot.apply(mix, demands)
  local out = {}

  for _, term in ipairs(mix or {}) do
    local value = demands[term.demand]
    if value ~= nil then
      out[term.control] = out[term.control] or {}
      local control = out[term.control]
      control[term.as] = (control[term.as] or 0) + value * (term.scale or 1) + (term.bias or 0)
    end
  end

  return out
end

--------------------------------------------------------------------------------

--- Is the ship where it was asked to be? Used by lib/flight to decide a climb
--- has finished, not to control anything.
function autopilot.settled(fix, goal)
  if not fix then return false end

  if tonumber(goal.alt) then
    if not fix.alt then return false end
    if math.abs(goal.alt - fix.alt) > config.altTolerance then return false end
  end

  if tonumber(goal.heading) then
    if not fix.heading then return false end
    if math.abs(nav.turn(fix.heading, goal.heading)) > config.headingTolerance then
      return false
    end
  end

  return true
end

return autopilot
