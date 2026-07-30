--- Mining turtle controller. Runs on an advanced mining turtle.
--
-- Listens on the fleet channel for commands from remote.lua, broadcasts a status
-- heartbeat, and executes mining patterns. Resumes an unfinished job on boot.
--
-- Usage:  miner            wait for a command from the pocket computer
--         miner quarry 8 8 16    start immediately without a remote

local config   = require("lib.config")
local move     = require("lib.move")
local state    = require("lib.state")
local patterns = require("lib.patterns")
local specs    = require("lib.specs")
local scanner  = require("lib.scanner")
local net      = require("lib.net")

-- A turtle has exactly two upgrade slots. A miner spends them on a pickaxe and
-- a wireless modem; a scout spends them on a geo scanner and a wireless modem
-- and therefore has no tool at all. Carrying a scanner is what makes a turtle a
-- scout, and it is also what makes it unable to dig.
local ROLE = scanner.available() and "scout" or "miner"
move.canDig = (ROLE == "miner")

--------------------------------------------------------------------------------
-- Shared control block
--------------------------------------------------------------------------------

-- Written by the listener task, read by the mining task after every block.
local ctl = {
  paused     = false,
  abort      = false,
  returnHome = false,
  shutdown   = false,

  state    = "idle",       -- idle | mining | paused | returning | done | error
  pattern  = nil,
  jobId    = nil,          -- echoed back so the server knows which job this is
  progress = 0,
  done     = 0,            -- cells finished / cells in the job, so the remote
  total    = 0,            -- can show counts and work out an ETA
  message  = nil,

  job      = nil,          -- pending {pattern, params, resume}
  remote   = nil,          -- id of the last pocket computer heard from
}
move.ctl = ctl

--------------------------------------------------------------------------------
-- Console
--------------------------------------------------------------------------------

local function log(colour, text)
  if term.isColour() then term.setTextColour(colour) end
  print(text)
  if term.isColour() then term.setTextColour(colours.white) end
end

--------------------------------------------------------------------------------
-- Networking
--------------------------------------------------------------------------------

local function openModem() return net.open() end

local function buildStatus()
  return {
    type     = "status",
    id       = os.getComputerID(),
    label    = os.getComputerLabel(),
    role     = ROLE,
    pos      = move.copyPos(),
    heading  = move.heading,
    facing   = move.headingName(),
    gps      = move.gps,
    fuel     = turtle.getFuelLevel(),
    mined    = move.mined,
    state    = ctl.paused and ctl.state ~= "idle" and "paused" or ctl.state,
    pattern  = ctl.pattern,
    jobId    = ctl.jobId,
    progress = ctl.progress,
    done     = ctl.done,
    total    = ctl.total,
    dumps    = move.dumpRuns,
    refuels  = move.fuelRuns,
    fuelMax  = turtle.getFuelLimit and turtle.getFuelLimit() or nil,
    message  = ctl.message,
  }
end

local function broadcast(msg)
  net.broadcast(msg)
end

local function reply(id, msg)
  if id then net.send(id, msg) end
end

local function report(reason)
  ctl.message = reason
  broadcast({ type = "error", reason = reason })
end

--------------------------------------------------------------------------------
-- Job execution
--------------------------------------------------------------------------------

