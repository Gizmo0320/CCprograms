--- Persistence, with the write debounced.
--
-- Three things a ship has to survive: the chunk unloading, the world restarting
-- and the computer being broken off and replaced. None gives any warning, so
-- state is written as it changes rather than on the way out.
--
-- Which raises the opposite problem. The fix moves every sweep, and a ship
-- writing its position to disk five times a second would do nothing else. So
-- `mark` only records that something changed and `tick` does the writing at most
-- once every config.stateWrite. Anything that must not be lost calls `flush` and
-- takes the write immediately -- a new flight plan is worth one disk hit,
-- because losing it means a ship that wakes up over open ocean with no idea
-- where it was going.
--
-- Time is passed in rather than read from os.clock(), so the debounce is
-- testable without sleeping.
--
-- Copied from redstone/lib/state.lua, which is the better-shaped of the two
-- persistence layers in this repo.

local config = require("lib.config")

local state = {}

state.path    = nil
state.data    = {}
state.dirty   = false
state.wroteAt = -math.huge
state.writes  = 0        -- for the tests, and for a status line worth having

--------------------------------------------------------------------------------

local function readFile(path)
  if not fs or not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local body = f.readAll()
  f.close()
  if not body or body == "" then return nil end

  local ok, data = pcall(textutils.unserialize, body)
  if not ok or type(data) ~= "table" then return nil end
  return data
end

local function writeFile(path, data)
  if not fs then return false, "no filesystem" end

  -- Serialising can fail, and it must not be fatal. textutils.serialize refuses
  -- any table that appears in the tree twice, so a single shared reference
  -- between two things being saved -- which is easy to write and impossible to
  -- see -- throws. From the control loop. On a ship in the air. Losing one write
  -- is survivable; losing the coroutine holding the ship up is not.
  local ok, body = pcall(textutils.serialize, data)
  if not ok then return false, "cannot serialise: " .. tostring(body) end

  -- Beside the target and moved into place. A chunk unloading halfway through
  -- an fs.write leaves a truncated file, and a state file that parses to nil is
  -- indistinguishable from no state at all -- which is a ship that boots with no
  -- plan and no idea it ever had one.
  local tmp = path .. ".part"
  local f = fs.open(tmp, "w")
  if not f then return false, "cannot write " .. tmp end
  f.write(body)
  f.close()

  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp, path)
  return true
end

--------------------------------------------------------------------------------

--- Load a state file, or start from `default` if there is not one. A corrupt
--- file is treated as absent: it is the same situation from here, and throwing
--- would leave a computer that cannot boot far enough to be fixed.
function state.open(path, default)
  state.path    = path or config.stateFile
  state.data    = readFile(state.path) or (default or {})
  state.dirty   = false
  state.wroteAt = -math.huge
  return state.data
end

function state.get(key) return state.data[key] end

function state.set(key, value)
  if state.data[key] == value then return end
  state.data[key] = value
  state.dirty = true
end

--- Something changed. Call this after mutating a nested table in place, which
--- `set` cannot see.
function state.mark() state.dirty = true end

--- Write if there is anything to write and enough time has passed. Called from
--- the control loop, which runs whether or not anything happened.
function state.tick(now)
  if not state.dirty then return false end
  if (now - state.wroteAt) < config.stateWrite then return false end
  return state.flush(now)
end

--- Write now, regardless.
function state.flush(now)
  if not state.path then return false end
  local ok, err = writeFile(state.path, state.data)
  if not ok then return false, err end

  state.dirty   = false
  state.wroteAt = now or 0
  state.writes  = state.writes + 1
  return true
end

--- Throw the file away. Used by `pilot.lua` when /craft.cfg has changed under
--- it: a plan written for controls that no longer exist is worse than no plan.
function state.clear()
  state.data, state.dirty = {}, false
  if state.path and fs and fs.exists(state.path) then fs.delete(state.path) end
end

return state
