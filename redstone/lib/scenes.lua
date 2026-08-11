--- Named sets of port values, applied together. Pure.
--
-- A scene is the reason there is a server at all. Everything else here works
-- node by node and would work with no base computer in the world; "night" sets
-- six ports across four computers, and something has to hold the list and know
-- who to ask.
--
-- Like lib/rules.lua this touches no APIs. It is handed the roster and returns
-- a plan -- who to send what -- and the caller does the sending. Time is passed
-- in, so staleness is testable without sleeping.

local config = require("lib.config")

local scenes = {}

scenes.list = {}     -- [name] = { { node = <id>, port = <name>, value = ... }, ... }

--------------------------------------------------------------------------------

function scenes.load(saved)
  scenes.list = {}
  for name, entries in pairs(saved or {}) do
    if type(name) == "string" and type(entries) == "table" then
      scenes.list[name] = entries
    end
  end
  return scenes.list
end

function scenes.get(name) return scenes.list[name] end

function scenes.names()
  local out = {}
  for name in pairs(scenes.list) do out[#out + 1] = name end
  table.sort(out)
  return out
end

function scenes.remove(name)
  local had = scenes.list[name] ~= nil
  scenes.list[name] = nil
  return had
end

--- Define or replace a scene. Returns ok, reason.
function scenes.set(name, entries)
  if type(name) ~= "string" or name == "" then return false, "no name" end
  if type(entries) ~= "table" or #entries == 0 then return false, "scene is empty" end

  local clean, seen = {}, {}
  for _, e in ipairs(entries) do
    if type(e) == "table" and e.node and type(e.port) == "string" then
      -- One value per port. A scene that listed the same port twice would
      -- apply both and settle on whichever the loop reached last, which is a
      -- silent way to make a scene mean something other than it reads.
      local key = tostring(e.node) .. "/" .. e.port
      if seen[key] then return false, e.port .. " is in this scene twice" end
      seen[key] = true
      clean[#clean + 1] = { node = e.node, port = e.port, value = e.value }
    end
  end

  if #clean == 0 then return false, "nothing usable in it" end
  scenes.list[name] = clean
  return true
end

--------------------------------------------------------------------------------

--- Build a scene from what the roster is currently reporting.
--
-- Capturing beats typing: you set the base up the way you want it by hand, then
-- name that. Only output ports are taken -- an input is a fact about the world
-- and cannot be replayed.
function scenes.capture(name, roster)
  local entries = {}

  for id, node in pairs(roster or {}) do
    for _, p in ipairs(node.ports or {}) do
      if p.dir == "out" then
        entries[#entries + 1] = { node = id, port = p.name, value = p.value }
      end
    end
  end

  -- Stable order, so a captured scene serialises the same way twice and a
  -- diff of /network.state is readable.
  table.sort(entries, function(a, b)
    if a.node ~= b.node then return tostring(a.node) < tostring(b.node) end
    return a.port < b.port
  end)

  return scenes.set(name, entries)
end

--------------------------------------------------------------------------------

--- Who to send what, and who is not going to hear it.
--
-- A node that is offline when a scene fires simply misses it. The alternative
-- -- holding the whole scene until everyone is reachable -- means one unloaded
-- chunk stops the lights coming on in the four rooms that are loaded, and the
-- cause of that is invisible from anywhere you would think to look. So the
-- misses are returned instead, for the log.
function scenes.plan(name, roster, now)
  local scene = scenes.list[name]
  if not scene then return nil, "no scene named " .. tostring(name) end

  local sends, missing = {}, {}

  for _, entry in ipairs(scene) do
    local node = roster and roster[entry.node]
    local stale = not node or (now - (node.seenAt or -math.huge)) > config.staleAfter

    if stale then
      missing[#missing + 1] = { node = entry.node, port = entry.port }
    else
      sends[#sends + 1] = {
        node = entry.node, port = entry.port, value = entry.value,
        why  = "scene:" .. name,
      }
    end
  end

  return { sends = sends, missing = missing }
end

--- Does the roster already look like this scene? Lets the UI show which scene
--- the base is currently in, which is otherwise something you work out by
--- reading six lamps.
function scenes.active(name, roster)
  local scene = scenes.list[name]
  if not scene then return false end

  for _, entry in ipairs(scene) do
    local node = roster and roster[entry.node]
    if not node then return false end

    local found = false
    for _, p in ipairs(node.ports or {}) do
      if p.name == entry.port then
        if p.value ~= entry.value then return false end
        found = true
        break
      end
    end
    if not found then return false end
  end

  return true
end

return scenes
