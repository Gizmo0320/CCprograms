--- The tower. Runs on an advanced computer at base.
--
-- Holds the things that are about the fleet rather than about any one ship: the
-- roster, the named waypoints and pads, saved routes, and the log. Draws a
-- dashboard on its own terminal and on any attached monitor.
--
-- It does not fly anything. Every ship is autonomous by design -- see pilot.lua
-- -- and this program can be switched off, unloaded or broken without a single
-- ship falling out of the sky. What is lost while it is away is the waypoint
-- table for ships that have not cached it, the log, and the map; and the ships
-- carry on to wherever they were already going.
--
-- Wants an ender modem. Range is the whole point of a tower: a base that can
-- only see ships already overhead is a base that finds out about the diversion
-- when the ship lands.

local config = require("lib.config")
local net    = require("lib.net")
local state  = require("lib.state")
local nav    = require("lib.nav")
local log    = require("lib.log")

local W, H = term.getSize()

local fleet = {
  ships   = {},        -- [id] = last telemetry
  heard   = {},        -- [id] = os.clock() of the last one
  screen  = "ships",   -- ships | map | log
  note    = nil,
  monitor = nil,
}

local function now() return os.clock() end

local function waypoints() return state.data.waypoints end
local function routes() return state.data.routes end

--------------------------------------------------------------------------------
-- Roster
--------------------------------------------------------------------------------

local function stale(id)
  return (now() - (fleet.heard[id] or -math.huge)) > config.staleAfter
end

--- The roster in a stable order, which is by computer id.
--
-- Not by name: a ship being renamed would reorder the whole dashboard while you
-- were reading it, and the id is the one thing about a ship that does not
-- change.
local function roster()
  local list = {}
  for id, tlm in pairs(fleet.ships) do
    list[#list + 1] = {
      id = id,
      label = tlm.label or ("ship " .. id),
      tlm = tlm,
      stale = stale(id),
    }
  end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end

--- What goes out to everyone, every couple of seconds.
--
-- Waypoints ride in this rather than being fetched, because the pilots cache
-- them to disk on arrival. That is what lets a ship already in the air be told
-- to fly to a named pad after this computer's chunk has unloaded, and what lets
-- the bingo-fuel guard know where home is.
local function broadcast()
  local ships = {}
  for _, s in ipairs(roster()) do
    ships[#ships + 1] = {
      id = s.id, label = s.label, stale = s.stale,
      pos = s.tlm.pos, alt = s.tlm.alt, heading = s.tlm.heading,
      speed = s.tlm.speed, burn = s.tlm.burn, flight = s.tlm.flight,
      source = s.tlm.source,
    }
  end

  net.broadcast({
    type = "net",
    ships = ships,
    waypoints = waypoints(),
    routes = routes(),
    home = state.data.home,
  })
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

local function colour(fg, bg)
  if term.isColour() then
    if fg then term.setTextColour(fg) end
    if bg then term.setBackgroundColour(bg) end
  end
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

local STATE_COLOUR = {
  idle = colours.grey, preflight = colours.yellow, takeoff = colours.yellow,
  climb = colours.yellow, cruise = colours.lime, descend = colours.yellow,
  approach = colours.yellow, land = colours.yellow, dock = colours.yellow,
  loiter = colours.orange, emergency = colours.red,
}

local function drawShips(w, h)
  local list = roster()
  if #list == 0 then
    at(1, 3, "No ships are answering.", colours.grey)
    at(1, 5, ("Channel %d, network '%s'."):format(config.channel, config.protocol),
       colours.grey)
    return
  end

  local y = 3
  for _, s in ipairs(list) do
    if y > h - 1 then break end

    local flight = s.tlm.flight or {}

    if s.stale then
      -- Never the last known position drawn as though it were live. A tower
      -- confidently showing a ship where it was a minute ago is worse than one
      -- that admits it has lost it, because somebody will go and look there.
      at(1, y, fit(s.label, 12), colours.red)
      at(14, y, "LOST " .. math.floor(now() - (fleet.heard[s.id] or 0)) .. "s",
         colours.red)
    else
      at(1, y, fit(s.label, 12), colours.white)
      at(14, y, fit(flight.state or "?", 9), STATE_COLOUR[flight.state] or colours.white)

      if s.tlm.alt then
        at(24, y, ("%5.0fm"):format(s.tlm.alt), colours.lightGrey)
      end
      if s.tlm.speed then
        at(31, y, ("%4.1f"):format(s.tlm.speed), colours.lightGrey)
      end

      -- The reason, when there is one, is the most useful thing on the line.
      local why = flight.guard or flight.leg or flight.why
      if why and w > 40 then
        at(37, y, fit(why, w - 37),
           flight.guard and colours.orange or colours.lightGrey)
      end
    end

    y = y + 1
  end