--- Validate an origin off the wire. Returns nil, nil when there is none (a
--- relative job, the old behaviour) and nil plus a reason when there is one but
--- it is malformed -- those two cases must not look alike, or a garbled message
--- would silently turn a placed job into a relative one somewhere else entirely.
local function readOrigin(o)
  if o == nil then return nil, nil end
  if type(o) ~= "table" then return nil, "origin must be a position" end
  local x, y, z = tonumber(o.x), tonumber(o.y), tonumber(o.z)
  if not (x and y and z) then return nil, "origin needs x, y and z" end
  return { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
end

local function runJob(job)
  local pattern = patterns.get(job.pattern)
  if not pattern then
    ctl.state = "error"
    report("unknown pattern: " .. tostring(job.pattern))
    return
  end

  ctl.pattern  = job.pattern
  ctl.jobId    = job.jobId
  ctl.progress = 0
  ctl.done, ctl.total = 0, 0
  ctl.message  = nil
  ctl.state    = "mining"
  ctl.abort, ctl.returnHome, ctl.paused = false, false, false

  local ctx = {
    resume = job.resume,
    setProgress = function(done, total)
      ctl.done, ctl.total = done, total
      ctl.progress = (total and total > 0) and (done / total) or 0
    end,
    -- How a pattern hands findings back. A survey uses it to report the ore
    -- clusters it saw; the server turns those into harvest jobs. Broadcast
    -- rather than replied, because the scout may have been started from the
    -- shell with no server involved yet.
    report = function(data)
      local msg = { type = "ore", id = os.getComputerID(), jobId = job.jobId }
      for k, v in pairs(data) do msg[k] = v end
      broadcast(msg)
      if data.clusters then
        log(colours.lime, ("Reported %d seam(s) from %d ore blocks.")
          :format(#data.clusters, data.blocks or 0))
      end
    end,
    checkpoint = function(data)
      state.save({
        pattern     = job.pattern,
        params      = job.params,
        checkpoint  = data,
        mined       = move.mined,
        home        = move.copyPos(move.home),
        homeHeading = move.homeHeading,
        pos         = move.copyPos(),
        heading     = move.heading,
      })
    end,
  }

  -- A dispatched job may name where it wants doing. Travel is a waypoint, not a
  -- new home: move.home stays the block the player put the turtle on, because
  -- that is where the dump chest is and dump-at-home depends on it.
  --
  -- Going through move.goTo means pause, abort, fuel and inventory guards all
  -- apply during the walk out, and a signal raised there unwinds into the same
  -- pcall as one raised mid-pattern.
  local ok, err = pcall(function()
    if job.origin then
      local reached, why = move.goTo(job.origin.x, job.origin.y, job.origin.z)
      if not reached then
        error(("cannot reach job origin %d,%d,%d: %s"):format(
          job.origin.x, job.origin.y, job.origin.z, tostring(why)), 0)
      end
      if job.facing then move.face(job.facing) end
    end
    return pattern.run(job.params, ctx)
  end)

  --- Walk home and say plainly whether the turtle made it. A turtle that could
  --- not get back is stranded, not idle, and the state file has to survive so
  --- there is a record of where it stopped.
  local function returnHome()
    ctl.state = "returning"
    broadcast(buildStatus())
    local arrived, why = move.goHome()
    if arrived then return true end
    local where = ("%d,%d,%d"):format(move.pos.x, move.pos.y, move.pos.z)
    local reason = "stranded at " .. where .. ": " .. tostring(why)
    ctl.state = "error"
    report(reason)
    state.fail(reason)
    log(colours.red, "Could not return home. Turtle is stranded at " .. where
      .. " (" .. tostring(why) .. ")")
    return false
  end

  if ok then
    if not returnHome() then return end
    state.clear()
    ctl.state    = "done"
    ctl.progress = 1
    ctl.message  = "job complete"
    log(colours.lime, "Job complete. " .. move.mined .. " blocks mined.")
    return
  end

  local signal, detail = move.isSignal(err)

  if signal == "abort" or signal == "return" then
    local word = (signal == "abort") and "aborted" or "recalled"
    if not returnHome() then return end
    state.clear()
    ctl.state   = "idle"
    ctl.message = word
    log(colours.orange, word:gsub("^%l", string.upper) .. "; returned home.")

  elseif signal == "fuel" or signal == "inventory" then
    -- Keep the state file: the job resumes once the human fixes the shortage.
    local reason = (signal == "fuel" and "out of fuel: " or "inventory full: ")
      .. tostring(detail)
    report(reason)
    if not returnHome() then return end
    state.fail(reason)
    ctl.state   = "error"
    ctl.message = reason
    log(colours.red, reason .. "; returned home.")
    log(colours.white, signal == "fuel"
      and "Refuel and rerun to resume."
      or  "Empty the turtle and rerun to resume.")

  else
    local reason = tostring(err)
    report(reason)
    state.fail(reason)
    log(colours.red, "Failed: " .. reason)
    if returnHome() then
      log(colours.orange, "Returned home after failure.")
      ctl.state   = "error"
      ctl.message = reason
    end
  end
end

--------------------------------------------------------------------------------
-- Tasks
--------------------------------------------------------------------------------

local function listenerTask()
  while not ctl.shutdown do
    local id, msg = net.receive(1)
    if type(msg) == "table" and type(msg.type) == "string" then
      ctl.remote = id
      local t = msg.type

      if t == "start" then
        local pattern = patterns.get(msg.pattern)
        if ctl.job or ctl.state == "mining" or ctl.state == "returning" then
          reply(id, { type = "error", reason = "busy" })
        elseif not pattern then
          reply(id, { type = "error", reason = "unknown pattern" })
        elseif pattern.role and pattern.role ~= ROLE then
          -- A scout cannot quarry and a miner cannot scan. Refusing here rather
          -- than failing halfway means the server can hand the job to something
          -- that can actually do it.
          reply(id, { type = "error",
                      reason = ("%s needs a %s, this is a %s")
                        :format(msg.pattern, pattern.role, ROLE) })
        else
          local params, why = specs.readParams(pattern, msg)
          local origin, originWhy = readOrigin(msg.origin)
          if not params then
            reply(id, { type = "error", reason = why })
          elseif not origin and originWhy then
            reply(id, { type = "error", reason = originWhy })
          elseif origin and not move.gps then
            -- An absolute position means nothing to a turtle dead-reckoning
            -- from 0,0,0. Accepting it would send it confidently to a place
            -- that has no relation to where the server meant.
            reply(id, { type = "error", reason = "no gps fix, cannot take a placed job" })
          else
            ctl.job = {
              pattern = msg.pattern,
              params  = params,
              origin  = origin,
              facing  = tonumber(msg.facing),
              jobId   = msg.jobId,
            }
            reply(id, { type = "ack", of = t, jobId = msg.jobId })
          end
        end

      elseif t == "pause" then
        ctl.paused = true
        reply(id, { type = "ack", of = t })

      elseif t == "resume" then
        ctl.paused = false
        reply(id, { type = "ack", of = t })

      elseif t == "abort" then
        ctl.abort  = true
        ctl.paused = false
        reply(id, { type = "ack", of = t })

      elseif t == "return" then
        ctl.returnHome = true
        ctl.paused     = false
        reply(id, { type = "ack", of = t })

      elseif t == "status" then
        reply(id, buildStatus())

      elseif t == "update" then
        -- Never mid-job. Swapping lib/move.lua underneath a running quarry
        -- leaves a turtle halfway down a hole running half of two versions,
        -- and the reboot afterwards would abandon the job where it stands.
        if ctl.state == "mining" or ctl.state == "returning" or ctl.job then
          reply(id, { type = "error", reason = "busy; not updating mid-job" })
        else
          reply(id, { type = "ack", of = t })
          ctl.update = { branch = msg.branch, repo = msg.repo }
          ctl.shutdown = true
        end

      elseif t == "shutdown" then
        ctl.shutdown = true
        ctl.abort    = true
        reply(id, { type = "ack", of = t })
      end
    end
  end
end

local function heartbeatTask()
  while not ctl.shutdown do
    broadcast(buildStatus())
    os.sleep(config.heartbeat)
  end
end

local function workerTask()
  while not ctl.shutdown do
    if ctl.job then
      local job = ctl.job
      ctl.job = nil
      runJob(job)
      -- Clear one-shot flags so the next job starts from a clean slate.
      ctl.abort, ctl.returnHome, ctl.paused = false, false, false
      if job.fromShell then
        -- Launched with arguments from the shell: finish and hand the terminal
        -- back. A remote-issued or resumed job leaves the turtle listening.
        broadcast(buildStatus())
        ctl.shutdown = true
      end
    else
      os.sleep(0.2)
    end
  end
end

--------------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------------

local function parseArgs(args)
  if #args == 0 then return nil end
  local name = args[1]
  local pattern = patterns.get(name)
  if not pattern then
    log(colours.red, "Unknown pattern: " .. tostring(name))
    log(colours.white, "Known patterns: " .. table.concat(patterns.order, ", "))
    return nil, true
  end
  local given = {}
  for i, spec in ipairs(pattern.params) do
    given[spec.key] = tonumber(args[i + 1]) or spec.default
  end
  local params, why = specs.readParams(pattern, given)
  if not params then
    log(colours.red, why)
    return nil, true
  end
  return { pattern = name, params = params, fromShell = true }
end

--- Offer a short window to cancel, then resume unattended. startup.lua relies
--- on this: a rebooted turtle must pick its job back up with nobody watching.
local function confirmResume(saved)
  log(colours.yellow, ("Unfinished %s job found (layer %d of %d).")
    :format(saved.pattern, (saved.checkpoint and saved.checkpoint.layer) or 1,
            saved.params.h or 0))
  if saved.failed then log(colours.red, "Last failure: " .. tostring(saved.failed)) end
  log(colours.white, "Resuming in 3s - press Q to cancel.")

  local timer = os.startTimer(3)
  while true do
    local event, a = os.pullEvent()
    if event == "timer" and a == timer then
      return true
    elseif event == "char" and (a == "q" or a == "Q") then
      return false
    end
  end
end

local function main(args)
  term.clear()
  term.setCursorPos(1, 1)
  log(colours.cyan, (ROLE == "scout" and "Scout turtle " or "Mining turtle ")
    .. os.getComputerID() .. " (" .. (os.getComputerLabel() or "unlabelled") .. ")")
  if ROLE == "scout" then
    log(colours.white, "Geo scanner found: no pickaxe, so it travels through")
    log(colours.white, "open air only. Drop it down a quarry the miners dug.")
  end

  local side = openModem()
  if side then
    log(colours.white, ("Modem on %s, fleet '%s' channel %d")
      :format(side, config.protocol, config.channel))
  else
    log(colours.orange, "No wireless modem: running standalone, no remote control.")
  end

  local saved = state.load()
  local resumeJob

  if saved and not saved.checkpoint then
    -- A failure record with no progress in it: nothing to resume.
    log(colours.orange, "Previous run failed: " .. tostring(saved.failed))
    state.clear()
    saved = nil
  end

  if saved then
    -- The file is on disk across reboots and edits, so treat it as untrusted:
    -- resuming into a pattern that no longer exists, or with parameters the
    -- pattern cannot honour, is worse than starting clean.
    local pattern = patterns.get(saved.pattern)
    local params  = specs.readParams(pattern, saved.params)
    if not params then
      log(colours.orange, "Saved job is not resumable ("
        .. tostring(saved.pattern) .. "); discarding.")
      state.clear()
      saved = nil
    else
      saved.params = params
    end
  end

  if saved then
    if confirmResume(saved) then
      move.restore(saved)
      resumeJob = {
        pattern = saved.pattern,
        params  = saved.params,
        resume  = saved.checkpoint,
      }
      log(colours.white, ("Frame restored: %d,%d,%d facing %s")
        :format(move.pos.x, move.pos.y, move.pos.z, move.headingName()))
    else
      state.clear()
      log(colours.white, "Saved job discarded.")
    end
  end

  if not resumeJob then
    local gpsOk, note = move.calibrate()
    log(gpsOk and colours.lime or colours.orange, "Origin: "
      .. move.pos.x .. "," .. move.pos.y .. "," .. move.pos.z
      .. " facing " .. move.headingName() .. " (" .. note .. ")")

    local argJob, bad = parseArgs(args)
    if bad then return end
    resumeJob = argJob
  end

  local level = turtle.getFuelLevel()
  local lowFuel = level ~= "unlimited" and level <= config.fuelMargin
  log(lowFuel and colours.orange or colours.white, "Fuel: " .. tostring(level))

  ctl.job = resumeJob
  if not resumeJob then
    if not side then
      log(colours.red, "Nothing to do and no modem. Give a pattern: miner quarry 8 8 16")
      return
    end
    log(colours.white, "Idle. Waiting for commands.")
  end

  if side then
    parallel.waitForAny(workerTask, listenerTask, heartbeatTask)
  else
    workerTask()
  end

  -- Run the updater after the tasks have stopped, not from inside the listener:
  -- update.lua reboots, and rebooting out of one branch of parallel.waitForAny
  -- while a job is still unwinding in another is how a half-written state file
  -- happens.
  if ctl.update then
    log(colours.cyan, "Updating from GitHub...")
    shell.run("/update.lua", ctl.update.branch or "", ctl.update.repo or "")
  end
end

main({ ... })
