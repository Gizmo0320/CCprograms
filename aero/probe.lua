--- What is bolted to this hull, and a /craft.cfg to start from.
--
-- The mod ships an examples/peripheral_probe.lua that prints the attached
-- peripherals and their methods. This does that too -- to a file, because the
-- list is longer than a pocket computer screen and you want to read it while
-- editing something else -- and then does the part that actually saves time: it
-- writes a /craft.cfg with the controls, the instruments and a mix already
-- filled in from what it found.
--
-- Wiring a hull by hand from a documentation page is the step most likely to be
-- got wrong, and every mistake in it shows up as a ship that will not fly with
-- no indication which of thirty lines is the problem. Generating the file means
-- the only thing left to decide is which bearing is which, which is the one
-- thing no program can work out by looking.
--
--   probe            survey, and write /craft.cfg if there is not one
--   probe --force    survey, and write /craft.cfg.new even if there is
--   probe --eyes     watch every optical sensor live, and stop

local hull = require("lib.hull")
local config = require("lib.config")

local args = { ... }
local force, watch = false, false
for _, a in ipairs(args) do
  if a == "--force" or a == "-f" then force = true end
  if a == "--eyes" or a == "-e" then watch = true end
end

--------------------------------------------------------------------------------
-- probe --eyes: what the optical sensors actually say
--------------------------------------------------------------------------------