end

--- A plan view of the fleet and the waypoints.
--
-- The one thing a base dashboard can do that a pocket computer cannot: show
-- where everything is at once. Autoscaled to fit whatever is out there, because
-- a fixed scale is either useless at base or useless at range.
local function drawMap(w, h)
  local top, bottom = 3, h - 1
  local points = {}

  for _, name in ipairs(nav.names(waypoints())) do
    local wp = waypoints()[name]
    points[#points + 1] = { x = wp.x, z = wp.z, mark = wp.kind == "pad" and "=" or "+",
                            colour = colours.lightBlue, label = name }
  end

  for _, s in ipairs(roster()) do
    if not s.stale and s.tlm.pos then
      points[#points + 1] = { x = s.tlm.pos.x, z = s.tlm.pos.z, mark = "o",
                              colour = colours.lime, label = s.label }
    end
  end

  if #points == 0 then
    at(1, 3, "Nothing to draw yet.", colours.grey)
    return
  end

  local minX, maxX, minZ, maxZ = points[1].x, points[1].x, points[1].z, points[1].z
  for _, p in ipairs(points) do
    if p.x < minX then minX = p.x end
    if p.x > maxX then maxX = p.x end
    if p.z < minZ then minZ = p.z end
    if p.z > maxZ then maxZ = p.z end
  end

  -- A single point, or every point in a line, gives a zero span and a division
  -- by zero. Padding it out is also what stops one ship at base filling the
  -- screen with a meaningless zoom.
  local spanX = math.max(maxX - minX, 32)
  local spanZ = math.max(maxZ - minZ, 32)
  local midX, midZ = (minX + maxX) / 2, (minZ + maxZ) / 2

  local cols, lines = w - 1, bottom - top
  if cols < 4 or lines < 2 then return end

  -- North is up, so +Z (south) goes down the screen and -X (west) goes right.
  -- Screen characters are about twice as tall as they are wide, which is why the
  -- vertical scale carries the extra factor -- without it every route looks like
  -- it doubles back.
  local scale = math.max(spanX / cols, spanZ / (lines * 2))

  for _, p in ipairs(points) do
    local sx = math.floor((midX - p.x) / scale + cols / 2 + 0.5) + 1
    local sy = math.floor((p.z - midZ) / (scale * 2) + lines / 2 + 0.5) + top

    if sx >= 1 and sx <= w and sy >= top and sy <= bottom then
      at(sx, sy, p.mark, p.colour)
      -- Labelled only when there is room to the right, and never over another
      -- mark. A map that overwrites the thing you are looking for is worse than
      -- one with no labels at all.
      if sx + 1 + #p.label <= w then
        at(sx + 1, sy, fit(p.label, w - sx - 1), colours.grey)
      end
    end
  end

  at(1, bottom + 1, ("%.0fm across   + waypoint  = pad  o ship"):format(spanX),
     colours.grey)
end

local function drawLog(w, h)
  local entries = log.recent(h - 3)
  if #entries == 0 then
    at(1, 3, "Nothing has happened yet.", colours.grey)
    return
  end

  local y = 3
  for _, entry in ipairs(entries) do
    if y > h - 1 then break end
    at(1, y, fit(log.time(entry.at), 5), colours.grey)
    at(7, y, fit(entry.name or ("ship " .. tostring(entry.ship)), 11), colours.white)
    at(19, y, fit(("%s > %s"):format(log.value(entry.from), log.value(entry.to)),
                  w - 19 - 12), colours.lightGrey)
    at(w - 11, y, fit(entry.why, 11),
       (entry.why == "bingo" or entry.why == "clearance") and colours.orange
       or colours.lightGrey)
    y = y + 1
  end
end

local TABS = { "ships", "map", "log" }

