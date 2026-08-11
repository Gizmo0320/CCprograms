# Project: CC: Tweaked Redstone Control Network

## What this is

Three Lua programs for the CC: Tweaked Minecraft mod:

- `node.lua` — runs on **any computer wired to redstone**. Owns that computer's
  ports, evaluates its own rules, reports state.
- `server.lua` — runs on an **advanced computer** at base. Holds the node
  roster, named scenes, cross-node rules and the event log; draws a dashboard on
  its terminal and any attached monitor. Wants an ender modem for range.
- `remote.lua` — runs on an **advanced pocket computer**. Four screens: panel,
  rules, scenes, log.

All three communicate over a raw modem channel via `lib/net.lua` — not rednet.
The channel is configurable per network, which is what lets several independent
setups share a world. This is the same net layer as `mining/`, deliberately
copied rather than shared: each directory installs and updates on its own, and a
shared root library would mean an update to one program rebooting the other.

Normal routing is pocket → server → nodes. **Nodes keep their own listener and
their own rules**, so the pocket falls back to commanding them directly when no
server answers, and a node's local automation keeps running with the server's
chunk unloaded. A door that only opens when a computer three hundred blocks away
is loaded is worse than no door.

## Environment constraints

- Runtime is **Cobalt** (~Lua 5.2 with some 5.3 features). No LuaJIT, no FFI, no
  `io.popen`, no OS access outside the sandboxed CC filesystem.
- Available APIs: `redstone`, `peripheral`, `parallel`, `os.pullEvent`, `fs`,
  `textutils`, `term`, `settings`, `keys`, `colours`.
- Advanced hardware means colour and `mouse_click`/`monitor_touch` are
  available. Take advantage in `remote.lua` and the server dashboard.
- Wireless modem range is limited and chunks unload. Assume the link **will**
  drop and design for it.

### What the redstone API actually gives us

Four things drive the whole port design:

- Three signal shapes on the same six sides: **digital** (`setOutput`/
  `getInput`, boolean), **analog** (`setAnalogOutput`/`getAnalogInput`, 0–15,
  which is what a comparator reads out of a chest or a furnace), and **bundled**
  (`setBundledOutput`/`getBundledInput`, a 16-bit colour mask).
- The `redstone` event carries **no side and no value**. It says only that
  something changed. Every read is therefore a poll of all six sides, and edge
  detection has to be done here rather than taken from the event.
- An output is **held by the computer**, not by the world. Outputs are restored
  from disk on boot, or every lamp in the base goes dark on a server restart.
- Bundled cable needs a mod that provides it (Project Red and friends). A
  network with no bundled cable must still work, so bundled ports are optional
  and their absence is a warning, not a crash.

## Architecture

### Ports

A **port** is the unit everything else names. Not a side: "kitchen-lamp" is what
you want on a button, and it may be colour 3 of a bundled cable on the back.

```lua
{ name = "kitchen-lamp", side = "back", colour = colours.lime,
  dir = "out", kind = "bundled", invert = false, label = "Kitchen lamp" }
```

- `kind` is `digital` | `analog` | `bundled`, and decides which API call is used.
- `colour` is required for `bundled` and meaningless otherwise.
- `dir` is `in` | `out`. A port is one or the other: CC reports its **own**
  output back from `getOutput`, so a port that tried to be both would read its
  own signal and latch itself on.
- `invert` is at the port, not in every rule that touches it. A daylight sensor
  wired the wrong way round should be fixed once.

Ports live in `/ports.cfg`, a Lua file returning a list. It is **not** in
`manifest.txt`, for the same reason `/redstone.cfg` is not: `update` replaces
every file it lists, and wiring is per-computer.

`lib/ports.lua` is the only module that touches the `redstone` API. It caches
the last read of every side so a rule sweep is one poll rather than one call per
port, and so edge detection has a previous value to compare against.

### Rules

A rule is **data**, not code — it has to cross the wire, be edited on a pocket
computer and survive a reboot:

```lua
{ id = "night-lights", enabled = true,
  when = { port = "daylight", op = "<", value = 4 },
  act  = { port = "lamps", set = true }, hold = 2 }
```

- `when` is one condition or `{all = {...}}` / `{any = {...}}` / `{none = {...}}`
  nested. `op` is one of `on` `off` `==` `~=` `<` `>` `<=` `>=` `changed`
  `rising` `falling`.
- `act` sets a port, pulses it (`pulse = 0.5`), or runs a scene.
- `hold` is a **debounce in seconds**: the condition must hold that long before
  the action fires. Without it a flickering comparator on a fill level toggles a
  hopper line hundreds of times a second, and the `redstone` event fires for
  every one.

The field names are `act` and `hold` rather than `then` and `for`, which are
Lua keywords and would need quoting at every use site.

An action fires on the **transition** into satisfied, not for as long as the
condition holds. A rule that re-set its port every sweep would fight anything
else touching it — including you, from the pocket computer — and the light
could never be turned off while the sun was down.

