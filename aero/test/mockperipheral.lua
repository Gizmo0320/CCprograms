--- A mock hull, and a world for it to fly in.
--
-- There is no Create Aeronautics outside the game, and lib/hull.lua is the one
-- module here that touches `peripheral`. It reads the global at call time rather
-- than capturing it at load, which is what lets this file stand in for the mod.
--
-- Every method name below is from /rom/thrusters/docs.lua and the base mod's
-- peripheral classes. Where the mock is wrong about a name, the tests pass and
-- the ship does not fly, so the names matter more here than anywhere else in the
-- suite.
--
-- Two things live in this file, and the second is the reason for the first.
--
-- **Devices** record what was written to them, which is enough to test that
-- lib/hull drops no-op writes, slew-limits a throttle and hands control back on
-- release.
--
-- **A flight model** turns those writes into motion, which is the only way to
-- test an autopilot at all. A PID that does not settle looks exactly like one
-- that does when you are reading it, and asserting that `setThrottle` was called
-- with 0.63 asserts nothing about whether the ship arrives. So the devices are
-- wired to a simulated ship: throttle becomes thrust becomes acceleration
-- becomes position, the instruments read that position back, and fly_spec.lua
-- closes the loop and asks whether the thing actually flies.
--
--   local mock = require("test.mockperipheral")
--   local world = mock.new{ lift = "thruster_bearing_1", main = "thruster_bearing_0" }
--   _G.peripheral = world.api
--   world.step(0.2)                  -- advance the physics one sweep
--   world.ship.alt, world.ship.heading
--   world.device("thruster_bearing_1").writes

local mock = {}

--------------------------------------------------------------------------------
-- Conventions
--------------------------------------------------------------------------------

-- Heading is Minecraft yaw: degrees clockwise from +Z, so 0 is south, 90 is
-- west. The forward unit vector is therefore (-sin h, cos h). lib/nav.lua uses
-- the same convention and says so; if the two ever disagree the ship flies
-- confidently in the wrong direction, which is why both files spell it out.
local function forward(headingDeg)
  local h = math.rad(headingDeg)
  return -math.sin(h), math.cos(h)
end

local function norm360(d)
  d = d % 360
  if d < 0 then d = d + 360 end
  return d
end

--------------------------------------------------------------------------------

