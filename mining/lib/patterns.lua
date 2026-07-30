--- Mining patterns.
--
-- Names, descriptions and parameter ranges live in lib/specs.lua; this module
-- attaches a run function to each. To add a pattern, add its spec there and
-- register the implementation here.
--
-- run(params, ctx) is given:
--   ctx.setProgress(done, total)  update the broadcast progress fraction
--   ctx.checkpoint(data)          persist resume data (called per layer)
--   ctx.resume                    resume data from a previous run, or nil
--
-- Patterns move only through lib/move, so pause, abort, fuel and inventory
-- handling all come for free.

local move    = require("lib.move")
local specs   = require("lib.specs")
local veins   = require("lib.veins")
local scanner = require("lib.scanner")
local config  = require("lib.config")

--- Chase any ore around the turtle if the job asked for it. Patterns that do
--- not declare a `veins` parameter -- quarry, which removes everything in its
--- footprint anyway -- pass nil here and this is a no-op.
local function follow(params)
  if (params.veins or 0) == 0 then return end
  veins.harvest()
end

local patterns = {}
patterns.byName = {}
patterns.order  = specs.order

function patterns.register(name, run)
  local spec = specs.get(name)
  if not spec then error("no spec for pattern " .. tostring(name), 2) end
  spec.run = run
  patterns.byName[name] = spec
  return spec
end

function patterns.get(name) return patterns.byName[name] end

--------------------------------------------------------------------------------
-- Shared traversal
--------------------------------------------------------------------------------

local function blockedAt(reason, name)
  return ("blocked at %d,%d,%d: %s%s"):format(
    move.pos.x, move.pos.y, move.pos.z,
    tostring(reason or "unknown"),
    name and (" (" .. name .. ")") or "")
end

--- Vertical travel to an absolute level, digging through whatever is between.
--- Absolute rather than "one step down", because a turtle riding over an
--- obstruction is not necessarily on the level it started the row at.
local function goToLevel(targetY)
  while move.pos.y ~= targetY do
    local dir = (move.pos.y > targetY) and "down" or "up"
    local ok, reason = move.step(dir)
    if not ok then return false, reason end
  end
  return true
end

--- One cell along the current row.
--
-- The turtle normally travels at layerY. A block it cannot remove -- bedrock,
-- or lava it has no junk left to seal with -- is ridden over instead: climb,
-- cross, then drop back into the row as soon as there is a floor to drop into.
--
-- Dropping back is deliberately not required to succeed. The old code climbed
-- over the obstruction and then insisted on descending into the very block it
-- had just climbed over, which is impossible by definition, so a single block
-- of bedrock failed the entire job. Riding one level high until the floor
-- returns costs nothing but travel through air already mined, and gets the
-- turtle past a whole bedrock ridge.
--
-- One advance() is always exactly one cell of the row, whatever height it
-- happens to happen at, so row lengths and the progress count stay honest.
local function advance(layerY)
  local ok, reason, name = move.step("forward")

  if not ok then
    local climbed, climbReason = move.step("up")
    if not climbed then
      error(blockedAt(reason or climbReason, name), 0)
    end
    local crossed, crossReason = move.step("forward")
    if not crossed then
      move.step("down")             -- undo the climb rather than drift upward
      error(blockedAt(crossReason, name), 0)
    end
  end

  while move.pos.y > layerY do
    if not move.step("down") then break end
  end
  return true
end

--- Serpentine traversal of one w x d rectangle at level `layerY`.
--
-- The turtle enters at a corner facing along the depth axis and leaves at the
-- opposite corner facing the way it last travelled. `side` is the direction of
-- the next column shift; it flips on every shift and is returned so the caller
-- can carry it into the layer below. Combined with a 180 between layers, this
-- means no travel is ever wasted returning to a start corner.
local function mineLayer(w, d, side, onCell, layerY)
  for col = 1, w do
    for _ = 1, d - 1 do
      advance(layerY)
      onCell()
    end
    if col < w then
      move.turn(side)
      advance(layerY)
      onCell()
      move.turn(side)
      side = (side == "right") and "left" or "right"
    end
  end
  return side
