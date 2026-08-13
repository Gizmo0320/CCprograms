--- What each kind of computer needs bolted to it.
--
-- Pure: a table of requirements and a function that checks a list of attached
-- peripheral types against it. `setup.lua` draws the result and `install.lua`
-- prints a short version of it, so both say exactly the same thing.
--
-- ## Why this exists as data
--
-- "It cannot find the navigation table" is the commonest way for this program to
-- fail, and it has at least four causes: the block is not on the contraption,
-- the contraption is not assembled, the craft file switched the role off, or
-- nothing has run `probe` yet. None of those is visible from a flight computer
-- printing one line of warning.
--
-- So the requirements are written down, per role, with what each thing is *for*
-- and what happens without it -- and a program can check the lot in one pass and
-- show you the answer rather than making you deduce it.
--
-- Three tiers, and the distinction matters more than it looks:
--
--   required     the role does not work at all without it
--   recommended  the role works, with a whole capability missing
--   optional     nice to have, nothing breaks

local needs = {}

--------------------------------------------------------------------------------

-- `kind` is the peripheral type as `getType()` reports it, or "modem" with
-- `wireless = true` for the one case where the type alone is not enough.
needs.roles = {

  pilot = {
    title = "Flight computer -- rides the contraption",
    items = {
      { kind = "modem", wireless = true, tier = "required",
        what = "wireless modem",
        why = "so the tower and the pocket can see this ship",
        without = "it still flies its own plan, but nothing can command it "
               .. "and you cannot watch it" },

      { kind = "navigation_table", tier = "required",
        what = "navigation table",
        why = "position and heading -- the only thing that supplies either",
        without = "the ship can hover but cannot go anywhere" },

      { kind = "altitude_sensor", tier = "required",
        what = "altitude sensor",
        why = "height, which the whole vertical loop is built on",
        without = "the pilot hands the hull back rather than fly it blind" },

      { kind = "thruster_bearing", tier = "required", any = { "thruster" },
        what = "thruster bearing (or a thruster)",
        why = "something to actually drive",
        without = "there is nothing for the autopilot to move" },

      { kind = "optical_sensor", tier = "recommended", count = 2,
        what = "optical sensor, pointing down",
        why = "ground clearance, for the terrain guard",
        without = "no terrain guard: nothing notices the ground coming up" },

      { kind = "docking_connector", tier = "optional",
        what = "docking connector",
        why = "so `dock` knows when it has arrived",
        without = "the ship can land, but not dock" },

      { kind = "gimbal_sensor", tier = "optional",
        what = "gimbal sensor",
        why = "pitch and roll, for the attitude guard",
        without = "no attitude guard unless CC: Sable is installed" },

      { kind = "analogue_joystick", tier = "optional",
        what = "analogue joystick",
        why = "so a person can take control by hand",
        without = "the autopilot is the only pilot" },
    },
  },

  server = {
    title = "Tower -- the base computer",
    items = {
      { kind = "modem", wireless = true, tier = "required",
        what = "wireless modem",
        why = "everything it does is listening and answering",
        without = "it cannot do anything at all" },

      { kind = "monitor", tier = "optional",
        what = "monitor",
        why = "the dashboard is drawn to it as well as the terminal",
        without = "the dashboard is only on this screen" },
    },
  },

  beacon = {
    title = "Beacon -- a waypoint that stands still",
    items = {
      { kind = "modem", wireless = true, tier = "required",
        what = "wireless modem",
        why = "so the tower hears it",
        without = "it is a computer standing in a field" },

      { kind = "docking_connector", tier = "optional",
        what = "docking connector",
        why = "reports whether the pad is occupied",
        without = "nobody can tell whether a ship is parked on it" },
    },
  },

  remote = {
    title = "Pocket computer -- the remote",
    items = {
      { kind = "modem", wireless = true, tier = "required",
        what = "wireless modem",
        why = "to see the fleet and command it",
        without = "it shows nothing" },
    },
  },
}

--------------------------------------------------------------------------------

--- Check one role against what is attached.
--
-- `found` is a list of { type = <string>, wireless = <boolean or nil> }, which
-- is everything the caller can learn from `peripheral` and all this needs. Pure,
-- so the whole table can be tested without a single peripheral.
--
-- Returns a list of { item, have, ok } and a summary of what is still missing.
function needs.check(role, found)
  local spec = needs.roles[role]
  if not spec then return {}, { missing = 0, required = 0 } end

  -- Counted rather than flagged, because two optical sensors is a different
  -- answer from one and the difference decides whether the obstacle guard
  -- exists at all.
  local count = {}
  for _, entry in ipairs(found or {}) do
    local kind = entry.type or entry
    if kind == "modem" and entry.wireless ~= true then
      kind = "wired_modem"      -- a wired modem is not a radio, and saying so
    end                         -- is kinder than "modem: found" next to silence
    count[kind] = (count[kind] or 0) + 1
  end

  local rows, missing, required = {}, 0, 0

  for _, item in ipairs(spec.items) do
    local have = count[item.kind] or 0

    -- Some requirements can be met by more than one block: a hull driving a
    -- single thruster directly is as valid as one with a bearing.
    for _, alternative in ipairs(item.any or {}) do
      have = have + (count[alternative] or 0)
    end

    local want = item.count or 1
    local ok = have >= want

    rows[#rows + 1] = { item = item, have = have, want = want, ok = ok }

    if not ok then
      missing = missing + 1
      if item.tier == "required" then required = required + 1 end
    end
  end

  return rows, { missing = missing, required = required }
end

--- One line saying whether this computer is ready, and what to do if not.
function needs.verdict(summary, role)
  if summary.required > 0 then
    return ("%d required item%s missing"):format(
      summary.required, summary.required == 1 and "" or "s"), "bad"
  end
  if summary.missing > 0 then
    return "ready, with things it could do better", "warn"
  end
  if role == "pilot" then
    return "everything attached -- run `probe` next", "ok"
  end
  return "everything attached", "ok"
end

return needs
