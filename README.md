# AegisUI

A self-contained Roblox UI library for scripts in this tree. No remote assets, no
third-party code, no executor global used outside a `pcall`. It is published, so
consumers normally fetch it over http rather than importing a local file.

Current version: **5.0.0** (see [What's new in 4.0](#whats-new-in-40); the
[2.0](#whats-new-in-20) section is kept because it explains most of the current
visual design).

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
so **publish before running anything that fetches it**. The demo checks the
fetched version and refuses to run against a 1.x copy.

## What's new in 4.0

* **Shared state.** `AegisUI.State(default)` returns a binding with `Get` / `Set`
  / `On` / `Toggle`. A `MakeCheckbox` or `MakeSegmented` bound to a State is a
  *view* of it, so two views of one State cannot drift apart. Flag bindings are
  unchanged and still register in `AegisUI.Flags` / `AegisUI.Values`.
* **Composability.** `Section:MakeGroup({Text})` and `Section:MakeColumns(n)`
  return hosts carrying the same component methods as a section, so a panel can
  be composed from nested containers instead of one flat list.
* **Control surface.** `MakeCheckbox` (compact boolean, left tick),
  `MakeSegmented` (short mutually exclusive choice), `MakeBadge` (tone chip),
  `MakeAlert` (tone-edged callout), `MakeStat` (metric tile), `MakeSpacer`.
* **Data views.** `MakeTable({Columns, Rows})` with flex columns, zebra rows,
  right-aligned numerics, badge cells and swatch cells, plus `SetRows` for
  incremental updates.
* **Design.** Semantic tones (`neutral` / `info` / `ok` / `warn` / `err`) applied
  consistently across chips, alerts, stats and table badges; section headers take
  a `Description` sub-line and a live `Badge` (`Section:SetBadge`), so state is
  readable without scrolling.

The guarantees listed below are unchanged from 1.x.

## What's new in 2.0

* **Visual refresh.** Soft layered shadow, gradient border and accent rule on the
  header, a gradient logo mark, rounded header, animated tab indicator, hover
  and press states on every control, focus ring on text inputs, gradient slider
  fill, rotating chevrons, slide-in toasts with a countdown bar.
* **Themes.** Five presets (`Midnight`, `Ember`, `Moss`, `Orchid`, `Daylight`)
  and live switching with `Win:SetTheme()`; every element restyles in place.
* **New elements.** `MakeKeybind`, `MakeColorPicker`, `MakeProgress`,
  `MakeParagraph`, multi-select dropdowns (`Multi = true`), button `Style`
  (`primary` / `danger`), toggle `Description`, slider `Suffix`.
* **Collapsible sections.** Click a section title to fold it; start folded with
  `MakeSection({ Name = "...", Collapsed = true })`.
* **Config persistence.** `SaveConfig` / `LoadConfig` / `ListConfigs` /
  `DeleteConfig` (files), `ExportConfig` / `ImportConfig` (JSON string), and
  `Tab:MakeConfigSection()` for a ready-made UI. This replaces the old
  "not implemented" note.
* **Easing.** Every animation uses a real easing curve (Quad / Quint / Back).
* **Tab icons** as short text glyphs (`Win:MakeTab("Main", "=")`).
* Fix: `getgenv().AegisUI.state.collapsed` now tracks the real collapsed state.

Default window size is now 520 × 360 (was 480 × 340). Pass `Width` / `Height`
to keep the old size. The 1.x API is otherwise unchanged.

## Build a window

```lua
local Win = AegisUI:MakeWindow({
    Name        = "My Script",
    Subtitle    = "v1",
    Width       = 520,        -- optional, default 520
    Height      = 360,        -- optional, default 360
    Theme       = "Midnight", -- preset name, or { accent = Color3... } overrides,
                              -- or { Preset = "Ember", accent = Color3... }
    Glyph       = "A",        -- optional letter in the header mark (default: first letter of Name)
    BadgeText   = "AEGIS",    -- optional, text on the collapsed badge
    ConfigFolder = "AegisUI", -- optional, folder used by SaveConfig / LoadConfig
    ShowUnload  = true,       -- optional, default true; false omits the button
    UnloadLabel = "Unload",   -- optional, default "Unload"
    OnUnload    = function(reason) end,   -- reason: "button" | "api" | your own string
})

local Tab = Win:MakeTab("Main", "=")      -- second argument: optional text glyph
local Sec = Tab:MakeSection("Automation")
```

## Window surface

* `Win:MakeTab(title [, icon])`, `Win:SelectTab(tab)`
* `Win:Notify({...})`, `Win:Collapse()`, `Win:Restore()`, `Win:ToggleCollapsed()`,
  `Win:Unload(reason)`
* `Win:SetTheme(nameOrTable)`, `Win:SetAccent(accent [, accent2])`,
  `Win:SetTitle(text [, subtitle])`
* handles: `Win.Panel`, `Win.Badge`, `Win.TabList`, `Win.UnloadButton`, `Win.Theme`

Every window gets its own unload button, created and wired by the library — a
consumer script never has to add one. It is pinned to the bottom of the sidebar
so it cannot be scrolled away by a long tab list, and it is the only control
that exits. `ShowUnload = false` omits it when a script genuinely needs no exit
(the panel is then removed only by `Win:Unload()` / `api.unload()`).

## Elements

Every element returns an object with `Set`, `Get`, `Destroy` and `Instance` (the
underlying Instance). Elements that take a `Flag` are registered globally.
`Set(value, silent)` skips the callback when `silent` is true.

```lua
Sec:MakeButton({ Text = "Run", Style = "primary",      -- "default" | "primary" | "danger"
                 Callback = function() end })
Sec:MakeToggle({ Text = "Auto farm", Description = "optional second line",
                 Flag = "AutoFarm", Default = false,
                 Callback = function(on) end })
Sec:MakeSlider({ Text = "Speed", Flag = "Speed", Min = 16, Max = 200, Step = 1,
                 Default = 16, Suffix = " sps", Callback = function(v) end })
Sec:MakeTextBox({ Text = "Webhook", Flag = "Hook", Placeholder = "https://...",
                  Callback = function(text) end })   -- fires on FocusLost
Sec:MakeDropdown({ Text = "Mode", Flag = "Mode", Options = { "Left", "Right" },
                   Default = "Left", Callback = function(v) end })
Sec:MakeDropdown({ Text = "Targets", Flag = "Targets", Multi = true,
                   Options = { "A", "B", "C" }, Default = { "A" },
                   Callback = function(list) end })  -- Get() returns an array
Sec:MakeKeybind({ Text = "Panic", Flag = "Panic", Default = "X",
                  Callback = function(keyName) end,  -- the bound key was pressed
                  Changed  = function(keyName) end })-- the binding changed (nil = cleared)
Sec:MakeColorPicker({ Text = "ESP", Flag = "Esp", Default = Color3.fromRGB(96, 214, 255),
                      Callback = function(color) end })  -- Set accepts Color3 or "#RRGGBB"
Sec:MakeProgress({ Text = "Task", Flag = "Task" })   -- value 0..1; not saved by configs
Sec:MakeParagraph({ Title = "Note", Text = "wrapped body text" })
Sec:MakeLabel({ Text = "status" })     -- TextWrapped, AutomaticSize
Sec:MakeDivider()
```

Sections: `section:Collapse()`, `:Expand()`, `:Toggle()`, `:SetTitle(text)`.

Other element methods: button `Press()` / `SetDisabled()`, toggle `SetSilent()` /
`SetDisabled()`, slider `SetRange()`, dropdown `SetOptions(list, keep)` /
`Toggle()`, progress `Set(fraction, text)` / `SetText()`.

Dropdowns and the colour picker expand inline (accordion) rather than
overlaying, so no parent clipping can hide them.

Keybinds: click the chip, press a key; `Escape` clears. While a keybind is
listening, the window's own hotkeys are suppressed so the key being bound does
not also collapse the panel.

Notifications:

```lua
Win:Notify({ Title = "Done", Text = "12 items", Type = "success", Duration = 3 })
-- Type: info | success | error | warn. Duration 0 = sticky, click to dismiss.
-- At most five toasts are shown; a new one dismisses the oldest.
```

## Themes

```lua
Win:SetTheme("Ember")                              -- preset
Win:SetTheme({ accent = Color3.fromRGB(255, 90, 90) })  -- override keys on the current theme
Win:SetTheme({ Preset = "Moss", accent2 = Color3.fromRGB(0, 160, 255) })
Win:SetAccent(Color3.fromRGB(255, 90, 90))         -- accent, optional accent2
AegisUI.Themes                                     -- table of presets
```

Theme keys: `bg surface row hover raised line text dim accent accent2 ok warn err`.
Unknown keys are ignored. `SetTheme` returns `false` for an unknown preset.

## Config persistence

```lua
AegisUI:SaveConfig("farm")        -- true, path   | false, reason
AegisUI:LoadConfig("farm")        -- applied count | 0, reason   (fires callbacks)
AegisUI:LoadConfig("farm", true)  -- same, silent
AegisUI:ListConfigs()             -- { "farm", ... }
AegisUI:DeleteConfig("farm")
local json = AegisUI:ExportConfig()          -- string, no file access needed
AegisUI:ImportConfig(json [, silent])
Tab:MakeConfigSection("Save and load")       -- ready-made name box, list, buttons
```

Every element with a `Flag` is saved, except progress bars. Colours are stored as
RGB triples, keybinds as key names, multi dropdowns as arrays. File functions
(`writefile`, `readfile`, `listfiles`, `delfile`, `makefolder`) are called inside
`pcall`s; where they do not exist the file methods return `false, reason` and
`ExportConfig` / `ImportConfig` still work (they need only `HttpService`).
Files live in `ConfigFolder` (default `AegisUI`).

## Driving it from another chunk

```lua
local api = getgenv().AegisUI.api
api.set("AutoFarm", true)   -- fires the element's Callback
api.get("AutoFarm")         -- true
api.getall()                -- { AutoFarm = true, Speed = 16, ... }
api.collapse() / api.restore() / api.toggle()
api.notify({ Title = "hi", Text = "there" })
api.theme("Orchid")
api.export() / api.import(json) / api.save("name") / api.load("name")
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

**Mock additions 2.0 needs.** The 1.x mock predates these, so extend it with:
classes `UIScale` (`Scale`); `UIGradient` (`Color`, `Transparency`, `Rotation`);
`UIStroke.Transparency` / `Color` tweened; properties `Rotation` and
`AutomaticSize = None` on GuiObjects; the `TextBox.Focused` event and
`TextButton.MouseButton1Down` / `MouseButton1Up`; `Enum.EasingStyle`
(`Quad Quint Back Linear`), `Enum.EasingDirection`, `Enum.Font.GothamBlack`,
`Enum.UserInputType.Keyboard`, `Enum.KeyCode[name]`; `TweenInfo.new(time, style, dir)`;
`ColorSequence` / `ColorSequenceKeypoint` / `NumberSequence` /
`NumberSequenceKeypoint`; `Color3:Lerp`, `Color3:ToHSV`, `Color3.fromHSV`;
`typeof`; `task.defer`; and `HttpService:JSONEncode` / `JSONDecode` (only for the
config tests). The library reads `TextBox`/`Frame` `AbsolutePosition` and
`AbsoluteSize` for slider and colour-bar dragging, as before.

## Known limits

* Image icons are not implemented (no remote assets). Tab icons are short text
  glyphs; stick to ASCII unless you have checked the glyph renders in Gotham.
* Orion's `SaveConfig` / `ConfigFolder` *options* on `MakeWindow` are still
  ignored except `ConfigFolder`, which now sets the save folder; saving is done
  by calling the methods above (or `Tab:MakeConfigSection()`), not automatically.
* Layout is verified structurally (the harness asserts the instance tree, the
  flag flow and the collapse/sweep/unload paths). It is not verified visually:
  the harness cannot render Roblox UI, so panel appearance must be confirmed in
  a live client.
