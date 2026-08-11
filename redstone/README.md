# Redstone control network

Named redstone ports, rules that switch them for you, scenes that switch a lot
of them at once, and a pocket computer to do it by hand — across as many
computers as you like.

Three programs, one install:

| Program | Runs on | What it does |
| --- | --- | --- |
| `node.lua` | any computer wired to redstone | Owns that computer's ports and runs its own rules |
| `server.lua` | an advanced computer at base | Node roster, scenes, the log, a monitor dashboard |
| `remote.lua` | an advanced pocket computer | Panel, scenes, rules, log |

A node needs nothing else to be running. The server holds the things that span
computers, but a node runs its own rules and answers the pocket directly, so the
base server's chunk unloading costs you the dashboard — not the lights.

## Install

On every computer, node and server and pocket alike:

```
wget run https://raw.githubusercontent.com/Gizmo0320/CCprograms/main/redstone/install.lua
```

It asks four things: the network name, the modem channel, whether this is a
node or the server, and a name for this computer. A pocket computer is always
the remote and is not asked.

Every computer needs a **wireless modem**. An ender modem on the server is worth
it — range is what decides whether a scene reaches the far shed.

Unattended:

```
install --net=base --channel=4200 --role=node --name=Kitchen
```

To update later, on any computer: `update`, or `update --check` to see what
would change without changing it.

## Wiring: `/ports.cfg`

A **port** is what everything else names. Not a side — `kitchen-lamp` is what you
want on a button, and it may be colour 3 of a bundled cable on the back.
`install.lua` leaves an example here; edit it to match your wiring and reboot.

```lua
return {
  { name = "lamp",   side = "top",   dir = "out", kind = "digital",
    label = "Ceiling lamp" },
  { name = "button", side = "front", dir = "in",  kind = "digital" },
  { name = "level",  side = "left",  dir = "in",  kind = "analog" },

  { name = "porch",  side = "back",  dir = "out", kind = "bundled",
    colour = colours.lime },
  { name = "garage", side = "back",  dir = "out", kind = "bundled",
    colour = colours.red },
}
```

| Field | |
| --- | --- |
| `name` | What rules, scenes, the log and the pocket call it |
| `side` | `top` `bottom` `left` `right` `front` `back` |
| `dir` | `in` or `out`, never both |
| `kind` | `digital` (on/off), `analog` (0–15, what a comparator reads), `bundled` (one colour of a cable) |
| `colour` | Required for `bundled`, meaningless otherwise |
| `invert` | Optional. Fixes a backwards daylight sensor once, here |
| `label` | Optional display name |

**One side carries one signal**, so everything on a side has to agree: all `in`
or all `out`, and all the same `kind`. Only `bundled` may have more than one
port on a side. A port cannot be both directions — ComputerCraft hands a
computer's own output straight back from `getInput`, so a port that tried would
latch itself on and never let go.

Bundled cable needs a mod that provides it (Project Red and friends). Everything
else works without one.

`/ports.cfg` is not replaced by `update`. Neither is `/redstone.cfg` or
`/rules.cfg`.

## Rules: `/rules.cfg`

A rule is *when this, do that*. Nodes evaluate their own, so they keep working
with the server down.

```lua
return {
  rules = {
    { id = "night-lights", enabled = true,
      when = { port = "daylight", op = "<", value = 4 },
      act  = { port = "lamps", set = true },
      hold = 2 },
  },
}
```

- `when` is one condition, or `{ all = {...} }` / `{ any = {...} }` /
  `{ none = {...} }` nested as deep as you like.
- `op` is `on` `off` `==` `~=` `<` `>` `<=` `>=` `changed` `rising` `falling`.
- `act` is `{ port = ..., set = ... }`, `{ port = ..., pulse = 0.5 }` (seconds),
  or `{ scene = "night" }`.
- `hold` is a debounce in seconds — the condition must stay true that long
  before anything happens. Put one on anything watching a comparator: a fill
  level flickering between 6 and 7 will otherwise toggle a hopper line as fast
  as the computer can manage.