-- An optical sensor that is not working looks, from every other screen in this
-- program, exactly like one pointed at a long drop: no clearance, no survey, no
-- terrain guard, and nothing anywhere saying why. This shows the raw answers,
-- including which calls failed, so the difference is visible in one glance
-- instead of being deduced from a ship that will not climb.
if watch then
  local sides = {}
  for _, side in ipairs(peripheral.getNames()) do
    local ok, kind = pcall(peripheral.getType, side)
    if ok and kind == "optical_sensor" then sides[#sides + 1] = side end
  end

  -- Which role /craft.cfg gives each one, if it has been configured. Knowing a
  -- sensor works is only half the question; the other half is whether this
  -- program is asking the one it thinks it is.
  local role = {}
  if fs.exists(config.craftFile) then
    local okLoad, craft = pcall(dofile, config.craftFile)
    if okLoad and type(craft) == "table" and type(craft.instruments) == "table" then
      for r, side in pairs(craft.instruments) do
        if type(side) == "string" then role[side] = r end
      end
    end
  end

  local function ask(side, method, ...)
    local ok, result = pcall(peripheral.call, side, method, ...)
    if not ok then return "ERROR: " .. tostring(result):gsub("^.*:%d+: ", "") end
    if result == nil then return "nil" end
    return tostring(result)
  end

  if #sides == 0 then
    print("No optical sensors attached to this computer.")
    print("They must be on the same wired network, or touching it.")
    return
  end

  print(("%d optical sensor(s). Ctrl-T to stop."):format(#sides))
  while true do
    term.clear(); term.setCursorPos(1, 1)
    print("optical sensors            " .. textutils.formatTime(os.time(), true))
    for _, side in ipairs(sides) do
      print("")
      print(side .. (role[side] and ("  [" .. role[side] .. "]") or "  [unassigned]"))
      print("  range    " .. ask(side, "getRange"))
      print("  hasHit   " .. ask(side, "hasHit"))
      print("  distance " .. ask(side, "getDistance"))
      print("  block    " .. ask(side, "getBlock"))
    end
    os.sleep(0.5)
  end
end

--------------------------------------------------------------------------------
-- Survey
--------------------------------------------------------------------------------

local found = {}     -- [type] = { side, ... }, in attachment order
local order = {}     -- every side, in attachment order

for _, side in ipairs(peripheral.getNames()) do
  local ok, kind = pcall(peripheral.getType, side)
  if ok and kind then
    found[kind] = found[kind] or {}
    found[kind][#found[kind] + 1] = side
    order[#order + 1] = { side = side, kind = kind }
  end
end

local lines = {
  "Peripherals attached to computer " .. os.getComputerID(),
  ("Label: %s"):format(os.getComputerLabel() or "(none)"),
  "",
}

for _, entry in ipairs(order) do
  lines[#lines + 1] = ("%s  [%s]"):format(entry.side, entry.kind)

  local ok, methods = pcall(peripheral.getMethods, entry.side)
  if ok and type(methods) == "table" then
    table.sort(methods)
    -- Wrapped at seventy-odd columns rather than dumped as one line, because a
    -- bearing has fifty methods and a single line of them is unreadable in
    -- every editor CC has.
    local row = "   "
    for _, m in ipairs(methods) do
      if #row + #m + 2 > 72 then
        lines[#lines + 1] = row
        row = "   "
      end
      row = row .. m .. " "
    end
    if row ~= "   " then lines[#lines + 1] = row end
  else
    lines[#lines + 1] = "   (no methods -- this is not a peripheral we can drive)"
  end
  lines[#lines + 1] = ""
end

if #order == 0 then
  lines[#lines + 1] = "Nothing is attached."
  lines[#lines + 1] = ""
  lines[#lines + 1] = "A computer only sees blocks it touches, or blocks on the"
  lines[#lines + 1] = "same wired modem network. On an assembled contraption both"
  lines[#lines + 1] = "the computer and the blocks have to be part of it."
end

--------------------------------------------------------------------------------
-- A craft file to start from
--------------------------------------------------------------------------------

local function first(kind) return found[kind] and found[kind][1] end

local controls, mix, notes = {}, {}, {}

-- Bearings. The first is assumed to hold the ship up and the second to push it
-- along, which is the commonest arrangement and is still a guess -- so it is
-- said out loud in the file rather than left to be discovered in the air.
local bearings = found.thruster_bearing or {}

if bearings[1] then
  controls[#controls + 1] = ('    lift = { kind = "bearing", peripheral = %q, group = "all" },')
    :format(bearings[1])
  mix[#mix + 1] = '    { demand = "lift",    control = "lift", as = "throttle" },'
end

if bearings[2] then
  controls[#controls + 1] = ('    main = { kind = "bearing", peripheral = %q, group = "all",')
    :format(bearings[2])
  controls[#controls + 1] =  '            pivot = { min = -30, max = 30 } },'
  mix[#mix + 1] = '    { demand = "forward", control = "main", as = "throttle" },'
  mix[#mix + 1] = '    { demand = "yaw",     control = "main", as = "pivot", scale = 30 },'
else
  notes[#notes + 1] = "Only one thruster bearing was found, so this ship can hold"
  notes[#notes + 1] = "altitude but has nothing to push it along. Add a second"
  notes[#notes + 1] = "bearing as `main` if it is meant to go somewhere."
end

if #bearings > 2 then
  notes[#notes + 1] = ("There are %d thruster bearings. Only the first two are"):format(#bearings)
  notes[#notes + 1] = "used above -- check which is which and add the rest."
end

for i = 3, #bearings do
  controls[#controls + 1] =
    ('    -- bearing%d = { kind = "bearing", peripheral = %q, group = "all" },')
      :format(i, bearings[i])
end

-- Single thrusters, for hulls that drive them directly rather than through a
-- bearing. Commented out: if there is a bearing, these are almost certainly the
-- thrusters attached to it and driving both would fight.
for i, side in ipairs(found.thruster or {}) do
  controls[#controls + 1] =
    ('    -- thruster%d = { kind = "thruster", peripheral = %q },'):format(i, side)
end

if first("virtual_orientation_source") or first("gyroscope_link") then
  controls[#controls + 1] = ('    trim = { kind = "orientation", peripheral = %q },')
    :format(first("virtual_orientation_source") or first("gyroscope_link"))
  mix[#mix + 1] = '    { demand = "pitch",   control = "trim", as = "angleX", scale = 15 },'
end

if first("wheel_mount") then
  controls[#controls + 1] = ('    wheels = { kind = "wheels", peripheral = %q },')
    :format(first("wheel_mount"))
  notes[#notes + 1] = "A wheel mount was found. Wheels are not in the mix above:"
  notes[#notes + 1] = "a ground vehicle wants forward on left/right, not on a"
  notes[#notes + 1] = "thruster. See README.md."
end

if first("claw") or first("rope_winch_cable") then
  controls[#controls + 1] = ('    claw = { kind = "grip", peripheral = %q },')
    :format(first("claw") or first("rope_winch_cable"))
end

-- Redstone. Commented out, because nothing here can work out what is on the
-- other end of a wire: a signal out of the back of this computer might be a
-- burner, a gearshift, or nothing at all. But a great deal of Create Aeronautics
-- is driven by a signal rather than a method call, and someone reading a
-- generated file has no way to know this kind exists unless it is in it.
local relays = found.redstone_relay or {}

controls[#controls + 1] = "    -- Redstone. `side` is one of top bottom left right"
controls[#controls + 1] = "    -- front back, and `mode` is digital, analog or bundled."
controls[#controls + 1] = "    -- With no `peripheral` these drive this computer's own sides."
controls[#controls + 1] = "    --"
controls[#controls + 1] = "    -- A hot air burner or a steam vent is analogue: the signal"
controls[#controls + 1] = "    -- strength sets the target volume of hot air, so it is the"
controls[#controls + 1] = "    -- lift. `hold = true` leaves it burning when the program"
controls[#controls + 1] = "    -- stops, which on a balloon is the difference between"
controls[#controls + 1] = "    -- landing and falling."
controls[#controls + 1] =
  '    -- burner = { kind = "wire", side = "top", mode = "analog", hold = true },'
controls[#controls + 1] = '    -- vent   = { kind = "wire", side = "left" },'

for i, side in ipairs(relays) do
  controls[#controls + 1] =
    ('    -- relayed%d = { kind = "wire", peripheral = %q, side = "front" },')
      :format(i, side)
end

if #relays > 0 then
  notes[#notes + 1] = ("%d redstone relay(s) found. A relay has the same API as"):format(#relays)
  notes[#notes + 1] = "this computer's own sides and can sit anywhere on a wired"
  notes[#notes + 1] = "modem network, which on an assembled contraption is how a"
  notes[#notes + 1] = "burner ends up somewhere sensible."
end

-- Instruments. Every one of these is found automatically at load, so naming
-- them is only necessary when there are two -- but writing them down makes the
-- file a description of the ship rather than a list of overrides, and a hull
-- that loses a sensor then says so instead of quietly flying without it.
-- The type strings are the ones each peripheral class's own getType() returns,
-- which are not always the block's name.
local ROLES = {
  { "nav",    "navigation_table" },
  { "alt",    "altitude_sensor" },
  { "vel",    "velocity_sensor" },
  { "gimbal", "gimbal_sensor" },
  -- Both optical roles, handled specially below: they are the same block and
  -- only the person who mounted them knows which way each one points.
  { "ground", "optical_sensor" },
  { "forward", "optical_sensor" },
  { "dock",   "docking_connector" },
  { "stick",  "analogue_joystick" },
  { "link",   "advanced_data_link" },
  { "homing", "directional_link" },
  { "range",  "modulating_link" },
  { "plate",  "name_plate" },
  { "swivel", "swivel_bearing" },
}

local instrumentLines = {}
local eyes = found.optical_sensor or {}

for _, role in ipairs(ROLES) do
  local side = first(role[2])

  -- The optical sensors are the lift-and-main problem again in miniature. Two
  -- of them are indistinguishable by type, so the first is guessed as the
  -- downward one and the second as the forward one -- which is the commonest
  -- arrangement, is still a guess, and is said out loud below.
  if role[1] == "ground" then side = eyes[1] end
  if role[1] == "forward" then side = eyes[2] end

  if side then
    instrumentLines[#instrumentLines + 1] = ("    %s = %q,"):format(role[1], side)
  else
    -- **Commented out, not `false`.**
    --
    -- `false` in a craft file means "this hull deliberately has none, stop
    -- looking and stop warning". That is not what a missing peripheral means
    -- here: it means one was not attached *at the moment probe ran*, which is
    -- the normal state of a contraption that has not been assembled yet.
    --
    -- Writing `false` for it turned a temporary absence into a permanent one.
    -- Plug the navigation table in afterwards and the pilot would never look
    -- for it again, because the craft file was now insisting the ship had none.
    -- Commented out, the role is simply found automatically once it appears.
    instrumentLines[#instrumentLines + 1] =
      ("    -- %s = ?,   -- no %s attached when probe ran"):format(role[1], role[2])
  end
end

if not first("navigation_table") then
  notes[#notes + 1] = "There is no navigation table. Without one this ship can"
  notes[#notes + 1] = "hold altitude but cannot navigate to anything."
end
if #eyes >= 2 then
  notes[#notes + 1] = ("%d optical sensors. The first is assumed to point DOWN"):format(#eyes)
  notes[#notes + 1] = "and the second FORWARD. Check which is which -- a"
  notes[#notes + 1] = "forward sensor read as the ground makes the terrain"
  notes[#notes + 1] = "guard fire at a hillside it is not under yet."
elseif #eyes == 1 then
  notes[#notes + 1] = "One optical sensor, assumed to point DOWN for ground"
  notes[#notes + 1] = "clearance. A second one pointing forward gives the"
  notes[#notes + 1] = "obstacle guard, which is the only thing that sees a"
  notes[#notes + 1] = "cliff face coming."
end

if first("gimbal_sensor") then
  notes[#notes + 1] = "A gimbal sensor peripheral was found, so tilt is read"
  notes[#notes + 1] = "directly and there is no need to wire it as redstone."
end
if not first("altitude_sensor") then
  notes[#notes + 1] = "There is no altitude sensor. The pilot will fall back to"
  notes[#notes + 1] = "the navigation table's height, and will hand the hull back"
  notes[#notes + 1] = "to redstone if it loses that too."
end

local craft = {
  "-- What this ship is, and how to fly it.",
  "--",
  "-- Written by probe.lua from what was attached. Everything here is a guess",
  "-- except the peripheral names, and the guesses are worth checking:",
  "--",
  "--   * which bearing is lift and which is main. Nothing can tell these apart",
  "--     by looking, and getting them the wrong way round is a ship that",
  "--     accelerates into the ground.",
  "--   * the limits. They are conservative defaults, not measurements.",
  "--   * the gains, which are tuned for a hull that hovers at half throttle.",
  "--",
  "-- This file is deliberately not in manifest.txt, so `update` never replaces",
  "-- it. Edit it freely.",
  "",
  ("return {"),
  ("  name = %q,"):format(os.getComputerLabel() or "unnamed"),
  "",
  "  controls = {",
}

for _, line in ipairs(controls) do craft[#craft + 1] = line end

craft[#craft + 1] = "  },"
craft[#craft + 1] = ""
craft[#craft + 1] = "  instruments = {"
for _, line in ipairs(instrumentLines) do craft[#craft + 1] = line end
craft[#craft + 1] = "  },"
craft[#craft + 1] = ""
craft[#craft + 1] = "  -- Redstone coming in: a launch button, a lever, a comparator on"
craft[#craft + 1] = "  -- the hold, the joystick's own directional output. These drive"
craft[#craft + 1] = "  -- nothing by themselves; they are read every sweep and ride in the"
craft[#craft + 1] = "  -- telemetry, so you can see them from the ground."
craft[#craft + 1] = "  signals = {"
craft[#craft + 1] = '    -- launch = { side = "front" },'
craft[#craft + 1] = '    -- cargo  = { side = "right", mode = "analog" },'
craft[#craft + 1] = "  },"
craft[#craft + 1] = ""
craft[#craft + 1] = "  -- A gimbal sensor wired as redstone rather than read as a"
craft[#craft + 1] = "  -- peripheral. It powers the face of whichever side is leaning"
craft[#craft + 1] = "  -- down. `degrees` is what a signal of 15 means and has to match"
craft[#craft + 1] = "  -- the sensitivity panels on the block -- nothing here can read"
craft[#craft + 1] = "  -- them. Not needed if you have the gimbal_sensor peripheral."
craft[#craft + 1] = "  -- tilt = { front = \"front\", back = \"back\","
craft[#craft + 1] = "  --          left = \"left\", right = \"right\", degrees = 30 },"
craft[#craft + 1] = ""
craft[#craft + 1] = "  -- cruise/climb/descend are blocks per second."
craft[#craft + 1] = "  -- clearance is how close to the ground the terrain guard tolerates."
craft[#craft + 1] = "  limits = { cruise = 10, climb = 3, descend = 2, clearance = 8 },"
craft[#craft + 1] = ""
craft[#craft + 1] = "  -- hover is where the lift throttle sits when the ship is neither"
craft[#craft + 1] = "  -- climbing nor sinking. Only a starting guess: the vertical loop's"
craft[#craft + 1] = "  -- integral finds the real value within a few seconds."
craft[#craft + 1] = "  gains = { hover = 0.5 },"
craft[#craft + 1] = ""
craft[#craft + 1] = "  mix = {"
for _, line in ipairs(mix) do craft[#craft + 1] = line end
craft[#craft + 1] = "  },"
craft[#craft + 1] = "}"

--------------------------------------------------------------------------------
-- Write
--------------------------------------------------------------------------------

local function write(path, body)
  local f = fs.open(path, "w")
  if not f then return false end
  for _, line in ipairs(body) do f.writeLine(line) end
  f.close()
  return true
end

if #notes > 0 then
  lines[#lines + 1] = "Notes"
  lines[#lines + 1] = ""
  for _, note in ipairs(notes) do lines[#lines + 1] = "  " .. note end
  lines[#lines + 1] = ""
end

write(config.surveyFile, lines)

-- Never overwritten. A generated file replacing a hull definition somebody tuned
-- over an evening would be the single most annoying thing this program could do.
local target = config.craftFile
local existing = fs.exists(target)
if existing and not force then
  target = config.craftFile .. ".new"
end
write(target, craft)

--------------------------------------------------------------------------------

print(("Found %d peripherals."):format(#order))
print("Survey: " .. config.surveyFile)

if existing and not force then
  print("Kept your " .. config.craftFile .. ".")
  print("Suggested one: " .. target)
else
  print("Wrote " .. target)
end

for _, note in ipairs(notes) do print(note) end

if #notes == 0 and not existing then
  print("Check which bearing is lift and which is main, then run pilot.")
end
