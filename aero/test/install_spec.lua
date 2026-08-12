--- Drives install.lua against a stubbed http.
--
-- The installer is the one program here nobody runs twice, which is exactly why
-- it is worth testing: a bug in it is discovered by somebody standing at a fresh
-- computer with no working copy of anything to fall back on.
--
-- Its http is stubbed to serve files out of the tree under test, so a successful
-- install rewrites every file with the bytes it already had. A case that wants a
-- *failed* download names a path that is not there rather than serving different
-- content -- there is no safe way to write different content into the tree the
-- suite is running from.
--
-- Runs last, and writes to the computer root the tree under test lives in.
--
-- CC's `write` calls term.write once per **word**, so a recording terminal has
-- to join its segments with nothing between them or every phrase comes back cut
-- in half. That is what `capture` below does.

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

local OVERRIDES = "/aero.cfg"

local realHttp   = _G.http
local realRead   = _G.read
local realReboot = os.reboot
local realLabel  = os.getComputerLabel()
local realPocket = _G.pocket
local realTimer  = os.startTimer

--------------------------------------------------------------------------------

local function readFile(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local body = f.readAll()
  f.close()
  return body
end

--- An http that serves the tree under test.
--
-- The cache buster the installer appends has to be stripped, or every path is a
-- miss. That the installer appends one at all is deliberate:
-- raw.githubusercontent serves a cached copy for minutes, and being handed the
-- version you just replaced is a genuinely baffling way to lose an afternoon.
local function stubHttp(opts)
  return {
    get = function(url)
      local path = tostring(url):match("/aero/([^?]+)")
      if not path then return nil, "not an aero url" end

      if opts.missing and opts.missing[path] then return nil, "404" end

      local body = readFile("/" .. path)
      if not body then return nil, "404" end

      -- `false` is a legitimate thing for a stub to be asked to return, so this
      -- is a comparison rather than `opts.x and ... or ...`. That shape has
      -- already been a bug twice in this repo, once in an http stub exactly like
      -- this one.
      return {
        readAll = function() return body end,
        close = function() end,
      }
    end,
  }
end

--- Run the installer with a script of typed answers, capturing what it printed.
local function runInstall(opts)
  opts = opts or {}

  fs.delete(OVERRIDES)
  os.setComputerLabel(opts.label)
  _G.pocket = opts.pocket and {} or nil

  local answers = opts.answers or {}
  local asked = 0
  _G.read = function()
    asked = asked + 1
    return answers[asked] or ""
  end

  _G.http = stubHttp(opts)

  local rebooted = false
  os.reboot = function() rebooted = true error("rebooted", 0) end

  -- The reboot prompt is timed rather than a bare pullEvent, so an unattended
  -- install does not leave a row of computers sitting at a question. Firing the
  -- timer immediately is how the case gets past it without waiting fifteen
  -- seconds of wall clock.
  local deadline
  os.startTimer = function(t)
    deadline = realTimer(0)
    return deadline
  end

  local printed = {}
  local recorder = {}
  local current = term.current()
  for k, v in pairs(current) do recorder[k] = v end
  -- Joined with nothing between the segments: CC's `write` calls term.write once
  -- per word, so "Installed 17 file(s)." arrives as five separate calls.
  recorder.write = function(text) printed[#printed + 1] = tostring(text) end
  recorder.blit = function(text) printed[#printed + 1] = tostring(text) end

  -- loadfile, not dofile: CC's dofile takes no arguments beyond the path, so
  -- every flag was silently dropped and the installer fell back to prompting.
  -- The symptom was four questions asked in a case that passed four flags.
  local chunk, loadErr = loadfile("/install.lua")
  local old = term.redirect(recorder)
  local ok, err = true, nil
  if not chunk then
    ok, err = false, loadErr
  else
    ok, err = pcall(chunk, unpack(opts.args or {}))
  end
  term.redirect(old)

  _G.http, _G.read, os.reboot, _G.pocket, os.startTimer =
    realHttp, realRead, realReboot, realPocket, realTimer

  local crash = nil
  if not ok and not tostring(err):find("rebooted", 1, true) then
    crash = tostring(err)
  end

  return {
    said = table.concat(printed, ""),
    rebooted = rebooted,
    asked = asked,
    crash = crash,
  }
end

local function said(r, text)
  return tostring(r.said):find(text, 1, true) ~= nil
end

--------------------------------------------------------------------------------
section("downloading")
--------------------------------------------------------------------------------

do
  local r = runInstall{
    args = { "main", "Gizmo0320/CCprograms", "--net=aero", "--channel=1618",
             "--role=pilot", "--name=Kestrel" },
  }

  check(r.crash == nil, "the installer runs", r.crash)
  check(said(r, "Installed"), "and says what it installed", r.said:sub(1, 120))
  check(fs.exists("/pilot.lua"), "pilot.lua is there")
  check(fs.exists("/lib/hull.lua"), "and the library with it")
  check(r.asked == 0, "the flags answer every prompt, for an unattended install",
        r.asked)
end

do
  -- One file missing. Nothing at all is written, because a tree where pilot.lua
  -- is new and lib/hull.lua is old fails in ways that look like bugs in neither
  -- -- and on this program it fails in the air.
  local before = readFile("/lib/hull.lua")

  local r = runInstall{
    missing = { ["lib/flight.lua"] = true },
    args = { "main", "Gizmo0320/CCprograms", "--net=aero", "--channel=1618",
             "--role=pilot", "--name=Kestrel" },
  }

  check(said(r, "Nothing was installed"), "a failed download installs nothing")
  check(said(r, "lib/flight.lua"), "and names the file that failed")
  check(readFile("/lib/hull.lua") == before, "leaving the working copy alone")
end

do
  local r = runInstall{
    missing = { ["manifest.txt"] = true },
    args = { "main", "Gizmo0320/CCprograms", "--net=aero", "--channel=1618",
             "--role=pilot", "--name=Kestrel" },
  }
  check(said(r, "Could not fetch the file list"),
        "no manifest is a clear message rather than a stack trace")
end

--------------------------------------------------------------------------------
section("configuration")
--------------------------------------------------------------------------------

do
  -- Everything at its default, so there is nothing to write down. A tree with no
  -- overrides file is one less thing to explain to whoever reads it later.
  local r = runInstall{
    args = { "main", "Gizmo0320/CCprograms", "--net=aero", "--channel=1618",
             "--role=pilot", "--name=Kestrel" },
  }
  check(not fs.exists(OVERRIDES),
        "a plain default setup writes no overrides file")
end

do
  local r = runInstall{
    args = { "main", "Gizmo0320/CCprograms", "--net=north", "--channel=4300",
             "--role=server", "--name=Tower" },
  }
  check(fs.exists(OVERRIDES), "anything else does")

  local cfg = loadfile(OVERRIDES)
  local ok, values = pcall(cfg)
  check(ok and values.protocol == "north", "with the network name",
        ok and values.protocol)
  check(ok and values.channel == 4300, "the channel", ok and values.channel)
  check(ok and values.role == "server", "and the role", ok and values.role)
end

do
  -- Explicitly back to the defaults. The file is deleted rather than left
  -- saying one thing while the computer does another.
  local r = runInstall{
    args = { "main", "Gizmo0320/CCprograms", "--net=aero", "--channel=1618",
             "--role=pilot", "--name=Kestrel" },
  }
  check(not fs.exists(OVERRIDES),
        "going back to the defaults removes the overrides file")
end

do
  -- A channel outside the range is a typo, and falling back beats a network on
  -- channel 0 that never speaks to anything.
  local r = runInstall{
    args = { "main", "Gizmo0320/CCprograms", "--net=aero", "--channel=99999",
             "--role=pilot", "--name=Kestrel" },
  }
  check(said(r, "1618"), "an impossible channel falls back to the default",
        r.said:match("channel %d+"))
end

do
  -- A pocket computer is always the remote, and is not asked.
  local r = runInstall{
    pocket = true,
    args = { "main", "Gizmo0320/CCprograms", "--net=aero", "--channel=1618",
             "--name=Pocket" },
  }
  check(said(r, "as remote"), "a pocket computer installs as the remote",
        r.said:match("as %a+"))
end

do
  -- "tower" and "ship" are what anyone would actually type.
  local r = runInstall{
    args = { "main", "Gizmo0320/CCprograms", "--net=aero", "--channel=1618",
             "--role=tower", "--name=Base" },
  }
  check(said(r, "as server"), "'tower' is accepted as the server role",
        r.said:match("as %a+"))
end

--------------------------------------------------------------------------------
section("prompts and naming")
--------------------------------------------------------------------------------

do
  -- No flags: every prompt is asked, in order -- network, channel, role, name.
  local r = runInstall{
    answers = { "north", "4300", "pilot", "Merlin" },
    args = { "main", "Gizmo0320/CCprograms" },
  }
  check(r.asked == 4, "four questions with no flags", r.asked)
  check(os.getComputerLabel() == "Merlin", "and the answer becomes the label",
        os.getComputerLabel())
end

do
  -- Enter through everything keeps what is already there.
  local r = runInstall{
    label = "Kestrel",
    answers = { "", "", "", "" },
    args = { "main", "Gizmo0320/CCprograms" },
  }
  check(os.getComputerLabel() == "Kestrel", "enter keeps the existing name",
        os.getComputerLabel())
  check(not fs.exists(OVERRIDES), "and the existing defaults")
end

do
  -- The name rides in every frame and is drawn in narrow columns.
  local r = runInstall{
    args = { "main", "Gizmo0320/CCprograms", "--net=aero", "--channel=1618",
             "--role=pilot", "--name=My Ship!! <>" },
  }
  check(os.getComputerLabel() == "MyShip",
        "odd characters are stripped from a name", os.getComputerLabel())
end

do
  -- A pilot is told what to do next, because it cannot fly until probe has run
  -- and nothing else in the program says so.
  fs.delete("/craft.cfg")
  local r = runInstall{
    args = { "main", "Gizmo0320/CCprograms", "--net=aero", "--channel=1618",
             "--role=pilot", "--name=Kestrel" },
  }
  check(said(r, "probe"), "a fresh pilot is told to run probe next")
  check(not fs.exists("/craft.cfg"),
        "and the installer does not guess at a hull it has never seen")
end

--------------------------------------------------------------------------------

-- Put the tree back the way the other suites expect to find it, and leave no
-- overrides file behind: lib/config is already loaded and would not read it now,
-- but the next run of the whole suite would.
fs.delete(OVERRIDES)
os.setComputerLabel(realLabel)

say("")
say(("%d passed, %d failed"):format(pass, fail))

_G.AERO_TOTALS = _G.AERO_TOTALS or {}
_G.AERO_TOTALS.install = { pass = pass, fail = fail }
