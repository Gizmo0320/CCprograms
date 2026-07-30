--- Mining remote. Runs on an advanced pocket computer.
--
-- The thing you carry: see the fleet, deploy work, manage the queue. It holds
-- no authoritative state of its own and never guesses -- if a turtle has gone
-- quiet it says so rather than showing stale numbers as though they were live.
--
-- Two routes, and the header always says which one is in use:
--
--   SERVER  the fleet server is answering. Commands and jobs go through it, so
--           the queue and the roster survive the pocket being put away.
--   DIRECT  no server in range. The roster is assembled from turtle heartbeats
--           and commands go straight to the turtle, which is exactly what this
--           program did before there was a server. A dead server must never
--           mean an unrecallable turtle.

local config = require("lib.config")
local specs  = require("lib.specs")
local net    = require("lib.net")

local W, H = term.getSize()

--------------------------------------------------------------------------------
-- Link
--------------------------------------------------------------------------------

local link = {
  modem   = nil,
  server  = nil,            -- id of the fleet server, if one is answering
  fleet   = nil,            -- its last broadcast
  seenAt  = -math.huge,     -- when that arrived
  turtles = {},             -- [id] = status, for direct mode
  heard   = {},             -- [id] = os.clock() of its last heartbeat
  note    = nil,      -- set below, once config.protocol is known
}

-- Which fleet this pocket is on. Two fleets in one world are only separated by
-- the protocol string, so when nothing answers it matters a great deal whether
-- you are on the one you think you are.
link.note = ("fleet '%s': looking..."):format(config.protocol)

local function openModem() return net.open() end

local function haveServer()
  return link.server ~= nil and (os.clock() - link.seenAt) < config.heartbeatTimeout
end

local function toServer(msg)
  if link.server then net.send(link.server, msg) end
end

local function toTurtle(id, msg)
  if id then net.send(id, msg) else net.broadcast(msg) end
end

--- One roster shape whichever route is live, so the fleet table is drawn from
--- the same rows either way.
local function roster()
  if haveServer() and link.fleet then return link.fleet.turtles or {} end

  local list, now = {}, os.clock()
  for id, s in pairs(link.turtles) do
    local stale = (now - (link.heard[id] or -math.huge)) > config.heartbeatTimeout
    list[#list + 1] = {
      id = id, label = s.label, stale = stale, role = s.role or "miner",
      state = stale and "lost" or s.state, fuel = s.fuel, mined = s.mined,
      progress = s.progress, pattern = s.pattern, pos = s.pos, jobId = s.jobId,
    }
  end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end

local function jobs()
  if haveServer() and link.fleet then return link.fleet.jobs or {} end
  return {}
end

--------------------------------------------------------------------------------
-- Selection and job configuration
--------------------------------------------------------------------------------

local screen  = "fleet"                     -- fleet | deploy | queue
local target  = nil                         -- turtle id, or nil meaning ALL
local anchor  = nil                         -- {x,y,z} for a placed job
local lanes   = 1

local sel = { pattern = 1, values = {} }

-- Inline entry: { key = <param>, text = "42", kind = "number"|"text" } while
-- something is being typed. Deliberately not read(), which blocks the event
-- loop -- heartbeats would stop arriving and the link would read LOST while
-- you type.
--
-- `kind` decides which characters are accepted. Parameters take digits; a
-- turtle's name takes letters too, which is the whole point of naming it.
local editing = nil

local EDIT_PATTERN = { number = "%d", text = "[%w%-_ ]" }
local EDIT_LIMIT   = { number = 4, text = 12 }

local function currentPattern()
  return specs.get(specs.order[sel.pattern])
end

local function resetValues()
  sel.values = {}
  for _, spec in ipairs(currentPattern().params) do
    sel.values[spec.key] = spec.default
  end
end