end

--- Drive `h` stacked layers of a w x d rectangle.
-- vertical is "down" (quarry) or "up" (tunnel).
local function runLayers(params, ctx, vertical, enterFirstLayer)
  local w, d, h = params.w, params.d, params.h
  local total = w * d * h
  local stride = (vertical == "down") and -1 or 1

  local side       = "right"
  local firstLayer = 1
  local done       = 0

  if ctx.resume then
    side       = ctx.resume.side or "right"
    firstLayer = ctx.resume.layer or 1
    done       = ctx.resume.done or 0
    ctx.setProgress(done, total)
    local ok, reason = move.goTo(ctx.resume.pos.x, ctx.resume.pos.y, ctx.resume.pos.z)
    if not ok then error("cannot reach resume point: " .. tostring(reason), 0) end
    move.face(ctx.resume.heading)
  elseif enterFirstLayer then
    -- Drop into the first layer so home stays on the surface, out of the hole.
    local ok, reason = move.step(vertical)
    if not ok then error("cannot start: " .. tostring(reason), 0) end
  end

  -- Called once the turtle is standing on a freshly entered cell, which is
  -- exactly the moment a vein next to it is worth chasing.
  local function onCell()
    follow(params)
    done = done + 1
    ctx.setProgress(done, total)
  end

  local levelY = move.pos.y

  for layer = firstLayer, h do
    ctx.checkpoint({
      layer   = layer,
      side    = side,
      done    = done,
      pos     = move.copyPos(),
      heading = move.heading,
    })

    onCell()                        -- the corner the turtle already occupies
    side = mineLayer(w, d, side, onCell, levelY)

    if layer < h then
      move.turn("right")            -- face back along the row just finished
      move.turn("right")
      local nextY = levelY + stride
      local ok, reason = goToLevel(nextY)
      if not ok then
        error(("cannot reach level %d from %d,%d,%d: %s"):format(
          nextY, move.pos.x, move.pos.y, move.pos.z, tostring(reason)), 0)
      end
      levelY = nextY
    end
  end

  ctx.setProgress(total, total)
end

--------------------------------------------------------------------------------
-- Patterns
--------------------------------------------------------------------------------

-- The turtle starts on the surface and drops into the first layer, so home
-- stays out of the hole.
patterns.register("quarry", function(params, ctx)
  runLayers(params, ctx, "down", true)
end)

-- Starts at the turtle's own level and builds upward, so the floor it stands
-- on is the corridor floor.
patterns.register("tunnel", function(params, ctx)
  runLayers(params, ctx, "up", false)
end)

--------------------------------------------------------------------------------
-- Corridor traversal, shared by strip and stairs
--------------------------------------------------------------------------------

--- Clear `height` blocks of air including the one the turtle stands in, then
--- come back down to the floor.
--
-- A turtle can only dig the block directly above itself, so anything past two
-- costs a move up and a move back for each extra block. That is why height 2 is
-- the sensible default for a corridor: it is the tallest column that is free.
local function clearColumn(height)
  if height <= 1 then return end

  local risen = 0
  for i = 1, height - 1 do
    if not move.dig("up") then break end       -- bedrock ceiling: leave it be
    if i < height - 1 then
      if not move.step("up") then break end
      risen = risen + 1
    end
  end

  while risen > 0 do
    if not move.step("down") then break end
    risen = risen - 1
  end
end

--- Clear a `width` wide, `height` tall slice centred on the turtle's column,
--- extending to its right, and return to the starting block and heading.
local function clearSlice(width, height)
  clearColumn(height)
  if width <= 1 then return end

  move.turnRight()
  local out = 0
  for _ = 1, width - 1 do
    if not move.step("forward") then break end
    out = out + 1
    clearColumn(height)
  end

  move.turnRight()
  move.turnRight()
  for _ = 1, out do
    if not move.step("forward") then break end
  end
  move.turnRight()