function mock.new(opts)
  opts = opts or {}

  local world = {}

  world.devices = {}    -- [side] = device
  world.order   = {}    -- attachment order, which peripheral.getNames returns

  -- Which controls the flight model listens to. A hull can have any number of
  -- bearings and the mock has no way to guess which one holds the ship up, so
  -- the test says.
  world.lift = opts.lift or "thruster_bearing_0"
  world.main = opts.main or nil
  world.trim = opts.trim or nil

  -- Which wheel mount drives the model, for something that drives rather than
  -- flies. Named `drive` rather than `wheels` because `world.wheels` is already
  -- the constructor that attaches one.
  world.drive = opts.drive or nil

  -- The ship ------------------------------------------------------------------

  world.ship = {
    x = opts.x or 0, y = opts.y or 64, z = opts.z or 0,
    heading = opts.heading or 0,
    speed = 0,          -- horizontal, blocks/second, always along `heading`
    vy = 0,             -- vertical, blocks/second
    pitch = 0, roll = 0,
    docked = nil,
  }

  -- The world -----------------------------------------------------------------

  -- Ground height under (x, z). Flat by default; a test that wants a hill for
  -- the terrain guard to notice replaces this with a function.
  world.terrain = opts.terrain or function() return 64 end

  -- Physics. These are not Create's numbers -- they are a hull that hovers at
  -- half throttle, which is the only property the control laws are tuned
  -- against and the only one that matters for asking whether a PID settles.
  world.gravity   = opts.gravity   or 8      -- blocks/s^2 down
  world.liftGain  = opts.liftGain  or 16     -- blocks/s^2 at full lift throttle
  world.thrustGain= opts.thrustGain or 10    -- blocks/s^2 at full main throttle
  world.dragH     = opts.dragH     or 0.35   -- per second, on horizontal speed
  world.dragV     = opts.dragV     or 0.5    -- per second, on vertical speed
  world.yawGain   = opts.yawGain   or 1.2    -- degrees/s per degree of pivot

  world.time = 0

  --------------------------------------------------------------------------------
  -- Devices
  --------------------------------------------------------------------------------

  --- Attach a device. `kind` is the peripheral type string the mod reports.
  function world.add(side, kind, device)
    device = device or {}
    device.side   = side
    device.kind   = kind
    device.writes = {}       -- [method] = number of calls
    device.last   = {}       -- [method] = the arguments of the last call

    world.devices[side] = device
    world.order[#world.order + 1] = side
    return device
  end

  function world.device(side) return world.devices[side] end

  --- Break a block off the hull.
  --
  -- Removed from the attachment order as well as the table, because that is what
  -- actually happens: a peripheral that has gone stops appearing in
  -- peripheral.getNames() rather than lingering there returning nil. Tests that
  -- only cleared the table were exercising a state the game cannot produce.
  function world.remove(side)
    world.devices[side] = nil
    for i, name in ipairs(world.order) do
      if name == side then table.remove(world.order, i) break end
    end
  end

  local function record(device, method, ...)
    device.writes[method] = (device.writes[method] or 0) + 1
    device.last[method] = { ... }
  end

  --------------------------------------------------------------------------------

  --- A thruster bearing: the workhorse, and the only actuator the flight model
  --- reads. `n` is how many thrusters hang off it, which only shows up in the
  --- fuel numbers and in listThrusters.
  function world.bearing(side, opts2)
    opts2 = opts2 or {}
    local d = world.add(side, "thruster_bearing", {
      throttle = 0,
      pivot    = 0,
      mode     = "redstone",
      count    = opts2.count or 4,
      fuel     = opts2.fuel or 8000,
      capacity = opts2.capacity or 8000,
      burn     = opts2.burn or 600,       -- seconds at full throttle
      override = false,
    })

    d.methods = {
      setBearingControlMode = function(mode)
        record(d, "setBearingControlMode", mode)
        d.mode = mode
      end,
      getBearingControlMode = function() return d.mode end,

      setThrottle = function(id, v)
        record(d, "setThrottle", id, v)
        d.throttle = tonumber(v) or 0
        d.override = true
      end,
      getThrottle = function() return d.throttle end,

      clearThrottleOverride = function(id)
        record(d, "clearThrottleOverride", id)
        d.override = false
        d.throttle = 0
      end,

      setPivotAngle = function(a)
        record(d, "setPivotAngle", a)
        d.pivot = tonumber(a) or 0
      end,
      getPivotAngle = function() return d.pivot end,
      clearPivotOverride = function()
        record(d, "clearPivotOverride")
        d.pivot = 0
      end,

      getThrusterCount = function() return d.count end,
      getFuel = function() return d.fuel end,
      getFuelCapacity = function() return d.capacity end,
      -- Burn time falls as the tank drains and as the throttle rises, which is
      -- what makes the bingo-fuel guard testable: fly for long enough and it
      -- fires on its own rather than being poked.
      getBurnTimeSeconds = function()
        local rate = math.max(0.05, d.throttle)
        return (d.fuel / math.max(1, d.capacity)) * d.burn / rate
      end,
      getTotalRealThrust = function() return d.throttle * d.count * 100 end,
      getTotalLiftCapacity = function() return d.count * 100 end,
      listThrusters = function()
        local out = {}
        for i = 1, d.count do out[tostring(i)] = { throttle = d.throttle } end
        return out
      end,
    }
    return d
  end

  --- A single thruster, for hulls that drive one directly.
  function world.thruster(side, opts2)
    opts2 = opts2 or {}
    local d = world.add(side, "thruster", {
      throttle = 0, enabled = false, mode = "redstone",
      fuel = opts2.fuel or 2000, capacity = opts2.capacity or 2000,
      burn = opts2.burn or 600,
    })

    d.methods = {
      setControlMode = function(m) record(d, "setControlMode", m); d.mode = m end,
      getControlMode = function() return d.mode end,
      setEnabled = function(v) record(d, "setEnabled", v); d.enabled = v and true or false end,
      isEnabled = function() return d.enabled end,
      setThrottle = function(v) record(d, "setThrottle", v); d.throttle = tonumber(v) or 0 end,
      getThrottle = function() return d.throttle end,
      clearThrottleOverride = function()
        record(d, "clearThrottleOverride"); d.throttle = 0
      end,
      getFuel = function() return d.fuel end,
      getFuelCapacity = function() return d.capacity end,
      getBurnTimeSeconds = function()
        return (d.fuel / math.max(1, d.capacity)) * d.burn
      end,
      getRealThrust = function() return d.throttle * 100 end,
      getLiftCapacity = function() return 100 end,
    }
    return d
  end

  --- The navigation table: position and heading, and the only reason this ship
  --- can navigate at all.
  function world.navTable(side, opts2)
    opts2 = opts2 or {}
    local d = world.add(side, "navigation_table", { available = true })

    -- `projected` comes back false with x/y/z missing when the sub-level a
    -- position refers to is not loaded. Setting d.available = false is how a
    -- test makes the fix go stale and watches lib/flight fall into loiter.
    local function pos()
      if not d.available then return { projected = false } end
      return {
        x = world.ship.x, y = world.ship.y, z = world.ship.z,
        blockX = math.floor(world.ship.x),
        blockY = math.floor(world.ship.y),
        blockZ = math.floor(world.ship.z),
        projected = true, subLevelId = "",
      }
    end

    d.methods = {
      getBlockPos = pos,
      getTablePosition = pos,
      getCurrentAngle = function()
        if not d.available then return nil end
        return world.ship.heading
      end,
      getState = function() return "idle" end,
      hasTarget = function() return false end,
      getSelectedSlot = function() return 1 end,
      getSlotCount = function() return 4 end,
    }
    return d
  end

  function world.altimeter(side)
    local d = world.add(side, "altitude_sensor", {})
    d.methods = {
      getWorldHeight = function() return world.ship.y end,
      getAirPressure = function() return 1 - world.ship.y / 512 end,
    }
    return d
  end

  --- The base mod's altimeter, which calls the same thing getHeight. Attached
  --- instead of `altimeter` by the case that checks lib/hull asks which one it
  --- has rather than calling both and swallowing an error every sweep.
  function world.altimeterLegacy(side)
    local d = world.add(side, "altitude_sensor", {})
    d.methods = {
      getHeight = function() return world.ship.y end,
      getAirPressure = function() return 1 - world.ship.y / 512 end,
    }
    return d
  end

  function world.velocimeter(side)
    local d = world.add(side, "velocity_sensor", {})
    -- The real sensor is a scalar with no direction, which is exactly why
    -- lib/instruments has to differentiate position to get a vector.
    d.methods = {
      getVelocity = function()
        local s = world.ship
        return math.sqrt(s.speed * s.speed + s.vy * s.vy)
      end,
    }
    return d
  end

  function world.gimbal(side)
    local d = world.add(side, "gimbal_sensor", {})
    -- Returns a Java List, which arrives in Lua as a 1-based array. lib/hull
    -- accepts both shapes; this is the shape the base mod actually sends.
    d.methods = {
      getAngles = function() return { world.ship.pitch, world.ship.roll } end,
      getAnglesRad = function()
        return { math.rad(world.ship.pitch), math.rad(world.ship.roll) }
      end,
    }
    return d
  end

  function world.optical(side, opts2)
    opts2 = opts2 or {}
    local d = world.add(side, "optical_sensor", { range = opts2.range or 16 })
    d.methods = {
      setRange = function(n) record(d, "setRange", n); d.range = tonumber(n) or d.range end,
      getRange = function() return d.range end,
      hasHit = function()
        return (world.ship.y - world.terrain(world.ship.x, world.ship.z)) <= d.range
      end,
      getDistance = function()
        return world.ship.y - world.terrain(world.ship.x, world.ship.z)
      end,
      getBlock = function() return "minecraft:stone" end,
    }
    return d
  end

  --- An optical sensor pointing at something that does not move.
  --
  -- What a beacon has: it looks up at a roof, or at nothing. Both the existing
  -- optical mocks raycast against the terrain from a ship, which is the wrong
  -- shape for a block standing still under a canopy.
  function world.opticalFixed(side, opts2)
    opts2 = opts2 or {}
    local d = world.add(side, "optical_sensor",
                        { range = opts2.range or 64, distance = opts2.distance })
    d.methods = {
      setRange = function(n) record(d, "setRange", n) d.range = tonumber(n) or d.range end,
      getRange = function() return d.range end,
      hasHit = function()
        return d.distance ~= nil and d.distance <= d.range
      end,
      getDistance = function() return d.distance or d.range end,
      getBlock = function() return "minecraft:oak_log" end,
    }
    return d
  end

  --- An optical sensor pointing along the ship's nose.
  --
  -- A real raycast against the terrain function: it steps forward until the
  -- ground is higher than the ship. That is what makes the obstacle guard
  -- testable at all -- a cliff face is exactly the thing the downward sensor
  -- cannot see, because the ground directly beneath the ship is fine right up
  -- until it is not.
  function world.forwardOptical(side, opts2)
    opts2 = opts2 or {}
    local d = world.add(side, "optical_sensor", { range = opts2.range or 64 })

    local function cast()
      local s = world.ship
      local fx, fz = forward(s.heading)
      local step = 1
      for distance = step, d.range, step do
        local x, z = s.x + fx * distance, s.z + fz * distance
        if world.terrain(x, z) > s.y then return distance end
      end
      return nil
    end

    d.methods = {
      setRange = function(n) record(d, "setRange", n); d.range = tonumber(n) or d.range end,
      getRange = function() return d.range end,
      hasHit = function() return cast() ~= nil end,
      getDistance = function() return cast() or d.range end,
      getBlock = function() return "minecraft:stone" end,
    }
    return d
  end

  function world.dockPort(side)
    local d = world.add(side, "docking_connector", {})
    d.methods = {
      getConnectedName = function() return world.ship.docked or "" end,
    }
    return d
  end

  function world.joystick(side)
    local d = world.add(side, "analogue_joystick",
      { tilt = { x = 0, z = 0, magnitude = 0, active = false, held = false } })
    d.methods = {
      getTilt = function() return d.tilt end,
      getX = function() return d.tilt.x end,
      getZ = function() return d.tilt.z end,
      isActive = function() return d.tilt.active end,
    }
    return d
  end

  --- A directional linked receiver: bearing to the nearest matching link.
  function world.beacon(side, opts2)
    local d = world.add(side, "directional_link", { angle = (opts2 or {}).angle or 0 })
    d.methods = {
      getClosestAngle = function() return d.angle end,
      getClosestAngleRad = function() return math.rad(d.angle) end,
    }
    return d
  end

  --- A modulating linked receiver: distance to the nearest matching link.
  function world.beaconRange(side, opts2)
    local d = world.add(side, "modulating_link", { distance = (opts2 or {}).distance or 0 })
    d.methods = { getClosestDistance = function() return d.distance end }
    return d
  end

  --- The ship's name on a block, readable from outside the hull.
  function world.plate(side, opts2)
    local d = world.add(side, "name_plate", { plateName = (opts2 or {}).name or "" })
    d.methods = {
      getName = function() return d.plateName end,
      setName = function(name) record(d, "setName", name); d.plateName = name end,
    }
    return d
  end

  function world.swivel(side, opts2)
    local d = world.add(side, "swivel_bearing", { angle = (opts2 or {}).angle or 0 })
    d.methods = {
      getTargetAngle = function() return d.angle end,
      getTargetAngleRad = function() return math.rad(d.angle) end,
    }
    return d
  end

  function world.orientation(side)
    local d = world.add(side, "virtual_orientation_source",
      { active = false, x = 0, z = 0 })
    d.methods = {
      setAnglesDegrees = function(x, z)
        record(d, "setAnglesDegrees", x, z)
        d.x, d.z, d.active = tonumber(x) or 0, tonumber(z) or 0, true
      end,
      clear = function() record(d, "clear"); d.active = false; d.x, d.z = 0, 0 end,
      isActive = function() return d.active end,
      getState = function()
        return { active = d.active, angles = { x = d.x, z = d.z } }
      end,
    }
    return d
  end

  function world.wheels(side)
    local d = world.add(side, "wheel_mount", { left = 0, right = 0, brake = 0 })
    d.methods = {
      setControls = function(l, r, b)
        record(d, "setControls", l, r, b)
        d.left, d.right, d.brake = tonumber(l) or 0, tonumber(r) or 0, tonumber(b) or 0
      end,
      clearControls = function()
        record(d, "clearControls"); d.left, d.right, d.brake = 0, 0, 0
      end,
      getStatus = function()
        return { left = d.left, right = d.right, brake = d.brake }
      end,
    }
    return d
  end

  --------------------------------------------------------------------------------
  -- Redstone
  --------------------------------------------------------------------------------

  --- A redstone bus: the six sides of one computer or one relay.
  --
  -- Deliberately dumber than the real thing in one direction and sharper in
  -- another. Dumber: a side holds whatever was last written, with no notion of a
  -- block on the other end. Sharper: every write is counted per side, because "a
  -- bundled cable is written once however many colours changed" is a property
  -- worth asserting and is invisible from the values alone.
  local function bus()
    local b = { input = {}, output = {}, writes = {}, reads = {} }

    local function read(side)
      b.reads[side] = (b.reads[side] or 0) + 1
      return b.input[side]
    end

    local function write(side, value)
      b.writes[side] = (b.writes[side] or 0) + 1
      b.output[side] = value
    end

    -- Each returns what the real API returns -- a boolean from getInput and a
    -- number from the other two -- so lib/hull has to do the same conversions it
    -- does in game. Both spellings, because CC provides both and a program that
    -- only had one would work until somebody's script called the other.
    b.api = {
      getSides = function()
        return { "top", "bottom", "left", "right", "front", "back" }
      end,

      getInput = function(side)
        local v = read(side)
        if type(v) == "number" then return v > 0 end
        return v == true
      end,
      getAnalogInput = function(side)
        local v = read(side)
        if type(v) == "boolean" then return v and 15 or 0 end
        return math.floor(tonumber(v) or 0)
      end,
      getBundledInput = function(side)
        local v = read(side)
        if type(v) == "boolean" then return v and 65535 or 0 end
        return math.floor(tonumber(v) or 0)
      end,

      setOutput = function(side, v) write(side, v == true) end,
      setAnalogOutput = function(side, v)
        write(side, math.max(0, math.min(15, math.floor(tonumber(v) or 0))))
      end,
      setBundledOutput = function(side, mask)
        write(side, math.floor(tonumber(mask) or 0))
      end,

      getOutput = function(side) return b.output[side] == true end,
      getAnalogOutput = function(side) return math.floor(tonumber(b.output[side]) or 0) end,
      getBundledOutput = function(side) return math.floor(tonumber(b.output[side]) or 0) end,

      testBundledInput = function(side, colour)
        return math.floor(b.api.getBundledInput(side) / colour) % 2 == 1
      end,
    }

    b.api.getAnalogueInput  = b.api.getAnalogInput
    b.api.getAnalogueOutput = b.api.getAnalogOutput
    b.api.setAnalogueOutput = b.api.setAnalogOutput

    return b
  end

  --- The flight computer's own six sides, for `_G.redstone`.
  world.redstone = bus()

  --------------------------------------------------------------------------------
  -- Balloons
  --------------------------------------------------------------------------------

  -- A hot air burner or a steam vent, as the wiki describes them: powered by
  -- redstone, and "the maximum volume scales linearly with received redstone
  -- signal strength". So the signal sets a **target volume** and the balloon
  -- fills towards it gradually -- which makes this a far slower and more
  -- integrating plant than a thruster, and the reason it is worth simulating
  -- separately rather than pretending a burner is a bearing with a wire on it.
  --
  --   world.balloon{ side = "top", volume = 500, fill = 60 }
  --
  -- Lift is proportional to the volume actually in the envelope, not to the
  -- signal, so a ship told to climb keeps climbing for a while after the signal
  -- comes back down. An autopilot tuned for a thruster will oscillate on this,
  -- which is exactly what the test suite is for.
  world.balloons = {}

  function world.balloon(opts2)
    opts2 = opts2 or {}
    local b = {
      relay  = opts2.peripheral,        -- nil for the computer's own bus
      side   = opts2.side or "top",
      max    = opts2.volume or 500,     -- m3 at signal 15, the panel setting
      fill   = opts2.fill or 60,        -- m3 per second it can move
      volume = opts2.start or 0,
      -- How much lift a cubic metre is worth, as an acceleration. Chosen by
      -- default so that half the maximum volume exactly cancels gravity, which
      -- makes "hover at signal 8" true and gives the gains something sane to be
      -- tuned against.
      per    = opts2.per or (world.gravity / ((opts2.volume or 500) / 2)),
    }
    world.balloons[#world.balloons + 1] = b
    return b
  end

  --------------------------------------------------------------------------------
  -- CC: Sable
  --------------------------------------------------------------------------------

  -- `sublevel` and `aero` are globals rather than peripherals, so they are
  -- installed separately from world.api. Everything is driven off world.ship, so
  -- a test that tilts the ship tilts what the physics engine reports too.
  --
  --   world.sable{ assembled = true }
  --   _G.sublevel, _G.aero = world.sublevel, world.aero
  --
  -- The orientation is built from the ship's pitch, roll and heading rather than
  -- stored, which is the only way the quaternion the code reads and the angles
  -- the test sets can be guaranteed to agree.
  function world.sable(opts2)
    opts2 = opts2 or {}
    world.assembled = opts2.assembled ~= false
    world.mass = opts2.mass or 12000
    world.spin = opts2.spin or { x = 0, y = 0, z = 0 }

    local function check()
      if not world.assembled then
        error("This computer is not on a Sub-Level!", 0)
      end
    end

    --- Ship angles to a quaternion, the way the physics engine would hold them.
    --
    -- Yaw about Y, then pitch about X, then roll about Z, composed in that
    -- order -- which is what lib/sable.attitude has to invert. Written out
    -- longhand rather than borrowed from a library so that a disagreement
    -- between the two is a test failure and not a shared mistake.
    local function orientation()
      local s = world.ship
      local hy, hp, hr = math.rad(-s.heading) / 2, math.rad(-(s.pitch or 0)) / 2,
                         math.rad(-(s.roll or 0)) / 2

      local cy, sy = math.cos(hy), math.sin(hy)
      local cp, sp = math.cos(hp), math.sin(hp)
      local cr, sr = math.cos(hr), math.sin(hr)

      -- q = qYaw * qPitch * qRoll, with qYaw = (0, sy, 0, cy),
      -- qPitch = (sp, 0, 0, cp) and qRoll = (0, 0, sr, cr).
      local x = cy * sp * cr + sy * cp * sr
      local y = sy * cp * cr - cy * sp * sr
      local z = cy * cp * sr - sy * sp * cr
      local w = cy * cp * cr + sy * sp * sr
      return { x = x, y = y, z = z, w = w }
    end

    local function velocity()
      local s = world.ship
      local fx, fz = forward(s.heading)
      return { x = fx * s.speed, y = s.vy, z = fz * s.speed }
    end

    world.sublevel = {
      isInPlotGrid = function() return world.assembled end,
      getUniqueId = function() check() return "0000-mock" end,
      getName = function() check() return world.shipName or "" end,
      setName = function(n) check() world.shipName = n end,
      getLogicalPose = function()
        check()
        return {
          position = { x = world.ship.x, y = world.ship.y, z = world.ship.z },
          orientation = orientation(),
          scale = { x = 1, y = 1, z = 1 },
          rotationPoint = { x = 0, y = 0, z = 0 },
        }
      end,
      getLastPose = function() check() return world.sublevel.getLogicalPose() end,
      getVelocity = function() return velocity() end,
      getLinearVelocity = function() check() return velocity() end,
      -- Radians per second, as the physics engine reports it. lib/sable converts;
      -- a mock that handed back degrees would hide the conversion being wrong.
      getAngularVelocity = function()
        check()
        return { x = math.rad(world.spin.x or 0),
                 y = math.rad(world.spin.y or 0),
                 z = math.rad(world.spin.z or 0) }
      end,
      getCenterOfMass = function() check() return { x = 0, y = 0, z = 0 } end,
      getMass = function() check() return world.mass end,
      getInverseMass = function() check() return 1 / world.mass end,
    }

    world.aero = {
      getAirPressure = function(x, y, z) return 1 - (y or 64) / 512 end,
      getGravity = function() return { x = 0, y = -world.gravity, z = 0 } end,
      getMagneticNorth = function() return { x = 0, y = 0, z = -1 } end,
      getUniversalDrag = function() return world.dragH end,
    }

    return world.sublevel
  end

  --- A gimbal sensor wired as redstone rather than read as a peripheral.
  --
  -- The block "outputs redstone signals based on which side is leaning
  -- downwards", with an adjustable sensitivity per axis. So it powers the face
  -- of whichever side is low, in proportion, and the two opposite faces are
  -- never both powered.
  --
  --   world.tiltWire{ front = "front", back = "back", degrees = 30 }
  --
  -- Then set world.ship.pitch and the inputs follow.
  function world.tiltWire(opts2)
    world.tilt = opts2 or {}
    world.tilt.degrees = world.tilt.degrees or 30
    world.updateTilt()
    return world.tilt
  end

  function world.updateTilt()
    local t = world.tilt
    if not t then return end

    local target = t.peripheral and world.devices[t.peripheral]
    local input = target and target.input or world.redstone.input

    local function put(side, degrees)
      if not side then return end
      local level = math.floor(math.abs(degrees) / t.degrees * 15 + 0.5)
      input[side] = math.max(0, math.min(15, level))
    end

    -- Positive pitch is nose down, positive roll is right side down -- the same
    -- convention lib/hull reads them back with. Only the low side is powered.
    put(t.front, world.ship.pitch > 0 and world.ship.pitch or 0)
    put(t.back,  world.ship.pitch < 0 and world.ship.pitch or 0)
    put(t.right, world.ship.roll  > 0 and world.ship.roll  or 0)
    put(t.left,  world.ship.roll  < 0 and world.ship.roll  or 0)
  end

  --- The signal a balloon is seeing, 0-15.
  local function balloonSignal(b)
    local out
    if b.relay then
      local d = world.devices[b.relay]
      out = d and d.output[b.side]
    else
      out = world.redstone.output[b.side]
    end
    if type(out) == "boolean" then return out and 15 or 0 end
    return math.floor(tonumber(out) or 0)
  end

  --- A redstone relay: the identical API, on the end of a wired modem.
  --
  -- Identical is the point. lib/hull drives a relay and its own bus through one
  -- code path, so a burner moved onto a relay is one line in /craft.cfg rather
  -- than a different control kind -- and this mock has to be the same shape or
  -- the tests would not be testing that.
  function world.relay(side)
    local b = bus()
    local d = world.add(side, "redstone_relay", { bus = b })
    d.methods = b.api
    -- Named for what they are rather than folded into the device's own `writes`,
    -- which counts method calls. On a relay the interesting count is per side:
    -- one write for a whole bundled cable, however many colours moved.
    d.input, d.output, d.sideWrites = b.input, b.output, b.writes
    return d
  end

  --- A claw, which holds cargo and is deliberately never released on exit.
  function world.claw(side)
    local d = world.add(side, "claw", { signal = 0, holding = false })
    d.methods = {
      open = function() record(d, "open") d.holding = false end,
      close = function() record(d, "close") d.holding = true end,
      release = function() record(d, "release") d.holding = false end,
      setSignal = function(v) record(d, "setSignal", v) d.signal = tonumber(v) or 0 end,
      clearSignalOverride = function() record(d, "clearSignalOverride") end,
      getSignal = function() return d.signal end,
      isHolding = function() return d.holding end,
      getStatus = function() return { holding = d.holding, signal = d.signal } end,
    }
    return d
  end

  --- The analogue contraption controller: named input channels a program drives
  --- in place of a player pressing a key.
  function world.controller(side, opts2)
    opts2 = opts2 or {}
    local d = world.add(side, "analogue_contraption_controller",
                        { inputs = {}, ids = opts2.ids or { "throttle", "brake" } })
    for _, id in ipairs(d.ids) do d.inputs[id] = 0 end

    d.methods = {
      listInputIds = function() return d.ids end,
      setInput = function(id, v)
        record(d, "setInput", id, v)
        d.inputs[id] = tonumber(v) or 0
      end,
      getInputValue = function(id) return d.inputs[id] end,
      resetInput = function(id) record(d, "resetInput", id) d.inputs[id] = 0 end,
      resetAll = function() record(d, "resetAll") for k in pairs(d.inputs) do d.inputs[k] = 0 end end,
    }
    return d
  end

  --- A bidirectional gearbox, one servo angle per compass face.
  function world.gearbox(side)
    local d = world.add(side, "bidirectional_gearbox",
                        { angles = {}, mode = "auto" })
    d.methods = {
      setFaceAngle = function(face, angle)
        record(d, "setFaceAngle", face, angle)
        d.angles[face] = tonumber(angle) or 0
      end,
      getFaceAngle = function(face) return d.angles[face] end,
      clearFaceAngle = function(face)
        record(d, "clearFaceAngle", face)
        d.angles[face] = nil
      end,
      getMode = function() return d.mode end,
      setMode = function(m) record(d, "setMode", m) d.mode = m end,
      getStatus = function() return { mode = d.mode } end,
    }
    return d
  end

  --- An advanced data link: where the ship has been told to point.
  function world.dataLink(side)
    local d = world.add(side, "advanced_data_link",
                        { target = nil, linked = true, mode = "live" })
    d.methods = {
      isLinked = function() return d.linked end,
      getTarget = function() return d.target end,
      setTarget = function(x, y, z)
        record(d, "setTarget", x, y, z)
        d.target = { x = x, y = y, z = z }
      end,
      clearTarget = function() record(d, "clearTarget") d.target = nil end,
      getMode = function() return d.mode end,
      setMode = function(m) d.mode = m end,
    }
    return d
  end

  --- A wireless modem, so net.open finds something. Messages go into `sent`
  --- rather than anywhere, which is what the program suites read the wire from.
  function world.modem(side)
    local d = world.add(side, "modem", { open = {}, sent = {} })
    d.methods = {
      isWireless = function() return true end,
      open = function(ch) d.open[ch] = true end,
      close = function(ch) d.open[ch] = nil end,
      isOpen = function(ch) return d.open[ch] == true end,
      transmit = function(ch, reply, frame)
        d.sent[#d.sent + 1] = { channel = ch, reply = reply, frame = frame }
      end,
    }
    return d
  end

  --------------------------------------------------------------------------------
  -- The peripheral API
  --------------------------------------------------------------------------------

  world.api = {
    getNames = function()
      local out = {}
      for i, side in ipairs(world.order) do out[i] = side end
      return out
    end,

    isPresent = function(side) return world.devices[side] ~= nil end,

    getType = function(side)
      local d = world.devices[side]
      return d and d.kind or nil
    end,

    getMethods = function(side)
      local d = world.devices[side]
      if not d then return nil end
      local out = {}
      for name in pairs(d.methods) do out[#out + 1] = name end
      table.sort(out)
      return out
    end,

    -- Throws on a missing peripheral or a missing method, exactly as CC does.
    -- lib/hull pcalls every one of these, and a mock that returned nil instead
    -- would let a hull that crashes in game pass here.
    call = function(side, method, ...)
      local d = world.devices[side]
      if not d then error("no peripheral attached to " .. tostring(side), 0) end
      local fn = d.methods[method]
      if not fn then
        error("No such method " .. tostring(method), 0)
      end
      return fn(...)
    end,

    wrap = function(side)
      local d = world.devices[side]
      if not d then return nil end
      local t = {}
      for name, fn in pairs(d.methods) do t[name] = fn end
      return t
    end,

    find = function(kind)
      for _, side in ipairs(world.order) do
        if world.devices[side].kind == kind then return world.api.wrap(side) end
      end
      return nil
    end,
  }

  --------------------------------------------------------------------------------
  -- The flight model
  --------------------------------------------------------------------------------

  local function throttleOf(side)
    local d = side and world.devices[side]
    if not d then return 0 end
    if d.override == false then return 0 end
    return d.throttle or 0
  end

  --- Advance the ship by dt seconds.
  --
  -- Deliberately the simplest model that has the properties the control laws
  -- care about: thrust is proportional to throttle, drag is proportional to
  -- speed, and nothing is instant. That gives it the two behaviours a PID can
  -- get wrong -- lag, so a proportional-only loop oscillates, and momentum, so
  -- an unclamped integral overshoots -- without pretending to be Create.
  function world.step(dt)
    dt = dt or 0.2
    world.time = world.time + dt
    local s = world.ship

    -- Vertical. Hovers at half lift throttle, by construction of the defaults.
    local up = throttleOf(world.lift) * world.liftGain

    -- Balloons add to it. The signal sets a target volume and the envelope
    -- fills towards it at a finite rate, so the lift lags the command by
    -- several seconds in both directions -- which is the whole character of the
    -- plant and the thing an autopilot has to be tuned for.
    for _, b in ipairs(world.balloons) do
      local target = balloonSignal(b) / 15 * b.max
      local step = b.fill * dt
      if target > b.volume then
        b.volume = math.min(target, b.volume + step)
      else
        b.volume = math.max(target, b.volume - step)
      end
      up = up + b.volume * b.per
    end

    s.vy = s.vy + (up - world.gravity) * dt
    s.vy = s.vy - s.vy * world.dragV * dt
    s.y  = s.y + s.vy * dt

    -- Horizontal. A hull with no main bearing named still turns and still
    -- holds altitude; it simply never goes anywhere, which is a balloon.
    local push = world.main and throttleOf(world.main) * world.thrustGain or 0

    -- ...or wheels, for something that drives rather than flies. Averaged
    -- because a wheel mount takes a left and a right and both push forward;
    -- steering by driving them at different rates is a thing the model does not
    -- pretend to do.
    if world.drive then
      local d = world.devices[world.drive]
      if d then
        push = push + ((d.left or 0) + (d.right or 0)) / 2 * world.thrustGain
        if (d.brake or 0) > 0 then
          s.speed = s.speed * (1 - math.min(1, d.brake))
        end
      end
    end
    s.speed = s.speed + push * dt
    s.speed = s.speed - s.speed * world.dragH * dt

    -- Yaw comes from the main bearing's pivot: the thrust is vectored, so the
    -- ship turns while it is pushing and does not turn when it is not.
    local main = world.main and world.devices[world.main]
    if main and main.pivot then
      local authority = math.min(1, math.abs(s.speed) / 4)
      s.heading = norm360(s.heading + main.pivot * world.yawGain * authority * dt)
    end

    local fx, fz = forward(s.heading)
    s.x = s.x + fx * s.speed * dt
    s.z = s.z + fz * s.speed * dt

    -- The ground. Contact stops the descent and kills forward speed, which is
    -- as much of a landing as anything here needs to model.
    local ground = world.terrain(s.x, s.z)
    if s.y <= ground then
      s.y = ground
      if s.vy < 0 then s.vy = 0 end
      s.speed = s.speed * 0.5
    end

    world.updateTilt()

    -- Fuel. Burned in proportion to throttle so a long flight actually runs the
    -- tanks down and the bingo guard has something real to fire on.
    for _, side in ipairs(world.order) do
      local d = world.devices[side]
      if d.kind == "thruster_bearing" or d.kind == "thruster" then
        local burned = (d.throttle or 0) * (d.count or 1) * dt
        d.fuel = math.max(0, (d.fuel or 0) - burned)
      end
    end
  end

  --- Run n sweeps, calling `each` between them. The shape every closed-loop
  --- case has: fly the thing for a while, then ask where it ended up.
  function world.fly(n, dt, each)
    for i = 1, n do
      if each then each(i) end
      world.step(dt)
    end
  end

  return world
end

return mock
