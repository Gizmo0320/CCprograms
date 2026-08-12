--- The manual, in game.
--
--   guide            open it
--   guide balloon    open it at the first topic mentioning balloons
--
-- Runs on anything: the ship's own computer, the tower, the pocket. The text
-- lives in lib/guide.lua and is written for twenty-six columns, so it reads the
-- same on all three.
--
-- Worth having for one reason: the moment you need to know why a ship will not
-- take off is the moment you are standing next to it in a cave, and a README on
-- a website is not reachable from there. The mod does the same thing with
-- /rom/thrusters/docs.lua.

local guide = require("lib.guide")
local ui    = require("lib.ui")

local args = { ... }

local topics = guide.topics
local selected, scroll = 1, 0
local typing = nil

-- Opened at whatever was asked for on the command line, which makes
-- `guide bingo` a reasonable thing to type when a ship has just turned round.
if args[1] then
  local found = guide.search(table.concat(args, " "))
  if #found > 0 then topics = found end
end

--------------------------------------------------------------------------------

local function draw()
  local w, h = term.getSize()
  local topic = topics[selected]

  ui.paint(ui.theme.text, ui.theme.bg)
  term.clear()

  -- The header carries the position in the manual, because "is there more of
  -- this" is the first thing anybody wants to know.
  ui.fill(1, 1, w, 1, ui.theme.accent)
  ui.at(1, 1, ui.fit((" %d/%d %s"):format(selected, #topics, topic.title), w, true),
        ui.theme.bg, ui.theme.accent)

  local body = guide.wrap(topic.body, w)
  local rows = h - 2

  local most = math.max(0, #body - rows)
  if scroll > most then scroll = most end
  if scroll < 0 then scroll = 0 end

  for i = 1, rows do
    local line = body[i + scroll]
    if line then
      -- A line that is all capitals is a heading in these topics, and picking it
      -- out is the difference between a wall of text and something skimmable.
      local shout = line:match("^%s*[A-Z][A-Z ]+$") ~= nil
      ui.at(1, i + 1, ui.fit(line, w, true),
            shout and ui.theme.select or ui.theme.text)
    end
  end

  if scroll > 0 then ui.at(w, 2, "^", ui.theme.dim) end
  if scroll < most then ui.at(w, h - 1, "v", ui.theme.dim) end

  if typing then
    ui.drawField(typing, h, w)
  else
    ui.fill(1, h, w, 1, ui.theme.panel)
    -- Only the keys that exist. A pocket computer has no page keys worth
    -- mentioning and listing them would be a lie on the device most likely to be
    -- reading this.
    ui.at(1, h, ui.fit(w >= 40
      and " <- -> topic   up/down scroll   / search   Q quit"
      or " <-/->  up/down  / find  Q", w, true), ui.theme.bg, ui.theme.panel)
  end

  ui.paint(ui.theme.text, ui.theme.bg)
end

local function go(delta)
  if #topics == 0 then return end
  selected = ((selected - 1 + delta) % #topics) + 1
  scroll = 0
end

--------------------------------------------------------------------------------

draw()

while true do
  local event, a, b, c = os.pullEvent()
  local w, h = term.getSize()

  if typing then
    if event == "char" then
      ui.type(typing, a)
    elseif event == "key" then
      if a == keys.enter then
        local found = guide.search(typing.text)
        if #found == 0 then
          topics = { { title = "Nothing found",
                       body = "No topic mentions '" .. typing.text .. "'.\n\n"
                              .. "Press / to look for something else." } }
        else
          topics = found
        end
        selected, scroll, typing = 1, 0, nil
      elseif a == keys.backspace then
        ui.backspace(typing)
      elseif a == keys.q then
        typing = nil
      end
    end
    draw()

  elseif event == "char" and a == "/" then
    -- Typed rather than read(), for the same reason as everywhere else here: a
    -- blocking read is a program that has stopped listening.
    typing = ui.field("find", ".", 20)
    draw()

  elseif event == "key" then
    if a == keys.q then break
    elseif a == keys.right or a == keys.pageDown then go(1)
    elseif a == keys.left or a == keys.pageUp then go(-1)
    elseif a == keys.down then scroll = scroll + 1
    elseif a == keys.up then scroll = scroll - 1
    elseif a == keys.home then selected, scroll = 1, 0
    elseif a == keys["end"] then selected, scroll = #topics, 0
    end
    draw()

  elseif event == "mouse_scroll" then
    scroll = scroll + a
    draw()

  elseif event == "mouse_click" then
    -- Tapping the left third goes back and the right third forward, which is the
    -- only navigation a pocket computer's thumb wants.
    if c == 1 or c == h then
      if b <= math.floor(w / 3) then go(-1)
      elseif b >= w - math.floor(w / 3) then go(1) end
    end
    draw()

  elseif event == "term_resize" then
    draw()

  elseif event == "terminate" then
    break
  end
end

ui.paint(ui.theme.text, ui.theme.bg)
term.clear()
term.setCursorPos(1, 1)
