--- What the ship is doing, and the four things that outrank it.
--
-- Pure. Given the state, a fix and the time, it returns the next state and the
-- goal for lib/autopilot. No APIs, no clock, no peripherals -- which matters
-- more here than anywhere else in the project, because this file is the safety
-- argument and an argument you cannot test is not one.
--
-- ## The states
--
--   idle       parked. The hull is handed back to redstone, see below.
--   preflight  the checks, and the only place a flight is refused.
--   takeoff    straight up off the pad, no steering.
--   climb      towards cruise altitude, pointing at the first leg.
--   cruise     flying the plan.
--   descend    down to approach height over the destination.
--   approach   over the pad, coming down slowly.
--   land       the last few blocks, until the ground.
--   dock       like land, but ending on a docking connector rather than dirt.
--   loiter     holding altitude and heading, going nowhere, waiting.
--   manual     somebody has the joystick. The hull is handed back and the
--              autopilot keeps out of the way until they let go.
--   emergency  a controlled descent to the ground, wherever we happen to be.
--
-- `idle` hands the hull back rather than holding everything at zero. A parked
-- ship should behave exactly like a ship with no computer on it -- which is the
-- configuration its builder actually tested -- and "every engine off" is not
-- that. It is also the only sane thing to do with a hull we have stopped being
-- able to fly, which is why the no-altimeter case below routes here too.
--
-- ## The guards
--
-- Evaluated before the state logic, every sweep, in this order. They are the
-- reason this file is pure: each one is a decision that must be provably right,
-- and none of them needs anything from the world that the fix does not carry.
--
--   1. **The pilot's hands.** Somebody has taken the joystick. Get out of the
--      way -- two things commanding one hull is worse than either of them alone.
--   2. **Attitude.** Past a lean the autopilot cannot help with, stop flying it.
--      Past one where "up" is not up any more, stop touching it: see below.
--   3. **No vertical reference.** Without an altitude there is no rate of climb,
--      so there is no vertical loop, so the lift demand would sit at zero and
--      the ship would fall out of the sky under program control. Hand it back
--      instead. Worse than flying; much better than a powered descent into the
--      ground.
--   4. **Ground clearance.** Below the limit, climb -- whatever the flight plan
--      said, and whatever the altitude hold wanted. Exempt during `land`,
--      `approach` and `dock`, where getting close to the ground is the entire
--      objective.
--   5. **An obstacle ahead.** The clearance guard is a floor and nothing else: a
--      ship at cruise flying at the *side* of a mountain has perfect clearance
--      underneath it the whole way in. A forward-facing optical sensor closes
--      that, and without one there is simply no guard here.
--   6. **No usable fix.** Stop navigating and loiter. Dead reckoning cannot
--      correct itself and its error grows without bound; a ship that kept flying
--      a twenty-second-old guess would look perfectly healthy on the dashboard
--      right up until it hit something.
--   7. **Bingo fuel.** Turn for home while there is still enough to get there.
--      Latched: fuel that recovers because a tank was topped up does not cancel
--      a diversion already begun, because the diversion is now the plan and
--      changing your mind twice is how ships end up in the sea.
--
-- ## Why the attitude guard hands the hull back rather than trying harder
--
-- Every control law in this program assumes the lift demand pushes the ship away
-- from the ground. That is true while it is roughly level. On a hull leaning
-- past about seventy degrees the lift pushes it sideways, and past ninety it
-- pushes it **down** -- so a ship on its back with the altitude hold still
-- calling for more lift is being flown into the ground, at full power, by the
-- loop whose entire job is to stop that happening.
--
-- There is no cleverer answer available from here. The autopilot has no direct
-- attitude authority worth the name; the physics engine rights most hulls on its
-- own given the chance. So past `tiltAbort` the hull is handed back and the
-- ship is left alone, which is the one action guaranteed not to make it worse.
--
-- A guard produces a goal and a reason. It never silently changes the plan --
-- every one of them emits an event, because "why did it turn round" is the
-- question the log exists to answer.

local config = require("lib.config")
local nav    = require("lib.nav")
local terrain = require("lib.terrain")

local flight = {}

