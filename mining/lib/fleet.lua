--- Fleet roster, job queue and work splitting.
--
-- Pure logic: no rednet, no turtle, no term. Everything here is "given this
-- roster and this queue, what should happen", which is exactly the part of a
-- multi-turtle system that is hard to get right and impossible to eyeball. It
-- is kept API-free for the same reason lib/specs.lua is -- so it can be tested
-- without an emulated world, and so server.lua is left as loops and drawing.
--
-- Time is passed in rather than read from os.clock(), so staleness can be
-- tested by handing it a clock instead of sleeping.

local config = require("lib.config")
local specs  = require("lib.specs")

local fleet = {}

-- heading: 0 = +z, 1 = -x, 2 = -z, 3 = +x, matching lib/move.
--
-- Every dispatched job faces +z. A quarry entered facing +z runs its depth
-- along +z and shifts its width along -x (turning right from south faces west),
-- so the anchor is the corner the volume extends south and west from. Fixing
-- the facing is what makes lane origins simple arithmetic instead of a case
-- analysis over four rotations.
local ALONG_Z = 0

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

function fleet.new()
  return {
    turtles = {},        -- [id] = { id, label, status, lastSeen, jobId }
    jobs    = {},        -- ordered list of job records
    nextId  = 1,
  }
end

--- Restore from whatever came off disk, discarding anything that does not look
--- like a fleet. A corrupt file should cost the roster, not the server.
function fleet.restore(data)
  local f = fleet.new()
  if type(data) ~= "table" then return f end
  if type(data.turtles) == "table" then f.turtles = data.turtles end
  if type(data.jobs) == "table" then f.jobs = data.jobs end
  if type(data.nextId) == "number" then f.nextId = data.nextId end
  return f
end

--------------------------------------------------------------------------------
-- Roster
--------------------------------------------------------------------------------

--- Fold a turtle's status broadcast into the roster.
function fleet.sawTurtle(f, id, status, now)
  local t = f.turtles[id]
  if not t then
    t = { id = id }
    f.turtles[id] = t
  end
  t.label    = status.label or t.label
  t.status   = status
  t.lastSeen = now
  t.jobId    = status.jobId
  return t
end

function fleet.isStale(t, now)
  return (now - (t.lastSeen or -math.huge)) > config.staleAfter
end

--- A turtle that could take work right now: heard from recently, not mining,
--- not walking home, and not already holding a job we dispatched.
function fleet.isIdle(f, t, now)
  if fleet.isStale(t, now) then return false end
  local s = t.status
  if not s then return false end
  if s.state ~= "idle" and s.state ~= "done" then return false end
  return not fleet.jobOf(f, t.id)
end

--- The job this turtle is currently assigned, if any.
function fleet.jobOf(f, id)
  for _, job in ipairs(f.jobs) do
    if job.turtle == id and job.state == "running" then return job end
  end
end

--- Roster as a stable, sorted list, so the server and pocket render rows in the
--- same order every frame rather than in pairs() order.
function fleet.roster(f, now)
  local list = {}
  for _, t in pairs(f.turtles) do
    list[#list + 1] = {
      id       = t.id,
      label    = t.label,
      status   = t.status,
      stale    = fleet.isStale(t, now),
      jobId    = t.jobId,
    }
  end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end

--------------------------------------------------------------------------------
-- Queue
--------------------------------------------------------------------------------

