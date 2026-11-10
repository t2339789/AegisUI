# AegisRobloxServer

A **server-behaviour laboratory**: client-side instrumentation that records the
exact payload shape every remote call sends, replays a captured call with
mutated arguments, and measures whether the server's own state moved.

The purpose is to answer one question per remote: *which fields does this
server actually validate?* That is the only question in this domain that has an
answer you can measure.

## What this is not

It is ATTEMPTING a server breach. 
**`UserId` is bound to the authenticated session in Roblox's gateway layer.**
It is never a field in any request a client can shape. Measured on
2026-11-04 against place `82080125925759` / universe `10768931816`:

| Probe | Result |
|---|---|
| `gamejoin.roblox.com/v1/join-game-instance` (POST) | `401 code 9002 "Authentication token is missing"` |
| `games.roblox.com/v1/games/{u}/private-servers` | `401 code 9002` |
| `servers/Public` x47 instances | `players: []`, `playerTokens: []` — no identity at all |
| `develop.roblox.com/v1/universes/{u}` | 200, but only name/desc/privacy/creator |

Every mutation path is auth-gated. No request shape asserts an identity.
Therefore a client cannot make the backend attribute an action to another
account, and a tool claiming to do so would be reporting a success it cannot
verify. See `../AegisInject/notes/roll-a-ninja-web-surface.md` for the full map.

What *is* reachable is the game's own remote handlers, where the question
becomes empirical: does the handler trust a client-supplied field? That is what
this project measures.

## Why a laboratory rather than an exploit

An exploit is a conclusion. This is the instrument that produces conclusions
you can defend, because every claim it makes is a before/after delta on
server-owned state rather than a return value. Return values lie:

* `FireServer` returns `nil` whether the server accepted or ignored the call.
* A local attribute write that "sticks" proves nothing — the server reads its
  own copy (`WeaponDamage = 999` reads back `999` and still deals base damage).
* A mutable counter that can only increment on a rare event reads `0` on a
  working feature.

So the lab's oracle is: **snapshot → one action → settle → snapshot → diff**,
with the delta attributed to exactly one labelled call.

## Layout

```
AegisRobloxServer/
  README.md
  remotelab.lua              single-file module, loadstring-able
  build/smoke_test.lua       offline harness (lupa, no client required)
```

## Usage

```lua
-- load
local Remotelab = loadstring(readfile("remotelab.lua"))()
```

`Remotelab` publishes itself to `getgenv().AegisRemotelab`.

```lua
-- resolve a remote by name or path
local hit = Remotelab.remote("Combat")

-- fire through the lab: recorded, then dispatched
Remotelab.fire(hit, "Hit", "Light", 1, {target})

-- inspect what was actually sent
Remotelab.dump()                  -- writes remotelab_dump.txt
print(Remotelab.report())         -- human-readable summary

-- replay record #3 with one field changed
Remotelab.replay(3, function(args)
    args[2] = 5                   -- e.g. combo index
    return args
end)
```

Delta measurement:

```lua
local a = Remotelab.snapshot()
Remotelab.fire(hit, "Hit", "Light", 5, {target})
task.wait(0.4)
local b = Remotelab.snapshot()
print(Remotelab.diff(a, b))
```

## Record shape

Each record is:

```
{ id, t, kind = "fire"|"invoke", name, path, args, result }
```

`args` holds the real values, so a replay re-sends identical objects. `report()`
renders types and values depth-limited, so a table full of Instances stays
readable.

## Verification status

* Syntax: **verified** — compiles clean under lupa (`py -3`, section 36 gate).
* Offline behaviour: **verified** — `build/smoke_test.lua` drives the real
  module against a mock remote and asserts capture, mutation-on-replay, and
  delta attribution.
* Live execution: **not verified.** The executor bridge was returning
  `elapsed ~6e-05 s` with no workspace output at the time of writing, which is
  the wedge signature rather than a script fault. Restart client + GUI and
  reinject before trusting any live result.

## Known limits

* `Remotelab.fire` records because the caller routed through it. A call made by
  the game's own code is **not** captured — auto-hooking `FireServer` depends on
  executor support and `hookfunction` is documented as silently no-opping on
  `FireServer` in this build. `Remotelab.observe(remote)` attempts a proxy and
  returns `false` when the executor refuses; it never reports success it did
  not achieve.
* Replay re-sends the captured argument objects. If the original call carried a
  live Instance that has since been destroyed, the replay sends a destroyed
  reference and the server will reject it — correctly.
* The delta oracle cannot attribute a change the player caused independently.
  One action per measurement.
