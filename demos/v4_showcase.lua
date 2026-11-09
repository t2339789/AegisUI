--[[
	AegisUI v4 showcase — four panels, four use cases.

	1. Dashboard  monitoring: metric tiles, an event table, tone alerts
	2. Settings   configuration: one State bound to two controls
	3. Interface  layout: grouped controls side by side in columns
	4. Components the new vocabulary: badges, alerts, spacing, notes

	Everything here is public API; nothing is renderer-specific.
]]

local AegisUI = loadstring(game:HttpGet(
	"https://raw.githubusercontent.com/t2339789/AegisUI/main/AegisUI.lua"))()

local Win = AegisUI:MakeWindow({
	Name     = "Aegis v4",
	Subtitle = "design · versatility · data views",
	Width    = 500,
	Height   = 680,
	Theme    = "Midnight",
})

--------------------------------------------------------------------------
-- 1. Dashboard — the monitoring use case
--------------------------------------------------------------------------

local dash = Win:MakeTab("Dashboard")

local overview = dash:MakeSection({
	Name        = "Overview",
	Description = "Live session metrics",
	Badge       = "LIVE",
	Tone        = "ok",
})

local tiles = overview:MakeColumns(3, { Plain = true })
tiles[1]:MakeStat({ Label = "Targets", Value = "12", Tone = "info" })
tiles[2]:MakeStat({ Label = "Accuracy", Value = "94%", Tone = "ok" })
tiles[3]:MakeStat({ Label = "Latency", Value = "38ms", Tone = "warn" })

local activity = dash:MakeSection({
	Name        = "Recent activity",
	Description = "Newest first",
})

activity:MakeTable({
	Columns = {
		{ Key = "event", Title = "EVENT", Flex = 2.2, Primary = true },
		{ Key = "state", Title = "STATE", Type = "badge", Flex = 1 },
		{ Key = "ms", Title = "MS", Flex = 0.7, Align = "right", Dim = true },
	},
	Rows = {
		{ event = "Aim lock acquired", state = "hit", tone = "ok", ms = "12" },
		{ event = "Target lost", state = "miss", tone = "err", ms = "84" },
		{ event = "Revolver reloaded", state = "info", tone = "info", ms = "31" },
		{ event = "Wallbang accepted", state = "hit", tone = "ok", ms = "09" },
		{ event = "Out of range", state = "warn", tone = "warn", ms = "120" },
	},
})

local diag = dash:MakeSection("Diagnostics")
diag:MakeAlert({
	Tone  = "warn",
	Title = "Input driver saturated",
	Text  = "Mouse driver is in a limit cycle at 3.5 deg; camera driver is stable at 0.25 deg.",
})

--------------------------------------------------------------------------
-- 2. Settings — configuration, with one State behind two controls
--------------------------------------------------------------------------

local settings = Win:MakeTab("Settings")

local enabled = AegisUI.State(true)

local aim = settings:MakeSection({
	Name        = "Aim",
	Description = "Both controls share one State",
	Badge       = "ACTIVE",
	Tone        = "info",
})

aim:MakeToggle({
	Text  = "Aim assist",
	Flag  = "AimEnabled",
	State = enabled,
})

aim:MakeCheckbox({
	Text        = "Aim assist (second view)",
	Description = "Flipping either control updates both",
	State       = enabled,
})

aim:MakeSegmented({
	Text    = "Priority",
	Flag    = "Priority",
	Options = { "Nearest", "Lowest HP", "Crosshair" },
	Default = "Nearest",
})

aim:MakeSlider({ Text = "Field of view", Flag = "FOV", Min = 10, Max = 360, Step = 5, Default = 120 })

-- the header badge is a live read of the same State: one write, one truth
enabled:On(function(on)
	aim:SetBadge(on and "ACTIVE" or "OFF", on and "ok" or "neutral")
end)

--------------------------------------------------------------------------
-- 3. Interface — grouped controls laid out in columns
--------------------------------------------------------------------------

local ui = Win:MakeTab("Interface")

local appearance = ui:MakeSection({
	Name        = "Appearance",
	Description = "Two columns of grouped toggles",
})

local cols = appearance:MakeColumns(2)
cols[1]:MakeCheckbox({ Text = "ESP boxes", Default = true })
cols[1]:MakeCheckbox({ Text = "Snaplines" })
cols[1]:MakeCheckbox({ Text = "FOV ring", Default = true })
cols[2]:MakeCheckbox({ Text = "Show FPS" })
cols[2]:MakeCheckbox({ Text = "Team colours", Default = true })
cols[2]:MakeCheckbox({ Text = "Compact rows" })

local behaviour = ui:MakeSection("Behaviour")
behaviour:MakeSegmented({
	Text    = "On join",
	Options = { "Restore last", "Ask", "Off" },
	Default = "Restore last",
})
behaviour:MakeSpacer({ Size = 2 })
behaviour:MakeAlert({
	Tone  = "info",
	Title = "Spacing is content",
	Text  = "MakeSpacer separates unrelated groups without inventing a divider.",
})

--------------------------------------------------------------------------
-- 4. Components — the tone vocabulary
--------------------------------------------------------------------------

local comp = Win:MakeTab("Components")

local badges = comp:MakeSection({
	Name        = "Badges",
	Description = "One tone per semantic role",
})

badges:MakeBadge({ Text = "NEUTRAL", Tone = "neutral" })
badges:MakeBadge({ Text = "INFO", Tone = "info" })
badges:MakeBadge({ Text = "HEALTHY", Tone = "ok" })
badges:MakeBadge({ Text = "DEGRADED", Tone = "warn" })
badges:MakeBadge({ Text = "FAILED", Tone = "err" })

local alerts = comp:MakeSection("Alerts")
alerts:MakeAlert({ Tone = "info", Title = "Heads up", Text = "Informational callouts use the accent tone." })
alerts:MakeAlert({ Tone = "ok", Title = "All clear", Text = "Success is green and short." })
alerts:MakeAlert({ Tone = "err", Title = "Injection failed", Text = "Errors carry the same edge as the badge, so severity reads at a glance." })

local notes = comp:MakeSection("Notes")
notes:MakeParagraph({
	Title = "Composition",
	Text  = "Sections take a Description and a live Badge; Section:SetBadge updates it without rebuilding.",
})

--------------------------------------------------------------------------

Win:Notify({
	Title    = "AegisUI 4.0",
	Text     = "State, groups, columns, tables, tones",
	Type     = "success",
	Duration = 0,
})
