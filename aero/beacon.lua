--- A waypoint that stands still.
--
-- Put a computer where you want a waypoint, tell it where that is, and it is
-- one. It announces itself to the tower for as long as it is running, so nobody
-- has to walk there with a pocket computer and nobody has to remember to add it
-- again after the world restarts.
--
-- That is the whole job. It is a marker, not an instrument: no sensors, no
-- measurements, nothing to wire up. A wireless modem so it can be heard, and a
-- position so it knows what to say.
--
--   beacon               run it, asking on the first time
--   beacon set           ask again -- move it, rename it, change its kind
--   beacon --at=40,70,300 --name=quarry-pad --kind=pad
--
-- ## Where it is
--
-- Typed in, and kept in /beacon.cfg. **GPS is only ever a suggestion**: if a
-- constellation answers, setup offers what it found as the default so the common
-- case is one keypress, and if it does not you type three numbers. A beacon that
-- depended on GPS would be a waypoint that stopped existing whenever the
-- satellites unloaded, which is the opposite of the point.
--
-- Nothing is guessed. A beacon with no position refuses to announce itself at
-- all, because a marker in the wrong place is worse than no marker: every route
-- through it would go somewhere nobody chose.
--
-- ## Optional
--
-- A **docking connector** attached to the same computer makes it report whether
-- the pad is occupied. That is the only peripheral it will ever look for, it is
-- entirely optional, and a beacon without one simply never mentions it.

local config = require("lib.config")
local net    = require("lib.net")
local ui     = require("lib.ui")

local args = { ... }

local beacon = {
  name    = nil,
  kind    = "point",
  pos     = nil,
  occupied = nil,
  seen    = 0,
  towerAt = -math.huge,
  said    = 0,
}

local function now() return os.clock() end

--------------------------------------------------------------------------------
-- The config file
--------------------------------------------------------------------------------

--- A waypoint name has to survive nav.check and a narrow column on a pocket
--- computer, so it is cut to the same shape here rather than being refused by
--- the tower after the fact.
local function sanitise(name)
  name = tostring(name or ""):match("^%s*(.-)%s*$")
  name = name:gsub("[^%w%-_]", "")
  return name:sub(1, 16)
end

local function load()
  if not fs.exists(config.beaconFile) then return nil end

  local fn = loadfile(config.beaconFile)
  if not fn then return nil end

  local ok, cfg = pcall(fn)
  if not ok or type(cfg) ~= "table" then return nil end
  return cfg
end

local function save()
  local f = fs.open(config.beaconFile, "w")
  if not f then return false end

  f.write(([[
-- What this beacon is and where it stands.
--
-- Written by `beacon set`, and not in manifest.txt, so `update` never replaces
-- it. Edit it by hand if you would rather; the beacon reads it at boot.

return {
  name = %q,
  kind = %q,
  x = %d,
  y = %d,
  z = %d,
}
]]):format(beacon.name, beacon.kind,
           beacon.pos.x, beacon.pos.y, beacon.pos.z))
  f.close()
  return true
end

--------------------------------------------------------------------------------
-- Setting it up
--------------------------------------------------------------------------------

local function say(text, colour)
  ui.paint(colour or ui.theme.text, ui.theme.bg)
  print(text)
  ui.paint(ui.theme.text, ui.theme.bg)
end

