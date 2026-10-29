--[[
	AegisUI - v1.0.0

	A self-contained Roblox UI library built to the AegisInject house contract
	(docs/AUTHORING.md, "Panel lifecycle"). No external assets, no loadstring of
	remote code, no executor-specific global outside a pcall.

	USAGE
	    -- once per session: execute this file (aegis exec Scripts\AegisUI.lua)
	    -- then, from any later chunk:
	    local AegisUI = getgenv().AegisUI.lib

	    local Win = AegisUI:MakeWindow({ Name = "My Script", Subtitle = "v1" })
	    local Tab = Win:MakeTab("Main")
	    local Sec = Tab:MakeSection("Automation")

	    Sec:MakeButton({ Text = "Run", Callback = function() print("run") end })
	    Sec:MakeToggle({ Text = "Auto farm", Flag = "AutoFarm", Callback = function(v) print(v) end })
	    Sec:MakeSlider({ Text = "Speed", Flag = "Speed", Min = 16, Max = 200, Default = 16 })
	    Sec:MakeTextBox({ Text = "Webhook", Flag = "Hook" })
	    Sec:MakeDropdown({ Text = "Mode", Flag = "Mode", Options = { "Left", "Right" } })

	WHAT IT GUARANTEES
	  * ScreenGui is created disabled, parented, fully built, then enabled -- never
	    enabled while it has no parent (aegis_gui.lua / Rayfield parenting order).
	  * DisplayOrder 999999 so Roblox's own menu cannot cover the panel.
	  * The close control COLLAPSES to a badge. It never hides the gui: from the
	    user's side a hidden gui is indistinguishable from a dead script.
	  * Unloading is reachable only from the sidebar Unload button and
	    AegisUI:Unload(). Keys collapse and restore; they do not exit.
	  * Every control with a Flag is readable from another chunk through
	    getgenv().AegisUI.api (set / get / getall / collapse / restore / notify /
	    unload), so a probe can inspect and drive the panel without a mouse.
	  * A previous instance is swept on load, and the connections it left on
	    services are disconnected, so re-exec cannot stack two panels.

	NOT IMPLEMENTED (deliberate, not stubbed)
	  * Config persistence. Orion's SaveConfig/ConfigFolder keys are accepted and
	    ignored; flags live in memory for the session only.
	  * Icons, tween easing and multi-select dropdowns.
]]

local AegisUI = {}

AegisUI.Name    = "AegisUI"
AegisUI.Version = "1.0.0"

local genv      = (type(getgenv) == "function" and getgenv()) or _G
local GUI_NAME  = "AegisUI"
local CONN_KEY  = "AegisUIConn"

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
	return string.format("%.2f", n)
end

local function fire(fn, ...)
	if type(fn) ~= "function" then return end
	if type(task) == "table" and type(task.spawn) == "function" then
		task.spawn(fn, ...)
	else
		fn(...)
	end
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

local DEFAULT_THEME = {
	bg      = Color3.fromRGB(16, 18, 24),
	surface = Color3.fromRGB(23, 26, 35),
	row     = Color3.fromRGB(19, 22, 29),
	hover   = Color3.fromRGB(33, 38, 50),
	line    = Color3.fromRGB(45, 52, 68),
	text    = Color3.fromRGB(226, 232, 240),
	dim     = Color3.fromRGB(130, 141, 160),
	accent  = Color3.fromRGB(96, 214, 255),
	accent2 = Color3.fromRGB(72, 128, 255),
	ok      = Color3.fromRGB(110, 231, 149),
	warn    = Color3.fromRGB(255, 196, 92),
	err     = Color3.fromRGB(255, 112, 112),
}

local function copyTheme(over)
	local t = {}
	for k, v in pairs(DEFAULT_THEME) do
		t[k] = v
	end
	if type(over) == "table" then
		for k, v in pairs(over) do
			if DEFAULT_THEME[k] ~= nil then
				t[k] = v
			end
		end
	end
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

local function stroke(inst, colour, transparency, thickness)
	return create("UIStroke", {
		Color = colour,
		Transparency = transparency or 0.35,
		Thickness = thickness or 1,
	}, inst)
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

