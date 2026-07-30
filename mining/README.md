# Remote Mining Turtle

CC: Tweaked programs for running a fleet of mining turtles: `miner.lua` on each
turtle, `server.lua` on an advanced computer at base, `remote.lua` on an advanced
pocket computer. They all talk over rednet on the `mining` protocol.

```
pocket (remote.lua) --- submit / cancel / command --> server (server.lua)
       \                                                  |
        \------------- direct fallback ----------------> turtles (miner.lua)
                                                          |
        <------------- status heartbeats -----------------+
```

The server owns the roster and the job queue, so work survives you putting the
pocket away. Give it an **ender modem**: wireless is about 64 blocks, and a plain
modem cannot hear a turtle at Y-50. Failing that, a computer running CC's own
`repeat` program between base and the mine relays rednet in both directions.

Only one server per fleet. A second one refuses to start rather than compete —
it claims the fleet name with `rednet.host`, so two servers dispatching to the
same turtles is caught at startup instead of showing up later as two turtles in
one lane. Any computer can find the server with
`rednet.lookup("<fleet>", "fleet")`.

Turtles stay autonomous. If the server is gone, the pocket says `DIRCT` in its
header and commands turtles itself — a server whose chunk unloaded must never
mean a turtle you cannot recall.

## Files

| Path | Runs on | Purpose |
| --- | --- | --- |
| `miner.lua` | turtle | command loop, job execution, heartbeat |
| `server.lua` | computer | fleet roster, job queue, dispatch, fleet table |
| `remote.lua` | pocket computer | fleet view, deploy, queue |
| `startup.lua` | all three | autostart; picks the right program for the host |
| `install.lua` | all | first-time install from GitHub |
| `update.lua` | all | pull the latest version and reboot |
| `lib/config.lua` | all | protocol name, junk/fuel filters, timings, margins |
| `lib/specs.lua` | all | pattern names, ranges and estimates (no `turtle` API) |
| `lib/fleet.lua` | server | roster, queue, assignment, region splitting |
| `lib/move.lua` | turtle | guarded movement, position tracking, fuel, inventory |
| `lib/state.lua` | turtle, server | crash-resumable state files |
| `lib/patterns.lua` | turtle | `quarry`, `tunnel`, `strip`, `stairs` traversal |
| `lib/veins.lua` | turtle | ore vein following |
| `lib/scanner.lua` | scout | geo scanner: scan, world coords, clustering |
| `test/` | CraftOS-PC | mock turtle and the test suite (see below) |

## Install

On each computer — turtle, pocket or server — run:

```
wget run https://raw.githubusercontent.com/Gizmo0320/CCprograms/main/mining/install.lua
```

The same tree goes on every machine. `startup.lua` works out what it is running
on, so there is one thing to install and no way to end up with the wrong half on
the wrong computer. The installer downloads everything before writing anything,
so a dropped connection leaves the old working copy rather than half a file; it
also labels the computer by role, which is what makes the fleet table readable.

It asks for a **fleet name**. Computers only talk to others on the same one, so
running two independent setups in one world is a matter of installing them with
different names — `north` and `south`, say. Press enter for the default.

There is no port number to set. `rednet.open` always opens the same two channels
— the computer's own id, and 65535 for broadcasts — and filters by protocol
string when a message is *received*. So the fleet name is the port in the sense
that matters: two fleets never act on each other's messages. They do still share
the airwaves, so a second fleet adds radio traffic and a `repeat` relay carries
both.

The name goes in `/fleet.cfg`, which is deliberately **not** in `manifest.txt` —
a per-fleet setting stored in a file the updater replaces would survive exactly
until the first update, and then quietly reunite two fleets meant to be apart.

`/fleet.cfg` overrides anything in `lib/config.lua`, not just the protocol:

```lua
return {
  protocol   = "mining-north",
  fuelMargin = 128,
}
```

For a fork, a branch, or an unattended install:

```
install.lua <branch> <owner/repo>
install.lua --fleet=north          skip the prompt
```

Pass `--fleet=` when scripting: without it the prompt waits for a line of input,
and unlike the reboot prompt at the end, `read()` cannot be given a timeout.

