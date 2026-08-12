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
local ui     = require("lib.ui")
local terrain = require("lib.terrain")

local W, H = term.getSize()

local fleet = {
  ships    = {},       -- [id] = last telemetry
  heard    = {},       -- [id] = os.clock() of the last one
  screen   = "ships",  -- ships | map | log | nav
  selected = nil,      -- a ship id, highlighted here and on the map
  rows     = nil,      -- the clickable ship list, rebuilt every draw
  tabs     = {},       -- where the header tabs landed, for hit testing
  note     = nil,
}

local function now() return os.clock() end

local function waypoints() return state.data.waypoints end
local function routes() return state.data.routes end

-- What the fleet has learned about the ground. Rebuilt from the state file on
-- boot and fed by every ship that reports a position and a clearance.
local map = nil

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
      commander = s.tlm.commander, commanderName = s.tlm.commanderName,
    }
  end

  net.broadcast({
    type = "net",
    ships = ships,
    waypoints = waypoints(),
    routes = routes(),
    home = state.data.home,
    -- The height map rides along. It is the only way a pilot can check its own
    -- route before setting off, and a ship that has cached it can still do that
    -- with this computer's chunk unloaded.
    terrain = map,
  })
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

-- Four views, cycled with Tab or by tapping the header. Everything is drawn
-- through lib/ui so the tower, the pocket and the ship agree about what orange
-- means -- a state that reads "loiter" in one colour here and another there is
-- worse than no colour at all.

local TABS = { "ships", "map", "log", "nav" }

local function drawShips(w, h)
  local list = roster()
  if #list == 0 then
    ui.at(2, 3, "No ships are answering.", ui.theme.dim)
    ui.at(2, 5, ("Channel %d, network '%s'."):format(config.channel,
          config.protocol), ui.theme.dim)
    return
  end

  -- A header row, because six columns of numbers with nothing over them is a
  -- puzzle rather than a dashboard.
  ui.fill(1, 2, w, 1, ui.theme.panel)
  ui.at(2, 2, "ship", ui.theme.bg, ui.theme.panel)
  ui.at(14, 2, "state", ui.theme.bg, ui.theme.panel)
  ui.at(24, 2, "  alt", ui.theme.bg, ui.theme.panel)
  ui.at(31, 2, " spd", ui.theme.bg, ui.theme.panel)
  if w > 40 then ui.at(37, 2, "doing", ui.theme.bg, ui.theme.panel) end
  if w >= 50 then ui.at(w - 11, 2, "flown by", ui.theme.bg, ui.theme.panel) end

  fleet.rows = ui.list()
  for _, ship in ipairs(list) do
    ui.row(fleet.rows, { ship = ship, click = function()
      fleet.selected = (fleet.selected == ship.id) and nil or ship.id
    end })
  end

  ui.draw(fleet.rows, 1, 3, w, h - 3, function(entry, y)
    local ship = entry.ship
    local flight = ship.tlm.flight or {}
    local chosen = (fleet.selected == ship.id)

    if chosen then ui.fill(1, y, w, 1, colours.blue) end
    local bg = chosen and colours.blue or ui.theme.bg

    if ship.stale then
      -- Never the last known position drawn as though it were live. A tower
      -- confidently showing a ship where it was a minute ago is worse than one
      -- that admits it has lost it, because somebody will go and look there.
      ui.at(2, y, ui.fit(ship.label, 11, true), ui.theme.bad, bg)
      ui.at(14, y, ui.fit(("LOST %ds")
        :format(math.floor(now() - (fleet.heard[ship.id] or 0))), w - 15, true),
        ui.theme.bad, bg)
      return
    end

    ui.at(2, y, ui.fit(ship.label, 11, true), ui.theme.text, bg)
    ui.at(14, y, ui.fit(flight.state or "?", 9, true),
          ui.stateColour[flight.state] or ui.theme.text, bg)
    ui.at(24, y, ("%5s"):format(ui.num(ship.tlm.alt)), ui.theme.dim, bg)
    ui.at(31, y, ("%4s"):format(ui.num(ship.tlm.speed, "%.1f")), ui.theme.dim, bg)

    if w > 40 then
      -- The reason, when there is one, is the most useful thing on the line.
      local why = flight.guard or flight.leg or flight.why
      local room = w - 38
      -- ...unless somebody is flying it by hand, in which case who they are is
      -- the thing you need before you touch anything.
      if flight.commanderName and w >= 50 then room = room - 12 end
      ui.at(37, y, ui.fit(why or "-", math.max(1, room), true),
            flight.guard and ui.guardColour(flight.guard) or ui.theme.dim, bg)

      if flight.commanderName and w >= 50 then
        ui.at(w - 11, y, ui.fit(flight.commanderName, 11, true),
              ui.theme.select, bg)
      end
    end
  end)
