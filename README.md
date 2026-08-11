# CCprograms

ComputerCraft: Tweaked programs.

| Directory | What it is |
| --- | --- |
| [`mining/`](mining/) | A mining turtle fleet: turtles that quarry, branch mine and follow ore veins, a base server that queues and dispatches work, a pocket computer to deploy from, and geo scanner scouts that find seams for the miners to take. |
| [`redstone/`](redstone/) | A redstone control network: named ports over sides and bundled cable, rules and logic blocks each node runs for itself, scenes that switch a lot of things at once, a base server holding the log, and a pocket computer to do it by hand. |

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

The two are independent installs on different modem channels, so a world can
run both without either being told about the other.

Everything is tested under [CraftOS-PC](https://www.craftos-pc.cc/), which has
neither a `turtle` API nor a `redstone` bus of its own, so each directory brings
its own mock and runs the real modules against it — 535 assertions for the
mining fleet covering traversal, the fuel and inventory guards, crash resume,
fleet dispatch, the pocket UI and the scanning pipeline, and 591 for the redstone
network covering ports, rules, logic blocks, scenes, all three programs' event
loops and the installer. See the Tests section of each README for how to run
them.
