--- Startup shim for running the suite under CCEmuX.
--
-- CCEmuX has no `--script` flag the way CraftOS-PC does: it boots a computer
-- whose root is a directory and runs that computer's `startup.lua`. But this
-- directory already has a `startup.lua`, and it is a real one -- it picks the
-- pilot, the tower or the pocket by hardware and then flies a ship. Booting the
-- test tree directly would start a flight computer instead of a test run.
--
-- So the harness copies the tree somewhere scratch and drops this file in as
-- `startup.lua`. See the Tests section of README.md for the command.
--
-- `os.shutdown()` at the end is what makes it usable from a script at all.
-- Without it the emulator sits at a shell prompt forever, and a suite that has
-- finished looks exactly like one that has hung.

local ok, err = pcall(function() shell.run("test/run.lua") end)

if not ok then
  -- Crash to a file, for the same reason `run.lua` wraps each suite: an error
  -- here happens after the terminal has scrolled and before anything is
  -- written, so without this the only evidence is an empty results directory.
  local h = fs.open("/crash.txt", "w")
  h.write(tostring(err))
  h.close()
end

os.shutdown()
