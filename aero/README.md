# Aeronautics flight network

Ships that hold altitude and heading by themselves, fly between named waypoints,
land or dock when they get there, and tell a base dashboard and a pocket computer
what they are doing on the way — for Create Aeronautics contraptions, driven
through **Create Aeronautics: Gadgets & Gizmos**.

Three programs, one install:

| Program | Runs on | What it does |
| --- | --- | --- |
| `pilot.lua` | a computer riding the contraption | Flies it. Owns the plan and every guard |
| `server.lua` | an advanced computer at base | Fleet roster, waypoints, the log, a monitor dashboard and a map |
| `remote.lua` | an advanced pocket computer | Fleet, fly, nav, log |

Plus `probe.lua`, which looks at what is bolted to the hull and writes a
`/craft.cfg` to start from.

**Every ship is autonomous.** The tower and the pocket set goals; they never fly
anything. Switch the tower off, break it, let its chunk unload — the ships carry
on to wherever they were already going and land themselves at the end of it. A
node in the redstone network that loses its link leaves a lamp in the wrong
state; a ship that loses its link is a falling building, so nothing here is
allowed to depend on the link.

## What you need

- **Create Aeronautics**, for the ships.
- **Create Aeronautics: Gadgets & Gizmos**, for the peripherals. The base mod's
  blocks are read-only sensors — without Gadgets & Gizmos this is a telemetry
  dashboard and nothing more.
- A **wireless modem** on every computer. An ender modem on the tower is worth
  it: range decides whether you hear about a diversion now or when the ship
  lands.
- A **navigation table** on the hull, or the ship can hold altitude but cannot
  navigate. An **altitude sensor** and an **optical sensor** pointing down are
  both strongly wanted; see Guards.

## Install

On every computer — pilot, tower and pocket alike:

```
wget run https://raw.githubusercontent.com/Gizmo0320/CCprograms/main/aero/install.lua
```

It asks four things: the network name, the modem channel, whether this is a pilot
or the tower, and a name for this computer. A pocket computer is always the
remote and is not asked.

Unattended:

```
install --net=north --channel=4300 --role=pilot --name=Kestrel
```

To update later, on any computer: `update`, or `update --check` to see what
would change without changing it. A ship in the air **refuses** an update.

## The hull: `/craft.cfg`

The installer deliberately does not write one. Which bearing holds the ship up
is the one thing it cannot possibly know, and a wrong guess is a ship that
accelerates into the ground.

Assemble the contraption, then on the ship's computer:

```
probe
```

It writes `/aero.survey.txt` — every attached peripheral and its methods — and a
`/craft.cfg` filled in from what it found. Then read it and fix the one thing it
had to guess:

```lua
return {
  name = "Kestrel",

  controls = {
    lift = { kind = "bearing", peripheral = "thruster_bearing_1", group = "all" },
    main = { kind = "bearing", peripheral = "thruster_bearing_0", group = "all",
             pivot = { min = -30, max = 30 } },
    trim = { kind = "orientation", peripheral = "virtual_orientation_source_0" },
  },

  instruments = {
    nav = "navigation_table_0", alt = "altitude_sensor_0",
    ground = "optical_sensor_0", dock = "docking_connector_0",
    stick = false,           -- this hull has none; stop looking, stop warning
  },

  limits = { cruise = 12, climb = 4, descend = 3, clearance = 8 },
  gains  = { hover = 0.5 },

  mix = {
    { demand = "lift",    control = "lift", as = "throttle" },
    { demand = "forward", control = "main", as = "throttle" },
    { demand = "yaw",     control = "main", as = "pivot", scale = 30 },
    { demand = "pitch",   control = "trim", as = "angleX", scale = 15 },
  },
}
```

**`lift` and `main` are the thing to check.** `probe` assumes the first bearing
lifts and the second pushes, which is the commonest arrangement and still a
guess.

`/craft.cfg` is not in `manifest.txt`, so `update` never replaces it. Edit it
freely. A malformed one is a warning on screen, never a computer that will not
boot.

### Control kinds

| `kind` | Peripheral | Takes |
| --- | --- | --- |
| `bearing` | `thruster_bearing` | `throttle` 0–1, `pivot` degrees |
| `thruster` | `thruster` | `throttle` 0–1, `enabled` |
| `orientation` | `virtual_orientation_source` | `angleX`, `angleZ` degrees |
| `wheels` | `wheel_mount` | `left`, `right`, `brake`, all 0–1 |
| `input` | `analogue_contraption_controller` | `input` 0–1, on the channel named by `input = <id>` |
| `grip` | `claw`, `rope_winch_cable` | `grip` = `open` / `close` / `release` |
| `wire` | this computer's sides, or a `redstone_relay` | `signal` 0–1 |

