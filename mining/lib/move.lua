--- Guarded movement, position tracking, fuel and inventory management.
--
-- Pattern code must go through this module and never call turtle.forward() or
-- turtle.dig() directly. Every function here either succeeds, returns
-- `false, reason`, or raises a control signal (see move.signal) that unwinds
-- the pattern so miner.lua can react.

local config = require("lib.config")

local move = {}

-- heading: 0 = +z (south), 1 = -x (west), 2 = -z (north), 3 = +x (east).
-- Turning right increments, matching Minecraft's yaw order.
local DELTA = {
  [0] = { x =  0, z =  1 },
  [1] = { x = -1, z =  0 },
  [2] = { x =  0, z = -1 },
  [3] = { x =  1, z =  0 },
}
local HEADING_NAME = { [0] = "S", [1] = "W", [2] = "N", [3] = "E" }

local inspect = { forward = turtle.inspect,  up = turtle.inspectUp,  down = turtle.inspectDown  }
local detect  = { forward = turtle.detect,   up = turtle.detectUp,   down = turtle.detectDown   }
local dig     = { forward = turtle.dig,      up = turtle.digUp,      down = turtle.digDown      }
local attack  = { forward = turtle.attack,   up = turtle.attackUp,   down = turtle.attackDown   }
local go      = { forward = turtle.forward,  up = turtle.up,         down = turtle.down         }
local drop    = { forward = turtle.drop,     up = turtle.dropUp,     down = turtle.dropDown     }
local place   = { forward = turtle.place,    up = turtle.placeUp,    down = turtle.placeDown    }

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

move.pos         = { x = 0, y = 0, z = 0 }
move.heading     = 0
move.home        = { x = 0, y = 0, z = 0 }
move.homeHeading = 0
move.mined       = 0
move.gps         = false      -- true if pos is a real world coordinate
move.returning   = false      -- suspends the fuel guard and the return signal
move.dumping     = false      -- true for the whole walk-home-and-back dump run
move.dumpRuns    = 0          -- how many times the turtle has been home to empty

-- False on a turtle with no tool -- a scout, which spends both upgrade slots on
-- a geo scanner and a modem. Without this every blocked move would burn the
-- whole retry budget attacking thin air before admitting a turtle with no
-- pickaxe was never going to get through.
move.canDig      = true
move.ctl         = { paused = false, abort = false, returnHome = false }

function move.headingName() return HEADING_NAME[move.heading] end

--- The x/z step one block forward for `heading` (default: the current one).
function move.delta(heading) return DELTA[(heading or move.heading) % 4] end

function move.copyPos(p)
  p = p or move.pos
  return { x = p.x, y = p.y, z = p.z }
end

--------------------------------------------------------------------------------
-- Control signals
--------------------------------------------------------------------------------

-- Raised as a table through error() so a signal unwinds out of arbitrarily deep
-- pattern code without every caller having to thread a return value.
-- kind is one of: "abort", "return", "fuel", "inventory".
function move.signal(kind, detail)
  error({ __miner = kind, detail = detail }, 0)
end

function move.isSignal(err)
  if type(err) == "table" and err.__miner then return err.__miner, err.detail end
  return nil
end

--- Cooperative checkpoint. Called by every guarded move, so pause and abort
--- take effect within one block rather than at the end of a layer.
function move.yield()
  local ctl = move.ctl
  if ctl.abort and not move.returning then move.signal("abort") end
  if ctl.returnHome and not move.returning then move.signal("return") end
  while ctl.paused do
    if ctl.abort and not move.returning then move.signal("abort") end
    if ctl.returnHome and not move.returning then move.signal("return") end
    os.sleep(0.2)
  end
end

--------------------------------------------------------------------------------
-- Fuel
--------------------------------------------------------------------------------

--- Manhattan distance home, which is exactly the fuel cost of walking it.
function move.fuelToHome()
  local h = move.home
  return math.abs(move.pos.x - h.x)
       + math.abs(move.pos.y - h.y)
       + math.abs(move.pos.z - h.z)
end

