--- Installer. Run this on a fresh computer or pocket computer:
--
--   wget run https://raw.githubusercontent.com/Gizmo0320/CCprograms/main/aero/install.lua
--
-- It fetches the file list from manifest.txt and downloads everything to the
-- computer root. The same tree goes on every machine -- startup.lua works out
-- what it is running on -- so there is one thing to install and no way to put
-- the wrong half on the wrong computer.
--
-- Optional arguments:
--   install <branch> <owner/repo>
--   install --net=north          name the network without being asked
--   install --channel=4300       set the modem channel without being asked
--   install --role=server        pilot | server | beacon
--   install --name=Kestrel       name this computer without being asked
--
-- Pass the flags for an unattended install: without them the prompts wait for a
-- line of input, and read() cannot be given a timeout the way the reboot prompt
-- at the end can.
--
-- Like the redstone network and unlike the mining fleet, the role has to be
-- asked. A turtle is obviously a turtle, but a pilot and a tower are both plain
-- computers, and the peripherals that would give it away are on the contraption
-- rather than on the computer.
--
-- On a pilot this does **not** write a /craft.cfg. That file describes one
-- particular hull and cannot be guessed from here; probe.lua writes it from what
-- is actually attached, and it has to be run on the assembled ship.

local args = { ... }

local NETWORK, CHANNEL, NAME, ROLE
local positional = {}
for _, a in ipairs(args) do
  local netArg  = a:match("^%-%-net=(.+)$")
  local chanArg = a:match("^%-%-channel=(%d+)$")
  local nameArg = a:match("^%-%-name=(.+)$")
  local roleArg = a:match("^%-%-role=(%a+)$")
  if netArg then NETWORK = netArg
  elseif chanArg then CHANNEL = tonumber(chanArg)
  elseif nameArg then NAME = nameArg
  elseif roleArg then ROLE = roleArg:lower()
  elseif a ~= "" then positional[#positional + 1] = a end
end

local BRANCH = positional[1] or "main"
local REPO   = positional[2] or "Gizmo0320/CCprograms"
local BASE   = ("https://raw.githubusercontent.com/%s/%s/aero/"):format(REPO, BRANCH)

local OVERRIDES = "/aero.cfg"

-- Mirrors the defaults in lib/config.lua. Naming them here is what lets this
-- skip writing an overrides file at all for a plain single-network setup, so
-- there is nothing extra to explain to anyone reading the tree later.
local DEFAULT_NET     = "aero"
local DEFAULT_CHANNEL = 1618
local DEFAULT_ROLE    = "pilot"

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
say("Aeronautics flight network installer", colours.cyan)
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
-- pilot.lua is new and lib/hull.lua is old fails in ways that look like bugs in
-- neither, and on this program it fails in the air.
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
-- Which network is this?
--------------------------------------------------------------------------------

local function currentConfig()
  if not fs.exists(OVERRIDES) then return {} end
  local fn = loadfile(OVERRIDES)
  if not fn then return {} end
  local ok, cfg = pcall(fn)
  if ok and type(cfg) == "table" then return cfg end
  return {}
end

--- A network name rides in every frame and shows up in narrow columns on
--- screen. Anything outside this is more likely a typo than an intention.
local function sanitise(name)
  name = tostring(name):match("^%s*(.-)%s*$")
  name = name:gsub("[^%w%-_]", "")
  return name:sub(1, 24)
end

local existing = currentConfig()

if not NETWORK then
  print()
  if existing.protocol then
    say("This computer is on network '" .. existing.protocol .. "'.", colours.lightGrey)
    say("Enter to keep it, or type a new name:", colours.yellow)
  else
    say("Network name? Computers only talk to others on", colours.yellow)
    say("the same one. Enter for '" .. DEFAULT_NET .. "':", colours.yellow)
  end
  term.setTextColour(colours.white)
  NETWORK = read()
end

NETWORK = sanitise(NETWORK or "")
if NETWORK == "" then NETWORK = existing.protocol or DEFAULT_NET end

-- The channel is the port, and the thing that actually separates two networks:
-- a modem never raises an event for a channel it has not opened. The default is
-- neither the mining fleet's nor the redstone network's, so one world can run
-- all three without any of them being told about the others.
if not CHANNEL then
  print()
  local current = existing.channel or DEFAULT_CHANNEL
  say("Modem channel (1-65535)? This is the port, and", colours.yellow)
  say("what really keeps two networks apart.", colours.yellow)
  say("Enter for " .. current .. ":", colours.yellow)
  term.setTextColour(colours.white)
  CHANNEL = tonumber(read())
end

CHANNEL = math.floor(tonumber(CHANNEL) or 0)
if CHANNEL < 1 or CHANNEL > 65535 then
  CHANNEL = existing.channel or DEFAULT_CHANNEL
end

--------------------------------------------------------------------------------
-- What is this computer for?
--------------------------------------------------------------------------------

local isPocket = pocket ~= nil

if isPocket then
  ROLE = "remote"
elseif not ROLE then
  print()
  local current = existing.role or DEFAULT_ROLE
  say("Is this a pilot, the tower, or a beacon?", colours.yellow)
  say("A pilot rides the contraption and flies it. The", colours.white)
  say("tower holds the waypoints and the log, and there", colours.white)
  say("is one of it. A beacon stands still and is a", colours.white)
  say("waypoint: put one where you want ships to go.", colours.white)
  say("Enter for '" .. current .. "':", colours.yellow)
  term.setTextColour(colours.white)
  ROLE = read()
end

ROLE = tostring(ROLE or ""):lower():gsub("%s", "")
if ROLE == "tower" then ROLE = "server" end
if ROLE == "ship" then ROLE = "pilot" end
if ROLE == "waypoint" then ROLE = "beacon" end
if ROLE ~= "pilot" and ROLE ~= "server" and ROLE ~= "remote"
   and ROLE ~= "beacon" then
  ROLE = existing.role or DEFAULT_ROLE
end

-- Only write the file when something differs from the defaults, so a plain
-- single-network setup has nothing extra to explain.
if NETWORK ~= DEFAULT_NET or CHANNEL ~= DEFAULT_CHANNEL or ROLE ~= DEFAULT_ROLE then
  local f = fs.open(OVERRIDES, "w")
  if f then
    f.write(("-- Written by install.lua. Not in manifest.txt, so `update`\n"
      .. "-- will not replace it. Edit freely; anything here overrides\n"
      .. "-- the defaults in lib/config.lua.\n"
      .. "return {\n  protocol = %q,\n  channel  = %d,\n  role     = %q,\n}\n")
      :format(NETWORK, CHANNEL, ROLE))
    f.close()
  end
elseif fs.exists(OVERRIDES) then
  -- Explicitly back to the defaults: drop the override rather than leave a file
  -- saying one thing while the computer is doing another.
  fs.delete(OVERRIDES)
end

print()
say(("Network '%s' on channel %d, as %s"):format(NETWORK, CHANNEL, ROLE), colours.cyan)

--------------------------------------------------------------------------------
-- Name
--------------------------------------------------------------------------------

-- The name is the only thing distinguishing one row of the fleet table from
-- another besides a number, and "Kestrel" tells you which thing is about to come
-- down in a field in a way that "computer 7" does not.
--
-- It lives in the computer's own label rather than /aero.cfg: a label already
-- survives updates, reboots, and being broken and replaced, and CC's own `label`
-- program can read and set it without this program involved.
local suggested = os.getComputerLabel() or (ROLE .. "-" .. os.getComputerID())

if not NAME then
  print()
  say("Name for this " .. ROLE .. "? Enter for '" .. suggested .. "':", colours.yellow)
  term.setTextColour(colours.white)
  NAME = read()
end

NAME = sanitise(NAME or "")
if NAME == "" then NAME = suggested end
os.setComputerLabel(NAME)
say("Named " .. NAME, colours.cyan)

--------------------------------------------------------------------------------

-- The hardware, checked here rather than described. The installer is the first
-- and often only time anybody reads what a role needs, and a list of what is
-- actually missing on this computer beats a paragraph about what one might.
local needs = nil
do
  local ok, module = pcall(dofile, "/lib/needs.lua")
  if ok then needs = module end
end

print()
if needs then
  local found = {}
  for _, side in ipairs(peripheral.getNames()) do
    local entry = { type = peripheral.getType(side) }
    if entry.type == "modem" then
      entry.wireless = peripheral.call(side, "isWireless")
    end
    found[#found + 1] = entry
  end

  local rows, summary = needs.check(ROLE, found)
  local verdict, mood = needs.verdict(summary, ROLE)

  say("Hardware on this computer:", colours.cyan)
  for _, row in ipairs(rows) do
    if row.ok then
      say(("  yes  %s"):format(row.item.what), colours.lime)
    elseif row.item.tier == "required" then
      say(("  NO   %s"):format(row.item.what), colours.red)
      say(("       %s"):format(row.item.why), colours.white)
    else
      say(("  --   %s"):format(row.item.what), colours.lightGrey)
    end
  end

  say(verdict, mood == "ok" and colours.lime
      or (mood == "warn" and colours.orange or colours.red))
  say("Run `setup` any time to see this again -- it", colours.white)
  say("re-checks while you watch, so you can go and", colours.white)
  say("place the missing block.", colours.white)

  if ROLE == "server" then
    print()
    say("An ender modem here is worth it: range decides", colours.white)
    say("whether you hear about a diversion now or when", colours.white)
    say("the ship lands.", colours.white)
  end
end

if ROLE == "beacon" then
  print()
  say("Next: run `beacon` on this computer. It asks for", colours.yellow)
  say("a name, whether it is a pad, and where it is --", colours.yellow)
  say("and then it is a waypoint. Nothing to wire up.", colours.yellow)
end

if ROLE == "pilot" then
  print()
  if fs.exists("/craft.cfg") then
    say("Kept your /craft.cfg.", colours.lightGrey)
  else
    -- Deliberately not generated here. The hull is the one thing an installer
    -- running before the ship is assembled cannot possibly know, and a wrong
    -- guess is worse than none: a mix that names the lift bearing as the main
    -- one is a ship that accelerates into the ground.
    say("Next: assemble the ship, then run `probe` on this", colours.yellow)
    say("computer. It writes /craft.cfg from what is really", colours.yellow)
    say("attached. Nothing will fly until it has.", colours.yellow)
  end
end

print()
-- Said on every machine, and last, so it is the line still on screen. The whole
-- manual ships with the program precisely so nobody has to go and find it.
say("Type `guide` for the manual: first flight, the", colours.white)
say("hull file, the guards, tuning and what to do when", colours.white)
say("it goes wrong.", colours.white)

print()
say("Reboot to start? (y/N, continues on its own in 15s)", colours.yellow)

-- Timed rather than a bare pullEvent. Installing across a row of computers is a
-- reasonable thing to script, and a prompt that waits forever turns that into a
-- row of computers sitting at a question nobody is there to answer.
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
