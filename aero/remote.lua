--- Flight remote. Runs on an advanced pocket computer.
--
-- The thing you carry: see where the fleet is, send it somewhere, put a waypoint
-- down where you are standing, and tune a ship that is not flying the way you
-- want. It holds no authoritative state of its own and never guesses -- a ship
-- that has gone quiet says LOST rather than showing the last position it had as
-- though it were live. A dashboard confidently drawing a ship where it was ten
-- seconds ago is worse than one that admits it does not know, because somebody
-- will go and look there.
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
-- Five screens. Four are tabs along the bottom, where a thumb is; the fifth is a
-- ship's own panel, reached by picking it out of the fleet, and is where the
-- things that belong to one ship live -- its gauges, its hull, its gains.
--
-- Deliberately not read() anywhere: it blocks the event loop, telemetry stops
-- arriving, and the link reads LOST while you type.

local config = require("lib.config")
local net    = require("lib.net")
local nav    = require("lib.nav")
local log    = require("lib.log")
local ui     = require("lib.ui")

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
  asked  = {},          -- [id] = when we last asked for one
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

local screen = "fleet"     -- one of TABS, or "ship"
local list   = ui.list()
local flash  = nil
local logs   = {}
local typing = nil

local selected = nil       -- ship id, or nil for the whole fleet
local plan = { names = {}, alt = 100 }

local function note(text) flash = ui.flash(text, now()) end

--- The selected ship's row out of the roster, or nil.
local function ship()
  if not selected then return nil end
  for _, s in ipairs(roster()) do
    if s.id == selected then return s end
  end
  return nil
end

--- Ask a ship to describe its hull, at most once every few seconds.
--
-- The reply is a whole control list and does not change while the ship is
-- flying, so asking on every redraw would be several frames a second of traffic
-- for an answer we already have.
local function wantHull(id)
  if link.hulls[id] then return link.hulls[id] end
  if (now() - (link.asked[id] or -math.huge)) < 3 then return nil end
  link.asked[id] = now()
  net.send(id, { type = "hull?" })
  return nil
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
-- Rows
--------------------------------------------------------------------------------

local function row(entry) return ui.row(list, entry) end

local function buildFleet()
  local fleet = roster()
  if #fleet == 0 then
    row({ kind = "note", text = "No ships answering." })
    return
  end

  for _, s in ipairs(fleet) do
    row({ kind = "ship", ship = s, click = function()
      selected = (selected == s.id) and nil or s.id
    end })
  end

  -- One ship picked out means its own panel is worth offering. With none
  -- picked, the buttons below command the whole fleet, which is the other
  -- genuinely useful mode and needs no extra control to reach.
  if selected then
    row({ kind = "action", text = "SHIP   gauges, hull, gains",
          colour = ui.theme.accent,
          click = function() screen = "ship" list.scroll = 0 end })
  end

  row({ kind = "gap" })
  row({ kind = "action", text = "HOLD   stop and hover", colour = ui.theme.warn,
        click = function() order({ type = "hold" }, "holding") end })
  row({ kind = "action", text = "LAND   come down here", colour = ui.theme.warn,
        click = function() order({ type = "land" }, "landing") end })
  row({ kind = "action", text = "RTB    return to base", colour = ui.theme.ok,
        click = function() order({ type = "rtb" }, "returning") end })
  row({ kind = "action", text = "STOP   descend now", colour = ui.theme.bad,
        click = function() order({ type = "stop" }, "descending") end })
end

