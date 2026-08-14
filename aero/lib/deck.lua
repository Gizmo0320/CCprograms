--- The flight deck: a big screen for somebody sitting in the ship.
--
-- `pilot.lua` already draws a cockpit on its own terminal, and that stays what it
-- is -- a compact instrument panel for the moment you climb up to a ship that is
-- parked somewhere it should not be. This is the other thing: a **monitor bolted
-- to the contraption**, read from the pilot's seat while the ship is flying.
--
-- The two are not the same screen made bigger. A 4x3 monitor at text scale 0.5 is
-- about 78x38, six times the area of the 51x19 terminal, and the right use of
-- that is not more numbers -- it is instruments that are read as *pictures*. A
-- tape tells you the altitude is falling before you have read a digit of it.
--
-- Two pages, because a cockpit and a nav display answer different questions:
--
--   flight   attitude, speed, altitude, heading. What the ship is doing now.
--   nav      the plan, leg by leg, with distances. Where it is going.
--
-- ## The rules this file follows
--
-- **Layout arithmetic is pure and separate from drawing.** `deck.layout` returns
-- rectangles and touches nothing; every draw function is handed one. That is the
-- part with the off-by-ones in it, and the part a test can check without a
-- screen -- the same split `lib/ui.lua` makes for the same reason.
--
-- **Where a button is drawn and what a touch at a column means are one
-- function.** `deck.actions` goes through `ui.tabLayout` for both, so they cannot
-- drift apart. The remote suite has a case for exactly that bug, after picking a
-- ship added a row and shifted every action below it.
--
-- **It renders at whatever size it is given.** Monitors come in every shape from
-- one block to eight by six, and a deck that assumed its own size would draw off
-- the edge of the small ones in silence. Below `deck.MIN_W` x `deck.MIN_H` there
-- is not room for an instrument worth reading, and it says so rather than drawing
-- a horizon two rows tall.

local ui = require("lib.ui")

local deck = {}

-- Under this there is no room for a horizon, a pair of tapes and a compass. A
-- 2x2 monitor at scale 0.5 is about 38x18, which is the first size that fits.
deck.MIN_W, deck.MIN_H = 36, 16

deck.pages = { "flight", "nav" }

--------------------------------------------------------------------------------
-- Where everything goes. Pure.
--------------------------------------------------------------------------------

--- Rectangles for every element, given the screen. Pure: no drawing, no globals.
--
-- Built from the bottom up, because the fixed-height furniture -- the button row,
-- the fix line, the readout panel, the compass -- is what the flexible middle has
-- to fit inside. Sizing the horizon first and hoping the rest fits underneath is
-- how a layout ends up drawing over its own footer on a short monitor.
function deck.layout(w, h)
  local buttons = h
  local fix     = h - 1

  -- The readout panel shrinks before anything else does: it is the part that is
  -- all numbers, and numbers are the thing the terminal cockpit already shows.
  local panelH = (h >= 26) and 4 or ((h >= 20) and 3 or 2)
  local panelY = fix - panelH

  -- The compass is two rows when there is room for a scale under the strip, one
  -- when there is not.
  local roseH = (h >= 22) and 2 or 1
  local roseY = panelY - roseH

  local bodyY = 2
  local bodyH = roseY - bodyY

  -- **The horizon fills the space and the tapes do not**, which is the whole
  -- difference between this looking like an aircraft and looking like a
  -- spreadsheet.
  --
  -- Both were tried the other way. Tapes given the full height of a 4x3 monitor
  -- were thirty rows deep and ran the speed scale down to minus sixteen -- a
  -- reading that cannot happen, on a scale nobody then trusts -- because a tape
  -- is read within a few rows of its pointer and everything past that is
  -- decoration. Capping the whole block instead left a twelve-row hole under it,
  -- which was worse: a big screen should gain something for being big.
  --
  -- So the picture grows and the scales stay legible, centred on the middle of
  -- the horizon exactly where a real display puts them. Fifteen rows of altitude
  -- tape is a seventy-block band, which is as much as is worth seeing at once.
  local tapeH = math.min(bodyH, 15)
  local tapeY = bodyY + math.floor((bodyH - tapeH) / 2)

  -- Tapes take a twelfth of the width each, within reason. Six columns is the
  -- narrowest that fits a five-digit altitude and its pointer.
  local tapeW = math.max(6, math.min(9, math.floor(w / 12)))

  return {
    w = w, h = h,
    ok = (w >= deck.MIN_W and h >= deck.MIN_H and bodyH >= 5),

    header  = { x = 1, y = 1, w = w, h = 1 },
    speed   = { x = 1, y = tapeY, w = tapeW, h = tapeH },
    horizon = { x = tapeW + 2, y = bodyY, w = w - 2 * tapeW - 2, h = bodyH },
    alt     = { x = w - tapeW + 1, y = tapeY, w = tapeW, h = tapeH },

    -- Two rows written over the foot of the horizon rather than given space of
    -- their own: they are what the picture is showing, and a real display
    -- annunciates over the horizon for the same reason.
    strip   = { x = tapeW + 2, y = bodyY + bodyH - 2,
                w = w - 2 * tapeW - 2, h = math.min(2, bodyH) },
    rose    = { x = 1, y = roseY, w = w, h = roseH },
    panel   = { x = 1, y = panelY, w = w, h = panelH },
    fix     = { x = 1, y = fix, w = w, h = 1 },
    buttons = { x = 1, y = buttons, w = w, h = 1 },

    -- The nav page uses the same furniture and gives the whole middle to the
    -- plan, so the two pages cannot disagree about where the buttons are.
    plan    = { x = 1, y = bodyY, w = w, h = roseY - bodyY },
  }