--- Burn anything in the whitelist. Returns the new fuel level.
function move.refuel()
  local selected = turtle.getSelectedSlot()
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and config.fuel[item.name] then
      turtle.select(slot)
      turtle.refuel()
    end
  end
  turtle.select(selected)
  return turtle.getFuelLevel()
end

--- True if there is enough fuel for `extra` more moves plus the walk home.
function move.hasFuel(extra)
  local level = turtle.getFuelLevel()
  if level == "unlimited" then return true end
  return level >= move.fuelToHome() + (extra or 1) + config.fuelMargin
end

local function fuelGuard()
  if move.returning then return end          -- getting home outranks the margin
  if move.hasFuel(1) then return end
  move.refuel()
  if move.hasFuel(1) then return end
  move.signal("fuel", ("%s fuel left, %d needed to reach home")
    :format(tostring(turtle.getFuelLevel()), move.fuelToHome() + config.fuelMargin))
end

--------------------------------------------------------------------------------
-- Inventory
--------------------------------------------------------------------------------

local function firstJunkSlot()
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and config.junk[item.name] then return slot end
  end
end

--- Throw away filtered junk. Tries forward, down, then up, since any single
--- direction may be solid rock.
function move.dropJunk()
  local selected = turtle.getSelectedSlot()
  local dropped = 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and config.junk[item.name] and not config.keep[item.name] then
      turtle.select(slot)
      for _, dir in ipairs({ "forward", "down", "up" }) do
        if drop[dir]() then dropped = dropped + 1 break end
      end
    end
  end
  turtle.select(selected)
  return dropped
end

local function dumpChestSlot()
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and config.dumpChest[item.name] then return slot end
  end
end

--- Place the carried dump chest above, empty everything worth keeping into it,
--- then break the chest and pick it back up.
function move.unload()
  local chest = dumpChestSlot()
  if not chest then return false, "no dump chest" end

  local selected = turtle.getSelectedSlot()
  turtle.select(chest)

  -- Raw digUp, not move.dig: move.dig calls ensureInventory, which calls back
  -- into unload. The inspect is not optional though -- lava above pours onto
  -- the turtle the instant the block goes, and bedrock burns the retry budget.
  -- It is inside the loop because gravel keeps falling into the cleared space.
  for _ = 1, 8 do
    if not detect.up() then break end
    local seen, above = inspect.up()
    if seen and (config.hazard[above.name] or config.unbreakable[above.name]) then
      turtle.select(selected)
      return false, "cannot clear " .. above.name .. " above"
    end
    turtle.digUp()
  end
  if detect.up() then
    turtle.select(selected)
    return false, "no room to place chest"
  end
  if not place.up() then
    turtle.select(selected)
    return false, "could not place chest"
  end

  for slot = 1, 16 do
    if slot ~= chest then
      local item = turtle.getItemDetail(slot)
      if item and not config.keep[item.name] then
        turtle.select(slot)
        drop.up()
      end
    end
  end

  turtle.select(chest)
  turtle.digUp()                    -- reclaim the chest
  turtle.select(selected)

  -- A chest that needs silk touch (vanilla ender chest) shatters instead of
  -- dropping itself, so the next unload would silently find nothing to place.
  -- Say so once, here, rather than failing obscurely a hundred blocks later.
  if not dumpChestSlot() then return false, "dump chest was destroyed, not recovered" end
  return true
end

--- Empty everything worth keeping into a container next to the home position.
--- Checks down, then forward, then up. Returns true, or false plus a reason.
--
-- It will only drop into a block it has confirmed is a container. Dropping at
-- open air succeeds as far as turtle.drop is concerned and scatters the entire
-- haul across the floor, which looks like a working unload right up until the
-- items despawn.
local function depositAtHome()
  local found
  for _, dir in ipairs({ "down", "forward", "up" }) do
    local seen, block = inspect[dir]()
    if seen and config.container[block.name] then found = dir break end
  end
  if not found then return false, "no container at home" end

  local selected = turtle.getSelectedSlot()
  local moved = 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and not config.keep[item.name] then
      turtle.select(slot)
      if drop[found]() then moved = moved + 1 end
    end
  end
  turtle.select(selected)

  if turtle.getItemCount(16) > 0 then return false, "container is full" end
  return true, moved
