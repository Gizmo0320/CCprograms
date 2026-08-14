--- Installer. Run this on a fresh computer or pocket computer:
--
--   wget run https://raw.githubusercontent.com/Gizmo0320/CCprograms/main/aero/install.lua
--
--   install                 install, or update if it is already here
--   install check           say what is here and what is available, write nothing
--   install update          fetch the current version, keeping every config file
--   install uninstall       remove the program, and ask about the config files
--
--   install <mode> <branch> <owner/repo>
--   install --yes           answer every prompt yes, for an unattended run
--
-- ## What it does not do any more
--
-- It does not ask a single question about the network, the channel, the role or
-- the name. It used to ask all four, `configure` also asked all four, and the
-- two wrote the file in different shapes -- so which of them you had run last
-- decided what your computer thought it was.
--
-- An installer installs. `configure` configures, and this hands over to it at
-- the end of a fresh install, which is also what `startup.lua` does when it
-- finds a computer that has never been set up. There is one way to answer those
-- questions and one file they land in.
--
-- ## What it keeps
--
-- Downloads everything before writing anything. A half-installed tree where
-- pilot.lua is new and lib/hull.lua is old fails in ways that look like bugs in
-- neither, and on this program it fails in the air. Writes beside each target
-- and moves into place, so an interrupted write leaves the old working copy
-- rather than half a file. Never touches /aero.cfg, /craft.cfg or /beacon.cfg,
-- none of which are in manifest.txt for exactly that reason.

local args = { ... }

--------------------------------------------------------------------------------
-- Arguments
--------------------------------------------------------------------------------

local MODES = { check = true, install = true, update = true, uninstall = true }

local MODE, YES = nil, false
local positional = {}

