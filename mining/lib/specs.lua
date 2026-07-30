--- Pattern metadata: names, descriptions and parameter ranges.
--
-- Kept separate from lib/patterns.lua because the pocket computer needs to
-- render the parameter widgets but has no `turtle` API, so it must not load
-- anything that touches movement code.

local specs = {}

specs.order = { "quarry", "tunnel", "strip", "stairs", "harvest", "survey" }

--- Serpentine traversal enters every cell exactly once, so the move count is
--- the cell count give or take the level changes between layers. The walk home
--- is a Manhattan run from the far corner.
local function rectEstimate(p)
  local cells = p.w * p.d * p.h
  local moves = cells + (p.h - 1)
  return {
    cells = cells,
    moves = moves,
    fuel  = moves + p.w + p.d + p.h,
  }
end

--- Clearing a column taller than 2 costs a move up and back for each extra
--- block, because a turtle can only dig the block directly above itself.
local function liftCost(height) return 2 * math.max(0, height - 2) end

local function stripEstimate(p)
  -- length counts the mouth the turtle starts on, so length-1 blocks of travel.
  local points  = math.floor((p.length - 1) / p.spacing)
  local columns = p.length + 2 * p.branch * points
  -- Each branch is walked out and back, so a branch point costs 4x its length.
  local moves   = (p.length - 1) + 4 * p.branch * points + columns * liftCost(p.height)
  return {
    cells = columns * p.height,
    moves = moves,
    fuel  = moves + p.length + p.branch,
  }
end

--- A scout drops through open air and climbs back, scanning on the way down.
--- The scan cost dominates: it is charged to turtle fuel, and rises with radius.
local function surveyEstimate(p)
  local scans = math.floor(p.depth / p.step) + 1
  local moves = 2 * p.depth
  return {
    cells = scans,
    moves = moves,
    fuel  = moves + scans * p.radius * 2,
  }
end

--- Vein following wanders and retraces, so roughly two moves per block taken.
--- The trip out to the seam is the server's to add: only it knows where the
--- turtle is standing when the job is handed over.
local function harvestEstimate(p)
  return {
    cells = p.max,
    moves = 2 * p.max,
    fuel  = 2 * p.max + p.radius,
  }
end

local function stairsEstimate(p)
  -- Two moves per tread (forward, down) plus the sideways sweep for width.
  local moves = p.depth * (2 + liftCost(p.headroom) + 2 * (p.width - 1))
  return {
    cells = p.depth * p.width * p.headroom,
    moves = moves,
    fuel  = moves + 2 * p.depth,        -- the climb back up is the long way home
  }
end

specs.byName = {
  quarry = {
    name        = "quarry",
    description = "w x d footprint, h layers straight down",
    params = {
      { key = "w", label = "Width",  default = 8,  min = 1, max = 64  },
      { key = "d", label = "Depth",  default = 8,  min = 1, max = 64  },
      { key = "h", label = "Layers", default = 16, min = 1, max = 256 },
    },
    role     = "miner",
    estimate = rectEstimate,
  },
  tunnel = {
    name        = "tunnel",
    description = "w wide, h tall corridor running d forward",
    params = {
      { key = "w", label = "Width",  default = 3,  min = 1, max = 16  },
      { key = "d", label = "Length", default = 32, min = 1, max = 256 },
      { key = "h", label = "Height", default = 3,  min = 1, max = 16  },
      { key = "veins",  label = "Veins",  default = 0,  min = 0, max = 1   },
    },
    role     = "miner",
    estimate = rectEstimate,
  },
  strip = {
    name        = "strip",
    description = "corridor with branch ribs every few blocks",
    params = {
      { key = "length",  label = "Length",  default = 32, min = 1, max = 256 },
      { key = "branch",  label = "Branch",  default = 8,  min = 1, max = 32  },
      { key = "spacing", label = "Spacing", default = 3,  min = 1, max = 16  },
      { key = "height",  label = "Height",  default = 2,  min = 1, max = 8   },
      { key = "veins",  label = "Veins",  default = 0,  min = 0, max = 1   },
    },
    role     = "miner",
    estimate = stripEstimate,
  },
  stairs = {
    name        = "stairs",
    description = "walkable staircase descending depth blocks",
    params = {
      { key = "depth",    label = "Depth",  default = 32, min = 1, max = 256 },
      { key = "width",    label = "Width",  default = 1,  min = 1, max = 3   },
      { key = "headroom", label = "Head",   default = 3,  min = 2, max = 5   },
      { key = "veins",  label = "Veins",  default = 0,  min = 0, max = 1   },
    },
    role     = "miner",
    estimate = stairsEstimate,
  },
  harvest = {
    name        = "harvest",
    description = "travel to a seam and follow it out",
    params = {
      { key = "radius", label = "Radius", default = 8,   min = 1, max = 32  },
      { key = "max",    label = "Max",    default = 128, min = 1, max = 512 },
    },
    role     = "miner",
    estimate = harvestEstimate,
  },
  survey = {
    name        = "survey",
    description = "scout: drop through open air, scanning for ore",
    params = {
      { key = "depth",  label = "Depth",  default = 32, min = 1, max = 256 },
      { key = "radius", label = "Radius", default = 8,  min = 1, max = 16  },
      { key = "step",   label = "Step",   default = 6,  min = 1, max = 16  },
    },
    role     = "scout",
    estimate = surveyEstimate,
  },
}

function specs.get(name) return specs.byName[name] end

--- Pull the parameters `spec` declares out of `source`, checked against their
--- declared range. Returns the parameter table, or nil plus a reason.
--
-- This lives next to the ranges it enforces so there is exactly one definition
-- of what a valid job is, shared by the shell arguments, the rednet message and
-- the state file. A garbled or truncated message must not reach pattern code,
-- where a nil width becomes a nil-arithmetic error mid-job and the turtle
-- reports having failed a job it never actually started.
function specs.readParams(spec, source)
  if type(spec) ~= "table" or type(spec.params) ~= "table" then
    return nil, "unknown pattern"
  end
  if type(source) ~= "table" then return nil, "no parameters" end

  local params = {}
  for _, p in ipairs(spec.params) do
    local v = tonumber(source[p.key])
    if not v then return nil, "missing parameter " .. p.key end
    if v ~= math.floor(v) then return nil, p.key .. " must be a whole number" end
    if v < p.min or v > p.max then
      return nil, ("%s must be %d-%d"):format(p.key, p.min, p.max)
    end
    params[p.key] = v
  end
  return params
end

--- Roughly how big a job is: { cells, moves, fuel }. Same nil-plus-reason
--- contract as readParams, and it validates through readParams first so a
--- nonsense job cannot produce a confident-looking number.
--
-- `fuel` covers the mining and the walk home but deliberately not
-- config.fuelMargin: the margin is the caller's policy, and the turtle's own
-- guard applies it separately. Estimates are approximate by nature -- they
-- cannot know how much backtracking bedrock or a vein will force -- so treat
-- them as "is this job the right order of magnitude for my fuel", not a budget.
function specs.estimate(spec, source)
  local params, why = specs.readParams(spec, source)
  if not params then return nil, why end
  if type(spec.estimate) ~= "function" then return nil, "no estimate available" end
  return spec.estimate(params)
end

return specs