end

--- Walk home, empty into the container there, and walk back to carry on.
--- Returns true if the turtle is back at work with room in its inventory.
--
-- This is why a vanilla world can run a job longer than sixteen stacks. The
-- pattern never learns it happened: it resumes on the exact block and heading it
-- left, so as far as the traversal is concerned the turtle never moved.
function move.dumpRun()
  if not config.dumpAtHome then return false, "dump-at-home disabled" end
  if move.dumping or move.returning then return false, "already travelling" end

  -- A round trip, not the usual one-way reserve. A turtle that walks home to
  -- empty and cannot get back out is worse off than one that stops where it is.
  local level = turtle.getFuelLevel()
  if level ~= "unlimited" then
    local needed = 2 * move.fuelToHome() + config.fuelMargin
    if level < needed then
      return false, ("not enough fuel for a round trip (%d < %d)"):format(level, needed)
    end
  end

  local resume = { pos = move.copyPos(), heading = move.heading }

  move.dumping = true
  move.returning = true                    -- suspend the guards for the trip home
  local wentHome, homeWhy = move.goHome()
  move.returning = false

  if not wentHome then
    move.dumping = false
    return false, "could not reach home: " .. tostring(homeWhy)
  end

  local emptied, why = depositAtHome()
  if not emptied then
    move.dumping = false
    return false, why
  end

  -- Guards are live again on the way back: a recall or abort issued while the
  -- turtle is at home should stop it here rather than march it back down a hole.
  local back, backWhy = move.goTo(resume.pos.x, resume.pos.y, resume.pos.z)
  move.dumping = false
  if not back then return false, "could not return to the job: " .. tostring(backWhy) end

  move.face(resume.heading)
  move.dumpRuns = move.dumpRuns + 1
  return true
end

--- Slot 16 occupied means the next dig could void an item, so make room now.
--- Escalates: throw junk away, fill the carried chest, walk home to empty, and
--- only then admit defeat.
function move.ensureInventory()
  if turtle.getItemCount(16) == 0 then return true end

  move.dropJunk()
  if turtle.getItemCount(16) == 0 then return true end

  local ok, why = move.unload()
  if ok and turtle.getItemCount(16) == 0 then return true end

  local dumped, dumpWhy = move.dumpRun()
  if dumped and turtle.getItemCount(16) == 0 then return true end
  why = dumpWhy or why

  return false, why and ("inventory full: " .. why) or "inventory full"
end

--- Make room, or raise a signal so the job stops cleanly and stays resumable.
--
-- Skipped while travelling. On the way home a full inventory is not worth
-- stopping for -- voiding a block is cheaper than stranding the turtle -- and
-- during a dump run the guard would re-enter the very function that started it.
local function inventoryGuard()
  if move.returning or move.dumping then return end
  local ok, reason = move.ensureInventory()
  if not ok then move.signal("inventory", reason) end
end

--------------------------------------------------------------------------------
-- Digging
--------------------------------------------------------------------------------

--- Dig in `dir`, handling falling blocks. Returns true on a clear space,
--- or false plus one of: "unbreakable", "hazard", "undiggable".
function move.dig(dir)
  if not detect[dir]() then return true end
  if not move.canDig then return false, "no tool" end

  local ok, data = inspect[dir]()
  if ok then
    if config.unbreakable[data.name] then return false, "unbreakable", data.name end
    if config.hazard[data.name] then return false, "hazard", data.name end
  end

  inventoryGuard()

  -- Gravel and sand refill the space, so keep digging until it stays clear.
  for _ = 1, config.maxRetries do
    local dug = dig[dir]()
    if dug then move.mined = move.mined + 1 end
    if not detect[dir]() then return true end
    if not dug then
      local ok2, data2 = inspect[dir]()
      if ok2 and config.unbreakable[data2.name] then return false, "unbreakable", data2.name end
      if ok2 and config.hazard[data2.name] then return false, "hazard", data2.name end
      attack[dir]()                 -- something alive is standing in the block
      os.sleep(0.2)
    end
  end
  return false, "undiggable"
end

