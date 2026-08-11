--- Redstone node. Runs on any computer wired to redstone.
--
-- Owns this computer's ports, evaluates its own rules and logic blocks, and
-- reports what it is doing. It needs nothing else to be running: the server
-- coordinates scenes and keeps the log, but a node whose base server is in an
-- unloaded chunk goes on opening its own door. A door that only works when a
-- computer three hundred blocks away is loaded is worse than no door.
--
-- Two coroutines under parallel.waitForAny:
--
--   sweep     polls the ports, runs the rules and blocks, applies the result
--   listener  takes orders off the modem
--
-- The sweep is driven by the `redstone` event *and* a timer. The event covers
-- inputs changing; nothing will ever raise an event to say a debounce has
-- expired, a pulse should end or a blink is due, so the timer covers time.

local config = require("lib.config")
local net    = require("lib.net")
local ports  = require("lib.ports")
local rules  = require("lib.rules")
local logic  = require("lib.logic")
local state  = require("lib.state")

local node = {
  running   = true,
  update    = nil,      -- set by an update order, run after parallel returns
  rules     = {},
  blocks    = {},
  memo      = { rules = {}, blocks = {} },
  pulses    = {},       -- [port] = { until_ = t, restore = value, why = ... }
  readings  = nil,      -- last sweep's, for edge detection
  beatAt    = -math.huge,
  problems  = {},
}

local function now() return os.clock() end

--------------------------------------------------------------------------------
-- Screen
--------------------------------------------------------------------------------

local function colour(c)
  if term.isColour() then term.setTextColour(c) end
end

local function say(text, c)
  colour(c or colours.white)
  print(text)
  colour(colours.white)
end

--------------------------------------------------------------------------------
-- Rules and blocks on disk
--------------------------------------------------------------------------------