end

--------------------------------------------------------------------------------
-- What a touch can do
--------------------------------------------------------------------------------

-- Every one of these goes through `flight.command` exactly as an order from a
-- pocket computer does -- same conn, same guards, same log entry. A second
-- command path into the flight state is precisely the thing `lib/flight.lua`
-- exists to prevent, and a cockpit button that skipped `mayCommand` would let
-- somebody standing on the deck fight the person holding the ship.
--
-- `order` is nil for anything handled locally, like turning the page.
deck.actions = {
  { key = "page", label = "PAGE" },
  { key = "alt+", label = "ALT+",
    order = function(step) return { type = "alt", by = step } end },
  { key = "alt-", label = "ALT-",
    order = function(step) return { type = "alt", by = -step } end },
  { key = "hold", label = "HOLD",
    order = function() return { type = "hold" } end },
  { key = "land", label = "LAND",
    order = function() return { type = "land" } end },
  { key = "conn", label = "CONN",
    order = function() return { type = "take" } end },
}

--- The labels along the button row, in order.
function deck.labels()
  local out = {}
  for i, action in ipairs(deck.actions) do out[i] = action.label end
  return out
end

--- Which action a touch at (x, y) landed on, or nil. Pure.
--
-- Shares `ui.tabLayout` with the drawing below, so the column a button occupies
-- and the column a touch is read at are one calculation. Touching the header
-- turns the page as well, because on a monitor the header is the biggest thing
-- to hit and turning a page is the safest thing a stray elbow can do.
function deck.hit(w, h, x, y)
  local at = deck.layout(w, h)

  if y == at.header.y then return "page" end
  if y ~= at.buttons.y then return nil end

  local label = ui.tabAt(deck.labels(), w, x)
  for _, action in ipairs(deck.actions) do
    if action.label == label then return action.key end
  end
  return nil
end

--- The order a key produces, or nil for a local action. Pure.
function deck.order(key, step)
  for _, action in ipairs(deck.actions) do
    if action.key == key then
      return action.order and action.order(step or 10) or nil
    end
  end
  return nil
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

local function header(at, view)
  local banner = view.guard and ui.guardColour(view.guard)
    or (ui.stateColour[view.state] or ui.theme.accent)

  ui.fill(at.header.x, at.header.y, at.header.w, 1, banner)

  local left = (" %s  %s"):format(view.label or "ship", (view.state or "?"):upper())
  if view.guard then left = left .. "  " .. view.guard:upper() end

  ui.at(1, at.header.y, ui.fit(left, at.header.w - 10, true), ui.theme.bg, banner)

  -- The page name at the far right, so the header doubles as the tab it is.
  ui.at(math.max(1, at.header.w - 9), at.header.y,
        ui.fit((view.page or "flight"):upper(), 9), ui.theme.bg, banner)
end