local function cyclePattern(delta)
  sel.pattern = ((sel.pattern - 1 + delta) % #specs.order) + 1
  editing = nil
  resetValues()
end

local function clamp(spec, v)
  return math.max(spec.min, math.min(spec.max, math.floor(v)))
end

local function adjust(spec, delta)
  editing = nil
  sel.values[spec.key] = clamp(spec, (sel.values[spec.key] or spec.default) + delta)
end

local LANE_SPEC = { key = "__lanes", label = "Lanes", default = 1, min = 1, max = 16 }

local function paramSpec(key)
  if key == LANE_SPEC.key then return LANE_SPEC end
  for _, p in ipairs(currentPattern().params) do
    if p.key == key then return p end
  end
end

--- Accept whatever has been typed, clamped to the parameter's range. An empty
--- or unparseable entry leaves the old value alone rather than guessing.
local function commitEdit()
  if not editing then return end

  if editing.kind == "text" then
    -- Renaming is handled by the caller through onCommit, because it has to go
    -- out on the wire rather than into a local table.
    local text = editing.text:match("^%s*(.-)%s*$")
    local done = editing.onCommit
    editing = nil
    if done and text ~= "" then done(text) end
    return
  end

  local spec = paramSpec(editing.key)
  local v = tonumber(editing.text)
  if spec and v then
    if spec == LANE_SPEC then lanes = clamp(spec, v)
    else sel.values[spec.key] = clamp(spec, v) end
  end
  editing = nil
end

resetValues()

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

local regions = {}                 -- click targets rebuilt on every draw
local flash                        -- transient message {text, colour, until_}
local armedAbort = 0               -- abort needs two presses

local function setColours(fg, bg)
  term.setTextColour(fg or colours.white)
  term.setBackgroundColour(bg or colours.black)
end

local function at(x, y, text, fg, bg)
  setColours(fg, bg)
  term.setCursorPos(x, y)
  term.write(tostring(text):sub(1, math.max(0, W - x + 1)))
  setColours()
end

local function rule(y) at(1, y, string.rep("-", W), colours.grey) end

local function region(x1, x2, y, fn)
  regions[#regions + 1] = { x1 = x1, x2 = x2, y = y, fn = fn }
end

local function button(x, y, width, label, bg, fg, fn)
  local pad  = math.max(0, width - #label)
  local left = math.floor(pad / 2)
  at(x, y, string.rep(" ", left) .. label .. string.rep(" ", pad - left), fg, bg)
  region(x, x + width - 1, y, fn)
end

local function flashNow(text, colour, seconds)
  flash = { text = text, colour = colour, until_ = os.clock() + (seconds or 2) }
end

local STATE_COLOUR = {
  idle = colours.lightGrey, mining = colours.lime, paused = colours.yellow,
  returning = colours.cyan, done = colours.lime, error = colours.red,
  lost = colours.red,
}

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

--- Route a command. Through the server when there is one so it can keep the
--- queue straight; straight at the turtle when there is not.
local function command(action)
  if haveServer() then
    toServer({ type = "command", target = target or "all", action = action })
    return ("%s -> server"):format(action)
  end

  if target then
    toTurtle(target, { type = action })
    return ("%s -> turtle %d"):format(action, target)
  end

  local n = 0
  for _, r in ipairs(roster()) do
    toTurtle(r.id, { type = action })
    n = n + 1
  end
  return ("%s -> %d turtle(s)"):format(action, n)
end

--- Rename one turtle. Same routing as any other command, but never "all":
--- naming every turtle the same defeats the purpose of naming them.
local function rename(id, name)
  if not id then return "pick a turtle first" end

  if haveServer() then
    toServer({ type = "command", target = id, action = "rename", name = name })
  else
    toTurtle(id, { type = "rename", name = name })
  end
  return ("named #%d %s"):format(id, name)
end

local function submit()
  local pattern = currentPattern()

  if haveServer() then
    if not anchor then
      flashNow("set an anchor first", colours.orange, 3)
      return
    end
    local params = {}
    for k, v in pairs(sel.values) do params[k] = v end
    toServer({ type = "submit", pattern = pattern.name, params = params,
               anchor = anchor, lanes = lanes })
    flashNow(("submitted %s x%d"):format(pattern.name, lanes), colours.lime)
    return
  end

  -- Direct: no server to split anything, so this is the old single relative
  -- job. Say so rather than silently dropping the lane count.
  if not target then
    flashNow("pick a turtle first", colours.orange, 3)
    return
  end
  local msg = { type = "start", pattern = pattern.name }
  for k, v in pairs(sel.values) do msg[k] = v end
  toTurtle(target, msg)
  flashNow(lanes > 1 and "direct: 1 lane only" or "start sent",
    lanes > 1 and colours.orange or colours.lime)
end

--------------------------------------------------------------------------------
-- Header, shared by every screen
--------------------------------------------------------------------------------

local TABS = { { "fleet", "FLEET" }, { "deploy", "DEPLOY" }, { "queue", "QUEUE" } }

local function drawHeader()
  local x = 1
  for _, tab in ipairs(TABS) do
    local here = (screen == tab[1])
    button(x, 1, #tab[2], tab[2],
      here and colours.cyan or colours.black,
      here and colours.black or colours.grey,
      function() screen = tab[1] editing = nil end)
    x = x + #tab[2] + 1
  end

  if haveServer() then
    at(W - 5, 1, "SERVR", colours.black, colours.lime)
  else
    at(W - 5, 1, "DIRCT", colours.white, colours.orange)
  end
  rule(2)
end

--- The one line at the bottom of every screen that is not a button.
local function drawFooter(y, text, colour)
  if y > H then return end
  rule(y)
  if y + 1 <= H then at(1, y + 1, text, colour or colours.grey) end
end

local function statusLine(y)
  if flash and os.clock() < flash.until_ then
    at(1, y, flash.text, flash.colour)
  else
    at(1, y, link.note, colours.grey)
  end
end

--------------------------------------------------------------------------------
-- FLEET
--------------------------------------------------------------------------------

local function drawFleet()
  local y = 3
  local list = roster()

  at(1, y, "ID  LABEL   *STATE   PROG", colours.lightGrey); y = y + 1

  -- Six rows are reserved below for the target line, the buttons, the status
  -- line and the footer; the roster gets whatever is left.
  local rows = H - 10
  if #list == 0 then
    at(1, y, haveServer() and "server reports no turtles"
      or "no turtles heard from", colours.grey)
    y = y + 1
  end

  for i = 1, math.min(#list, rows) do
    local r = list[i]
    local chosen = (target == r.id)
    local fg = chosen and colours.black or colours.white
    local bg = chosen and colours.blue or colours.black

    at(1, y, ("%-3d %-8s"):format(r.id, (r.label or "-"):sub(1, 8)), fg, bg)
    -- One column for the role: on a 26 wide screen there is no room for a word,
    -- and which turtle is the scout is the only thing you need at a glance.
    at(13, y, (r.role == "scout") and "S" or " ",
      chosen and colours.black or colours.magenta, bg)
    at(14, y, ("%-7s"):format((r.state or "-"):sub(1, 7)),
      chosen and colours.black or (STATE_COLOUR[r.state] or colours.white), bg)
    at(22, y, r.progress and ("%3d%%"):format(math.floor(r.progress * 100 + 0.5))
      or "   -", fg, bg)

    -- Tapping a row targets that turtle; tapping it again goes back to ALL, so
    -- there is always a way out of a selection without hunting for a button.
    local id = r.id
    region(1, W, y, function() target = (target == id) and nil or id end)
    y = y + 1
  end

  if #list > rows then
    at(1, y, ("...and %d more"):format(#list - rows), colours.grey)
    y = y + 1
  end

  y = H - 6
  rule(y); y = y + 1

  if editing and editing.kind == "text" then
    -- The name entry takes over this row while it is open. There is no space on
    -- 26 columns for a field beside the buttons, and nothing else on this row is
    -- any use while you are typing anyway.
    at(1, y, "Name", colours.lightGrey)
    at(6, y, editing.text .. "_", colours.yellow)
    at(W - 8, y, "enter=ok", colours.grey)
  else
    at(1, y, target and ("#" .. target) or "ALL",
      target and colours.white or colours.yellow)
    button(6, y, 4, "ALL", target and colours.grey or colours.blue, colours.white,
      function() target = nil end)

    -- Naming one turtle at a time is the point; naming them all the same is not.
    button(11, y, 5, "NAME", target and colours.blue or colours.grey, colours.white,
      function()
        if not target then
          flashNow("pick a turtle to name", colours.orange, 3)
          return
        end
        editing = {
          kind = "text", text = "",
          onCommit = function(name) flashNow(rename(target, name), colours.cyan) end,
        }
      end)

    -- Safe to leave unguarded: a turtle refuses an update while it is working,
    -- so the worst this can do is reboot the idle half of the fleet.
    button(17, y, 8, "UPDATE", colours.brown, colours.white, function()
      flashNow(command("update"), colours.cyan, 4)
    end)
  end
  y = y + 1

  local half = math.floor((W - 1) / 2)
  local rightX = half + 2

  button(1, y, half, "PAUSE", colours.blue, colours.white, function()
    flashNow(command("pause"), colours.yellow)
  end)
  button(rightX, y, half, "RESUME", colours.green, colours.white, function()
    flashNow(command("resume"), colours.lime)
  end)
  y = y + 1

  local arming = os.clock() < armedAbort
  button(1, y, half, arming and "SURE?" or "ABORT",
    arming and colours.red or colours.brown, colours.white, function()
      if os.clock() < armedAbort then
        armedAbort = 0
        flashNow(command("abort"), colours.red)
      else
        armedAbort = os.clock() + 3
        flashNow("press again to abort", colours.red, 3)
      end
    end)
  button(rightX, y, half, "RECALL", colours.magenta, colours.white, function()
    flashNow(command("return"), colours.magenta)
  end)
  y = y + 1

  statusLine(y)
  drawFooter(y + 1, "tab p/r/a/c n name u upd q")
end

--------------------------------------------------------------------------------
-- DEPLOY
--------------------------------------------------------------------------------

--- Stamp the pocket's own position as the corner a job extends from.
--
-- gps.locate needs only a wireless modem, so the pocket can fix itself: walk to
-- the corner and press SET. It blocks for its timeout, which is why the timeout
-- is short -- heartbeats stop arriving while it runs.
local function setAnchor()
  local x, y, z = gps.locate(1)
  if not x then
    anchor = nil
    flashNow("no gps fix here", colours.red, 3)
    return
  end
  anchor = { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
  flashNow(("anchor %d,%d,%d"):format(anchor.x, anchor.y, anchor.z), colours.lime)
end

local function numberRow(y, label, value, spec, get, set)
  at(1, y, ("%-7s"):format(label:sub(1, 7)), colours.lightGrey)
  button(9,  y, 2, "--", colours.grey, colours.white, function() set(get() - 10) end)
  button(12, y, 1, "-",  colours.grey, colours.white, function() set(get() - 1) end)

  if editing and editing.key == spec.key then
    at(14, y, ("%-4s"):format(editing.text .. "_"), colours.yellow)
  else
    at(14, y, ("%4d"):format(value), colours.white)
  end
  region(14, 17, y, function()
    editing = { key = spec.key, text = "", kind = "number" }
  end)

  button(19, y, 1, "+",  colours.grey, colours.white, function() set(get() + 1) end)
  button(21, y, 2, "++", colours.grey, colours.white, function() set(get() + 10) end)
end

local function drawDeploy()
  local y = 3
  local pattern = currentPattern()

  at(1, y, "Anchor", colours.lightGrey)
  at(8, y, anchor and ("%d,%d,%d"):format(anchor.x, anchor.y, anchor.z) or "not set",
    anchor and colours.white or colours.orange)
  button(W - 4, y, 5, "SET", colours.grey, colours.white, setAnchor)
  y = y + 1

  at(1, y, "Mode", colours.lightGrey)
  button(7, y, 1, "<", colours.grey, colours.white, function() cyclePattern(-1) end)
  at(9, y, ("%-10s"):format(pattern.name:sub(1, 10)), colours.yellow)
  button(20, y, 1, ">", colours.grey, colours.white, function() cyclePattern(1) end)
  y = y + 1

  for _, spec in ipairs(pattern.params) do
    numberRow(y, spec.label, sel.values[spec.key], spec,
      function() return sel.values[spec.key] or spec.default end,
      function(v) sel.values[spec.key] = clamp(spec, v) end)
    y = y + 1
  end

  numberRow(y, LANE_SPEC.label, lanes, LANE_SPEC,
    function() return lanes end,
    function(v) lanes = clamp(LANE_SPEC, v) end)
  y = y + 1

  rule(y); y = y + 1

  -- What this will cost, before committing to it.
  local est = specs.estimate(pattern, sel.values)
  if est then
    at(1, y, ("%d blocks  ~%d fuel"):format(est.cells, est.fuel + config.fuelMargin),
      colours.lightGrey)
    y = y + 1
    if lanes > 1 then
      local each = math.floor(est.fuel / lanes) + config.fuelMargin
      at(1, y, ("%d lanes, ~%d fuel each"):format(lanes, each), colours.lightGrey)
    else
      at(1, y, haveServer() and "one turtle" or "direct: one turtle", colours.grey)
    end
    y = y + 1
  else
    at(1, y, "parameters are not valid", colours.red); y = y + 2
  end

  rule(y); y = y + 1

  local half = math.floor((W - 1) / 2)
  button(1, y, half, "SUBMIT", colours.green, colours.white, submit)
  button(half + 2, y, half, "RESET", colours.grey, colours.white, function()
    resetValues() lanes = 1 editing = nil
    flashNow("reset", colours.grey)
  end)
  y = y + 1

  statusLine(y)
  drawFooter(y + 1, "tab  s submit  q quit")
end

--------------------------------------------------------------------------------
-- QUEUE
--------------------------------------------------------------------------------

local function drawQueue()
  local y = 3

  if not haveServer() then
    at(1, y, "No server.", colours.orange); y = y + 1
    at(1, y, "The queue lives on the fleet", colours.grey); y = y + 1
    at(1, y, "server. Without one, jobs go", colours.grey); y = y + 1
    at(1, y, "straight to a turtle and are", colours.grey); y = y + 1
    at(1, y, "not remembered anywhere.", colours.grey); y = y + 1
    statusLine(H - 2)
    drawFooter(H - 1, "tab  q quit")
    return
  end

  local list = jobs()
  local counts = link.fleet and link.fleet.counts or {}
  at(1, y, ("%d pending  %d running"):format(counts.pending or 0, counts.running or 0),
    colours.lightGrey)
  y = y + 1

  if #list == 0 then
    at(1, y, "nothing queued", colours.grey); y = y + 1
  end

  local rows = H - 5
  for i = 1, math.min(#list, rows) do
    local job = list[i]
    local lane = (job.lanes and job.lanes > 1)
      and ("%d/%d"):format(job.lane, job.lanes) or ""
    at(1, y, ("%-4s %-7s"):format(job.id, (job.pattern or "?"):sub(1, 7)))
    at(14, y, ("%-8s"):format(job.state or "?"),
      job.state == "running" and colours.lime or colours.lightGrey)
    at(23, y, lane, colours.grey)

    local id = job.id
    region(1, W, y, function()
      toServer({ type = "cancel", jobId = id })
      flashNow("cancelling " .. id, colours.orange)
    end)
    y = y + 1
  end

  if #list > rows then
    at(1, y, ("...and %d more"):format(#list - rows), colours.grey)
  end

  statusLine(H - 2)
  drawFooter(H - 1, "tab  tap a job to cancel")
end

--------------------------------------------------------------------------------

local function draw()
  regions = {}
  term.setBackgroundColour(colours.black)
  term.clear()
  drawHeader()

  if screen == "fleet" then drawFleet()
  elseif screen == "deploy" then drawDeploy()
  else drawQueue() end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local function handleMessage(id, msg)
  if type(msg) ~= "table" or type(msg.type) ~= "string" then return end

  if msg.type == "fleet" then
    link.server = id
    link.fleet  = msg
    link.seenAt = os.clock()
    link.note   = ("server %d  %d turtles"):format(id, #(msg.turtles or {}))

  elseif msg.type == "status" and msg.id then
    -- Kept even when a server is answering: if it goes quiet mid-session the
    -- roster is already populated and DIRECT works immediately.
    link.turtles[id] = msg
    link.heard[id]   = os.clock()
    if not haveServer() then
      link.note = ("direct: %d turtle(s)"):format(#roster())
    end

  elseif msg.type == "error" then
    flashNow(tostring(msg.reason), colours.red, 5)

  elseif msg.type == "ack" then
    link.note = "ack: " .. tostring(msg.of)
  end
end

local function handleClick(x, y)
  -- Any click banks a pending edit first, so tapping away from a half-typed
  -- number keeps it instead of quietly throwing it away.
  commitEdit()
  for _, r in ipairs(regions) do
    if y == r.y and x >= r.x1 and x <= r.x2 then
      r.fn()
      return true
    end
  end
  return false
end

local function nextScreen(delta)
  local i = 1
  for n, tab in ipairs(TABS) do
    if tab[1] == screen then i = n end
  end
  screen = TABS[((i - 1 + delta) % #TABS) + 1][1]
  editing = nil
end

local function main()
  link.modem = openModem()
  if not link.modem then
    term.clear()
    term.setCursorPos(1, 1)
    print("No wireless modem attached.")
    print("This program needs an advanced pocket computer")
    print("with a wireless (or ender) modem.")
    return
  end

  net.broadcast({ type = "fleet?" })
  net.broadcast({ type = "status" })
  draw()

  local redraw    = os.startTimer(0.4)
  local discovery = os.startTimer(2)

  while true do
    local event, a, b, c, d = os.pullEvent()

    if event == "timer" and a == redraw then
      redraw = os.startTimer(0.4)
      draw()

    elseif event == "timer" and a == discovery then
      discovery = os.startTimer(2)
      if not haveServer() then
        if link.server then link.note = "server " .. link.server .. " has gone quiet" end
        -- Ask for both: whichever answers decides which route we are on.
        net.broadcast({ type = "fleet?" })
        net.broadcast({ type = "status" })
      end

    elseif event == "modem_message" then
      local from, msg = net.decode(event, a, b, c, d)
      if from then
        handleMessage(from, msg)
        -- Redraw immediately rather than waiting for the timer. A roster that
        -- appears up to half a second late is also a roster whose rows are not
        -- clickable yet, which reads as the screen ignoring taps.
        draw()
      end

    elseif event == "mouse_click" or event == "monitor_touch" then
      handleClick(b, c)
      draw()

    elseif event == "char" and editing then
      -- What is accepted depends on what is being typed, and both are short
      -- enough that nothing can overflow the field it is drawn in.
      local kind = editing.kind or "number"
      if a:match(EDIT_PATTERN[kind]) and #editing.text < EDIT_LIMIT[kind] then
        editing.text = editing.text .. a
      end
      draw()

    elseif event == "char" then
      local key = a:lower()
      if key == "q" then
        break
      elseif key == "p" then
        flashNow(command("pause"), colours.yellow)
      elseif key == "r" then
        flashNow(command("resume"), colours.lime)
      elseif key == "c" then
        flashNow(command("return"), colours.magenta)
      elseif key == "s" then
        submit()
      elseif key == "u" then
        flashNow(command("update"), colours.cyan, 4)
      elseif key == "n" then
        if target then
          screen = "fleet"
          editing = {
            kind = "text", text = "",
            onCommit = function(name) flashNow(rename(target, name), colours.cyan) end,
          }
        else
          flashNow("pick a turtle to name", colours.orange, 3)
        end
      elseif key == "a" then
        if os.clock() < armedAbort then
          armedAbort = 0
          flashNow(command("abort"), colours.red)
        else
          armedAbort = os.clock() + 3
          flashNow("press a again to abort", colours.red, 3)
        end
      end
      draw()

    elseif event == "key" and editing then
      if a == keys.enter or a == keys.numPadEnter or a == keys.tab then
        commitEdit()
      elseif a == keys.backspace then
        editing.text = editing.text:sub(1, -2)
      end
      draw()

    elseif event == "key" then
      if a == keys.tab then
        nextScreen(1)
      elseif a == keys.left then
        if screen == "deploy" then cyclePattern(-1) else nextScreen(-1) end
      elseif a == keys.right then
        if screen == "deploy" then cyclePattern(1) else nextScreen(1) end
      end
      draw()
    end
  end

  term.setBackgroundColour(colours.black)
  term.setTextColour(colours.white)
  term.clear()
  term.setCursorPos(1, 1)
end

main()
