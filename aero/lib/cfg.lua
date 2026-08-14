--- The configuration files, and whether this computer has a usable one.
--
-- Three files describe a computer on this network, and until now three separate
-- programs wrote them and four separate programs decided whether they were any
-- good. `install.lua` wrote /aero.cfg one way, `configure.lua` wrote it another,
-- `probe.lua` wrote /craft.cfg in a third style, `beacon.lua` owned /beacon.cfg,
-- and every one of them had its own opinion about what counted as broken. So a
-- ship could pass `setup` and fail to fly, and the configurator's front page
-- could report a clean configuration that `lib/hull.lua` refused.
--
-- This is the one place that reads them, the one place that writes them, and the
-- one place that says what is wrong with them. Everything else asks here.
--
--   cfg.network()                    what /aero.cfg says, over the defaults
--   cfg.craft()                      /craft.cfg, or nil
--   cfg.beacon()                     /beacon.cfg, or nil
--   cfg.writeNetwork(n)              the only writers
--   cfg.writeCraft(craft)
--   cfg.writeBeacon(b)
--   cfg.check(role, opts)            everything wrong, worst first
--   cfg.blocking(problems)           does any of it stop the program running
--
-- ## What gates a boot, and what merely gets reported
--
-- The distinction this module exists to make, and the one that is easy to get
-- catastrophically wrong.
--
-- **Configuration gates. Hardware never does.** A pilot with no /craft.cfg
-- cannot fly and should be sent to the configurator. A pilot whose /craft.cfg is
-- perfect but whose navigation table is missing must boot anyway -- because
-- assembling a contraption is what attaches its peripherals, so *every* ship is
-- in that state until the moment it is assembled, and `hull.remount` exists
-- precisely to pick them up when they appear. A gate on attached hardware would
-- trap every ship in the world at a configuration screen it has no way to
-- satisfy, and would strand a chunk-reloaded ship that was flying a minute ago.
--
-- So missing hardware is a `warn` here however required it is, and only the
-- files can produce a `bad`.

local config = require("lib.config")
local needs  = require("lib.needs")

local cfg = {}

--------------------------------------------------------------------------------
-- What the defaults are
--------------------------------------------------------------------------------

-- Named here as well as in lib/config.lua because this module has to be able to
-- tell "the same as the default" from "explicitly set to the same value", which
-- is the difference between a computer nobody has configured and one somebody
-- configured to the ordinary settings.
cfg.DEFAULT_PROTOCOL = "aero"
cfg.DEFAULT_CHANNEL  = 1618
cfg.DEFAULT_ROLE     = "pilot"

cfg.ROLES = { "pilot", "server", "beacon", "remote" }

--- The other names people reasonably use for a role.
local ALIAS = {
  tower = "server", base = "server", ground = "server",
  ship = "pilot", craft = "pilot", flight = "pilot",
  waypoint = "beacon", marker = "beacon",
  pocket = "remote", handheld = "remote",
}

function cfg.role(name)
  name = tostring(name or ""):lower():gsub("%s", "")
  name = ALIAS[name] or name
  for _, known in ipairs(cfg.ROLES) do
    if name == known then return name end
  end
  return nil
end

--- The instrument roles a hull can name, in the order they matter.
--
-- Shared by the configurator's instrument pane, the craft-file writer and the
-- generator, so a role cannot exist in one and be silently dropped by another --
-- which is how `homing` and `range` ended up written by `probe` into files the
-- configurator would then quietly delete on the next save.
cfg.instruments = {
  { role = "nav",     kind = "navigation_table",  what = "position and heading",
    tier = "required" },
  { role = "alt",     kind = "altitude_sensor",   what = "height",
    tier = "required" },
  { role = "ground",  kind = "optical_sensor",    what = "clearance below",
    tier = "recommended" },
  { role = "forward", kind = "optical_sensor",    what = "what is ahead",
    tier = "recommended" },
  { role = "vel",     kind = "velocity_sensor",   what = "speed",
    tier = "optional" },
  { role = "gimbal",  kind = "gimbal_sensor",     what = "pitch and roll",
    tier = "optional" },
  { role = "dock",    kind = "docking_connector", what = "docking",
    tier = "optional" },
  { role = "stick",   kind = "analogue_joystick", what = "taking control by hand",
    tier = "optional" },
  { role = "link",    kind = "advanced_data_link", what = "publishing the leg",
    tier = "optional" },
  { role = "homing",  kind = "directional_link",  what = "bearing to a link",
    tier = "optional" },
  { role = "range",   kind = "modulating_link",   what = "distance to a link",
    tier = "optional" },
  { role = "plate",   kind = "name_plate",        what = "the ship's own name",
    tier = "optional" },
  { role = "swivel",  kind = "swivel_bearing",    what = "a steerable mount",
    tier = "optional" },
}

