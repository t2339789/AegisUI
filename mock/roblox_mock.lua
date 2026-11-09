--[[
	roblox_mock.lua — a permissive stand-in for the Roblox runtime.

	Purpose: run a real AegisUI consumer script headlessly under stock Lua 5.4,
	let the library build its ScreenGui tree exactly as it would in the client,
	then serialise that tree (classes, resolved properties, modifier instances)
	to JSON so render_ui.py can rasterise it. Nothing here draws anything; this
	half only produces ground truth about what the library built.

	usage: lua roblox_mock.lua <consumer.lua> <out.json> [<AegisUI.lua>]
]]

local SCRIPT = assert(arg[1], "usage: roblox_mock.lua <consumer.lua> <out.json> [<AegisUI.lua>]")
local OUT    = arg[2] or "tree.json"
local LIB    = arg[3]

local stderr = io.stderr
local function log(...)
	local n = select("#", ...)
	local parts = {}
	for i = 1, n do parts[i] = tostring((select(i, ...))) end
	stderr:write("[lua] ", table.concat(parts, "\t"), "\n")
end
print = log
warn  = log

--------------------------------------------------------------------------
-- 1. datatypes
--------------------------------------------------------------------------

local UDim = {}
UDim.__index = UDim
function UDim.new(scale, offset)
	return setmetatable({ _t = "UDim", Scale = scale or 0, Offset = offset or 0 }, UDim)
end

local UDim2 = {}
UDim2.__index = UDim2
local function mk2(xs, xo, ys, yo)
	return setmetatable({ _t = "UDim2", X = UDim.new(xs, xo), Y = UDim.new(ys, yo) }, UDim2)
end
UDim2.new        = mk2
UDim2.fromScale  = function(x, y) return mk2(x or 0, 0, y or 0, 0) end
UDim2.fromOffset = function(x, y) return mk2(0, x or 0, 0, y or 0) end

local Vector2 = {}
Vector2.__index = Vector2
function Vector2.new(x, y)
	return setmetatable({ _t = "Vector2", X = x or 0, Y = y or 0 }, Vector2)
end
Vector2.__add = function(a, b) return Vector2.new(a.X + b.X, a.Y + b.Y) end
Vector2.__sub = function(a, b) return Vector2.new(a.X - b.X, a.Y - b.Y) end

local Vector3 = {}
Vector3.__index = Vector3
function Vector3.new(x, y, z)
	return setmetatable({ _t = "Vector3", X = x or 0, Y = y or 0, Z = z or 0 }, Vector3)
end

local Color3 = {}
Color3.__index = Color3
local function mkColor(r, g, b)
	return setmetatable({ _t = "Color3", R = r or 0, G = g or 0, B = b or 0 }, Color3)
end
Color3.new = mkColor
Color3.fromRGB = function(r, g, b) return mkColor((r or 0) / 255, (g or 0) / 255, (b or 0) / 255) end
Color3.fromHSV = function(h, s, v) return Color3.fromRGB(255, 255, 255) end
function Color3:Lerp(other, t)
	t = t or 0
	return mkColor(self.R + (other.R - self.R) * t,
	               self.G + (other.G - self.G) * t,
	               self.B + (other.B - self.B) * t)
end
function Color3:ToHSV() return 0, 0, 0 end

local NumberSequenceKeypoint = {}
NumberSequenceKeypoint.__index = NumberSequenceKeypoint
function NumberSequenceKeypoint.new(time, value, envelope)
	return setmetatable({ _t = "NumberSequenceKeypoint", Time = time or 0,
	                      Value = value or 0, Envelope = envelope or 0 }, NumberSequenceKeypoint)
end

local NumberSequence = {}
NumberSequence.__index = NumberSequence
-- A keypoint list is a bare array. Datatype values are also tables (Color3 is
-- one), so the two-argument colour form must not be mistaken for a list.
local function isKeypointList(t)
	return type(t) == "table" and t._t == nil and #t > 0
end

function NumberSequence.new(a, b)
	if isKeypointList(a) then
		return setmetatable({ _t = "NumberSequence", Keypoints = a }, NumberSequence)
	end
	local kps = { NumberSequenceKeypoint.new(0, a or 0), NumberSequenceKeypoint.new(1, b or a or 0) }
	return setmetatable({ _t = "NumberSequence", Keypoints = kps }, NumberSequence)