--- Drop a junk block into a lava space so it can be dug and walked through.
local function sealHazard(dir)
  local slot = firstJunkSlot()
  if not slot then return false end
  local selected = turtle.getSelectedSlot()
  turtle.select(slot)
  local placed = place[dir]()
  turtle.select(selected)
  return placed
end

--------------------------------------------------------------------------------
-- Movement
--------------------------------------------------------------------------------

local function applyStep(dir)
  if dir == "up" then
    move.pos.y = move.pos.y + 1
  elseif dir == "down" then
    move.pos.y = move.pos.y - 1
  else
    local d = DELTA[move.heading]
    move.pos.x = move.pos.x + d.x
    move.pos.z = move.pos.z + d.z
  end
end

--- Move one block in `dir` ("forward", "up", "down"), digging what is in the
--- way. Returns true, or false plus a reason. Raises a control signal for
--- pause/abort/return and for terminal fuel exhaustion.
function move.step(dir)
  move.yield()
  fuelGuard()
  inventoryGuard()

  for _ = 1, config.maxRetries do
    local moved, why = go[dir]()
    if moved then
      applyStep(dir)
      return true
    end

    -- turtle.forward reports "Out of fuel" rather than failing to detect a
    -- block; retrying that 64 times just wastes wall-clock time. The tank is
    -- genuinely dry here (fuelGuard already refuelled and passed), so raise the
    -- fuel signal rather than returning a string a caller might mistake for an
    -- obstruction -- unless we are already walking home, where the caller needs
    -- the failure back so it can report the turtle as stranded.
    if type(why) == "string" and why:lower():find("fuel") then
      if move.returning then return false, "out of fuel" end
      move.signal("fuel", "tank empty at " .. move.pos.x .. "," .. move.pos.y .. "," .. move.pos.z)
    end

    if detect[dir]() then
      local ok, reason, name = move.dig(dir)
      if not ok then
        if reason == "hazard" and sealHazard(dir) then
          -- sealed; loop round and try the block again
        else
          return false, reason, name
        end
      end
    else
      -- Nothing solid there: a mob, a boat, or the world is still loading.
      attack[dir]()
      os.sleep(0.2)
    end
    move.yield()
  end

  return false, "blocked"
end

--- Move one block only if the space is already clear. Same guards and the same
--- position tracking as step, but it never digs and never attacks.
--
-- This is how a scout travels: it has no tool, so an occupied block is simply
-- somewhere it cannot go, and the honest answer is to say so immediately.
function move.drift(dir)
  move.yield()
  fuelGuard()

  if detect[dir]() then return false, "blocked" end
  local moved, why = go[dir]()
  if not moved then return false, tostring(why or "could not move") end

  applyStep(dir)
  return true
end

--- Step over an obstruction the turtle cannot dig: up, across, back down.
--- Used to keep a layer going when a column hits bedrock or lava.
function move.detour()
  if not move.step("up") then return false, "cannot rise" end
  if not move.step("forward") then
    move.step("down")
    return false, "cannot pass"
  end
  if not move.step("down") then
    return true, "stayed high"   -- above the obstruction but could not descend
  end
  return true
end

function move.turnRight()
  move.yield()
  if not turtle.turnRight() then return false, "turn failed" end
  move.heading = (move.heading + 1) % 4
  return true
end

function move.turnLeft()
  move.yield()
  if not turtle.turnLeft() then return false, "turn failed" end
  move.heading = (move.heading + 3) % 4
  return true
end

function move.turn(side)
  if side == "left" then return move.turnLeft() end
  return move.turnRight()
end

function move.face(heading)
  heading = heading % 4
  local diff = (heading - move.heading) % 4
  if diff == 1 then
    return move.turnRight()
  elseif diff == 2 then
    return move.turnRight() and move.turnRight()
  elseif diff == 3 then
    return move.turnLeft()
  end
  return true
end

