--- Runs the libraries against a mock redstone bus, and against nothing at all.
--
-- lib/rules, lib/logic and lib/scenes need no mock: they touch no APIs, which
-- is most of the reason they are shaped that way. lib/ports is the only module
-- that talks to the `redstone` API, so it gets test/mockredstone.lua. lib/net
-- gets a real emulated modem, because the thing worth checking there is that it
-- finds a *wireless* one.
--
-- Results go to /test-results.txt; the terminal in headless mode is unreadable.

local out = {}
local flush
local function print(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  out[#out + 1] = table.concat(parts, " ")
  flush()                            -- so an uncaught error still leaves a trail
end
function flush()
  local f = fs.open("/test-results.txt", "w")
  for _, line in ipairs(out) do f.writeLine(line) end
  f.close()
end

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

local pass, fail = 0, 0

--- `quiet` assertions still count, but only show up when they fail. The
--- fixture's self-checks run before every single case; printing them all buries
--- the results they exist to protect.
local function report(ok, label, extra, quiet)
  if ok then
    pass = pass + 1
    if not quiet then print("  ok   " .. label) end
  else
    fail = fail + 1
    print("  FAIL " .. label .. (extra and ("  <" .. tostring(extra) .. ">") or ""))
  end
end

local function check(ok, label, extra) report(ok, label, extra, false) end
local function checkQuiet(ok, label, extra) report(ok, label, extra, true) end

local function section(name)
  print("")
  print(name)
end

--- Did this fail for the reason we meant it to? Every validator here returns
--- ok, reason, and a check that only looks at `ok` passes just as happily when
--- the entry was rejected for something else entirely.
local function refused(ok, reason, text)
  if ok then return false end
  if not text then return true end
  return tostring(reason):find(text, 1, true) ~= nil
end

local function writeFile(path, body)
  local f = fs.open(path, "w")
  f.write(body)
  f.close()
end

--------------------------------------------------------------------------------
section("manifest")
--------------------------------------------------------------------------------

-- install.lua downloads exactly what manifest.txt lists, so a file added to the
-- tree and not to the list is an installer that silently ships an incomplete
-- program -- which shows up as a require() error on somebody's computer rather
-- than here.
do
  local listed, count = {}, 0
  local f = fs.open("/manifest.txt", "r")
  while true do
    local line = f.readLine()
    if not line then break end
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" and line:sub(1, 1) ~= "#" then
      listed[line] = true
      count = count + 1
    end
  end
  f.close()

  check(count > 0, "manifest.txt lists something", count)

  local missing = nil
  for path in pairs(listed) do
    if not fs.exists("/" .. path) then missing = path end
  end
  check(missing == nil, "every file the installer downloads exists", missing)

  -- install.lua is deliberately absent: it is fetched by `wget run` and is the
  -- thing doing the downloading, not one of the downloads.
  local expected = {}
  for _, name in ipairs(fs.list("/")) do
    if name:sub(-4) == ".lua" and name ~= "install.lua" then expected[name] = true end
  end
  for _, name in ipairs(fs.list("/lib")) do
    if name:sub(-4) == ".lua" then expected["lib/" .. name] = true end
  end

  local unlisted = nil
  for path in pairs(expected) do
    if not listed[path] then unlisted = path end
  end
  check(unlisted == nil, "and every file in the tree is downloaded", unlisted)

  local stale = nil
  for path in pairs(listed) do
    if not expected[path] then stale = path end
  end
  check(stale == nil, "with nothing listed that is not there", stale)
end

--------------------------------------------------------------------------------
section("lib/net")
--------------------------------------------------------------------------------

do
  periphemu.create("back", "modem")

  -- CraftOS-PC's emulated modem reports isWireless() == false and net.open
  -- accepts wireless only -- a wired modem cannot reach the pocket computer in
  -- your hand, which is the entire point of the roster. Present it as wireless
  -- rather than loosening the program to suit the emulator.
  local realCall = peripheral.call
  peripheral.call = function(side, method, ...)
    if method == "isWireless" and peripheral.getType(side) == "modem" then return true end
    return realCall(side, method, ...)
  end

  local config = require("lib.config")
  local net    = require("lib.net")

  check(net.open() == "back", "net.open finds the wireless modem")
  check(net.isOpen(), "and opens the network's channel")
  check(net.channel == config.channel, "which is the configured one", net.channel)
  check(config.channel ~= 3141, "and is not the mining fleet's", config.channel)

  local function frame(fields)
    local f = { net = config.protocol, from = 99, to = "*", body = { type = "ping" } }
    for k, v in pairs(fields or {}) do f[k] = v end
    return f
  end
  local function decode(f, channel)
    return net.decode("modem_message", "back", channel or config.channel,
      config.channel, f)
  end

  local from, body = decode(frame())
  check(from == 99 and type(body) == "table" and body.type == "ping",
    "a broadcast on our channel is ours")

  from = decode(frame(), config.channel + 1)
  check(from == nil, "another channel is not")

  check(decode(frame({ net = "somebody-else" })) == nil,
    "nor is another network that happens to share the number")

  check(decode(frame({ from = net.id })) == nil,
    "our own broadcast does not come back to us")

  check(decode(frame({ to = net.id + 1 })) == nil,
    "a message addressed to someone else is not ours")

  check(decode(frame({ to = net.id })) == 99, "one addressed to us is")

  check(net.decode("redstone") == nil, "a non-modem event decodes to nothing")
  check(decode(frame({ body = "not a table" })) == nil, "and neither does a frame with no body")
  check(decode("not a frame at all") == nil, "or one that is not a frame")

  net.close()
  check(not net.isOpen(), "net.close closes the channel")

  peripheral.call = realCall
  periphemu.remove("back")
end

--------------------------------------------------------------------------------
section("lib/ports")
--------------------------------------------------------------------------------

local mock = dofile("/test/mockredstone.lua")

local bus, ports

--- Eight ports covering all three signal shapes, both directions, and two
--- colours sharing one bundled cable -- which is the case that everything
--- interesting about this module hangs off.
local function defaultPorts()
  return {
    { name = "lamp",   side = "top",    dir = "out", kind = "digital", label = "Ceiling lamp" },
    { name = "level",  side = "left",   dir = "in",  kind = "analog"  },
    { name = "button", side = "front",  dir = "in",  kind = "digital" },
    { name = "dial",   side = "right",  dir = "out", kind = "analog"  },
    { name = "porch",  side = "back",   dir = "out", kind = "bundled", colour = colours.lime },
    { name = "garage", side = "back",   dir = "out", kind = "bundled", colour = colours.red  },
    { name = "gate",   side = "bottom", dir = "in",  kind = "bundled", colour = colours.blue },
    { name = "shed",   side = "bottom", dir = "in",  kind = "bundled", colour = colours.green },
  }
end

--- A fresh bus and a completely fresh module, because lib/ports keeps the whole
--- wiring in module-level tables and a case that inherited the last one's ports
--- would pass or fail for reasons nothing to do with itself.
local function fixture(list)
  bus = mock.new()
  _G.redstone = bus.api
  loaded = {}
  ports = require("lib.ports")

  local ok, problems = ports.define(list or defaultPorts())

  -- Prove the wiring before trusting a single assertion made through it.
  if list == nil then
    checkQuiet(ok and ports.count() == 8, "[fixture] the default ports install",
      problems and problems[1])
    checkQuiet(select(1, ports.set("lamp", true)), "[fixture] an output can be driven")
    checkQuiet(bus.output.top == true, "[fixture] and reaches the mock bus", bus.output.top)
    ports.set("lamp", false)
    bus.clear()
  end

  return ok, problems
end

do
  fixture()

  check(ports.get("lamp").label == "Ceiling lamp", "a port keeps its label")
  check(ports.get("button").label == "button", "and falls back to its name")
  check(#ports.bySide.back == 2, "two colours share one side")
  check(ports.names()[1] == "lamp", "names come back in file order")
  check(ports.get("nope") == nil, "an undefined port is nil")
end

do
  section("lib/ports: reading")
  fixture()

  bus.input.left   = 7
  bus.input.front  = true
  bus.input.bottom = colours.blue + colours.yellow

  local v = ports.poll()
  check(v.level == 7, "an analog input reads its level", v.level)
  check(v.button == true, "a digital input reads on or off")
  check(v.gate == true, "a bundled input reads its own colour out of the mask")
  check(v.shed == false, "and is not fooled by the others being set")
  check(v.lamp == false, "an output reports what we are driving")
  check(v.dial == 0, "including an analog one")

  check(bus.totalReads() == 3, "one API call per side, not per port", bus.totalReads())
  check(bus.reads.bottom == 1, "so one cable is read once for both its colours",
    bus.reads.bottom)
  check(bus.reads.top == nil, "and an output side is never read")

  -- Inverted, which lives on the port rather than in every rule that reads it.
  fixture({
    { name = "sensor", side = "left",  dir = "in",  kind = "digital", invert = true },
    { name = "dark",   side = "front", dir = "in",  kind = "analog",  invert = true },
  })
  bus.input.left, bus.input.front = true, 4
  local inv = ports.poll()
  check(inv.sensor == false, "an inverted digital input reads the other way round")
  check(inv.dark == 11, "and an inverted analog one is subtracted from 15", inv.dark)
end

do
  section("lib/ports: writing")
  fixture()

  local ok, prev = ports.set("lamp", true)
  check(ok and prev == false, "set returns the value it replaced", tostring(prev))
  check(bus.output.top == true, "and drives the side")

  local no, whyNot = ports.set("button", true)
  check(refused(no, whyNot, "is an input"), "an input cannot be driven", whyNot)
  no, whyNot = ports.set("nope", true)
  check(refused(no, whyNot, "no port named"),
    "and neither can a port that does not exist", whyNot)

  ports.set("dial", 99)
  check(ports.outputs.dial == 15 and bus.output.right == 15, "an analog value is clamped")
  ports.set("dial", true)
  check(ports.outputs.dial == 15, "a boolean on an analog port is full strength")
  ports.set("dial", false)
  check(ports.outputs.dial == 0, "and off is nothing")
  ports.set("lamp", 5)
  check(ports.outputs.lamp == true, "a number on a digital port is on or off")

  -- The case the whole `emit` design exists for: a bundled side is one number
  -- shared by up to sixteen ports, and writing a colour without knowing the
  -- other fifteen turns them all off.
  ports.set("porch", true)
  check(bus.output.back == colours.lime, "a bundled port sets its colour", bus.output.back)
  ports.set("garage", true)
  check(bus.output.back == colours.lime + colours.red,
    "and setting a second keeps the first", bus.output.back)
  ports.set("porch", false)
  check(bus.output.back == colours.red, "clearing one keeps the other", bus.output.back)

  fixture({
    { name = "closed", side = "top", dir = "out", kind = "digital", invert = true },
    { name = "meter",  side = "left", dir = "out", kind = "analog", invert = true },
  })
  ports.set("closed", true)
  check(bus.output.top == false, "an inverted output is inverted on the wire")
  check(ports.values.closed == true, "but reads as what was asked for")
  ports.set("meter", 4)
  check(bus.output.left == 11, "an inverted analog output too", bus.output.left)
end

do
  section("lib/ports: batches")
  fixture()
  bus.clear()

  local applied = ports.apply({
    { port = "porch",  value = true,  why = "night" },
    { port = "garage", value = true,  why = "night" },
    { port = "lamp",   value = false, why = "night" },   -- already off
    { port = "button", value = true,  why = "night" },   -- an input
    { port = "ghost",  value = true,  why = "night" },   -- not a port
  })

  check(#applied == 2, "only the changes come back", #applied)
  check(applied[1].port == "porch" and applied[1].from == false
    and applied[1].to == true and applied[1].why == "night",
    "each carrying what it was, what it is, and why")
  check(bus.writes.back == 1, "one cable, one write, however many colours moved",
    bus.writes.back)
  check(bus.writes.top == nil, "a write that would change nothing is not made")
  check(bus.output.back == colours.lime + colours.red, "and the cable carries both")

  local before = ports.snapshot()
  ports.set("dial", 4)
  ports.set("lamp", true)
  local after = ports.snapshot()
  local d = ports.diff(before, after)
  check(#d == 2, "diff finds both changes", #d)
  check(d[1].port == "lamp" and d[2].port == "dial",
    "in port order, not hash order", d[1].port)
  check(d[1].from == false and d[1].to == true, "with both values")
  check(#ports.diff(after, after) == 0, "and nothing when nothing moved")
end

do
  section("lib/ports: restore")
  fixture()

  local n = ports.restore({ lamp = true, porch = true, button = true, ghost = 1 })
  check(n == 2, "restore takes the outputs and leaves the rest", n)
  check(bus.output.top == true, "putting them back on the wire")
  check(bus.output.back == colours.lime, "bundled ones included")
  check(ports.values.lamp == true, "and reporting them as current")

  local saved = ports.saved()
  check(saved.lamp == true and saved.porch == true, "saved() round-trips the outputs")
  check(saved.button == nil, "and holds no inputs, which the world owns")

  check(ports.restore("nonsense") == 0, "a corrupt saved table restores nothing")

  local described = ports.describe()
  check(#described == 8, "describe covers every port", #described)
  check(described[1].name == "lamp" and described[1].dir == "out"
    and described[1].kind == "digital" and described[1].value == true,
    "with what the pocket computer needs to draw it")
  check(described[5].colour == colours.lime, "and the colour of a bundled one")
end

do
  section("lib/ports: bad wiring")
  local function whyNot(list)
    local _, problems = fixture(list)
    return problems[1] or ""
  end
  local function one(side, extra)
    local p = { name = "a", side = side or "top", dir = "out", kind = "digital" }
    for k, v in pairs(extra or {}) do p[k] = v end
    return p
  end

  check(whyNot({ 5 }):find("is not a table", 1, true), "an entry that is not a table")
  check(whyNot({ one(nil, { name = "" }) }):find("has no name", 1, true), "an entry with no name")
  check(whyNot({ one("top"), one("left") }):find("defined twice", 1, true),
    "the same name twice")
  check(whyNot({ one("middle") }):find("is not a side", 1, true), "a side that is not one")
  check(whyNot({ one(nil, { dir = "sideways" }) }):find("dir must be", 1, true),
    "a direction that is neither")
  check(whyNot({ one(nil, { kind = "fancy" }) }):find("is not a kind", 1, true),
    "a kind that does not exist")
  check(whyNot({ one(nil, { kind = "bundled" }) }):find("needs a colour", 1, true),
    "bundled with no colour")
  check(whyNot({ one(nil, { kind = "bundled", colour = 3 }) }):find("needs a colour", 1, true),
    "and bundled with a number that is not one")

  -- A side carries one signal, so everything on it has to agree what it is.
  check(whyNot({ one("top"), { name = "b", side = "top", dir = "in", kind = "digital" } })
    :find("already an output", 1, true), "an input and an output on one side")
  check(whyNot({ one("top"), { name = "b", side = "top", dir = "out", kind = "bundled",
    colour = colours.lime } }):find("already digital", 1, true), "two kinds on one side")
  check(whyNot({ one("top"), { name = "b", side = "top", dir = "out", kind = "digital" } })
    :find("already used by a", 1, true), "two digital ports on one side")
  check(whyNot({
    { name = "a", side = "back", dir = "out", kind = "bundled", colour = colours.lime },
    { name = "b", side = "back", dir = "out", kind = "bundled", colour = colours.lime },
  }):find("colour already used by", 1, true), "and one colour twice on a cable")

  local ok, problems = fixture({
    { name = "good",  side = "top",  dir = "out", kind = "digital" },
    { name = "bad",   side = "nope", dir = "out", kind = "digital" },
    { name = "other", side = "left", dir = "in",  kind = "digital" },
  })
  check(not ok and #problems == 1, "a typo is one problem", #problems)
  check(ports.count() == 2, "costing you one port and not the file", ports.count())
end

do
  section("lib/ports: loading")
  local path = "/test-ports.cfg"
  fixture({})

  writeFile(path, "return { { name = 'lamp', side = 'top', dir = 'out', kind = 'digital' } }")
  local ok = ports.load(path)
  check(ok and ports.count() == 1, "a ports file loads")

  writeFile(path, "return {{{{")
  local bad, problems = ports.load(path)
  check(not bad and ports.count() == 0, "a file that will not parse is a warning")
  check(problems[1]:find(path, 1, true), "naming the file", problems[1])

  writeFile(path, "error('boom')")
  bad, problems = ports.load(path)
  check(not bad and problems[1]:find("boom", 1, true), "so is one that throws", problems[1])

  writeFile(path, "return 'not a list'")
  bad, problems = ports.load(path)
  check(not bad and problems[1]:find("did not return a table", 1, true),
    "and one that returns the wrong thing", problems[1])

  fs.delete(path)
  bad, problems = ports.load(path)
  check(not bad and problems[1]:find("no " .. path, 1, true),
    "a missing file says which one", problems[1])
end

--------------------------------------------------------------------------------
section("lib/rules: conditions")
--------------------------------------------------------------------------------

local rules = require("lib.rules")

do
  local now = { sw = true, dark = 4, lit = 0 }
  local was = { sw = false, dark = 9, lit = 0 }
  local function m(cond) return rules.match(cond, now, was) end

  check(m({ port = "sw",   op = "on"  }), "on")
  check(m({ port = "lit",  op = "off" }), "off")
  check(m({ port = "dark", op = "==", value = 4 }), "==")
  check(m({ port = "dark", op = "~=", value = 9 }), "~=")
  check(m({ port = "dark", op = "<",  value = 5 }), "<")
  check(not m({ port = "dark", op = ">", value = 5 }), ">")
  check(m({ port = "dark", op = "<=", value = 4 }), "<=")
  check(m({ port = "dark", op = ">=", value = 4 }), ">=")
  check(m({ port = "sw",   op = "rising"  }), "rising")
  check(not m({ port = "sw", op = "falling" }), "not falling when it rose")
  check(rules.match({ port = "sw", op = "falling" }, was, now), "falling")
  check(m({ port = "dark", op = "changed" }), "changed")
  check(not m({ port = "lit", op = "changed" }), "not changed when it did not")

  -- The mixed-shape cases. Readings are booleans from digital and bundled ports
  -- and 0-15 from analog ones, and everything has to agree on one answer for
  -- "is a 4 on".
  check(m({ port = "dark", op = "on" }), "an analog 4 counts as on")
  check(m({ port = "sw", op = "==", value = 15 }), "and a boolean compares as 0 or 15")
  check(rules.match({ port = "lit", op = "off" }, now), "an analog 0 counts as off")

  -- Edges need last sweep's readings, and inventing one would fire every rule
  -- in the file the moment the chunk loads.
  check(not rules.match({ port = "sw", op = "rising"  }, now), "no rising edge on the first sweep")
  check(not rules.match({ port = "sw", op = "falling" }, now), "no falling edge either")
  check(not rules.match({ port = "dark", op = "changed" }, now), "and nothing has changed yet")

  check(not m({ port = "nope", op = "on" }), "an unknown port is not on")
  check(not m({ port = "sw", op = "wat" }), "an unknown operator never matches")
  check(not m({ op = "on" }), "a condition with no port never matches")
  check(not rules.match("nonsense", now, was), "and neither does something that is not one")

  check(m({ all = { { port = "sw", op = "on" }, { port = "dark", op = "<", value = 5 } } }), "all")
  check(not m({ all = { { port = "sw", op = "on" }, { port = "lit", op = "on" } } }),
    "all, with one false")
  check(m({ any = { { port = "lit", op = "on" }, { port = "sw", op = "on" } } }), "any")
  check(not m({ any = { { port = "lit", op = "on" } } }), "any, with none true")
  check(m({ none = { { port = "lit", op = "on" } } }), "none")
  check(not m({ none = { { port = "sw", op = "on" } } }), "none, with one true")
  check(m({ all = { { port = "sw", op = "on" },
    { any = { { port = "lit", op = "on" }, { port = "dark", op = "<", value = 5 } } } } }),
    "and they nest")

  local read = rules.reads({ all = { { port = "a", op = "on" },
    { any = { { port = "b", op = "on" }, { port = "c", op = "on" } } } } })
  check(#read == 3, "reads() finds every port a condition looks at", #read)
  check(#rules.reads({ port = "a", op = "on" }) == 1, "including a bare one")
  check(#rules.reads("nonsense") == 0, "and none in something that is not a condition")

  check(#rules.ops >= 11, "the operator list is published for the UI", #rules.ops)
end

--------------------------------------------------------------------------------
section("lib/rules: evaluation")
--------------------------------------------------------------------------------

do
  local list = { { id = "lights",
                   when = { port = "dark", op = "<", value = 5 },
                   act  = { port = "lamp", set = true } } }
  local memo = {}

  local a = rules.evaluate(list, { dark = 4 }, { dark = 9 }, 0, memo)
  check(#a == 1 and a[1].port == "lamp" and a[1].set == true, "a rule fires when it matches")
  check(a[1].why == "lights", "and says which rule it was", a[1].why)
  check(list[1].act.why == nil, "without scribbling on the rule it came from")

  check(#rules.evaluate(list, { dark = 4 }, { dark = 4 }, 0.25, memo) == 0,
    "it fires on the transition, not for as long as the condition holds")
  check(#rules.evaluate(list, { dark = 9 }, { dark = 4 }, 0.5, memo) == 0,
    "nothing when it stops matching")
  check(#rules.evaluate(list, { dark = 4 }, { dark = 9 }, 0.75, memo) == 1,
    "and again once it has gone away and come back")

  check(#rules.evaluate({ { id = "off", enabled = false,
    when = { port = "a", op = "on" }, act = { port = "b", set = true } } },
    { a = true }, nil, 0, {}) == 0, "a disabled rule does nothing")
  check(#rules.evaluate({ { when = { port = "a", op = "on" },
    act = { port = "b", set = true } } }, { a = true }, nil, 0, {}) == 0,
    "and neither does one with no id")
  check(#rules.evaluate(nil, {}, nil, 0, {}) == 0, "no rules is not an error")

  -- Debounce. Without it a comparator flickering between 6 and 7 toggles a
  -- hopper line as fast as the sweep will let it.
  local held = { { id = "settle", when = { port = "lvl", op = ">", value = 8 },
                   act = { port = "hopper", set = false }, hold = 2 } }
  local m2 = {}
  check(#rules.evaluate(held, { lvl = 9 }, { lvl = 0 }, 10, m2) == 0, "a hold waits")
  check(#rules.evaluate(held, { lvl = 9 }, { lvl = 9 }, 11.5, m2) == 0, "still waiting")
  check(#rules.evaluate(held, { lvl = 9 }, { lvl = 9 }, 12, m2) == 1, "and then fires")
  check(#rules.evaluate(held, { lvl = 9 }, { lvl = 9 }, 13, m2) == 0, "once")

  local m3 = {}
  rules.evaluate(held, { lvl = 9 }, { lvl = 0 }, 0, m3)
  rules.evaluate(held, { lvl = 1 }, { lvl = 9 }, 1, m3)
  check(#rules.evaluate(held, { lvl = 9 }, { lvl = 1 }, 1.5, m3) == 0,
    "a hold interrupted starts again from the beginning")
  check(#rules.evaluate(held, { lvl = 9 }, { lvl = 9 }, 3.6, m3) == 1, "and elapses from there")

  -- The memo is what node.lua keeps in its state file, so a debounce that was
  -- half elapsed when the chunk unloaded does not start again from zero.
  check(m3.settle ~= nil and m3.settle.fired == true, "the memo carries between sweeps")
  local pruned = rules.prune({ { id = "settle" } }, { settle = {}, gone = {} })
  check(pruned.settle ~= nil and pruned.gone == nil, "and prune drops ids that no longer exist")
end

--------------------------------------------------------------------------------
section("lib/rules: validation")
--------------------------------------------------------------------------------

do
  local shapes = { button = { dir = "in" }, level = { dir = "in" }, lamp = { dir = "out" } }
  local function why(rule) return select(2, rules.check(rule, shapes)) end
  local function ok(rule) return (rules.check(rule, shapes)) end

  check(ok({ id = "a", when = { port = "button", op = "on" },
    act = { port = "lamp", set = true } }), "a sound rule passes")
  check(ok({ id = "a", when = { port = "button", op = "on" },
    act = { port = "lamp", pulse = 2 } }), "so does a pulse")
  check(ok({ id = "a", when = { port = "button", op = "on" },
    act = { scene = "night" } }), "and a scene action")

  check(tostring(why({ when = { port = "button", op = "on" },
    act = { port = "lamp", set = true } })):find("no id", 1, true), "a rule needs an id")
  check(tostring(why("nonsense")):find("not a table", 1, true), "and has to be a table")
  check(tostring(why({ id = "a", when = { port = "button", op = "on" },
    act = { port = "lamp", set = true }, hold = -1 })):find("hold must be", 1, true),
    "a hold cannot be negative")
  check(tostring(why({ id = "a", when = { port = "button", op = "nope" },
    act = { port = "lamp", set = true } })):find("is not an operator", 1, true),
    "the operator has to exist")
  check(tostring(why({ id = "a", when = { port = "ghost", op = "on" },
    act = { port = "lamp", set = true } })):find("no port named ghost", 1, true),
    "so does the port it watches")
  check(tostring(why({ id = "a", when = { all = {} },
    act = { port = "lamp", set = true } })):find("all is empty", 1, true),
    "an empty group means nothing")
  check(tostring(why({ id = "a", when = { port = "button", op = "on" } }))
    :find("no action", 1, true), "a rule with no action")
  check(tostring(why({ id = "a", when = { port = "button", op = "on" },
    act = { port = "lamp" } })):find("does nothing", 1, true), "an action that does nothing")
  check(tostring(why({ id = "a", when = { port = "button", op = "on" },
    act = { port = "lamp", pulse = 0 } })):find("pulse must be", 1, true),
    "a pulse of no length")
  check(tostring(why({ id = "a", when = { port = "button", op = "on" },
    act = { port = "ghost", set = true } })):find("no port named ghost", 1, true),
    "an action on a port that does not exist")
  check(tostring(why({ id = "a", when = { port = "button", op = "on" },
    act = { port = "button", set = true } })):find("is an input", 1, true),
    "an action on an input")
  check(tostring(why({ id = "a", when = { port = "lamp", op = "on" },
    act = { port = "lamp", set = true } }))
    :find("both what it watches and what it sets", 1, true),
    "and a rule that drives what it is watching")

  -- The server holds rules about ports on computers it cannot see the wiring of.
  check((rules.check({ id = "a", when = { port = "anything", op = "on" },
    act = { port = "elsewhere", set = true } })),
    "with no ports to check against, only the shape is checked")

  local clashes = rules.conflicts({
    { id = "on",  act = { port = "lamp", set = true  } },
    { id = "off", act = { port = "lamp", set = false } },
    { id = "also", act = { port = "lamp", set = true } },
    { id = "quiet", enabled = false, act = { port = "lamp", set = false } },
    { id = "other", act = { port = "dial", set = true } },
  })
  check(#clashes == 2, "two rules disagreeing about one output is a conflict", #clashes)
  check(clashes[1].port == "lamp", "named by port", clashes[1].port)
  check(clashes[1].rules[1] == "on" and clashes[1].rules[2] == "off", "and by rule")
  check(#rules.conflicts({ { id = "a", act = { port = "lamp", set = true } },
    { id = "b", act = { port = "lamp", set = true } } }) == 0,
    "two rules agreeing about one output is not")

  local good, problems = rules.validate({
    { id = "fine", when = { port = "button", op = "on" }, act = { port = "lamp", set = true } },
    { id = "fine", when = { port = "button", op = "on" }, act = { port = "lamp", set = true } },
    { id = "bad",  when = { port = "ghost",  op = "on" }, act = { port = "lamp", set = true } },
    { when = { port = "button", op = "on" }, act = { port = "lamp", set = true } },
  }, shapes)
  check(#good == 1, "validate keeps the rules that pass", #good)
  check(#problems == 3, "and reports the rest", #problems)
  check(table.concat(problems, "|"):find("defined twice", 1, true), "duplicate ids included")
end

--------------------------------------------------------------------------------
section("lib/logic: blocks")
--------------------------------------------------------------------------------

local logic = require("lib.logic")

do
  local function gate(op, inputs)
    local _, value = logic.blocks.gate.step({}, inputs, 0, { op = op })
    return value
  end

  check(gate("and", { true, true }) == true, "and, both")
  check(gate("and", { true, false }) == false, "and, one")
  check(gate("or",  { false, true }) == true, "or")
  check(gate("or",  { false, false }) == false, "or, neither")
  check(gate("not", { false }) == true, "not")
  check(gate("not", { true }) == false, "not, of on")
  check(gate("xor", { true, false }) == true, "xor")
  check(gate("xor", { true, true }) == false, "xor, both")
  check(gate("xor", { true, true, true }) == true, "xor counts parity")
  check(gate("nand", { true, true }) == false, "nand")
  check(gate("nand", { true, false }) == true, "nand, one")
  check(gate("nor", { false, false }) == true, "nor")
  check(gate("nor", { true, false }) == false, "nor, one")
  check(gate("wat", { true, true }) == true, "an unknown gate falls back to and")
  check(gate("and", { 7, 15 }) == true, "and analog inputs count as on")

  local latch = { id = "door", kind = "latch", out = "lamp",
                  wire = { set = "bell", reset = "close" } }
  local st = {}
  check(logic.run(latch, st, { bell = false, close = false }, 0) == false, "a latch starts off")
  check(logic.run(latch, st, { bell = true,  close = false }, 1) == true, "set turns it on")
  check(logic.run(latch, st, { bell = false, close = false }, 2) == true, "and it stays on")
  check(logic.run(latch, st, { bell = false, close = true  }, 3) == false, "reset turns it off")
  check(logic.run(latch, st, { bell = true,  close = true  }, 4) == false,
    "and reset wins when both arrive at once")

  local toggle = { id = "t", kind = "toggle", out = "lamp",
                   wire = { input = "btn", reset = "clear" } }
  st = {}
  check(logic.run(toggle, st, { btn = true }, 0) == false,
    "a toggle does not flip on the first sweep it is seen held")
  st = {}
  logic.run(toggle, st, { btn = false }, 0)
  check(logic.run(toggle, st, { btn = true }, 1) == true, "a press flips it")
  check(logic.run(toggle, st, { btn = true }, 2) == true, "holding it down does not flip it again")
  logic.run(toggle, st, { btn = false }, 3)
  check(logic.run(toggle, st, { btn = true }, 4) == false, "the next press flips it back")
  check(logic.run(toggle, st, { btn = true, clear = true }, 5) == false, "and reset clears it")

  local pulse = { id = "p", kind = "pulse", out = "lamp",
                  wire = { input = "motion" }, params = { secs = 2 } }
  st = {}
  logic.run(pulse, st, { motion = false }, 0)
  check(logic.run(pulse, st, { motion = true }, 1) == true, "a pulse extender starts on a press")
  check(logic.run(pulse, st, { motion = false }, 2) == true, "and holds after it is released")
  logic.run(pulse, st, { motion = true }, 2.5)
  check(logic.run(pulse, st, { motion = false }, 3.1) == true,
    "a second press while it is on restarts the clock")
  check(logic.run(pulse, st, { motion = false }, 4.4) == true, "measured from the last one")
  check(logic.run(pulse, st, { motion = false }, 4.6) == false, "and then it ends")

  local delay = { id = "d", kind = "delay", out = "lamp",
                  wire = { input = "sensor" }, params = { secs = 1 } }
  st = {}
  check(logic.run(delay, st, { sensor = true }, 0) == false, "a delay does not follow at once")
  check(logic.run(delay, st, { sensor = true }, 0.5) == false, "nor before it has settled")
  check(logic.run(delay, st, { sensor = true }, 1) == true, "and then it follows")
  check(logic.run(delay, st, { sensor = false }, 1.2) == true, "the other edge is delayed too")
  check(logic.run(delay, st, { sensor = true }, 1.5) == true,
    "a signal that comes back before the delay never moves the output")
  logic.run(delay, st, { sensor = false }, 2)
  check(logic.run(delay, st, { sensor = false }, 3.1) == false, "and one that stays away does")

  local blink = { id = "b", kind = "blink", out = "lamp",
                  wire = { input = "run" }, params = { secs = 0.5 } }
  st = {}
  check(logic.run(blink, st, { run = false }, 0) == false, "a blink held off is off")
  check(logic.run(blink, st, { run = true }, 1) == true, "and comes on as soon as it is enabled")
  check(logic.run(blink, st, { run = true }, 1.2) == true, "staying on for the interval")
  check(logic.run(blink, st, { run = true }, 1.5) == false, "then flipping")
  check(logic.run(blink, st, { run = true }, 2) == true, "and flipping back")
  check(logic.run(blink, st, { run = false }, 2.1) == false, "disabling it turns it off")
  check(logic.run(blink, st, { run = true }, 2.2) == true, "re-enabling starts a whole interval")
  check(logic.run(blink, st, { run = true }, 2.5) == true, "rather than a deadline that expired")
  check(logic.run(blink, st, { run = true }, 2.7) == false, "measured from when it came back")

  local counter = { id = "c", kind = "counter", out = "lamp",
                    wire = { input = "item", reset = "clear" }, params = { n = 3 } }
  st = {}
  logic.run(counter, st, { item = false }, 0)
  for i = 1, 2 do
    logic.run(counter, st, { item = true }, i)
    logic.run(counter, st, { item = false }, i + 0.5)
  end
  check(st.count == 2, "a counter counts rising edges", st.count)
  check(logic.run(counter, st, { item = false }, 3) == false, "and is off below its target")
  check(logic.run(counter, st, { item = true }, 4) == true, "on at it")
  check(logic.run(counter, st, { item = false }, 5) == true, "and stays on")
  check(logic.run(counter, st, { item = false, clear = true }, 6) == false, "until it is reset")
end

do
  section("lib/logic: wiring")

  local latch = { id = "l", kind = "latch", out = "lamp", wire = { set = "bell" } }
  local st = {}
  logic.run(latch, st, { bell = true }, 0)
  check(logic.run(latch, st, { bell = false }, 1) == true,
    "an unwired input reads off, so a latch with no reset never resets")

  local out, why = logic.run({ id = "x", kind = "nope", out = "lamp" }, {}, {}, 0)
  check(out == nil and tostring(why):find("no such block", 1, true),
    "an unknown kind is refused rather than thrown", why)

  local blocks = { { id = "l", kind = "latch", out = "lamp",
                     wire = { set = "bell", reset = "off" } } }
  local memo = {}
  local a = logic.evaluate(blocks, memo, { bell = true }, 0)
  check(#a == 1 and a[1].port == "lamp" and a[1].set == true and a[1].why == "l",
    "evaluate returns actions in the shape rules do")
  a = logic.evaluate(blocks, memo, { bell = false }, 1)
  check(#a == 1 and a[1].set == true,
    "and a block says what its output is every sweep, unlike a rule")
  check(memo.l ~= nil, "keeping its memory in the memo")
  check(#logic.evaluate({ { id = "l", enabled = false, kind = "latch", out = "lamp",
    wire = { set = "bell" } } }, {}, { bell = true }, 0) == 0, "a disabled block does nothing")
  check(#logic.evaluate({ { id = "l", kind = "latch", wire = { set = "bell" } } },
    {}, { bell = true }, 0) == 0, "and neither does one with no output port")

  local pruned = logic.prune({ { id = "l" } }, { l = {}, gone = {} })
  check(pruned.l ~= nil and pruned.gone == nil, "prune drops blocks that no longer exist")

  for _, kind in ipairs(logic.order) do
    checkQuiet(logic.get(kind) ~= nil, "[order] " .. kind .. " exists")
  end
  local defined = 0
  for _ in pairs(logic.blocks) do defined = defined + 1 end
  check(defined == #logic.order, "every block kind is in the UI's order list", defined)
end

do
  section("lib/logic: validation")
  local shapes = { bell = { dir = "in" }, close = { dir = "in" }, lamp = { dir = "out" } }
  local function why(block) return tostring(select(2, logic.check(block, shapes))) end
  local function ok(block) return (logic.check(block, shapes)) end

  check(ok({ id = "a", kind = "latch", out = "lamp", wire = { set = "bell" } }),
    "a sound block passes")
  check(ok({ id = "a", kind = "gate", out = "lamp", wire = { "bell", "close" },
    params = { op = "or" } }), "so does a gate with a list of inputs")

  check(why({ kind = "latch", out = "lamp", wire = { set = "bell" } })
    :find("no id", 1, true), "a block needs an id")
  check(why("nonsense"):find("not a table", 1, true), "and has to be a table")
  check(why({ id = "a", kind = "nope", out = "lamp", wire = { set = "bell" } })
    :find("is not a block", 1, true), "the kind has to exist")
  check(why({ id = "a", kind = "latch", wire = { set = "bell" } })
    :find("no output port", 1, true), "it needs somewhere to go")
  check(why({ id = "a", kind = "latch", out = "ghost", wire = { set = "bell" } })
    :find("no port named ghost", 1, true), "which has to exist")
  check(why({ id = "a", kind = "latch", out = "bell", wire = { set = "close" } })
    :find("is an input", 1, true), "and has to be an output")
  check(why({ id = "a", kind = "latch", out = "lamp" })
    :find("no inputs wired", 1, true), "it needs an input")
  check(why({ id = "a", kind = "gate", out = "lamp", wire = {} })
    :find("no inputs wired", 1, true), "a gate too")
  check(why({ id = "a", kind = "latch", out = "lamp", wire = { set = "ghost" } })
    :find("no port named ghost", 1, true), "whose port has to exist")
  check(why({ id = "a", kind = "gate", out = "lamp", wire = { "bell", "lamp" } })
    :find("both an input and the output", 1, true),
    "and a gate feeding its own input is refused")
  check(why({ id = "a", kind = "pulse", out = "lamp", wire = { input = "bell" },
    params = { secs = 900 } }):find("secs must be between", 1, true),
    "a parameter out of range is refused")
  check(ok({ id = "a", kind = "pulse", out = "lamp", wire = { input = "bell" },
    params = { secs = 5 } }), "and one inside it is not")
end

--------------------------------------------------------------------------------
section("lib/scenes")
--------------------------------------------------------------------------------

do
  local scenes = require("lib.scenes")
  local config = require("lib.config")

  local roster = {
    [3] = { seenAt = 100, ports = {
      { name = "lamp", dir = "out", value = true  },
      { name = "btn",  dir = "in",  value = false },
      { name = "dial", dir = "out", value = 7     } } },
    [4] = { seenAt = 100, ports = {
      { name = "porch", dir = "out", value = false } } },
    [5] = { seenAt = 1, ports = {
      { name = "shed", dir = "out", value = true } } },
  }

  scenes.load({})
  check(#scenes.names() == 0, "a network with no scenes has none")

  check((scenes.capture("night", roster)), "a scene can be captured from the roster")
  local night = scenes.get("night")
  check(#night == 4, "taking only the outputs", #night)
  check(night[1].node == 3 and night[1].port == "dial",
    "in a stable order, so it serialises the same way twice", night[1].port)
  check(night[2].port == "lamp" and night[2].value == true, "with the values it found")

  -- staleAfter is 15s; node 5 was last seen at t=1 and it is now t=105.
  local plan = scenes.plan("night", roster, 105)
  check(#plan.sends == 3, "a plan reaches the nodes that are answering", #plan.sends)
  check(#plan.missing == 1 and plan.missing[1].node == 5,
    "and reports the one that is not, rather than blocking on it")
  check(plan.sends[1].why == "scene:night", "every send says which scene it was")
  check(config.staleAfter > config.heartbeatTimeout,
    "the server is slower to give up on a node than the pocket computer is")

  local unknown, whyNot = scenes.plan("nope", roster, 105)
  check(unknown == nil and tostring(whyNot):find("no scene named", 1, true),
    "a scene that does not exist has no plan")

  check(scenes.active("night", roster), "the scene it was captured from is the one it is in")
  roster[3].ports[1].value = false
  check(not scenes.active("night", roster), "one port moving takes it out of that scene")
  roster[3].ports[1].value = true
  check(scenes.active("night", roster), "and putting it back puts it back")
  check(not scenes.active("night", { [3] = roster[3], [4] = roster[4] }),
    "a node that is not there cannot match")
  check(not scenes.active("nope", roster), "and a scene that does not exist is never active")

  local function set(name, entries)
    local fine, reason = scenes.set(name, entries)
    return fine, reason
  end

  check(refused(set("", { { node = 1, port = "a" } })), "a scene needs a name")
  check(refused(set("x", {}), select(2, set("x", {})), "empty"), "and something in it")
  local dup = { { node = 1, port = "a", value = true }, { node = 1, port = "a", value = false } }
  check(refused(set("x", dup), select(2, set("x", dup)), "twice"),
    "one port cannot be in a scene twice")
  check((set("x", { { node = 1, port = "a", value = true },
    { node = 1, port = "a2", value = true } })), "but two ports on one node can be")
  check((set("y", { { node = 1, port = "a", value = true }, "junk", { nope = 1 } })),
    "unusable entries are dropped")
  check(#scenes.get("y") == 1, "leaving the rest", #scenes.get("y"))
  check(refused(set("z", { "junk" }), select(2, set("z", { "junk" })), "nothing usable"),
    "and a scene of nothing but junk is refused")

  local names = scenes.names()
  check(names[1] == "night" and names[#names] == "y", "names come back sorted", names[1])
  check(scenes.remove("y"), "a scene can be removed")
  check(not scenes.remove("y"), "and says so if it was not there")

  scenes.load({ good = { { node = 1, port = "a" } }, bad = "not a table" })
  check(scenes.get("good") ~= nil and scenes.get("bad") == nil,
    "load ignores anything that is not a scene")
  check(#scenes.names() == 1, "and keeps the rest", #scenes.names())
end

--------------------------------------------------------------------------------
section("lib/log")
--------------------------------------------------------------------------------

do
  local log    = require("lib.log")
  local config = require("lib.config")

  log.clear()
  for i = 1, config.logSize + 20 do log.add({ port = "p" .. i, to = true, why = "r" }) end
  check(#log.entries == config.logSize, "the log is bounded", #log.entries)
  check(log.entries[1].port == "p21", "and the oldest go first", log.entries[1].port)

  local recent = log.recent(3)
  check(#recent == 3, "recent takes the last few", #recent)
  check(recent[1].port == "p" .. (config.logSize + 20), "newest first", recent[1].port)
  check(#log.recent() == config.logSize, "and everything by default")

  log.clear()
  log.add({ port = "lamp", to = true,  why = "night" })
  log.add({ port = "dial", to = 7,     why = "manual" })
  log.add({ port = "lamp", to = false, why = "manual" })
  local mine = log.forPort("lamp")
  check(#mine == 2 and mine[1].why == "manual",
    "one port's history comes back newest first", mine[1].why)
  check(#log.forPort("lamp", 1) == 1, "and can be capped")
  check(#log.forPort("ghost") == 0, "a port with no history has none")

  check(log.add({ port = "x" }).why == "?",
    "an entry with no cause still says something, because the cause is the point")
  check(log.add("nonsense") == nil, "and something that is not an entry is not one")

  check(log.value(true) == "on" and log.value(false) == "off", "booleans render as on and off")
  check(log.value(7) == "7", "a comparator level stays a number")
  check(log.value(nil) == "-", "and nothing renders as nothing")
  check(log.line({ at = { day = 1, clock = 12 }, port = "lamp", to = true })
    :find("lamp", 1, true), "a log line names its port")
  check(log.time(nil) == "--:--", "an entry with no time says so")
  check(type(log.stamp().day) == "number", "and a stamp carries the in-game day")

  local realSize = config.logSize
  config.logSize = 3
  log.load({ { port = "a" }, { port = "b" }, { port = "c" }, { port = "d" } })
  check(#log.entries == 3, "a log loaded from disk is trimmed too", #log.entries)
  check(log.entries[1].port == "b", "from the front", log.entries[1].port)
  config.logSize = realSize
  log.load({})
  check(#log.entries == 0, "and an empty one loads empty")
end

--------------------------------------------------------------------------------
section("lib/state")
--------------------------------------------------------------------------------

do
  local state  = require("lib.state")
  local config = require("lib.config")
  local path   = "/test-state.dat"
  fs.delete(path)

  local data = state.open(path, { outputs = {}, n = 1 })
  check(data.n == 1, "a missing state file starts from the default")

  state.set("n", 1)
  check(state.dirty == false, "setting a value to what it already was is not a change")
  state.set("n", 2)
  check(state.dirty, "and setting it to something else is")

  check(state.flush(10), "flush writes")
  check(state.dirty == false, "and clears the flag")
  check(fs.exists(path), "leaving a file behind")
  check(not fs.exists(path .. ".part"),
    "written beside the target and moved into place, not left half done")

  state.set("n", 3)
  check(state.tick(10.5) == false, "the write is debounced")
  check(state.tick(10 + config.stateWrite) ~= false, "and taken once the interval has passed")
  check(state.tick(20) == false, "with nothing to write, nothing is written")

  state.open(path, { n = 99 })
  check(state.get("n") == 3, "what was written comes back")

  writeFile(path, "}{ not lua at all")
  state.open(path, { n = 42 })
  check(state.get("n") == 42, "and a corrupt file is treated as no file, not as a crash")

  state.mark()
  check(state.dirty, "mark says something nested changed")
  state.clear()
  check(not fs.exists(path), "clear throws the file away")
  check(state.dirty == false, "with nothing left to write")
end

--------------------------------------------------------------------------------

print("")
print(("%d passed, %d failed"):format(pass, fail))
_G.RS_TOTALS = _G.RS_TOTALS or {}
_G.RS_TOTALS["spec"] = { pass = pass, fail = fail }
flush()
