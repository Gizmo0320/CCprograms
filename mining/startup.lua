--- Autostart for both halves of the system.
--
-- On a turtle this is what makes a job survive a chunk unload or a server
-- restart: miner.lua finds /miner.state and resumes with nobody watching.
-- On a pocket computer it just brings the remote UI up.

if turtle then
  shell.run("/miner.lua")
elseif pocket then
  shell.run("/remote.lua")
else
  -- Anything else at base is the fleet server. It has the most reason of the
  -- three to come back by itself: a server that stays down after a restart
  -- means nothing dispatches and nothing is recorded.
  shell.run("/server.lua")
end
