--- Drives remote.lua's real event loop.
--
-- remote.lua is one program with no seams, so it is tested the way it runs:
-- queue the events a thumb, a node and a server would produce, let it process
-- them, and inspect both what it put on the wire and what it put on the screen.
-- That second half is the point on a pocket computer -- a draw() that throws on
-- some state it can be asked to render is the difference between a UI and a
-- brick, and there is no way to see that from the traffic.
--
-- Every case runs at 26x20 in a window. The headless terminal is 51 wide and
-- every layout here is relative to the screen width, so a click at column 24
-- lands somewhere completely different on a 51-column terminal than on the
-- screen this program is actually for. Redirecting into a window of the right
-- size also gives something to read back, which term.native() does not.
--
-- Two harness events ride the same net.decode wrapper the other suites use:
--
--   rs_test_clock <t>   move os.clock() to t, for the link going quiet
--   rs_test_snap        remember the screen, which the program clears on exit

local out = {}
local function say(s)
  out[#out + 1] = tostring(s)
  local f = fs.open("/test-remote-results.txt", "w")
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

local realOpen      = net.open
local realSend      = net.send
local realBroadcast = net.broadcast
local realDecode    = net.decode
local realClock     = os.clock

local clock = 0
os.clock = function() return clock end

local W, H = 26, 20          -- an advanced pocket computer
local NODE, SERVER, OTHER = 3, 7, 4

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

--- Five ports: two outputs of different kinds and two inputs, because the rule
--- editor refuses to open without one of each and cycling a field is not worth
--- much when there is only one thing to cycle through.
local function nodePorts(lampValue)
  return {
    { name = "lamp", label = "Lamp",   dir = "out", kind = "digital", side = "top",
      value = lampValue },
    { name = "dial", label = "Dial",   dir = "out", kind = "analog",  side = "right",
      value = 0 },
    { name = "btn",  label = "Button", dir = "in",  kind = "digital", side = "front",
      value = false },
    { name = "pir",  label = "Motion", dir = "in",  kind = "digital", side = "back",
      value = false },
  }
end

local function nodeState(label, lampValue)
  return { type = "state", role = "node", label = label, rules = 1, blocks = 0,
           ports = nodePorts(lampValue) }
end

local function netSnapshot(stale, scenes)
  return { type = "net",
           nodes = { { id = NODE, label = "Kitchen", stale = stale or false,
                       rules = 1, blocks = 0, ports = nodePorts(true) } },
           scenes = scenes or { { name = "night", active = false } } }
end

local function runRemote(opts)
  opts = opts or {}
  drain()
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
  net.decode = function(event, a, b, c, d)
    if event == "rs_test_clock" then clock = a return nil end
    if event == "rs_test_snap"  then shot = readWindow(win) return nil end
    return realDecode(event, a, b, c, d)
  end

  for _, event in ipairs(opts.script or {}) do os.queueEvent(unpack(event)) end
  os.queueEvent("rs_test_snap")
  os.queueEvent("key", keys.q)
  os.queueEvent("terminate")            -- a backstop, if q was swallowed

  local prev = term.redirect(win)
  local ok, err = pcall(dofile, "/remote.lua")
  term.redirect(prev)

  net.open, net.send, net.broadcast, net.decode =
    realOpen, realSend, realBroadcast, realDecode

  local crash = nil
  if not ok and not tostring(err):find("Terminated", 1, true) then crash = tostring(err) end
  return { sent = sent, casts = casts, crash = crash,
           screen = shot or readWindow(win) }
end

local function castOf(casts, type_)
  for _, msg in ipairs(casts) do if msg.type == type_ then return msg end end
  return nil
end

local function sentOf(sent, type_)
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

-- Rows start on line 3 and there is one per line, so row n is at y = n + 2.
local function rowY(n) return n + 2 end
local function click(n) return { "mouse_click", 1, 5, rowY(n) } end
local function tab(name)
  local index = ({ panel = 1, scenes = 2, rules = 3, log = 4 })[name]
  return { "mouse_click", 1, (index - 1) * 6 + 1, H }
end

--------------------------------------------------------------------------------
section("remote: the link")
--------------------------------------------------------------------------------

do
  local r = runRemote({})
  check(r.crash == nil, "the remote starts", r.crash)
  check(castOf(r.casts, "net?") ~= nil, "asking base what is going on")
  check(castOf(r.casts, "ports?") ~= nil,
    "and asking the nodes directly too, in case nothing is home")
  check(r.screen:find("REDSTONE", 1, true), "it draws")
  check(r.screen:find("LOST", 1, true), "and says so when nothing at all is answering")
  check(r.screen:find("network '" .. config.protocol, 1, true),
    "naming the network it is looking for, cut to the width it has")

  r = runRemote({ script = { frame(NODE, nodeState("Kitchen", true)) } })
  check(r.screen:find("DIRECT", 1, true),
    "a node answering with no server at base is direct mode")
  check(r.screen:find("Kitchen", 1, true), "and its ports are still yours to switch")
  check(r.screen:find("Lamp", 1, true), "listed by label")

  r = runRemote({ script = { frame(SERVER, netSnapshot()) } })
  check(r.screen:find("SERVER", 1, true), "a server answering takes over")
  check(r.screen:find("Kitchen", 1, true), "and the roster comes from it")

  -- It must never show a stale value as though it were live: the whole job of
  -- this program is telling you what is on right now.
  r = runRemote({ script = {
    frame(NODE, nodeState("Kitchen", true)),
    { "rs_test_clock", config.heartbeatTimeout + 5 },
    { "key", keys.down },
  } })
  check(r.screen:find("LOST", 1, true), "a node that goes quiet says LOST")
  check(not r.screen:find("Lamp", 1, true), "and stops offering its ports")

  r = runRemote({ script = { frame(SERVER, netSnapshot(true)) } })
  check(r.screen:find("LOST", 1, true), "a node the server has lost says so too")
end

--------------------------------------------------------------------------------
section("remote: the panel")
--------------------------------------------------------------------------------

do
  -- rows: 1 head, 2 lamp, 3 dial, 4 btn, 5 pir
  local r = runRemote({ script = {
    frame(NODE, nodeState("Kitchen", true)),
    click(2),
  } })
  local order, to = sentOf(r.sent, "set")
  check(order.port == "lamp" and to == NODE, "tapping a port switches it")
  check(order.value == false, "to the other thing from what it was", tostring(order.value))
  check(order.why == "manual", "as a manual change, so the log says who did it")

  r = runRemote({ script = { frame(NODE, nodeState("Kitchen", false)), click(2) } })
  check(sentOf(r.sent, "set").value == true, "and back the other way")

  r = runRemote({ script = { frame(NODE, nodeState("Kitchen", true)), click(3) } })
  check(sentOf(r.sent, "set").value == 15,
    "an analog port goes to full rather than to true", sentOf(r.sent, "set").value)

  r = runRemote({ script = { frame(NODE, nodeState("Kitchen", true)), click(4) } })
  check(countSent(r.sent, "set") == 0, "an input is not something to tap")
  check(r.screen:find("is an input", 1, true), "and says why")

  r = runRemote({ script = { frame(NODE, nodeState("Kitchen", true)), click(2), click(2) } })
  check(countSent(r.sent, "set") == 2, "the panel does not wait for the round trip")
  local both = {}
  for _, s in ipairs(r.sent) do if s.msg.type == "set" then both[#both + 1] = s.msg.value end end
  check(both[1] == false and both[2] == true,
    "showing the change at once so a slow link does not feel like a broken button")

  r = runRemote({ script = {
    frame(NODE, nodeState("Kitchen", true)),
    frame(OTHER, nodeState("Porch", false)),
  } })
  check(r.screen:find("Kitchen", 1, true) and r.screen:find("Porch", 1, true),
    "two nodes are two headings")

  r = runRemote({ script = {
    frame(NODE, nodeState("Kitchen", true)),
    frame(NODE, { type = "error", reason = "no port named ghost" }),
  } })
  check(r.screen:find("ghost", 1, true), "an error from a node is shown rather than swallowed")
end

--------------------------------------------------------------------------------
section("remote: scenes")
--------------------------------------------------------------------------------

do
  local r = runRemote({ script = { frame(NODE, nodeState("Kitchen", true)), tab("scenes") } })
  check(r.screen:find("Scenes need the server", 1, true),
    "scenes say so when there is no server, because they only ever lived there")
  check(countSent(r.sent, "scene") == 0, "and there is nothing to tap")

  r = runRemote({ script = { frame(SERVER, netSnapshot()), tab("scenes"), click(1) } })
  local scene, to = sentOf(r.sent, "scene")
  check(scene.name == "night" and to == SERVER, "tapping a scene applies it")
  check(r.screen:find("applying", 1, true), "and says so")

  r = runRemote({ script = {
    frame(SERVER, netSnapshot(false, { { name = "night", active = true } })),
    tab("scenes"),
  } })
  check(r.screen:find("ACTIVE", 1, true), "the scene the base is in is marked")

  -- rows: 1 night, 2 "+ capture current as..."
  r = runRemote({ script = {
    frame(SERVER, netSnapshot()),
    tab("scenes"), click(2),
    { "char", "n" }, { "char", "i" }, { "char", "t" }, { "char", "e" },
    { "key", keys.enter },
  } })
  local made, whom = sentOf(r.sent, "scene!")
  check(made.name == "nite" and made.capture == true and whom == SERVER,
    "the current state can be captured under a typed name", made.name)

  r = runRemote({ script = {
    frame(SERVER, netSnapshot()),
    tab("scenes"), click(2),
    { "char", "a" }, { "char", " " }, { "char", "!" }, { "char", "b" },
    { "key", keys.backspace },
    { "key", keys.enter },
  } })
  check(sentOf(r.sent, "scene!").name == "a",
    "typing takes names and nothing else", sentOf(r.sent, "scene!").name)

  r = runRemote({ script = {
    frame(SERVER, netSnapshot()),
    tab("scenes"), click(2), { "char", "x" }, { "key", keys.q },
  } })
  check(countSent(r.sent, "scene!") == 0, "and can be given up on")
end

--------------------------------------------------------------------------------
section("remote: rules")
--------------------------------------------------------------------------------

local ruleList = { type = "rules", problems = {},
  rules = { { id = "night", enabled = true,
              when = { port = "btn", op = "on" },
              act  = { port = "lamp", set = true } } },
  blocks = { { id = "hall", kind = "toggle", out = "dial",
               wire = { input = "pir" } } } }

do
  local r = runRemote({ script = { frame(NODE, nodeState("Kitchen", true)), tab("rules") } })
  check(sentOf(r.sent, "rules?") ~= nil, "the rules screen asks each node for its own")
  check(r.screen:find("asking", 1, true), "and says it is waiting")

  -- rows: 1 head, 2 night, 3 hall, 4 "+ new rule"
  r = runRemote({ script = {
    frame(NODE, nodeState("Kitchen", true)), tab("rules"), frame(NODE, ruleList),
  } })
  check(r.screen:find("night", 1, true), "a node's rules are listed")
  check(r.screen:find("hall", 1, true), "and its logic blocks with them")
  check(r.screen:find("toggle", 1, true), "by kind, since a block has no condition to show")

  r = runRemote({ script = {
    frame(NODE, nodeState("Kitchen", true)), tab("rules"), frame(NODE, ruleList), click(2),
  } })
  local edit, to = sentOf(r.sent, "rule")
  check(edit.action == "disable" and to == NODE, "tapping a rule turns it off")
  check(edit.rule.id == "night", "the one that was tapped", edit.rule and edit.rule.id)

  local off = { type = "rules", problems = {}, blocks = {},
                rules = { { id = "night", enabled = false,
                            when = { port = "btn", op = "on" },
                            act = { port = "lamp", set = true } } } }
  r = runRemote({ script = {
    frame(NODE, nodeState("Kitchen", true)), tab("rules"), frame(NODE, off), click(2),
  } })
  check(sentOf(r.sent, "rule").action == "enable", "and tapping it again turns it back on")

  r = runRemote({ script = {
    frame(NODE, nodeState("Kitchen", true)), tab("rules"),
    frame(NODE, { type = "rules", rules = {}, blocks = {},
                  problems = { "oops: no port ghost" } }),
  } })
  check(r.screen:find("ghost", 1, true),
    "a rule the node refused is shown where you can fix it")
end

--------------------------------------------------------------------------------
section("remote: the rule editor")
--------------------------------------------------------------------------------

do
  local function openEditor(extra)
    local script = {
      frame(NODE, nodeState("Kitchen", true)), tab("rules"), frame(NODE, ruleList),
      click(4),
    }
    for _, e in ipairs(extra or {}) do script[#script + 1] = e end
    return runRemote({ script = script })
  end

  local r = openEditor()
  check(r.screen:find("NEW RULE", 1, true), "the editor opens")
  check(r.screen:find("btn", 1, true), "on the node's first input")
  check(r.screen:find("lamp", 1, true), "and its first output")

  r = openEditor({ { "key", keys.enter } })
  local made = sentOf(r.sent, "rule")
  check(made.action == "add", "enter sends the rule")
  check(made.rule.when.port == "btn" and made.rule.when.op == "on",
    "with the condition on screen")
  check(made.rule.act.port == "lamp" and made.rule.act.set == true, "and the action")
  check((rules.check(made.rule,
    { btn = { dir = "in" }, pir = { dir = "in" },
      lamp = { dir = "out" }, dial = { dir = "out" } })),
    "and what it builds is a rule a node will accept")

  r = openEditor({ { "key", keys.down }, { "key", keys.right }, { "key", keys.enter } })
  check(sentOf(r.sent, "rule").rule.when.port == "pir",
    "the watched port cycles through the node's inputs",
    sentOf(r.sent, "rule").rule.when.port)

  r = openEditor({ { "key", keys.down }, { "key", keys.down },
                   { "key", keys.right }, { "key", keys.enter } })
  check(sentOf(r.sent, "rule").rule.when.op == "off", "so does the operator")

  r = openEditor({ { "key", keys.down }, { "key", keys.down }, { "key", keys.down },
                   { "key", keys.down }, { "key", keys.right }, { "key", keys.enter } })
  check(sentOf(r.sent, "rule").rule.act.port == "dial", "and the port it drives")

  r = openEditor({ { "key", keys.up }, { "key", keys.right }, { "key", keys.enter } })
  check(sentOf(r.sent, "rule").rule.hold == 1,
    "up from the top wraps round to the hold", sentOf(r.sent, "rule").rule.hold)

  r = openEditor({ { "key", keys.right }, { "char", "b" }, { "char", "e" },
                   { "key", keys.enter }, { "key", keys.enter } })
  check(sentOf(r.sent, "rule").rule.id == "be", "an id can be typed")

  r = openEditor({ { "key", keys.q } })
  check(countSent(r.sent, "rule") == 0, "and the whole thing abandoned")
  check(not r.screen:find("NEW RULE", 1, true), "leaving the list behind")
end

--------------------------------------------------------------------------------
section("remote: the log")
--------------------------------------------------------------------------------

do
  local r = runRemote({ script = { frame(NODE, nodeState("Kitchen", true)), tab("log") } })
  check(r.screen:find("The log lives on the", 1, true),
    "the log says where it is when there is no server")

  r = runRemote({ script = { frame(SERVER, netSnapshot()), tab("log") } })
  check(sentOf(r.sent, "log?").n == 30, "with a server, the log is fetched")
  check(r.screen:find("Nothing yet", 1, true), "and says when there is none")

  r = runRemote({ script = {
    frame(SERVER, netSnapshot()), tab("log"),
    frame(SERVER, { type = "log", entries = {
      { at = { day = 1, clock = 19.5 }, port = "lamp", to = true,  why = "night" },
      { at = { day = 1, clock = 19.6 }, port = "dial", to = 7,     why = "manual" },
    } }),
  } })
  check(r.screen:find("lamp", 1, true), "entries name their port")
  check(r.screen:find("night", 1, true), "and their cause, which is the question being asked")
  check(r.screen:find("7", 1, true), "a comparator level stays a number")

  r = runRemote({ script = {
    frame(SERVER, netSnapshot()),
    frame(SERVER, { type = "ack", of = "scene", sent = 3, missed = 1 }),
  } })
  check(r.screen:find("3 sent, 1 missed", 1, true),
    "a scene that half landed says how much of it did")
end

--------------------------------------------------------------------------------
section("remote: getting about")
--------------------------------------------------------------------------------

do
  local r = runRemote({ script = { frame(SERVER, netSnapshot()), tab("scenes") } })
  check(r.screen:find("night", 1, true), "the tabs move between screens")
  r = runRemote({ script = { frame(SERVER, netSnapshot()), tab("scenes"), tab("panel") } })
  check(r.screen:find("Lamp", 1, true), "and back")

  r = runRemote({ script = { frame(SERVER, netSnapshot()), { "key", keys.tab } } })
  check(r.screen:find("night", 1, true), "the tab key moves on one")

  r = runRemote({ script = { frame(SERVER, netSnapshot()), { "mouse_click", 1, 25, H } } })
  check(r.crash == nil, "a tap past the last tab does nothing", r.crash)

  r = runRemote({ script = { frame(SERVER, netSnapshot()), { "mouse_click", 1, 5, 12 } } })
  check(r.crash == nil and countSent(r.sent, "set") == 0, "and so does one on empty space")

  -- Four nodes is more ports than fit on twenty lines, which is what scrolling
  -- is for -- and scrolling off the end of a short list must not leave a blank
  -- screen with no way back.
  local many = { frame(NODE, nodeState("Kitchen", true)) }
  for i = 1, 6 do many[#many + 1] = { "key", keys.down } end
  r = runRemote({ script = many })
  check(r.crash == nil, "scrolling past the end is not a crash", r.crash)
  check(r.screen:find("Kitchen", 1, true) or r.screen:find("Lamp", 1, true),
    "and does not scroll the list off the screen")

  for _, name in ipairs({ "panel", "scenes", "rules", "log" }) do
    r = runRemote({ script = { tab(name) } })
    check(r.crash == nil, "the " .. name .. " screen draws with nothing to show", r.crash)
  end
end

--------------------------------------------------------------------------------

os.clock = realClock

say("")
say(("%d passed, %d failed"):format(pass, fail))
_G.RS_TOTALS = _G.RS_TOTALS or {}
_G.RS_TOTALS["remote"] = { pass = pass, fail = fail }
