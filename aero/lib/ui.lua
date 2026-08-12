--- The widgets all three programs draw with.
--
-- The other two suites in this repo redeclare their `colour`, `at` and `fit`
-- helpers in every file, and say so: at four lines each that is cheaper than a
-- dependency. This one has gauges, a compass, an artificial horizon and a
-- scrolling row list, and three copies of those would drift apart within a week
-- -- so the rule is deliberately broken here, once, with this note.
--
-- ## What it has to survive
--
--   * **26x20.** A pocket computer. Everything here takes a width and cuts to
--     it; nothing assumes it has room.
--   * **No colour.** A basic computer has one, and a pilot computer bolted to a
--     hull is quite likely to be one. Every colour goes through `ui.paint`,
--     which is a no-op without `term.isColour`, and nothing is drawn in a way
--     that only reads as different because it is a different colour.
--   * **Being redirected.** The tower draws the same screen to its terminal and
--     to a monitor through `term.redirect`, so nothing here may cache the
--     terminal or its size.
--
-- Pure layout arithmetic -- `fit`, `ratio`, `tapeRows`, `horizonRows` -- is
-- separated from anything that draws, because it is the part with off-by-ones in
-- it and the part a test can check without a screen.

local ui = {}

--------------------------------------------------------------------------------
-- Theme
--------------------------------------------------------------------------------

-- Named by **meaning**, not by colour. "warn" is a decision the caller has
-- already made; `colours.orange` is a decision it should not be making.
ui.theme = {
  bg      = colours.black,
  panel   = colours.grey,
  text    = colours.white,
  dim     = colours.lightGrey,
  accent  = colours.cyan,
  ok      = colours.lime,
  warn    = colours.orange,
  bad     = colours.red,
  cold    = colours.lightBlue,
  sky     = colours.lightBlue,
  ground  = colours.brown,
  select  = colours.yellow,
}

function ui.colour()
  return term.isColour ~= nil and term.isColour()
end

--- Set colours, or do nothing at all on a basic computer.
function ui.paint(fg, bg)
  if not ui.colour() then
    -- Still worth setting on mono: CC maps everything to black and white, and
    -- writing white on white is invisible either way.
    if fg then term.setTextColour(colours.white) end
    if bg then term.setBackgroundColour(colours.black) end
    return
  end
  if fg then term.setTextColour(fg) end
  if bg then term.setBackgroundColour(bg) end
end

--------------------------------------------------------------------------------
-- Text
--------------------------------------------------------------------------------

