--- What the fleet has learned about the ground.
--
-- Pure. A coarse height map, fed by ships as they fly and by beacons standing
-- still, and the one question worth asking of it: **how high must I be to cross
-- from here to there.**
--
-- Until now a ship discovered hills by nearly hitting them. The clearance guard
-- looks down and the obstacle guard looks forward, and both are reflexes -- they
-- fire when the ground is already close. Neither can tell you before you set off
-- that a route needs a hundred and forty rather than a hundred. This can, for
-- ground somebody has already flown over.
--
-- ## Unknown stays unknown
--
-- The single rule the whole file is built around. A cell nobody has been over
-- has **no height**, not a height of zero, and `along` reports how much of a
-- route it actually knows rather than averaging the gaps away. A map that
-- answered "sixty-four" for terrain it had never seen would be worse than no map
-- at all: it would look like knowledge and it would fly ships into hills.
--
-- So every answer here comes with its coverage, callers are expected to look at
-- it, and `safe` refuses to produce an altitude from nothing.
--
-- ## Coarse on purpose
--
-- Cells are `config.terrainCell` blocks square and hold the **highest** ground
-- seen in them. A ship at cruise samples every couple of blocks, so a cell fills
-- quickly, and taking the maximum means a route crossing the corner of a cell is
-- planned against the worst of it rather than the average. Erring upwards is the
-- only direction that is safe to err in.

local config = require("lib.config")

local terrain = {}

--------------------------------------------------------------------------------

local function key(cx, cz)
  return ("%d,%d"):format(cx, cz)
end

local function cellOf(map, x, z)
  local size = map.cell or config.terrainCell
  return math.floor(x / size), math.floor(z / size)
end

--- An empty map.
function terrain.new(cell)
  return {
    cell  = tonumber(cell) or config.terrainCell,
    cells = {},          -- ["cx,cz"] = { h = highest ground, at = when }
    count = 0,
  }
end

--- Adopt a map that came off the wire or off disk, without trusting its shape.
--
-- The tower serialises this to /fleet.state and broadcasts it, so it arrives
-- from two directions that can both be out of date or corrupt, and a malformed
-- one has to be an empty map rather than a crash on somebody's flight computer.
function terrain.load(saved)
  local map = terrain.new(saved and saved.cell)
  if type(saved) ~= "table" or type(saved.cells) ~= "table" then return map end

  for k, entry in pairs(saved.cells) do
    if type(k) == "string" and type(entry) == "table" and tonumber(entry.h) then
      map.cells[k] = { h = tonumber(entry.h), at = tonumber(entry.at) or 0 }
      map.count = map.count + 1
    end
  end
  return map
end

--------------------------------------------------------------------------------

--- Throw away the least recently touched cells.
--
-- The map is the one thing here that grows with every block flown over, and a
-- computer that fills its disk stops being able to write its state file. Oldest
-- first, because the ground under a route nobody flies any more matters less
-- than the ground under one they do.
local function trim(map)
  local most = config.terrainCells
  if map.count <= most then return end

  local oldest, oldestKey = math.huge, nil
  local drop = map.count - most

  -- Dropped one at a time rather than by sorting the whole table. This runs at
  -- most once per new cell, so it is one pass over a map that is already at its
  -- limit rather than a sort of it.
  for _ = 1, drop do
    oldest, oldestKey = math.huge, nil
    for k, entry in pairs(map.cells) do
      if entry.at < oldest then oldest, oldestKey = entry.at, k end
    end
    if not oldestKey then return end
    map.cells[oldestKey] = nil
    map.count = map.count - 1
  end
end

--- Record that the ground at (x, z) is at height `ground`.
--
-- Keeps the **highest** reading a cell has ever given, and never lowers one. A
-- ship passing over the gap between two towers would otherwise erase what it
-- learned about the towers, and the whole point is to plan against the worst of
-- a cell rather than the last look at it.
function terrain.note(map, x, z, ground, now)
  if not (tonumber(x) and tonumber(z) and tonumber(ground)) then return false end

  local k = key(cellOf(map, x, z))
  local entry = map.cells[k]

  if not entry then
    map.cells[k] = { h = ground, at = now or 0 }
    map.count = map.count + 1
    trim(map)
    return true
  end

  entry.at = now or entry.at
  if ground > entry.h then
    entry.h = ground
    return true
  end
  return false
