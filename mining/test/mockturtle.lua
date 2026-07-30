--- A fake turtle plus a fake world, good enough to run lib/move and
--- lib/patterns for real under CraftOS-PC (which has no turtle API).

local M = {}

local DELTA = {
  [0] = { x = 0, z = 1 }, [1] = { x = -1, z = 0 },
  [2] = { x = 0, z = -1 }, [3] = { x = 1, z = 0 },
}

local function key(x, y, z) return x .. "," .. y .. "," .. z end

function M.new(opts)
  opts = opts or {}
  local t = {
    pos     = { x = 0, y = 0, z = 0 },
    heading = 0,
    fuel    = opts.fuel or 100000,
    slots   = {},              -- [1..16] = {name=, count=}
    sel     = 1,
    world   = {},              -- key -> block name
    visited = {},              -- key -> true, every block ever removed
    moves   = 0,
    log     = {},
  }

  function t.setBlock(x, y, z, name) t.world[key(x, y, z)] = name end
  function t.blockAt(x, y, z) return t.world[key(x, y, z)] end

  --- Fill a solid box, inclusive.
  function t.fill(x1, y1, z1, x2, y2, z2, name)
    for x = math.min(x1, x2), math.max(x1, x2) do
      for y = math.min(y1, y2), math.max(y1, y2) do
        for z = math.min(z1, z2), math.max(z1, z2) do
          t.world[key(x, y, z)] = name or "minecraft:stone"
        end
      end
    end
  end

  local function ahead(dir)
    local p = t.pos
    if dir == "up" then return p.x, p.y + 1, p.z end
    if dir == "down" then return p.x, p.y - 1, p.z end
    local d = DELTA[t.heading]
    return p.x + d.x, p.y, p.z + d.z
  end

  local function firstFree()
    for i = 1, 16 do if not t.slots[i] then return i end end
  end

  local function give(name)
    for i = 1, 16 do
      if t.slots[i] and t.slots[i].name == name and t.slots[i].count < 64 then
        t.slots[i].count = t.slots[i].count + 1
        return true
      end
    end
    local free = firstFree()
    if not free then return false end          -- item is voided, as in game
    t.slots[free] = { name = name, count = 1 }
    return true
  end

  local turtle = {}

  -- A turtle that spins forever is a bug, not a slow test. Convert it into a
  -- catchable error so the suite reports which case hangs instead of timing out.
  t.budget = opts.budget or 400000
  local function spend()
    t.budget = t.budget - 1
    if t.budget <= 0 then error("mock turtle op budget exhausted (probable hang)", 0) end
  end

  local function detect(dir)
    spend()
    local x, y, z = ahead(dir)
    return t.world[key(x, y, z)] ~= nil
  end

  -- Modern CC:T reports block tags from inspect. Ore detection prefers them
  -- over a hardcoded name list, so the mock has to supply them.
  local function tagsFor(name)
    local tags = {}
    if name:find("_ore$") or name == "minecraft:ancient_debris" then
      tags["c:ores"] = true
      tags["forge:ores"] = true
    end
    return tags
  end

  local function inspect(dir)
    local x, y, z = ahead(dir)
    local name = t.world[key(x, y, z)]
    if not name then return false, "No block to inspect" end
    return true, { name = name, state = {}, tags = tagsFor(name) }
  end

  local function dig(dir)
    local x, y, z = ahead(dir)
    local k = key(x, y, z)
    local name = t.world[k]
    if not name then return false, "Nothing to dig here" end
    if name == "minecraft:bedrock" then return false, "Unbreakable block detected" end
    t.world[k] = nil
    t.visited[k] = true
    give(name)
    if t.onDig then t.onDig(x, y, z, name) end
    return true
  end

  local function move(dir)
    if t.fuel <= 0 then return false, "Out of fuel" end
    local x, y, z = ahead(dir)
    if t.world[key(x, y, z)] then return false, "Movement obstructed" end
    t.pos.x, t.pos.y, t.pos.z = x, y, z
    t.fuel = t.fuel - 1
    t.moves = t.moves + 1
    t.visited[key(x, y, z)] = true
    if t.onMove then t.onMove(x, y, z) end
    return true
  end

  turtle.forward  = function() return move("forward") end
  turtle.up       = function() return move("up") end
  turtle.down     = function() return move("down") end
  turtle.back     = function()
    t.heading = (t.heading + 2) % 4
    local ok, why = move("forward")
    t.heading = (t.heading + 2) % 4
    return ok, why
  end
  turtle.turnRight = function() t.heading = (t.heading + 1) % 4 return true end
  turtle.turnLeft  = function() t.heading = (t.heading + 3) % 4 return true end

  turtle.detect     = function() return detect("forward") end
  turtle.detectUp   = function() return detect("up") end
  turtle.detectDown = function() return detect("down") end
  turtle.inspect     = function() return inspect("forward") end
  turtle.inspectUp   = function() return inspect("up") end
  turtle.inspectDown = function() return inspect("down") end
  turtle.dig     = function() return dig("forward") end
  turtle.digUp   = function() return dig("up") end
  turtle.digDown = function() return dig("down") end
  turtle.attack     = function() return false end
  turtle.attackUp   = function() return false end
  turtle.attackDown = function() return false end

  local CONTAINER = {
    ["enderstorage:ender_chest"]  = true,
    ["ender_storage:ender_chest"] = true,
    ["minecraft:ender_chest"]     = true,
    ["minecraft:chest"]           = true,
    ["minecraft:trapped_chest"]   = true,
    ["minecraft:barrel"]          = true,
    ["minecraft:shulker_box"]     = true,
  }

  local function place(dir)
    local s = t.slots[t.sel]
    if not s then return false, "No items to place" end
    local x, y, z = ahead(dir)
    local k = key(x, y, z)
    local existing = t.world[k]
    -- Liquids and air are replaceable; solid blocks are not.
    if existing and existing ~= "minecraft:lava" and existing ~= "minecraft:flowing_lava" then
      return false, "Cannot place block here"
    end
    t.world[k] = s.name
    s.count = s.count - 1
    if s.count <= 0 then t.slots[t.sel] = nil end
    return true
  end
  turtle.place     = function() return place("forward") end
  turtle.placeUp   = function() return place("up") end
  turtle.placeDown = function() return place("down") end

  local function dropItems(dir)
    local s = t.slots[t.sel]
    if not s then return false, "No items to drop" end
    local x, y, z = ahead(dir)
    local block = t.world[key(x, y, z)]
    -- Into a container the items are inserted; into air they fall on the floor;
    -- a solid block has nowhere to put them.
    if block and not CONTAINER[block] then return false, "No space to drop" end
    if block and t.chestFull then return false, "No space in container" end
    t.dropped = (t.dropped or 0) + s.count
    if block then t.intoChest = (t.intoChest or 0) + s.count end
    t.slots[t.sel] = nil
    return true
  end
  turtle.drop     = function() return dropItems("forward") end
  turtle.dropUp   = function() return dropItems("up") end
  turtle.dropDown = function() return dropItems("down") end

  -- What a container yields to suck(), as a queue of {name, count}. Empty by
  -- default: a chest a player has not stocked is the normal case and the code
  -- has to cope with it.
  t.chestStock = {}

  local function suckItems(dir)
    local x, y, z = ahead(dir)
    local block = t.world[key(x, y, z)]
    if not block or not CONTAINER[block] then return false, "No container to take from" end
    if #t.chestStock == 0 then return false, "No items to take" end

    local entry = t.chestStock[1]
    local take = math.min(entry.count, 64)
    local free
    for i = 1, 16 do if not t.slots[i] then free = i break end end
    if not free then return false, "No space in inventory" end

    t.slots[free] = { name = entry.name, count = take }
    entry.count = entry.count - take
    if entry.count <= 0 then table.remove(t.chestStock, 1) end
    t.sucked = (t.sucked or 0) + take
    return true
  end

  turtle.suck     = function() return suckItems("forward") end
  turtle.suckUp   = function() return suckItems("up") end
  turtle.suckDown = function() return suckItems("down") end

  turtle.select          = function(n) t.sel = n return true end
  turtle.getSelectedSlot = function() return t.sel end
  turtle.getItemCount    = function(n) local s = t.slots[n or t.sel] return s and s.count or 0 end
  turtle.getItemDetail   = function(n)
    local s = t.slots[n or t.sel]
    if not s then return nil end
    return { name = s.name, count = s.count, damage = 0 }
  end
  turtle.getFuelLevel = function() return t.fuel end
  turtle.refuel = function(n)
    local s = t.slots[t.sel]
    if not s then return false, "No items to combust" end
    local per = ({ ["minecraft:coal"] = 80, ["minecraft:charcoal"] = 80,
                   ["minecraft:coal_block"] = 800 })[s.name]
    if not per then return false, "Items not combustible" end
    t.fuel = t.fuel + per * s.count
    t.slots[t.sel] = nil
    return true
  end

  t.api = turtle
  t.give = give

  ------------------------------------------------------------------------------
  -- Geo scanner
  ------------------------------------------------------------------------------

  --- Attach a fake Advanced Peripherals geo scanner.
  --
  -- `mode` is "relative" (what the real one does) or "absolute", so the frame
  -- detection can be tested both ways rather than only the way we expect.
  function t.attachScanner(opts)
    opts = opts or {}
    t.scanner = {
      mode      = opts.mode or "relative",
      costPer   = opts.costPer or 1,      -- fuel per unit of radius cubed-ish
      cooldown  = opts.cooldown or 0,     -- how many scans fail before one works
      scans     = 0,
      refusals  = 0,
    }

    local gs = {}

    function gs.cost(radius)
      return radius * t.scanner.costPer
    end

    function gs.getMaxFuelLevel() return 100000 end

    function gs.scan(radius)
      -- Refuse the first `cooldown` attempts, the way the real one does while
      -- it is recharging.
      if t.scanner.refusals < t.scanner.cooldown then
        t.scanner.refusals = t.scanner.refusals + 1
        return nil, "Scanner is on cooldown"
      end
      t.scanner.refusals = 0
      t.scanner.scans = t.scanner.scans + 1
      t.fuel = t.fuel - gs.cost(radius)

      local hits = {}
      for dx = -radius, radius do
        for dy = -radius, radius do
          for dz = -radius, radius do
            if math.abs(dx) + math.abs(dy) + math.abs(dz) <= radius then
              local wx, wy, wz = t.pos.x + dx, t.pos.y + dy, t.pos.z + dz
              local name = t.world[key(wx, wy, wz)]
              if name then
                local rel = (t.scanner.mode == "relative")
                hits[#hits + 1] = {
                  name = name,
                  tags = tagsFor(name),
                  x = rel and dx or wx,
                  y = rel and dy or wy,
                  z = rel and dz or wz,
                }
              end
            end
          end
        end
      end
      return hits
    end

    t.scannerPeripheral = gs
    return gs
  end

  return t
end

return M
