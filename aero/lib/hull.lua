--- Named controls and instruments over whatever is bolted to this hull.
--
-- The unit everything else talks about. Not a peripheral: "lift" is what the
-- mix wants to push on, and it may be `thruster_bearing_1` addressed as "all"
-- while "main" is `thruster_bearing_0` with a thirty degree pivot limit. The
-- autopilot names controls, the flight plan names controls, the log names
-- controls, and only this file knows which peripheral any of them is.
--
-- It is also the only module here that touches `peripheral`, which is what lets
-- lib/autopilot.lua, lib/nav.lua and lib/flight.lua be pure and testable. The
-- global is read at call time rather than captured at load, so a test can
-- substitute a mock.
--
-- Three rules run through the whole file, all of them the same rule:
--
--   * **Never throw.** Every call into the mod goes through `call` below, which
--     pcalls it and records a fault. A missing peripheral, a method that this
--     version of the addon does not have, a bearing broken off the hull by a
--     tree -- none of them may take down the control loop, because a control
--     loop that stops is a building that falls.
--   * **The safe state is the hull's own.** `release` hands control back to
--     redstone rather than writing zeros. A ship with no computer at all does
--     whatever its levers say; that is the state to leave behind, and it is not
--     the same thing as every engine off.
--   * **Every write is an override that outlives us.** setThrottle switches a
--     thruster into computer control and it stays there after the program exits.
--     This is the aero version of "an output is held by the computer" from the
--     redstone network, and it is much less forgiving.
--
-- The peripheral and method names below are from the mod's own reference,
-- /rom/thrusters/docs.lua, not from guesswork.

local config = require("lib.config")

local hull = {}

hull.craft       = nil   -- the whole /craft.cfg table, as loaded
hull.name        = nil   -- what the ship calls itself
hull.controls    = {}    -- [name] = control
hull.order       = {}    -- control names in file order, which the UI draws in
hull.instruments = {}    -- [role] = { role, side, kind }
hull.limits      = {}
hull.gains       = {}
hull.mix         = {}
hull.problems    = {}    -- what was wrong with the last define(), for the UI
hull.faults      = {}    -- [key] = reason -- what has gone wrong since
hull.current     = {}    -- [control] = { field = value } we are actually driving
hull.wires       = {}    -- ["<relay|*>:<face>"] = { control, ... } sharing a side
hull.tilt        = nil   -- the gimbal sensor read over redstone, if wired that way
hull.signals     = {}    -- [name] = redstone inputs read this sweep

-- Fuel and thrust are read on their own slower clock, see `read`.
hull.fuel   = { fuel = nil, capacity = nil, burn = nil, thrust = nil, lift = nil }
hull.fuelAt = -math.huge

--------------------------------------------------------------------------------
-- Kinds
--------------------------------------------------------------------------------

-- What a control of each kind can be asked for, and which peripheral type it
-- expects. `fields` is what lib/autopilot.lua's mix is validated against, so a
-- mix naming a field the control cannot do is caught at load rather than
-- discovered at four hundred blocks.
--
-- `fields` is a list rather than a set because it is also the order writes are
-- reported in, and pairs() over a set is hash order -- which would have the log
-- and the telemetry frame listing the same sweep's changes differently on two
-- computers reading the same hull.
local KINDS = {
  bearing = {
    types  = { thruster_bearing = true },
    fields = { "throttle", "pivot" },
  },
  thruster = {
    types  = { thruster = true },
    fields = { "enabled", "throttle" },
  },
  orientation = {
    types  = { virtual_orientation_source = true, gyroscope_link = true },
    fields = { "angleX", "angleZ" },
  },
  wheels = {
    types  = { wheel_mount = true },
    fields = { "left", "right", "brake" },
  },
  input = {
    types  = { analogue_contraption_controller = true },
    fields = { "input" },
  },
  grip = {
    types  = { claw = true, rope_winch_cable = true },
    fields = { "grip" },
  },

  -- Plain redstone, and the reason this list is not just the Gadgets & Gizmos
  -- peripherals. A great deal of Create Aeronautics is driven by a signal rather
  -- than by a method call -- hot air burners, steam vents, throttle levers,
  -- gearshifts, deployers, anything on a redstone link, and every thruster
  -- sitting in its default `redstone` control mode. Without this kind, "put the
  -- burner on when we want to climb" has no way to be said at all.
  --
  -- `wire` is the only kind that may have **no peripheral**: with none it drives
  -- the flight computer's own six sides through the `redstone` global, and with
  -- one it drives a `redstone_relay`, which has an identical API and can sit
  -- anywhere on a wired modem network. On an assembled contraption that matters
  -- -- the computer is wherever it was placed, and the burner is wherever it
  -- looks right.
  wire = {
    types  = { redstone_relay = true },
    fields = { "signal" },
    loose  = true,        -- may resolve to the computer's own bus, see define
  },

  -- A bidirectional gearbox, driven one face at a time. `setFaceAngle` is a
  -- servo position in degrees, the same shape as a bearing's pivot, so a mix
  -- term aims it exactly the way it aims one of those.
  --
  -- The block's *mode* is deliberately not touched. auto, passthrough, servo and
  -- the rest change what the gearbox is for, that is a decision its builder made
  -- when they placed it, and a program that quietly flipped it to servo on boot
  -- would break a contraption that was working.
  gearbox = {
    types  = { bidirectional_gearbox = true },
    fields = { "angle" },
  },
}

-- The set form, built once, for the mix validation and for `apply`'s lookup.
for _, spec in pairs(KINDS) do
  spec.has = {}
  for _, field in ipairs(spec.fields) do spec.has[field] = true end
end

-- Which of those fields are thrust-like, and so slew-limited on the way out.
-- Angles are not: a bearing and a gyro rate-limit themselves in the world, and
-- a second rate limit in software here would only fight the first one.
--
-- `signal` is here conditionally -- see `apply`. An analogue signal driving a
-- throttle lever wants the same rate limit a throttle does; a digital one is a
-- switch, and rate-limiting a switch just means it turns on a fraction of a
-- second late.
local SLEWED = { throttle = true, left = true, right = true }

-- The six sides, and the three shapes a redstone signal comes in. Same three as
-- redstone/lib/ports.lua, and for the same reason: they share the sides but each
-- needs a different pair of API calls.
local SIDES = { top = true, bottom = true, left = true,
                right = true, front = true, back = true }

local MODES = { digital = true, analog = true, bundled = true }

-- A gearbox names its faces by compass point rather than by the computer's own
-- sides, because it is a block on a contraption rather than something bolted to
-- the machine running this.
local GEAR_FACES = { north = true, south = true, east = true, west = true }

-- Forward declaration. `emitFace` lives down with the other writing code, where
-- it belongs, but `release` needs it and comes first -- a wire is the one control
-- kind release has to actively turn off rather than hand back.
local emitFace

