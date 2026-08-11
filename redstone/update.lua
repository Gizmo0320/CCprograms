--- Pull the latest version from GitHub.
--
--   update            fetch and reboot
--   update --check    say whether anything would change, and change nothing
--
-- Nodes can also be updated over the wire: the pocket computer's rules screen
-- sends this. A node with a pulse outstanding refuses -- see node.lua -- because
-- rebooting halfway through a pulse leaves the output stuck on, the restore
-- having been half a second away and now never coming.
--
-- Deliberately a separate program from install.lua rather than a flag on it.
-- `update` is the thing you type, it is what the network-wide push runs, and it
-- never has to guess whether you meant a fresh install.

local args = { ... }

local checkOnly = false
local positional = {}
for _, a in ipairs(args) do
  if a == "--check" or a == "-c" then
    checkOnly = true
  elseif a ~= "" then
    -- Empty strings are dropped, not treated as values. node.lua invokes this
    -- through shell.run with placeholders for arguments it may not have, and an
    -- empty branch name builds a URL that 404s in a way that looks like the
    -- repo has gone missing.
    positional[#positional + 1] = a
  end
end

local BRANCH = positional[1] or "main"
local REPO   = positional[2] or "Gizmo0320/CCprograms"
local BASE   = ("https://raw.githubusercontent.com/%s/%s/redstone/"):format(REPO, BRANCH)

local function colour(c)
  if term.isColour() then term.setTextColour(c) end
end

local function say(text, c)
  colour(c or colours.white)
  print(text)
  colour(colours.white)
end

--- Fetch, with a cache buster. raw.githubusercontent serves a cached copy for a
--- few minutes, and an update that hands you back the version you already have
--- is a genuinely baffling way to lose an afternoon.
local function fetch(path)
  local url = BASE .. path .. "?nocache=" .. tostring(math.random(1, 1e9))
  local res, err = http.get(url)
  if not res then return nil, tostring(err or "no response") end
  local body = res.readAll()
  res.close()
  if not body or #body == 0 then return nil, "empty file" end
  return body
end

local function readLocal(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local body = f.readAll()
  f.close()
  return body
end

--------------------------------------------------------------------------------

if not http then
  say("The HTTP API is disabled; cannot update.", colours.red)
  return
end

say("Checking " .. REPO .. " @ " .. BRANCH .. "...", colours.lightGrey)

local manifest, why = fetch("manifest.txt")
if not manifest then
  say("Could not fetch the file list: " .. why, colours.red)
  return
end

local files = {}
for line in manifest:gmatch("[^\r\n]+") do
  line = line:match("^%s*(.-)%s*$")
  if line ~= "" and not line:match("^#") then files[#files + 1] = line end
end

-- Download everything first and compare, so "nothing to do" is free and a
-- half-finished update never happens. A tree where node.lua is new and
-- lib/ports.lua is old fails in ways that look like bugs in neither.
local changed, bodies, failed = {}, {}, {}
for _, path in ipairs(files) do
  local body, err = fetch(path)
  if not body then
    failed[#failed + 1] = path .. " (" .. err .. ")"
  else
    bodies[path] = body
    if readLocal("/" .. path) ~= body then changed[#changed + 1] = path end
  end
end

if #failed > 0 then
  say("Nothing changed. These could not be downloaded:", colours.red)
  for _, f in ipairs(failed) do say("  " .. f, colours.white) end
  return
end

if #changed == 0 then
  say("Already up to date.", colours.lime)
  return
end

say(("%d file(s) changed:"):format(#changed), colours.yellow)
for _, path in ipairs(changed) do say("  " .. path, colours.white) end

if checkOnly then
  say("--check: nothing written.", colours.lightGrey)
  return
end

for _, path in ipairs(changed) do
  local target = "/" .. path
  local dir = fs.getDir(target)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end

  local tmp = target .. ".part"
  local f = fs.open(tmp, "w")
  if not f then
    say("Could not write " .. tmp, colours.red)
    return
  end
  f.write(bodies[path])
  f.close()
  if fs.exists(target) then fs.delete(target) end
  fs.move(tmp, target)
end

say("Updated. Rebooting.", colours.lime)
os.sleep(1)
os.reboot()