-- States in which being near the ground is intended rather than alarming.
local NEAR_GROUND = { approach = true, land = true, dock = true, idle = true,
                      preflight = true, takeoff = true }

-- States that are actually flying somewhere, and so need a usable fix.
local NAVIGATING = { climb = true, cruise = true, descend = true, approach = true }

-- States in which the ship is airborne under our control. Used by the fuel
-- guard, and by `update` being refused.
local AIRBORNE = { takeoff = true, climb = true, cruise = true, descend = true,
                   approach = true, land = true, dock = true, loiter = true,
                   emergency = true,
                   -- Somebody is flying it by hand, which is the last moment to
                   -- be replacing lib/hull.lua underneath them.
                   manual = true }

--------------------------------------------------------------------------------

function flight.new()
  return {
    state = "idle",
    since = 0,
    plan  = nil,        -- a nav.plan, or nil
    goal  = { idle = true },
    guard = nil,        -- which guard is currently overriding, or nil
    why   = "boot",
    bingo = false,      -- latched, see above
    alt   = nil,        -- the cruise altitude this flight is using
    home  = nil,        -- waypoint name to divert to
    dockTo = nil,       -- pad name, when the flight ends in a dock
    handsAt = nil,      -- when the joystick was last touched

    -- Who has the conn. Several people may watch one ship; one flies it.
    commander     = nil,
    commanderName = nil,
    commandedAt   = nil,
  }
end

function flight.airborne(st) return AIRBORNE[st.state] == true end

--- Is it safe to swap the program's own files underneath it?
--
-- The same rule as a miner refusing an update mid-job and a redstone node
-- refusing one mid-pulse, only less forgiving: replacing lib/hull.lua while a
-- control loop is holding a ship up is the worst of the three.
function flight.busy(st)
  return flight.airborne(st)
end

--------------------------------------------------------------------------------
-- Transitions
--------------------------------------------------------------------------------

--- Change state, recording when and why. Returns an event for the log, or nil
--- when nothing changed -- so the caller can log unconditionally.
local function goTo(st, state, why, now)
  if st.state == state then return nil end

  local event = { what = "state", from = st.state, to = state, why = why }
  st.state, st.since, st.why = state, now, why

  -- Forgotten on every transition, and re-latched by whichever state wants it.
  -- See `holding` below.
  st.hold = nil
  return event
end

--- The heading to hold while going nowhere.
--
-- Latched once on entering the state, not read from the fix every sweep. A
-- target of "wherever you are pointing right now" is not a target at all: the
-- error is zero by construction, the loop never corrects anything, and a ship
-- told to hold position slowly rotates for as long as you leave it. It also
-- looks completely correct in the source, which is how it survived a first pass
-- through four states here.
local function holding(st, fix)
  if st.hold == nil then st.hold = fix.heading end
  return st.hold
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

--- Who has the conn, and may anyone else have it?
--
-- Several people can watch one ship -- telemetry is broadcast and costs nothing
-- -- but only one may fly it. Two pocket computers sending "land" and "fly to
-- the quarry" a second apart is the joystick problem again with more hands: the
-- ship obeys whichever arrived last and nobody watching can tell why.
--
-- So control is held, and the holder is named in every telemetry frame. Anyone
-- else is refused with a reason that says who to ask. Taking over is deliberate
-- and always allowed -- this is a game, and a ship nobody can command because
-- its commander logged off would be worse than the collision this prevents --
-- but it is an explicit act and it is written in the log.
--
-- Control also lapses on its own after config.conn of silence, so the common
-- case of somebody wandering off needs no ceremony at all.
function flight.mayCommand(st, from, now)
  if st.commander == nil then return true end
  if st.commander == from then return true end

  if (now - (st.commandedAt or -math.huge)) >= config.conn then
    return true, nil, "lapsed"
  end

  return false, (st.commanderName or ("computer " .. tostring(st.commander)))
    .. " has control"
end

--- Give control to `from`, returning an event when it actually changed hands.
local function claim(st, ctx, now)
  local from = ctx.from
  if from == nil then return nil end

  local previous, previousName = st.commander, st.commanderName
  st.commander, st.commanderAt = from, now
  st.commanderName = ctx.who or ("computer " .. tostring(from))
  st.commandedAt = now

  if previous == from then return nil end

  return { what = "control", from = previousName or "nobody",
           to = st.commanderName, why = "took control" }
