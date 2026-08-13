# Project: CC: Tweaked Aeronautics Flight Network

## What this is

Three Lua programs for the CC: Tweaked Minecraft mod, flying Create Aeronautics
contraptions:

- `pilot.lua` — runs on a computer **riding the contraption**. Owns the control
  loop and the whole flight plan. Fully autonomous.
- `server.lua` — runs on an **advanced computer** at base. Fleet roster, named
  waypoints and pads, routes, the log; draws a dashboard on its terminal and any
  attached monitor. Wants an ender modem for range.
- `remote.lua` — runs on an **advanced pocket computer**. Four screens: fleet,
  fly, nav, log.

Plus `probe.lua`, a hardware survey that writes a starter `/craft.cfg` from what
is actually attached to the hull, and `beacon.lua` -- a computer placed in the
world that registers itself as a waypoint and measures what is standing above it.

All communicate over a raw modem channel via `lib/net.lua` — not rednet. The
channel is configurable per network, which is what lets several independent
setups share a world. This is the same net layer as `mining/` and `redstone/`,
deliberately copied rather than shared: each directory installs and updates on
its own, and a shared root library would mean updating the redstone network
rebooting every ship in the air.

Default channel **1618**, protocol name **`aero`** — distinct from the mining
fleet's 3141 and the redstone network's 2718, so one world runs all three
without any of them being told about the others.

## The one thing that makes this different from the other two

A redstone node that loses its link leaves a lamp in the wrong state. A ship that
loses its link is a falling building.

Everything below follows from that. Routing is pocket → server → pilot with a
direct fallback, as in `redstone/` — but unlike there, **the server never flies
anything**. It sets goals. Every ship carries its own plan, its own waypoint
cache and its own guards, and the tower can be switched off, unloaded or broken
without a single ship coming down.

## Environment constraints

- Runtime is **Cobalt** (~Lua 5.2 with some 5.3 features). No LuaJIT, no FFI, no
  `io.popen`, no OS access outside the sandboxed CC filesystem. `math.atan2`
  exists; `lib/nav.lua` binds it with a fallback anyway so the module runs under
  a stock Lua too.
- Available APIs: `peripheral`, `parallel`, `os.pullEvent`, `fs`, `gps`,
  `textutils`, `term`, `settings`, `keys`, `colours`.
- Advanced hardware means colour and `mouse_click`/`monitor_touch` are
  available. Take advantage in `remote.lua` and the server dashboard.
- Wireless modem range is limited and chunks unload. Assume the link **will**
  drop and design for it.

### What the mod actually gives us

Read from the mod's own reference at `/rom/thrusters/docs.lua` and its
`examples/`, and from Simulated-Project's `compat/computercraft/peripherals/`.
Every method named here is real.

**Instruments** — all read-only:

| Peripheral | Gives us |
| --- | --- |
| `navigation_table` | `getBlockPos()` / `getTablePosition()` — projected world position; `getCurrentAngle()` heading in degrees |
| `altitude_sensor` | `getWorldHeight()` (compat layer) or `getHeight()` (base mod); `getAirPressure()` |
| `velocity_sensor` | `getVelocity()` — a **scalar**, with no direction |
| `gimbal_sensor` | `getAngles()` → a Java List, so `{ [1] = x, [2] = z }` in Lua |
| `optical_sensor` | `hasHit()`, `getDistance()`, `getBlock()`, `setRange(n)` |
| `docking_connector` | `getConnectedName()` |
| `analogue_joystick` | `getTilt()` → `{x, z, magnitude, held, active}` |
| `directional_link` | `getClosestAngle()` — bearing to the nearest matching link |
| `modulating_link` | `getClosestDistance()` — and its range |
| `name_plate` | `getName()` / `setName(s)` |
| `swivel_bearing` | `getTargetAngle()` |

Every type string above is the one the peripheral class's own `getType()`
returns, checked against the source rather than inferred from the block's name —
they are not always the same word, and a role that auto-finds nothing is a silent
instrument rather than an error.