## Updating

On any computer:

```
update            fetch the latest and reboot
update --check    say what would change, and change nothing
```

It compares every file against the repo and writes only what differs, so
"already up to date" costs nothing but the download. As with installing, it
fetches everything before writing anything, and it only touches files listed in
`manifest.txt` — so `/fleet.cfg`, and which fleet this computer is on, survives
every update.

From the pocket, `UPDATE` on the fleet screen (or `u`) pushes it to every
turtle at once — updating a dozen turtles by hand is exactly the chore worth
automating. **A turtle refuses an update while it is working**, because swapping
`lib/move.lua` underneath a running quarry leaves it halfway down a hole running
half of two versions, and the reboot afterwards would abandon the job. Pause or
let the fleet finish, then update.

The server does not update itself from that push. It is one machine at your base
with a keyboard, and a bad push that takes out the thing coordinating the
recovery is a worse day than walking over and typing `update`.

Installing by hand instead: copy the tree to `/`. `lib/` must sit beside the
program that loads it, since CC:T resolves `require` relative to the program's
directory.

## Turtle setup

1. Advanced mining turtle with a **diamond pickaxe** and a **wireless modem**.
   Wireless (or ender) only — a wired modem is ignored.
2. Fuel in the inventory (coal, charcoal, coal blocks — see `config.fuel`), and
   **fuel in the chest at its start position**. Burning what it carries already
   happens automatically; the chest is where the next lot comes from, which is
   otherwise the thing that ends a long job.
3. **A chest next to the start position.** When the inventory fills, the turtle
   walks home, empties into it, walks back to the exact block it left and
   carries on. This is what lets a job run past sixteen stacks in a vanilla
   world. Any container works — chest, barrel, shulker box (`config.container`)
   — placed directly below, in front of, or above the turtle's start block.

   It only ever drops into a block it has confirmed is a container. Dropping at
   open air succeeds as far as `turtle.drop` is concerned and scatters the whole
   haul across the floor, which looks like a working unload right up until the
   items despawn.
4. Optional: an **EnderStorage ender chest** in the inventory. Carried rather
   than placed at home, so there is no walk: the turtle places it, empties into
   it, picks it back up and keeps mining.

   It has to be that chest specifically (see `config.dumpChest`). A portable
   dump has to send its contents somewhere else *and* drop itself when mined
   without silk touch. An ordinary chest or barrel fails the first test — its
   contents spill on the floor and the turtle picks them straight back up — and
   vanilla `minecraft:ender_chest` fails the second, shattering into obsidian
   and leaving the turtle with nowhere to dump for the rest of the job.
5. Optional: a GPS cluster in range. With GPS the turtle reports real world
   coordinates and re-derives its heading after a reboot by stepping one block
   and comparing fixes. Without it, the start position becomes `0,0,0` and the
   start facing becomes heading 0, and everything is dead reckoned from there.

Place the turtle at the **top-left corner** of the area you want dug, facing
along the depth axis. `quarry` drops one block down before it starts, so the
turtle's starting block stays clear as the return point.

## Patterns

| Pattern | Parameters | What it does |
| --- | --- | --- |
| `quarry` | width, depth, layers | Clears a rectangular volume straight down. |
| `tunnel` | width, length, height | Corridor at the turtle's own level, built upward. |
| `strip` | length, branch, spacing, height | Branch mining: one corridor with ribs off both sides every `spacing` blocks. The best ore per unit of fuel of any of these. |
| `stairs` | depth, width, headroom | A walkable staircase, one block down per block forward. |
| `harvest` | radius, max | Travel to a seam and follow it out. Normally queued by the server from a scout's report rather than submitted by hand. |
| `survey` | depth, radius, step | **Scout only.** Drop through open air scanning for ore, then climb back and report. |

`survey` runs on a scout; everything else runs on a miner. A turtle refuses a job
meant for the other kind rather than failing halfway through it, so the server
can hand it to something that can actually do it.

