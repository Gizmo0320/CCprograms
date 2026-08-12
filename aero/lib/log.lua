--- A bounded log of what a ship did and why.
--
-- The question being asked when someone opens this is always "why did it do
-- that" -- why did the Kestrel turn round halfway to the quarry, why is it
-- sitting on a hillside forty blocks short. A log that records the change but
-- not the cause does not answer it, so `why` is not optional: it is a guard name
-- ("clearance", "bingo", "nofix"), a waypoint name, "manual", or the state it
-- came from, and every path that changes a ship's mind supplies one.
--
-- Bounded at config.logSize. This is the one thing in the project that grows
-- without limit if left alone, and a computer that fills its disk stops being
-- able to write its state file -- which loses the flight plan.
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
    ship = entry.ship,
    name = entry.name,        -- the ship's label, so the log survives a rename
    what = entry.what,        -- "state", "alt", "leg", "fuel", ...
    from = entry.from,
    to   = entry.to,
    why  = entry.why or "?",
    pos  = entry.pos,         -- where it happened, when that is the point
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

--- Everything one ship did, newest first. With a fleet in the air the log is
--- interleaved, and "what was the Kestrel doing" is unanswerable without this.
function log.forShip(ship, n)
  local out = {}
  for i = #log.entries, 1, -1 do
    if log.entries[i].ship == ship then
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

--- Values here are flight states ("cruise"), altitudes, headings and waypoint
--- names, so unlike the redstone log there is no on/off to prettify -- only
--- numbers to round. A heading printed to six decimal places in a 26-column
--- window pushes the reason for the entry off the end of the line.
function log.value(v)
  if type(v) == "number" then
    if v == math.floor(v) then return tostring(math.floor(v)) end
    return ("%.1f"):format(v)
  end
  if v == nil then return "-" end
  if type(v) == "boolean" then return v and "yes" or "no" end
  return tostring(v)
end

function log.time(at)
  if not at then return "--:--" end
  if textutils and textutils.formatTime then
    return textutils.formatTime(at.clock or 0, true)
  end
  return tostring(at.clock or 0)
end

--- One line, as narrow as it can be and still answer the question. Fits the
--- pocket computer's 26 columns.
--
-- The cause is the point of the entry, so it is what survives when the line is
-- cut: "19:30 cruise>rtb bingo" says everything, and the same line with the
-- reason trimmed off says nothing at all.
function log.line(entry)
  local change
  if entry.from ~= nil then
    change = ("%s>%s"):format(log.value(entry.from), log.value(entry.to))
  else
    change = log.value(entry.to)
  end

  return ("%s %s %s"):format(log.time(entry.at), change, tostring(entry.why))
end

return log