Two are deliberately unused, listed here so that is a decision rather than an
oversight: `torsion_spring` (`getAngle`, `setLimit`, `isRunning`) is an actuator
whose effect on a hull in flight this program cannot guess at, and
`linked_typewriter` (`getPressedKeyCodes`, and it attaches to the computer) is a
cockpit keyboard — a manual flying mode, which is a different program.

The two linked receivers give a homing fix between them -- role `homing`, not
`beacon`, because `beacon.lua` is an entirely different thing -- and are
**reported but never navigated on**: `getAngleToClosestLink` is an angle, and nothing
available outside the game says whether it is measured from world north or from
the receiver's own facing. Those differ by the ship's heading, which is precisely
the error that would send a ship past its pad. It goes in the telemetry frame so
the convention can be established by watching it, and steers nothing until it has
been.

**Actuators** — all from Gadgets & Gizmos:

| Peripheral | Drives |
| --- | --- |
| `thruster_bearing` | `setBearingControlMode("computer")`, `setThrottle(idOrAll, 0..1)`, `setPivotAngle(deg)`, `getFuel/getBurnTimeSeconds/getTotalRealThrust`, `clearThrottleOverride(idOrAll)` |
| `thruster` | one at a time: `setThrottle`, `setEnabled`, `setControlMode`, `clearThrottleOverride` |
| `virtual_orientation_source` | `setAnglesDegrees(x, z)`, `clear()` |
| `bidirectional_gearbox` | `setFaceAngle(face, angle)`, `clearFaceAngle(face)` — the `gearbox` kind. `setMode` is deliberately not called: it changes what the block is for, and its builder already decided that |
| `wheel_mount` | `setControls(left, right, brake)`, `clearControls()` |
| `claw` / `rope_winch_cable` | `open()`, `close()`, `release()`, `isHolding()` |
| `analogue_contraption_controller` | `setInput(id, 0..1)`, `listInputIds()` — the escape hatch for anything without a dedicated peripheral |

Four facts drive the whole design:

- **Position comes from the ship, not from GPS.** `navigation_table.getBlockPos`
  is a projected world position on a moving contraption. GPS is the cross-check
  and the fallback — it needs a satellite constellation and loaded chunks, which
  is exactly what vanishes over open terrain.
- **Every actuator write is an override that outlives the program.**
  `setThrottle` switches a thruster into computer control and it stays there.
  This is the aero version of the redstone network's "an output is held by the
  computer", and far less forgiving: a program that exits with the lift bearing
  at 0.8 leaves a ship climbing with nobody flying it.
- **Attitude and speed are partial.** The velocity sensor is a scalar and the
  gimbal gives two angles. Anything needing a velocity *vector* — cross-track,
  vertical speed, dead reckoning — is differentiated from position over time.
- **The base mod's peripherals are read-only.** Without Gadgets & Gizmos this is
  a telemetry dashboard and nothing more.

## Architecture

Pure modules touch **no APIs** and take `now` as a parameter rather than reading
`os.clock()` — the same rule that makes `redstone/lib/rules.lua` and
`mining/lib/fleet.lua` testable without an emulated world. Here it also means the
autopilot can be *flown* against a simulator in the test suite, which is the only
way to find out whether a control law settles.

### Controls, and `/craft.cfg`

A **control** is the unit everything else names, the way a redstone *port* is.
Not a peripheral: `"lift"` may be `thruster_bearing_1` addressed as `"all"`
while `"main"` is `thruster_bearing_0` with a thirty-degree pivot limit.

```lua
{ name = "Kestrel",
  controls = {
    lift = { kind = "bearing", peripheral = "thruster_bearing_1", group = "all" },
    main = { kind = "bearing", peripheral = "thruster_bearing_0", group = "all",
             pivot = { min = -30, max = 30 } },
  },
  instruments = { nav = "navigation_table_0", ground = "optical_sensor_0",
                  stick = false },
  limits = { cruise = 12, climb = 4, descend = 3, clearance = 8 },
  gains  = { hover = 0.5 },
  mix    = { { demand = "lift", control = "lift", as = "throttle" }, ... } }
```