Only `quarry` and `tunnel` can be split into lanes — they have a footprint to
divide. A `strip` or `stairs` is already a line, so submitting one with more than
one lane is refused rather than quietly turned into several short corridors.

The anchor is the corner a job extends **south and west** from: every dispatched
job faces +z, and a quarry entered facing +z runs its depth along +z and shifts
its width along -x.

`tunnel`, `strip` and `stairs` also take **veins** (0 or 1). With it on, ore the
turtle exposes is chased to the end of its seam and then the turtle retraces its
way back to the row and carries on. It follows what it can *see* — ore sealed
behind a block it never breaks is not found — and it is bounded by
`config.veinMax` blocks and `config.veinRadius` from the row. Those caps are the
only thing standing between a turtle and an ore-lined ravine.

Spacing 3 is the classic branch-mining figure: it leaves two blocks of stone
between ribs, which is the widest gap that still puts every block within reach
of a mined face.

## Fleet setup

1. An advanced computer at base with an **ender modem**, running `server.lua`.
2. A **GPS cluster** in range — four computers with wireless modems, set up with
   the built-in `gps` program. Required for splitting an area between turtles:
   the server hands each one a world-coordinate corner, and a turtle without a
   fix refuses a placed job rather than navigating in a frame of its own
   invention.
3. Turtles placed at base, each with its own chest. They report in by
   themselves; there is nothing to register.
4. Optionally a **scout**: a turtle with an Advanced Peripherals geo scanner and
   a wireless modem. See below — it is a different animal from a miner.

## Scouts

A turtle has exactly **two upgrade slots**, and a miner already spends both on a
pickaxe and a wireless modem. So a geo scanner means giving something up, and
what it gives up is the pickaxe: **a scout cannot dig at all.**

That sounds like a limitation and is really the point. A scout travels through
open air, which makes its natural habitat the hole the miners have already made.
Drop it into a quarry, run `survey`, and it descends the shaft scanning the walls
at intervals — finding exactly the ore the lanes are about to reach or have just
missed. Started somewhere solid it scans once where it stands and comes back,
which is the honest outcome rather than an error.

What it finds becomes work:

```
scout runs survey        ore blocks, in world coordinates
      -> clusters them   one seam, not forty blocks
      -> server          one harvest job per seam
      -> a miner         travels there, follows the vein out
```

The seam-following at the far end is the same `lib/veins.lua` a `tunnel` uses, and
the travel is the same job `origin` a split quarry lane uses. Scanning mostly
wires existing parts together.

Worth knowing:

- **Scanning costs turtle fuel**, via `gs.cost(radius)`. `lib/scanner.lua` refuses
  a scan that would eat the fuel the scout needs to get home — the fuel guard in
  `lib/move.lua` cannot see it coming, because a scan is not a move.
- **Scan coordinates are relative to the scanner**, so a scout needs a GPS fix to
  turn them into anything the server can act on. The published docs do not
  actually say which frame it is, so `lib/scanner.lua` works it out at runtime by
  checking which origin the hits are consistent with.
- **Overlapping scans see the same seam repeatedly.** The server deduplicates
  against seams already queued, running or mined, so one seam is one job.
- **Single blocks are ignored** (`config.clusterMin`). A round trip for one lump
  of coal is not worth it; a passing miner's vein following gets it eventually.

## Running

The pocket has three screens, `TAB` to cycle. The header always says `SERVR` or
`DIRCT` so it is never ambiguous where a command went.

**FLEET** — a row per turtle: id, label, state, progress. Tap a row to target
just that one, tap it again to go back to `ALL`. `PAUSE` / `RESUME` /
`ABORT` / `RECALL` act on the target. `PAUSE` takes effect within one block, not
at the end of a layer; `ABORT` needs two presses.

**DEPLOY** — walk to the corner you want dug and press `SET` to stamp the anchor
from GPS, pick a pattern and sizes, set how many `Lanes` to split it into, and
`SUBMIT`. The line above the buttons is a fuel pre-flight for the whole job and
per lane. Tap any number to type it instead of clicking `+` forty times.

**QUEUE** — pending and running jobs. Tap one to cancel it; a running job's
turtle is recalled.