`lib/rules.lua` evaluates them and touches **no APIs** — no redstone, no net, no
term — for the same reason `mining/lib/fleet.lua` does not: so it can be tested
without an emulated world. It is handed a table of port readings and the current
time and returns a list of actions; the caller applies them. Time is passed in
rather than read from `os.clock()`, so debounce is testable without sleeping.

Two failure modes it has to prevent outright, both of which are pure logic and
so belong here rather than in `node.lua`:

- **Feedback loops.** A rule whose action changes a port that its own condition
  reads will fire forever. Actions are applied as one batch per sweep and a port
  written this sweep is not re-read until the next, which turns an infinite loop
  into an oscillation at sweep rate — and `rules.check` refuses to save a rule
  that is self-referential in the first place.
- **Contradiction.** Two enabled rules driving one port to different values in
  the same sweep is a wiring mistake, not something to resolve by ordering.
  `rules.conflicts` finds them so the UI can show it before it is saved.

### Logic blocks

`lib/logic.lua` holds the composable pieces that a single condition cannot
express, because all of them are memory: a `gate` (and/or/not/xor/nand/nor), an
RS `latch`, a `toggle` (a button that alternates rather than follows), a `pulse`
extender, a two-sided `delay`, a gated `blink` clock and a `counter`.

Each is a **pure state machine** — `step(st, inputs, now, params)` returning
`st, output`, with all of its memory in `st` and nothing read from the world —
so a latch meant to stay set across a reboot is just a table written to disk,
and the whole set is testable as arithmetic.

An instance is data, like a rule, with `wire` mapping the block's input names to
port names:

```lua
{ id = "front-door", kind = "latch", out = "door",
  wire = { set = "doorbell", reset = "close-button" } }
```

Unlike a rule, a block emits its output **every sweep** rather than on a
transition: a block *is* the state of its output, and one that stopped saying so
would be left contradicting the wire the moment anything else touched it.
`ports.apply` drops writes that change nothing, so this costs no traffic.

Blocks register into a table keyed by name; adding another needs a `step` and an
entry in the spec table `remote.lua` builds its editor from.

### Scenes

A **scene** is a named set of port values applied together: `"night"` sets six
ports across four computers. Scenes live on the server, because the point of
them is that they span nodes. Applying one is a fan-out of ordinary port
commands, so a node that is offline when a scene fires simply misses it and the
server records that in the log rather than blocking the other five.

### State persistence

Two files, deliberately separate:

- `/redstone.state` on a node: current outputs, latch states, rule debounce
  timers. Written on change, **debounced to at most once a second** — a pulse
  rule firing at 20Hz would otherwise write the disk raw.
- `/network.state` on the server: roster, scenes, cross-node rules, log.

Outputs are restored **before** the listener starts, so a reboot does not
announce a state it has not applied yet.

### The log

`lib/log.lua` is a ring buffer of `{t, node, port, from, to, why}`. `why` is the
rule id, `"manual"`, or the scene name — the question being asked when someone
opens it is always "what turned that off", and a log that records the change but
not the cause does not answer it.

Bounded at `config.logSize` entries. It is the one thing here that grows without
limit if left alone, and a computer that fills its disk stops being able to
write its state file.

### Concurrency

`node.lua` runs `parallel.waitForAny(sweepTask, listenerTask)`. The sweep is
driven by the `redstone` event *and* a timer: the event covers input changes,
the timer covers everything time-based (debounce expiry, pulse ends, repeat
timers), which no event will ever announce.

### Message protocol

Every message is a table with a `type` field, carried in a `lib/net` frame.

Pocket → node (and server → node):
- `{type="set", port=<name>, value=<bool|0-15>, why=<string>}`
- `{type="pulse", port=<name>, secs=<n>}`
- `{type="ports?"}` — describe yourself; how the pocket learns what exists
- `{type="rule", action="add"|"remove"|"enable"|"disable", rule=<table>}`
- `{type="rename", name=<string>}` — set the computer label
- `{type="update", branch=<string>, repo=<string>}` — run update.lua and reboot

Pocket → server:
- `{type="scene", name=<string>}` — apply
- `{type="scene!", name=<string>, ports={...}}` — define
- `{type="net?"}` (discovery)
- `{type="log?", n=<n>}`

Server → all:
- `{type="net", nodes={...}, scenes={...}}` broadcast every ~2s

Node → pocket and server:
- `{type="state", ports={[name]={value,dir,kind}}, rules=<n>, label=<string>}`
  broadcast every ~2s and immediately on any change. Unsolicited, so the pocket
  renders the latest heartbeat instead of polling.
- `{type="event", port=<name>, from=<v>, to=<v>, why=<string>}` — one line for
  the log, sent when it happens rather than waiting for the next heartbeat.
- `{type="error", reason=<string>}`

No heartbeat for ~6s and the pocket shows **CONNECTION LOST** for that node. It
must never show a stale value as though it were live: the whole job of this
program is telling you what is on right now.

