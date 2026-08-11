--- Logic blocks. Pure state machines.
--
-- The pieces a single condition cannot express. A rule says "when this, do
-- that"; it cannot say "stay on until something else turns you off", or "flip
-- every time the button is pressed", because both of those are memory.
--
-- Every block is `step(st, inputs, now)` returning `st, output`, with all of
-- its memory in `st` and nothing read from the world. That is what makes a
-- latch meant to survive a reboot merely a table written to disk, and the whole
-- file testable as arithmetic.
--
-- A block instance is data, like a rule:
--
--   { id = "front-door", kind = "latch", out = "door",
--     wire = { set = "doorbell", reset = "close-button" } }
--
-- `wire` maps the block's input names to port names. `out` is the port it
-- drives. node.lua evaluates blocks in the same sweep as rules and applies both
-- through the one batch.

local logic = {}

local function truthy(v)
  if type(v) == "number" then return v > 0 end
  return v and true or false
end

--- Rising edge against a remembered value. Every block that cares about a
--- press rather than a hold goes through this, so they all agree that a first
--- sweep with nothing remembered is not an edge -- otherwise every toggle in
--- the base flips once when the chunk loads.
local function rose(st, key, value)
  local was = st[key]
  st[key] = value
  return value and was == false
end

--------------------------------------------------------------------------------

logic.blocks = {}

local function define(kind, spec)
  spec.kind = kind
  logic.blocks[kind] = spec
end

--------------------------------------------------------------------------------

local GATES = {
  ["and"]  = function(n, count) return n == count end,
  ["or"]   = function(n) return n > 0 end,
  ["not"]  = function(n) return n == 0 end,
  ["xor"]  = function(n) return n % 2 == 1 end,
  ["nand"] = function(n, count) return n ~= count end,
  ["nor"]  = function(n) return n == 0 end,
}

--- Combinational, and the only block with no memory at all. Kept here anyway:
--- a network where half the logic is a block and half is a rule condition is
--- harder to read than one where all of it is blocks.
define("gate", {
  inputs = "n",
  params = { { key = "op", kind = "choice",
               choices = { "and", "or", "not", "xor", "nand", "nor" },
               default = "and" } },
  step = function(st, inputs, _, params)
    local n, count = 0, 0
    for _, v in ipairs(inputs) do
      count = count + 1
      if truthy(v) then n = n + 1 end
    end
    local fn = GATES[(params and params.op) or "and"] or GATES["and"]
    return st, fn(n, count)
  end,
})

--- Set/reset latch. A doorbell that leaves the light on until you press the
--- other button.
--
-- Reset wins when both arrive in the same sweep. That is not arbitrary: reset
-- is the one that turns things off, and a tie that leaves a machine running is
-- a worse failure than a tie that stops it.
define("latch", {
  inputs = { "set", "reset" },
  params = {},
  step = function(st, inputs)
    if truthy(inputs.reset) then
      st.on = false
    elseif truthy(inputs.set) then
      st.on = true
    end
    return st, st.on == true
  end,
})

--- A button that alternates rather than follows. The single most asked-for
--- thing a bare redstone button cannot do.
define("toggle", {
  inputs = { "input", "reset" },
  params = {},
  step = function(st, inputs)
    if truthy(inputs.reset) then
      st.on = false
    elseif rose(st, "last", truthy(inputs.input)) then
      st.on = not st.on
    end
    return st, st.on == true
  end,
})

--- Pulse extender: a press becomes an output held for `secs`.
--
-- Retriggerable -- a second press while it is still on restarts the clock
-- rather than being ignored. A motion sensor lighting a corridor should keep it
-- lit while someone is walking down it.
define("pulse", {
  inputs = { "input" },
  params = { { key = "secs", kind = "number", default = 1, min = 0.05, max = 60 } },
  step = function(st, inputs, now, params)
    if rose(st, "last", truthy(inputs.input)) then
      st.until_ = now + ((params and params.secs) or 1)
    end
    if st.until_ and now >= st.until_ then st.until_ = nil end
    return st, st.until_ ~= nil
  end,
})

--- Output follows input, but only once it has held that way for `secs`.
--
-- Both edges, deliberately. A one-sided delay is a pulse extender, which is the
-- block above; this one is for a signal that chatters and should be believed
-- only when it settles.
define("delay", {
  inputs = { "input" },
  params = { { key = "secs", kind = "number", default = 1, min = 0.05, max = 600 } },
  step = function(st, inputs, now, params)
    local want = truthy(inputs.input)
    if st.on == nil then st.on = false end

    if want == st.on then
      st.since = nil
    else
      st.since = st.since or now
      if (now - st.since) >= ((params and params.secs) or 1) then
        st.on, st.since = want, nil
      end
    end

    return st, st.on
  end,
})

