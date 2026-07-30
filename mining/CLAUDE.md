# Project: CC: Tweaked Mining Turtle Fleet

## What this is

Three Lua programs for the CC: Tweaked Minecraft mod:

- `miner.lua` — runs on an **advanced mining turtle**. Executes mining patterns.
- `server.lua` — runs on an **advanced computer** at base. Owns the fleet roster and job queue, dispatches work, shows a fleet table on its terminal and any attached monitor. Wants an ender modem for range.
- `remote.lua` — runs on an **advanced pocket computer**. Three screens: fleet, deploy, queue.

`miner.lua` runs two roles off the same code. A turtle has exactly two upgrade slots: a **miner** spends them on a pickaxe and a wireless modem, a **scout** on an Advanced Peripherals geo scanner and a wireless modem. Carrying a scanner is what makes a turtle a scout, and it is also what makes it unable to dig — `move.canDig` is false for scouts, so a blocked move fails immediately instead of burning the whole retry budget attacking thin air.

All three communicate over rednet using the protocol name `"mining"`.

Normal routing is pocket → server → turtles. Turtles keep their own listener, so the pocket falls back to commanding them directly when no server answers — a server whose chunk unloads must never mean a turtle nobody can recall.

## Environment constraints

- Runtime is **Cobalt** (~Lua 5.2 with some 5.3 features). No LuaJIT, no FFI, no `io.popen`, no OS access outside the sandboxed CC filesystem.
- Available APIs: `turtle`, `rednet`, `peripheral`, `parallel`, `os.pullEvent`, `fs`, `textutils`, `term`, `gps`, `settings`, `keys`.
- Advanced hardware means color (`term.setTextColor`) and `mouse_click` events are available. Take advantage in `remote.lua`.
- `textutils.serialize` / `unserialize` for state files. `textutils.serializeJSON` only if something outside the game needs to read it.
- Wireless modem range is limited (~64 blocks for basic, more with ender modems, scales with altitude). Assume the link **will** drop and design for it.

## Architecture

### Message protocol

Every rednet message is a table with a `type` field. Everything speaks the one protocol and is disambiguated by `type`, which is what lets the pocket fall back to talking to turtles directly with no second channel to maintain.

Pocket -> turtle:
- `{type="start", pattern=<string>, ...params}` — the parameter keys are
  whatever the pattern declares in `lib/specs.lua` (`w/d/h` for quarry and
  tunnel, `length/branch/spacing/height/veins` for strip, and so on). The
  message is validated with `specs.readParams` before it reaches pattern code.
- `{type="pause"}` / `{type="resume"}` / `{type="abort"}`
- `{type="status"}` (explicit request)
- `{type="return"}` (come home now, abandon job)
- `{type="update", branch=<string>, repo=<string>}` — run update.lua and reboot. Refused while mining or returning: swapping `lib/move.lua` underneath a running quarry leaves a turtle halfway down a hole running half of two versions. The updater runs *after* `parallel.waitForAny` returns, never from inside the listener, because rebooting out of one branch while a job unwinds in another is how a half-written state file happens.

A `start` may also carry `origin={x,y,z}`, `facing=<0-3>` and `jobId=<string>`. The origin is a **waypoint, not a new home**: `move.home` stays the block the player placed the turtle on, because that is where its dump chest is. A turtle with no GPS fix refuses a job carrying an origin rather than navigating an absolute coordinate in its own dead-reckoned frame.

Pocket -> server:
- `{type="submit", pattern=<string>, params=<table>, anchor={x,y,z}, lanes=<n>}`
- `{type="cancel", jobId=<string>}`
- `{type="command", target=<turtle id|"all">, action="pause"|"resume"|"abort"|"return"}`
- `{type="fleet?"}` (discovery)

Server -> all:
- `{type="fleet", turtles={...}, jobs={...}, counts={...}}` broadcast every ~2s

Scout -> server:
- `{type="ore", clusters={{x,y,z,count,name},...}, blocks=<n>, scans=<n>}` — after a survey. The server deduplicates against seams already queued, running or mined, and turns what is left into `harvest` jobs.

Turtle -> pocket and server:
- `{type="status", pos={x,y,z}, heading=<0-3>, fuel=<n>, mined=<n>, state=<string>, pattern=<string>, progress=<n>, done=<n>, total=<n>, dumps=<n>, jobId=<string>, role="miner"|"scout"}`
- `{type="error", reason=<string>}`
- `{type="ack", of=<string>}`

The turtle broadcasts an unsolicited `status` every ~2 seconds so the pocket UI renders the latest heartbeat instead of polling. Pocket should show a clear "CONNECTION LOST" state if no heartbeat arrives for ~6 seconds.

### Turtle concurrency

`turtle.dig` / `turtle.forward` block, so a single event loop cannot mine and listen simultaneously. Use:

```lua
parallel.waitForAny(miningTask, listenerTask)
```

A shared control table (`ctl.paused`, `ctl.abort`, `ctl.returnHome`) is written by `listenerTask` and checked by `miningTask` after every move. This is what makes pause feel immediate rather than deferred to the end of a layer.

### Movement layer (build this first)

Pattern code must never call `turtle.forward()` etc. directly. Wrap all movement:

