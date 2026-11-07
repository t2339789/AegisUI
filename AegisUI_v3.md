# AegisUI v3 — Product and UI Architecture

This document expands the v3 roadmap into a component and layout plan for richer, composable interfaces. It is a design specification, not a claim that these APIs or components already exist in the published v2 source.

## Product goal

Make AegisUI a capable, dependable Roblox UI toolkit for both compact control panels and dense data-oriented interfaces. “Capable” should mean users can compose new layouts from stable primitives—not merely that the library has the longest list of widgets.

Priorities:

1. Reliable state and lifecycle contracts.
2. Composable layout primitives and rich data views.
3. Good behavior at small screen sizes and with large datasets.
4. Consistent themes, interaction states, and accessibility cues.
5. A verifiable API, examples, and tests for each shipped feature.

## Research and design references

The following public projects offer useful, different design lessons. They are references for patterns, not dependencies to copy wholesale:

- [Roblox/Roact](https://github.com/Roblox/roact) demonstrates a declarative tree, component composition, and explicit mount/unmount lifecycle. Its README says it is deprecated and points users to [React Lua](https://github.com/Roblox/react-lua), so use it as a historical design reference rather than a recommended new dependency.
- [SirMallard/Iris](https://github.com/SirMallard/Iris) demonstrates immediate-mode UI for debug and visualization tools, including concise widget calls, state objects, tree composition, and a demo window that teaches the API. Its approach is valuable for fast tool-building, but a retained-mode control-panel library should not adopt an every-frame rebuild model without a deliberate performance and state plan.
- [Footagesus/WindUI](https://github.com/Footagesus/WindUI) demonstrates a broad control-panel component surface, theming, examples, and published documentation. Its repository describes the project as beta, which is a reminder to distinguish documented/stable features from experimental ones.

These comparisons suggest that v3 should combine the discoverability of a widget API, the composability of declarative UI, and the practical ergonomics of retained controls—without taking a dependency on these libraries.

## Core architecture

### Keep state separate from presentation

Controls should read and write through a small state/binding layer rather than directly modifying sibling Instances. A binding can be a named flag, a local state object, or a derived value. UI updates should be scheduled only when the relevant value changes.

Concept sketch (proposed, not implemented):

```lua
local enabled = AegisUI.State(false)
local mode = AegisUI.State("Manual")

section:MakeToggle({ Text = "Enabled", State = enabled })
section:MakeCheckbox({ Text = "Enable diagnostics", State = enabled })
section:MakeDropdown({ Text = "Mode", State = mode, Options = { "Manual", "Auto" } })
```

A checkbox and toggle bound to the same state are two views of one boolean, not two separately synchronized values. Setting either one updates the state once; both views render the new value. The existing `Flag` API remains supported as a convenient named binding.

### Element contract

All elements should follow one lifecycle and value contract:

- `Set(value, options?)` validates and updates the value.
- `Get()` returns the current value.
- `Destroy()` is idempotent and removes event listeners, registry entries, and Instances.
- `Update(props)` applies supported live property changes where useful.
- `Instance` exposes the root Instance for advanced customization.
- Optional `Flag`, `State`, `NoSave`, and `Changed` metadata follow consistent rules.

Element callbacks should have documented semantics: whether defaults invoke callbacks, whether unchanged values are ignored, how `silent` applies, and how callback errors are reported. Do not silently swallow validation errors that users need to fix.

### Layout primitives before more widgets

Add a small set of composable containers so complex designs do not require a bespoke API for every arrangement:

- `MakeSection` / collapsible section with title, description, accessory slot, and badge slot.
- `MakeGroup` for related controls, with vertical or horizontal flow.
- `MakeColumns` for responsive multi-column layouts.
- `MakeCard` for an independently themed bordered surface.
- `MakeScrollArea` with explicit canvas and sizing behavior.
- `MakeSpacer`, `MakeDivider`, and `MakeText` / paragraph primitives.
- Optional `MakeCustom`/slot escape hatch for user-provided Roblox Instances, with clear ownership and cleanup rules.

Containers should compose through a common child API, not require hardcoded paths in the UI tree. Every container must document clipping, scrolling, automatic sizing, and what `Destroy()` owns.

## Expanded component catalog

### Status badges and count indicators

Provide both standalone and inline badge forms:

- `MakeBadge({ Text = "LIVE", Tone = "success" })`
- `section:MakeToggle({ ..., Badge = { Text = "BETA", Tone = "warning" } })`
- Tab and section count badges that can update without rebuilding the item.

Support semantic tones (`neutral`, `info`, `success`, `warning`, `danger`) that map to theme tokens; allow an explicit color override. Badge text should size safely, truncate or wrap by policy, and remain legible in light and dark themes. Badges communicate status only; they should not be the only indication of state.

### Checkbox and toggle family

Checkboxes and toggles share boolean state semantics and validation, but can have different presentation:

- `MakeCheckbox`: compact form rows, table cells, and multi-option lists.
- `MakeToggle`: prominent on/off setting with an animated track.
- Optional tri-state checkbox (`false`, `true`, `"mixed"`) for parent selections and matrix/table bulk state.
- `Indeterminate` should be a derived visual state when bound to child values; it must not overwrite those values implicitly.
- `Enabled`, `Visible`, and `ReadOnly` should be distinct properties. Disabled controls do not accept input; read-only controls can remain focusable and inspectable.

Dynamic visibility/enabled state should use a binding or predicate, with dependencies explicit so updates are predictable:

```lua
section:MakeCheckbox({
  Text = "Advanced mode",
  State = advanced,
  Flag = "AdvancedMode",
})

section:MakeSlider({
  Text = "Detail level",
  VisibleWhen = function() return advanced:Get() end,
  Min = 1,
  Max = 10,
})
```

The library should specify whether hidden values remain in config and whether hiding a control affects its state. Default recommendation: hidden controls retain their value; dynamic UI visibility does not reset user data.

### Tables

`MakeTable` should be schema-driven and separate row data from cell rendering. A table should support:

- typed columns (`text`, `number`, `boolean`, `badge`, custom renderer), widths, alignment, and optional sorting
- stable row keys supplied by the caller
- row selection and selected-row callbacks
- optional search/filter controls, pagination, and empty/loading/error states
- sticky header where Roblox layout allows it
- row actions and per-cell custom content
- editable cells only when explicitly configured, with validation and clear commit/cancel behavior
- safe updates through methods such as `SetRows`, `InsertRow`, `UpdateRow`, `RemoveRow`, and `SetSort`

Use a virtualized row renderer or a documented row limit for large datasets. Do not create thousands of Instances by default. Sorting/filtering must operate on model data, preserve stable keys, and avoid reordering user data in place unless explicitly requested.

Proposed usage:

```lua
local tableView = section:MakeTable({
  Columns = {
    { Key = "name", Title = "Name", Width = 180, Sortable = true },
    { Key = "state", Title = "State", Type = "badge" },
    { Key = "enabled", Title = "Enabled", Type = "checkbox" },
  },
  RowKey = "id",
  Rows = rows,
  OnRowActivated = function(row) end,
})

tableView:UpdateRow("worker-1", { enabled = true })
```

### Matrix / permission grid

A matrix is a specialized data view with row entities and column capabilities, useful for permissions, feature combinations, and compact configuration. It should build on the same row/column model as tables rather than invent a separate state system.

Support:

- fixed or scrollable row and column headers
- row labels and column labels with optional badges/tooltips
- boolean cells rendered as checkboxes, plus read-only/status cells
- per-cell disabled state and explanatory reason
- row, column, and whole-grid select/clear actions
- derived mixed state for row/column header checkboxes
- stable row/column IDs independent of displayed labels
- cell-level callback and bulk-change callback with changed-cell list
- optional search/filter for rows and columns
- keyboard/gamepad focus navigation where supported
- size thresholds and virtualization for large matrices

Store values by stable IDs, for example `values[rowId][columnId]`; do not bind cells by visible display text. A bulk operation should apply only to eligible cells, report exactly what changed, and make its callback behavior consistent with individual cell changes.

Proposed usage:

```lua
local permissions = section:MakeMatrix({
  Rows = roles,
  Columns = actions,
  RowKey = "id",
  ColumnKey = "id",
  State = permissionState,
  Cell = {
    Type = "checkbox",
    CanEdit = function(row, column) return row.editable ~= false end,
  },
  OnChanged = function(changes) end,
})

permissions:SetCell("moderator", "manage", true)
```

### Other high-value components

Build breadth in coherent families instead of isolated one-off controls:

- Searchable single-select and multi-select dropdowns with stable option IDs, disabled options, and clear behavior.
- Radio groups for mutually exclusive values.
- Segmented controls for short mutually exclusive choices.
- Numeric and text inputs with validation, formatting, and clear error states.
- Range slider where a two-ended interval is a real use case.
- Progress/status row with determinate and indeterminate modes.
- Keybind display/capture with explicit input ownership and cancellation.
- Color picker with color/alpha support where the runtime supports it.
- Inline alert/callout and empty/loading/error-state components.
- Tooltip/popover and context menu with focus, clipping, and dismissal rules.
- Tabs, breadcrumbs, accordions, and command/search palette for larger information architectures.
- Optional chart/plot primitives as a separate module; keep charting out of the core bundle until there is a tested use case.

## Interaction, accessibility, and responsive design

- Use Roblox-native interactive controls and input signals where possible; avoid invisible hit targets that cannot be focused or tested.
- Provide visible hover, pressed, focused, disabled, selected, and error states.
- Ensure text scale and row height remain usable on smaller screens; prefer scale-aware constraints and wrapping over fixed-width assumptions.
- Respect text direction and long labels where Roblox text components allow it.
- Add keyboard/gamepad navigation and predictable focus order for grids, menus, and dialogs.
- Tooltips supplement labels; they do not replace essential instructions.
- Provide reduced-motion configuration and avoid motion as the sole way to convey state.
- Use semantic theme tokens for surfaces, text, borders, focus, and status; validate contrast for all built-in presets.

## Performance and reliability guardrails

Complex widgets multiply Instances and connections. v3 should establish limits and measure them:

- Virtualize or page long tables and matrices; document when rows are not virtualized.
- Reuse row/cell templates where safe and disconnect their old bindings before reuse.
- Update only cells affected by changed data; avoid rebuilding the full table on every state change.
- Avoid per-frame polling for retained components.
- Make event and tween cleanup part of element destruction.
- Add stress tests for hundreds of rows/cells, repeated theme changes, repeated mount/unmount, and rapid state updates.
- Provide optional instrumentation (element count, render/update timing) for development builds.

## Documentation and examples

A rich component library needs a browsable catalog and examples, not just a long API list. Every component page/example should state:

- constructor options and defaults
- returned methods and value shape
- state/flag binding behavior
- callback timing and silent mode behavior
- theme and disabled/read-only behavior
- lifecycle/cleanup ownership
- limits and known visual/runtime caveats

Add a showcase/demo that contains one example of every stable component and combined layouts, including a searchable table, a permission matrix, dynamic fields, shared checkbox/toggle state, badges, empty/loading states, and a narrow-screen layout. Keep the demo runnable and covered by the same mock/smoke checks where possible.

## Phased delivery

### Phase 1 — Foundations

Finalize the element contract, state/binding layer, theme tokens, reusable layout containers, validation, and lifecycle/test harness. Reconcile v2 documentation with actual behavior first.

### Phase 2 — Everyday composition

Ship badges, groups/cards/columns, checkbox/radio/segmented controls, dynamic visibility/enabled bindings, and consistent text/input states. Update the component catalog and examples.

### Phase 3 — Data views

Ship table model/schema, sorting/filtering/selection, row updates, and performance limits. Then build matrix as a reusable table specialization with derived bulk-selection state.

### Phase 4 — Advanced interactions

Add tooltips/popovers, command palette, additional navigation patterns, and optional plotting only after focus, clipping, cleanup, and performance behavior are tested.

Do not label a phase feature stable until it has documented behavior, smoke coverage, and a live Roblox visual check.

## References

- [AegisUI current usage and lifecycle notes](https://github.com/t2339789/AegisUI/blob/main/AegisUI.md)
- [AegisUI v3 roadmap](https://github.com/t2339789/AegisUI/blob/main/AegisUI_v3.md)
- [Roblox/Roact](https://github.com/Roblox/roact) — declarative composition reference; repository is deprecated.
- [Roblox React Lua](https://github.com/Roblox/react-lua) — successor referenced by Roact.
- [SirMallard/Iris](https://github.com/SirMallard/Iris) — immediate-mode widgets and demo-oriented tool design.
- [Footagesus/WindUI](https://github.com/Footagesus/WindUI) — broad Roblox control-panel component and documentation reference.

## Success criteria

AegisUI v3 should be judged by whether a user can build a polished, data-rich panel with predictable state and lifecycle—not by a feature-count claim. Initial acceptance criteria:

- A checkbox and toggle bound to the same state stay synchronized without duplicate callback updates.
- Dynamic visibility/enabled rules update from declared dependencies and do not silently erase values.
- Table and matrix rows/cells use stable IDs and update incrementally.
- Bulk matrix changes correctly report eligible cells and derive mixed selection state.
- Theme changes restyle new and existing components consistently.
- Destroying/rebuilding complex views leaves no event connections or registry entries behind.
- Large views remain responsive under a documented and tested scale.
- The published documentation, demo, and source agree on every stable API.