local function tween(inst, time, props)
	if TweenService then
		local t = TweenService:Create(inst, TweenInfo.new(time), props)
		t:Play()
		return t
	end
	for k, v in pairs(props) do
		inst[k] = v
	end
	return nil
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

local function registerFlag(flag, element)
	if type(flag) ~= "string" or flag == "" then return end
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
-- 6. window
--
-- Two forward declarations, both load-bearing:
--   makeSection  -- tab:MakeSection is bound inside MakeTab, but the section
--                   implementation lives below the window builder
--   sliderDrag   -- assigned by a slider's InputBegan and cleared by the one
--                   InputEnded handler created here; a local declared later
--                   would leave the handler reading a different variable
--------------------------------------------------------------------------

local makeSection
local sliderDrag = nil

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
		notify   = function(props) return call("Notify", props) end,
		unload   = function() return call("Unload", "api") end,
		tabs     = function()
			if not win then return 0 end
			return #win.Tabs
		end,
	}
end

function AegisUI:MakeWindow(options)
	options = options or {}
	local theme = copyTheme(options.Theme)

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

	------------------------------------------------------------------
	-- panel
	------------------------------------------------------------------

	local panel = create("Frame", {
		Name = "Panel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(options.Width or 480, options.Height or 340),
		BackgroundColor3 = theme.bg,
		BorderSizePixel = 0,
		ClipsDescendants = true,
	}, gui)
	corner(panel, 10)
	stroke(panel, theme.line, 0.15)
	win.Panel = panel

	------------------------------------------------------------------
	-- header
	------------------------------------------------------------------

	local header = create("Frame", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, 40),
		BackgroundColor3 = theme.surface,
		BorderSizePixel = 0,
		Active = true,           -- non-Active frames receive no mouse input
	}, panel)

	create("UIGradient", {
		Color = ColorSequence.new(theme.accent, theme.accent2),
		Rotation = 90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.86),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, header)

	local title = create("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.new(1, -50, 0, 16),
		Font = Enum.Font.GothamBold,
		Text = tostring(options.Name or "AegisUI"),
		TextSize = 13,
		TextColor3 = theme.text,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, header)

	local subtitle = create("TextLabel", {
		Name = "Subtitle",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12, 22),
		Size = UDim2.new(1, -50, 0, 12),
		Font = Enum.Font.Gotham,
		Text = tostring(options.Subtitle or ("AegisUI " .. AegisUI.Version)),
		TextSize = 10,
		TextColor3 = theme.dim,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, header)

	local closeBtn = create("TextButton", {
		Name = "Collapse",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(26, 26),
		Font = Enum.Font.GothamBold,
		Text = "-",
		TextSize = 15,
		TextColor3 = theme.dim,
		AutoButtonColor = false,
	}, header)

	------------------------------------------------------------------
	-- body: sidebar + content
	------------------------------------------------------------------

	local body = create("Frame", {
		Name = "Body",
		Position = UDim2.fromOffset(0, 40),
		Size = UDim2.new(1, 0, 1, -40),
		BackgroundTransparency = 1,
	}, panel)

	local sidebar = create("Frame", {
		Name = "Sidebar",
		Size = UDim2.new(0, 132, 1, 0),
		BackgroundColor3 = theme.bg,
		BorderSizePixel = 0,
	}, body)
	pad(sidebar, 8, 8, 8, 8)
	vlist(sidebar, 4)

	create("Frame", {
		Name = "Divider",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.new(0, 1, 1, 0),
		BackgroundColor3 = theme.line,
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
		ZIndex = 5,
	}, sidebar)

	local content = create("Frame", {
		Name = "Content",
		Position = UDim2.fromOffset(132, 0),
		Size = UDim2.new(1, -132, 1, 0),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
	}, body)

	local unloadBtn = create("TextButton", {
		Name = "Unload",
		LayoutOrder = 100000,
		Size = UDim2.new(1, 0, 0, 24),
		BackgroundColor3 = theme.row,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamSemibold,
		Text = "Unload",
		TextSize = 11,
		TextColor3 = theme.err,
		AutoButtonColor = false,
	}, sidebar)
	corner(unloadBtn, 6)
	stroke(unloadBtn, theme.line, 0.6)

	------------------------------------------------------------------
	-- notifications
	------------------------------------------------------------------

	local notifyHolder = create("Frame", {
		Name = "Notifications",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 12),
		Size = UDim2.fromOffset(240, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, gui)
	vlist(notifyHolder, 6, Enum.HorizontalAlignment.Right)
	win.NotifyHolder = notifyHolder

	------------------------------------------------------------------
	-- badge (the collapse target; sibling of the panel, not a child)
	------------------------------------------------------------------

	local badge = create("TextButton", {
		Name = "Badge",
		Position = UDim2.fromOffset(20, 20),
		Size = UDim2.fromOffset(64, 20),
		BackgroundColor3 = theme.surface,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		Text = "AEGIS",
		TextSize = 10,
		TextColor3 = theme.accent,
		AutoButtonColor = false,
		Visible = false,
	}, gui)
	corner(badge, 6)
	stroke(badge, theme.line, 0.4)
	win.Badge = badge

	------------------------------------------------------------------
	-- collapse / restore
	------------------------------------------------------------------

	function win:Collapse()
		if not win.Alive then return false end
		win.Collapsed = true
		panel.Visible = false
		badge.Visible = true
		return true
	end

	function win:Restore()
		if not win.Alive then return false end
		win.Collapsed = false
		panel.Visible = true
		badge.Visible = false
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
			if other == tab then
				other:__activate(true)
			else
				other:__activate(false)
			end
		end
		win.ActiveTab = tab
		return true
	end

	function win:MakeTab(tabTitle)
		if not win.Alive then return nil end
		tabOrder = tabOrder + 1

		local button = create("TextButton", {
			Name = tostring(tabTitle or "Tab"),
			LayoutOrder = tabOrder,
			Size = UDim2.new(1, 0, 0, 26),
			BackgroundColor3 = theme.surface,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Font = Enum.Font.GothamSemibold,
			Text = tostring(tabTitle or "Tab"),
			TextSize = 11,
			TextColor3 = theme.dim,
			TextXAlignment = Enum.TextXAlignment.Left,
			AutoButtonColor = false,
		}, sidebar)
		corner(button, 6)
		pad(button, 0, 0, 8, 8)

		local page = create("ScrollingFrame", {
			Name = tostring(tabTitle or "Tab") .. "Page",
			Size = UDim2.new(1, 0, 1, 0),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			CanvasSize = UDim2.new(0, 0, 0, 0),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			ScrollBarThickness = 4,
			ScrollBarImageColor3 = theme.line,
			Visible = false,
		}, content)
		pad(page, 10, 10, 10, 10)
		vlist(page, 8)

		local tab = {
			Window = win,
			Button = button,
			Page = page,
			Sections = {},
			Theme = theme,
			-- exposed so Show/Hide can be driven from a probe
			Name = tostring(tabTitle or "Tab"),
		}

		local order = 0
		function tab:__nextOrder()
			order = order + 1
			return order
		end

		function tab:__activate(state)
			page.Visible = state
			if state then
				button.BackgroundTransparency = 0
				button.TextColor3 = theme.text
			else
				button.BackgroundTransparency = 1
				button.TextColor3 = theme.dim
			end
		end

		function tab:MakeSection(sectionTitle)
			return makeSection(tab, sectionTitle)
		end

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
		if processed then return end
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
		panel.Position = UDim2.new(
			startPos.X.Scale, startPos.X.Offset + delta.X,
			startPos.Y.Scale, startPos.Y.Offset + delta.Y
		)
	end)

	on(UIS and UIS.InputEnded, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
			sliderDrag = nil
		end
	end)

	------------------------------------------------------------------
	-- notifications
	------------------------------------------------------------------

	function win:Notify(props)
		props = props or {}
		if not win.Alive or not notifyHolder.Parent then return nil end

		local kind = tostring(props.Type or "info")
		local colour = theme.accent
		if kind == "success" then
			colour = theme.ok
		elseif kind == "error" then
			colour = theme.err
		elseif kind == "warn" or kind == "warning" then
			colour = theme.warn
		end

		local toast = create("Frame", {
			Name = "Toast",
			Size = UDim2.new(1, 0, 0, 46),
			BackgroundColor3 = theme.surface,
			BorderSizePixel = 0,
		}, notifyHolder)
		corner(toast, 7)
		stroke(toast, theme.line, 0.4)

		create("Frame", {
			Name = "Accent",
			Size = UDim2.new(0, 3, 1, 0),
			BackgroundColor3 = colour,
			BorderSizePixel = 0,
		}, toast)

		create("TextLabel", {
			Name = "Title",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(12, 7),
			Size = UDim2.new(1, -20, 0, 14),
			Font = Enum.Font.GothamBold,
			Text = tostring(props.Title or kind),
			TextSize = 11,
			TextColor3 = colour,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, toast)

		create("TextLabel", {
			Name = "Body",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(12, 21),
			Size = UDim2.new(1, -20, 0, 18),
			Font = Enum.Font.Gotham,
			Text = tostring(props.Text or props.Content or ""),
			TextSize = 11,
			TextColor3 = theme.text,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, toast)

		local dismissed = false
		local function dismiss()
			if dismissed then return end
			dismissed = true
			pcall(function()
				toast:Destroy()
			end)
		end

		toast.Active = true
		on(toast.InputBegan, function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				dismiss()
			end
		end)

		local duration = props.Duration
		if not finite(duration) then duration = 3 end
		if duration > 0 then
			if type(task) == "table" and type(task.delay) == "function" then
				task.delay(duration, dismiss)
			else
				dismiss()
			end
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

	on(unloadBtn.MouseButton1Click, function()
		win:Unload("panel")
	end)

	------------------------------------------------------------------
	-- content is complete: now it may be shown
	------------------------------------------------------------------

	gui.Enabled = true

	win.Title    = title
	win.Subtitle = subtitle

	function win:SetTitle(text, sub)
		if not win.Alive then return false end
		if text ~= nil then title.Text = tostring(text) end
		if sub ~= nil then subtitle.Text = tostring(sub) end
		return true
	end

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
-- every slider, and the InputEnded handler in MakeWindow clears it.
--------------------------------------------------------------------------

function makeSection(tab, sectionTitle)
	local theme = tab.Theme

	local frame = create("Frame", {
		Name = tostring(sectionTitle or "Section"),
		LayoutOrder = tab:__nextOrder(),
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = theme.surface,
		BorderSizePixel = 0,
	}, tab.Page)
	corner(frame, 8)
	stroke(frame, theme.line, 0.55)
	vlist(frame, 0)

	local head = create("TextLabel", {
		Name = "Head",
		LayoutOrder = 0,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 24),
		Font = Enum.Font.GothamBold,
		Text = tostring(sectionTitle or "Section"),
		TextSize = 11,
		TextColor3 = theme.dim,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, frame)
	pad(head, 4, 0, 10, 10)

	local contentFrame = create("Frame", {
		Name = "Content",
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, frame)
	pad(contentFrame, 0, 8, 8, 8)
	vlist(contentFrame, 6)

	local section = {
		Tab = tab,
		Frame = frame,
		Content = contentFrame,
		Theme = theme,
		Elements = {},
		Name = tostring(sectionTitle or "Section"),
	}

	local order = 0
	local function nextOrder()
		order = order + 1
		return order
	end

	function section:__dead()
		local win = tab.Window
		if not win or not win.Alive then return true end
		if not frame.Parent then return true end
		return false
	end

	-- a row is a TextButton so the whole strip is clickable; children drawn on
	-- top of it are transparent labels, so the text stays visible.
	local function makeRow(name, height)
		local row = create("TextButton", {
			Name = tostring(name or "Row"),
			LayoutOrder = nextOrder(),
			Size = UDim2.new(1, 0, 0, height or 28),
			BackgroundColor3 = theme.row,
			BorderSizePixel = 0,
			Text = "",
			AutoButtonColor = false,
		}, contentFrame)
		corner(row, 7)
		stroke(row, theme.line, 0.6)
		return row
	end

	local function rowLabel(parent, text, x, width, colour, bold)
		return create("TextLabel", {
			Name = "Label",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(x or 10, 0),
			Size = UDim2.new(1, width or -20, 1, 0),
			Font = bold and Enum.Font.GothamSemibold or Enum.Font.Gotham,
			Text = tostring(text or ""),
			TextSize = 12,
			TextColor3 = colour or theme.text,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, parent)
	end

	------------------------------------------------------------------
	-- label
	------------------------------------------------------------------

	function section:MakeLabel(props)
		props = props or {}
		if section:__dead() then return nil end

		local label = create("TextLabel", {
			Name = tostring(props.Name or "Label"),
			LayoutOrder = nextOrder(),
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Font = Enum.Font.Gotham,
			Text = tostring(props.Text or ""),
			TextSize = props.TextSize or 11,
			TextColor3 = props.Color or theme.dim,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextWrapped = true,
		}, contentFrame)

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
		element.Instance = label

		section.Elements[#section.Elements + 1] = element
		return element
	end

	------------------------------------------------------------------
	-- button
	------------------------------------------------------------------

	function section:MakeButton(props)
		props = props or {}
		if section:__dead() then return nil end

		local row = makeRow(props.Name or props.Text or "Button", props.Height or 28)
		row.Text = tostring(props.Text or props.Name or "Run")
		row.TextSize = 12
		row.TextColor3 = theme.text
		row.TextXAlignment = Enum.TextXAlignment.Center
		row.Font = Enum.Font.GothamSemibold

		local disabled = props.Disabled == true

		local function refresh()
			row.TextColor3 = disabled and theme.dim or theme.text
			row.BackgroundColor3 = theme.row
		end
		refresh()

		on(row.MouseEnter, function()
			if disabled then return end
			tween(row, 0.12, { BackgroundColor3 = theme.hover })
		end)
		on(row.MouseLeave, function()
			if disabled then return end
			refresh()
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
			refresh()
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
		element.Instance = row

		section.Elements[#section.Elements + 1] = element
		return element
	end

	------------------------------------------------------------------
	-- toggle
	------------------------------------------------------------------

	function section:MakeToggle(props)
		props = props or {}
		if section:__dead() then return nil end

		local row = makeRow(props.Name or props.Text or "Toggle", props.Height or 28)
		rowLabel(row, props.Text or props.Name or "Toggle", 10, -60, theme.text)

		local pill = create("Frame", {
			Name = "Pill",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -10, 0.5, 0),
			Size = UDim2.fromOffset(34, 18),
			BackgroundColor3 = theme.line,
			BorderSizePixel = 0,
		}, row)
		corner(pill, 9)

		local knob = create("Frame", {
			Name = "Knob",
			Position = UDim2.fromOffset(2, 2),
			Size = UDim2.fromOffset(14, 14),
			BackgroundColor3 = theme.text,
			BorderSizePixel = 0,
			ZIndex = 2,
		}, pill)
		corner(knob, 7)

		local value = props.Default == true
		local disabled = props.Disabled == true

		local function refresh()
			if disabled then
				pill.BackgroundColor3 = theme.row
				knob.BackgroundColor3 = theme.dim
			elseif value then
				pill.BackgroundColor3 = theme.accent
				knob.BackgroundColor3 = theme.text
			else
				pill.BackgroundColor3 = theme.line
				knob.BackgroundColor3 = theme.text
			end
			knob.Position = value and UDim2.fromOffset(18, 2) or UDim2.fromOffset(2, 2)
		end

		local function set(v, silent)
			value = v and true or false
			refresh()
			if props.Flag then
				AegisUI.Values[props.Flag] = value
			end
			if not silent then
				fire(props.Callback, value)
			end
			return value
		end

		refresh()

		local element = {}
		function element:Set(v)
			return set(v, false)
		end
		function element:Get()
			return value
		end
		function element:SetSilent(v)
			return set(v, true)
		end
		function element:SetDisabled(state)
			disabled = state and true or false
			refresh()
			return disabled
		end
		function element:Destroy()
			pcall(function()
				row:Destroy()
			end)
		end
		element.Instance = row

		on(row.MouseButton1Click, function()
			if disabled then return end
			set(not value, false)
		end)

		registerFlag(props.Flag, element)
		section.Elements[#section.Elements + 1] = element
		return element
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
		local value = clamp((finite(props.Default) and props.Default) or minV, minV, maxV)

		local holder = create("Frame", {
			Name = tostring(props.Name or props.Text or "Slider"),
			LayoutOrder = nextOrder(),
			Size = UDim2.new(1, 0, 0, 46),
			BackgroundColor3 = theme.row,
			BorderSizePixel = 0,
		}, contentFrame)
		corner(holder, 7)
		stroke(holder, theme.line, 0.6)

		create("TextLabel", {
			Name = "Label",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(10, 5),
			Size = UDim2.new(1, -80, 0, 16),
			Font = Enum.Font.Gotham,
			Text = tostring(props.Text or props.Name or "Slider"),
			TextSize = 12,
			TextColor3 = theme.text,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, holder)

		local valueLabel = create("TextLabel", {
			Name = "Value",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -10, 0, 5),
			Size = UDim2.fromOffset(64, 16),
			BackgroundTransparency = 1,
			Font = Enum.Font.Code,
			Text = fmtNum(value),
			TextSize = 11,
			TextColor3 = theme.accent,
			TextXAlignment = Enum.TextXAlignment.Right,
		}, holder)

		local track = create("Frame", {
			Name = "Track",
			Position = UDim2.fromOffset(10, 30),
			Size = UDim2.new(1, -20, 0, 6),
			BackgroundColor3 = theme.line,
			BorderSizePixel = 0,
		}, holder)
		corner(track, 3)

		local fill = create("Frame", {
			Name = "Fill",
			Size = UDim2.new(0, 0, 1, 0),
			BackgroundColor3 = theme.accent,
			BorderSizePixel = 0,
		}, track)
		corner(fill, 3)

		local knob = create("Frame", {
			Name = "Knob",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0, 0, 0.5, 0),
			Size = UDim2.fromOffset(12, 12),
			BackgroundColor3 = theme.text,
			BorderSizePixel = 0,
			ZIndex = 3,
		}, track)
		corner(knob, 6)

		-- a 6px track is a 6px hit target; this invisible strip is the real one
		local hit = create("Frame", {
			Name = "Hit",
			Position = UDim2.fromOffset(10, 22),
			Size = UDim2.new(1, -20, 0, 22),
			BackgroundTransparency = 1,
			Active = true,
		}, holder)

		local function apply(v, silent)
			value = clamp(v, minV, maxV)
			local span = maxV - minV
			local fraction = 0
			if span > 0 then
				fraction = (value - minV) / span
			end
			fill.Size = UDim2.new(fraction, 0, 1, 0)
			knob.Position = UDim2.new(fraction, 0, 0.5, 0)
			valueLabel.Text = fmtNum(value)
			if props.Flag then
				AegisUI.Values[props.Flag] = value
			end
			if not silent then
				fire(props.Callback, value)
			end
			return value
		end

		local function applyX(x)
			local absX = track.AbsolutePosition and track.AbsolutePosition.X or nil
			local width = track.AbsoluteSize and track.AbsoluteSize.X or nil
			if not finite(absX) or not finite(width) or width <= 0 then return end
			local fraction = clamp((x - absX) / width, 0, 1)
			local v = minV + fraction * (maxV - minV)
			if step > 0 then
				v = minV + round((v - minV) / step) * step
			end
			apply(clamp(v, minV, maxV), false)
		end

		on(hit.InputBegan, function(input)
			local kind = input.UserInputType
			if kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch then
				return
			end
			sliderDrag = function(x)
				applyX(x)
			end
			applyX(input.Position.X)
		end)

		apply(value, true)

		local element = {}
		function element:Set(v, silent)
			return apply(tonumber(v) or minV, silent)
		end
		function element:Get()
			return value
		end
		function element:SetRange(lo, hi)
			if finite(lo) and finite(hi) and hi > lo then
				minV, maxV = lo, hi
				apply(clamp(value, minV, maxV), true)
			end
			return minV, maxV
		end
		function element:Destroy()
			pcall(function()
				holder:Destroy()
			end)
		end
		element.Instance = holder

		registerFlag(props.Flag, element)
		section.Elements[#section.Elements + 1] = element
		return element
	end

	------------------------------------------------------------------
	-- textbox
	------------------------------------------------------------------

	function section:MakeTextBox(props)
		props = props or {}
		if section:__dead() then return nil end

		local holder = create("Frame", {
			Name = tostring(props.Name or props.Text or "TextBox"),
			LayoutOrder = nextOrder(),
			Size = UDim2.new(1, 0, 0, 46),
			BackgroundColor3 = theme.row,
			BorderSizePixel = 0,
		}, contentFrame)
		corner(holder, 7)
		stroke(holder, theme.line, 0.6)

		create("TextLabel", {
			Name = "Label",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(10, 4),
			Size = UDim2.new(1, -20, 0, 14),
			Font = Enum.Font.Gotham,
			Text = tostring(props.Text or props.Name or "Value"),
			TextSize = 11,
			TextColor3 = theme.dim,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, holder)

		local box = create("TextBox", {
			Name = "Input",
			Position = UDim2.fromOffset(8, 20),
			Size = UDim2.new(1, -16, 0, 20),
			BackgroundColor3 = theme.bg,
			BorderSizePixel = 0,
			Font = Enum.Font.Code,
			Text = tostring(props.Default or ""),
			PlaceholderText = tostring(props.Placeholder or ""),
			PlaceholderColor3 = theme.dim,
			TextSize = 11,
			TextColor3 = theme.text,
			TextXAlignment = Enum.TextXAlignment.Left,
			ClearTextOnFocus = false,
		}, holder)
		corner(box, 5)
		pad(box, 0, 0, 6, 6)

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

		on(box.FocusLost, function()
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
		element.Instance = holder

		registerFlag(props.Flag, element)
		section.Elements[#section.Elements + 1] = element
		return element
	end

	------------------------------------------------------------------
	-- dropdown (accordion: the list grows inline, so nothing can clip it)
	------------------------------------------------------------------

	function section:MakeDropdown(props)
		props = props or {}
		if section:__dead() then return nil end

		local options = {}
		if type(props.Options) == "table" then
			for i, v in ipairs(props.Options) do
				options[i] = tostring(v)
			end
		end

		local holder = create("Frame", {
			Name = tostring(props.Name or props.Text or "Dropdown"),
			LayoutOrder = nextOrder(),
			Size = UDim2.new(1, 0, 0, 28),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = theme.row,
			BorderSizePixel = 0,
		}, contentFrame)
		corner(holder, 7)
		stroke(holder, theme.line, 0.6)
		vlist(holder, 0)

		local head = create("TextButton", {
			Name = "Head",
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, 28),
			BackgroundTransparency = 1,
			Text = "",
			AutoButtonColor = false,
		}, holder)

		create("TextLabel", {
			Name = "Label",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(10, 0),
			Size = UDim2.new(1, -80, 1, 0),
			Font = Enum.Font.Gotham,
			Text = tostring(props.Text or props.Name or "Dropdown"),
			TextSize = 12,
			TextColor3 = theme.text,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, head)

		local valueLabel = create("TextLabel", {
			Name = "Value",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -22, 0.5, 0),
			Size = UDim2.fromOffset(100, 16),
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			Text = "none",
			TextSize = 11,
			TextColor3 = theme.accent,
			TextXAlignment = Enum.TextXAlignment.Right,
		}, head)

		create("TextLabel", {
			Name = "Chevron",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -8, 0.5, 0),
			Size = UDim2.fromOffset(10, 16),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = "v",
			TextSize = 9,
			TextColor3 = theme.dim,
			TextXAlignment = Enum.TextXAlignment.Right,
		}, head)

		local listFrame = create("Frame", {
			Name = "List",
			LayoutOrder = 2,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Visible = false,
		}, holder)
		pad(listFrame, 0, 4, 6, 6)
		vlist(listFrame, 2)

		local value = nil
		local optionButtons = {}
		local open = false

		local function refreshColors()
			for i, btn in ipairs(optionButtons) do
				if options[i] == value then
					btn.TextColor3 = theme.accent
				else
					btn.TextColor3 = theme.text
				end
			end
			valueLabel.Text = value or "none"
		end

		local function set(v, silent)
			local match = nil
			for i, name in ipairs(options) do
				if name == v then
					match = name
					break
				end
			end
			if match == nil then
				return value
			end
			value = match
			refreshColors()
			if props.Flag then
				AegisUI.Values[props.Flag] = value
			end
			if not silent then
				fire(props.Callback, value)
			end
			return value
		end

		for i, name in ipairs(options) do
			local btn = create("TextButton", {
				Name = name,
				LayoutOrder = i,
				Size = UDim2.new(1, 0, 0, 22),
				BackgroundColor3 = theme.surface,
				BorderSizePixel = 0,
				Font = Enum.Font.Gotham,
				Text = name,
				TextSize = 11,
				TextColor3 = theme.text,
				TextXAlignment = Enum.TextXAlignment.Left,
				AutoButtonColor = false,
			}, listFrame)
			corner(btn, 5)
			pad(btn, 0, 0, 6, 6)
			optionButtons[i] = btn
			on(btn.MouseButton1Click, function()
				set(name, false)
				open = false
				listFrame.Visible = false
			end)
		end

		on(head.MouseButton1Click, function()
			open = not open
			listFrame.Visible = open
		end)

		if props.Default ~= nil then
			set(props.Default, true)
		elseif #options > 0 then
			set(options[1], true)
		end
		refreshColors()

		local element = {}
		function element:Set(v, silent)
			return set(v, silent)
		end
		function element:Get()
			return value
		end
		function element:SetOptions(list, keep)
			options = {}
			for i, v in ipairs(list or {}) do
				options[i] = tostring(v)
			end
			for _, btn in ipairs(optionButtons) do
				pcall(function()
					btn:Destroy()
				end)
			end
			optionButtons = {}
			for i, name in ipairs(options) do
				local btn = create("TextButton", {
					Name = name,
					LayoutOrder = i,
					Size = UDim2.new(1, 0, 0, 22),
					BackgroundColor3 = theme.surface,
					BorderSizePixel = 0,
					Font = Enum.Font.Gotham,
					Text = name,
					TextSize = 11,
					TextColor3 = theme.text,
					TextXAlignment = Enum.TextXAlignment.Left,
					AutoButtonColor = false,
				}, listFrame)
				corner(btn, 5)
				pad(btn, 0, 0, 6, 6)
				optionButtons[i] = btn
				on(btn.MouseButton1Click, function()
					set(name, false)
					open = false
					listFrame.Visible = false
				end)
			end
			if keep ~= true then
				value = nil
			end
			refreshColors()
			return #options
		end
		function element:Toggle()
			open = not open
			listFrame.Visible = open
			return open
		end
		function element:Destroy()
			pcall(function()
				holder:Destroy()
			end)
		end
		element.Instance = holder

		registerFlag(props.Flag, element)
		section.Elements[#section.Elements + 1] = element
		return element
	end

	------------------------------------------------------------------
	-- divider
	------------------------------------------------------------------

	function section:MakeDivider()
		if section:__dead() then return nil end
		local line = create("Frame", {
			Name = "Divider",
			LayoutOrder = nextOrder(),
			Size = UDim2.new(1, 0, 0, 1),
			BackgroundColor3 = theme.line,
			BackgroundTransparency = 0.4,
			BorderSizePixel = 0,
		}, contentFrame)
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
