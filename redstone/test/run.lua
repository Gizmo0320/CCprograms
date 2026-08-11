--- Test entry point.
--
-- Run under CraftOS-PC with the project copied to the computer root:
--
--   CraftOS-PC --headless -d <datadir> --script <abs path to test/run.lua>
--
-- Results land in /test-*.txt on the emulated computer, with the totals in
-- /test-summary.txt, because headless mode renders the whole terminal on every
-- redraw and is unreadable when piped.
--
-- Every suite is wrapped in a pcall. Without it an uncaught error prints to the
-- terminal and drops CraftOS into its shell, which then blocks until the host
-- kills the process -- so a crash looks exactly like a hang.
--
-- spec.lua goes first because it is the one that would still pass if the three
-- programs were deleted, and a failure there explains failures everywhere else.
-- The program suites replace parts of lib/net and the clock; each puts back what
-- it borrowed, and running them in a fixed order keeps that honest.
--
-- install_spec.lua goes last because it is the only one that writes to the
-- computer root the tree under test lives in.

local suites = {
  { name = "spec",   path = "/test/spec.lua"        },
  { name = "node",   path = "/test/node_spec.lua"   },
  { name = "server", path = "/test/server_spec.lua" },
  { name = "remote", path = "/test/remote_spec.lua" },
  { name = "install", path = "/test/install_spec.lua" },
}

_G.RS_TOTALS = {}

local problems = {}

for _, suite in ipairs(suites) do
  local ok, err = pcall(dofile, suite.path)
  if not ok then
    problems[#problems + 1] = suite.path .. ": "
      .. (type(err) == "table" and textutils.serialize(err) or tostring(err))
  end
end

local lines, pass, fail = {}, 0, 0
for _, suite in ipairs(suites) do
  local totals = _G.RS_TOTALS[suite.name]
  if totals then
    pass, fail = pass + totals.pass, fail + totals.fail
    lines[#lines + 1] = ("%-8s %4d passed, %d failed")
      :format(suite.name, totals.pass, totals.fail)
  else
    lines[#lines + 1] = ("%-8s did not finish"):format(suite.name)
  end
end

lines[#lines + 1] = ""
lines[#lines + 1] = ("total    %4d passed, %d failed"):format(pass, fail)
for _, why in ipairs(problems) do lines[#lines + 1] = why end

local f = fs.open("/test-summary.txt", "w")
for _, line in ipairs(lines) do f.writeLine(line) end
f.close()

if #problems > 0 then
  local e = fs.open("/test-error.txt", "w")
  for _, why in ipairs(problems) do e.writeLine(why) end
  e.close()
end

os.shutdown()