end

--- A plan view of the fleet and the waypoints.
--
-- The one thing a base dashboard can do that a pocket computer cannot: show
-- where everything is at once. Autoscaled, because a fixed scale is either
-- useless at base or useless at range.
local function drawMap(w, h)
  local top, bottom = 2, h - 2
  local points = {}

  for _, name in ipairs(nav.names(waypoints())) do
    local wp = waypoints()[name]
    points[#points + 1] = { x = wp.x, z = wp.z,
                            mark = wp.kind == "pad" and "=" or "+",
                            colour = ui.theme.cold, label = name }
  end

  -- Eight sectors of heading, which is as much as the character set can show
  -- honestly. A ship with no heading gets a dot rather than a wrong arrow.
  local ARROWS = { "v", "\\", "<", "/", "^", "\\", ">", "/" }

  for _, s in ipairs(roster()) do
    if not s.stale and s.tlm.pos then
      local mark = "o"
      if s.tlm.heading then
        mark = ARROWS[(math.floor((s.tlm.heading % 360) / 45 + 0.5) % 8) + 1]
      end
      points[#points + 1] = { x = s.tlm.pos.x, z = s.tlm.pos.z, mark = mark,
                              colour = (fleet.selected == s.id)
                                and ui.theme.select or ui.theme.ok,
                              label = s.label, ship = true }
    end
  end

  if #points == 0 then
    ui.at(2, 3, "Nothing to draw yet.", ui.theme.dim)
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
      ui.at(sx, sy, p.mark, p.colour)
      -- Labelled only when there is room to the right. A map that overwrites the
      -- thing you are looking for is worse than one with no labels.
      if sx + 1 + #p.label <= w then
        ui.at(sx + 1, sy, ui.fit(p.label, w - sx - 1),
              p.ship and ui.theme.text or ui.theme.dim)
      end
    end
  end

  -- North is up, and saying so costs two characters.
  ui.at(w - 1, top, "N", ui.theme.accent)
  ui.at(w - 1, top + 1, "^", ui.theme.accent)

  ui.at(1, bottom + 1, ui.fit(("%.0fm across   %d cells surveyed")
        :format(spanX, terrain.size(map)), w, true), ui.theme.dim)
end

local function drawLog(w, h)
  local entries = log.recent(h - 3)
  if #entries == 0 then
    ui.at(2, 3, "Nothing has happened yet.", ui.theme.dim)
    return
  end

  -- Which causes are routine. Everything else is coloured as a guard, so a
  -- screen full of ordinary leg changes cannot hide the one diversion in the
  -- middle of it.
  local ROUTINE = { arrived = true, fly = true, cleared = true, manual = true,
                    airborne = true, down = true, docked = true,
                    ["at altitude"] = true, handback = true }

  local y = 2
  for _, entry in ipairs(entries) do
    if y > h - 1 then break end
    ui.at(1, y, log.time(entry.at), ui.theme.dim)
    ui.at(7, y, ui.fit(entry.name or ("ship " .. tostring(entry.ship)), 11, true),
          ui.theme.text)
    ui.at(19, y, ui.fit(("%s > %s"):format(log.value(entry.from),
          log.value(entry.to)), math.max(0, w - 19 - 12), true), ui.theme.dim)
    ui.at(w - 11, y, ui.fit(entry.why, 11, true),
          ROUTINE[entry.why] and ui.theme.dim or ui.guardColour(entry.why))
    y = y + 1
  end
end