- **Retry on failure.** Mob blocking -> `turtle.attack()` then retry. Gravel/sand -> dig again, it refills. Cap retries and surface an error rather than looping forever.
- **Position tracking.** Maintain `{x, y, z, heading}` in memory. Calibrate against `gps.locate()` at startup if a GPS cluster is reachable; otherwise dead-reckon from a user-supplied origin.
- **Fuel guard.** Before each move, check `turtle.getFuelLevel()` against the cost of returning home. Escalate the same way the inventory guard does: burn carried fuel, then walk home and take more from the chest, and only then raise the signal. A fuel run reserves **one way**, not a round trip — it happens because fuel is short, so demanding enough to get back would refuse exactly when it is needed. `move.dumping` is what stops the guard re-entering the run that walks home through `move.step`.
- **Inventory guard.** When slot 16 is occupied, escalate: drop filtered junk (a config table), then a carried ender chest, then walk home to the container there and come back to the exact block and heading it left. A dump run must reserve fuel for the round trip, not just the leg home.
- **Bedrock and lava handling.** `turtle.inspect()` before digging; refuse to dig into lava and try to seal it with a junk block. Anything still unbreakable is ridden over — climb, cross, drop back into the row when there is a floor to drop into — rather than treated as a hard stop. Never dig blind, including upward: lava above pours onto the turtle the instant the block goes.

### State persistence

Chunk unloads and server restarts kill mid-job turtles. Write `{pos, heading, pattern, params, progress, mined}` to `/miner.state` after each completed layer (not each block). On startup, detect an unfinished job and resume it. Include a `startup.lua` so resume happens without human interaction.

### Patterns

`quarry` and `tunnel` share a serpentine layer traversal (no wasted travel between layers); `strip` and `stairs` share a corridor traversal. All four register into a table keyed by name, and adding another needs only a spec in `lib/specs.lua` and a `run` in `lib/patterns.lua` — the protocol carries arbitrary parameter keys already.

Every spec also carries an `estimate(params)` returning `{cells, moves, fuel}`. Keep it in step with the traversal: `test/spec.lua` runs each pattern against the mock and fails if the estimate drifts more than 20% from the real move count.

### Geo scanner

`lib/scanner.lua` wraps the Advanced Peripherals geo scanner. Three things about it drive the design:

- Scanning costs **turtle fuel** (`gs.cost(radius)`), and `lib/move.lua`'s fuel guard cannot see it coming because a scan is not a move. The scanner does its own reserve check.
- There is a **cooldown**; `scan()` returns nil plus a reason. That is a wait, not a failure — retry before reporting anything wrong.
- Coordinates come back **relative to the scanner**. The published docs do not state this either way, so the frame is worked out at runtime by checking which origin the hits are consistent with, rather than trusting anyone's reading of it. `scanner.frame` caches the answer.

Specs carry a `role` field. `fleet.assign` filters on it, and `miner.lua` refuses a job for the other role outright — a scout cannot quarry and a miner cannot scan, so that is not a slow job, it is an impossible one.

### Fleet

`lib/fleet.lua` holds every decision: roster staleness, the job queue, which turtle gets which job, how a volume is split into lanes, and what a heartbeat that disagrees with the queue means. It touches **no APIs** — no rednet, no turtle, no term — for the same reason `lib/specs.lua` does not: so it can be tested without an emulated world, and so `server.lua` is left as loops and drawing. Time is passed in rather than read from `os.clock()`, so staleness is testable without sleeping.

Two timing constants earn their keep and are easy to get wrong:

- `config.dispatchGrace` — a turtle that has just been given a job still reports `idle` for a moment, because its next heartbeat may already have been in flight. Believing that heartbeat means dispatching the same lane to a second turtle.
- `config.staleAfter` — a turtle out of contact keeps its job. It is most likely still mining in an unloaded chunk, and two turtles in one lane is worse than one stalled job. Only a turtle that comes back *idle* gets its work requeued.

## Suggested build order

1. Movement wrapper + position tracking + fuel/inventory guards (`lib/move.lua`)
2. State persistence (`lib/state.lua`)
3. Quarry pattern on top of the movement layer
4. rednet listener + `parallel` integration in `miner.lua`
5. Pure fleet logic (`lib/fleet.lua`), then `server.lua` over it
6. `remote.lua` UI last — it only renders what the protocol already provides

## Install and update

`install.lua` and `update.lua` both download the list in `manifest.txt` and then
the files in it. `test/spec.lua` checks that manifest against the repo in both
directions, so adding a library and forgetting the manifest is a test failure
here rather than a `require` error on someone else's turtle.

Both fetch everything before writing anything, and both cache-bust: raw
GitHub serves a stale copy for a few minutes, and an update that hands back the
version you already have is a baffling way to lose an afternoon.

## Testing

There is no `turtle` API outside the game, so `test/` supplies a mock turtle and
a mock world and runs the real modules against them under CraftOS-PC. See the
Tests section of `README.md` for the command.

Four things to know before adding cases:

- `--script` takes a **host** path, not a path inside the emulated filesystem.
- An uncaught error drops CraftOS into its shell, which blocks until the process
  is killed, so a crash looks exactly like a hang. `test/run.lua` wraps every
  suite in `pcall` for that reason.
- CraftOS-PC's emulated modem reports `isWireless() == false`, and every program
  here accepts wireless only. The suites shim `peripheral.call` rather than
  loosening the programs to suit the emulator.
- UI tests must force the terminal to **26x20**. The headless terminal is 51
  wide and layouts are relative to screen width, so a click at column 24 lands
  somewhere completely different.

## Style notes

- Prefer small module files under `lib/` returning a table, loaded with `require`. CC:T supports `require` from the program's directory.
- Every turtle action returns `success, reason` — check both. Silent failures are the main source of turtles wandering off into caves.
- Fail loud: broadcast an `error` message and write the reason to the state file before halting.