end

--- The known ground height at a point, or nil.
function terrain.at(map, x, z)
  local entry = map.cells[key(cellOf(map, x, z))]
  return entry and entry.h or nil
end

--------------------------------------------------------------------------------

--- The highest known ground between two points.
--
-- Returns highest, coverage, longestGap:
--
--   highest     the worst ground found, or nil if none of it is known
--   coverage    0..1, how much of the line had an answer
--   longestGap  the longest unbroken stretch with no answer, in blocks
--
-- **Coverage and the gap are not decoration.** A route that is ninety per cent
-- surveyed with a two hundred block hole in the middle is not a surveyed route,
-- and a caller that looked only at `highest` would fly straight into whatever is
-- in the hole. Both numbers are returned so the caller has to decide, and every
-- caller in this project checks the gap.
function terrain.along(map, from, to)
  local ax, az = tonumber(from and from.x), tonumber(from and from.z)
  local bx, bz = tonumber(to and to.x), tonumber(to and to.z)
  if not (ax and az and bx and bz) then return nil, 0, 0 end

  local dx, dz = bx - ax, bz - az
  local length = math.sqrt(dx * dx + dz * dz)

  -- A leg shorter than a cell is one lookup, not a walk.
  if length < 1 then
    local h = terrain.at(map, ax, az)
    return h, h and 1 or 0, h and 0 or 0
  end

  -- Half a cell, so a leg cutting a corner cannot slip between samples.
  local step = (map.cell or config.terrainCell) / 2
  local steps = math.max(1, math.ceil(length / step))

  local highest, known = nil, 0
  local gap, longestGap = 0, 0

  for i = 0, steps do
    local t = i / steps
    local h = terrain.at(map, ax + dx * t, az + dz * t)

    if h then
      known = known + 1
      gap = 0
      if highest == nil or h > highest then highest = h end
    else
      gap = gap + (length / steps)
      if gap > longestGap then longestGap = gap end
    end
  end

  return highest, known / (steps + 1), longestGap
end

--- The same, over every leg of a plan, starting from where the ship is.
--
-- The worst of the whole route rather than of the next leg: a plan is flown at
-- one cruise altitude and the altitude has to clear all of it.
function terrain.forPlan(map, plan, at)
  if type(plan) ~= "table" or type(plan.legs) ~= "table" then return nil, 0, 0 end

  local highest, worstGap = nil, 0
  local knownTotal, samples = 0, 0
  local previous = at

  for i = (plan.leg or 1), #plan.legs do
    local leg = plan.legs[i]
    if previous then
      local h, coverage, gap = terrain.along(map, previous, leg)
      if h and (highest == nil or h > highest) then highest = h end
      if gap > worstGap then worstGap = gap end
      knownTotal = knownTotal + coverage
      samples = samples + 1
    end
    previous = leg
  end

  if samples == 0 then return nil, 0, 0 end
  return highest, knownTotal / samples, worstGap
end

--------------------------------------------------------------------------------

--- The altitude a route needs, or nil when there is nothing to base one on.
--
-- Deliberately returns nil rather than a default. A caller that wants a fallback
-- has to say so itself, in its own words, where the reader can see that a guess
-- is being made.
function terrain.safe(highest, margin)
  if highest == nil then return nil end
  return highest + (tonumber(margin) or config.surveyMargin)
end

--- Is this route surveyed well enough to plan against?
--
-- Both tests, and the gap is the one that matters. Coverage alone would pass a
-- route with a single enormous hole in the middle of it.
function terrain.surveyed(coverage, gap)
  return (coverage or 0) >= config.surveyCoverage
     and (gap or math.huge) <= config.surveyGap
end

--- How many cells are known, for a status line. The map is invisible otherwise
--- and "has anything surveyed this" is a fair question to be able to answer.
function terrain.size(map)
  return map and map.count or 0
end

return terrain