--- The bottom line: where the ship thinks it is, and how stale that is.
--
-- Last, and across the whole width, because everything above it is worthless if
-- the ship does not know where it is -- and a deck that showed a confident
-- horizon over a dead fix would be actively misleading.
local function fixLine(at, view)
  ui.fill(1, at.fix.y, at.fix.w, 1, ui.theme.bg)

  -- A refused order takes this line for a few seconds. It is the only place a
  -- deck ever says anything back, and it goes here rather than over an
  -- instrument: the answer to "why did nothing happen when I pressed that" is
  -- worth more than the position for six seconds, and the position is on every
  -- other screen in the fleet.
  if view.note then
    ui.at(1, at.fix.y, ui.fit(" " .. view.note, at.fix.w, true),
          ui.theme.warn, ui.theme.bg)
    return
  end

  local text = (" %s  %s%s"):format(
    view.source or "?",
    view.x and ("%d %d %d"):format(view.x, view.y or 0, view.z) or "no position",
    view.assembled == false and "  UNASSEMBLED" or "")

  ui.at(1, at.fix.y, ui.fit(text, at.fix.w, true),
        view.usable and ui.theme.dim or ui.theme.bad, ui.theme.bg)
end

local function buttons(at, view)
  local layout = ui.tabLayout(deck.labels(), at.buttons.w)
  ui.fill(1, at.buttons.y, at.buttons.w, 1, ui.theme.panel)

  for i, tab in ipairs(layout) do
    local action = deck.actions[i]

    -- A button that cannot be pressed is drawn dim rather than hidden. A control
    -- that disappears when it would be refused teaches nobody why, and the whole
    -- point of the conn is that being refused is explicable.
    local live = (action.key == "page") or (action.key == "conn")
      or view.mayCommand ~= false

    ui.at(tab.x, at.buttons.y, ui.centre(tab.name, tab.w),
          live and ui.theme.bg or ui.theme.dim,
          live and ui.theme.accent or ui.theme.panel)
  end
  ui.paint(ui.theme.text, ui.theme.bg)
end

