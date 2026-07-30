--- Crash-resumable state files.
--
-- Written after each completed layer, not each block: a chunk unload or server
-- restart costs at most one layer of re-mining, and the disk does not churn.
--
-- `state` itself is the turtle's job file, kept as module-level functions so
-- miner.lua reads unchanged. `state.file` builds another store over the same
-- atomic write, which is how server.lua persists its fleet.

local config = require("lib.config")

local state = {}

--- Build a store over `path`.
--
-- `validate(data)` returns true, or false plus a reason, and is what stops a
-- file written by a different program -- or a half-finished edit -- from being
-- loaded as though it were the real thing. `blank()` supplies the skeleton
-- `fail` writes into when there is nothing on disk to annotate.
function state.file(path, validate, blank)
  local tmp = path .. ".tmp"
  local store = {}

  --- Serialise to a temp file and swap it in, so a crash mid-write cannot leave
  --- a truncated file behind.
  function store.save(data)
    local file = fs.open(tmp, "w")
    if not file then return false, "cannot open " .. tmp end
    file.write(textutils.serialize(data))
    file.close()

    if fs.exists(path) then fs.delete(path) end
    fs.move(tmp, path)
    return true
  end

  --- Returns the saved table, or nil plus a reason.
  function store.load()
    if not fs.exists(path) then return nil, "no state file" end

    local file = fs.open(path, "r")
    if not file then return nil, "cannot read state file" end
    local text = file.readAll()
    file.close()

    local data = textutils.unserialize(text or "")
    if type(data) ~= "table" then return nil, "state file is corrupt" end
    if validate then
      local ok, why = validate(data)
      if not ok then return nil, why or "state file is incomplete" end
    end
    return data
  end

  function store.clear()
    if fs.exists(path) then fs.delete(path) end
    if fs.exists(tmp) then fs.delete(tmp) end
  end

  --- Record why things stopped, keeping the rest intact so a human can see what
  --- happened without digging through the terminal.
  function store.fail(reason)
    local data = store.load() or (blank and blank()) or {}
    data.failed = reason
    -- os.time() is the in-game clock, 0-24, which is useless for working out
    -- when something broke. os.epoch is a real millisecond timestamp.
    data.failedAt = os.epoch("utc")
    data.failedOn = ("day %d, %s"):format(os.day(), textutils.formatTime(os.time(), true))
    store.save(data)
  end

  return store
end

--------------------------------------------------------------------------------
-- The turtle's job file
--------------------------------------------------------------------------------

local job = state.file(config.stateFile, function(data)
  if type(data.pattern) ~= "string" or type(data.params) ~= "table" then
    return false, "state file is incomplete"
  end
  return true
end, function()
  return { pattern = "none", params = {} }
end)

state.save  = job.save
state.load  = job.load
state.clear = job.clear
state.fail  = job.fail

return state
