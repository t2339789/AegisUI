--[[
	AegisUI - v2.0.0

	A self-contained Roblox UI library built to the AegisInject house contract
	(docs/AUTHORING.md, "Panel lifecycle"). No external assets, no loadstring of
	remote code, no executor-specific global outside a pcall.

	USAGE
	    local AegisUI = loadstring(game:HttpGet(
	        "https://raw.githubusercontent.com/t2339789/AegisUI/main/AegisUI.lua"))()
	    -- or, from a later chunk: local AegisUI = getgenv().AegisUI.lib

	    local Win = AegisUI:MakeWindow({ Name = "My Script", Subtitle = "v1", Theme = "Midnight" })
	    local Tab = Win:MakeTab("Main")
	    local Sec = Tab:MakeSection("Automation")

	    Sec:MakeButton({ Text = "Run", Style = "primary", Callback = function() end })
	    Sec:MakeToggle({ Text = "Auto farm", Flag = "AutoFarm", Callback = function(v) end })
	    Sec:MakeSlider({ Text = "Speed", Flag = "Speed", Min = 16, Max = 200, Default = 16 })
	    Sec:MakeTextBox({ Text = "Webhook", Flag = "Hook" })
	    Sec:MakeDropdown({ Text = "Mode", Flag = "Mode", Options = { "Left", "Right" } })
	    Sec:MakeKeybind({ Text = "Panic key", Flag = "Panic", Default = "X" })
	    Sec:MakeColorPicker({ Text = "ESP colour", Flag = "Esp", Default = Color3.fromRGB(96, 214, 255) })
	    Sec:MakeProgress({ Text = "Progress" })

	NEW IN 2.0
	  * Visual refresh: soft layered shadow, gradient border and accent rule,
	    animated tabs / toggles / sliders / dropdown chevrons, slide-in toasts
	    with a countdown bar, collapsible sections, focus rings on inputs.
	  * Theme presets (Midnight, Ember, Moss, Orchid, Daylight) and live
	    Win:SetTheme(nameOrTable) -- every element restyles in place.
	  * New elements: Keybind, ColorPicker, Progress, Paragraph, multi-select
	    dropdowns (Multi = true), primary / danger button styles.
	  * Config persistence: AegisUI:SaveConfig / LoadConfig / ListConfigs /
	    DeleteConfig (file based), ExportConfig / ImportConfig (JSON string),
	    and Tab:MakeConfigSection() for a ready-made save/load UI.
	  * Easing curves on every animation (Quad / Quint / Back).

	WHAT IT GUARANTEES (unchanged from 1.x)
	  * ScreenGui is created disabled, parented, fully built, then enabled -- never
	    enabled while it has no parent.
	  * DisplayOrder 999999 so Roblox's own menu cannot cover the panel.
	  * The close control COLLAPSES to a badge. It never hides the gui.
	  * Unloading is reachable only from the sidebar Unload button and
	    AegisUI:Unload() / api.unload(). Keys collapse and restore; they do not exit.
	  * Every control with a Flag is readable from another chunk through
	    getgenv().AegisUI.api, so a probe can inspect and drive the panel.
	  * A previous instance is swept on load, and its connections disconnected.

	NOT IMPLEMENTED (deliberate, not stubbed)
	  * Image icons (no remote assets). Tabs accept a short text glyph as Icon.
]]

local AegisUI = {}

AegisUI.Name    = "AegisUI"
AegisUI.Version = "2.0.0"

local genv      = (type(getgenv) == "function" and getgenv()) or _G
local GUI_NAME  = "AegisUI"
local CONN_KEY  = "AegisUIConn"

local typeOf = (type(typeof) == "function") and typeof or type

--------------------------------------------------------------------------
-- 0. maths
--------------------------------------------------------------------------

local function clamp(n, lo, hi)
	if n < lo then return lo end
	if n > hi then return hi end
	return n
end

local function round(n)
	return math.floor(n + 0.5)
end

local function finite(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- %d on a float throws in Lua 5.3+ ("number has no integer representation");
-- floor first, and only fall back to a decimal format for real fractions.
local function fmtNum(n)
	if n == math.floor(n) then
		return string.format("%d", math.floor(n))
	end
	local s = string.format("%.2f", n)
	s = s:gsub("0+$", "")
	s = s:gsub("%.$", "")
	return s
end

local function fire(fn, ...)
	if type(fn) ~= "function" then return end
	if type(task) == "table" and type(task.spawn) == "function" then
		task.spawn(fn, ...)
	else
		fn(...)
	end
end

local function later(seconds, fn)
	if type(task) == "table" and type(task.delay) == "function" then
		task.delay(seconds, fn)
	else
		fn()
	end
end

local function defer(fn)
	if type(task) == "table" and type(task.defer) == "function" then
		task.defer(fn)
	else
		fn()
	end
end

local function toHex(c)
	return string.format("#%02X%02X%02X",
		round(clamp(c.R, 0, 1) * 255),
		round(clamp(c.G, 0, 1) * 255),
		round(clamp(c.B, 0, 1) * 255))
end

--------------------------------------------------------------------------
-- 1. services -- every lookup optional
--------------------------------------------------------------------------

local function getService(name)
	local ok, svc = pcall(function()
		return game:GetService(name)
	end)
	if ok and svc then return svc end
	return nil
end

local UIS          = getService("UserInputService")
local TweenService = getService("TweenService")
local Players      = getService("Players")

--------------------------------------------------------------------------
-- 2. theme
--------------------------------------------------------------------------

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

local STATUS = {
	ok   = rgb(110, 231, 149),
	warn = rgb(255, 196, 92),
	err  = rgb(255, 112, 112),
}

local function preset(t)
	for k, v in pairs(STATUS) do
		if t[k] == nil then t[k] = v end
	end
	return t
end

local THEMES = {
	Midnight = preset({
		bg = rgb(11, 13, 20),   surface = rgb(18, 21, 32), row = rgb(25, 29, 43),
		hover = rgb(35, 40, 60), raised = rgb(46, 52, 78), line = rgb(42, 48, 70),
		text = rgb(232, 236, 247), dim = rgb(126, 136, 163),
		accent = rgb(94, 214, 255), accent2 = rgb(148, 112, 255),
	}),
	Ember = preset({
		bg = rgb(16, 12, 12),   surface = rgb(25, 19, 19), row = rgb(33, 26, 26),
		hover = rgb(46, 36, 35), raised = rgb(60, 46, 44), line = rgb(62, 48, 46),
		text = rgb(245, 236, 230), dim = rgb(160, 140, 132),
		accent = rgb(255, 150, 84), accent2 = rgb(255, 92, 120),
	}),
	Moss = preset({
		bg = rgb(11, 16, 14),   surface = rgb(17, 25, 22), row = rgb(23, 33, 29),
		hover = rgb(31, 45, 39), raised = rgb(41, 59, 51), line = rgb(40, 57, 49),
		text = rgb(230, 243, 236), dim = rgb(126, 155, 141),
		accent = rgb(108, 236, 160), accent2 = rgb(64, 196, 200),
	}),
	Orchid = preset({
		bg = rgb(15, 12, 22),   surface = rgb(23, 18, 34), row = rgb(31, 25, 46),
		hover = rgb(43, 35, 64), raised = rgb(56, 46, 82), line = rgb(55, 45, 82),
		text = rgb(240, 234, 250), dim = rgb(148, 136, 176),
		accent = rgb(232, 128, 255), accent2 = rgb(124, 120, 255),
	}),
	Daylight = {
		bg = rgb(244, 246, 251),   surface = rgb(255, 255, 255), row = rgb(237, 240, 248),
		hover = rgb(226, 232, 244), raised = rgb(214, 221, 238), line = rgb(204, 212, 230),
		text = rgb(28, 33, 48), dim = rgb(100, 111, 136),
		accent = rgb(36, 120, 255), accent2 = rgb(128, 84, 255),
		ok = rgb(24, 160, 88), warn = rgb(214, 140, 10), err = rgb(220, 64, 64),
	},
}

local DEFAULT_THEME = THEMES.Midnight

AegisUI.Themes = THEMES

-- Merge a theme spec into `target` in place (a spec may be a preset name, a
-- table of per-key overrides, or { Preset = "Ember", accent = ... }).
-- Mutating in place matters: every element holds the same theme table, so a
-- live SetTheme reaches all of them without rebuilding anything.
local function applyThemeSpec(target, spec)
	if type(spec) == "string" then
		spec = { Preset = spec }
	end
	if type(spec) ~= "table" then return false end
	local name = spec.Preset or spec.preset
	if type(name) == "string" then
		local src = THEMES[name]
		if not src then return false end
		for k, v in pairs(src) do
			target[k] = v
		end
	end
	for k, v in pairs(spec) do
		if DEFAULT_THEME[k] ~= nil and v ~= nil then
			target[k] = v
		end
	end
	return true
end

local function copyTheme(spec)
	local t = {}
	for k, v in pairs(DEFAULT_THEME) do
		t[k] = v
	end
	applyThemeSpec(t, spec)
	return t
end

--------------------------------------------------------------------------
-- 3. instance helpers
--------------------------------------------------------------------------

-- Clearing in place, never reassigning: published handles keep pointing at the
-- same table, so a probe holding getgenv().AegisUI.state.values still reads
-- the live registry after a sweep or an unload.
local function clearTable(t)
	for key in pairs(t) do
		t[key] = nil
	end
	return t
end

local function create(class, props, parent)
	local inst = Instance.new(class)
	if props then
		for key, value in pairs(props) do
			inst[key] = value
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function corner(inst, radius)
	return create("UICorner", { CornerRadius = UDim.new(0, radius or 6) }, inst)
end

local function pad(inst, top, bottom, left, right)
	return create("UIPadding", {
		PaddingTop = UDim.new(0, top or 0),
		PaddingBottom = UDim.new(0, bottom or 0),
		PaddingLeft = UDim.new(0, left or 0),
		PaddingRight = UDim.new(0, right or 0),
	}, inst)
end

local function vlist(inst, spacing, horizontal)
	return create("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, spacing or 0),
		FillDirection = Enum.FillDirection.Vertical,
		HorizontalAlignment = horizontal or Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Top,
	}, inst)
end

-- Animation. `style` / `dir` are Enum.EasingStyle / EasingDirection names so
-- callers stay readable: tween(frame, 0.2, { ... }, "Quint"). Falls back to
-- setting the properties directly when TweenService is missing or errors.
local function tween(inst, time, props, style, dir)
	if TweenService and time and time > 0 then
		local ok, t = pcall(function()
			local info = TweenInfo.new(
				time,
				Enum.EasingStyle[style or "Quad"],
				Enum.EasingDirection[dir or "Out"]
			)
			local tw = TweenService:Create(inst, info, props)
			tw:Play()
			return tw
		end)
		if ok then return t end
	end
	for k, v in pairs(props) do
		pcall(function()
			inst[k] = v
		end)
	end
	return nil
end

