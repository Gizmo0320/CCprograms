--- Shared configuration for every program here.
--
-- These are the defaults. Anything in /aero.cfg overrides them -- see the bottom
-- of this file. Change things there, not here: this file is replaced wholesale
-- by `update`, and /aero.cfg is not, which is the entire point of the split.
--
-- What is *not* here is anything about a particular hull. Which thruster does
-- lift, how far a bearing may pivot, what the gains are -- that is /craft.cfg,
-- because it differs per ship and this file is the same on every computer on the
-- network. See lib/hull.lua.

local config = {}

-- The modem channel every program on this network talks on: the port. A modem
-- never raises an event for a channel it has not opened, so two networks on
-- different channels genuinely do not touch -- unlike rednet, which puts
-- everyone on the same two channels and filters after delivery.
--
-- Any number from 1 to 65535. The default is deliberately neither the mining
-- fleet's 3141 nor the redstone network's 2718, so one world can run all three
-- without any of them being told about the others. install.lua asks for it and
-- writes it into /aero.cfg.
config.channel = 1618

-- A name for the network, carried in every frame. The channel does the real
-- separating; this catches two networks accidentally configured on the same
-- number, which is otherwise a confusing failure where a ship quietly takes
-- orders from the wrong tower.
config.protocol = "aero"

-- What this computer is. Like the redstone network and unlike the mining fleet,
-- hardware cannot tell a pilot from a server -- both are plain computers -- so
-- install.lua asks and records the answer rather than guessing at every boot.
--
-- "pilot" | "server". A pocket computer ignores this and is always the remote.
config.role = "pilot"

--------------------------------------------------------------------------------
-- Files
--------------------------------------------------------------------------------

-- This hull: which peripheral is which control, the mix, the limits, the gains.
-- Per-ship, so it is deliberately not in manifest.txt: `update` replaces every
-- file it lists, and a Kestrel that flew like a Kestrel exactly until the first
-- update would be worse than one that never flew.
config.craftFile = "/craft.cfg"

-- A pilot's own: the flight plan, the cached waypoints, the last known fix.
config.stateFile = "/aero.state"

-- The server's: roster, waypoints, pads, routes, log.
config.fleetFile = "/fleet.state"

-- Where probe.lua writes what it found. Plain text, meant to be read by a human
-- squinting at a hull that will not fly.
config.surveyFile = "/aero.survey.txt"

--------------------------------------------------------------------------------
-- Timing
--------------------------------------------------------------------------------

-- Unsolicited telemetry interval (seconds). Twice as fast as the redstone
-- network's heartbeat: a lamp can be a second stale without anyone minding, and
-- a ship at cruise covers twelve blocks in that second.
config.heartbeat = 1

-- Pocket side: no telemetry for this long means CONNECTION LOST. It must never
-- show a stale position as though it were live -- a dashboard confidently
-- drawing a ship where it was ten seconds ago is worse than one that admits it
-- does not know.
config.heartbeatTimeout = 4

-- Server side: no telemetry for this long and a ship is presumed lost. Longer
-- than heartbeatTimeout, because the pocket can afford to cry wolf and the
-- server uses this to decide a ship needs looking for.
config.staleAfter = 10

-- How often the control loop runs.
--
-- Unlike redstone/node.lua there is no event to react to: nothing in CC raises
-- an event because a ship has drifted off heading. The timer is the whole clock,
-- and every derivative in lib/instruments.lua is taken across it. Five sweeps a
-- second is fast enough for a PID on something this slow and heavy, and slow
-- enough that it is not a busy loop.
config.sweep = 0.2

-- Never write the state file more often than this (seconds). The plan changes
-- rarely but the fix changes every sweep, and a ship writing its position to
-- disk five times a second would do nothing else.
config.stateWrite = 1

--------------------------------------------------------------------------------
-- Flight
--------------------------------------------------------------------------------

-- Most a throttle may move per second, 0..1. A step from 0 to 1 on a lift
-- bearing is a ship launched rather than a ship raised, and the physics does not
-- care that the PID only meant it for one sweep.
config.slew = 0.6

-- How long a fix may be dead-reckoned before it is unusable (seconds).
--
-- Past this, lib/flight.lua stops navigating and loiters. Dead reckoning
-- integrates heading and a scalar speed, so its error grows without bound and
-- there is nothing to correct it against; flying a guessed course into a
-- mountain is strictly worse than hanging in the air waiting for the navigation
-- table to answer again.
config.reckonLimit = 8

-- Inside this many blocks of a waypoint, the leg is flown (blocks). Wide enough
-- that a ship which cannot turn tightly does not circle its own destination
-- forever trying to hit it exactly.
config.arriveRadius = 6

-- Vertical tolerance for "at altitude" (blocks), used to decide a climb has
-- finished rather than to control anything.
config.altTolerance = 2

-- Heading tolerance for "pointing the right way" (degrees).
config.headingTolerance = 8

-- Below this ground clearance the terrain guard takes the aircraft off its
-- flight plan and climbs, whatever else it had been asked to do. Overridden per
-- hull by limits.clearance in /craft.cfg; this is the floor for a hull that did
-- not say.
config.clearance = 6

