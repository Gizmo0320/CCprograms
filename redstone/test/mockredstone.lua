--- A mock redstone bus.
--
-- There is no `redstone` API outside the game, and lib/ports.lua is the one
-- module here that touches it. It reads the global at call time rather than
-- capturing it at load, which is what lets this file stand in for the world.
--
-- The bus is deliberately dumber than the real thing in one direction and
-- sharper in another. Dumber: a side holds whatever was last written to it,
-- with no notion of a block on the other end. Sharper: every read and write is
-- counted per side, because "one API call per side rather than one per port"
-- and "a bundled cable is written once however many colours changed" are
-- properties worth asserting, and they are invisible from the values alone.
--
--   local bus = mock.new()
--   _G.redstone = bus.api
--   bus.input.left = 7          -- what the world is presenting to us
--   bus.output.top               -- what we last drove
--   bus.reads.left, bus.writes.back

local mock = {}

local SIDES = { "top", "bottom", "left", "right", "front", "back" }

function mock.new()
  local bus = {
    input  = {},    -- [side] = boolean | 0-15 | colour mask, whatever is on the wire
    output = {},    -- [side] = what setOutput/setAnalogOutput/setBundledOutput last got
    reads  = {},    -- [side] = API reads since the last clear()
    writes = {},    -- [side] = API writes since the last clear()
  }

  local function read(side)
    bus.reads[side] = (bus.reads[side] or 0) + 1
    return bus.input[side]
  end

  local function write(side, value)
    bus.writes[side] = (bus.writes[side] or 0) + 1
    bus.output[side] = value
  end

  -- The three shapes CC presents. Each returns what the real API returns, which
  -- is the whole point: a boolean from getInput and a number from the other two,
  -- so lib/ports has to do the same conversions it does in game.
  bus.api = {
    getInput = function(side)
      local v = read(side)
      if type(v) == "number" then return v > 0 end
      return v and true or false
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

    setOutput = function(side, v)
      write(side, v and true or false)
    end,

    setAnalogOutput = function(side, v)
      write(side, math.max(0, math.min(15, math.floor(tonumber(v) or 0))))
    end,

    setBundledOutput = function(side, mask)
      write(side, math.floor(tonumber(mask) or 0))
    end,

    getOutput = function(side) return bus.output[side] and true or false end,
    getAnalogOutput = function(side) return math.floor(tonumber(bus.output[side]) or 0) end,
    getBundledOutput = function(side) return math.floor(tonumber(bus.output[side]) or 0) end,

    testBundledInput = function(side, colour)
      local mask = bus.api.getBundledInput(side)
      return math.floor(mask / colour) % 2 == 1
    end,

    getSides = function()
      local out = {}
      for i, side in ipairs(SIDES) do out[i] = side end
      return out
    end,
  }

  --- Forget the call counts, keeping the wire where it is. Called before the
  --- part of a case that is about how many calls were made.
  function bus.clear()
    bus.reads, bus.writes = {}, {}
  end

  function bus.totalReads()
    local n = 0
    for _, count in pairs(bus.reads) do n = n + count end
    return n
  end

  function bus.totalWrites()
    local n = 0
    for _, count in pairs(bus.writes) do n = n + count end
    return n
  end

  return bus
end

return mock
