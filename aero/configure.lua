--- Set this computer up, without editing Lua.
--
--   configure
--
-- Panes, a summary, and nothing written until you say so. Modelled on
-- cc-mek-scada's configurator, which gets three things right that this project
-- did not: setup is its own program, the front page **tells you what is wrong
-- with the current configuration** before you go looking, and you see everything
-- you are about to write before it is written.
--
-- ## What it can do that hand-editing cannot
--
-- The important one: **which bearing is lift and which is main.** Nothing can
-- work that out by looking -- `probe` guesses, and getting it backwards is a
-- ship that accelerates into the ground -- so here you are shown every bearing
-- that is actually attached and you point at the right one. Swapping them is two
-- keypresses rather than an edit to a file you have to find first.
--
-- Everything it writes is ordinary Lua in /aero.cfg and /craft.cfg, still
-- hand-editable, still outside manifest.txt. This is a nicer way in, not a
-- replacement for the files.

local config = require("lib.config")
local needs  = require("lib.needs")
local nav    = require("lib.nav")
local ui     = require("lib.ui")

local W, H = term.getSize()

--------------------------------------------------------------------------------
-- The draft
--------------------------------------------------------------------------------

-- Everything is edited here and written on Apply. A configurator that wrote as
-- you typed would leave a half-configured computer behind the moment somebody
-- changed their mind, and on a flight computer that is a hull definition with
-- one bearing in it.
local draft = {
  network = { protocol = config.protocol, channel = config.channel,
              role = config.role, name = os.getComputerLabel() or "" },
  craft   = nil,      -- loaded below, for a pilot
  beacon  = nil,
}

local pane   = "main"
local list   = ui.list()
local typing = nil
local flash  = nil
local notices = {}

local function now() return os.clock() end
local function note(text) flash = ui.flash(text, now()) end

--------------------------------------------------------------------------------
-- What is attached
--------------------------------------------------------------------------------

local attached = {}      -- [type] = { side, ... }

local function scan()
  attached = {}
  local ok, names = pcall(peripheral.getNames)
  if not ok then return end

  for _, side in ipairs(names) do
    local okType, kind = pcall(peripheral.getType, side)
    if okType and kind then
      if kind == "modem" then
        local okW, wireless = pcall(peripheral.call, side, "isWireless")
        kind = (okW and wireless) and "modem" or "wired_modem"
      end
      attached[kind] = attached[kind] or {}
      table.insert(attached[kind], side)
    end
  end
end

local function first(kind) return attached[kind] and attached[kind][1] or nil end

--------------------------------------------------------------------------------
-- Loading what is already there
--------------------------------------------------------------------------------

local function loadLua(path)
  if not fs.exists(path) then return nil end
  local fn = loadfile(path)
  if not fn then return nil end
  local ok, value = pcall(fn)
  if ok and type(value) == "table" then return value end
  return nil
end

--- The instrument roles, in the order they matter.
local ROLES = {
  { "nav",     "navigation_table",   "position and heading", true },
  { "alt",     "altitude_sensor",    "height",               true },
  { "ground",  "optical_sensor",     "clearance below",      false },
  { "forward", "optical_sensor",     "what is ahead",        false },
  { "vel",     "velocity_sensor",    "speed",                false },
  { "gimbal",  "gimbal_sensor",      "pitch and roll",       false },
  { "dock",    "docking_connector",  "docking",              false },
  { "stick",   "analogue_joystick",  "taking control by hand", false },
  { "link",    "advanced_data_link", "publishing the leg",   false },
}

local function blankCraft()
  return {
    name = draft.network.name,
    controls = {},
    instruments = {},
    limits = { cruise = 10, climb = 3, descend = 2, clearance = 8 },
    gains = { hover = 0.5 },
    mix = {},
  }
end

