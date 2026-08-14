--- Set this computer up. The only way in.
--
--   configure              the front page, or the wizard on a fresh computer
--   configure --wizard     the wizard, whatever state the computer is in
--   configure hardware     open straight on a pane, by name
--
-- Every other program here reads configuration and none of them write it. This
-- is where /aero.cfg, /craft.cfg and /beacon.cfg come from, and `startup.lua`
-- runs it before it will start anything at all.
--
-- ## What it replaced
--
-- It used to be four programs. `install.lua` asked for the network and the role
-- while it downloaded; `probe.lua` looked at the hull and wrote a starting
-- /craft.cfg; `setup.lua` drew a live checklist of what was attached; and an
-- earlier `configure.lua` edited some of the result. They overlapped, they each
-- had their own idea of what a broken configuration looked like, and the order
-- you were meant to run them in was written down in the README and nowhere the
-- program could enforce it -- so the ordinary failure was a computer that had
-- been through all four and still would not fly, with each program reporting
-- that its own part was fine.
--
-- Now there is one program, it knows the order, and it will not let you leave a
-- required question unanswered. cc-mek-scada's configurator is the model: a
-- front page that opens by **telling you what is wrong**, a wizard on first run
-- with the exit disabled, and nothing written until you have seen all of it.
--
-- ## The draft
--
-- Everything is edited in `draft` and written on Apply. A configurator that
-- wrote as you typed would leave a half-configured computer behind the moment
-- somebody changed their mind, and on a flight computer that is a hull
-- definition with one bearing in it.

local config = require("lib.config")
local cfg    = require("lib.cfg")
local needs  = require("lib.needs")
local ui     = require("lib.ui")

--------------------------------------------------------------------------------
-- Arguments
--------------------------------------------------------------------------------

local args = { ... }
local WIZARD, START_PANE = false, nil

for _, a in ipairs(args) do
  if a == "--wizard" or a == "-w" then WIZARD = true
  elseif a ~= "" and not a:match("^%-") then START_PANE = a:lower() end
end

-- A computer nobody has configured gets the wizard whether it asked for one or
-- not. This is the whole point: the wizard is not a mode you remember to pick,
-- it is what happens when there is nothing there yet.
if not cfg.configured() then WIZARD = true end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local draft = {
  network = cfg.network(),
  craft   = nil,
  beacon  = nil,
}

local attached  = {}
local problems  = {}
local pane      = WIZARD and "welcome" or "main"
local list      = ui.list()
local typing    = nil
local flash     = nil
local running   = true
local applied   = false
local watching  = false     -- the live optical sensor view owns the screen
local surveyed  = nil       -- what the last survey wrote, for the flash

local function now() return os.clock() end
local function note(text) flash = ui.flash(text, now()) end

--------------------------------------------------------------------------------
-- Scanning and checking
--------------------------------------------------------------------------------

local function firstOf(kind)
  return attached[kind] and attached[kind][1] or nil
end

local function recheck()
  problems = cfg.check(draft.network.role, {
    craft      = draft.craft,
    beacon     = draft.beacon,
    network    = draft.network,
    attached   = attached,
    -- Inside the configurator the stamp is never the complaint: you are looking
    -- at the screen that fixes it, and "this computer has not been configured"
    -- listed among the things to go and fix would be a joke at the reader's
    -- expense.
    configured = true,
  })
end

local function scan()
  attached = cfg.attached()
  recheck()
end

--------------------------------------------------------------------------------
-- A hull from what is bolted to it
--------------------------------------------------------------------------------

local function blankCraft()
  return {
    name = draft.network.name ~= "" and draft.network.name or "ship",
    controls = {}, instruments = {}, signals = {},
    limits = { cruise = 10, climb = 3, descend = 2, clearance = 8 },
    gains = { hover = 0.5 },
    mix = {},
  }
end

