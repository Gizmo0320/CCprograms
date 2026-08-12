# CCprograms

ComputerCraft: Tweaked programs.

| Directory | What it is |
| --- | --- |
| [`mining/`](mining/) | A mining turtle fleet: turtles that quarry, branch mine and follow ore veins, a base server that queues and dispatches work, a pocket computer to deploy from, and geo scanner scouts that find seams for the miners to take. |
| [`redstone/`](redstone/) | A redstone control network: named ports over sides and bundled cable, rules and logic blocks each node runs for itself, scenes that switch a lot of things at once, a base server holding the log, and a pocket computer to do it by hand. |
| [`aero/`](aero/) | A flight network for Create Aeronautics: ships that hold altitude and heading for themselves, fly between named waypoints and land or dock at the end, a base tower holding the waypoints and a map, and a pocket computer to send them places. |

## mining

Install on any turtle, pocket computer or base computer:

```
wget run https://raw.githubusercontent.com/Gizmo0320/CCprograms/main/mining/install.lua
```

See [`mining/README.md`](mining/README.md) for setup, patterns and behaviour.

## redstone

Install on any computer or pocket computer:

```
wget run https://raw.githubusercontent.com/Gizmo0320/CCprograms/main/redstone/install.lua
```

See [`redstone/README.md`](redstone/README.md) for wiring, rules and scenes.

## aero

Install on any computer or pocket computer:

```
wget run https://raw.githubusercontent.com/Gizmo0320/CCprograms/main/aero/install.lua
```

Needs [Create Aeronautics: Gadgets & Gizmos](https://modrinth.com/mod/create-aeronautics-gadgets-and-gizmos)
for the peripherals — the base mod's blocks are read-only sensors. See
[`aero/README.md`](aero/README.md) for the hull file, waypoints and the guards.

The three are independent installs on different modem channels, so a world can
run all of them without any being told about the others.

Everything is tested under [CraftOS-PC](https://www.craftos-pc.cc/), which has
no `turtle` API, no `redstone` bus and no Create Aeronautics of its own, so each
directory brings its own mock and runs the real modules against it — 535
assertions for the mining fleet covering traversal, the fuel and inventory
guards, crash resume, fleet dispatch, the pocket UI and the scanning pipeline;
591 for the redstone network covering ports, rules, logic blocks, scenes, all
three programs' event loops and the installer; and 682 for the flight network
covering the navigation arithmetic, sensor fusion and dead reckoning, the control
laws, all four flight guards, the three programs and the installer — plus a
flight model the autopilot is flown against for a few hundred sweeps at a time,
because a control law that does not settle looks exactly like one that does when
you are only reading it. See the Tests section of each README for how to run
them.
