# Aeronautics flight network

Ships that hold altitude and heading by themselves, fly between named waypoints,
land or dock when they get there, and tell a base dashboard and a pocket computer
what they are doing on the way — for Create Aeronautics contraptions, driven
through **Create Aeronautics: Gadgets & Gizmos**.

Four programs, one install. Every computer gets the whole tree and runs the one
its role says:

| Program | Runs on | What it does |
| --- | --- | --- |
| `pilot.lua` | a computer riding the contraption | Flies it. Owns the plan and every guard |
| `server.lua` | an advanced computer at base | Fleet roster, waypoints, the log, a monitor dashboard and a map |
| `remote.lua` | an advanced pocket computer | Fleet, fly, nav, log |
| `beacon.lua` | a computer standing where you want a waypoint | Announces itself as one. No sensors needed |
| `setup.lua` | any of them | What this computer needs, what it has, and what is wrong |
| `configure.lua` | any of them | Set it up in panes, with a review, without editing Lua |

Plus `probe.lua`, which looks at what is bolted to the hull and writes a
`/craft.cfg` to start from — and, with `--eyes`, shows live what the optical
sensors actually report; `beacon.lua`, a computer you place in the world and
give coordinates to, so that it *is* a waypoint; and `setup.lua`, which tells you
what any computer is missing.

```
probe            survey the hull, and write /craft.cfg if there is not one
probe --force    survey, and write /craft.cfg.new even if there is
probe --eyes     watch every optical sensor live: range, hit, distance, block
```

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
- **Beacons are optional.** A waypoint tapped in from the pocket works; a beacon
  is a computer that stands there being one, so it does not need anybody present
  and survives restarts. It needs no sensors. See *Waypoint computers*.
