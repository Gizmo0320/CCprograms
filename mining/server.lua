--- Fleet server. Runs on an advanced computer at base.
--
-- Owns the roster and the job queue, dispatches work to idle turtles, and shows
-- the fleet on its own screen and on an attached monitor. The pocket computer
-- talks to this; this talks to the turtles.
--
-- An ender modem is worth it here. Wireless is about 64 blocks, so a plain
-- modem cannot hear a turtle at Y-50 and the server is reduced to guessing.
--
-- All the decisions live in lib/fleet, which touches no APIs and is tested on
-- its own. What is left here is rednet, drawing, and the clock.

local config = require("lib.config")
local specs  = require("lib.specs")
local fleet  = require("lib.fleet")
local state  = require("lib.state")

local store = state.file(config.fleetFile, function(data)
  if type(data.turtles) ~= "table" or type(data.jobs) ~= "table" then
    return false, "not a fleet file"
  end
  return true
end)

local F        = fleet.new()
local running  = true
local log      = {}
local monitor  = nil
local lastDispatch = -math.huge

local function now() return os.clock() end

local function note(text, colour)
  log[#log + 1] = { text = text, colour = colour or colours.white,
                    at = os.date("%H:%M:%S") }
  while #log > 50 do table.remove(log, 1) end
end

--------------------------------------------------------------------------------
-- Networking
--------------------------------------------------------------------------------

local function openModem()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" and peripheral.call(side, "isWireless") then
      rednet.open(side)
      return side
    end
  end
  return nil
end

local function send(id, msg) rednet.send(id, msg, config.protocol) end
local function broadcast(msg) rednet.broadcast(msg, config.protocol) end

local function persist()
  store.save({ turtles = F.turtles, jobs = F.jobs, nextId = F.nextId })
end

--------------------------------------------------------------------------------
-- Fleet broadcast
--------------------------------------------------------------------------------

--- What the pocket renders. Deliberately a summary rather than the whole
--- roster: a rednet message carrying every turtle's full status table gets
--- large fast, and the pocket only draws a row per turtle anyway.
local function fleetMessage()
  local t = now()
  local turtles = {}
  for _, r in ipairs(fleet.roster(F, t)) do
    local s = r.status or {}
    turtles[#turtles + 1] = {
      id = r.id, label = r.label, stale = r.stale, role = s.role or "miner",
      state = r.stale and "lost" or s.state,
      fuel = s.fuel, mined = s.mined, progress = s.progress,
      pattern = s.pattern, pos = s.pos, jobId = r.jobId,
    }
  end

  local jobs = {}
  for _, job in ipairs(F.jobs) do
    if job.state == "pending" or job.state == "running" then
      jobs[#jobs + 1] = {
        id = job.id, pattern = job.pattern, state = job.state,
        turtle = job.turtle, lane = job.lane, lanes = job.lanes,
        waiting = job.waiting,
      }
    end
  end

  return {
    type    = "fleet",
    id      = os.getComputerID(),
    label   = os.getComputerLabel(),
    turtles = turtles,
    jobs    = jobs,
    counts  = fleet.counts(F, t),
  }
end

--------------------------------------------------------------------------------
-- Commands from the pocket
--------------------------------------------------------------------------------

-- `update` is relayed like any other command; a turtle refuses it while it is
-- working, so the blast radius is the idle half of the fleet. The server does
-- not update itself from this: it is one machine sitting at your base with a
-- keyboard, and a bad push that takes out the thing coordinating the recovery
-- is a worse day than walking over to it and typing `update`.
local ACTIONS = { pause = true, resume = true, abort = true,
                  ["return"] = true, update = true }

