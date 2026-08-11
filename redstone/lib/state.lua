--- Persistence, with the write debounced.
--
-- Two things a redstone network has to survive: the chunk unloading and the
-- world restarting. Neither gives any warning, so state is written as it
-- changes rather than on the way out.
--
-- Which raises the opposite problem. A pulse rule firing at sweep rate would
-- write the disk four times a second forever, so `mark` only records that
-- something changed and `tick` does the writing at most once every
-- config.stateWrite. Anything that must not be lost calls `flush` and takes the
-- write immediately -- restoring outputs after a reboot is worth one disk hit.
--
-- Time is passed in rather than read from os.clock(), so the debounce is
-- testable without sleeping.

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

  -- Beside the target and moved into place. A chunk unloading halfway through
  -- an fs.write leaves a truncated file, and a state file that parses to nil is
  -- indistinguishable from no state at all -- every output comes back off.
  local tmp = path .. ".part"
  local f = fs.open(tmp, "w")
  if not f then return false, "cannot write " .. tmp end
  f.write(textutils.serialize(data))
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
--- the sweep, which runs whether or not anything happened.
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

--- Throw the file away. Used by `node.lua` when /ports.cfg has changed under
--- it: restoring outputs for ports that no longer exist is worse than starting
--- from off.
function state.clear()
  state.data, state.dirty = {}, false
  if state.path and fs and fs.exists(state.path) then fs.delete(state.path) end
end

return state
