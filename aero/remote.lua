--- Flight remote. Runs on an advanced pocket computer.
--
-- The thing you carry: see where the fleet is, send it somewhere, put a
-- waypoint down where you are standing. It holds no authoritative state of its
-- own and never guesses -- a ship that has gone quiet says LOST rather than
-- showing the last position it had as though it were live. A dashboard
-- confidently drawing a ship where it was ten seconds ago is worse than one that
-- admits it does not know, because somebody will go and look there.
--
-- Two routes, and the header always says which one is in use:
--
--   TOWER   the base server is answering. Waypoints, routes and the log come
--           from it, and commands are relayed through it so the log stays whole.
--   DIRECT  nothing at base is answering. The roster is assembled from the
--           ships' own telemetry and commands go straight to them. Waypoints are
--           whatever each ship has cached, so "fly to the quarry" still works if
--           the ship has heard of the quarry -- which is the part that matters
--           when you are standing in a field watching one circle.
--
-- Deliberately not read() anywhere: it blocks the event loop, telemetry stops
-- arriving, and the link reads LOST while you type.

local config = require("lib.config")
local net    = require("lib.net")
local nav    = require("lib.nav")
local log    = require("lib.log")

local W, H = term.getSize()

--------------------------------------------------------------------------------
-- Link
--------------------------------------------------------------------------------

local link = {
  server = nil,
  net    = nil,
  seenAt = -math.huge,
  ships  = {},          -- [id] = telemetry, for direct mode
  heard  = {},          -- [id] = os.clock()
  hulls  = {},          -- [id] = last `hull` reply
  note   = nil,
}

link.note = ("network '%s': looking..."):format(config.protocol)

local function now() return os.clock() end

local function haveServer()
  return link.server ~= nil and (now() - link.seenAt) < config.heartbeatTimeout
end

--- One roster shape whichever route is live, so the fleet screen is drawn from
--- the same rows either way.
local function roster()
  if haveServer() and link.net then return link.net.ships or {} end

  local list = {}
  for id, tlm in pairs(link.ships) do
    local gone = (now() - (link.heard[id] or -math.huge)) > config.heartbeatTimeout
    list[#list + 1] = {
      id = id, label = tlm.label, stale = gone,
      pos = tlm.pos, alt = tlm.alt, heading = tlm.heading, speed = tlm.speed,
      burn = tlm.burn, flight = tlm.flight, source = tlm.source,
    }
  end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end

--- Waypoints from the tower, or from whatever the ships have cached.
--
-- The union rather than the first one found: two ships that were airborne at
-- different times may have different caches, and the pocket showing only one of
-- them would hide a pad that is perfectly reachable.
local function waypoints()
  if haveServer() and link.net then return link.net.waypoints or {} end

  local all = {}
  for _, tlm in pairs(link.ships) do
    for name, wp in pairs(tlm.waypoints or {}) do all[name] = wp end
  end
  return all
end

local function toServer(msg)
  if link.server then net.send(link.server, msg) end
end

--------------------------------------------------------------------------------
-- Screens
--------------------------------------------------------------------------------

local TABS = { "fleet", "fly", "nav", "log" }

local screen = "fleet"
local scroll = 0
local rows   = {}          -- rebuilt every draw; carries the clicks
local flash  = nil
local logs   = {}
local typing = nil         -- { field, text } while a name is typed

local selected = nil       -- ship id, or nil for the whole fleet
local plan = { names = {}, alt = 100 }

local function note(text)
  flash = { text = text, until_ = now() + 3 }
end

local function colour(c)
  if term.isColour() then term.setTextColour(c) end
end

local function at(x, y, text, c)
  colour(c or colours.white)
  term.setCursorPos(x, y)
  term.write(text)
end

local function fit(text, width)
  text = tostring(text or "")
  if #text <= width then return text end
  return text:sub(1, math.max(0, width - 1)) .. "."
end

