# CCprograms

ComputerCraft: Tweaked programs.

| Directory | What it is |
| --- | --- |
| [`mining/`](mining/) | A mining turtle fleet: turtles that quarry, branch mine and follow ore veins, a base server that queues and dispatches work, a pocket computer to deploy from, and geo scanner scouts that find seams for the miners to take. |

## mining

Install on any turtle, pocket computer or base computer:

```
wget run https://raw.githubusercontent.com/Gizmo0320/CCprograms/main/mining/install.lua
```

See [`mining/README.md`](mining/README.md) for setup, patterns and behaviour.

Everything is tested against a mock turtle and a mock world under
[CraftOS-PC](https://www.craftos-pc.cc/), which has no `turtle` API of its own —
535 assertions covering traversal, the fuel and inventory guards, crash resume,
fleet dispatch, the pocket UI and the scanning pipeline. See the Tests section of
the mining README for how to run them.