local function render()
  local w, h = term.getSize()

  colour(colours.white, colours.black)
  term.clear()

  colour(colours.black, colours.cyan)
  term.setCursorPos(1, 1)
  term.clearLine()
  local flying = 0
  for _, s in ipairs(roster()) do
    if not s.stale and s.tlm.flight and s.tlm.flight.state ~= "idle" then
      flying = flying + 1
    end
  end
  term.write(fit((" AERO  %d ships, %d flying"):format(#roster(), flying), w - 18))

  local x = w - 17
  for _, name in ipairs(TABS) do
    colour(fleet.screen == name and colours.white or colours.black, colours.cyan)
    term.setCursorPos(x, 1)
    term.write(" " .. name .. " ")
    x = x + #name + 2
  end

  colour(colours.white, colours.black)

  if fleet.screen == "ships" then drawShips(w, h)
  elseif fleet.screen == "map" then drawMap(w, h)
  else drawLog(w, h) end

  if fleet.note then
    at(1, h, fit(fleet.note, w), colours.yellow)
  else
    at(1, h, fit("Tab: view   Q: quit   " .. (state.data.home
        and ("home " .. state.data.home) or "no home set"), w), colours.grey)
  end
end

--- Draw to the terminal and to every monitor.
--
-- term.redirect rather than a second rendering path, so the monitor cannot drift
-- out of step with the terminal -- which it will, because nobody is looking at
-- both at once and a bug in the copy nobody watches survives forever.
local function redraw()
  render()

  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "monitor" then
      local ok = pcall(function()
        local mon = peripheral.wrap(side)
        mon.setTextScale(0.5)
        local old = term.redirect(mon)
        render()
        term.redirect(old)
      end)
      if not ok then fleet.monitor = nil end
    end
  end
end

local function note(text)
  fleet.note = text
end

--------------------------------------------------------------------------------
-- Messages
--------------------------------------------------------------------------------

local function record(from, msg)
  local entry = log.add({
    ship = from,
    name = msg.label,
    what = msg.what,
    from = msg.from,
    to   = msg.to,
    why  = msg.why,
    pos  = msg.pos,
  })

  state.data.log = log.entries
  state.mark()
  return entry
end

local function handle(from, msg)
  ------------------------------------------------------------------------------
  if msg.type == "tlm" then
    if msg.gone then
      -- A pilot saying goodbye on its way out. Dropped from the roster at once
      -- rather than left to time out, so a ship that was landed and switched off
      -- does not sit on the dashboard in red for fifteen seconds looking lost.
      fleet.ships[from], fleet.heard[from] = nil, nil
    else
      fleet.ships[from], fleet.heard[from] = msg, now()
    end
    return
  end

  ------------------------------------------------------------------------------
  if msg.type == "event" then
    record(from, msg)
    return
  end

  ------------------------------------------------------------------------------
  if msg.type == "server?" then
    net.send(from, { type = "server!" })
    return
  end

  ------------------------------------------------------------------------------
  if msg.type == "net?" then
    broadcast()
    return
  end

  ------------------------------------------------------------------------------
  if msg.type == "log?" then
    net.send(from, { type = "log", entries = log.recent(msg.n or 30) })
    return
  end

  ------------------------------------------------------------------------------
  if msg.type == "wp!" then
    local wp = msg.waypoint or msg
    local ok, why = nav.put(waypoints(), {
      name = wp.name, x = wp.x, y = wp.y, z = wp.z, kind = wp.kind, note = wp.note,
    })
    if not ok then
      net.send(from, { type = "error", reason = why })
      return
    end

    state.mark()
    state.flush(now())     -- a waypoint is worth one disk hit
    broadcast()            -- and every ship should know about it now, not in 2s
    net.send(from, { type = "ack", of = "wp!" })
    note("waypoint " .. wp.name)
    return
  end

  ------------------------------------------------------------------------------
  if msg.type == "wp-" then
    if not waypoints()[msg.name] then
      net.send(from, { type = "error", reason = "no waypoint " .. tostring(msg.name) })
      return
    end

    -- Home is deleted last of all, or the bingo guard has nowhere to send a
    -- ship that is already out there relying on it.
    if state.data.home == msg.name then
      net.send(from, { type = "error", reason = msg.name .. " is home" })
      return
    end

    waypoints()[msg.name] = nil
    state.mark()
    state.flush(now())
    broadcast()
    net.send(from, { type = "ack", of = "wp-" })
    return
  end

  ------------------------------------------------------------------------------
  if msg.type == "home!" then
    if not waypoints()[msg.name] then
      net.send(from, { type = "error", reason = "no waypoint " .. tostring(msg.name) })
      return
    end
    state.data.home = msg.name
    state.mark()
    state.flush(now())
    broadcast()
    net.send(from, { type = "ack", of = "home!" })
    note("home is " .. msg.name)
    return
  end

  ------------------------------------------------------------------------------
  if msg.type == "route!" then
    if type(msg.names) ~= "table" or #msg.names == 0 then
      net.send(from, { type = "error", reason = "an empty route is not a route" })
      return
    end
    for _, name in ipairs(msg.names) do
      if not waypoints()[name] then
        net.send(from, { type = "error", reason = "no waypoint " .. name })
        return
      end
    end

    routes()[msg.name] = { name = msg.name, names = msg.names, alt = msg.alt }
    state.mark()
    state.flush(now())
    broadcast()
    net.send(from, { type = "ack", of = "route!" })
    return
  end

  ------------------------------------------------------------------------------
  if msg.type == "command" then
    -- Relayed from the pocket computer. Routing through here rather than
    -- straight to the ship is what keeps the log complete: a command sent
    -- directly is invisible to the tower, and the log then has a ship changing
    -- its mind for no recorded reason.
    local body = msg.body
    if type(body) ~= "table" then
      net.send(from, { type = "error", reason = "no command" })
      return
    end

    local sent = 0
    for _, s in ipairs(roster()) do
      if (msg.target == nil or msg.target == s.id) and not s.stale then
        net.send(s.id, body)
        sent = sent + 1
      end
    end

    net.send(from, { type = "ack", of = "command", sent = sent })
    if sent == 0 then
      net.send(from, { type = "error", reason = "nothing answering" })
    end
    return
  end
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

state.open(config.fleetFile, { waypoints = {}, routes = {}, log = {}, home = nil })
state.data.waypoints = state.data.waypoints or {}
state.data.routes    = state.data.routes or {}
log.load(state.data.log)

term.clear()
term.setCursorPos(1, 1)

if not net.open() then
  colour(colours.red)
  print("No wireless modem. A tower with no radio is a chair.")
  colour(colours.white)
  return
end

-- Two towers would both fan out commands and both keep a log, and the log would
-- then be half the story in two places. Ask before claiming the job.
net.broadcast({ type = "server?" })
local answered = select(2, net.receive(2))
if type(answered) == "table" and answered.type == "server!" then
  colour(colours.yellow)
  print("Another tower is already up on this network.")
  print("Standing down.")
  colour(colours.white)
  return
end

broadcast()
redraw()

local beat = os.startTimer(config.heartbeat * 2)
local tick = os.startTimer(1)

while true do
  local event, a, b, c, d = os.pullEvent()

  local from, msg = net.decode(event, a, b, c, d)
  if from and type(msg) == "table" then
    local ok, why = pcall(handle, from, msg)
    if not ok then note(tostring(why)) end
    redraw()

  elseif event == "timer" and a == beat then
    beat = os.startTimer(config.heartbeat * 2)
    broadcast()

  elseif event == "timer" and a == tick then
    tick = os.startTimer(1)
    state.tick(now())
    fleet.note = nil
    redraw()

  elseif event == "key" then
    if a == keys.tab then
      local index = 1
      for i, name in ipairs(TABS) do if name == fleet.screen then index = i end end
      fleet.screen = TABS[(index % #TABS) + 1]
      redraw()
    elseif a == keys.q then
      break
    end

  elseif event == "mouse_click" or event == "monitor_touch" then
    -- The header carries the tabs, so tapping it cycles the view. On a monitor
    -- that is the only input there is.
    fleet.screen = TABS[(({ ships = 1, map = 2, log = 3 })[fleet.screen] % #TABS) + 1]
    redraw()

  elseif event == "term_resize" or event == "monitor_resize" then
    W, H = term.getSize()
    redraw()

  elseif event == "terminate" then
    break
  end
end

state.data.log = log.entries
state.flush(now())

term.clear()
term.setCursorPos(1, 1)
colour(colours.white)
print("Tower closed. Every ship carries on by itself.")
