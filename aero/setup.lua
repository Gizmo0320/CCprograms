--- What this computer needs, and what it has.
--
--   setup            the checklist for whatever role this computer is
--   setup pilot      the checklist for a role it is not, to plan a build
--
-- Run it on a computer that will not do what you expect. It lists everything the
-- role needs, marks what is attached right now, and says what each thing is for
-- and what you lose without it -- and it **re-scans as you go**, so you can walk
-- over, place the block, and watch the line turn green without touching
-- anything.
--
-- ## Why this is its own program
--
-- "It cannot find the navigation table" has at least four causes: the block is
-- not on the contraption, the contraption is not assembled, the craft file
-- switched the role off, or nothing has run `probe` yet. A flight computer
-- printing one line of warning cannot distinguish them, and neither can anybody
-- reading it.
--
-- So the question gets a program. It also checks the things a checklist alone
-- would miss -- whether a craft file exists, whether it disagrees with the
-- hardware -- because those are the same question wearing a different hat.

local config = require("lib.config")
local needs  = require("lib.needs")
local hull   = require("lib.hull")
local ui     = require("lib.ui")

local args = { ... }

local role = args[1]
if role == "tower" then role = "server" end
if role == "ship" then role = "pilot" end
if role == "waypoint" then role = "beacon" end

if not needs.roles[role] then
  role = pocket and "remote" or config.role
end

local scroll = 0

--------------------------------------------------------------------------------

