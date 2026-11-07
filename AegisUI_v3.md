# AegisUI v3

AegisUI v3 is a cleanup and consolidation release aimed at replacing the current monolithic design with a more maintainable, testable, and documentation-aligned API while preserving the library’s strongest guarantees:

- GUI is created disabled, parented, fully built, then enabled.
- Unloading is explicit and single-path.
- Controls with flags remain readable and writable from later execution chunks.
- A previous instance is swept and its connections are disconnected.
- The library remains self-contained and executor-safe.

## Goals

1. Reduce implementation risk
   - Split the current large Lua file into focused modules.
   - Keep behaviour explicit and easier to unit-test through a mock runtime.

2. Align code and documentation
   - Remove mismatch between the documentation and the implementation.
   - Publish a single source of truth for supported features.

3. Improve maintainability
   - Make theme, flag registry, lifecycle, and element definitions independent concerns.
   - Keep the public API stable while improving internals.

4. Make the library easier to extend
   - Add a consistent element contract: `Set`, `Get`, `Destroy`, `Instance`, `Flag`, `NoSave`.
   - Keep window construction and element creation in a common builder pattern.

## v3 design principles

### 1. Keep the public API familiar

Compatibility with the current flow is preserved:

```lua
local AegisUI = loadstring(game:HttpGet(
  "https://raw.githubusercontent.com/t2339789/AegisUI/main/AegisUI.lua"
))()

local Win = AegisUI:MakeWindow({
  Name = "My Script",
  Subtitle = "v3",
  Width = 500,
  Height = 360,
  Theme = "Midnight",
})

local Tab = Win:MakeTab("Main")
local Sec = Tab:MakeSection("Automation")
```

The public methods remain the same where possible:

- `AegisUI:MakeWindow(options)`
- `Win:MakeTab(title)`
- `Tab:MakeSection(title)`
- `Sec:MakeButton`, `MakeToggle`, `MakeSlider`, `MakeTextBox`, `MakeDropdown`, etc.
- `AegisUI:Set`, `AegisUI:Get`, `AegisUI:GetAll`
- `api.set`, `api.get`, `api.getall`, `api.unload`

### 2. Separate concerns into modules

The current monolithic file should be split into a small folder structure.

```text
AegisUI/
  AegisUI.lua
  core/
    init.lua
    types.lua
    helpers.lua
    lifecycle.lua
    registry.lua
    theme.lua
    persistence.lua
  ui/
    window.lua
    tabs.lua
    sections.lua
    elements/
      base.lua
      button.lua
      toggle.lua
      slider.lua
      textbox.lua
      dropdown.lua
      keybind.lua
      colorpicker.lua
      progress.lua
      label.lua
      divider.lua
      notification.lua
  docs/
    README.md
    migration-v2-to-v3.md
```

### 3. Keep a single “ground truth” registry

The v3 registry should own:

- active flags
- active values
- config import/export state
- opened windows
- connections for teardown

This ensures later chunks can inspect or drive flags without relying on stale state after unload or a sweep.

### 4. Standardize element contracts

Every element should fully conform to a common shape:

```lua
local element = {
  Instance = instance,
  Flag = "AutoFarm",
  NoSave = false,
}

function element:Set(value, silent)
  -- update backing state
end

function element:Get()
  -- read state
end

function element:Destroy()
  -- disconnect, clear refs, remove instance
end
```

All elements should:

- return an object with `Set`, `Get`, `Destroy` and `Instance`
- register into the flag table when a `Flag` is present
- support a `silent` mode where appropriate for config imports
- use local `fire` or `defer` wrappers to avoid blocking UI updates

## Proposed v3 API

### Window API

```lua
local Win = AegisUI:MakeWindow({
  Name = "My Script",
  Subtitle = "v1",
  Width = 480,
  Height = 340,
  Theme = "Midnight",
  ShowUnload = true,
  OnUnload = function(reason) end,
})
```

### Window methods

```lua
Win:MakeTab("Main")
Win:SelectTab(tab)
Win:Notify({ Title = "Done", Text = "Saved", Type = "success", Duration = 3 })
Win:Collapse()
Win:Restore()
Win:Unload(reason)
```

### Global API

```lua
local api = getgenv().AegisUI.api
api.set("AutoFarm", true)
api.get("AutoFarm")
api.getall()
api.collapse()
api.restore()
api.notify({ Title = "Hi", Text = "There" })
api.unload()
```

## Major v3 improvements

### A. Theme system hardening

v3 should make theme handling more explicit:

- exported preset names: `Midnight`, `Ember`, `Moss`, `Orchid`, `Daylight`
- `Win:SetTheme(spec)` consistently updates the entire tree
- `spec` accepts either a preset, partial table, or `{ Preset = "Ember", accent = ... }`
- each element stores its own visual state but reads from the shared window theme

### B. Config persistence contract

The current docs say config persistence is not implemented; the source includes config export/import/save/load APIs. v3 should finalize this contract and document the actual behavior.

Recommended rules:

- `SaveConfig` and `LoadConfig` should only work when executor file access is available.
- `ExportConfig` / `ImportConfig` should work without files.
- `NoSave` flags must be excluded.
- color values must round-trip cleanly via JSON-safe encoding.

### C. Duplicate instance protection

The current code sweeps previous AegisUI GUI instances and clears flag state. v3 should preserve this as a strict contract and validate it in the smoke test suite.

### D. Strict internal tests

AegisUI v3 should ship with a mock harness that asserts:

- no ScreenGui is enabled while unparented
- all connection cleanup occurs on unload or sweep
- all flag values remain available after a later chunk reads them
- a destroyed window cannot keep stale references alive
- theme updates reach all previously created elements

## v3 migration plan

### Breaking changes

The following may be accepted in a major version if needed:

- explicit `Theme` structure normalization
- stricter validation of option tables
- removal of undocumented or ambiguous config semantics
- more consistent `Callback` behaviour for controls

### Non-breaking behaviour to keep

- `Flag` registration stays global, accessible from another chunk
- `api.set` returns `false` for unknown flag instead of throwing
- no key unloads; unload remains button/API-only
- main collapse/restore model remains unchanged

## Quality gates for v3

Before publishing the v3 library, the project should verify:

- runtime script syntax checks
- mock-driven smoke tests for GUI lifecycle
- theme reflow checks
- config import/export consistency
- stale reference cleanup
- no executor-global leakage beyond safe `pcall` guards

## Recommended release state

v3 should be released as:

- a documented, versioned source
- a published README that matches actual API behaviour exactly
- a smoke test harness included in the repository
- a short migration note for users of v2

This is the key improvement the project needs: not just a visual refresh, but a stronger contract between code, documentation, and runtime behaviour.

## Summary

AegisUI v3 is not a rewrite for style alone. It is a maintenance release focused on three things:

- reduce complexity by splitting the large implementation
- improve correctness by clarifying the lifecycle and config contract
- improve trust by aligning docs and implementation with verified runtime behaviour

This would turn the project from a strong but occasionally opaque one-file library into a more durable and professional UI framework.

---

This document is intentionally written as a design and migration note for the next version and can be turned into an implementation checklist or a new source tree once the project is ready.
