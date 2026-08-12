--- Autostart for all three programs.
--
-- A pilot has by far the most reason of the three to come back by itself. A
-- redstone node that stayed at the shell after a restart is a base with the
-- lights off; a pilot that stayed at the shell is a ship with nobody flying it,
-- and it was probably in the air when the chunk unloaded.
--
-- pilot.lua's own boot order handles the rest: it hands the hull back to
-- redstone before it does anything else, and comes up loitering rather than
-- cruising, because a ship returning from an unload has no idea how long it was
-- away or where it is now.

local config = require("lib.config")

if pocket then
  shell.run("/remote.lua")
elseif config.role == "server" then
  shell.run("/server.lua")
else
  -- Hardware cannot tell these apart -- a pilot and a tower are both plain
  -- computers, and the peripherals that would give it away are on the
  -- contraption rather than on the computer. install.lua asks and records the
  -- answer in /aero.cfg, and anything that has not been asked is a pilot, which
  -- is the one there are many of.
  shell.run("/pilot.lua")
end