local function handleCommand(from, msg)
  if not ACTIONS[msg.action] then
    send(from, { type = "error", reason = "unknown action " .. tostring(msg.action) })
    return
  end

  local targets = {}
  if msg.target == "all" then
    for id in pairs(F.turtles) do targets[#targets + 1] = id end
  elseif F.turtles[msg.target] then
    targets[1] = msg.target
  else
    send(from, { type = "error", reason = "no such turtle" })
    return
  end

  for _, id in ipairs(targets) do
    -- Forward the branch and repo so a fleet can be pointed at a fork or a
    -- test branch without reinstalling every turtle by hand.
    send(id, { type = msg.action, branch = msg.branch, repo = msg.repo })
  end
  note(("%s -> %d turtle(s)"):format(msg.action, #targets), colours.yellow)
  send(from, { type = "ack", of = "command", count = #targets })
end

local function handleSubmit(from, msg)
  local jobs, why = fleet.split(msg.anchor, msg.pattern, msg.params, msg.lanes or 1)
  if not jobs then
    send(from, { type = "error", reason = why })
    note("rejected: " .. tostring(why), colours.red)
    return
  end

  local ids = {}
  for _, job in ipairs(jobs) do
    local added = fleet.addJob(F, job)
    ids[#ids + 1] = added.id
  end
  persist()
  note(("queued %s x%d"):format(msg.pattern, #jobs), colours.lime)
  send(from, { type = "ack", of = "submit", jobs = ids })
end

--- A scout has finished a sweep and is telling us what is down there.
local function handleOre(from, msg)
  if type(msg.clusters) ~= "table" then return end

  local added, skipped = fleet.addSeams(F, msg.clusters)
  if #added > 0 or skipped > 0 then
    persist()
    note(("scout %d: %d seam(s)%s"):format(from, #added,
      skipped > 0 and (", " .. skipped .. " already known") or ""), colours.lime)
  end
end

local function handleCancel(from, msg)
  local job, was = fleet.cancel(F, msg.jobId)
  if not job then
    send(from, { type = "error", reason = was or "no such job" })
    return
  end
  -- A running job only really stops when its turtle does, so tell it to come
  -- home. Marking the record is not enough on its own.
  if was == "running" and job.turtle then
    send(job.turtle, { type = "return" })
  end
  persist()
  note("cancelled " .. job.id, colours.orange)
  send(from, { type = "ack", of = "cancel" })
end

--------------------------------------------------------------------------------
-- Tasks
--------------------------------------------------------------------------------

local function listenerTask()
  while running do
    local from, msg = rednet.receive(config.protocol, 1)
    if type(msg) == "table" and type(msg.type) == "string" then
      if msg.type == "status" and msg.id then
        -- A turtle heartbeat. Fold it in and let reconcile work out what it
        -- means for the queue.
        fleet.sawTurtle(F, from, msg, now())
        for _, e in ipairs(fleet.reconcile(F, now())) do
          local colour = (e.event == "done") and colours.lime or colours.orange
          note(("%s %s"):format(e.job.id, e.event), colour)
        end

      elseif msg.type == "ore" then
        handleOre(from, msg)
      elseif msg.type == "submit" then
        handleSubmit(from, msg)
      elseif msg.type == "cancel" then
        handleCancel(from, msg)
      elseif msg.type == "command" then
        handleCommand(from, msg)
      elseif msg.type == "fleet?" then
        send(from, fleetMessage())
      end
    end
  end
end

local function dispatchTask()
  while running do
    -- Staggered: turtles all leaving base in the same tick means they all try
    -- to occupy the same block above the chest, and then spend their retry
    -- budget climbing over each other.
    if now() - lastDispatch >= config.dispatchDelay then
      local job, turtle = fleet.nextDispatch(F, now())
      if job and turtle then
        local msg = {
          type    = "start",
          pattern = job.pattern,
          origin  = job.origin,
          facing  = job.facing,
          jobId   = job.id,
        }
        for k, v in pairs(job.params) do msg[k] = v end
        send(turtle.id, msg)

        fleet.markRunning(F, job, turtle.id, now())
        lastDispatch = now()
        persist()
        note(("%s -> turtle %d"):format(job.id, turtle.id), colours.cyan)
      end
    end
    os.sleep(0.5)
  end
end

local function broadcastTask()
  while running do
    broadcast(fleetMessage())
    os.sleep(config.heartbeat)
  end
end

--------------------------------------------------------------------------------
-- Display
--------------------------------------------------------------------------------

local STATE_COLOUR = {
  idle = colours.lightGrey, mining = colours.lime, paused = colours.yellow,
  returning = colours.cyan, done = colours.lime, error = colours.red,
  lost = colours.red,
}

local function drawTo(target)
  local W, H = target.getSize()
  local colour = target.isColour and target.isColour()

  local function at(x, y, text, fg)
    if colour and fg then target.setTextColour(fg) end
    target.setCursorPos(x, y)
    target.write(tostring(text):sub(1, math.max(0, W - x + 1)))
    if colour then target.setTextColour(colours.white) end
  end

  target.setBackgroundColour(colours.black)
  target.clear()

  local t = now()
  local c = fleet.counts(F, t)
  local y = 1

  at(1, y, ("FLEET %s  %d turtles  %d idle  %d busy%s"):format(
    config.protocol, c.turtles, c.idle, c.busy,
    c.stale > 0 and ("  " .. c.stale .. " lost") or ""), colours.cyan)
  y = y + 1
  at(1, y, string.rep("-", W), colours.grey); y = y + 1

  at(1, y, "ID   LABEL      STATE      PROG  FUEL   ROLE", colours.lightGrey)
  y = y + 1

  local roster = fleet.roster(F, t)
  -- Leave room for the queue and the log; a long roster scrolls off rather
  -- than pushing everything else off the bottom.
  local rosterRows = math.max(1, math.floor((H - 6) / 2))
  for i = 1, math.min(#roster, rosterRows) do
    local r = roster[i]
    local s = r.status or {}
    local stateName = r.stale and "lost" or (s.state or "-")
    at(1, y, ("%-4d %-10s"):format(r.id, (r.label or "-"):sub(1, 10)))
    at(17, y, ("%-10s"):format(stateName), STATE_COLOUR[stateName] or colours.white)
    at(28, y, s.progress and ("%3d%%"):format(math.floor(s.progress * 100 + 0.5)) or "   -")
    at(34, y, s.fuel or "-",
      (type(s.fuel) == "number" and s.fuel <= config.fuelMargin)
        and colours.red or colours.white)
    at(41, y, (s.role == "scout") and "scout" or "miner",
      (s.role == "scout") and colours.magenta or colours.grey)
    y = y + 1
  end
  if #roster == 0 then
    at(1, y, "no turtles have reported in", colours.grey); y = y + 1
  elseif #roster > rosterRows then
    at(1, y, ("...and %d more"):format(#roster - rosterRows), colours.grey); y = y + 1
  end

  at(1, y, string.rep("-", W), colours.grey); y = y + 1
  at(1, y, ("QUEUE  %d pending  %d running  %d done  %d failed"):format(
    c.pending, c.running, c.done, c.failed), colours.lightGrey)
  y = y + 1

  for _, job in ipairs(F.jobs) do
    if y >= H then break end
    if job.state == "pending" or job.state == "running" then
      local lane = job.lanes and job.lanes > 1
        and (" [%d/%d]"):format(job.lane, job.lanes) or ""
      local where = job.turtle and (" -> " .. job.turtle) or ""
      at(1, y, ("%-4s %-8s %s%s%s"):format(job.id, job.pattern, job.state, lane, where),
        job.state == "running" and colours.lime or colours.lightGrey)
      if job.waiting and y < H then
        y = y + 1
        at(3, y, job.waiting, colours.orange)
      end
      y = y + 1
    end
  end

  -- Whatever room is left goes to the most recent events.
  if y < H then
    at(1, y, string.rep("-", W), colours.grey); y = y + 1
    for i = math.max(1, #log - (H - y)), #log do
      if y > H then break end
      local entry = log[i]
      at(1, y, entry.at .. " " .. entry.text, entry.colour)
      y = y + 1
    end
  end
end

local function displayTask()
  while running do
    drawTo(term)
    if monitor then
      local ok = pcall(drawTo, monitor)
      -- A monitor broken or unloaded mid-session must not take the server down
      -- with it; drop it and carry on drawing to the terminal.
      if not ok then monitor = nil note("monitor lost", colours.orange) end
    end
    os.sleep(0.5)
  end
end

--------------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------------

local function main()
  term.clear()
  term.setCursorPos(1, 1)

  local side = openModem()
  if not side then
    print("No wireless modem attached.")
    print("The fleet server needs one -- an ender modem if the")
    print("turtles work far from base.")
    return
  end

  -- Claim the fleet name on the network. rednet.host errors if another computer
  -- is already hosting it, and that is exactly the check worth having: two
  -- servers on one fleet would both dispatch, both reconcile, and the turtles
  -- would act on whichever order happened to arrive last. Nothing would look
  -- broken until two turtles turned up in the same lane.
  --
  -- It costs a two second lookup at startup, once. A crashed server leaves no
  -- stale claim behind, because lookup only hears from computers still running.
  local hosted, hostErr = pcall(rednet.host, config.protocol, "fleet")
  if not hosted then
    term.setTextColour(colours.red)
    print("Another server is already running on fleet '" .. config.protocol .. "'.")
    term.setTextColour(colours.white)
    print("")
    print("Two servers on one fleet both dispatch to the same")
    print("turtles. Stop the other one, or install this")
    print("computer on a different fleet:")
    print("  install.lua --fleet=<name>")
    print("")
    print("(" .. tostring(hostErr) .. ")")
    return
  end

  -- A side effect worth having: any computer can now find this one with
  -- rednet.lookup(protocol, "fleet").

  monitor = peripheral.find("monitor")
  if monitor then
    monitor.setTextScale(0.5)
    note("monitor attached", colours.lightGrey)
  end

  local saved = store.load()
  if saved then
    F = fleet.restore(saved)
    -- Everything that was running belonged to a turtle we have not heard from
    -- since the reboot. Leave the records alone: the next heartbeat tells us
    -- whether that turtle is still on the job, and reconcile sorts it out.
    note(("restored %d job(s)"):format(#F.jobs), colours.lightGrey)
  end

  note(("server %d up on %s, fleet '%s'")
    :format(os.getComputerID(), side, config.protocol), colours.cyan)

  parallel.waitForAny(listenerTask, dispatchTask, broadcastTask, displayTask)
end

main()
