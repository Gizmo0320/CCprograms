--- Drives node.lua's real loops against a mock redstone bus.
--
-- lib/rules and lib/logic are tested on their own; this is about the wiring
-- around them -- that a `set` order reaches the wire, that a pulse comes back
-- to where it started, that a rule fires when an input moves, and that outputs
-- survive the chunk unloading.
--
-- The node runs two coroutines under parallel.waitForAny, both pulling every
-- event, so the harness scripts it by queueing the events a modem, a redstone
-- input and a timer would produce and letting the real loops process them. Two
-- of those events are ours:
--
--   rs_test_clock <t>          move os.clock() to t
--   rs_test_input <side> <v>   change what the world is presenting
--
-- They are picked up by a wrapper around net.decode, which is the one function
-- both loops call for every single event. The sweep runs before the listener
-- for any one event, so a clock or input event takes effect on the *next* one --
-- which is why every case that changes the world follows it with a `redstone`.
--
-- Each case ends with a queued `terminate`, which unwinds both coroutines
-- however the node happens to be sitting. Anything else -- draining the queue,
-- waiting for the node to notice -- turns a crash into a hang.

local out = {}
local function say(s)
  out[#out + 1] = tostring(s)
  local f = fs.open("/test-node-results.txt", "w")
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
local rules  = require("lib.rules")
local mock   = dofile("/test/mockredstone.lua")

-- The module cache is deliberately *not* cleared between cases. node.lua is
-- dofile'd fresh each time and resets everything that carries state -- ports
-- through ports.load, state through state.open -- while lib/net is the module
-- this file has replaced the guts of. Reloading it would quietly restore the
-- real transport and every case would sit waiting for a modem.
-- `--script` runs outside the shell, so there is no `shell` global to borrow
-- from. node.lua only reaches for it on the update path, which is stubbed
-- below -- but it has to be reachable for the stub to replace anything.
_G.shell = _G.shell or {}

local realOpen      = net.open
local realSend      = net.send
local realBroadcast = net.broadcast
local realDecode    = net.decode
local realClock     = os.clock
local realRun       = shell.run

local bus, clock = nil, 0
os.clock = function() return clock end

--------------------------------------------------------------------------------

local PILOT = 42        -- the pocket computer asking for things

local function writeFile(path, body)
  local f = fs.open(path, "w")
  f.write(body)
  f.close()
end

local function readFile(path)
  if not fs.exists(path) then return "" end
  local f = fs.open(path, "r")
  local body = f.readAll()
  f.close()
  return body or ""
end

--- A modem_message event carrying a lib/net frame, so the node decodes it the
--- same way it would decode one off a real modem.
local function frame(from, body)
  return { "modem_message", "back", config.channel, config.channel,
           { net = config.protocol, from = from, to = "*", body = body } }
end

--- Empty the event queue, so one case's leftovers are not the next one's script.
local function drain()
  os.queueEvent("rs_drain")
  while true do
    if os.pullEventRaw() == "rs_drain" then return end
  end
end

local function nodePorts()
  return {
    { name = "lamp",   side = "top",   dir = "out", kind = "digital", label = "Ceiling lamp" },
    { name = "button", side = "front", dir = "in",  kind = "digital" },
    { name = "level",  side = "left",  dir = "in",  kind = "analog"  },
    { name = "porch",  side = "back",  dir = "out", kind = "bundled", colour = colours.lime },
    { name = "garage", side = "back",  dir = "out", kind = "bundled", colour = colours.red  },
  }
end

--- Boot a node with the given wiring, rules and saved state, feed it a script
--- of events, and hand back everything it put on the wire.
local function runNode(opts)
  opts = opts or {}
  drain()

  bus = mock.new()
  _G.redstone = bus.api
  for side, value in pairs(opts.input or {}) do bus.input[side] = value end

  fs.delete(config.portsFile)
  fs.delete(config.rulesFile)
  fs.delete(config.stateFile)
  writeFile(config.portsFile, "return " .. textutils.serialize(opts.ports or nodePorts()))
  if opts.rules then
    writeFile(config.rulesFile, "return " .. textutils.serialize(opts.rules))
  end
  if opts.state then
    writeFile(config.stateFile, textutils.serialize(opts.state))
  end

  local sent, casts, ran = {}, {}, {}
  clock = opts.at or 0

  net.open = function()
    if opts.noModem then return nil end
    net.channel = config.channel
    net.id      = os.getComputerID()
    return "back"
  end
  net.send = function(id, msg)
    if opts.noModem then return false end
    sent[#sent + 1] = { to = id, msg = msg }
    return true
  end
  net.broadcast = function(msg)
    if opts.noModem then return false end
    casts[#casts + 1] = msg
    return true
  end
  net.decode = function(event, a, b, c, d)
    if event == "rs_test_clock" then clock = a return nil end
    if event == "rs_test_input" then bus.input[a] = b return nil end
    return realDecode(event, a, b, c, d)
  end

  -- The update path reboots into /update.lua, which would try to download the
  -- whole tree over http. Record the call instead.
  shell.run = function(...) ran[#ran + 1] = { ... } return true end

  for _, event in ipairs(opts.script or {}) do os.queueEvent(unpack(event)) end
  os.queueEvent("terminate")

  local ok, err = pcall(dofile, "/node.lua")

  net.open, net.send, net.broadcast, net.decode =
    realOpen, realSend, realBroadcast, realDecode
  shell.run = realRun

  local crash = nil
  if not ok and not tostring(err):find("Terminated", 1, true) then crash = tostring(err) end
  return { sent = sent, casts = casts, bus = bus, ran = ran, crash = crash }
end

--- Every `event` broadcast about one port, in the order they were sent.
local function eventsFor(casts, port)
  local found = {}
  for _, msg in ipairs(casts) do
    if msg.type == "event" and msg.port == port then found[#found + 1] = msg end
  end
  return found
end

local function lastCast(casts)
  return casts[#casts] or {}
end

local function lastSent(sent)
  return (sent[#sent] or {}).msg or {}
end

--------------------------------------------------------------------------------
section("node: booting")
--------------------------------------------------------------------------------

do
  local r = runNode()
  check(r.crash == nil, "a node boots", r.crash)

  local first = r.casts[1] or {}
  check(first.type == "state" and first.role == "node", "and announces itself at once")
  check(#(first.ports or {}) == 5, "with every port it has", #(first.ports or {}))
  check(first.rules == 0 and first.blocks == 0, "and nothing to run")
  check((first.ports or {})[1].label == "Ceiling lamp",
    "the description carries labels, so the pocket has something to draw")

  r = runNode({ ports = {} })
  check(#r.casts == 0, "a node with no ports defined says so and stops")
  check(r.crash == nil, "rather than crashing", r.crash)

  r = runNode({ state = { outputs = { lamp = true, porch = true }, memo = {}, pulses = {} } })
  check(r.bus.output.top == true, "an output survives the chunk unloading")
  check(r.bus.output.back == colours.lime, "bundled ones included")
  check((r.casts[1].ports or {})[1].value == true,
    "and the first heartbeat is already true, not sent before the restore")

  -- The deadline that would have ended this pulse belonged to a clock that no
  -- longer exists, so the output has to be put back rather than left out.
  r = runNode({ state = { outputs = { lamp = true }, memo = {},
                          pulses = { lamp = { restore = false, until_ = 900, why = "bell" } } } })
  check(r.bus.output.top == false, "anything caught mid-pulse comes back to rest")
end

--------------------------------------------------------------------------------
section("node: orders")
--------------------------------------------------------------------------------

do
  local r = runNode({ script = { frame(PILOT, { type = "set", port = "lamp", value = true }) } })
  check(r.bus.output.top == true, "a set order drives the port")
  local ev = eventsFor(r.casts, "lamp")
  check(#ev == 1 and ev[1].to == true, "and is reported straight away", #ev)
  check(ev[1] and ev[1].why == "manual", "with a cause, because that is what the log is for")

  r = runNode({ script = { frame(PILOT, { type = "set", port = "button", value = true }) } })
  check(lastSent(r.sent).type == "error", "setting an input is refused")
  check(r.sent[1] and r.sent[1].to == PILOT, "to whoever asked")
  check(r.bus.writes.front == nil, "and nothing is written to the wire")

  r = runNode({ script = { frame(PILOT, { type = "set", port = "porch", value = true }) } })
  check(r.bus.output.back == colours.lime, "a bundled port can be set by name")

  r = runNode({ script = { frame(PILOT, { type = "ports?" }) } })
  check(lastSent(r.sent).type == "state", "ports? is answered directly")
  check(#(lastSent(r.sent).ports or {}) == 5, "with the whole description")
end

--------------------------------------------------------------------------------
section("node: pulses")
--------------------------------------------------------------------------------

do
  local r = runNode({ script = {
    frame(PILOT, { type = "pulse", port = "lamp", secs = 1 }),
    { "rs_test_clock", 5 },
    { "redstone" },
  } })
  local ev = eventsFor(r.casts, "lamp")
  check(#ev == 2, "a pulse is two events, not one", #ev)
  check(ev[1] and ev[1].to == true, "on")
  check(ev[2] and ev[2].to == false, "and back off")
  check(ev[2] and tostring(ev[2].why):find("end", 1, true),
    "with the end named, so the log does not look like two orders", ev[2] and ev[2].why)
  check(r.bus.output.top == false, "leaving the wire where it started")

  -- Reading the resting value off the port on the second pulse would decide
  -- that "on" was where it came from, and latch it there permanently.
  r = runNode({ script = {
    frame(PILOT, { type = "pulse", port = "lamp", secs = 1 }),
    { "rs_test_clock", 0.5 },
    frame(PILOT, { type = "pulse", port = "lamp", secs = 1 }),
    { "rs_test_clock", 3 },
    { "redstone" },
  } })
  check(r.bus.output.top == false, "a retriggered pulse still knows where it came from")

  r = runNode({ script = {
    frame(PILOT, { type = "pulse", port = "lamp", secs = 1 }),
    { "rs_test_clock", 0.5 },
    frame(PILOT, { type = "set", port = "lamp", value = true }),
    { "rs_test_clock", 3 },
    { "redstone" },
  } })
  check(r.bus.output.top == true,
    "switching a port by hand cancels the pulse rather than being undone by it")

  r = runNode({ script = { frame(PILOT, { type = "pulse", port = "button", secs = 1 }) } })
  check(lastSent(r.sent).type == "error", "an input cannot be pulsed")

  r = runNode({ script = {
    frame(PILOT, { type = "pulse", port = "lamp", secs = 9999 }),
    { "rs_test_clock", config.maxPulse + 1 },
    { "redstone" },
  } })
  check(r.bus.output.top == false,
    "and a pulse longer than the cap is capped, not left holding a piston out")
end

--------------------------------------------------------------------------------
section("node: rules")
--------------------------------------------------------------------------------

local nightRule = { id = "night", when = { port = "level", op = "<", value = 5 },
                    act = { port = "lamp", set = true } }

do
  local r = runNode({
    input  = { left = 9 },
    rules  = { rules = { nightRule } },
    script = { { "rs_test_input", "left", 2 }, { "redstone" } },
  })
  check(r.casts[1].rules == 1, "a rules file loads", r.casts[1].rules)
  check(r.bus.output.top == true, "and the rule fires when its input moves")
  local ev = eventsFor(r.casts, "lamp")
  check(#ev == 1 and ev[1].why == "night", "the log says which rule did it",
    ev[1] and ev[1].why)
  local moved = eventsFor(r.casts, "level")
  check(#moved == 1 and moved[1].to == 2,
    "and the input that caused it is reported too, because it is the interesting half")

  r = runNode({
    input  = { left = 9 },
    rules  = { rules = { nightRule } },
    script = { { "rs_test_input", "left", 2 }, { "redstone" }, { "redstone" }, { "redstone" } },
  })
  check(#eventsFor(r.casts, "lamp") == 1,
    "a rule fires on the transition, however many sweeps go by")

  r = runNode({ rules = { rules = { { id = "oops", when = { port = "ghost", op = "on" },
                                      act = { port = "lamp", set = true } } } } })
  check(r.casts[1].rules == 0, "a rule naming a port this computer has not got is dropped")
  check(tostring(r.casts[1].warn):find("ghost", 1, true),
    "and the heartbeat carries the reason", r.casts[1].warn)

  local toggle = { rules = {}, blocks = { { id = "hall", kind = "toggle", out = "lamp",
                                            wire = { input = "button" } } } }

  r = runNode({
    rules  = toggle,
    script = { { "redstone" }, { "rs_test_input", "front", true }, { "redstone" } },
  })
  check(r.casts[1].blocks == 1, "a logic block loads")
  check(r.bus.output.top == true, "and a toggle flips on a press")

  -- A block that treated the first sweep it ever ran as an edge would flip
  -- every toggle in the base the moment the chunk loaded.
  r = runNode({
    input  = { front = true },
    rules  = toggle,
    script = { { "redstone" }, { "redstone" } },
  })
  -- Never driven at all rather than driven off: a write that changes nothing is
  -- not made, so the side is untouched.
  check(not r.bus.output.top, "but not on the first sweep it is seen held down",
    tostring(r.bus.output.top))

  r = runNode({
    noModem = true,
    input   = { left = 9 },
    rules   = { rules = { nightRule } },
    script  = { { "rs_test_input", "left", 2 }, { "redstone" } },
  })
  check(r.bus.output.top == true, "a node with no modem still runs its own rules")
  check(#r.casts == 0, "even though nothing in the world can hear it")
end

--------------------------------------------------------------------------------
section("node: editing rules over the wire")
--------------------------------------------------------------------------------

do
  local bell = { id = "bell", when = { port = "button", op = "rising" },
                 act = { port = "lamp", set = true } }

  local r = runNode({ script = {
    frame(PILOT, { type = "rule", action = "add", rule = bell }),
    frame(PILOT, { type = "rules?" }),
  } })
  check(lastSent(r.sent).type == "rules", "rules? answers with the list")
  check(r.sent[1] and r.sent[1].msg.of == "rule", "an added rule is acknowledged")
  check(#(lastSent(r.sent).rules or {}) == 1, "and shows up in it")
  check(readFile(config.rulesFile):find("bell", 1, true),
    "written to disk, so an edit from the pocket survives a reboot")

  r = runNode({ script = { frame(PILOT, { type = "rule", action = "add",
    rule = { id = "bad", when = { port = "button", op = "on" },
             act = { port = "button", set = true } } }) } })
  check(lastSent(r.sent).type == "error", "a rule that drives an input is refused")
  check(tostring(lastSent(r.sent).reason):find("is an input", 1, true),
    "with the reason", lastSent(r.sent).reason)

  r = runNode({
    rules  = { rules = { { id = "on", when = { port = "button", op = "on" },
                           act = { port = "lamp", set = true } } } },
    script = { frame(PILOT, { type = "rule", action = "add",
      rule = { id = "off", when = { port = "button", op = "off" },
               act = { port = "lamp", set = false } } }) },
  })
  check(tostring(lastSent(r.sent).reason):find("conflicts with on", 1, true),
    "two rules disagreeing about one output is refused before it is saved",
    lastSent(r.sent).reason)

  r = runNode({
    rules  = { rules = { { id = "on", when = { port = "button", op = "on" },
                           act = { port = "lamp", set = true } } } },
    script = {
      frame(PILOT, { type = "rule", action = "add",
        rule = { id = "on", when = { port = "button", op = "off" },
                 act = { port = "lamp", set = true } } }),
      frame(PILOT, { type = "rules?" }),
    },
  })
  check(#(lastSent(r.sent).rules or {}) == 1,
    "editing a rule and sending it back replaces it rather than leaving two",
    #(lastSent(r.sent).rules or {}))
  check((lastSent(r.sent).rules or {})[1].when.op == "off", "with the new version")

  r = runNode({
    rules  = { rules = { { id = "on", when = { port = "button", op = "on" },
                           act = { port = "lamp", set = true } } } },
    script = {
      frame(PILOT, { type = "rule", action = "disable", rule = { id = "on" } }),
      frame(PILOT, { type = "rules?" }),
    },
  })
  check((lastSent(r.sent).rules or {})[1].enabled == false, "a rule can be disabled")

  r = runNode({
    rules  = { rules = { { id = "on", when = { port = "button", op = "on" },
                           act = { port = "lamp", set = true } } } },
    script = {
      frame(PILOT, { type = "rule", action = "remove", id = "on" }),
      frame(PILOT, { type = "rules?" }),
    },
  })
  check(#(lastSent(r.sent).rules or {}) == 0, "and removed")

  r = runNode({ script = { frame(PILOT, { type = "rule", action = "disable", id = "ghost" }) } })
  check(tostring(lastSent(r.sent).reason):find("no rule named ghost", 1, true),
    "editing a rule that does not exist says so", lastSent(r.sent).reason)

  r = runNode({ script = { frame(PILOT, { type = "rule", action = "wat", rule = bell }) } })
  check(lastSent(r.sent).type == "error", "and so does an action that is not one")

  -- Whatever the pocket computer sends has to survive being written out and
  -- read back as a rules file, which is the same shape someone writes by hand.
  r = runNode({ script = { frame(PILOT, { type = "rule", action = "add", rule = bell }) } })
  local fn = loadfile(config.rulesFile)
  local data = fn and select(2, pcall(fn))
  check(type(data) == "table" and #(data.rules or {}) == 1,
    "the saved rules file loads back as a rules file")
  check((rules.check((data.rules or {})[1])), "with a rule still sound in it")
end

--------------------------------------------------------------------------------
section("node: housekeeping")
--------------------------------------------------------------------------------

do
  local was = os.getComputerLabel()

  local r = runNode({ script = { frame(PILOT, { type = "rename", name = "Kitchen shed!" }) } })
  check(os.getComputerLabel() == "Kitchenshed",
    "a rename strips anything that is not a name", os.getComputerLabel())
  check(lastCast(r.casts).label == "Kitchenshed",
    "and goes out at once rather than waiting for the next heartbeat")

  r = runNode({ script = { frame(PILOT, { type = "rename", name = "!!!" }) } })
  check(os.getComputerLabel() == "Kitchenshed", "a rename to nothing is ignored")
  os.setComputerLabel(was)

  r = runNode({ script = {
    frame(PILOT, { type = "pulse", port = "lamp", secs = 5 }),
    frame(PILOT, { type = "update" }),
  } })
  check(tostring(lastSent(r.sent).reason):find("busy", 1, true),
    "an update waits for a pulse, because rebooting mid-pulse leaves the output stuck on",
    lastSent(r.sent).reason)
  check(#r.ran == 0, "and nothing is downloaded")

  r = runNode({ script = { frame(PILOT, { type = "update", branch = "dev" }) } })
  check(lastSent(r.sent).of == "update", "an idle node accepts an update")
  check(#r.ran == 1 and r.ran[1][1] == "/update.lua",
    "and runs the updater once both loops have stopped", #r.ran)
  check(r.ran[1] and r.ran[1][2] == "dev", "on the branch it was told", r.ran[1] and r.ran[1][2])

  r = runNode({ script = { frame(PILOT, { type = "nonsense" }) } })
  check(r.crash == nil and #r.sent == 0, "a message it does not understand is ignored", r.crash)
  r = runNode({ script = { frame(PILOT, "not a table") } })
  check(r.crash == nil, "and so is one that is not a message", r.crash)
end

--------------------------------------------------------------------------------

os.clock = realClock
net.open, net.send, net.broadcast, net.decode = realOpen, realSend, realBroadcast, realDecode
fs.delete(config.portsFile)
fs.delete(config.rulesFile)
fs.delete(config.stateFile)

say("")
say(("%d passed, %d failed"):format(pass, fail))
_G.RS_TOTALS = _G.RS_TOTALS or {}
_G.RS_TOTALS["node"] = { pass = pass, fail = fail }