end

--- Mine `count` cells straight ahead, clearing each to `height`. Returns how
--- many it actually managed.
--
-- Stopping short is normal, not a failure: a branch that runs into bedrock has
-- simply reached its end, and failing the whole job over it would throw away
-- every other branch.
local function mineRun(count, params, onCell)
  local done = 0
  for _ = 1, count do
    if not move.step("forward") then break end
    clearColumn(params.height)
    follow(params)
    done = done + 1
    if onCell then onCell() end
  end
  return done
end

--- Walk back `count` cells the way we came, digging through anything that has
--- fallen in behind (gravel, a mob-shoved block).
local function walkBack(count)
  for _ = 1, count do
    if not move.step("forward") then break end
  end
end

--------------------------------------------------------------------------------
-- strip
--------------------------------------------------------------------------------

-- Branch mining: one corridor with ribs off both sides. Every block in the
-- ground ends up within a block or two of a mined face, which is why this
-- yields more ore per unit of fuel than any volume pattern.
--
-- The turtle starts at the corridor mouth facing along it and stays at that
-- level throughout, so `home` is the corridor entrance.
patterns.register("strip", function(params, ctx)
  local length, branch = params.length, params.branch
  local spacing, height = params.spacing, params.height

  -- `length` counts the corridor mouth the turtle already stands on, so there
  -- are length-1 blocks to advance through and that is the range branch points
  -- are drawn from.
  local points = math.floor((length - 1) / spacing)
  local total  = length + 2 * branch * points

  local first, done = 1, 0

  if ctx.resume then
    first = ctx.resume.step or 1
    done  = ctx.resume.done or 0
    ctx.setProgress(done, total)
    local ok, reason = move.goTo(ctx.resume.pos.x, ctx.resume.pos.y, ctx.resume.pos.z)
    if not ok then error("cannot reach resume point: " .. tostring(reason), 0) end
    move.face(ctx.resume.heading)
  end

  local function onCell()
    done = done + 1
    ctx.setProgress(done, total)
  end

  if first == 1 then
    clearColumn(height)               -- the mouth the turtle already occupies
    follow(params)
    onCell()
  end

  for i = first, length - 1 do
    -- Checkpoint at the corridor, never mid-branch: resuming onto the corridor
    -- and redoing a branch pair is cheap and always geometrically valid.
    ctx.checkpoint({
      step    = i,
      done    = done,
      pos     = move.copyPos(),
      heading = move.heading,
    })

    if mineRun(1, params, onCell) == 0 then break end

    if i % spacing == 0 then
      -- Out to the left, back, out to the right, back. Coming back from the
      -- left branch already leaves the turtle facing right, so the second
      -- branch needs no extra turn.
      move.turnLeft()
      local out = mineRun(branch, params, onCell)
      move.turnRight(); move.turnRight()
      walkBack(out)

      out = mineRun(branch, params, onCell)
      move.turnRight(); move.turnRight()
      walkBack(out)

      move.turnRight()                -- back to the corridor heading
    end
  end

  ctx.setProgress(total, total)
end)

--------------------------------------------------------------------------------
-- stairs
--------------------------------------------------------------------------------

-- A walkable staircase: one block forward and one block down per tread, with
-- headroom cleared so a player can actually use it. Ends at the bottom, and
-- goHome climbs back up the way it came.
patterns.register("stairs", function(params, ctx)
  local depth, width, headroom = params.depth, params.width, params.headroom
  local total = depth

  local first, done = 1, 0

  if ctx.resume then
    first = ctx.resume.step or 1
    done  = ctx.resume.done or 0
    ctx.setProgress(done, total)
    local ok, reason = move.goTo(ctx.resume.pos.x, ctx.resume.pos.y, ctx.resume.pos.z)
    if not ok then error("cannot reach resume point: " .. tostring(reason), 0) end
    move.face(ctx.resume.heading)
  end

  local function onCell()
    done = done + 1
    ctx.setProgress(done, total)
  end

  for i = first, depth do
    ctx.checkpoint({
      step    = i,
      done    = done,
      pos     = move.copyPos(),
      heading = move.heading,
    })

    if not move.step("forward") then break end
    if not move.step("down") then break end
    clearSlice(width, headroom)
    follow(params)
    onCell()
  end

  ctx.setProgress(total, total)
end)