end

-- Orders that change what the ship is doing, and so need the conn. Everything
-- absent from this -- asking for the hull, asking who has control -- is a
-- question, and questions are free.
local COMMANDS = {
  fly = true, route = true, hold = true, land = true, dock = true,
  rtb = true, stop = true, park = true, alt = true, tune = true,
}

--- Take an order. Returns ok, reason-or-event.
--
-- Orders are refused rather than queued. A ship that accepted "fly to the
-- quarry" while descending onto a pad and did it eventually would be doing
-- something nobody watching could predict.
--
-- `ctx.from` is who sent it and `ctx.who` is what they are called. When the
-- tower relays an order it stamps the *original* sender, so the conn belongs to
-- the person at the pocket computer rather than to the tower that passed it on.
function flight.command(st, cmd, ctx, now)
  ctx = ctx or {}
  local limits = ctx.limits or {}

  if type(cmd) ~= "table" or type(cmd.type) ~= "string" then
    return false, "not a command"
  end

  ------------------------------------------------------------------------------
  -- Control
  ------------------------------------------------------------------------------

  if cmd.type == "take" then
    return true, claim(st, ctx, now)
  end

  if cmd.type == "release" then
    if st.commander ~= ctx.from then return false, "you do not have control" end
    local name = st.commanderName
    st.commander, st.commanderName, st.commandedAt = nil, nil, nil
    return true, { what = "control", from = name, to = "nobody",
                   why = "released" }
  end

  if COMMANDS[cmd.type] and ctx.from ~= nil then
    local may, held = flight.mayCommand(st, ctx.from, now)
    if not may then return false, held end
  end

  ------------------------------------------------------------------------------
  if cmd.type == "alt" then
    -- Raising and lowering a ship without giving it anywhere to go. Absolute
    -- with `alt`, relative with `by`, and it works from the pad as well as in
    -- the air -- "take off and hover at 140" is the commonest thing anybody
    -- wants and there was no way to say it.
    local want
    if tonumber(cmd.alt) then
      want = tonumber(cmd.alt)
    elseif tonumber(cmd.by) then
      -- Relative to where the ship is *going*, not where it is, so two taps of
      -- up in quick succession move it twenty blocks rather than racing the
      -- climb and moving it ten.
      local base = st.alt or (ctx.fix and ctx.fix.alt)
      if not base then return false, "no altitude to move from" end
      want = base + tonumber(cmd.by)
    else
      return false, "no altitude"
    end

    local ceiling = tonumber(limits.ceiling) or config.maxAlt
    local floor   = tonumber(limits.floor) or config.minAlt
    if want > ceiling then want = ceiling end
    if want < floor then want = floor end

    local was = st.alt
    st.alt = want
    claim(st, ctx, now)

    -- Parked ships take off for this. Anything already flying simply changes
    -- what it is holding, and a ship on a leg keeps the leg -- it is a change of
    -- cruise altitude, not a change of mind.
    if not flight.airborne(st) then
      local event = goTo(st, "preflight", "alt", now)
      return true, event or { what = "alt", from = was, to = want, why = "alt" }
    end

    return true, { what = "alt", from = was, to = want, why = "alt" }
  end

  ------------------------------------------------------------------------------
  if cmd.type == "fly" or cmd.type == "route" then
    local names = cmd.names
    if not names and cmd.to then names = { cmd.to } end
    if type(names) ~= "table" or #names == 0 then return false, "nowhere to fly" end

    local plan, why = nav.plan(ctx.waypoints or {}, names, cmd.alt or ctx.cruiseAlt)
    if not plan then return false, why end

    st.plan = plan
    st.alt  = tonumber(cmd.alt) or tonumber(ctx.cruiseAlt) or nil
    st.dockTo = nil

    -- Cruise altitude has to be a number by here. A plan whose altitude is nil
    -- means an altitude loop that never runs, which means a ship that takes off
    -- and keeps going up, and it is much better to refuse now.
    if not st.alt then
      local fix = ctx.fix
      st.alt = (fix and fix.alt and (fix.alt + 20)) or nil
    end
    if not st.alt then
      st.plan = nil
      return false, "no cruise altitude and nothing to guess one from"
    end

    st.bingo = false
    claim(st, ctx, now)
    local event = goTo(st, flight.airborne(st) and "cruise" or "preflight",
                       "fly", now)
    return true, event
  end

  ------------------------------------------------------------------------------
  if cmd.type == "hold" then
    if not flight.airborne(st) then return false, "not flying" end
    claim(st, ctx, now)
    return true, goTo(st, "loiter", "manual", now)
  end

  ------------------------------------------------------------------------------
  if cmd.type == "land" or cmd.type == "dock" then
    local pad = cmd.pad and (ctx.waypoints or {})[cmd.pad]

    if cmd.type == "dock" and not pad then
      return false, "no pad named " .. tostring(cmd.pad)
    end

    claim(st, ctx, now)

    if pad then
      -- Landing somewhere else is a flight, so it becomes one. The difference
      -- between this and `fly` is only what happens at the far end.
      local plan = nav.plan(ctx.waypoints or {}, { pad.name },
                            st.alt or ctx.cruiseAlt)
      if not plan then return false, "cannot plan to " .. pad.name end
      st.plan = plan
      st.dockTo = (cmd.type == "dock") and pad.name or nil
      return true, goTo(st, flight.airborne(st) and "cruise" or "preflight",
                        cmd.type, now)
    end

    -- No pad named: come down here.
    if not flight.airborne(st) then return false, "already down" end
    st.plan = nil
    st.dockTo = nil
    return true, goTo(st, "approach", "manual", now)
  end

  ------------------------------------------------------------------------------
  if cmd.type == "rtb" then
    local home = ctx.home or st.home
    if not home or not (ctx.waypoints or {})[home] then
      return false, "no home set"
    end
    return flight.command(st, { type = "land", pad = home }, ctx, now)
  end

  ------------------------------------------------------------------------------
  if cmd.type == "stop" then
    -- Deliberately not "cut the engines". `stop` from a pocket computer means
    -- "put it down now", and a controlled descent is what that has to mean when
    -- the alternative is a falling building.
    st.plan = nil
    claim(st, ctx, now)
    return true, goTo(st, "emergency", "manual", now)
  end

  ------------------------------------------------------------------------------
  if cmd.type == "park" then
    if flight.airborne(st) then return false, "still flying" end
    return true, goTo(st, "idle", "manual", now)
  end

  return false, "unknown command " .. cmd.type
