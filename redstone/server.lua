--- Redstone network server. Runs on an advanced computer at base.
--
-- Holds the things that are about more than one computer: the node roster, the
-- scenes, and the log. Nothing here is required for a node to work -- a node
-- runs its own rules and answers the pocket computer directly -- which is
-- deliberate. This machine's chunk unloading should cost you the dashboard and
-- the scene buttons, not the lights.
--
-- One event loop rather than parallel: there is no blocking work to do here,
-- only messages to answer and a screen to redraw.

local config = require("lib.config")
local net    = require("lib.net")
local scenes = require("lib.scenes")
local log    = require("lib.log")
local state  = require("lib.state")

local server = {
  running = true,
  roster  = {},          -- [id] = { label, ports, rules, blocks, seenAt, warn }
  view    = "nodes",     -- nodes | log | scenes
  beatAt  = -math.huge,
  scroll  = 0,
}

local function now() return os.clock() end

--------------------------------------------------------------------------------
-- Screen
--------------------------------------------------------------------------------

local monitor = nil
for _, side in ipairs(peripheral.getNames()) do
  if peripheral.getType(side) == "monitor" then
    monitor = peripheral.wrap(side)
    monitor.setTextScale(0.5)
    break
  end
end

local function colour(c)
  if term.isColour() then term.setTextColour(c) end
end

local function at(x, y, text, c)
  colour(c or colours.white)
  term.setCursorPos(x, y)
  term.write(text)
end

--- Truncate to fit. Every layout here is relative to the screen width, because
--- the same draw runs on a 51-column terminal and whatever size monitor happens
--- to be bolted to the wall.
local function fit(text, width)
  text = tostring(text or "")
  if #text <= width then return text end
  return text:sub(1, math.max(0, width - 1)) .. "."
end

local function stale(node)
  return (now() - (node.seenAt or -math.huge)) > config.staleAfter
end