-- A stroke whose colour follows a theme key (needs the window's painter).
local function pstroke(paint, inst, key, transparency, thickness)
	return paint("UIStroke", {
		Transparency = transparency or 0.5,
		Thickness = thickness or 1,
	}, inst, { Color = key })
end

--------------------------------------------------------------------------
-- 4. singleton sweep + connection tracking
--------------------------------------------------------------------------

local connections = {}

local function track(conn)
	if conn then
		connections[#connections + 1] = conn
	end
	return conn
end

local function on(signal, fn)
	if not signal then return nil end
	return track(signal:Connect(fn))
end

local function roots()
	local out = {}
	if type(gethui) == "function" then
		local ok, hidden = pcall(gethui)
		if ok and hidden then
			out[#out + 1] = hidden
		end
	end
	local coreGui = getService("CoreGui")
	if coreGui then
		out[#out + 1] = coreGui
		local robloxGui = coreGui:FindFirstChild("RobloxGui")
		if robloxGui then
			out[#out + 1] = robloxGui
		end
	end
	if Players and Players.LocalPlayer then
		local okPg, pg = pcall(function()
			return Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
		end)
		if okPg and pg then
			out[#out + 1] = pg
		end
	end
	return out
end

local function sweep()
	local killed = 0
	for _, root in ipairs(roots()) do
		local old = root:FindFirstChild(GUI_NAME)
		if old then
			pcall(function()
				old:Destroy()
			end)
			killed = killed + 1
		end
	end

	local held = genv[CONN_KEY]
	if type(held) == "table" then
		for _, conn in ipairs(held) do
			pcall(function()
				conn:Disconnect()
			end)
		end
	end
	connections = {}
	genv[CONN_KEY] = connections

	-- the swept window's elements are gone with its gui, so its flags must go
	-- too: a flag still pointing at a destroyed instance reads as "supported"
	clearTable(AegisUI.Flags)
	clearTable(AegisUI.Values)

	return killed
end

local function attach(gui)
	if type(gethui) == "function" then
		pcall(function()
			gui.Parent = gethui()
		end)
		if gui.Parent then return true end
	end

	pcall(function()
		if syn and syn.protect_gui then
			syn.protect_gui(gui)
			gui.Parent = getService("CoreGui")
		end
	end)
	if gui.Parent then return true end

	pcall(function()
		local coreGui = getService("CoreGui")
		if coreGui then
			gui.Parent = coreGui:FindFirstChild("RobloxGui") or coreGui
		end
	end)
	if gui.Parent then return true end

	if Players and Players.LocalPlayer then
		pcall(function()
			local pg = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
			if pg then
				gui.Parent = pg
			end
		end)
	end

	return gui.Parent ~= nil
end

--------------------------------------------------------------------------
-- 5. flag registry
--
-- Every control carrying a Flag lands here, so a probe in a later chunk can
-- read and drive it: api.set("AutoFarm", true), api.get("Speed").
--------------------------------------------------------------------------

AegisUI.Flags  = {}
AegisUI.Values = {}
AegisUI.ConfigFolder = "AegisUI"

local function registerFlag(flag, element)
	if type(flag) ~= "string" or flag == "" then return end
	element.Flag = flag
	AegisUI.Flags[flag] = element
	AegisUI.Values[flag] = element:Get()
end

function AegisUI:Set(flag, value)
	local element = self.Flags[flag]
	if not element then return false end
	element:Set(value)
	return true
end

function AegisUI:Get(flag)
	local element = self.Flags[flag]
	if not element then return nil end
	return element:Get()
end

function AegisUI:GetAll()
	local out = {}
	for flag, element in pairs(self.Flags) do
		out[flag] = element:Get()
	end
	return out
end

--------------------------------------------------------------------------
-- 5a. config persistence
--
-- ExportConfig / ImportConfig work on a JSON string and need only
-- HttpService, so they are usable (and testable) without a filesystem.
-- SaveConfig / LoadConfig put that string in <ConfigFolder>/<name>.json
-- through the executor's file functions, each call inside a pcall.
--------------------------------------------------------------------------

local function encodeValue(v)
	if typeOf(v) == "Color3" then
		return { __color = { v.R, v.G, v.B } }
	end
	return v
end

local function decodeValue(v)
	if type(v) == "table" and type(v.__color) == "table" then
		return Color3.new(v.__color[1] or 0, v.__color[2] or 0, v.__color[3] or 0)
	end
	return v
end

function AegisUI:ExportConfig()
	local data = {}
	for flag, element in pairs(self.Flags) do
		if not element.NoSave then
			local ok, v = pcall(function()
				return element:Get()
			end)
			if ok and v ~= nil then
				data[flag] = encodeValue(v)
			end
		end
	end
	local http = getService("HttpService")
	if not http then return nil, "HttpService unavailable" end
	local ok, json = pcall(function()
		return http:JSONEncode(data)
	end)
	if not ok then return nil, tostring(json) end
	return json
end

function AegisUI:ImportConfig(json, silent)
	local http = getService("HttpService")
	if not http then return 0, "HttpService unavailable" end
	local ok, data = pcall(function()
		return http:JSONDecode(json)
	end)
	if not ok or type(data) ~= "table" then
		return 0, "config is not valid JSON"
	end
	local applied = 0
	for flag, raw in pairs(data) do
		local element = self.Flags[flag]
		if element and not element.NoSave then
			local set = pcall(function()
				element:Set(decodeValue(raw), silent)
			end)
			if set then applied = applied + 1 end
		end
	end
	return applied
end

local function configPath(name)
	local clean = (tostring(name or "default"):gsub("[^%w_%- ]", ""))
	if clean == "" then clean = "default" end
	return AegisUI.ConfigFolder .. "/" .. clean .. ".json", clean
end

local function hasFiles()
	return type(writefile) == "function" and type(readfile) == "function"
end

function AegisUI:SaveConfig(name)
	if not hasFiles() then return false, "no file access in this executor" end
	local json, err = self:ExportConfig()
	if not json then return false, err end
	local path = configPath(name)
	local ok, fail = pcall(function()
		if type(isfolder) == "function" and type(makefolder) == "function"
			and not isfolder(AegisUI.ConfigFolder) then
			makefolder(AegisUI.ConfigFolder)
		end
		writefile(path, json)
	end)
	if not ok then return false, tostring(fail) end
	return true, path
end

function AegisUI:LoadConfig(name, silent)
	if not hasFiles() then return 0, "no file access in this executor" end
	local path = configPath(name)
	local ok, text = pcall(function()
		return readfile(path)
	end)
	if not ok or type(text) ~= "string" then
		return 0, "no saved config named " .. tostring(name)
	end
	return self:ImportConfig(text, silent)
end

function AegisUI:ListConfigs()
	local out = {}
	if type(listfiles) ~= "function" then return out end
	local ok, files = pcall(function()
		return listfiles(AegisUI.ConfigFolder)
	end)
	if not ok or type(files) ~= "table" then return out end
	for _, path in ipairs(files) do
		local base = tostring(path):match("([^/\\]+)%.json$")
		if base then out[#out + 1] = base end
	end
	table.sort(out)
	return out
end

function AegisUI:DeleteConfig(name)
	if type(delfile) ~= "function" then return false, "delfile unavailable" end
	local path = configPath(name)
	local ok, err = pcall(function()
		delfile(path)
	end)
	if not ok then return false, tostring(err) end
	return true
end

--------------------------------------------------------------------------
-- 6. window
--
-- Forward declarations, all load-bearing:
--   makeSection  -- tab:MakeSection is bound inside MakeTab, but the section
--                   implementation lives below the window builder
--   sliderDrag   -- assigned by a slider / colour bar's InputBegan and cleared
--                   by the one InputEnded handler created here; a local
--                   declared later would leave the handler reading a
--                   different variable
--   sliderRelease-- optional hook run when that drag ends (knob shrink etc.)
--   capturing    -- true while a Keybind waits for a key, so the window's own
--                   hotkeys do not fire on the key being bound
--------------------------------------------------------------------------

local makeSection
local makeConfigSection
local sliderDrag = nil
local sliderRelease = nil
local capturing = false

--------------------------------------------------------------------------
-- 6a. the published api
--
-- Built twice: once at load time with no window (so the documented flow --
-- "exec the library, then a later chunk uses getgenv().AegisUI.lib" -- works
-- before anything is drawn), and once by MakeWindow bound to that window.
--------------------------------------------------------------------------

local function buildApi(win)
	local function call(method, ...)
		if not win then return nil end
		return win[method](win, ...)
	end

	return {
		version  = AegisUI.Version,
		set      = function(flag, value) return AegisUI:Set(flag, value) end,
		get      = function(flag) return AegisUI:Get(flag) end,
		getall   = function() return AegisUI:GetAll() end,
		collapse = function() return call("Collapse") end,
		restore  = function() return call("Restore") end,
		toggle   = function() return call("ToggleCollapsed") end,
		notify   = function(props) return call("Notify", props) end,
		theme    = function(spec) return call("SetTheme", spec) end,
		unload   = function() return call("Unload", "api") end,
		export   = function() return AegisUI:ExportConfig() end,
		import   = function(json, silent) return AegisUI:ImportConfig(json, silent) end,
		save     = function(name) return AegisUI:SaveConfig(name) end,
		load     = function(name, silent) return AegisUI:LoadConfig(name, silent) end,
		tabs     = function()
			if not win then return 0 end
			return #win.Tabs
		end,
	}
end
function AegisUI:MakeWindow(options)
	options = options or {}
	local theme = copyTheme(options.Theme)
	if type(options.ConfigFolder) == "string" and options.ConfigFolder ~= "" then
		AegisUI.ConfigFolder = options.ConfigFolder
	end

	sweep()

	local gui = create("ScreenGui", {
		Name = GUI_NAME,
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = options.DisplayOrder or 999999,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Enabled = false,
	})

	if not attach(gui) then
		gui:Destroy()
		return nil, "no safe container for the GUI"
	end

	local win = {}
	win.Gui    = gui
	win.Theme  = theme
	win.Tabs   = {}
	win.Alive  = true
	win.Collapsed = false
	win.Toasts = {}

	------------------------------------------------------------------
	-- theming: every coloured instance is registered with the key it
	-- follows, so SetTheme can recolour the whole tree in place. State
	-- dependent colours (active tab, toggle on/off...) are re-derived by
	-- restyle callbacks instead.
	------------------------------------------------------------------

	local bound = {}
	local restylers = {}

	local function paint(class, props, parent, binds)
		local inst = create(class, props)
		if binds then
			for prop, key in pairs(binds) do
				inst[prop] = theme[key]
				bound[#bound + 1] = { inst, prop, key }
			end
		end
		if parent then
			inst.Parent = parent
		end
		return inst
	end

	local function restyle(fn)
		restylers[#restylers + 1] = fn
		return fn
	end

	-- accent -> accent2 gradient that follows the theme
	local function gradient(parent, rotation, transparency)
		local g = create("UIGradient", { Rotation = rotation or 0 }, parent)
		if transparency then
			g.Transparency = transparency
		end
		local function apply()
			g.Color = ColorSequence.new(theme.accent, theme.accent2)
		end
		apply()
		restyle(apply)
		return g
	end

	win.__paint, win.__restyle, win.__gradient = paint, restyle, gradient

	local function applyTheme()
		local keep = {}
		for _, b in ipairs(bound) do
			local inst = b[1]
			if inst and inst.Parent ~= nil then
				pcall(function()
					inst[b[2]] = theme[b[3]]
				end)
				keep[#keep + 1] = b
			end
		end
		bound = keep
		for _, fn in ipairs(restylers) do
			pcall(fn)
		end
	end

	function win:SetTheme(spec)
		if not win.Alive then return false end
		if not applyThemeSpec(theme, spec) then return false end
		applyTheme()
		return true
	end

	function win:SetAccent(accent, accent2)
		if not win.Alive then return false end
		if accent ~= nil then theme.accent = accent end
		if accent2 ~= nil then theme.accent2 = accent2 end
		applyTheme()
		return true
	end

	------------------------------------------------------------------
	-- panel: layered shadow, gradient border, UIScale for the open pop
	------------------------------------------------------------------

	local W = options.Width or 520
	local H = options.Height or 360
	local SIDEBAR = 148
	local HEADER = 46

	local shadowLayers = {}
	for i, spec in ipairs({ { 12, 0.86 }, { 26, 0.91 }, { 44, 0.955 } }) do
		shadowLayers[i] = create("Frame", {
			Name = "Shadow" .. i,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, 6),
			Size = UDim2.fromOffset(W + spec[1], H + spec[1]),
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = spec[2],
			BorderSizePixel = 0,
			ZIndex = 1,
		}, gui)
		corner(shadowLayers[i], 12 + math.floor(spec[1] / 2))
	end

	local panel = paint("Frame", {
		Name = "Panel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(W, H),
		BorderSizePixel = 0,
		ClipsDescendants = true,
		ZIndex = 2,
	}, gui, { BackgroundColor3 = "bg" })
	corner(panel, 12)
	win.Panel = panel

	local panelScale = create("UIScale", { Scale = 1 }, panel)

	local panelStroke = create("UIStroke", {
		Color = Color3.new(1, 1, 1),
		Transparency = 0.35,
		Thickness = 1,
	}, panel)
	gradient(panelStroke, 35, NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(1, 0.7),
	}))

	local function placeAll(pos)
		panel.Position = pos
		for _, layer in ipairs(shadowLayers) do
			layer.Position = UDim2.new(pos.X.Scale, pos.X.Offset, pos.Y.Scale, pos.Y.Offset + 6)
		end
	end

	local function setShown(visible)
		panel.Visible = visible
		for _, layer in ipairs(shadowLayers) do
			layer.Visible = visible
		end
	end

	------------------------------------------------------------------
	-- header
	------------------------------------------------------------------

	local header = paint("Frame", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, HEADER),
		BorderSizePixel = 0,
		Active = true,           -- non-Active frames receive no mouse input
	}, panel, { BackgroundColor3 = "surface" })
	corner(header, 12)

	-- squares off the header's lower corners (only the top ones should round)
	paint("Frame", {
		Name = "HeaderFill",
		Position = UDim2.new(0, 0, 1, -14),
		Size = UDim2.new(1, 0, 0, 14),
		BorderSizePixel = 0,
	}, header, { BackgroundColor3 = "surface" })

	local rule = create("Frame", {
		Name = "HeaderRule",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, 1),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		ZIndex = 2,
	}, header)
	gradient(rule, 0, NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 0.85),
	}))

	local mark = create("Frame", {
		Name = "Mark",
		Position = UDim2.fromOffset(12, 11),
		Size = UDim2.fromOffset(24, 24),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
	}, header)
	corner(mark, 7)
	gradient(mark, 45)

	-- The Aegis mark, drawn instead of shipped as an image: a dark shield with a
	-- gradient A cut into it, over the gradient tile.  aegis_logo.svg cannot be
	-- given to an ImageLabel (no SVG support) and getcustomasset would need the
	-- bytes written to disk first, so the mark is reconstructed here from two
	-- frames and a glyph.  `Glyph` overrides the A for a different product mark.
	local shield = create("Frame", {
		Name = "Shield",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(15, 18),
		BackgroundColor3 = Color3.fromRGB(14, 22, 32),
		BorderSizePixel = 0,
	}, mark)
	corner(shield, 4)

	local glyph = create("TextLabel", {
		Name = "Glyph",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Font = Enum.Font.GothamBlack,
		Text = string.upper(tostring(options.Glyph or "A")),
		TextSize = 12,
		TextColor3 = Color3.new(1, 1, 1),
	}, shield)
	gradient(glyph, 45)

	local title = paint("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(46, 7),
		Size = UDim2.new(1, -100, 0, 18),
		Font = Enum.Font.GothamBold,
		Text = tostring(options.Name or "AegisUI"),
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, header, { TextColor3 = "text" })

	local subtitle = paint("TextLabel", {
		Name = "Subtitle",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(46, 25),
		Size = UDim2.new(1, -100, 0, 13),
		Font = Enum.Font.Gotham,
		Text = tostring(options.Subtitle or ("AegisUI " .. AegisUI.Version)),
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, header, { TextColor3 = "dim" })

	local closeBtn = paint("TextButton", {
		Name = "Collapse",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -9, 0.5, 0),
		Size = UDim2.fromOffset(28, 28),
		Font = Enum.Font.GothamBold,
		Text = "-",
		TextSize = 18,
		AutoButtonColor = false,
	}, header, { TextColor3 = "dim", BackgroundColor3 = "hover" })
	corner(closeBtn, 8)

	on(closeBtn.MouseEnter, function()
		tween(closeBtn, 0.12, { BackgroundTransparency = 0.2, TextColor3 = theme.text })
	end)
	on(closeBtn.MouseLeave, function()
		tween(closeBtn, 0.15, { BackgroundTransparency = 1, TextColor3 = theme.dim })
	end)

	------------------------------------------------------------------
	-- body: sidebar + content
	------------------------------------------------------------------

	local body = create("Frame", {
		Name = "Body",
		Position = UDim2.fromOffset(0, HEADER),
		Size = UDim2.new(1, 0, 1, -HEADER),
		BackgroundTransparency = 1,
	}, panel)

	local sidebar = create("Frame", {
		Name = "Sidebar",
		Size = UDim2.new(0, SIDEBAR, 1, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}, body)
	pad(sidebar, 10, 10, 8, 8)

	-- The divider belongs to the body, not the sidebar. A child of a frame that
	-- owns a UIListLayout is laid out as a row, so a 1-scale-high divider would
	-- be a full-height row and push every tab out of the panel.
	paint("Frame", {
		Name = "SidebarDivider",
		Position = UDim2.fromOffset(SIDEBAR - 1, 10),
		Size = UDim2.new(0, 1, 1, -20),
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		ZIndex = 5,
	}, body, { BackgroundColor3 = "line" })

	-- Tab rail: fixed height with its own canvas, so however many tabs are
	-- added they scroll instead of shoving the unload button off the panel.
	local tabList = create("ScrollingFrame", {
		Name = "TabList",
		Size = UDim2.new(1, 0, 1, -38),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 2,
		ScrollBarImageColor3 = theme.line,
	}, sidebar)
	vlist(tabList, 4)
	win.TabList = tabList
	restyle(function()
		tabList.ScrollBarImageColor3 = theme.line
	end)

	local content = create("Frame", {
		Name = "Content",
		Position = UDim2.fromOffset(SIDEBAR, 0),
		Size = UDim2.new(1, -SIDEBAR, 1, 0),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
	}, body)

	-- Every window ships an unload button, created and wired by the library:
	-- the panel is the lib's, so the way out of it is too. Pinned to the bottom
	-- of the sidebar so it is always reachable and never scrolled away, and it
	-- remains the only control that exits (docs/AUTHORING.md "one way out").
	local unloadBtn
	if options.ShowUnload ~= false then
		unloadBtn = paint("TextButton", {
			Name = "Unload",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 0, 1, 0),
			Size = UDim2.new(1, 0, 0, 30),
			BorderSizePixel = 0,
			Font = Enum.Font.GothamSemibold,
			Text = tostring(options.UnloadLabel or "Unload"),
			TextSize = 12,
			AutoButtonColor = false,
		}, sidebar, { BackgroundColor3 = "row", TextColor3 = "err" })
		corner(unloadBtn, 8)
		pstroke(paint, unloadBtn, "line", 0.55)
		win.UnloadButton = unloadBtn

		on(unloadBtn.MouseEnter, function()
			tween(unloadBtn, 0.12, { BackgroundColor3 = theme.row:Lerp(theme.err, 0.2) })
		end)
		on(unloadBtn.MouseLeave, function()
			tween(unloadBtn, 0.15, { BackgroundColor3 = theme.row })
		end)
	end

	------------------------------------------------------------------
	-- notifications: slide in from the right, countdown bar, click to dismiss
	------------------------------------------------------------------

	local notifyHolder = create("Frame", {
		Name = "Notifications",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 14),
		Size = UDim2.fromOffset(272, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		ZIndex = 10,
	}, gui)
	vlist(notifyHolder, 8, Enum.HorizontalAlignment.Right)
	win.NotifyHolder = notifyHolder

	------------------------------------------------------------------
	-- badge (the collapse target; sibling of the panel, not a child)
	------------------------------------------------------------------

	local badge = paint("TextButton", {
		Name = "Badge",
		Position = UDim2.fromOffset(20, 20),
		Size = UDim2.fromOffset(92, 28),
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		Text = tostring(options.BadgeText or "AEGIS"),
		TextSize = 11,
		AutoButtonColor = false,
		Visible = false,
		ZIndex = 5,
	}, gui, { BackgroundColor3 = "surface", TextColor3 = "text" })
	corner(badge, 14)
	pad(badge, 0, 0, 14, 0)
	local badgeStroke = create("UIStroke", {
		Color = Color3.new(1, 1, 1),
		Transparency = 0.3,
		Thickness = 1,
	}, badge)
	gradient(badgeStroke, 20)
	local badgeDot = create("Frame", {
		Name = "Dot",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, -4, 0.5, 0),
		Size = UDim2.fromOffset(8, 8),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
	}, badge)
	corner(badgeDot, 4)
	gradient(badgeDot, 45)
	win.Badge = badge

	on(badge.MouseEnter, function()
		tween(badge, 0.12, { BackgroundColor3 = theme.hover })
	end)
	on(badge.MouseLeave, function()
		tween(badge, 0.15, { BackgroundColor3 = theme.surface })
	end)

	------------------------------------------------------------------
	-- collapse / restore
	------------------------------------------------------------------

	local function publishCollapsed(value)
		if genv.AegisUI and genv.AegisUI.window == win and type(genv.AegisUI.state) == "table" then
			genv.AegisUI.state.collapsed = value
		end
	end

	function win:Collapse()
		if not win.Alive then return false end
		win.Collapsed = true
		setShown(false)
		badge.Visible = true
		publishCollapsed(true)
		return true
	end

	function win:Restore()
		if not win.Alive then return false end
		win.Collapsed = false
		setShown(true)
		badge.Visible = false
		panelScale.Scale = 0.94
		tween(panelScale, 0.28, { Scale = 1 }, "Back", "Out")
		publishCollapsed(false)
		return true
	end

	function win:ToggleCollapsed()
		if win.Collapsed then
			return win:Restore()
		end
		return win:Collapse()
	end

	on(closeBtn.MouseButton1Click, function()
		win:Collapse()
	end)
	on(badge.MouseButton1Click, function()
		win:Restore()
	end)

	------------------------------------------------------------------
	-- tabs
	------------------------------------------------------------------

	local tabOrder = 0

	function win:SelectTab(tab)
		if not tab or not win.Alive then return false end
		for _, other in ipairs(win.Tabs) do
			other:__activate(other == tab)
		end
		win.ActiveTab = tab
		return true
	end

	-- MakeTab("Main") or MakeTab("Main", "#") or MakeTab({ Name = "Main", Icon = "#" })
	-- Icon is a short text glyph; there are no image assets in this library.
	function win:MakeTab(tabTitle, icon)
		if not win.Alive then return nil end
		if type(tabTitle) == "table" then
			icon = tabTitle.Icon
			tabTitle = tabTitle.Name or tabTitle.Title
		end
		tabOrder = tabOrder + 1
		local label = tostring(tabTitle or "Tab")

		local button = create("TextButton", {
			Name = label,
			LayoutOrder = tabOrder,
			Size = UDim2.new(1, 0, 0, 32),
			BackgroundColor3 = theme.row,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Font = Enum.Font.GothamSemibold,
			Text = label,
			TextSize = 12,
			TextColor3 = theme.dim,
			TextXAlignment = Enum.TextXAlignment.Left,
			AutoButtonColor = false,
		}, tabList)
		corner(button, 8)
		-- UIPadding shifts a child's Position as well as the button's text, so
		-- the indicator below has to be offset back out of the padding.  With an
		-- icon the gutter is 30, and a bare x = 3 put the accent bar straight
		-- through the first character of the label.
		local gutter = icon and 30 or 14
		pad(button, 0, 0, gutter, 8)

		local iconLabel
		if icon then
			iconLabel = create("TextLabel", {
				Name = "Icon",
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(-20, 0),
				Size = UDim2.new(0, 16, 1, 0),
				Font = Enum.Font.GothamBold,
				Text = tostring(icon),
				TextSize = 13,
				TextColor3 = theme.dim,
			}, button)
		end

		local indicator = create("Frame", {
			Name = "Indicator",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 2 - gutter, 0.5, 0),
			Size = UDim2.fromOffset(3, 6),
			BackgroundColor3 = theme.accent,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
		}, button)
		corner(indicator, 2)

		local page = create("ScrollingFrame", {
			Name = label .. "Page",
			Size = UDim2.new(1, 0, 1, 0),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			CanvasSize = UDim2.new(0, 0, 0, 0),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			ScrollBarThickness = 3,
			ScrollBarImageColor3 = theme.line,
			Visible = false,
		}, content)
		pad(page, 12, 12, 12, 12)
		vlist(page, 10)
		restyle(function()
			page.ScrollBarImageColor3 = theme.line
		end)

		local tab = {
			Window = win,
			Button = button,
			Page = page,
			Sections = {},
			Theme = theme,
			Active = false,
			Name = label,
		}

		local order = 0
		function tab:__nextOrder()
			order = order + 1
			return order
		end

		local function look(animate)
			local t = animate and 0.18 or 0
			if tab.Active then
				button.BackgroundColor3 = theme.row
				tween(button, t, { BackgroundTransparency = 0, TextColor3 = theme.text })
				indicator.BackgroundColor3 = theme.accent
				tween(indicator, t, { BackgroundTransparency = 0, Size = UDim2.fromOffset(3, 16) }, "Quint")
				if iconLabel then tween(iconLabel, t, { TextColor3 = theme.accent }) end
			else
				tween(button, t, { BackgroundTransparency = 1, TextColor3 = theme.dim })
				tween(indicator, t, { BackgroundTransparency = 1, Size = UDim2.fromOffset(3, 6) }, "Quint")
				if iconLabel then tween(iconLabel, t, { TextColor3 = theme.dim }) end
			end
		end

		function tab:__activate(state)
			local changed = tab.Active ~= state
			tab.Active = state and true or false
			page.Visible = state
			if state and changed then
				-- a short rise-in answers the click and shows which page is new
				page.Position = UDim2.fromOffset(0, 10)
				tween(page, 0.24, { Position = UDim2.fromOffset(0, 0) }, "Quint")
			end
			look(true)
		end

		restyle(function()
			look(false)
		end)

		function tab:MakeSection(sectionTitle)
			return makeSection(tab, sectionTitle)
		end

		function tab:MakeConfigSection(sectionTitle)
			return makeConfigSection(tab, sectionTitle)
		end

		on(button.MouseEnter, function()
			if tab.Active then return end
			tween(button, 0.12, { BackgroundTransparency = 0.6, TextColor3 = theme.text })
		end)
		on(button.MouseLeave, function()
			if tab.Active then return end
			tween(button, 0.15, { BackgroundTransparency = 1, TextColor3 = theme.dim })
		end)
		on(button.MouseButton1Click, function()
			win:SelectTab(tab)
		end)

		win.Tabs[#win.Tabs + 1] = tab
		if #win.Tabs == 1 then
			win:SelectTab(tab)
		end
		return tab
	end

	------------------------------------------------------------------
	-- keys: collapse and restore only
	--
	-- Deliberately no key that unloads: a keypress during combat must cost a
	-- badge click, not a re-injection (AUTHORING.md, "Exactly one way out").
	------------------------------------------------------------------

	local keys = options.Keys or {}
	local keyToggle   = keys.Toggle   or Enum.KeyCode.RightShift
	local keyRestore  = keys.Restore  or Enum.KeyCode.Insert
	local keyCollapse = keys.Collapse or Enum.KeyCode.F4

	on(UIS and UIS.InputBegan, function(input, processed)
		if processed or capturing then return end
		local kc = input and input.KeyCode
		if kc == keyToggle then
			win:ToggleCollapsed()
		elseif kc == keyRestore then
			win:Restore()
		elseif kc == keyCollapse then
			win:Collapse()
		end
	end)

	------------------------------------------------------------------
	-- window drag (header)
	------------------------------------------------------------------

	local dragging, dragStart, startPos = false, nil, nil

	on(header.InputBegan, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = panel.Position
		end
	end)

	on(UIS and UIS.InputChanged, function(input)
		local kind = input.UserInputType
		if kind ~= Enum.UserInputType.MouseMovement and kind ~= Enum.UserInputType.Touch then
			return
		end
		-- a slider being dragged owns the movement before a window drag does
		if sliderDrag then
			sliderDrag(input.Position.X)
			return
		end
		if not dragging then return end
		local delta = input.Position - dragStart
		placeAll(UDim2.new(
			startPos.X.Scale, startPos.X.Offset + delta.X,
			startPos.Y.Scale, startPos.Y.Offset + delta.Y
		))
	end)

	on(UIS and UIS.InputEnded, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
			local release = sliderRelease
			sliderDrag = nil
			sliderRelease = nil
			if release then
				pcall(release)
			end
		end
	end)

	------------------------------------------------------------------
	-- notifications
	------------------------------------------------------------------

	function win:Notify(props)
		props = props or {}
		if not win.Alive or not notifyHolder.Parent then return nil end

		local kind = tostring(props.Type or "info")
		local colourKey = "accent"
		if kind == "success" then
			colourKey = "ok"
		elseif kind == "error" then
			colourKey = "err"
		elseif kind == "warn" or kind == "warning" then
			colourKey = "warn"
		end
		local colour = theme[colourKey]

		-- keep the stack short: the oldest toast makes room for a new one
		while #win.Toasts >= 5 do
			local oldest = table.remove(win.Toasts, 1)
			if oldest then oldest.dismiss(true) end
		end

		-- the wrapper is what the list layout positions; the toast inside it is
		-- free to slide, which a direct layout child could not do
		local wrapper = create("Frame", {
			Name = "ToastSlot",
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
		}, notifyHolder)

		local toast = create("Frame", {
			Name = "Toast",
			Position = UDim2.new(1.15, 0, 0, 0),
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = theme.surface,
			BorderSizePixel = 0,
			Active = true,
		}, wrapper)
		corner(toast, 10)
		local toastStroke = create("UIStroke", {
			Color = colour,
			Transparency = 0.55,
			Thickness = 1,
		}, toast)
		pad(toast, 10, 0, 12, 12)
		vlist(toast, 3)

		local head = create("TextLabel", {
			Name = "Title",
			LayoutOrder = 1,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 16),
			Font = Enum.Font.GothamBold,
			Text = tostring(props.Title or kind),
			TextSize = 12,
			TextColor3 = colour,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, toast)
		pad(head, 0, 0, 14, 0)
		local dot = create("Frame", {
			Name = "Dot",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, -14, 0.5, 0),
			Size = UDim2.fromOffset(7, 7),
			BackgroundColor3 = colour,
			BorderSizePixel = 0,
		}, head)
		corner(dot, 4)

		local text = tostring(props.Text or props.Content or "")
		if text ~= "" then
			create("TextLabel", {
				Name = "Body",
				LayoutOrder = 2,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				Font = Enum.Font.Gotham,
				Text = text,
				TextSize = 12,
				TextColor3 = theme.text,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				TextWrapped = true,
			}, toast)
		end

		local duration = props.Duration
		if not finite(duration) then duration = 3 end

		local barTrack = create("Frame", {
			Name = "Timer",
			LayoutOrder = 3,
			Size = UDim2.new(1, 0, 0, 2),
			BackgroundColor3 = theme.line,
			BackgroundTransparency = duration > 0 and 0.2 or 1,
			BorderSizePixel = 0,
		}, toast)
		corner(barTrack, 1)
		local barFill = create("Frame", {
			Name = "Fill",
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = colour,
			BorderSizePixel = 0,
		}, barTrack)
		corner(barFill, 1)
		-- spacer so the bar does not sit on the toast's bottom edge
		create("Frame", {
			Name = "Spacer",
			LayoutOrder = 4,
			Size = UDim2.new(1, 0, 0, 7),
			BackgroundTransparency = 1,
		}, toast)

		local dismissed = false
		local entry = {}
		local function dismiss(instant)
			if dismissed then return end
			dismissed = true
			for i, other in ipairs(win.Toasts) do
				if other == entry then
					table.remove(win.Toasts, i)
					break
				end
			end
			if instant == true then
				pcall(function()
					wrapper:Destroy()
				end)
				return
			end
			tween(toast, 0.2, { Position = UDim2.new(1.15, 0, 0, 0) }, "Quad", "In")
			later(0.22, function()
				pcall(function()
					wrapper:Destroy()
				end)
			end)
		end
		entry.dismiss = dismiss
		win.Toasts[#win.Toasts + 1] = entry

		on(toast.InputBegan, function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				dismiss()
			end
		end)

		tween(toast, 0.32, { Position = UDim2.new(0, 0, 0, 0) }, "Back", "Out")
		if duration > 0 then
			tween(barFill, duration, { Size = UDim2.new(0, 0, 1, 0) }, "Linear")
			later(duration, dismiss)
		end

		win.LastToast = toast
		return toast
	end

	------------------------------------------------------------------
	-- unload
	------------------------------------------------------------------

	function win:Unload(reason)
		if not win.Alive then return false end
		win.Alive = false

		if notifyHolder and notifyHolder.Parent then
			pcall(function()
				notifyHolder:Destroy()
			end)
		end
		pcall(function()
			gui:Destroy()
		end)
		for _, conn in ipairs(connections) do
			pcall(function()
				conn:Disconnect()
			end)
		end
		connections = {}
		genv[CONN_KEY] = nil

		bound = {}
		restylers = {}
		win.Toasts = {}
		capturing = false
		sliderDrag = nil
		sliderRelease = nil

		clearTable(AegisUI.Flags)
		clearTable(AegisUI.Values)
		if AegisUI.CurrentWindow == win then
			AegisUI.CurrentWindow = nil
		end
		if genv.AegisUI and genv.AegisUI.window == win then
			-- The library handle survives: a later chunk must be able to build a
			-- new window without re-execing the library. Only the window binding
			-- is cleared, and the api degrades to no-ops.
			genv.AegisUI.window = nil
			genv.AegisUI.api = buildApi(nil)
			genv.AegisUI.state.collapsed = false
		end

		fire(options.OnUnload, reason or "unload")
		return true
	end

	if unloadBtn then
		on(unloadBtn.MouseButton1Click, function()
			win:Unload("button")
		end)
	end

	function win:SetTitle(text, sub)
		if not win.Alive then return false end
		if text ~= nil then title.Text = tostring(text) end
		if sub ~= nil then subtitle.Text = tostring(sub) end
		return true
	end

	win.Title    = title
	win.Subtitle = subtitle

	------------------------------------------------------------------
	-- content is complete: now it may be shown
	------------------------------------------------------------------

	gui.Enabled = true
	panelScale.Scale = 0.93
	tween(panelScale, 0.34, { Scale = 1 }, "Back", "Out")

	AegisUI.CurrentWindow = win

	genv.AegisUI = {
		version = AegisUI.Version,
		lib     = AegisUI,
		window  = win,
		api     = buildApi(win),
		state = {
			collapsed = false,
			values    = AegisUI.Values,
		},
	}

	return win
end

function AegisUI:Notify(props)
	if self.CurrentWindow then
		return self.CurrentWindow:Notify(props)
	end
	return nil
end

function AegisUI:SetTheme(spec)
	if self.CurrentWindow then
		return self.CurrentWindow:SetTheme(spec)
	end
	return false
end

function AegisUI:Unload(reason)
	if self.CurrentWindow then
		return self.CurrentWindow:Unload(reason or "lib")
	end
	return false
end
--------------------------------------------------------------------------
-- 7. sections and elements
--
-- sliderDrag is declared next to the window builder: one drag handler serves
-- every slider and colour bar, and the InputEnded handler in MakeWindow
-- clears it.
--------------------------------------------------------------------------

local function dragFraction(track, x)
	local absX = track.AbsolutePosition and track.AbsolutePosition.X or nil
	local width = track.AbsoluteSize and track.AbsoluteSize.X or nil
	if not finite(absX) or not finite(width) or width <= 0 then return nil end
	return clamp((x - absX) / width, 0, 1)
end

local function isPointerDown(input)
	local kind = input.UserInputType
	return kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch
end

function makeSection(tab, sectionSpec)
	local theme = tab.Theme
	local win = tab.Window
	local paint, restyle, gradient = win.__paint, win.__restyle, win.__gradient

	local sectionTitle, startCollapsed = sectionSpec, false
	if type(sectionSpec) == "table" then
		sectionTitle = sectionSpec.Name or sectionSpec.Title
		startCollapsed = sectionSpec.Collapsed == true
	end
	local sectionName = tostring(sectionTitle or "Section")

	local frame = paint("Frame", {
		Name = sectionName,
		LayoutOrder = tab:__nextOrder(),
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BorderSizePixel = 0,
	}, tab.Page, { BackgroundColor3 = "surface" })
	corner(frame, 10)
	pstroke(paint, frame, "line", 0.5)
	vlist(frame, 0)

	-- the head is a button: click it to fold the section away
	local head = create("TextButton", {
		Name = "Head",
		LayoutOrder = 0,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 34),
		Text = "",
		AutoButtonColor = false,
	}, frame)

	local pip = create("Frame", {
		Name = "Pip",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 12, 0.5, 0),
		Size = UDim2.fromOffset(3, 14),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
	}, head)
	corner(pip, 2)
	gradient(pip, 90)

	local headLabel = paint("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(24, 0),
		Size = UDim2.new(1, -56, 1, 0),
		Font = Enum.Font.GothamBold,
		Text = sectionName,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, head, { TextColor3 = "text" })

	local chevron = paint("TextLabel", {
		Name = "Chevron",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(14, 14),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = ">",
		TextSize = 12,
		Rotation = 90,
	}, head, { TextColor3 = "dim" })

	local contentFrame = create("Frame", {
		Name = "Content",
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, frame)
	pad(contentFrame, 0, 10, 10, 10)
	vlist(contentFrame, 6)

	local section = {
		Tab = tab,
		Frame = frame,
		Content = contentFrame,
		Theme = theme,
		Elements = {},
		Name = sectionName,
		Collapsed = false,
	}

	local order = 0
	local function nextOrder()
		order = order + 1
		return order
	end

	function section:__dead()
		if not win or not win.Alive then return true end
		if not frame.Parent then return true end
		return false
	end

	local function setCollapsed(state, animate)
		section.Collapsed = state and true or false
		contentFrame.Visible = not section.Collapsed
		tween(chevron, animate and 0.2 or 0, { Rotation = section.Collapsed and 0 or 90 }, "Quint")
		return section.Collapsed
	end

	function section:Collapse() return setCollapsed(true, true) end
	function section:Expand() return setCollapsed(false, true) end
	function section:Toggle() return setCollapsed(not section.Collapsed, true) end
	function section:SetTitle(text)
		headLabel.Text = tostring(text or "")
		return headLabel.Text
	end

	on(head.MouseButton1Click, function()
		section:Toggle()
	end)
	on(head.MouseEnter, function()
		tween(chevron, 0.12, { TextColor3 = theme.accent })
	end)
	on(head.MouseLeave, function()
		tween(chevron, 0.15, { TextColor3 = theme.dim })
	end)

	if startCollapsed then
		setCollapsed(true, false)
	end

	-- every element shares this tail: instance, flag, bookkeeping
	local function finish(element, props, inst)
		element.Instance = inst
		registerFlag(props.Flag, element)
		section.Elements[#section.Elements + 1] = element
		return element
	end

	-- a row is a TextButton so the whole strip is clickable; children drawn on
	-- top of it are transparent labels, so the text stays visible.
	local function makeRow(name, height, noHover)
		local row = paint("TextButton", {
			Name = tostring(name or "Row"),
			LayoutOrder = nextOrder(),
			Size = UDim2.new(1, 0, 0, height or 34),
			BorderSizePixel = 0,
			Text = "",
			AutoButtonColor = false,
		}, contentFrame, { BackgroundColor3 = "row" })
		corner(row, 8)
		local edge = pstroke(paint, row, "line", 0.55)
		if not noHover then
			on(row.MouseEnter, function()
				tween(row, 0.12, { BackgroundColor3 = theme.hover })
				tween(edge, 0.12, { Color = theme.accent2, Transparency = 0.45 })
			end)
			on(row.MouseLeave, function()
				tween(row, 0.16, { BackgroundColor3 = theme.row })
				tween(edge, 0.16, { Color = theme.line, Transparency = 0.55 })
			end)
		end
		return row, edge
	end

	local function rowLabel(parent, text, x, width, colourKey, bold)
		return paint("TextLabel", {
			Name = "Label",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(x or 12, 0),
			Size = UDim2.new(1, width or -24, 1, 0),
			Font = bold and Enum.Font.GothamSemibold or Enum.Font.Gotham,
			Text = tostring(text or ""),
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, parent, { TextColor3 = colourKey or "text" })
	end

	-- a card (holder) that the element fills; used by the taller controls
	local function makeCard(name, height, auto)
		local holder = paint("Frame", {
			Name = tostring(name or "Card"),
			LayoutOrder = nextOrder(),
			Size = UDim2.new(1, 0, 0, height or 50),
			AutomaticSize = auto and Enum.AutomaticSize.Y or Enum.AutomaticSize.None,
			BorderSizePixel = 0,
		}, contentFrame, { BackgroundColor3 = "row" })
		corner(holder, 8)
		local edge = pstroke(paint, holder, "line", 0.55)
		return holder, edge
	end

	------------------------------------------------------------------
	-- label
	------------------------------------------------------------------

	function section:MakeLabel(props)
		props = props or {}
		if section:__dead() then return nil end

		local label = paint("TextLabel", {
			Name = tostring(props.Name or "Label"),
			LayoutOrder = nextOrder(),
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Font = Enum.Font.Gotham,
			Text = tostring(props.Text or ""),
			TextSize = props.TextSize or 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextWrapped = true,
		}, contentFrame, (not props.Color) and { TextColor3 = "dim" } or nil)
		if props.Color then
			label.TextColor3 = props.Color
		end

		local element = {}
		function element:Set(text)
			label.Text = tostring(text or "")
			return label.Text
		end
		function element:Get()
			return label.Text
		end
		function element:Destroy()
			pcall(function()
				label:Destroy()
			end)
		end

		return finish(element, {}, label)
	end

	------------------------------------------------------------------
	-- paragraph: a titled note card with an accent edge
	------------------------------------------------------------------

	function section:MakeParagraph(props)
		props = props or {}
		if section:__dead() then return nil end

		local card = paint("Frame", {
			Name = tostring(props.Name or props.Title or "Paragraph"),
			LayoutOrder = nextOrder(),
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BorderSizePixel = 0,
		}, contentFrame, { BackgroundColor3 = "row" })
		corner(card, 8)
		pstroke(paint, card, "line", 0.6)

		local bar = create("Frame", {
			Name = "Edge",
			Position = UDim2.fromOffset(0, 8),
			Size = UDim2.new(0, 3, 1, -16),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
		}, card)
		corner(bar, 2)
		gradient(bar, 90)

		local inner = create("Frame", {
			Name = "Inner",
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
		}, card)
		pad(inner, 9, 10, 14, 12)
		vlist(inner, 3)

		local titleLabel = paint("TextLabel", {
			Name = "Title",
			LayoutOrder = 1,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 16),
			Font = Enum.Font.GothamBold,
			Text = tostring(props.Title or ""),
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			Visible = props.Title ~= nil,
		}, inner, { TextColor3 = "text" })

		local bodyLabel = paint("TextLabel", {
			Name = "Body",
			LayoutOrder = 2,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Font = Enum.Font.Gotham,
			Text = tostring(props.Text or ""),
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextWrapped = true,
		}, inner, { TextColor3 = "dim" })

		local element = {}
		function element:Set(text, newTitle)
			bodyLabel.Text = tostring(text or "")
			if newTitle ~= nil then
				titleLabel.Text = tostring(newTitle)
				titleLabel.Visible = true
			end
			return bodyLabel.Text
		end
		function element:Get()
			return bodyLabel.Text
		end
		function element:Destroy()
			pcall(function()
				card:Destroy()
			end)
		end

		return finish(element, {}, card)
	end

	------------------------------------------------------------------
	-- button   Style = "default" | "primary" | "danger"
	------------------------------------------------------------------

	function section:MakeButton(props)
		props = props or {}
		if section:__dead() then return nil end

		local style = tostring(props.Style or "default")
		local row, edge = makeRow(props.Name or props.Text or "Button", props.Height or 34, true)
		row.Text = tostring(props.Text or props.Name or "Run")
		row.TextSize = 13
		row.Font = Enum.Font.GothamSemibold
		row.TextXAlignment = Enum.TextXAlignment.Center

		local disabled = props.Disabled == true

		if style == "primary" then
			row.BackgroundColor3 = Color3.new(1, 1, 1)
			edge.Transparency = 1
			gradient(row, 0)
		end

		local function resting(animate)
			local t = animate and 0.15 or 0
			if style == "primary" then
				row.TextColor3 = theme.bg
				tween(row, t, { BackgroundTransparency = disabled and 0.65 or 0 })
			elseif style == "danger" then
				row.TextColor3 = disabled and theme.dim or theme.err
				tween(row, t, { BackgroundColor3 = theme.row })
			else
				row.TextColor3 = disabled and theme.dim or theme.text
				tween(row, t, { BackgroundColor3 = theme.row })
			end
		end

		local function lifted(amount)
			if style == "primary" then
				tween(row, 0.1, { BackgroundTransparency = amount == 2 and 0.28 or 0.1 })
			elseif style == "danger" then
				tween(row, 0.1, { BackgroundColor3 = theme.row:Lerp(theme.err, amount == 2 and 0.3 or 0.16) })
			else
				tween(row, 0.1, { BackgroundColor3 = amount == 2 and theme.raised or theme.hover })
			end
		end

		resting(false)
		restyle(function()
			resting(false)
		end)

		on(row.MouseEnter, function()
			if disabled then return end
			lifted(1)
			if style ~= "primary" then
				tween(edge, 0.12, { Color = style == "danger" and theme.err or theme.accent2, Transparency = 0.4 })
			end
		end)
		on(row.MouseLeave, function()
			if disabled then return end
			resting(true)
			if style ~= "primary" then
				tween(edge, 0.15, { Color = theme.line, Transparency = 0.55 })
			end
		end)
		on(row.MouseButton1Down, function()
			if disabled then return end
			lifted(2)
		end)
		on(row.MouseButton1Up, function()
			if disabled then return end
			lifted(1)
		end)
		on(row.MouseButton1Click, function()
			if disabled then return end
			fire(props.Callback)
		end)

		local element = {}
		function element:Set(text)
			row.Text = tostring(text or "")
			return row.Text
		end
		function element:Get()
			return row.Text
		end
		function element:SetDisabled(state)
			disabled = state and true or false
			resting(true)
			return disabled
		end
		function element:Destroy()
			pcall(function()
				row:Destroy()
			end)
		end
		function element:Press()
			if disabled then return false end
			fire(props.Callback)
			return true
		end

		return finish(element, {}, row)
	end

	------------------------------------------------------------------
	-- toggle
	------------------------------------------------------------------

	function section:MakeToggle(props)
		props = props or {}
		if section:__dead() then return nil end

		local desc = props.Description
		local row = makeRow(props.Name or props.Text or "Toggle", props.Height or (desc and 50 or 34))
		local label = rowLabel(row, props.Text or props.Name or "Toggle", 12, -70, "text")
		if desc then
			label.Position = UDim2.fromOffset(12, 7)
			label.Size = UDim2.new(1, -70, 0, 18)
			paint("TextLabel", {
				Name = "Description",
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(12, 26),
				Size = UDim2.new(1, -70, 0, 16),
				Font = Enum.Font.Gotham,
				Text = tostring(desc),
				TextSize = 11,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
			}, row, { TextColor3 = "dim" })
		end

		local pill = create("Frame", {
			Name = "Pill",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -12, 0.5, 0),
			Size = UDim2.fromOffset(40, 22),
			BackgroundColor3 = theme.line,
			BorderSizePixel = 0,
		}, row)
		corner(pill, 11)

		local knob = create("Frame", {
			Name = "Knob",
			Position = UDim2.fromOffset(3, 3),
			Size = UDim2.fromOffset(16, 16),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
			ZIndex = 2,
		}, pill)
		corner(knob, 8)

		local value = props.Default == true
		local disabled = props.Disabled == true

		local function refresh(animate)
			local t = animate and 0.18 or 0
			local colour = theme.line
			if disabled then
				colour = theme.row
			elseif value then
				colour = theme.accent
			end
			tween(pill, t, { BackgroundColor3 = colour })
			tween(knob, t, {
				Position = value and UDim2.fromOffset(21, 3) or UDim2.fromOffset(3, 3),
				BackgroundColor3 = disabled and theme.dim or Color3.new(1, 1, 1),
			}, "Quint")
		end

		local function set(v, silent, animate)
			value = v and true or false
			refresh(animate ~= false)
			if props.Flag then
				AegisUI.Values[props.Flag] = value
			end
			if not silent then
				fire(props.Callback, value)
			end
			return value
		end

		refresh(false)
		restyle(function()
			refresh(false)
		end)

		local element = {}
		function element:Set(v, silent)
			return set(v, silent)
		end
		function element:Get()
			return value
		end
		function element:SetSilent(v)
			return set(v, true)
		end
		function element:SetDisabled(state)
			disabled = state and true or false
			refresh(true)
			return disabled
		end
		function element:Destroy()
			pcall(function()
				row:Destroy()
			end)
		end

		on(row.MouseButton1Click, function()
			if disabled then return end
			set(not value, false)
		end)

		return finish(element, props, row)
	end

	------------------------------------------------------------------
	-- slider
	------------------------------------------------------------------

	function section:MakeSlider(props)
		props = props or {}
		if section:__dead() then return nil end

		local minV = finite(props.Min) and props.Min or 0
		local maxV = finite(props.Max) and props.Max or 100
		if maxV < minV then
			minV, maxV = maxV, minV
		end
		local step = (finite(props.Step) and props.Step > 0) and props.Step or 0
		local suffix = props.Suffix and tostring(props.Suffix) or ""
		local value = clamp((finite(props.Default) and props.Default) or minV, minV, maxV)

		local holder, edge = makeCard(props.Name or props.Text or "Slider", 54)

		local label = rowLabel(holder, props.Text or props.Name or "Slider", 12, -96, "text")
		label.Position = UDim2.fromOffset(12, 8)
		label.Size = UDim2.new(1, -96, 0, 20)

		local chip = paint("Frame", {
			Name = "Chip",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -10, 0, 8),
			Size = UDim2.fromOffset(66, 20),
			BorderSizePixel = 0,
		}, holder, { BackgroundColor3 = "bg" })
		corner(chip, 6)

		local valueLabel = paint("TextLabel", {
			Name = "Value",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Font = Enum.Font.Code,
			Text = fmtNum(value) .. suffix,
			TextSize = 12,
		}, chip, { TextColor3 = "accent" })

		local track = paint("Frame", {
			Name = "Track",
			Position = UDim2.fromOffset(12, 36),
			Size = UDim2.new(1, -24, 0, 6),
			BorderSizePixel = 0,
		}, holder, { BackgroundColor3 = "line" })
		corner(track, 3)

		local fill = create("Frame", {
			Name = "Fill",
			Size = UDim2.new(0, 0, 1, 0),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
		}, track)
		corner(fill, 3)
		gradient(fill, 0)

		local knob = create("Frame", {
			Name = "Knob",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0, 0, 0.5, 0),
			Size = UDim2.fromOffset(14, 14),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
			ZIndex = 3,
		}, track)
		corner(knob, 7)
		pstroke(paint, knob, "accent", 0.1, 2)

		-- a 6px track is a 6px hit target; this invisible strip is the real one
		local hit = create("Frame", {
			Name = "Hit",
			Position = UDim2.fromOffset(12, 28),
			Size = UDim2.new(1, -24, 0, 22),
			BackgroundTransparency = 1,
			Active = true,
		}, holder)

		local hovering, dragging = false, false

		local function grow()
			local big = hovering or dragging
			tween(knob, 0.14, { Size = big and UDim2.fromOffset(18, 18) or UDim2.fromOffset(14, 14) }, "Quint")
			tween(edge, 0.14, {
				Color = big and theme.accent2 or theme.line,
				Transparency = big and 0.45 or 0.55,
			})
		end

		local function apply(v, silent, instant)
			value = clamp(v, minV, maxV)
			local span = maxV - minV
			local fraction = 0
			if span > 0 then
				fraction = (value - minV) / span
			end
			local t = instant and 0 or 0.14
			tween(fill, t, { Size = UDim2.new(fraction, 0, 1, 0) })
			tween(knob, t, { Position = UDim2.new(fraction, 0, 0.5, 0) })
			valueLabel.Text = fmtNum(value) .. suffix
			if props.Flag then
				AegisUI.Values[props.Flag] = value
			end
			if not silent then
				fire(props.Callback, value)
			end
			return value
		end

		local function applyX(x)
			local fraction = dragFraction(track, x)
			if not fraction then return end
			local v = minV + fraction * (maxV - minV)
			if step > 0 then
				v = minV + round((v - minV) / step) * step
			end
			apply(clamp(v, minV, maxV), false, true)
		end

		on(hit.MouseEnter, function()
			hovering = true
			grow()
		end)
		on(hit.MouseLeave, function()
			hovering = false
			grow()
		end)
		on(hit.InputBegan, function(input)
			if not isPointerDown(input) then return end
			dragging = true
			sliderDrag = function(x)
				applyX(x)
			end
			sliderRelease = function()
				dragging = false
				grow()
			end
			grow()
			applyX(input.Position.X)
		end)

		apply(value, true, true)

		local element = {}
		function element:Set(v, silent)
			return apply(tonumber(v) or minV, silent, false)
		end
		function element:Get()
			return value
		end
		function element:SetRange(lo, hi)
			if finite(lo) and finite(hi) and hi > lo then
				minV, maxV = lo, hi
				apply(clamp(value, minV, maxV), true, true)
			end
			return minV, maxV
		end
		function element:Destroy()
			pcall(function()
				holder:Destroy()
			end)
		end

		return finish(element, props, holder)
	end

	------------------------------------------------------------------
	-- textbox   (fires on FocusLost; the border lights up while typing)
	------------------------------------------------------------------

	function section:MakeTextBox(props)
		props = props or {}
		if section:__dead() then return nil end

		local holder = makeCard(props.Name or props.Text or "TextBox", 56)

		paint("TextLabel", {
			Name = "Label",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(12, 6),
			Size = UDim2.new(1, -24, 0, 14),
			Font = Enum.Font.Gotham,
			Text = tostring(props.Text or props.Name or "Value"),
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, holder, { TextColor3 = "dim" })

		local box = paint("TextBox", {
			Name = "Input",
			Position = UDim2.fromOffset(8, 23),
			Size = UDim2.new(1, -16, 0, 26),
			BorderSizePixel = 0,
			Font = Enum.Font.Code,
			Text = tostring(props.Default or ""),
			PlaceholderText = tostring(props.Placeholder or ""),
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			ClearTextOnFocus = false,
		}, holder, { BackgroundColor3 = "bg", TextColor3 = "text", PlaceholderColor3 = "dim" })
		corner(box, 6)
		pad(box, 0, 0, 8, 8)
		local boxEdge = pstroke(paint, box, "line", 0.4)

		local function commit(silent)
			local text = box.Text
			if props.Flag then
				AegisUI.Values[props.Flag] = text
			end
			if not silent then
				fire(props.Callback, text)
			end
			return text
		end

		on(box.Focused, function()
			tween(boxEdge, 0.12, { Color = theme.accent, Transparency = 0 })
		end)
		on(box.FocusLost, function()
			tween(boxEdge, 0.16, { Color = theme.line, Transparency = 0.4 })
			commit(false)
		end)

		local element = {}
		function element:Set(text, silent)
			box.Text = tostring(text or "")
			return commit(silent)
		end
		function element:Get()
			return box.Text
		end
		function element:Destroy()
			pcall(function()
				holder:Destroy()
			end)
		end

		return finish(element, props, holder)
	end

	------------------------------------------------------------------
	-- dropdown (accordion: the list grows inline, so nothing can clip it)
	--   Multi = true -> several options can be ticked, Get() returns an array
	------------------------------------------------------------------

	function section:MakeDropdown(props)
		props = props or {}
		if section:__dead() then return nil end

		local multi = props.Multi == true
		local options = {}
		if type(props.Options) == "table" then
			for i, v in ipairs(props.Options) do
				options[i] = tostring(v)
			end
		end

		local holder, hedge = makeCard(props.Name or props.Text or "Dropdown", 34, true)
		vlist(holder, 0)

		local head = create("TextButton", {
			Name = "Head",
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, 34),
			BackgroundTransparency = 1,
			Text = "",
			AutoButtonColor = false,
		}, holder)

		rowLabel(head, props.Text or props.Name or "Dropdown", 12, -150, "text")

		local valueLabel = paint("TextLabel", {
			Name = "Value",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -30, 0.5, 0),
			Size = UDim2.fromOffset(120, 16),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamSemibold,
			Text = "none",
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Right,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, head, { TextColor3 = "accent" })

		local chevron = paint("TextLabel", {
			Name = "Chevron",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -12, 0.5, 0),
			Size = UDim2.fromOffset(14, 14),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = ">",
			TextSize = 12,
		}, head, { TextColor3 = "dim" })

		local listFrame = create("Frame", {
			Name = "List",
			LayoutOrder = 2,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Visible = false,
		}, holder)
		pad(listFrame, 0, 6, 6, 6)
		vlist(listFrame, 2)

		local value = nil
		local chosen = {}
		local optionButtons = {}
		local isOpen = false

		local function selectedList()
			local out = {}
			for _, name in ipairs(options) do
				if chosen[name] then
					out[#out + 1] = name
				end
			end
			return out
		end

		local function current()
			if multi then
				return selectedList()
			end
			return value
		end

		local function display()
			if multi then
				local list = selectedList()
				if #list == 0 then return "none" end
				if #list == 1 then return list[1] end
				return tostring(#list) .. " selected"
			end
			return value or "none"
		end

		local function refresh()
			for i, rec in ipairs(optionButtons) do
				local name = options[i]
				local selected
				if multi then
					selected = chosen[name] == true
				else
					selected = name == value
				end
				rec.button.TextColor3 = selected and theme.accent or theme.text
				rec.mark.Visible = selected
			end
			valueLabel.Text = display()
		end

		local function commit(silent)
			local v = current()
			if props.Flag then
				AegisUI.Values[props.Flag] = v
			end
			if not silent then
				fire(props.Callback, v)
			end
			return v
		end

		local function set(v, silent)
			if multi then
				local want = {}
				if type(v) == "table" then
					for _, name in ipairs(v) do
						want[tostring(name)] = true
					end
				elseif v ~= nil then
					want[tostring(v)] = true
				end
				chosen = {}
				for _, name in ipairs(options) do
					if want[name] then
						chosen[name] = true
					end
				end
			else
				local match = nil
				for _, name in ipairs(options) do
					if name == tostring(v) then
						match = name
						break
					end
				end
				if match == nil then
					return value
				end
				value = match
			end
			refresh()
			return commit(silent)
		end

		local function setOpen(state)
			isOpen = state and true or false
			listFrame.Visible = isOpen
			tween(chevron, 0.2, { Rotation = isOpen and 90 or 0 }, "Quint")
			tween(hedge, 0.15, {
				Color = isOpen and theme.accent or theme.line,
				Transparency = isOpen and 0.25 or 0.55,
			})
		end

		local function buildOptions()
			for _, rec in ipairs(optionButtons) do
				pcall(function()
					rec.button:Destroy()
				end)
			end
			optionButtons = {}
			for i, name in ipairs(options) do
				local btn = paint("TextButton", {
					Name = name,
					LayoutOrder = i,
					Size = UDim2.new(1, 0, 0, 28),
					BackgroundTransparency = 1,
					BorderSizePixel = 0,
					Font = Enum.Font.Gotham,
					Text = name,
					TextSize = 12,
					TextXAlignment = Enum.TextXAlignment.Left,
					AutoButtonColor = false,
				}, listFrame, { BackgroundColor3 = "hover", TextColor3 = "text" })
				corner(btn, 6)
				pad(btn, 0, 0, 10, 24)
				local mark = paint("Frame", {
					Name = "Mark",
					AnchorPoint = Vector2.new(1, 0.5),
					Position = UDim2.new(1, 12, 0.5, 0),
					Size = UDim2.fromOffset(6, 6),
					BorderSizePixel = 0,
					Visible = false,
				}, btn, { BackgroundColor3 = "accent" })
				corner(mark, 3)
				optionButtons[i] = { button = btn, mark = mark }

				on(btn.MouseEnter, function()
					tween(btn, 0.1, { BackgroundTransparency = 0.45 })
				end)
				on(btn.MouseLeave, function()
					tween(btn, 0.14, { BackgroundTransparency = 1 })
				end)
				on(btn.MouseButton1Click, function()
					if multi then
						chosen[name] = (not chosen[name]) or nil
						refresh()
						commit(false)
					else
						set(name, false)
						setOpen(false)
					end
				end)
			end
		end

		buildOptions()

		on(head.MouseButton1Click, function()
			setOpen(not isOpen)
		end)

		if multi then
			set(props.Default, true)
		elseif props.Default ~= nil then
			set(props.Default, true)
		elseif #options > 0 then
			set(options[1], true)
		end
		refresh()
		restyle(function()
			refresh()
			setOpen(isOpen)
		end)

		local element = {}
		function element:Set(v, silent)
			return set(v, silent)
		end
		function element:Get()
			return current()
		end
		function element:SetOptions(list, keep)
			options = {}
			for i, v in ipairs(list or {}) do
				options[i] = tostring(v)
			end
			if keep ~= true then
				value = nil
				chosen = {}
			else
				local still = {}
				for _, name in ipairs(options) do
					if chosen[name] then still[name] = true end
				end
				chosen = still
				local found = false
				for _, name in ipairs(options) do
					if name == value then found = true end
				end
				if not found then value = nil end
			end
			buildOptions()
			refresh()
			if props.Flag then
				AegisUI.Values[props.Flag] = current()
			end
			return #options
		end
		function element:Toggle()
			setOpen(not isOpen)
			return isOpen
		end
		function element:Destroy()
			pcall(function()
				holder:Destroy()
			end)
		end

		return finish(element, props, holder)
	end

	------------------------------------------------------------------
	-- keybind
	--   Callback(keyName)  fires when the bound key is pressed
	--   Changed(keyName)   fires when the binding changes (nil = cleared)
	--   click the chip, press a key; Escape clears the binding
	------------------------------------------------------------------

	function section:MakeKeybind(props)
		props = props or {}
		if section:__dead() then return nil end

		local row = makeRow(props.Name or props.Text or "Keybind", props.Height or 34)
		rowLabel(row, props.Text or props.Name or "Keybind", 12, -120, "text")

		local chip = paint("Frame", {
			Name = "Chip",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -10, 0.5, 0),
			Size = UDim2.fromOffset(92, 22),
			BorderSizePixel = 0,
		}, row, { BackgroundColor3 = "bg" })
		corner(chip, 6)
		local chipEdge = pstroke(paint, chip, "line", 0.4)

		local chipText = paint("TextLabel", {
			Name = "Key",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Font = Enum.Font.Code,
			Text = "None",
			TextSize = 12,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, chip, { TextColor3 = "accent" })

		local key = nil
		local listening = false

		local function resolve(v)
			if v == nil or v == "" or v == "None" then return nil end
			if type(v) == "string" then
				local ok, item = pcall(function()
					return Enum.KeyCode[v]
				end)
				if ok then return item end
				return nil
			end
			local ok, name = pcall(function()
				return v.Name
			end)
			if ok and type(name) == "string" then
				local ok2, item = pcall(function()
					return Enum.KeyCode[name]
				end)
				if ok2 then return item end
			end
			return nil
		end

		local function look()
			chipText.Text = listening and "press a key" or (key and key.Name or "None")
			chipText.TextColor3 = listening and theme.warn or theme.accent
			tween(chipEdge, 0.12, {
				Color = listening and theme.accent or theme.line,
				Transparency = listening and 0 or 0.4,
			})
		end

		local function set(v, silent)
			key = resolve(v)
			listening = false
			look()
			local name = key and key.Name or nil
			if props.Flag then
				AegisUI.Values[props.Flag] = name or "None"
			end
			if not silent then
				fire(props.Changed, name)
			end
			return name
		end

		local function endListening()
			defer(function()
				capturing = false
			end)
		end

		on(row.MouseButton1Click, function()
			if listening then
				listening = false
				endListening()
			else
				listening = true
				capturing = true
			end
			look()
		end)

		on(UIS and UIS.InputBegan, function(input, processed)
			if not win.Alive then return end
			if listening then
				if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
				local kc = input.KeyCode
				endListening()
				if kc == Enum.KeyCode.Escape then
					set(nil, false)
				else
					set(kc, false)
				end
				return
			end
			if processed or not key then return end
			if input.KeyCode == key then
				fire(props.Callback, key.Name)
			end
		end)

		set(props.Default, true)
		restyle(look)

		local element = {}
		function element:Set(v, silent)
			return set(v, silent)
		end
		function element:Get()
			return key and key.Name or "None"
		end
		function element:Destroy()
			pcall(function()
				row:Destroy()
			end)
		end

		return finish(element, props, row)
	end

	------------------------------------------------------------------
	-- colour picker: hue / saturation / brightness bars, hex readout
	--   Callback(Color3) fires on every change
	------------------------------------------------------------------

	function section:MakeColorPicker(props)
		props = props or {}
		if section:__dead() then return nil end

		local holder, hedge = makeCard(props.Name or props.Text or "Colour", 34, true)
		vlist(holder, 0)

		local head = create("TextButton", {
			Name = "Head",
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, 34),
			BackgroundTransparency = 1,
			Text = "",
			AutoButtonColor = false,
		}, holder)
		rowLabel(head, props.Text or props.Name or "Colour", 12, -90, "text")

		local swatch = create("Frame", {
			Name = "Swatch",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -30, 0.5, 0),
			Size = UDim2.fromOffset(34, 16),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
		}, head)
		corner(swatch, 5)
		create("UIStroke", { Color = Color3.new(1, 1, 1), Transparency = 0.75, Thickness = 1 }, swatch)

		local chevron = paint("TextLabel", {
			Name = "Chevron",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -12, 0.5, 0),
			Size = UDim2.fromOffset(14, 14),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = ">",
			TextSize = 12,
		}, head, { TextColor3 = "dim" })

		local panelFrame = create("Frame", {
			Name = "Bars",
			LayoutOrder = 2,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Visible = false,
		}, holder)
		pad(panelFrame, 2, 10, 12, 12)
		vlist(panelFrame, 8)

		local seed = props.Default
		if typeOf(seed) ~= "Color3" then
			seed = theme.accent
		end
		local h, s, v = seed:ToHSV()

		local function colour()
			return Color3.fromHSV(h, s, v)
		end

		local bars = {}
		local rainbow = {}
		for i = 0, 6 do
			rainbow[#rainbow + 1] = ColorSequenceKeypoint.new(i / 6, Color3.fromHSV(i / 6, 1, 1))
		end

		local function makeBar(index, name, which)
			local line = create("Frame", {
				Name = name .. "Bar",
				LayoutOrder = index,
				Size = UDim2.new(1, 0, 0, 20),
				BackgroundTransparency = 1,
			}, panelFrame)

			paint("TextLabel", {
				Name = "Label",
				BackgroundTransparency = 1,
				Size = UDim2.new(0, 76, 1, 0),
				Font = Enum.Font.Gotham,
				Text = name,
				TextSize = 11,
				TextXAlignment = Enum.TextXAlignment.Left,
			}, line, { TextColor3 = "dim" })

			local track = create("Frame", {
				Name = "Track",
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 80, 0.5, 0),
				Size = UDim2.new(1, -80, 0, 10),
				BackgroundColor3 = Color3.new(1, 1, 1),
				BorderSizePixel = 0,
			}, line)
			corner(track, 5)
			local grad = create("UIGradient", {}, track)

			local knob = create("Frame", {
				Name = "Knob",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0, 0, 0.5, 0),
				Size = UDim2.fromOffset(14, 14),
				BackgroundColor3 = Color3.new(1, 1, 1),
				BorderSizePixel = 0,
				ZIndex = 3,
			}, track)
			corner(knob, 7)
			create("UIStroke", { Color = Color3.new(0, 0, 0), Transparency = 0.55, Thickness = 1 }, knob)

			local hit = create("Frame", {
				Name = "Hit",
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 80, 0.5, 0),
				Size = UDim2.new(1, -80, 1, 0),
				BackgroundTransparency = 1,
				Active = true,
			}, line)

			local function drag(x)
				local fraction = dragFraction(track, x)
				if not fraction then return end
				if which == "h" then
					h = fraction
				elseif which == "s" then
					s = fraction
				else
					v = fraction
				end
				bars.render()
				bars.commit(false)
			end

			on(hit.InputBegan, function(input)
				if not isPointerDown(input) then return end
				sliderDrag = drag
				drag(input.Position.X)
			end)

			bars[which] = { grad = grad, knob = knob }
		end

		makeBar(1, "Hue", "h")
		makeBar(2, "Saturation", "s")
		makeBar(3, "Brightness", "v")

		local hexLabel = paint("TextLabel", {
			Name = "Hex",
			LayoutOrder = 4,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 14),
			Font = Enum.Font.Code,
			Text = "",
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, panelFrame, { TextColor3 = "dim" })

		function bars.render()
			local c = colour()
			swatch.BackgroundColor3 = c
			bars.h.grad.Color = ColorSequence.new(rainbow)
			bars.s.grad.Color = ColorSequence.new(Color3.fromHSV(h, 0, v), Color3.fromHSV(h, 1, v))
			bars.v.grad.Color = ColorSequence.new(Color3.fromHSV(h, s, 0), Color3.fromHSV(h, s, 1))
			bars.h.knob.Position = UDim2.new(h, 0, 0.5, 0)
			bars.s.knob.Position = UDim2.new(s, 0, 0.5, 0)
			bars.v.knob.Position = UDim2.new(v, 0, 0.5, 0)
			hexLabel.Text = string.format("%s    rgb(%d, %d, %d)", toHex(c),
				round(c.R * 255), round(c.G * 255), round(c.B * 255))
		end

		function bars.commit(silent)
			local c = colour()
			if props.Flag then
				AegisUI.Values[props.Flag] = c
			end
			if not silent then
				fire(props.Callback, c)
			end
			return c
		end

		local isOpen = false
		local function setOpen(state)
			isOpen = state and true or false
			panelFrame.Visible = isOpen
			tween(chevron, 0.2, { Rotation = isOpen and 90 or 0 }, "Quint")
			tween(hedge, 0.15, {
				Color = isOpen and theme.accent or theme.line,
				Transparency = isOpen and 0.25 or 0.55,
			})
		end
		on(head.MouseButton1Click, function()
			setOpen(not isOpen)
		end)

		local function parse(c)
			if typeOf(c) == "Color3" then return c end
			if type(c) == "string" then
				local r, g, b = c:match("^#?(%x%x)(%x%x)(%x%x)$")
				if r then
					return Color3.fromRGB(tonumber(r, 16), tonumber(g, 16), tonumber(b, 16))
				end
			end
			return nil
		end

		bars.render()
		restyle(function()
			setOpen(isOpen)
		end)

		local element = {}
		function element:Set(c, silent)
			local parsed = parse(c)
			if not parsed then return colour() end
			h, s, v = parsed:ToHSV()
			bars.render()
			return bars.commit(silent)
		end
		function element:Get()
			return colour()
		end
		function element:Toggle()
			setOpen(not isOpen)
			return isOpen
		end
		function element:Destroy()
			pcall(function()
				holder:Destroy()
			end)
		end

		return finish(element, props, holder)
	end

	------------------------------------------------------------------
	-- progress bar (0..1). Not saved by configs: it reports, it is not a setting.
	------------------------------------------------------------------

	function section:MakeProgress(props)
		props = props or {}
		if section:__dead() then return nil end

		local holder = makeCard(props.Name or props.Text or "Progress", 46)

		local label = rowLabel(holder, props.Text or props.Name or "Progress", 12, -80, "text")
		label.Position = UDim2.fromOffset(12, 7)
		label.Size = UDim2.new(1, -80, 0, 20)

		local pct = paint("TextLabel", {
			Name = "Percent",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -12, 0, 8),
			Size = UDim2.fromOffset(60, 18),
			BackgroundTransparency = 1,
			Font = Enum.Font.Code,
			Text = "0%",
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Right,
		}, holder, { TextColor3 = "accent" })

		local track = paint("Frame", {
			Name = "Track",
			Position = UDim2.fromOffset(12, 31),
			Size = UDim2.new(1, -24, 0, 6),
			BorderSizePixel = 0,
		}, holder, { BackgroundColor3 = "line" })
		corner(track, 3)

		local fill = create("Frame", {
			Name = "Fill",
			Size = UDim2.new(0, 0, 1, 0),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
		}, track)
		corner(fill, 3)
		gradient(fill, 0)

		local value = 0
		local function apply(v, text)
			value = clamp(finite(v) and v or 0, 0, 1)
			tween(fill, 0.3, { Size = UDim2.new(value, 0, 1, 0) }, "Quint")
			pct.Text = text or (tostring(round(value * 100)) .. "%")
			if props.Flag then
				AegisUI.Values[props.Flag] = value
			end
			return value
		end
		apply(props.Default or 0)

		local element = { NoSave = true }
		function element:Set(v, text)
			return apply(tonumber(v) or 0, text)
		end
		function element:Get()
			return value
		end
		function element:SetText(text)
			label.Text = tostring(text or "")
			return label.Text
		end
		function element:Destroy()
			pcall(function()
				holder:Destroy()
			end)
		end

		return finish(element, props, holder)
	end

	------------------------------------------------------------------
	-- divider
	------------------------------------------------------------------

	function section:MakeDivider()
		if section:__dead() then return nil end
		local line = paint("Frame", {
			Name = "Divider",
			LayoutOrder = nextOrder(),
			Size = UDim2.new(1, 0, 0, 1),
			BackgroundTransparency = 0.45,
			BorderSizePixel = 0,
		}, contentFrame, { BackgroundColor3 = "line" })
		return line
	end

	function section:Destroy()
		pcall(function()
			frame:Destroy()
		end)
		section.Elements = {}
		return true
	end

	tab.Sections[#tab.Sections + 1] = section
	return section
end

--------------------------------------------------------------------------
-- 7a. config section: a ready-made save / load panel for a tab
--------------------------------------------------------------------------

function makeConfigSection(tab, title)
	local win = tab.Window
	local sec = makeSection(tab, title or "Configs")
	if not sec then return nil end

	local nameBox = sec:MakeTextBox({
		Text = "Config name",
		Placeholder = "default",
		Default = "default",
	})
	local list
	local status = sec:MakeLabel({
		Text = hasFiles() and "Saved to the executor's workspace folder."
			or "No file access here. Use AegisUI:ExportConfig() instead.",
		TextSize = 11,
	})

	local function refreshList()
		if list then
			list:SetOptions(AegisUI:ListConfigs(), false)
		end
	end

	list = sec:MakeDropdown({
		Text = "Saved configs",
		Options = AegisUI:ListConfigs(),
		Callback = function(name)
			if nameBox and name then
				nameBox:Set(name, true)
			end
		end,
	})

	local function say(ok, message)
		status:Set(message)
		win:Notify({
			Title = ok and "Config" or "Config failed",
			Text = message,
			Type = ok and "success" or "error",
		})
	end

	local function chosenName()
		local name = nameBox and nameBox:Get() or ""
		if name == "" then name = "default" end
		return name
	end

	sec:MakeButton({
		Text = "Save",
		Style = "primary",
		Callback = function()
			local ok, info = AegisUI:SaveConfig(chosenName())
			say(ok, ok and ("saved " .. chosenName()) or tostring(info))
			if ok then refreshList() end
		end,
	})
	sec:MakeButton({
		Text = "Load",
		Callback = function()
			local count, err = AegisUI:LoadConfig(chosenName())
			if err then
				say(false, tostring(err))
			else
				say(true, "loaded " .. chosenName() .. " (" .. tostring(count) .. " settings)")
			end
		end,
	})
	sec:MakeButton({
		Text = "Delete",
		Style = "danger",
		Callback = function()
			local ok, err = AegisUI:DeleteConfig(chosenName())
			say(ok, ok and ("deleted " .. chosenName()) or tostring(err))
			if ok then refreshList() end
		end,
	})
	sec:MakeButton({
		Text = "Refresh list",
		Callback = refreshList,
	})

	return sec
end

--------------------------------------------------------------------------
-- 8. publish the handle at load time
--------------------------------------------------------------------------

genv.AegisUI = {
	version = AegisUI.Version,
	lib     = AegisUI,
	window  = nil,
	api     = buildApi(nil),
	state = {
		collapsed = false,
		values    = AegisUI.Values,
	},
}

return AegisUI
