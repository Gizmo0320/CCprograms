--- A waypoint that stands still.
--
-- Put a computer where you want a waypoint, run this, and it is one. It tells
-- the tower where it is, what it is called, whether it is a pad, and -- the part
-- that matters -- **how high the ground and whatever is standing on it reach
-- here**, so a route planned through it can be planned to clear them.
--
-- The alternative was walking to the spot with a pocket computer and tapping
-- "+ pad here", which puts a name on a coordinate and nothing else. That still
-- works and is still the quick way. A beacon is for the places you care about:
-- it does not forget, it does not need anyone standing there, it corrects itself
-- if the world changes around it, and it contributes real measurements to the
-- height map instead of a single point.
--
-- ## What it needs
--
--   * a **wireless modem**, to be heard
--   * **GPS**, or a position written into /beacon.cfg. A beacon that guessed
--     its own position would be worse than no beacon: every route through it
--     would be planned against the wrong place.
--   * optionally an **optical sensor pointing up**, which is what turns it from
--     a named coordinate into a measurement. Without one it still registers, and
--     says it has nothing to say about height.
--   * optionally a **docking connector**, and then it reports whether the pad is
--     occupied.
--
-- ## What it is not
--
-- Not a controller. It commands nothing and holds no conn. If every beacon in
-- the world is broken the fleet still flies; it just plans against less.

local config = require("lib.config")
local net    = require("lib.net")
local state  = require("lib.state")
local ui     = require("lib.ui")

local beacon = {
  pos      = nil,
  ground   = nil,       -- the height of the ground under us
  ceiling  = nil,       -- how high whatever is above us reaches, if we can see
  occupied = nil,       -- for a pad with a docking connector
  kind     = "point",
  note     = nil,
  seen     = 0,         -- ships that have said hello
  towerAt  = -math.huge,
}

local function now() return os.clock() end

local function label()
  return os.getComputerLabel() or ("beacon-" .. os.getComputerID())
end

--------------------------------------------------------------------------------
-- Where am I
--------------------------------------------------------------------------------

--- Ask GPS, or take what the config file says.
--
-- Tried repeatedly rather than once: a beacon placed in a chunk whose GPS
-- satellites have not loaded yet would otherwise sit there forever knowing
-- nothing, and the fix for that should not be "turn it off and on again".
local function locate()
  local override = state.data.pos
  if type(override) == "table" and tonumber(override.x) then
    return { x = override.x, y = override.y, z = override.z }, "config"
  end

  if not gps then return nil end
  local ok, x, y, z = pcall(gps.locate, 2)
  if not ok or not x then return nil end
  return { x = math.floor(x), y = math.floor(y), z = math.floor(z) }, "gps"
end

--------------------------------------------------------------------------------
-- What is around me
--------------------------------------------------------------------------------

local function sensor(kind)
  local ok, names = pcall(peripheral.getNames)
  if not ok then return nil end
  for _, side in ipairs(names) do
    local okType, found = pcall(peripheral.getType, side)
    if okType and found == kind then return side end
  end
  return nil
end

local function read(side, method, ...)
  if not side then return nil end
  local ok, result = pcall(peripheral.call, side, method, ...)
  if not ok then return nil end
  return result
end

--- Measure upwards.
--
-- The beacon sits on the ground, so its own y **is** the ground height here --
-- that is the one measurement it never has to take. What it cannot know without
-- help is what is standing above it: a tree, a roof, the underside of the
-- platform it is bolted to. An optical sensor pointing up answers that, and the
-- answer is what stops a route being planned through a canopy.
local function survey()
  if not beacon.pos then return end

  beacon.ground = beacon.pos.y

  local eye = sensor("optical_sensor")
  if eye then
    read(eye, "setRange", 64)
    if read(eye, "hasHit") == true then
      local distance = tonumber(read(eye, "getDistance"))
      if distance then beacon.ceiling = beacon.pos.y + distance end
    else
      -- Nothing within range is a real answer and a useful one: open sky.
      beacon.ceiling = nil
    end
  end

  local dock = sensor("docking_connector")
  if dock then
    local docked = read(dock, "getConnectedName")
    beacon.occupied = (type(docked) == "string" and docked ~= "") and docked or false
  end
end

--------------------------------------------------------------------------------
-- Saying so
--------------------------------------------------------------------------------

--- The height a route through here has to clear.
--
-- The ground, or whatever is standing on it, whichever is higher. nil when we
-- have no sensor and therefore nothing to say -- and nil has to stay nil, or a
-- beacon under a canopy would report open sky.
local function obstruction()
  if beacon.ceiling and beacon.ground then
    return math.max(beacon.ground, beacon.ceiling)
  end
  return beacon.ground
