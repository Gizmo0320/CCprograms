--- Installer. Run this on a fresh computer or pocket computer:
--
--   wget run https://raw.githubusercontent.com/Gizmo0320/CCprograms/main/redstone/install.lua
--
-- It fetches the file list from manifest.txt and downloads everything to the
-- computer root. The same tree goes on every machine -- startup.lua works out
-- what it is running on -- so there is one thing to install and no way to put
-- the wrong half on the wrong computer.
--
-- Optional arguments:
--   install <branch> <owner/repo>
--   install --net=base           name the network without being asked
--   install --channel=4200       set the modem channel without being asked
--   install --role=server        node | server
--   install --name=Kitchen       name this computer without being asked
--
-- Pass the flags for an unattended install: without them the prompts wait for a
-- line of input, and read() cannot be given a timeout the way the reboot prompt
-- at the end can.
--
-- Unlike the mining fleet, the role has to be asked. A turtle is obviously a
-- turtle and a pocket computer is obviously a pocket computer, but a node and a
-- server are both plain computers and no amount of peripheral sniffing tells
-- them apart.

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
local BASE   = ("https://raw.githubusercontent.com/%s/%s/redstone/"):format(REPO, BRANCH)

local OVERRIDES = "/redstone.cfg"
local PORTS     = "/ports.cfg"

-- Mirrors the defaults in lib/config.lua. Naming them here is what lets this
-- skip writing an overrides file at all for a plain single-network setup, so
-- there is nothing extra to explain to anyone reading the tree later.
local DEFAULT_NET     = "redstone"
local DEFAULT_CHANNEL = 2718
local DEFAULT_ROLE    = "node"

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
say("Redstone network installer", colours.cyan)
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
-- node.lua is new and lib/ports.lua is old fails in ways that look like bugs.
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
-- not the mining fleet's, so a world can run both without either being told
-- about the other.
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
  say("Is this a node or the server?", colours.yellow)
  say("A node drives redstone. The server holds the", colours.white)
  say("scenes and the log, and there is one of it.", colours.white)
  say("Enter for '" .. current .. "':", colours.yellow)
  term.setTextColour(colours.white)
  ROLE = read()
end

ROLE = tostring(ROLE or ""):lower():gsub("%s", "")
if ROLE ~= "node" and ROLE ~= "server" and ROLE ~= "remote" then
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
-- Wiring
--------------------------------------------------------------------------------

-- An example rather than an empty file. A node with no ports has nothing to do
-- and no obvious way to be told about any, and the shape of a port definition
-- is the one thing here that cannot be guessed from the program's own screens.
local EXAMPLE = [[
-- What this computer is wired to. Not in manifest.txt, so `update` never
-- replaces it -- wiring is per-computer and would otherwise survive exactly
-- until the first update.
--
-- Each port is:
--   name    what everything else calls it: rules, scenes, the log, the pocket
--   side    top bottom left right front back
--   dir     "in" or "out". Never both: CC hands our own output straight back
--           from getInput, so a port that tried to be both would latch itself on
--   kind    "digital"  on/off        setOutput / getInput
--           "analog"   0-15          what a comparator reads out of a chest
--           "bundled"  one colour of a bundled cable (needs a mod for cable)
--   colour  required for bundled, meaningless otherwise
--   invert  optional. Fix a backwards daylight sensor once, here, rather than
--           in every rule that reads it
--
-- One side carries one signal, so everything on a side must agree: all "in" or
-- all "out", and all the same kind. Only bundled may have more than one port.

return {
  { name = "lamp",     side = "top",   dir = "out", kind = "digital",
    label = "Ceiling lamp" },

  { name = "button",   side = "front", dir = "in",  kind = "digital" },

  -- A comparator on a chest or a furnace. 0-15, so rules can ask "< 4".
  { name = "level",    side = "left",  dir = "in",  kind = "analog",
    label = "Silo level" },

  -- Bundled cable on one side, up to sixteen ports sharing it.
  -- { name = "porch",  side = "back", dir = "out", kind = "bundled",
  --   colour = colours.lime },
  -- { name = "garage", side = "back", dir = "out", kind = "bundled",
  --   colour = colours.red },
}
]]

local EXAMPLE_RULES = [[
-- Rules this computer applies for itself, and logic blocks it runs.
--
-- It keeps applying them with the server down, which is the point: a door that
-- only works when a computer three hundred blocks away is loaded is worse than
-- no door.
--
-- The pocket computer edits this file over the wire, so it is rewritten from
-- time to time -- comments in it will not survive that. Keep notes elsewhere.

return {
  rules = {
    -- { id = "night-lights", enabled = true,
    --   when = { port = "level", op = "<", value = 4 },
    --   act  = { port = "lamp", set = true },
    --   hold = 2 },     -- seconds the condition must hold first
  },

  blocks = {
    -- { id = "porch", kind = "toggle", out = "lamp",
    --   wire = { input = "button" } },
  },
}
]]

if ROLE == "node" then
  if not fs.exists(PORTS) then
    writeFile(PORTS, EXAMPLE)
    say("Wrote an example " .. PORTS .. " -- edit it to match your wiring.",
      colours.yellow)
  else
    say("Kept your existing " .. PORTS .. ".", colours.lightGrey)
  end

  if not fs.exists("/rules.cfg") then
    writeFile("/rules.cfg", EXAMPLE_RULES)
  end
end

--------------------------------------------------------------------------------
-- Name
--------------------------------------------------------------------------------

-- The name is the only thing distinguishing one row of the node table from
-- another besides a number, and "Kitchen" tells you what you are about to
-- switch off in a way that "computer 7" does not.
--
-- It lives in the computer's own label rather than /redstone.cfg: a label
-- already survives updates, reboots, and being broken and replaced, and CC's
-- own `label` program can read and set it without this program involved.
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

local function hasWirelessModem()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" and peripheral.call(side, "isWireless") then
      return true
    end
  end
  return false
end

print()
if not hasWirelessModem() then
  if ROLE == "node" then
    say("No wireless modem. Local rules will still run, but", colours.orange)
    say("nothing can see or command this node.", colours.orange)
  else
    say("No wireless modem. This one cannot do anything", colours.orange)
    say("without one.", colours.orange)
  end
elseif ROLE == "server" then
  say("An ender modem here is worth it -- range is what", colours.white)
  say("decides whether a scene reaches the far shed.", colours.white)
end

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
