--- Drives install.lua against a stubbed http and scripted answers.
--
-- The installer is the one program where a bug means the user never gets far
-- enough to report it: there is no log, no dashboard, and nothing installed to
-- read the error from. So it is run here the way it runs in the world -- fetch,
-- prompt, write -- with three things stood in for:
--
--   http    served out of the local tree, so a "download" hands back the real
--           file. Nothing writes anything this suite did not already have.
--   read    a scripted list of answers, counted, so a case can prove a prompt
--           was *not* asked as well as what it was answered with.
--   term    a recording proxy over a window, because the messages are the
--           product here and most of them scroll off a 19-line screen.
--
-- The last prompt waits fifteen seconds for a keypress. os.startTimer is stubbed
-- to fire at once so the timeout path costs nothing, and a `char` queued before
-- the program starts beats it to the queue when a case wants the other branch.
--
-- This suite runs last because it is the only one that writes to the computer
-- root the real tree lives in.

local out = {}
local function say(s)
  out[#out + 1] = tostring(s)
  local f = fs.open("/test-install-results.txt", "w")
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

local OVERRIDES = "/redstone.cfg"
local PORTS     = "/ports.cfg"
local RULES     = "/rules.cfg"

local realHttp   = _G.http
local realRead   = _G.read
local realPocket = _G.pocket
local realReboot = os.reboot
local realTimer  = os.startTimer
local realCall   = peripheral.call
local realLabel  = os.getComputerLabel()

local function writeFile(path, body)
  local f = fs.open(path, "w")
  f.write(body)
  f.close()
end

local function readFile(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local body = f.readAll()
  f.close()
  return body
end

local function drain()
  os.queueEvent("rs_drain")
  while true do
    if os.pullEventRaw() == "rs_drain" then return end
  end
end

--- A terminal that keeps everything written to it.
--
-- The segments are joined with nothing between them, because CC's `write` calls
-- term.write once per *word* -- "hello there" arrives as "hello", " ", "there"
-- -- and anything put between them would cut every phrase worth asserting on in
-- half. Line breaks are lost with it, so two consecutive prints run together;
-- keep needles inside one printed line.
local function recorder()
  local win = window.create(term.native(), 1, 1, 51, 19, false)
  local said = {}

  local proxy = {}
  for key, value in pairs(win) do proxy[key] = value end
  proxy.write = function(text)
    said[#said + 1] = tostring(text)
    return win.write(text)
  end
  proxy.blit = function(text, fg, bg)
    said[#said + 1] = tostring(text)
    return win.blit(text, fg, bg)
  end

  return proxy, function() return table.concat(said, "") end
end

--- Serves the repo out of the local tree.
--
-- `manifest` replaces what manifest.txt would say; `fail` maps a path to the
-- reason its download should fail; `empty` marks paths that come back as a
-- zero-length body, which is a different failure from a 404 and is the one
-- raw.githubusercontent actually produces for a path that is a directory.
local function stubHttp(opts)
  local asked = {}
  return {
    asked = asked,
    get = function(url)
      asked[#asked + 1] = url
      local path = url:match("/redstone/(.-)%?nocache=")
      if not path then return nil, "unexpected url: " .. tostring(url) end
      if opts.fail and opts.fail[path] then return nil, opts.fail[path] end

      local body
      if opts.empty and opts.empty[path] then
        body = ""
      elseif path == "manifest.txt" and opts.manifest then
        body = opts.manifest
      else
        body = readFile("/" .. path)
        if not body then return nil, "404 not found" end
      end

      return { readAll = function() return body end, close = function() end }
    end,
  }
end

--- Run the installer once. Everything it touches is reset first, so a case
--- never inherits the file another one left behind.
local function runInstall(opts)
  opts = opts or {}
  drain()

  fs.delete(OVERRIDES)
  fs.delete(PORTS)
  fs.delete(RULES)
  if opts.cfg   then writeFile(OVERRIDES, opts.cfg) end
  if opts.ports then writeFile(PORTS, opts.ports) end
  os.setComputerLabel(opts.label)

  -- Spelled out rather than `(opts.noHttp and nil) or http`, which is `http`
  -- either way: the same falsy trap that had node.lua latching a repeatedly
  -- pulsed output permanently on.
  local http = stubHttp(opts)
  if opts.noHttp then _G.http = nil else _G.http = http end
  _G.pocket = opts.pocket and {} or nil

  local answers, reads = opts.answers or {}, 0
  _G.read = function()
    reads = reads + 1
    return answers[reads] or ""
  end

  local rebooted = false
  os.reboot = function() rebooted = true end

  -- Fifteen seconds is the right wait in the world and the wrong one here.
  os.startTimer = function() return realTimer(0) end

  -- CraftOS-PC's emulated modem reports isWireless() == false, and the check at
  -- the end of the installer accepts wireless only. Present it as wireless
  -- rather than loosening the program to suit the emulator.
  if opts.modem then
    pcall(periphemu.create, "back", "modem")
    peripheral.call = function(side, method, ...)
      if method == "isWireless" and peripheral.getType(side) == "modem" then return true end
      return realCall(side, method, ...)
    end
  end

  if opts.key then os.queueEvent("char", opts.key) end

  local proxy, transcript = recorder()
  local prev = term.redirect(proxy)
  local fn, loadErr = loadfile("/install.lua")
  local ok, err = true, loadErr
  if fn then ok, err = pcall(fn, unpack(opts.args or {})) end
  term.redirect(prev)

  _G.http, _G.read, _G.pocket = realHttp, realRead, realPocket
  os.reboot, os.startTimer, peripheral.call = realReboot, realTimer, realCall
  if opts.modem then pcall(periphemu.remove, "back") end

  return {
    said     = transcript(),
    asked    = http.asked,
    reads    = reads,
    rebooted = rebooted,
    crash    = (not ok) and tostring(err) or nil,
  }
end

--- Did the installer ask for this path, and from where?
local function askedFor(asked, path)
  for _, url in ipairs(asked) do
    if url:find("/redstone/" .. path .. "?", 1, true) then return url end
  end
  return nil
end

--- The overrides file as a table, or nil if it was not written.
local function overrides()
  local body = readFile(OVERRIDES)
  if not body then return nil end
  local fn = loadfile(OVERRIDES)
  if not fn then return nil, body end
  local ok, cfg = pcall(fn)
  if ok and type(cfg) == "table" then return cfg, body end
  return nil, body
end

--- The paths manifest.txt lists, which is what a successful install fetches.
local function manifestPaths()
  local paths = {}
  for line in readFile("/manifest.txt"):gmatch("[^\r\n]+") do
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" and not line:match("^#") then paths[#paths + 1] = line end
  end
  return paths
end

--------------------------------------------------------------------------------
section("install: downloading")
--------------------------------------------------------------------------------

local MANIFEST = manifestPaths()

do
  local r = runInstall({ answers = { "", "", "", "" }, key = "n" })
  check(r.crash == nil, "the installer runs", r.crash)
  check(askedFor(r.asked, "manifest.txt") ~= nil, "asking for the file list first")
  check(r.asked[1]:find("manifest.txt", 1, true), "before anything else", r.asked[1])

  local missing = nil
  for _, path in ipairs(MANIFEST) do
    if not askedFor(r.asked, path) then missing = path end
  end
  check(missing == nil, "then for every file the manifest lists", missing)
  check(#r.asked == #MANIFEST + 1, "and nothing else", #r.asked)
  check(askedFor(r.asked, "install.lua") == nil,
    "the installer does not download itself -- wget run already did")

  check(r.asked[1]:find("Gizmo0320/CCprograms/main/", 1, true),
    "from the default repo and branch", r.asked[1])
  check(r.asked[1]:find("nocache=", 1, true),
    "with a cache buster, because raw.githubusercontent serves stale copies")
  check(r.said:find("Installed", 1, true), "and says how it went")

  r = runInstall({ args = { "dev", "someone/fork" }, answers = { "", "", "", "" }, key = "n" })
  check(r.asked[1]:find("someone/fork/dev/", 1, true),
    "a branch and repo can be given as arguments", r.asked[1])

  r = runInstall({ noHttp = true, key = "n" })
  check(r.said:find("HTTP API is disabled", 1, true), "http being off is explained")
  check(r.reads == 0, "and nothing is asked that cannot be acted on", r.reads)

  r = runInstall({ fail = { ["manifest.txt"] = "404" }, key = "n" })
  check(r.said:find("Could not fetch the file list", 1, true),
    "a manifest that will not download says so")
  check(r.said:find("branch name", 1, true), "with the two things worth checking")
  check(r.reads == 0, "and stops there")

  r = runInstall({ manifest = "# nothing but a comment\n\n", key = "n" })
  check(r.said:find("manifest is empty", 1, true), "an empty manifest is not an install")
  check(#r.asked == 1, "and costs one request", #r.asked)

  r = runInstall({ manifest = "# a comment\n\n  node.lua  \n\nlib/net.lua\n", key = "n",
                   answers = { "", "", "", "" } })
  check(#r.asked == 3, "comments and blank lines are skipped", #r.asked)
  check(askedFor(r.asked, "node.lua") and askedFor(r.asked, "lib/net.lua"),
    "and paths are trimmed of the whitespace around them")

  -- Nothing is written until everything has arrived: a tree where node.lua is
  -- new and lib/ports.lua is old fails in ways that look like bugs.
  r = runInstall({ manifest = "node.lua\nghost.lua\n", key = "n" })
  check(r.said:find("Nothing was installed", 1, true), "one failed download stops the install")
  check(r.said:find("ghost.lua", 1, true), "naming the file", nil)
  check(not fs.exists("/ghost.lua"), "and nothing is left behind")
  check(r.reads == 0, "with nothing asked afterwards")

  r = runInstall({ manifest = "node.lua\n", empty = { ["node.lua"] = true }, key = "n" })
  check(r.said:find("Nothing was installed", 1, true),
    "a file that comes back empty counts as a failure, not as a file")
end

--------------------------------------------------------------------------------
section("install: the network")
--------------------------------------------------------------------------------

do
  local r = runInstall({ answers = { "", "", "", "" }, key = "n" })
  check(r.reads == 4, "a plain computer is asked four things", r.reads)
  check(overrides() == nil,
    "and answering with the defaults writes no overrides file at all")
  check(r.said:find("channel 2718", 1, true), "which are the ones lib/config.lua has")

  r = runInstall({ answers = { "base", "4200", "server", "Base" }, key = "n" })
  local cfg = overrides()
  check(cfg ~= nil, "anything else is written down")
  check(cfg.protocol == "base", "the network name", cfg and cfg.protocol)
  check(cfg.channel == 4200, "the channel", cfg and cfg.channel)
  check(cfg.role == "server", "and the role", cfg and cfg.role)
  check(select(2, overrides()):find("update", 1, true),
    "with a note saying why update will not replace it")

  r = runInstall({ args = { "--net=base", "--channel=4200", "--role=server",
                            "--name=Kitchen" }, key = "n" })
  check(r.reads == 0, "the flags skip every prompt, for an unattended install", r.reads)
  cfg = overrides()
  check(cfg and cfg.protocol == "base" and cfg.channel == 4200 and cfg.role == "server",
    "and land in the same place the answers would have")
  check(os.getComputerLabel() == "Kitchen", "the name included", os.getComputerLabel())

  -- Enter keeps what the computer already is, so re-running the installer to
  -- pick up a fix does not quietly move it to another network.
  local existing = 'return { protocol = "base", channel = 4200, role = "server" }'
  r = runInstall({ cfg = existing, answers = { "", "", "", "" }, key = "n" })
  cfg = overrides()
  check(cfg and cfg.protocol == "base" and cfg.channel == 4200 and cfg.role == "server",
    "enter keeps the network this computer is already on")
  check(r.said:find("on network 'base'", 1, true), "and it says which that is")

  r = runInstall({ cfg = existing, answers = { "redstone", "2718", "node", "" }, key = "n" })
  check(not fs.exists(OVERRIDES),
    "setting everything back to the defaults drops the file rather than leaving "
    .. "one saying otherwise")

  r = runInstall({ answers = { "my base!!", "", "", "" }, key = "n" })
  check((overrides() or {}).protocol == "mybase",
    "a network name is cut down to what fits in a frame and a column",
    (overrides() or {}).protocol)

  r = runInstall({ answers = { ("x"):rep(40), "", "", "" }, key = "n" })
  check(#((overrides() or {}).protocol or "") == 24, "and to 24 characters",
    #((overrides() or {}).protocol or ""))

  r = runInstall({ answers = { "", "999999", "", "" }, key = "n" })
  check(overrides() == nil, "a channel outside 1-65535 falls back rather than sticking")
  r = runInstall({ answers = { "", "not a number", "", "" }, key = "n" })
  check(overrides() == nil, "and so does one that is not a number")
  r = runInstall({ cfg = existing, answers = { "", "0", "", "" }, key = "n" })
  check((overrides() or {}).channel == 4200, "falling back to what it was on",
    (overrides() or {}).channel)

  r = runInstall({ answers = { "", "", "wat", "" }, key = "n" })
  check(overrides() == nil, "a role that is neither falls back to node")
end

--------------------------------------------------------------------------------
section("install: what this computer is")
--------------------------------------------------------------------------------

do
  -- A turtle is obviously a turtle, but a node and a server are both plain
  -- computers and no amount of peripheral sniffing tells them apart.
  local r = runInstall({ answers = { "", "", "", "" }, key = "n" })
  check(r.said:find("node or the server", 1, true), "a plain computer is asked which it is")
  check(fs.exists(PORTS), "a node gets an example ports file")
  check(fs.exists(RULES), "and an example rules file")
  check(r.said:find("edit it to match", 1, true), "and is told to edit it")

  r = runInstall({ answers = { "", "", "server", "" }, key = "n" })
  check(not fs.exists(PORTS), "a server gets neither, having no wiring of its own")

  r = runInstall({ modem = true, answers = { "", "", "server", "" }, key = "n" })
  check(r.said:find("ender modem", 1, true),
    "a server with a modem is told range is what decides whether a scene reaches "
    .. "the far shed")

  r = runInstall({ pocket = true, answers = { "", "", "" }, key = "n" })
  check(r.reads == 3, "a pocket computer is never asked its role", r.reads)
  check((overrides() or {}).role == "remote", "it is always the remote",
    (overrides() or {}).role)
  check(not fs.exists(PORTS), "and has no ports of its own")

  -- Wiring is per-computer and is not in manifest.txt, so it has to survive
  -- being reinstalled over as well as being updated over.
  local mine = "-- mine\nreturn { { name = 'x', side = 'top', dir = 'out', kind = 'digital' } }\n"
  r = runInstall({ ports = mine, answers = { "", "", "", "" }, key = "n" })
  check(readFile(PORTS) == mine, "an existing ports file is never overwritten")
  check(r.said:find("Kept your existing", 1, true), "and it says so")

  r = runInstall({ answers = { "", "", "", "" }, key = "n" })
  check(r.said:find("No wireless modem", 1, true), "a node with no modem is warned")
  check(r.said:find("nothing can see", 1, true), "that it is on its own")
  r = runInstall({ answers = { "", "", "server", "" }, key = "n" })
  check(r.said:find("cannot do anything", 1, true),
    "and a server with no modem more sharply, having nothing else to do")

  r = runInstall({ modem = true, answers = { "", "", "", "" }, key = "n" })
  check(not r.said:find("No wireless modem", 1, true),
    "a computer that has one is not warned about it")
end

--------------------------------------------------------------------------------
section("install: the examples it leaves behind")
--------------------------------------------------------------------------------

-- The example ports file is the first thing anyone edits, and a broken one is a
-- broken first five minutes with no way to tell whose fault it is.
do
  runInstall({ answers = { "", "", "", "" }, key = "n" })

  local ports = require("lib.ports")
  local rules = require("lib.rules")
  local logic = require("lib.logic")

  local fn = loadfile(PORTS)
  check(fn ~= nil, "the example ports file is Lua")
  local ok, list = pcall(fn)
  check(ok and type(list) == "table", "returning a table", not ok and list or nil)

  local fine, problems = ports.define(list)
  check(fine, "which lib/ports accepts", problems and problems[1])
  check(ports.count() == 3, "with a port of each kind in it", ports.count())
  check(ports.get("lamp") and ports.get("button") and ports.get("level"),
    "named the way the README names them")

  local shapes = {}
  for _, p in ipairs(ports.list) do shapes[p.name] = { dir = p.dir, kind = p.kind } end

  fn = loadfile(RULES)
  check(fn ~= nil, "the example rules file is Lua too")
  local data
  ok, data = pcall(fn)
  check(ok and type(data) == "table", "returning a table", not ok and data or nil)
  check(type(data.rules) == "table" and type(data.blocks) == "table",
    "in the shape node.lua reads: rules and blocks")

  local good, why = rules.validate(data.rules, shapes)
  check(#why == 0, "with nothing in it a node would refuse", why[1])
  check(#good == 0, "and nothing switched on before anyone has read it", #good)

  local bad = nil
  for _, block in ipairs(data.blocks) do
    if not logic.check(block, shapes) then bad = block.id end
  end
  check(bad == nil, "the same for the blocks", bad)

  -- Every rule the file suggests in a comment has to be one the node accepts,
  -- or the first thing anyone uncomments is refused.
  local suggested = {
    { id = "night-lights", enabled = true,
      when = { port = "level", op = "<", value = 4 },
      act  = { port = "lamp", set = true }, hold = 2 },
  }
  local fineRules, rulesWhy = rules.validate(suggested, shapes)
  check(#fineRules == 1, "the commented-out rule is one a node would take", rulesWhy[1])
  check((logic.check({ id = "porch", kind = "toggle", out = "lamp",
    wire = { input = "button" } }, shapes)), "and so is the commented-out block")
end

--------------------------------------------------------------------------------
section("install: finishing")
--------------------------------------------------------------------------------

do
  local r = runInstall({ answers = { "", "", "", "Kitchen" }, key = "n" })
  check(os.getComputerLabel() == "Kitchen", "the name becomes the computer's label")
  check(r.said:find("Named Kitchen", 1, true), "and is read back")

  r = runInstall({ answers = { "", "", "", "" }, key = "n" })
  check(os.getComputerLabel() == "node-" .. os.getComputerID(),
    "with a default that at least says what it is", os.getComputerLabel())

  r = runInstall({ label = "Existing", answers = { "", "", "", "" }, key = "n" })
  check(os.getComputerLabel() == "Existing", "an existing label is offered back")

  r = runInstall({ answers = { "", "", "", "my node!" }, key = "n" })
  check(os.getComputerLabel() == "mynode", "and a name is cut down like the network's")

  r = runInstall({ answers = { "", "", "", "" }, key = "y" })
  check(r.rebooted, "y reboots into the program that was just installed")
  r = runInstall({ answers = { "", "", "", "" }, key = "n" })
  check(not r.rebooted, "anything else does not")

  -- Installing across a row of computers is a reasonable thing to script, and a
  -- prompt that waits forever turns that into a row of computers sitting at a
  -- question nobody is there to answer.
  r = runInstall({ answers = { "", "", "", "" } })
  check(r.said:find("leaving it to you", 1, true), "and the prompt gives up on its own")
  check(not r.rebooted, "without rebooting behind your back")
end

--------------------------------------------------------------------------------

_G.http, _G.read, _G.pocket = realHttp, realRead, realPocket
os.reboot, os.startTimer = realReboot, realTimer
os.setComputerLabel(realLabel)
fs.delete(OVERRIDES)
fs.delete(PORTS)
fs.delete(RULES)

say("")
say(("%d passed, %d failed"):format(pass, fail))
_G.RS_TOTALS = _G.RS_TOTALS or {}
_G.RS_TOTALS["install"] = { pass = pass, fail = fail }