--- One ship: what it is doing, what it is made of, and how it is tuned.
local function buildShip()
  local s = ship()
  if not s then
    row({ kind = "note", text = "That ship has gone." })
    row({ kind = "action", text = "< back", colour = ui.theme.accent,
          click = function() screen = "fleet" end })
    return
  end

  row({ kind = "action", text = "< " .. (s.label or ("ship " .. s.id)),
        colour = ui.theme.accent,
        click = function() screen = "fleet" list.scroll = 0 end })

  local flight = s.flight or {}
  local tlm = link.ships[s.id] or {}

  row({ kind = "head", label = flight.state or "?",
        colour = ui.stateColour[flight.state] })

  -- Gauges rather than numbers where a gauge says it faster: altitude against
  -- the target it was given, and fuel against the tank.
  row({ kind = "gauge", label = ("alt %s"):format(ui.num(s.alt)),
        value = s.alt, lo = 0, hi = math.max(1, (flight.alt or s.alt or 1) * 1.5),
        colour = ui.theme.cold })

  if tlm.capacity and tlm.capacity > 0 then
    row({ kind = "gauge", label = ("fuel %ss"):format(ui.num(tlm.burn)),
          value = tlm.fuel, lo = 0, hi = tlm.capacity,
          colour = (tlm.burn and tlm.burn < 120) and ui.theme.bad or ui.theme.ok })
  end

  row({ kind = "pair", left = "speed", right = ui.num(s.speed, "%.1f") })
  row({ kind = "pair", left = "hdg", right = ui.num(s.heading) })
  row({ kind = "pair", left = "vs", right = ui.num(tlm.vs, "%+.1f") })
  row({ kind = "pair", left = "tilt", right = ui.num(tlm.tilt) })
  row({ kind = "pair", left = "fix", right = tostring(s.source or "-") })
  if flight.guard then
    row({ kind = "pair", left = "guard", right = flight.guard,
          colour = ui.guardColour(flight.guard) })
  end

  -- The hull. The pocket has no /craft.cfg of its own -- it learns what a ship
  -- is made of by asking, which is also the quickest way to find out that the
  -- bearing you thought was lift is not attached.
  local hull = wantHull(s.id)
  row({ kind = "head", label = "hull" })

  if not hull then
    row({ kind = "note", text = "  asking..." })
  else
    for _, control in ipairs(hull.controls or {}) do
      row({ kind = "control", control = control })
    end
    for _, why in ipairs(hull.problems or {}) do
      row({ kind = "note", text = why, colour = ui.theme.warn })
    end
  end

  -- Gains. Reinstalling to try 0.4 instead of 0.35 is not a tuning loop anybody
  -- will use, so the numbers that decide how a ship flies are editable from the
  -- thing in your hand while it is in the air in front of you.
  if hull then
    row({ kind = "head", label = "gains" })

    local TUNABLE = { "hover", "altP", "vsP", "vsI", "hdgP", "spdP" }
    for _, key in ipairs(TUNABLE) do
      local value = (hull.gains or {})[key]
      row({
        kind = "gain", key = key, value = value,
        click = function(x)
          local gains = {}
          for k, v in pairs(hull.gains or {}) do gains[k] = v end

          -- A tenth of the current value per tap, so one control works for a
          -- gain of 0.5 and a gain of 0.015 without needing to know which is
          -- which. Never below zero: a negative gain is a loop that drives the
          -- ship away from what it was asked for.
          local base = tonumber(value) or 0
          local step = math.max(0.001, math.abs(base) * 0.1)
          local up = (x or 0) >= W - 1
          gains[key] = math.max(0, base + (up and step or -step))

          net.send(s.id, { type = "tune", gains = gains })
          -- Optimistic, and corrected by the next hull reply. Waiting for the
          -- round trip makes a button feel broken on a link that is merely slow.
          hull.gains = gains
          link.asked[s.id] = -math.huge
          note(("%s %.3f"):format(key, gains[key]))
        end,
      })
    end
  end
end