--- /rules.cfg returns either a plain list of rules or { rules = {}, blocks = {} }.
--
-- Both shapes because the first is what someone writes by hand for a network
-- with three lamps in it, and having to wrap that in a table with one key to
-- add a rule is a papercut on the most common case.
local function loadRules()
  node.rules, node.blocks, node.problems = {}, {}, {}

  if not fs or not fs.exists(config.rulesFile) then return end

  local fn, err = loadfile(config.rulesFile)
  if not fn then
    node.problems = { config.rulesFile .. ": " .. tostring(err) }
    return
  end

  local ok, data = pcall(fn)
  if not ok or type(data) ~= "table" then
    node.problems = { config.rulesFile .. ": " .. tostring(data) }
    return
  end

  local rawRules  = data.rules or data
  local rawBlocks = data.blocks or {}

  -- Port shapes for validation. Rules naming a port this computer does not
  -- have are dropped with a reason rather than failing at the first sweep.
  local shapes = {}
  for _, p in ipairs(ports.list) do shapes[p.name] = { dir = p.dir, kind = p.kind } end

  local good, problems = rules.validate(rawRules, shapes)
  node.rules = good
  for _, why in ipairs(problems) do node.problems[#node.problems + 1] = why end

  for i, block in ipairs(rawBlocks) do
    local fine, why = logic.check(block, shapes)
    if fine then
      node.blocks[#node.blocks + 1] = block
    else
      node.problems[#node.problems + 1] = ("block %d (%s): %s")
        :format(i, tostring(type(block) == "table" and block.id or "?"), why)
    end
  end
end

--- Write the rules back, so an edit made from the pocket computer survives a
--- reboot. Serialised as a Lua file returning a table, which is the same shape
--- someone would have written by hand -- there is one format, not two.
local function saveRules()
  if not fs then return false end

  local body = "-- Written by node.lua. Edit freely; this is the same shape\n"
    .. "-- install.lua leaves behind and the pocket computer edits.\n"
    .. "return " .. textutils.serialize({ rules = node.rules, blocks = node.blocks })
    .. "\n"

  local tmp = config.rulesFile .. ".part"
  local f = fs.open(tmp, "w")
  if not f then return false end
  f.write(body)
  f.close()
  if fs.exists(config.rulesFile) then fs.delete(config.rulesFile) end
  fs.move(tmp, config.rulesFile)
  return true
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

--- Absolute times in restored memory are meaningless: os.clock() restarts at
--- zero when the computer boots, so a debounce that was due at t=900 would sit
--- there for fifteen minutes waiting for a clock that has gone back to nothing.
--
-- Drop every time-valued field and keep the rest. That is exactly the right
-- split: a latch's `on` and a counter's `count` are facts about the world and
-- should survive, while "the condition has held since t=871" is a fact about a
-- clock that no longer exists.
local function reviveMemo(memo)
  for _, group in pairs(memo or {}) do
    for _, st in pairs(group) do
      if type(st) == "table" then
        st.since, st.until_, st.next_ = nil, nil, nil
      end
    end
  end
  return memo
end

local function markState()
  state.data.outputs = ports.saved()
  state.data.memo    = node.memo
  state.data.pulses  = node.pulses
  state.mark()
end

--------------------------------------------------------------------------------
-- Messaging
--------------------------------------------------------------------------------

local function describe()
  return {
    type   = "state",
    role   = "node",
    label  = os.getComputerLabel(),
    ports  = ports.describe(),
    rules  = #node.rules,
    blocks = #node.blocks,
    warn   = (#node.problems > 0) and node.problems[1] or nil,
  }
end

local function heartbeat(force)
  local t = now()
  if not force and (t - node.beatAt) < config.heartbeat then return end
  node.beatAt = t
  net.broadcast(describe())
end

--- One line for the server's log, sent when it happens rather than folded into
--- the next heartbeat. The question the log answers is "what turned that off",
--- and an entry that arrives two seconds later next to three others has lost
--- the ordering that made it an answer.
local function report(change)
  net.broadcast({
    type = "event", port = change.port,
    from = change.from, to = change.to, why = change.why or "input",
  })
end

--------------------------------------------------------------------------------
-- The sweep
--------------------------------------------------------------------------------

--- Turn a rule or block action into a batch entry, scheduling the restore if it
--- is a pulse.
local function stage(batch, action, t)
  if action.scene then return end          -- server business; a node has none
  if not action.port then return end

  if action.pulse then
    local secs = math.min(tonumber(action.pulse) or 0, config.maxPulse)
    if secs <= 0 then return end
    local port = ports.get(action.port)
    if not port then return end

    -- The resting value is whatever it was before the pulse, not `false`: a
    -- normally-closed circuit pulsed open has to go back to closed.
    if not node.pulses[action.port] then
      node.pulses[action.port] = {
        restore = ports.outputs[action.port],
        why     = action.why,
      }
    end
    node.pulses[action.port].until_ = t + secs

    batch[#batch + 1] = { port = action.port, value = true, why = action.why }
  else
    batch[#batch + 1] = { port = action.port, value = action.set, why = action.why }
  end
end

local function sweep()
  local t   = now()
  local was = node.readings
  local is  = ports.snapshot(ports.poll())

  local batch = {}

  -- Expired pulses first, so a rule that wants to pulse the same port again
  -- this sweep is staged after the restore rather than cancelled by it.
  for port, pulse in pairs(node.pulses) do
    if t >= (pulse.until_ or 0) then
      batch[#batch + 1] = { port = port, value = pulse.restore,
                            why = (pulse.why or "pulse") .. " end" }
      node.pulses[port] = nil
    end
  end

  for _, action in ipairs(rules.evaluate(node.rules, is, was, t, node.memo.rules)) do
    stage(batch, action, t)
  end

  for _, action in ipairs(logic.evaluate(node.blocks, node.memo.blocks, is, t)) do
    stage(batch, action, t)
  end

  -- One batch, so a bundled cable is written once however many of its colours
  -- changed, and so nothing in this sweep can see half of its own effects.
  local applied = ports.apply(batch)

  -- Inputs that moved on their own are worth a log line too -- often they are
  -- the interesting half, because they are what the rules were reacting to.
  if was then
    for _, change in ipairs(ports.diff(was, is)) do
      local p = ports.get(change.port)
      if p and p.dir == "in" then report(change) end
    end
  end

  for _, change in ipairs(applied) do
    report(change)
    is[change.port] = change.to
  end

  node.readings = is

  if #applied > 0 then
    markState()
    heartbeat(true)      -- something visibly changed; do not make anyone wait
  end

  state.tick(t)
  heartbeat(false)
end

local function sweepTask()
  local timer = os.startTimer(config.sweep)

  while node.running do
    local event, a = os.pullEvent()

    if event == "timer" and a == timer then
      timer = os.startTimer(config.sweep)
      sweep()
    elseif event == "redstone" or event == "rs_sweep" then
      -- An input moved, or the listener has just applied an order and wants the
      -- consequences worked out now rather than up to a quarter second later.
      sweep()
    end
  end
end

--------------------------------------------------------------------------------
-- The listener
--------------------------------------------------------------------------------

--- Drive a port by hand. `keepPulse` is for the one caller that is *starting* a
--- pulse and would otherwise have its own timer cleared out from under it.
local function manual(port, value, why, keepPulse)
  local ok, prev = ports.set(port, value)
  if not ok then return false, prev end

  -- A hand-driven change cancels any pulse on that port. Otherwise turning a
  -- light on during a pulse would have it snap off again when the pulse it knew
  -- nothing about expired.
  if not keepPulse then node.pulses[port] = nil end

  if prev ~= ports.outputs[port] then
    report({ port = port, from = prev, to = ports.outputs[port], why = why or "manual" })
    markState()
  end
  return true
end

local function editRule(msg)
  local incoming = msg.rule
  local action   = msg.action

  if action == "remove" or action == "enable" or action == "disable" then
    local id = (type(incoming) == "table" and incoming.id) or msg.id
    for i, rule in ipairs(node.rules) do
      if rule.id == id then
        if action == "remove" then
          table.remove(node.rules, i)
        else
          rule.enabled = (action == "enable")
        end
        rules.prune(node.rules, node.memo.rules)
        saveRules()
        return true
      end
    end
    return false, "no rule named " .. tostring(id)
  end

  if action ~= "add" then return false, "unknown rule action" end

  local shapes = {}
  for _, p in ipairs(ports.list) do shapes[p.name] = { dir = p.dir, kind = p.kind } end

  local ok, why = rules.check(incoming, shapes)
  if not ok then return false, why end

  -- Replace by id rather than append, so editing a rule on the pocket computer
  -- and sending it back does not leave two rules fighting over one port.
  for i, rule in ipairs(node.rules) do
    if rule.id == incoming.id then node.rules[i] = incoming; saveRules(); return true end
  end

  local candidate = {}
  for _, rule in ipairs(node.rules) do candidate[#candidate + 1] = rule end
  candidate[#candidate + 1] = incoming

  local clashes = rules.conflicts(candidate)
  if #clashes > 0 then
    return false, ("conflicts with %s over %s")
      :format(clashes[1].rules[1], clashes[1].port)
  end

  node.rules[#node.rules + 1] = incoming
  saveRules()
  return true
end

--- Is anything mid-flight? An update reboots, and rebooting with a pulse
--- outstanding leaves the output stuck on -- the restore was going to happen in
--- half a second and now never will.
local function busy()
  if next(node.pulses) then return true end
  for _, st in pairs(node.memo.rules) do
    if st.since and not st.fired then return true end
  end
  return false
end

local function handle(from, msg)
  if type(msg) ~= "table" or not msg.type then return end

  if msg.type == "set" then
    local ok, why = manual(msg.port, msg.value, msg.why)
    if not ok then net.send(from, { type = "error", reason = why }) end
    os.queueEvent("rs_sweep")

  elseif msg.type == "pulse" then
    local port = ports.get(msg.port)
    if not port or port.dir ~= "out" then
      net.send(from, { type = "error", reason = "no output named " .. tostring(msg.port) })
    else
      local secs = math.min(math.max(tonumber(msg.secs) or 0.5, 0.05), config.maxPulse)

      -- Retriggering keeps the *original* resting value. Reading it off the
      -- port instead would latch a repeatedly-pulsed output permanently on:
      -- the second pulse would decide that "on" was where it came from.
      --
      -- Spelled out rather than written as `pending and pending.restore or
      -- ports.outputs[...]`, because the resting value this exists to protect
      -- is usually `false` -- and `false or x` is x, which is the exact latch
      -- the paragraph above is about.
      local resting = ports.outputs[msg.port]
      local pending = node.pulses[msg.port]
      if pending then resting = pending.restore end

      manual(msg.port, true, msg.why or "manual", true)
      node.pulses[msg.port] = {
        restore = resting, why = msg.why or "manual", until_ = now() + secs,
      }
      os.queueEvent("rs_sweep")
    end

  elseif msg.type == "ports?" then
    net.send(from, describe())

  elseif msg.type == "rules?" then
    net.send(from, { type = "rules", rules = node.rules, blocks = node.blocks,
                     problems = node.problems })

  elseif msg.type == "rule" then
    local ok, why = editRule(msg)
    net.send(from, ok and { type = "ack", of = "rule" }
                      or { type = "error", reason = why })
    os.queueEvent("rs_sweep")

  elseif msg.type == "rename" then
    -- Allowed at any time. Nothing on disk changes and nothing reboots, so
    -- there is no reason to make someone wait for a pulse to finish to fix a
    -- typo in a name.
    local name = tostring(msg.name or ""):gsub("[^%w%-_]", ""):sub(1, 24)
    if name ~= "" then
      os.setComputerLabel(name)
      heartbeat(true)
    end

  elseif msg.type == "update" then
    if busy() then
      net.send(from, { type = "error", reason = "busy: a pulse or debounce is pending" })
    else
      net.send(from, { type = "ack", of = "update" })
      node.update  = { branch = msg.branch or "main", repo = msg.repo or "" }
      node.running = false
      -- Ends the listener; parallel.waitForAny then ends the sweep, and the
      -- update runs at the bottom of this file. Never from in here: rebooting
      -- out of one branch while the other is halfway through a batch is how a
      -- half-written state file happens.
      os.queueEvent("rs_sweep")
    end
  end
end

local function listenerTask()
  while node.running do
    local event, a, b, c, d = os.pullEvent()
    local from, msg = net.decode(event, a, b, c, d)
    if from then handle(from, msg) end
  end
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

term.clear()
term.setCursorPos(1, 1)
say("Redstone node", colours.cyan)
say(("network '%s' on channel %d"):format(config.protocol, config.channel), colours.grey)

local ok, problems = ports.load()
if not ok then
  for _, why in ipairs(problems) do say("  " .. why, colours.orange) end
end

if ports.count() == 0 then
  say("No ports defined. Edit " .. config.portsFile .. " and reboot.", colours.red)
  say("install.lua leaves an example there.", colours.white)
  return
end

-- Outputs first, before anything can be told about them. An output is held by
-- the computer rather than by the world, so without this every lamp in the base
-- goes dark the moment the chunk reloads -- and a heartbeat sent before the
-- restore would be announcing a state we had not applied yet.
state.open(config.stateFile, { outputs = {}, memo = {}, pulses = {} })
node.memo = reviveMemo(state.data.memo) or { rules = {}, blocks = {} }
node.memo.rules  = node.memo.rules  or {}
node.memo.blocks = node.memo.blocks or {}

local restored = ports.restore(state.data.outputs)

-- Anything caught mid-pulse when the power went off is put back to its resting
-- value rather than left out. The deadline that would have done it belonged to
-- a clock that no longer exists.
for port, pulse in pairs(state.data.pulses or {}) do
  ports.set(port, pulse.restore)
end
node.pulses = {}
state.data.pulses = {}
state.flush(now())

say(("%d port(s), %d output(s) restored"):format(ports.count(), restored), colours.lime)

loadRules()
rules.prune(node.rules, node.memo.rules)
logic.prune(node.blocks, node.memo.blocks)
say(("%d rule(s), %d block(s)"):format(#node.rules, #node.blocks),
  #node.problems > 0 and colours.orange or colours.lime)
for _, why in ipairs(node.problems) do say("  " .. why, colours.orange) end

if not net.open() then
  say("No wireless modem. Running local rules only --", colours.orange)
  say("nothing can see or command this node.", colours.orange)
else
  say("Listening on channel " .. config.channel, colours.lightGrey)
end

node.readings = ports.snapshot(ports.poll())
heartbeat(true)

parallel.waitForAny(sweepTask, listenerTask)

--------------------------------------------------------------------------------

state.flush(now())

if node.update then
  say("Updating...", colours.yellow)
  shell.run("/update.lua", node.update.branch, node.update.repo)
end
