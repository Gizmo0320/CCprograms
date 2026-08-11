--- Named ports over the six sides.
--
-- The unit everything else talks about. Not a side: "kitchen-lamp" is what you
-- want on a button, and it may be colour 3 of a bundled cable on the back. Rules
-- name ports, scenes name ports, the log names ports, and only this file knows
-- which side any of them is on.
--
-- It is also the only module here that touches the `redstone` API, which is
-- what lets lib/rules.lua be pure and testable. The global is read at call time
-- rather than captured at load, so a test can substitute a mock bus.
--
-- A port:
--
--   { name = "kitchen-lamp", side = "back", colour = colours.lime,
--     dir = "out", kind = "bundled", invert = false, label = "Kitchen lamp" }
--
-- Three signal shapes share the same six sides and each needs a different API
-- call, which is what `kind` selects:
--
--   digital  setOutput / getInput          -- boolean
--   analog   setAnalogOutput / getAnalogInput  -- 0-15, what a comparator reads
--   bundled  setBundledOutput / getBundledInput -- a 16-bit colour mask
--
-- `invert` lives on the port rather than in every rule that reads it. A
-- daylight sensor wired the wrong way round should be fixed once, in the place
-- that describes the wiring.

local config = require("lib.config")

local ports = {}

ports.list     = {}   -- in file order, which is the order the UI draws
ports.byName   = {}
ports.bySide   = {}   -- [side] = { port, ... }
ports.values   = {}   -- [name] = last known logical value
ports.outputs  = {}   -- [name] = logical value we are driving, for out ports
ports.problems = {}   -- what was wrong with the last define(), for the UI

local SIDES = { top = true, bottom = true, left = true,
                right = true, front = true, back = true }

local KINDS = { digital = true, analog = true, bundled = true }

-- Colour masks are powers of two. Everything below uses arithmetic on them
-- rather than bit32 or colours.test, because a mask is just a number and this
-- way the module has no dependency to mock in the test harness.
local function inMask(mask, colour)
  return math.floor(mask / colour) % 2 == 1
end

-- A colour is one of the sixteen powers of two from 1 to 32768. Checked by
-- walking them rather than with logarithms: there are sixteen, and a float
-- log2 that comes back as 3.9999999 would reject a perfectly good colour.
local function isColour(c)
  if type(c) ~= "number" or c ~= math.floor(c) then return false end
  local bit = 1
  for _ = 1, 16 do
    if c == bit then return true end
    bit = bit * 2
  end
  return false
end

--------------------------------------------------------------------------------
-- Definition
--------------------------------------------------------------------------------

function ports.reset()
  ports.list, ports.byName, ports.bySide = {}, {}, {}
  ports.values, ports.outputs, ports.problems = {}, {}, {}
end

