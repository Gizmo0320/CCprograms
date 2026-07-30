--- Runs lib/move, lib/patterns and lib/state against a mock turtle.
--- Results go to /results.txt; the terminal in headless mode is unreadable.

local out = {}
local flush
local function print(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  out[#out + 1] = table.concat(parts, " ")
  flush()                            -- so an uncaught error still leaves a trail
end
function flush()
  local f = fs.open("/test-results.txt", "w")
  for _, line in ipairs(out) do f.writeLine(line) end
  f.close()
end


local loaded = {}
function _G.require(name)
  if loaded[name] then return loaded[name] end
  local path = "/" .. name:gsub("%.", "/") .. ".lua"
  local fn, err = loadfile(path)
  if not fn then error("cannot load " .. path .. ": " .. tostring(err), 0) end
  local m = fn()
  loaded[name] = m
  return m
end

local mock = dofile("/test/mockturtle.lua")

-- Retry paths sleep 0.2s at a time. Keep the yield (CC kills a coroutine that
-- never yields) but drop the wall-clock cost.
local realSleep = os.sleep
os.sleep = function() return realSleep(0) end

local pass, fail = 0, 0

--- `quiet` assertions still count, but only show up when they fail. The
--- fixture's self-checks run before every single case; printing them all buries
--- the results they exist to protect.
local function report(ok, label, extra, quiet)
  if ok then
    pass = pass + 1
    if not quiet then print("  ok   " .. label) end
  else
    fail = fail + 1
    print("  FAIL " .. label .. (extra and ("  <" .. tostring(extra) .. ">") or ""))
  end
end

local function check(ok, label, extra) report(ok, label, extra, false) end
local function checkQuiet(ok, label, extra) report(ok, label, extra, true) end

--- Fresh turtle plus a completely fresh module graph. Everything is dropped,
--- not just lib.move: lib.specs holds the spec tables that lib.patterns writes
--- `run` into, so a half-cleared cache leaves patterns bound to an older
--- lib.move -- and therefore to an older mock world.
local function fixture(opts)
  local t = mock.new(opts)
  _G.turtle = t.api
  loaded = {}
  local move = require("lib.move")
  local patterns = require("lib.patterns")
  move.pos, move.heading = { x = 0, y = 0, z = 0 }, 0
  move.home, move.homeHeading = { x = 0, y = 0, z = 0 }, 0
  move.mined, move.returning = 0, false
  move.dumping, move.dumpRuns = false, 0
  move.ctl = { paused = false, abort = false, returnHome = false }

  -- Prove the wiring before trusting a single assertion made through it.
  t.setBlock(0, -1, 0, "minecraft:stone")
  local stepped, why = move.step("down")
  checkQuiet(stepped, "[fixture] turtle digs down through the new mock", why)
  checkQuiet(move.mined == 1, "[fixture] move.mined tracks the new mock", move.mined)
  checkQuiet(t.pos.y == -1, "[fixture] mock turtle actually moved", t.pos.y)
  move.step("up")
  t.world = {}
  t.slots = {}                       -- the probe put a block in slot 1
  t.sel = 1
  move.pos, move.heading = { x = 0, y = 0, z = 0 }, 0
  t.pos, t.heading = { x = 0, y = 0, z = 0 }, 0
  move.mined, t.moves, t.dropped, t.intoChest = 0, 0, 0, 0
  move.dumpRuns, t.chestFull = 0, false
  t.fuel = opts and opts.fuel or 100000
  return t, move, patterns
end

local function newCtx(resume)
  local ctx = { resume = resume, progress = 0, checkpoints = {} }
  ctx.setProgress = function(done, total)
    ctx.progress = (total and total > 0) and (done / total) or 0
    ctx.done, ctx.total = done, total
  end
  ctx.checkpoint = function(data) ctx.checkpoints[#ctx.checkpoints + 1] = data end
  return ctx
end

--- Every block in the w x d x h volume the quarry should have cleared.
local function footprintCleared(t, w, d, h)
  local missing = 0
  for layer = 1, h do
    local y = -layer
    for i = 0, w - 1 do
      for j = 0, d - 1 do
        if t.blockAt(-i, y, j) then missing = missing + 1 end
      end
    end
  end
  return missing
end

--------------------------------------------------------------------------------
print("quarry: full coverage")
--------------------------------------------------------------------------------
do
  local w, d, h = 4, 5, 3
  local t, move, patterns = fixture()
  t.fill(-10, -10, -10, 10, -1, 10, "minecraft:stone")

  local ctx = newCtx()
  local ok, err = pcall(patterns.get("quarry").run, { w = w, d = d, h = h }, ctx)
  check(ok, "run completes", err and (move.isSignal(err) or textutils.serialize(err)))
  check(footprintCleared(t, w, d, h) == 0, "every block in the footprint removed",
    footprintCleared(t, w, d, h) .. " left")
  check(move.mined == w * d * h, "mined count == w*d*h", move.mined)
  check(ctx.progress == 1, "progress reaches 1.0", ctx.progress)
  check(#ctx.checkpoints == h, "one checkpoint per layer", #ctx.checkpoints)
  check(move.pos.y == -h, "ends on the bottom layer", move.pos.y)

  local home = move.goHome()
  check(home, "returns home")
  check(move.pos.x == 0 and move.pos.y == 0 and move.pos.z == 0,
    "home is 0,0,0", ("%d,%d,%d"):format(move.pos.x, move.pos.y, move.pos.z))
  check(move.heading == 0, "restores home heading", move.heading)
end

--------------------------------------------------------------------------------
print("quarry: 1x1 and 1xN degenerate sizes")
--------------------------------------------------------------------------------
do
  local t, move, patterns = fixture()
  t.fill(-5, -5, -5, 5, -1, 5, "minecraft:stone")
  local ok, err = pcall(patterns.get("quarry").run, { w = 1, d = 1, h = 4 }, newCtx())
  check(ok, "1x1x4 completes", err and textutils.serialize(err))
  check(move.mined == 4, "mined 4", move.mined)

  local t2, move2, patterns2 = fixture()
  t2.fill(-5, -5, -5, 5, -1, 5, "minecraft:stone")
  local ok2, err2 = pcall(patterns2.get("quarry").run, { w = 1, d = 6, h = 2 }, newCtx())
  check(ok2, "1x6x2 completes", err2 and textutils.serialize(err2))
  check(move2.mined == 12, "mined 12", move2.mined)
end

--------------------------------------------------------------------------------
print("tunnel: builds upward from the current level")
--------------------------------------------------------------------------------
do
  local t, move, patterns = fixture()
  t.fill(-10, -2, -10, 10, 10, 10, "minecraft:stone")
  t.setBlock(0, 0, 0, nil)                    -- the turtle's own space
  local ok, err = pcall(patterns.get("tunnel").run, { w = 3, d = 8, h = 3 }, newCtx())
  check(ok, "run completes", err and textutils.serialize(err))
  check(move.mined == 3 * 8 * 3 - 1, "mined w*d*h minus its own starting block", move.mined)
  check(move.pos.y == 2, "ends two layers up", move.pos.y)
end

--------------------------------------------------------------------------------
print("strip: corridor and branch ribs land where they should")
--------------------------------------------------------------------------------
do
  -- Corridor runs +z from the mouth at 0,0,0. Branches run along x.
  local length, branch, spacing, height = 7, 2, 3, 2
  local t, move, patterns = fixture()
  t.fill(-20, -1, -20, 20, 8, 20, "minecraft:stone")
  t.setBlock(0, 0, 0, nil)                       -- the mouth the turtle occupies

  local ctx = newCtx()
  local ok, err = pcall(patterns.get("strip").run,
    { length = length, branch = branch, spacing = spacing, height = height }, ctx)
  check(ok, "run completes", err and textutils.serialize(err))

  local corridorOk, branchOk, headroomOk = true, true, true
  for z = 0, length - 1 do
    if t.blockAt(0, 0, z) then corridorOk = false end
    if t.blockAt(0, 1, z) then headroomOk = false end   -- height 2
  end
  check(corridorOk, "the whole corridor floor is clear")
  check(headroomOk, "and it is cleared to the requested height")

  -- length 7, spacing 3 -> branch points at z = 3 and z = 6.
  local points = math.floor((length - 1) / spacing)
  check(points == 2, "two branch points", points)
  for _, z in ipairs({ 3, 6 }) do
    for i = 1, branch do
      if t.blockAt(-i, 0, z) then branchOk = false end  -- left branch
      if t.blockAt(i, 0, z) then branchOk = false end   -- right branch
    end
  end
  check(branchOk, "both ribs are cut at every branch point")

  -- Nothing should be cut at a non-branch corridor position.
  check(t.blockAt(1, 0, 2) ~= nil and t.blockAt(-1, 0, 2) ~= nil,
    "and nowhere else")

  check(ctx.progress == 1, "progress reaches 1.0", ctx.progress)
  check(move.pos.z == length - 1 and move.pos.x == 0,
    "ends at the far end of the corridor",
    ("%d,%d"):format(move.pos.x, move.pos.z))
  check(move.heading == 0, "still facing along it", move.heading)
  check(move.goHome(), "and walks back to the mouth")
end

--------------------------------------------------------------------------------
print("stairs: descends one block per tread with headroom")
--------------------------------------------------------------------------------
do
  local depth, width, headroom = 8, 1, 3
  local t, move, patterns = fixture()
  t.fill(-20, -30, -20, 20, 8, 20, "minecraft:stone")
  t.setBlock(0, 0, 0, nil)

  local ctx = newCtx()
  local ok, err = pcall(patterns.get("stairs").run,
    { depth = depth, width = width, headroom = headroom }, ctx)
  check(ok, "run completes", err and textutils.serialize(err))

  check(move.pos.y == -depth, "ends `depth` blocks down", move.pos.y)
  check(move.pos.z == depth, "and `depth` blocks along", move.pos.z)

  local treadsOk, headOk = true, true
  for i = 1, depth do
    if t.blockAt(0, -i, i) then treadsOk = false end
    for up = 1, headroom - 1 do
      if t.blockAt(0, -i + up, i) then headOk = false end
    end
  end
  check(treadsOk, "every tread is clear")
  check(headOk, "with the requested headroom above each one")
  check(move.goHome(), "and it climbs back out")
end

--------------------------------------------------------------------------------
print("stairs: width sweeps sideways and returns to the centre line")
--------------------------------------------------------------------------------
do
  local t, move, patterns = fixture()
  t.fill(-20, -30, -20, 20, 8, 20, "minecraft:stone")
  t.setBlock(0, 0, 0, nil)

  local ok, err = pcall(patterns.get("stairs").run,
    { depth = 4, width = 3, headroom = 2 }, newCtx())
  check(ok, "run completes", err and textutils.serialize(err))
  check(move.pos.x == 0, "stays on the centre line", move.pos.x)
  check(move.heading == 0, "and keeps its heading", move.heading)

  -- The slice extends to the turtle's right. Facing +z (south), right is -x.
  local wideOk = true
  for i = 1, 4 do
    for x = 0, 2 do
      if t.blockAt(-x, -i, i) then wideOk = false end
    end
  end
  check(wideOk, "the full width is cut at every tread")
  check(t.blockAt(1, -1, 1) ~= nil, "and nothing is cut on the other side")
end

--------------------------------------------------------------------------------
print("veins: ore detection")
--------------------------------------------------------------------------------
do
  loaded = {}
  local t = mock.new()
  _G.turtle = t.api
  local veins = require("lib.veins")

  check(veins.isOre({ name = "minecraft:iron_ore", tags = { ["c:ores"] = true } }),
    "a tagged ore is ore")
  check(veins.isOre({ name = "minecraft:deepslate_diamond_ore", tags = {} }),
    "an untagged known ore falls back to the name list")
  check(veins.isOre({ name = "minecraft:ancient_debris", tags = {} }),
    "ancient debris counts")
  check(not veins.isOre({ name = "minecraft:stone", tags = {} }), "stone does not")
  check(not veins.isOre({ name = "minecraft:deepslate", tags = {} }), "nor deepslate")
  check(not veins.isOre(nil), "and nil is not an ore")
end

--------------------------------------------------------------------------------
print("veins: a blob beside the row is taken and the turtle comes back")
--------------------------------------------------------------------------------
do
  local t, move = fixture()
  loaded["lib.veins"] = nil
  local veins = require("lib.veins")
  t.fill(-10, -10, -10, 10, 10, 10, "minecraft:stone")
  t.setBlock(0, 0, 0, nil)

  -- An L-shaped vein hanging off the turtle's left and continuing away.
  local blob = { {-1,0,0}, {-2,0,0}, {-2,0,1}, {-2,1,1}, {-3,0,1} }
  for _, c in ipairs(blob) do t.setBlock(c[1], c[2], c[3], "minecraft:diamond_ore") end

  local taken = veins.harvest()
  check(taken == #blob, "every block of the vein is taken", taken)

  local allGone = true
  for _, c in ipairs(blob) do
    if t.blockAt(c[1], c[2], c[3]) then allGone = false end
  end
  check(allGone, "the vein really is gone from the world")
  check(move.pos.x == 0 and move.pos.y == 0 and move.pos.z == 0,
    "the turtle is back where it started",
    ("%d,%d,%d"):format(move.pos.x, move.pos.y, move.pos.z))
  check(move.heading == 0, "facing the way it was", move.heading)
  check(t.pos.x == 0 and t.pos.y == 0 and t.pos.z == 0,
    "and the mock agrees, so tracking did not drift")
end

--------------------------------------------------------------------------------
print("veins: the caps are respected")
--------------------------------------------------------------------------------
do
  local t, move = fixture()
  loaded["lib.veins"] = nil
  local veins = require("lib.veins")
  t.fill(-10, -10, -10, 10, 10, 10, "minecraft:stone")
  t.setBlock(0, 0, 0, nil)

  -- A seam of ore running far past the radius cap.
  for x = 1, 9 do t.setBlock(-x, 0, 0, "minecraft:iron_ore") end

  local taken = veins.harvest({ radius = 3 })
  check(taken == 3, "it stops at the radius cap", taken)
  check(t.blockAt(-4, 0, 0) == "minecraft:iron_ore", "leaving the rest in place")
  check(move.pos.x == 0 and move.pos.z == 0, "and still comes home", move.pos.x)
end

do
  -- A fresh seam: the radius run above already ate the blocks nearest the
  -- turtle, and a gap of air is not a vein to follow.
  local t, move = fixture()
  loaded["lib.veins"] = nil
  local veins = require("lib.veins")
  t.fill(-10, -10, -10, 10, 10, 10, "minecraft:stone")
  t.setBlock(0, 0, 0, nil)
  for x = 1, 9 do t.setBlock(-x, 0, 0, "minecraft:iron_ore") end

  local taken = veins.harvest({ max = 2 })
  check(taken == 2, "it stops at the block cap", taken)
  check(t.blockAt(-3, 0, 0) == "minecraft:iron_ore", "leaving the rest in place")
  check(move.pos.x == 0 and move.pos.z == 0, "and comes home", move.pos.x)
end

--------------------------------------------------------------------------------
print("veins: nothing to chase costs nothing")
--------------------------------------------------------------------------------
do
  local t, move = fixture()
  loaded["lib.veins"] = nil
  local veins = require("lib.veins")
  t.fill(-10, -10, -10, 10, 10, 10, "minecraft:stone")
  t.setBlock(0, 0, 0, nil)

  local before = t.moves
  check(veins.harvest() == 0, "no ore, nothing taken")
  check(t.moves == before, "and the turtle did not move at all", t.moves - before)
  check(move.heading == 0, "nor end up turned around", move.heading)
end

--------------------------------------------------------------------------------
print("veins: a tunnel with veins on collects ore off its path")
--------------------------------------------------------------------------------
do
  local t, move, patterns = fixture()
  t.fill(-10, -10, -10, 10, 10, 10, "minecraft:stone")
  t.setBlock(0, 0, 0, nil)
  -- A vein touching the corridor wall, running away from it. A plain tunnel
  -- exposes the first block and walks past the rest.
  t.setBlock(-1, 0, 2, "minecraft:gold_ore")
  t.setBlock(-2, 0, 2, "minecraft:gold_ore")
  t.setBlock(-3, 0, 2, "minecraft:gold_ore")
  -- And one sealed behind a block of stone, which nothing should reach.
  t.setBlock(-2, 0, 4, "minecraft:gold_ore")

  local ok, err = pcall(patterns.get("tunnel").run,
    { w = 1, d = 6, h = 2, veins = 1 }, newCtx())
  check(ok, "run completes", err and textutils.serialize(err))
  check(t.blockAt(-1, 0, 2) == nil and t.blockAt(-2, 0, 2) == nil
    and t.blockAt(-3, 0, 2) == nil, "the whole exposed vein was collected")
  check(t.blockAt(-2, 0, 4) == "minecraft:gold_ore",
    "but ore the turtle never saw is untouched -- it follows veins, not maps")

  -- Same job with the toggle off must leave the exposed vein alone too.
  local t2, _, patterns2 = fixture()
  t2.fill(-10, -10, -10, 10, 10, 10, "minecraft:stone")
  t2.setBlock(0, 0, 0, nil)
  t2.setBlock(-1, 0, 2, "minecraft:gold_ore")
  t2.setBlock(-2, 0, 2, "minecraft:gold_ore")
  local ok2 = pcall(patterns2.get("tunnel").run,
    { w = 1, d = 6, h = 2, veins = 0 }, newCtx())
  check(ok2, "run completes with veins off")
  check(t2.blockAt(-1, 0, 2) == "minecraft:gold_ore",
    "and with the toggle off the vein is left alone")
end

--------------------------------------------------------------------------------
print("bedrock: detours instead of failing the layer")
--------------------------------------------------------------------------------
do
  local t, move, patterns = fixture()
  t.fill(-10, -10, -10, 10, -1, 10, "minecraft:stone")
  t.setBlock(-1, -1, 2, "minecraft:bedrock")  -- mid-layer pillar
  t.setBlock(-2, -2, 3, "minecraft:bedrock")
  local ok, err = pcall(patterns.get("quarry").run, { w = 4, d = 5, h = 3 }, newCtx())
  check(ok, "run survives bedrock", err and textutils.serialize(err))
  check(t.blockAt(-1, -1, 2) == "minecraft:bedrock", "bedrock is still there")
  check(footprintCleared(t, 4, 5, 3) == 2, "only the bedrock blocks remain",
    footprintCleared(t, 4, 5, 3))
end

--------------------------------------------------------------------------------
print("bedrock: a ridge across a whole row is ridden over, not fatal")
--------------------------------------------------------------------------------
do
  local w, d, h = 4, 6, 2
  local t, move, patterns = fixture()
  t.fill(-10, -10, -10, 10, -1, 10, "minecraft:stone")
  -- A wall of bedrock across the full width of the top layer, mid-row.
  local ridge = 0
  for i = 0, w - 1 do
    t.setBlock(-i, -1, 3, "minecraft:bedrock")
    ridge = ridge + 1
  end
  local ok, err = pcall(patterns.get("quarry").run, { w = w, d = d, h = h }, newCtx())
  check(ok, "run survives a full-width ridge", err and textutils.serialize(err))
  check(footprintCleared(t, w, d, h) == ridge,
    "everything except the ridge is mined", footprintCleared(t, w, d, h))
  check(move.pos.y == -h, "and it still finished on the bottom layer", move.pos.y)
end

--------------------------------------------------------------------------------
print("lava: sealed with junk, then mined through")
--------------------------------------------------------------------------------
do
  local t, move, patterns = fixture()
  t.fill(-10, -10, -10, 10, -1, 10, "minecraft:stone")
  t.setBlock(0, -1, 2, "minecraft:lava")
  t.give("minecraft:cobblestone")
  t.give("minecraft:cobblestone")
  local ok, err = pcall(patterns.get("quarry").run, { w = 3, d = 4, h = 2 }, newCtx())
  check(ok, "run survives lava", err and textutils.serialize(err))
  check(t.blockAt(0, -1, 2) == nil, "the lava space ends up clear",
    tostring(t.blockAt(0, -1, 2)))
end

--------------------------------------------------------------------------------
print("fuel: guard raises a resumable signal, not a crash")
--------------------------------------------------------------------------------
do
  local t, move, patterns = fixture({ fuel = 80 })
  t.fill(-20, -20, -20, 20, -1, 20, "minecraft:stone")
  local ok, err = pcall(patterns.get("quarry").run, { w = 8, d = 8, h = 8 }, newCtx())
  check(not ok, "run stops")
  local kind, detail = move.isSignal(err)
  check(kind == "fuel", "signal is 'fuel'", kind or tostring(err))
  check(t.fuel >= move.fuelToHome(), "stopped with enough fuel to walk home",
    t.fuel .. " have, " .. move.fuelToHome() .. " needed")
  check(move.goHome(), "and it does get home")
end

--------------------------------------------------------------------------------
print("fuel: burns carried coal before giving up")
--------------------------------------------------------------------------------
do
  local t, move, patterns = fixture({ fuel = 200 })
  t.fill(-20, -20, -20, 20, -1, 20, "minecraft:stone")
  t.give("minecraft:coal") t.give("minecraft:coal") t.give("minecraft:coal")
  local ok = pcall(patterns.get("quarry").run, { w = 4, d = 4, h = 2 }, newCtx())
  check(ok, "job that needs a refuel completes")
  check(move.mined == 32, "mined 4*4*2", move.mined)
end

--------------------------------------------------------------------------------
print("inventory: full with nowhere to put anything raises 'inventory'")
--------------------------------------------------------------------------------
do
  -- No carried chest and no container at home, so every escalation fails and
  -- the signal has to remain the last resort.
  local t, move, patterns = fixture()
  t.fill(-20, -30, -20, 20, -1, 20, "minecraft:diamond_ore")   -- nothing is junk
  -- 16 slots x 64 = 1024 items, so the volume has to exceed that to fill up.
  local ok, err = pcall(patterns.get("quarry").run, { w = 12, d = 12, h = 10 }, newCtx())
  check(not ok, "run stops")
  local kind = move.isSignal(err)
  check(kind == "inventory", "signal is 'inventory' (was a generic error before)",
    kind or tostring(err))
  check(move.dumpRuns == 0, "no dump run was recorded", move.dumpRuns)
  check(move.goHome(), "still walks home with a full inventory")
end

--------------------------------------------------------------------------------
print("dump-at-home: walks home to empty into a chest and carries on")
--------------------------------------------------------------------------------
do
  local w, d, h = 12, 12, 10
  local t, move, patterns = fixture()
  t.fill(-20, -30, -20, 20, -1, 20, "minecraft:diamond_ore")  -- nothing is junk
  t.setBlock(0, 1, 0, "minecraft:chest")                      -- a chest above home

  local ok, err = pcall(patterns.get("quarry").run, { w = w, d = d, h = h }, newCtx())
  check(ok, "a job well past 16 stacks completes", err and textutils.serialize(err))
  check(move.mined == w * d * h, "the whole volume is mined", move.mined)
  check(move.dumpRuns > 0, "it went home to empty at least once", move.dumpRuns)
  check((t.intoChest or 0) > 0, "ore went into the chest", t.intoChest)
  check(t.blockAt(0, 1, 0) == "minecraft:chest", "the home chest is left in place")
end

--------------------------------------------------------------------------------
print("dump-at-home: resumes on the exact block it left")
--------------------------------------------------------------------------------
do
  local t, move = fixture()
  t.fill(-20, -30, -20, 20, -1, 20, "minecraft:stone")
  t.setBlock(0, 1, 0, "minecraft:barrel")
  move.pos = { x = -4, y = -6, z = 5 }
  t.pos = { x = -4, y = -6, z = 5 }
  move.heading, t.heading = 2, 2
  for i = 1, 16 do t.slots[i] = { name = "minecraft:diamond_ore", count = 64 } end

  local ok, why = move.dumpRun()
  check(ok, "the dump run succeeds", why)
  check(move.pos.x == -4 and move.pos.y == -6 and move.pos.z == 5,
    "back on the same block", ("%d,%d,%d"):format(move.pos.x, move.pos.y, move.pos.z))
  check(move.heading == 2, "facing the same way", move.heading)
  check(turtle.getItemCount(16) == 0, "with room in the inventory")
  check(not move.dumping, "and the dumping flag is cleared")
end

--------------------------------------------------------------------------------
print("dump-at-home: refuses without the fuel for a round trip")
--------------------------------------------------------------------------------
do
  local t, move = fixture()
  t.fill(-20, -30, -20, 20, -1, 20, "minecraft:stone")
  t.setBlock(0, 1, 0, "minecraft:chest")
  move.pos = { x = 0, y = -40, z = 0 }
  t.pos = { x = 0, y = -40, z = 0 }
  for i = 1, 16 do t.slots[i] = { name = "minecraft:diamond_ore", count = 64 } end

  -- Enough to get home, nowhere near enough to get home and back out again.
  t.fuel = move.fuelToHome() + 10
  local ok, why = move.dumpRun()
  check(not ok, "the dump run is refused", tostring(ok))
  check(tostring(why):find("round trip"), "because of the round trip", why)
  check(move.pos.y == -40, "and the turtle has not moved", move.pos.y)
end

--------------------------------------------------------------------------------
print("dump-at-home: a full container does not look like success")
--------------------------------------------------------------------------------
do
  local t, move = fixture()
  t.fill(-20, -30, -20, 20, -1, 20, "minecraft:stone")
  t.setBlock(0, 1, 0, "minecraft:chest")
  t.chestFull = true
  move.pos, t.pos = { x = 0, y = -5, z = 0 }, { x = 0, y = -5, z = 0 }
  for i = 1, 16 do t.slots[i] = { name = "minecraft:diamond_ore", count = 64 } end

  local ok, why = move.dumpRun()
  check(not ok, "the dump run reports failure", tostring(ok))
  check(tostring(why):find("full"), "naming the full container", why)
  check(turtle.getItemCount(16) > 0, "and the inventory really is still full")
end

--------------------------------------------------------------------------------
print("inventory: junk is dropped and mining continues")
--------------------------------------------------------------------------------
do
  local t, move, patterns = fixture()
  t.fill(-20, -30, -20, 20, -1, 20, "minecraft:stone")         -- all junk
  local ok, err = pcall(patterns.get("quarry").run, { w = 12, d = 12, h = 10 }, newCtx())
  check(ok, "run completes past 16 stacks", err and textutils.serialize(err))
  check(move.mined == 12 * 12 * 10, "mined the whole volume", move.mined)
  check((t.dropped or 0) > 0, "junk was actually dropped", t.dropped)
end

--------------------------------------------------------------------------------
print("inventory: ender chest is used and reclaimed")
--------------------------------------------------------------------------------
do
  local t, move, patterns = fixture()
  t.fill(-20, -30, -20, 20, -1, 20, "minecraft:diamond_ore")
  t.give("enderstorage:ender_chest")
  local ok, err = pcall(patterns.get("quarry").run, { w = 12, d = 12, h = 10 }, newCtx())
  check(ok, "run completes using the chest", err and textutils.serialize(err))
  check((t.intoChest or 0) > 0, "ore went into the chest, not onto the floor", t.intoChest)
  check(move.mined == 12 * 12 * 10, "and the whole volume was mined", move.mined)
  local hasChest = false
  for i = 1, 16 do
    local it = turtle.getItemDetail(i)
    if it and it.name == "enderstorage:ender_chest" then hasChest = true end
  end
  check(hasChest, "chest is still carried at the end")
end

--------------------------------------------------------------------------------
print("inventory: unload refuses to dig lava overhead")
--------------------------------------------------------------------------------
do
  local t, move = fixture()
  t.give("enderstorage:ender_chest")
  for i = 2, 16 do t.slots[i] = { name = "minecraft:diamond_ore", count = 64 } end
  t.setBlock(0, 1, 0, "minecraft:lava")
  local ok, why = move.unload()
  check(not ok, "unload refuses", tostring(ok))
  check(tostring(why):find("lava"), "and says why", why)
  check(t.blockAt(0, 1, 0) == "minecraft:lava", "lava was left alone")
end

--------------------------------------------------------------------------------
print("goHome: reports failure when it cannot arrive")
--------------------------------------------------------------------------------
do
  local t, move = fixture()
  t.fill(-40, -40, -40, 40, 40, 40, "minecraft:stone")
  t.setBlock(0, 0, 0, nil)
  move.pos = { x = 0, y = -30, z = 0 }
  t.pos = { x = 0, y = -30, z = 0 }
  t.fuel = 5                                  -- nowhere near enough to climb
  local ok, why = move.goHome()
  check(not ok, "goHome returns false (this used to return true)", tostring(ok))
  check(why ~= nil and #tostring(why) > 0, "with a reason", why)
  check(move.pos.y ~= 0, "and the turtle really is not home", move.pos.y)
end

--------------------------------------------------------------------------------
print("state: save / load / fail round trip")
--------------------------------------------------------------------------------
do
  local state = require("lib.state")
  state.clear()
  check(state.load() == nil, "no state file loads as nil")

  local saved = {
    pattern = "quarry", params = { w = 4, d = 5, h = 3 },
    checkpoint = { layer = 2, side = "left", done = 20,
                   pos = { x = -1, y = -2, z = 3 }, heading = 2 },
    mined = 20, home = { x = 0, y = 0, z = 0 }, homeHeading = 0,
    pos = { x = -1, y = -2, z = 3 }, heading = 2,
  }
  check(state.save(saved), "save succeeds")
  local back = state.load()
  check(back ~= nil and back.pattern == "quarry", "loads back")
  check(back.checkpoint.layer == 2 and back.checkpoint.side == "left",
    "checkpoint survives")
  check(back.params.w == 4 and back.params.d == 5 and back.params.h == 3,
    "params survive")

  state.fail("out of fuel")
  local failed = state.load()
  check(failed.failed == "out of fuel", "failure reason recorded")
  check(type(failed.failedAt) == "number" and failed.failedAt > 1e12,
    "failedAt is a real epoch timestamp, not the 0-24 game clock", failed.failedAt)
  check(failed.checkpoint ~= nil, "and the job is still resumable")

  local f = fs.open("/miner.state", "w") f.write("this is not lua") f.close()
  check(state.load() == nil, "a corrupt file loads as nil")
  state.clear()
  check(not fs.exists("/miner.state"), "clear removes the file")
end

--------------------------------------------------------------------------------
print("resume: finishes the volume from a mid-job checkpoint")
--------------------------------------------------------------------------------
do
  local w, d, h = 4, 5, 4
  -- First run: stop it partway by aborting after the third checkpoint.
  local t, move, patterns = fixture()
  t.fill(-10, -10, -10, 10, -1, 10, "minecraft:stone")
  local ctx = newCtx()
  local realCheckpoint = ctx.checkpoint
  ctx.checkpoint = function(data)
    realCheckpoint(data)
    if #ctx.checkpoints == 3 then move.ctl.abort = true end
  end
  local ok, err = pcall(patterns.get("quarry").run, { w = w, d = d, h = h }, ctx)
  check(not ok and move.isSignal(err) == "abort", "first run aborts mid-job")
  local cp = ctx.checkpoints[3]
  check(cp.layer == 3, "checkpoint is at layer 3", cp.layer)

  -- Second run: same world, same mock turtle, resuming from that checkpoint.
  move.ctl.abort = false
  move.mined = 0
  local ctx2 = newCtx(cp)
  local ok2, err2 = pcall(patterns.get("quarry").run, { w = w, d = d, h = h }, ctx2)
  check(ok2, "resumed run completes", err2 and textutils.serialize(err2))
  check(footprintCleared(t, w, d, h) == 0, "the whole volume ends up cleared",
    footprintCleared(t, w, d, h))
  check(ctx2.progress == 1, "progress ends at 1.0", ctx2.progress)
end

--------------------------------------------------------------------------------
print("placed jobs: travel to an origin, then mine there")
--------------------------------------------------------------------------------
do
  -- What a dispatched lane looks like from the turtle's side: go to a corner
  -- some distance away, face along +z, and quarry from there. Home stays put.
  local t, move, patterns = fixture()
  t.fill(-40, -40, -40, 40, 8, 40, "minecraft:stone")
  t.setBlock(0, 0, 0, nil)

  local origin = { x = -6, y = 0, z = 9 }
  local reached = move.goTo(origin.x, origin.y, origin.z)
  check(reached, "the turtle reaches the origin")
  move.face(0)
  check(move.heading == 0, "and faces along the lane")

  local before = move.mined
  local ok, err = pcall(patterns.get("quarry").run, { w = 3, d = 4, h = 2 }, newCtx())
  check(ok, "the pattern runs from there", err and textutils.serialize(err))

  -- A quarry entered facing +z runs its depth along +z and its width along -x,
  -- one layer below the origin. That convention is what lane arithmetic in
  -- lib/fleet assumes, so it is worth pinning here rather than in a comment.
  local cleared = true
  for i = 0, 2 do
    for j = 0, 3 do
      for layer = 1, 2 do
        if t.blockAt(origin.x - i, origin.y - layer, origin.z + j) then cleared = false end
      end
    end
  end
  check(cleared, "clearing the volume that lib/fleet lays out from the anchor")
  check(move.mined - before == 3 * 4 * 2, "and only that volume",
    move.mined - before)

  check(move.home.x == 0 and move.home.y == 0 and move.home.z == 0,
    "home is still the deploy point, not the lane corner",
    ("%d,%d,%d"):format(move.home.x, move.home.y, move.home.z))
  check(move.goHome(), "so it walks all the way back to the chest")
end

--------------------------------------------------------------------------------
-- Geo scanner
--------------------------------------------------------------------------------

--- Expose a mock scanner the way an equipped turtle upgrade appears: as a
--- peripheral of type geoScanner on one of the turtle's sides.
local function withScanner(t, opts)
  local gs = t.attachScanner(opts)
  local real = {
    isPresent = peripheral.isPresent, getType = peripheral.getType,
    wrap = peripheral.wrap, getNames = peripheral.getNames,
  }
  peripheral.isPresent = function(side) return side == "right" end
  peripheral.getType   = function(side) return side == "right" and "geoScanner" or nil end
  peripheral.wrap      = function(side) return side == "right" and gs or nil end
  peripheral.getNames  = function() return { "right" } end
  return function()
    peripheral.isPresent, peripheral.getType = real.isPresent, real.getType
    peripheral.wrap, peripheral.getNames = real.wrap, real.getNames
  end
end

local function scannerModule()
  loaded["lib.scanner"] = nil
  local s = require("lib.scanner")
  s.frame = nil                      -- frame detection is cached; start fresh
  return s
end

print("scanner: reports world coordinates whichever frame it is given")
--------------------------------------------------------------------------------
do
  -- Somewhere far from the origin, so a relative frame and an absolute one give
  -- obviously different answers.
  local HOME = { x = 100, y = 64, z = -20 }

  for _, mode in ipairs({ "relative", "absolute" }) do
    local t, move = fixture()
    move.pos, t.pos = { x = HOME.x, y = HOME.y, z = HOME.z },
                      { x = HOME.x, y = HOME.y, z = HOME.z }
    move.home = { x = HOME.x, y = HOME.y, z = HOME.z }
    t.setBlock(HOME.x + 2, HOME.y - 1, HOME.z, "minecraft:diamond_ore")
    t.setBlock(HOME.x - 3, HOME.y + 1, HOME.z + 1, "minecraft:iron_ore")
    t.setBlock(HOME.x + 1, HOME.y, HOME.z + 1, "minecraft:stone")

    local restore = withScanner(t, { mode = mode })
    local scanner = scannerModule()

    local hits, why = scanner.scan(6)
    check(hits ~= nil, mode .. ": the scan succeeds", why)
    check(scanner.frame == mode, mode .. ": the frame is worked out correctly",
      scanner.frame)

    local ores = scanner.ores(hits or {})
    check(#ores == 2, mode .. ": both ores are picked out, and not the stone", #ores)

    local found = {}
    for _, o in ipairs(ores) do
      found[("%d,%d,%d"):format(o.x, o.y, o.z)] = o.name
    end
    check(found[("%d,%d,%d"):format(HOME.x + 2, HOME.y - 1, HOME.z)]
      == "minecraft:diamond_ore", mode .. ": at real world coordinates")
    check(found[("%d,%d,%d"):format(HOME.x - 3, HOME.y + 1, HOME.z + 1)]
      == "minecraft:iron_ore", mode .. ": including the negative offsets")

    restore()
  end
end

--------------------------------------------------------------------------------
print("scanner: cooldown is a wait, low fuel is a refusal")
--------------------------------------------------------------------------------
do
  local t, move = fixture()
  t.setBlock(2, 0, 0, "minecraft:coal_ore")
  local restore = withScanner(t, { cooldown = 2 })   -- two refusals, then works
  local scanner = scannerModule()

  local hits, why = scanner.scan(4)
  check(hits ~= nil, "a scan that hits the cooldown still succeeds", why)
  check(t.scanner.scans == 1, "after retrying", t.scanner.scans)
  restore()

  -- Refuses outright when it cannot cool down in time.
  local t2, move2 = fixture()
  local restore2 = withScanner(t2, { cooldown = 99 })
  local scanner2 = scannerModule()
  local hits2, why2 = scanner2.scan(4)
  check(hits2 == nil, "a scanner that never comes back gives up")
  check(tostring(why2):find("cooldown") ~= nil, "reporting the cooldown", why2)
  restore2()

  -- Scanning is not free, and lib/move's fuel guard cannot see it coming: from
  -- its point of view a scan is not a move.
  local t3, move3 = fixture()
  move3.pos, t3.pos = { x = 0, y = -200, z = 0 }, { x = 0, y = -200, z = 0 }
  t3.fuel = 210                       -- barely enough to climb home
  local restore3 = withScanner(t3, { costPer = 20 })
  local scanner3 = scannerModule()
  local hits3, why3 = scanner3.scan(8)
  check(hits3 == nil, "a scan that would strand the scout is refused")
  check(tostring(why3):find("walk home") ~= nil, "saying why", why3)
  check(t3.fuel == 210, "and no fuel is spent", t3.fuel)
  restore3()
end

--------------------------------------------------------------------------------
print("scanner: no scanner attached is a clean answer, not a crash")
--------------------------------------------------------------------------------
do
  local t = fixture()
  local scanner = scannerModule()
  check(scanner.find() == nil, "find reports nothing")
  check(not scanner.available(), "available says so")
  local hits, why = scanner.scan(4)
  check(hits == nil and tostring(why):find("no geo scanner") ~= nil,
    "and a scan refuses politely", why)
end

--------------------------------------------------------------------------------
print("scanner.cluster: one job per seam, not per block")
--------------------------------------------------------------------------------
do
  local t = fixture()
  local scanner = scannerModule()

  -- Two seams far apart, plus a lone block further out again.
  local hits = {}
  local function ore(x, y, z, name)
    hits[#hits + 1] = { x = x, y = y, z = z, name = name or "minecraft:iron_ore" }
  end
  ore(0, 0, 0) ore(1, 0, 0) ore(1, 1, 0) ore(2, 1, 0)          -- seam A, 4
  ore(40, 0, 0) ore(41, 0, 0)                                   -- seam B, 2
  ore(0, 0, 80, "minecraft:diamond_ore")                        -- lone block

  local clusters = scanner.cluster(hits, 4)
  check(#clusters == 3, "three seams are found", #clusters)
  check(clusters[1].count == 4, "biggest first", clusters[1].count)
  check(clusters[3].count == 1, "smallest last", clusters[3].count)

  -- The centre has to be a real ore block. The arithmetic mean of a curved seam
  -- is a lump of stone in the middle of it, and a turtle sent there would have
  -- to find its own way back to the ore.
  local onOre = true
  for _, c in ipairs(clusters) do
    local hit = false
    for _, h in ipairs(hits) do
      if h.x == c.x and h.y == c.y and h.z == c.z then hit = true end
    end
    if not hit then onOre = false end
  end
  check(onOre, "every centre sits on an actual ore block")

  check(clusters[1].kinds["minecraft:iron_ore"] == 4, "kinds are counted",
    clusters[1].kinds["minecraft:iron_ore"])

  -- A horseshoe: every block within gap of the next, so it is one seam even
  -- though the ends are far apart.
  local horseshoe = {}
  for i = 0, 10 do
    horseshoe[#horseshoe + 1] = { x = i, y = 0, z = 0, name = "minecraft:gold_ore" }
  end
  local one = scanner.cluster(horseshoe, 2)
  check(#one == 1, "a chain of blocks is a single seam", #one)
  check(one[1].count == 11, "with every block in it", one[1].count)

  check(#scanner.cluster({}, 4) == 0, "nothing in, nothing out")
end

--------------------------------------------------------------------------------
print("survey: a scout drops through air, scanning, and climbs back")
--------------------------------------------------------------------------------
do
  local t, move, patterns = fixture()
  move.canDig = false                   -- a scout has no pickaxe

  -- An open shaft with rock either side, which is what a quarry leaves behind.
  t.fill(-12, -40, -12, 12, 2, 12, "minecraft:stone")
  for y = -30, 0 do t.setBlock(0, y, 0, nil) end

  -- Ore in the walls at two depths, plus one far outside any scan sphere.
  local seamA = { { 2, -6, 0 }, { 3, -6, 0 }, { 3, -7, 0 } }
  local seamB = { { -2, -20, 1 }, { -3, -20, 1 }, { -3, -20, 2 } }
  for _, c in ipairs(seamA) do t.setBlock(c[1], c[2], c[3], "minecraft:diamond_ore") end
  for _, c in ipairs(seamB) do t.setBlock(c[1], c[2], c[3], "minecraft:gold_ore") end
  t.setBlock(10, -35, 10, "minecraft:iron_ore")

  local restore = withScanner(t, { mode = "relative" })
  scannerModule()

  local reports = {}
  local ctx = newCtx()
  ctx.report = function(data) reports[#reports + 1] = data end

  local ok, err = pcall(patterns.get("survey").run,
    { depth = 28, radius = 8, step = 6 }, ctx)
  restore()

  check(ok, "the survey runs", err and textutils.serialize(err))
  check(move.pos.y == 0, "and climbs back to where it started", move.pos.y)
  check(t.scanner.scans > 1, "having scanned on the way down", t.scanner.scans)

  local report = reports[#reports]
  check(report ~= nil, "it reports what it found")
  check(report and #report.clusters == 2, "two seams, not six ore blocks",
    report and #report.clusters)

  -- Both seams are three blocks, which clears config.clusterMin; the lone iron
  -- block out at the edge is below it and never reaches the queue.
  local names = {}
  for _, c in ipairs(report and report.clusters or {}) do names[c.name] = true end
  check(names["minecraft:diamond_ore"] and names["minecraft:gold_ore"],
    "one for each seam it passed")
  check(not names["minecraft:iron_ore"],
    "and nothing for the single block out of range")

  -- The whole point of a scout: it took nothing and broke nothing.
  check(move.mined == 0, "it mined nothing", move.mined)
  check(t.blockAt(2, -6, 0) == "minecraft:diamond_ore", "the ore is still there")
end

--------------------------------------------------------------------------------
print("survey: solid ground is an answer, not an error")
--------------------------------------------------------------------------------
do
  local t, move, patterns = fixture()
  move.canDig = false
  t.fill(-12, -40, -12, 12, 2, 12, "minecraft:stone")
  t.setBlock(0, 0, 0, nil)              -- one block of air and nothing below
  t.setBlock(2, -1, 0, "minecraft:coal_ore")
  t.setBlock(2, -2, 0, "minecraft:coal_ore")
  t.setBlock(3, -2, 0, "minecraft:coal_ore")

  local restore = withScanner(t, {})
  scannerModule()

  local reports = {}
  local ctx = newCtx()
  ctx.report = function(data) reports[#reports + 1] = data end

  local ok, err = pcall(patterns.get("survey").run,
    { depth = 32, radius = 6, step = 4 }, ctx)
  restore()

  check(ok, "a scout that cannot descend still finishes", err and textutils.serialize(err))
  check(t.scanner.scans == 1, "having scanned once where it stood", t.scanner.scans)
  check(move.pos.y == 0, "and stayed put", move.pos.y)
  check(reports[1] and #reports[1].clusters == 1, "still reporting what it could see",
    reports[1] and #reports[1].clusters)
end

--------------------------------------------------------------------------------
print("harvest: travels to a seam and follows it out")
--------------------------------------------------------------------------------
do
  local t, move, patterns = fixture()
  t.fill(-20, -20, -20, 20, 2, 20, "minecraft:stone")
  t.setBlock(0, 0, 0, nil)

  -- A seam some distance away, the way a scout would have reported it.
  local seam = { { 6, -4, 5 }, { 7, -4, 5 }, { 7, -4, 6 }, { 7, -5, 6 }, { 8, -5, 6 } }
  for _, c in ipairs(seam) do t.setBlock(c[1], c[2], c[3], "minecraft:diamond_ore") end

  -- miner.lua walks to job.origin before the pattern runs; do the same here.
  local reached = move.goTo(6, -4, 5)
  check(reached, "the miner reaches the seam")

  local ok, err = pcall(patterns.get("harvest").run,
    { radius = 8, max = 128 }, newCtx())
  check(ok, "the harvest runs", err and textutils.serialize(err))

  local left = 0
  for _, c in ipairs(seam) do
    if t.blockAt(c[1], c[2], c[3]) then left = left + 1 end
  end
  check(left == 0, "the whole seam is taken", left)
  check(move.goHome(), "and it gets home afterwards")
end

--------------------------------------------------------------------------------
print("scout: refuses to dig instead of grinding through its retry budget")
--------------------------------------------------------------------------------
do
  local t, move = fixture()
  move.canDig = false
  t.fill(-5, -5, -5, 5, 5, 5, "minecraft:stone")
  t.setBlock(0, 0, 0, nil)

  local before = t.budget
  local ok, why = move.step("forward")
  check(not ok, "a blocked move fails", tostring(ok))
  check(tostring(why):find("tool") ~= nil, "saying there is no tool", why)

  -- The point of move.canDig: without it this would attack thin air 64 times
  -- with a sleep between each before admitting it was never going to work.
  check(before - t.budget < 20, "without burning the retry budget",
    before - t.budget)

  check(not move.drift("forward"), "drift refuses a blocked space too")
  t.setBlock(0, 1, 0, nil)
  check(move.drift("up"), "but goes where there is room")
  check(move.pos.y == 1, "tracking the move", move.pos.y)
end

--------------------------------------------------------------------------------
print("specs.readParams: rejects everything a bad message can be")
--------------------------------------------------------------------------------
do
  loaded = {}
  local specs = require("lib.specs")
  local quarry = specs.get("quarry")

  local ok = specs.readParams(quarry, { w = 8, d = 8, h = 16 })
  check(ok and ok.w == 8 and ok.d == 8 and ok.h == 16, "a good message passes")

  local str = specs.readParams(quarry, { w = "8", d = "8", h = "16" })
  check(str and str.w == 8 and type(str.w) == "number",
    "numeric strings are coerced to numbers")

  local cases = {
    { label = "an empty message",        src = {} },
    { label = "a missing parameter",     src = { w = 8, d = 8 } },
    { label = "zero",                    src = { w = 0, d = 8, h = 16 } },
    { label = "a negative size",         src = { w = -4, d = 8, h = 16 } },
    { label = "a size past the maximum", src = { w = 9999, d = 8, h = 16 } },
    { label = "a fraction",              src = { w = 2.5, d = 8, h = 16 } },
    { label = "a non-number",            src = { w = "wide", d = 8, h = 16 } },
    { label = "a table",                 src = { w = {}, d = 8, h = 16 } },
  }
  for _, c in ipairs(cases) do
    local params, why = specs.readParams(quarry, c.src)
    check(params == nil and type(why) == "string", "rejects " .. c.label, why)
  end

  check(specs.readParams(nil, { w = 1, d = 1, h = 1 }) == nil, "rejects a nil pattern")
  check(specs.readParams(quarry, nil) == nil, "rejects nil parameters")

  -- The exact failure the validation exists to prevent: a start message with no
  -- sizes used to reach pattern code and die on nil arithmetic.
  local t, move, patterns = fixture()
  t.fill(-10, -10, -10, 10, -1, 10, "minecraft:stone")
  local raced = pcall(patterns.get("quarry").run, {}, newCtx())
  check(not raced, "and pattern code really does blow up on unvalidated params")
end

--------------------------------------------------------------------------------
print("specs.estimate: matches what the turtle actually does")
--------------------------------------------------------------------------------
do
  loaded = {}
  local specs = require("lib.specs")

  local bad = specs.estimate(specs.get("quarry"), { w = 0, d = 8, h = 4 })
  check(bad == nil, "a job that fails validation gets no confident number")
  check(specs.estimate(nil, {}) == nil, "and neither does an unknown pattern")

  -- The point of this block: run the pattern for real against the mock and
  -- compare. An estimate nobody checks drifts the moment a pattern changes,
  -- and a wrong pre-flight number is worse than none -- it is the number the
  -- player decides whether to walk away from the turtle on.
  local cases = {
    { pattern = "quarry", params = { w = 4, d = 5, h = 3 } },
    { pattern = "quarry", params = { w = 8, d = 8, h = 2 } },
    { pattern = "tunnel", params = { w = 3, d = 10, h = 2, veins = 0 } },
    { pattern = "strip",
      params = { length = 16, branch = 4, spacing = 3, height = 2, veins = 0 } },
    { pattern = "strip",
      params = { length = 12, branch = 3, spacing = 4, height = 3, veins = 0 } },
    { pattern = "stairs", params = { depth = 10, width = 1, headroom = 3, veins = 0 } },
    { pattern = "stairs", params = { depth = 8, width = 3, headroom = 2, veins = 0 } },
  }

  for _, case in ipairs(cases) do
    local t, move, patterns = fixture()
    t.fill(-40, -40, -40, 40, 40, 40, "minecraft:stone")
    t.setBlock(0, 0, 0, nil)

    local est = specs.estimate(specs.get(case.pattern), case.params)
    local ok = pcall(patterns.get(case.pattern).run, case.params, newCtx())

    local label = case.pattern .. " " .. textutils.serialize(case.params):gsub("%s+", "")
    if not ok or not est then
      check(false, "estimate case ran: " .. case.pattern)
    else
      -- Within 20%: the estimate is a guide, not a budget, but an order of
      -- magnitude apart would mean the formula no longer describes the pattern.
      local ratio = t.moves / est.moves
      check(ratio > 0.8 and ratio < 1.2,
        ("%s moves within 20%% (est %d, actual %d)")
          :format(case.pattern, est.moves, t.moves),
        ("ratio %.2f  %s"):format(ratio, label))
    end
  end
end

--------------------------------------------------------------------------------
print("manifest: the installer ships every file and no phantoms")
--------------------------------------------------------------------------------
do
  -- install.lua downloads exactly what manifest.txt lists. A file added to the
  -- project and not to the manifest produces an install that is missing a
  -- library, which shows up as a require error on someone else's turtle rather
  -- than here. This is that failure, moved to where it is cheap.
  local f = fs.open("/manifest.txt", "r")
  check(f ~= nil, "manifest.txt exists")

  if f then
    local listed, order = {}, {}
    for line in (f.readAll() or ""):gmatch("[^\r\n]+") do
      line = line:match("^%s*(.-)%s*$")
      if line ~= "" and not line:match("^#") then
        listed[line] = true
        order[#order + 1] = line
      end
    end
    f.close()

    local missing = {}
    for _, path in ipairs(order) do
      if not fs.exists("/" .. path) then missing[#missing + 1] = path end
    end
    check(#missing == 0, "every listed file exists",
      table.concat(missing, ", "))

    -- And the other direction: anything shipped must be listed. test/ is
    -- deliberately excluded -- it does not go on a turtle.
    local unlisted = {}
    for _, path in ipairs(fs.list("/")) do
      if path:match("%.lua$") and path ~= "install.lua"
         and not path:match("^mock") and not path:match("^test")
         and not path:match("^probe") and not path:match("^runner")
         and not path:match("^hello") and not path:match("^mprobe") then
        if not listed[path] then unlisted[#unlisted + 1] = path end
      end
    end
    for _, path in ipairs(fs.exists("/lib") and fs.list("/lib") or {}) do
      if path:match("%.lua$") and not listed["lib/" .. path] then
        unlisted[#unlisted + 1] = "lib/" .. path
      end
    end
    check(#unlisted == 0, "and every project file is listed",
      table.concat(unlisted, ", "))
  end
end

--------------------------------------------------------------------------------
print("")
print(("%d passed, %d failed"):format(pass, fail))
print("=== TESTS DONE ===")
flush()
return fail                          -- run.lua owns shutting the emulator down
