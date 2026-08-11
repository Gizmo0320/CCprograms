--- Rule evaluation. Pure.
--
-- This module touches no APIs -- no redstone, no net, no term -- for the same
-- reason mining/lib/fleet.lua does not: so the part that decides things can be
-- tested without an emulated world, and so node.lua is left as loops and
-- wiring. It is handed a table of port readings and the current time, and
-- returns a list of actions. The caller applies them.
--
-- Time is passed in rather than read from os.clock(), so `hold` is testable
-- without sleeping.
--
-- A rule is data, not code. It has to cross the wire, be edited on a pocket
-- computer with sixteen usable columns, and survive a reboot:
--
--   { id      = "night-lights",
--     enabled = true,
--     when    = { port = "daylight", op = "<", value = 4 },
--     act     = { port = "lamps", set = true },
--     hold    = 2 }
--
-- `when` is a leaf condition or a nested { all = {...} } / { any = {...} } /
-- { none = {...} }. The field names avoid `then` and `for`, which are Lua
-- keywords and would need quoting at every use site.

local rules = {}

--------------------------------------------------------------------------------
-- Values
--------------------------------------------------------------------------------

-- Readings arrive as booleans from digital and bundled ports and as 0-15 from
-- analog ones. Comparing them means agreeing on one answer for "is a 4 on", so
-- both shapes are converted at the point of use rather than at the port.
local function truthy(v)
  if type(v) == "number" then return v > 0 end
  return v and true or false
end

local function number(v)
  if type(v) == "boolean" then return v and 15 or 0 end
  return tonumber(v) or 0
end

--------------------------------------------------------------------------------
-- Conditions
--------------------------------------------------------------------------------

-- Edge operators need last sweep's readings. On the very first sweep there are
-- none, and every one of them returns false rather than inventing an edge --
-- otherwise every rule in the file fires once at boot, which with a pulse
-- action means every piston in the base moves when the chunk loads.
local OPS = {
  ["on"]      = function(now) return truthy(now) end,
  ["off"]     = function(now) return not truthy(now) end,
  ["=="]      = function(now, _, v) return number(now) == number(v) end,
  ["~="]      = function(now, _, v) return number(now) ~= number(v) end,
  ["<"]       = function(now, _, v) return number(now) <  number(v) end,
  [">"]       = function(now, _, v) return number(now) >  number(v) end,
  ["<="]      = function(now, _, v) return number(now) <= number(v) end,
  [">="]      = function(now, _, v) return number(now) >= number(v) end,
  ["changed"] = function(now, was) return was ~= nil and now ~= was end,
  ["rising"]  = function(now, was)
    return was ~= nil and truthy(now) and not truthy(was)
  end,
  ["falling"] = function(now, was)
    return was ~= nil and not truthy(now) and truthy(was)
  end,
}

