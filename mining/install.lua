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
--   install --channel=4200         set the modem channel without being asked
--
-- Pass --fleet= for an unattended install: without it the fleet prompt waits
-- for a line of input, and read() cannot be given a timeout the way the reboot
-- prompt at the end can.
--
-- The fleet name and channel go in /fleet.cfg, which `update` deliberately
-- does not replace. The channel is the port: a modem never raises an event for
-- a channel it has not opened, so two fleets on different channels genuinely do
-- not touch.

local args = { ... }

local FLEET, CHANNEL
local positional = {}
for _, a in ipairs(args) do
  local fleetArg = a:match("^%-%-fleet=(.+)$")
  local chanArg  = a:match("^%-%-channel=(%d+)$")
  if fleetArg then FLEET = fleetArg
  elseif chanArg then CHANNEL = tonumber(chanArg)
  elseif a ~= "" then positional[#positional + 1] = a end
end

local BRANCH = positional[1] or "main"
local REPO   = positional[2] or "Gizmo0320/CCprograms"
local BASE   = ("https://raw.githubusercontent.com/%s/%s/mining/"):format(REPO, BRANCH)

local OVERRIDES = "/fleet.cfg"

-- Mirrors config.protocol's default in lib/config.lua. Naming the default is
-- what lets this skip writing an overrides file at all for a single-fleet
-- setup, so there is nothing extra to explain to anyone reading the tree later.
local DEFAULT_FLEET   = "mining"
local DEFAULT_CHANNEL = 3141

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
local function currentConfig()
  if not fs.exists(OVERRIDES) then return {} end
  local fn = loadfile(OVERRIDES)
  if not fn then return {} end
  local ok, cfg = pcall(fn)
  if ok and type(cfg) == "table" then return cfg end
  return {}
end

--- A fleet name rides in every frame and shows up in narrow columns on screen.
--- Anything outside this is more likely a typo than an intention.
local function sanitise(name)
  name = tostring(name):match("^%s*(.-)%s*$")
  name = name:gsub("[^%w%-_]", "")
  return name:sub(1, 24)
end

local existing = currentConfig()

if not FLEET then
  print()
  if existing.protocol then
    say("This computer is on fleet '" .. existing.protocol .. "'.", colours.lightGrey)
    say("Enter to keep it, or type a new name:", colours.yellow)
  else
    say("Fleet name? Computers only talk to others on the", colours.yellow)
    say("same one. Enter for '" .. DEFAULT_FLEET .. "':", colours.yellow)
  end
  term.setTextColour(colours.white)
  FLEET = read()
end

FLEET = sanitise(FLEET or "")
if FLEET == "" then FLEET = existing.protocol or DEFAULT_FLEET end

-- The channel is the port, and the thing that actually separates two fleets:
-- a modem never raises an event for a channel it has not opened.
if not CHANNEL then
  print()
  local current = existing.channel or DEFAULT_CHANNEL
  say("Modem channel (1-65535)? This is the port, and", colours.yellow)
  say("what really keeps two fleets apart.", colours.yellow)
  say("Enter for " .. current .. ":", colours.yellow)
  term.setTextColour(colours.white)
  CHANNEL = tonumber(read())
end

CHANNEL = math.floor(tonumber(CHANNEL) or 0)
if CHANNEL < 1 or CHANNEL > 65535 then
  CHANNEL = existing.channel or DEFAULT_CHANNEL
end

-- Only write the file when something differs from the defaults, so a plain
-- single-fleet setup has nothing extra to explain.
if FLEET ~= DEFAULT_FLEET or CHANNEL ~= DEFAULT_CHANNEL then
  local f = fs.open(OVERRIDES, "w")
  if f then
    f.write(("-- Written by install.lua. Not in manifest.txt, so `update`\n"
      .. "-- will not replace it. Edit freely; anything here overrides\n"
      .. "-- the defaults in lib/config.lua.\n"
      .. "return {\n  protocol = %q,\n  channel  = %d,\n}\n")
      :format(FLEET, CHANNEL))
    f.close()
  end
elseif fs.exists(OVERRIDES) then
  -- Explicitly back to the defaults: drop the override rather than leave a file
  -- saying one thing while the fleet is on another.
  fs.delete(OVERRIDES)
end

say(("Fleet '%s' on channel %d"):format(FLEET, CHANNEL), colours.cyan)

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