--- What GPS thinks, or nil. Only ever used as a default to offer.
local function fromGps()
  if not gps then return nil end
  local ok, x, y, z = pcall(gps.locate, 2)
  if not ok or not x then return nil end
  return { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
end

--- Three numbers out of one line, in any of the shapes somebody might type.
--
-- "10 70 300", "10,70,300" and "10, 70, 300" all mean the same thing and it
-- would be rude to insist on one of them.
local function coordinates(text)
  local x, y, z = tostring(text or ""):match(
    "^%s*(-?%d+)%s*[, ]%s*(-?%d+)%s*[, ]%s*(-?%d+)%s*$")
  if not x then return nil end
  return { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
end

local function setup(existing)
  term.clear()
  term.setCursorPos(1, 1)
  say("Beacon setup", ui.theme.accent)
  say("A waypoint that stands here and says so.", ui.theme.dim)
  print()

  -- Name ----------------------------------------------------------------------

  local suggested = (existing and existing.name)
    or sanitise(os.getComputerLabel() or "")
  if suggested == "" then suggested = "beacon" .. os.getComputerID() end

  say("Name for this waypoint?", ui.theme.select)
  say("Enter for '" .. suggested .. "':", ui.theme.dim)
  local name = sanitise(read())
  if name == "" then name = suggested end
  beacon.name = name

  -- Kind ----------------------------------------------------------------------

  print()
  local wasPad = (existing and existing.kind) == "pad"
  say("Is this a pad ships can land on?", ui.theme.select)
  say("A point is somewhere to fly over; a pad is", ui.theme.dim)
  say("somewhere to come down. y/N"
      .. (wasPad and "  (currently a pad)" or ""), ui.theme.dim)
  local answer = read():lower()
  if answer == "" then
    beacon.kind = wasPad and "pad" or "point"
  else
    beacon.kind = (answer:sub(1, 1) == "y") and "pad" or "point"
  end

  -- Where ---------------------------------------------------------------------

  print()
  local suggestion = (existing and tonumber(existing.x))
    and { x = existing.x, y = existing.y, z = existing.z }
    or fromGps()

  say("Where is it?", ui.theme.select)
  if suggestion then
    say(("Enter for %d %d %d, or type x y z:")
      :format(suggestion.x, suggestion.y, suggestion.z), ui.theme.dim)
  else
    -- No GPS and nothing saved. Typing it is the normal way, not the fallback:
    -- a marker is placed deliberately and you know where you put it.
    say("Type x y z, for example  40 70 300", ui.theme.dim)
    say("(No GPS here, so there is nothing to offer.)", ui.theme.dim)
  end

  say("Q to leave it unset.", ui.theme.dim)

  while true do
    local typed = read()

    if typed == "" and suggestion then
      beacon.pos = suggestion
      break
    end

    -- A way out. Keeping a beacon in the dark is a perfectly reasonable thing
    -- to want -- you have placed the computer and not decided where it is yet --
    -- and a prompt with no escape is a program you have to break the computer to
    -- get out of.
    if typed:lower() == "q" then
      beacon.pos = beacon.pos or nil
      say("Left unset. Press S on the beacon to set it.", ui.theme.warn)
      os.sleep(1)
      return
    end

    local at = coordinates(typed)
    if at then
      beacon.pos = at
      break
    end

    say("Three whole numbers, please: x y z", ui.theme.warn)
  end

  os.setComputerLabel(beacon.name)
  save()

  print()
  say(("%s: a %s at %d %d %d"):format(beacon.name, beacon.kind,
      beacon.pos.x, beacon.pos.y, beacon.pos.z), ui.theme.ok)
  say("Run `beacon set` to change any of it.", ui.theme.dim)
  os.sleep(1.5)
end

--------------------------------------------------------------------------------
-- Being a waypoint
--------------------------------------------------------------------------------

--- The only peripheral this program ever looks for, and it is optional.
local function dockPort()
  local ok, names = pcall(peripheral.getNames)
  if not ok then return nil end
  for _, side in ipairs(names) do
    local okType, kind = pcall(peripheral.getType, side)
    if okType and kind == "docking_connector" then return side end
  end
  return nil
end

local function checkPad()
  local side = dockPort()
  if not side then
    beacon.occupied = nil
    return
  end

  local ok, docked = pcall(peripheral.call, side, "getConnectedName")
  if not ok then return end
  beacon.occupied = (type(docked) == "string" and docked ~= "") and docked or false
end

local function announce()
  if not beacon.pos then return end

  net.broadcast({
    type = "beacon",
    name = beacon.name,
    x = beacon.pos.x, y = beacon.pos.y, z = beacon.pos.z,
    kind = beacon.kind,
    -- The beacon stands on the ground, so its own height *is* the ground here.
    -- One free known point for the height map, and the only measurement this
    -- program will ever make -- it needs no sensor to know how tall it is not.
    ground = beacon.pos.y,
    occupied = beacon.occupied,
  })
  beacon.said = beacon.said + 1
end

--------------------------------------------------------------------------------
-- Screen
--------------------------------------------------------------------------------

local function redraw()
  local w, h = term.getSize()
  ui.paint(ui.theme.text, ui.theme.bg)
  term.clear()

  local ready = beacon.pos ~= nil
  local banner = ready and ui.theme.accent or ui.theme.bad
  ui.fill(1, 1, w, 1, banner)
  ui.at(1, 1, ui.fit((" %s  %s"):format(beacon.name or "beacon",
        beacon.kind), w, true), ui.theme.bg, banner)

  local lines = {}

  if not ready then
    lines[#lines + 1] = "No position set."
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Press S to set one."
  else
    lines[#lines + 1] = ("at    %d %d %d")
      :format(beacon.pos.x, beacon.pos.y, beacon.pos.z)
    lines[#lines + 1] = ("kind  %s"):format(beacon.kind)

    if beacon.occupied ~= nil then
      lines[#lines + 1] = ("pad   %s"):format(
        beacon.occupied and ("occupied by " .. tostring(beacon.occupied))
        or "free")
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = ("tower %s"):format(
      (now() - beacon.towerAt) < config.staleAfter and "listening" or "not heard")
    lines[#lines + 1] = ("said  %d times"):format(beacon.said)
    lines[#lines + 1] = ("ships %d seen"):format(beacon.seen)
  end

  for i, line in ipairs(lines) do
    if i + 1 >= h then break end
    ui.at(1, i + 1, ui.fit(line, w, true),
          line:find("No ") == 1 and ui.theme.warn or ui.theme.text)
  end

  ui.at(1, h, ui.fit(" S set   Q quit", w, true), ui.theme.dim, ui.theme.bg)
  ui.paint(ui.theme.text, ui.theme.bg)
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

local cfg = load()

-- Flags, for setting a row of beacons up without sitting at each one.
local flagged = {}
local asked = false
for _, a in ipairs(args) do
  if a == "set" then asked = true end
  local at   = a:match("^%-%-at=(.+)$")
  local name = a:match("^%-%-name=(.+)$")
  local kind = a:match("^%-%-kind=(%a+)$")
  if at then flagged.pos = coordinates(at:gsub(",", " ")) end
  if name then flagged.name = sanitise(name) end
  if kind then flagged.kind = (kind:lower() == "pad") and "pad" or "point" end
end

beacon.name = flagged.name or (cfg and cfg.name) or sanitise(os.getComputerLabel() or "")
beacon.kind = flagged.kind or (cfg and cfg.kind) or "point"

if flagged.pos then
  beacon.pos = flagged.pos
elseif cfg and tonumber(cfg.x) then
  beacon.pos = { x = cfg.x, y = cfg.y, z = cfg.z }
end

if beacon.name == "" then beacon.name = nil end

if flagged.pos or flagged.name or flagged.kind then
  -- Given on the command line, so there is nothing to ask about. Written down
  -- so the next boot needs no flags either.
  if beacon.pos and beacon.name then
    os.setComputerLabel(beacon.name)
    save()
  end
elseif asked or not beacon.pos or not beacon.name then
  -- Nothing saved, or explicitly asked to change it. `read` blocks, which is
  -- exactly right here and exactly wrong in the loop below -- so it all happens
  -- before the loop starts and never again.
  setup(cfg)
end

term.clear()
term.setCursorPos(1, 1)

if not net.open() then
  ui.paint(ui.theme.bad, ui.theme.bg)
  print("No wireless modem. A beacon nobody can hear is")
  print("a computer standing in a field.")
  ui.paint(ui.theme.text, ui.theme.bg)
  return
end

checkPad()
announce()
redraw()

local beat = os.startTimer(config.beaconEvery)
local look = os.startTimer(5)

while true do
  local event, a, b, c, d = os.pullEvent()

  local from, msg = net.decode(event, a, b, c, d)
  if from and type(msg) == "table" then
    if msg.type == "net" then
      -- The tower is up. Announce at once rather than waiting for the next
      -- beat, so a tower that has just booted learns about every beacon in
      -- earshot in a second instead of ten.
      beacon.towerAt = now()
      announce()
    elseif msg.type == "beacon?" then
      announce()
    elseif msg.type == "tlm" and not msg.gone then
      beacon.seen = beacon.seen + 1
    end
    redraw()

  elseif event == "timer" and a == beat then
    beat = os.startTimer(config.beaconEvery)
    announce()
    redraw()

  elseif event == "timer" and a == look then
    look = os.startTimer(5)
    checkPad()
    redraw()

  elseif event == "key" then
    if a == keys.q then
      break
    elseif a == keys.s then
      setup(load())
      term.clear()
      announce()
      redraw()
      beat = os.startTimer(config.beaconEvery)
      look = os.startTimer(5)
    end

  elseif event == "terminate" then
    break
  end
end

term.clear()
term.setCursorPos(1, 1)
ui.paint(ui.theme.text, ui.theme.bg)
print("Beacon off. The tower keeps the waypoint until")
print("something replaces it.")