rules.ops = {}
for op in pairs(OPS) do rules.ops[#rules.ops + 1] = op end
table.sort(rules.ops)

--- Is a condition satisfied? `now` and `was` are readings tables; `was` may be
--- nil on the first sweep.
function rules.match(cond, now, was)
  if type(cond) ~= "table" then return false end

  if cond.all then
    for _, c in ipairs(cond.all) do
      if not rules.match(c, now, was) then return false end
    end
    return true
  end

  if cond.any then
    for _, c in ipairs(cond.any) do
      if rules.match(c, now, was) then return true end
    end
    return false
  end

  if cond.none then
    for _, c in ipairs(cond.none) do
      if rules.match(c, now, was) then return false end
    end
    return true
  end

  local fn = OPS[cond.op]
  if not fn or cond.port == nil then return false end
  return fn(now[cond.port], was and was[cond.port], cond.value)
end

--- Every port a condition reads, so the UI can show it and so `check` can spot
--- a rule that drives what it is watching.
function rules.reads(cond, out)
  out = out or {}
  if type(cond) ~= "table" then return out end

  for _, key in ipairs({ "all", "any", "none" }) do
    if cond[key] then
      for _, c in ipairs(cond[key]) do rules.reads(c, out) end
      return out
    end
  end

  if cond.port ~= nil then out[#out + 1] = cond.port end
  return out
end

--------------------------------------------------------------------------------
-- Evaluation
--------------------------------------------------------------------------------

--- Run every enabled rule and return the actions to apply.
--
-- `memo` carries the per-rule bookkeeping between sweeps and is mutated in
-- place: when the condition first became true, and whether we have already
-- acted on it. Pass the same table every time -- node.lua keeps it in its state
-- file, so a debounce that was half elapsed when the chunk unloaded does not
-- start again from zero.
--
-- An action fires on the **transition** into satisfied, not for as long as the
-- condition holds. A rule that re-set its port every sweep would fight anything
-- else touching it -- including you, from the pocket computer -- and you would
-- never be able to turn the light off while the sun was down.
function rules.evaluate(list, now, was, t, memo)
  local actions = {}
  memo = memo or {}

  for _, rule in ipairs(list or {}) do
    if rule.enabled ~= false and rule.id then
      local m = memo[rule.id]
      if not m then m = {}; memo[rule.id] = m end

      if rules.match(rule.when, now, was) then
        -- `hold` is a debounce in seconds: the condition has to stay true that
        -- long before anything happens. Without it a comparator sitting on a
        -- fill level flickers between 6 and 7 and toggles a hopper line as fast
        -- as the sweep will let it -- and the redstone event fires for every
        -- one of those, so the sweep runs flat out too.
        m.since = m.since or t
        if not m.fired and (t - m.since) >= (rule.hold or 0) then
          m.fired = true
          if rule.act then
            local a = {}
            for k, v in pairs(rule.act) do a[k] = v end
            a.why = rule.id
            actions[#actions + 1] = a
          end
        end
      else
        m.since, m.fired = nil, false
      end
    end
  end

  return actions
end

--- Drop bookkeeping for rules that no longer exist, so an edited rules file
--- does not leave a memo table growing forever with dead ids.
function rules.prune(list, memo)
  local live = {}
  for _, rule in ipairs(list or {}) do
    if rule.id then live[rule.id] = true end
  end
  for id in pairs(memo or {}) do
    if not live[id] then memo[id] = nil end
  end
  return memo
end

--------------------------------------------------------------------------------
-- Validation
--------------------------------------------------------------------------------

local function checkCond(cond, ports, seen)
  if type(cond) ~= "table" then return "condition is not a table" end

  for _, key in ipairs({ "all", "any", "none" }) do
    if cond[key] then
      if type(cond[key]) ~= "table" or #cond[key] == 0 then
        return key .. " is empty"
      end
      for _, c in ipairs(cond[key]) do
        local why = checkCond(c, ports, seen)
        if why then return why end
      end
      return nil
    end
  end

  if cond.port == nil then return "condition has no port" end
  if not OPS[cond.op] then return "'" .. tostring(cond.op) .. "' is not an operator" end
  if ports and not ports[cond.port] then
    return "no port named " .. tostring(cond.port)
  end
  return nil
end

--- Is this rule sound? Returns ok, reason.
--
-- `ports` maps name -> { dir = ... } and may be nil, which skips the existence
-- checks -- the server holds rules about ports on other computers and cannot
-- know their wiring.
function rules.check(rule, ports)
  if type(rule) ~= "table" then return false, "not a table" end
  if type(rule.id) ~= "string" or rule.id == "" then return false, "no id" end
  if rule.hold ~= nil and (tonumber(rule.hold) or -1) < 0 then
    return false, "hold must be a positive number of seconds"
  end

  local why = checkCond(rule.when, ports)
  if why then return false, why end

  local act = rule.act
  if type(act) ~= "table" then return false, "no action" end

  if act.scene then
    if type(act.scene) ~= "string" then return false, "scene must be a name" end
  elseif act.port then
    if act.set == nil and act.pulse == nil then
      return false, "action does nothing"
    end
    if act.pulse ~= nil and (tonumber(act.pulse) or 0) <= 0 then
      return false, "pulse must be a length in seconds"
    end
    if ports then
      local p = ports[act.port]
      if not p then return false, "no port named " .. tostring(act.port) end
      if p.dir ~= "out" then return false, act.port .. " is an input" end
    end

    -- A rule that drives what it watches never stops. lib/ports.apply batches a
    -- sweep's actions so this oscillates at sweep rate rather than locking the
    -- computer up, but an output blinking four times a second forever is not a
    -- better outcome than refusing to save it.
    for _, name in ipairs(rules.reads(rule.when)) do
      if name == act.port then
        return false, act.port .. " is both what it watches and what it sets"
      end
    end
  else
    return false, "action has no port or scene"
  end

  return true
end

--- Enabled rules that drive the same port to different values.
--
-- Two rules disagreeing about one output is a wiring mistake, not something to
-- resolve by ordering them: whichever ran last would win, and which that was
-- would depend on the order they happen to sit in the file. Surfaced so the UI
-- can say so before it is saved.
function rules.conflicts(list)
  local byPort, found = {}, {}

  for _, rule in ipairs(list or {}) do
    if rule.enabled ~= false and rule.act and rule.act.port and rule.act.set ~= nil then
      local port = rule.act.port
      byPort[port] = byPort[port] or {}
      local seen = byPort[port]
      for _, other in ipairs(seen) do
        if other.set ~= rule.act.set then
          found[#found + 1] = { port = port, rules = { other.id, rule.id } }
        end
      end
      seen[#seen + 1] = { id = rule.id, set = rule.act.set }
    end
  end

  return found
end

--- Check a whole file at once. Returns the rules that passed, and the problems.
function rules.validate(list, ports)
  local ok, problems, ids = {}, {}, {}

  for i, rule in ipairs(list or {}) do
    local good, why = rules.check(rule, ports)
    if not good then
      problems[#problems + 1] = ("rule %d (%s): %s")
        :format(i, tostring(type(rule) == "table" and rule.id or "?"), why)
    elseif ids[rule.id] then
      problems[#problems + 1] = rule.id .. ": defined twice"
    else
      ids[rule.id] = true
      ok[#ok + 1] = rule
    end
  end

  for _, clash in ipairs(rules.conflicts(ok)) do
    problems[#problems + 1] = ("%s and %s both set %s")
      :format(clash.rules[1], clash.rules[2], clash.port)
  end

  return ok, problems
end

return rules