function fleet.addJob(f, job)
  job.id      = job.id or ("J" .. f.nextId)
  job.state   = "pending"
  job.tries   = 0
  f.nextId    = f.nextId + 1
  f.jobs[#f.jobs + 1] = job
  return job
end

function fleet.getJob(f, jobId)
  for _, job in ipairs(f.jobs) do
    if job.id == jobId then return job end
  end
end

--- Cancel a job. A running one is only marked: the caller still has to tell the
--- turtle, and it is the turtle going idle that actually ends the work.
function fleet.cancel(f, jobId)
  local job = fleet.getJob(f, jobId)
  if not job then return nil, "no such job" end
  if job.state == "done" then return nil, "already finished" end
  local was = job.state
  job.state = "cancelled"
  return job, was
end

--- Drop finished and cancelled jobs so the queue does not grow without bound
--- across a long session. Keeps the most recent `keep` of them for the UI.
function fleet.prune(f, keep)
  keep = keep or 10
  local live, dead = {}, {}
  for _, job in ipairs(f.jobs) do
    if job.state == "pending" or job.state == "running" then
      live[#live + 1] = job
    else
      dead[#dead + 1] = job
    end
  end
  for i = math.max(1, #dead - keep + 1), #dead do
    live[#live + 1] = dead[i]
  end
  f.jobs = live
  return f.jobs
end

function fleet.counts(f, now)
  local c = { turtles = 0, idle = 0, busy = 0, stale = 0,
              pending = 0, running = 0, done = 0, failed = 0 }
  for _, t in pairs(f.turtles) do
    c.turtles = c.turtles + 1
    if fleet.isStale(t, now) then c.stale = c.stale + 1
    elseif fleet.isIdle(f, t, now) then c.idle = c.idle + 1
    else c.busy = c.busy + 1 end
  end
  for _, job in ipairs(f.jobs) do
    if c[job.state] then c[job.state] = c[job.state] + 1 end
  end
  return c
end

--------------------------------------------------------------------------------
-- Assignment
--------------------------------------------------------------------------------

local function manhattan(a, b)
  if not a or not b then return 0 end
  return math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z)
end

--- What a job will cost the turtle that takes it: the pattern itself, plus the
--- round trip out to the region and back.
--
-- The turtle's own guard only ever reserves a one-way trip home, because from
-- its point of view home is wherever it started. It has no idea it is about to
-- be sent somewhere else first, so the server has to do this arithmetic before
-- it dispatches or the turtle will accept a job it cannot finish.
function fleet.jobFuel(job, from)
  local spec = specs.get(job.pattern)
  local est  = spec and specs.estimate(spec, job.params)
  if not est then return nil, "cannot estimate " .. tostring(job.pattern) end
  local travel = 2 * manhattan(from, job.origin)
  return est.fuel + travel + config.fuelMargin
end

--- Pick a turtle for a job. Returns the turtle, or nil plus why not.
--
-- Prefers the closest capable turtle, so a fleet spread around a base does not
-- send the far one across the world while the near one sits idle.
--- What kind of turtle a job needs, and what kind a turtle is.
--
-- A scout has no pickaxe and a miner has no scanner, so getting this wrong is
-- not a slow job, it is a job that cannot start at all. Turtles that predate
-- the scout role report no role and are taken to be miners.
local function roleOf(t)
  return (t.status and t.status.role) or "miner"
end

local function roleFor(job)
  local spec = specs.get(job.pattern)
  return (spec and spec.role) or "miner"
end

function fleet.assign(f, job, now)
  local best, bestDistance, reason
  local anyIdle = false
  local want = roleFor(job)

  for _, t in pairs(f.turtles) do
    if fleet.isIdle(f, t, now) and roleOf(t) == want then
      anyIdle = true
      local from = t.status and t.status.pos
      local need, why = fleet.jobFuel(job, from)

      if not need then
        reason = why
      else
        local have = t.status and t.status.fuel
        if have == "unlimited" or (type(have) == "number" and have >= need) then
          local d = manhattan(from, job.origin)
          if not best or d < bestDistance then best, bestDistance = t, d end
        else
          reason = ("no turtle has the %d fuel this job needs"):format(need)
        end
      end
    end
  end

  if best then return best end
  if not anyIdle then return nil, "no idle " .. want end
  return nil, reason or "no suitable turtle"
end

--- The next job worth dispatching, paired with a turtle that can take it.
--- Jobs are considered in submission order so the queue behaves like a queue.
function fleet.nextDispatch(f, now)
  for _, job in ipairs(f.jobs) do
    if job.state == "pending" then
      local t, why = fleet.assign(f, job, now)
      if t then return job, t end
      -- Record why it is waiting so the UI can say so, then keep looking: a
      -- later job may be small enough for the fuel that is actually available.
      job.waiting = why
    end
  end
end

function fleet.markRunning(f, job, turtleId, now)
  job.state     = "running"
  job.turtle    = turtleId
  job.startedAt = now
  job.waiting   = nil
  job.tries     = (job.tries or 0) + 1
  local t = f.turtles[turtleId]
  if t then t.jobId = job.id end
  return job
end

--------------------------------------------------------------------------------
-- Reconciliation
--------------------------------------------------------------------------------

--- Work out what changed and correct the record. Called on every heartbeat.
--
-- Returns a list of {job, event} so the caller can log and act. A turtle
-- reporting a state that disagrees with the queue is the normal case, not an
-- error: the turtle is the authority on what it is doing, and the server's job
-- is to notice and catch up.
function fleet.reconcile(f, now)
  local events = {}

  for _, job in ipairs(f.jobs) do
    if job.state == "running" then
      local t = f.turtles[job.turtle]
      local s = t and t.status

      if not t or fleet.isStale(t, now) then
        -- Lost contact. Deliberately *not* requeued: the turtle is probably
        -- still mining in an unloaded chunk, and a second turtle in the same
        -- lane is worse than a stalled job. It reappears or a human intervenes.
        job.waiting = "turtle " .. tostring(job.turtle) .. " out of contact"

      elseif s and s.jobId == job.id and s.state == "done" then
        job.state = "done"
        job.endedAt = now
        if t then t.jobId = nil end
        events[#events + 1] = { job = job, event = "done" }

      elseif s and s.jobId == job.id and s.state == "error" then
        job.state = "failed"
        job.reason = s.message
        job.endedAt = now
        if t then t.jobId = nil end
        events[#events + 1] = { job = job, event = "failed" }

      elseif s and (s.state == "idle" or s.state == "done")
             and (now - (job.startedAt or 0)) >= config.dispatchGrace then
        -- The turtle is free but did not finish our job: it rebooted, was
        -- recalled or aborted by hand, or never received the dispatch. Note
        -- this catches a turtle still echoing our jobId while sitting idle,
        -- which is exactly what a recalled turtle looks like -- matching only
        -- done and error above would leave the job "running" for ever.
        --
        -- The grace period is what stops this firing on a heartbeat that was
        -- already in flight when the dispatch went out. Without it the server
        -- reads a perfectly healthy turtle as having missed its orders and
        -- sends the same lane to a second one.
        --
        -- The work did not happen, so put it back -- but only so many times, or
        -- a job that can never start cycles through the whole fleet forever.
        if (job.tries or 0) >= config.jobRetries then
          job.state  = "failed"
          job.reason = "abandoned after " .. tostring(job.tries) .. " attempts"
          events[#events + 1] = { job = job, event = "abandoned" }
        else
          job.state  = "pending"
          job.turtle = nil
          events[#events + 1] = { job = job, event = "requeued" }
        end
        if t then t.jobId = nil end
      end
    end
  end

  return events
end

--------------------------------------------------------------------------------
-- Ore reports
--------------------------------------------------------------------------------

--- Have we already got this seam covered?
--
-- Scan spheres overlap, so a scout descending a shaft reports the same seam
-- from two or three positions. Queueing each report would send three turtles to
-- the same hole, and the second and third would find it already mined.
--
-- Jobs that are done still count: a seam that has been harvested must not come
-- back the next time anything scans near it.
function fleet.knownSeam(f, cluster)
  for _, job in ipairs(f.jobs) do
    if job.pattern == "harvest" and job.origin
       and job.state ~= "failed" and job.state ~= "cancelled" then
      if manhattan(job.origin, cluster) <= config.clusterSame then return job end
    end
  end
end

--- Turn a scout's report into harvest jobs, skipping seams already covered.
--- Returns the jobs it added and how many it skipped.
function fleet.addSeams(f, clusters, params)
  local added, skipped = {}, 0

  for _, c in ipairs(clusters or {}) do
    if type(c) == "table" and c.x and c.y and c.z then
      if fleet.knownSeam(f, c) then
        skipped = skipped + 1
      else
        local job = fleet.addJob(f, {
          pattern = "harvest",
          params  = params or { radius = config.veinRadius, max = config.veinMax },
          origin  = { x = c.x, y = c.y, z = c.z },
          facing  = ALONG_Z,
          seam    = { count = c.count, name = c.name },
        })
        added[#added + 1] = job
      end
    end
  end

  return added, skipped
end

--------------------------------------------------------------------------------
-- Region splitting
--------------------------------------------------------------------------------

--- Carve one volume into `lanes` disjoint jobs.
--
-- `anchor` is the corner the volume extends from, in world coordinates, and is
-- the block a turtle would stand on to run the whole thing single-handed.
--
-- The split runs along the wider horizontal axis so lanes stay as square as
-- possible; a long thin lane is mostly travel. Remainder is spread one block at
-- a time across the first lanes rather than dumped on the last, so the widest
-- and narrowest lane differ by one and the turtles finish together.
--
-- Returns a list of jobs, or nil plus a reason.
function fleet.split(anchor, pattern, params, lanes)
  lanes = math.floor(tonumber(lanes) or 1)
  if lanes < 1 then return nil, "need at least one lane" end

  local spec = specs.get(pattern)
  if not spec then return nil, "unknown pattern" end
  local checked, why = specs.readParams(spec, params)
  if not checked then return nil, why end

  if type(anchor) ~= "table" or type(anchor.x) ~= "number"
     or type(anchor.y) ~= "number" or type(anchor.z) ~= "number" then
    return nil, "no anchor position"
  end

  -- Only the rectangular patterns have a footprint to divide. A corridor is
  -- already a line; splitting it would just make several shorter corridors,
  -- which is a different job the player can submit directly.
  if checked.w == nil or checked.d == nil then
    if lanes > 1 then return nil, pattern .. " cannot be split into lanes" end
    return { { pattern = pattern, params = checked,
               origin = { x = anchor.x, y = anchor.y, z = anchor.z },
               facing = ALONG_Z, lane = 1, lanes = 1 } }
  end

  local axis  = (checked.w >= checked.d) and "w" or "d"
  local span  = checked[axis]
  if lanes > span then
    return nil, ("%d lanes needs at least %d blocks, this one is %d wide")
      :format(lanes, lanes, span)
  end

  local base, extra = math.floor(span / lanes), span % lanes
  local jobs, offset = {}, 0

  for lane = 1, lanes do
    local width = base + ((lane <= extra) and 1 or 0)
    local params2 = {}
    for k, v in pairs(checked) do params2[k] = v end
    params2[axis] = width

    -- A quarry cut along w advances along -x from its corner (heading 1 walks
    -- the width), so lanes step along -x; cut along d they step along +z.
    local origin
    if axis == "w" then
      origin = { x = anchor.x - offset, y = anchor.y, z = anchor.z }
    else
      origin = { x = anchor.x, y = anchor.y, z = anchor.z + offset }
    end

    jobs[#jobs + 1] = {
      pattern = pattern,
      params  = params2,
      origin  = origin,
      facing  = ALONG_Z,
      lane    = lane,
      lanes   = lanes,
    }
    offset = offset + width
  end

  return jobs
end

return fleet