local function buildFly()
  local wp = waypoints()
  local names = nav.names(wp)

  if #names == 0 then
    row({ kind = "note", text = "No waypoints yet." })
    row({ kind = "note", text = "Add one on the nav tab." })
    return
  end

  row({ kind = "head", label = ("alt %d"):format(plan.alt) })
  row({ kind = "step", text = "  altitude", click = function(x)
    plan.alt = math.max(0, plan.alt + (((x or 0) >= W - 1) and 10 or -10))
  end })

  row({ kind = "head", label = "route" })
  for i, name in ipairs(plan.names) do
    row({ kind = "leg", index = i, name = name,
          click = function() table.remove(plan.names, i) end })
  end
  if #plan.names == 0 then
    row({ kind = "note", text = "  tap a waypoint below" })
  end

  row({ kind = "gap" })
  row({ kind = "action", text = "FLY IT", colour = ui.theme.ok,
        click = function()
          if #plan.names == 0 then
            note("no route")
            return
          end
          order({ type = "fly", names = plan.names, alt = plan.alt }, "flying")
        end })

  if #plan.names > 1 and haveServer() then
    row({ kind = "action", text = "SAVE as...", colour = ui.theme.accent,
          click = function() typing = ui.field("route") end })
  end

  -- Routes the tower has kept, so a run you fly every day is two taps.
  local routes = (haveServer() and link.net and link.net.routes) or {}
  local routeNames = {}
  for name in pairs(routes) do routeNames[#routeNames + 1] = name end
  table.sort(routeNames)

  if #routeNames > 0 then
    row({ kind = "head", label = "routes" })
    for _, name in ipairs(routeNames) do
      local route = routes[name]
      row({ kind = "route", name = name, route = route, click = function()
        plan.names = {}
        for _, leg in ipairs(route.names or {}) do
          plan.names[#plan.names + 1] = leg
        end
        plan.alt = tonumber(route.alt) or plan.alt
        note("loaded " .. name)
      end })
    end
  end

  row({ kind = "head", label = "waypoints" })
  for _, name in ipairs(names) do
    row({ kind = "waypoint", name = name, point = wp[name], click = function()
      plan.names[#plan.names + 1] = name
      note("+ " .. name)
    end })
  end
end

local function buildNav()
  local wp = waypoints()

  row({ kind = "action", text = "+ waypoint here", colour = ui.theme.ok,
        click = function()
          if not haveServer() then note("waypoints need the tower") return end
          typing = ui.field("waypoint")
        end })

  row({ kind = "action", text = "+ pad here", colour = ui.theme.ok,
        click = function()
          if not haveServer() then note("waypoints need the tower") return end
          typing = ui.field("pad")
        end })

  row({ kind = "gap" })

  local names = nav.names(wp)
  if #names == 0 then
    row({ kind = "note", text = "No waypoints." })
    return
  end

  row({ kind = "head", label = "tap: home    x: delete" })

  local home = link.net and link.net.home
  for _, name in ipairs(names) do
    row({
      kind = "waypoint", name = name, point = wp[name], home = (home == name),
      delete = true,
      -- Two gestures on one row, because deleting is the more dangerous of the
      -- two and should not be the thing that happens when you tap a list you
      -- were reading. The x sits in the last column and nothing else does.
      click = function(x)
        if not haveServer() then note("needs the tower") return end
        if (x or 0) >= W then
          toServer({ type = "wp-", name = name })
          note("deleting " .. name)
        else
          toServer({ type = "home!", name = name })
        end
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

local function drawRow(entry, y, w)
  if entry.kind == "ship" then
    local s = entry.ship
    local chosen = (selected == s.id)
    if chosen then ui.fill(1, y, w, 1, colours.blue) end
    local bg = chosen and colours.blue or ui.theme.bg

    if s.stale then
      ui.at(1, y, ui.fit((chosen and ">" or " ") .. (s.label or ("ship " .. s.id)),
            12, true), ui.theme.bad, bg)
      ui.at(13, y, ui.fit("LOST", w - 13, true), ui.theme.bad, bg)
    else
      local flight = s.flight or {}
      ui.at(1, y, ui.fit((chosen and ">" or " ") .. (s.label or ("ship " .. s.id)),
            12, true), ui.theme.text, bg)
      ui.at(13, y, ui.fit(flight.state or "?", 8, true),
            ui.stateColour[flight.state] or ui.theme.dim, bg)
      ui.at(22, y, ("%4s"):format(ui.num(s.alt)), ui.theme.dim, bg)
    end

  elseif entry.kind == "gauge" then
    ui.bar(1, y, w, entry.value, entry.lo, entry.hi, entry.colour,
           " " .. entry.label)

  elseif entry.kind == "pair" then
    ui.at(1, y, ui.fit(" " .. entry.left, 9, true), ui.theme.dim)
    ui.at(10, y, ui.fit(entry.right, w - 10, true), entry.colour or ui.theme.text)

  elseif entry.kind == "control" then
    local c = entry.control
    ui.at(1, y, ui.fit(" " .. c.name, 10, true),
          c.ok and ui.theme.text or ui.theme.bad)
    ui.at(11, y, ui.fit(c.kind or "?", 7, true), ui.theme.dim)
    ui.at(18, y, ui.fit(c.ok and "ok" or "FAULT", w - 18, true),
          c.ok and ui.theme.ok or ui.theme.bad)

  elseif entry.kind == "gain" then
    ui.at(1, y, ui.fit(" " .. entry.key, 8, true), ui.theme.dim)
    ui.at(9, y, ui.fit(entry.value and ("%.3f"):format(entry.value) or "-",
          w - 13, true), ui.theme.text)
    ui.at(w - 3, y, "- +", ui.theme.accent)

  elseif entry.kind == "step" then
    ui.at(1, y, ui.fit(entry.text, w - 4, true), ui.theme.text)
    ui.at(w - 3, y, "- +", ui.theme.accent)

  elseif entry.kind == "waypoint" then
    local p = entry.point or {}
    ui.at(1, y, ui.fit((entry.home and "*" or " ") .. entry.name, 12, true),
          entry.home and ui.theme.ok or ui.theme.text)
    ui.at(13, y, ui.fit(("%d %d"):format(p.x or 0, p.z or 0),
          w - 14, true), ui.theme.dim)
    if p.kind == "pad" then ui.at(w - 1, y, "=", ui.theme.cold) end
    if entry.delete then ui.at(w, y, "x", ui.theme.bad) end

  elseif entry.kind == "route" then
    ui.at(1, y, ui.fit(" " .. entry.name, 14, true), ui.theme.text)
    ui.at(15, y, ui.fit(("%d legs"):format(#(entry.route.names or {})),
          w - 15, true), ui.theme.dim)

  elseif entry.kind == "leg" then
    ui.at(1, y, ui.fit(("%d %s"):format(entry.index, entry.name), w - 1, true),
          ui.theme.text)
    ui.at(w, y, "x", ui.theme.bad)

  elseif entry.kind == "log" then
    ui.at(1, y, ui.fit(log.line(entry.entry), w, true), ui.theme.dim)

  elseif entry.kind == "head" then
    ui.fill(1, y, w, 1, ui.theme.panel)
    ui.at(1, y, ui.fit(" " .. entry.label, w, true),
          entry.colour or ui.theme.bg, ui.theme.panel)

  elseif entry.kind == "action" then
    ui.at(1, y, ui.fit(" " .. entry.text, w, true), entry.colour or ui.theme.text)

  elseif entry.kind == "note" then
    ui.at(1, y, ui.fit(entry.text, w, true), entry.colour or ui.theme.dim)
  end

  ui.paint(ui.theme.text, ui.theme.bg)
end

local function draw()
  list.entries = {}
  if screen == "fleet" then buildFleet()
  elseif screen == "ship" then buildShip()
  elseif screen == "fly" then buildFly()
  elseif screen == "nav" then buildNav()
  else buildLog() end

  ui.paint(ui.theme.text, ui.theme.bg)
  term.clear()

  -- The header is the link light. Which of the two routes is live decides what
  -- half these screens can do, so it is never more than a glance away.
  local live, colour
  if haveServer() then live, colour = "TOWER ", ui.theme.ok
  elseif #roster() > 0 then live, colour = "DIRECT", ui.theme.warn
  else live, colour = " LOST ", ui.theme.bad end

  ui.fill(1, 1, W, 1, colour)
  ui.at(1, 1, ui.fit(" AERO", 6, true), ui.theme.bg, colour)
  ui.at(7, 1, ui.fit(selected and ("#" .. selected) or "all", W - 13, true),
        ui.theme.bg, colour)
  ui.at(W - 5, 1, live, ui.theme.bg, colour)

  local top, bottom = 3, H - 2
  if #list.entries == 0 then
    ui.at(1, 4, ui.fit(link.note, W, true), ui.theme.dim)
  end
  ui.draw(list, 1, top, W, bottom - top + 1, function(entry, y)
    drawRow(entry, y, W)
  end)

  -- Tabs on the bottom row, which is where a thumb is on a pocket computer.
  ui.tabs(H, W, TABS, screen == "ship" and "fleet" or screen)

  if typing then
    ui.drawField(typing, H - 1, W)
  else
    ui.drawFlash(flash, now(), H - 1, W)
  end

  ui.paint(ui.theme.text, ui.theme.bg)
end

--------------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------------

local function clickTab(x)
  local name = ui.tabAt(TABS, W, x)
  if not name then return end

  screen, list.scroll = name, 0
  if name == "log" then toServer({ type = "log?", n = 30 }) end
end

local function onClick(x, y)
  if y == H then return clickTab(x) end

  -- The column is handed to the row's own handler, because two of them have two
  -- gestures on one line -- delete at the far right, and the minus and plus of a
  -- stepper. Everything else ignores it.
  for _, entry in ipairs(list.entries) do
    if entry.y == y and entry.click then
      entry.click(x)
      return
    end
  end
end

local function onChar(ch) ui.type(typing, ch) end

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

local function commit()
  if typing.text == "" then return end

  if typing.prompt == "route" then
    toServer({ type = "route!", name = typing.text, names = plan.names,
               alt = plan.alt })
    note("saved " .. typing.text)
    return
  end

  local at = here()
  if not at then
    note("no GPS fix here")
    return
  end

  toServer({
    type = "wp!",
    name = typing.text,
    x = at.x, y = at.y, z = at.z,
    kind = typing.prompt == "pad" and "pad" or "point",
  })
  note("sent " .. typing.text)
end

local function onKey(key)
  if typing then
    if key == keys.enter then
      commit()
      typing = nil
    elseif key == keys.backspace then
      ui.backspace(typing)
    elseif key == keys.q then
      typing = nil
    end
    return
  end

  if key == keys.up then
    list.scroll = math.max(0, list.scroll - 1)
  elseif key == keys.down then
    list.scroll = list.scroll + 1
  elseif key == keys.tab then
    local index = 1
    for i, name in ipairs(TABS) do if name == screen then index = i end end
    screen = TABS[(index % #TABS) + 1]
    list.scroll = 0
    if screen == "log" then toServer({ type = "log?", n = 30 }) end
  elseif key == keys.q then
    -- Always quit, on every screen. Making it mean "back" on the ship panel was
    -- tried and taken out again: a quit key that sometimes does not quit is a
    -- worse trade than one extra tap, the panel already has a back row at the
    -- top of it, and the first thing the change did was hang the test harness,
    -- which ends every case by pressing exactly this.
    return "quit"
  end
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

term.clear()
term.setCursorPos(1, 1)

if not net.open() then
  ui.paint(ui.theme.bad, ui.theme.bg)
  print("No wireless modem.")
  print("This pocket computer needs one to see anything.")
  ui.paint(ui.theme.text, ui.theme.bg)
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
        elseif msg.of == "wp-" then
          note("deleted")
        elseif msg.of == "route!" then
          note("route saved")
        elseif msg.of == "tune" then
          -- The gains have moved, so the cached hull description is stale.
          link.hulls[from] = nil
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

  elseif event == "mouse_scroll" then
    list.scroll = math.max(0, list.scroll + a)
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
ui.paint(ui.theme.text, ui.theme.bg)
print("Remote closed. Every ship carries on.")
