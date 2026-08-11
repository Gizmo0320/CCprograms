--- Drives server.lua's real event loop.
--
-- lib/scenes and lib/log are tested on their own; this is the wiring around
-- them -- that a heartbeat becomes a roster entry, that a scene fans out to the
-- nodes that are answering and logs the ones that are not, and that the log and
-- the scenes are still there after the base has been unloaded and reloaded.
--
-- The server is a single event loop, so the harness queues the events a node, a
-- pocket computer and a keyboard would produce and lets it run. Two of those
-- events are the harness's own, picked up by a wrapper around net.decode:
--
--   rs_test_clock <t>   move os.clock() to t, for staleness
--   rs_test_snap        remember what is on screen
--
-- The snapshot matters because the program clears the terminal on its way out,
-- so anything read afterwards is blank. Every case is drawn into a window
-- rather than the headless terminal, which gives a stable size to lay out
-- against and something to read back.

local out = {}
local function say(s)
  out[#out + 1] = tostring(s)
  local f = fs.open("/test-server-results.txt", "w")
  for _, l in ipairs(out) do f.writeLine(l) end
  f.close()
end

local pass, fail = 0, 0
local function check(ok, label, extra)
  if ok then
    pass = pass + 1
    say("  ok   " .. label)
  else
    fail = fail + 1
    say("  FAIL " .. label .. (extra and ("  <" .. tostring(extra) .. ">") or ""))
  end
end
local function section(name) say("") say(name) end

local loaded = {}
function _G.require(name)
  if loaded[name] then return loaded[name] end
  local path = "/" .. name:gsub("%.", "/") .. ".lua"
  local fn, err = loadfile(path)
  if not fn then error("cannot load " .. path .. ": " .. tostring(err), 0) end
  local m = fn()
  loaded[name] = m
  return m
end

local unpack = table.unpack or unpack

local config = require("lib.config")
local net    = require("lib.net")

local realOpen      = net.open
local realSend      = net.send
local realBroadcast = net.broadcast
local realReceive   = net.receive
local realDecode    = net.decode
local realClock     = os.clock

local clock = 0
os.clock = function() return clock end

local W, H = 51, 19
local PILOT = 42

local function frame(from, body)
  return { "modem_message", "back", config.channel, config.channel,
           { net = config.protocol, from = from, to = "*", body = body } }
end

local function drain()
  os.queueEvent("rs_drain")
  while true do
    if os.pullEventRaw() == "rs_drain" then return end
  end
end

local function readWindow(win)
  local lines = {}
  for y = 1, H do lines[#lines + 1] = (win.getLine(y)) end
  return table.concat(lines, "\n")
end

--- A node's heartbeat, which is the only thing that puts it on the roster.
local function nodeState(label, value)
  return { type = "state", role = "node", label = label, rules = 2, blocks = 1,
           ports = {
             { name = "lamp", label = "Lamp", dir = "out", kind = "digital",
               side = "top", value = value },
             { name = "btn", label = "Button", dir = "in", kind = "digital",
               side = "front", value = false },
           } }
end

local function runServer(opts)
  opts = opts or {}
  drain()

  if not opts.keep then fs.delete(config.networkFile) end
  clock = opts.at or 0

  local sent, casts = {}, {}
  local win  = window.create(term.native(), 1, 1, W, H, false)
  local shot = nil

  net.open = function()
    net.channel = config.channel
    net.id      = os.getComputerID()
    return "back"
  end
  net.send = function(id, msg) sent[#sent + 1] = { to = id, msg = msg } return true end
  net.broadcast = function(msg) casts[#casts + 1] = msg return true end

  -- The startup probe asks whether anyone is already serving this network. It
  -- is answered here rather than left to time out, so a case takes no time and
  -- the probe cannot swallow the scripted conversation.
  net.receive = function()
    if opts.probe then return opts.probe.from, opts.probe.msg end
    return nil
  end

  net.decode = function(event, a, b, c, d)
    if event == "rs_test_clock" then clock = a return nil end
    if event == "rs_test_snap"  then shot = readWindow(win) return nil end
    return realDecode(event, a, b, c, d)
  end

  for _, event in ipairs(opts.script or {}) do os.queueEvent(unpack(event)) end
  os.queueEvent("rs_test_snap")
  os.queueEvent("key", keys.q)
  os.queueEvent("terminate")            -- a backstop, if q did not land

  local prev = term.redirect(win)
  local ok, err = pcall(dofile, "/server.lua")
  term.redirect(prev)

  net.open, net.send, net.broadcast, net.receive, net.decode =
    realOpen, realSend, realBroadcast, realReceive, realDecode

  local crash = nil
  if not ok and not tostring(err):find("Terminated", 1, true) then crash = tostring(err) end
  return { sent = sent, casts = casts, crash = crash,
           screen = shot or readWindow(win) }
end

local function castOf(casts, type_)
  for _, msg in ipairs(casts) do if msg.type == type_ then return msg end end
  return nil
end

local function replyOf(sent, type_)
  for i = #sent, 1, -1 do
    if sent[i].msg.type == type_ then return sent[i].msg, sent[i].to end
  end
  return {}, nil
end

local function countSent(sent, type_)
  local n = 0
  for _, s in ipairs(sent) do if s.msg.type == type_ then n = n + 1 end end
  return n
end

local function lastSent(sent) return (sent[#sent] or {}).msg or {} end

--------------------------------------------------------------------------------
section("server: starting up")
--------------------------------------------------------------------------------

do
  local r = runServer({})
  check(r.crash == nil, "the server starts", r.crash)
  check(r.casts[1] and r.casts[1].type == "server?",
    "asking first whether anyone is already serving this network")
  check(castOf(r.casts, "net") ~= nil, "then announcing the network")
  check(castOf(r.casts, "ports?") ~= nil,
    "and calling the roll rather than waiting for the first heartbeats")
  check(r.screen:find("REDSTONE", 1, true), "the dashboard draws")
  check(r.screen:find("No nodes have reported", 1, true), "and says when there is nothing on it")

  -- Two servers would both fan out scenes and both write the log, and nothing
  -- would look wrong until a scene applied twice.
  r = runServer({ probe = { from = 7, msg = { type = "server!" } } })
  check(#r.casts == 1, "a second server on one network stands down", #r.casts)
  check(r.screen:find("already the server", 1, true), "saying who has it")
  check(not fs.exists(config.networkFile), "and touching nothing on disk")
end

--------------------------------------------------------------------------------
section("server: the roster")
--------------------------------------------------------------------------------

do
  local r = runServer({ script = {
    frame(3, nodeState("Kitchen", true)),
    frame(PILOT, { type = "net?" }),
  } })

  local snap = replyOf(r.sent, "net")
  check(#(snap.nodes or {}) == 1, "a node that reports is on the roster", #(snap.nodes or {}))
  check(snap.nodes[1].label == "Kitchen" and snap.nodes[1].id == 3, "with its name and id")
  check(snap.nodes[1].stale == false, "and marked live")
  check(#(snap.nodes[1].ports or {}) == 2, "carrying its ports, so the pocket can draw them")
  check(r.screen:find("Kitchen", 1, true), "it is on the dashboard too")
  check(r.screen:find("1/1 on", 1, true), "with what it is driving", nil)
  check(r.screen:find("r2 b1", 1, true), "and what it is running")

  r = runServer({ script = {
    frame(3, nodeState("Kitchen", true)),
    { "rs_test_clock", config.staleAfter + 10 },
    frame(PILOT, { type = "net?" }),
  } })
  snap = replyOf(r.sent, "net")
  check(snap.nodes[1].stale == true, "a node that stops reporting goes stale")
  check(r.screen:find("LOST", 1, true), "and says so where you can see it")

  r = runServer({ script = { frame(9, { type = "server?" }) } })
  local reply, to = replyOf(r.sent, "server!")
  check(reply.type == "server!" and to == 9, "another server asking is answered")

  r = runServer({ script = {
    frame(3, { type = "state", label = "Shed", ports = {}, rules = 0, blocks = 0,
               warn = "no port named ghost" }),
  } })
  -- Truncated to the column it is drawn in, which is the point of `fit`.
  check(r.screen:find("no port name", 1, true),
    "a node's warning is shown at base, not just on the node nobody is standing next to")
end

--------------------------------------------------------------------------------
section("server: the log")
--------------------------------------------------------------------------------

do
  local r = runServer({ script = {
    frame(3, nodeState("Kitchen", false)),
    frame(3, { type = "event", port = "lamp", from = false, to = true, why = "night" }),
    frame(PILOT, { type = "log?", n = 5 }),
  } })

  local reply = replyOf(r.sent, "log")
  check(#(reply.entries or {}) == 1, "an event becomes a log entry", #(reply.entries or {}))
  local entry = reply.entries[1]
  check(entry.port == "lamp" and entry.to == true, "with what changed")
  check(entry.why == "night", "and why, which is the question being asked")
  check(entry.name == "Kitchen",
    "stamped with the node's name, so the log survives a rename")

  r = runServer({ script = {
    frame(3, nodeState("Kitchen", false)),
    frame(3, { type = "event", port = "lamp", to = true, why = "night" }),
    { "key", keys.tab },
  } })
  check(r.screen:find("night", 1, true), "the log view shows it")
  check(r.screen:find("lamp", 1, true), "and which port it was about")
end

--------------------------------------------------------------------------------
section("server: scenes")
--------------------------------------------------------------------------------

do
  local r = runServer({ script = {
    frame(3, nodeState("Kitchen", true)),
    frame(4, nodeState("Porch", false)),
    frame(PILOT, { type = "scene!", name = "night", capture = true }),
    frame(PILOT, { type = "scene", name = "night" }),
  } })

  check(replyOf(r.sent, "ack").of == "scene", "applying a scene is acknowledged")
  check(countSent(r.sent, "set") == 2, "and reaches every node in it", countSent(r.sent, "set"))
  local ack = lastSent(r.sent)
  check(ack.sent == 2 and ack.missed == 0, "with a count of who heard it")

  local order = nil
  for _, s in ipairs(r.sent) do
    if s.msg.type == "set" then order = s.msg break end
  end
  check(order.port == "lamp" and order.value == true,
    "each node is told the value that was captured")
  check(order.why == "scene:night",
    "and why, so the log does not fill up with anonymous changes", order.why)

  -- One unloaded chunk must not stop the lights coming on in the rooms that
  -- are loaded, and "nothing happened" is the hardest failure to trace.
  r = runServer({ script = {
    frame(3, nodeState("Kitchen", true)),
    frame(4, nodeState("Porch", false)),
    frame(PILOT, { type = "scene!", name = "night", capture = true }),
    { "rs_test_clock", 100 },
    frame(3, nodeState("Kitchen", true)),
    frame(PILOT, { type = "scene", name = "night" }),
    frame(PILOT, { type = "log?", n = 5 }),
  } })
  local applied = nil
  for _, s in ipairs(r.sent) do
    if s.msg.type == "ack" and s.msg.of == "scene" then applied = s.msg end
  end
  check(applied and applied.sent == 1 and applied.missed == 1,
    "a node that is not answering misses the scene rather than holding it up")
  local logged = replyOf(r.sent, "log")
  check(tostring((logged.entries or {})[1] and logged.entries[1].why):find("MISSED", 1, true),
    "and the miss goes in the log, where it can be found")

  r = runServer({ script = { frame(PILOT, { type = "scene", name = "nope" }) } })
  check(tostring(replyOf(r.sent, "error").reason):find("no scene named", 1, true),
    "a scene that does not exist says so")

  r = runServer({ script = {
    frame(PILOT, { type = "scene!", name = "x",
                   ports = { { node = 3, port = "lamp", value = false } } }),
    frame(PILOT, { type = "net?" }),
  } })
  check(replyOf(r.sent, "ack").of == "scene!", "a scene can be written out rather than captured")
  check(#(replyOf(r.sent, "net").scenes or {}) == 1, "and shows up in the network snapshot")

  r = runServer({ script = { frame(PILOT, { type = "scene!", name = "x", ports = {} }) } })
  check(replyOf(r.sent, "error").type == "error", "an empty scene is refused")

  r = runServer({ script = {
    frame(3, nodeState("Kitchen", true)),
    frame(PILOT, { type = "scene!", name = "night", capture = true }),
    frame(PILOT, { type = "scene-", name = "night" }),
    frame(PILOT, { type = "net?" }),
  } })
  check(#(replyOf(r.sent, "net").scenes or {}) == 0, "and a scene can be removed")

  r = runServer({ script = {
    frame(3, nodeState("Kitchen", true)),
    frame(PILOT, { type = "scene!", name = "night", capture = true }),
    frame(PILOT, { type = "net?" }),
    { "key", keys.tab }, { "key", keys.tab },
  } })
  local snap = replyOf(r.sent, "net")
  check(snap.scenes[1].name == "night" and snap.scenes[1].active == true,
    "the snapshot says which scene the base is currently in")
  check(r.screen:find("ACTIVE", 1, true), "and the scenes view marks it")
end

--------------------------------------------------------------------------------
section("server: relaying and persisting")
--------------------------------------------------------------------------------

do
  local r = runServer({ script = {
    frame(PILOT, { type = "command", target = 3, action = "set",
                   port = "lamp", value = true }),
  } })
  local relay, to = replyOf(r.sent, "set")
  check(relay.port == "lamp" and relay.value == true and to == 3,
    "a command is relayed to the node it names")
  check(relay.why == "manual", "as a manual change")

  r = runServer({ script = {
    frame(PILOT, { type = "command", target = "all", action = "set",
                   port = "lamp", value = false }),
  } })
  check(castOf(r.casts, "set") ~= nil, "and to everyone when it says all")

  r = runServer({ script = {
    frame(3, nodeState("Kitchen", true)),
    frame(PILOT, { type = "scene!", name = "night", capture = true }),
    frame(3, { type = "event", port = "lamp", to = true, why = "night" }),
  } })
  check(fs.exists(config.networkFile), "the network file is written")

  r = runServer({ keep = true, script = {
    frame(PILOT, { type = "net?" }),
    frame(PILOT, { type = "log?", n = 5 }),
  } })
  check(#(replyOf(r.sent, "net").scenes or {}) == 1,
    "scenes survive the base being unloaded and reloaded")
  check(#(replyOf(r.sent, "log").entries or {}) == 1, "and so does the log")

  r = runServer({ script = { frame(PILOT, { type = "nonsense" }) } })
  check(r.crash == nil and #r.sent == 0, "a message it does not understand is ignored", r.crash)
end

--------------------------------------------------------------------------------
section("server: the screen")
--------------------------------------------------------------------------------

do
  local r = runServer({ script = { { "key", keys.tab } } })
  check(r.screen:find("Nothing has changed yet", 1, true), "tab moves to the log")
  r = runServer({ script = { { "key", keys.tab }, { "key", keys.tab } } })
  check(r.screen:find("No scenes defined", 1, true), "again to the scenes")
  r = runServer({ script = { { "key", keys.tab }, { "key", keys.tab }, { "key", keys.tab } } })
  check(r.screen:find("No nodes have reported", 1, true), "and round to the nodes")

  -- Tapping the header, so a wall display is usable without walking back to the
  -- keyboard. mouse_click and monitor_touch both carry (x, y) after the first
  -- argument, and it is the row that decides, not the column.
  r = runServer({ script = { { "mouse_click", 1, 30, 2 } } })
  check(r.screen:find("Nothing has changed yet", 1, true), "tapping the header cycles the view")
  r = runServer({ script = { { "monitor_touch", "right", 30, 2 } } })
  check(r.screen:find("Nothing has changed yet", 1, true), "from the monitor as well")
  r = runServer({ script = { { "mouse_click", 1, 30, 8 } } })
  check(r.screen:find("No nodes have reported", 1, true), "and tapping the body does not")

  -- Headless CraftOS has no monitors to attach. Where it does, this proves the
  -- redirect to the wall display neither crashes nor eats the terminal's copy.
  if pcall(periphemu.create, "right", "monitor") then
    r = runServer({ script = { frame(3, nodeState("Kitchen", true)) } })
    check(r.crash == nil, "an attached monitor is drawn to as well as the terminal", r.crash)
    check(r.screen:find("Kitchen", 1, true), "and the terminal still has the dashboard on it")
    periphemu.remove("right")
  else
    say("  --   no monitor in this emulator; skipped")
  end
end

--------------------------------------------------------------------------------

os.clock = realClock
fs.delete(config.networkFile)

say("")
say(("%d passed, %d failed"):format(pass, fail))
_G.RS_TOTALS = _G.RS_TOTALS or {}
_G.RS_TOTALS["server"] = { pass = pass, fail = fail }