A rule fires on the **transition** into true, not continuously. That is what
lets you turn a light off by hand while the rule that turned it on is still
satisfied.

Two rules driving one port to different values is refused when you try to save
it, and so is a rule that sets the port it watches — that one never stops.

## Logic blocks

For the things a single condition cannot express, because all of them are
memory. Same file, under `blocks`:

```lua
blocks = {
  { id = "porch", kind = "toggle", out = "porch-light",
    wire = { input = "button" } },

  { id = "door", kind = "latch", out = "piston",
    wire = { set = "doorbell", reset = "close-button" } },
}
```

| Kind | Inputs | Does |
| --- | --- | --- |
| `gate` | any number | `and` `or` `not` `xor` `nand` `nor`, set by `params.op` |
| `latch` | `set`, `reset` | Stays on until reset. Reset wins a tie |
| `toggle` | `input`, `reset` | A button that alternates rather than follows |
| `pulse` | `input` | A press becomes `params.secs` of output. Retriggerable |
| `delay` | `input` | Follows the input, but only once it has held for `params.secs` |
| `blink` | `input` | While enabled, flips every `params.secs` |
| `counter` | `input`, `reset` | On at `params.n` rising edges, until reset |

`wire` maps the block's input names to your port names. A `gate` takes an array
instead, since it has as many inputs as you give it.

## Scenes

A named set of port values applied together — `night` sets six ports across four
computers. Scenes live on the server, because spanning nodes is the whole point.

Easiest way to make one: set the base up by hand the way you want it, then open
**scenes** on the pocket computer and pick *capture current as…*. Only outputs
are captured; an input is a fact about the world and cannot be replayed.

A node that is offline when a scene fires misses it and the miss goes in the
log. One unloaded chunk does not stop the lights coming on in the rooms that
are loaded.

## The pocket computer

Four screens, tabs along the bottom row where your thumb is.

- **panel** — every node and every port. Tap an output to toggle it.
- **scenes** — tap to apply. Capture a new one.
- **rules** — what each node is running. Tap a rule to enable or disable it;
  *+ new rule* opens a form (arrows change a field, enter saves, q cancels).
- **log** — what changed and why.

The header says `SERVER` or `DIRECT`. `DIRECT` means nothing is answering at
base: the roster is assembled from node heartbeats and switches go straight to
the node. Scenes and the log are unavailable then, because they only ever lived
on the server — but every switch still works, which is the part that matters
when you are standing in the dark.

A node that has gone quiet shows `LOST` rather than its last known values. It
will never show you a stale reading as though it were live.

## The log

`what turned that off` is the question, so every entry carries a cause: a rule
id, a block id, a scene name, or `manual`. Held on the server, bounded at 200
entries.

## Tests

There is no `redstone` API outside the game, so the modules run against a mock
bus under [CraftOS-PC](https://www.craftos-pc.cc/). Copy the tree to a computer
directory and run:

```
CraftOS-PC --headless -d <datadir> --script <abs path>/test/run.lua
```

`--script` takes a **host** path, not a path inside the emulated filesystem.
Results are written to `/test-summary.txt` and `/test-*-results.txt` on the
emulated computer rather than stdout, because headless mode redraws the entire
terminal on every update.

591 assertions. `spec.lua` covers each module on its own — the port abstraction
over all three signal shapes, every rule operator and the debounce, all seven
logic blocks as arithmetic, scene planning against a stale roster, the bounded
log, the debounced state write, and the manifest against the tree. Three more
drive the real event loops of `node.lua`, `server.lua` and `remote.lua` with
scripted events, checking both what goes on the wire and what goes on the
screen — a `draw()` that throws on a pocket computer is the difference between
a UI and a brick, and that is invisible from the traffic.

`install_spec.lua` runs `install.lua` against a stubbed `http` served out of the
local tree and a scripted set of answers: that it downloads everything before
writing anything, that the flags skip the prompts, that pressing enter keeps the
network the computer is already on, that your `/ports.cfg` is never overwritten,
and that the example wiring it leaves behind is one `lib/ports.lua` accepts. An
installer is the one program where a bug means nobody gets far enough to report
it.