--- Is this one of the sixteen colours?
--
-- Checked by walking the powers of two rather than with a logarithm: there are
-- sixteen of them, and a float log2 that came back as 3.9999999 would reject a
-- perfectly good colour.
local function isColour(c)
  if type(c) ~= "number" or c ~= math.floor(c) then return false end
  local bit = 1
  for _ = 1, 16 do
    if c == bit then return true end
    bit = bit * 2
  end
  return false
end

-- Instrument roles and the peripheral types that can fill them. A role may be
-- filled by more than one type because the base mod and the Gadgets & Gizmos
-- compatibility layer expose some of the same blocks under different names.
--
-- Every type string here is from the peripheral class's own getType(), not
-- inferred from the block name -- the two are not always the same word, and a
-- role that auto-finds nothing is a silent instrument rather than an error.
local ROLES = {
  nav    = { navigation_table = true },
  alt    = { altitude_sensor = true },
  vel    = { velocity_sensor = true },
  gimbal = { gimbal_sensor = true },
  -- Two optical sensors, and which is which is a decision nobody can make by
  -- looking. `ground` points **down** and feeds the terrain guard; `forward`
  -- points along the ship's nose and feeds the obstacle guard.
  --
  -- Only `ground` is auto-found, and only when there is exactly one sensor --
  -- see define. A hull with one sensor mounted facing forward and picked up as
  -- the ground sensor has a terrain guard reading the distance to a hillside it
  -- is about to hit as though it were altitude, which is worse than having no
  -- guard at all.
  ground  = { optical_sensor = true },
  forward = { optical_sensor = true },

  dock   = { docking_connector = true },
  stick  = { analogue_joystick = true },
  link   = { advanced_data_link = true },

  -- A linked receiver pair, which between them give bearing and distance to the
  -- nearest matching link: a homing fix. Reported, not flown on -- see `read`.
  --
  -- Called `homing` and not `beacon`, because beacon.lua is a different
  -- thing entirely -- a computer standing in the world being a waypoint --
  -- and one word for two of them is a confusing bug report waiting to be
  -- written.
  homing = { directional_link = true },
  range  = { modulating_link = true },

  -- The ship's name on a physical block, so it is readable from outside as well
  -- as on the dashboard.
  plate  = { name_plate = true },

  -- Where a swivel bearing has been told to point. Read-only: the peripheral
  -- exposes getTargetAngle and nothing that sets it.
  swivel = { swivel_bearing = true },
}

-- Deliberately not wired up, and listed so that is a decision rather than an
-- oversight:
--
--   torsion_spring     getAngle / setLimit / isRunning. An actuator, but what a
--                      limit does to a hull in flight is not something this file
--                      can guess at, and guessing would mean a control that
--                      moves something nobody asked it to move.
--   linked_typewriter  getPressedKeyCodes, and it attaches to the computer. A
--                      cockpit keyboard -- a manual flying mode rather than an
--                      instrument, and a different program from this one.

--------------------------------------------------------------------------------
-- Talking to the mod
--------------------------------------------------------------------------------

--- Call a method on a peripheral, and never throw.
--
-- Returns value, reason. The reasons a call fails are all real and all
-- survivable: the block was broken off, the addon is a version older than this
-- method, or a value was out of range. None of them is worth a stack trace on a
-- computer nobody can reach.
--
-- **Failure is the second return, not a nil first one.** Most of the methods
-- worth calling here -- setThrottle, clear, clearThrottleOverride -- return
-- nothing at all, so a nil value says only that the method was void. Testing it
-- for failure is how `release` came to hand the hull back and then immediately
-- take it again, which is the exact opposite of what release is for.
--
-- Two returns also means **`tonumber((call(...)))` needs the inner brackets**.
-- Without them the reason string is passed to tonumber as the numeric base, and
-- the error you get is "bad argument #1 (expected string, got nil)" from a line
-- that plainly has a string in it.
local function call(key, side, method, ...)
  if not side then
    hull.faults[key] = "not attached"
    return nil, "not attached"
  end

  local ok, result = pcall(peripheral.call, side, method, ...)
  if not ok then
    hull.faults[key] = method .. ": " .. tostring(result)
    return nil, hull.faults[key]
  end

  hull.faults[key] = nil
  return result
end

--- Call a redstone method, on a relay or on the computer's own bus.
--
-- `side` is the relay's peripheral name, or nil for the flight computer itself.
-- The two have an identical API, which is the whole reason a relay is worth
-- supporting: the same control definition works either way and moving a burner
-- onto a relay is one line in /craft.cfg rather than a different kind.
--
-- The `redstone` global is read at call time rather than captured at load, for
-- the same reason `peripheral` is: it is how the test harness substitutes a bus.
local function wireCall(key, side, method, ...)
  if side then return call(key, side, method, ...) end

  local api = _G.redstone or _G.rs
  if type(api) ~= "table" or type(api[method]) ~= "function" then
    hull.faults[key] = "no redstone API for " .. method
    return nil, hull.faults[key]
  end

  local ok, result = pcall(api[method], ...)
  if not ok then
    hull.faults[key] = method .. ": " .. tostring(result)
    return nil, hull.faults[key]
  end

  hull.faults[key] = nil
  return result
end

--- Does this peripheral have this method? Used to tell the base mod's
--- AltitudeSensorPeripheral.getHeight from the compatibility layer's
--- getWorldHeight without calling one and catching the error.
local function has(side, method)
  if not side then return false end
  local ok, methods = pcall(peripheral.getMethods, side)
  if not ok or type(methods) ~= "table" then return false end
  for _, m in ipairs(methods) do
    if m == method then return true end
  end
  return false
end

--- The first attached peripheral of any of these types, or nil. How probe.lua
--- guesses a starting /craft.cfg, and how an instrument with no side named finds
--- itself anyway -- most hulls have exactly one altitude sensor and making
--- someone write that down is friction for nothing.
function hull.find(types)
  local ok, names = pcall(peripheral.getNames)
  if not ok then return nil end

  for _, side in ipairs(names) do
    local okType, kind = pcall(peripheral.getType, side)
    if okType and types[kind] then return side, kind end
  end
  return nil
end

--------------------------------------------------------------------------------
-- Definition
--------------------------------------------------------------------------------

function hull.reset()
  hull.craft, hull.name = nil, nil
  hull.controls, hull.order, hull.instruments = {}, {}, {}
  hull.limits, hull.gains, hull.mix = {}, {}, {}
  hull.problems, hull.faults, hull.current = {}, {}, {}
  hull.wires, hull.signals, hull.inputs = {}, {}, {}
  hull.tilt = nil
  hull.fuel, hull.fuelAt = {}, -math.huge
end

--- Sort control names for a stable draw order.
--
-- /craft.cfg's `controls` is a map, and pairs() over a map is in hash order --
-- which means the pocket computer's control list would come back in a different
-- order on every computer that read the same file. Alphabetical is arbitrary but
-- it is at least the same arbitrary everywhere.
local function sortedKeys(t)
  local keys = {}
  for k in pairs(t or {}) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