- `kind` is `bearing` | `thruster` | `orientation` | `wheels` | `input` | `grip` |
  `gearbox` | `wire`, and decides which methods are called. `control.face` means
  one of the computer's six sides for a `wire` and a compass point for a
  `gearbox`; each is validated against its own set, and neither silently accepts
  the other's -- a face that does not exist is a call that does nothing at all.
- An instrument may be named, left out to be found automatically, or set to
  `false` — which means "this hull has none, stop looking and stop warning".
  A balloon with no optical sensor is a design, not a fault, and a warning that
  is always on screen is one nobody reads.
- Lives in `/craft.cfg`, and is **not** in `manifest.txt`, for the same reason
  `/ports.cfg` is not: `update` replaces every file it lists, and a hull
  definition that survived exactly until the first update would be worse than
  none.

`lib/hull.lua` is the only module that touches `peripheral`. It reads the global
at call time rather than at load, so tests substitute a mock. Three rules run
through it, all the same rule:

- **Never throw.** Every call goes through a `pcall` wrapper that records a
  fault. A control loop that stops is a building that falls.
- **The safe state is the hull's own.** `release` hands control back to redstone
  rather than writing zeros. A ship with no computer does whatever its levers
  say; that is the state its builder tested, and it is not the same as every
  engine off.
- **Nothing is written twice.** A ship holding cruise asks for the same throttle
  five times a second, and `apply` drops anything that changes nothing.

### Redstone

The `wire` kind, and the reason the control list is not just the Gadgets &
Gizmos peripherals. A great deal of Create Aeronautics is driven by a **signal**
rather than a method call — burners, steam vents, throttle levers, gearshifts,
anything on a redstone link, and every thruster left in its default `redstone`
control mode. Without it, "put the burner on when we want to climb" cannot be
said at all.

```lua
burner = { kind = "wire", side = "top" },
vent   = { kind = "wire", peripheral = "redstone_relay_0", side = "front",
           mode = "analog" },
```

