--- The startup log.
--
-- Every program here comes up by doing half a dozen things that can each fail
-- quietly: read a config, load a hull, find a modem, restore a plan. Until now
-- they did them in silence and you found out something was wrong later, from a
-- warning line on a screen that had already been redrawn twice.
--
-- So each step says what it is doing and whether it worked. Borrowed shamelessly
-- from cc-mek-scada, which prints a boot log for exactly this reason: a computer
-- that comes up wrong should tell you *where* it stopped, not present a blank
-- screen and let you guess.
--
--   boot.start("Kestrel", "pilot")
--   boot.step("craft file", function() return hull.load() end)
--   boot.note("3 controls, 5 instruments")
--   boot.done()
--
-- Failures do not throw. A pilot that cannot find its hull still has to reach
-- the part of its own startup that hands the hull back to redstone, so the log
-- records and carries on, and the program decides for itself what is fatal.

local ui = require("lib.ui")

local boot = {}

boot.lines   = {}      -- kept, so a program can show what happened at boot later
boot.failed  = 0
boot.warned  = 0
boot.quiet   = false   -- set by the test harness: a boot log is not a test result

--------------------------------------------------------------------------------

local function put(mark, colour, text)
  boot.lines[#boot.lines + 1] = { mark = mark, text = text, colour = colour }
  if boot.quiet then return end

  local w = term.getSize()

  -- The mark is a fixed four columns so the messages line up down the screen,
  -- which is the whole reason a boot log is readable at a glance rather than
  -- being a paragraph.
  ui.paint(colour, ui.theme.bg)
  term.write(("%-4s"):format(mark))
  ui.paint(ui.theme.text, ui.theme.bg)
  print(ui.fit(text, math.max(1, w - 5)))
end

--- Begin. Says what this computer thinks it is, which is worth stating out loud:
--- a pilot that has come up as a tower because /aero.cfg says so is otherwise a
--- baffling ten minutes.
function boot.start(name, role, version)
  boot.lines, boot.failed, boot.warned = {}, 0, 0

  if not boot.quiet then
    term.clear()
    term.setCursorPos(1, 1)
    ui.paint(ui.theme.accent, ui.theme.bg)
    print(("aero %s -- %s as %s"):format(version or "", tostring(name),
                                         tostring(role)))
    ui.paint(ui.theme.text, ui.theme.bg)
  end
end

--- Run one step. `fn` returns ok, detail -- the shape every loader in this
--- project already uses, so nothing had to change to be logged.
function boot.step(label, fn)
  local ok, detail = pcall(fn)

  if not ok then
    -- A step that threw is worse than one that returned false, and the
    -- difference is worth keeping: the message is a Lua error, not an
    -- explanation, and saying so stops somebody hunting for a config option
    -- called "attempt to index a nil value".
    boot.failed = boot.failed + 1
    put("ERR", ui.theme.bad, label .. ": " .. tostring(detail))
    return false, detail
  end

  local result, why = detail, nil
  if type(detail) == "table" then why = detail[1] end

  if result == false then
    boot.failed = boot.failed + 1
    put("FAIL", ui.theme.bad, label .. (why and (": " .. tostring(why)) or ""))
    return false, why
  end

  put("ok", ui.theme.ok, label)
  return true, detail
end

--- A step that is allowed to be absent. Says so in a colour that does not look
--- like a fault, because most hulls are missing most optional things and a
--- screen of red on a healthy ship teaches people to ignore red.
function boot.optional(label, present, detail)
  if present then
    put("ok", ui.theme.ok, label .. (detail and (": " .. detail) or ""))
  else
    boot.warned = boot.warned + 1
    put("--", ui.theme.dim, label .. (detail and (": " .. detail) or ""))
  end
  return present
end

--- Something worth knowing that did not pass or fail.
function boot.note(text)
  put("", ui.theme.dim, text)
end

--- Something wrong that is not fatal.
function boot.warn(text)
  boot.warned = boot.warned + 1
  put("WARN", ui.theme.warn, text)
end

--- Finish, and hold the log on screen when anything went wrong.
--
-- A clean boot flicks past and the program takes over, which is right: nobody
-- wants to press a key every time a ship reboots. A boot with failures in it is
-- the one thing you actually wanted to read, and it would otherwise be erased a
-- tenth of a second later by the first redraw.
function boot.done(hold)
  if boot.quiet then return boot.failed end

  if boot.failed > 0 or (hold and boot.warned > 0) then
    ui.paint(ui.theme.warn, ui.theme.bg)
    print("")
    print(("%d problem%s. Press a key."):format(boot.failed + boot.warned,
      (boot.failed + boot.warned) == 1 and "" or "s"))
    ui.paint(ui.theme.text, ui.theme.bg)

    -- Bounded, so an unattended computer that reboots into a fault still comes
    -- up rather than sitting at a prompt in an unloaded chunk forever.
    local timer = os.startTimer(10)
    while true do
      local event, a = os.pullEvent()
      if event == "key" then break end
      if event == "timer" and a == timer then break end
      if event == "terminate" then break end
    end
  end

  return boot.failed
end

return boot