end

local ColorSequenceKeypoint = {}
ColorSequenceKeypoint.__index = ColorSequenceKeypoint
function ColorSequenceKeypoint.new(time, color)
	return setmetatable({ _t = "ColorSequenceKeypoint", Time = time or 0, Value = color }, ColorSequenceKeypoint)
end

local ColorSequence = {}
ColorSequence.__index = ColorSequence
function ColorSequence.new(a, b)
	if isKeypointList(a) then
		return setmetatable({ _t = "ColorSequence", Keypoints = a }, ColorSequence)
	end
	local kps = { ColorSequenceKeypoint.new(0, a), ColorSequenceKeypoint.new(1, b or a) }
	return setmetatable({ _t = "ColorSequence", Keypoints = kps }, ColorSequence)
end

local TweenInfo = {}
TweenInfo.__index = TweenInfo
function TweenInfo.new(time, style, direction, repeatCount, reverses, delayTime)
	return setmetatable({ _t = "TweenInfo", Time = time or 1, EasingStyle = style,
	                      EasingDirection = direction, RepeatCount = repeatCount or 0,
	                      Reverses = reverses or false, DelayTime = delayTime or 0 }, TweenInfo)
end

local Rect = {}
Rect.__index = Rect
function Rect.new(a, b, c, d)
	if c == nil then
		return setmetatable({ _t = "Rect", MinX = 0, MinY = 0, MaxX = a or 0, MaxY = b or 0 }, Rect)
	end
	return setmetatable({ _t = "Rect", MinX = a or 0, MinY = b or 0, MaxX = c or 0, MaxY = d or 0 }, Rect)
end

local CFrame = {}
CFrame.__index = CFrame
function CFrame.new(x, y, z)
	local v = Vector3.new(x, y, z)
	return setmetatable({ _t = "CFrame", Position = v, p = v }, CFrame)
end
CFrame.Angles = function() return CFrame.new(0, 0, 0) end
CFrame.lookAt  = function() return CFrame.new(0, 0, 0) end
CFrame.fromEulerAnglesYXZ = function() return CFrame.new(0, 0, 0) end

local RaycastParams = {}
RaycastParams.__index = RaycastParams
function RaycastParams.new()
	-- FilterType is left unset: the Enum table is built later in this file, so
	-- a default here would be a nil global. Consumers assign it explicitly.
	return setmetatable({
		_t = "RaycastParams",
		FilterDescendantsInstances = {},
		IgnoreWater = false,
		CollisionGroup = "Default",
	}, RaycastParams)
end

local OverlapParams = {}
OverlapParams.__index = OverlapParams
function OverlapParams.new()
	return setmetatable({
		_t = "OverlapParams",
		FilterDescendantsInstances = {},
		MaxParts = 0,
	}, OverlapParams)
end

--------------------------------------------------------------------------
-- 2. enums
--------------------------------------------------------------------------

local enumValueMT = {
	__tostring = function(self) return "Enum." .. self._category .. "." .. self.Name end,
}
local enumValueCache = {}
local enumValueId = 0

local function enumValue(category, name)
	local key = category .. "." .. name
	local cached = enumValueCache[key]
	if cached then return cached end
	enumValueId = enumValueId + 1
	local v = setmetatable({
		_t = "EnumItem", _category = category, Name = name, Value = enumValueId, EnumType = category,
	}, enumValueMT)
	enumValueCache[key] = v
	return v
end

local enumCategoryCache = {}
local function enumCategory(name)
	local cached = enumCategoryCache[name]
	if cached then return cached end
	local category = setmetatable({ _t = "EnumCategory", _category = name }, {
		__index = function(self, key)
			local v = enumValue(self._category, key)
			rawset(self, key, v)
			return v
		end,
	})
	enumCategoryCache[name] = category
	return category
end

local Enum = setmetatable({ _t = "Enum" }, {
	__index = function(self, key)
		local c = enumCategory(key)
		rawset(self, key, c)
		return c
	end,
})

--------------------------------------------------------------------------
-- 3. signals
--------------------------------------------------------------------------