`wire` is the only kind that may have **no peripheral**: with none it drives the
flight computer's own six sides through the `redstone` global, and with one it
drives a [`redstone_relay`](https://tweaked.cc/peripheral/redstone_relay.html),
whose API is identical. One code path covers both — `wireCall` takes a relay name
or nil — so moving a burner onto a relay is one line in `/craft.cfg` rather than
a different kind. Deliberately **not** auto-found: picking up a relay somebody
put on the network for something else and quietly driving a burner through it
would be a very confusing afternoon.

`mode` is `digital` | `analog` | `bundled`, exactly as in `redstone/lib/ports.lua`
and for the same reason: the three shapes share the six sides and each needs a
different pair of API calls. A bundled face is recomputed in full on every write,
because it is one number shared by up to sixteen controls. Sides that disagree
about mode, and repeated colours, are refused at load — a signal sent to a side
that does not exist is silently nothing at all, so the burner simply never lights
and there is no error anywhere to explain it.

`craft.signals` is the input direction: named redstone reads that drive nothing
but ride in the telemetry frame, so a comparator on the hold is visible from the
ground rather than something you find out about when the ship will not climb.
One API call per side however many share it.

**A wire is the one control `release` turns off rather than hands back**, and the
exception proves the rule. Everything else is an override on top of a control the
ship already had; a redstone output has no owner underneath us, so there is
nothing to hand it to and off is the safe value for a vent stuck open.

Unless it is the lift. A [hot air burner](https://createaeronautics.miraheze.org/wiki/Hot_Air_Burner)
and a [steam vent](https://createaeronautics.miraheze.org/wiki/Steam_Vent) are
**analogue** — signal strength sets the target volume of hot air, linearly — so
the signal *is* the buoyancy, and turning it off on the way out is a descent
nobody asked for. `hold = true` marks such a wire: `release` leaves it driving
and `hull.current` keeps its value, because clearing it would leave the burner
lit in the world and recorded as off in the state file.

Which leads to the other half. **CC does not persist a computer's redstone
outputs** — they come back off after a chunk unload, exactly as in the redstone
network, which is why that program restores them from disk too. `hull.saved` and
`hull.restore` do the same here, and `pilot.lua` calls `restore` at boot
immediately *after* `release`. That looks contradictory and is not: a peripheral
override survives a reboot and must be dropped, a redstone output does not
survive one and must be put back.

A burner is also a far slower plant than a thruster — the envelope fills at a
finite rate, so lift lags the command by seconds — and there are only sixteen
levels to express it in. `apply` rounds a `signal` demand to one of them
**before** the change test, or a settled hover asking for 0.500 then 0.503
rewrites the wire every sweep. The thruster gain defaults will make a balloon
oscillate; `fly_spec.lua` flies one with a softer set and asserts it neither
drifts nor hunts between two redstone levels.

### Tilt over redstone

The gimbal sensor "outputs redstone signals based on which side is leaning
downwards" with a per-axis sensitivity, so attitude off a bare block is four
analogue reads to combine rather than a method call. `craft.tilt` names the four
faces and the degrees a full signal means; opposite faces are **subtracted**, so
a sensor leaking on both at once reads level rather than as a ship pitched hard
in whichever direction was checked first. Only consulted when the
`gimbal_sensor` peripheral did not answer — it reports real angles where this
reports sixteen steps.

`apply` also **slew-limits** throttle by `config.slew` per second, treating "not
yet written" as zero. A step from nothing to everything on a lift bearing is a
ship launched rather than raised, and the very first demand after claiming the
hull is the one most likely to be full lift.

### The fix

`lib/instruments.lua` fuses one answer to "where is this ship and what is it
doing", preferring `nav` → `gps` → **dead reckoning**, and it ages position and
altitude **separately**.

That separation is not fussiness. The altitude used to be `raw.alt or fix.y`,
and `fix.y` falls back to the previous fix when reckoning — so a ship that lost
its altimeter *and* its navigation table reported the last height it ever knew,
forever, and the guard that exists to catch exactly that never fired.

Past `config.reckonLimit` a fix is marked **unusable** and `lib/flight` stops
navigating on it. Dead reckoning integrates a heading that may be wrong and a
scalar speed that says nothing about drift; its error grows without bound and
nothing here can tell you by how much.

### The control laws

`lib/autopilot.lua` produces four abstract demands — `lift`, `forward`, `yaw`,
`pitch` — and knows nothing about thrusters. The **mix** in `/craft.cfg` maps
them onto whatever this hull has, which is why a jet, a balloon and a truck share
one autopilot: they disagree about what a bearing does, not about what "climb"
means.

Altitude is a **cascade**: altitude error drives a desired rate of climb, which
drives the throttle. The climb and descent limits are then a clamp on one number
in one place, and the inner loop is tuned for holding while the outer is tuned
for approaching, neither compromising for the other.

Four things every loop here has to get right, all of which have already been got
wrong once:

- **Clamped integral.** A ship on the pad accumulates altitude error all night
  and then leaves like a rocket. `reset` clears it on every state change.
- **Derivative on measurement, not on error**, so a new target does not kick.
- **Heading error is a signed turn** (`nav.turn`), not subtraction: a ship on 350
  asked for 10 must turn 20 right, not 340 left.
- **Heading has no integral, and almost no derivative.** Yaw drives a *rate* of
  turn, so the plant is nearly a pure integrator. `hdgD` at 0.05 produced a
  derivative term of 1.8 — larger than the whole output range — and the ship
  hunted across forty-six degrees forever, looking exactly like a gain that was
  too high.

### The states and the guards

`lib/flight.lua` is the mission state machine: `idle → preflight → takeoff →
climb → cruise → descend → approach → land | dock`, plus `loiter` and
`emergency`. Pure, so the safety argument is testable.

`idle` **hands the hull back** rather than holding zeros, and so does an
unflyable hull. A parked ship should behave exactly like a ship with no computer
on it — the configuration its builder tested.

Any state that holds a heading **latches it once on entry**. A target of
"wherever you are pointing right now" is not a target: the error is zero by
construction and the ship slowly rotates for as long as you leave it. It also
looks entirely correct in the source.

Seven guards, evaluated before the state logic, in this order:

0. **The pilot's hands.** The joystick is being used, so let go of the hull
   entirely and drop the plan. Two things commanding one ship is worse than
   either alone, and a ship that resumed a flight the moment the stick was
   released would be the most alarming thing here. `active` is used rather than
   raw tilt: the mod applies its own deadzone and reports the result.
0b. **Attitude.** Past `limits.tilt`, stop navigating and ask for level. Past
   `limits.tiltAbort`, hand the hull back — every law here assumes lift pushes
   *away* from the ground, and past ninety degrees it pushes the ship at it, so
   an inverted ship with the altitude hold still running is being flown into the
   ground by the loop meant to prevent that. With CC: Sable the same guard also
   fires on angular velocity, which catches a level ship that is a quarter of a
   second from being upside down.
0c. **An obstacle ahead.** The clearance guard is a floor and nothing more; a
   ship flying at the *side* of a mountain has perfect clearance the whole way
   in. The guard climbs and **adopts the height it climbed to** for the rest of
   the flight — without that it is a bounce loop, because the forward sensor
   stops seeing the ridge the instant the ship clears it and the altitude hold
   then flies it straight back down into it. It does not stop the ship: there
   are no brakes, drag is exponential, and a hull at cruise coasts thirty-odd
   blocks. Against something unclimbable this buys height and time and nothing
   else, and `lib/flight.lua` says so where the guard is written.

1. **No vertical reference.** Without an altitude there is no rate of climb, so
   the lift demand sits at zero and the ship falls under program control. Hand it
   back instead.
2. **Ground clearance.** Below the limit, climb — whatever the plan said. The
   plan is *not* abandoned: the ship climbs, clears the hill and carries on to
   the same waypoint. Exempt during `approach`, `land` and `dock`.
3. **No usable fix.** Loiter. Recoverable, because a navigation table going quiet
   for four seconds is normal.
4. **Bingo fuel.** Turn for home while there is still enough to get there,
   computed from burn time against distance home rather than a percentage.
   **Latched**: fuel that recovers does not un-divert.

Every guard emits an event, because "why did it turn round" is the question the
log exists to answer. The bingo diversion originally emitted nothing — a ship
already cruising stays cruising, and `goTo` returns nothing when nothing changed,
so the single most important entry the log will ever hold was the one it never
wrote.

### CC: Sable

`lib/sable.lua` is the only other module that touches an API, and it has to be:
`sublevel` and `aero` are **globals**, not peripherals, so `lib/hull.lua` cannot
reach them. Where CC: Sable is installed and the contraption is assembled, it
supersedes the sensors — a real velocity vector rather than a smoothed
derivative (which matters: the smoothing costs lag in exactly the term the
altitude loop damps with), a real orientation quaternion, and **angular
velocity**, which nothing else here can measure at all.

Every `sublevel` call throws when the contraption is unassembled, which is its
state on the pad and every time it is taken apart — so that is a normal
configuration to degrade through, not an error. `read()` returns nil rather than
an empty table, so a caller can tell "no data" from "data that happens to be
zero", which on a velocity is the difference between stationary and unknown.

`sable.attitude` is pure and separately tested, because it is the part where a
sign error puts the ship's up somewhere it is not. It deliberately does **not**
produce Euler angles for the guard: `tilt` is the angle between the ship's own up
and the world's, straight out of `up.y` in the rotation matrix. No convention to
argue about, no gimbal lock, one number for "how far from level" whichever way
the ship is facing. `test/mockperipheral.lua` composes the quaternion from the
ship's angles longhand rather than sharing the code, so a disagreement between
the two is a test failure and not a shared mistake.

### The interface

`lib/ui.lua` is a deliberate departure from the other two suites, which
redeclare `colour`, `at` and `fit` in every file and say so — at four lines each
that is cheaper than a dependency. This one has gauges, a compass, an artificial
horizon, a scrolling row list and tabs, and three copies of those would drift
apart within a week. Broken once, with a note in the file.

Three constraints shape it. It must survive **26x20**, so everything takes a
width and cuts to it. It must survive **no colour**, because a ship's flight
computer may be a basic computer — `ui.paint` is a no-op there and nothing is
drawn in a way that only reads as different because it is a different colour. And
it must survive **being redirected**, since the tower draws the same screen to
its terminal and a monitor, so nothing caches the terminal or its size.

Pure layout arithmetic — `fit`, `ratio`, `tapeRows`, `horizonRows`, `tabLayout`,
`tabAt` — is separated from anything that draws, because it is the part with the
off-by-ones and the part a test can check without a screen. `tabLayout` and
`tabAt` share one function so where a tab is drawn and what a click at a column
means cannot disagree.

`ui.stateColour` and `ui.guardColour` live here rather than in each program, so
the tower, the pocket and the ship cannot mean different things by orange.

The row list from `redstone/remote.lua` is lifted into `ui.list`/`ui.row`/
`ui.draw`/`ui.click` and now carries the **column** as well, because two rows
have two gestures on one line — a stepper's minus and plus, and delete at the far
right. Rebuilding the list every draw and letting each row carry its own handler
is what stops a click landing on the button next to the one it looks like; the
remote suite has a case for exactly that, after picking a ship added a row and
shifted every action below it.

### Who has the conn

Several people can watch one ship; one flies it. `flight.mayCommand` refuses an
order from anyone but the holder, which is the joystick guard's problem with more
hands -- two pockets sending contradictory orders a second apart leaves a ship
obeying whichever arrived last and nobody able to say why.

Held rather than locked: `take` is never refused, because a ship nobody can
command because its commander logged off is worse than the muddle this prevents.
It is deliberate, it is logged with both names, and control lapses by itself
after `config.conn` of silence so the common case needs no ceremony.

Two details that are easy to get wrong. The tower **stamps `sender` with the
original sender** when it relays, or every relayed order would look like it came
from the same place and one person taking control would silently hand it to
everybody. It is called `sender` rather than `by` because `by` is the relative
altitude on an `alt` order: when the two shared a name, `alt by = -20` set the
sender to -20 and the ship refused its own commander his own order. Only the
round trip through `pilot_spec` found it. And
an order with **no sender at all** is not blocked -- a direct message from a
script that did not say who it was predates this feature and should not start
failing because of it.

`tune` needs the conn too: two people moving the same gain in opposite directions
is the same problem with a slower fuse.

### Surveying, and lib/terrain.lua

The guards are reflexes: clearance looks down, obstacle looks forward, and both
fire when the ground is already close. Neither can say before departure that a
route needs a hundred and forty rather than a hundred. `lib/terrain.lua` can, for
ground somebody has flown over.

Ships survey by existing. Telemetry already carries position and clearance, so
`altitude - clearance` is a ground sample the tower gets for free on every frame.

The whole module is built on one rule: **unknown stays unknown**. A cell nobody
has crossed has no height, not a height of zero, and `along` returns coverage and
the longest gap beside the answer. A map that replied "sixty-four" for terrain it
had never seen would look like knowledge and fly ships into hills.

Three decisions follow from it:

- A cell keeps the **highest** reading it ever gave, never the latest. A ship
  passing over the gap between two towers must not erase the towers.
- `surveyed` tests coverage **and** the longest gap. Coverage alone passes a
  route that is ninety per cent known with one hole in it, and the hole is where
  the mountain is.
- Preflight only ever **raises** an altitude. A map built from where ships
  happened to fly can say a hill is present; it can never honestly say one is
  absent, so lowering on its word would be trusting an absence of evidence.

Bounded like the log, for the same reason -- it grows with every block ever flown
over -- and evicted oldest-first, because ground under a route nobody flies any
more matters less than ground under one they do.

Beacons feed the same map. A beacon's own y is the ground it stands on, so the
only thing it needs a sensor for is what is *above* it, and that is the number a
tapped-in waypoint can never give.

### State persistence

Two files, deliberately separate:

- `/aero.state` on a pilot: the flight plan, the cached waypoints, home. Written
  on change, **debounced to at most once a second** — the fix moves every sweep
  and a ship writing its position five times a second would do nothing else.
- `/fleet.state` on the server: roster, waypoints, routes, log.

A ship that was flying when the chunk unloaded comes back **loitering**, not
cruising: it has no fix yet and no idea how long it was away.

`textutils.serialize` refuses a table that appears twice, so `nav.plan` **copies**
waypoints into its legs rather than referencing them — sharing the reference made
every save throw, from inside the control loop, on a ship in the air. `state`
also `pcall`s the serialise: losing one write is survivable, losing the coroutine
holding the ship up is not.

### The log

`lib/log.lua` is a ring buffer of `{t, ship, what, from, to, why}`. `why` is a
guard name (`clearance`, `bingo`, `nofix`), a waypoint, or `manual`. Bounded at
`config.logSize`.

### Concurrency

`pilot.lua` runs `parallel.waitForAny(flyTask, listenerTask)` inside one `pcall`,
with `hull.release()` in the epilogue on **every** path — clean stop, terminate,
uncaught error, update.

Boot order: `hull.load` → `state.open` → restore the plan → **`hull.release`
before anything else**, so a reboot mid-flight starts from a known-neutral hull
rather than whatever override survived → `net.open` → first telemetry →
`parallel`.

Unlike `redstone/node.lua` there is **no event to react to**. Nothing in CC
raises an event because a ship has drifted, so the `config.sweep` timer is the
whole clock and every derivative is taken across it.

`server.lua` and `remote.lua` are single `os.pullEvent` loops.

### Message protocol

Every message is a table with a `type` field, carried in a `lib/net` frame.

Pocket / server → pilot:
- `{type="fly", names={...}, alt=<n>}` · `{type="hold"}` · `{type="land", pad=?}`
- `{type="alt", alt=<n>}` or `{type="alt", by=<n>}` — raise or lower, with no
  plan needed. From a parked ship this takes off and holds.
- `{type="take"}` / `{type="release"}` — the conn, see below
- `{type="dock", pad=<name>}` · `{type="rtb"}` · `{type="stop"}` (descend now)
- `{type="hull?"}` — describe yourself; how the pocket learns the controls
- `{type="tune", gains={...}}` · `{type="rename", name=...}` · `{type="update", ...}`

Pilot → all, every `config.heartbeat` (**1s** — a lamp can be a second stale, a
ship at cruise covers twelve blocks):
- `{type="tlm", pos, alt, heading, speed, vs, fuel, burn, flight={...}, source}`
- `{type="tlm", gone=true}` on the way out, so the tower drops it at once
- `{type="event", what, from, to, why}` · `{type="error", reason}`

Pocket → server: `{type="net?"}` · `{type="wp!"}` / `{type="wp-"}` ·
`{type="home!"}` · `{type="route!"}` · `{type="log?"}` · `{type="command", target, body}`

Server → all: `{type="net", ships, waypoints, routes, home}` every ~2s.

**Pilots cache the waypoint table to disk** on every `net` broadcast, so a ship
already airborne when base unloads can still fly to a named pad and still knows
where home is.

An `update` is refused while `flight.busy` — which is any airborne state.
Replacing `lib/hull.lua` underneath a live control loop and then rebooting means
several seconds during which nothing is holding the ship up. The updater runs
*after* `parallel.waitForAny` returns, never from inside the listener.

### Configuration

`lib/config.lua` holds the defaults. `/aero.cfg` is a Lua file returning a table
that overrides any of them, written by `install.lua`. Like the other two suites
it is deliberately **not** in `manifest.txt`. It also carries `role`
(`pilot` | `server`), because hardware cannot tell a pilot from a tower.

## Suggested build order

1. `lib/config`, `lib/net`, `lib/state`, `lib/log` — adapted copies
2. `test/mockperipheral.lua` and `lib/hull.lua`, together; the mock is the only
   way to see the hull work
3. `lib/instruments.lua`, then `lib/nav.lua` — pure, no mock needed at all
4. `lib/autopilot.lua` and the mix, driven by the simulator. This is where the
   time goes: a PID that does not settle is not visible from reading it
5. `lib/flight.lua` and its guards
6. `pilot.lua` under `parallel`, with the release epilogue
7. `probe.lua`, then `server.lua`, then `remote.lua` last — it only renders what
   the protocol already provides

## Testing

There is no Create Aeronautics outside the game, so `test/mockperipheral.lua`
supplies the peripherals — with the mod's real method names — and the real
modules run against them under CraftOS-PC. See the Tests section of `README.md`
for the command. Six suites, run in that order by `test/run.lua`:

| Suite | What it covers |
| --- | --- |
| `spec.lua` | every module on its own, plus the manifest against the tree |
| `fly_spec.lua` | the whole stack flown against a simulated hull |
| `pilot_spec.lua` | pilot.lua's two loops: orders, updates, the release epilogue |
| `server_spec.lua` | server.lua's loop: roster, waypoints, log, relaying |
| `remote_spec.lua` | remote.lua's loop: both link modes, every screen |
| `install_spec.lua` | install.lua: fetching, the prompts, the files it leaves |

`lib/nav`, `lib/instruments`, `lib/autopilot` and `lib/flight` need no mock at
all — they touch no APIs, which is most of the reason they are shaped that way.

**`fly_spec.lua` is the one that matters most.** The mock carries a small flight
model — throttle to thrust to acceleration to position, with a terrain floor —
and the suite closes the loop through the real modules. Asserting that
`setThrottle` was called with 0.63 asserts nothing about whether the ship
arrives; this asks whether it arrives.

Things to know before adding cases:

- `--script` takes a **host** path, not a path inside the emulated filesystem.
- An uncaught error drops CraftOS into its shell, which blocks until the process
  is killed, so a crash looks exactly like a hang. `test/run.lua` wraps every
  suite in `pcall` for that reason.
- The pilot's control loop is **timer-driven and nothing else**, so
  `pilot_spec.lua` stubs `os.startTimer` to a constant id and queues
  `{ "timer", 1 }` to drive a sweep. It also stubs `gps.locate`, which blocks for
  its timeout and — worse — uses `os.startTimer`, which the harness has just
  taken over.
- Telemetry is rate limited to one frame per `config.heartbeat` of *ship* time, so
  a script that queues twenty timers without moving the clock gets exactly one
  telemetry frame, from before anything in the script happened.
- `lastTelemetry` must skip the `gone` farewell, which carries no state at all.
- UI tests force the terminal to **26x20** for the pocket computer. The headless
  terminal is 51 wide and layouts are relative to screen width, so a click at
  column 24 lands somewhere completely different.
- Every case ends with a queued `terminate` (or `q` for the remote).
- `server.lua` and `remote.lua` clear the terminal on their way out, so screens
  are captured mid-run with `aero_test_snap`.
- CC's `dofile` **does not forward arguments** to the chunk. `install_spec.lua`
  uses `loadfile` and calls the result, or every flag is silently dropped and the
  installer falls back to prompting.
- CC's `write` calls `term.write` once per **word**, so a recording terminal has
  to join its segments with nothing between them.
- A suite that swaps in a mock `peripheral` must **put the real one back**, not
  nil it. `install_spec.lua` runs last and `install.lua` calls
  `peripheral.getNames()`.
- `call` in `lib/hull.lua` returns two values, so `tonumber((call(...)))` needs
  the inner brackets — without them the reason string becomes the numeric base.
- Watch for `x and x.field or default` where the field can be `false`. It is
  always `default`, and it has already been a bug three times in this repo.

## Style notes

- Prefer small module files under `lib/` returning a table, loaded with
  `require`. CC:T supports `require` from the program's directory.
- Fail loud: broadcast an `error` message and write the reason to the state file
  before halting — but **never** from inside the control loop.
- A malformed `/craft.cfg` or `/aero.cfg` is ignored with a warning, never fatal.
  Every program requires config at load, so throwing would brick the computer —
  and on a pilot it would brick it mid-air.
