--- Installer. Run this on a fresh turtle, pocket computer or server:
--
--   wget run https://raw.githubusercontent.com/Gizmo0320/CCprograms/main/mining/install.lua
--
-- It fetches the file list from manifest.txt and downloads everything to the
-- computer root. The same tree goes on every machine -- startup.lua works out
-- what it is running on -- so there is one thing to install and no way to put
-- the wrong half on the wrong computer.
--
-- Optional arguments: install <branch> <owner/repo>

local args = { ... }

local BRANCH = args[1] or "main"
local REPO   = args[2] or "Gizmo0320/CCprograms"
local BASE   = ("https://raw.githubusercontent.com/%s/%s/mining/"):format(REPO, BRANCH)

--------------------------------------------------------------------------------

local function colour(c)
  if term.isColour() then term.setTextColour(c) end
end

local function say(text, c)
  colour(c or colours.white)
  print(text)
  colour(colours.white)
end

--- Fetch a file. The cache buster matters: raw.githubusercontent serves a
--- cached copy for a few minutes, and reinstalling to pick up a fix you just
--- pushed only to be handed the old file is a genuinely baffling way to lose an
--- afternoon.
local function fetch(path)
  local url = BASE .. path .. "?nocache=" .. tostring(math.random(1, 1e9))
  local res, err = http.get(url)
  if not res then return nil, tostring(err or "no response") end
  local body = res.readAll()
  res.close()
  if not body or #body == 0 then return nil, "empty file" end
  return body
end

local function writeFile(path, body)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end

  -- Write beside the target and move into place, so an interrupted install
  -- leaves the old working copy rather than half a file.
  local tmp = path .. ".part"
  local file = fs.open(tmp, "w")
  if not file then return false, "cannot write " .. tmp end
  file.write(body)
  file.close()

  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp, path)
  return true
end

--------------------------------------------------------------------------------

term.clear()
term.setCursorPos(1, 1)
say("Mining fleet installer", colours.cyan)
say(REPO .. " @ " .. BRANCH, colours.grey)
print()

if not http then
  say("The HTTP API is disabled.", colours.red)
  say("Enable http in the ComputerCraft config and try again.", colours.white)
  return
end

say("Fetching manifest...", colours.lightGrey)
local manifest, why = fetch("manifest.txt")
if not manifest then
  say("Could not fetch the file list: " .. why, colours.red)
  say("Check the branch name and that the repo is public.", colours.white)
  return
end

local files = {}
for line in manifest:gmatch("[^\r\n]+") do
  line = line:match("^%s*(.-)%s*$")
  if line ~= "" and not line:match("^#") then files[#files + 1] = line end
end

if #files == 0 then
  say("The manifest is empty. Nothing to install.", colours.red)
  return
end

-- Download everything before writing anything: a half-installed tree where
-- miner.lua is new and lib/move.lua is old fails in ways that look like bugs.
local bodies, failed = {}, {}
for i, path in ipairs(files) do
  term.write(("[%d/%d] %s"):format(i, #files, path))
  local body, err = fetch(path)
  if body then
    bodies[path] = body
    say("  ok", colours.lime)
  else
    failed[#failed + 1] = path .. " (" .. err .. ")"
    say("  FAILED", colours.red)
  end
end

if #failed > 0 then
  print()
  say("Nothing was installed. These could not be downloaded:", colours.red)
  for _, f in ipairs(failed) do say("  " .. f, colours.white) end
  return
end

print()
for path, body in pairs(bodies) do
  local ok, err = writeFile("/" .. path, body)
  if not ok then
    say("Could not write " .. path .. ": " .. tostring(err), colours.red)
    return
  end
end

say(("Installed %d file(s)."):format(#files), colours.lime)

--------------------------------------------------------------------------------
-- What did we just install onto?
--------------------------------------------------------------------------------

local SCANNERS = { geoScanner = true, geo_scanner = true }

local function hasScanner()
  for _, side in ipairs(peripheral.getNames()) do
    if SCANNERS[peripheral.getType(side)] then return true end
  end
  return false
end

local function hasWirelessModem()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" and peripheral.call(side, "isWireless") then
      return true
    end
  end
  return false
end

local role
if turtle then
  role = hasScanner() and "scout" or "miner"
elseif pocket then
  role = "remote"
else
  role = "server"
end

print()
say("This computer is a " .. role .. ".", colours.cyan)

-- A readable roster beats a column of numbers, and the label is the only thing
-- the fleet table has to show besides the id.
if not os.getComputerLabel() then
  os.setComputerLabel(role .. "-" .. os.getComputerID())
  say("Labelled " .. os.getComputerLabel(), colours.lightGrey)
end

if not hasWirelessModem() then
  say("No wireless modem. This one cannot join the fleet until", colours.orange)
  say("it has one -- an ender modem on the server.", colours.orange)
end

if role == "miner" then
  say("Give it fuel, and a chest at its start position to empty into.",
    colours.white)
elseif role == "scout" then
  say("A scout has no pickaxe and only travels through open air.", colours.white)
  say("Drop it into a quarry the miners have already dug.", colours.white)
elseif role == "server" then
  say("Needs a GPS cluster in range to place jobs by coordinate.", colours.white)
end

print()
say("Reboot to start? (y/N)", colours.yellow)
local event, key = os.pullEvent("char")
if key == "y" or key == "Y" then os.reboot() end
