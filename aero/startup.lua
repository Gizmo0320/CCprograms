--- Autostart, and the gate in front of it.
--
-- Two jobs, in this order:
--
--   1. Refuse to start a program this computer is not configured to run, and
--      hand over to `configure` instead.
--   2. Work out which of the four programs this computer is, and run it.
--
-- ## Why the gate is here
--
-- The programs used to start whatever state the computer was in, on the theory
-- that each of them warned about its own problems as it went. The trouble is
-- that a warning has to be read, and the moment a program starts it redraws the
-- screen -- so the message explaining why nothing works was replaced, a tenth of
-- a second later, by a dashboard confidently showing nothing working. The
-- commonest way to lose an evening with this program was a pilot with no
-- /craft.cfg sitting there looking like a pilot.
--
-- cc-mek-scada's startup does the same thing and it is the right shape: try to
-- load the configuration, and if it will not load, run the configurator, then
-- try again. A computer that cannot do its job should say so once, clearly, on a
-- screen that stays up.
--
-- ## What it will and will not stop for
--
-- **Configuration only. Never hardware.** See the note at the top of
-- `lib/cfg.lua`: assembling a contraption is what attaches its peripherals, so
-- every ship in the world is missing its navigation table right up until the
-- moment it is assembled, and `hull.remount` exists to pick them up when they
-- appear. A gate on attached hardware would trap every ship at a screen it has
-- no way to satisfy, and would strand a ship that was flying a minute ago and
-- came back from a chunk unload.
--
-- So a pilot with no hull file is stopped, and a pilot with a hull file and
-- nothing plugged in is started.

local cfg = require("lib.cfg")
local ui  = require("lib.ui")

--------------------------------------------------------------------------------

--- Say what is wrong, and hold it on screen long enough to be read.
local function complain(problems)
  ui.paint(ui.theme.text, ui.theme.bg)
  term.clear()
  term.setCursorPos(1, 1)

  ui.paint(ui.theme.bad, ui.theme.bg)
  print("This computer is not configured.")
  ui.paint(ui.theme.text, ui.theme.bg)
  print("")

  for _, problem in ipairs(problems) do
    if problem.severity == "bad" then
      ui.paint(ui.theme.bad, ui.theme.bg)
      print("  " .. problem.text)
    end
  end

  ui.paint(ui.theme.text, ui.theme.bg)
  print("")
  print("Starting `configure`...")
  os.sleep(2)
end

--------------------------------------------------------------------------------

local problems = cfg.checkHere()

if cfg.blocking(problems) then
  complain(problems)
  shell.run("/configure.lua", "--wizard")

  -- Re-read from disk rather than trusting anything cached. `configure` runs in
  -- its own environment with its own copy of lib/config, so the values this
  -- program loaded at the top of the file are the old ones by now.
  problems = cfg.checkHere()

  if cfg.blocking(problems) then
    ui.paint(ui.theme.text, ui.theme.bg)
    term.clear()
    term.setCursorPos(1, 1)
    ui.paint(ui.theme.bad, ui.theme.bg)
    print("Still not configured, so nothing was started.")
    ui.paint(ui.theme.text, ui.theme.bg)
    print("")
    for _, problem in ipairs(problems) do
      if problem.severity == "bad" then print("  " .. problem.text) end
    end
    print("")
    print("Run `configure` when you are ready, or reboot.")
    return
  end
end

--------------------------------------------------------------------------------

-- Read after the gate, not before it: the role is one of the things `configure`
-- may just have changed.
local role = cfg.roleHere()

-- A pilot has by far the most reason of the four to come back by itself. A
-- redstone node that stayed at the shell after a restart is a base with the
-- lights off; a pilot that stayed at the shell is a ship with nobody flying it,
-- and it was probably in the air when the chunk unloaded.
--
-- pilot.lua's own boot order handles the rest: it hands the hull back to
-- redstone before it does anything else, and comes up loitering rather than
-- cruising, because a ship returning from an unload has no idea how long it was
-- away or where it is now.
if role == "remote" then
  shell.run("/remote.lua")

elseif role == "server" then
  shell.run("/server.lua")

elseif role == "beacon" then
  -- A beacon has the most to lose from not restarting: it is the fixed point
  -- other things navigate by, and one that stayed at the shell after its chunk
  -- reloaded would quietly stop being a waypoint while still looking like one.
  shell.run("/beacon.lua")

else
  shell.run("/pilot.lua")
end
