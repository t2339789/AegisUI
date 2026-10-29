# AegisUI

A self-contained Roblox UI library for scripts in this tree. No remote assets, no
third-party code, no executor global used outside a `pcall`. It is published, so
consumers normally fetch it over http rather than importing a local file.

| File | Role |
|---|---|
| `Scripts/AegisUI/AegisUI.lua` | the library — source of truth |
| `Scripts/AegisUI/README.md` | this file |
| `Scripts/aegisui_demo.lua` | consumer; fetches the published copy over http |
| `tools/aegisui_smoke_test.lua` | offline harness (strict mock) |

## Load it

Published copy: <https://github.com/t2339789/AegisUI>. Scripts use the raw URL:

```lua
local AegisUI = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/t2339789/AegisUI/main/AegisUI.lua"))()
```

The library also publishes itself on `getgenv()`, which survives across exec
chunks (`docs/AUTHORING.md` section 3), so any later chunk can pick it up:

```lua
local AegisUI = getgenv().AegisUI.lib
```

To run the local file without http while developing:

```powershell
.\aegis.cmd exec Scripts\AegisUI\AegisUI.lua --no-capture
.\aegis.cmd exec Scripts\aegisui_demo.lua --no-capture
.\aegis.cmd eval "local d=getgenv().AegisUIDemo print(d and d.state.runs, d and d.state.note)"
```

The local file is the source of truth; the URL serves whatever was pushed last,
so publish before running anything that fetches it.

## Build a window

```lua
local Win = AegisUI:MakeWindow({
    Name        = "My Script",
    Subtitle    = "v1",
    Width       = 480,        -- optional, default 480
    Height      = 340,        -- optional, default 340
    Theme       = { accent = Color3.fromRGB(96, 214, 255) },   -- optional, per key
    ShowUnload  = true,       -- optional, default true; false omits the button
    UnloadLabel = "Unload",   -- optional, default "Unload"
    OnUnload    = function(reason) end,   -- reason: "button" | "api" | your own string
})

local Tab = Win:MakeTab("Main")
local Sec = Tab:MakeSection("Automation")
```

## Window surface

* `Win:MakeTab(title)`, `Win:SelectTab(tab)`
* `Win:Notify({...})`, `Win:Collapse()`, `Win:Restore()`, `Win:Unload(reason)`
* handles: `Win.Panel`, `Win.Badge`, `Win.TabList`, `Win.UnloadButton`

Every window gets its own unload button, created and wired by the library — a
consumer script never has to add one. It is pinned to the bottom of the sidebar
so it cannot be scrolled away by a long tab list, and it is the only control
that exits. `ShowUnload = false` omits it when a script genuinely needs no exit
(the panel is then removed only by `Win:Unload()` / `api.unload()`).

## Elements

Every element returns an object with `Set`, `Get`, `Destroy` and `Instance` (the
underlying Instance). Elements that take a `Flag` are registered globally.

```lua
Sec:MakeButton({ Text = "Run", Callback = function() end })
Sec:MakeToggle({ Text = "Auto farm", Flag = "AutoFarm", Default = false,
                 Callback = function(on) end })
Sec:MakeSlider({ Text = "Speed", Flag = "Speed", Min = 16, Max = 200, Step = 1,
                 Default = 16, Callback = function(v) end })
Sec:MakeTextBox({ Text = "Webhook", Flag = "Hook", Placeholder = "https://...",
                  Callback = function(text) end })   -- fires on FocusLost
Sec:MakeDropdown({ Text = "Mode", Flag = "Mode", Options = { "Left", "Right" },
                   Default = "Left", Callback = function(v) end })
Sec:MakeLabel({ Text = "status" })     -- TextWrapped, AutomaticSize
Sec:MakeDivider()
```

Dropdowns expand inline (accordion) rather than overlaying, so no parent clipping
can hide the option list.

Notifications:

```lua
Win:Notify({ Title = "Done", Text = "12 items", Type = "success", Duration = 3 })
-- Type: info | success | error | warn. Duration 0 = sticky, click to dismiss.
```

## Driving it from another chunk

```lua
local api = getgenv().AegisUI.api
api.set("AutoFarm", true)   -- fires the element's Callback
api.get("AutoFarm")         -- true
api.getall()                -- { AutoFarm = true, Speed = 16, ... }
api.collapse() / api.restore()
api.notify({ Title = "hi", Text = "there" })
api.unload()
```

`api.set` returns `false` for an unknown flag rather than erroring, so a probe
can assert on it.

## Lifecycle contract

* the ScreenGui is created disabled, parented, fully built, then enabled — it is
  never enabled while it has no parent
* `DisplayOrder = 999999`, so Roblox's own menu cannot draw over the panel
* the header control **collapses** to an `AEGIS` badge; it never hides the gui
* keys: `RightShift` collapse/restore, `Insert` restore, `F4` collapse.
  **No key unloads** — unloading is the sidebar button or `api.unload()`
* re-execing a script that calls `MakeWindow` sweeps the previous `AegisUI`
  gui, disconnects its connections, and clears its flags
* `Win:Unload()` is idempotent; the published handle survives it with
  `window = nil` and a no-op api, so a later chunk can build again

## Verification

```powershell
cd C:\Users\JaeB8\OneDrive\Desktop\AegisInject
py -3 tools\check_script_syntax.py Scripts\AegisUI\AegisUI.lua Scripts\aegisui_demo.lua tools\aegisui_smoke_test.lua
py -3 -c "import lupa; lupa.LuaRuntime().execute(open('tools/aegisui_smoke_test.lua',encoding='utf-8').read())"
```

The harness runs the library and the demo against a mock that raises on an
unknown class, an unknown property, or a wrong-typed property, and that records a
contract violation if any ScreenGui is ever enabled while unparented. It serves
the published URL out of the local file, so the demo's http path is exercised
offline; the two copies are byte-identical (checked by hash).

## Known limits

* **Config persistence is not implemented.** Orion's `SaveConfig` /
  `ConfigFolder` options are accepted and ignored; flags live in memory for the
  session only.
* Icons, tween easing curves and multi-select dropdowns are not implemented.
* Layout is verified structurally (the harness asserts the instance tree, the
  flag flow and the collapse/sweep/unload paths). It is not verified visually:
  the harness cannot render Roblox UI, so panel appearance must be confirmed in
  a live client.