--- Cut or pad to exactly `width`. Pure.
--
-- Cut rather than wrapped, and marked with a full stop so a truncated name does
-- not read as a real one. Everything on these screens is drawn into a fixed
-- column and the alternative to cutting is a layout that shifts when a ship gets
-- a longer name.
function ui.fit(text, width, pad)
  text = tostring(text == nil and "" or text)
  if width <= 0 then return "" end
  if #text > width then return text:sub(1, math.max(0, width - 1)) .. "." end
  if pad then return text .. string.rep(" ", width - #text) end
  return text
end

--- Centre within a width, without ever exceeding it. Pure.
function ui.centre(text, width)
  text = ui.fit(text, width)
  local left = math.floor((width - #text) / 2)
  return string.rep(" ", math.max(0, left)) .. text
end

function ui.at(x, y, text, fg, bg)
  ui.paint(fg, bg)
  term.setCursorPos(x, y)
  term.write(text)
end

--- A number, rounded for a narrow column, with nothing pretending to be zero.
function ui.num(v, format)
  if v == nil then return "--" end
  return (format or "%.0f"):format(v)
end

--------------------------------------------------------------------------------
-- Panels
--------------------------------------------------------------------------------

--- Fill a rectangle. The only drawing primitive that is not text.
function ui.fill(x, y, w, h, colour)
  ui.paint(nil, colour)
  local blank = string.rep(" ", math.max(0, w))
  for row = 0, h - 1 do
    term.setCursorPos(x, y + row)
    term.write(blank)
  end
  ui.paint(nil, ui.theme.bg)
end

--- A titled panel: a header bar and a cleared body underneath.
--
-- Drawn with a filled row rather than box-drawing characters. CC's font has no
-- reliable corners, and a border made of dashes and plus signs costs two columns
-- and two rows on a screen that has twenty-six of one and twenty of the other.
function ui.panel(x, y, w, h, title, accent)
  ui.fill(x, y, w, 1, accent or ui.theme.panel)
  if title then
    ui.at(x + 1, y, ui.fit(title, w - 2), ui.theme.bg, accent or ui.theme.panel)
  end
  ui.paint(ui.theme.text, ui.theme.bg)
  if h > 1 then ui.fill(x, y + 1, w, h - 1, ui.theme.bg) end
end

--------------------------------------------------------------------------------
-- Gauges
--------------------------------------------------------------------------------

--- Where a value sits between two bounds, clamped to 0..1. Pure.
--
-- nil in, nil out. A gauge with no reading has to be able to draw itself as
-- empty and *say* so, which is not the same as drawing itself at zero -- the
-- whole difference between "no fuel reading" and "no fuel".
function ui.ratio(value, lo, hi)
  if value == nil then return nil end
  lo, hi = lo or 0, hi or 1
  if hi == lo then return 0 end
  local r = (value - lo) / (hi - lo)
  if r < 0 then return 0 end
  if r > 1 then return 1 end
  return r
end

--- A horizontal bar. `label` is drawn over the top of it.
function ui.bar(x, y, w, value, lo, hi, colour, label)
  local r = ui.ratio(value, lo, hi)

  ui.fill(x, y, w, 1, ui.theme.panel)
  if r then
    local filled = math.floor(r * w + 0.5)
    if filled > 0 then ui.fill(x, y, filled, 1, colour or ui.theme.ok) end
  end

  if label then
    -- Written across the whole bar so it stays readable whichever side the fill
    -- has reached. Two writes rather than one because the background changes
    -- half way along, and blit would need the fill computed twice anyway.
    local text = ui.fit(label, w)
    local filled = r and math.floor(r * w + 0.5) or 0
    for i = 1, #text do
      local ch = text:sub(i, i)
      local over = (i <= filled)
      ui.at(x + i - 1, y, ch,
            over and ui.theme.bg or ui.theme.text,
            over and (colour or ui.theme.ok) or ui.theme.panel)
    end
  end

  ui.paint(ui.theme.text, ui.theme.bg)
end

--- The rows of a vertical tape, centred on `value`. Pure.
--
-- Returns a list of { label, value, here } from the top down, so the caller only
-- has to draw strings. The tape is what makes an altitude readable at a glance:
-- a number tells you where you are and a tape tells you where you are *going*.
function ui.tapeRows(value, rows, step)
  if value == nil then return {} end
  step = step or 10

  local out = {}
  local middle = math.floor(rows / 2)

  for i = 0, rows - 1 do
    -- Top row is the highest, so the tape reads the way the world does.
    local offset = (middle - i) * step
    local at = math.floor(value / step + 0.5) * step + offset
    out[#out + 1] = { value = at, here = (i == middle) }
  end
  return out
end

--- A compass strip centred on `heading`, `w` characters wide. Pure.
--
-- Returns the string. Degrees per character is fixed at 3 so the strip covers
-- about a quadrant on a pocket screen -- wide enough to see the next cardinal
-- coming, narrow enough that a ten degree correction visibly moves it.
function ui.compassStrip(heading, w)
  if heading == nil then return string.rep("-", w) end

  local PER = 3
  local marks = { [0] = "S", [90] = "W", [180] = "N", [270] = "E" }

  local out = {}
  for i = 0, w - 1 do
    local degrees = heading + (i - math.floor(w / 2)) * PER
    degrees = degrees % 360
    if degrees < 0 then degrees = degrees + 360 end

    local rounded = math.floor(degrees / PER + 0.5) * PER % 360
    local char = "-"
    for at, letter in pairs(marks) do
      if rounded == at then char = letter end
    end
    if char == "-" and rounded % 45 == 0 then char = "+" end
    out[#out + 1] = char
  end

  return table.concat(out)
end

--- Where the horizon sits on each column of a box, as a fractional row. Pure.
--
-- `pitch` moves it up and down, `roll` tips it. Returned as numbers rather than
-- drawn so the arithmetic -- which is the part that gets the sign backwards --
-- can be checked without a screen.
--
-- Positive pitch is nose down, matching lib/sable and lib/hull, and nose down
-- puts *more* ground in view, so the horizon moves up the screen.
function ui.horizonRows(pitch, roll, w, h)
  pitch, roll = pitch or 0, roll or 0

  local middle = h / 2
  local perDegree = h / 60          -- 60 degrees of pitch fills the box
  local centre = middle + pitch * perDegree

  local out = {}
  local slope = math.tan(math.rad(math.max(-80, math.min(80, roll))))

  for i = 0, w - 1 do
    local across = i - (w - 1) / 2
    -- Halved because a character cell is about twice as tall as it is wide, so
    -- an unscaled slope draws a forty-five degree roll at about sixty.
    out[#out + 1] = centre + across * slope * 0.5
  end
  return out
end

--- An artificial horizon in a box. Needs colour to mean anything; on a mono
--- screen it degrades to the numbers, which the caller draws anyway.
function ui.horizon(x, y, w, h, pitch, roll)
  if not ui.colour() then
    ui.fill(x, y, w, h, ui.theme.bg)
    ui.at(x, y + math.floor(h / 2), ui.fit(("P%s R%s")
      :format(ui.num(pitch, "%+.0f"), ui.num(roll, "%+.0f")), w), ui.theme.text)
    return
  end

  local rows = ui.horizonRows(pitch, roll, w, h)

  for i = 0, w - 1 do
    local split = rows[i + 1]
    for row = 0, h - 1 do
      local sky = (row + 0.5) < split
      ui.at(x + i, y + row, " ", ui.theme.text,
            sky and ui.theme.sky or ui.theme.ground)
    end
  end

  -- The aircraft symbol, fixed in the middle: the horizon moves, not this.
  local midY = y + math.floor(h / 2)
  local midX = x + math.floor(w / 2)
  ui.at(midX - 1, midY, "-o-", ui.theme.select, ui.theme.bg)
  ui.paint(ui.theme.text, ui.theme.bg)
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

--- A scrolling list whose entries carry their own click handlers.
--
-- Working out what was clicked from coordinates and the current screen was the
-- thing that went wrong most often in mining/remote.lua; a row that carries its
-- own action cannot drift out of step with where it was drawn. This is that
-- pattern from redstone/remote.lua, lifted out so all three programs share it.
function ui.list()
  return { entries = {}, scroll = 0 }
end

function ui.row(list, entry)
  list.entries[#list.entries + 1] = entry
  return entry
end

--- Draw the visible window of a list, stamping each entry with the row it
--- landed on. `draw` is called as draw(entry, y, width).
function ui.draw(list, x, y, w, h, draw)
  local most = math.max(0, #list.entries - h)
  if list.scroll > most then list.scroll = most end
  if list.scroll < 0 then list.scroll = 0 end

  for i = 1, h do
    local entry = list.entries[i + list.scroll]
    if entry then
      entry.y = y + i - 1
      draw(entry, entry.y, w)
    end
  end

  -- Scroll marks, only when there is something to scroll to. An arrow that is
  -- always there tells you nothing.
  if list.scroll > 0 then ui.at(x + w - 1, y, "^", ui.theme.dim) end
  if list.scroll < most then ui.at(x + w - 1, y + h - 1, "v", ui.theme.dim) end
end

--- Find and run the handler for a click. Returns true if something took it.
function ui.click(list, y)
  for _, entry in ipairs(list.entries) do
    if entry.y == y and entry.click then
      entry.click()
      return true
    end
  end
  return false
end

--------------------------------------------------------------------------------
-- Tabs
--------------------------------------------------------------------------------

--- Evenly spaced tabs across a width. Pure: returns { name, x, w } so the same
--- arithmetic decides where they are drawn and what a click at a column means.
function ui.tabLayout(names, w)
  local out = {}
  local each = math.floor(w / math.max(1, #names))

  for i, name in ipairs(names) do
    out[i] = {
      name = name,
      x = (i - 1) * each + 1,
      w = (i == #names) and (w - (i - 1) * each) or each,
    }
  end
  return out
end

function ui.tabs(y, w, names, selected)
  local layout = ui.tabLayout(names, w)
  ui.fill(1, y, w, 1, ui.theme.panel)

  for _, tab in ipairs(layout) do
    local on = (tab.name == selected)
    if on then ui.fill(tab.x, y, tab.w, 1, ui.theme.accent) end
    ui.at(tab.x, y, ui.centre(tab.name, tab.w),
          on and ui.theme.bg or ui.theme.text,
          on and ui.theme.accent or ui.theme.panel)
  end

  ui.paint(ui.theme.text, ui.theme.bg)
  return layout
end

--- Which tab a click at column x landed on, or nil. Pure.
function ui.tabAt(names, w, x)
  for _, tab in ipairs(ui.tabLayout(names, w)) do
    if x >= tab.x and x < tab.x + tab.w then return tab.name end
  end
  return nil
end

--------------------------------------------------------------------------------
-- Typing
--------------------------------------------------------------------------------

--- An inline text field.
--
-- Never `read()`. It blocks the event loop, so telemetry stops arriving and the
-- link reads LOST while you type -- which on a pocket computer looking at a ship
-- in the air is exactly the wrong moment to stop hearing from it.
function ui.field(prompt, pattern, limit)
  return { prompt = prompt, text = "", pattern = pattern or "[%w%-_]",
           limit = limit or 16 }
end

function ui.type(field, ch)
  if not field then return end
  if #field.text < field.limit and ch:match(field.pattern) then
    field.text = field.text .. ch
  end
end

function ui.backspace(field)
  if field then field.text = field.text:sub(1, -2) end
end

function ui.drawField(field, y, w)
  ui.at(1, y, ui.fit(field.prompt .. ": " .. field.text .. "_", w, true),
        ui.theme.select, ui.theme.bg)
end

--------------------------------------------------------------------------------

--- A one-line message that fades. Returns a table the caller keeps.
function ui.flash(text, now, seconds)
  return { text = text, until_ = now + (seconds or 3) }
end

function ui.drawFlash(flash, now, y, w, colour)
  if not flash or now >= flash.until_ then return false end
  ui.at(1, y, ui.fit(flash.text, w, true), colour or ui.theme.ok, ui.theme.bg)
  return true
end

--- The colour a flight state should be drawn in. One table, so the tower, the
--- pocket and the ship all agree about what orange means.
ui.stateColour = {
  idle = colours.grey, preflight = colours.yellow, takeoff = colours.yellow,
  climb = colours.yellow, cruise = colours.lime, descend = colours.yellow,
  approach = colours.yellow, land = colours.yellow, dock = colours.yellow,
  loiter = colours.orange, manual = colours.magenta, emergency = colours.red,
}

--- ...and the colour a guard should shout in.
function ui.guardColour(guard)
  if guard == nil then return ui.theme.dim end
  if guard == "manual" then return colours.magenta end
  if guard == "nofix" then return ui.theme.warn end
  return ui.theme.bad
end

return ui