--------------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------------

--- Load a Lua file that returns a table.
--
-- Never throws, and says *why* rather than just failing. A malformed craft file
-- reported as "no craft file" sends somebody looking for a file that is sitting
-- right there.
function cfg.readLua(path)
  if not fs or not fs.exists(path) then return nil, "missing" end

  local fn, err = loadfile(path)
  if not fn then return nil, tostring(err) end

  local ok, value = pcall(fn)
  if not ok then return nil, tostring(value) end
  if type(value) ~= "table" then return nil, "did not return a table" end

  return value
end

--- What /aero.cfg says, with the defaults filled in underneath.
function cfg.network()
  local raw = cfg.readLua(config.overridesFile) or {}
  return {
    protocol   = type(raw.protocol) == "string" and raw.protocol
                 or cfg.DEFAULT_PROTOCOL,
    channel    = tonumber(raw.channel) or cfg.DEFAULT_CHANNEL,
    role       = cfg.role(raw.role) or cfg.DEFAULT_ROLE,
    name       = os.getComputerLabel() or "",
    configured = raw.configured,
  }
end

function cfg.craft()  return cfg.readLua(config.craftFile) end
function cfg.beacon() return cfg.readLua(config.beaconFile) end

--- Has anybody actually set this computer up?
--
-- The stamp is what makes a first run distinguishable from a run where
-- everything happens to be at its defaults, which used to be indistinguishable:
-- both older installers *deleted* /aero.cfg when nothing differed from the
-- defaults, on the reasonable-sounding grounds that a plain setup should leave
-- nothing extra to explain. The cost was that a fresh computer and a deliberately
-- ordinary one looked identical, so nothing could decide whether to run the
-- wizard.
--
-- Returns the version it was configured at, or nil.
--
-- Deliberately **not** compared against the current version. cc-mek-scada
-- re-asks when its config version moves, which is right for a reactor that is
-- not going anywhere; here it would drop every ship in the fleet into a
-- configuration screen on the next `update`, and a pilot sitting at a menu is a
-- pilot not holding anything up.
function cfg.configured()
  local n = cfg.network()
  return type(n.configured) == "string" and n.configured or nil
end

--- Which role this computer should be, taking the hardware's word where it is
--- decisive. A pocket computer is the remote and there is nothing to discuss.
function cfg.roleHere()
  if pocket then return "remote" end
  return cfg.network().role
end

--- Everything attached, as { [kind] = { side, ... } }.
--
-- Wireless and wired modems are separated here rather than by every caller,
-- because "a modem is attached" is the single most misleading thing this can
-- report: a wired modem satisfies none of the reasons any role wants one.
function cfg.attached()
  local out = {}
  if not peripheral then return out end

  local ok, names = pcall(peripheral.getNames)
  if not ok then return out end

  for _, side in ipairs(names) do
    local okType, kind = pcall(peripheral.getType, side)
    if okType and kind then
      if kind == "modem" then
        local okW, wireless = pcall(peripheral.call, side, "isWireless")
        if not (okW and wireless) then kind = "wired_modem" end
      end
      out[kind] = out[kind] or {}
      table.insert(out[kind], side)
    end
  end
  return out
end