--- Waypoints, and which one is home.
--
-- The tower owns this table and every ship depends on it, so being able to read
-- it without a pocket computer in hand is worth a view of its own.
local function drawNav(w, h)
  local names = nav.names(waypoints())
  if #names == 0 then
    ui.at(2, 3, "No waypoints.", ui.theme.dim)
    ui.at(2, 5, "Put one down from the pocket computer:", ui.theme.dim)
    ui.at(2, 6, "the nav tab, + waypoint here.", ui.theme.dim)
    return
  end

  ui.fill(1, 2, w, 1, ui.theme.panel)
  ui.at(2, 2, "waypoint", ui.theme.bg, ui.theme.panel)
  ui.at(16, 2, "kind", ui.theme.bg, ui.theme.panel)
  ui.at(23, 2, "position", ui.theme.bg, ui.theme.panel)

  local y = 3
  for _, name in ipairs(names) do
    if y > h - 1 then break end
    local wp = waypoints()[name]
    local home = (state.data.home == name)

    ui.at(2, y, ui.fit((home and "*" or " ") .. name, 13, true),
          home and ui.theme.ok or ui.theme.text)
    ui.at(16, y, ui.fit(wp.kind or "point", 6, true), ui.theme.dim)
    ui.at(23, y, ui.fit(("%d %d %d"):format(wp.x, wp.y or 0, wp.z), w - 36, true),
          ui.theme.dim)
    -- A beacon is a waypoint that maintains itself, which is worth telling
    -- apart from one somebody tapped in and may have moved away from.
    if wp.beacon and w >= 46 then
      ui.at(w - 12, y, ui.fit(wp.occupied and "pad busy" or "beacon", 12, true),
            wp.occupied and ui.theme.warn or ui.theme.ok)
    end
    y = y + 1
  end
end

