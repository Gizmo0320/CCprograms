--- Autostart for all three programs.
--
-- A node has the most reason of the three to come back by itself: it is holding
-- outputs, and an output is held by the computer rather than by the world. A
-- node that stayed at the shell after a restart is a base with the lights off
-- and no indication why.

local config = require("lib.config")

if pocket then
  shell.run("/remote.lua")
elseif config.role == "server" then
  shell.run("/server.lua")
else
  -- Unlike the mining fleet, hardware cannot tell these apart -- a node and a
  -- server are both plain computers. install.lua asks and records the answer in
  -- /redstone.cfg, and anything that has not been asked is a node, which is the
  -- one there are many of.
  shell.run("/node.lua")
end