for _, a in ipairs(args) do
  if a == "--yes" or a == "-y" then YES = true
  elseif MODES[a:lower()] and not MODE then MODE = a:lower()
  elseif a ~= "" and not a:match("^%-") then positional[#positional + 1] = a end
end

local BRANCH = positional[1] or "main"
local REPO   = positional[2] or "Gizmo0320/CCprograms"
local BASE   = ("https://raw.githubusercontent.com/%s/%s/aero/"):format(REPO, BRANCH)

-- What was installed last time: the version and the file list. Kept so an
-- update can delete the files that used to be part of the program and are not
-- any more -- an orphaned lib/ module still sitting there is one `require` away
-- from being loaded in preference to nothing at all.
local RECORD = "/aero.install"

--------------------------------------------------------------------------------
-- Screen
--------------------------------------------------------------------------------

local function colour(c)
  if term.isColour and term.isColour() then term.setTextColour(c) end
end

local function say(text, c)
  colour(c or colours.white)
  print(text)
  colour(colours.white)
end

local function rule()
  local w = term.getSize()
  colour(colours.grey)
  print(string.rep("-", w))
  colour(colours.white)
end

--- A progress bar on the bottom line, and the cursor put back where it was.
--
-- On the bottom line rather than inline because the file list scrolls: a bar
-- that scrolls with it is a bar you cannot find, and one redrawn per file is
-- most of the screen by the end.
local function progress(done, total, label)
  local w, h = term.getSize()
  local x, y = term.getCursorPos()

  local filled = math.floor((done / math.max(1, total)) * w + 0.5)
  local text = (" %d%%  %s"):format(math.floor(done / math.max(1, total) * 100),
                                    label or "")
  if #text > w then text = text:sub(1, w) end
  text = text .. string.rep(" ", w - #text)

  for i = 1, w do
    term.setCursorPos(i, h)
    if term.isColour and term.isColour() then
      term.setBackgroundColour(i <= filled and colours.lightBlue or colours.grey)
      term.setTextColour(i <= filled and colours.black or colours.white)
    end
    term.write(text:sub(i, i))
  end

  if term.isColour and term.isColour() then
    term.setBackgroundColour(colours.black)
    term.setTextColour(colours.white)
  end
  term.setCursorPos(x, y)
end

local function clearProgress()
  local w, h = term.getSize()
  local x, y = term.getCursorPos()
  term.setCursorPos(1, h)
  term.write(string.rep(" ", w))
  term.setCursorPos(x, y)
end

--- A yes/no question that an unattended run can answer.
local function confirm(question)
  if YES then return true end
  say(question .. " (y/N)", colours.yellow)
  while true do
    local event, key = os.pullEvent()
    if event == "char" then return key == "y" or key == "Y" end
    if event == "key" and key == keys.enter then return false end
    if event == "terminate" then return false end
  end
end

--------------------------------------------------------------------------------
-- Fetching
--------------------------------------------------------------------------------

--- Fetch a file, with retries.
--
-- The cache buster matters: raw.githubusercontent serves a cached copy for a few
-- minutes, and reinstalling to pick up a fix you just pushed only to be handed
-- the old file is a genuinely baffling way to lose an afternoon.
--
-- Retried three times because the failure this sees most is a single request
-- timing out under load, and failing the whole install for it means starting
-- over from the beginning.
local function fetch(path, attempts)
  local why
  for _ = 1, attempts or 3 do
    local url = BASE .. path .. "?nocache=" .. tostring(math.random(1, 1e9))
    local res, err = http.get(url)

    if res then
      local body = res.readAll()
      res.close()
      if body and #body > 0 then return body end
      why = "empty file"
    else
      why = tostring(err or "no response")
    end
  end
  return nil, why
end

local function writeFile(path, body)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end

  local tmp = path .. ".part"
  local file = fs.open(tmp, "w")
  if not file then return false, "cannot write " .. tmp end
  file.write(body)
  file.close()

  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp, path)
  return true
end

--- Parse manifest.txt into a file list and whatever version it declares.
--
-- The version rides in a comment so the manifest stays exactly the plain list of
-- paths that `test/spec.lua` checks against the tree in both directions.
local function parseManifest(body)
  local files, version = {}, nil

  for line in body:gmatch("[^\r\n]+") do
    local declared = line:match("^#%s*version%s+([%w%.%-]+)")
    if declared then version = declared end

    line = line:match("^%s*(.-)%s*$")
    if line ~= "" and not line:match("^#") then files[#files + 1] = line end
  end

  return files, version
end

--------------------------------------------------------------------------------
-- What is here already
--------------------------------------------------------------------------------

local function readRecord()
  if not fs.exists(RECORD) then return nil end
  local fn = loadfile(RECORD)
  if not fn then return nil end
  local ok, value = pcall(fn)
  if ok and type(value) == "table" then return value end
  return nil
end

local function writeRecord(version, files)
  local out = {
    "-- What `install` last put on this computer.",
    "--",
    "-- Read by the installer to work out which files used to be part of the",
    "-- program and are not any more. Not in manifest.txt, and safe to delete --",
    "-- losing it only costs the next update its orphan cleanup.",
    "",
    "return {",
    ("  version = %q,"):format(version or "unknown"),
    ("  branch  = %q,"):format(BRANCH),
    ("  repo    = %q,"):format(REPO),
    "  files = {",
  }
  for _, path in ipairs(files) do
    out[#out + 1] = ("    %q,"):format(path)
  end
  out[#out + 1] = "  },"
  out[#out + 1] = "}"

  local f = fs.open(RECORD, "w")
  if not f then return false end
  for _, line in ipairs(out) do f.writeLine(line) end
  f.close()
  return true
end

--- The version currently on this computer, read out of the installed config.
local function localVersion()
  if not fs.exists("/lib/config.lua") then return nil end
  local record = readRecord()
  if record and record.version and record.version ~= "unknown" then
    return record.version
  end

  local fn = loadfile("/lib/config.lua")
  if not fn then return nil end
  local ok, value = pcall(fn)
  if ok and type(value) == "table" then return value.version end
  return nil
end

--------------------------------------------------------------------------------

term.clear()
term.setCursorPos(1, 1)
say("Aeronautics flight network installer", colours.cyan)
say(REPO .. " @ " .. BRANCH, colours.grey)
rule()

if not http then
  say("The HTTP API is disabled.", colours.red)
  say("Enable http in the ComputerCraft config and try again.", colours.white)
  return
end

local installed = localVersion()

--------------------------------------------------------------------------------
-- Uninstall
--------------------------------------------------------------------------------

if MODE == "uninstall" then
  local record = readRecord()
  if not record then
    say("Nothing here was installed by this installer.", colours.orange)
    say("Delete the files by hand if you want them gone.", colours.white)
    return
  end

  -- `files` defaulted rather than indexed straight: a record written by an
  -- older version, or edited by hand, is a table this has to survive reading.
  record.files = record.files or {}

  say(("About to remove %d file(s) of aero %s.")
    :format(#record.files, record.version or "?"), colours.orange)

  if not confirm("Remove the program?") then
    say("Left alone.", colours.lime)
    return
  end

  local gone = 0
  for _, path in ipairs(record.files) do
    if fs.exists("/" .. path) then
      fs.delete("/" .. path)
      gone = gone + 1
    end
  end
  fs.delete(RECORD)
  say(("Removed %d file(s)."):format(gone), colours.lime)

  -- Asked separately and last, because these are the only files here that
  -- somebody made rather than downloaded. A hull tuned over an evening is worth
  -- more than the program, and it is one keypress from being gone.
  local mine = {}
  for _, path in ipairs({ "/aero.cfg", "/craft.cfg", "/beacon.cfg",
                          "/aero.state", "/fleet.state" }) do
    if fs.exists(path) then mine[#mine + 1] = path end
  end

  if #mine > 0 then
    print()
    say("These are yours, and were left alone:", colours.cyan)
    for _, path in ipairs(mine) do say("  " .. path, colours.white) end
    if confirm("Delete these too?") then
      for _, path in ipairs(mine) do fs.delete(path) end
      say("Deleted.", colours.lime)
    end
  end
  return
end

--------------------------------------------------------------------------------
-- The manifest
--------------------------------------------------------------------------------

say("Fetching the file list...", colours.lightGrey)

local manifest, why = fetch("manifest.txt")
if not manifest then
  say("Could not fetch the file list: " .. why, colours.red)
  say("Check the branch name and that the repo is public.", colours.white)
  return
end

local files, available = parseManifest(manifest)

if #files == 0 then
  say("The manifest is empty. Nothing to install.", colours.red)
  return
end

print()
say(("installed  %s"):format(installed or "nothing"),
    installed and colours.cyan or colours.grey)
say(("available  %s"):format(available or "?"), colours.cyan)
say(("files      %d"):format(#files), colours.grey)

--------------------------------------------------------------------------------
-- Check
--------------------------------------------------------------------------------

if MODE == "check" then
  print()
  if not installed then
    say("Not installed here. Run `install` to put it on.", colours.orange)
  elseif installed == available then
    say("Up to date.", colours.lime)
  else
    say(("An update is available: %s -> %s"):format(installed, available),
        colours.orange)
  end

  -- Said even when up to date: a file deleted by hand is invisible from the
  -- version number, and it is exactly the state that makes a program fail in a
  -- way nothing explains.
  local missing = {}
  for _, path in ipairs(files) do
    if not fs.exists("/" .. path) then missing[#missing + 1] = path end
  end
  if #missing > 0 then
    print()
    say(("%d file(s) missing from this computer:"):format(#missing), colours.red)
    for _, path in ipairs(missing) do say("  " .. path, colours.white) end
    say("Run `install` to put them back.", colours.white)
  end
  return
end

--------------------------------------------------------------------------------
-- Install and update
--------------------------------------------------------------------------------

local fresh = (installed == nil)

if MODE == "update" and fresh then
  say("Nothing is installed here, so this is an install.", colours.orange)
end

print()

local bodies, failed = {}, {}
for i, path in ipairs(files) do
  progress(i - 1, #files, path)

  local body, err = fetch(path)
  if body then
    bodies[path] = body
  else
    failed[#failed + 1] = path .. " (" .. err .. ")"
  end
end

progress(#files, #files, "done")

if #failed > 0 then
  clearProgress()
  print()
  say("Nothing was installed. These could not be downloaded:", colours.red)
  for _, f in ipairs(failed) do say("  " .. f, colours.white) end
  say("Nothing on this computer was changed.", colours.white)
  return
end

for _, path in ipairs(files) do
  local ok, err = writeFile("/" .. path, bodies[path])
  if not ok then
    clearProgress()
    say("Could not write " .. path .. ": " .. tostring(err), colours.red)
    return
  end
end

clearProgress()
say(("Installed %d file(s), version %s."):format(#files, available or "?"),
    colours.lime)

--------------------------------------------------------------------------------
-- Orphans
--------------------------------------------------------------------------------

local previous = readRecord()
if previous then
  local wanted = {}
  for _, path in ipairs(files) do wanted[path] = true end

  local orphans = {}
  for _, path in ipairs(previous.files or {}) do
    if not wanted[path] and fs.exists("/" .. path) then
      orphans[#orphans + 1] = path
    end
  end

  if #orphans > 0 then
    print()
    say("These were part of the program and are not any more:", colours.orange)
    for _, path in ipairs(orphans) do say("  " .. path, colours.white) end

    -- Worth asking rather than doing. An orphan is harmless sitting there, and
    -- deleting a file somebody has started keeping their own notes in would be
    -- a poor trade for the tidiness.
    if confirm("Delete them?") then
      for _, path in ipairs(orphans) do fs.delete("/" .. path) end
      say(("Deleted %d."):format(#orphans), colours.lime)
    end
  end
end

writeRecord(available, files)

--------------------------------------------------------------------------------
-- Hand over
--------------------------------------------------------------------------------

print()

local configured = fs.exists("/aero.cfg")

if configured then
  -- An update on a computer somebody has already set up asks nothing and
  -- changes nothing about it. Dropping a working tower into a wizard because it
  -- fetched a new pilot.lua would be an unpleasant surprise.
  say("Your settings were left alone.", colours.lime)
  say("Run `configure` to change them, or reboot to start.", colours.white)
  return
end

say("Now to set this computer up.", colours.cyan)
say("It will ask what this computer is, which network", colours.white)
say("it is on, and -- on a ship -- which bearing holds", colours.white)
say("it up. Nothing is written until the end.", colours.white)
print()

if not YES then
  say("Press a key to start, or Q to do it later.", colours.yellow)
  local timer = os.startTimer(20)
  while true do
    local event, a = os.pullEvent()
    if event == "char" then
      if a == "q" or a == "Q" then
        say("Run `configure` when you are ready.", colours.white)
        return
      end
      break
    elseif event == "key" and a == keys.enter then
      break
    elseif event == "timer" and a == timer then
      -- Bounded, so installing across a row of computers is scriptable. A
      -- prompt that waits forever turns that into a row of computers sitting at
      -- a question nobody is there to answer.
      break
    elseif event == "terminate" then
      return
    end
  end
end

shell.run("/configure.lua", "--wizard")
