--- Ore vein following.
--
-- A tunnel that walks past a diamond vein one block to the side has wasted the
-- trip. This module lets a pattern chase a vein it has exposed and then put the
-- turtle back exactly where it was, so the traversal above it never notices.
--
-- It is kept out of lib/move.lua deliberately: it is a movement-layer concern
-- and goes through move for every step, but it is a self-contained search with
-- its own bookkeeping rather than another guard on a single block of travel.
--
-- Safety comes entirely from the two caps in config. A turtle that clips the
-- edge of an ore-lined ravine will otherwise happily walk to the horizon.

local config = require("lib.config")
local move   = require("lib.move")

local veins = {}

-- Neighbours of a cell. "left" and "right" are turns followed by a forward
-- step; "back" is deliberately absent, since that is the cell we arrived from.
local SIDES = { "forward", "left", "right", "up", "down" }

--- True if `data` from turtle.inspect looks like ore.
--
-- Tags first: CC:T reports them for modded ores too, so a tag test picks up
-- ores this project has never heard of. The name list is the fallback for
-- builds that report no tags.
function veins.isOre(data)
  if type(data) ~= "table" then return false end

  if type(data.tags) == "table" then
    for tag in pairs(data.tags) do
      if config.oreTag[tag] then return true end
    end
  end

  return config.ore[data.name] or false
end

--- Face the neighbour `side` refers to, and report which axis to travel along.
--- Turning is the caller's to undo -- see restore().
local function faceSide(side)
  if side == "left" then
    move.turnLeft()
    return "forward"
  elseif side == "right" then
    move.turnRight()
    return "forward"
  end
  return side
end

local function restore(side)
  if side == "left" then
    move.turnRight()
  elseif side == "right" then
    move.turnLeft()
  end
end

local function inspectDir(dir)
  if dir == "up" then return turtle.inspectUp() end
  if dir == "down" then return turtle.inspectDown() end
  return turtle.inspect()
end

--- Where the turtle would land if it moved one block along `dir`.
local function ahead(dir)
  local p = move.copyPos()
  if dir == "up" then
    p.y = p.y + 1
  elseif dir == "down" then
    p.y = p.y - 1
  else
    local d = move.delta()
    p.x, p.z = p.x + d.x, p.z + d.z
  end
  return p
end

local function distance(a, b)
  return math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z)
end

--- Undo one recorded step, putting the turtle back on the cell it came from.
local function retrace(entry)
  if entry.dir == "up" then
    move.step("down")
  elseif entry.dir == "down" then
    move.step("up")
  else
    move.turnRight(); move.turnRight()
    move.step("forward")
    move.face(entry.heading)
  end
end

--- Chase the vein reachable from the turtle's current cell, then come back.
--
-- Returns the number of blocks taken. The turtle finishes on the block and
-- heading it started on, which is what lets a pattern call this mid-row and
-- carry on as though nothing had happened.
--
-- Depth-first with an explicit stack rather than recursion: the unwind has to
-- happen move by move in reverse, and blowing the Lua stack halfway down a vein
-- would leave the turtle stranded off its row with no way back.
--
-- Mined cells need no "visited" set. Digging an ore turns it into air, and air
-- does not look like ore, so the search cannot revisit what it has taken.
function veins.harvest(opts)
  opts = opts or {}
  local maxBlocks = opts.max or config.veinMax
  local maxRadius = opts.radius or config.veinRadius

  local origin        = move.copyPos()
  local originHeading = move.heading
  local taken         = 0
  local stack         = {}

  while true do
    local stepped = false

    if taken < maxBlocks then
      for _, side in ipairs(SIDES) do
        local dir = faceSide(side)
        local seen, data = inspectDir(dir)

        -- Radius is measured against the cell we would land on, not the one we
        -- are standing on, so the cap is never overshot by a block.
        if seen and veins.isOre(data) and distance(ahead(dir), origin) <= maxRadius then
          local heading = move.heading
          if move.step(dir) then
            stack[#stack + 1] = { dir = dir, heading = heading }
            taken = taken + 1
            stepped = true
            break
          end
        end

        restore(side)
      end
    end

    if not stepped then
      local entry = table.remove(stack)
      if not entry then break end
      retrace(entry)
    end
  end

  -- retrace should already have walked us home. goTo is the belt and braces for
  -- the case where a step back failed and left the turtle off the path.
  if move.pos.x ~= origin.x or move.pos.y ~= origin.y or move.pos.z ~= origin.z then
    move.goTo(origin.x, origin.y, origin.z)
  end
  move.face(originHeading)

  return taken
end

return veins
