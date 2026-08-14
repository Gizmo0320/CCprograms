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
-- ## What changed when the installer stopped configuring
--
-- It used to ask for the network, the channel, the role and the name, and most
-- of this suite was about those four questions. It asks none of them now:
-- `configure` owns every one, and the installer's last act on a fresh computer
-- is to hand over to it. So the cases here are about the four modes, the version
-- comparison, what gets left alone, and that the hand-off actually happens.
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
local RECORD    = "/aero.install"

local realHttp   = _G.http
local realReboot = os.reboot
local realLabel  = os.getComputerLabel()
local realPocket = _G.pocket
local realTimer  = os.startTimer
local realShell  = _G.shell

--------------------------------------------------------------------------------

local function readFile(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local body = f.readAll()
  f.close()
  return body
end

local function writeFile(path, body)
  local f = fs.open(path, "w")
  f.write(body)
  f.close()
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

      -- A case that wants to look like a newer release rewrites the version
      -- comment rather than the file list, because the file list has to keep
      -- naming files that really exist in the tree being served.
      if path == "manifest.txt" and opts.remoteVersion then
        local body = readFile("/manifest.txt")
        body = body:gsub("# version [%w%.%-]+",
                         "# version " .. opts.remoteVersion, 1)
        return { readAll = function() return body end, close = function() end }
      end

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

--- Run the installer, capturing what it printed and what it handed off to.
local function runInstall(opts)
  opts = opts or {}

  _G.pocket = opts.pocket and {} or nil
  _G.http = stubHttp(opts)

  local rebooted = false
  os.reboot = function() rebooted = true error("rebooted", 0) end

  -- The hand-off is the installer's last act, and running it for real would
  -- drop the whole suite into an interactive configurator. Recorded instead,
  -- which is also the only way to assert that it happened.
  local ran = {}
  _G.shell = setmetatable({
    run = function(...) ran[#ran + 1] = table.concat({ ... }, " ") return true end,
  }, { __index = realShell })

  -- Prompts that are not answered by --yes are timed rather than bare, so an
  -- unattended install does not leave a row of computers sitting at a question.
  -- Firing the timer immediately is how a case gets past one without waiting.
  os.startTimer = function()
    return realTimer(0)
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
  local chunk, loadErr = loadfile("/install.lua")
  local old = term.redirect(recorder)
  local ok, err = true, nil
  if not chunk then
    ok, err = false, loadErr
  else
    ok, err = pcall(chunk, unpack(opts.args or {}))
  end
  term.redirect(old)

  _G.http, os.reboot, _G.pocket, os.startTimer, _G.shell =
    realHttp, realReboot, realPocket, realTimer, realShell

  local crash = nil
  if not ok and not tostring(err):find("rebooted", 1, true) then
    crash = tostring(err)
  end

  return {
    said = table.concat(printed, ""),
    rebooted = rebooted,
    handedOff = table.concat(ran, "; "),
    crash = crash,
  }
end

local function said(r, text)
  return tostring(r.said):find(text, 1, true) ~= nil
end

--- The state a fresh computer is in: no settings, no install record.
local function fresh()
  fs.delete(OVERRIDES)
  fs.delete(RECORD)
end

--------------------------------------------------------------------------------
section("downloading")
--------------------------------------------------------------------------------

do
  fresh()
  local r = runInstall{ args = { "install", "main", "Gizmo0320/CCprograms", "--yes" } }

  check(r.crash == nil, "the installer runs", r.crash)
  check(said(r, "Installed"), "and says what it installed", r.said:sub(1, 120))
  check(fs.exists("/pilot.lua"), "pilot.lua is there")
  check(fs.exists("/lib/hull.lua"), "and the library with it")
  check(fs.exists("/lib/cfg.lua"), "including the one the configurator needs")
  check(fs.exists(RECORD), "and it records what it put on")
end

do
  -- One file missing. Nothing at all is written, because a tree where pilot.lua
  -- is new and lib/hull.lua is old fails in ways that look like bugs in neither
  -- -- and on this program it fails in the air.
  local before = readFile("/lib/hull.lua")

  local r = runInstall{
    missing = { ["lib/flight.lua"] = true },
    args = { "install", "main", "Gizmo0320/CCprograms", "--yes" },
  }

  check(said(r, "Nothing was installed"), "a failed download installs nothing")
  check(said(r, "lib/flight.lua"), "and names the file that failed")
  check(readFile("/lib/hull.lua") == before, "leaving the working copy alone")
end

do
  local r = runInstall{
    missing = { ["manifest.txt"] = true },
    args = { "install", "main", "Gizmo0320/CCprograms", "--yes" },
  }
  check(said(r, "Could not fetch the file list"),
        "no manifest is a clear message rather than a stack trace")
end

--------------------------------------------------------------------------------
section("check, which writes nothing")
--------------------------------------------------------------------------------

do
  -- The installed version is read back out of the record the last install left.
  local r = runInstall{ args = { "check", "main", "Gizmo0320/CCprograms" } }
  check(r.crash == nil, "check runs", r.crash)
  check(said(r, "installed"), "and says what is on this computer")
  check(said(r, "available"), "and what is on the branch")
  check(said(r, "Up to date"), "and that they are the same", r.said:sub(-80))
end

do
  -- A newer version on the branch is the case the mode exists for.
  local r = runInstall{ remoteVersion = "9.9",
                        args = { "check", "main", "Gizmo0320/CCprograms" } }
  check(said(r, "An update is available"), "an older local version is noticed")
  check(said(r, "9.9"), "and the new one is named", r.said:sub(-80))
end

do
  -- A file deleted by hand is invisible from the version number, and is exactly
  -- the state that makes a program fail in a way nothing explains.
  local keep = readFile("/lib/terrain.lua")
  fs.delete("/lib/terrain.lua")

  local r = runInstall{ args = { "check", "main", "Gizmo0320/CCprograms" } }
  check(said(r, "missing from this computer"), "a missing file is reported")
  check(said(r, "lib/terrain.lua"), "and named")

  writeFile("/lib/terrain.lua", keep)
  check(fs.exists("/lib/terrain.lua"), "and the suite puts it back")
end

--------------------------------------------------------------------------------
section("orphans")
--------------------------------------------------------------------------------

do
  -- A file that used to be part of the program and is not any more. An orphaned
  -- lib/ module still sitting there is one `require` away from being loaded in
  -- preference to nothing at all -- which is how a deleted probe.lua could go on
  -- being run for weeks.
  writeFile("/test-orphan.lua", "-- left over from an older version\n")
  writeFile(RECORD, [[return { version = "1.0", branch = "main",
    repo = "Gizmo0320/CCprograms",
    files = { "test-orphan.lua", "pilot.lua" } }]])

  local r = runInstall{ args = { "update", "main", "Gizmo0320/CCprograms", "--yes" } }
  check(said(r, "not any more"), "an orphan is noticed")
  check(said(r, "test-orphan.lua"), "and named")
  check(not fs.exists("/test-orphan.lua"), "and deleted once you agree")
  check(fs.exists("/pilot.lua"), "while everything still in the manifest stays")
end

do
  -- Declined, because an orphan is harmless sitting there and deleting a file
  -- somebody has started keeping their own notes in would be a poor trade.
  writeFile("/test-orphan.lua", "-- mine now\n")
  writeFile(RECORD, [[return { version = "1.0", files = { "test-orphan.lua" } }]])

  os.queueEvent("char", "n")
  local r = runInstall{ args = { "update", "main", "Gizmo0320/CCprograms" } }
  check(fs.exists("/test-orphan.lua"), "and left alone if you say no")
  fs.delete("/test-orphan.lua")
end

--------------------------------------------------------------------------------
section("what it leaves alone, and what it hands over to")
--------------------------------------------------------------------------------

do
  -- The whole point of the rewrite. A fresh computer is installed and then
  -- handed to the configurator, because the installer no longer knows how to
  -- ask any of the questions itself.
  fresh()
  local r = runInstall{ args = { "install", "main", "Gizmo0320/CCprograms", "--yes" } }

  check(said(r, "set this computer up"), "a fresh install says what happens next")
  check(r.handedOff:find("configure", 1, true) ~= nil,
        "and hands over to the configurator", r.handedOff)
  check(r.handedOff:find("--wizard", 1, true) ~= nil,
        "in wizard mode, because nothing has been answered yet", r.handedOff)
  check(not said(r, "Network name?"),
        "and it never asks a configuration question itself")
end

do
  -- An update on a computer somebody has already set up asks nothing and
  -- changes nothing about it. Dropping a working tower into a wizard because it
  -- fetched a new pilot.lua would be an unpleasant surprise.
  writeFile(OVERRIDES, 'return { role = "server", channel = 4300, '
    .. 'protocol = "north", configured = "1.0" }')

  local r = runInstall{ args = { "update", "main", "Gizmo0320/CCprograms", "--yes" } }
  check(said(r, "left alone"), "an update leaves your settings alone")
  check(r.handedOff == "", "and does not run the configurator", r.handedOff)

  local values = loadfile(OVERRIDES)()
  check(values.channel == 4300 and values.protocol == "north",
        "and the file is untouched", values.channel)
end

do
  -- The three files nobody downloaded. A hull tuned over an evening is worth
  -- more than the program, and none of them are in manifest.txt for exactly
  -- this reason.
  writeFile("/craft.cfg", "-- mine\nreturn { controls = {}, mix = {} }\n")
  local before = readFile("/craft.cfg")

  runInstall{ args = { "update", "main", "Gizmo0320/CCprograms", "--yes" } }
  check(readFile("/craft.cfg") == before, "an update never touches /craft.cfg")

  fs.delete("/craft.cfg")
end

--------------------------------------------------------------------------------
section("uninstall")
--------------------------------------------------------------------------------

do
  -- Driven against a record naming throwaway files, because a real uninstall
  -- would delete the tree the suite is running from.
  writeFile("/test-gone-a.lua", "-- a\n")
  writeFile("/test-gone-b.lua", "-- b\n")
  writeFile(RECORD, [[return { version = "1.1",
    files = { "test-gone-a.lua", "test-gone-b.lua" } }]])

  fs.delete(OVERRIDES)
  fs.delete("/craft.cfg")

  local r = runInstall{ args = { "uninstall", "--yes" } }
  check(said(r, "Removed"), "uninstall says what it removed")
  check(not fs.exists("/test-gone-a.lua"), "and the files are gone")
  check(not fs.exists("/test-gone-b.lua"), "all of them")
  check(not fs.exists(RECORD), "and the record with them")
  check(fs.exists("/pilot.lua"),
        "while anything it never installed is left where it is")
end

do
  -- Your own files are asked about separately and last.
  writeFile("/craft.cfg", "-- mine\nreturn { controls = {}, mix = {} }\n")
  writeFile("/test-gone-c.lua", "-- c\n")
  writeFile(RECORD, [[return { version = "1.1", files = { "test-gone-c.lua" } }]])

  -- Yes to removing the program, no to removing the hull.
  os.queueEvent("char", "y")
  os.queueEvent("char", "n")
  local r = runInstall{ args = { "uninstall" } }

  check(not fs.exists("/test-gone-c.lua"), "the program goes")
  check(said(r, "left alone"), "and your own files are listed as kept")
  check(fs.exists("/craft.cfg"),
        "and a hull tuned over an evening survives saying no")

  fs.delete("/craft.cfg")
  fs.delete("/test-gone-c.lua")
end

do
  local r = runInstall{ args = { "uninstall", "--yes" } }
  check(said(r, "Nothing here was installed"),
        "uninstalling with no record says so rather than guessing at files")
end

--------------------------------------------------------------------------------

-- Put the tree back the way the other suites expect to find it, and leave no
-- overrides file behind: lib/config is already loaded and would not read it now,
-- but the next run of the whole suite would.
fs.delete(OVERRIDES)
fs.delete(RECORD)
fs.delete("/craft.cfg")
os.setComputerLabel(realLabel)

say("")
say(("%d passed, %d failed"):format(pass, fail))

_G.AERO_TOTALS = _G.AERO_TOTALS or {}
_G.AERO_TOTALS.install = { pass = pass, fail = fail }