--------------------------------------------------------------------------------
-- harvest
--------------------------------------------------------------------------------

-- Go to a seam a scout found and take it. The job's `origin` does the
-- travelling -- miner.lua walks there before this runs -- so all that is left
-- is the vein following that already exists.
--
-- Getting there digs a tunnel to the centre of the seam, which means the turtle
-- arrives standing in or beside the ore. That is exactly where veins.harvest
-- expects to start.
patterns.register("harvest", function(params, ctx)
  ctx.checkpoint({
    step    = 1,
    done    = 0,
    pos     = move.copyPos(),
    heading = move.heading,
  })

  local taken = veins.harvest({ radius = params.radius, max = params.max })

  -- Progress is blocks taken against what was actually there, because nobody
  -- knows how big a seam is until it has been followed to the end.
  ctx.setProgress(taken, math.max(taken, 1))
  if ctx.report then ctx.report({ harvested = taken }) end
end)

--------------------------------------------------------------------------------
-- survey
--------------------------------------------------------------------------------

-- A scout drops through open air, scanning as it goes, and climbs back.
--
-- It has no pickaxe -- both upgrade slots go to the geo scanner and the modem --
-- so every move here is move.drift, which refuses rather than digs. Its natural
-- habitat is the hole the miners have already made: descending an open quarry
-- and scanning the walls finds precisely the ore the lanes are about to reach or
-- have just missed. Started somewhere solid it scans once and comes back, which
-- is the honest outcome rather than an error.
patterns.register("survey", function(params, ctx)
  local depth, radius, step = params.depth, params.radius, params.step
  local total  = math.floor(depth / step) + 1
  local startY = move.pos.y
  local done, seen = 0, {}

  local function scanHere()
    local hits, why = scanner.scan(radius)
    done = done + 1
    ctx.setProgress(done, total)
    if not hits then return false, why end

    for _, o in ipairs(scanner.ores(hits)) do
      -- The same block shows up from several scan positions, so key by
      -- position and let the clustering see each one once.
      seen[("%d,%d,%d"):format(o.x, o.y, o.z)] = o
    end
    return true
  end

  local ok, why = scanHere()
  if not ok then error("scan failed: " .. tostring(why), 0) end

  local dropped = 0
  while dropped < depth do
    local fell = 0
    for _ = 1, math.min(step, depth - dropped) do
      if not move.drift("down") then break end
      fell = fell + 1
    end
    if fell == 0 then break end          -- solid floor: this is as deep as it goes
    dropped = dropped + fell

    local scanned = scanHere()
    if not scanned then break end        -- no fuel to scan, or scanner stuck
  end

  -- Climb back to the level it started on, so home is a straight run up and the
  -- scout is out of the way of whatever is mining below it.
  while move.pos.y < startY do
    if not move.drift("up") then break end
  end

  local list = {}
  for _, o in pairs(seen) do list[#list + 1] = o end

  local clusters = {}
  for _, c in ipairs(scanner.cluster(list, config.clusterGap)) do
    -- A lone block is not worth a round trip; the vein following a passing
    -- miner does will pick it up eventually.
    if c.count >= config.clusterMin then clusters[#clusters + 1] = c end
  end

  ctx.setProgress(total, total)
  if ctx.report then
    ctx.report({ clusters = clusters, blocks = #list, scans = done })
  end
end)

return patterns
