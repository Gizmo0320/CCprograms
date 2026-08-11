--- Shared configuration for every program here.
--
-- These are the defaults. Anything in /redstone.cfg overrides them -- see the
-- bottom of this file. Change things there, not here: this file is replaced
-- wholesale by `update`, and /redstone.cfg is not, which is the entire point of
-- the split.

local config = {}

-- The modem channel every program on this network talks on: the port. A modem
-- never raises an event for a channel it has not opened, so two networks on
-- different channels genuinely do not touch -- unlike rednet, which puts
-- everyone on the same two channels and filters after delivery.
--
-- Any number from 1 to 65535. The default is deliberately not the mining
-- fleet's 3141, so a world can run both without either being told about the
-- other. install.lua asks for it and writes it into /redstone.cfg.
config.channel = 2718

-- A name for the network, carried in every frame. The channel does the real
-- separating; this catches two networks accidentally configured on the same
-- number, which is otherwise a confusing failure where a node quietly takes
-- orders from the wrong base.
config.protocol = "redstone"

-- What this computer is. Unlike the mining fleet -- where a turtle is a turtle
-- and a pocket computer is a pocket computer -- a node and a server are both
-- plain computers and no amount of peripheral sniffing tells them apart. So it
-- is asked at install time and recorded, rather than guessed at every boot.
--
-- "node" | "server". A pocket computer ignores this and is always the remote.
config.role = "node"

--------------------------------------------------------------------------------
-- Files
--------------------------------------------------------------------------------

-- Which ports this computer has and how they are wired. Per-computer, so it is
-- deliberately not in manifest.txt: `update` replaces every file it lists, and
-- wiring that survived exactly until the first update would be worse than none.
config.portsFile = "/ports.cfg"

-- A node's own state: current outputs, latch states, pending timers.
config.stateFile = "/redstone.state"

-- The server's: roster, scenes, cross-node rules, log.
config.networkFile = "/network.state"

-- Rules a node evaluates for itself. Separate from stateFile because one is
-- configuration you wrote and the other is bookkeeping the program owns, and
-- losing the second should never cost you the first.
config.rulesFile = "/rules.cfg"

--------------------------------------------------------------------------------
-- Timing
--------------------------------------------------------------------------------

-- Unsolicited state broadcast interval (seconds).
config.heartbeat = 2

-- Pocket side: no heartbeat for this long means CONNECTION LOST. It must never
-- show a stale value as though it were live -- the whole job of this program is
-- telling you what is on right now.
config.heartbeatTimeout = 6

-- Server side: no heartbeat for this long and a node is presumed lost. Longer
-- than heartbeatTimeout, because the pocket can afford to cry wolf and the
-- server uses this to decide a scene fan-out failed.
config.staleAfter = 15

-- How often the rule sweep runs when nothing has changed.
--
-- The `redstone` event covers input changes, but it will never tell us a
-- debounce has expired, a pulse should end or a repeat timer has come round. So
-- the sweep is driven by a timer as well as the event. A quarter second is four
-- game ticks: fast enough that a light feels immediate, slow enough that it is
-- not a busy loop.
config.sweep = 0.25

-- Never write the state file more often than this (seconds). A pulse rule
-- firing at sweep rate would otherwise write the disk raw.
config.stateWrite = 1

-- Longest a pulse may be asked to hold an output, as a guard against a typo in
-- the pocket UI leaving a piston out for an hour.
config.maxPulse = 60

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

-- /redstone.cfg is a Lua file returning a table of settings to override,
-- written by install.lua and edited by hand if you like:
--
--   return { protocol = "base-north", channel = 4200, role = "server" }
--
-- It is deliberately **not** in manifest.txt, so `update` never touches it.
config.overridesFile = "/redstone.cfg"

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
  -- obvious way to get back in and fix it.
end

return config
