--[[
	showcase.lua — a consumer that exercises every AegisUI element, so the
	renderer has something representative to rasterise.

	It builds the library exactly as a script would in a live client: fetch the
	published copy, MakeWindow, tabs, sections, elements. Nothing here is
	renderer-specific — this file would run unchanged in Roblox.

	The active tab is chosen by the harness (`render_ui.py --tab N`), which
	calls Win:SelectTab after this script has run.
]]

local AegisUI = loadstring(game:HttpGet(
	"https://raw.githubusercontent.com/t2339789/AegisUI/main/AegisUI.lua"))()

local Win = AegisUI:MakeWindow({
	Name     = "Aegis Renderer",
	Subtitle = "v2.0.0 offline preview",
	Width    = 480,
	Height   = 460,
	Theme    = "Midnight",
})

--------------------------------------------------------------------------
-- Tab 1 — the everyday control surface
--------------------------------------------------------------------------
local main = Win:MakeTab("Main")
local auto = main:MakeSection("Automation")

auto:MakeButton({ Text = "Start routine", Style = "primary" })
auto:MakeToggle({ Text = "Auto farm", Flag = "AutoFarm", Default = true })
auto:MakeToggle({ Text = "Team check", Flag = "TeamCheck", Default = false })
auto:MakeSlider({ Text = "Walk speed", Flag = "Speed", Min = 16, Max = 200, Step = 1, Default = 64 })
auto:MakeDropdown({
	Text = "Target mode", Flag = "Mode",
	Options = { "Closest", "Lowest health", "Crosshair" }, Default = "Closest",
})
auto:MakeTextBox({ Text = "Webhook", Flag = "Hook", Placeholder = "https://discord.com/api/..." })

local input = main:MakeSection("Input")
input:MakeKeybind({ Text = "Panic key", Flag = "Panic", Default = "X" })
input:MakeColorPicker({ Text = "ESP colour", Flag = "Esp" })

local status = main:MakeSection("Status")
status:MakeProgress({ Text = "Scanning" })
status:MakeLabel({ Text = "3 targets in range" })
status:MakeDivider()
status:MakeParagraph({ Text = "Paragraph elements wrap across multiple lines and are used for inline documentation inside a panel." })

--------------------------------------------------------------------------
-- Tab 2 — secondary surface, exercise multi-select + danger styling
--------------------------------------------------------------------------
local advanced = Win:MakeTab("Advanced")
local aim = advanced:MakeSection("Aim")

aim:MakeDropdown({
	Text = "Bones", Flag = "Bones", Multi = true,
	Options = { "Head", "Torso", "Arms", "Legs" }, Default = "Head",
})
aim:MakeSlider({ Text = "Field of view", Flag = "FOV", Min = 10, Max = 360, Step = 5, Default = 120 })
aim:MakeToggle({ Text = "Smoothing", Flag = "Smooth", Default = true })
aim:MakeSlider({ Text = "Strength", Flag = "Strength", Min = 1, Max = 100, Step = 1, Default = 35 })

local danger = advanced:MakeSection("Danger zone")
danger:MakeButton({ Text = "Unload routine", Style = "danger" })
danger:MakeLabel({ Text = "This stops the routine immediately." })

--------------------------------------------------------------------------
-- Tab 3 — config surface
--------------------------------------------------------------------------
local cfg = Win:MakeTab("Config")
cfg:MakeConfigSection("Profiles")

--------------------------------------------------------------------------

Win:Notify({
	Title = "Renderer online",
	Text  = "AegisUI built this panel offline",
	Type  = "success",
	Duration = 0,
})