--- The compass, with the target heading bugged on it.
local function rose(at, view)
  ui.fill(1, at.rose.y, at.rose.w, at.rose.h, ui.theme.bg)
  ui.at(1, at.rose.y, ui.compassStrip(view.heading, at.rose.w), ui.theme.accent)

  local text = ("%s / %s"):format(ui.num(view.heading), ui.num(view.targetHeading))

  if at.rose.h < 2 then
    -- One row, on a small monitor: the numbers go over the right-hand end of the
    -- strip. Six columns of compass are worth less than knowing the heading, and
    -- a display that shows the picture but not the number is the wrong way round
    -- when there is only room for one of them.
    ui.at(math.max(1, at.rose.w - #text + 1), at.rose.y, text, ui.theme.text)
    return
  end

  local row = string.rep(" ", at.rose.w)
  ui.at(1, at.rose.y + 1, row, ui.theme.dim)

  -- The bug sits where the wanted heading is, in the same three-degrees-a-column
  -- the strip is drawn at. Without it the strip says which way the ship points
  -- and nothing about which way it is trying to.
  if view.heading and view.targetHeading then
    local delta = (view.targetHeading - view.heading + 540) % 360 - 180
    local column = math.floor(at.rose.w / 2) + math.floor(delta / 3 + 0.5) + 1
    if column >= 1 and column <= at.rose.w then
      ui.at(column, at.rose.y + 1, "^", ui.theme.ok)
    end
  end

  ui.at(math.max(1, at.rose.w - #text), at.rose.y + 1, text, ui.theme.text)
end

--- Control bars and the numbers that explain them.
local function panel(at, view)
  ui.fill(1, at.panel.y, at.panel.w, at.panel.h, ui.theme.bg)

  local half = math.floor(at.panel.w / 2)
  local y = at.panel.y

  -- Left: what the autopilot is actually asking the hull for. This is the one
  -- thing invisible from outside the ship and it explains most of the surprises
  -- -- a hull sitting on the pad with the lift bearing at full is a completely
  -- different problem from one with it at nothing.
  for _, entry in ipairs(view.controls or {}) do
    if y >= at.panel.y + at.panel.h then break end
    ui.bar(1, y, half - 1, entry.value, 0, 1, ui.theme.ok,
           (" %s %3d%%"):format(ui.fit(entry.name, 8, true), entry.value * 100))
    y = y + 1
  end

  if view.capacity and view.capacity > 0 and y < at.panel.y + at.panel.h then
    local low = view.burn and view.burn < 120
    ui.bar(1, y, half - 1, view.fuel, 0, view.capacity,
           low and ui.theme.bad or ui.theme.cold,
           (" fuel %ss"):format(ui.num(view.burn)))
  end

  -- Right: the readings a pilot checks rather than watches.
  local right = {
    { "clear", ui.num(view.clearance) },
    { "ahead", ui.num(view.ahead) },
    { "tilt",  ui.num(view.tilt) },
    { "conn",  view.commander or "nobody" },
  }

  for i, entry in ipairs(right) do
    if i > at.panel.h then break end
    local ry = at.panel.y + i - 1
    ui.at(half + 1, ry, ui.fit(entry[1], 7, true), ui.theme.dim)
    ui.at(half + 8, ry, ui.fit(entry[2], at.panel.w - half - 8, true),
          ui.theme.text)
  end
end

--------------------------------------------------------------------------------

local function flightPage(at, view)
  -- Speed on the left and altitude on the right, which is the way round every
  -- real primary flight display puts them. Worth matching: anybody who has seen
  -- one reads this without being told, and there is no reason to be original
  -- about it.
  -- Floored at zero: a ship cannot fly backwards, and a scale offering readings
  -- that cannot happen is one you stop trusting the rest of.
  ui.tape(at.speed.x, at.speed.y, at.speed.w, at.speed.h,
          view.speed, view.targetSpeed, 2, ui.theme.dim, 0)
  ui.tape(at.alt.x, at.alt.y, at.alt.w, at.alt.h,
          view.alt, view.targetAlt, 10, ui.theme.dim)

  ui.horizon(at.horizon.x, at.horizon.y, at.horizon.w, at.horizon.h,
             view.pitch, view.roll)

  -- Annunciated over the foot of the horizon: pitch, roll and vertical speed are
  -- what the picture is showing, and where the ship is going is the question a
  -- pilot asks between glances at it. Putting either anywhere else would make
  -- three instruments out of one.
  if at.strip.h > 0 then
    ui.fill(at.strip.x, at.strip.y, at.strip.w, at.strip.h, ui.theme.bg)

    local leg = nil
    for _, entry in ipairs(view.legs or {}) do
      if entry.current then leg = entry end
    end

    local line = leg
      and (" to %s   %sm to run"):format(leg.name, ui.num(leg.distance))
      or " no plan"
    ui.at(at.strip.x, at.strip.y, ui.centre(line, at.strip.w),
          leg and ui.theme.accent or ui.theme.dim, ui.theme.bg)
  end

  local readout = ("P %s   R %s   VS %s")
    :format(ui.num(view.pitch, "%+.0f"), ui.num(view.roll, "%+.0f"),
            ui.num(view.vs, "%+.1f"))
  ui.at(at.horizon.x, at.horizon.y + at.horizon.h - 1,
        ui.centre(readout, at.horizon.w),
        (view.tilt and view.tilt > 25) and ui.theme.bad or ui.theme.text,
        ui.theme.bg)

  rose(at, view)
  panel(at, view)
end

local function navPage(at, view)
  ui.fill(at.plan.x, at.plan.y, at.plan.w, at.plan.h, ui.theme.bg)

  local bottom = at.plan.y + at.plan.h
  local y = at.plan.y

  -- Columns, so the numbers line up down the page rather than trailing each
  -- name. A list of destinations is read by scanning one column at a time.
  local nameW = math.max(14, math.floor(at.plan.w * 0.34))
  local distX = nameW + 3
  local atX   = distX + 12

  ui.fill(1, y, at.plan.w, 1, ui.theme.panel)
  ui.at(2, y, ui.fit("flight plan", nameW, true), ui.theme.bg, ui.theme.panel)
  ui.at(distX, y, ui.fit("to run", 10, true), ui.theme.bg, ui.theme.panel)
  ui.at(atX, y, ui.fit("at", at.plan.w - atX, true), ui.theme.bg, ui.theme.panel)
  ui.paint(ui.theme.text, ui.theme.bg)
  y = y + 1

  local legs = view.legs or {}
  if #legs == 0 then
    ui.at(2, y + 1, ui.fit("no plan -- this ship is going nowhere",
          at.plan.w - 2, true), ui.theme.dim)
    y = y + 3
  end

  local total = 0
  for _, leg in ipairs(legs) do
    total = total + (leg.distance or 0)

    if y < bottom then
      -- The leg being flown is marked and coloured; the rest are dim. A list
      -- where every row looks the same makes you count to find out where the
      -- ship actually is.
      local here = leg.current
      ui.at(1, y, ui.fit(("%s %s"):format(here and ">" or " ", leg.name),
            nameW + 1, true), here and ui.theme.select or ui.theme.text)
      ui.at(distX, y, ui.fit(("%sm"):format(ui.num(leg.distance)), 10, true),
            here and ui.theme.text or ui.theme.dim)

      if leg.x then
        ui.at(atX, y, ui.fit(("%d %d %d"):format(leg.x, leg.y or 0, leg.z),
              at.plan.w - atX, true), ui.theme.dim)
      end
      y = y + 1
    end
  end

  y = y + 1

  -- What the plan adds up to. The distance left and how long it will take are
  -- the two things a list of legs does not answer by itself, and they are the
  -- two anybody actually wants from a nav display.
  local eta = (view.speed and view.speed > 0.5 and total > 0)
    and (total / view.speed) or nil

  local summary = {
    { "to run", total > 0 and (ui.num(total) .. "m") or "-" },
    { "eta", eta and ("%dm %02ds"):format(math.floor(eta / 60), eta % 60) or "-" },
    { "alt", ("%s / %s"):format(ui.num(view.alt), ui.num(view.targetAlt)) },
    { "spd", ("%s / %s"):format(ui.num(view.speed, "%.1f"),
                                ui.num(view.targetSpeed)) },
    { "hdg", ("%s / %s"):format(ui.num(view.heading),
                                ui.num(view.targetHeading)) },
    { "home", view.home or "not set" },
  }

  for _, entry in ipairs(summary) do
    if y >= bottom then break end
    ui.at(2, y, ui.fit(entry[1], 8, true), ui.theme.dim)
    ui.at(10, y, ui.fit(entry[2], at.plan.w - 10, true), ui.theme.text)
    y = y + 1
  end

  -- Anything wrong with the hull, last and in the space left over. This is the
  -- one screen on the ship with room for it, and a warning that only ever
  -- appeared in a boot log scrolled past a second later is a warning nobody has
  -- ever read.
  local problems = view.problems or {}
  if #problems > 0 and y + 1 < bottom then
    y = y + 1
    ui.at(2, y, ui.fit("what is wrong", at.plan.w - 2, true), ui.theme.warn)
    y = y + 1
    for _, why in ipairs(problems) do
      if y >= bottom then break end
      ui.at(2, y, ui.fit(why, at.plan.w - 2, true), ui.theme.dim)
      y = y + 1
    end
  end

  rose(at, view)
  panel(at, view)
end

--------------------------------------------------------------------------------

--- Draw the whole deck to whatever terminal is current.
--
-- `view` is a plain table assembled by the caller. Nothing here reaches into
-- `hull` or `flight` -- which is what lets the whole screen be rendered into a
-- window in a test, and what stops a drawing bug being a flying bug.
function deck.draw(view)
  local w, h = term.getSize()
  local at = deck.layout(w, h)

  ui.paint(ui.theme.text, ui.theme.bg)
  term.clear()

  if not at.ok then
    -- Too small to instrument. Say so, and fall back to the numbers that matter
    -- most -- a monitor showing nothing at all looks broken, and somebody will
    -- go looking for a fault that is really a one-block screen.
    ui.at(1, 1, ui.fit(" " .. (view.label or "ship"), w, true),
          ui.theme.bg, ui.theme.accent)
    ui.at(1, 2, ui.fit((view.state or "?"):upper(), w),
          ui.stateColour[view.state] or ui.theme.text)
    ui.at(1, 3, ui.fit(("alt %s"):format(ui.num(view.alt)), w), ui.theme.text)
    ui.at(1, 4, ui.fit(("hdg %s"):format(ui.num(view.heading)), w), ui.theme.text)
    if h >= 6 then
      ui.at(1, 6, ui.fit("monitor too small for the deck", w), ui.theme.dim)
    end
    ui.paint(ui.theme.text, ui.theme.bg)
    return at
  end

  header(at, view)

  if view.page == "nav" then navPage(at, view) else flightPage(at, view) end

  fixLine(at, view)
  buttons(at, view)

  ui.paint(ui.theme.text, ui.theme.bg)
  return at
end

return deck
