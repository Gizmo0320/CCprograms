--- Test entry point.
--
-- Run under CraftOS-PC with the project copied to the computer root:
--
--   CraftOS-PC --headless -d <datadir> --script <abs path to test/run.lua>
--
-- Results land in /test-results.txt on the emulated computer, because headless
-- mode renders the whole terminal on every redraw and is unreadable when piped.
--
-- The suite is wrapped in a pcall so an uncaught error is recorded and the
-- emulator still exits. Without this, an error prints to the terminal and drops
-- CraftOS into its shell, which then blocks until the host kills the process --
-- a crash looks exactly like a hang.

local problems = {}

-- remote_spec first: spec.lua replaces os.sleep with an instant version to keep
-- the mining tests quick, and the remote's event loop should not inherit that.
for _, suite in ipairs({ "/test/fleet_spec.lua", "/test/server_spec.lua",
                         "/test/remote_spec.lua", "/test/spec.lua" }) do
  local ok, err = pcall(dofile, suite)
  if not ok then
    problems[#problems + 1] = suite .. ": "
      .. (type(err) == "table" and textutils.serialize(err) or tostring(err))
  end
end

if #problems > 0 then
  local f = fs.open("/test-error.txt", "w")
  for _, p in ipairs(problems) do f.writeLine(p) end
  f.close()
end

os.shutdown()