end

--------------------------------------------------------------------------------
-- Guards
--------------------------------------------------------------------------------

--- Returns goal, event when a guard fires; nil when none does.
local function guards(st, fix, ctx, now)
  local limits = ctx.limits or {}
  local floor  = tonumber(limits.clearance) or config.clearance

  -- 1. The pilot's hands -------------------------------------------------------

  -- `active` rather than the raw tilt: the mod applies its own deadzone and
  -- reports the result, so this is "somebody is flying" and not "somebody
  -- brushed past it".
  local hands = fix.stick ~= nil and (fix.stick.active == true or fix.stick.held == true)

  if hands then
    st.handsAt = now
    if st.state ~= "manual" then
      -- The plan goes with it. A pilot who takes the stick has taken over, and a
      -- ship that quietly resumed a flight to somewhere else the moment they let
      -- go would be the single most alarming thing this program could do.
      st.plan = nil
      st.guard = "manual"
      return { release = true }, goTo(st, "manual", "manual", now)
    end
    st.guard = "manual"
    return { release = true }
  end

  if st.state == "manual" then
    -- Let go. Wait a little before taking it back, so a pause between inputs is
    -- not a handover, then catch the ship in a hold rather than resuming
    -- anything.
    if (now - (st.handsAt or now)) < config.handback then
      st.guard = "manual"
      return { release = true }
    end
    st.guard = nil
    return nil, goTo(st, "loiter", "handback", now)
  end

  -- 2. Attitude ----------------------------------------------------------------

  local tilt  = tonumber(fix.tilt)
  local spin  = tonumber(fix.spin)
  local lean  = tonumber(limits.tilt) or config.tiltLimit
  local abort = tonumber(limits.tiltAbort) or config.tiltAbort

  -- Nil is not level. A hull with no attitude source at all gets no attitude
  -- guard, which is a gap to be aware of rather than a reason to invent a
  -- reading -- and the same rule as every other instrument here.
  if tilt then
    if tilt >= abort then
      st.guard = "attitude"
      local event = nil
      if st.state ~= "idle" then
        event = { what = "guard", from = st.state, to = "released",
                  why = "inverted" }
      end
      goTo(st, "idle", "inverted", now)
      st.plan = nil
      return { release = true }, event
    end

    if tilt >= lean and not NEAR_GROUND[st.state] then
      local event = nil
      if st.guard ~= "attitude" then
        event = { what = "guard", from = st.state, to = "levelling",
                  why = "tilt" }
      end
      st.guard = "attitude"

      -- Hold height, stop going anywhere, and ask any trim control to level.
      -- The plan survives: a ship that leaned over in a gust and came back
      -- should carry on, not abandon the flight.
      return {
        alt     = st.alt or fix.alt,
        speed   = 0,
        heading = holding(st, fix),
        level   = true,
        limits  = limits,
      }, event
    end
  end

  -- A ship spinning fast is out of control whatever its current angle: it is
  -- simply between two attitudes. Only measurable with CC: Sable.
  if spin and spin >= (tonumber(limits.spin) or config.spinLimit) then
    st.guard = "attitude"
    local event = nil
    if st.state ~= "idle" then
      event = { what = "guard", from = st.state, to = "released", why = "tumbling" }
    end
    goTo(st, "idle", "tumbling", now)
    st.plan = nil
    return { release = true }, event
  end

  -- 3. No vertical reference ---------------------------------------------------

  if not fix.levelled then
    local event = goTo(st, "idle", "noalt", now)
    st.guard = "noalt"
    return { release = true }, event
  end

  -- 4. Ground clearance --------------------------------------------------------

  -- Note the explicit nil test. A clearance of nil is "nothing answered" and a
  -- clearance of 0 is "on the ground", and `fix.clearance or floor` would turn
  -- the first into the second on every hull without an optical sensor.
  if fix.clearance ~= nil and fix.clearance < floor and not NEAR_GROUND[st.state] then
    local event = nil
    if st.guard ~= "clearance" then
      event = { what = "guard", from = st.state, to = "climbing", why = "clearance" }
    end
    st.guard = "clearance"

    -- The plan is untouched. This is an override for as long as the ground is
    -- too close, not a change of mission -- the ship climbs, clears the hill,
    -- and carries on to the same waypoint it was already going to.
    return {
      vs      = tonumber(limits.climb) or 4,
      heading = st.goal and st.goal.heading,
      speed   = 0,
      limits  = limits,
    }, event
  end

  -- 5. An obstacle ahead -------------------------------------------------------

  -- The clearance guard above is a floor and nothing more. A ship at cruise
  -- altitude flying at the side of a mountain has perfect clearance underneath
  -- it the whole way in, and would have right up until it stopped.
  --
  -- Nil again means no reading, and here that is the common case twice over: no
  -- forward sensor on the hull, or a sensor seeing nothing but sky. Neither is
  -- an obstacle at zero blocks.
  if fix.ahead ~= nil and not NEAR_GROUND[st.state] then
    -- How far the ship travels before it can have stopped, near enough. Speed is
    -- what makes an obstacle dangerous: the same rock is nothing at two blocks a
    -- second and a problem at twelve.
    local stopping = math.max((fix.speed or 0) * config.reaction, config.standoff)

    if fix.ahead < stopping then
      local event = nil
      if st.guard ~= "obstacle" then
        event = { what = "guard", from = st.state, to = "climbing",
                  why = "obstacle" }
      end
      st.guard = "obstacle"

      -- Adopt the height we are having to climb to, for the rest of the flight.
      --
      -- Without this the guard is a bounce loop and worse than useless. It
      -- climbs; the forward sensor stops seeing the ridge the moment the ship
      -- is above it; the guard releases; the altitude hold -- still set to the
      -- plan's cruise altitude, which is *below* the ridge -- immediately flies
      -- the ship back down into it. The downward guard never shows this because
      -- its sensor keeps firing all the way across the top.
      --
      -- Monotonic within a flight, and reset by the next order. The plan's
      -- altitude was simply too low for this route; the ship has just found that
      -- out, and going back down to it having found out would be perverse.
      if fix.alt and (st.alt == nil or fix.alt > st.alt) then
        st.alt = fix.alt
      end

      -- Stop and climb, exactly as for terrain, and for the same reason: up is
      -- the one direction that is reliably clear on a hull that can only see
      -- forwards and down. The plan is untouched -- over the top and carry on.
      --
      -- **Know what this does not do.** A ship has no brakes. Zeroing the
      -- forward demand removes the push; drag removes the speed, exponentially,
      -- and a hull at cruise coasts a long way while it climbs. Against a ridge
      -- it can get over, the climb wins and it clears. Against something
      -- unclimbable -- a sheer cliff, a wall -- it will still drift into the
      -- face, slowly, and this guard only buys height and time.
      --
      -- Turning away would be the real answer and is not attempted here: it
      -- needs lateral momentum to reason about, the hull has no reverse thrust
      -- to arrest it with, and a manoeuvre this file cannot test against the
      -- flight model is a manoeuvre it has no business commanding.
      return {
        vs      = tonumber(limits.climb) or 4,
        heading = st.goal and st.goal.heading,
        speed   = 0,
        limits  = limits,
      }, event
    end
  end

  -- 6. No usable fix -----------------------------------------------------------

  if NAVIGATING[st.state] and not fix.usable then
    st.guard = "nofix"
    return nil, goTo(st, "loiter", "nofix", now)
  end

  -- 7. Bingo fuel --------------------------------------------------------------

  if not st.bingo and flight.airborne(st) and fix.burn and ctx.home then
    local home = (ctx.waypoints or {})[ctx.home]
    local at   = fix.usable and fix or nil

    if home and at then
      local distance = nav.distance(at, home)
      local eta = nav.eta(distance, tonumber(limits.cruise) or 10)

      -- eta is nil when the cruise speed is zero, which is a hull that cannot
      -- go anywhere; there is no diversion to make and comparing nil to a burn
      -- time would turn every hover into a mayday.
      if eta and fix.burn < eta * config.fuelReserve then
        st.bingo = true
        st.guard = "bingo"

        local plan = nav.plan(ctx.waypoints, { home.name }, st.alt)
        if plan then
          st.plan = plan
          st.dockTo = (home.kind == "pad") and home.name or nil

          -- The event is built here rather than taken from goTo, because a ship
          -- already cruising stays cruising: the state does not change, only the
          -- destination does, and goTo returns nothing when nothing changed.
          -- Leaving it at that made the single most important entry the log will
          -- ever hold -- why did it turn round -- the one entry it never wrote.
          goTo(st, "cruise", "bingo", now)
          return nil, { what = "plan", from = "flight", to = home.name,
                        why = "bingo" }
        end

        -- Nowhere to go and not enough fuel to keep flying. Down now, under
        -- power, while there still is some -- rather than in ninety seconds
        -- without.
        return nil, goTo(st, "emergency", "bingo", now)
      end
    end
  end

  st.guard = nil
  return nil