Keys: `p` `r` `a` `c` are pause, resume, abort, recall; `s` submits; `TAB`
changes screen; `q` exits.

Without a server, `DEPLOY` sends a plain relative job to the selected turtle,
exactly as this program did before there was a fleet, and `QUEUE` says so rather
than showing an empty list as though nothing were queued.

Standalone, no remote:

```
miner quarry 8 8 16          # width, depth, layers
miner tunnel 3 32 3 0        # width, length, height, veins
miner strip 32 8 3 2 1       # length, branch, spacing, height, veins
miner stairs 32 1 3 0        # depth, width, headroom, veins
```

Arguments are positional, in the order the pattern declares them, and are
validated against the same ranges the pocket computer enforces.

## Behaviour worth knowing

- **Fuel.** Before every move the turtle checks that it still has the Manhattan
  distance home plus `config.fuelMargin` in reserve. If not it burns whatever
  whitelisted fuel it is carrying, and if that is not enough it abandons the job
  and walks home while it still can. The state file survives, so refuelling and
  rerunning `miner` resumes the job.
- **A full inventory escalates.** Junk is dropped first, then a carried ender
  chest, then a walk home to the chest there. Only when all three fail does the
  turtle stop, keep its state file and wait to be emptied. A dump run demands
  fuel for the *round trip*, not just the leg home — a turtle that empties
  itself and then cannot get back out is worse off than one that stopped where
  it was.
- **Running low on fuel escalates the same way.** Burn what it carries, then
  walk home and take more from the chest, and only then stop. That run reserves
  only enough to get home *one way*, unlike a dump run: it happens precisely
  because fuel is short, so demanding a round trip would refuse at exactly the
  moment it is needed. The return leg is paid for out of what it collects.
  A turtle that has mined until it ran dry is usually also full, so it empties
  into the chest first to make room for the coal.
- **It tops up while it is already home.** A dump run that finds fuel below
  `config.fuelTopUp` fills the tank before heading back, because the turtle is
  standing at the chest anyway and a separate trip later costs the walk twice.
- **Resume granularity is one layer.** The state file is written at the top of
  each layer — or, for `strip`, at the corridor before each branch pair, never
  mid-branch. It records position, heading, serpentine direction and progress,
  so a chunk unload costs at most one layer of re-mining.
- **Bedrock and lava.** The turtle refuses to dig either. It tries to seal lava
  with a junk block. Anything it still cannot remove it rides over: it climbs a
  level, crosses, and drops back into the row as soon as there is a floor to
  drop into, leaving only the obstructing block unmined. A bedrock ridge lying
  across the whole row is fine — the turtle travels above it and comes back down
  on the far side.
- **The remote tells you before, not after.** Idle, the line under the progress
  bar is a fuel pre-flight: `needs ~3400, have 3204`, in red when short. Running,
  it is the count, the rate and an ETA. Running out of fuel is the most common
  way a job dies and it is knowable before you press START.
- **Link loss is expected.** The turtle keeps mining with nothing attached. The
  pocket marks a turtle `lost` after 6 seconds without a heartbeat rather than
  displaying stale numbers, and falls back to `DIRCT` if the server goes quiet.
- **A dispatched job is a waypoint, not a new home.** The turtle travels to the
  corner the server gave it, mines, and returns to the block you placed it on —
  that is where its chest is. The server therefore does its own fuel pre-flight
  including the round trip, because the turtle's own guard only ever reserves a
  one-way walk to a home it thinks it never left.
- **A job whose turtle goes quiet is not reassigned.** It is most likely still
  mining in an unloaded chunk, and two turtles in one lane is worse than one
  stalled job. A turtle that comes back *idle* is a different matter: that work
  did not happen, so the job is requeued, up to `config.jobRetries` times.
- **A turtle that has just been given a job still says it is idle** for a moment.
  `config.dispatchGrace` is how long the server waits before believing that,
  which is what stops a heartbeat that was already in flight from causing the
  same lane to be handed out twice.