--- Validate and install a list of port definitions.
--
-- Returns ok, problems. A bad entry is dropped with a reason rather than
-- throwing: a typo in /ports.cfg should cost you one lamp and a warning on
-- screen, not a computer that will not boot far enough to let you fix it.
function ports.define(list)
  ports.reset()
  if type(list) ~= "table" then
    ports.problems = { "ports file did not return a table" }
    return false, ports.problems
  end

  for i, p in ipairs(list) do
    local why = nil

    if type(p) ~= "table" then
      why = "entry " .. i .. " is not a table"
    elseif type(p.name) ~= "string" or p.name == "" then
      why = "entry " .. i .. " has no name"
    elseif ports.byName[p.name] then
      why = p.name .. ": defined twice"
    elseif not SIDES[p.side] then
      why = p.name .. ": '" .. tostring(p.side) .. "' is not a side"
    elseif p.dir ~= "in" and p.dir ~= "out" then
      why = p.name .. ": dir must be 'in' or 'out'"
    elseif not KINDS[p.kind] then
      why = p.name .. ": '" .. tostring(p.kind) .. "' is not a kind"
    elseif p.kind == "bundled" and not isColour(p.colour) then
      why = p.name .. ": bundled needs a colour"
    end

    -- A side carries one signal, so everything on it has to agree about what
    -- that signal is. Two of these are physically impossible rather than merely
    -- unwise: a side driving an output cannot also read an input, because CC
    -- reports our own output straight back to us and the port would latch
    -- itself on; and a side is either bundled cable or it is not.
    if not why then
      local others = ports.bySide[p.side]
      if others and #others > 0 then
        local first = others[1]
        if first.dir ~= p.dir then
          why = p.name .. ": side " .. p.side .. " is already an " .. first.dir .. "put"
        elseif first.kind ~= p.kind then
          why = p.name .. ": side " .. p.side .. " is already " .. first.kind
        elseif p.kind ~= "bundled" then
          why = p.name .. ": side " .. p.side .. " is already used by " .. first.name
        else
          for _, o in ipairs(others) do
            if o.colour == p.colour then
              why = p.name .. ": colour already used by " .. o.name
              break
            end
          end
        end
      end
    end

    if why then
      ports.problems[#ports.problems + 1] = why
    else
      local port = {
        name   = p.name,
        label  = p.label or p.name,
        side   = p.side,
        colour = p.colour,
        dir    = p.dir,
        kind   = p.kind,
        invert = p.invert and true or false,
      }
      ports.list[#ports.list + 1] = port
      ports.byName[port.name] = port
      ports.bySide[port.side] = ports.bySide[port.side] or {}
      local sideList = ports.bySide[port.side]
      sideList[#sideList + 1] = port

      -- Everything starts off. An output's real value is restored from the
      -- state file a moment later, before the listener starts.
      local zero = (port.kind == "analog") and 0 or false
      ports.values[port.name] = zero
      if port.dir == "out" then ports.outputs[port.name] = zero end
    end
  end

  return #ports.problems == 0, ports.problems
end

--- Load /ports.cfg. Returns ok, problems.
function ports.load(path)
  path = path or config.portsFile
  if not fs or not fs.exists(path) then
    ports.reset()
    ports.problems = { "no " .. path .. " -- this computer has no ports defined" }
    return false, ports.problems
  end

  local fn, err = loadfile(path)
  if not fn then
    ports.reset()
    ports.problems = { path .. ": " .. tostring(err) }
    return false, ports.problems
  end

  local ok, list = pcall(fn)
  if not ok then
    ports.reset()
    ports.problems = { path .. ": " .. tostring(list) }
    return false, ports.problems
  end

  return ports.define(list)
end

function ports.get(name) return ports.byName[name] end

function ports.names()
  local out = {}
  for _, p in ipairs(ports.list) do out[#out + 1] = p.name end
  return out
end

function ports.count() return #ports.list end

--------------------------------------------------------------------------------
-- Values
--------------------------------------------------------------------------------

--- Force a value into the shape its port's kind uses.
function ports.coerce(port, value)
  if port.kind == "analog" then
    if type(value) == "boolean" then return value and 15 or 0 end
    local n = math.floor(tonumber(value) or 0)
    return math.max(0, math.min(15, n))
  end
  if type(value) == "number" then return value > 0 end
  return value and true or false
end

local function applyInvert(port, value)
  if not port.invert then return value end
  if port.kind == "analog" then return 15 - value end
  return not value
end

--------------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------------

--- Read every input port, one API call per side rather than one per port.
--
-- The `redstone` event carries no side and no value -- it says only that
-- something, somewhere, changed -- so every read is a poll of everything. Doing
-- it per port would be sixteen calls to getBundledInput on the same side for
-- one cable.
--
-- Output ports report what we are driving. That is not a second-class answer:
-- an output is held by the computer, so what we last wrote *is* what the wire
-- is carrying.
function ports.poll()
  local cache = {}

  for _, p in ipairs(ports.list) do
    if p.dir == "in" then
      local raw = cache[p.side]
      if raw == nil then
        if p.kind == "analog" then
          raw = redstone.getAnalogInput(p.side)
        elseif p.kind == "bundled" then
          raw = redstone.getBundledInput(p.side)
        else
          raw = redstone.getInput(p.side)
        end
        cache[p.side] = raw
      end

      local value
      if p.kind == "bundled" then
        value = inMask(raw, p.colour)
      else
        value = raw
      end
      ports.values[p.name] = applyInvert(p, value)
    else
      ports.values[p.name] = ports.outputs[p.name]
    end
  end

  return ports.values
end

--- A copy, for handing to rules as "what it was last sweep".
function ports.snapshot(t)
  local out = {}
  for k, v in pairs(t or ports.values) do out[k] = v end
  return out
end

--- What changed between two snapshots, in port order so the log reads in the
--- order the ports are listed rather than in hash order.
function ports.diff(before, after)
  local changes = {}
  for _, p in ipairs(ports.list) do
    local was, now = before[p.name], after[p.name]
    if was ~= now then
      changes[#changes + 1] = { port = p.name, from = was, to = now }
    end
  end
  return changes
end

--------------------------------------------------------------------------------
-- Writing
--------------------------------------------------------------------------------

--- Push the whole of one side to the wire.
--
-- Recomputed from every output port on the side rather than adjusted in place,
-- because a bundled side is one number shared by up to sixteen ports and
-- setting a colour without knowing the other fifteen turns them all off.
local function emit(side)
  local list = ports.bySide[side]
  if not list or list[1].dir ~= "out" then return end

  local kind = list[1].kind

  if kind == "bundled" then
    local mask = 0
    for _, p in ipairs(list) do
      if applyInvert(p, ports.outputs[p.name]) then mask = mask + p.colour end
    end
    redstone.setBundledOutput(side, mask)
  elseif kind == "analog" then
    redstone.setAnalogOutput(side, applyInvert(list[1], ports.outputs[list[1].name]))
  else
    redstone.setOutput(side, applyInvert(list[1], ports.outputs[list[1].name]))
  end
end

--- Drive a port. Returns ok, previous value -- or false, reason.
function ports.set(name, value)
  local p = ports.byName[name]
  if not p then return false, "no port named " .. tostring(name) end
  if p.dir ~= "out" then return false, name .. " is an input" end

  local now  = ports.coerce(p, value)
  local prev = ports.outputs[name]

  ports.outputs[name] = now
  ports.values[name]  = now
  emit(p.side)

  return true, prev
end

--- Apply a batch in one go, so a scene that touches four ports on one bundled
--- cable writes that cable once instead of four times -- and so a rule sweep
--- cannot see half of its own actions.
function ports.apply(batch)
  local touched, applied = {}, {}

  for _, action in ipairs(batch) do
    local p = ports.byName[action.port]
    if p and p.dir == "out" then
      local value = ports.coerce(p, action.value)
      if ports.outputs[p.name] ~= value then
        applied[#applied + 1] = {
          port = p.name, from = ports.outputs[p.name], to = value,
          why = action.why,
        }
        ports.outputs[p.name] = value
        ports.values[p.name]  = value
        touched[p.side] = true
      end
    end
  end

  for side in pairs(touched) do emit(side) end
  return applied
end

--- Put outputs back the way they were before the reboot.
--
-- An output is held by the computer rather than by the world, so without this
-- every lamp in the base goes dark the moment the chunk reloads. It runs before
-- the listener starts, so the first heartbeat we send is already true.
function ports.restore(saved)
  if type(saved) ~= "table" then return 0 end

  local n, touched = 0, {}
  for name, value in pairs(saved) do
    local p = ports.byName[name]
    if p and p.dir == "out" then
      ports.outputs[name] = ports.coerce(p, value)
      ports.values[name]  = ports.outputs[name]
      touched[p.side] = true
      n = n + 1
    end
  end

  for side in pairs(touched) do emit(side) end
  return n
end

--- Just the output values, for the state file.
function ports.saved()
  local out = {}
  for name, value in pairs(ports.outputs) do out[name] = value end
  return out
end

--------------------------------------------------------------------------------

--- A serialisable description, for the `ports?` reply. The pocket computer has
--- no /ports.cfg of its own -- it learns what exists by asking.
function ports.describe()
  local out = {}
  for _, p in ipairs(ports.list) do
    out[#out + 1] = {
      name = p.name, label = p.label, dir = p.dir, kind = p.kind,
      side = p.side, colour = p.colour, value = ports.values[p.name],
    }
  end
  return out
end

return ports