end

--------------------------------------------------------------------------------
-- The machine
--------------------------------------------------------------------------------

--- One step. Returns st, goal, events.
--
-- `ctx` carries what this file cannot know: the waypoint table, the hull's
-- limits, the name of home, and the fix. Passed in rather than stored so the
-- same state table can be stepped against a different world in a test.
function flight.step(st, fix, ctx, now)
  ctx = ctx or {}
  ctx.fix = fix
  local limits = ctx.limits or {}
  local events = {}

  local cruise   = tonumber(limits.cruise)   or 10
  local descend  = tonumber(limits.descend)  or 3
  local climb    = tonumber(limits.climb)    or 4
  local floor    = tonumber(limits.clearance) or config.clearance

  local function emit(event)
    if event then events[#events + 1] = event end
  end

  -- Guards first, always ------------------------------------------------------

  local override, guardEvent = guards(st, fix, ctx, now)
  emit(guardEvent)
  if override then
    st.goal = override
    return st, override, events
  end

  -- States --------------------------------------------------------------------

  local goal = { limits = limits }
  local leg  = nav.current(st.plan)

  if st.state == "idle" then
    goal = { release = true }

  elseif st.state == "preflight" then
    -- The only place a flight is refused. Everything checked here is something
    -- that would otherwise be discovered in the air.
    local problem = nil

    if not st.plan and not st.alt then
      problem = "nowhere to go and no altitude"
    elseif not st.alt then
      problem = "no cruise altitude"
    elseif not fix.usable then
      problem = "no fix"
    elseif st.plan and fix.burn and ctx.home and (ctx.waypoints or {})[ctx.home] then
      -- Only a plan can be too long for the fuel. "Go up twenty blocks" cannot.
      local eta = nav.eta(nav.remaining(st.plan, fix), cruise)
      if eta and fix.burn < eta * config.fuelReserve then
        problem = "not enough fuel for the plan"
      end
    end

    if problem then
      st.plan = nil
      st.alt = nil
      emit(goTo(st, "idle", problem, now))
      goal = { release = true }
    else
      -- Check the route against what the fleet has learned about the ground.
      --
      -- This is the one thing the guards cannot do. The clearance and obstacle
      -- guards are reflexes: they fire when the ground is already close, and
      -- they cost a climb from cruise every time. Knowing before setting off
      -- that a route needs a hundred and forty is worth more than surviving a
      -- hundred, and it is free -- ships surveyed it on the way past.
      --
      -- It only ever raises. A survey that lowered a cruise altitude would be
      -- trusting a map to say a hill is *absent*, which is not something a map
      -- built from where ships happened to fly can ever honestly say.
      if st.plan and ctx.terrain then
        local highest, coverage, gap = terrain.forPlan(ctx.terrain, st.plan, fix)
        local need = terrain.safe(highest, limits.clearance)

        if need and terrain.surveyed(coverage, gap) and st.alt < need then
          emit({ what = "alt", from = st.alt, to = need, why = "terrain" })
          st.alt = need
        end
      end

      emit(goTo(st, "takeoff", "cleared", now))
      goal = { vs = climb, speed = 0, limits = limits }
    end

  elseif st.state == "takeoff" then
    -- Straight up, no steering. A ship still inside its own launch scaffolding
    -- that started turning towards the first waypoint would take the scaffolding
    -- with it.
    goal = { vs = climb, speed = 0, limits = limits }

    local high = (fix.clearance ~= nil and fix.clearance >= floor * 1.5)
      or (st.alt and fix.alt and fix.alt >= st.alt - config.altTolerance)

    if high then emit(goTo(st, "climb", "airborne", now)) end

  elseif st.state == "climb" then
    goal = {
      alt     = st.alt,
      heading = leg and nav.bearing(fix, leg) or holding(st, fix),
      speed   = leg and (cruise * 0.5) or 0,
      limits  = limits,
    }

    if fix.alt and st.alt and math.abs(st.alt - fix.alt) <= config.altTolerance then
      emit(goTo(st, leg and "cruise" or "loiter", "at altitude", now))
    end

  elseif st.state == "cruise" then
    if not leg then
      emit(goTo(st, "loiter", "plan finished", now))
      goal = { alt = st.alt, heading = holding(st, fix), speed = 0, limits = limits }
    else
      -- The leg's origin is stamped the first time we fly it, not when the plan
      -- was made: a plan built on the ground and started ten minutes later would
      -- otherwise measure cross-track from the pad.
      if not st.plan.from then st.plan.from = { x = fix.x, y = fix.y, z = fix.z } end

      goal = {
        alt     = st.alt,
        heading = nav.steer(fix, st.plan.from, leg),
        speed   = cruise,
        limits  = limits,
      }

      if nav.arrived(fix, leg) then
        local next_ = nav.advance(st.plan, fix)
        emit({ what = "leg", from = leg.name, to = next_ and next_.name or "end",
               why = "arrived" })

        if not next_ then
          -- The end of the plan. A pad is somewhere to come down; a point is
          -- somewhere to be, so the ship holds there rather than landing in a
          -- field because the list ran out.
          if leg.kind == "pad" or st.dockTo then
            emit(goTo(st, "descend", "arrived", now))
          else
            emit(goTo(st, "loiter", "arrived", now))
          end
        end
      end
    end

  elseif st.state == "descend" then
    -- Down to approach height over the destination, still holding position over
    -- it. Separate from `approach` so the long descent happens at cruise
    -- descent rate and the last part happens slowly.
    local pad = leg or st.plan and st.plan.legs[#st.plan.legs]
    local target = (pad and pad.y or fix.alt or 0) + floor * 2

    goal = {
      alt     = target,
      heading = pad and nav.bearing(fix, pad) or holding(st, fix),
      speed   = pad and nav.distance(fix, pad) or 0,
      limits  = limits,
    }
    if goal.speed and goal.speed > cruise * 0.4 then goal.speed = cruise * 0.4 end

    if fix.alt and math.abs(fix.alt - target) <= config.altTolerance then
      emit(goTo(st, "approach", "at approach height", now))
    end

  elseif st.state == "approach" then
    -- Over the spot, coming down. Speed zero: the ship should be stopped before
    -- it is low, not still moving when it touches.
    goal = { vs = -descend * 0.6, speed = 0, heading = holding(st, fix), limits = limits }

    local low = (fix.clearance ~= nil and fix.clearance <= floor)
    if low then
      emit(goTo(st, st.dockTo and "dock" or "land", "over the pad", now))
    end

  elseif st.state == "land" then
    goal = { vs = -descend * 0.3, speed = 0, heading = holding(st, fix), limits = limits }

    -- Down when the ground is within a block and we have stopped moving. Both,
    -- because a ship still descending at two blocks a second one block up has
    -- not landed, it is about to.
    local down = (fix.clearance ~= nil and fix.clearance <= 1.0)
      and math.abs(fix.vs or 0) < 0.5

    if down then
      emit(goTo(st, "idle", "down", now))
      st.plan = nil
      goal = { release = true }
    end

  elseif st.state == "dock" then
    goal = { vs = -descend * 0.3, speed = 0, heading = holding(st, fix), limits = limits }

    if fix.docked then
      emit(goTo(st, "idle", "docked", now))
      st.plan = nil
      goal = { release = true }
    end

  elseif st.state == "loiter" then
    -- Holding. If the fix comes back and there is still a plan to fly, carry on
    -- -- the whole reason loiter is a state rather than an abort is that the
    -- navigation table going quiet for four seconds is normal.
    goal = { alt = st.alt or fix.alt, heading = holding(st, fix), speed = 0, limits = limits }

    if st.plan and nav.current(st.plan) and fix.usable then
      emit(goTo(st, "cruise", "fix recovered", now))
    end

  elseif st.state == "emergency" then
    goal = { vs = -descend, speed = 0, heading = holding(st, fix), limits = limits }

    local down = (fix.clearance ~= nil and fix.clearance <= 1.0)
      and math.abs(fix.vs or 0) < 0.5
    if down then
      emit(goTo(st, "idle", "down", now))
      goal = { release = true }
    end

  else
    -- An unknown state is a bug, and the safe response to a bug in the thing
    -- flying the ship is to stop flying it rather than to guess.
    emit(goTo(st, "emergency", "unknown state", now))
    goal = { vs = -descend, speed = 0, limits = limits }
  end

  st.goal = goal
  return st, goal, events
end

--------------------------------------------------------------------------------

--- A one-line summary, for the dashboard and the telemetry frame.
function flight.describe(st, fix)
  local leg = nav.current(st.plan)
  return {
    state = st.state,
    why   = st.why,
    guard = st.guard,
    leg   = leg and leg.name or nil,
    legs  = st.plan and #st.plan.legs or 0,
    at    = st.plan and st.plan.leg or 0,
    alt   = st.alt,
    bingo = st.bingo,
    tilt  = fix and fix.tilt or nil,
    commander     = st.commander,
    commanderName = st.commanderName,
    left  = st.plan and fix and nav.remaining(st.plan, fix) or nil,
  }
end

return flight