--- The standard mix for whatever controls exist.
--
-- Regenerated rather than edited, because a mix that half matches the controls
-- is worse than one that does not match at all: it drives some of the ship.
local function rebuildMix()
  local craft = draft.craft
  local mix = {}

  if craft.controls.lift then
    mix[#mix + 1] = { demand = "lift", control = "lift", as = "throttle" }
  end
  if craft.controls.main then
    mix[#mix + 1] = { demand = "forward", control = "main", as = "throttle" }
    mix[#mix + 1] = { demand = "yaw", control = "main", as = "pivot", scale = 30 }
  end
  if craft.controls.trim then
    mix[#mix + 1] = { demand = "pitch", control = "trim", as = "angleX", scale = 15 }
  end

  -- Every wire control that is held is buoyancy: a hot air burner and a steam
  -- vent are analogue, the signal *is* the lift, and a hull whose only lift is
  -- a burner has no bearing to put in the mix at all.
  for name, c in pairs(craft.controls) do
    if c.kind == "wire" and c.hold then
      mix[#mix + 1] = { demand = "lift", control = name, as = "signal" }
    end
  end

  table.sort(mix, function(a, b)
    if a.demand ~= b.demand then return a.demand < b.demand end
    return a.control < b.control
  end)

  craft.mix = mix
end

--- Build a starting hull from what is attached. This is what `probe` did.
--
-- Everything here except the peripheral names is a guess, and the guesses are
-- the ones worth checking: the first bearing is assumed to hold the ship up and
-- the second to push it along, and the first optical sensor to point down. Both
-- are the commonest arrangement and neither can be worked out by looking, which
-- is exactly why the wizard walks you onto the Bearings pane next.
local function generate()
  local craft = draft.craft or blankCraft()
  craft.controls = craft.controls or {}
  craft.instruments = craft.instruments or {}

  local bearings = attached.thruster_bearing or {}

  if bearings[1] then
    craft.controls.lift = { kind = "bearing", peripheral = bearings[1],
                            group = "all" }
  end
  if bearings[2] then
    craft.controls.main = { kind = "bearing", peripheral = bearings[2],
                            group = "all", pivot = { min = -30, max = 30 } }
  end

  -- A hull with no bearing at all may still drive a thruster directly.
  if not bearings[1] and firstOf("thruster") then
    craft.controls.lift = { kind = "thruster", peripheral = firstOf("thruster") }
  end

  local orientation = firstOf("virtual_orientation_source")
  if orientation then
    craft.controls.trim = { kind = "orientation", peripheral = orientation }
  end
  if firstOf("wheel_mount") then
    craft.controls.wheels = { kind = "wheels", peripheral = firstOf("wheel_mount") }
  end
  if firstOf("claw") or firstOf("rope_winch_cable") then
    craft.controls.claw = { kind = "grip",
                            peripheral = firstOf("claw") or firstOf("rope_winch_cable") }
  end

  -- Instruments. Named rather than left to be found, so the file is a
  -- description of this ship rather than a list of overrides -- and so a hull
  -- that loses a sensor says so instead of quietly flying without it.
  local eyes = attached.optical_sensor or {}
  for _, entry in ipairs(cfg.instruments) do
    local side
    if entry.role == "ground" then side = eyes[1]
    elseif entry.role == "forward" then side = eyes[2]
    else side = firstOf(entry.kind) end

    -- Only ever filled in, never cleared. A role with nothing attached is left
    -- absent so it is found automatically once its block appears, which is what
    -- has to happen on a contraption assembled after the computer was switched
    -- on. Writing `false` for it turned a temporary absence into a permanent
    -- one, and that was the bug the whole configurator was first built for.
    if side and craft.instruments[entry.role] == nil then
      craft.instruments[entry.role] = side
    end
  end

  draft.craft = craft
  rebuildMix()
  recheck()
end

--- The full peripheral dump `probe` used to write. Longer than any screen, so it
--- goes to a file you can read while editing something else.
local function survey()
  local lines = {
    "Peripherals attached to computer " .. os.getComputerID(),
    ("Label: %s"):format(os.getComputerLabel() or "(none)"),
    ("Role:  %s"):format(draft.network.role),
    "",
  }

  local count = 0
  local ok, names = pcall(peripheral.getNames)
  for _, side in ipairs(ok and names or {}) do
    local okType, kind = pcall(peripheral.getType, side)
    if okType and kind then
      count = count + 1
      lines[#lines + 1] = ("%s  [%s]"):format(side, kind)

      local okM, methods = pcall(peripheral.getMethods, side)
      if okM and type(methods) == "table" then
        table.sort(methods)
        -- Wrapped rather than dumped on one line: a bearing has fifty methods
        -- and a single line of them is unreadable in every editor CC has.
        local row = "   "
        for _, m in ipairs(methods) do
          if #row + #m + 2 > 72 then lines[#lines + 1] = row row = "   " end
          row = row .. m .. " "
        end
        if row ~= "   " then lines[#lines + 1] = row end
      else
        lines[#lines + 1] = "   (no methods -- not something we can drive)"
      end
      lines[#lines + 1] = ""
    end
  end

  if count == 0 then
    lines[#lines + 1] = "Nothing is attached."
    lines[#lines + 1] = ""
    lines[#lines + 1] = "A computer only sees blocks it touches, or blocks on the"
    lines[#lines + 1] = "same wired modem network. On an assembled contraption both"
    lines[#lines + 1] = "the computer and the blocks have to be part of it."
  end

  local f = fs.open(config.surveyFile, "w")
  if not f then return nil end
  for _, line in ipairs(lines) do f.writeLine(line) end
  f.close()

  surveyed = count
  return count
end

--------------------------------------------------------------------------------
-- The wizard's running order
--------------------------------------------------------------------------------

-- Per role, because a beacon has no bearings and a pocket computer has no hull.
-- The order is the order the answers depend on each other in: the role decides
-- which panes exist at all, the hardware scan decides what the hull pane can
-- offer, and the hull has to exist before there is anything to point at.
local ORDER = {
  pilot  = { "welcome", "network", "hardware", "hull", "bearings",
             "instruments", "redstone", "limits", "review" },
  server = { "welcome", "network", "hardware", "review" },
  beacon = { "welcome", "network", "hardware", "waypoint", "review" },
  remote = { "welcome", "network", "hardware", "review" },
}

local function order() return ORDER[draft.network.role] or ORDER.pilot end

local function stepIndex()
  for i, name in ipairs(order()) do
    if name == pane then return i end
  end
  return nil
end

local function goTo(name)
  pane = name
  list.scroll = 0
end

local function advance(by)
  local at = stepIndex()
  if not at then return goTo("review") end
  local steps = order()
  local to = math.max(1, math.min(#steps, at + by))
  goTo(steps[to])
end

--------------------------------------------------------------------------------
-- Panes
--------------------------------------------------------------------------------

local function row(entry) return ui.row(list, entry) end

local function gap() row({ kind = "gap" }) end

local function heading(text) row({ kind = "head", label = text }) end

local function text(line, colour)
  row({ kind = "note", text = " " .. line, colour = colour or ui.theme.dim })
end

local function action(label, fn, colour)
  row({ kind = "action", text = label, click = fn, colour = colour })
end

local function back()
  action("< back", function() goTo("main") end, ui.theme.accent)
end

--- The problems, drawn wherever they are wanted. Each one offers to take you to
--- the pane that fixes it, which is the difference between a diagnosis and a
--- direction.
local function showProblems(clickable)
  local bad, warn = 0, 0
  for _, p in ipairs(problems) do
    if p.severity == "bad" then bad = bad + 1 else warn = warn + 1 end
  end

  if #problems == 0 then
    text("Nothing wrong that this can see.", ui.theme.ok)
    return
  end

  heading(bad > 0 and "problems -- these stop it working" or "worth knowing")
  for _, p in ipairs(problems) do
    row({
      kind = "note", text = " " .. p.text,
      colour = p.severity == "bad" and ui.theme.bad or ui.theme.warn,
      click = clickable and p.pane and function() goTo(p.pane) end or nil,
    })
  end
end

--------------------------------------------------------------------------------

local ROLE_WHY = {
  pilot  = "rides the contraption and flies it",
  server = "the tower: waypoints, the log, the map",
  beacon = "stands still and is a waypoint",
  remote = "the pocket computer you command from",
}

local function buildWelcome()
  text("This computer has not been set up, so this is", ui.theme.text)
  text("the short version of setting it up. Nothing is", ui.theme.text)
  text("written until the end, and you can go back.", ui.theme.text)
  gap()

  heading("what is this computer?")

  if pocket then
    -- Not a question. A pocket computer cannot ride a hull or stand in a field,
    -- and asking would only offer three wrong answers.
    text("A pocket computer is always the remote.", ui.theme.ok)
    draft.network.role = "remote"
  else
    for _, name in ipairs({ "pilot", "server", "beacon" }) do
      row({
        kind = "choice", label = name, on = draft.network.role == name,
        why = ROLE_WHY[name],
        click = function()
          draft.network.role = name
          if name == "pilot" and not draft.craft then draft.craft = blankCraft() end
          if name == "beacon" and not draft.beacon then
            draft.beacon = { name = draft.network.name, kind = "point" }
          end
          recheck()
        end,
      })
    end
  end

  gap()
  text("Hardware cannot tell a pilot from a tower --", ui.theme.dim)
  text("both are plain computers, and the blocks that", ui.theme.dim)
  text("would give it away are on the contraption.", ui.theme.dim)
end

local function buildNetwork()
  local n = draft.network
  if not WIZARD then back() end
  heading("network")

  row({ kind = "value", label = "name", value = n.name,
        why = "what this computer is called",
        click = function() typing = ui.field("name") end })

  row({ kind = "value", label = "network", value = n.protocol,
        why = "only talks to others on the same one",
        click = function() typing = ui.field("network") end })

  row({ kind = "step", text = ("  channel    %d"):format(n.channel),
        click = function(x, w)
          n.channel = math.max(1, math.min(65535,
            n.channel + (x >= w - 1 and 1 or -1)))
        end })
  text("  the port, and the real separation")
  gap()
  text("A modem raises no event for a channel it has")
  text("not opened, so two networks on different")
  text("channels genuinely do not touch.")

  if not WIZARD then
    gap()
    heading("role")
    for _, name in ipairs({ "pilot", "server", "beacon" }) do
      row({ kind = "choice", label = name, on = n.role == name,
            why = ROLE_WHY[name],
            click = function()
              n.role = name
              if name == "pilot" and not draft.craft then draft.craft = blankCraft() end
              recheck()
            end })
    end
  end
end

--- The live checklist. This was `setup.lua`, and it re-scans while you watch so
--- you can walk over, place the block, and see the line go green.
local function buildHardware()
  if not WIZARD then back() end

  local spec = needs.roles[draft.network.role]
  local rows, summary = needs.check(draft.network.role, cfg.found(attached))
  local verdict, mood = needs.verdict(summary, draft.network.role)

  heading(spec and spec.title or "hardware")
  row({ kind = "note", text = " " .. verdict,
        colour = mood == "ok" and ui.theme.ok
          or (mood == "warn" and ui.theme.warn or ui.theme.bad) })
  gap()

  for _, entry in ipairs(rows) do
    local item = entry.item
    local mark = entry.ok and "yes" or (item.tier == "required" and "NO" or "--")
    local colour = entry.ok and ui.theme.ok
      or (item.tier == "required" and ui.theme.bad or ui.theme.dim)

    local count = entry.want > 1
      and (" (%d of %d)"):format(entry.have, entry.want) or ""

    row({ kind = "note", colour = colour,
          text = ("%-4s %s%s"):format(mark, item.what, count) })

    -- Only explained when it is missing. A screen that explains everything
    -- explains nothing.
    if not entry.ok then
      text("       " .. item.why)
      text("       without: " .. item.without)
    end
  end

  gap()
  heading("tools")
  action("Write a full survey to a file", function()
    local count = survey()
    note(count and ("surveyed %d peripherals"):format(count) or "could not write")
  end)
  text("  every peripheral and every method it has")
  text("  " .. config.surveyFile)

  if (attached.optical_sensor or {})[1] then
    action("Watch the optical sensors", function() watching = true end)
    text("  what they really report, live")
    text("  a broken sensor and one pointed at a long")
    text("  drop look identical from every other screen")
  end

  gap()
  text("This re-scans every second. Go and place the")
  text("missing block and watch the line turn green.")

  if draft.network.role == "pilot" and not next(attached) then
    gap()
    text("Nothing at all is attached, which usually means", ui.theme.warn)
    text("the contraption is not assembled yet. Assemble", ui.theme.warn)
    text("it and this fills in by itself.", ui.theme.warn)
  end
end

--- The hull pane: build a starting /craft.cfg from what is bolted on. This was
--- `probe`, and it is the step that saves the most time -- wiring a hull by hand
--- from a documentation page is where the mistakes come from, and every one of
--- them shows up as a ship that will not fly with nothing to say which line is
--- wrong.
local function buildHull()
  if not WIZARD then back() end
  heading("the hull")

  local craft = draft.craft
  local controls = 0
  for _ in pairs((craft or {}).controls or {}) do controls = controls + 1 end

  local bearings = #(attached.thruster_bearing or {})
  local eyes = #(attached.optical_sensor or {})

  row({ kind = "pair", left = "bearings", right = tostring(bearings) })
  row({ kind = "pair", left = "optical", right = tostring(eyes) })
  row({ kind = "pair", left = "controls set", right = tostring(controls) })
  gap()

  if bearings == 0 and not firstOf("thruster") then
    text("No thruster bearing and no thruster.", ui.theme.bad)
    text("There is nothing here to drive. Assemble the", ui.theme.dim)
    text("contraption, or check the computer is part of", ui.theme.dim)
    text("it -- a computer only sees blocks it touches.", ui.theme.dim)
  else
    action(controls > 0 and "Build it again from what is attached"
                        or "Build a hull from what is attached",
           function()
             generate()
             note("built from " .. bearings .. " bearing(s)")
             if WIZARD then advance(1) end
           end, ui.theme.ok)
    text("  fills in the controls, the instruments and")
    text("  a standard mix, then asks you which bearing")
    text("  is which -- the one thing it cannot guess")
  end

  if controls > 0 then
    gap()
    heading("what it has now")
    local names = {}
    for name in pairs(craft.controls) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      local c = craft.controls[name]
      row({ kind = "pair", left = name,
            right = (c.peripheral or c.side or "?") .. "  " .. c.kind })
    end
  end
end

local function usedBy(side)
  for name, c in pairs((draft.craft or {}).controls or {}) do
    if c.peripheral == side then return name end
  end
  return nil
end

--- Point `name` at `side`, taking it off whatever had it.
--
-- Swapping lift and main is the single most valuable thing this program does, so
-- it is one action rather than two: assigning a bearing that is already the
-- other one exchanges them, instead of leaving a hull with two lifts and nothing
-- to push it along.
local function assign(name, side)
  local craft = draft.craft
  local holder = usedBy(side)

  if holder and holder ~= name then
    local ours = craft.controls[name]
    craft.controls[holder] = ours and {
      kind = ours.kind, peripheral = ours.peripheral,
      group = ours.group, pivot = ours.pivot,
    } or nil
  end

  craft.controls[name] = craft.controls[name] or { kind = "bearing", group = "all" }
  craft.controls[name].peripheral = side

  if name == "main" then
    craft.controls[name].pivot = craft.controls[name].pivot
      or { min = -30, max = 30 }
  end

  rebuildMix()
  recheck()
end

local function buildBearings()
  if not WIZARD then back() end

  local bearings = attached.thruster_bearing or {}
  if #bearings == 0 then
    heading("bearings")
    text("No thruster bearings attached.", ui.theme.bad)
    text("Assemble the contraption first, then come back.")
    return
  end

  heading("lift -- holds the ship up")
  for _, side in ipairs(bearings) do
    local c = (draft.craft.controls or {}).lift
    row({ kind = "choice", label = side, on = c and c.peripheral == side,
          why = usedBy(side) and ("currently " .. usedBy(side)) or "unused",
          click = function() assign("lift", side) note("lift is " .. side) end })
  end

  heading("main -- pushes it along")
  for _, side in ipairs(bearings) do
    local c = (draft.craft.controls or {}).main
    row({ kind = "choice", label = side, on = c and c.peripheral == side,
          why = usedBy(side) and ("currently " .. usedBy(side)) or "unused",
          click = function() assign("main", side) note("main is " .. side) end })
  end

  gap()
  local lift = (draft.craft.controls or {}).lift
  local main = (draft.craft.controls or {}).main

  if lift and main and lift.peripheral == main.peripheral then
    text("Both are the same bearing.", ui.theme.bad)
  end

  text("Getting these the wrong way round is a ship", ui.theme.warn)
  text("that flies into the ground. Nothing can work", ui.theme.warn)
  text("it out by looking -- only you can.", ui.theme.warn)
  gap()
  text("If this hull is a balloon, it may have no lift")
  text("bearing at all: its lift is a burner on a wire.")
  text("Set that on the Redstone pane.")
end

local function buildInstruments()
  if not WIZARD then back() end
  heading("instruments")

  for _, entry in ipairs(cfg.instruments) do
    local set = (draft.craft.instruments or {})[entry.role]
    local here = attached[entry.kind] or {}

    local shown, colour
    if set == false then
      shown, colour = "none (deliberately)", ui.theme.dim
    elseif type(set) == "string" then
      shown = set
      colour = peripheral.isPresent(set) and ui.theme.ok or ui.theme.warn
    elseif #here > 0 then
      shown, colour = "auto: " .. here[1], ui.theme.ok
    else
      shown = "not attached"
      colour = entry.tier == "required" and ui.theme.warn or ui.theme.dim
    end

    row({
      kind = "instrument", label = entry.role, value = shown, why = entry.what,
      colour = colour,
      -- Cycles: auto, then each attached one, then off. Every state a craft file
      -- can hold, reachable by tapping -- including the `false` that used to be
      -- the trap, because switching one off deliberately is legitimate and
      -- should look different from having it broken.
      click = function()
        local options = {}
        for _, side in ipairs(here) do options[#options + 1] = side end
        options[#options + 1] = false

        local at = 0
        for i, option in ipairs(options) do
          if option == set then at = i end
        end

        local nextAt = at + 1
        draft.craft.instruments[entry.role] =
          nextAt > #options and nil or options[nextAt]
        recheck()
      end,
    })
  end

  gap()
  local eyes = #(attached.optical_sensor or {})
  if eyes >= 2 then
    text("Two optical sensors look identical from here.", ui.theme.warn)
    text("Only you know which points down and which", ui.theme.warn)
    text("points forward. A forward one read as the", ui.theme.warn)
    text("ground fires the terrain guard at a hillside", ui.theme.warn)
    text("the ship is not under yet.", ui.theme.warn)
  end
  text("Tapping cycles: found automatically, then each")
  text("attached one by name, then off. Off means this")
  text("hull has none -- it stops the warnings.")
end

--------------------------------------------------------------------------------
-- Redstone, which the old configurator could not do at all
--------------------------------------------------------------------------------

local SIDES = { "top", "bottom", "left", "right", "front", "back" }
local MODES = { "digital", "analog", "bundled" }

local function cycle(listOf, value, by)
  local at = 1
  for i, v in ipairs(listOf) do if v == value then at = i end end
  return listOf[((at - 1 + (by or 1)) % #listOf) + 1]
end

local function buildRedstone()
  if not WIZARD then back() end
  heading("redstone")

  local craft = draft.craft
  local wires = {}
  for name, c in pairs(craft.controls or {}) do
    if c.kind == "wire" then wires[#wires + 1] = name end
  end
  table.sort(wires)

  if #wires == 0 then
    text("No redstone controls. Most jet hulls need none.")
    gap()
  end

  for _, name in ipairs(wires) do
    local c = craft.controls[name]
    heading(name)
    row({ kind = "step", text = ("  side       %s"):format(c.side or "top"),
          click = function(x, w)
            c.side = cycle(SIDES, c.side or "top", x >= w - 1 and 1 or -1)
          end })
    row({ kind = "step", text = ("  mode       %s"):format(c.mode or "digital"),
          click = function(x, w)
            c.mode = cycle(MODES, c.mode or "digital", x >= w - 1 and 1 or -1)
          end })
    row({ kind = "choice", label = "holds when the program stops",
          on = c.hold == true,
          why = c.hold and "this is lift" or "released on exit",
          click = function()
            c.hold = not c.hold
            rebuildMix()
            recheck()
          end })
    action("  remove " .. name, function()
      craft.controls[name] = nil
      rebuildMix()
      recheck()
      note("removed " .. name)
    end, ui.theme.bad)
  end

  gap()
  heading("add")
  action("Add a burner -- analogue, and held", function()
    craft.controls.burner = { kind = "wire", side = "top", mode = "analog",
                              hold = true }
    rebuildMix()
    recheck()
    note("added burner on top")
  end, ui.theme.ok)
  action("Add a vent -- digital, released on exit", function()
    craft.controls.vent = { kind = "wire", side = "left", mode = "digital" }
    rebuildMix()
    recheck()
    note("added vent on left")
  end, ui.theme.ok)
  action("Add one with a name...", function()
    typing = ui.field("wire name")
  end)

  gap()
  text("A great deal of Create Aeronautics is driven by")
  text("a signal rather than a method call: burners,")
  text("steam vents, gearshifts, and every thruster")
  text("left in its default redstone control mode.")
  gap()
  text("A burner and a steam vent are analogue -- the")
  text("signal strength sets the target volume of hot", ui.theme.warn)
  text("air, so the signal IS the lift. Held means it", ui.theme.warn)
  text("keeps burning when the program stops, which on", ui.theme.warn)
  text("a balloon is the difference between landing and", ui.theme.warn)
  text("falling.", ui.theme.warn)
end

--------------------------------------------------------------------------------

local function buildLimits()
  if not WIZARD then back() end
  heading("limits -- blocks per second")

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
          click = function(x, w)
            l[key] = math.max(low, math.min(high, l[key] + (x >= w - 1 and 1 or -1)))
          end })
    text("   " .. why)
  end

  heading("hover")
  row({ kind = "step",
        text = ("  hover      %.2f"):format(draft.craft.gains.hover or 0.5),
        click = function(x, w)
          draft.craft.gains.hover = math.max(0, math.min(1,
            (draft.craft.gains.hover or 0.5) + (x >= w - 1 and 0.05 or -0.05)))
        end })
  text("   throttle that neither climbs nor sinks")
  text("   a guess is fine; the loop finds the rest")
end

--------------------------------------------------------------------------------

local function buildWaypoint()
  if not WIZARD then back() end
  draft.beacon = draft.beacon or { name = draft.network.name, kind = "point" }
  local b = draft.beacon

  heading("this waypoint")
  row({ kind = "value", label = "name", value = b.name or "",
        why = "what ships are told to fly to",
        click = function() typing = ui.field("waypoint name") end })

  row({ kind = "choice", label = "a pad ships can land on",
        on = b.kind == "pad",
        why = b.kind == "pad" and "pad" or "just a point to fly over",
        click = function()
          b.kind = (b.kind == "pad") and "point" or "pad"
          recheck()
        end })

  heading("where it is")
  for _, axis in ipairs({ "x", "y", "z" }) do
    row({ kind = "step", text = ("  %s          %s"):format(axis,
            b[axis] and tostring(math.floor(b[axis])) or "not set"),
          click = function(x, w)
            b[axis] = (tonumber(b[axis]) or 0) + (x >= w - 1 and 1 or -1)
            recheck()
          end })
  end

  action("Type the coordinates", function() typing = ui.field("x y z", "[%d%-%s]", 20) end)

  if gps then
    action("Use GPS, if there is one", function()
      local x, y, z = gps.locate(2)
      if x then
        b.x, b.y, b.z = math.floor(x), math.floor(y), math.floor(z)
        recheck()
        note(("gps: %d %d %d"):format(b.x, b.y, b.z))
      else
        note("no gps fix")
      end
    end)
  end

  gap()
  text("A beacon is a marker and nothing more: it")
  text("remembers three numbers and says them. GPS is")
  text("offered as a convenience and never required --")
  text("it needs satellites and loaded chunks, which is")
  text("exactly what a beacon in a far chunk lacks.")
end

--------------------------------------------------------------------------------
-- Review, and writing
--------------------------------------------------------------------------------

local function apply()
  local ok, why = cfg.writeNetwork(draft.network)
  if not ok then note("could not write: " .. tostring(why)) return end

  if draft.network.role == "pilot" and draft.craft then
    ok, why = cfg.writeCraft(draft.craft)
    if not ok then note("could not write: " .. tostring(why)) return end
  end

  if draft.network.role == "beacon" and draft.beacon then
    ok, why = cfg.writeBeacon(draft.beacon)
    if not ok then note("could not write: " .. tostring(why)) return end
  end

  -- Ends the program rather than showing a "done" pane. A pane would need one
  -- more event to get past, which on a wizard that has just written everything
  -- is a screen asking you to press a key to agree that you pressed a key.
  applied = true
  running = false
end

local function buildReview()
  if not WIZARD then back() end

  -- APPLY is the last row of this pane and this pane is longer than the screen,
  -- so on a hull of any size the only button that does anything sits below the
  -- fold behind a one-character scroll arrow. The symptom was somebody
  -- carefully setting everything, leaving, and finding the file unchanged with
  -- nothing anywhere to say why. So say it at the top, where the eye already is.
  text("ENTER writes it all. Or scroll to APPLY at", ui.theme.ok)
  text("the end of this list.", ui.theme.ok)
  gap()

  showProblems(false)
  gap()

  local n = draft.network
  heading("about to write")
  row({ kind = "pair", left = "file", right = config.overridesFile })
  row({ kind = "pair", left = "name", right = n.name })
  row({ kind = "pair", left = "network", right = n.protocol })
  row({ kind = "pair", left = "channel", right = tostring(n.channel) })
  row({ kind = "pair", left = "role", right = n.role })

  if n.role == "pilot" and draft.craft then
    heading("controls -- " .. config.craftFile)
    local names = {}
    for name in pairs(draft.craft.controls) do names[#names + 1] = name end
    table.sort(names)
    if #names == 0 then text("none", ui.theme.bad) end
    for _, name in ipairs(names) do
      local c = draft.craft.controls[name]
      row({ kind = "pair", left = name,
            right = (c.peripheral or c.side or "?") })
    end

    heading("instruments")
    for _, entry in ipairs(cfg.instruments) do
      local set = draft.craft.instruments[entry.role]
      if set ~= nil then
        row({ kind = "pair", left = entry.role,
              right = set == false and "none" or tostring(set) })
      end
    end

    local l = draft.craft.limits
    heading("limits")
    row({ kind = "pair", left = "cruise", right = tostring(l.cruise) })
    row({ kind = "pair", left = "climb", right = tostring(l.climb) })
    row({ kind = "pair", left = "descend", right = tostring(l.descend) })
    row({ kind = "pair", left = "clearance", right = tostring(l.clearance) })
    row({ kind = "pair", left = "mix terms", right = tostring(#draft.craft.mix) })
  end

  if n.role == "beacon" and draft.beacon then
    local b = draft.beacon
    heading("waypoint -- " .. config.beaconFile)
    row({ kind = "pair", left = "name", right = tostring(b.name) })
    row({ kind = "pair", left = "kind", right = tostring(b.kind) })
    row({ kind = "pair", left = "at",
          right = ("%s %s %s"):format(b.x or "?", b.y or "?", b.z or "?") })
  end

  gap()
  action("APPLY -- write it", apply, ui.theme.ok)
end

local function buildMain()
  showProblems(true)
  gap()

  action("Network -- name, channel, role",
         function() goTo("network") end)
  action("Hardware -- what is attached, live",
         function() goTo("hardware") end)

  if draft.network.role == "pilot" then
    action("The hull -- build one from what is attached",
           function() goTo("hull") end)
    action("Bearings -- which is lift, which is main",
           function() goTo("bearings") end, ui.theme.accent)
    action("Instruments -- what this hull can read",
           function() goTo("instruments") end)
    action("Redstone -- burners, vents, wires",
           function() goTo("redstone") end)
    action("Limits -- speeds, heights, hover",
           function() goTo("limits") end)
  end

  if draft.network.role == "beacon" then
    action("Waypoint -- name and coordinates",
           function() goTo("waypoint") end)
  end

  gap()
  action("Review and apply", function() goTo("review") end, ui.theme.ok)
  action("Run the wizard again", function()
    WIZARD = true
    goTo("welcome")
  end)
  action("Quit without saving", function() running = false end, ui.theme.dim)
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

local BUILD = {
  welcome = buildWelcome, main = buildMain, network = buildNetwork,
  hardware = buildHardware, hull = buildHull, bearings = buildBearings,
  instruments = buildInstruments, redstone = buildRedstone, limits = buildLimits,
  waypoint = buildWaypoint, review = buildReview,
}

local TITLE = {
  welcome = "Welcome", main = "Configure", network = "Network",
  hardware = "Hardware", hull = "The hull", bearings = "Bearings",
  instruments = "Instruments", redstone = "Redstone", limits = "Limits",
  waypoint = "Waypoint", review = "Review",
}

local function drawRow(entry, y, w)
  if entry.kind == "head" then
    ui.fill(1, y, w, 1, ui.theme.panel)
    ui.at(1, y, ui.fit(" " .. entry.label, w, true), ui.theme.bg, ui.theme.panel)

  elseif entry.kind == "action" then
    ui.at(1, y, ui.fit(" " .. entry.text, w, true), entry.colour or ui.theme.text)

  elseif entry.kind == "choice" then
    local split = math.min(24, math.max(12, math.floor(w * 0.55)))
    ui.at(1, y, ui.fit((entry.on and " (*) " or " ( ) ") .. entry.label, split, true),
          entry.on and ui.theme.ok or ui.theme.text)
    ui.at(split + 1, y, ui.fit(entry.why or "", w - split, true), ui.theme.dim)

  elseif entry.kind == "instrument" then
    local nameW = 9
    local valueW = math.max(8, math.floor((w - nameW) * 0.55))
    ui.at(1, y, ui.fit(" " .. entry.label, nameW, true), ui.theme.text)
    ui.at(nameW + 1, y, ui.fit(entry.value, valueW, true), entry.colour)
    ui.at(nameW + valueW + 1, y,
          ui.fit(entry.why or "", w - nameW - valueW, true), ui.theme.dim)

  elseif entry.kind == "value" then
    local nameW = 9
    local valueW = math.max(8, math.floor((w - nameW) * 0.55))
    ui.at(1, y, ui.fit(" " .. entry.label, nameW, true), ui.theme.text)
    ui.at(nameW + 1, y, ui.fit(entry.value == "" and "(unset)" or entry.value,
          valueW, true), ui.theme.select)
    ui.at(nameW + valueW + 1, y,
          ui.fit(entry.why or "", w - nameW - valueW, true), ui.theme.dim)

  elseif entry.kind == "step" then
    ui.at(1, y, ui.fit(entry.text, w - 4, true), ui.theme.text)
    ui.at(w - 3, y, "- +", ui.theme.accent)

  elseif entry.kind == "pair" then
    local leftW = math.min(14, math.max(8, math.floor(w * 0.35)))
    ui.at(1, y, ui.fit(" " .. entry.left, leftW, true), ui.theme.dim)
    ui.at(leftW + 1, y, ui.fit(entry.right, w - leftW, true), ui.theme.text)

  elseif entry.kind == "note" then
    ui.at(1, y, ui.fit(entry.text, w, true), entry.colour or ui.theme.dim)

  elseif entry.kind == "gap" then
    ui.at(1, y, string.rep(" ", w), ui.theme.text)
  end

  ui.paint(ui.theme.text, ui.theme.bg)
end

--- The live optical sensor view. Owns the whole screen while it is up, because
--- it is the one thing here that is watched rather than read.
local function drawWatch(w, h)
  ui.paint(ui.theme.text, ui.theme.bg)
  term.clear()

  ui.fill(1, 1, w, 1, ui.theme.accent)
  ui.at(1, 1, ui.fit(" optical sensors", w, true), ui.theme.bg, ui.theme.accent)

  local function ask(side, method)
    local ok, result = pcall(peripheral.call, side, method)
    if not ok then return "ERROR", ui.theme.bad end
    if result == nil then return "nil", ui.theme.dim end
    return tostring(result), ui.theme.text
  end

  local role = {}
  for r, side in pairs((draft.craft or {}).instruments or {}) do
    if type(side) == "string" then role[side] = r end
  end

  local y = 3
  for _, side in ipairs(attached.optical_sensor or {}) do
    if y > h - 2 then break end
    ui.at(1, y, ui.fit(side .. "  [" .. (role[side] or "unassigned") .. "]", w, true),
          ui.theme.accent)
    y = y + 1
    for _, method in ipairs({ "getRange", "hasHit", "getDistance", "getBlock" }) do
      if y > h - 2 then break end
      local value, colour = ask(side, method)
      ui.at(1, y, ui.fit(("  %-10s %s"):format(method:gsub("^get", ""):lower(),
            value), w, true), colour)
      y = y + 1
    end
    y = y + 1
  end

  ui.fill(1, h, w, 1, ui.theme.panel)
  ui.at(1, h, ui.fit(" Q back", w, true), ui.theme.bg, ui.theme.panel)
  ui.paint(ui.theme.text, ui.theme.bg)
end

local function draw()
  local w, h = term.getSize()

  if watching then return drawWatch(w, h) end

  list.entries = {}
  local build = BUILD[pane]
  if build then build() end

  ui.paint(ui.theme.text, ui.theme.bg)
  term.clear()

  local bad = false
  for _, p in ipairs(problems) do
    if p.severity == "bad" then bad = true end
  end

  local banner = (pane == "main" and bad) and ui.theme.bad or ui.theme.accent
  ui.fill(1, 1, w, 1, banner)

  local at = stepIndex()
  local title = TITLE[pane] or ""
  if WIZARD and at then
    title = ("%s  (%d/%d)"):format(title, at, #order())
  end

  ui.at(1, 1, ui.fit(" aero -- " .. title, w - 8, true), ui.theme.bg, banner)
  ui.at(math.max(1, w - 7), 1, ui.fit(draft.network.role, 7),
        ui.theme.bg, banner)

  ui.draw(list, 1, 3, w, h - 4, function(entry, y) drawRow(entry, y, w) end)

  if typing then
    ui.drawField(typing, h, w)
  elseif not ui.drawFlash(flash, now(), h, w) then
    ui.fill(1, h, w, 1, ui.theme.panel)

    local hint
    if WIZARD then
      hint = (pane == "review") and " ENTER apply   LEFT back"
        or " ENTER next   LEFT back   up/down scroll"
    else
      hint = (pane == "review") and " ENTER apply   Q back"
        or " Q back   up/down scroll"
    end
    ui.at(1, h, ui.fit(hint, w, true), ui.theme.bg, ui.theme.panel)
  end

  ui.paint(ui.theme.text, ui.theme.bg)
end

--------------------------------------------------------------------------------
-- Typing
--------------------------------------------------------------------------------

local function commitTyping()
  local value = typing.text
  local prompt = typing.prompt
  typing = nil
  if value == "" then return end

  if prompt == "name" then
    draft.network.name = value
    if draft.craft then draft.craft.name = value end
    if draft.beacon and not draft.beacon.name then draft.beacon.name = value end

  elseif prompt == "network" then
    draft.network.protocol = value

  elseif prompt == "waypoint name" then
    draft.beacon.name = value

  elseif prompt == "wire name" then
    -- Named wires are how a hull says "this signal is the gearshift". The name
    -- is what the mix and the telemetry call it, so it has to be a Lua
    -- identifier -- ui.field's pattern already refuses anything else.
    draft.craft.controls[value] = { kind = "wire", side = "top",
                                    mode = "digital" }
    rebuildMix()
    note("added " .. value)

  elseif prompt == "x y z" then
    local x, y, z = value:match("(-?%d+)%s+(-?%d+)%s+(-?%d+)")
    if x then
      draft.beacon.x, draft.beacon.y, draft.beacon.z =
        tonumber(x), tonumber(y), tonumber(z)
      note(("at %s %s %s"):format(x, y, z))
    else
      note("three numbers, like: 40 70 -300")
    end
  end

  recheck()
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

scan()
draft.craft = cfg.craft()
draft.beacon = cfg.beacon()

if draft.network.role == "pilot" and not draft.craft then
  draft.craft = blankCraft()
end
if pocket then draft.network.role = "remote" end

-- A wizard on a computer with nothing attached and no hull yet is still worth
-- offering the generated hull, so the scan happens before the first draw rather
-- than when the pane is reached.
recheck()

if START_PANE and BUILD[START_PANE] then
  WIZARD = false
  goTo(START_PANE)
end

draw()

-- The clock is what makes the hardware pane worth having: it re-scans while you
-- are looking at it, so you can walk over and place the block. Everything else
-- redraws on it too, which costs nothing and keeps the sensor watch live.
local tick = os.startTimer(1)

while running do
  -- Raw, so terminate arrives as an event rather than as an error thrown out of
  -- the middle of the loop. It is the documented way out of the wizard -- see
  -- the `q` handler -- and a way out that skipped the epilogue would leave the
  -- screen half drawn and the shell prompt somewhere in the middle of it.
  local event, a, b, c = os.pullEventRaw()

  if event == "terminate" then
    break

  elseif event == "timer" and a == tick then
    tick = os.startTimer(1)
    scan()
    draw()

  elseif event == "peripheral" or event == "peripheral_detach" then
    scan()
    draw()

  elseif event == "term_resize" then
    draw()

  elseif watching then
    if event == "key" and (a == keys.q or a == keys.left) then
      watching = false
      draw()
    end

  elseif typing then
    if event == "char" then ui.type(typing, a) draw()
    elseif event == "key" then
      if a == keys.enter then commitTyping() draw()
      elseif a == keys.backspace then ui.backspace(typing) draw()
      end
    end

  elseif event == "mouse_click" then
    local w = term.getSize()
    for _, entry in ipairs(list.entries) do
      if entry.y == c and entry.click then
        entry.click(b, w)
        break
      end
    end
    recheck()
    draw()

  elseif event == "mouse_scroll" then
    list.scroll = math.max(0, list.scroll + a)
    draw()

  elseif event == "key" then
    if a == keys.up then
      list.scroll = math.max(0, list.scroll - 1)

    elseif a == keys.down then
      list.scroll = list.scroll + 1

    elseif a == keys.enter then
      if pane == "review" then apply()
      elseif WIZARD then advance(1) end

    elseif a == keys.right and WIZARD then
      advance(1)

    elseif a == keys.left and WIZARD then
      advance(-1)

    elseif a == keys.q then
      if WIZARD then
        -- Deliberately not a way out. A computer that has not been configured
        -- cannot do its job, and letting Q past this leaves somebody at a shell
        -- wondering why the ship will not fly. Ctrl-T still works, so a person
        -- at the keyboard is never actually trapped -- an unattended computer
        -- rebooting into the wizard is the case this protects.
        note("finish the wizard, or Ctrl-T to give up")
      elseif pane == "main" then
        running = false
      else
        goTo("main")
      end
    end

    draw()
  end
end

--------------------------------------------------------------------------------

ui.paint(ui.theme.text, ui.theme.bg)
term.clear()
term.setCursorPos(1, 1)

if applied then
  ui.paint(ui.theme.ok, ui.theme.bg)
  print("Written.")
  ui.paint(ui.theme.text, ui.theme.bg)
  print("")
  print(config.overridesFile .. " -- " .. draft.network.role
    .. " on " .. draft.network.protocol .. "/" .. draft.network.channel)
  if draft.network.role == "pilot" then print(config.craftFile) end
  if draft.network.role == "beacon" then print(config.beaconFile) end
  print("")

  -- Said rather than done. `startup.lua` re-checks and launches by itself when
  -- this was run from a boot, and a configurator that rebooted the computer out
  -- from under somebody who only wanted to change the channel would be a
  -- genuinely alarming thing to use.
  print("Reboot to start, or run the program directly.")
else
  print("Nothing written.")
end