--- Send an order to the selected ship, or to every ship if none is selected.
--
-- Routed through the tower when one is answering, so the log stays complete: a
-- command sent straight to a ship is invisible to the tower, and the log then
-- shows a ship changing its mind for no recorded reason.
local function order(body, why)
  if haveServer() then
    toServer({ type = "command", target = selected, body = body })
  else
    local sent = 0
    for _, s in ipairs(roster()) do
      if (selected == nil or selected == s.id) and not s.stale then
        net.send(s.id, body)
        sent = sent + 1
      end
    end
    if sent == 0 then
      note("nothing answering")
      return
    end
  end
  note(why or body.type)
end

--------------------------------------------------------------------------------
-- Row building
--------------------------------------------------------------------------------

-- Every screen builds a flat list of rows and hands each one a click handler.
-- Working out what was clicked from coordinates and the current screen was the
-- thing that went wrong most often in mining/remote.lua; a row that carries its
-- own action cannot drift out of step with where it was drawn.
local function row(entry)
  rows[#rows + 1] = entry
  return entry
end

local STATE_COLOUR = {
  idle = colours.grey, cruise = colours.lime, loiter = colours.orange,
  emergency = colours.red,
}

local function buildFleet()
  local list = roster()
  if #list == 0 then
    row({ kind = "note", text = "No ships answering." })
    return
  end

  for _, s in ipairs(list) do
    row({
      kind = "ship", ship = s,
      click = function()
        -- Tapping the selected ship clears the selection, which is how you get
        -- back to commanding the whole fleet without a separate control.
        selected = (selected == s.id) and nil or s.id
      end,
    })
  end

  row({ kind = "gap" })
  row({ kind = "action", text = "HOLD   stop and hover", colour = colours.yellow,
        click = function() order({ type = "hold" }, "holding") end })
  row({ kind = "action", text = "LAND   come down here", colour = colours.yellow,
        click = function() order({ type = "land" }, "landing") end })
  row({ kind = "action", text = "RTB    return to base", colour = colours.lime,
        click = function() order({ type = "rtb" }, "returning") end })
  row({ kind = "action", text = "STOP   descend now", colour = colours.red,
        click = function() order({ type = "stop" }, "descending") end })
end

local function buildFly()
  local wp = waypoints()
  local names = nav.names(wp)

  if #names == 0 then
    row({ kind = "note", text = "No waypoints yet." })
    row({ kind = "note", text = "Add one on the nav tab." })
    return
  end

  row({ kind = "head", label = ("alt %d  (- +)"):format(plan.alt) })
  row({ kind = "action", text = "  -10", colour = colours.lightGrey,
        click = function() plan.alt = math.max(0, plan.alt - 10) end })
  row({ kind = "action", text = "  +10", colour = colours.lightGrey,
        click = function() plan.alt = plan.alt + 10 end })

  row({ kind = "head", label = "route" })
  for i, name in ipairs(plan.names) do
    row({ kind = "leg", index = i, name = name,
          click = function() table.remove(plan.names, i) end })
  end
  if #plan.names == 0 then
    row({ kind = "note", text = "  tap a waypoint below" })
  end

  row({ kind = "gap" })
  row({ kind = "action", text = "FLY IT", colour = colours.lime,
        click = function()
          if #plan.names == 0 then
            note("no route")
            return
          end
          order({ type = "fly", names = plan.names, alt = plan.alt }, "flying")
        end })

  row({ kind = "head", label = "waypoints" })
  for _, name in ipairs(names) do
    local point = wp[name]
    row({
      kind = "waypoint", name = name, point = point,
      click = function()
        plan.names[#plan.names + 1] = name
        note("+ " .. name)
      end,
    })
  end
end

local function buildNav()
  local wp = waypoints()

  row({ kind = "action", text = "+ waypoint here", colour = colours.lime,
        click = function()
          if not haveServer() then
            note("waypoints need the tower")
            return
          end
          typing = { field = "waypoint", text = "" }
        end })

  row({ kind = "action", text = "+ pad here", colour = colours.lime,
        click = function()
          if not haveServer() then
            note("waypoints need the tower")
            return
          end
          typing = { field = "pad", text = "" }
        end })

  row({ kind = "gap" })

  local names = nav.names(wp)
  if #names == 0 then
    row({ kind = "note", text = "None yet." })
    return
  end

  local home = link.net and link.net.home
  for _, name in ipairs(names) do
    local point = wp[name]
    row({
      kind = "waypoint", name = name, point = point, home = (home == name),
      -- Tapping a waypoint here makes it home rather than deleting it. Deletion
      -- is the more dangerous of the two and should not be one tap away from
      -- something you do while reading a list.
      click = function()
        if not haveServer() then
          note("needs the tower")
          return
        end
        toServer({ type = "home!", name = name })
      end,
    })
  end
end

local function buildLog()
  if #logs == 0 then
    row({ kind = "note", text = haveServer() and "Nothing logged yet."
                                or "The log lives on the tower." })
    return
  end
  for _, entry in ipairs(logs) do
    row({ kind = "log", entry = entry })
  end
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

local function drawRow(entry, y)
  if entry.kind == "ship" then
    local s = entry.ship
    local mark = (selected == s.id) and ">" or " "

    if s.stale then
      at(1, y, mark .. fit(s.label or ("ship " .. s.id), 10), colours.red)
      at(13, y, "LOST", colours.red)
    else
      local flight = s.flight or {}
      at(1, y, mark .. fit(s.label or ("ship " .. s.id), 10),
         (selected == s.id) and colours.yellow or colours.white)
      at(13, y, fit(flight.state or "?", 8),
         STATE_COLOUR[flight.state] or colours.lightGrey)
      if s.alt then at(22, y, ("%4.0f"):format(s.alt), colours.lightGrey) end
    end

  elseif entry.kind == "waypoint" then
    local p = entry.point or {}
    at(1, y, (entry.home and "*" or " ") .. fit(entry.name, 11),
       entry.home and colours.lime or colours.white)
    at(13, y, fit(("%d %d"):format(p.x or 0, p.z or 0), W - 14), colours.lightGrey)
    if p.kind == "pad" then at(W, y, "=", colours.lightBlue) end

  elseif entry.kind == "leg" then
    at(1, y, ("%d %s"):format(entry.index, fit(entry.name, W - 4)), colours.white)
    at(W, y, "x", colours.red)

  elseif entry.kind == "log" then
    at(1, y, fit(log.line(entry.entry), W), colours.lightGrey)

  elseif entry.kind == "head" then
    at(1, y, fit(entry.label, W), colours.cyan)

  elseif entry.kind == "action" then
    at(1, y, fit(entry.text, W), entry.colour or colours.white)

  elseif entry.kind == "note" then
    at(1, y, fit(entry.text, W), colours.grey)
  end
end

local function draw()
  rows = {}
  if screen == "fleet" then buildFleet()
  elseif screen == "fly" then buildFly()
  elseif screen == "nav" then buildNav()
  else buildLog() end

  term.setBackgroundColour(colours.black)
  term.clear()

  at(1, 1, "AERO", colours.cyan)
  if selected then
    at(6, 1, fit("#" .. selected, 8), colours.yellow)
  else
    at(6, 1, "all", colours.grey)
  end

  if haveServer() then
    at(W - 5, 1, "TOWER ", colours.lime)
  elseif #roster() > 0 then
    at(W - 5, 1, "DIRECT", colours.yellow)
  else
    at(W - 5, 1, " LOST ", colours.red)
  end

  local top, bottom = 3, H - 2
  local visible = bottom - top + 1

  if scroll > math.max(0, #rows - visible) then
    scroll = math.max(0, #rows - visible)
  end

  if #rows == 0 then
    at(1, 4, fit(link.note, W), colours.grey)
  end

  for i = 1, visible do
    local entry = rows[i + scroll]
    if entry then
      entry.y = top + i - 1
      drawRow(entry, entry.y)
    end
  end

  if #rows > visible then
    at(W, 2, "^", colours.grey)
    at(W, H - 1, "v", colours.grey)
  end

  -- Tabs on the bottom row, which is where a thumb is on a pocket computer.
  local x = 1
  for _, name in ipairs(TABS) do
    at(x, H, name:sub(1, 5), screen == name and colours.yellow or colours.grey)
    x = x + 6
  end

  if typing then
    at(1, H - 1, fit(typing.field .. ": " .. typing.text .. "_", W), colours.yellow)
  elseif flash and now() < flash.until_ then
    at(1, H - 1, fit(flash.text, W), colours.lime)
  end
end

--------------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------------

local function clickTab(x)
  local index = math.floor((x - 1) / 6) + 1
  local name = TABS[index]
  if not name then return end

  screen, scroll = name, 0
  if name == "log" then toServer({ type = "log?", n = 30 }) end
end

local function onClick(x, y)
  if y == H then return clickTab(x) end

  for _, entry in ipairs(rows) do
    if entry.y == y and entry.click then
      entry.click()
      return
    end
  end
end

local function onChar(ch)
  if not typing then return end
  if #typing.text < 16 and ch:match("[%w%-_]") then
    typing.text = typing.text .. ch
  end
end

--- Where the pocket computer is, for putting a waypoint down.
--
-- A pocket computer with a wireless modem can use GPS, and standing where you
-- want the pad and naming it is the only waypoint-entry method anyone will
-- actually use. Typing three coordinates on this keyboard is not.
local function here()
  if not gps then return nil end
  local ok, x, y, z = pcall(gps.locate, 2)
  if not ok or not x then return nil end
  return { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
end

local function onKey(key)
  if typing then
    if key == keys.enter then
      if typing.text ~= "" then
        local at_ = here()
        if not at_ then
          note("no GPS fix here")
        else
          toServer({
            type = "wp!",
            name = typing.text,
            x = at_.x, y = at_.y, z = at_.z,
            kind = typing.field == "pad" and "pad" or "point",
          })
          note("sent " .. typing.text)
        end
      end
      typing = nil
    elseif key == keys.backspace then
      typing.text = typing.text:sub(1, -2)
    elseif key == keys.q then
      typing = nil
    end
    return
  end

  if key == keys.up then
    scroll = math.max(0, scroll - 1)
  elseif key == keys.down then
    scroll = scroll + 1
  elseif key == keys.tab then
    local index = 1
    for i, name in ipairs(TABS) do if name == screen then index = i end end
    clickTab((index % #TABS) * 6 + 1)
  elseif key == keys.q then
    return "quit"
  end
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

term.clear()
term.setCursorPos(1, 1)

if not net.open() then
  colour(colours.red)
  print("No wireless modem.")
  print("This pocket computer needs one to see anything.")
  colour(colours.white)
  return
end

net.broadcast({ type = "net?" })
draw()

local tick = os.startTimer(0.5)
local ask  = os.startTimer(config.heartbeat)

while true do
  local event, a, b, c, d = os.pullEvent()

  local from, msg = net.decode(event, a, b, c, d)
  if from then
    if type(msg) == "table" then
      if msg.type == "net" then
        link.server, link.net, link.seenAt = from, msg, now()
      elseif msg.type == "tlm" then
        if msg.gone then
          link.ships[from], link.heard[from] = nil, nil
        else
          link.ships[from], link.heard[from] = msg, now()
        end
      elseif msg.type == "hull" then
        link.hulls[from] = msg.hull
      elseif msg.type == "log" then
        logs = msg.entries or {}
      elseif msg.type == "error" then
        note(tostring(msg.reason))
      elseif msg.type == "ack" then
        if msg.of == "command" then
          note(("sent to %d"):format(msg.sent or 0))
        elseif msg.of == "wp!" then
          note("waypoint saved")
        end
      end
    end
    draw()

  elseif event == "timer" and a == tick then
    tick = os.startTimer(0.5)
    draw()

  elseif event == "timer" and a == ask then
    ask = os.startTimer(config.heartbeat)
    -- Ships and the tower broadcast unprompted, so this is only for the first
    -- few seconds after the pocket is picked up.
    if not haveServer() then
      link.note = ("network '%s': no tower"):format(config.protocol)
      net.broadcast({ type = "net?" })
    end

  elseif event == "mouse_click" then
    onClick(b, c)
    draw()

  elseif event == "char" then
    onChar(a)
    draw()

  elseif event == "key" then
    if onKey(a) == "quit" then break end
    draw()

  elseif event == "terminate" then
    break
  end
end

term.clear()
term.setCursorPos(1, 1)
colour(colours.white)
print("Remote closed. Every ship carries on.")