--- Work out what is wrong with the configuration as it stands.
--
-- Shown on the front page, which is the cc-mek-scada idea worth stealing above
-- all the others: a configurator that opens by telling you what is broken saves
-- the entire process of finding out.
local function findNotices()
  notices = {}

  if draft.network.role ~= "pilot" then return end

  if not draft.craft then
    notices[#notices + 1] = { "no " .. config.craftFile
      .. " -- this ship has no hull definition", "bad" }
    return
  end

  local instruments = draft.craft.instruments or {}

  for _, role in ipairs(ROLES) do
    local name, kind, _, required = role[1], role[2], role[3], role[4]
    local set = instruments[name]

    -- The trap that started all this. `false` means "deliberately none", and
    -- probe used to write it for anything simply not plugged in yet.
    if set == false and first(kind) then
      notices[#notices + 1] = { name .. " is switched off, but a " .. kind
        .. " is attached", "bad" }
    elseif set and set ~= false and not peripheral.isPresent(set) then
      notices[#notices + 1] = { name .. " names " .. tostring(set)
        .. ", which is not attached", "bad" }
    elseif required and not set and not first(kind) then
      notices[#notices + 1] = { "no " .. kind .. " -- " .. role[3]
        .. " is unavailable", "bad" }
    end
  end

  local controls = 0
  for _ in pairs(draft.craft.controls or {}) do controls = controls + 1 end
  if controls == 0 then
    notices[#notices + 1] = { "no controls -- nothing for the autopilot to move",
                              "bad" }
  end
  if #(draft.craft.mix or {}) == 0 and controls > 0 then
    notices[#notices + 1] = { "no mix -- the controls are never driven", "bad" }
  end
end

--------------------------------------------------------------------------------
-- Writing
--------------------------------------------------------------------------------

local function quoted(v)
  if type(v) == "string" then return ("%q"):format(v) end
  return tostring(v)
end

local function writeNetwork()
  local n = draft.network

  -- Only when it differs from the defaults, the same rule install.lua follows:
  -- a plain setup should leave nothing extra behind to explain.
  if n.protocol == "aero" and n.channel == 1618 and n.role == "pilot" then
    if fs.exists("/aero.cfg") then fs.delete("/aero.cfg") end
  else
    local f = fs.open("/aero.cfg", "w")
    f.write(("-- Written by `configure`. Not in manifest.txt, so `update` will\n"
      .. "-- not replace it. Anything here overrides lib/config.lua.\n"
      .. "return {\n  protocol = %q,\n  channel  = %d,\n  role     = %q,\n}\n")
      :format(n.protocol, n.channel, n.role))
    f.close()
  end

  if n.name ~= "" then os.setComputerLabel(n.name) end
end

local function writeCraft()
  if draft.network.role ~= "pilot" or not draft.craft then return end

  local out = {
    "-- What this ship is, and how to fly it.",
    "--",
    "-- Written by `configure`. Not in manifest.txt, so `update` never replaces",
    "-- it -- edit it by hand as much as you like.",
    "",
    "return {",
    ("  name = %q,"):format(draft.craft.name or "ship"),
    "",
    "  controls = {",
  }

  local names = {}
  for name in pairs(draft.craft.controls) do names[#names + 1] = name end
  table.sort(names)

  for _, name in ipairs(names) do
    local c = draft.craft.controls[name]
    local parts = { ("kind = %q"):format(c.kind) }
    if c.peripheral then parts[#parts + 1] = ("peripheral = %q"):format(c.peripheral) end
    if c.group then parts[#parts + 1] = ("group = %q"):format(c.group) end
    if c.side then parts[#parts + 1] = ("side = %q"):format(c.side) end
    if c.mode then parts[#parts + 1] = ("mode = %q"):format(c.mode) end
    if c.hold then parts[#parts + 1] = "hold = true" end
    if c.pivot then
      parts[#parts + 1] = ("pivot = { min = %d, max = %d }")
        :format(c.pivot.min, c.pivot.max)
    end
    out[#out + 1] = ("    %s = { %s },"):format(name, table.concat(parts, ", "))
  end

  out[#out + 1] = "  },"
  out[#out + 1] = ""
  out[#out + 1] = "  instruments = {"
  for _, role in ipairs(ROLES) do
    local set = draft.craft.instruments[role[1]]
    if set == false then
      out[#out + 1] = ("    %s = false,   -- this hull has none"):format(role[1])
    elseif set then
      out[#out + 1] = ("    %s = %q,"):format(role[1], set)
    end
  end
  out[#out + 1] = "  },"
  out[#out + 1] = ""

  local l = draft.craft.limits
  out[#out + 1] = ("  limits = { cruise = %d, climb = %d, descend = %d, clearance = %d },")
    :format(l.cruise, l.climb, l.descend, l.clearance)
  out[#out + 1] = ""

  local gainParts = {}
  for key, value in pairs(draft.craft.gains or {}) do
    gainParts[#gainParts + 1] = ("%s = %s"):format(key, quoted(value))
  end
  table.sort(gainParts)
  out[#out + 1] = ("  gains = { %s },"):format(table.concat(gainParts, ", "))
  out[#out + 1] = ""

  out[#out + 1] = "  mix = {"
  for _, term_ in ipairs(draft.craft.mix) do
    local extra = ""
    if term_.scale and term_.scale ~= 1 then
      extra = extra .. (", scale = %s"):format(term_.scale)
    end
    out[#out + 1] = ("    { demand = %q, control = %q, as = %q%s },")
      :format(term_.demand, term_.control, term_.as, extra)
  end
  out[#out + 1] = "  },"
  out[#out + 1] = "}"

  local f = fs.open(config.craftFile, "w")
  for _, line in ipairs(out) do f.writeLine(line) end
  f.close()
end

--------------------------------------------------------------------------------
-- The bearings, which is the whole point
--------------------------------------------------------------------------------

--- Which control, if any, currently uses this peripheral.
local function usedBy(side)
  for name, c in pairs((draft.craft or {}).controls or {}) do
    if c.peripheral == side then return name end
  end
  return nil
end

--- Point `name` at `side`, taking it off whatever had it.
--
-- Swapping lift and main is the single most valuable thing this program does,
-- so it is one action rather than two: assigning a bearing that is already the
-- other one exchanges them instead of leaving a hull with two lifts and nothing
-- to push it along.
local function assign(name, side)
  local craft = draft.craft
  local holder = usedBy(side)

  if holder and holder ~= name then
    local ours = craft.controls[name]
    craft.controls[holder] = ours and { kind = ours.kind, peripheral = ours.peripheral,
                                        group = ours.group, pivot = ours.pivot } or nil
  end

  craft.controls[name] = craft.controls[name] or
    { kind = "bearing", group = "all" }
  craft.controls[name].peripheral = side

  if name == "main" then
    craft.controls[name].pivot = craft.controls[name].pivot
      or { min = -30, max = 30 }
  end
end

--- The standard mix for whatever controls exist. Regenerated rather than edited,
--- because a mix that half matches the controls is worse than one that does not.
local function rebuildMix()
  local craft = draft.craft
  craft.mix = {}

  if craft.controls.lift then
    craft.mix[#craft.mix + 1] =
      { demand = "lift", control = "lift", as = "throttle" }
  end
  if craft.controls.main then
    craft.mix[#craft.mix + 1] =
      { demand = "forward", control = "main", as = "throttle" }
    craft.mix[#craft.mix + 1] =
      { demand = "yaw", control = "main", as = "pivot", scale = 30 }
  end
  if craft.controls.burner then
    craft.mix[#craft.mix + 1] =
      { demand = "lift", control = "burner", as = "signal" }
  end
  if craft.controls.trim then
    craft.mix[#craft.mix + 1] =
      { demand = "pitch", control = "trim", as = "angleX", scale = 15 }
  end
end

--------------------------------------------------------------------------------
-- Panes
--------------------------------------------------------------------------------

local function row(entry) return ui.row(list, entry) end

local function buildMain()
  if #notices > 0 then
    row({ kind = "head", label = "problems with this configuration" })
    for _, entry in ipairs(notices) do
      row({ kind = "note", text = " " .. entry[1],
            colour = entry[2] == "bad" and ui.theme.bad or ui.theme.warn })
    end
    row({ kind = "gap" })
  else
    row({ kind = "note", text = " Nothing wrong that this can see.",
          colour = ui.theme.ok })
    row({ kind = "gap" })
  end

  row({ kind = "action", text = "Network -- name, channel, role",
        click = function() pane = "network" list.scroll = 0 end })

  if draft.network.role == "pilot" then
    row({ kind = "action", text = "Bearings -- which is lift, which is main",
          colour = ui.theme.accent,
          click = function() pane = "bearings" list.scroll = 0 end })
    row({ kind = "action", text = "Instruments -- what this hull can read",
          click = function() pane = "instruments" list.scroll = 0 end })
    row({ kind = "action", text = "Limits -- speeds, heights, hover",
          click = function() pane = "limits" list.scroll = 0 end })
  end

  if draft.network.role == "beacon" then
    row({ kind = "note", text = " A beacon is set up with `beacon`,",
          colour = ui.theme.dim })
    row({ kind = "note", text = " which asks for its coordinates.",
          colour = ui.theme.dim })
  end

  row({ kind = "gap" })
  row({ kind = "action", text = "Review and apply", colour = ui.theme.ok,
        click = function() pane = "summary" list.scroll = 0 end })
  row({ kind = "action", text = "Quit without saving", colour = ui.theme.dim,
        click = function() pane = "quit" end })
end

local function buildNetwork()
  local n = draft.network

  row({ kind = "action", text = "< back",
        colour = ui.theme.accent, click = function() pane = "main" end })
  row({ kind = "head", label = "network" })

  row({ kind = "value", label = "name", value = n.name,
        why = "what this computer is called",
        click = function() typing = ui.field("name") end })

  row({ kind = "value", label = "network", value = n.protocol,
        why = "computers only talk to others on the same one",
        click = function() typing = ui.field("network") end })

  row({ kind = "step", text = ("  channel  %d"):format(n.channel),
        click = function(x)
          local by = ((x or 0) >= W - 1) and 1 or -1
          n.channel = math.max(1, math.min(65535, n.channel + by))
        end })
  row({ kind = "note", text = "   the port, and the real separation",
        colour = ui.theme.dim })

  row({ kind = "head", label = "role" })
  for _, name in ipairs({ "pilot", "server", "beacon" }) do
    row({ kind = "choice", label = name, on = (n.role == name),
          why = needs.roles[name] and needs.roles[name].title or "",
          click = function()
            n.role = name
            if name == "pilot" and not draft.craft then
              draft.craft = blankCraft()
            end
            findNotices()
          end })
  end
end

local function buildBearings()
  row({ kind = "action", text = "< back",
        colour = ui.theme.accent, click = function() pane = "main" end })

  local bearings = attached.thruster_bearing or {}
  if #bearings == 0 then
    row({ kind = "note", text = " No thruster bearings attached.",
          colour = ui.theme.bad })
    row({ kind = "note", text = " Assemble the contraption first, then",
          colour = ui.theme.dim })
    row({ kind = "note", text = " come back. `setup` shows what is missing.",
          colour = ui.theme.dim })
    return
  end

  row({ kind = "head", label = "lift -- holds the ship up" })
  for _, side in ipairs(bearings) do
    local c = draft.craft.controls.lift
    row({ kind = "choice", label = side, on = (c and c.peripheral == side),
          why = usedBy(side) and ("currently " .. usedBy(side)) or "unused",
          click = function()
            assign("lift", side)
            rebuildMix()
            note("lift is " .. side)
          end })
  end

  row({ kind = "head", label = "main -- pushes it along" })
  for _, side in ipairs(bearings) do
    local c = draft.craft.controls.main
    row({ kind = "choice", label = side, on = (c and c.peripheral == side),
          why = usedBy(side) and ("currently " .. usedBy(side)) or "unused",
          click = function()
            assign("main", side)
            rebuildMix()
            note("main is " .. side)
          end })
  end

  row({ kind = "gap" })
  row({ kind = "note",
        text = " Getting these the wrong way round is a",
        colour = ui.theme.warn })
  row({ kind = "note", text = " ship that flies into the ground. Nothing",
        colour = ui.theme.warn })
  row({ kind = "note", text = " can work it out by looking -- only you can.",
        colour = ui.theme.warn })

  if draft.craft.controls.lift and draft.craft.controls.main
     and draft.craft.controls.lift.peripheral
       == draft.craft.controls.main.peripheral then
    row({ kind = "note", text = " Both are the same bearing.",
          colour = ui.theme.bad })
  end
end

local function buildInstruments()
  row({ kind = "action", text = "< back",
        colour = ui.theme.accent, click = function() pane = "main" end })
  row({ kind = "head", label = "instruments" })

  for _, role in ipairs(ROLES) do
    local name, kind, why, required = role[1], role[2], role[3], role[4]
    local set = draft.craft.instruments[name]
    local here = attached[kind] or {}

    local shown, colour
    if set == false then
      shown, colour = "none (deliberately)", ui.theme.dim
    elseif set then
      shown = set
      colour = peripheral.isPresent(set) and ui.theme.ok or ui.theme.bad
    elseif #here > 0 then
      shown, colour = "auto: " .. here[1], ui.theme.ok
    else
      shown = "not attached"
      colour = required and ui.theme.bad or ui.theme.dim
    end

    row({
      kind = "instrument", label = name, value = shown, why = why,
      colour = colour,
      -- Cycles: auto, then each attached one, then off. Every state a craft file
      -- can hold, reachable by tapping, including the `false` that used to be
      -- the trap -- because switching one off deliberately is legitimate and
      -- should look different from having it broken.
      click = function()
        local options = { nil }
        for _, side in ipairs(here) do options[#options + 1] = side end
        options[#options + 1] = false

        local at = 0
        for i, option in ipairs(options) do
          if option == set then at = i end
        end
        if set == nil then at = 0 end

        local nextAt = at + 1
        if nextAt > #options then
          draft.craft.instruments[name] = nil
        else
          draft.craft.instruments[name] = options[nextAt]
        end
        findNotices()
      end,
    })
  end
end

local function buildLimits()
  row({ kind = "action", text = "< back",
        colour = ui.theme.accent, click = function() pane = "main" end })
  row({ kind = "head", label = "limits -- blocks per second" })

  local l = draft.craft.limits
  local FIELDS = {
    { "cruise", "how fast it flies a leg", 1, 40 },
    { "climb", "fastest it will go up", 1, 20 },
    { "descend", "fastest it will come down", 1, 20 },
    { "clearance", "how close to the ground it tolerates", 1, 60 },
  }

  for _, field in ipairs(FIELDS) do
    local key, why, low, high = field[1], field[2], field[3], field[4]
    row({ kind = "step", text = ("  %-10s %3d"):format(key, l[key]),
          click = function(x)
            local by = ((x or 0) >= W - 1) and 1 or -1
            l[key] = math.max(low, math.min(high, l[key] + by))
          end })
    row({ kind = "note", text = "   " .. why, colour = ui.theme.dim })
  end

  row({ kind = "head", label = "hover" })
  row({ kind = "step",
        text = ("  hover      %.2f"):format(draft.craft.gains.hover or 0.5),
        click = function(x)
          local by = ((x or 0) >= W - 1) and 0.05 or -0.05
          draft.craft.gains.hover =
            math.max(0, math.min(1, (draft.craft.gains.hover or 0.5) + by))
        end })
  row({ kind = "note", text = "   throttle that neither climbs nor sinks",
        colour = ui.theme.dim })
  row({ kind = "note", text = "   a guess is fine; the loop finds the rest",
        colour = ui.theme.dim })
end

local function buildSummary()
  row({ kind = "action", text = "< back",
        colour = ui.theme.accent, click = function() pane = "main" end })

  local n = draft.network
  row({ kind = "head", label = "about to write" })
  row({ kind = "pair", left = "name", right = n.name })
  row({ kind = "pair", left = "network", right = n.protocol })
  row({ kind = "pair", left = "channel", right = tostring(n.channel) })
  row({ kind = "pair", left = "role", right = n.role })

  if n.role == "pilot" and draft.craft then
    row({ kind = "head", label = "controls" })
    local names = {}
    for name in pairs(draft.craft.controls) do names[#names + 1] = name end
    table.sort(names)
    if #names == 0 then
      row({ kind = "note", text = " none", colour = ui.theme.bad })
    end
    for _, name in ipairs(names) do
      local c = draft.craft.controls[name]
      row({ kind = "pair", left = name,
            right = (c.peripheral or c.side or "?") })
    end

    row({ kind = "head", label = "instruments" })
    for _, role in ipairs(ROLES) do
      local set = draft.craft.instruments[role[1]]
      if set ~= nil then
        row({ kind = "pair", left = role[1],
              right = set == false and "none" or tostring(set) })
      end
    end

    local l = draft.craft.limits
    row({ kind = "head", label = "limits" })
    row({ kind = "pair", left = "cruise", right = tostring(l.cruise) })
    row({ kind = "pair", left = "climb", right = tostring(l.climb) })
    row({ kind = "pair", left = "descend", right = tostring(l.descend) })
    row({ kind = "pair", left = "clearance", right = tostring(l.clearance) })
    row({ kind = "pair", left = "mix terms", right = tostring(#draft.craft.mix) })
  end

  row({ kind = "gap" })
  row({ kind = "action", text = "APPLY -- write it", colour = ui.theme.ok,
        click = function()
          writeNetwork()
          writeCraft()
          pane = "done"
        end })
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

local function drawRow(entry, y, w)
  if entry.kind == "head" then
    ui.fill(1, y, w, 1, ui.theme.panel)
    ui.at(1, y, ui.fit(" " .. entry.label, w, true), ui.theme.bg, ui.theme.panel)

  elseif entry.kind == "action" then
    ui.at(1, y, ui.fit(" " .. entry.text, w, true), entry.colour or ui.theme.text)

  elseif entry.kind == "choice" then
    ui.at(1, y, ui.fit((entry.on and " (*) " or " ( ) ") .. entry.label, 24, true),
          entry.on and ui.theme.ok or ui.theme.text)
    ui.at(25, y, ui.fit(entry.why or "", w - 25, true), ui.theme.dim)

  elseif entry.kind == "instrument" then
    ui.at(1, y, ui.fit(" " .. entry.label, 10, true), ui.theme.text)
    ui.at(11, y, ui.fit(entry.value, 22, true), entry.colour)
    ui.at(33, y, ui.fit(entry.why or "", w - 33, true), ui.theme.dim)

  elseif entry.kind == "value" then
    ui.at(1, y, ui.fit(" " .. entry.label, 10, true), ui.theme.text)
    ui.at(11, y, ui.fit(entry.value == "" and "(unset)" or entry.value, 20, true),
          ui.theme.select)
    ui.at(32, y, ui.fit(entry.why or "", w - 32, true), ui.theme.dim)

  elseif entry.kind == "step" then
    ui.at(1, y, ui.fit(entry.text, w - 4, true), ui.theme.text)
    ui.at(w - 3, y, "- +", ui.theme.accent)

  elseif entry.kind == "pair" then
    ui.at(1, y, ui.fit(" " .. entry.left, 14, true), ui.theme.dim)
    ui.at(15, y, ui.fit(entry.right, w - 15, true), ui.theme.text)

  elseif entry.kind == "note" then
    ui.at(1, y, ui.fit(entry.text, w, true), entry.colour or ui.theme.dim)
  end
  ui.paint(ui.theme.text, ui.theme.bg)
end

local TITLE = {
  main = "Configure", network = "Network", bearings = "Bearings",
  instruments = "Instruments", limits = "Limits", summary = "Review",
}

local function draw()
  list.entries = {}
  if pane == "main" then buildMain()
  elseif pane == "network" then buildNetwork()
  elseif pane == "bearings" then buildBearings()
  elseif pane == "instruments" then buildInstruments()
  elseif pane == "limits" then buildLimits()
  elseif pane == "summary" then buildSummary() end

  ui.paint(ui.theme.text, ui.theme.bg)
  term.clear()

  local bad = #notices > 0
  local banner = (pane == "main" and bad) and ui.theme.bad or ui.theme.accent
  ui.fill(1, 1, W, 1, banner)
  ui.at(1, 1, ui.fit((" aero -- %s"):format(TITLE[pane] or ""), W - 10, true),
        ui.theme.bg, banner)
  ui.at(W - 9, 1, ui.fit(draft.network.role, 9), ui.theme.bg, banner)

  ui.draw(list, 1, 3, W, H - 4, function(entry, y) drawRow(entry, y, W) end)

  if typing then
    ui.drawField(typing, H, W)
  elseif not ui.drawFlash(flash, now(), H, W) then
    ui.fill(1, H, W, 1, ui.theme.panel)
    ui.at(1, H, ui.fit(" Q quit   up/down scroll", W, true),
          ui.theme.bg, ui.theme.panel)
  end
  ui.paint(ui.theme.text, ui.theme.bg)
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

scan()
draft.craft = loadLua(config.craftFile)
if draft.network.role == "pilot" and not draft.craft then
  draft.craft = blankCraft()
end
findNotices()

draw()

while true do
  local event, a, b, c = os.pullEvent()

  if pane == "quit" then break end
  if pane == "done" then
    ui.paint(ui.theme.text, ui.theme.bg)
    term.clear()
    term.setCursorPos(1, 1)
    ui.paint(ui.theme.ok, ui.theme.bg)
    print("Written.")
    ui.paint(ui.theme.text, ui.theme.bg)
    print("")
    print("Reboot to start with the new settings, or run")
    print("`setup` to check the hardware first.")
    return
  end

  if typing then
    if event == "char" then ui.type(typing, a)
    elseif event == "key" then
      if a == keys.enter then
        if typing.text ~= "" then
          if typing.prompt == "name" then
            draft.network.name = typing.text
            if draft.craft then draft.craft.name = typing.text end
          elseif typing.prompt == "network" then
            draft.network.protocol = typing.text
          end
        end
        typing = nil
      elseif a == keys.backspace then ui.backspace(typing)
      elseif a == keys.q then typing = nil end
    end
    draw()

  elseif event == "mouse_click" then
    for _, entry in ipairs(list.entries) do
      if entry.y == c and entry.click then entry.click(b) break end
    end
    draw()

  elseif event == "mouse_scroll" then
    list.scroll = math.max(0, list.scroll + a)
    draw()

  elseif event == "key" then
    if a == keys.q then
      if pane == "main" then break end
      pane = "main"
    elseif a == keys.up then list.scroll = math.max(0, list.scroll - 1)
    elseif a == keys.down then list.scroll = list.scroll + 1 end
    draw()

  elseif event == "peripheral" or event == "peripheral_detach" then
    scan()
    findNotices()
    draw()

  elseif event == "terminate" then
    break
  end
end

ui.paint(ui.theme.text, ui.theme.bg)
term.clear()
term.setCursorPos(1, 1)
print("Nothing written.")