--- Validate and install a craft definition. Returns ok, problems.
--
-- A bad entry is dropped with a reason rather than throwing: a typo in
-- /craft.cfg should cost you one control and a warning on screen, not a ship
-- that will not boot far enough to let you fix it.
function hull.define(craft, path)
  hull.reset()

  if type(craft) ~= "table" then
    hull.problems = { "craft file did not return a table" }
    return false, hull.problems
  end

  hull.craft  = craft
  hull.name   = type(craft.name) == "string" and craft.name or nil
  hull.limits = type(craft.limits) == "table" and craft.limits or {}
  hull.gains  = type(craft.gains)  == "table" and craft.gains  or {}

  -- Controls -----------------------------------------------------------------

  for _, name in ipairs(sortedKeys(craft.controls)) do
    local c   = craft.controls[name]
    local why = nil

    if type(c) ~= "table" then
      why = name .. ": not a table"
    elseif not KINDS[c.kind] then
      why = name .. ": '" .. tostring(c.kind) .. "' is not a control kind"
    end

    if not why then
      local spec = KINDS[c.kind]

      -- A control may name its peripheral or leave it to be found. Naming it is
      -- how a hull with two bearings says which is which; leaving it out is how
      -- a hull with one says "the obvious one".
      local side = c.peripheral
      if side and not peripheral.isPresent(side) then
        why = name .. ": " .. tostring(side) .. " is not attached"
        side = nil
      elseif not side and not spec.loose then
        side = hull.find(spec.types)
        if not side then
          why = name .. ": no " .. next(spec.types) .. " attached"
        end
      end
      -- A `wire` with no peripheral named is not a failure to find one: it is
      -- the flight computer's own six sides, which is the common case and needs
      -- nothing attached at all. Deliberately not auto-found either -- picking up
      -- a relay somebody put on the network for something else and quietly
      -- driving a burner through it would be a very confusing afternoon.

      local control = {
        name    = name,
        kind    = c.kind,
        side    = side,
        group   = c.group or "all",   -- a bearing addresses its thrusters by id or "all"
        fields  = spec.fields,        -- in write order
        has     = spec.has,
        pivot   = c.pivot,            -- { min, max } in degrees, clamped on write
        input   = c.input,            -- a controller channel id, for kind = "input"
        -- One field, two meanings, and they never overlap: a `wire` names one
        -- of the computer's six sides with `side`, a `gearbox` names a compass
        -- face with `face`. Each is validated against its own set below.
        face    = (c.kind == "gearbox") and c.face or c.side,
        mode    = c.mode or "digital",
        colour  = c.colour or c.color,
        invert  = c.invert and true or false,
        -- `hold` marks a wire whose signal is holding the ship up: a hot air
        -- burner or a steam vent. See `release`.
        hold    = c.hold and true or false,
        label   = c.label or name,
      }

      -- Wiring is checked here rather than at write time, because a signal sent
      -- to a side that does not exist is silently nothing at all -- the burner
      -- simply never lights, and there is no error anywhere to explain it.
      if c.kind == "gearbox" and not why then
        if not GEAR_FACES[control.face] then
          why = name .. ": '" .. tostring(control.face)
            .. "' is not a gearbox face (north south east west)"
        end
      end

      if c.kind == "wire" and not why then
        if not SIDES[control.face] then
          why = name .. ": '" .. tostring(control.face) .. "' is not a side"
        elseif not MODES[control.mode] then
          why = name .. ": '" .. tostring(control.mode) .. "' is not digital, analog or bundled"
        elseif control.mode == "bundled" and not isColour(control.colour) then
          why = name .. ": a bundled wire needs a colour"
        end
      end

      hull.controls[name] = control
      hull.order[#hull.order + 1] = name

      -- A control that could not find its peripheral is still installed, with
      -- side = nil. Dropping it would mean the mix silently loses a term and the
      -- ship flies on three engines believing it has four; keeping it means
      -- every write logs a fault and the pocket shows the control in red.
      if why then hull.problems[#hull.problems + 1] = why end
    else
      hull.problems[#hull.problems + 1] = why
    end
  end

  -- Wires sharing a face -------------------------------------------------------

  -- A side carries one signal, so everything driving it has to agree about what
  -- that signal is. Recomputing the whole face on every write is the only way to
  -- get bundled cable right -- a bundled side is one number shared by up to
  -- sixteen controls, and setting a colour without knowing the other fifteen
  -- turns them all off.
  for _, name in ipairs(hull.order) do
    local c = hull.controls[name]
    if c.kind == "wire" and c.face then
      local key = (c.side or "*") .. ":" .. c.face
      hull.wires[key] = hull.wires[key] or {}
      local group = hull.wires[key]

      local why = nil
      local first = group[1]
      if first then
        if first.mode ~= c.mode then
          why = name .. ": " .. c.face .. " is already " .. first.mode
        elseif c.mode ~= "bundled" then
          why = name .. ": " .. c.face .. " is already used by " .. first.name
        else
          for _, other in ipairs(group) do
            if other.colour == c.colour then
              why = name .. ": that colour is already used by " .. other.name
              break
            end
          end
        end
      end

      if why then
        hull.problems[#hull.problems + 1] = why
      else
        group[#group + 1] = c
      end
    end
  end

  -- Redstone inputs ------------------------------------------------------------

  -- Named signals coming *in*: a launch button, a lever the pilot flips, a
  -- comparator on the cargo hold, the joystick's own directional output. They
  -- drive nothing by themselves -- they are read every sweep, ride in the
  -- telemetry frame and show on the dashboard, which is what makes "the hold is
  -- full" a thing you can see from the ground rather than a thing you find out
  -- when the ship will not climb.
  for _, name in ipairs(sortedKeys(craft.signals)) do
    local s = craft.signals[name]
    local why = nil

    if type(s) ~= "table" then
      why = "signal " .. name .. ": not a table"
    elseif not SIDES[s.side] then
      why = "signal " .. name .. ": '" .. tostring(s.side) .. "' is not a side"
    elseif not MODES[s.mode or "digital"] then
      why = "signal " .. name .. ": '" .. tostring(s.mode) .. "' is not a mode"
    elseif (s.mode == "bundled") and not isColour(s.colour or s.color) then
      why = "signal " .. name .. ": a bundled input needs a colour"
    elseif s.peripheral and not peripheral.isPresent(s.peripheral) then
      why = "signal " .. name .. ": " .. tostring(s.peripheral) .. " is not attached"
    end

    if why then
      hull.problems[#hull.problems + 1] = why
    else
      hull.inputs[#hull.inputs + 1] = {
        name   = name,
        side   = s.peripheral,        -- a relay, or nil for our own bus
        face   = s.side,
        mode   = s.mode or "digital",
        colour = s.colour or s.color,
        invert = s.invert and true or false,
        label  = s.label or name,
      }
    end
  end

  -- Tilt over redstone ---------------------------------------------------------

  -- The gimbal sensor "outputs redstone signals based on which side is leaning
  -- downwards", one adjustable sensitivity per axis. So attitude off a bare
  -- sensor is four analogue reads to be combined, not a method call -- and on a
  -- hull without the Gadgets & Gizmos peripheral it is the only way to know
  -- which way up the ship is.
  --
  --   tilt = { front = "front", back = "back",
  --            left = "left", right = "right", degrees = 30 }
  --
  -- Each names the input side that powers when *that* side of the ship leans
  -- down. `degrees` is what a signal of 15 means and must match the sensitivity
  -- panels on the block, because nothing here can read them.
  local tilt = craft.tilt
  if type(tilt) == "table" then
    local why = nil

    if tilt.peripheral and not peripheral.isPresent(tilt.peripheral) then
      why = "tilt: " .. tostring(tilt.peripheral) .. " is not attached"
    end

    local faces = {}
    for _, axis in ipairs({ "front", "back", "left", "right" }) do
      local side = tilt[axis]
      if side ~= nil then
        if not SIDES[side] then
          why = why or ("tilt." .. axis .. ": '" .. tostring(side) .. "' is not a side")
        else
          faces[axis] = side
        end
      end
    end

    -- All four may be wired, or only the pair for one axis. None at all is a
    -- `tilt` block that says nothing, which is more likely a half-finished edit
    -- than an intention.
    if not why and next(faces) == nil then
      why = "tilt: no sides named"
    end

    if why then
      hull.problems[#hull.problems + 1] = why
    else
      hull.tilt = {
        side    = tilt.peripheral,
        faces   = faces,
        degrees = tonumber(tilt.degrees) or 30,
        invertPitch = tilt.invertPitch and true or false,
        invertRoll  = tilt.invertRoll  and true or false,
      }
    end
  end

  -- Instruments --------------------------------------------------------------

  local named = type(craft.instruments) == "table" and craft.instruments or {}

  for role, types in pairs(ROLES) do
    local side = named[role]

    if side == false then
      -- An explicit false means "this hull has none, stop looking and stop
      -- warning about it" -- a balloon with no optical sensor is a design, not a
      -- fault, and a warning that is always there is a warning nobody reads.
      --
      -- But if one is *actually attached*, `false` is almost certainly a
      -- mistake rather than a decision, and it is the most confusing kind:
      -- the hardware is right there and the program refuses to see it. Say so,
      -- and say what to change, because nothing else in the program can explain
      -- a symptom whose cause is a single word in a file.
      if hull.find(types) then
        hull.problems[#hull.problems + 1] =
          role .. " = false in " .. (path or config.craftFile)
          .. ", but a " .. next(types) .. " is attached"
      end
      side = nil
    elseif side then
      if not peripheral.isPresent(side) then
        hull.problems[#hull.problems + 1] =
          role .. ": " .. tostring(side) .. " is not attached"
        side = nil
      end
    elseif role == "forward" then
      -- Never auto-found. Two optical sensors are indistinguishable by type, so
      -- picking one to be the forward sensor would be a coin toss between "the
      -- obstacle guard works" and "the terrain guard is reading a hillside".
      side = nil

    else
      side = hull.find(types)
    end

    if side then
      hull.instruments[role] = {
        role = role,
        side = side,
        kind = select(2, pcall(peripheral.getType, side)),
      }
    end
  end

  -- ...and the same trap from the other end. One sensor auto-found as `ground`
  -- is the common, correct case. Two sensors with only one named means the
  -- second is doing nothing, and the odds are even that the one picked up is the
  -- wrong one.
  local sensors = 0
  for _, name in ipairs((function()
    local ok, list = pcall(peripheral.getNames)
    return ok and list or {}
  end)()) do
    local okType, kind = pcall(peripheral.getType, name)
    if okType and kind == "optical_sensor" then sensors = sensors + 1 end
  end

  if sensors > 1 and (named.ground == nil or named.forward == nil) then
    hull.problems[#hull.problems + 1] =
      ("%d optical sensors: name `ground` and `forward` in instruments, or one is guessed at")
        :format(sensors)
  end

  -- The navigation table is the only instrument whose absence is worth saying
  -- out loud here. Everything else degrades -- no optical sensor means no
  -- terrain guard, no gimbal means no attitude readout -- but with no position
  -- source at all lib/flight.lua will refuse to navigate, and being told that
  -- now beats discovering it on the pad.
  if not hull.instruments.nav then
    -- Three different causes, one symptom, so the message names all three. This
    -- is the single most likely thing to go wrong on a first hull and the
    -- version that only said "no navigation_table" left nowhere to go next.
    local attached = hull.find(ROLES.nav)
    if attached then
      hull.problems[#hull.problems + 1] =
        "a navigation_table is attached but not being used -- check nav in "
        .. (path or config.craftFile)
    else
      hull.problems[#hull.problems + 1] =
        "no navigation_table found: is the contraption assembled, and is the "
        .. "table part of it? Run `setup` to check the hardware"
    end
  end

  -- The mix -----------------------------------------------------------------

  for i, term in ipairs(craft.mix or {}) do
    local why = nil
    local c   = term.control and hull.controls[term.control]

    if type(term) ~= "table" then
      why = "mix " .. i .. " is not a table"
    elseif not c then
      why = "mix " .. i .. ": no control named " .. tostring(term.control)
    elseif not c.has[term.as] then
      why = "mix " .. i .. ": a " .. c.kind .. " has no " .. tostring(term.as)
    end

    if why then
      hull.problems[#hull.problems + 1] = why
    else
      hull.mix[#hull.mix + 1] = {
        demand  = term.demand,
        control = term.control,
        as      = term.as,
        scale   = tonumber(term.scale) or 1,
        bias    = tonumber(term.bias) or 0,
      }
    end
  end

  return #hull.problems == 0, hull.problems
end

--- Load /craft.cfg. Returns ok, problems.
function hull.load(path)
  path = path or config.craftFile

  if not fs or not fs.exists(path) then
    hull.reset()
    hull.problems = { "no " .. path .. " -- run probe.lua to make one" }
    return false, hull.problems
  end

  local fn, err = loadfile(path)
  if not fn then
    hull.reset()
    hull.problems = { path .. ": " .. tostring(err) }
    return false, hull.problems
  end

  local ok, craft = pcall(fn)
  if not ok then
    hull.reset()
    hull.problems = { path .. ": " .. tostring(craft) }
    return false, hull.problems
  end

  return hull.define(craft, path)
end

function hull.get(name) return hull.controls[name] end
function hull.count() return #hull.order end

--------------------------------------------------------------------------------
-- Taking and giving back control
--------------------------------------------------------------------------------

--- Tell every control it is ours now.
--
-- Separate from `define`, which only reads a table: this is the first thing that
-- changes the world, and it is what `release` undoes. Called once at boot, after
-- the state file has been read, so a reboot mid-flight does not claim the hull
-- before it knows what it was doing with it.
function hull.claim()
  for _, name in ipairs(hull.order) do
    local c = hull.controls[name]

    if c.kind == "bearing" then
      call(name, c.side, "setBearingControlMode", "computer")
    elseif c.kind == "thruster" then
      call(name, c.side, "setControlMode", "computer")
      call(name, c.side, "setEnabled", true)
    end
  end

  -- The optical sensor is the terrain guard's only eye, and its default range is
  -- shorter than the clearance we want to keep. Asking for twice the limit means
  -- the guard sees the ground coming rather than arriving.
  local ground = hull.instruments.ground
  if ground then
    local want = (hull.limits.clearance or config.clearance) * 2
    call("ground", ground.side, "setRange", math.floor(want))
  end

  -- The forward sensor wants to see much further: far enough that the obstacle
  -- guard has time to stop the ship, which is a function of cruise speed rather
  -- than of clearance.
  local forward = hull.instruments.forward
  if forward then
    local cruise = tonumber(hull.limits.cruise) or 10
    local want = math.max(cruise * config.reaction * 2, config.standoff * 2)
    call("forward", forward.side, "setRange", math.floor(want))
  end
end

--- Give the hull back, on every exit path there is.
--
-- Not "set everything to zero". The safe state is the one this ship has without
-- a computer on it at all -- whatever its own levers and redstone say -- because
-- that is the state its builder designed and tested. A balloon handed back to
-- redstone keeps its burner lit; the same balloon handed a zero drops out of the
-- sky at terminal velocity with the program that did it already exited.
--
-- Zeroing is the fallback for when handing back fails, which happens when the
-- addon is old enough not to have clearThrottleOverride. Better a ship that
-- sinks slowly than one still holding cruise power with nobody flying it.
function hull.release()
  local released = 0

  for _, name in ipairs(hull.order) do
    local c = hull.controls[name]

    if c.kind == "bearing" then
      local _, failed = call(name, c.side, "clearThrottleOverride", c.group)
      if failed then call(name, c.side, "setThrottle", c.group, 0) end
      call(name, c.side, "clearPivotOverride")
      call(name, c.side, "setBearingControlMode", "redstone")

    elseif c.kind == "thruster" then
      local _, failed = call(name, c.side, "clearThrottleOverride")
      if failed then call(name, c.side, "setThrottle", 0) end
      call(name, c.side, "setControlMode", "redstone")

    elseif c.kind == "orientation" then
      call(name, c.side, "clear")

    elseif c.kind == "wheels" then
      call(name, c.side, "clearControls")

    elseif c.kind == "input" then
      if c.input then call(name, c.side, "resetInput", c.input) end

    elseif c.kind == "gearbox" then
      -- Back to whatever the block does on its own. clearFaceAngle drops the
      -- override without changing the mode, which is the gearbox equivalent of
      -- handing a bearing back to redstone.
      call(name, c.side, "clearFaceAngle", c.face)

    elseif c.kind == "grip" then
      -- Deliberately not released. A claw that let go of its cargo every time
      -- the program stopped would drop a chest of ore into the sea on a reboot,
      -- and unlike a throttle a grip is not holding the ship up.

    elseif c.kind == "wire" then
      -- A wire has no owner underneath us. The computer *is* what holds the
      -- signal, exactly as in the redstone network, so there is nothing to hand
      -- it back to and the only two choices are off and left where it is.
      --
      -- Off is the default, because a vent stuck open or a gearshift stuck over
      -- is worse than one that stopped. But a hot air burner or a steam vent is
      -- holding the ship *up* -- signal strength sets the target volume of hot
      -- air in the balloon, and zero means the balloon empties -- so a `hold`
      -- wire is deliberately left driving. Turning the burner off on the way out
      -- of the program would be a controlled descent nobody asked for, from
      -- whatever altitude the ship happened to be at.
      if not c.hold then
        hull.current[name] = { signal = 0 }
        emitFace(c)
      end
    end

    released = released + 1
  end

  -- Everything we were driving is forgotten, **except** the wires we
  -- deliberately left driving. Clearing those too would leave the burner lit in
  -- the world and recorded as off in the state file -- so the next boot would
  -- restore a zero over a balloon that was perfectly happy, which is the exact
  -- descent `hold` exists to prevent, only delayed until the chunk reloads.
  local kept = {}
  for _, name in ipairs(hull.order) do
    local c = hull.controls[name]
    if c.kind == "wire" and c.hold then kept[name] = hull.current[name] end
  end
  hull.current = kept

  return released
end

--------------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------------

--- Pull an {x,y,z} out of whatever shape the mod handed back.
--
-- Positions come in two shapes and one refusal. The plain shape has x/y/z; the
-- block-backed shape adds blockX/blockY/blockZ and, for anything on a sub-level,
-- localX/localY/localZ. And `projected` comes back false with x/y/z *missing*
-- when the sub-level a position refers to is not loaded -- which on a ship
-- flying away from base is not an error, it is Tuesday.
local function position(p)
  if type(p) ~= "table" then return nil end
  if p.projected == false then return nil end

  local x = tonumber(p.x) or tonumber(p.blockX)
  local y = tonumber(p.y) or tonumber(p.blockY)
  local z = tonumber(p.z) or tonumber(p.blockZ)
  if not (x and y and z) then return nil end

  return { x = x, y = y, z = z }
end

--- Two angles out of whatever shape the mod handed back.
--
-- The base mod's gimbal sensor returns a Java List, which arrives in Lua as
-- { [1] = x, [2] = z }. The compatibility layer's data link returns a table with
-- names. Both are "the angles", so both are accepted rather than picking one and
-- making the other version of the addon a bug report.
local function angles(a)
  if type(a) ~= "table" then return nil, nil end
  local x = tonumber(a.x) or tonumber(a[1])
  local z = tonumber(a.z) or tonumber(a[2])
  return x, z
end

--- Fuel, thrust and lift, on their own clock.
--
-- These change slowly and cost several calls across every bearing on the hull,
-- and nothing in the control loop is a function of them -- only the bingo-fuel
-- guard, which is deciding whether to fly home in ten minutes. Reading them five
-- times a second alongside everything else would be the most expensive thing the
-- sweep does, for no gain at all.
local function readSlow(raw, now)
  if (now - hull.fuelAt) < config.heartbeat then
    raw.fuel     = hull.fuel.fuel
    raw.capacity = hull.fuel.capacity
    raw.burn     = hull.fuel.burn
    raw.thrust   = hull.fuel.thrust
    raw.lift     = hull.fuel.lift
    raw.pressure = hull.fuel.pressure
    return
  end
  hull.fuelAt = now

  local fuel, capacity, burn, thrust, lift

  local function total(v, add)
    if type(add) == "table" then
      for _, n in pairs(add) do
        if tonumber(n) then v = (v or 0) + tonumber(n) end
      end
    elseif tonumber(add) then
      v = (v or 0) + tonumber(add)
    end
    return v
  end

  -- Burn time is a **minimum**, not a sum. Every other number here is a fleet
  -- total, but the ship stops flying when the *first* engine runs dry, and an
  -- average across four tanks says everything is fine right up until it is not.
  local function soonest(v, add)
    if type(add) == "table" then
      for _, n in pairs(add) do
        n = tonumber(n)
        if n and (v == nil or n < v) then v = n end
      end
    else
      add = tonumber(add)
      if add and (v == nil or add < v) then v = add end
    end
    return v
  end

  for _, name in ipairs(hull.order) do
    local c = hull.controls[name]

    if c.kind == "bearing" then
      fuel     = total(fuel,     call(name, c.side, "getFuel", c.group))
      capacity = total(capacity, call(name, c.side, "getFuelCapacity", c.group))
      burn     = soonest(burn,   call(name, c.side, "getBurnTimeSeconds", c.group))
      thrust   = total(thrust,   call(name, c.side, "getTotalRealThrust"))
      lift     = total(lift,     call(name, c.side, "getTotalLiftCapacity"))

    elseif c.kind == "thruster" then
      fuel     = total(fuel,     call(name, c.side, "getFuel"))
      capacity = total(capacity, call(name, c.side, "getFuelCapacity"))
      burn     = soonest(burn,   call(name, c.side, "getBurnTimeSeconds"))
      thrust   = total(thrust,   call(name, c.side, "getRealThrust"))
      lift     = total(lift,     call(name, c.side, "getLiftCapacity"))
    end
  end

  -- Ambient pressure belongs on this clock rather than the sweep's. It changes
  -- with altitude and nothing else, it is a whole peripheral call, and it was
  -- being read five times a second and used by nothing at all.
  local pressure = nil
  local alt = hull.instruments.alt
  if alt then
    pressure = tonumber((call("alt", alt.side, "getAirPressure")))
  end

  hull.fuel = { fuel = fuel, capacity = capacity, burn = burn,
                thrust = thrust, lift = lift, pressure = pressure }

  raw.fuel, raw.capacity = fuel, capacity
  raw.burn, raw.thrust, raw.lift = burn, thrust, lift
  raw.pressure = pressure
end

--- Everything the instruments say, in one table, once per sweep.
--
-- Every field may be nil, and a nil means "this hull cannot tell you" rather
-- than "zero". lib/instruments.lua is what turns this into a fix; the difference
-- matters because an altitude of nil must fall through to another source and an
-- altitude of 0 is bedrock.
function hull.read(now)
  now = now or 0
  local raw = { at = now }
  local inst = hull.instruments

  if inst.nav then
    local p = call("nav", inst.nav.side, "getBlockPos")
    if p == nil then p = call("nav", inst.nav.side, "getTablePosition") end
    raw.pos = position(p)
    raw.heading = tonumber((call("nav", inst.nav.side, "getCurrentAngle")))
  end

  if inst.alt then
    -- getWorldHeight is the compatibility layer's name and getHeight is the base
    -- mod's. Asked rather than tried, so a hull with the older block does not
    -- record a fault on every sweep for a method it was never going to have.
    if has(inst.alt.side, "getWorldHeight") then
      raw.alt = tonumber((call("alt", inst.alt.side, "getWorldHeight")))
    else
      raw.alt = tonumber((call("alt", inst.alt.side, "getHeight")))
    end
  end

  if inst.vel then
    raw.speed = tonumber((call("vel", inst.vel.side, "getVelocity")))
  end

  if inst.gimbal then
    raw.pitch, raw.roll = angles(call("gimbal", inst.gimbal.side, "getAngles"))
    raw.tiltSource = "sensor"
  end

  -- A gimbal sensor read over plain redstone: four analogue faces, each powered
  -- in proportion to how far that side of the ship is leaning down.
  --
  -- Only consulted when the peripheral did not answer. The peripheral reports
  -- real angles; this reports sixteen steps of whatever the sensitivity panel is
  -- set to, and preferring the coarse reading over the exact one would be an odd
  -- thing to do to a hull that has both.
  if hull.tilt and (raw.pitch == nil or raw.roll == nil) then
    local t = hull.tilt
    local per = t.degrees / 15

    local function lean(axis)
      local side = t.faces[axis]
      if not side then return nil end
      return tonumber((wireCall("tilt", t.side, "getAnalogInput", side)))
    end

    local front, back = lean("front"), lean("back")
    local left, right = lean("left"), lean("right")

    -- Opposite faces are subtracted rather than taken one at a time, so a sensor
    -- leaking a signal on both faces at once reads as level rather than as a
    -- ship pitched hard in whichever direction happened to be checked first.
    if front or back then
      local pitch = ((front or 0) - (back or 0)) * per
      raw.pitch = t.invertPitch and -pitch or pitch
    end
    if left or right then
      local roll = ((right or 0) - (left or 0)) * per
      raw.roll = t.invertRoll and -roll or roll
    end

    raw.tiltSource = "redstone"
  end

  if inst.ground then
    -- Clearance is nil when the beam hit nothing, which is not the same as a
    -- clearance of zero and must never be allowed to become it -- a sensor that
    -- reads zero over a canyon would have the terrain guard climbing away from
    -- nothing at full power.
    if call("ground", inst.ground.side, "hasHit") == true then
      raw.clearance = tonumber((call("ground", inst.ground.side, "getDistance")))
      raw.ground    = call("ground", inst.ground.side, "getBlock")
    end
  end

  -- What is in front. Same nil-is-not-zero rule as the ground sensor, and it
  -- matters more here: a forward sensor that read zero when it saw nothing would
  -- have the obstacle guard stopping the ship dead in clear air.
  if inst.forward then
    if call("forward", inst.forward.side, "hasHit") == true then
      raw.ahead = tonumber((call("forward", inst.forward.side, "getDistance")))
      raw.aheadBlock = call("forward", inst.forward.side, "getBlock")
    end
  end

  -- The data link, which publishes where the ship is going so gyro-guided parts
  -- of the contraption can point at it. Read here; written by hull.setTarget
  -- when the leg changes, which is the only time it can have changed.
  if inst.link then
    raw.linked = call("link", inst.link.side, "isLinked") == true
  end

  if inst.dock then
    local docked = call("dock", inst.dock.side, "getConnectedName")
    if type(docked) == "string" and docked ~= "" then raw.docked = docked end
  end

  -- Homing: bearing from a directional link, range from a modulating
  -- one. Both are relative to the nearest matching link rather than to anywhere
  -- in the world.
  --
  -- **Reported, never navigated on.** getAngleToClosestLink is an angle, and
  -- nothing available from outside the game says whether it is measured from
  -- world north or from the receiver's own facing. Those two differ by the
  -- ship's heading, which is precisely the error that would send a ship
  -- confidently past its pad -- so it goes in the telemetry frame, where you can
  -- watch it against a known bearing and find out, and nothing steers on it
  -- until someone has.
  if inst.homing then
    raw.homing = tonumber((call("homing", inst.homing.side, "getClosestAngle")))
  end
  if inst.range then
    raw.homingRange = tonumber((call("range", inst.range.side, "getClosestDistance")))
  end

  if inst.swivel then
    raw.swivel = tonumber((call("swivel", inst.swivel.side, "getTargetAngle")))
  end

  if inst.stick then
    local tilt = call("stick", inst.stick.side, "getTilt")
    if type(tilt) == "table" then
      raw.stick = {
        x = tonumber(tilt.x) or 0,
        z = tonumber(tilt.z) or 0,
        magnitude = tonumber(tilt.magnitude) or 0,
        -- `active` can legitimately be false, so it is compared rather than
        -- defaulted. `a and a.b or c` on a false field is the bug this repo has
        -- already written twice.
        active = tilt.active == true,
        held   = tilt.held == true,
      }
    end
  end

  -- Named redstone inputs. One API call per side rather than one per signal:
  -- sixteen bundled colours on one cable is one read, not sixteen.
  if #hull.inputs > 0 then
    local cache = {}
    raw.signals = {}

    for _, s in ipairs(hull.inputs) do
      local key = (s.side or "*") .. ":" .. s.face .. ":" .. s.mode
      local wire = cache[key]

      if wire == nil then
        if s.mode == "analog" then
          wire = wireCall(s.name, s.side, "getAnalogInput", s.face)
        elseif s.mode == "bundled" then
          wire = wireCall(s.name, s.side, "getBundledInput", s.face)
        else
          wire = wireCall(s.name, s.side, "getInput", s.face)
        end
        cache[key] = wire
      end

      local value
      if s.mode == "bundled" then
        -- A mask is just a number, so this is arithmetic rather than
        -- colours.test or bit32 -- one less thing for the harness to provide.
        value = (math.floor((tonumber(wire) or 0) / s.colour) % 2 == 1)
      elseif s.mode == "analog" then
        value = tonumber(wire) or 0
      else
        value = wire == true
      end

      if s.invert then
        if type(value) == "number" then value = 15 - value else value = not value end
      end

      raw.signals[s.name] = value
    end

    hull.signals = raw.signals
  end

  readSlow(raw, now)

  raw.faults = {}
  for key, why in pairs(hull.faults) do
    raw.faults[#raw.faults + 1] = key .. ": " .. why
  end
  table.sort(raw.faults)

  return raw
end

--------------------------------------------------------------------------------
-- Writing
--------------------------------------------------------------------------------

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

--- Move `from` towards `to` by at most config.slew per second.
--
-- A PID that wants full lift this instant gets it over most of a second
-- instead. The physics does not care that the controller only meant it for one
-- sweep: a step from nothing to everything on a lift bearing is a ship launched
-- rather than a ship raised, and the overshoot that follows is the one the
-- integral clamp was supposed to prevent.
--------------------------------------------------------------------------------
-- Redstone
--------------------------------------------------------------------------------

--- What this wire is being driven to, as a level and as a boolean.
--
-- `invert` lives on the control rather than in every mix term that touches it.
-- A burner wired through a NOT gate should be fixed once, in the place that
-- describes the wiring.
local function wireValue(c)
  local held = hull.current[c.name]
  local signal = (held and tonumber(held.signal)) or 0

  local level = math.floor(signal * 15 + 0.5)
  if level < 0 then level = 0 end
  if level > 15 then level = 15 end

  local on = signal > 0.5

  if c.invert then
    level = 15 - level
    on = not on
  end

  return level, on
end

--- Push a whole face to the wire.
--
-- Recomputed from every control on the face rather than adjusted in place: a
-- bundled side is one number shared by up to sixteen controls, and writing one
-- colour without knowing the other fifteen turns them all off.
function emitFace(c)
  local group = hull.wires[(c.side or "*") .. ":" .. tostring(c.face)]
  if not group or not group[1] then return end

  local mode = group[1].mode

  if mode == "bundled" then
    local mask = 0
    for _, w in ipairs(group) do
      local _, on = wireValue(w)
      if on then mask = mask + w.colour end
    end
    wireCall(c.name, c.side, "setBundledOutput", c.face, mask)

  elseif mode == "analog" then
    local level = wireValue(group[1])
    wireCall(c.name, c.side, "setAnalogOutput", c.face, level)

  else
    local _, on = wireValue(group[1])
    wireCall(c.name, c.side, "setOutput", c.face, on)
  end
end

local function slew(from, to, dt)
  -- Nothing written yet counts as zero, not as "no limit". The very first
  -- demand after claiming the hull is the one most likely to be full lift --
  -- the altitude loop has a hundred blocks of error and no integral yet -- and
  -- letting that one through unlimited is the launch this function exists to
  -- prevent, on the one sweep where it matters most.
  if from == nil then from = 0 end
  local most = config.slew * (dt or config.sweep)
  if to > from + most then return from + most end
  if to < from - most then return from - most end
  return to
end

--- Write a batch of demands. Returns the list of writes actually made.
--
-- Anything that changes nothing is dropped, which is most of them: a ship
-- holding cruise is asking for the same throttle five times a second, and a
-- peripheral call per control per sweep for a value the mod already has is pure
-- server load.
--
-- `demands` is { [control] = { field = value } }. Fields the control does not
-- have are ignored rather than refused -- the mix is validated at load, and by
-- here a stray field means a control was swapped for one of another kind, which
-- is not worth failing a sweep over.
function hull.apply(demands, dt)
  local applied = {}

  for _, name in ipairs(hull.order) do
    local c    = hull.controls[name]
    local want = demands and demands[name]

    if want then
      hull.current[name] = hull.current[name] or {}
      local have = hull.current[name]
      local changed = false

      for _, field in ipairs(c.fields) do
        local value = want[field]

        if value ~= nil then
          if field == "throttle" or field == "left" or field == "right"
             or field == "brake" or field == "input" or field == "signal" then
            value = clamp(tonumber(value) or 0, 0, 1)
          elseif field == "pivot" or field == "angle" then
            local lo = (c.pivot and tonumber(c.pivot.min)) or -90
            local hi = (c.pivot and tonumber(c.pivot.max)) or  90
            value = clamp(tonumber(value) or 0, lo, hi)
          elseif field == "angleX" or field == "angleZ" then
            value = tonumber(value) or 0
          end

          -- An analogue signal is usually driving something proportional -- a
          -- throttle lever, a burner -- so it gets the same rate limit a
          -- throttle does. A digital or bundled one is a switch, and rate
          -- limiting a switch only means it turns on a fraction of a second late.
          if SLEWED[field] or (field == "signal" and c.mode == "analog") then
            value = slew(have[field], value, dt)
          end

          -- Redstone has sixteen levels and nothing in between, so the demand is
          -- rounded to one of them *before* the change test rather than after.
          -- A PID asking for 0.500 and then 0.503 is asking for signal 8 twice,
          -- and without this every sweep of a settled hover counts as a change
          -- and rewrites the wire.
          if field == "signal" then
            if c.mode == "analog" then
              value = math.floor(value * 15 + 0.5) / 15
            else
              value = (value > 0.5) and 1 or 0
            end
          end

          if have[field] ~= value then
            applied[#applied + 1] =
              { control = name, field = field, from = have[field], to = value }
            have[field] = value
            changed = true
          end
        end
      end

      -- A grip is a command rather than a position -- "close" is not a value the
      -- claw then holds, it is a thing to do -- so it is not diffed and asking
      -- twice does it twice.
      if want.grip ~= nil then changed = true end

      -- Nothing moved, so nothing is written. This is the common case by a long
      -- way: a ship holding cruise asks for the same throttle five times a
      -- second, and a peripheral call per control per sweep for a value the mod
      -- already has is pure server load.
      --
      -- Written per control rather than per field, because the two kinds that
      -- take more than one value take them in a single call and writing left
      -- without right would brake a wheel that was meant to be turning.
      local have2 = hull.current[name]

      if not changed then
        -- nothing to do

      elseif c.kind == "bearing" then
        if have2.throttle ~= nil then
          call(name, c.side, "setThrottle", c.group, have2.throttle)
        end
        if have2.pivot ~= nil then
          call(name, c.side, "setPivotAngle", have2.pivot)
        end

      elseif c.kind == "thruster" then
        if have2.enabled ~= nil then
          call(name, c.side, "setEnabled", have2.enabled and true or false)
        end
        if have2.throttle ~= nil then
          call(name, c.side, "setThrottle", have2.throttle)
        end

      elseif c.kind == "orientation" then
        if have2.angleX ~= nil or have2.angleZ ~= nil then
          call(name, c.side, "setAnglesDegrees",
               have2.angleX or 0, have2.angleZ or 0)
        end

      elseif c.kind == "wheels" then
        call(name, c.side, "setControls",
             have2.left or 0, have2.right or 0, have2.brake or 0)

      elseif c.kind == "input" then
        if c.input and have2.input ~= nil then
          call(name, c.side, "setInput", c.input, have2.input)
        end

      elseif c.kind == "grip" then
        local grip = want.grip
        if grip == "open" then call(name, c.side, "open")
        elseif grip == "close" then call(name, c.side, "close")
        elseif grip == "release" then call(name, c.side, "release") end

      elseif c.kind == "wire" then
        emitFace(c)

      elseif c.kind == "gearbox" then
        if have2.angle ~= nil then
          call(name, c.side, "setFaceAngle", c.face, have2.angle)
        end
      end
    end
  end

  return applied
end

--------------------------------------------------------------------------------
-- The data link
--------------------------------------------------------------------------------

--- Tell the hull where it is going.
--
-- An advanced data link broadcasts a target position to whatever on the
-- contraption is listening -- gyros, guided bearings, anything the builder wired
-- to it. Publishing the current leg means those parts aim at the same place the
-- autopilot is flying to, instead of at whatever was last set by hand.
--
-- Nothing here depends on it: a hull without the block is the common case and
-- this is a no-op. Returns true when it actually went somewhere.
function hull.setTarget(x, y, z)
  local link = hull.instruments.link
  if not link then return false end

  local _, failed = call("link", link.side, "setTarget", x, y, z)
  return not failed
end

function hull.clearTarget()
  local link = hull.instruments.link
  if not link then return false end

  local _, failed = call("link", link.side, "clearTarget")
  return not failed
end

--------------------------------------------------------------------------------
-- The nameplate
--------------------------------------------------------------------------------

--- What the nameplate on the hull says, or nil.
--
-- Not read every sweep: it is a name, and it changes when somebody changes it.
function hull.plateName()
  local plate = hull.instruments.plate
  if not plate then return nil end

  local name = call("plate", plate.side, "getName")
  if type(name) ~= "string" or name == "" then return nil end
  return name
end

--- Write the ship's name onto the nameplate.
--
-- The computer's label is the name everything else uses -- it survives updates,
-- reboots and being broken and replaced, and CC's own `label` program can read
-- it. The plate is the same name made visible from outside, which is the only
-- place it is any use while you are standing on the ground watching the thing
-- come in.
function hull.setPlateName(name)
  local plate = hull.instruments.plate
  if not plate then return false end

  local _, failed = call("plate", plate.side, "setName", tostring(name))
  return not failed
end

--------------------------------------------------------------------------------
-- Surviving a reboot
--------------------------------------------------------------------------------

--- Just the wire signals, for the state file.
--
-- Only wires. Every other control here is an override on a peripheral that keeps
-- its own state, and restoring a throttle from disk onto a bearing that has been
-- sitting idle would be the pilot's first sweep fighting a number it did not
-- choose. A redstone output is the one thing the *computer* was holding.
function hull.saved()
  local out = {}
  for _, name in ipairs(hull.order) do
    local c = hull.controls[name]
    if c.kind == "wire" then
      local held = hull.current[name]
      out[name] = (held and held.signal) or 0
    end
  end
  return out
end

--- Put the wires back the way they were before the reboot.
--
-- CC does **not** persist a computer's redstone outputs. They come back off
-- after a chunk unload or a server restart, exactly as they do in the redstone
-- network, which is why that program restores them from disk too.
--
-- On a balloon that is not a cosmetic problem. The burner goes out, the balloon
-- stops being told to hold its volume, and the ship sinks -- because a chunk
-- reloaded, which is a thing that happens every time you walk away. So this runs
-- at boot, before the listener starts, and the first telemetry frame is already
-- true.
function hull.restore(saved)
  if type(saved) ~= "table" then return 0 end

  local n, faces = 0, {}
  for name, signal in pairs(saved) do
    local c = hull.controls[name]
    if c and c.kind == "wire" then
      hull.current[name] = hull.current[name] or {}
      hull.current[name].signal = clamp(tonumber(signal) or 0, 0, 1)
      faces[c] = true
      n = n + 1
    end
  end

  -- One emit per control is one per *face* in effect, because emitFace rebuilds
  -- the whole face anyway -- but a bundled cable with four colours restored
  -- would otherwise be written four times before it was right once.
  local done = {}
  for c in pairs(faces) do
    local key = (c.side or "*") .. ":" .. tostring(c.face)
    if not done[key] then
      done[key] = true
      emitFace(c)
    end
  end

  return n
end

--------------------------------------------------------------------------------

--- A serialisable description, for the `hull?` reply. The pocket computer has no
--- /craft.cfg of its own -- it learns what this ship has by asking.
function hull.describe()
  local controls = {}
  for _, name in ipairs(hull.order) do
    local c = hull.controls[name]
    controls[#controls + 1] = {
      name  = c.name,
      label = c.label,
      kind  = c.kind,
      side  = c.side,
      group = c.group,
      face  = c.face,
      mode  = c.kind == "wire" and c.mode or nil,
      -- A `wire` on the flight computer's own bus has no peripheral at all and
      -- is still perfectly healthy, so this cannot simply be "we found one".
      ok    = (c.side ~= nil or c.kind == "wire") and hull.faults[name] == nil,
      value = hull.current[name],
    }
  end

  local instruments = {}
  for role, inst in pairs(hull.instruments) do
    instruments[role] = inst.kind or true
  end

  local signals = {}
  for _, s in ipairs(hull.inputs) do
    signals[#signals + 1] = { name = s.name, label = s.label, mode = s.mode,
                              face = s.face, value = hull.signals[s.name] }
  end

  return {
    name        = hull.name,
    controls    = controls,
    instruments = instruments,
    signals     = signals,
    limits      = hull.limits,
    gains       = hull.gains,
    problems    = hull.problems,
  }
end

return hull
