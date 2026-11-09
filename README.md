# aegisui-renderer

Renders AegisUI Lua panels to PNG and animated GIF without a Roblox client.

AegisUI builds a `ScreenGui` instance tree and hands it to Roblox to draw. That
makes it unverifiable offline — the library's own README says panel appearance
"must be confirmed in a live client". This tool removes that dependency: it runs
the real Lua against a mock Roblox runtime, serialises the resulting instance
tree plus its tweens, and rasterises any moment of the resulting animation.

Nothing about the Lua is modified. The scripts it renders are ordinary
consumers, and would run unchanged in Roblox.

## Quickstart

```bash
# one tab of a panel
python3.13 render_ui.py --lua demos/v4_showcase.lua --lib aegisui/AegisUI.lua \
    --tab 2 --viewport 1200x820 --out out/tab2.png --crop

# an animated GIF of the panel opening (slowed 3x so it is legible)
python3.13 render_ui.py --lua demos/v4_showcase.lua --lib aegisui/AegisUI.lua \
    --tab 1 --viewport 1200x820 --gif out/open.gif --gif-frames 18 --gif-hold 3

# a single frame from inside an animation
python3.13 render_ui.py --lua demos/v4_showcase.lua --lib aegisui/AegisUI.lua \
    --tab 1 --time 0.12 --out out/mid.png --crop
```

| Flag | Meaning |
|---|---|
| `--lua FILE` | consumer script to run (needs `--lib` if it fetches AegisUI over http) |
| `--lib FILE` | local `AegisUI.lua` served for the published raw URL |
| `--tab N` | select tab N before dumping, so one run photographs one state |
| `--json FILE` | render a previously dumped tree instead of running Lua |
| `--time T` | seconds into the animation timeline (default: settled) |
| `--gif PATH` | write an animated GIF instead of a still |
| `--gif-frames N` / `--gif-hold X` | frame count, and playback slowdown |
| `--scale N` | device pixel ratio (default 2) |
| `--crop` | crop to painted content plus `--margin` |
| `--viewport WxH` | ScreenGui resolution the layout is computed against |
| `--bg #RRGGBB` | canvas colour behind the GUI |

## How it works

Two stages, deliberately decoupled — the Lua half produces ground truth, the
Python half only draws.

**1. `mock/roblox_mock.lua`** is a small, permissive Roblox runtime:
`Instance.new` with parenting and destruction, the datatypes (`UDim2`, `UDim`,
`Color3`, `Vector2`, `NumberSequence`, `ColorSequence`, `TweenInfo`,
`RaycastParams`), `Enum`, signals, `game:GetService` with the services these
scripts touch, a virtual executor filesystem, and `task`. It runs the consumer
and dumps the tree to JSON — every instance with a stable id, every property,
and every tween as `(target, property, from, to, start, duration, easing)`.

Three deliberate behaviours:

* **Tweens are data, not side effects.** `TweenService:Create(...):Play()`
  records the tween instead of writing values, so the renderer evaluates the
  scene at any time t. One dump yields any number of frames.
* **Delayed work never runs.** `task.delay` queues and is never resumed, because
  delayed work in these scripts is always teardown — toast dismissal, animation
  cleanup, autosave. `task.spawn` runs until its first `wait`, then stays
  suspended: setup executes, `while true do ... wait() end` drivers cannot spin.
* **A consumer error still dumps a tree**, labelled `PARTIAL`; the renderer
  refuses to present that as a complete render without saying so.

**2. `render_ui.py`** implements the Roblox 2D subset these panels use —
`UDim2` with `AnchorPoint`, `UIPadding` (which insets an object's *own* text,
not just its children), `UIListLayout` both directions, `AutomaticSize` from
content, scrolling canvas offsets, `ClipsDescendants`, `UICorner`, `UIGradient`
at arbitrary rotation, `UIStroke`, `BorderSizePixel`, `UIScale`, and text with
alignment, wrapping, scaling and truncation — then rasterises with Pillow at a
configurable device scale.

Animation evaluation lives in `apply_animations()`: Roblox's easing styles
(Linear, Sine, Quad, Cubic, Quart, Quint, Exponential, Circular, Back, Elastic,
Bounce) with In/Out/InOut directions, interpolating numbers, `UDim`, `UDim2`,
`Vector2` and `Color3`; booleans, enums and strings step at the end.

## Files

| Path | Role |
|---|---|
| `aegisui/AegisUI.lua` | AegisUI **v4.0.0** — the library under test |
| `aegisui/AegisUI.v2.0.0.lua` | the previous release, kept for comparison |
| `mock/roblox_mock.lua` | mock runtime + JSON tree/tween dump |
| `render_ui.py` | layout engine, animation evaluator, rasteriser, CLI |
| `tools/tree_inspect.py` | prints computed rects and properties for a dumped tree |
| `demos/v4_showcase.lua` | v4 surface: dashboard, settings, columns, tones |
| `demos/showcase.lua` | v2 surface, kept as a regression check |
| `demos/selftest.lua` | minimal script proving the mock works with no library |

## Verification

```bash
# mock alone, no library involved
lua mock/roblox_mock.lua demos/selftest.lua /tmp/self.json

# v2 API still works against v4
lua mock/roblox_mock.lua demos/showcase.lua /tmp/reg.json aegisui/AegisUI.lua

# every v4 tab
for t in 1 2 3 4; do
  python3.13 render_ui.py --lua demos/v4_showcase.lua --lib aegisui/AegisUI.lua \
      --tab $t --viewport 1200x820 --out out/v4_tab$t.png --crop
done
```

Rendered output is inspected image by image; the layout numbers behind any
suspicious pixel come from `tools/tree_inspect.py`.

## Known gaps

Faithful to structure and to time, but these are not emulated — do not read a
render as proof of these behaviours:

* **No scrollbars are drawn.** A `ScrollingFrame` clips correctly, but the
  track and thumb are absent, so overflow is visible only as clipping.
* **Sequential animations are approximated.** Tweens are recorded at the moment
  they are played, which is script-setup time. A tween created inside a delayed
  callback never exists, so a chained animation shortens to its first leg.
* **A tweened property reads as its pre-tween value** inside the Lua itself,
  since values are recorded rather than written. Do not use the mock to test
  code that reads back a property it animated.
* **No input state.** Hover, press, focus and drag appearances never trigger.
* **No icons or images** — the library ships none, but `ImageLabel` /
  `ImageButton` are not rasterised.
* **Fonts are stand-ins.** Roblox's Gotham family is not installed; Arial and
  Menlo are substituted, so glyph shapes and exact advance widths differ.
* **`RichText` markup is stripped**, not styled inline.
* **`GuiObject.Rotation` is ignored**, though `UIGradient.Rotation` works.
* Only the subset of the Roblox API these scripts touch is mocked. An unmocked
  service method is a nil-call error, reported by the mock — not a silently
  wrong picture.