local function render()
  local w, h = term.getSize()

  ui.paint(ui.theme.text, ui.theme.bg)
  term.clear()

  local flying = 0
  for _, s in ipairs(roster()) do
    if not s.stale and s.tlm.flight and s.tlm.flight.state ~= "idle" then
      flying = flying + 1
    end
  end

  -- The header is the alarm as well as the title. If anything out there is on a
  -- guard the whole bar turns that colour, so the tower is readable across a
  -- room before anybody has read a word of it.
  local alarm = nil
  for _, s in ipairs(roster()) do
    if s.stale then
      alarm = alarm or "lost"
    elseif s.tlm.flight and s.tlm.flight.guard then
      alarm = s.tlm.flight.guard
    end
  end

  local banner = alarm and ui.guardColour(alarm) or ui.theme.accent
  ui.fill(1, 1, w, 1, banner)

  -- The alarm goes **first**, not after the title. There are twenty-four columns
  -- of tabs on the right of this bar, so the header is cut at about half the
  -- screen -- and appending the guard to a title meant the one word worth
  -- shouting was the one word that got trimmed off the end.
  local headline = alarm
    and ("%s  %d ships"):format(alarm:upper(), #roster())
    or ("AERO  %d ships, %d flying"):format(#roster(), flying)

  ui.at(2, 1, ui.fit(headline, math.max(0, w - 27)), ui.theme.bg, banner)

  -- Tabs sit in the header on the tower: the bottom row is the status line and
  -- the screen is wide enough for both.
  local layout = ui.tabLayout(TABS, 24)
  fleet.tabs = {}
  for _, tab in ipairs(layout) do
    local on = (fleet.screen == tab.name)
    local x = w - 24 + tab.x - 1
    fleet.tabs[#fleet.tabs + 1] = { name = tab.name, x = x, w = tab.w }
    if on then ui.fill(x, 1, tab.w, 1, ui.theme.bg) end
    ui.at(x, 1, ui.centre(tab.name, tab.w),
          on and ui.theme.select or ui.theme.bg,
          on and ui.theme.bg or banner)
  end

  ui.paint(ui.theme.text, ui.theme.bg)

  if fleet.screen == "ships" then drawShips(w, h)
  elseif fleet.screen == "map" then drawMap(w, h)
  elseif fleet.screen == "nav" then drawNav(w, h)
  else drawLog(w, h) end

  if fleet.note then
    ui.at(1, h, ui.fit(fleet.note, w, true), ui.theme.select, ui.theme.bg)
  else
    ui.at(1, h, ui.fit(("Tab: view   Q: quit   %s"):format(state.data.home
          and ("home " .. state.data.home) or "no home set"), w, true),
          ui.theme.dim, ui.theme.bg)
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

      -- Survey as a side effect of flying. A ship reporting where it is and how
      -- far the ground is below it has just measured the ground, and that is
      -- worth remembering: it is the difference between discovering a hill by
      -- nearly hitting it and knowing about it before setting off.
      if msg.pos and msg.alt and msg.clearance then
        if terrain.note(map, msg.pos.x, msg.pos.z, msg.alt - msg.clearance,
                        now()) then
          state.mark()
        end
      end
    end
    return
  end

  ------------------------------------------------------------------------------
  if msg.type == "beacon" then
    -- A waypoint that stands still. It registers itself, so nobody has to walk
    -- there with a pocket computer, and unlike a tapped-in point it can measure
    -- what is above it.
    local ok, why = nav.put(waypoints(), {
      name = msg.name, x = msg.x, y = msg.y, z = msg.z,
      kind = msg.kind, note = msg.note,
    })

    if not ok then
      net.send(from, { type = "error", reason = why })
      return
    end

    -- The measurement, which is the part a tapped-in waypoint cannot give. A
    -- beacon standing under a canopy reports the canopy, so a route through it
    -- is planned over the top rather than into it.
    local height = tonumber(msg.obstruction) or tonumber(msg.ground)
    if height then terrain.note(map, msg.x, msg.z, height, now()) end

    waypoints()[msg.name].beacon = from
    waypoints()[msg.name].occupied = msg.occupied
    state.mark()
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

    -- Stamped with whoever actually sent it, so a ship holds the conn for the
    -- person at the pocket computer rather than for this tower. Without it every
    -- relayed order would look like it came from the same place and one person
    -- taking control would silently give it to everybody.
    body.sender = body.sender or from
    body.who = body.who or msg.who

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

map = terrain.load(state.data.terrain)

term.clear()
term.setCursorPos(1, 1)

if not net.open() then
  ui.paint(ui.theme.bad, ui.theme.bg)
  print("No wireless modem. A tower with no radio is a chair.")
  ui.paint(ui.theme.text, ui.theme.bg)
  return
end

-- Two towers would both fan out commands and both keep a log, and the log would
-- then be half the story in two places. Ask before claiming the job.
net.broadcast({ type = "server?" })
local answered = select(2, net.receive(2))
if type(answered) == "table" and answered.type == "server!" then
  ui.paint(ui.theme.warn, ui.theme.bg)
  print("Another tower is already up on this network.")
  print("Standing down.")
  ui.paint(ui.theme.text, ui.theme.bg)
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
    state.data.terrain = map
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
    -- b, c are the column and row for a mouse_click; a monitor_touch puts the
    -- side in `a` and the coordinates in the same two places, so one branch
    -- serves both.
    local x, y = b, c
    if event == "monitor_touch" then x, y = b, c end

    if y == 1 then
      -- The header. Tapping a tab picks it; tapping anywhere else on the bar
      -- cycles, which is the only gesture a monitor without a keyboard has.
      local picked = nil
      for _, tab in ipairs(fleet.tabs) do
        if x >= tab.x and x < tab.x + tab.w then picked = tab.name end
      end

      if picked then
        fleet.screen = picked
      else
        local index = 1
        for i, name in ipairs(TABS) do if name == fleet.screen then index = i end end
        fleet.screen = TABS[(index % #TABS) + 1]
      end

    elseif fleet.screen == "ships" and fleet.rows then
      ui.click(fleet.rows, y)
    end

    redraw()

  elseif event == "mouse_scroll" then
    if fleet.rows then
      fleet.rows.scroll = fleet.rows.scroll + a
      redraw()
    end

  elseif event == "term_resize" or event == "monitor_resize" then
    W, H = term.getSize()
    redraw()

  elseif event == "terminate" then
    break
  end
end

state.data.log = log.entries
state.data.terrain = map
state.flush(now())

term.clear()
term.setCursorPos(1, 1)
ui.paint(ui.theme.text, ui.theme.bg)
print("Tower closed. Every ship carries on by itself.")
