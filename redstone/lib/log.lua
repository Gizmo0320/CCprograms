--- A bounded log of what changed and why.
--
-- The question being asked when someone opens this is always "what turned that
-- off". A log that records the change but not the cause does not answer it, so
-- `why` is not optional: it is a rule id, a block id, a scene name, or
-- "manual", and every path that changes a port supplies one.
--
-- Bounded at config.logSize. This is the one thing in the project that grows
-- without limit if left alone, and a computer that fills its disk stops being
-- able to write its state file -- which loses the outputs, which turns the
-- lights off. An unbounded log is a lighting failure with extra steps.
--
-- Pure apart from `stamp`. Entries are handed in fully formed so the ring
-- buffer can be tested without a clock.

local config = require("lib.config")

local log = {}

log.entries = {}     -- oldest first

--------------------------------------------------------------------------------

--- The in-game day and time, which is what someone reading this actually wants:
--- "day 42, 19:30" places an event in a Minecraft evening in a way that a unix
--- millisecond does not.
function log.stamp()
  if not os.day then return { day = 0, clock = 0 } end
  return { day = os.day(), clock = os.time() }
end

function log.add(entry)
  if type(entry) ~= "table" then return end

  log.entries[#log.entries + 1] = {
    at   = entry.at or log.stamp(),
    node = entry.node,
    name = entry.name,        -- the node's label, so the log survives a rename
    port = entry.port,
    from = entry.from,
    to   = entry.to,
    why  = entry.why or "?",
  }

  -- Trimmed from the front one at a time rather than in a block. The buffer is
  -- only ever one over, because it is trimmed on every add.
  while #log.entries > config.logSize do
    table.remove(log.entries, 1)
  end

  return log.entries[#log.entries]
end

--- The last n, newest first -- which is the order they are read in.
function log.recent(n)
  local out = {}
  local first = math.max(1, #log.entries - (n or config.logSize) + 1)
  for i = #log.entries, first, -1 do
    out[#out + 1] = log.entries[i]
  end
  return out
end

--- Everything about one port, newest first. "What keeps turning the furnace
--- off" is the question this exists for.
function log.forPort(port, n)
  local out = {}
  for i = #log.entries, 1, -1 do
    if log.entries[i].port == port then
      out[#out + 1] = log.entries[i]
      if n and #out >= n then break end
    end
  end
  return out
end

function log.load(saved)
  log.entries = {}
  for _, entry in ipairs(saved or {}) do log.add(entry) end
  return log.entries
end

function log.clear() log.entries = {} end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

--- Port values are booleans from digital and bundled ports and 0-15 from analog
--- ones. "on"/"off" reads better than "true"/"false" in a column, and a number
--- has to stay a number -- "on" for a comparator reading 7 throws away the only
--- interesting thing about it.
function log.value(v)
  if type(v) == "number" then return tostring(v) end
  if v == nil then return "-" end
  return v and "on" or "off"
end

function log.time(at)
  if not at then return "--:--" end
  if textutils and textutils.formatTime then
    return textutils.formatTime(at.clock or 0, true)
  end
  return tostring(at.clock or 0)
end

--- One line, as narrow as it can be and still answer the question. Fits the
--- pocket computer's 26 columns at the default port name length.
function log.line(entry)
  return ("%s %s %s"):format(
    log.time(entry.at),
    tostring(entry.port),
    log.value(entry.to))
end

return log