An `update` is refused while a pulse or a debounce timer is pending, the same
way a miner refuses one mid-job — swapping `lib/ports.lua` underneath a
half-finished pulse leaves an output stuck on. The updater runs *after*
`parallel.waitForAny` returns, never from inside the listener.

### Configuration

`lib/config.lua` holds the defaults. `/redstone.cfg` is a Lua file returning a
table that overrides any of them, written by `install.lua` and editable by hand.
Like `mining/`, it is deliberately **not** in `manifest.txt`.

`config.channel` is the port and the real isolation; `config.protocol` rides in
every frame as a second check. Default channel 2718, so a mining fleet and a
redstone network in one world do not have to be told about each other.

`/redstone.cfg` also carries `role`. Unlike `mining/`, hardware cannot tell a
node from a server — both are plain computers — so `install.lua` asks and
records the answer. `server.lua` still asks "server?" on startup and stands
down if anything answers, because two servers would both fan out scenes and
both write the log.

## Suggested build order

1. `lib/ports.lua` — the port abstraction and the polling cache
2. `lib/state.lua` — persistence, with the write debounce
3. Pure rule evaluation (`lib/rules.lua`) and `lib/logic.lua`
4. `node.lua` — listener + sweep under `parallel`
5. `lib/log.lua`, then `server.lua` over it
6. `remote.lua` UI last — it only renders what the protocol already provides

## Testing

There is no `redstone` API outside the game, so `test/mockredstone.lua` supplies
a bus and the real modules run against it under CraftOS-PC. See the Tests
section of `README.md` for the command. Five suites, run in that order by
`test/run.lua`:

| Suite | What it covers |
| --- | --- |
| `spec.lua` | every module on its own, plus the manifest against the tree |
| `node_spec.lua` | node.lua's two loops: orders, pulses, rules, updates |
| `server_spec.lua` | server.lua's loop: roster, log, scene fan-out, the dashboard |
| `remote_spec.lua` | remote.lua's loop: both link modes, every screen, the editor |
| `install_spec.lua` | install.lua: fetching, the prompts, the files it leaves |

`lib/rules.lua`, `lib/logic.lua` and `lib/scenes.lua` need no mock at all — they
touch no APIs, which is most of the reason they are shaped that way.

Things to know before adding cases:

- `--script` takes a **host** path, not a path inside the emulated filesystem.
- An uncaught error drops CraftOS into its shell, which blocks until the process
  is killed, so a crash looks exactly like a hang. `test/run.lua` wraps every
  suite in `pcall` for that reason.
- CraftOS-PC's emulated modem reports `isWireless() == false`, and every program
  here accepts wireless only. `spec.lua` shims `peripheral.call` to test
  `net.open` rather than loosening the program to suit the emulator; the three
  program suites replace `net.open` outright and never touch a modem.
- The three program suites script the real event loops by queueing events
  before `dofile` and reading the wire afterwards. Two of the events are the
  harness's own — `rs_test_clock` and `rs_test_input`/`rs_test_snap` — and they
  are picked up by a wrapper around `net.decode`, the one function every loop
  calls for every event. In `node.lua` the sweep coroutine runs *before* the
  listener for any one event, so a clock or input event lands on the **next**
  one; that is why cases follow them with a `redstone`.
- Every case ends with a queued `terminate`, which unwinds a program however it
  happens to be sitting. Waiting for it to stop on its own turns a bug into a
  hang.
- `server.lua` and `remote.lua` clear the terminal on their way out, so anything
  read afterwards is blank. Screens are captured mid-run with `rs_test_snap`.
- UI tests must force the terminal to **26x20** for the pocket computer. The
  headless terminal is 51 wide and layouts are relative to screen width, so a
  click at column 24 lands somewhere completely different. Both UI suites draw
  into a `window` of the right size, which also gives `getLine` to read back.
- Text on screen is cut to the column it is drawn in. Assert on what fits, not
  on the whole string.
- CC's `write` calls `term.write` once per **word**, so a recording terminal has
  to join its segments with nothing between them or every phrase comes back cut
  in half. `install_spec.lua` reads the installer's messages that way; the two
  UI suites read a window with `getLine` instead, which does not have the
  problem.
- A write that changes nothing is never made, so an output that was never driven
  reads `nil` on the mock bus, not `false`.
- `install_spec.lua` runs last and writes to the computer root the tree under
  test lives in. Its stubbed `http` serves files out of that same tree, so a
  successful install rewrites every file with the bytes it already had; a case
  that wants a *failed* download names a path that is not there rather than
  serving different content.
- Watch for `x and x.field or default` where the field can be `false`. It is
  always `default`, and it has already been a bug twice here -- once in
  `node.lua`'s pulse restore, once in this suite's own http stub.

## Style notes

- Prefer small module files under `lib/` returning a table, loaded with
  `require`. CC:T supports `require` from the program's directory.
- Fail loud: broadcast an `error` message and write the reason to the state file
  before halting.
- A malformed `/ports.cfg` or `/redstone.cfg` is ignored with a warning, never
  fatal. Every program requires config at load, so throwing would brick the
  computer with no way back in.