--- Everything attached, in the shape lib/needs wants.
local function attached()
  local found = {}
  local ok, names = pcall(peripheral.getNames)
  if not ok then return found end

  for _, side in ipairs(names) do
    local okType, kind = pcall(peripheral.getType, side)
    if okType and kind then
      local entry = { type = kind, side = side }
      if kind == "modem" then
        local okWireless, wireless = pcall(peripheral.call, side, "isWireless")
        entry.wireless = okWireless and wireless or false
      end
      found[#found + 1] = entry
    end
  end
  return found
end

--- What the craft file says, for a pilot. This is the half a hardware checklist
--- cannot see, and it is where the confusing failures live.
local function craftTrouble()
  if role ~= "pilot" then return {} end

  if not fs.exists(config.craftFile) then
    return { { "no " .. config.craftFile,
               "run `probe` once the contraption is assembled", "bad" } }
  end

  -- Loading it is the check. hull.load reports every disagreement between the
  -- file and the hardware, including the one that used to be silent: a role set
  -- to false while the peripheral is sitting right there.
  local ok, problems = hull.load()
  local out = {}
  for _, why in ipairs(problems or {}) do
    out[#out + 1] = { why, nil, ok and "warn" or "bad" }
  end
  if #out == 0 then
    out[#out + 1] = { config.craftFile .. " loads clean",
                      hull.count() .. " controls", "ok" }
  end
  return out
end

--------------------------------------------------------------------------------

-- Required needs no label: a red NO says it. The other two do, because "--" on
-- its own reads like a fault when it is a suggestion.
local TIER = { required = "", recommended = " (recommended)", optional = " (optional)" }

local RANK = { ok = 1, warn = 2, bad = 3 }

local function draw()
  local w, h = term.getSize()
  local spec = needs.roles[role]
  local rows, summary = needs.check(role, attached())
  local trouble = craftTrouble()

  local verdict, mood = needs.verdict(summary, role)
  local moodColour = { ok = ui.theme.ok, warn = ui.theme.warn, bad = ui.theme.bad }

  -- The craft file counts towards the verdict, and this is the whole reason
  -- the two halves are one program. A ship with every block attached and
  -- `nav = false` in its craft file is not "ready with things it could do
  -- better" -- it is broken, in the one way a hardware checklist cannot see.
  for _, entry in ipairs(trouble) do
    if RANK[entry[3]] > RANK[mood] then
      mood = entry[3]
      verdict = entry[1]
    end
  end

  ui.paint(ui.theme.text, ui.theme.bg)
  term.clear()

  ui.fill(1, 1, w, 1, moodColour[mood])
  ui.at(1, 1, ui.fit(" " .. spec.title, w, true), ui.theme.bg, moodColour[mood])

  -- Flattened into one list so the hardware and the craft file scroll together:
  -- they are two halves of one question and reading them apart is what makes
  -- the answer hard to find.
  local lines = {}

  -- Craft-file trouble goes **first**. It was at the bottom, which put the most
  -- important line on a screen below the fold on a computer where every piece of
  -- hardware showed green -- exactly the case somebody runs this to understand.
  local interesting = false
  for _, entry in ipairs(trouble) do
    if entry[3] ~= "ok" then interesting = true end
  end

  if interesting then
    lines[#lines + 1] = { "the craft file", ui.theme.accent }
    for _, entry in ipairs(trouble) do
      lines[#lines + 1] = { "  " .. entry[1], moodColour[entry[3]] }
      if entry[2] then lines[#lines + 1] = { "    " .. entry[2], ui.theme.dim } end
    end
    lines[#lines + 1] = { "", ui.theme.text }
    lines[#lines + 1] = { "the hardware", ui.theme.accent }
  end

  for _, row in ipairs(rows) do
    local item = row.item
    local mark = row.ok and "yes" or (item.tier == "required" and "NO" or "--")
    local colour = row.ok and ui.theme.ok
      or (item.tier == "required" and ui.theme.bad or ui.theme.dim)

    local count = ""
    if row.want > 1 then count = (" (%d of %d)"):format(row.have, row.want) end

    lines[#lines + 1] = { ("%-4s %s%s%s")
      :format(mark, item.what, count, TIER[item.tier]), colour }

    -- The reason is indented under it, and only when it is missing. A screen
    -- that explains everything explains nothing.
    if not row.ok then
      lines[#lines + 1] = { "          " .. item.why, ui.theme.dim }
      lines[#lines + 1] = { "          without: " .. item.without, ui.theme.dim }
    end
  end

  if #trouble > 0 and not interesting then
    lines[#lines + 1] = { "", ui.theme.text }
    lines[#lines + 1] = { "the craft file", ui.theme.accent }
    for _, entry in ipairs(trouble) do
      lines[#lines + 1] = { "  " .. entry[1], moodColour[entry[3]] }
      if entry[2] then
        lines[#lines + 1] = { "    " .. entry[2], ui.theme.dim }
      end
    end
  end

  local top, bottom = 3, h - 2
  local visible = bottom - top + 1
  local most = math.max(0, #lines - visible)
  if scroll > most then scroll = most end
  if scroll < 0 then scroll = 0 end

  ui.at(1, 2, ui.fit(verdict, w, true), moodColour[mood])

  for i = 1, visible do
    local line = lines[i + scroll]
    if line then ui.at(1, top + i - 1, ui.fit(line[1], w, true), line[2]) end
  end

  if scroll > 0 then ui.at(w, top, "^", ui.theme.dim) end
  if scroll < most then ui.at(w, bottom, "v", ui.theme.dim) end

  ui.fill(1, h, w, 1, ui.theme.panel)
  ui.at(1, h, ui.fit(w >= 40
    and " Q quit   up/down scroll   checking every second"
    or " Q quit  up/down", w, true), ui.theme.bg, ui.theme.panel)

  ui.paint(ui.theme.text, ui.theme.bg)
end

--------------------------------------------------------------------------------

draw()

-- Re-scanned on a timer rather than on demand, so you can leave this on screen,
-- go and place the block, and see it go green when you come back. That is the
-- whole reason it is a program rather than a printout.
local tick = os.startTimer(1)

while true do
  local event, a = os.pullEvent()

  if event == "timer" and a == tick then
    tick = os.startTimer(1)
    draw()

  elseif event == "key" then
    if a == keys.q then break
    elseif a == keys.up then scroll = scroll - 1 draw()
    elseif a == keys.down then scroll = scroll + 1 draw()
    end

  elseif event == "mouse_scroll" then
    scroll = scroll + a
    draw()

  elseif event == "peripheral" or event == "peripheral_detach" then
    -- Instant, when CC bothers to tell us. The timer is the backstop for
    -- everything it does not raise an event for -- a contraption being
    -- assembled, for one.
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