## Redstone

A great deal of Create Aeronautics is driven by a **signal** rather than a method
call: hot air burners, steam vents, throttle levers, gearshifts, deployers,
anything on a redstone link, and every thruster left in its default `redstone`
control mode. The `wire` kind is how any of that gets said at all.

```lua
controls = {
  burner = { kind = "wire", side = "top" },
  lever  = { kind = "wire", side = "back", mode = "analog" },
  lamp   = { kind = "wire", side = "left", mode = "bundled", colour = colours.lime },
  vent   = { kind = "wire", peripheral = "redstone_relay_0", side = "front" },
}
```

- `side` is one of `top` `bottom` `left` `right` `front` `back`.
- `mode` is `digital` (on/off), `analog` (0–15, what a Create throttle lever
  reads) or `bundled` (one colour of a bundled cable). `bundled` needs a `colour`.
- `peripheral` names a [`redstone_relay`](https://tweaked.cc/peripheral/redstone_relay.html).
  With none, the control drives the flight computer's **own six sides**. A relay
  has an identical API and can sit anywhere on a wired modem network, which on an
  assembled contraption is how the burner ends up somewhere sensible rather than
  bolted to the computer.
- `invert` lives on the control, not in every mix term that touches it. A burner
  wired through a NOT gate should be fixed once, in the place that describes the
  wiring.

Then drive it from the mix like anything else — `signal` is 0–1, so a demand goes
straight in:

```lua
{ demand = "lift", control = "burner", as = "signal" },
```

An **analogue** signal is rate limited like a throttle, because it is usually
driving something proportional that the ship's motion depends on. A digital or
bundled one is a switch, and rate-limiting a switch only makes it late.

Several controls may share a side if they are all `bundled` and all use different
colours — the whole face is recomputed on every write, because a bundled side is
one number shared by up to sixteen controls and setting one colour without
knowing the other fifteen turns them all off. Anything else sharing a side is
refused at load with a reason.

**A wire is the one control that is turned off rather than handed back.**
Everything else here is an override on top of a control the ship already had, so
releasing means giving it up. A redstone output has no owner underneath us — the
computer *is* what holds it — so there is nothing to hand it back to and off is
the only safe value. Which cuts both ways, and is worth knowing before you wire a
burner through one: **a ship kept aloft by a redstone-driven burner comes down
when the program stops.** Drive lift through a bearing.

### Signals coming in

```lua
signals = {
  launch = { side = "front" },
  cargo  = { side = "right", mode = "analog" },
  hatch  = { side = "back", peripheral = "redstone_relay_0", invert = true },
}
```

A launch button, a lever, a comparator on the hold, the joystick's own
directional output. They drive nothing by themselves: they are read every sweep,
ride in the telemetry frame, and show on the pilot's screen when they are saying
something — which is what makes "the hold is full" a thing you can see from the
ground rather than a thing you find out when the ship will not climb.

Same fields as a `wire`, and one API call per side however many signals share it:
sixteen bundled colours on one cable is one read, not sixteen.

### The mix

The autopilot produces four abstract demands — `lift`, `forward`, `yaw`,
`pitch` — and knows nothing about thrusters. The mix maps them onto what this
hull actually has, which is why a jet, a balloon and a truck can share one
autopilot.

Terms **add**, so two bearings can share the lift:

```lua
{ demand = "lift", control = "port",      as = "throttle", scale = 0.5 },
{ demand = "lift", control = "starboard", as = "throttle", scale = 0.5 },
```

`scale` multiplies the demand and `bias` is added once. A ground vehicle wants
`forward` on the wheels rather than on a thruster:

```lua
{ demand = "forward", control = "wheels", as = "left"  },
{ demand = "forward", control = "wheels", as = "right" },
```

## Flying

On the pocket computer, four tabs along the bottom.

**fleet** — every ship, what it is doing, how high. Tap one to select it; tap it
again to go back to commanding the whole fleet. Then:

| | |
| --- | --- |
| `HOLD` | stop and hover where you are |
| `LAND` | come down here |
| `RTB` | fly home and land |
| `STOP` | descend now, wherever you are |

`STOP` is a **controlled descent**, never a thrust cut. There is no button here
that switches the engines off in mid-air, on purpose.

**fly** — set an altitude, tap waypoints to build a route, tap `FLY IT`.

**nav** — `+ waypoint here` and `+ pad here` put a point down at the pocket
computer's own GPS position and ask you to name it. Standing where you want the
pad is the only waypoint-entry method anyone actually uses. Tapping an existing
waypoint makes it **home**.

A **pad** is somewhere to land and needs a height; a **point** is somewhere to
fly over. A plan ending on a pad descends and lands. A plan ending on a point
holds there — the ship does not put itself down in a field because the list ran
out.

**log** — what happened and why.

## Guards

Four rules outrank the flight plan. All four are checked every sweep, in this
order, and every one of them writes a line in the log — "why did it turn round"
is the question the log exists to answer.

**No vertical reference.** If the ship cannot tell you its height it cannot be
flown, so the hull is handed back to redstone. Worse than flying; much better
than a powered descent into the ground. This is why an altitude sensor matters.

**Ground clearance.** Below `limits.clearance`, climb — whatever the plan said.
The plan is not abandoned: the ship climbs, clears the hill, and carries on to
the same waypoint. Exempt while landing or docking, where getting close to the
ground is the point. Needs a downward optical sensor; without one there is no
terrain guard at all.

**No usable fix.** The navigation table going quiet for a few seconds is normal,
and the ship carries on by dead reckoning. Past about eight seconds it stops
navigating and loiters, holding altitude and heading until the fix comes back —
because dead reckoning cannot correct itself and flying a guess into a hillside
is worse than hanging in the air.

**Bingo fuel.** The ship turns for home while there is still enough burn time to
get there, with a margin. It is **latched**: topping a tank up does not
un-divert, because the diversion is now the plan.

A ship that is parked, or that has just been handed back, behaves exactly like a
ship with no computer on it — whatever its own levers say. That is the
configuration you built and tested, and it is not the same thing as every engine
off.

## The tower

`server.lua` draws three views, cycled with Tab or by tapping the header, on its
own terminal and on any attached monitor:

- **ships** — the roster, what each is doing, and why
- **map** — a plan view of the fleet and the waypoints, autoscaled. North is up
- **log** — what happened, to which ship, and the cause

It holds the waypoint table, and broadcasts it every couple of seconds. **Pilots
cache it to disk**, which is what lets a ship already in the air be sent to a
named pad after the tower's chunk has unloaded — and what lets the bingo guard
know where home is.

Two towers on one network would both relay commands and both keep a log, so a
second one asks first and stands down.

## Tuning

The default gains are tuned for a hull that hovers at about half throttle. If
yours does not, `gains.hover` in `/craft.cfg` is the first thing to change —
though the vertical loop's integral finds the true value within a few seconds
either way, so getting it roughly right only means the ship does not sink while
that happens.

If the ship hunts left and right of its heading, `hdgP` is too high. If it rolls
out of turns early and then overshoots, `hdgD` is too high — yaw drives a *rate*
of turn, so this loop needs far less damping than it looks like it should.

## Tests

There is no Create Aeronautics outside the game, so the modules run against a
mock hull under [CraftOS-PC](https://www.craftos-pc.cc/). Copy the tree to a
computer directory and run:

```
CraftOS-PC --headless -d <datadir> --script <abs path>/test/run.lua
```

`--script` takes a **host** path, not a path inside the emulated filesystem.
Results are written to `/test-summary.txt` and `/test-*-results.txt` on the
emulated computer rather than stdout, because headless mode redraws the entire
terminal on every update.

391 assertions. `spec.lua` covers each module on its own — the heading
arithmetic and the wrap, plans and legs, sensor fusion and the ageing of a
dead-reckoned fix, the PID loops and the integral clamp, every flight state and
all four guards, the hull abstraction over a mock of the real peripheral API, the
redstone layer over both a computer's own bus and a relay in all three signal
shapes, `probe.lua` round-tripped through the craft file it generates, the
bounded log, the debounced state write, and the manifest against the tree. Three
more drive the real event loops of `pilot.lua`, `server.lua` and `remote.lua`,
and one drives `install.lua`.

And `fly_spec.lua` actually flies it. The mock carries a small flight model —
throttle to thrust to acceleration to position, over terrain — and the suite
closes the loop through the real modules to ask whether the ship arrives:
whether altitude hold settles without overshoot, whether a heading hold holds
rather than hunting, whether a pad-to-pad flight ends parked on the pad, whether
a ridge across the flight path gets climbed and the mission survives it, whether
a fix going away turns into a loiter and back again, and whether low fuel turns
the ship round in time.