local function sortedRoster()
  local list = {}
  for id, node in pairs(server.roster) do
    list[#list + 1] = { id = id, node = node }
  end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end

local function portSummary(node)
  local on, outs = 0, 0
  for _, p in ipairs(node.ports or {}) do
    if p.dir == "out" then
      outs = outs + 1
      if p.value == true or (type(p.value) == "number" and p.value > 0) then
        on = on + 1
      end
    end
  end
  return on, outs
end

local function drawNodes(W, H)
  local list = sortedRoster()
  if #list == 0 then
    at(2, 4, "No nodes have reported yet.", colours.grey)
    at(2, 5, "Check they are on channel " .. config.channel .. ".", colours.grey)
    return
  end

  for i, row in ipairs(list) do
    local y = 3 + i
    if y > H - 1 then break end

    local node = row.node
    local gone = stale(node)
    local on, outs = portSummary(node)

    at(2, y, fit(node.label or ("node " .. row.id), 14),
      gone and colours.red or colours.white)

    if gone then
      at(18, y, "LOST", colours.red)
    else
      at(18, y, ("%d/%d on"):format(on, outs), on > 0 and colours.lime or colours.grey)
      at(28, y, ("r%d b%d"):format(node.rules or 0, node.blocks or 0), colours.lightGrey)
      if node.warn then at(36, y, fit(node.warn, W - 37), colours.orange) end
    end
  end
end

local function drawLog(W, H)
  local recent = log.recent(H - 4)
  if #recent == 0 then
    at(2, 4, "Nothing has changed yet.", colours.grey)
    return
  end

  for i, entry in ipairs(recent) do
    local y = 3 + i
    if y > H - 1 then break end

    at(2, y, log.time(entry.at), colours.grey)
    at(8, y, fit(entry.port, 14), colours.white)
    at(23, y, log.value(entry.to),
      (entry.to == true or (type(entry.to) == "number" and entry.to > 0))
        and colours.lime or colours.grey)
    at(28, y, fit(entry.why, W - 29),
      entry.why == "manual" and colours.yellow or colours.lightBlue)
  end
end

local function drawScenes(W, H)
  local names = scenes.names()
  if #names == 0 then
    at(2, 4, "No scenes defined.", colours.grey)
    at(2, 5, "Capture one from the pocket computer.", colours.grey)
    return
  end

  for i, name in ipairs(names) do
    local y = 3 + i
    if y > H - 1 then break end

    local live = scenes.active(name, server.roster)
    at(2, y, fit(name, 18), live and colours.lime or colours.white)
    at(22, y, ("%d port(s)"):format(#scenes.get(name)), colours.grey)
    if live then at(34, y, "ACTIVE", colours.lime) end
  end
end

local function draw()
  local W, H = term.getSize()
  term.setBackgroundColour(colours.black)
  term.clear()

  local live = 0
  for _, node in pairs(server.roster) do
    if not stale(node) then live = live + 1 end
  end

  at(1, 1, "REDSTONE", colours.cyan)
  at(11, 1, fit(("'%s' ch %d"):format(config.protocol, config.channel), W - 22),
    colours.grey)
  at(W - 9, 1, ("%d node%s"):format(live, live == 1 and "" or "s"),
    live > 0 and colours.lime or colours.orange)

  at(2, 2, "NODES",  server.view == "nodes"  and colours.yellow or colours.grey)
  at(10, 2, "LOG",   server.view == "log"    and colours.yellow or colours.grey)
  at(15, 2, "SCENES", server.view == "scenes" and colours.yellow or colours.grey)
  at(W - 12, 2, "tab / q", colours.grey)

  if server.view == "nodes" then drawNodes(W, H)
  elseif server.view == "log" then drawLog(W, H)
  else drawScenes(W, H) end

  term.setCursorPos(1, H)
end

--- Draw to the terminal and to any attached monitor. The monitor is the point
--- of a base computer -- a wall you can read from across the room -- and
--- redirecting means one layout rather than two that drift apart.
local function redraw()
  draw()
  if monitor then
    local ok, prev = pcall(term.redirect, monitor)
    if ok then
      pcall(draw)
      term.redirect(prev)
    else
      -- A monitor broken while we were running is not worth halting for.
      monitor = nil
    end
  end
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local function persist()
  state.data.scenes = scenes.list
  state.data.log    = log.entries
  state.mark()
end

--------------------------------------------------------------------------------
-- Messages
--------------------------------------------------------------------------------

local function snapshot()
  local nodes = {}
  for _, row in ipairs(sortedRoster()) do
    local node = row.node
    nodes[#nodes + 1] = {
      id     = row.id,
      label  = node.label,
      stale  = stale(node),
      ports  = node.ports,
      rules  = node.rules,
      blocks = node.blocks,
      warn   = node.warn,
    }
  end

  local list = {}
  for _, name in ipairs(scenes.names()) do
    list[#list + 1] = { name = name, active = scenes.active(name, server.roster) }
  end

  return { type = "net", nodes = nodes, scenes = list }
end

local function heartbeat(force)
  local t = now()
  if not force and (t - server.beatAt) < config.heartbeat then return end
  server.beatAt = t
  net.broadcast(snapshot())
end

local function applyScene(name)
  local plan, why = scenes.plan(name, server.roster, now())
  if not plan then return false, why end

  for _, send in ipairs(plan.sends) do
    net.send(send.node, { type = "set", port = send.port,
                          value = send.value, why = send.why })
  end

  -- A node that missed it goes in the log rather than blocking the rest. One
  -- unloaded chunk must not stop the lights coming on in the rooms that are
  -- loaded, and "nothing happened" is the hardest failure to trace back.
  for _, miss in ipairs(plan.missing) do
    local node = server.roster[miss.node]
    log.add({ node = miss.node, name = node and node.label,
              port = miss.port, why = "scene:" .. name .. " MISSED" })
  end

  return true, #plan.sends, #plan.missing
end

local function handle(from, msg)
  if type(msg) ~= "table" or not msg.type then return end

  if msg.type == "state" then
    local node = server.roster[from] or {}
    node.label  = msg.label
    node.ports  = msg.ports
    node.rules  = msg.rules
    node.blocks = msg.blocks
    node.warn   = msg.warn
    node.seenAt = now()
    server.roster[from] = node

  elseif msg.type == "event" then
    local node = server.roster[from]
    log.add({ node = from, name = node and node.label, port = msg.port,
              from = msg.from, to = msg.to, why = msg.why })
    persist()

  elseif msg.type == "server?" then
    net.send(from, { type = "server!" })

  elseif msg.type == "net?" then
    net.send(from, snapshot())

  elseif msg.type == "log?" then
    net.send(from, { type = "log", entries = log.recent(tonumber(msg.n) or 20) })

  elseif msg.type == "scene" then
    local ok, sent, missed = applyScene(msg.name)
    if ok then
      net.send(from, { type = "ack", of = "scene", sent = sent, missed = missed })
    else
      net.send(from, { type = "error", reason = sent })
    end

  elseif msg.type == "scene!" then
    local ok, why
    if msg.capture then
      ok, why = scenes.capture(msg.name, server.roster)
    else
      ok, why = scenes.set(msg.name, msg.ports)
    end
    if ok then persist() end
    net.send(from, ok and { type = "ack", of = "scene!" }
                      or { type = "error", reason = why })

  elseif msg.type == "scene-" then
    if scenes.remove(msg.name) then persist() end
    net.send(from, { type = "ack", of = "scene-" })

  elseif msg.type == "command" then
    -- Relay. The pocket can reach a node directly and usually does, but a
    -- command sent through here is logged and reaches nodes the pocket is out
    -- of range of, which for anything underground is most of them.
    local body = { type = msg.action or "set", port = msg.port,
                   value = msg.value, secs = msg.secs, why = "manual" }
    if msg.target == "all" then
      net.broadcast(body)
    else
      net.send(msg.target, body)
    end
  end
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

term.clear()
term.setCursorPos(1, 1)
colour(colours.cyan) print("Redstone network server")
colour(colours.grey)
print(("network '%s' on channel %d"):format(config.protocol, config.channel))
colour(colours.white)

if not net.open() then
  colour(colours.red)
  print("No wireless modem. A server with no modem is a blank screen.")
  print("Attach one -- an ender modem for range -- and reboot.")
  colour(colours.white)
  return
end

-- Two servers on one network would both fan out scenes and both write the log,
-- and nothing would look wrong until a scene applied twice and the log showed
-- every change in duplicate.
net.broadcast({ type = "server?" })
local from, reply = net.receive(2)
if from and type(reply) == "table" and reply.type == "server!" then
  colour(colours.orange)
  print("Computer " .. from .. " is already the server for this network.")
  print("Standing down.")
  colour(colours.white)
  return
end

state.open(config.networkFile, { scenes = {}, log = {} })
scenes.load(state.data.scenes)
log.load(state.data.log)

heartbeat(true)
net.broadcast({ type = "ports?" })     -- roll call, rather than waiting 2s
redraw()

local tick = os.startTimer(1)

while server.running do
  local event, a, b, c, d = os.pullEvent()

  local sender, msg = net.decode(event, a, b, c, d)
  if sender then
    handle(sender, msg)
    redraw()
  elseif event == "timer" and a == tick then
    tick = os.startTimer(1)
    heartbeat(false)
    state.tick(now())
    redraw()
  elseif event == "key" then
    if a == keys.q then
      server.running = false
    elseif a == keys.tab then
      server.view = (server.view == "nodes" and "log")
                 or (server.view == "log" and "scenes")
                 or "nodes"
      redraw()
    end
  elseif event == "monitor_touch" or event == "mouse_click" then
    -- Tapping the header cycles the view, so the wall display is usable
    -- without walking back to the keyboard. Both events carry (x, y) after
    -- their first argument, and it is the row that decides, not the column.
    if c and c <= 2 then
      server.view = (server.view == "nodes" and "log")
                 or (server.view == "log" and "scenes")
                 or "nodes"
      redraw()
    end
  end
end

state.flush(now())
term.clear()
term.setCursorPos(1, 1)
colour(colours.white)
print("Server stopped. Nodes carry on with their own rules.")