local signalMT = {}
signalMT.__index = signalMT
function signalMT:Connect(fn)
	local conn = {
		_connected = true,
		Disconnect = function(this)
			if this then this._connected = false end
		end,
	}
	conn.Disconnect = function() conn._connected = false end
	self._connections[#self._connections + 1] = conn
	if fn then conn._fn = fn end
	return conn
end
signalMT.Once = signalMT.Connect
-- No event ever fires, so Wait suspends the caller permanently rather than
-- returning nil — that keeps `while true do sig.Wait() ... end` from spinning.
function signalMT:Wait() coroutine.yield() end

local function makeSignal(name)
	return setmetatable({ _t = "Signal", _name = name or "Signal", _connections = {} }, signalMT)
end

--------------------------------------------------------------------------
-- 4. instances
--------------------------------------------------------------------------

-- class inheritance used by IsA
local PARENTS = {
	Frame              = { "GuiObject", "GuiBase2d" },
	ScrollingFrame     = { "GuiObject", "GuiBase2d" },
	TextLabel          = { "GuiObject", "GuiBase2d" },
	TextButton         = { "GuiObject", "GuiBase2d" },
	TextBox            = { "GuiObject", "GuiBase2d" },
	ImageLabel         = { "GuiObject", "GuiBase2d" },
	ImageButton        = { "GuiObject", "GuiBase2d" },
	ViewportFrame      = { "GuiObject", "GuiBase2d" },
	CanvasGroup        = { "GuiObject", "GuiBase2d" },
	ScreenGui          = { "LayerCollector", "GuiBase2d" },
	BillboardGui       = { "LayerCollector", "GuiBase2d" },
	SurfaceGui         = { "LayerCollector", "GuiBase2d" },
	GuiObject          = { "GuiBase2d" },
	LayerCollector     = { "GuiBase2d" },
	UICorner           = { "UIComponent", "UIBase" },
	UIPadding          = { "UIComponent", "UIBase" },
	UIListLayout       = { "UILayout", "UIComponent", "UIBase" },
	UIGridLayout       = { "UILayout", "UIComponent", "UIBase" },
	UIGradient         = { "UIComponent", "UIBase" },
	UIStroke           = { "UIComponent", "UIBase" },
	UIScale            = { "UIComponent", "UIBase" },
	UIAspectRatioConstraint = { "UIConstraint", "UIComponent", "UIBase" },
	UITextSizeConstraint    = { "UIConstraint", "UIComponent", "UIBase" },
}

local function isA(className, want)
	if className == want then return true end
	local p = PARENTS[className]
	while p do
		local nxt = nil
		for _, parent in ipairs(p) do
			if parent == want then return true end
		end
		-- climb one level: use the first entry as the immediate parent
		nxt = p[1] and PARENTS[p[1]] or nil
		if nxt and nxt == p then break end
		p = nxt
	end
	return want == "Instance"
end

local METHODS = {}
local instanceMT = {}

-- Animation records. TweenService does not write values: it records
-- (target, property, from, to, start, duration, easing) and the renderer
-- evaluates the whole scene at any time t. One dump therefore yields any
-- number of frames, including an animated GIF.
local tweens = {}
local nextInstanceId = 0

local function newInstance(className)
	nextInstanceId = nextInstanceId + 1
	local inst = {
		_t = "Instance",
		_id = nextInstanceId,
		_className = className,
		_props = { Name = className },
		_children = {},
		_methods = {},
		_parent = nil,
		_destroyed = false,
		_signals = {},
	}
	return setmetatable(inst, instanceMT)
end

local function signalFor(inst, name)
	local s = inst._signals[name]
	if not s then
		s = makeSignal(name)
		inst._signals[name] = s
	end
	return s
end

local function childByName(inst, name)
	for _, c in ipairs(inst._children) do
		if c._props.Name == name then return c end
	end
	return nil
end

local function childByClass(inst, className)
	for _, c in ipairs(inst._children) do
		if c._className == className or isA(c._className, className) then return c end
	end
	return nil
end

local function detach(inst)
	local p = inst._parent
	if not p then return end
	for i, c in ipairs(p._children) do
		if c == inst then
			table.remove(p._children, i)
			break
		end
	end
	inst._parent = nil
end

local SIGNAL_SUFFIXES = {
	"Began", "Ended", "Changed", "Added", "Removed", "Removing", "Stepped", "Heartbeat",
	"Render", "Completed", "Activated", "Focused", "LostFocus", "Touched", "TouchEnded",
	"Signal", "Event", "Triggered", "Update", "Pressed", "Released", "Hover", "Moved", "Died",
	"Opened", "Closed", "Idled", "Jumping",
}

local function looksLikeSignal(name)
	for _, suffix in ipairs(SIGNAL_SUFFIXES) do
		if #name >= #suffix and name:sub(-#suffix) == suffix then return true end
	end
	return false
end

instanceMT.__index = function(self, key)
	local m = self._methods[key] or METHODS[key]
	if m then return m end
	-- Parent and ClassName are real Instance fields, not entries in _props;
	-- attach() checks `gui.Parent` to decide whether a container accepted it.
	if key == "Parent" then return self._parent end
	if key == "ClassName" then return self._className end
	local p = self._props[key]
	if p ~= nil then return p end
	local child = childByName(self, key)
	if child then return child end
	if type(key) == "string" and key:match("^%u") and looksLikeSignal(key) then
		return signalFor(self, key)
	end
	return nil
end

instanceMT.__newindex = function(self, key, value)
	-- internal fields were initialised to nil, so they are absent from the
	-- table and reach this metamethod; keep them out of _props.
	if type(key) == "string" and key:sub(1, 1) == "_" then
		rawset(self, key, value)
		return
	end
	if key == "Parent" then
		if self._parent == value then return end
		detach(self)
		if value ~= nil then
			value._children[#value._children + 1] = self
			self._parent = value
		end
		return
	end
	if key == "Name" then
		self._props.Name = tostring(value)
		return
	end
	self._props[key] = value
end

instanceMT.__tostring = function(self)
	return self._props.Name or self._className
end

--------------------------------------------------------------------------
-- 5. instance methods
--------------------------------------------------------------------------

function METHODS.Destroy(self)
	self._destroyed = true
	for _, c in ipairs(self._children) do
		c._destroyed = true
	end
	detach(self)
	self._children = {}
	self._destroyed = true
end

function METHODS.IsA(self, want)
	if want == self._className then return true end
	return isA(self._className, want)
end

function METHODS.FindFirstChild(self, name, recursive)
	local c = childByName(self, name)
	if c then return c end
	if recursive then
		for _, ch in ipairs(self._children) do
			local found = METHODS.FindFirstChild(ch, name, true)
			if found then return found end
		end
	end
	return nil
end

function METHODS.FindFirstChildOfClass(self, className)
	return childByClass(self, className)
end

function METHODS.FindFirstChildWhichIsA(self, className, recursive)
	local c = childByClass(self, className)
	if c then return c end
	if recursive then
		for _, ch in ipairs(self._children) do
			local found = METHODS.FindFirstChildWhichIsA(ch, className, true)
			if found then return found end
		end
	end
	return nil
end

function METHODS.WaitForChild(self, name) return childByName(self, name) end
function METHODS.GetChildren(self)
	local out = {}
	for i, c in ipairs(self._children) do out[i] = c end
	return out
end
function METHODS.GetDescendants(self)
	local out = {}
	local function walk(node)
		for _, c in ipairs(node._children) do
			out[#out + 1] = c
			walk(c)
		end
	end
	walk(self)
	return out
end
function METHODS.ClearAllChildren(self)
	for _, c in ipairs(self._children) do c._parent = nil end
	self._children = {}
end
function METHODS.GetPropertyChangedSignal(self, name) return signalFor(self, "Changed:" .. tostring(name)) end
function METHODS.SetAttribute(self, k, v) self._props["attr_" .. k] = v end
function METHODS.GetAttribute(self, k) return self._props["attr_" .. k] end
function METHODS.GetFullName(self) return self._props.Name end
function METHODS.Clone(self) return newInstance(self._className) end

--------------------------------------------------------------------------
-- 6. services + game
--------------------------------------------------------------------------

local services = {}

local function serviceClass(name) return newInstance(name) end

local function addMethod(inst, name, fn)
	inst._methods[name] = fn
end

local function setupService(inst, name)
	if name == "TweenService" then
		addMethod(inst, "Create", function(_, target, info, props)
			local record = {
				target = target,
				props = props or {},
				from = {},
				start = 0,
				duration = (info and info.Time) or 0,
				style = (info and info.EasingStyle and info.EasingStyle.Name) or "Quad",
				direction = (info and info.EasingDirection and info.EasingDirection.Name) or "Out",
				delay = (info and info.DelayTime) or 0,
				playing = false,
			}
			local tween = { _t = "Tween", Completed = makeSignal("Completed") }

			function tween.Play()
				if record.playing then return end
				record.playing = true
				-- `from` is captured when the tween starts, which for setup-time
				-- animation is the value the element was built with.
				for k in pairs(record.props) do
					record.from[k] = target[k]
				end
				record.start = record.delay or 0
				tweens[#tweens + 1] = record
			end

			function tween.Cancel()
				record.playing = false
				for i = #tweens, 1, -1 do
					if tweens[i] == record then table.remove(tweens, i) end
				end
			end

			function tween.Pause() end
			tween.Play = tween.Play
			return tween
		end)
	elseif name == "HttpService" then
		addMethod(inst, "JSONEncode", function(_, v) return "{}" end)
		addMethod(inst, "JSONDecode", function(_, s) return {} end)
		addMethod(inst, "GenerateGUID", function() return "{00000000-0000-0000-0000-000000000000}" end)
		addMethod(inst, "UrlEncode", function(_, s) return s end)
	elseif name == "Players" then
		local player = newInstance("Player")
		player._props.Name = "LocalPlayer"
		local pg = newInstance("PlayerGui")
		pg._props.Name = "PlayerGui"
		pg.Parent = player
		player._props.LocalPlayer = player
		inst._props.LocalPlayer = player
		addMethod(player, "FindFirstChildOfClass", function(self, cls)
			if cls == "PlayerGui" then return pg end
			return childByClass(self, cls)
		end)
		addMethod(inst, "GetPlayers", function() return { player } end)
		addMethod(inst, "GetPlayerFromCharacter", function() return nil end)
		addMethod(inst, "GetPlayerByUserId", function() return nil end)
	elseif name == "CollectionService" then
		addMethod(inst, "GetTagged", function() return {} end)
		addMethod(inst, "HasTag", function() return false end)
		addMethod(inst, "AddTag", function() end)
		addMethod(inst, "RemoveTag", function() end)
		addMethod(inst, "GetInstanceAddedSignal", function() return makeSignal("Added") end)
		addMethod(inst, "GetInstanceRemovedSignal", function() return makeSignal("Removed") end)
	elseif name == "RunService" then
		addMethod(inst, "IsStudio", function() return true end)
		addMethod(inst, "IsClient", function() return true end)
	elseif name == "Workspace" then
		local cam = newInstance("Camera")
		cam._props.Name = "Camera"
		cam._props.CFrame = CFrame.new(0, 0, 0)
		cam._props.FieldOfView = 70
		cam._props.ViewportSize = Vector2.new(1280, 720)
		inst._props.CurrentCamera = cam
	elseif name == "Stats" then
		local network = newInstance("Stats")
		network._props.Name = "Network"
		network._props.ServerStatsItem = setmetatable({}, {
			__index = function()
				local item = newInstance("StatsItem")
				addMethod(item, "GetValue", function() return 42 end)
				addMethod(item, "GetValueString", function() return "42" end)
				return item
			end,
		})
		network._props.ServerStatsItem = { ["Data Ping"] = (function()
			local item = newInstance("StatsItem")
			addMethod(item, "GetValue", function() return 42 end)
			return item
		end)() }
		network.Parent = inst
		inst._props.Network = network
	elseif name == "GuiService" then
		addMethod(inst, "IsTenFootInterface", function() return false end)
		addMethod(inst, "GetGuiInset", function() return Vector2.new(0, 58), Vector2.new(0, 0) end)
	end
end

local function getService(name)
	local svc = services[name]
	if svc then return svc end
	svc = serviceClass(name)
	setupService(svc, name)
	services[name] = svc
	return svc
end

local game = { _t = "Game", PlaceId = 0, JobId = "mock" }
function game:GetService(name)
	return getService(name)
end
function game:HttpGet(url)
	if LIB and type(url) == "string" and url:find("AegisUI.lua", 1, true) then
		local f = io.open(LIB, "r")
		if f then
			local src = f:read("*a")
			f:close()
			return src
		end
	end
	if type(url) == "string" and url:find("AegisUI.lua", 1, true) and LIB then
		return ""
	end
	return ""
end
function game:GetObjects() return {} end
game.Workspace = getService("Workspace")
game.CoreGui = getService("CoreGui")

-- RobloxGui must not exist, so the library parents into CoreGui directly.
local coreGui = getService("CoreGui")

local hiddenUi = newInstance("Folder")
hiddenUi._props.Name = "HiddenUI"

--------------------------------------------------------------------------
-- 7. task scheduler
--------------------------------------------------------------------------

-- task.spawn / task.defer run inline (setup work must have happened by the
-- time we dump). task.delay is QUEUED AND NEVER RUN: delayed work is always
-- teardown (toast dismissal, animation cleanup, autosave). Running it would
-- delete the very things we are trying to photograph.
local scratch = {}

-- There is no scheduler. A spawned body runs until its first wait, then stays
-- suspended forever: that executes the setup (which is what builds UI) while
-- keeping `while true do ... wait() end` drivers from spinning the process.
task = {
	spawn = function(fn, ...)
		if type(fn) ~= "function" then return end
		local thread = coroutine.create(fn)
		local ok, err = coroutine.resume(thread, ...)
		if not ok then log("task.spawn error: " .. tostring(err)) end
		return thread
	end,
	defer = function(fn, ...)
		if type(fn) ~= "function" then return end
		local thread = coroutine.create(fn)
		local ok, err = coroutine.resume(thread, ...)
		if not ok then log("task.defer error: " .. tostring(err)) end
		return thread
	end,
	delay = function(_, fn, ...)
		scratch[#scratch + 1] = { fn = fn, args = { ... } }
	end,
	wait = function(t) coroutine.yield(); return t or 0 end,
	cancel = function() end,
	synchronize = function() end,
	desynchronize = function() end,
}

local function wait(n)
	coroutine.yield()
	return n or 0
end

--------------------------------------------------------------------------
-- 8. virtual filesystem + executor surface
--------------------------------------------------------------------------

local FS = {}
local FS_FILE, FS_DIR = {}, {}

isfile = function(p) return FS_FILE[p] ~= nil end
writefile = function(p, d) FS_FILE[p] = d end
appendfile = function(p, d) FS_FILE[p] = (FS_FILE[p] or "") .. d end
readfile = function(p) return FS_FILE[p] or "" end
delfile = function(p) FS_FILE[p] = nil end
listfiles = function(p)
	local out = {}
	local prefix = p:gsub("/$", "") .. "/"
	for k in pairs(FS_FILE) do
		if k:sub(1, #prefix) == prefix then
			local rest = k:sub(#prefix + 1)
			if not rest:find("/") then out[#out + 1] = k end
		end
	end
	return out
end
makefolder = function(p) FS_DIR[p] = true end
isfolder = function(p) return FS_DIR[p] == true end
delfolder = function(p) FS_DIR[p] = nil end
identifyexecutor = function() return "AegisRenderer", "1.0" end
setclipboard = function() end
getclipboard = function() return "" end
toclipboard = function() end
queue_on_teleport = function() end
setfpscap = function() end
syn = nil
Drawing = nil

local genv = {}
function getgenv() return genv end
function getreg() return genv end
function getrenv() return _G end

function typeof(v)
	if type(v) == "table" and v._t then return v._t end
	return type(v)
end

function gethui() return hiddenUi end

Instance = {}
function Instance.new(class)
	return newInstance(class)
end

function loadstring(src, chunkname)
	if type(src) ~= "string" then return nil, "expected string" end
	local fn, err = load(src, chunkname or "=loadstring", "t", _G)
	if not fn then return nil, err end
	return fn
end

--------------------------------------------------------------------------
-- 9. JSON
--------------------------------------------------------------------------

local function esc(s)
	s = s:gsub('[\\"]', function(c) if c == '\\' then return '\\\\' else return '\\"' end end)
	s = s:gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
	s = s:gsub('[%z\1-\31]', function(c) return string.format('\\u%04x', c:byte()) end)
	return s
end

local function num(n)
	if n ~= n or n == math.huge or n == -math.huge then return "0" end
	if n == math.floor(n) and math.abs(n) < 1e15 then
		return string.format("%d", n)
	end
	return (string.format("%.6f", n):gsub("0+$", ""):gsub("%.$", ""))
end

local enc

local function encodeValue(v, depth)
	local t = type(v)
	if t == "number" then return num(v) end
	if t == "boolean" then return v and "true" or "false" end
	if t == "string" then return '"' .. esc(v) .. '"' end
	if t ~= "table" then return "null" end
	-- Guard against pathological nesting only. This must stay well above GUI
	-- depth: elements live ~8-10 levels down, and datatypes are tables, so a
	-- low limit silently strips every Size/Position/Colour on deep nodes
	-- while leaving their strings and numbers intact.
	if depth > 32 then return "null" end

	local tag = v._t
	if tag == "UDim2" then
		return string.format('{"__type":"UDim2","xs":%s,"xo":%s,"ys":%s,"yo":%s}',
			num(v.X.Scale), num(v.X.Offset), num(v.Y.Scale), num(v.Y.Offset))
	elseif tag == "UDim" then
		return string.format('{"__type":"UDim","s":%s,"o":%s}', num(v.Scale), num(v.Offset))
	elseif tag == "Vector2" then
		return string.format('{"__type":"Vector2","x":%s,"y":%s}', num(v.X), num(v.Y))
	elseif tag == "Color3" then
		return string.format('{"__type":"Color3","r":%s,"g":%s,"b":%s}', num(v.R), num(v.G), num(v.B))
	elseif tag == "EnumItem" then
		return string.format('{"__type":"Enum","category":"%s","name":"%s"}', esc(v._category), esc(v.Name))
	elseif tag == "ColorSequence" then
		local parts = {}
		for _, kp in ipairs(v.Keypoints) do
			local c = kp.Value or Color3.new(0, 0, 0)
			parts[#parts + 1] = string.format('{"t":%s,"r":%s,"g":%s,"b":%s}',
				num(kp.Time), num(c.R), num(c.G), num(c.B))
		end
		return '{"__type":"ColorSequence","keypoints":[' .. table.concat(parts, ",") .. ']}'
	elseif tag == "NumberSequence" then
		local parts = {}
		for _, kp in ipairs(v.Keypoints) do
			parts[#parts + 1] = string.format('{"t":%s,"v":%s}', num(kp.Time), num(kp.Value))
		end
		return '{"__type":"NumberSequence","keypoints":[' .. table.concat(parts, ",") .. ']}'
	elseif tag == "Instance" then
		return string.format('{"__type":"Instance","name":"%s"}', esc(v._props.Name or ""))
	elseif tag == "Signal" or tag == "Tween" then
		return "null"
	end

	-- plain table: array if it only has sequential integer keys
	local count, maxIndex, allNumbers = 0, 0, true
	for k in pairs(v) do
		count = count + 1
		if type(k) == "number" then
			if k > maxIndex then maxIndex = k end
		else
			allNumbers = false
		end
	end
	if count == 0 then return "{}" end
	if allNumbers and maxIndex == count then
		local parts = {}
		for i = 1, maxIndex do parts[i] = encodeValue(v[i], depth + 1) end
		return "[" .. table.concat(parts, ",") .. "]"
	end
	local parts = {}
	for k, val in pairs(v) do
		if type(k) == "string" then
			parts[#parts + 1] = '"' .. esc(k) .. '":' .. encodeValue(val, depth + 1)
		end
	end
	return "{" .. table.concat(parts, ",") .. "}"
end
enc = encodeValue

local SKIP_PROPS = { Parent = true }

local function dumpNode(node, depth)
	local props = {}
	for k, v in pairs(node._props) do
		if not SKIP_PROPS[k] and type(v) ~= "function" then
			local encoded = encodeValue(v, depth + 1)
			if encoded ~= "null" then
				props[#props + 1] = '"' .. esc(k) .. '":' .. encoded
			end
		end
	end
	local kids = {}
	for _, c in ipairs(node._children) do
		kids[#kids + 1] = dumpNode(c, depth + 1)
	end
	return string.format(
		'{"id":%d,"class":"%s","name":"%s","props":{%s},"children":[%s]}',
		node._id, esc(node._className), esc(node._props.Name or ""),
		table.concat(props, ","), table.concat(kids, ","))
end

local function dumpAll()
	local roots = {}
	local function collect(node)
		for _, c in ipairs(node._children) do
			if c._className == "ScreenGui" then
				roots[#roots + 1] = dumpNode(c, 0)
			else
				collect(c)
			end
		end
	end
	collect(hiddenUi)
	collect(coreGui)

	local records = {}
	for _, tw in ipairs(tweens) do
		local props, from = {}, {}
		for k, v in pairs(tw.props) do
			props[#props + 1] = '"' .. esc(tostring(k)) .. '":' .. encodeValue(v, 1)
			local f = tw.from[k]
			if f ~= nil then
				from[#from + 1] = '"' .. esc(tostring(k)) .. '":' .. encodeValue(f, 1)
			end
		end
		records[#records + 1] = string.format(
			'{"target":%d,"props":{%s},"from":{%s},"start":%s,"duration":%s,"style":"%s","direction":"%s"}',
			tw.target._id, table.concat(props, ","), table.concat(from, ","),
			num(tw.start), num(tw.duration), esc(tw.style), esc(tw.direction))
	end

	local viewport = os.getenv("AEGIS_VIEWPORT") or "1440x900"
	local maxEnd = 0
	for _, tw in ipairs(tweens) do
		local finish = (tw.start or 0) + (tw.duration or 0)
		if finish > maxEnd then maxEnd = finish end
	end
	return string.format('{"viewport":"%s","duration":%s,"guis":[%s],"tweens":[%s]}',
		viewport, num(maxEnd), table.concat(roots, ","), table.concat(records, ","))
end

--------------------------------------------------------------------------
-- 10. run
--------------------------------------------------------------------------

-- Publish the datatype constructors into the script environment. These names
-- are also locals above, so each assignment must go through _G explicitly: a
-- bare `UDim2 = UDim2` resolves to the local and sets nothing global at all.
_G.Color3                 = Color3
_G.UDim                   = UDim
_G.UDim2                  = UDim2
_G.Vector2                = Vector2
_G.Vector3                = Vector3
_G.Enum                   = Enum
_G.NumberSequence         = NumberSequence
_G.NumberSequenceKeypoint = NumberSequenceKeypoint
_G.ColorSequence          = ColorSequence
_G.ColorSequenceKeypoint  = ColorSequenceKeypoint
_G.TweenInfo              = TweenInfo
_G.Rect                   = Rect
_G.CFrame                 = CFrame
_G.RaycastParams          = RaycastParams
_G.OverlapParams          = OverlapParams
_G.game                   = game
_G.wait                   = wait
_G.tick                   = os.clock

-- AEGIS_TRACE=1 samples the interpreter so a spinning consumer can be located
-- instead of just timing out.
if os.getenv("AEGIS_TRACE") then
	local ticks, dumped = 0, false
	debug.sethook(function()
		ticks = ticks + 1
		if not dumped and ticks > 4000 then
			dumped = true
			log("TRACEBACK:\n" .. debug.traceback("", 2))
		end
	end, "", 500)
end

log("running " .. SCRIPT)
local chunk, err = loadfile(SCRIPT)
if not chunk then
	log("COMPILE ERROR: " .. tostring(err))
	os.exit(2)
end

local ok, runErr = xpcall(chunk, function(e)
	return tostring(e) .. "\n" .. (debug.traceback("", 2) or "")
end)

if not ok then
	-- Still dump: a consumer that failed late has usually already built its
	-- UI, and half a panel is worth seeing. The renderer reports it as partial.
	log("RUNTIME ERROR: " .. tostring(runErr))
	log("PARTIAL: dumping whatever the tree holds at the point of failure")
end

-- Optional: select a tab before dumping, so one run can photograph the panel
-- in any of its states. Works for any AegisUI consumer, not just the demos.
local function selectTab()
	local idx = tonumber(os.getenv("AEGIS_TAB") or "")
	if not idx then return end
	local pub = genv.AegisUI
	local lib = (type(pub) == "table") and (pub.lib or pub) or nil
	local win = lib and lib.CurrentWindow
	if not (win and win.Tabs and win.Tabs[idx]) then
		local have = (win and win.Tabs) and #win.Tabs or 0
		log(string.format("AEGIS_TAB=%d ignored: %d tab(s) available", idx, have))
		return
	end
	local ok, err = pcall(function() win:SelectTab(win.Tabs[idx]) end)
	log(string.format("AEGIS_TAB=%d -> %s%s", idx, tostring(ok), ok and "" or (" " .. tostring(err))))
end

selectTab()

local json = dumpAll()
local f = io.open(OUT, "w")
if not f then
	log("cannot write " .. OUT)
	os.exit(4)
end
f:write(json)
f:close()
log(string.format("dumped %d bytes to %s", #json, OUT))