--- The same thing in the shape lib/needs wants.
function cfg.found(attached)
  local out = {}
  for kind, sides in pairs(attached or {}) do
    for _ = 1, #sides do
      if kind == "wired_modem" then
        out[#out + 1] = { type = "modem", wireless = false }
      elseif kind == "modem" then
        out[#out + 1] = { type = "modem", wireless = true }
      else
        out[#out + 1] = { type = kind }
      end
    end
  end
  return out
end

--------------------------------------------------------------------------------
-- Writing
--------------------------------------------------------------------------------

local function quoted(v)
  if type(v) == "string" then return ("%q"):format(v) end
  return tostring(v)
end

--- Write a file by writing beside it and moving into place.
--
-- The same rule the installer follows, for the same reason: a configuration
-- half-written because the chunk unloaded mid-save is worse than an old one,
-- and on a pilot it is a hull definition with one bearing in it.
local function put(path, lines)
  local tmp = path .. ".part"
  local f = fs.open(tmp, "w")
  if not f then return false, "cannot write " .. tmp end

  for _, line in ipairs(lines) do f.writeLine(line) end
  f.close()

  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp, path)
  return true
end

function cfg.writeNetwork(n)
  local lines = {
    "-- What this computer is, and which network it is on.",
    "--",
    "-- Written by `configure`. Not in manifest.txt, so `update` never replaces",
    "-- it. Anything here overrides the defaults in lib/config.lua, and you may",
    "-- edit it by hand -- it is an ordinary Lua file returning a table.",
    "--",
    "-- `configured` is the version this was last set up at. Its presence is how",
    "-- startup.lua tells a computer somebody has configured from a fresh one",
    "-- that happens to want the ordinary settings; delete it to be asked again.",
    "",
    "return {",
    ("  protocol   = %s,"):format(quoted(n.protocol or cfg.DEFAULT_PROTOCOL)),
    ("  channel    = %d,"):format(tonumber(n.channel) or cfg.DEFAULT_CHANNEL),
    ("  role       = %s,"):format(quoted(cfg.role(n.role) or cfg.DEFAULT_ROLE)),
    -- Always the current version, not whatever was there before. The stamp
    -- answers "when was this last set up", and carrying an old one forward
    -- through a re-configuration would make it answer a different question.
    ("  configured = %s,"):format(quoted(config.version)),
    "}",
  }

  local ok, why = put(config.overridesFile, lines)
  if not ok then return false, why end

  -- The label is the name, and it lives there rather than in this file because
  -- a label already survives updates, reboots, and being broken and replaced --
  -- and CC's own `label` program can read and set it without this program.
  if n.name and n.name ~= "" then os.setComputerLabel(n.name) end
  return true
end

--- Serialise a craft table to the lines of a /craft.cfg. Pure, so the writer can
--- be tested without a filesystem and the result compared against what
--- `lib/hull.lua` will make of it.
function cfg.craftLines(craft)
  local out = {
    "-- What this ship is, and how to fly it.",
    "--",
    "-- Written by `configure`. Not in manifest.txt, so `update` never replaces",
    "-- it -- edit it by hand as much as you like.",
    "--",
    "-- The two things worth checking, because nothing can work them out by",
    "-- looking: which bearing is lift and which is main, and which optical",
    "-- sensor points down. Both wrong the same way is a ship that flies into",
    "-- the ground.",
    "",
    "return {",
    ("  name = %s,"):format(quoted(craft.name or "ship")),
    "",
    "  controls = {",
  }

  local names = {}
  for name in pairs(craft.controls or {}) do names[#names + 1] = name end
  table.sort(names)

  for _, name in ipairs(names) do
    local c = craft.controls[name]
    local parts = { ("kind = %s"):format(quoted(c.kind)) }
    if c.peripheral then
      parts[#parts + 1] = ("peripheral = %s"):format(quoted(c.peripheral))
    end
    if c.group then parts[#parts + 1] = ("group = %s"):format(quoted(c.group)) end
    if c.side  then parts[#parts + 1] = ("side = %s"):format(quoted(c.side)) end
    if c.mode  then parts[#parts + 1] = ("mode = %s"):format(quoted(c.mode)) end
    if c.colour then parts[#parts + 1] = ("colour = %d"):format(c.colour) end
    if c.hold  then parts[#parts + 1] = "hold = true" end
    if c.pivot then
      parts[#parts + 1] = ("pivot = { min = %d, max = %d }")
        :format(c.pivot.min, c.pivot.max)
    end
    out[#out + 1] = ("    %s = { %s },"):format(name, table.concat(parts, ", "))
  end

  out[#out + 1] = "  },"
  out[#out + 1] = ""
  out[#out + 1] = "  instruments = {"

  for _, entry in ipairs(cfg.instruments) do
    local set = (craft.instruments or {})[entry.role]
    if set == false then
      out[#out + 1] = ("    %s = false,   -- this hull deliberately has none")
        :format(entry.role)
    elseif type(set) == "string" then
      out[#out + 1] = ("    %s = %s,"):format(entry.role, quoted(set))
    end
    -- Anything else is left out entirely rather than written as `false`. A role
    -- that is absent is found automatically the moment its block appears, which
    -- is what has to happen on a contraption assembled after the computer was
    -- turned on; `false` would make that absence permanent.
  end

  out[#out + 1] = "  },"
  out[#out + 1] = ""

  local signals = {}
  for name in pairs(craft.signals or {}) do signals[#signals + 1] = name end
  table.sort(signals)
  if #signals > 0 then
    out[#out + 1] = "  -- Redstone coming in: read every sweep, drives nothing,"
    out[#out + 1] = "  -- and rides in the telemetry so you can see it from base."
    out[#out + 1] = "  signals = {"
    for _, name in ipairs(signals) do
      local s = craft.signals[name]
      local parts = { ("side = %s"):format(quoted(s.side)) }
      if s.mode then parts[#parts + 1] = ("mode = %s"):format(quoted(s.mode)) end
      out[#out + 1] = ("    %s = { %s },"):format(name, table.concat(parts, ", "))
    end
    out[#out + 1] = "  },"
    out[#out + 1] = ""
  end

  local l = craft.limits or {}
  out[#out + 1] = "  -- cruise/climb/descend are blocks per second; clearance is"
  out[#out + 1] = "  -- how close to the ground the terrain guard tolerates."
  out[#out + 1] = ("  limits = { cruise = %d, climb = %d, descend = %d, clearance = %d },")
    :format(l.cruise or 10, l.climb or 3, l.descend or 2, l.clearance or 8)
  out[#out + 1] = ""

  local gainParts = {}
  for key, value in pairs(craft.gains or {}) do
    gainParts[#gainParts + 1] = ("%s = %s"):format(key, tostring(value))
  end
  table.sort(gainParts)
  out[#out + 1] = "  -- hover is where the lift throttle sits when the ship is"
  out[#out + 1] = "  -- neither climbing nor sinking. A guess is fine: the"
  out[#out + 1] = "  -- vertical loop's integral finds the real value in seconds."
  out[#out + 1] = ("  gains = { %s },"):format(table.concat(gainParts, ", "))
  out[#out + 1] = ""

  out[#out + 1] = "  mix = {"
  for _, entry in ipairs(craft.mix or {}) do
    local extra = ""
    if entry.scale and entry.scale ~= 1 then
      extra = (", scale = %s"):format(entry.scale)
    end
    out[#out + 1] = ("    { demand = %s, control = %s, as = %s%s },")
      :format(quoted(entry.demand), quoted(entry.control), quoted(entry.as), extra)
  end
  out[#out + 1] = "  },"
  out[#out + 1] = "}"

  return out
end

function cfg.writeCraft(craft)
  return put(config.craftFile, cfg.craftLines(craft))
end

function cfg.writeBeacon(b)
  return put(config.beaconFile, {
    "-- Where this beacon stands, and what it is called.",
    "--",
    "-- Written by `configure`. Not in manifest.txt, so `update` never replaces",
    "-- it: a beacon whose coordinates were overwritten would go on calling",
    "-- itself the quarry pad from somewhere else entirely.",
    "",
    "return {",
    ("  name = %s,"):format(quoted(b.name or "beacon")),
    ("  kind = %s,"):format(quoted(b.kind == "pad" and "pad" or "point")),
    ("  x = %d,"):format(math.floor(tonumber(b.x) or 0)),
    ("  y = %d,"):format(math.floor(tonumber(b.y) or 0)),
    ("  z = %d,"):format(math.floor(tonumber(b.z) or 0)),
    "}",
  })
end

--------------------------------------------------------------------------------
-- What is wrong with it
--------------------------------------------------------------------------------

local BAD, WARN = "bad", "warn"

--- Everything wrong with this computer's configuration.
--
-- Pure given its inputs, so the whole table of failure modes can be tested
-- without a peripheral, a filesystem or a screen -- which is the only reason it
-- is worth having the rules in one place at all.
--
--   role      what this computer is meant to be
--   opts.craft     the craft table, or nil
--   opts.beacon    the beacon table, or nil
--   opts.network   the network table
--   opts.attached  { [kind] = { side, ... } }
--   opts.configured  whether the stamp is present
--
-- Each problem is { text = , severity = , pane = }, where `pane` is the screen
-- in `configure` that fixes it -- so the front page can offer to take you there
-- rather than describing where to go.
function cfg.check(role, opts)
  opts = opts or {}
  local attached = opts.attached or {}
  local problems = {}

  local function say(severity, pane, text)
    problems[#problems + 1] = { text = text, severity = severity, pane = pane }
  end

  local function firstOf(kind)
    return attached[kind] and attached[kind][1] or nil
  end

  -- Never configured -------------------------------------------------------
  --
  -- Ahead of everything else and for every role, because it is the one problem
  -- whose answer is "run the wizard" rather than "fix this field".
  if not opts.configured then
    say(BAD, "welcome", "this computer has not been configured")
  end

  -- Hardware ---------------------------------------------------------------
  --
  -- Reported, never blocking. See the note at the top of this file: assembling
  -- a contraption is what attaches its peripherals, so a required instrument
  -- being absent is the normal state of every ship until the moment it is
  -- assembled.
  local rows = needs.check(role, cfg.found(attached))
  for _, row in ipairs(rows) do
    if not row.ok and row.item.tier == "required" then
      say(WARN, "hardware", "no " .. row.item.what .. " -- " .. row.item.without)
    end
  end

  if role == "pilot" then
    local craft = opts.craft

    if not craft then
      say(BAD, "hull", "no " .. config.craftFile .. " -- this ship has no hull")
      return problems
    end

    local instruments = type(craft.instruments) == "table" and craft.instruments or {}

    for _, entry in ipairs(cfg.instruments) do
      local set = instruments[entry.role]

      if set == false and firstOf(entry.kind) then
        -- The trap the whole configurator was first written for. `false` means
        -- "this hull deliberately has none, stop looking"; the block is right
        -- there, so it plainly does have one and is being ignored.
        say(WARN, "instruments", entry.role .. " is switched off, but a "
          .. entry.kind .. " is attached")

      elseif type(set) == "string" and next(attached) then
        -- Named a peripheral that is nowhere on this computer. Checked against
        -- the actual list rather than merely against the kind: a craft file
        -- naming `optical_sensor_3` on a hull that has 0 and 1 is a typo that
        -- costs a whole instrument, and "well, *an* optical sensor is attached"
        -- is not an answer to it.
        --
        -- Only worth saying when *something* is attached. On a computer with
        -- nothing at all the contraption is simply not assembled, and every
        -- role would fire this at once for no reason.
        local here = false
        for _, side in ipairs(attached[entry.kind] or {}) do
          if side == set then here = true end
        end
        if not here then
          say(WARN, "instruments", entry.role .. " names " .. set
            .. ", which is not attached")
        end
      end
    end

    local eyes = #(attached.optical_sensor or {})
    if eyes > 1 and (instruments.ground == nil or instruments.forward == nil) then
      say(WARN, "instruments", ("%d optical sensors -- name ground and forward, "
        .. "or one of them is a guess"):format(eyes))
    end

    -- Controls and the mix ---------------------------------------------------
    --
    -- These are the blocking ones, and the reason a pilot is gated at all: a
    -- hull with no controls or no mix is not a ship with a problem, it is a
    -- flight computer wired to nothing, and letting it reach the control loop
    -- gains nobody anything.
    local controls = 0
    for _ in pairs(type(craft.controls) == "table" and craft.controls or {}) do
      controls = controls + 1
    end
    if controls == 0 then
      say(BAD, "bearings", "no controls -- nothing for the autopilot to move")
    end

    local mix = type(craft.mix) == "table" and craft.mix or {}
    if #mix == 0 and controls > 0 then
      say(BAD, "bearings", "no mix -- the controls are never driven")
    end

    local drivesLift = false
    for _, entry in ipairs(mix) do
      if entry.demand == "lift" then drivesLift = true end
    end
    if #mix > 0 and not drivesLift then
      -- Everything else is a matter of going somewhere. This one is the
      -- difference between a ship and a falling building.
      say(BAD, "bearings", "nothing in the mix drives lift -- this hull cannot "
        .. "hold itself up")
    end

    -- A control naming a peripheral is not checked against what is attached,
    -- deliberately, and for the same reason as the instruments: on the pad,
    -- before assembly, none of them are there.

  elseif role == "beacon" then
    local b = opts.beacon
    if not b then
      say(BAD, "waypoint", "no " .. config.beaconFile .. " -- this beacon has no "
        .. "name and no coordinates")
    elseif not (tonumber(b.x) and tonumber(b.y) and tonumber(b.z)) then
      say(BAD, "waypoint", "this beacon has no coordinates, so it is not a "
        .. "waypoint")
    elseif type(b.name) ~= "string" or b.name == "" then
      say(BAD, "waypoint", "this beacon has no name, so nothing can be sent to it")
    end
  end

  -- server and remote need nothing beyond the network settings and the stamp.
  -- Saying so here rather than leaving the branch out, because "there is no
  -- check for this role" and "somebody forgot this role" look identical in a
  -- table of conditions.

  return problems
end

--- Does any of this stop the program running?
function cfg.blocking(problems)
  for _, p in ipairs(problems or {}) do
    if p.severity == BAD then return true end
  end
  return false
end

--- Check this computer as it actually stands, reading every file and scanning
--- the peripherals. The convenience wrapper `startup.lua` and the configurator's
--- front page both use, so neither can assemble the inputs differently.
function cfg.checkHere(role)
  role = role or cfg.roleHere()
  local network = cfg.network()

  return cfg.check(role, {
    craft      = role == "pilot" and cfg.craft() or nil,
    beacon     = role == "beacon" and cfg.beacon() or nil,
    network    = network,
    attached   = cfg.attached(),
    configured = network.configured ~= nil,
  }), role
end

return cfg