- **[CC: Sable](https://techtastic.github.io/CC-Sable/)** is optional and worth
  having. It exposes the physics object itself — real velocity, real
  orientation, angular velocity, mass — which is strictly better than any sensor
  block and is what makes the attitude guard able to tell a tumbling ship from a
  banking one. Everything works without it; less well.

## Install

On every computer — pilot, tower and pocket alike:

```
wget run https://raw.githubusercontent.com/Gizmo0320/CCprograms/main/aero/install.lua
```

It asks four things: the network name, the modem channel, whether this is a
**pilot**, the **tower** or a **beacon**, and a name for this computer. A pocket
computer is always the remote and is not asked.

Unattended:

```
install --net=north --channel=4300 --role=pilot  --name=Kestrel
install --net=north --channel=4300 --role=server --name=Tower
install --net=north --channel=4300 --role=beacon --name=quarry-pad
```

To update later, on any computer: `update`, or `update --check` to see what
would change without changing it. A ship in the air **refuses** an update.

### The manual is in the game

```
guide
```

The whole thing — first flight, the hull file, balloons, the guards, tuning and
troubleshooting — readable on the ship's own computer, the tower or the pocket.
`guide bingo` opens it at the first topic that mentions bingo fuel, which is a
reasonable thing to type when a ship has just turned round on you.

It is there because the moment you need to know why a ship will not take off is
the moment you are standing next to it in a cave, and a page on the internet is
not reachable from there.

## Quick start

From nothing to a ship in the air.

**1. Build the contraption** with a computer on it, and assemble it. Put a
wireless modem on that computer, a navigation table and an altitude sensor on
the hull, and an optical sensor pointing down.

**2. Install** on the ship's computer, on an advanced computer at base, and on
an advanced pocket computer — the same one-liner on all three. It asks four
things; the defaults are fine for a first ship.

**3. Check the hardware.** On the ship's computer, `setup`. Everything marked
`NO` in red has to be dealt with before the rest of this works. Leave it running
while you fix them; it re-checks itself.

**4. Survey the hull, with the contraption assembled.** On the ship's computer:

```
probe
```

It writes `/craft.cfg` from what it can see, and `/aero.survey.txt` listing
every peripheral it found.

Assembled matters here and only here. An unassembled contraption's blocks are
not peripherals yet, so `probe` would survey a hull with nothing on it. The
*pilot* no longer cares — it re-resolves whenever a peripheral attaches, so you
can start it before assembling — but `probe` writes a file, and a file written
from an empty survey is a hull definition that says the ship has no instruments.

If two optical sensors came back, run `probe --eyes` and check which is which:
they are the same block, so `probe` guesses the first points down and the second
forward.

**5. Check the one guess.** Run `configure` and open **Bearings**. `probe`
assumes the first bearing lifts and the second pushes; that is the commonest
arrangement and still a guess, and getting it backwards is a ship that
accelerates into the ground. The pane shows every bearing attached — point at the
right one. (Or edit `/craft.cfg` by hand; it is only Lua.)

**6. Tethered test — do not skip this.** Run `pilot` with no flight plan. Check
the pocket computer sees the ship. Then press **Ctrl-T**. Every thruster must go
to zero and back to redstone control (`getControlMode()` reads `"redstone"`).
Nothing should fly until this passes: it is the difference between a program you
can stop and one you cannot.

**7. Put down a pad.** Stand where you want it. On the pocket: **nav** tab,
`+ pad here`, name it. Tap the name to make it **home** — the bingo-fuel guard
needs somewhere to divert to.

**8. Put down a second waypoint** somewhere you can see from the pad.

**9. Fly it.** **fly** tab: set an altitude well clear of anything, tap the
waypoint, tap `FLY IT`. Watch it on the pocket, and keep a hand near the
joystick — touching it takes control back instantly.

The route will say **not surveyed**, because nobody has been that way. That is
expected on a first flight and is why step 9 says *well clear of anything*: the
guards are all the ship has until something has measured the ground. Fly it once
and the tower remembers; the next plan over the same ground will tell you what it
needs before you take off.

**10. Optional, later.** Put a computer at the far pad, install it with
`--role=beacon`, and run `beacon` to give it a name and its coordinates. It is
then a waypoint that is always there, with nobody standing next to it.

## Configuring

```
configure
```

Panes, a review, and nothing written until you say so — the shape
[cc-mek-scada](https://github.com/MikaylaFischler/cc-mek-scada) uses, which gets
three things right this project did not: setup is its own program, the front page
**tells you what is wrong with the configuration you already have**, and you see
everything you are about to write before it is written.

| Pane | |
| --- | --- |
| **Network** | name, channel, role |
| **Bearings** | which bearing is lift and which is main |
| **Instruments** | what this hull can read, including switching one off deliberately |
| **Limits** | cruise, climb, descend, clearance, hover |

**Bearings is the one that matters.** Nothing can work out which bearing holds
the ship up by looking — `probe` guesses — and getting it backwards is a ship
that accelerates into the ground. Here you are shown every bearing that is
actually attached and you point at the right one; swapping them is two taps
rather than an edit to a file you have to find first.

It writes ordinary Lua to `/aero.cfg` and `/craft.cfg`, both still outside
`manifest.txt` and still yours to edit by hand. This is a nicer way in, not a
replacement.

## Checking the hardware

```
setup
```

Lists everything this computer's role needs, marks what is attached **right
now**, and says what each thing is for and what you lose without it. It
re-checks every second, so you can leave it on screen, walk over, place the
missing block, and watch the line turn green.

`setup pilot` shows another role's list, for planning a build before you have
made it.

On a flight computer it also reads `/craft.cfg` and reports anything that
disagrees with the hardware — and that half is the important one, because
**"it cannot find the navigation table" has four separate causes**:

- the block is not on the contraption
- the contraption is not assembled, so its blocks are not peripherals yet
- `/craft.cfg` has the role switched off
- nothing has run `probe` yet, so there is no `/craft.cfg` at all

A flight computer printing one line of warning cannot tell those apart. `setup`
can, and puts the answer on the second line of the screen with the header in red.

> **If you have a ship that will not navigate, this is the first thing to run.**
> Earlier versions of `probe` wrote `nav = false` into `/craft.cfg` for anything
> that was not attached at the moment it ran — which is the normal state of a
> contraption that has not been assembled — and `false` means *this hull
> deliberately has none, stop looking*. Plugging the table in afterwards did not
> help, because the file was now insisting the ship had none. `probe` no longer
> does that, and `setup` reports the mistake in existing files. Re-run `probe` on
> an assembled ship, or delete the `nav = false` line by hand.

### Assembling the ship after starting the pilot

The second cause in that list used to be permanent, and it was the commonest of
the four.

Assembling a Create Aeronautics contraption **attaches every peripheral on it**;
taking it apart detaches them all. The pilot used to resolve its hardware once at
boot and keep that answer for the life of the computer — so turning the flight
computer on and *then* assembling the ship, which is the ordinary order of
operations, left it reporting that it could not find the navigation table while
the table sat plainly on the hull. Rebooting fixed it, which made it look like an
intermittent fault rather than a rule.

The tell was that `setup` and `configure` could see hardware the pilot could not:
both have always rescanned on attach and detach. The pilot now does the same, and
logs a `hardware` event when the set of instruments actually changes. Assembly
order no longer matters, and neither does taking a ship apart and putting it back
together with the computer left running.

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
| `gearbox` | `bidirectional_gearbox` | `angle` degrees, on the compass `face` you name |
| `wire` | this computer's sides, or a `redstone_relay` | `signal` 0–1 |

A `gearbox` names its face by compass point rather than by one of the computer's
sides, because it is a block on the contraption:

```lua
vane = { kind = "gearbox", peripheral = "bidirectional_gearbox_0",
         face = "north", pivot = { min = -45, max = 45 } },
```

Its **mode** is deliberately left alone. `auto`, `passthrough`, `servo` and the
rest change what the gearbox is *for*; that is a decision its builder made when
they placed it, and a program that quietly flipped it to servo on boot would
break a contraption that was working.

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

**A wire is turned off rather than handed back when the program stops.**
Everything else here is an override on top of a control the ship already had, so
releasing means giving it up. A redstone output has no owner underneath us — the
computer *is* what holds it — so there is nothing to hand it back to, and off is
the safe value for a vent or a gearshift stuck over.

It is emphatically **not** the safe value for something holding the ship up.
See below.

## Balloons: burners and steam vents

A [hot air burner](https://createaeronautics.miraheze.org/wiki/Hot_Air_Burner)
and a [steam vent](https://createaeronautics.miraheze.org/wiki/Steam_Vent) both
generate lift by filling a hot air envelope, and both are **analogue**: the
signal strength sets the target volume, linearly, up to whatever the panel on the
block is configured to. Signal 15 is the full volume; signal 0 empties it.

```lua
controls = {
  burner = { kind = "wire", side = "top", mode = "analog", hold = true },
}

mix = {
  { demand = "lift", control = "burner", as = "signal" },
}
```

Three things follow, and all three matter.

**`hold = true`, always, on anything that is lift.** It tells `release` to leave
the wire driving when the program stops. Without it, quitting the pilot turns the
burner off at whatever altitude you happened to be at. `hold` is also what keeps
the signal in the state file, so the next boot puts it back.

**CC does not persist redstone outputs.** They come back off after a chunk
unload or a server restart. The pilot saves every wire signal and restores it at
boot, before the listener starts — which is the only reason walking away from a
moored balloon is survivable. This is handled for you; it is written down because
it is not obvious and it is the difference between a ship that is still there
when you come back and one that is not.

**It is a much slower plant than a thruster.** The envelope fills at a finite
rate, so the lift lags the command by seconds in both directions, and there are
only sixteen signal levels to express it in. The thruster defaults will make a
balloon bob up and down for as long as you leave it. Start softer and let the
integral do the work — this is the gain set the test suite flies a balloon with:

```lua
gains = { hover = 0.5, altP = 0.2, vsP = 0.05, vsI = 0.04, vsD = 0.04,
          vsIMax = 0.5 },
limits = { cruise = 8, climb = 2, descend = 2, clearance = 8 },
```

Multiple burners or vents can fill one balloon and their volumes combine, so give
each its own `wire` control and its own `lift` mix term — the terms add.

## Instruments

Every one of these is found automatically by type, so naming it in
`instruments` is only necessary when you have two — or when you want the file to
be a description of the ship rather than a list of overrides. Set one to `false`
to say "this hull has none, stop looking and stop warning".

| Role | Peripheral | Gives |
| --- | --- | --- |
| `nav` | `navigation_table` | position and heading. Without it the ship can hover but not navigate |
| `alt` | `altitude_sensor` | height. Without it *and* `nav`, the pilot hands the hull back |
| `vel` | `velocity_sensor` | speed, as a cross-check on the differentiated figure |
| `gimbal` | `gimbal_sensor` | pitch and roll, as real angles |
| `ground` | `optical_sensor` | clearance below. No sensor means no terrain guard |
| `forward` | `optical_sensor` | what is ahead. No sensor means no obstacle guard |

**The two optical sensors are the same block**, so only you know which way each
one points. `probe` assumes the first points down and the second forward — the
commonest arrangement, and still a guess. Check it, in `configure` →
**Instruments** or in the file.

Three rules keep them apart. A sensor named for one role is never auto-found for
the other. Roles resolve in a fixed order, so two computers reading one craft
file cannot disagree about which got first pick. And naming *one* sensor as both
is refused with a reason — they want opposite ranges, so whichever is written
last wins and the other guard spends the flight reading a number that means
something else entirely.

The `ground` sensor is *asked* to look **128 blocks** down, not just far enough
for the guard. The same reading is the ship's height above ground in the cockpit
and the sample every terrain survey is built from — at sixteen blocks it saw
nothing at cruise altitude, so the map stayed empty and nothing said why.

Asked, not told. **The maximum range is set on the sensor block itself**, and the
mod raises a Lua error rather than clamping when a program asks for more than
that. So the flight computer negotiates: if the block already sees far enough it
writes nothing at all, otherwise it asks and keeps halving until something is
accepted, and if the block refuses everything its own setting stands. A refused
range is not a fault — the sensor works, it has a limit — but a `ground` sensor
that ends up under 32 blocks is called out on the ship panel, because a blank
clearance reads exactly like flat ground a long way down.

To see what a sensor actually reports, including which calls fail:

```
probe --eyes
```

It lists every optical sensor with its range, `hasHit`, distance and block, live,
and says which role `/craft.cfg` gives each one — because knowing a sensor works
is only half the question, and the other half is whether the program is asking
the one it thinks it is.
| `dock` | `docking_connector` | what the ship is docked to |
| `stick` | `analogue_joystick` | the pilot's hands |
| `link` | `advanced_data_link` | publishes where the ship is going |
| `homing` | `directional_link` | bearing to the nearest matching link |
| `range` | `modulating_link` | distance to the nearest matching link |
| `plate` | `name_plate` | the ship's name, on a block you can read from outside |
| `swivel` | `swivel_bearing` | where a swivel bearing is pointing |

Renaming a ship from the pocket computer writes the **nameplate** as well as the
computer's label, so the name is visible from the ground rather than only on the
dashboard.

If the hull has an **advanced data link**, the pilot publishes the current leg's
position to it whenever the leg changes — so gyros and guided bearings wired to
that link aim at the same place the autopilot is flying to, rather than at
whatever was last set by hand. A hull without one is the common case and nothing
depends on it.

The two **linked receivers** together give a homing fix: bearing and range to the
nearest matching link. The role is `homing` rather than `beacon`, because
`beacon.lua` is a different thing entirely and one word for both would be a
confusing bug report waiting to happen. They are reported in the telemetry and nothing steers
on them, deliberately — `getClosestAngle` is an angle, and I have not been able
to confirm whether it is measured from world north or from the receiver's own
facing. Those differ by the ship's heading, which is exactly the error that sends
a ship confidently past its pad. Watch it against a known bearing, tell me which
it is, and it can become a real approach aid.

Two peripherals are deliberately unused. `torsion_spring` (`getAngle`,
`setLimit`, `isRunning`) is an actuator, but what a limit does to a hull in
flight is not something this program can guess. `linked_typewriter`
(`getPressedKeyCodes`) is a cockpit keyboard — a manual flying mode, which is a
different program from this one.

## Tilt

The [gimbal sensor](https://createaeronautics.miraheze.org/wiki/Gimbal_sensor)
has a peripheral — `gimbal_sensor`, with `getAngles()` returning real degrees —
and if you have it, tilt is read directly and you need nothing below.

The block *also* "outputs redstone signals based on which side is leaning
downwards", with a separate sensitivity per axis, which is the only way to read
it without the Gadgets & Gizmos compatibility layer. To do it that way, name the
four faces:

```lua
tilt = {
  front = "front",   -- the input side that powers when the nose leans down
  back  = "back",
  left  = "left",
  right = "right",
  degrees = 30,      -- what a signal of 15 means; match the sensitivity panels
  -- peripheral = "redstone_relay_0",   -- optional
},
```

`degrees` has to match what is set on the block, because nothing here can read
it. Pitch comes out positive nose-down and roll positive right-side-down; add
`invertPitch = true` or `invertRoll = true` if your sensor is mounted the other
way round. Either pair may be omitted if you only wired one axis.

Tilt shows on the pilot's screen and rides in the telemetry frame. The peripheral
is preferred when both are present: it reports real angles, where redstone gives
sixteen steps of whatever the panel says.

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

## The screens

Four programs, one look. Colour means the same thing on all of them — a state
that read "loiter" in one colour on the tower and another on the pocket would be
worse than no colour at all — and everything degrades: to 26x20 on a pocket, and
to a **basic computer with no colour**, which a ship's flight computer or a
beacon may well be.

### The ship

`pilot.lua` draws an instrument panel, not a log. Nobody is standing at this
computer while the ship is flying; what it is for is the moment you climb up to
one sitting somewhere it should not be and want to know what it thinks is going
on.

- An **artificial horizon** from pitch and roll, with tilt and spin under it
- An **altitude tape** with the commanded altitude marked on it
- State, why, speed, heading, clearance, what is ahead, the current leg
- A **bar per control** showing what the autopilot is actually asking the hull
  for — the one thing invisible from outside, and the thing that explains most
  surprises. A ship on the ground with the lift bearing at full is a different
  problem from one with it at nothing.
- Fuel, with burn time
- The fix source along the bottom, because everything above it is worthless if
  the ship does not know where it is

The header bar turns the colour of whatever guard is firing, so a ship in
trouble is obvious from the ladder.

On a narrow screen the horizon and the tape give way to a compass strip and the
numbers. Nothing is only distinguishable by colour.

### The tower

`server.lua` draws four views, cycled with Tab or by tapping a tab in the
header, on its own terminal and on any attached monitor.

- **ships** — the roster, colour-coded by state, with the reason for whatever
  each one is doing. Click one to pick it out; it is highlighted on the map too.
- **map** — everything at once, autoscaled, north up, each ship an arrow showing
  its heading and each waypoint marked by kind.
- **log** — coloured by cause, so a screen of routine leg changes cannot hide
  the one diversion in the middle of it.
- **nav** — the waypoint table and which one is home, readable without a pocket
  computer in your hand.

The header is the alarm as well as the title: if any ship is on a guard the
whole bar turns that colour and leads with the reason.

## Flying

On the pocket computer, four tabs along the bottom, plus a panel for one ship.

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

### Up and down

`ALT raise / lower` on the fleet tab, and again on a ship's own panel. Tap the
right of the row to climb, the left to descend, ten blocks a tap. Altitude does
not need a flight plan.

- A **parked** ship takes off for it and holds where you put it — the short way
  to say "take off and hover at 140", which previously could not be said at all.
- A **flying** ship just changes what it holds. If it was on a leg it keeps the
  leg: this is a change of cruise altitude, not a change of mind.
- Two taps move it twice. The second is measured from where the ship is *going*,
  not from where it has got to, so a quick double tap does not race the climb.
- Silly numbers are clamped, because the altitude is something you type now and
  `1500` instead of `150` is a ship that spends four minutes climbing out of
  sight. A hull can narrow the range with `limits.ceiling` and `limits.floor`.

### Sharing a ship

Anyone can **watch** a ship — telemetry is broadcast and costs nothing. One
person at a time **flies** it.

Two pocket computers sending `land` and `fly to the quarry` a second apart is the
joystick problem again with more hands: the ship obeys whichever arrived last and
nobody watching can tell why. So control is **held**. The first order takes it;
anyone else is refused and told who to ask.

On a ship's panel:

```
 control   Anna
 TAKE control from Anna
```

**Taking over always works.** A ship nobody can command because its commander
logged off would be worse than the muddle this prevents — but it is a deliberate
tap and it goes in the log, naming both people. `RELEASE control` hands it back
to nobody, and control lapses on its own after `config.conn` (90s) of silence, so
wandering off needs no ceremony.

A ship somebody else is flying is marked with a `*` in the fleet list, and the
tower shows the name in a **flown by** column — which is what you want to know
before you touch anything.

Orders relayed through the tower are stamped with the pocket computer that
*originally* sent them, so the conn belongs to the person holding it rather than
to the tower that passed the message on.

### One ship's panel

Pick a ship on the **fleet** tab and `SHIP` opens its own screen. This is where
everything that belongs to one ship rather than to the fleet lives, and all of it
was previously reachable in the protocol and by nothing a thumb could press:

- **Gauges** — altitude against the commanded altitude, fuel against the tank,
  and the readings that explain a ship not doing what you expected: vertical
  speed, tilt, fix source, and the active guard.
- **The hull** — every control, its kind, and whether it is answering. The
  quickest way to find out that the bearing you thought was lift is not attached
  is to look at this list; the pocket has no `/craft.cfg` of its own and learns
  by asking.
- **Gains** — `hover`, `altP`, `vsP`, `vsI`, `hdgP`, `spdP`, each with a minus
  and a plus. A tap moves the gain by a tenth of itself, so one control works for
  a gain of 0.5 and one of 0.015 without you having to know which is which, and
  never below zero. **This is the tuning loop**: reinstalling to try 0.4 instead
  of 0.35 is not one anybody will use, so it happens from the thing in your hand
  while the ship is in the air in front of you.

### Routes

Build a route on the **fly** tab and `SAVE as...` keeps it on the tower. Saved
routes appear above the waypoint list, and tapping one loads its legs and its
altitude — so a run you fly every day is two taps.

### Deleting

On the **nav** tab, tapping a waypoint's name makes it home; tapping the `x` in
the last column deletes it. Two gestures on one row, because deleting is the more
dangerous of the two and should not be what happens when you tap a list you were
reading. Home cannot be deleted at all — a ship already out there is relying on
it.

## Waypoint computers

A **beacon** is a computer you place where you want a waypoint. It tells the
tower it is there for as long as it is running, so nobody has to walk over with a
pocket computer and nobody has to add it again after the world restarts.

That is the whole job. It is a marker, not an instrument — **no sensors, nothing
to wire up**. A wireless modem so it can be heard, and a position so it knows
what to say.

Install it with the `beacon` role, then:

```
beacon
```

It asks three things: a **name**, whether it is a **pad** (somewhere to land) or
a point (somewhere to fly over), and **where it is**.

```
Where is it?
Enter for 40 70 300, or type x y z:
```

If GPS answers, setup offers what it found and Enter takes it. If it does not,
you type three numbers — `40 70 300` or `40,70,300`, either is fine. **GPS is
only ever a suggestion.** A beacon that depended on it would be a waypoint that
stopped existing whenever the satellites unloaded, which is the opposite of the
point, and the coordinates are yours to set regardless.

To change any of it later: `beacon set`, or press `S` on the beacon itself, or
edit `/beacon.cfg` by hand — `update` never replaces it.

For a row of them, skip the questions entirely:

```
beacon --at=40,70,300 --name=quarry-pad --kind=pad
```

**Optional:** a docking connector on the same computer makes it report whether
the pad is occupied. That is the only peripheral it will ever look for.

A beacon with no position announces **nothing at all**, and says so on its own
screen. A marker in the wrong place is worse than no marker: every route through
it would go somewhere nobody chose.

Because it stands on the ground, its own height is a known ground point and goes
into the height map for free — see below.

## Surveying

Ships survey as a side effect of flying. Every telemetry frame carries where the
ship is and how far the ground is below it — which is a measurement — and the
tower folds it into a coarse height map. **So the second flight over a route
knows what the first one found out.**

Before taking off, `preflight` checks the route against that map and **raises**
the cruise altitude if the ground needs it, logging `terrain` when it does.

It only ever raises, and that asymmetry is the point. A map built from wherever
ships happened to fly can say a hill *is* there. It can never honestly say a hill
is *not* — nobody may have looked. Lowering an altitude on that basis would be
trusting an absence of evidence.

On the **fly** tab, a route you are building shows one of:

```
 route needs 190
 route not surveyed
```

The second is not a fault. It means nobody has been that way, so the guards are
all you have — fly it high.

Two things keep it honest. A cell holds the **highest** ground ever seen in it,
never the latest, so a ship passing over the gap between two towers cannot erase
what it learned about the towers. And a route is only treated as surveyed if
coverage is good enough **and** its longest unsurveyed stretch is short enough —
coverage alone would wave through a route that is ninety per cent known with one
enormous hole in the middle, and the hole is exactly where the mountain is.

The map is bounded like the log, kept across restarts, and cached by ships — so
one already in the air can still check its own route with the tower's chunk
unloaded.

## Guards

Seven rules outrank the flight plan. All are checked every sweep, in this order,
and every one writes a line in the log — "why did it turn round" is the question
the log exists to answer.

**The pilot's hands.** Touch the joystick and the autopilot lets go of the hull
entirely, because two things commanding one ship is worse than either alone. It
also **drops the flight plan**: a ship that quietly resumed a flight to somewhere
else the moment you let go would be the most alarming thing this program could
do. Let go and it waits a few seconds — a pause between inputs is not a handover
— then catches the ship in a hold. Fly on from there with a new order.

**Attitude.** Past `limits.tilt` (25° by default) the ship stops navigating,
holds its height and asks any trim control to level. The plan survives, because a
ship that leaned in a gust and came back should carry on.

Past `limits.tiltAbort` (70°) it hands the hull back and stops flying altogether,
and this is the one worth understanding. Every control law here assumes the lift
demand pushes the ship *away* from the ground. Past about seventy degrees it
pushes sideways; past ninety it pushes **down**. A ship on its back with the
altitude hold still calling for more lift is being flown into the ground at full
power by the loop whose whole job is preventing that. There is no cleverer answer
available — the autopilot has no real attitude authority, and the physics engine
rights most hulls on its own given the chance.

With CC: Sable the same guard also watches **angular velocity**: a ship spinning
fast is out of control whatever its current angle, because it is simply between
two attitudes. Without CC: Sable there is no spin reading and a level-but-tumbling
ship is not caught.

**No vertical reference.** If the ship cannot tell you its height it cannot be
flown, so the hull is handed back to redstone. Worse than flying; much better
than a powered descent into the ground. This is why an altitude sensor matters.

**Ground clearance.** Below `limits.clearance`, climb — whatever the plan said.
The plan is not abandoned: the ship climbs, clears the hill, and carries on to
the same waypoint. Exempt while landing or docking, where getting close to the
ground is the point. Needs a downward optical sensor; without one there is no
terrain guard at all.

**An obstacle ahead.** The clearance guard is a *floor* and nothing else — a
ship at cruise flying at the **side** of a mountain has perfect clearance
underneath it the whole way in. A forward-facing optical sensor closes that: the
ship stops pushing, climbs, and adopts the height it had to climb to for the rest
of the flight. Without a `forward` sensor there is no guard here at all.

Know what it does not do. **A ship has no brakes.** Zeroing the forward demand
removes the push; drag removes the speed, exponentially, and a hull at cruise
coasts a long way while it climbs — thirty-odd blocks is typical. Against a ridge
it can get over, the climb wins. Against something unclimbable it will still
drift into the face, slowly, climbing all the way. Raise `config.reaction` on a
hull with little drag.

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

## The boot log

Every program now says what it is doing as it comes up — the hull, each
instrument, the modem, the saved state — with `ok`, `FAIL` or `--` against each
line. A computer that comes up wrong should tell you *where* it stopped rather
than presenting a blank screen. If anything failed it holds the log on screen for
ten seconds so you can read it, then carries on, because an unattended computer
in an unloaded chunk must not sit at a prompt forever.

The boot log is a snapshot, though, and on a ship the hardware moves afterwards.
A pilot logs a `hardware` event whenever assembling or disassembling the
contraption changes which instruments it can resolve — so the flight log records
the ship gaining its navigation table three seconds after boot, rather than
leaving a boot line that said `--` and was true only for a moment.

## When it goes wrong

Also in the game, as `guide` → *When it goes wrong*.

| What you see | What it usually is |
| --- | --- |
| Pocket shows **LOST** and no ships | No wireless modem, or the computers are on different channels. They must all match; reinstall to change one. |
| One ship shows **LOST** | Out of modem range, or its chunk is not loaded. An ender modem on the tower is the fix. |
| Refuses to take off | `preflight` rejected it and said why in the log: no plan, no cruise altitude, no usable fix, or not enough fuel for the distance. |
| Hands the hull back the moment it starts | No altitude source. The altitude sensor must be part of the assembled contraption and named in `/craft.cfg`. |
| Holds height but will not navigate | **Run `setup`.** Four different causes look identical from the ship: no block, an unassembled contraption, `nav` switched off in `/craft.cfg`, or `probe` never run. |
| Flies confidently the wrong way | `lift` and `main` swapped in `/craft.cfg`, or a mix term with the wrong `scale`. |
| Climbs like a rocket on takeoff | `hover` far too high, or the mix is driving lift from two terms that add to more than you meant. |
| Sinks slowly and never climbs | `hover` too low. Raise it; `vsI` will find the rest within a few seconds. |
| Bobs up and down for ever | Thruster gains on a balloon. See **Balloons** — it wants roughly a quarter of them. |
| Wanders either side of its heading | `hdgP` too high. |
| Rolls out of a turn early, then overshoots | `hdgD` too high. Yaw drives a *rate* of turn, so this loop needs far less damping than it looks like it should. |
| Turns round part way to somewhere | Bingo fuel. The log says `bingo`. It is latched, and topping a tank up will not un-divert it. |
| Stops and climbs for no visible reason | The obstacle or clearance guard. The log says which. |
| Drifts into a cliff while climbing | Expected, and documented above: a ship has no brakes. Raise `config.reaction`. |
| Nothing on the **nav** tab | Waypoints live on the tower. Without one, the pocket shows only what ships have cached. |
| A beacon shows **No position** | Nobody has told it where it is. Press `S`, or run `beacon set`. It will not guess: a marker in the wrong place is worse than none. |
| Route says **not surveyed** | Nobody has flown it. Not a fault — fly it high, and it will be surveyed for next time. |
| A ship took off higher than you asked | The route's survey needed it. The log says `terrain`. |
| `update` refused | The ship is airborne. Land it first — this is deliberate. |
| An order is refused, naming somebody | They have control. `TAKE control` on the ship's panel, or wait 90s for it to lapse. |
| Altitude order refused on a parked ship | It has no altitude to move *from* and none was given. Send an absolute altitude, or check it has an altitude sensor. |
| Terrain guard fires in clear air | The `ground` sensor is the forward-facing one. `configure` → Instruments, or swap them in `/craft.cfg`. |
| Cockpit shows `clear --` at altitude | The ground sensor cannot see that far. `probe --eyes` shows its range. The maximum is set on the sensor block itself, and the flight computer cannot raise it past that — it asks, and takes what it is given. |
| `configure` does not seem to save | **APPLY is at the bottom of the Review pane, below the fold.** Press **ENTER** on that pane instead — it writes everything without scrolling. Nothing is written until one or the other happens; leaving with `q` discards the lot, by design. |
| Ship says it cannot find the `navigation_table` | Almost always the pilot was started before the contraption was assembled. Fixed as of this version: the pilot now re-resolves its hardware whenever a peripheral attaches. If it persists, `probe --eyes` and `configure` → Instruments. |
| An instrument works in `setup` but not in `pilot` | Same cause, and this was the tell: `setup` and `configure` have always rescanned on attach, so they could see hardware the flying program had never resolved. |
| Nothing is ever surveyed | Same cause: surveying is built from the ground reading, so a ship that cannot see the ground records nothing. |
| A control shows **FAULT** on the ship panel | That peripheral is not answering. It has been broken off, or renamed, or was never on the contraption. |

## Tests

There is no Create Aeronautics outside the game, so the modules run against a
mock hull in an emulator. Either of two work.

**[CCEmuX](https://emux.cc/getting-started.html)** boots a computer whose root is
a directory, and runs that computer's `startup.lua`. This tree already has a real
`startup.lua` — it picks the pilot, the tower or the pocket by hardware and then
flies a ship — so copy the tree somewhere scratch and put the test shim in as the
startup:

```
cp -r aero/* /tmp/run/
cp /tmp/run/test/ccemux.lua /tmp/run/startup.lua
java -jar ccemux-launcher.jar -r TRoR -c /tmp/run
```

`-r TRoR` is the renderer that does not want a window. The shim calls
`os.shutdown()` at the end, without which the emulator sits at a shell prompt
forever and a finished suite looks exactly like a hung one.

**[CraftOS-PC](https://www.craftos-pc.cc/)** takes the runner directly:

```
CraftOS-PC --headless -d <datadir> --script <abs path>/test/run.lua
```

`--script` takes a **host** path, not a path inside the emulated filesystem.

Under either, results are written to `/test-summary.txt` and
`/test-*-results.txt` on the emulated computer rather than stdout, because
headless mode redraws the entire terminal on every update — and because an
uncaught error drops the emulator into its shell, where a crash and a hang look
identical from outside.

992 assertions. `spec.lua` covers each module on its own — the heading
arithmetic and the wrap, plans and legs, sensor fusion and the ageing of a
dead-reckoned fix, the PID loops and the integral clamp, every flight state and
all four guards, the hull abstraction over a mock of the real peripheral API, the
redstone layer over both a computer's own bus and a relay in all three signal
shapes, the quaternion attitude maths, the UI's layout arithmetic, `probe.lua`
round-tripped through the craft file it generates, the bounded log, the debounced state write, and the manifest against the tree. Three
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
