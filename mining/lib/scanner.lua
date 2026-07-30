--- Advanced Peripherals geo scanner.
--
-- Turns "what is in the rock around me" into world coordinates the fleet can
-- act on. A scout carries this; a mining turtle cannot, because a turtle has
-- exactly two upgrade slots and a miner already spends both on a pickaxe and a
-- wireless modem.
--
-- Three facts about the peripheral that the design has to respect:
--
--   * On a turtle, scanning burns *turtle fuel* -- gs.cost(radius) against
--     turtle.getFuelLevel(). Fuel spent scanning is fuel not spent moving, and
--     a scout that strands itself is no more use than a stranded miner.
--   * There is a cooldown between scans. scan() returns nil plus a reason when
--     you hit it, which is a wait, not a failure.
--   * Coordinates come back *relative to the scanner*. The published docs do
--     not actually say so either way, which is why this module works it out at
--     runtime rather than trusting anyone's reading -- see detectFrame.

local config = require("lib.config")
local move   = require("lib.move")
local veins  = require("lib.veins")

local scanner = {}

scanner.frame = nil        -- "relative" | "absolute", once we have worked it out

--------------------------------------------------------------------------------
-- Finding the peripheral
--------------------------------------------------------------------------------

-- Advanced Peripherals renamed this between versions, and a turtle upgrade
-- appears on the side it is equipped to.
local NAMES = { geoScanner = true, geo_scanner = true }

function scanner.find()
  for _, side in ipairs({ "left", "right", "top", "bottom", "front", "back" }) do
    if peripheral.isPresent(side) and NAMES[peripheral.getType(side)] then
      return peripheral.wrap(side), side
    end
  end
  -- Fall back to a search, in case it is attached somewhere unexpected.
  for _, side in ipairs(peripheral.getNames()) do
    if NAMES[peripheral.getType(side)] then
      return peripheral.wrap(side), side
    end
  end
  return nil
end

function scanner.available()
  return scanner.find() ~= nil
end

--------------------------------------------------------------------------------
-- Coordinate frame
--------------------------------------------------------------------------------

--- Work out whether hits are offsets from the scanner or world positions.
--
-- Every hit must lie within `radius` of the scanner. So compare each hit
-- against both candidate origins: an offset frame clusters around 0,0,0 and a
-- world frame clusters around the turtle. Whichever is consistent wins.
--
-- Ambiguous only when the turtle is standing at world 0,0,0, where the two
-- frames coincide and it does not matter which we pick.
local function detectFrame(hits, radius)
  local slack = radius + 2
  local nearZero, nearPos = true, true
  local p = move.pos

  for _, h in ipairs(hits) do
    if math.abs(h.x) > slack or math.abs(h.y) > slack or math.abs(h.z) > slack then
      nearZero = false
    end
    if math.abs(h.x - p.x) > slack or math.abs(h.y - p.y) > slack
       or math.abs(h.z - p.z) > slack then
      nearPos = false
    end
  end

  if nearZero and not nearPos then return "relative" end
  if nearPos and not nearZero then return "absolute" end
  -- Both fit (the turtle is at or near the origin) or neither does (something
  -- unexpected): relative is the documented behaviour and the safer guess,
  -- because at the origin the two are the same answer anyway.
  return "relative"
end

--- Convert a hit into world coordinates.
local function toWorld(h)
  if scanner.frame == "absolute" then
    return { x = h.x, y = h.y, z = h.z, name = h.name, tags = h.tags }
  end
  local p = move.pos
  return {
    x = p.x + h.x, y = p.y + h.y, z = p.z + h.z,
    name = h.name, tags = h.tags,
  }
end

--------------------------------------------------------------------------------
-- Scanning
--------------------------------------------------------------------------------

--- Scan and return hits in world coordinates, or nil plus a reason.
--
-- Refuses rather than scans when the cost would eat the fuel the scout needs to
-- get home: the fuel guard in lib/move cannot see this coming, because from its
-- point of view scanning is not a move.
function scanner.scan(radius)
  radius = radius or config.scanRadius
  local gs = scanner.find()
  if not gs then return nil, "no geo scanner" end

  local level = turtle and turtle.getFuelLevel() or "unlimited"
  if level ~= "unlimited" then
    local ok, cost = pcall(gs.cost, radius)
    if ok and type(cost) == "number" then
      local reserve = move.fuelToHome() + config.fuelMargin
      if level - cost < reserve then
        return nil, ("scan costs %d, only %d spare above the walk home")
          :format(cost, math.max(0, level - reserve))
      end
    end
  end

  -- The cooldown is a wait, not a failure, so give it a few goes before
  -- reporting anything wrong.
  local hits, why
  for attempt = 1, config.scanRetries do
    hits, why = gs.scan(radius)
    if hits then break end
    if attempt < config.scanRetries then os.sleep(config.scanCooldown) end
  end
  if not hits then return nil, tostring(why or "scan failed") end

  if not scanner.frame then
    scanner.frame = detectFrame(hits, radius)
  end

  local world = {}
  for _, h in ipairs(hits) do
    if type(h) == "table" and h.name and h.x and h.y and h.z then
      world[#world + 1] = toWorld(h)
    end
  end
  return world
end

--- Just the ore, using the same test vein following uses so the two agree
--- about what is worth chasing.
function scanner.ores(hits)
  local found = {}
  for _, h in ipairs(hits or {}) do
    if veins.isOre(h) then found[#found + 1] = h end
  end
  return found
end

--------------------------------------------------------------------------------
-- Clustering
--------------------------------------------------------------------------------

local function distance(a, b)
  return math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z)
end

--- Group ore hits into clusters no more than `gap` apart.
--
-- One job per ore block would swamp the queue and send a turtle on a round trip
-- for a single lump of coal. One job per seam is the useful unit, and it is
-- also what vein following harvests once a turtle gets there.
--
-- Pure: it takes a list and returns a list, so it can be tested without a
-- scanner, a world, or a turtle.
function scanner.cluster(hits, gap)
  gap = gap or config.clusterGap
  local remaining, clusters = {}, {}
  for i, h in ipairs(hits) do remaining[i] = h end

  while #remaining > 0 do
    local seed = table.remove(remaining)
    local members = { seed }

    -- Grow the cluster until nothing else is within gap of any member. Repeated
    -- passes because adding a block can bring further ones into range.
    local grew = true
    while grew do
      grew = false
      for i = #remaining, 1, -1 do
        for _, m in ipairs(members) do
          if distance(remaining[i], m) <= gap then
            members[#members + 1] = table.remove(remaining, i)
            grew = true
            break
          end
        end
      end
    end

    local sx, sy, sz = 0, 0, 0
    local kinds = {}
    for _, m in ipairs(members) do
      sx, sy, sz = sx + m.x, sy + m.y, sz + m.z
      kinds[m.name] = (kinds[m.name] or 0) + 1
    end
    local n = #members

    -- The centre is snapped to an actual member, not the arithmetic mean: the
    -- mean of a horseshoe-shaped seam is a block of stone in the middle of it,
    -- and a miner sent there would have to find its way back to the ore.
    local mean = { x = sx / n, y = sy / n, z = sz / n }
    local centre, best = members[1], math.huge
    for _, m in ipairs(members) do
      local d = distance(m, mean)
      if d < best then centre, best = m, d end
    end

    clusters[#clusters + 1] = {
      x = centre.x, y = centre.y, z = centre.z,
      count = n, kinds = kinds, name = centre.name,
    }
  end

  table.sort(clusters, function(a, b) return a.count > b.count end)
  return clusters
end

return scanner
