--- Installer. Run this on a fresh turtle, pocket computer or server:
--
--   wget run https://raw.githubusercontent.com/Gizmo0320/CCprograms/main/mining/install.lua
--
-- It fetches the file list from manifest.txt and downloads everything to the
-- computer root. The same tree goes on every machine -- startup.lua works out
-- what it is running on -- so there is one thing to install and no way to put
-- the wrong half on the wrong computer.
--
-- Optional arguments:
--   install <branch> <owner/repo>
--   install --fleet=north          name the fleet without being asked
--
-- Pass --fleet= for an unattended install: without it the fleet prompt waits
-- for a line of input, and read() cannot be given a timeout the way the reboot
-- prompt at the end can.
--
-- The fleet name is the rednet protocol every program on this computer will
-- speak, and it is what lets two fleets share a world without hearing each
-- other. It goes in /fleet.cfg, which is deliberately not something `update`
-- replaces.

local args = { ... }

local FLEET
local positional = {}
for _, a in ipairs(args) do
  local named = a:match("^%-%-fleet=(.+)$")
  if named then FLEET = named
  elseif a ~= "" then positional[#positional + 1] = a end
end

local BRANCH = positional[1] or "main"
local REPO   = positional[2] or "Gizmo0320/CCprograms"
local BASE   = ("https://raw.githubusercontent.com/%s/%s/mining/"):format(REPO, BRANCH)

local OVERRIDES = "/fleet.cfg"

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
-- Which fleet is this?
--------------------------------------------------------------------------------

--- What /fleet.cfg currently says, if anything.
local function currentFleet()
  if not fs.exists(OVERRIDES) then return nil end
  local fn = loadfile(OVERRIDES)
  if not fn then return nil end
  local ok, cfg = pcall(fn)
  if ok and type(cfg) == "table" then return cfg.protocol end
  return nil
end

--- A protocol string goes in rednet messages and on screen in narrow columns.
--- Anything outside this is more likely a typo than an intention.
local function sanitise(name)
  name = tostring(name):match("^%s*(.-)%s*$")
  name = name:gsub("[^%w%-_]", "")
  return name:sub(1, 24)
end

local existing = currentFleet()

if not FLEET then
  print()
  if existing then
    say("This computer is on fleet '" .. existing .. "'.", colours.lightGrey)
    say("Enter to keep it, or type a new name:", colours.yellow)
  else
    say("Fleet name? Computers only talk to others on the", colours.yellow)
    say("same one. Enter for the default 'mining':", colours.yellow)
  end
  term.setTextColour(colours.white)
  FLEET = read()
end

FLEET = sanitise(FLEET or "")
if FLEET == "" then FLEET = existing or "mining" end

-- Only write the file when it says something other than the default, so a
-- single-fleet setup has nothing extra to explain.
if FLEET ~= "mining" then
  local f = fs.open(OVERRIDES, "w")
  if f then
    f.write(("-- Written by install.lua. Not in manifest.txt, so `update`\n"
      .. "-- will not replace it. Edit freely; anything here overrides\n"
      .. "-- the defaults in lib/config.lua.\nreturn {\n  protocol = %q,\n}\n")
      :format(FLEET))
    f.close()
  end
elseif fs.exists(OVERRIDES) and existing and existing ~= "mining" then
  -- Explicitly moved back to the default: drop the override rather than
  -- leaving a file that says one thing while the fleet is on another.
  fs.delete(OVERRIDES)
end

say("Fleet: " .. FLEET, colours.cyan)

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
say("Reboot to start? (y/N, continues on its own in 15s)", colours.yellow)

-- Timed rather than a bare pullEvent. Installing across a row of turtles is a
-- reasonable thing to script, and a prompt that waits forever turns that into a
-- row of turtles sitting at a question nobody is there to answer.
local deadline = os.startTimer(15)
while true do
  local event, a = os.pullEvent()
  if event == "char" then
    if a == "y" or a == "Y" then os.reboot() end
    break
  elseif event == "timer" and a == deadline then
    say("No answer; leaving it to you.", colours.grey)
    break
  end
end
