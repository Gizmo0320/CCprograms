--- lib/fleet is pure logic, so this suite needs no mock turtle and no world.
--- It is the half of the multi-turtle system that is impossible to eyeball:
--- whether lanes actually tile a volume, and whether a lost job comes back.

local out = {}
local flush
local function say(s)
  out[#out + 1] = tostring(s)
  flush()
end
function flush()
  local f = fs.open("/test-fleet-results.txt", "w")
  for _, line in ipairs(out) do f.writeLine(line) end
  f.close()
end

local pass, fail = 0, 0
local function check(ok, label, extra)
  if ok then
    pass = pass + 1
    say("  ok   " .. label)
  else
    fail = fail + 1
    say("  FAIL " .. label .. (extra and ("  <" .. tostring(extra) .. ">") or ""))
  end
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

local fleet  = require("lib.fleet")
local config = require("lib.config")

--- A turtle that has just reported in and is ready for work.
local function idleTurtle(id, fuel, pos)
  return {
    type = "status", id = id, label = "T" .. id,
    state = "idle", fuel = fuel or 100000,
    pos = pos or { x = 0, y = 0, z = 0 },
    mined = 0, progress = 0,
  }
end

--------------------------------------------------------------------------------
say("fleet.split: lanes tile the volume exactly")
--------------------------------------------------------------------------------

--- Rebuild the footprint each lane claims and check it covers the original
--- once and only once. Overlap means two turtles in the same hole; a gap means
--- a column nobody digs, and neither is visible from reading the arithmetic.
local function coverage(anchor, jobs)
  local seen, overlaps = {}, 0
  for _, job in ipairs(jobs) do
    for i = 0, job.params.w - 1 do
      for j = 0, job.params.d - 1 do
        local k = (job.origin.x - i) .. "," .. (job.origin.z + j)
        if seen[k] then overlaps = overlaps + 1 end
        seen[k] = true
      end
    end
  end
  return seen, overlaps
end

local function checkTiling(w, d, h, lanes)
  local anchor = { x = 100, y = 64, z = -20 }
  local jobs, why = fleet.split(anchor, "quarry",
    { w = w, d = d, h = h }, lanes)

  if not jobs then
    check(false, ("split %dx%d into %d lanes"):format(w, d, lanes), why)
    return
  end

  check(#jobs == lanes, ("%dx%d / %d lanes -> %d jobs"):format(w, d, lanes, #jobs))

  local seen, overlaps = coverage(anchor, jobs)
  check(overlaps == 0, ("  %dx%d / %d: no lane overlaps another"):format(w, d, lanes),
    overlaps)

  local missing = 0
  for i = 0, w - 1 do
    for j = 0, d - 1 do
      if not seen[(anchor.x - i) .. "," .. (anchor.z + j)] then missing = missing + 1 end
    end
  end
  check(missing == 0, ("  %dx%d / %d: every column is claimed"):format(w, d, lanes),
    missing)

  -- Depth and layers are untouched by a width split, and every lane keeps them.
  local layersOk, widths, total = true, {}, 0
  for _, job in ipairs(jobs) do
    if job.params.h ~= h then layersOk = false end
    widths[#widths + 1] = job.params[(w >= d) and "w" or "d"]
    total = total + job.params.w * job.params.d * job.params.h
  end
  check(layersOk, ("  %dx%d / %d: every lane keeps all %d layers"):format(w, d, lanes, h))
  check(total == w * d * h, ("  %dx%d / %d: block totals add up"):format(w, d, lanes),
    total .. " vs " .. (w * d * h))

  -- Remainder spread one at a time, so no turtle gets a much bigger share.
  local lo, hi = math.huge, 0
  for _, n in ipairs(widths) do
    lo, hi = math.min(lo, n), math.max(hi, n)
  end
  check(hi - lo <= 1, ("  %dx%d / %d: lanes differ by at most one block"):format(
    w, d, lanes), hi - lo)
end

checkTiling(16, 16, 8, 4)     -- divides evenly
checkTiling(17, 16, 8, 4)     -- remainder 1
checkTiling(18, 12, 4, 4)     -- remainder 2
checkTiling(10, 32, 4, 3)     -- splits along d, since d is the wider axis
checkTiling(7, 7, 2, 7)       -- one block per lane, the tightest legal split
checkTiling(16, 16, 8, 1)     -- degenerate: one lane

--------------------------------------------------------------------------------
say("fleet.split: refuses what it cannot do")
--------------------------------------------------------------------------------
do
  local anchor = { x = 0, y = 0, z = 0 }

  local one = fleet.split(anchor, "quarry", { w = 8, d = 8, h = 4 }, 1)
  check(one and #one == 1 and one[1].params.w == 8,
    "a single lane is the undivided job")

  local tooMany, why = fleet.split(anchor, "quarry", { w = 4, d = 4, h = 2 }, 8)
  check(tooMany == nil, "more lanes than blocks is refused, not padded with empties")
  check(tostring(why):find("4 blocks") ~= nil or tostring(why):find("wide") ~= nil,
    "and says how wide it actually is", why)

  check(fleet.split(anchor, "quarry", { w = 8, d = 8, h = 4 }, 0) == nil,
    "zero lanes is refused")
  check(fleet.split(anchor, "nonsense", { w = 8, d = 8, h = 4 }, 2) == nil,
    "an unknown pattern is refused")
  check(fleet.split(anchor, "quarry", { w = 0, d = 8, h = 4 }, 2) == nil,
    "parameters that fail validation are refused")
  check(fleet.split(nil, "quarry", { w = 8, d = 8, h = 4 }, 2) == nil,
    "and so is a missing anchor")

  -- A corridor is already a line; there is no footprint to divide.
  local strip, stripWhy = fleet.split(anchor, "strip",
    { length = 32, branch = 8, spacing = 3, height = 2, veins = 0 }, 3)
  check(strip == nil, "a strip cannot be split into lanes")
  check(tostring(stripWhy):find("split") ~= nil, "and says so plainly", stripWhy)

  local solo = fleet.split(anchor, "strip",
    { length = 32, branch = 8, spacing = 3, height = 2, veins = 0 }, 1)
  check(solo and #solo == 1, "but one lane of it is fine")
end

--------------------------------------------------------------------------------
say("fleet.assign: skips turtles that cannot take the job")
--------------------------------------------------------------------------------
do
  local f = fleet.new()
  local now = 1000
  local job = { pattern = "quarry", params = { w = 8, d = 8, h = 4 },
                origin = { x = 0, y = 0, z = 0 } }

  check(select(2, fleet.assign(f, job, now)) == "no idle miner",
    "an empty roster has nobody to give it to")

  fleet.sawTurtle(f, 7, idleTurtle(7), now)
  check(fleet.assign(f, job, now) ~= nil, "one idle turtle takes it")

  -- Stale: heard from long enough ago that we cannot assume it is listening.
  local old = now - config.staleAfter - 1
  local g = fleet.new()
  fleet.sawTurtle(g, 7, idleTurtle(7), old)
  check(fleet.assign(g, job, now) == nil, "a stale turtle is not given work")

  -- Busy.
  local h = fleet.new()
  local mining = idleTurtle(9)
  mining.state = "mining"
  fleet.sawTurtle(h, 9, mining, now)
  check(fleet.assign(h, job, now) == nil, "a mining turtle is not given work")

  -- Low on fuel for the job plus the trip out and back.
  local k = fleet.new()
  fleet.sawTurtle(k, 11, idleTurtle(11, 50), now)
  local who, why = fleet.assign(k, job, now)
  check(who == nil, "a turtle without the fuel is skipped")
  check(tostring(why):find("fuel") ~= nil, "and the reason names fuel", why)

  -- Unlimited fuel (creative) always qualifies.
  local u = fleet.new()
  fleet.sawTurtle(u, 13, idleTurtle(13, "unlimited"), now)
  check(fleet.assign(u, job, now) ~= nil, "unlimited fuel qualifies")
end

--------------------------------------------------------------------------------
say("fleet.assign: a job goes to the kind of turtle that can do it")
--------------------------------------------------------------------------------
do
  local now = 1000
  local f = fleet.new()

  local miner = idleTurtle(7); miner.role = "miner"
  local scout = idleTurtle(9); scout.role = "scout"
  fleet.sawTurtle(f, 7, miner, now)
  fleet.sawTurtle(f, 9, scout, now)

  local quarry = { pattern = "quarry", params = { w = 8, d = 8, h = 4 },
                   origin = { x = 0, y = 0, z = 0 } }
  local survey = { pattern = "survey", params = { depth = 32, radius = 8, step = 6 },
                   origin = { x = 0, y = 0, z = 0 } }

  local who = fleet.assign(f, quarry, now)
  check(who and who.id == 7, "a quarry goes to the miner", who and who.id)

  who = fleet.assign(f, survey, now)
  check(who and who.id == 9, "a survey goes to the scout", who and who.id)

  -- A scout has no pickaxe and a miner has no scanner, so the wrong kind is not
  -- slow, it is impossible.
  local minersOnly = fleet.new()
  fleet.sawTurtle(minersOnly, 7, miner, now)
  local none, why = fleet.assign(minersOnly, survey, now)
  check(none == nil, "with no scout, a survey waits")
  check(tostring(why):find("scout") ~= nil, "and says what it is waiting for", why)

  -- A turtle from before the scout role exists reports no role at all.
  local legacy = fleet.new()
  local old = idleTurtle(11); old.role = nil
  fleet.sawTurtle(legacy, 11, old, now)
  check(fleet.assign(legacy, quarry, now) ~= nil,
    "a turtle that reports no role is treated as a miner")
end

--------------------------------------------------------------------------------
say("fleet.assign: prefers the nearest capable turtle")
--------------------------------------------------------------------------------
do
  local f = fleet.new()
  local now = 1000
  fleet.sawTurtle(f, 7, idleTurtle(7, 100000, { x = 200, y = 64, z = 0 }), now)
  fleet.sawTurtle(f, 9, idleTurtle(9, 100000, { x = 5, y = 64, z = 0 }), now)
  fleet.sawTurtle(f, 11, idleTurtle(11, 100000, { x = -300, y = 64, z = 0 }), now)

  local job = { pattern = "quarry", params = { w = 8, d = 8, h = 4 },
                origin = { x = 0, y = 64, z = 0 } }
  local who = fleet.assign(f, job, now)
  check(who and who.id == 9, "the closest one is chosen", who and who.id)
end

--------------------------------------------------------------------------------
say("fleet: dispatch marks a job running and stops it being dispatched twice")
--------------------------------------------------------------------------------
do
  local f = fleet.new()
  local now = 1000
  fleet.sawTurtle(f, 7, idleTurtle(7), now)

  fleet.addJob(f, { pattern = "quarry", params = { w = 8, d = 8, h = 4 },
                    origin = { x = 0, y = 0, z = 0 } })
  fleet.addJob(f, { pattern = "quarry", params = { w = 4, d = 4, h = 2 },
                    origin = { x = 0, y = 0, z = 0 } })

  local job, turtle = fleet.nextDispatch(f, now)
  check(job ~= nil and turtle ~= nil, "the first job finds a turtle")
  fleet.markRunning(f, job, turtle.id, now)
  check(job.state == "running" and job.turtle == 7, "and is marked running")

  -- The turtle is still reporting idle -- its next heartbeat has not arrived --
  -- but it must not be handed a second job in the meantime.
  local job2, turtle2 = fleet.nextDispatch(f, now)
  check(job2 == nil or turtle2 == nil,
    "the only turtle is not given a second job while it holds one",
    job2 and job2.id)

  local c = fleet.counts(f, now)
  check(c.running == 1 and c.pending == 1, "counts reflect one of each",
    c.running .. "/" .. c.pending)
end

--------------------------------------------------------------------------------
say("fleet.reconcile: completion, failure and requeue")
--------------------------------------------------------------------------------
do
  local function running(now)
    local f = fleet.new()
    fleet.sawTurtle(f, 7, idleTurtle(7), now)
    local job = fleet.addJob(f, { pattern = "quarry",
      params = { w = 4, d = 4, h = 2 }, origin = { x = 0, y = 0, z = 0 } })
    fleet.markRunning(f, job, 7, now)
    return f, job
  end

  local now = 1000

  -- Done.
  local f, job = running(now)
  local s = idleTurtle(7); s.state, s.jobId = "done", job.id
  fleet.sawTurtle(f, 7, s, now)
  local events = fleet.reconcile(f, now)
  check(job.state == "done", "a turtle reporting done completes the job", job.state)
  check(#events == 1 and events[1].event == "done", "and the event says so")

  -- Errored.
  f, job = running(now)
  s = idleTurtle(7); s.state, s.jobId, s.message = "error", job.id, "hit bedrock"
  fleet.sawTurtle(f, 7, s, now)
  fleet.reconcile(f, now)
  check(job.state == "failed", "a turtle reporting error fails the job", job.state)
  check(job.reason == "hit bedrock", "keeping the reason", job.reason)

  local settled = now + config.dispatchGrace + 1

  -- Went idle without ever reporting our job: rebooted or never got the order.
  f, job = running(now)
  fleet.sawTurtle(f, 7, idleTurtle(7), settled)
  fleet.reconcile(f, settled)
  check(job.state == "pending", "a turtle that went idle requeues the job", job.state)
  check(job.turtle == nil, "and releases the turtle")

  -- Recalled or aborted by hand: idle, but still echoing our jobId. This must
  -- not read as "still running" just because the ids match.
  f, job = running(now)
  s = idleTurtle(7); s.jobId, s.message = job.id, "recalled"
  fleet.sawTurtle(f, 7, s, settled)
  fleet.reconcile(f, settled)
  check(job.state == "pending", "a recalled turtle releases its job too", job.state)
  check(f.turtles[7].jobId == nil, "and stops being counted as holding one")
  check(fleet.isIdle(f, f.turtles[7], settled), "so it is available for work again")

  -- Out of contact is NOT requeued: it is probably still mining in an unloaded
  -- chunk, and a second turtle in the same lane is worse than a stalled job.
  f, job = running(now)
  local events2 = fleet.reconcile(f, now + config.staleAfter + 1)
  check(job.state == "running", "a turtle out of contact keeps its job", job.state)
  check(#events2 == 0, "and raises no event")
  check(tostring(job.waiting):find("contact") ~= nil, "but the job says why", job.waiting)
end

--------------------------------------------------------------------------------
say("fleet.reconcile: a just-dispatched turtle is given time to answer")
--------------------------------------------------------------------------------
do
  -- The race this exists for: the server dispatches, and a heartbeat that was
  -- already in flight arrives saying "idle". Requeueing on that would put a
  -- second turtle in the same lane.
  local now = 1000
  local f = fleet.new()
  fleet.sawTurtle(f, 7, idleTurtle(7), now)
  local job = fleet.addJob(f, { pattern = "quarry",
    params = { w = 4, d = 4, h = 2 }, origin = { x = 0, y = 0, z = 0 } })
  fleet.markRunning(f, job, 7, now)

  fleet.sawTurtle(f, 7, idleTurtle(7), now + 1)
  fleet.reconcile(f, now + 1)
  check(job.state == "running", "an idle heartbeat just after dispatch is ignored",
    job.state)

  check(fleet.nextDispatch(f, now + 1) == nil,
    "so the job is not handed to anyone else")

  -- Once the grace has passed, a turtle still claiming to be idle really did
  -- miss it.
  fleet.sawTurtle(f, 7, idleTurtle(7), now + config.dispatchGrace + 1)
  fleet.reconcile(f, now + config.dispatchGrace + 1)
  check(job.state == "pending", "but after the grace period it is requeued",
    job.state)
end

--------------------------------------------------------------------------------
say("fleet.reconcile: gives up rather than cycling a job through the fleet")
--------------------------------------------------------------------------------
do
  local now = 1000
  local f = fleet.new()
  fleet.sawTurtle(f, 7, idleTurtle(7), now)
  local job = fleet.addJob(f, { pattern = "quarry",
    params = { w = 4, d = 4, h = 2 }, origin = { x = 0, y = 0, z = 0 } })

  -- Dispatch and have the turtle bounce straight back to idle, repeatedly,
  -- each round leaving enough time for the grace period to expire.
  local rounds = 0
  local clock = now
  for _ = 1, config.jobRetries + 5 do
    if job.state == "pending" then
      fleet.markRunning(f, job, 7, clock)
      clock = clock + config.dispatchGrace + 1
      fleet.sawTurtle(f, 7, idleTurtle(7), clock)
      fleet.reconcile(f, clock)
      rounds = rounds + 1
    end
  end

  check(job.state == "failed", "the job ends up failed, not pending forever", job.state)
  check(rounds <= config.jobRetries + 1, "after the retry cap, not indefinitely", rounds)
  check(tostring(job.reason):find("abandoned") ~= nil, "and says it was abandoned",
    job.reason)
end

--------------------------------------------------------------------------------
say("fleet.addSeams: one harvest job per seam, and only once")
--------------------------------------------------------------------------------
do
  local f = fleet.new()
  local clusters = {
    { x = 100, y = 30, z = 40, count = 9, name = "minecraft:diamond_ore" },
    { x = 160, y = 30, z = 40, count = 4, name = "minecraft:iron_ore" },
  }

  local added, skipped = fleet.addSeams(f, clusters)
  check(#added == 2 and skipped == 0, "two seams become two jobs",
    #added .. "/" .. skipped)
  check(added[1].pattern == "harvest", "of the harvest pattern", added[1].pattern)
  check(added[1].origin.x == 100 and added[1].origin.z == 40,
    "with the seam as the origin")
  check(added[1].seam and added[1].seam.count == 9, "remembering how big it was")

  -- Scan spheres overlap, so a scout descending a shaft reports the same seam
  -- two or three times. Queueing each one would send three turtles to one hole.
  local again, skipped2 = fleet.addSeams(f, {
    { x = 100, y = 30, z = 40, count = 9 },              -- exactly the same
    { x = 102, y = 31, z = 40, count = 7 },              -- the same seam, off centre
  })
  check(#again == 0 and skipped2 == 2, "reporting them again adds nothing",
    #again .. "/" .. skipped2)

  -- Far enough away to be a different seam.
  local far = fleet.addSeams(f, { { x = 100, y = 30, z = 99, count = 5 } })
  check(#far == 1, "but a genuinely new seam is queued")

  -- A harvested seam must not come back the next time anything scans near it.
  for _, job in ipairs(f.jobs) do job.state = "done" end
  local revisit, skipped3 = fleet.addSeams(f, { { x = 100, y = 30, z = 40, count = 9 } })
  check(#revisit == 0 and skipped3 == 1, "a seam already mined is not queued again",
    #revisit .. "/" .. skipped3)

  -- A failed one, though, is fair game: nothing was taken out of it.
  for _, job in ipairs(f.jobs) do job.state = "failed" end
  local retry = fleet.addSeams(f, { { x = 100, y = 30, z = 40, count = 9 } })
  check(#retry == 1, "a seam whose job failed can be queued again")

  check(#fleet.addSeams(f, nil) == 0, "no clusters is not an error")
  check(#fleet.addSeams(f, { "nonsense", {} }) == 0, "and nor is junk")
end

--------------------------------------------------------------------------------
say("fleet: a harvest job is dispatched to a miner, not the scout that found it")
--------------------------------------------------------------------------------
do
  local now = 1000
  local f = fleet.new()
  local scout = idleTurtle(9); scout.role = "scout"
  local miner = idleTurtle(7); miner.role = "miner"
  fleet.sawTurtle(f, 9, scout, now)
  fleet.sawTurtle(f, 7, miner, now)

  fleet.addSeams(f, { { x = 10, y = 0, z = 10, count = 8 } })
  local job, turtle = fleet.nextDispatch(f, now)
  check(job and job.pattern == "harvest", "the seam is dispatched", job and job.pattern)
  check(turtle and turtle.id == 7, "to the miner", turtle and turtle.id)
end

--------------------------------------------------------------------------------
say("fleet: queue housekeeping")
--------------------------------------------------------------------------------
do
  local f = fleet.new()
  local a = fleet.addJob(f, { pattern = "quarry", params = { w = 4, d = 4, h = 2 } })
  local b = fleet.addJob(f, { pattern = "quarry", params = { w = 4, d = 4, h = 2 } })
  check(a.id ~= b.id, "jobs get distinct ids", a.id .. "/" .. b.id)
  check(fleet.getJob(f, a.id) == a, "and can be looked up")

  local cancelled, was = fleet.cancel(f, a.id)
  check(cancelled == a and was == "pending", "a pending job cancels")
  check(fleet.cancel(f, "nope") == nil, "an unknown id does not")

  for _ = 1, 40 do
    local j = fleet.addJob(f, { pattern = "quarry", params = { w = 4, d = 4, h = 2 } })
    j.state = "done"
  end
  fleet.prune(f, 5)
  local live, dead = 0, 0
  for _, job in ipairs(f.jobs) do
    if job.state == "pending" or job.state == "running" then live = live + 1
    else dead = dead + 1 end
  end
  check(live == 1, "pruning keeps every live job", live)
  check(dead <= 5, "and only the most recent finished ones", dead)
end

--------------------------------------------------------------------------------
say("fleet: survives a corrupt state file")
--------------------------------------------------------------------------------
do
  check(fleet.restore(nil).turtles ~= nil, "nil restores to an empty fleet")
  check(fleet.restore("garbage").nextId == 1, "so does junk")
  check(#fleet.restore({ jobs = { { id = "J1" } } }).jobs == 1, "and real data survives")

  local roster = fleet.roster(fleet.restore({
    turtles = { [9] = { id = 9, lastSeen = 0 }, [7] = { id = 7, lastSeen = 0 } },
  }), 0)
  check(roster[1].id == 7 and roster[2].id == 9,
    "the roster comes back in a stable order, not pairs() order")
end

say("")
say(("%d passed, %d failed"):format(pass, fail))
say("=== FLEET TESTS DONE ===")
return fail