- **A turtle that cannot get home says so.** Every job outcome ends in a walk
  home whose result is checked. If it does not arrive, the turtle reports
  `stranded at x,y,z`, writes the reason to the state file and stays in the
  `error` state rather than reporting itself idle and clearing its job.

## Tests

The mining logic runs against a mock turtle and a mock world under
[CraftOS-PC](https://www.craftos-pc.cc/), which has no `turtle` API of its own.
Copy the tree to a computer directory and run:

```
CraftOS-PC --headless -d <datadir> --script <abs path>/test/run.lua
```

`--script` takes a **host** path, not a path inside the emulated filesystem.
Results are written to `/test-results.txt` on the emulated computer rather than
stdout, because headless mode redraws the entire terminal on every update.

`fleet_spec.lua` needs no emulated world at all, because `lib/fleet.lua` touches
no APIs. It checks that lanes tile a volume exactly — no overlap, no gap, block
totals adding back up — for splits that divide evenly and that do not, that
assignment skips busy, stale and low-fuel turtles, and that reconciliation
requeues a lost job but gives up at the retry cap instead of cycling it through
the whole fleet.

`server_spec.lua` runs `server.lua` itself against a scripted conversation and
inspects what it puts on the wire: a submit is split and dispatched, the same job
is never sent twice, commands are relayed, and a cancelled job's turtle is
recalled.

`spec.lua` covers footprint coverage and the serpentine carry between layers,
degenerate sizes, bedrock (single blocks and full-width ridges), lava sealing,
the fuel and inventory guards, all three unload routes, `strip` and `stairs`
geometry, vein following and its caps, walking home, the state file round trip,
resuming from a mid-job checkpoint, and parameter validation.

It also runs the scanner against a mock geo scanner that can be told to report
either coordinate frame, so the runtime detection is tested both ways rather than
only the way we expect. A scout is run down a mock shaft to check it scans, finds
the seams in the walls, ignores single blocks, mines nothing, and climbs back.

It also runs each pattern against the mock and compares the result to
`specs.estimate`. An estimate nobody checks drifts the moment a pattern changes,
and a wrong pre-flight number is worse than none — it is the number the player
decides whether to walk away from the turtle on.

`remote_spec.lua` drives `remote.lua`'s real event loop with queued events and
inspects the rednet traffic it produces. It proves `draw()` survives every screen
and pattern it can be asked to render, that `SERVR` and `DIRCT` route commands to
different places, that a submit is something the server's own splitter accepts,
and that the layout never writes past row 20 or column 26 — every case runs at
pocket dimensions, because a click at column 24 lands somewhere else entirely on
the emulator's 51 column terminal.

Each fixture rebuilds the whole module graph and then proves the new mock is
really wired up before running its case — a half-reset harness silently leaves
the pattern code driving the *previous* world, which looks like a passing test.

## Known limits

- Turtles cross each other's paths going to and from base. They will not dig
  each other (`config.unbreakable` lists both turtle blocks) and `move.detour`
  climbs over an obstruction, and lanes are disjoint so they never contend while
  mining. But two turtles trying to climb over each other at the same moment can
  oscillate until one gives up. Staggered dispatch keeps it rare rather than
  solving it.
- The server does not chunk-load anything. Turtles in unloaded chunks freeze;
  they show as `lost` and pick up where they left off when the chunk reloads.
- Resume from a checkpoint re-mines the partial layer that was in progress.
- Riding over an obstruction handles bedrock and unsealable lava, but nothing
  paths *around* a wall: a block the turtle can neither remove nor climb over
  ends the job.
- Vein following only chases ore the turtle actually exposes. It is a flood fill
  from a block it can see, not a survey of what is nearby.
- `quarry` has no veins option because it removes every block in its footprint
  anyway.
- Estimates cannot predict backtracking, so a job full of bedrock or a `veins`
  run will use more fuel than the pre-flight figure suggests.
- A scout cannot dig, so it can only survey where there is already air. It finds
  ore beside a quarry or a tunnel, not ore under untouched ground.
- The ore map is a snapshot. A seam reported and then mined by a passing turtle
  still has a harvest job queued against it; the miner arrives, finds nothing,
  and comes home having spent the trip.