--- Walk to a coordinate, digging through anything in between. Rises first and
--- descends last so the turtle travels above the hole it just dug.
function move.goTo(tx, ty, tz)
  while move.pos.y < ty do
    local ok, reason = move.step("up")
    if not ok then return false, reason end
  end

  if move.pos.x ~= tx then
    move.face(tx > move.pos.x and 3 or 1)
    while move.pos.x ~= tx do
      local ok, reason = move.step("forward")
      if not ok and not move.detour() then return false, reason end
    end
  end

  if move.pos.z ~= tz then
    move.face(tz > move.pos.z and 0 or 2)
    while move.pos.z ~= tz do
      local ok, reason = move.step("forward")
      if not ok and not move.detour() then return false, reason end
    end
  end

  while move.pos.y > ty do
    local ok, reason = move.step("down")
    if not ok then return false, reason end
  end

  return true
end

--- Return to the recorded origin. Ignores the fuel margin and the return
--- signal, because this *is* the return.
function move.goHome()
  move.returning = true
  -- Two failure modes, and they are easy to conflate: pcall reporting a raised
  -- error, and goTo returning false because it could not get through. Both mean
  -- the turtle is not home.
  local alive, arrived, reason = pcall(move.goTo, move.home.x, move.home.y, move.home.z)
  move.returning = false

  if not alive then return false, tostring(arrived) end
  if not arrived then return false, tostring(reason or "could not reach home") end

  local h = move.home
  if move.pos.x ~= h.x or move.pos.y ~= h.y or move.pos.z ~= h.z then
    return false, ("stopped at %d,%d,%d"):format(move.pos.x, move.pos.y, move.pos.z)
  end

  move.face(move.homeHeading)
  return true
end

--------------------------------------------------------------------------------
-- Calibration
--------------------------------------------------------------------------------

--- Work out which way the turtle is pointing by moving one block and comparing
--- GPS fixes. Restores the original position before returning.
local function calibrateHeading()
  local x1, _, z1 = gps.locate(2)
  if not x1 then return false, "no gps" end

  local moved, sign
  if turtle.forward() then
    moved, sign = "forward", 1
  elseif turtle.back() then
    moved, sign = "back", -1
  else
    return false, "boxed in, cannot determine heading"
  end

  local x2, _, z2 = gps.locate(2)
  if moved == "forward" then turtle.back() else turtle.forward() end
  if not x2 then return false, "lost gps mid-calibration" end

  -- The step back may have failed (something moved in behind), so trust GPS
  -- over the assumption that we ended up where we started.
  local x3, y3, z3 = gps.locate(2)
  if x3 then move.pos = { x = x3, y = y3, z = z3 } end

  local dx, dz = (x2 - x1) * sign, (z2 - z1) * sign
  for heading, d in pairs(DELTA) do
    if d.x == dx and d.z == dz then
      move.heading = heading
      return true
    end
  end
  return false, "ambiguous gps fix"
end

--- Establish the coordinate frame. Prefers GPS; falls back to dead reckoning
--- from `origin` (default 0,0,0 with the current facing treated as heading 0).
-- Returns gpsAvailable, note.
function move.calibrate(origin, heading)
  local x, y, z = gps.locate(2)
  if x then
    move.pos = { x = x, y = y, z = z }
    move.gps = true
    local ok, reason = calibrateHeading()
    if not ok then
      move.heading = heading or 0
      move.gps = true
      move.home = move.copyPos()
      move.homeHeading = move.heading
      return true, "gps position, assumed heading (" .. reason .. ")"
    end
  else
    move.pos = origin and move.copyPos(origin) or { x = 0, y = 0, z = 0 }
    move.heading = heading or 0
    move.gps = false
  end

  move.home = move.copyPos()
  move.homeHeading = move.heading
  return move.gps, move.gps and "gps locked" or "dead reckoning from origin"
end

--- Restore a frame loaded from the state file after a reboot.
function move.restore(saved)
  move.pos         = move.copyPos(saved.pos)
  move.heading     = saved.heading or 0
  move.home        = move.copyPos(saved.home)
  move.homeHeading = saved.homeHeading or 0
  move.mined       = saved.mined or 0

  -- If GPS is reachable it wins: the turtle may have been pushed while off.
  local x, y, z = gps.locate(2)
  if x then
    move.pos = { x = x, y = y, z = z }
    move.gps = true
    calibrateHeading()
  end
end

return move