-- Fuel margin. A leg is refused, and an airborne ship turns for home, when the
-- burn time remaining is less than the time to get home times this. Anything at
-- 1.0 arrives dry, and a headwind is not something we can measure.
config.fuelReserve = 1.5

--------------------------------------------------------------------------------
-- Altitude
--------------------------------------------------------------------------------

-- How far one tap of up or down moves the hold altitude (blocks). Ten is a
-- storey and a bit: small enough to place a ship over a wall, large enough that
-- getting from the ground to cruise is not thirty taps.
config.altStep = 10

-- The highest and lowest a ship may be sent, as a guard against a typo rather
-- than as a flight envelope (blocks). Minecraft's build limits with a little
-- room; a hull can narrow them with limits.ceiling and limits.floor.
--
-- Worth having because the altitude is now something you type, and "1500"
-- instead of "150" on a ship that will happily try is a ship that spends the
-- next four minutes climbing out of sight.
config.maxAlt = 320
config.minAlt = -60

--------------------------------------------------------------------------------
-- Who is flying
--------------------------------------------------------------------------------

-- How long a commander's silence lasts before control lapses (seconds).
--
-- Long, because the holder of the conn is not obliged to keep talking -- they
-- may be watching a ship fly a leg for two minutes -- and short enough that
-- somebody who put their pocket computer in a chest does not own the ship
-- forever. An explicit takeover works at any time regardless; this is only for
-- the case where nobody is there to release it.
config.conn = 90

--------------------------------------------------------------------------------
-- Attitude
--------------------------------------------------------------------------------

-- How far from level the ship may lean before it stops navigating and
-- concentrates on being level again (degrees). Overridden per hull by
-- limits.tilt.
config.tiltLimit = 25

-- ...and how far before the autopilot stops flying it altogether (degrees).
--
-- This is not "very tilted", it is the angle past which **our idea of up is no
-- longer up**. Every control law here assumes the lift demand pushes the ship
-- away from the ground; on a hull leaning past about seventy degrees it pushes
-- it sideways, and on one past ninety it pushes it *down*. A ship on its back
-- with the autopilot still calling for more lift is being flown into the ground
-- by its own altitude hold, at full power, and no amount of good intent in the
-- outer loop can help. So the hull is handed back and the physics is allowed to
-- sort it out, which it usually does.
config.tiltAbort = 70

-- Angular velocity above which the ship is tumbling rather than manoeuvring
-- (degrees per second). Only measurable with CC: Sable; without it the guard
-- falls back to the tilt angle alone, which catches a ship that has gone over
-- but not one that is spinning.
config.spinLimit = 90

--------------------------------------------------------------------------------
-- Obstacles
--------------------------------------------------------------------------------

-- How many seconds of travel to keep clear of whatever is in front (seconds).
--
-- Deliberately generous, and it was two to begin with. **A ship has no brakes.**
-- Zeroing the forward demand does not stop it; drag does, exponentially, and a
-- hull at twelve blocks a second with a drag coefficient around a third coasts
-- something like thirty-four blocks before it is really stopped. Triggering at
-- twenty-four meant the guard fired, the ship climbed, and it still drifted into
-- the cliff -- which is a guard that reports for duty and achieves nothing.
--
-- Four seconds is forty-eight blocks at cruise, which clears a ridge the ship
-- can climb over. It is still not enough to stop dead in front of something
-- unclimbable: see the note in lib/flight.lua's obstacle guard. A hull with real
-- drag wants this higher.
config.reaction = 4

-- The least distance a forward obstacle may be at whatever the speed, so a ship
-- creeping up to something still stops before it touches (blocks).
config.standoff = 6

--------------------------------------------------------------------------------
-- The pilot's hands
--------------------------------------------------------------------------------

-- How long the joystick must be left alone before the autopilot takes the ship
-- back (seconds). Short enough to catch a ship that has been let go of, long
-- enough that pausing between inputs does not hand control back mid-manoeuvre.
config.handback = 3

--------------------------------------------------------------------------------
-- Log
--------------------------------------------------------------------------------

-- How many events the ring buffer keeps. This is the one thing here that grows
-- without limit if left alone, and a computer that fills its disk stops being
-- able to write its state file at all.
config.logSize = 200

--------------------------------------------------------------------------------
-- Local overrides
--------------------------------------------------------------------------------

-- /aero.cfg is a Lua file returning a table of settings to override, written by
-- install.lua and edited by hand if you like:
--
--   return { protocol = "north-fleet", channel = 4300, role = "server" }
--
-- It is deliberately **not** in manifest.txt, so `update` never touches it.
config.overridesFile = "/aero.cfg"

if fs and fs.exists(config.overridesFile) then
  local fn = loadfile(config.overridesFile)
  if fn then
    local ok, custom = pcall(fn)
    if ok and type(custom) == "table" then
      for key, value in pairs(custom) do config[key] = value end
    end
  end
  -- A malformed overrides file is ignored rather than fatal. Every program here
  -- requires this module at load, so throwing would brick the computer with no
  -- obvious way to get back in and fix it -- and on a pilot it would brick it
  -- mid-air.
end

return config