end

local function announce()
  if not beacon.pos then return end

  net.broadcast({
    type = "beacon",
    name = label(),
    x = beacon.pos.x, y = beacon.pos.y, z = beacon.pos.z,
    kind = beacon.kind,
    -- The measurement, kept separate from the position. A tower that only
    -- wanted a waypoint can ignore it; one that is building a height map wants
    -- exactly this.
    ground = beacon.ground,
    obstruction = obstruction(),
    occupied = beacon.occupied,
    note = state.data.note,
  })
end

--------------------------------------------------------------------------------
-- Screen
--------------------------------------------------------------------------------

local function redraw()
  local w, h = term.getSize()
  ui.paint(ui.theme.text, ui.theme.bg)
  term.clear()

  local live = beacon.pos ~= nil
  local banner = live and ui.theme.accent or ui.theme.bad
  ui.fill(1, 1, w, 1, banner)
  ui.at(1, 1, ui.fit((" %s  %s"):format(label(), beacon.kind), w, true),
        ui.theme.bg, banner)

  local lines = {}

  if not beacon.pos then
    lines[#lines + 1] = "No position."
    lines[#lines + 1] = ""
    lines[#lines + 1] = "This needs GPS, or a position"
    lines[#lines + 1] = "in /beacon.cfg. A beacon that"
    lines[#lines + 1] = "guessed would send every route"
    lines[#lines + 1] = "through the wrong place."
  else
    lines[#lines + 1] = ("at   %d %d %d")
      :format(beacon.pos.x, beacon.pos.y, beacon.pos.z)
    lines[#lines + 1] = ("kind %s"):format(beacon.kind)
    lines[#lines + 1] = ("ground  %s"):format(ui.num(beacon.ground))
    lines[#lines + 1] = ("clear above %s"):format(
      beacon.ceiling and ui.num(beacon.ceiling) or "open sky")

    if beacon.occupied ~= nil then
      lines[#lines + 1] = ("pad  %s"):format(
        beacon.occupied and ("occupied: " .. tostring(beacon.occupied)) or "free")
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = ("tower %s"):format(
      (now() - beacon.towerAt) < config.staleAfter and "listening" or "not heard")
    lines[#lines + 1] = ("ships seen %d"):format(beacon.seen)
  end

  if not sensor("optical_sensor") then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "No optical sensor pointing up."
    lines[#lines + 1] = "This is a named place, not a"
    lines[#lines + 1] = "measured one."
  end

  for i, line in ipairs(lines) do
    if i + 1 >= h then break end
    ui.at(1, i + 1, ui.fit(line, w, true),
          line:find("No ") == 1 and ui.theme.warn or ui.theme.text)
  end

  ui.at(1, h, ui.fit(" Q quit   " .. (beacon.note or "beacon"), w, true),
        ui.theme.dim, ui.theme.bg)
  ui.paint(ui.theme.text, ui.theme.bg)
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

state.open("/beacon.state", { kind = "point" })
beacon.kind = state.data.kind or "point"

term.clear()
term.setCursorPos(1, 1)

if not net.open() then
  ui.paint(ui.theme.bad, ui.theme.bg)
  print("No wireless modem. A beacon nobody can hear")
  print("is a computer standing in a field.")
  ui.paint(ui.theme.text, ui.theme.bg)
  return
end

beacon.pos = locate()
survey()
announce()
redraw()

local beat = os.startTimer(config.beaconEvery)
local look = os.startTimer(5)

while true do
  local event, a, b, c, d = os.pullEvent()

  local from, msg = net.decode(event, a, b, c, d)
  if from and type(msg) == "table" then
    if msg.type == "net" then
      -- The tower is up. Announce straight away rather than waiting for the next
      -- beat, so a tower that has just booted learns about every beacon in
      -- earshot within a second instead of within ten.
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

    -- Keep trying for a position, and keep measuring. The world changes: a tree
    -- grows, somebody builds a roof over the pad, the platform is rebuilt one
    -- block higher. A beacon that measured once at boot would go on insisting on
    -- what used to be true.
    if not beacon.pos then beacon.pos = locate() end
    survey()
    redraw()

  elseif event == "key" then
    if a == keys.q then break end

  elseif event == "terminate" then
    break
  end
end

state.data.kind = beacon.kind
state.flush(now())

term.clear()
term.setCursorPos(1, 1)
ui.paint(ui.theme.text, ui.theme.bg)
print("Beacon off. The tower keeps the waypoint until")
print("something replaces it.")