--- A clock, gated by its input: while enabled, the output flips every `secs`.
--
-- `next_` is cleared when it is disabled rather than left to run, so switching
-- it back on starts a full interval instead of firing immediately on a deadline
-- that expired while nobody was watching.
define("blink", {
  inputs = { "input" },
  params = { { key = "secs", kind = "number", default = 0.5, min = 0.05, max = 600 } },
  step = function(st, inputs, now, params)
    if not truthy(inputs.input) then
      st.on, st.next_ = false, nil
      return st, false
    end

    if not st.next_ then
      st.on, st.next_ = true, now + ((params and params.secs) or 0.5)
    elseif now >= st.next_ then
      st.on, st.next_ = not st.on, now + ((params and params.secs) or 0.5)
    end

    return st, st.on == true
  end,
})

--- Counts rising edges and turns on at `n`. Stays on until reset -- an item
--- counter that switched off again as the seventeenth item went past would be
--- unreadable at anything faster than walking pace.
define("counter", {
  inputs = { "input", "reset" },
  params = { { key = "n", kind = "number", default = 8, min = 1, max = 9999 } },
  step = function(st, inputs, _, params)
    if truthy(inputs.reset) then
      st.count = 0
    elseif rose(st, "last", truthy(inputs.input)) then
      st.count = (st.count or 0) + 1
    end
    return st, (st.count or 0) >= ((params and params.n) or 8)
  end,
})

--------------------------------------------------------------------------------

logic.order = { "gate", "latch", "toggle", "pulse", "delay", "blink", "counter" }

function logic.get(kind) return logic.blocks[kind] end

--------------------------------------------------------------------------------

--- Evaluate one block against a table of port readings.
--
-- `st` is the block's persisted memory and is mutated in place. Returns the
-- output value, which the caller turns into an action for `block.out`.
function logic.run(block, st, readings, now)
  local spec = logic.blocks[block.kind]
  if not spec then return nil, "no such block: " .. tostring(block.kind) end

  local inputs
  if spec.inputs == "n" then
    inputs = {}
    for i, port in ipairs(block.wire or {}) do inputs[i] = readings[port] end
  else
    inputs = {}
    for _, name in ipairs(spec.inputs) do
      local port = block.wire and block.wire[name]
      -- An unwired input reads false rather than nil, so a latch with no reset
      -- button is a latch that never resets instead of one that errors.
      inputs[name] = port and readings[port] or false
    end
  end

  local _, out = spec.step(st, inputs, now, block.params)
  return out
end

--- Run every block and return actions in the same shape rules.evaluate does,
--- so node.lua applies both through one batch.
--
-- Unlike a rule, a block emits its output every sweep rather than on a
-- transition: a block *is* the state of its output, and one that stopped saying
-- so could be left contradicting the wire after anything else touched it.
-- lib/ports.apply drops writes that change nothing, so this costs no traffic.
function logic.evaluate(list, memo, readings, now)
  local actions = {}
  memo = memo or {}

  for _, block in ipairs(list or {}) do
    if block.enabled ~= false and block.id and block.out then
      local st = memo[block.id]
      if not st then st = {}; memo[block.id] = st end

      local out = logic.run(block, st, readings, now)
      if out ~= nil then
        actions[#actions + 1] = { port = block.out, set = out, why = block.id }
      end
    end
  end

  return actions
end

function logic.prune(list, memo)
  local live = {}
  for _, block in ipairs(list or {}) do
    if block.id then live[block.id] = true end
  end
  for id in pairs(memo or {}) do
    if not live[id] then memo[id] = nil end
  end
  return memo
end

--------------------------------------------------------------------------------

--- Is this block sound? Returns ok, reason.
function logic.check(block, ports)
  if type(block) ~= "table" then return false, "not a table" end
  if type(block.id) ~= "string" or block.id == "" then return false, "no id" end

  local spec = logic.blocks[block.kind]
  if not spec then return false, "'" .. tostring(block.kind) .. "' is not a block" end

  if type(block.out) ~= "string" then return false, "no output port" end
  if ports then
    local p = ports[block.out]
    if not p then return false, "no port named " .. block.out end
    if p.dir ~= "out" then return false, block.out .. " is an input" end
  end

  local wire = block.wire or {}
  local wired = {}

  if spec.inputs == "n" then
    if #wire == 0 then return false, "no inputs wired" end
    for _, port in ipairs(wire) do wired[#wired + 1] = port end
  else
    local any = false
    for _, name in ipairs(spec.inputs) do
      if wire[name] then any = true; wired[#wired + 1] = wire[name] end
    end
    if not any then return false, "no inputs wired" end
  end

  for _, port in ipairs(wired) do
    if ports and not ports[port] then return false, "no port named " .. port end
    -- Same trap as a self-referential rule, and worse here: a gate feeding its
    -- own input oscillates every sweep for as long as the computer is on.
    if port == block.out then
      return false, block.out .. " is both an input and the output"
    end
  end

  for _, p in ipairs(spec.params or {}) do
    local v = block.params and block.params[p.key]
    if v ~= nil and p.kind == "number" then
      local n = tonumber(v)
      if not n or n < p.min or n > p.max then
        return false, ("%s must be between %s and %s"):format(p.key, p.min, p.max)
      end
    end
  end

  return true
end

return logic
