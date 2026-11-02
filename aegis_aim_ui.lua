--[[
	Aegis · Aim assist — AegisUI edition  (aegis_aim_ui.lua)
	=======================================================

	VERSION 4.00-ui   <-- bump on every change, and keep this header in step.
	                     A stale version number makes every verification claim
	                     in a session unreliable; read it back out of the running
	                     instance instead of trusting the file.

	Rewrite of Scripts\MurderDuels\aegis_aim.lua (v3.30-md5) with the hand-built
	CoreGui panel replaced by AegisUI, wired the way
	Scripts\SellOres\AegisSellOres.lua wires it. The original file is untouched.

	What changed, and why
	---------------------
	* Panel: one AegisUI window, eight tabs. Every CONFIG key that had a row in
	  the old panel now has a real AegisUI control, and the flags are read back
	  through `lib:Get` / `lib:Set`, so there is no second syncer to drift.
	* Persistence: the old aegis_aim_config.json writer is gone. AegisUI owns
	  flag persistence (`LoadConfig` / `SaveConfig`), so there is one store. The
	  Config tab exposes it; `default` is restored at start with callbacks live
	  and re-written 2 s after the last change, so a setting survives a client
	  restart -- the unload button is not how a session usually ends.
	* Keys: AegisUI owns RightShift (collapse), Insert (restore) and F4
	  (collapse) -- no key unloads. Auto-win therefore moves onto its own
	  bindable key, default X, whose press is handled here (above the
	  gameProcessedEvent guard) so it still fires mid-match. The binding is
	  editable in the Auto-win tab. End/Insert/F4 are the library's business.
	* 200-local ceiling: the original declared exactly 200 top-level locals --
	  Lua's limit -- and had to publish auto-win through a global to free a slot.
	  Everything here hangs off one table, A, so the ceiling cannot be reached.
	* Dropped: the non-Drawing GUI fallback overlay (a second ScreenGui holding
	  a ring and a box frame). This executor has Drawing -- measured:
	  `type(Drawing.new) == "function"` -- and a second ScreenGui cannot be
	  themed, collapsed or unloaded with the panel. With Drawing absent the
	  ring, box, ESP and snaplines do not draw, and the status line says so.
	* One latent bug fixed: drawESP sorted on `cand.distSq`, a field that
	  buildCandidate never set, so every key compared 0 and ESPMax was spent in
	  insertion order instead of by distance. distSq is now produced.

	Everything below the UI layer is carried over from 3.30-md5 unchanged: the
	camera / input / mouse solvers, the velocity estimator and freeze gate, the
	oriented-box aim point, the projection basis, auto-win's payloads, the
	no-reload pulse and the wallbang.

	Measured facts the defaults rest on
	-----------------------------------
	  camera driver   7.5 deg -> 0.25 deg over 70 frames (inside the deadzone)
	  input driver    126 deg -> 3.5-4.0 deg and stuck, in a limit cycle
	  transport       40 units: mousemoverel -6.37 deg, Input.MoveMouse -20.00 deg
	                  (0.159 vs 0.500 deg/unit -- discard the gain on a switch)
	  loop lag        tau 0.166 s against an 80 deg/s crossing = 15.9 deg of
	                  permanent lag; LeadLoop removes it, 0.99 deg measured
	  auto-win melee  ReportHit{kind="melee", backstab=true} -> 250 dmg;
	                  accepted at 9 and 11 studs, REFUSED at 38
	  auto-win throw  ThrowReplicate then ReportHit{kind="throw"} -> 100 dmg at
	                  156 studs THROUGH geometry; the throw alone deals nothing
	  no-reload       RapidReload runs playRapidReload -> n1 = os.clock()+0.2,
	                  1.332 s of client cooldown down to 0.2 s
	  wallbang        ShootReplicate payload with the enemy Head named, 132 studs
	                  with a confirmed wall between: 100 hp -> 0

	Cross-script API
	----------------
	  getgenv().AegisAim.version
	  getgenv().AegisAim.on() / .off()          arm / disarm the aim
	  getgenv().AegisAim.set("FOV", 240)        sets CONFIG and the panel control
	  getgenv().AegisAim.get("FOV")
	  getgenv().AegisAim.npcs(true)             also target non-player Humanoids
	  getgenv().AegisAim.target()               the live candidate, or nil
	  getgenv().AegisAim.aw.on() / .off() / .toggle() / .state
	  getgenv().AegisAim.unload()
	  getgenv().AegisAutoWin                    the same table as .aw.state
--]]

local VERSION = "4.00-ui"
local LIB_URL = "https://raw.githubusercontent.com/t2339789/AegisUI/main/AegisUI.lua"
local genv = (type(getgenv) == "function") and getgenv() or _G

--------------------------------------------------------------------
-- Services
--------------------------------------------------------------------

local Players    = game:GetService("Players")
local UIS        = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Stats      = game:GetService("Stats")
local Workspace  = game:GetService("Workspace")
local GuiService = game:GetService("GuiService")
local CollectionService = game:GetService("CollectionService")

local lp = Players.LocalPlayer
if not lp then
	return "aim-ui: no local player (run inside the client)"
end

local SOLVER_ID = "AegisAimUiSolver"
local DRAW_KEY  = "AegisDraw_AegisAimUi"
local CONN_KEY  = "AegisConn_AegisAimUi"

--------------------------------------------------------------------
-- One namespace.
--
-- The original file ran into Lua's 200-local ceiling and had to publish its
-- auto-win table as a global to free a slot. Every subsystem lives on A, so
-- adding one more never costs a local slot.
--------------------------------------------------------------------

local A = {}
A.VERSION = VERSION
A.conns = {}

A.C = {
	-- aiming ------------------------------------------------------
	Enabled       = true,
	Activation    = "hold",       -- "hold" | "toggle" | "always"
	HoldKey       = "LeftAlt",
	ToggleKey     = "Q",
	DriveMode     = "camera",     -- "camera" | "mouse"
	SimulateInput = true,
	RequireClick  = false,

	FOV           = 180,          -- px, radius from the reference point
	Range         = 600,          -- studs
	Smoothing     = 55,           -- 0 snaps, 100 crawls
	Strength      = 300,          -- percent
	MaxSpeed      = 900,          -- deg/s

	Part          = "Head",
	PartNPC       = "Torso",
	PadPct        = 0,
	BoxBody       = true,
	MarkRadiusPx  = 70,
	LockGraceFrames = 20,
	MaxLockDeg    = 75,

	PredictionMs  = 0,
	LeadByPing    = false,
	ProjectileSpeed = 0,
	MaxLeadStuds  = 0,
	LeadLoop      = true,
	LeadSelf      = true,
	DeadzoneX100  = 0,
	HumanTenths   = 4,

	AdaptiveSpeed = true,
	MaxLagX10     = 5,
	MaxSpeedCeiling = 2000,

	TeamCheck     = true,
	WallCheck     = true,
	IgnoreFriends = false,
	NPCCheck      = true,
	RequireHead   = true,
	IgnoreAnchored = true,
	IgnoreNames   = { "AimRing", "HumanBody" },
	IgnoreSubstrings = { "_died", "_dead", "_corpse", "_ragdoll" },
	IgnoreFrozen  = true,
	FrozenHoldMs  = 2000,
	FrozenMinSpeed = 6,
	FrozenMotionMs = 250,
	FrozenFrames  = 12,
	UseGameDeathFlag = true,

	AutoFire       = true,
	AutoFireRateMs = 90,
	AutoFireArcDeg = 3.0,

	LiveTags      = { "entity", "bot" },
	BodyTags      = { "entityref", "corpse" },
	IgnoreHashNames = false,
	FriendlyFolders = { "friendly" },

	SensX10       = 120,

	ShowFov       = true,
	ShowTarget    = true,
	ESP           = false,
	ESPColor      = Color3.fromRGB(125, 220, 150),
	ESPTargetColor = Color3.fromRGB(255, 60, 60),
	ESPMax        = 12,
	ESPLine       = true,
	ESPLinePx     = 2,

	NoReload      = true,
	NoReloadPulseGapMs = 200,
	WallBang      = true,
	WallBangGapMs = 250,
	WallBangDamage = 75,

	GunAim        = true,
	UseCursor     = false,

	Sticky        = 0.70,
	PickClosest   = true,

	-- Local keybind for auto-win. RightShift belongs to AegisUI now.
	AutowinKey    = "X",
}

A.S = {
	cam      = nil,
	target   = nil,
	held     = false,
	-- Must start false: this is the toggle-mode state, and the gate falls back to
	-- it for any activation value it does not recognise, so a true seed makes the
	-- aim engage with no key pressed.
	toggled  = false,
	angle    = 0,
	status   = "booting",
	ping     = 0,
	errors   = 0,
	broken   = false,
	unloaded = false,
	switches = 0,
	rendered = nil,
	ownsCamera = false,
	tau      = 0,
	leadStuds = 0,
	velStuds = 0,
	selfVelStuds = 0,
	reject   = {},
	shots    = 0,
	keyGuard = 0,
}

local C = A.C
local S = A.S

--------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------

local function clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

local function wrapDeg(a)
	a = a % 360
	if a > 180 then a = a - 360 end
	return a
end

local function wrap180(a)
	while a > 180 do a = a - 360 end
	while a <= -180 do a = a + 360 end
	return a
end

local function keyOf(name)
	if type(name) ~= "string" then return nil end
	local ok, item = pcall(function() return Enum.KeyCode[name] end)
	if ok then return item end
	return nil
end

local function track(conn)
	A.conns[#A.conns + 1] = conn
	if genv then
		local held = genv[CONN_KEY]
		if type(held) ~= "table" then
			held = {}
			genv[CONN_KEY] = held
		end
		held[#held + 1] = conn
	end
	return conn
end

local function on(signal, fn)
	return track(signal:Connect(fn))
end

local function isPart(o)
	return o ~= nil and o:IsA("BasePart")
end

local function modelOf(inst)
	local node = inst
	for _ = 1, 5 do
		if not node then return nil end
		if node:IsA("Model") then return node end
		node = node.Parent
	end
	return nil
end

local function indexOf(list, value)
	for i = 1, #list do
		if list[i] == value then return i end
	end
	return nil
end

--------------------------------------------------------------------
-- Teardown of a previous copy
--
-- A re-run must not stack a second render-step binding or leave orphaned
-- Drawing objects. Drawings are not Instances -- they never appear under any
-- root -- so they are reclaimed through the shared getgenv slot.
--------------------------------------------------------------------

local function sweep()
	if genv then
		local held = genv[CONN_KEY]
		if type(held) == "table" then
			for _, conn in ipairs(held) do
				pcall(function() conn:Disconnect() end)
			end
		end
		genv[CONN_KEY] = {}

		local draw = genv[DRAW_KEY]
		if type(draw) == "table" then
			for _, obj in pairs(draw) do
				if type(obj) == "table" then
					for _, one in pairs(obj) do
						pcall(function() one.Visible = false end)
						pcall(function() one:Remove() end)
					end
				else
					pcall(function() obj.Visible = false end)
					pcall(function() obj:Remove() end)
				end
			end
		end
		genv[DRAW_KEY] = {}
	end
	pcall(function() RunService:UnbindFromRenderStep(SOLVER_ID) end)
end

sweep()

--------------------------------------------------------------------
-- 1. Sides, friends
--------------------------------------------------------------------

local SIDE_ATTRS = { "Team", "TeamName", "Faction", "Side", "Allegiance", "TeamId" }
local SIDE_CHILDS = { "Team", "TeamName", "Faction" }

local function attrSide(inst)
	for i = 1, #SIDE_ATTRS do
		local ok, value = pcall(function() return inst:GetAttribute(SIDE_ATTRS[i]) end)
		if ok and value ~= nil and value ~= "" then
			return "attr:" .. tostring(value)
		end
	end
	return nil
end

local function childSide(inst)
	for i = 1, #SIDE_CHILDS do
		local child = inst:FindFirstChild(SIDE_CHILDS[i])
		if child and child:IsA("ValueBase") then
			local value = child.Value
			if value ~= nil and value ~= "" then
				return "child:" .. tostring(value)
			end
		end
	end
	return nil
end

-- Team by NAME, not by identity: a place that rebuilds its Teams between rounds
-- would otherwise silently stop matching.
local function sideOf(player, model)
	if player then
		local team = player.Team
		if team then
			return "team:" .. team.Name
		end
		return attrSide(player) or (model and attrSide(model)) or nil
	end
	if not model then return nil end
	local side = attrSide(model) or childSide(model)
	if side then return side end
	local node = model.Parent
	for _ = 1, 4 do
		if not node or node == Workspace then break end
		side = attrSide(node) or childSide(node)
		if side then return side end
		node = node.Parent
	end
	return nil
end

local function teamBlocked(player, model)
	if not C.TeamCheck then return false end
	local mine = sideOf(lp, lp.Character)
	if not mine then return false end
	local theirs = sideOf(player, player and player.Character or model)
	if not theirs then return false end
	return theirs == mine
end

-- Middle-click allies, keyed by UserId and mirrored into getgenv so the list
-- survives a reload within the session.
local friendList = genv.AegisAimFriends or {}
genv.AegisAimFriends = friendList

local function friendCount()
	local n = 0
	for _ in pairs(friendList) do n = n + 1 end
	return n
end

local friendCache, friendPending = {}, {}
local markTarget

-- Player:IsFriendsWith is web-backed and yields; never call it from the render
-- step. Resolve off-thread and answer "not a friend" until it lands.
local function friendBlocked(player)
	if not C.IgnoreFriends then return false end
	local now = os.clock()
	local rec = friendCache[player.UserId]
	if rec and (now - rec.at) < 30 then return rec.value end
	local uid = player.UserId
	if not friendPending[uid] then
		friendPending[uid] = true
		task.spawn(function()
			local ok, value = pcall(function() return lp:IsFriendsWith(uid) end)
			friendCache[uid] = { value = (ok and value) and true or false, at = os.clock() }
			friendPending[uid] = nil
		end)
	end
	return false
end

--------------------------------------------------------------------
-- 2. Parts, aim point, visibility
--------------------------------------------------------------------

local PART_NAMES = {
	Head  = { "Head", "HeadPart" },
	Torso = { "UpperTorso", "Torso", "LowerTorso", "Chest", "Trunk" },
	Root  = { "HumanoidRootPart", "RootPart", "Root" },
}

-- Exact name first, then a case-insensitive sweep: R6 names Head/Torso, R15
-- UpperTorso/LowerTorso, and custom rigs rename freely -- an exact lookup
-- silently fell through to the root part and aimed at the feet.
local function findPart(model, names)
	for i = 1, #names do
		local part = model:FindFirstChild(names[i])
		if isPart(part) then return part end
	end
	local want = names[1]:lower()
	for _, child in ipairs(model:GetChildren()) do
		if isPart(child) and child.Name:lower() == want then
			return child
		end
	end
	return nil
end

-- Humanoid.RootPart is authoritative; then PrimaryPart; then a named root; then
-- the largest part. NPC dummies ship without a HumanoidRootPart and the old
-- code dropped every one of them.
local function rootOf(model, hum)
	local root = hum and hum.RootPart
	if root and root.Parent then return root end
	root = model.PrimaryPart
	if isPart(root) then return root end
	root = findPart(model, PART_NAMES.Root)
	if root then return root end
	local best, bestVol = nil, -1
	for _, child in ipairs(model:GetChildren()) do
		if isPart(child) then
			local s = child.Size
			local vol = s.X * s.Y * s.Z
			if vol > bestVol then
				best, bestVol = child, vol
			end
		end
	end
	return best
end

-- A body with no Humanoid anywhere inside it: a head, a torso and a root as
-- direct children. Structural, because a class test cannot work when the class
-- is absent (measured: R15 MeshPart bodies driven by an AnimationController).
local function isBareCharacter(model, head, root)
	if not head or not root then return false end
	return findPart(model, PART_NAMES.Torso) ~= nil
end

-- The rig's own Dead flag, and nothing else: a pooled ragdoll copy keeps a
-- stale Health of 100 while carrying no Dead attribute at all.
local function rigStatedDead(model)
	local ok, dead = pcall(function() return model:GetAttribute("Dead") end)
	if not ok then return nil end
	if dead == true then return true end
	if dead == false then return false end
	return nil
end

local function partFor(model, root, head, isNPC)
	local mode = (isNPC and C.PartNPC) or C.Part
	if mode == "Head" then
		return head or root
	elseif mode == "Torso" then
		return findPart(model, PART_NAMES.Torso) or root
	end
	return root
end

-- Nearest point on the part's oriented box to the eye. Also covers rotated
-- limbs, which the reference client's AABB clamp does not.
local function aimPointFor(part, from)
	local localEye = part.CFrame:PointToObjectSpace(from)
	local half = part.Size * 0.5
	local pad = 1 + (C.PadPct / 100)
	local clamped = Vector3.new(
		clamp(localEye.X, -half.X * pad, half.X * pad),
		clamp(localEye.Y, -half.Y * pad, half.Y * pad),
		clamp(localEye.Z, -half.Z * pad, half.Z * pad)
	)
	local point = part.CFrame:PointToWorldSpace(clamped)
	local centre = part.CFrame.Position
	local limit = part.Size.Magnitude * 2 + 1
	local finite = point.X == point.X and point.Y == point.Y and point.Z == point.Z
		and math.abs(point.X) < 1e7 and math.abs(point.Y) < 1e7 and math.abs(point.Z) < 1e7
	if not finite or (point - centre).Magnitude > limit then
		return centre
	end
	if (point - from).Magnitude < 0.4 then
		return centre
	end
	return point
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local rayFilter = {}

-- Cast from the character, not the camera: a bullet leaves the character, and
-- a third-person camera pushed into geometry starts the ray inside the wall
-- where Roblox reports no hit and the target looks visible through it.
local function isVisible(from, to, character)
	local n = 0
	if character then
		n = n + 1
		rayFilter[n] = character
	end
	local mine = lp.Character
	if mine then
		n = n + 1
		rayFilter[n] = mine
	end
	for i = n + 1, #rayFilter do rayFilter[i] = nil end
	rayParams.FilterDescendantsInstances = rayFilter

	local origin = from
	local myChar = lp.Character
	if myChar then
		local eye = myChar:FindFirstChild("Head") or myChar:FindFirstChild("HumanoidRootPart")
		if eye and eye:IsA("BasePart") then
			origin = eye.CFrame.Position
		end
	end
	local dir = to - origin
	local hit = Workspace:Raycast(origin, dir, rayParams)
	if not hit then return true end
	return (hit.Position - origin).Magnitude >= (dir.Magnitude - 0.25)
end

--------------------------------------------------------------------
-- 3. Velocity, freeze gate, lead
--------------------------------------------------------------------

local VEL_SPAN      = 0.18
local VEL_MIN_SPAN  = 0.03
local VEL_KEEP      = 1.0
local VEL_MAX_SPEED = 200
local VEL_RECENCY   = 0.06
local VEL_EPSILON   = 1e-4
local MOTION_GAP    = 0.08
local VEL_JUMP_SLACK = 1.5
local VEL_PLAUSIBLE  = 60

local velHist, velSweepAt = {}, 0

-- Measured from the character's own positions, not from AssemblyLinearVelocity:
-- a rig moved by CFrame writes reports 0 there while plainly moving, and a
-- walking body reports the vertical component of every step.
--
-- Recency-weighted line fit rather than an endpoint difference: the endpoint
-- form returns the velocity at the window's middle (90 ms stale) and collapses
-- to nothing the moment the target reverses inside it.
local function velocityFrom(model, root, now)
	now = now or os.clock()
	local pos = root.CFrame.Position
	local h = velHist[model]
	if not h then
		h = { p = { pos }, t = { now }, lastMove = now, lastMoveSpeed = 0 }
		velHist[model] = h
		return root.AssemblyLinearVelocity
	end

	if now - h.t[#h.t] > 1e-6 then
		local prev = h.p[#h.p]
		local step = pos - prev
		local gap = now - h.t[#h.t]

		-- A step further than this body could have walked is an arrival, not
		-- motion: a respawn, a server correction, or a body the game placed.
		local pace = math.min(h.lastMoveSpeed or 0, VEL_PLAUSIBLE)
		local span = math.min(gap, MOTION_GAP)
		if step.Magnitude > math.max(pace, C.FrozenMinSpeed) * span * 2 + VEL_JUMP_SLACK then
			h.p, h.t = { pos }, { now }
			h.step, h.lastMoveSpeed, h.motionStart = nil, 0, nil
			h.still = (h.still or 0) + 1
			return pos * 0
		end

		-- Horizontal displacement only: y is discounted on purpose, because a
		-- corpse keeps changing y as it settles.
		local flat = math.sqrt(step.X * step.X + step.Z * step.Z)
		if flat > VEL_EPSILON then
			if not h.motionStart or now - h.lastMove > MOTION_GAP then
				h.motionStart = now
			end
			h.lastMove = now
			h.motionRun = now - h.motionStart
			h.still = 0

			local prevSpeed = h.lastMoveSpeed or 0
			h.lastMoveSpeed = math.min(flat / gap, VEL_MAX_SPEED)

			-- A step that turns against the one before it, at real speed, is a
			-- reversal: keep the window and the fit spends the next fifth of a
			-- second averaging the direction already abandoned.
			if h.step and h.step:Dot(step) < 0
				and prevSpeed >= C.FrozenMinSpeed
				and h.lastMoveSpeed <= math.min(prevSpeed * 2, VEL_MAX_SPEED) then
				h.step = step
				h.p, h.t = { prev }, { h.t[#h.t] }
				h.p[2], h.t[2] = pos, now
				return step * (1 / gap)
			end
			h.step = step
		end
		if flat <= VEL_EPSILON then
			-- Counted, not timed: stillness has to be observed frame after frame,
			-- so a stalled frame cannot read as a body lying dead.
			h.still = (h.still or 0) + 1
		end
		h.p[#h.p + 1] = pos
		h.t[#h.t + 1] = now
	else
		if (pos - h.p[#h.p]).Magnitude > VEL_JUMP_SLACK then
			h.p, h.t = { pos }, { now }
			h.step, h.lastMoveSpeed, h.motionStart = nil, 0, nil
		else
			h.p[#h.p] = pos
		end
	end

	while #h.t > 2 and (now - h.t[1]) > VEL_SPAN do
		table.remove(h.p, 1)
		table.remove(h.t, 1)
	end

	if now - velSweepAt > 5 then
		velSweepAt = now
		for m, e in pairs(velHist) do
			if now - e.t[#e.t] > VEL_KEEP then
				velHist[m] = nil
			end
		end
	end

	local span = h.t[#h.t] - h.t[1]
	if span < VEL_MIN_SPAN then
		return root.AssemblyLinearVelocity
	end

	local sw, su, suu = 0, 0, 0
	local sx, sxu, sy, syu, sz, szu = 0, 0, 0, 0, 0, 0
	for i = 1, #h.t do
		local u = now - h.t[i]
		local w = math.exp(-u / VEL_RECENCY)
		local p = h.p[i]
		sw = sw + w
		su = su + w * u
		suu = suu + w * u * u
		sx, sxu = sx + w * p.X, sxu + w * u * p.X
		sy, syu = sy + w * p.Y, syu + w * u * p.Y
		sz, szu = sz + w * p.Z, szu + w * u * p.Z
	end
	local den = sw * suu - su * su
	if den < 1e-12 then
		return root.AssemblyLinearVelocity
	end
	local v = Vector3.new(
		-(sw * sxu - su * sx) / den,
		-(sw * syu - su * sy) / den,
		-(sw * szu - su * sz) / den
	)

	if v.Magnitude > VEL_MAX_SPEED then
		h.p, h.t = { pos }, { now }
		h.lastMoveSpeed, h.step = 0, nil
		return pos * 0
	end
	return v
end

-- A body that died mid-run stops dead and never moves again. The stop -- after
-- real sustained speed -- is the discriminator; the stillness alone is not.
local function isFrozen(model, now)
	if not C.IgnoreFrozen then return false end
	local h = velHist[model]
	if not h or not h.lastMove or not h.lastMoveSpeed then return false end
	if h.lastMoveSpeed < C.FrozenMinSpeed then return false end
	if (h.motionRun or 0) * 1000 < C.FrozenMotionMs then return false end
	if (h.still or 0) < C.FrozenFrames then return false end
	return (now - h.lastMove) * 1000 >= C.FrozenHoldMs
end

-- Our own velocity, sampled once per frame however many candidates are in view.
local selfVel, selfVelAt = nil, nil

local function selfVelocity(now)
	if selfVelAt == now then return selfVel end
	selfVelAt = now
	selfVel = nil
	local char = lp and lp.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if root then
		selfVel = velocityFrom(char, root, now)
	end
	return selfVel
end

local function leadPoint(point, velocity, from, ping, shooterVelocity)
	if shooterVelocity and C.LeadSelf then
		-- A lead is a claim about where the target will be RELATIVE to the
		-- shooter, so the shooter's own motion belongs in it.
		velocity = velocity - shooterVelocity
	end
	local ahead = (C.PredictionMs or 0) * 0.001
	if C.LeadByPing then
		ahead = ahead + (ping or 0) * 0.5
	end
	local speed = C.ProjectileSpeed or 0
	if speed > 1 then
		local flight = 0
		for _ = 1, 2 do
			flight = ((point + velocity * flight) - from).Magnitude / speed
		end
		ahead = ahead + math.min(flight, 1)
	end
	if C.LeadLoop then
		-- The tau approachAlpha actually used last frame, capped so a stalled
		-- solver cannot turn into an arbitrarily long prediction.
		ahead = ahead + clamp(S.tau or 0, 0, 0.12)
	end
	if ahead <= 0 then return point end
	local delta = velocity * ahead
	local cap = C.MaxLeadStuds or 0
	local mag = delta.Magnitude
	if cap > 0 and mag > cap then
		delta = delta * (cap / mag)
	end
	return point + delta
end

local function project(cam, world)
	local screen = cam:WorldToViewportPoint(world)
	if screen.Z <= 0 then return nil end
	return Vector2.new(screen.X, screen.Y)
end

--------------------------------------------------------------------
-- 4. Candidate sources
--------------------------------------------------------------------

local playerCache = {}
local playerCacheAt = -math.huge

local function playerList(now)
	if (now - playerCacheAt) > 0.4 then
		playerCache = Players:GetPlayers()
		playerCacheAt = now
	end
	return playerCache
end

local playerNames, playerNamesAt = {}, -math.huge

local function refreshPlayerNames(now)
	if (now - playerNamesAt) > 0.4 then
		playerNames = {}
		for _, p in ipairs(Players:GetPlayers()) do
			playerNames[string.lower(p.Name)] = true
		end
		playerNamesAt = now
	end
	return playerNames
end

local function looksLikeHash(name)
	local hex, other = 0, 0
	for i = 1, #name do
		local c = name:sub(i, i)
		if c:match("%x") then
			hex = hex + 1
		elseif c ~= "-" and c ~= "_" then
			other = other + 1
		end
	end
	return other == 0 and hex >= 16
end

local ignoreSet, ignoreSig = {}, nil

local function nameLooksIgnored(model)
	local name = string.lower(model.Name)
	for _, entry in ipairs(C.IgnoreNames or {}) do
		if name == string.lower(tostring(entry)) then return true end
	end
	for _, entry in ipairs(C.IgnoreSubstrings or {}) do
		if string.find(name, tostring(entry), 1, true) then return true end
	end
	return false
end

local function isIgnored(model)
	if ignoreSig ~= C.IgnoreNames then
		ignoreSig = C.IgnoreNames
		ignoreSet = {}
		for _, entry in ipairs(ignoreSig or {}) do
			ignoreSet[string.lower(tostring(entry))] = true
		end
	end
	local name = string.lower(model.Name)
	if ignoreSet[name] then return true end
	for _, sub in ipairs(C.IgnoreSubstrings or {}) do
		if string.find(name, sub, 1, true) then return true end
	end
	return false
end

-- The game's own death flag. Measured live: a dead player's character still
-- reads Humanoid Health 100 in state Running while the player's attributes read
-- Health = 0 and State = "Dead". The attributes flip at the instant of death.
local function gameDead(player)
	if not player or C.UseGameDeathFlag == false then return false end
	local ok, hp = pcall(function() return player:GetAttribute("Health") end)
	if ok and type(hp) == "number" and hp <= 0 then return true end
	local ok2, st = pcall(function() return player:GetAttribute("State") end)
	return ok2 and st == "Dead"
end

--------------------------------------------------------------------
-- 5. NPC registry
--
-- One full workspace walk, kept current by DescendantAdded, re-walked every few
-- seconds as a safety net. Workspace:GetDescendants() per frame is the one
-- thing that makes an NPC-capable aimbot unplayable on a large map: measured
-- 2.2-2.9 ms warm but 207-370 ms on the first call.
--------------------------------------------------------------------

local npcSet, npcArr = {}, {}
local NO_NPCS = {}
local npcScanned = false
local npcHooked = false
local npcPending = false
local npcRescanAt = 0
local NPC_RESCAN = 10

local function npcAdd(model)
	if model and not npcSet[model] then
		npcSet[model] = true
		npcArr[#npcArr + 1] = model
	end
end

local DEAD_STATES = { Dead = true }
-- Downed is not dead: FallingDown / PlatformStanding / Physics are poses a
-- fighting game puts a live, full-health enemy into when it is knocked over.
local DOWNED_STATES = { FallingDown = true, PlatformStanding = true, Physics = true }
local downedSeen = {}
S.downedIsAlive = S.downedIsAlive or false

local function isLiveHumanoid(hum)
	local ok, st = pcall(function() return hum:GetState() end)
	if not ok or st == nil then return true end
	local name = tostring(st):gsub("Enum%.HumanoidStateType%.", "")
	if DEAD_STATES[name] then return false end
	local model = hum.Parent
	if not DOWNED_STATES[name] then
		if model and downedSeen[model] then
			S.downedIsAlive = true
			for k in pairs(downedSeen) do downedSeen[k] = nil end
		end
		return true
	end
	if S.downedIsAlive then return true end
	if model and hum.Health > 0 then
		downedSeen[model] = true
	end
	return false
end

local function isLiveModel(model)
	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum then
		return isLiveHumanoid(hum)
	end
	-- A rig with no Humanoid counts as live only when the game says so: "not
	-- stated dead" is exactly what a pooled copy looks like.
	return rigStatedDead(model) == false
end

local function hasTag(inst, tag)
	local ok, v = pcall(function() return CollectionService:HasTag(inst, tag) end)
	return ok and v == true
end

-- What the game says this model is. A body tag beats a live tag: a rig carrying
-- both is far more likely to be a re-tagged corpse than something to shoot.
local function tagKind(model)
	local ok, list = pcall(function() return CollectionService:GetTags(model) end)
	if not ok or type(list) ~= "table" then return nil end
	local seen = {}
	for i = 1, #list do
		seen[string.lower(tostring(list[i]))] = true
	end
	for i = 1, #C.BodyTags do
		if seen[C.BodyTags[i]] then return "body" end
	end
	for i = 1, #C.LiveTags do
		if seen[C.LiveTags[i]] then return "live" end
	end
	return nil
end

local function reject(why)
	S.reject[why] = (S.reject[why] or 0) + 1
end

local function npcScan()
	local n = 0
	for i = 1, #npcArr do
		local model = npcArr[i]
		if model.Parent then
			n = n + 1
			npcArr[n] = model
		else
			npcSet[model] = nil
		end
	end
	for i = n + 1, #npcArr do npcArr[i] = nil end

	-- Measure whether "anchored" separates decoration from targets in THIS
	-- place. Place A: real NPCs unanchored, anchored rigs decorative. Place B:
	-- the reverse. If no head-bearing rig is unanchored, the filter carries no
	-- signal and would only destroy targets.
	local headBearing, headUnanchored = 0, 0
	for _, desc in ipairs(Workspace:GetDescendants()) do
		if desc:IsA("Humanoid") then
			local model = modelOf(desc)
			if model and not Players:GetPlayerFromCharacter(model)
				and not nameLooksIgnored(model) then
				npcAdd(model)
				if findPart(model, PART_NAMES.Head) then
					headBearing = headBearing + 1
					local root = rootOf(model, desc)
					local anchor = root and (root.AssemblyRootPart or root)
					if anchor and not anchor.Anchored then
						headUnanchored = headUnanchored + 1
					end
				end
			end
		end
	end

	-- Rigs with no Humanoid at all, which the pass above cannot see.
	for _, desc in ipairs(Workspace:GetDescendants()) do
		if desc:IsA("BasePart") and string.lower(desc.Name) == "head" then
			local model = desc.Parent
			if model and model:IsA("Model")
				and not model:FindFirstChildOfClass("Humanoid")
				and not Players:GetPlayerFromCharacter(model)
				and not nameLooksIgnored(model)
				and rigStatedDead(model) == false
				and isBareCharacter(model, desc, findPart(model, PART_NAMES.Root)) then
				npcAdd(model)
				headBearing = headBearing + 1
				local anchor = desc.AssemblyRootPart or desc
				if not anchor.Anchored then
					headUnanchored = headUnanchored + 1
				end
			end
		end
	end

	S.anchorFilterUsable = not (headBearing > 0 and headUnanchored == 0)
	S.headBearing = headBearing
	S.headUnanchored = headUnanchored

	-- Does this place label its entities, and does it label ALL of them? A tag
	-- only becomes a requirement when a live tag is present AND the unlabelled
	-- models are not the majority.
	local taggedLive, untaggedLive = 0, 0
	for i = 1, #npcArr do
		local m = npcArr[i]
		if isLiveModel(m) then
			local kind = tagKind(m)
			if kind == "live" then
				taggedLive = taggedLive + 1
			elseif kind == nil then
				untaggedLive = untaggedLive + 1
			end
		end
	end
	S.taggedLive = taggedLive
	S.untaggedLive = untaggedLive
	S.requireTags = taggedLive > 0 and untaggedLive <= taggedLive

	-- Does having a head identify a LIVE npc here? If every live one is
	-- headless, the requirement selects corpses instead of targets.
	local liveN, liveHeadless = 0, 0
	for i = 1, #npcArr do
		local m = npcArr[i]
		if isLiveModel(m) and tagKind(m) ~= "body" then
			liveN = liveN + 1
			if not findPart(m, PART_NAMES.Head) then
				liveHeadless = liveHeadless + 1
			end
		end
	end
	S.liveNPCs = liveN
	S.liveHeadless = liveHeadless
	S.headRequirementUsable = not (liveN > 0 and liveHeadless == liveN)
	S.reject = {}
end

local function npcHook()
	if npcHooked then return end
	npcHooked = true
	pcall(function()
		on(Workspace.DescendantAdded, function(desc)
			if not C.NPCCheck then return end
			if desc:IsA("Humanoid") then
				local model = modelOf(desc)
				if model and not Players:GetPlayerFromCharacter(model) then
					npcAdd(model)
				end
			end
		end)
	end)
end

local function npcList(now)
	if not C.NPCCheck then return NO_NPCS end
	npcHook()
	if not npcScanned then
		-- The first walk is the expensive one: hand it to the end of the frame
		-- so the camera update is not the thing that stalls.
		if not npcPending then
			npcPending = true
			local deferred = type(task.defer) == "function" and task.defer or task.spawn
			deferred(function()
				npcPending = false
				if S.unloaded or not C.NPCCheck then return end
				npcScan()
				npcScanned = true
				npcRescanAt = os.clock() + NPC_RESCAN
			end)
		end
		return NO_NPCS
	elseif now >= npcRescanAt then
		npcScan()
		npcRescanAt = now + NPC_RESCAN
	end
	return npcArr
end

--------------------------------------------------------------------
-- 6. Candidate build + acquisition
--------------------------------------------------------------------

-- The range and rear-hemisphere gates run BEFORE the oriented-box maths and the
-- projection, which is what keeps a map full of NPCs affordable.
local function buildCandidate(model, player, ctx)
	if not model or not model.Parent then return nil end
	if isIgnored(model) then return nil end

	if not player and C.FriendlyFolders then
		local node = model
		for _ = 1, 5 do
			if not node or not node.Name then break end
			local lowered = string.lower(node.Name)
			for i = 1, #C.FriendlyFolders do
				if lowered == C.FriendlyFolders[i] then return nil end
			end
			node = node.Parent
		end
	end
	-- A dead body belonging to a player keeps that player's name and has no
	-- Player behind it, so it arrives here as an NPC.
	if not player and refreshPlayerNames(os.clock())[string.lower(model.Name)] then
		return nil
	end
	if not player and C.IgnoreHashNames and looksLikeHash(model.Name) then
		return nil
	end

	if not player then
		local kind = tagKind(model)
		if kind == "body" then
			reject("tagged body")
			return nil
		end
		if kind == nil and S.requireTags then
			reject("untagged")
			return nil
		end
		-- A Humanoid model nested inside another Humanoid model is that model's
		-- body, not a second entity.
		local node = model.Parent
		for _ = 1, 6 do
			if not node then break end
			if node:IsA("Model") and node:FindFirstChildOfClass("Humanoid") then
				reject("nested body")
				return nil
			end
			node = node.Parent
		end
		if teamBlocked(nil, model) then
			reject("same team (npc)")
			return nil
		end
	end

	if player then
		if gameDead(player) then
			reject("dead (game flag)")
			return nil
		end
		if player == lp then return nil end
		if friendList[player.UserId] then return nil end
		if teamBlocked(player, model) then
			reject("same team")
			return nil
		end
		if friendBlocked(player) then
			reject("friend")
			return nil
		end
	end

	local hum = model:FindFirstChildOfClass("Humanoid")
		or model:FindFirstChildWhichIsA("Humanoid", true)
	if hum and hum.Health <= 0 then return nil end

	local root = rootOf(model, hum)
	if not root then return nil end

	local head = findPart(model, PART_NAMES.Head)
	if C.RequireHead and S.headRequirementUsable ~= false and not head then
		return nil
	end

	if not hum then
		if not isBareCharacter(model, head, root) then
			reject("no humanoid")
			return nil
		end
		local stated = rigStatedDead(model)
		if stated == true then
			reject("rig stated dead")
			return nil
		end
		-- A rig with no Humanoid must be stated ALIVE, not merely unstated: a
		-- stored copy is shaped exactly like a body.
		if stated == nil then
			reject("rig not stated alive")
			return nil
		end
	end

	-- A ragdoll is not a target, whatever its name, rig or health says. Applied
	-- to players too: a dead player's body can still be Player.Character.
	if hum and not isLiveHumanoid(hum) then
		reject("not live")
		return nil
	end

	local frozenNow = ctx.now or os.clock()
	if isFrozen(model, frozenNow) then
		velocityFrom(model, root, frozenNow)
		reject("frozen body")
		return nil
	end

	if not player and C.IgnoreAnchored and S.anchorFilterUsable ~= false then
		local anchor = root.AssemblyRootPart or root
		if anchor.Anchored then
			reject("anchored")
			return nil
		end
	end

	local rel = root.CFrame.Position - ctx.from
	local distSq = rel:Dot(rel)
	if ctx.range2 > 0 and distSq > ctx.range2 then return nil end
	if ctx.frontGate and rel:Dot(ctx.look) < -root.Size.Magnitude then return nil end
	if ctx.minDot then
		local len = math.sqrt(distSq)
		if len > 1e-3 and (rel:Dot(ctx.look) / len) < ctx.minDot then return nil end
	end

	local part = partFor(model, root, head, player == nil)
	local raw = aimPointFor(part, ctx.from)
	local velocity = velocityFrom(model, root, ctx.now)
	local point = leadPoint(raw, velocity, ctx.from, S.ping, selfVelocity(ctx.now))
	local screen = project(ctx.cam, point)
	if not screen then
		if ctx.frontGate or ctx.minDot then
			reject("off screen")
			return nil
		end
		return {
			model = model, player = player, part = part,
			raw = raw, point = point, dist = math.sqrt(distSq),
			distSq = distSq, behind = true,
		}
	end

	local sx = screen.X - ctx.refX
	local sy = screen.Y - ctx.refY
	local px2 = sx * sx + sy * sy
	if px2 > ctx.fov2 then
		reject("outside fov")
		return nil
	end

	S.reject.accepted = (S.reject.accepted or 0) + 1

	return {
		model  = model,
		player = player,
		label  = player and player.Name or (model.Name .. " · npc"),
		part   = part,
		point  = point,
		screen = screen,
		dist   = (point - ctx.from).Magnitude,
		distSq = distSq,
		distPx = math.sqrt(px2),
		speed  = velocity.Magnitude,
		lead   = (point - raw).Magnitude,
		raw    = raw,
		score  = 0,
		visible = not C.WallCheck,
	}
end

local function byScore(a, b)
	return a.score < b.score
end

local function acquire(cam, vp, refX, refY, now, outList)
	if outList then
		for i = 1, #outList do outList[i] = nil end
	end
	-- Range 0 is the slider's floor and reads as "detect nothing"; it used to
	-- read as its opposite, because range2 = 0 is the "no gate" sentinel.
	if (tonumber(C.Range) or 0) <= 0 then return nil end

	local camCF = cam.CFrame
	local ctx = {
		cam    = cam,
		from   = camCF.Position,
		look   = camCF.LookVector,
		refX   = refX,
		refY   = refY,
		fov2   = C.FOV * C.FOV,
		range2 = C.Range * C.Range,
		frontGate = true,
		now    = now,
	}
	local cands = {}

	for _, player in ipairs(playerList(now)) do
		local cand = buildCandidate(player.Character, player, ctx)
		if cand then cands[#cands + 1] = cand end
	end
	if C.NPCCheck then
		local list = npcList(now)
		for i = 1, #list do
			local cand = buildCandidate(list[i], nil, ctx)
			if cand then cands[#cands + 1] = cand end
		end
	end

	local count = #cands
	if count == 0 then return nil end

	-- Stickiness: the incumbent wins ties unless a newcomer is meaningfully
	-- nearer by the active metric.
	local incumbent = S.target and S.target.model
	for i = 1, count do
		local cand = cands[i]
		local metric = C.PickClosest and cand.dist or cand.distPx
		if incumbent and cand.model == incumbent then
			metric = metric * C.Sticky
		end
		cand.score = metric
	end

	table.sort(cands, byScore)
	if outList then
		for i = 1, #cands do outList[i] = cands[i] end
	end

	-- Raycast only until something is visible: one ray per candidate that
	-- actually outranks the rest.
	local limit = math.min(count, 5)
	for i = 1, limit do
		local cand = cands[i]
		if C.WallCheck and not cand.visible then
			cand.visible = isVisible(ctx.from, cand.point, cand.model)
		end
		if cand.visible then return cand end
	end
	return nil
end

-- A held lock must survive the mouse, so it is re-derived from the character
-- rather than from the FOV ring (which the game's own camera moves).
local function targetFor(model, player, cam)
	if not model and not player then return nil end
	local char = model or (player and player.Character)
	if not char then return nil end
	if (tonumber(C.Range) or 0) <= 0 then return nil end

	local ctx = {
		cam    = cam,
		from   = cam.CFrame.Position,
		look   = cam.CFrame.LookVector,
		refX   = 0,
		refY   = 0,
		fov2   = math.huge,
		range2 = C.Range * C.Range,
		frontGate = false,
		minDot = math.cos(math.rad(clamp(C.MaxLockDeg or 75, 1, 179))),
		now    = os.clock(),
	}
	local cand = buildCandidate(char, player, ctx)
	if not cand then return nil end
	if C.WallCheck and not cand.visible then
		if not isVisible(ctx.from, cand.point, char) then return nil end
		cand.visible = true
	end
	return cand
end

--------------------------------------------------------------------
-- 7. Solvers
--------------------------------------------------------------------

local function approachAlpha(angle, dt)
	local smooth = clamp(C.Smoothing / 100, 0, 1)
	local strength = math.max(C.Strength / 100, 0.05)
	-- 0.002 at Smoothing 0 so the authored "0 snaps" is actually true.
	local tau = (0.002 + 0.298 * smooth) / strength

	-- Adaptive speed: shrink tau until the lag the loop would settle at fits
	-- MaxLag, and raise the cap so the smaller tau survives the clamp.
	local capDeg = C.MaxSpeed
	local rate = S.aimRate or 0
	if C.AdaptiveSpeed and rate > 1 then
		local lagAllowed = math.max((C.MaxLagX10 or 5) / 10, 0.05)
		local tauNeeded = lagAllowed / rate
		if tauNeeded < tau then tau = tauNeeded end
		local adaptiveCap = math.min(rate * 3, C.MaxSpeedCeiling or 2000)
		if adaptiveCap > capDeg then capDeg = adaptiveCap end
	end

	local alpha = 1 - math.exp(-dt / tau)
	-- A monotone exponential: the old near-target brake turned a 12 deg
	-- correction into a 1.6 s crawl that still stalled ~0.45 deg short.
	local norm = clamp(angle / 35, 0, 1)
	alpha = alpha * (0.75 + 0.25 * norm)

	-- The constant this loop is actually running at, brake included: for a
	-- small residual alpha is dt/tauEff. leadPoint advances the aim point by
	-- this much target travel, cancelling exactly the lag it settles at.
	S.tau = tau / (0.75 + 0.25 * norm)

	local maxStep = math.rad(capDeg) * dt
	local needed = math.rad(math.max(angle, 0.0001))
	if alpha * needed > maxStep then
		alpha = maxStep / needed
	end
	return clamp(alpha, 0, 1)
end

-- Rotate unit vector u toward unit vector v by exactly `deg` degrees. A
-- renormalised lerp does not give a uniform angular rate, so MaxSpeed was never
-- the slew rate it claimed to be.
local function rotateToward(u, v, deg)
	local axis = u:Cross(v)
	local magnitude = axis.Magnitude
	if magnitude < 1e-6 then return v end
	local k = axis * (1 / magnitude)
	local a = math.rad(deg)
	local rotated = u * math.cos(a) + k:Cross(u) * math.sin(a)
	if rotated.Magnitude < 1e-6 then return v end
	return rotated.Unit
end

local function resetAim()
	S.human = nil
	S.humanGoal = nil
	S.missed = 0
	S.aimDir = nil
	S.aimRate = 0
	-- Drop the remembered render so a fresh engage starts from whatever the
	-- game is showing now, not from a direction we left behind.
	S.rendered = nil
	S.ownsCamera = false
	S.sentX, S.sentY = nil, nil
	S.lockModel = nil
	S.lockPlayer = nil
	S.lockMiss = 0
end

local function yawPitchOf(look)
	return math.deg(math.atan2(-look.X, -look.Z)), math.deg(math.asin(clamp(look.Y, -1, 1)))
end

local function lookAngles(cf)
	local look = cf.LookVector
	local yaw = math.atan2(-look.X, -look.Z)
	local pitch = math.asin(clamp(look.Y, -1, 1))
	return yaw, pitch
end

-- Which transport the aim drives through:
--   "aegis" -> getgenv().Input.MoveMouse, the injector's own primitive
--   "raw"   -> the executor's mousemoverel
--   "none"  -> neither exists; the caller falls back to the camera write
local function activeTransport()
	if C.SimulateInput and genv then
		local I = genv.Input
		if type(I) == "table" and type(I.MoveMouse) == "function" then
			return "aegis"
		end
	end
	if type(mousemoverel) == "function" then
		return "raw"
	end
	return "none"
end

-- Every mouse delta goes through here, so the toggle covers the calibrated
-- input driver and the fixed-gain mouse driver alike.
local function sendDelta(dx, dy)
	if activeTransport() == "aegis" then
		if genv and genv.Input and type(genv.Input.MoveMouse) == "function" then
			if pcall(genv.Input.MoveMouse, dx, dy) then
				return true
			end
		end
	end
	if type(mousemoverel) == "function" then
		return pcall(mousemoverel, dx, dy)
	end
	return false
end

local solveInput

-- Calibrated input driver: a 40-unit pulse per axis on first engage, then the
-- degrees-per-unit constant refined every frame from what the last pulse
-- achieved.
solveInput = function(cam, point, dt)
	local camCF = cam.CFrame
	local curLook = camCF.LookVector
	local wantLook = point - camCF.Position
	if wantLook.Magnitude < 1e-3 then return 0 end
	wantLook = wantLook.Unit

	local curYaw, curPitch = yawPitchOf(curLook)
	local wantYaw, wantPitch = yawPitchOf(wantLook)
	local errYaw = wrap180(wantYaw - curYaw)
	local errPitch = wantPitch - curPitch
	local err = math.sqrt(errYaw * errYaw + errPitch * errPitch)

	if not S.cal then
		S.cal = 1
		S.calRefYaw, S.calRefPitch = curYaw, curPitch
		sendDelta(40, 0)
		return err
	elseif S.cal == 1 then
		S.axisYaw = wrap180(curYaw - S.calRefYaw) / 40
		S.calRefYaw, S.calRefPitch = curYaw, curPitch
		S.cal = 2
		sendDelta(0, 40)
		return err
	elseif S.cal == 2 then
		S.axisPitch = (curPitch - S.calRefPitch) / 40
		S.cal = 3
		if math.abs(S.axisYaw or 0) < 1e-5 or math.abs(S.axisPitch or 0) < 1e-5 then
			S.inputFailed = true     -- input never reached the camera script
			return err
		end
	end

	if S.sentX and math.abs(S.sentX) > 4 then
		local g = wrap180(curYaw - S.calRefYaw) / S.sentX
		if math.abs(g) > 1e-5 and math.abs(g) < 5 then
			S.axisYaw = S.axisYaw * 0.7 + g * 0.3
		end
	end
	if S.sentY and math.abs(S.sentY) > 4 then
		local g = (curPitch - S.calRefPitch) / S.sentY
		if math.abs(g) > 1e-5 and math.abs(g) < 5 then
			S.axisPitch = S.axisPitch * 0.7 + g * 0.3
		end
	end

	if err <= (C.DeadzoneX100 / 100) then
		S.sentX, S.sentY = nil, nil
		return err
	end

	local stepDeg = math.min(err * approachAlpha(err, dt), math.max(1, C.MaxSpeed * dt))
	local scale = stepDeg / math.max(err, 1e-6)

	local dx = clamp((errYaw * scale) / S.axisYaw, -400, 400)
	local dy = clamp((errPitch * scale) / S.axisPitch, -400, 400)

	S.calRefYaw, S.calRefPitch = curYaw, curPitch
	S.sentX, S.sentY = dx, dy
	sendDelta(dx, dy)
	return err
end

-- The camera belongs to the game. A stock CameraModule rebuilds CFrame from its
-- own yaw/pitch every frame, so an absolute write is discarded and the view
-- parks one smoothing step off target. Keep our own rotation instead: recover
-- the orientation the controller produced, advance the correction in that
-- frame, and publish base * offset. The offset survives the rewrite.
local function solveCamera(cam, point, dt)
	local camCF = cam.CFrame
	if (point - camCF.Position).Magnitude < 0.5 then return 0 end

	local desired = CFrame.lookAt(camCF.Position, point)
	local camErr = math.deg(math.acos(clamp(camCF.LookVector:Dot(desired.LookVector), -1, 1)))

	-- Did the game put the camera back where its own controller wanted it?
	if S.rendered then
		S.ownsCamera = (S.rendered.LookVector - camCF.LookVector).Magnitude < 1e-4
	end

	if camErr <= (C.DeadzoneX100 / 100) then
		cam.CFrame = desired
		S.rendered = desired
		S.ownsCamera = true
		return camErr
	end

	local from = S.rendered or camCF
	if (from.LookVector - camCF.LookVector).Magnitude > 1.9 then
		from = camCF            -- view was reset or flipped: start from the game
	end

	local remaining = math.deg(math.acos(clamp(from.LookVector:Dot(desired.LookVector), -1, 1)))
	local stepDeg = remaining * approachAlpha(remaining, dt)
	local capDeg = C.MaxSpeed

	if C.AdaptiveSpeed then
		local rate = math.min(S.aimRate or 0, C.MaxSpeedCeiling or 2000)
		capDeg = math.min(math.max(C.MaxSpeed, rate * 3), C.MaxSpeedCeiling or 2000)
	end

	stepDeg = math.min(stepDeg, capDeg * dt)
	local look = rotateToward(from.LookVector, desired.LookVector, stepDeg)

	-- Position is always the game's; only the look direction is ours.
	local outCF = CFrame.lookAt(camCF.Position, camCF.Position + look)
	cam.CFrame = outCF
	S.rendered = outCF
	return remaining
end

local function solveMouse(cam, point, dt)
	local origin = cam.CFrame.Position
	if (point - origin).Magnitude < 0.5 then return 0 end

	local curYaw, curPitch = lookAngles(cam.CFrame)
	local wantYaw, wantPitch = lookAngles(CFrame.lookAt(origin, point))

	local dYaw = wrapDeg(math.deg(wantYaw - curYaw))
	local dPitch = math.deg(wantPitch - curPitch)
	local angle = math.sqrt(dYaw * dYaw + dPitch * dPitch)
	if angle <= (C.DeadzoneX100 / 100) then return angle end

	local sens = math.max(C.SensX10 / 10, 0.2)
	local norm = clamp(angle / 35, 0, 1)
	local budget = math.min(angle, C.MaxSpeed * dt * (0.3 + 0.7 * norm))
	local frac = budget / angle

	-- Positive screen dx turns right, which in Roblox is decreasing yaw.
	sendDelta(-dYaw * frac * sens, -dPitch * frac * sens)
	return angle
end

-- Humanisation is a HELD offset, not a per-frame dice roll: re-rolling it every
-- frame teleported the aim point by up to ~0.5 deg on every tick, so the solver
-- chased a point that kept jumping.
local function humanise(cam, point, residual, dt, speed)
	local tenths = C.HumanTenths
	if tenths <= 0 then return point end

	local now = os.clock()
	if not S.humanGoal or now - (S.humanAt or 0) > 0.4 then
		local dir = Vector3.new(math.random() * 2 - 1, math.random() * 2 - 1, 0)
		if dir.Magnitude > 1e-3 then dir = dir.Unit else dir = Vector3.new(0, 0, 0) end
		S.humanGoal = dir * ((tenths / 10) * (0.5 + math.random()))
		S.humanAt = now
	end
	if not S.human then S.human = Vector3.new(0, 0, 0) end
	S.human = S.human + (S.humanGoal - S.human) * clamp((dt or 0.016) * 5, 0, 1)

	local fade = clamp((residual or 99) / 3, 0, 1)
	local mobility = 1 / (1 + math.max(speed or 0, 0) * 0.35)
	local amount = fade * mobility
	if amount <= 0.001 then return point end

	local origin = cam.CFrame.Position
	local dist = (point - origin).Magnitude
	local lateral = cam.CFrame.RightVector * S.human.X + cam.CFrame.UpVector * S.human.Y
	return point + lateral * amount * dist * 0.01745
end

--------------------------------------------------------------------
-- 8. Drawing overlay
--
-- Drawing objects are NOT Instances: no Parent, never under any root. They
-- outlive the script, so every handle is published into the getgenv slot for
-- the next execution's sweep().
--------------------------------------------------------------------

local overlay = { available = false }

local function buildOverlay()
	if not Drawing or type(Drawing.new) ~= "function" then return false end
	local ok, circle = pcall(Drawing.new, "Circle")
	if not ok or not circle then return false end
	circle.Thickness = 1
	circle.NumSides = 64
	circle.Filled = false
	circle.Transparency = 0.85
	circle.Visible = false

	local okBox, box = pcall(Drawing.new, "Square")
	if not okBox or not box then
		pcall(function() circle:Remove() end)
		return false
	end
	box.Thickness = 1.5
	box.Filled = false
	box.Transparency = 0.85
	box.Visible = false

	if genv then
		genv[DRAW_KEY] = { circle = circle, box = box }
	end

	overlay.available = true
	overlay.kind = "drawing"

	overlay.circle = function(x, y, r, colour, visible)
		circle.Position = Vector2.new(x, y)
		circle.Radius = r
		circle.Color = colour
		circle.Visible = visible
	end

	overlay.box = function(x, y, w, h, colour, visible)
		box.Position = Vector2.new(x, y)
		box.Size = Vector2.new(w, h)
		box.Color = colour
		box.Visible = visible
	end

	local esp = {}
	overlay.esp = function(index, x, y, w, h, colour, visible)
		local o = esp[index]
		if not o then
			local okNew, obj = pcall(Drawing.new, "Square")
			if not okNew or not obj then return end
			obj.Thickness = 1
			obj.Filled = false
			obj.Transparency = 0.5
			obj.Visible = false
			esp[index] = obj
			if genv and type(genv[DRAW_KEY]) == "table" then
				genv[DRAW_KEY].esp = esp
			end
			o = obj
		end
		o.Position = Vector2.new(x, y)
		o.Size = Vector2.new(w, h)
		o.Color = colour
		o.Visible = visible
	end

	-- Called from `first` onward, so a frame with fewer candidates cannot leave
	-- the previous frame's outlines on screen.
	overlay.espHide = function(first)
		for i = first, #esp do
			if esp[i] then pcall(function() esp[i].Visible = false end) end
		end
	end

	local lines = {}
	overlay.line = function(index, x1, y1, x2, y2, colour, thickness, visible)
		local o = lines[index]
		if not o then
			local okNew, obj = pcall(Drawing.new, "Line")
			if not okNew or not obj then return end
			obj.Transparency = 0.35
			obj.Visible = false
			lines[index] = obj
			if genv and type(genv[DRAW_KEY]) == "table" then
				genv[DRAW_KEY].lines = lines
			end
			o = obj
		end
		o.From = Vector2.new(x1, y1)
		o.To = Vector2.new(x2, y2)
		o.Color = colour
		o.Thickness = thickness
		o.Visible = visible
	end

	overlay.lineHide = function(first)
		for i = first, #lines do
			if lines[i] then pcall(function() lines[i].Visible = false end) end
		end
	end

	overlay.destroy = function()
		pcall(function() circle.Visible = false end)
		pcall(function() box.Visible = false end)
		pcall(function() circle:Remove() end)
		pcall(function() box:Remove() end)
		for i = 1, #esp do
			if esp[i] then
				pcall(function() esp[i].Visible = false end)
				pcall(function() esp[i]:Remove() end)
			end
		end
		for i = 1, #lines do
			if lines[i] then
				pcall(function() lines[i].Visible = false end)
				pcall(function() lines[i]:Remove() end)
			end
		end
		if genv and type(genv[DRAW_KEY]) == "table" and genv[DRAW_KEY].circle == circle then
			genv[DRAW_KEY] = nil
		end
	end

	return true
end

if not buildOverlay() then
	overlay.available = false
	overlay.kind = "none"
	overlay.circle = function() end
	overlay.box = function() end
	overlay.destroy = function() end
end

-- Projection basis for one frame, reused for every corner of every part. The
-- tangents are MEASURED from the engine: FieldOfViewMode is not trustworthy
-- (it reported Diagonal while the renderer projected vertical, 2.217x off).
local basis = { inv = nil, tanX = 1, tanY = 1, w = 1, h = 1, near = 0.05 }

local function viewBasis(cam, vp, camCF)
	local tanX, tanY
	local ok = pcall(function()
		local halfW, halfH = vp.X * 0.5, vp.Y * 0.5
		local px = cam:WorldToViewportPoint(camCF * Vector3.new(10, 0, -100))
		local py = cam:WorldToViewportPoint(camCF * Vector3.new(0, 10, -100))
		local dx = math.abs(px.X - halfW)
		local dy = math.abs(py.Y - halfH)
		if dx > 1e-3 and dy > 1e-3 then
			tanX = 0.05 * vp.X / dx
			tanY = 0.05 * vp.Y / dy
		end
	end)
	if not ok or not tanX or not tanY or tanX <= 0 or tanY <= 0 then
		local fov = math.rad(cam.FieldOfView)
		local mode = tostring(cam.FieldOfViewMode)
		if mode:find("Horizontal", 1, true) then
			tanX = math.tan(fov * 0.5)
			tanY = tanX * (vp.Y / vp.X)
		elseif mode:find("Diagonal", 1, true) then
			local a = vp.X / vp.Y
			tanY = math.tan(fov * 0.5) / math.sqrt(1 + a * a)
			tanX = tanY * a
		else
			tanY = math.tan(fov * 0.5)
			tanX = tanY * (vp.X / vp.Y)
		end
	end
	basis.inv = camCF:Inverse()
	basis.tanX, basis.tanY = tanX, tanY
	basis.w, basis.h = vp.X, vp.Y
	return basis
end

local function projectCorner(b, v)
	local z = -v.Z
	if z < b.near then z = b.near end
	return ((v.X / z) / b.tanX * 0.5 + 0.5) * b.w,
		(0.5 - ((v.Y / z) / b.tanY) * 0.5) * b.h
end

local function screenBox(b, parts)
	local minX, minY, maxX, maxY
	local pad = 1 + (C.PadPct / 100)
	for _, part in ipairs(parts) do
		if part and part.Parent and isPart(part) then
			local relCF = b.inv * part.CFrame
			-- Skip a part behind the near plane instead of clamping it: a
			-- clamped corner projects from z = near and lands nowhere near the
			-- part, which drew a box on the crosshair.
			if -relCF.Position.Z > b.near then
				local half = part.Size * 0.5 * pad
				local ax, ay, az = half.X, half.Y, half.Z
				for i = 0, 7 do
					local sx = (i % 2 == 0) and -ax or ax
					local sy = (math.floor(i / 2) % 2 == 0) and -ay or ay
					local sz = (i >= 4) and -az or az
					local x, y = projectCorner(b, relCF * Vector3.new(sx, sy, sz))
					if not minX or x < minX then minX = x end
					if not maxX or x > maxX then maxX = x end
					if not minY or y < minY then minY = y end
					if not maxY or y > maxY then maxY = y end
				end
			end
		end
	end
	if not minX then return nil end
	return minX, minY, maxX - minX, maxY - minY
end

local boxCache = { model = nil, at = -math.huge, parts = {} }

local function bodyParts(model, now)
	if boxCache.model == model and (now - boxCache.at) < 0.5 then
		return boxCache.parts
	end
	local parts = {}
	if model then
		for _, d in ipairs(model:GetDescendants()) do
			if isPart(d) and d.Transparency < 1 then
				parts[#parts + 1] = d
			end
		end
	end
	boxCache.model, boxCache.at, boxCache.parts = model, now, parts
	return parts
end

local singlePart = {}
local ESP_CANDS = {}

local visibleCache, visibleCount = {}, 0
local VISIBLE_TTL, VISIBLE_MAX = 0.5, 40
local NO_PARTS = {}

local function visibleParts(model, now)
	if not model then return NO_PARTS end
	local hit = visibleCache[model]
	if hit and (now - hit.at) < VISIBLE_TTL then
		return hit.parts
	end
	local parts = {}
	for _, d in ipairs(model:GetDescendants()) do
		if isPart(d) and d.Transparency < 0.95 then
			parts[#parts + 1] = d
		end
	end
	if not hit then
		visibleCount = visibleCount + 1
		if visibleCount > VISIBLE_MAX then
			for k in pairs(visibleCache) do visibleCache[k] = nil end
			visibleCount = 1
		end
	end
	visibleCache[model] = { at = now, parts = parts }
	return parts
end

local function modelScreenBox(b, model, now)
	local minX, minY, maxX, maxY

	-- The body's own geometry first: a model's world AABB is an axis-aligned
	-- superset that changes shape as the body turns, measured 41x50 px wider and
	-- offset 16/14 px from the visible body on a standing character.
	local parts = visibleParts(model, now or os.clock())
	for i = 1, #parts do
		local p = parts[i]
		local s = p.Size
		local phx, phy, phz = s.X * 0.5, s.Y * 0.5, s.Z * 0.5
		local prel = b.inv * p.CFrame
		-- The centre test is not enough: one corner behind the plane drew
		-- 18263 px tall extents. Require the part to clear the plane by its own
		-- reach.
		local reach = math.sqrt(s.X * s.X + s.Y * s.Y + s.Z * s.Z) * 0.5
		if -prel.Position.Z > b.near + reach then
			for c = 0, 7 do
				local sx = (c % 2 == 0) and -phx or phx
				local sy = (math.floor(c / 2) % 2 == 0) and -phy or phy
				local sz = (c >= 4) and -phz or phz
				local x, y = projectCorner(b, prel * Vector3.new(sx, sy, sz))
				if not minX or x < minX then minX = x end
				if not maxX or x > maxX then maxX = x end
				if not minY or y < minY then minY = y end
				if not maxY or y > maxY then maxY = y end
			end
		end
	end
	if minX then
		return minX, minY, maxX - minX, maxY - minY
	end

	-- Fallback for a place that hides every part it draws (measured: all 12
	-- parts reported Transparency = 1).
	local ok, cf, size = pcall(function()
		local centre, extent = model:GetBoundingBox()
		return centre, extent
	end)
	if not ok or not cf or not size then return nil end

	local relCF = b.inv * cf
	local reach = math.sqrt(size.X * size.X + size.Y * size.Y + size.Z * size.Z) * 0.5
	if -relCF.Position.Z <= b.near + reach then return nil end

	local hx, hy, hz = size.X * 0.5, size.Y * 0.5, size.Z * 0.5
	for i = 0, 7 do
		local sx = (i % 2 == 0) and -hx or hx
		local sy = (math.floor(i / 2) % 2 == 0) and -hy or hy
		local sz = (i >= 4) and -hz or hz
		local x, y = projectCorner(b, relCF * Vector3.new(sx, sy, sz))
		if not minX or x < minX then minX = x end
		if not maxX or x > maxX then maxX = x end
		if not minY or y < minY then minY = y end
		if not maxY or y > maxY then maxY = y end
	end
	if not minX then return nil end
	return minX, minY, maxX - minX, maxY - minY
end

local function paint(cam, vp, refX, refY, target, now, camCF)
	if not overlay.available then return end

	if C.ShowFov and C.Enabled then
		local colour = target and Color3.fromRGB(110, 231, 255) or Color3.fromRGB(90, 100, 120)
		overlay.circle(refX, refY, C.FOV, colour, true)
	else
		overlay.circle(0, 0, 1, Color3.fromRGB(110, 231, 255), false)
	end

	if not (C.ShowTarget and target and target.part) then
		overlay.box(0, 0, 1, 1, Color3.fromRGB(125, 220, 150), false)
		return
	end

	local b = viewBasis(cam, vp, camCF or cam.CFrame)
	local bx, by, bw, bh

	if C.BoxBody and target.model then
		bx, by, bw, bh = modelScreenBox(b, target.model)
	end
	if not bx then
		local parts = nil
		if C.BoxBody then
			parts = bodyParts(target.model, now)
		end
		if not parts or #parts == 0 then
			singlePart[1] = target.part
			parts = singlePart
		end
		bx, by, bw, bh = screenBox(b, parts)
	end
	-- Same rule as the ESP box: a rect covering half the screen is the
	-- camera-inside-the-body case, and it is drawn on top of the player rather
	-- than the target, so it is dropped instead of being drawn wrong.
	local sane = bx and bw > 0.5 and bh > 0.5
		and bw < vp.X * 0.5 and bh < vp.Y * 0.5
	if sane then
		overlay.box(bx, by, bw, bh,
			target.visible and Color3.fromRGB(125, 220, 150) or Color3.fromRGB(255, 118, 118),
			true)
	else
		overlay.box(0, 0, 1, 1, Color3.fromRGB(125, 220, 150), false)
	end
end

-- ESP keeps the wider question: every entity the gates allow, with Range still
-- bounding it (range2 = 0 is the "no gate" sentinel, which is why Range 0 used
-- to draw MORE than any other setting).
local function espCandidates(cam, now, out)
	local camCF = cam.CFrame
	for i = 1, #out do out[i] = nil end
	local range = tonumber(C.Range) or 0
	if range <= 0 then return out end

	local ctx = {
		cam    = cam,
		from   = camCF.Position,
		look   = camCF.LookVector,
		refX   = 0,
		refY   = 0,
		fov2   = math.huge,
		range2 = range * range,
		frontGate = false,
		now    = now,
	}

	local n = 0
	for _, player in ipairs(playerList(now)) do
		local cand = buildCandidate(player.Character, player, ctx)
		if cand then
			n = n + 1
			out[n] = cand
		end
	end
	if C.NPCCheck then
		local list = npcList(now)
		for i = 1, #list do
			local cand = buildCandidate(list[i], nil, ctx)
			if cand then
				n = n + 1
				out[n] = cand
			end
		end
	end
	for i = n + 1, #out do out[i] = nil end
	return out
end

-- Snaplines are Drawing lines, i.e. screen space, and that is the only thing
-- that can work: a line joining the eye to a hitbox lies along a view ray, so
-- real geometry there is seen end-on and collapses into a dot.
local ESP_LINE_REF = 100

local function linePixels(dist)
	local base = math.max(C.ESPLinePx or 2, 1)
	local px = math.floor(base * ESP_LINE_REF / math.max(dist or 1, 1) + 0.5)
	return clamp(px, 1, base * 2)
end

local function drawESP(cam, vp, target, cands, camCF)
	if not (C.ESP and overlay.esp) then
		if overlay.espHide then overlay.espHide(1) end
		if overlay.lineHide then overlay.lineHide(1) end
		return
	end

	local basisCF = camCF or cam.CFrame
	local b = viewBasis(cam, vp, basisCF)
	local camPos = basisCF.Position
	local lookup = basisCF.LookVector
	local drawn, lined = 0, 0

	-- Players before NPCs, nearest first within each group: ESPMax is a budget of
	-- drawn primitives, and spending it in pure distance order let a cluster of
	-- NPCs take every slot and leave an enemy with no box.
	table.sort(cands, function(a, b2)
		local ap = a.player ~= nil
		local bp = b2.player ~= nil
		if ap ~= bp then return ap end
		return (a.distSq or 0) < (b2.distSq or 0)
	end)
	local limit = math.min(#cands, C.ESPMax or 12)

	for i = 1, limit do
		local c = cands[i]
		local model = c.model
		if model and model.Parent then
			local world = c.point or (c.part and c.part.CFrame.Position)
			if world then
				local rel = world - camPos
				if rel.Magnitude <= 1 then
					-- nothing to draw
				elseif rel:Dot(lookup) <= 0 then
					-- Behind the eye: the bearing still exists, so the line is
					-- kept and sent to the nearest screen edge instead of
					-- vanishing with the projection.
					if rel.Magnitude <= (C.ESPLineRangeStuds or C.Range or 300)
						and C.ESPLine and overlay.line then
						local flat = Vector3.new(rel.X, 0, rel.Z)
						local side = 0
						if flat.Magnitude > 1e-3 then
							local rightFlat = Vector3.new(basisCF.RightVector.X, 0,
								basisCF.RightVector.Z)
							if rightFlat.Magnitude > 1e-3 then
								side = clamp(flat.Unit:Dot(rightFlat.Unit), -1, 1)
							end
						end
						local rise = clamp(rel.Unit.Y, -1, 1)

						local margin = math.min(vp.X, vp.Y) * 0.06
						local cx, cy = vp.X * 0.5, vp.Y * 0.5
						local ex, ey
						if math.abs(side) > math.abs(rise) then
							ex = side >= 0 and (vp.X - margin) or margin
							ey = clamp(cy + rise * vp.Y * 0.30, margin, vp.Y - margin)
						else
							ex = clamp(cx + side * vp.X * 0.40, margin, vp.X - margin)
							ey = rise < 0 and (vp.Y - margin) or margin
						end

						lined = lined + 1
						overlay.line(lined, cx, cy, ex, ey,
							Color3.fromRGB(255, 214, 10),
							linePixels(rel.Magnitude), true)
					end
				else
					local bx, by, bw, bh = modelScreenBox(b, model)
					-- Off-screen boxes are culled: a Drawing object parked at
					-- x = -1400 reads as a box frozen at the border.
					local onScreen = bx ~= nil
						and bx + bw > 0 and bx < vp.X
						and by + bh > 0 and by < vp.Y
					-- A rect larger than half the viewport is not a box: it is the
					-- case where the camera sits inside or just behind the body and
					-- every corner projects outward from the centre, so the rect's
					-- centre lands on the player's own character. That is the "ESP
					-- and snapline are drawn on me, pointing at me" report -- and at
					-- that size the box identifies nothing, so it is not drawn, nor
					-- is the line that would hang off it. rel.Magnitude is camera
					-- distance; 6 studs is inside the third-person camera-to-body
					-- gap, i.e. an entity between the eye and the player.
					local sane = onScreen and bw > 1 and bh > 1
						and bw < vp.X * 0.5 and bh < vp.Y * 0.5
						and rel.Magnitude > 6
					if sane then
						drawn = drawn + 1
						local hot = (target ~= nil) and (model == target.model)
						local colour = hot and C.ESPTargetColor or C.ESPColor
						overlay.esp(drawn, bx, by, bw, bh, colour, true)
						if C.ESPLine and overlay.line then
							lined = lined + 1
							overlay.line(lined, vp.X * 0.5, vp.Y * 0.5,
								bx + bw * 0.5, by + bh * 0.5, colour,
								linePixels(rel.Magnitude), true)
						end
					end
				end
			end
		end
	end

	overlay.espHide(drawn + 1)
	if overlay.lineHide then overlay.lineHide(lined + 1) end
end

--------------------------------------------------------------------
-- 9. Gun-aware aiming
--
-- Measured: the first-person weapon is a Model under workspace.Camera, its
-- muzzle ~1.5-1.8 studs ahead of the eye and offset laterally, so a shot cast
-- from the muzzle along the camera look is ~11 deg off at 10 studs.
--------------------------------------------------------------------

local MUZZLE_NAMES = {
	"muzzle", "muzzlepoint", "muzzle_point", "barrel", "barreltip",
	"pointfrontsight", "frontsight", "tip",
}

local muzzlePart, muzzleAt = nil, -math.huge

local function findMuzzle(now)
	if (now - muzzleAt) < 1 then return muzzlePart end
	muzzleAt = now
	muzzlePart = nil

	local container = Workspace:FindFirstChild("Camera")
	if container then
		local best, bestParts = nil, 0
		for _, m in ipairs(container:GetChildren()) do
			if m:IsA("Model") then
				local n = 0
				for _, d in ipairs(m:GetDescendants()) do
					if d:IsA("BasePart") then n = n + 1 end
				end
				if n > bestParts then
					best, bestParts = m, n
				end
			end
		end
		if best and bestParts >= 3 then
			for _, want in ipairs(MUZZLE_NAMES) do
				for _, d in ipairs(best:GetDescendants()) do
					if d:IsA("BasePart") and d.Name:lower():find(want, 1, true) then
						muzzlePart = d
						break
					end
				end
				if muzzlePart then break end
			end
		end
	end

	S.muzzleName = muzzlePart and muzzlePart.Name or nil
	return muzzlePart
end

local function gunAimPoint(camCF, point)
	if not C.GunAim then return point end
	local muzzle = findMuzzle(os.clock())
	if not muzzle or not muzzle.Parent then return point end
	local eye = camCF.Position
	local dist = (point - eye).Magnitude
	if dist < 1e-3 then return point end
	local dir = point - muzzle.CFrame.Position
	if dir.Magnitude < 1e-3 then return point end
	-- Same range as before, corrected bearing: the solvers see the distance they
	-- always saw and only the bearing changes.
	return eye + dir.Unit * dist
end

--------------------------------------------------------------------
-- 10. Status + frame step
--------------------------------------------------------------------

local nextStatusAt = 0
local lastStatusText = nil

A.setStatus = function(text)
	S.status = text
end

-- Writes are gated to 10 Hz and skipped when nothing changed, which keeps the
-- panel quiet while the solver is tracking.
local function publishStatus(text)
	local now = os.clock()
	if text == lastStatusText then return end
	if now < nextStatusAt then return end
	nextStatusAt = now + 0.1
	lastStatusText = text
	A.setStatus(text)
end

local function triggering()
	if not C.Enabled then return false end
	if C.RequireClick then
		local ok, pressed = pcall(function()
			return UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
		end)
		if ok and not pressed then return false end
	end
	if C.Activation == "always" then
		return true
	end
	if C.Activation == "toggle" then
		return S.toggled
	end

	-- "hold", and anything this build does not recognise, requires the key. The
	-- previous fall-through returned S.toggled for an unrecognised value, so one
	-- bad activation string -- a saved display label, say -- read as "always on".
	-- Poll the keyboard rather than trusting event bookkeeping: a press the game
	-- consumed, an InputEnded lost on alt-tab and a mouse release each left
	-- state.held stale in a different direction.
	local key = keyOf(C.HoldKey)
	if key then
		local ok, down = pcall(function() return UIS:IsKeyDown(key) end)
		if ok and type(down) == "boolean" then
			S.held = down
			return down
		end
	end
	return S.held
end

local function step(dt)
	local cam = Workspace.CurrentCamera
	if not cam then return end
	S.cam = cam

	local vp = cam.ViewportSize
	if vp.X <= 0 or vp.Y <= 0 then return end

	local now = os.clock()
	local refX, refY = vp.X * 0.5, vp.Y * 0.5
	if C.UseCursor and UIS.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
		local ok, loc = pcall(function() return UIS:GetMouseLocation() end)
		if ok and loc then
			local dx, dy = 0, 0
			local okInset, inset = pcall(function() return GuiService:GetGuiInset() end)
			if okInset and inset then dx, dy = inset.X, inset.Y end
			refX, refY = clamp(loc.X - dx, 0, vp.X), clamp(loc.Y - dy, 0, vp.Y)
		end
	end

	-- A respawn replaces the local character: everything held against the old one
	-- refers to a body that no longer exists.
	if lp.Character ~= S.lastChar then
		S.lastChar = lp.Character
		S.target = nil
		resetAim()
	end

	if not triggering() then
		if S.target ~= nil then
			S.target = nil
			S.switches = S.switches + 1
		end
		resetAim()
		paint(cam, vp, refX, refY, nil, now, cam.CFrame)
		if C.ESP then
			drawESP(cam, vp, nil, espCandidates(cam, now, ESP_CANDS), cam.CFrame)
		end
		if C.Enabled then
			publishStatus("armed · " .. tostring(C.DriveMode))
		else
			publishStatus("disabled")
		end
		return
	end

	local target = acquire(cam, vp, refX, refY, now)

	-- The held lock is a FALLBACK, not an override: it only applies when
	-- acquisition came back empty, so PickClosest and Sticky stay live.
	if S.lockModel then
		local heldHum = S.lockModel:FindFirstChildOfClass("Humanoid")
		-- A rig with no Humanoid is a character here, so an absent Humanoid is
		-- not a death -- only one that exists and reports no health is.
		local heldDead = heldHum ~= nil and heldHum.Health <= 0
		if not S.lockModel.Parent or heldDead
			or gameDead(S.lockPlayer)
			or isFrozen(S.lockModel, now) then
			S.lockModel, S.lockPlayer = nil, nil
			S.target = nil
		end
	end

	local riding = false
	if target == nil and (S.lockModel or S.lockPlayer) then
		local held = targetFor(S.lockModel, S.lockPlayer, cam)
		if held then
			target = held
			S.lockMiss = 0
		else
			S.lockMiss = (S.lockMiss or 0) + 1
			if S.lockMiss > C.LockGraceFrames then
				S.lockModel, S.lockPlayer = nil, nil
				S.target = nil
			else
				target = S.target        -- ride out brief occlusion
				riding = true
			end
		end
	end
	-- Only a freshly resolved lock resets the miss counter: counting a ride-out
	-- as fresh zeroed it one frame after incrementing, so it never expired.
	if target and not riding then
		S.lockModel, S.lockPlayer = target.model, target.player
		S.lockMiss = 0
	end

	local previous = S.target
	local switched = previous ~= nil and (target == nil or target.model ~= previous.model)
	if switched then S.switches = S.switches + 1 end
	-- The held rotation is NOT target-specific: the residual is recomputed from
	-- the rendered orientation every frame. Discarding it on a switch threw the
	-- view back to the game's own orientation -- the teleport on every switch.
	S.missed = target == nil and ((S.missed or 0) + 1) or 0
	S.target = target

	-- How fast the aim point is crossing the view, in deg/s: the measured signal
	-- adaptive speed rides on. Smoothed, and a >12 deg jump is a teleport.
	if target then
		local dir = target.point - cam.CFrame.Position
		if dir.Magnitude > 1e-3 then
			dir = dir.Unit
			local prev = S.aimDir
			if prev and not switched then
				local jumped = math.deg(math.acos(clamp(dir:Dot(prev), -1, 1)))
				if jumped < 12 then
					local inst = jumped / math.max(dt, 1e-3)
					S.aimRate = (S.aimRate or 0) * 0.75 + inst * 0.25
				end
			else
				S.aimRate = 0
			end
			S.aimDir = dir
		end
	else
		S.aimRate = 0
		S.aimDir = nil
	end

	if target then
		S.leadStuds = target.lead or 0
		S.velStuds = target.speed or 0
		S.selfVelStuds = (selfVel and selfVel.Magnitude) or 0
		local point = humanise(cam, target.point, S.angle, dt, target.speed)
		point = gunAimPoint(cam.CFrame, point)
		local angle
		local transport = activeTransport()

		-- The two transports differ by ~3.1x in degrees per unit, so a change
		-- discards the calibration rather than trusting a stale gain.
		if transport ~= S.transport then
			S.transport = transport
			S.cal = nil
			S.axisYaw, S.axisPitch = nil, nil
			S.inputFailed = nil
			S.sentX, S.sentY = nil, nil
		end

		if C.SimulateInput then
			-- A camera script that provably ignores input (the calibration
			-- measured zero rotation for a 40-unit pulse) falls back to the
			-- camera write rather than doing nothing.
			if transport ~= "none" and not S.inputFailed then
				angle = solveInput(cam, point, dt)
			else
				angle = solveCamera(cam, point, dt)
			end
		elseif C.DriveMode == "mouse" then
			angle = solveMouse(cam, point, dt)
		else
			angle = solveCamera(cam, point, dt)
		end
		S.angle = angle

		-- Autofire, after the solver has written this frame's orientation, and
		-- gated on the residual so a shot is never thrown while the camera is
		-- still travelling.
		if C.AutoFire and angle <= (C.AutoFireArcDeg or 3.0) then
			if now >= (S.nextShot or 0) then
				S.nextShot = now + (C.AutoFireRateMs or 90) / 1000
				S.shots = (S.shots or 0) + 1
				local click = mouse1click
				if type(click) == "function" then
					pcall(click)
				end
			end
		end

		local note = ""
		if not C.SimulateInput and C.DriveMode == "camera" and not S.ownsCamera then
			note = " · game cam"
		end
		if S.transport == "aegis" then
			note = note .. " · sim"
		end
		local leadNote = ""
		if (S.leadStuds or 0) >= 0.05 then
			leadNote = string.format(" · +%.1f", S.leadStuds)
		end
		publishStatus(string.format("%s · %.1f° · %.0fm%s%s",
			target.label, angle, target.dist, leadNote, note))
	else
		S.angle = 0
		-- Clear the rate limit so the next acquisition fires on the frame the
		-- crosshair arrives.
		S.nextShot = 0
		publishStatus("searching · " .. tostring(C.DriveMode))
	end

	-- Read the camera only now: the solver may have written it, and what it wrote
	-- is what this frame renders. One pose shared by both passes.
	local drawCF = cam.CFrame
	paint(cam, vp, refX, refY, target, now, drawCF)
	drawESP(cam, vp, target, espCandidates(cam, now, ESP_CANDS), drawCF)
end

A.step = step

local function startSolver()
	local priority = Enum.RenderPriority.Camera.Value + 1
	local ok, err = pcall(function()
		RunService:UnbindFromRenderStep(SOLVER_ID)
		RunService:BindToRenderStep(SOLVER_ID, priority, function(dt)
			if S.unloaded or S.broken then return end
			local okStep, stepErr = pcall(step, clamp(dt, 0.001, 0.05))
			if okStep then
				S.errors = 0
			else
				S.errors = S.errors + 1
				if S.errors >= 30 then
					S.broken = true
					A.setStatus("solver error: " .. tostring(stepErr))
					pcall(function() RunService:UnbindFromRenderStep(SOLVER_ID) end)
				end
			end
		end)
	end)
	if not ok then
		A.setStatus("bind failed: " .. tostring(err))
		return false
	end
	return true
end

--------------------------------------------------------------------
-- 11. Auto-win
--
-- Two damage paths, both measured on a live client rather than inferred:
--   melee  ReportHit{kind="melee", backstab=true} -> 250 damage; accepted at 9
--          and 11 studs, REFUSED at 38, so the server owns a melee radius.
--   throw  ThrowReplicate, then ReportHit{kind="throw"} -> 100 damage at 156
--          studs THROUGH geometry. The throw alone deals nothing: it announces
--          the knife, and the hit report is what the server bills.
--
-- Nothing here touches movement. An earlier build slid the character with a
-- BodyVelocity at 304 studs/s; it worked, but the kill does not need it and a
-- body mover left attached after unload is a real hazard.
--------------------------------------------------------------------

A.aw = {
	enabled       = false,
	meleeRange    = 11,
	throwRange    = 200,
	meleeInterval = 0.35,
	throwInterval = 0.45,
	equipInterval = 1.6,
	confirmWindow = 2.0,
	lastMelee     = 0,
	lastThrow     = 0,
	lastEquip     = 0,
	throwId       = 1000,
	pending       = {},
	note          = "off",
	targetName    = "-",
	targetDist    = 0,
	counters      = {
		throws = 0, throwHits = 0,
		melees = 0, meleeHits = 0,
		killsSeen = 0, errors = 0,
	},
}

local AW = A.aw

AW.remotes = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
AW.throwRemote = AW.remotes and AW.remotes:FindFirstChild("ThrowReplicate")
AW.hitRemote = AW.remotes and AW.remotes:FindFirstChild("ReportHit")

-- A player on the other side. Teams exist here, but a lobby with no team
-- assigned must not read as "everyone is a teammate".
function AW.hostile(p)
	if p == lp then return false end
	if lp.Team and p.Team then
		return p.Team ~= lp.Team
	end
	return true
end

function AW.char()
	local ch = lp.Character
	if not ch then return nil end
	local hum = ch:FindFirstChildOfClass("Humanoid")
	local root = ch:FindFirstChild("HumanoidRootPart")
	if not hum or not root then return nil end
	return ch, hum, root
end

-- Nearest live hostile, rebuilt every frame: a cached target that has died or
-- swapped teams is a silent stall.
function AW.enemy(root)
	local best, bestD = nil, math.huge
	for _, p in ipairs(Players:GetPlayers()) do
		if AW.hostile(p) and p.Character then
			local ch = p.Character
			local hum = ch:FindFirstChildOfClass("Humanoid")
			local er = ch:FindFirstChild("HumanoidRootPart")
			if hum and er and hum.Health > 0 then
				local d = (er.Position - root.Position).Magnitude
				if d < bestD then
					bestD = d
					best = {
						player = p,
						char   = ch,
						hum    = hum,
						root   = er,
						part   = ch:FindFirstChild("Head") or er,
					}
				end
			end
		end
	end
	return best, bestD
end

-- Keep a knife in hand: the throw is only plausible from a held tool, and
-- re-equipping every frame would fight the engine's own equip cycle.
function AW.equip(hum, ch)
	if os.clock() - AW.lastEquip < AW.equipInterval then return end
	AW.lastEquip = os.clock()
	for _, v in ipairs(ch:GetChildren()) do
		if v:IsA("Tool") and string.find(v.Name, "Knife") then
			return
		end
	end
	local bp = lp:FindFirstChildOfClass("Backpack")
	if not bp then return end
	for _, v in ipairs(bp:GetChildren()) do
		if v:IsA("Tool") and string.find(v.Name, "Knife") then
			pcall(function() hum:EquipTool(v) end)
			return
		end
	end
end

-- Attribute a health drop to the action that caused it. Without this the
-- counters measure "reports sent", which is the lying counter that reads
-- success while nothing lands.
function AW.noteHit(model, hp, kind)
	AW.pending[#AW.pending + 1] = { model = model, hp = hp, kind = kind, t = os.clock() }
	if #AW.pending > 32 then
		table.remove(AW.pending, 1)
	end
end

function AW.reap()
	for i = #AW.pending, 1, -1 do
		local e = AW.pending[i]
		local hum = e.model and e.model.Parent and e.model:FindFirstChildOfClass("Humanoid")
		if hum and hum.Health < e.hp - 0.5 then
			if e.kind == "throw" then
				AW.counters.throwHits = AW.counters.throwHits + 1
			else
				AW.counters.meleeHits = AW.counters.meleeHits + 1
			end
			if hum.Health <= 0 then
				AW.counters.killsSeen = AW.counters.killsSeen + 1
			end
			table.remove(AW.pending, i)
		elseif (not hum) or (os.clock() - e.t > AW.confirmWindow) then
			table.remove(AW.pending, i)
		end
	end
end

function AW.melee(target, root)
	if not AW.hitRemote or not target.hum or target.hum.Health <= 0 then
		return false
	end
	local hp = target.hum.Health
	local dir = root.CFrame.LookVector
	local ok = pcall(function()
		AW.hitRemote:FireServer({
			kind         = "melee",
			targetUserId = target.player.UserId,
			targetModel  = target.char,
			direction    = dir,
			at           = Workspace:GetServerTimeNow(),
			backstab     = true,
		})
	end)
	if ok then
		AW.counters.melees = AW.counters.melees + 1
		AW.lastMelee = os.clock()
		AW.noteHit(target.char, hp, "melee")
	else
		AW.counters.errors = AW.counters.errors + 1
	end
	return ok
end

-- The wallbang half: `target` is where the knife travels to, so the throw is
-- announced along the vector to the enemy's head and the hit is reported
-- against that enemy regardless of what stands between us.
function AW.throw(target, root)
	-- Same lazy resolve as the aimed throw: these remotes are looked up once at
	-- load, so a client that had not replicated them yet would never throw.
	AW.resolveRemotes()
	if not AW.hitRemote or not target.part or not target.part.Parent then
		return false
	end
	local origin = root.Position + Vector3.new(0, 2, 0)
	local hitPos = target.part.Position
	local delta  = hitPos - origin
	if delta.Magnitude < 0.5 then return false end
	local dir = delta.Unit

	local id = AW.throwId
	AW.throwId = AW.throwId + 1

	if AW.throwRemote then
		pcall(function()
			AW.throwRemote:FireServer({
				origin      = origin,
				target      = origin + dir * 1000,
				id          = id,
				ownerUserId = lp.UserId,
				toolName    = "Knife",
				power       = 1,
				effects     = {},
			})
		end)
	end

	local hp = target.hum and target.hum.Health or 0
	local ok = pcall(function()
		AW.hitRemote:FireServer({
			kind         = "throw",
			throwId      = id,
			ownerUserId  = lp.UserId,
			targetUserId = target.player.UserId,
			targetModel  = target.char,
			at           = Workspace:GetServerTimeNow(),
			origin       = origin,
			to           = target.root.Position,
			vel          = dir * 420,
			hitPart      = target.part,
			hitPos       = hitPos,
			headshot     = target.part.Name == "Head",
		})
	end)
	if ok then
		AW.counters.throws = AW.counters.throws + 1
		AW.lastThrow = os.clock()
		AW.noteHit(target.char, hp, "throw")
	else
		AW.counters.errors = AW.counters.errors + 1
	end
	return ok
end

function AW.tick()
	AW.reap()
	if not AW.enabled then return end
	local ch, hum, root = AW.char()
	if not ch or not hum or hum.Health <= 0 then
		AW.note = "dead / respawning"
		AW.targetName = "-"
		return
	end
	local target, dist = AW.enemy(root)
	if not target then
		AW.note = "no target"
		AW.targetName = "-"
		AW.targetDist = 0
		return
	end

	AW.targetName = target.player.Name
	AW.targetDist = dist
	AW.equip(hum, ch)

	if dist <= AW.meleeRange then
		if os.clock() - AW.lastMelee >= AW.meleeInterval then
			AW.melee(target, root)
		end
	elseif dist <= AW.throwRange then
		if os.clock() - AW.lastThrow >= AW.throwInterval then
			AW.throw(target, root)
		end
	end

	local hp = 0
	if target.hum then hp = math.floor(target.hum.Health) end
	AW.note = string.format("%s %dst hp%d", target.player.Name, math.floor(dist), hp)
end

function AW.set(enabled)
	AW.enabled = enabled and true or false
	if A.push then A.push("Autowin", AW.enabled) end
	return AW.enabled
end

function AW.toggle()
	return AW.set(not AW.enabled)
end

-- pcall'd because a single bad frame must not disconnect the heartbeat and
-- leave the switch reading ON while nothing runs.
on(RunService.Heartbeat, function()
	if not pcall(AW.tick) then
		AW.counters.errors = AW.counters.errors + 1
	end
end)

genv.AegisAutoWin = AW

--------------------------------------------------------------------
-- 12. No-reload + wallbang
--
-- Murder Duels gates every shot behind canShoot() = v5 and os.clock() >= n1 and
-- not v7; n1 is written by startCooldown(SHOT_COOLDOWN), measured 1.332 s. The
-- game's own rapid-reload path replaces n1: RapidReload runs playRapidReload ->
-- stopReloadSequenceInstant, ending with v7 = false and n1 = os.clock() + 0.2.
-- That is the lever here. The Reloading attribute is written by startCooldown
-- and never read by the client, so it doubles as a per-shot signal; it is
-- cleared after each pulse or the second SetAttribute(true) is not a change.
--------------------------------------------------------------------

A.noReload = {
	bound = {},
	conns = {},
	pulses = 0,
	clears = 0,
	skipped = 0,
	errors = 0,
	landed = 0,
	lastDelta = 0,
	busy = false,
	lastPulse = 0,
	pulseClearDelay = 0.04,
	markerClearDelay = 0.06,
	minInterval = 0.10,
}

local NR = A.noReload

local function noReloadPulse(tool)
	if not C.NoReload or NR.busy then return false end
	if not tool or not tool.Parent then return false end
	local now = os.clock()
	local gap = (tonumber(C.NoReloadPulseGapMs) or 200) / 1000
	if now - NR.lastPulse < gap then
		NR.skipped = NR.skipped + 1
		return false
	end
	NR.busy = true
	NR.lastPulse = now
	local ok = pcall(function() tool:SetAttribute("RapidReload", true) end)
	if not ok then
		NR.errors = NR.errors + 1
		NR.busy = false
		return false
	end
	NR.pulses = NR.pulses + 1

	-- Did that shot actually cost the target health? The damage number over an
	-- enemy is a client prediction; health is server-replicated, so a drop is.
	-- This pair of counters is what NoReloadPulseGapMs is tuned against.
	local tgt = S.target
	local tmodel = tgt and tgt.model
	local thum = tmodel and tmodel:FindFirstChildOfClass("Humanoid")
	if thum then
		local before = thum.Health
		task.delay(0.6, function()
			pcall(function()
				if thum.Parent then
					local delta = before - thum.Health
					NR.lastDelta = delta
					if delta > 0 then NR.landed = NR.landed + 1 end
				end
			end)
		end)
	end

	task.delay(NR.pulseClearDelay, function()
		pcall(function()
			if tool.Parent then tool:SetAttribute("RapidReload", nil) end
		end)
		NR.busy = false
	end)
	task.delay(NR.markerClearDelay, function()
		pcall(function()
			if tool.Parent and tool:GetAttribute("Reloading") == true then
				tool:SetAttribute("Reloading", nil)
				NR.clears = NR.clears + 1
			end
		end)
	end)
	return true
end

local function noReloadBind(tool)
	if not tool or NR.bound[tool] then return end
	if not tool:FindFirstChild("RevolverClient") then return end
	NR.bound[tool] = tool:GetAttributeChangedSignal("Reloading"):Connect(function()
		if not C.NoReload then return end
		if tool:GetAttribute("Reloading") ~= true then return end
		task.spawn(noReloadPulse, tool)
	end)
end

local function noReloadTrack(conn)
	NR.conns[#NR.conns + 1] = conn
	return conn
end

local function noReloadScan()
	local containers = {}
	local ch = lp.Character
	if ch then containers[#containers + 1] = ch end
	local bp = lp:FindFirstChildOfClass("Backpack")
	if bp then containers[#containers + 1] = bp end
	for i = 1, #containers do
		for _, item in ipairs(containers[i]:GetChildren()) do
			if item:IsA("Tool") then noReloadBind(item) end
		end
	end
end

local function noReloadWatchCharacter(ch)
	if not ch then return end
	for _, item in ipairs(ch:GetChildren()) do
		if item:IsA("Tool") then noReloadBind(item) end
	end
	noReloadTrack(ch.ChildAdded:Connect(function(c)
		if c:IsA("Tool") then noReloadBind(c) end
	end))
end

pcall(function()
	noReloadWatchCharacter(lp.Character)
	noReloadScan()
	noReloadTrack(lp.CharacterAdded:Connect(function(ch)
		task.wait(0.5)
		noReloadWatchCharacter(ch)
		noReloadScan()
	end))
	noReloadTrack(lp.ChildAdded:Connect(function(c)
		if c:IsA("Backpack") then noReloadScan() end
	end))
end)

-- The client's own hit cast excludes only dead bodies and same-side bots, so a
-- wall stops it: no hit is ever sent. ShootReplicate does not care where the
-- payload came from. Measured on place 120851538706364: a target 132 studs away
-- with a confirmed wall between, 100 hp -> 0 in one call.
A.wallbang = {
	shots = 0,
	accepted = 0,
	skipped = 0,
	errors = 0,
	lastDelta = 0,
	lastAt = 0,
	id = 0,
}

local WB = A.wallbang

function WB.fire(model)
	if not C.WallBang then return false end
	local remotes = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
	local remote = remotes and remotes:FindFirstChild("ShootReplicate")
	if not remote then return false end
	local now = os.clock()
	local gap = (tonumber(C.WallBangGapMs) or 250) / 1000
	if now - WB.lastAt < gap then
		WB.skipped = WB.skipped + 1
		return false
	end
	local tgt = S.target
	local target = model or (tgt and tgt.model)
	local head = target and target:FindFirstChild("Head")
	local hum = target and target:FindFirstChildOfClass("Humanoid")
	if not head or not hum or hum.Health <= 0 then return false end
	WB.lastAt = now
	WB.id = WB.id + 1
	local cam = Workspace.CurrentCamera
	if not cam then return false end
	local payload = {
		kind = "bullet",
		mode = nil,
		id = WB.id,
		reloadSoundDelay = 0,
		segments = {},
		origin = cam.CFrame.Position,
		firedAt = Workspace:GetServerTimeNow(),
		to = head.Position,
		hitInstance = head,
		hitPos = head.Position,
		hitNormal = Vector3.new(0, 1, 0),
		isCharacterHit = true,
		ownerUserId = lp.UserId,
		effects = {},
		chainHits = {
			{ hitPart = head, damage = tonumber(C.WallBangDamage) or 75, headshot = true },
		},
		isADS = false,
		bulletFx = nil,
	}
	local ok = pcall(function() remote:FireServer(payload) end)
	if not ok then
		WB.errors = WB.errors + 1
		return false
	end
	WB.shots = WB.shots + 1
	local before = hum.Health
	task.delay(0.6, function()
		pcall(function()
			if hum.Parent then
				local delta = before - hum.Health
				WB.lastDelta = delta
				if delta > 0 then WB.accepted = WB.accepted + 1 end
			end
		end)
	end)
	return true
end

--------------------------------------------------------------------
-- 13. AegisUI panel
--
-- Fetched over http, exactly as Scripts\SellOres\AegisSellOres.lua does: the
-- published copy is what scripts execute, and loading it publishes
-- getgenv().AegisUI for later chunks.
--------------------------------------------------------------------

local okFetch, fetched = pcall(function()
	return loadstring(game:HttpGet(LIB_URL))()
end)
if not (okFetch and type(fetched) == "table") then
	genv.AegisAim = {
		version = VERSION,
		state = S,
		config = C,
		error = tostring(fetched),
		api = { unload = function() end },
	}
	return "aim-ui: AegisUI fetch failed: " .. tostring(fetched)
end

local lib = fetched
A.lib = lib

local major = tonumber(tostring(lib.Version or "0"):match("^(%d+)")) or 0

local window = lib:MakeWindow{
	Name = "Aegis Aim",
	Subtitle = "v" .. VERSION .. " · Murder Duels",
	Width = 560,
	Height = 420,
	ConfigFolder = "AegisAim",
	OnUnload = function()
		pcall(function() lib:SaveConfig("default") end)
		A.unload("panel")
	end,
}
A.win = window

if major < 2 and type(window.Notify) == "function" then
	-- The URL serves whatever was pushed last. 1.x runs the same controls and
	-- just ignores the newer options, so this warns rather than failing closed.
	window:Notify({
		Title = "AegisUI " .. tostring(lib.Version),
		Text = "This panel is written for 2.x; some controls may look different.",
		Type = "warn",
		Duration = 6,
	})
end

local labels = {}
A.labels = labels
local elements = {}
A.el = elements
-- Auto-win's tunables are their own state (AW), not CONFIG keys, so their
-- elements are tracked separately and pushed on restore rather than bound.
A.awEl = {}
local order = {}          -- flags in creation order: snapshot, restore, save
A.flagList = order

local function push(flag, value)
	local el = elements[flag]
	if el and type(el.Set) == "function" then
		pcall(function() el:Set(value, true) end)
	end
end
A.push = push

-- Every control that owns a CONFIG key reports back here, so the table stays
-- the single source of truth and api.get reads what the panel shows.
local function bind(el, flag)
	elements[flag] = el
	order[#order + 1] = flag
	return el
end

local tabAim     = window:MakeTab("Aim")
local tabTarget  = window:MakeTab("Target")
local tabPredict = window:MakeTab("Predict")
local tabVisual  = window:MakeTab("Visuals")
local tabCombat  = window:MakeTab("Combat")
local tabWin     = window:MakeTab("Auto-win")
local tabAdvanced = window:MakeTab("Advanced")
local tabStatus  = window:MakeTab("Status")
local tabConfig  = window:MakeTab("Config")
local tabStreak  = window:MakeTab("Winstreak")

do
	local sec = tabAim:MakeSection("Run")
	bind(sec:MakeToggle({
		Text = "Aim enabled",
		Description = "Arms the solver. Activation decides what actually triggers a pull.",
		Flag = "Enabled",
		Default = C.Enabled,
		Callback = function(v) C.Enabled = v and true or false end,
	}), "Enabled")
	-- Shown in plain English rather than as the internal value: "always on" IS
	-- the auto-trigger, and the other two name the key they need. The mapping
	-- accepts the raw values too, so a saved config or api.set("Activation",
	-- "always") still lands.
	local triggerLabel = { hold = "hold key", toggle = "toggle key", always = "always on" }
	local triggerValue = { ["hold key"] = "hold", ["toggle key"] = "toggle", ["always on"] = "always" }
	A.triggerLabel = triggerLabel
	-- applyFlag() runs after every config load and on every sampled change, so it
	-- needs the inverse map too. Without it the display label ("hold key") was
	-- stored as the activation value and never matched a branch in triggering().
	A.triggerValue = triggerValue
	bind(sec:MakeDropdown({
		Text = "Trigger",
		Description = "hold key / toggle key wait for a press; always on is the auto-trigger.",
		Flag = "Activation",
		Options = { "hold key", "toggle key", "always on" },
		Default = triggerLabel[C.Activation] or "hold key",
		Callback = function(v) C.Activation = triggerValue[v] or v end,
	}), "Activation")
	bind(sec:MakeKeybind({
		Text = "Hold key",
		Flag = "HoldKey",
		Default = C.HoldKey,
		Changed = function(name)
			C.HoldKey = name or C.HoldKey
			S.keyGuard = os.clock() + 0.5
		end,
	}), "HoldKey")
	bind(sec:MakeKeybind({
		Text = "Toggle key",
		Flag = "ToggleKey",
		Default = C.ToggleKey,
		Changed = function(name)
			C.ToggleKey = name or C.ToggleKey
			S.keyGuard = os.clock() + 0.5
		end,
	}), "ToggleKey")
	bind(sec:MakeDropdown({
		Text = "Driver",
		Description = "camera writes the transform; mouse converts the error into pixels",
		Flag = "DriveMode",
		Options = { "camera", "mouse" },
		Default = C.DriveMode,
		Callback = function(v) C.DriveMode = v end,
	}), "DriveMode")
	bind(sec:MakeToggle({
		Text = "Simulate real input",
		Description = "Drive through the injector's mouse primitive instead of the camera transform.",
		Flag = "SimulateInput",
		Default = C.SimulateInput,
		Callback = function(v) C.SimulateInput = v and true or false end,
	}), "SimulateInput")
	bind(sec:MakeToggle({
		Text = "Require left click",
		Flag = "RequireClick",
		Default = C.RequireClick,
		Callback = function(v) C.RequireClick = v and true or false end,
	}), "RequireClick")

	local solve = tabAim:MakeSection("Solver")
	bind(solve:MakeSlider({
		Text = "Smoothing", Flag = "Smoothing",
		Min = 0, Max = 100, Step = 5, Default = C.Smoothing,
		Callback = function(v) C.Smoothing = v end,
	}), "Smoothing")
	bind(solve:MakeSlider({
		Text = "Strength", Flag = "Strength", Suffix = " %",
		Min = 10, Max = 300, Step = 10, Default = C.Strength,
		Callback = function(v) C.Strength = v end,
	}), "Strength")
	bind(solve:MakeSlider({
		Text = "Max turn", Flag = "MaxSpeed", Suffix = " °/s",
		Min = 60, Max = 2000, Step = 60, Default = C.MaxSpeed,
		Callback = function(v) C.MaxSpeed = v end,
	}), "MaxSpeed")
	bind(solve:MakeSlider({
		Text = "Deadzone", Flag = "DeadzoneX100", Suffix = " °/100",
		Min = 0, Max = 200, Step = 5, Default = C.DeadzoneX100,
		Callback = function(v) C.DeadzoneX100 = v end,
	}), "DeadzoneX100")
	bind(solve:MakeSlider({
		Text = "Humanise", Flag = "HumanTenths", Suffix = " x0.1°",
		Min = 0, Max = 30, Step = 1, Default = C.HumanTenths,
		Callback = function(v) C.HumanTenths = v end,
	}), "HumanTenths")
	bind(solve:MakeSlider({
		Text = "Mouse sens", Flag = "SensX10", Suffix = " x0.1 px/°",
		Min = 5, Max = 120, Step = 5, Default = C.SensX10,
		Callback = function(v) C.SensX10 = v end,
	}), "SensX10")
	bind(solve:MakeToggle({
		Text = "Adaptive speed",
		Description = "Shorten tau until the settled lag fits Max lag.",
		Flag = "AdaptiveSpeed",
		Default = C.AdaptiveSpeed,
		Callback = function(v) C.AdaptiveSpeed = v and true or false end,
	}), "AdaptiveSpeed")
	bind(solve:MakeSlider({
		Text = "Max lag", Flag = "MaxLagX10", Suffix = " x0.1°",
		Min = 1, Max = 30, Step = 1, Default = C.MaxLagX10,
		Callback = function(v) C.MaxLagX10 = v end,
	}), "MaxLagX10")
end

do
	local sec = tabTarget:MakeSection("Acquire")
	bind(sec:MakeSlider({
		Text = "FOV ring", Flag = "FOV", Suffix = " px",
		Min = 30, Max = 600, Step = 10, Default = C.FOV,
		Callback = function(v) C.FOV = v end,
	}), "FOV")
	bind(sec:MakeSlider({
		Text = "Range", Flag = "Range", Suffix = " studs",
		Min = 0, Max = 2000, Step = 100, Default = C.Range,
		Callback = function(v) C.Range = v end,
	}), "Range")
	bind(sec:MakeDropdown({
		Text = "Aim part", Flag = "Part",
		Options = { "Head", "Torso", "Root" },
		Default = C.Part,
		Callback = function(v) C.Part = v end,
	}), "Part")
	bind(sec:MakeDropdown({
		Text = "NPC aim part", Flag = "PartNPC",
		Options = { "Head", "Torso", "Root" },
		Default = C.PartNPC,
		Callback = function(v) C.PartNPC = v end,
	}), "PartNPC")
	bind(sec:MakeSlider({
		Text = "Hitbox pad", Flag = "PadPct", Suffix = " %",
		Min = 0, Max = 60, Step = 5, Default = C.PadPct,
		Callback = function(v) C.PadPct = v end,
	}), "PadPct")
	bind(sec:MakeSlider({
		Text = "Lock angle", Flag = "MaxLockDeg", Suffix = " °",
		Min = 1, Max = 179, Step = 1, Default = C.MaxLockDeg,
		Callback = function(v) C.MaxLockDeg = v end,
	}), "MaxLockDeg")
	bind(sec:MakeSlider({
		Text = "Lock grace", Flag = "LockGraceFrames", Suffix = " frames",
		Min = 0, Max = 240, Step = 1, Default = C.LockGraceFrames,
		Callback = function(v) C.LockGraceFrames = v end,
	}), "LockGraceFrames")
	bind(sec:MakeSlider({
		Text = "Mark radius", Flag = "MarkRadiusPx", Suffix = " px",
		Min = 10, Max = 300, Step = 10, Default = C.MarkRadiusPx,
		Callback = function(v) C.MarkRadiusPx = v end,
	}), "MarkRadiusPx")

	local gates = tabTarget:MakeSection("Gates")
	bind(gates:MakeToggle({
		Text = "Team check", Flag = "TeamCheck", Default = C.TeamCheck,
		Callback = function(v) C.TeamCheck = v and true or false end,
	}), "TeamCheck")
	bind(gates:MakeToggle({
		Text = "Wall check", Flag = "WallCheck", Default = C.WallCheck,
		Callback = function(v) C.WallCheck = v and true or false end,
	}), "WallCheck")
	bind(gates:MakeToggle({
		Text = "Ignore friends", Flag = "IgnoreFriends", Default = C.IgnoreFriends,
		Callback = function(v) C.IgnoreFriends = v and true or false end,
	}), "IgnoreFriends")
	bind(gates:MakeToggle({
		Text = "NPC check", Flag = "NPCCheck", Default = C.NPCCheck,
		Callback = function(v)
			C.NPCCheck = v and true or false
			if C.NPCCheck then npcScanned = false end
		end,
	}), "NPCCheck")
	bind(gates:MakeToggle({
		Text = "Require head", Flag = "RequireHead", Default = C.RequireHead,
		Callback = function(v) C.RequireHead = v and true or false end,
	}), "RequireHead")
	bind(gates:MakeToggle({
		Text = "Active rigs only", Flag = "IgnoreAnchored", Default = C.IgnoreAnchored,
		Callback = function(v) C.IgnoreAnchored = v and true or false end,
	}), "IgnoreAnchored")
	bind(gates:MakeToggle({
		Text = "Skip frozen bodies", Flag = "IgnoreFrozen", Default = C.IgnoreFrozen,
		Callback = function(v) C.IgnoreFrozen = v and true or false end,
	}), "IgnoreFrozen")
	bind(gates:MakeToggle({
		Text = "Box whole body", Flag = "BoxBody", Default = C.BoxBody,
		Callback = function(v) C.BoxBody = v and true or false end,
	}), "BoxBody")
	bind(gates:MakeToggle({
		Text = "Pick closest", Flag = "PickClosest", Default = C.PickClosest,
		Callback = function(v) C.PickClosest = v and true or false end,
	}), "PickClosest")
end

do
	local sec = tabPredict:MakeSection("Lead")
	bind(sec:MakeSlider({
		Text = "Fixed lead", Flag = "PredictionMs", Suffix = " ms",
		Min = 0, Max = 400, Step = 10, Default = C.PredictionMs,
		Callback = function(v) C.PredictionMs = v end,
	}), "PredictionMs")
	bind(sec:MakeToggle({
		Text = "Lead by ping", Flag = "LeadByPing", Default = C.LeadByPing,
		Callback = function(v) C.LeadByPing = v and true or false end,
	}), "LeadByPing")
	bind(sec:MakeSlider({
		Text = "Projectile speed", Flag = "ProjectileSpeed", Suffix = " studs/s",
		Min = 0, Max = 2000, Step = 50, Default = C.ProjectileSpeed,
		Callback = function(v) C.ProjectileSpeed = v end,
	}), "ProjectileSpeed")
	bind(sec:MakeSlider({
		Text = "Lead cap", Flag = "MaxLeadStuds", Suffix = " studs",
		Min = 0, Max = 200, Step = 10, Default = C.MaxLeadStuds,
		Callback = function(v) C.MaxLeadStuds = v end,
	}), "MaxLeadStuds")
	bind(sec:MakeToggle({
		Text = "Lead the loop's own lag",
		Description = "A first-order loop settles rate x tau behind a mover; this aims one tau ahead.",
		Flag = "LeadLoop", Default = C.LeadLoop,
		Callback = function(v) C.LeadLoop = v and true or false end,
	}), "LeadLoop")
	bind(sec:MakeToggle({
		Text = "Lead own movement", Flag = "LeadSelf", Default = C.LeadSelf,
		Callback = function(v) C.LeadSelf = v and true or false end,
	}), "LeadSelf")
	bind(sec:MakeToggle({
		Text = "Gun aim", Flag = "GunAim", Default = C.GunAim,
		Callback = function(v) C.GunAim = v and true or false end,
	}), "GunAim")
	bind(sec:MakeToggle({
		Text = "Cursor aim", Flag = "UseCursor", Default = C.UseCursor,
		Callback = function(v) C.UseCursor = v and true or false end,
	}), "UseCursor")
end

do
	local sec = tabVisual:MakeSection("Overlay")
	bind(sec:MakeToggle({
		Text = "FOV ring", Flag = "ShowFov", Default = C.ShowFov,
		Callback = function(v) C.ShowFov = v and true or false end,
	}), "ShowFov")
	bind(sec:MakeToggle({
		Text = "Target box", Flag = "ShowTarget", Default = C.ShowTarget,
		Callback = function(v) C.ShowTarget = v and true or false end,
	}), "ShowTarget")
	bind(sec:MakeToggle({
		Text = "ESP", Flag = "ESP", Default = C.ESP,
		Callback = function(v) C.ESP = v and true or false end,
	}), "ESP")
	bind(sec:MakeToggle({
		Text = "Snaplines", Flag = "ESPLine", Default = C.ESPLine,
		Callback = function(v) C.ESPLine = v and true or false end,
	}), "ESPLine")
	bind(sec:MakeSlider({
		Text = "ESP slots", Flag = "ESPMax",
		Min = 1, Max = 40, Step = 1, Default = C.ESPMax,
		Callback = function(v) C.ESPMax = v end,
	}), "ESPMax")
	bind(sec:MakeSlider({
		Text = "Line width", Flag = "ESPLinePx", Suffix = " px @100",
		Min = 1, Max = 6, Step = 1, Default = C.ESPLinePx,
		Callback = function(v) C.ESPLinePx = v end,
	}), "ESPLinePx")
	bind(sec:MakeColorPicker({
		Text = "ESP colour", Flag = "ESPColor", Default = C.ESPColor,
		Callback = function(colour) C.ESPColor = colour end,
	}), "ESPColor")
	bind(sec:MakeColorPicker({
		Text = "Target colour", Flag = "ESPTargetColor", Default = C.ESPTargetColor,
		Callback = function(colour) C.ESPTargetColor = colour end,
	}), "ESPTargetColor")
end

do
	local sec = tabCombat:MakeSection("Fire")
	bind(sec:MakeToggle({
		Text = "Autofire",
		Description = "Clicks synthetic left mouse once the aim error is inside the arc.",
		Flag = "AutoFire", Default = C.AutoFire,
		Callback = function(v) C.AutoFire = v and true or false end,
	}), "AutoFire")
	bind(sec:MakeSlider({
		Text = "Fire rate", Flag = "AutoFireRateMs", Suffix = " ms",
		Min = 30, Max = 500, Step = 10, Default = C.AutoFireRateMs,
		Callback = function(v) C.AutoFireRateMs = v end,
	}), "AutoFireRateMs")
	bind(sec:MakeSlider({
		Text = "Fire arc", Flag = "AutoFireArcDeg", Suffix = " °",
		Min = 0.5, Max = 15, Step = 0.5, Default = C.AutoFireArcDeg,
		Callback = function(v) C.AutoFireArcDeg = v end,
	}), "AutoFireArcDeg")

	local nr = tabCombat:MakeSection("Revolver")
	bind(nr:MakeToggle({
		Text = "No-reload pulse",
		Description = "Pulses RapidReload after each shot: 1.332 s of cooldown down to 0.2 s.",
		Flag = "NoReload", Default = C.NoReload,
		Callback = function(v) C.NoReload = v and true or false end,
	}), "NoReload")
	bind(nr:MakeSlider({
		Text = "Pulse gap", Flag = "NoReloadPulseGapMs", Suffix = " ms",
		Min = 50, Max = 1000, Step = 50, Default = C.NoReloadPulseGapMs,
		Callback = function(v) C.NoReloadPulseGapMs = v end,
	}), "NoReloadPulseGapMs")
	bind(nr:MakeToggle({
		Text = "Wallbang (F6)",
		Description = "Sends the ShootReplicate payload directly, so geometry cannot block the shot.",
		Flag = "WallBang", Default = C.WallBang,
		Callback = function(v) C.WallBang = v and true or false end,
	}), "WallBang")
	bind(nr:MakeSlider({
		Text = "Wallbang gap", Flag = "WallBangGapMs", Suffix = " ms",
		Min = 50, Max = 1000, Step = 50, Default = C.WallBangGapMs,
		Callback = function(v) C.WallBangGapMs = v end,
	}), "WallBangGapMs")
	bind(nr:MakeSlider({
		Text = "Wallbang damage", Flag = "WallBangDamage",
		Min = 10, Max = 200, Step = 5, Default = C.WallBangDamage,
		Callback = function(v) C.WallBangDamage = v end,
	}), "WallBangDamage")
	nr:MakeButton({
		Text = "Fire wallbang at current target",
		Callback = function()
			local fired = WB.fire()
			if type(window.Notify) == "function" then
				window:Notify({
					Title = fired and "Wallbang sent" or "No shot",
					Text = fired and "payload dispatched" or "no target, or on cooldown",
					Type = fired and "success" or "warn",
					Duration = 3,
				})
			end
		end,
	})
end

do
	local sec = tabWin:MakeSection("Knife")
	bind(sec:MakeToggle({
		Text = "Auto-win",
		Description = "Melee inside the melee radius, thrown knife beyond it. Both report hits the server bills.",
		Flag = "Autowin", Default = false,
		Callback = function(v) AW.set(v and true or false) end,
	}), "Autowin")
	bind(sec:MakeKeybind({
		Text = "Auto-win key",
		Flag = "AutowinKey",
		Default = C.AutowinKey,
		Changed = function(name)
			C.AutowinKey = name or C.AutowinKey
			S.keyGuard = os.clock() + 0.5
		end,
	}), "AutowinKey")
	sec:MakeButton({
		Text = "Attack once",
		Style = "primary",
		Callback = function()
			local ch, hum, root = AW.char()
			if not ch or not hum or hum.Health <= 0 then return end
			local target, dist = AW.enemy(root)
			if not target then return end
			if dist <= AW.meleeRange then
				AW.melee(target, root)
			else
				AW.throw(target, root)
			end
		end,
	})

	local tune = tabWin:MakeSection("Tuning")
	A.awEl.meleeRange = tune:MakeSlider({
		Text = "Melee range", Suffix = " studs", Min = 5, Max = 30, Step = 1,
		Default = AW.meleeRange,
		Callback = function(v) AW.meleeRange = v end,
	})
	A.awEl.throwRange = tune:MakeSlider({
		Text = "Throw range", Suffix = " studs", Min = 20, Max = 600, Step = 10,
		Default = AW.throwRange,
		Callback = function(v) AW.throwRange = v end,
	})
	A.awEl.meleeInterval = tune:MakeSlider({
		Text = "Melee interval", Suffix = " s", Min = 0.1, Max = 1.5, Step = 0.05,
		Default = AW.meleeInterval,
		Callback = function(v) AW.meleeInterval = v end,
	})
	A.awEl.throwInterval = tune:MakeSlider({
		Text = "Throw interval", Suffix = " s", Min = 0.1, Max = 1.5, Step = 0.05,
		Default = AW.throwInterval,
		Callback = function(v) AW.throwInterval = v end,
	})
	A.awEl.equipInterval = tune:MakeSlider({
		Text = "Equip interval", Suffix = " s", Min = 0.5, Max = 5, Step = 0.1,
		Default = AW.equipInterval,
		Callback = function(v) AW.equipInterval = v end,
	})

	local live = tabWin:MakeSection("Counters")
	labels.awNote = live:MakeLabel({ Text = "note: off" })
	labels.awStat = live:MakeLabel({ Text = "throws 0/0 · melee 0/0 · kills 0" })
	live:MakeParagraph({
		Title = "Reading the counters",
		Text = "A hit is only counted when the target's server-replicated Health drops "
			.. "after the report. Reports sent with no drop mean the server refused the "
			.. "payload, not that the script is idle.",
	})
end

do
	local sec = tabStatus:MakeSection("Live")
	labels.target = sec:MakeLabel({ Text = "target: -" })
	labels.solve = sec:MakeLabel({ Text = "solver: -" })
	labels.pred = sec:MakeLabel({ Text = "lead: -" })
	labels.counters = sec:MakeLabel({ Text = "shots 0 · switches 0" })
	labels.gates = sec:MakeLabel({ Text = "gates: -" })
	labels.note = sec:MakeLabel({ Text = "status: booting" })
	labels.overlay = sec:MakeLabel({
		Text = "overlay: " .. tostring(overlay.kind) ..
			" · drivers: " .. tostring(activeTransport()),
	})
end

-- ---------------------------------------------------------------- advanced
-- Every remaining CONFIG key gets a control here. A key with no control used to
-- have no flag, and a key with no flag never reached the saved file at all.
-- The five list-valued gates are edited as comma-separated text; each callback
-- builds a NEW table, which also invalidates isIgnored()'s identity-keyed cache.
local function splitList(text)
	local out = {}
	for piece in string.gmatch(tostring(text or ""), "[^,]+") do
		local t = string.match(piece, "^%s*(.-)%s*$")
		if t ~= "" then out[#out + 1] = string.lower(t) end
	end
	return out
end
A.splitList = splitList

A.syncAw = function()
	for name, el in pairs(A.awEl) do
		if el and type(el.Set) == "function" then
			pcall(function() el:Set(AW[name], true) end)
		end
	end
end

do
	local sec = tabAdvanced:MakeSection("Solver limits")
	bind(sec:MakeSlider({
		Text = "Max speed ceiling", Suffix = " °/s", Min = 300, Max = 4000, Step = 50,
		Flag = "MaxSpeedCeiling", Default = C.MaxSpeedCeiling,
		Callback = function(v) C.MaxSpeedCeiling = v end,
	}), "MaxSpeedCeiling")
	bind(sec:MakeSlider({
		Text = "Sticky weight", Min = 0, Max = 1, Step = 0.05,
		Flag = "Sticky", Default = C.Sticky,
		Callback = function(v) C.Sticky = v end,
	}), "Sticky")

	local frz = tabAdvanced:MakeSection("Frozen-body gate")
	bind(frz:MakeSlider({
		Text = "Still for", Suffix = " ms", Min = 500, Max = 8000, Step = 100,
		Flag = "FrozenHoldMs", Default = C.FrozenHoldMs,
		Callback = function(v) C.FrozenHoldMs = v end,
	}), "FrozenHoldMs")
	bind(frz:MakeSlider({
		Text = "Max speed", Suffix = " studs/s", Min = 1, Max = 30, Step = 1,
		Flag = "FrozenMinSpeed", Default = C.FrozenMinSpeed,
		Callback = function(v) C.FrozenMinSpeed = v end,
	}), "FrozenMinSpeed")
	bind(frz:MakeSlider({
		Text = "Motion window", Suffix = " ms", Min = 50, Max = 1000, Step = 50,
		Flag = "FrozenMotionMs", Default = C.FrozenMotionMs,
		Callback = function(v) C.FrozenMotionMs = v end,
	}), "FrozenMotionMs")
	bind(frz:MakeSlider({
		Text = "Frames", Min = 2, Max = 60, Step = 1,
		Flag = "FrozenFrames", Default = C.FrozenFrames,
		Callback = function(v) C.FrozenFrames = v end,
	}), "FrozenFrames")
	bind(frz:MakeToggle({
		Text = "Use the game's death flag",
		Description = "the player's Health/State attributes, which flip at the instant of death",
		Flag = "UseGameDeathFlag", Default = C.UseGameDeathFlag,
		Callback = function(v) C.UseGameDeathFlag = v end,
	}), "UseGameDeathFlag")

	local gates = tabAdvanced:MakeSection("Name and tag gates")
	bind(gates:MakeToggle({
		Text = "Ignore hash-like names",
		Description = "a corpse is <guid>_Died; a bare hex name is not a live entity",
		Flag = "IgnoreHashNames", Default = C.IgnoreHashNames,
		Callback = function(v) C.IgnoreHashNames = v end,
	}), "IgnoreHashNames")
	bind(gates:MakeTextBox({
		Text = "Ignore names (comma separated)", Flag = "IgnoreNames",
		Default = table.concat(C.IgnoreNames, ", "),
		Callback = function(t) C.IgnoreNames = splitList(t) end,
	}), "IgnoreNames")
	bind(gates:MakeTextBox({
		Text = "Ignore substrings (comma separated)", Flag = "IgnoreSubstrings",
		Default = table.concat(C.IgnoreSubstrings, ", "),
		Callback = function(t) C.IgnoreSubstrings = splitList(t) end,
	}), "IgnoreSubstrings")
	bind(gates:MakeTextBox({
		Text = "Live tags (comma separated)", Flag = "LiveTags",
		Default = table.concat(C.LiveTags, ", "),
		Callback = function(t) C.LiveTags = splitList(t) end,
	}), "LiveTags")
	bind(gates:MakeTextBox({
		Text = "Body tags (comma separated)", Flag = "BodyTags",
		Default = table.concat(C.BodyTags, ", "),
		Callback = function(t) C.BodyTags = splitList(t) end,
	}), "BodyTags")
	bind(gates:MakeTextBox({
		Text = "Friendly folders (comma separated)", Flag = "FriendlyFolders",
		Default = table.concat(C.FriendlyFolders, ", "),
		Callback = function(t) C.FriendlyFolders = splitList(t) end,
	}), "FriendlyFolders")
end

-- ------------------------------------------------------------------ config
do
	local sec = tabConfig:MakeSection("Saved config")
	sec:MakeButton({
		Text = "Save every option now",
		Style = "primary",
		Callback = function()
			local ok = A.saveNow()
			if type(window.Notify) == "function" then
				window:Notify({
					Title = ok and "Saved" or "Save failed",
					Text = tostring(ok and A.S.savePath or A.S.saveErr or "?"),
					Type = ok and "success" or "warn",
					Duration = 3,
				})
			end
		end,
	})
	sec:MakeButton({
		Text = "Reload from file",
		Callback = function()
			local ok = A.restore()
			if type(window.Notify) == "function" then
				window:Notify({
					Title = ok and "Loaded" or "Load failed",
					Text = tostring(A.S.restoreState or "?"),
					Type = ok and "success" or "warn",
					Duration = 3,
				})
			end
		end,
	})
	sec:MakeButton({
		Text = "Reset to shipped defaults",
		Callback = function()
			A.reset()
			if type(window.Notify) == "function" then
				window:Notify({
					Title = "Reset",
					Text = "shipped defaults restored and saved",
					Type = "info",
					Duration = 3,
				})
			end
		end,
	})
	sec:MakeParagraph({
		Title = "File",
		Text = "Every CONFIG key and the auto-win tunables are written to " ..
			"AegisAim/config.json two seconds after the last change and read back on every load, " ..
			"so a setting does not depend on the panel having a control for it.",
	})
end

-- Panel value -> CONFIG. Every flag maps straight onto its key except the two
-- that do not: the trigger dropdown holds a display label, and Autowin owns AW
-- instead of CONFIG. Colours read back from a config file arrive as hex text.
-- Flags whose control holds comma-separated text instead of a value. Their
-- callbacks build the table, so re-applying the joined text would collapse it.
A.listFlags = {
	IgnoreNames = true,
	IgnoreSubstrings = true,
	LiveTags = true,
	BodyTags = true,
	FriendlyFolders = true,
}

local function applyFlag(flag, v)
	if v == nil then return end
	if A.listFlags[flag] then return end

	if flag == "Activation" then
		A.C.Activation = (A.triggerValue and A.triggerValue[v]) or v
		return
	end

	if flag == "Autowin" then
		AW.set(v == true)
		return
	end

	if (flag == "ESPColor" or flag == "ESPTargetColor") and type(v) == "string" then
		local okc, col = pcall(Color3.fromHex, v)
		if okc then A.C[flag] = col end
		return
	end

	A.C[flag] = v
end
A.applyFlag = applyFlag

-- ------------------------------------------------------------- persistence
-- ONE store, holding the whole CONFIG table plus auto-win's tunables. The
-- earlier version wrote AegisUI's flag file, which only contains controls that
-- exist -- so any key without a panel row silently never round-tripped. A JSON
-- snapshot of CONFIG makes completeness a property of the format instead of a
-- hand-maintained flag list that drifts the moment a key is added.
local HttpService = game:GetService("HttpService")
local AW_KEYS = { "meleeRange", "throwRange", "meleeInterval", "throwInterval", "equipInterval" }
A.conFile = "AegisAim/config.json"

local function hexOf(c)
	return string.format("#%02X%02X%02X",
		math.floor(math.clamp(c.R, 0, 1) * 255 + 0.5),
		math.floor(math.clamp(c.G, 0, 1) * 255 + 0.5),
		math.floor(math.clamp(c.B, 0, 1) * 255 + 0.5))
end

local function pack()
	local t = { _version = VERSION }
	for k, v in pairs(A.C) do
		if type(v) == "table" then
			local arr = {}
			for i = 1, #v do arr[i] = tostring(v[i]) end
			t[k] = arr
		elseif typeof(v) == "Color3" then
			t[k] = hexOf(v)
		elseif type(v) == "string" or type(v) == "number" or type(v) == "boolean" then
			t[k] = v
		end
	end
	local aw = {}
	for i = 1, #AW_KEYS do aw[AW_KEYS[i]] = AW[AW_KEYS[i]] end
	t._autowin = aw
	return t
end
A.pack = pack

local function unpackInto(t)
	if type(t) ~= "table" then return 0 end
	local n = 0
	for k, v in pairs(t) do
		local default = A.C[k]
		if default ~= nil and k ~= "_version" then
			if type(default) == "table" then
				if type(v) == "table" then
					local arr = {}
					for i = 1, #v do arr[i] = tostring(v[i]) end
					A.C[k] = arr
					n = n + 1
				end
			elseif typeof(default) == "Color3" then
				if type(v) == "string" then
					local okHex, c = pcall(Color3.fromHex, v)
					if okHex then
						A.C[k] = c
						n = n + 1
					end
				end
			elseif type(v) == type(default) then
				A.C[k] = v
				n = n + 1
			end
		end
	end
	local aw = t._autowin
	if type(aw) == "table" then
		for i = 1, #AW_KEYS do
			local k = AW_KEYS[i]
			if type(aw[k]) == type(AW[k]) then
				AW[k] = aw[k]
				n = n + 1
			end
		end
	end
	return n
end

-- Control -> CONFIG for every flag with an element, so a control whose callback
-- does not write CONFIG cannot lose its value.
local function absorbControls()
	for i = 1, #order do
		local f = order[i]
		if not A.listFlags[f] then
			local ok, v = pcall(function() return elements[f]:Get() end)
			if ok then applyFlag(f, v) end
		end
	end
end
A.absorbControls = absorbControls

-- CONFIG -> controls, silent so a restore cannot re-enter a callback.
local function syncUI()
	for i = 1, #order do
		local f = order[i]
		local v = A.C[f]
		if v ~= nil then
			if f == "Activation" then
				push(f, (A.triggerLabel or {})[v] or v)
			elseif type(v) == "table" then
				push(f, table.concat(v, ", "))
			else
				push(f, v)
			end
		end
	end
	push("Autowin", AW.enabled)
	if A.syncAw then pcall(A.syncAw) end
end
A.syncUI = syncUI

local function restore()
	if not (isfile and pcall(isfile, A.conFile)) then
		A.S.restoreState = "no file yet"
		return false
	end
	local okRead, raw = pcall(readfile, A.conFile)
	if not okRead or type(raw) ~= "string" or raw == "" then
		A.S.restoreState = "read failed"
		return false
	end
	local okDecode, t = pcall(function() return HttpService:JSONDecode(raw) end)
	if not okDecode or type(t) ~= "table" then
		A.S.restoreState = "decode failed"
		return false
	end
	local n = unpackInto(t)
	A.S.restoreState = "loaded " .. tostring(n) .. " values"
	syncUI()
	return true
end
A.restore = restore

A.saveNow = function()
	local okEnc, body = pcall(function() return HttpService:JSONEncode(pack()) end)
	A.S.saves = (A.S.saves or 0) + 1
	if not okEnc or type(body) ~= "string" then
		A.S.saveOk = false
		A.S.saveErr = "encode: " .. tostring(body)
		return false
	end
	if makefolder and not (isfolder and pcall(isfolder, "AegisAim")) then
		pcall(makefolder, "AegisAim")
	end
	local okWrite = pcall(writefile, A.conFile, body)
	A.S.saveOk = okWrite and true or false
	A.S.saveErr = okWrite and nil or "writefile refused"
	A.S.savePath = A.conFile
	A.S.savedBytes = #body
	return A.S.saveOk
end

-- Shipped defaults are captured before the file is applied, so Reset is exact.
A.defaults = pack()
restore()
A.reset = function()
	unpackInto(A.defaults)
	syncUI()
	A.saveNow()
end

-- No change hook exists, so CONFIG is encoded once a second and written 2 s
-- after it stops changing. The unload button is not how a session ends -- a
-- client restart runs no Lua -- so without this a setting only lived in memory.
task.spawn(function()
	local last = nil
	local due = nil
	while not S.unloaded do
		task.wait(1)
		absorbControls()
		local okEnc, enc = pcall(function() return HttpService:JSONEncode(pack()) end)
		if okEnc and type(enc) == "string" then
			if last == nil then
				last = enc
			elseif enc ~= last then
				last = enc
				due = os.clock() + 2
			elseif due and os.clock() >= due then
				due = nil
				A.saveNow()
			end
		end
	end
end)

-- A single writer for the live labels, at 5 Hz: a status line does not need
-- frame rate, and CoreGui text writes are not free.
task.spawn(function()
	while not S.unloaded do
		task.wait(0.2)
		local ok, err = pcall(function()
			if labels.note then labels.note:Set("status: " .. tostring(S.status)) end
			if labels.target then
				local t = S.target
				if t then
					labels.target:Set(string.format("target: %s · %.0f studs · %.1f°",
						t.label, t.dist, S.angle or 0))
				else
					labels.target:Set("target: -")
				end
			end
			if labels.solve then
				labels.solve:Set(string.format("solver: %s · trigger %s · %.1f° · tau %.2f%s",
					tostring(C.DriveMode), tostring(C.Activation), S.angle or 0, S.tau or 0,
					S.ownsCamera and "" or " · game cam"))
			end
			if labels.pred then
				labels.pred:Set(string.format("lead: %.2f studs · target %.0f · self %.0f studs/s",
					S.leadStuds or 0, S.velStuds or 0, S.selfVelStuds or 0))
			end
			if labels.counters then
				local save = "saves 0"
				if (S.saves or 0) > 0 then
					save = S.saveOk and string.format("saves %d ok", S.saves)
						or string.format("saves %d FAILED (%s)", S.saves, tostring(S.saveErr or "?"))
				end
				labels.counters:Set(string.format("shots %d · switches %d · errors %d · %s",
					S.shots or 0, S.switches or 0, S.errors or 0, save))
			end
			if labels.gates then
				local n = 0
				for _ in pairs(S.reject) do n = n + 1 end
				labels.gates:Set(string.format("gates: %d rejects · accepted %d · npcs %d",
					n, S.reject.accepted or 0, C.NPCCheck and #npcArr or 0))
			end
			if labels.awNote then
				labels.awNote:Set("note: " .. tostring(AW.note))
			end
			if labels.awStat then
				labels.awStat:Set(string.format(
					"throws %d/%d · melee %d/%d · kills %d · errors %d",
					AW.counters.throwHits, AW.counters.throws,
					AW.counters.meleeHits, AW.counters.melees,
					AW.counters.killsSeen, AW.counters.errors))
			end
		end)
		if not ok then S.errors = S.errors + 1 end
	end
end)

--------------------------------------------------------------------
-- 14. Input
--
-- Local controls sit ABOVE the gameProcessedEvent guard: a key the game consumes
-- (alt-look, ContextActionService) reports processed = true, the press is
-- dropped, and the feature looks dead while the key is physically held.
--------------------------------------------------------------------

local KEY_KILL = Enum.KeyCode.F4

on(UIS.InputBegan, function(input, processed)
	local kc = input.KeyCode

	if kc == KEY_KILL then
		pcall(function() window:Collapse() end)
		return
	end

	if os.clock() < (S.keyGuard or 0) then
		return
	end

	local winKey = C.AutowinKey
	if winKey and kc ~= Enum.KeyCode.Unknown and kc.Name == winKey then
		AW.toggle()
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton3 then
		markTarget()
		return
	end

	if C.Activation == "hold" and kc ~= Enum.KeyCode.Unknown and kc.Name == C.HoldKey then
		S.held = true
	elseif C.Activation == "toggle" and kc ~= Enum.KeyCode.Unknown and kc.Name == C.ToggleKey then
		S.toggled = not S.toggled
		A.setStatus("aim " .. (S.toggled and "on" or "off"))
	elseif C.RequireClick and input.UserInputType == Enum.UserInputType.MouseButton1 then
		S.held = true
	end

	if kc == Enum.KeyCode.F6 then
		task.spawn(WB.fire)
		return
	end

	if processed then
		return
	end
end)

on(UIS.InputEnded, function(input)
	local kc = input.KeyCode
	if kc ~= Enum.KeyCode.Unknown and kc.Name == C.HoldKey then
		S.held = false
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		S.held = false
	end
end)

-- Toggle the locked target (or the best candidate under the crosshair) between
-- enemy and friendly. Falls back to the nearest-to-crosshair player, because a
-- friendly is never acquired and can never be the lock.
markTarget = function()
	local locked = S.target
	local player = locked and locked.player

	local cam = Workspace.CurrentCamera
	if not player and cam then
		local vp = cam.ViewportSize
		local cx, cy = vp.X * 0.5, vp.Y * 0.5
		local best, bestD = nil, C.MarkRadiusPx + 1
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= lp and p.Character then
				local head = p.Character:FindFirstChild("Head")
					or p.Character:FindFirstChild("HumanoidRootPart")
				if head then
					local ok, sp = pcall(function()
						return cam:WorldToViewportPoint(head.Position)
					end)
					if ok and sp and sp.Z > 0 then
						local d = math.sqrt((sp.X - cx) ^ 2 + (sp.Y - cy) ^ 2)
						if d < bestD then
							best, bestD = p, d
						end
					end
				end
			end
		end
		player = best
	end

	if not player then
		if locked then
			A.setStatus("middle-click: " .. locked.label .. " is an NPC")
		else
			A.setStatus("middle-click: nothing locked")
		end
		return
	end

	local uid = player.UserId
	if friendList[uid] then
		friendList[uid] = nil
		A.setStatus(player.Name .. " -> enemy (" .. friendCount() .. " friendly)")
	else
		friendList[uid] = player.Name
		if S.target and S.target.player == player then
			S.target = nil          -- stop pulling immediately
		end
		A.setStatus(player.Name .. " -> friendly (" .. friendCount() .. ")")
	end
end

--------------------------------------------------------------------
-- 15. Ping sampler
--------------------------------------------------------------------

task.spawn(function()
	while not S.unloaded do
		task.wait(1)
		local ok, value = pcall(function()
			return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
		end)
		if ok and type(value) == "number" then
			-- "Data Ping" is a spiky rolling figure; feeding it raw into the lead
			-- moved the aim point by ~1.4 studs a second on a moving target.
			local sample = clamp(value / 1000, 0, 0.5)
			if S.ping and S.ping > 0 then
				S.ping = S.ping * 0.7 + sample * 0.3
			else
				S.ping = sample
			end
		end
	end
end)

--------------------------------------------------------------------
-- 16. Teardown
--------------------------------------------------------------------

function A.unload(reason)
	if S.unloaded then return "aim-ui already unloaded" end
	S.unloaded = true

	-- Save before tearing the panel down. CONFIG is the store, not the panel, so
	-- this survives even if the window fails to be destroyed.
	if A.absorbControls then pcall(A.absorbControls) end
	if A.saveNow then pcall(A.saveNow) end

	if overlay.available and overlay.destroy then
		pcall(overlay.destroy)
	end
	pcall(function() RunService:UnbindFromRenderStep(SOLVER_ID) end)
	for i = 1, #A.conns do
		pcall(function() A.conns[i]:Disconnect() end)
	end
	for i = 1, #NR.conns do
		pcall(function() NR.conns[i]:Disconnect() end)
		NR.conns[i] = nil
	end
	for tool, conn in pairs(NR.bound) do
		pcall(function() conn:Disconnect() end)
		NR.bound[tool] = nil
	end
	pcall(function() window:Destroy() end)
	if genv then
		pcall(function()
			genv[CONN_KEY] = nil
			genv.AegisAim = nil
		end)
	end
	return "aim-ui unloaded (" .. tostring(reason) .. ")"
end

--------------------------------------------------------------------
-- 17. Cross-script API
--------------------------------------------------------------------

local api = {
	version = VERSION,
	config  = C,
	state   = S,

	-- Sets the table AND the control, so the panel and a probe cannot disagree.
	set = function(key, value)
		if key == "Autowin" then
			A.push("Autowin", value and true or false)
			return AW.set(value)
		end
		if C[key] == nil then
			return nil
		end
		C[key] = value
		-- The panel shows Activation as prose, so push the label it expects.
		if key == "Activation" then
			push(key, (A.triggerLabel or {})[value] or value)
		else
			push(key, value)
		end
		return C[key]
	end,

	get = function(key)
		if key == "Autowin" then return AW.enabled end
		return C[key]
	end,

	on = function()
		C.Enabled = true
		push("Enabled", true)
		A.setStatus("enabled")
	end,

	off = function()
		C.Enabled = false
		push("Enabled", false)
		A.setStatus("disabled")
	end,

	npcs = function(enabled)
		if enabled == nil then return C.NPCCheck end
		C.NPCCheck = enabled and true or false
		push("NPCCheck", C.NPCCheck)
		if C.NPCCheck then npcScanned = false end
		return C.NPCCheck
	end,

	target = function() return S.target end,
	npcCount = function() return C.NPCCheck and #npcArr or 0 end,
	velocity = function(model, root) return velocityFrom(model, root, os.clock()) end,

	collapse = function() pcall(function() window:Collapse() end) end,
	restore = function() pcall(function() window:Restore() end) end,

	party = function()
		return { count = friendCount(), list = friendList }
	end,

	save = function() return A.saveNow() end,
	load = function() return A.restore() end,
	saveNow = function() return A.saveNow() end,
	reset = function() return A.reset() end,
	pack = function() return A.pack() end,

	aw = {
		on = function() return AW.set(true) end,
		off = function() return AW.set(false) end,
		toggle = function() return AW.toggle() end,
		state = AW,
		set = function(key, value)
			if AW[key] ~= nil then AW[key] = value end
			return AW[key]
		end,
	},

	wallbang = WB.fire,
	unload = function() return A.unload("api") end,
}

genv.AegisAim = api
genv.AegisAutoWin = AW

--------------------------------------------------------------------
-- 17b. Winstreak table
--------------------------------------------------------------------
-- Winstreak is server-owned: the client only ever sees the replicated copy,
-- and the lobby boards (Wins, Kills, Level, WinStreak) are rendered from it.
-- So every number here is read from a live Instance -- leaderstats first,
-- because that is the copy the player list itself draws -- then a player
-- attribute, then a ValueBase parented straight to the player. A row that
-- resolves nowhere prints n/a, which keeps "this account has no streak"
-- distinguishable from "the read failed".

local STREAK_KEYS = {
 "WinStreak", "Winstreak", "Win Streak", "Streak", "WinstreakValue", "WinStreakValue",
}

local function streakOf(player)
 local stats = player:FindFirstChild("leaderstats")
 if stats then
  for _, child in ipairs(stats:GetChildren()) do
   if child:IsA("ValueBase") and string.find(string.lower(child.Name), "streak", 1, true) then
    return tostring(child.Value), "leaderstats." .. child.Name
   end
  end
 end
 for _, key in ipairs(STREAK_KEYS) do
  local ok, value = pcall(function() return player:GetAttribute(key) end)
  if ok and value ~= nil then
   return tostring(value), "attribute " .. key
  end
 end
 for _, child in ipairs(player:GetChildren()) do
  if child:IsA("ValueBase") and string.find(string.lower(child.Name), "streak", 1, true) then
   return tostring(child.Value), "player." .. child.Name
  end
 end
 return "n/a", ""
end

do
 local sec = tabStreak:MakeSection("Lobby")
 sec:MakeLabel({ Text = "player / winstreak" })
 local rows = {}
 local status = sec:MakeLabel({ Text = "reading the lobby..." })
 for i = 1, 32 do
  rows[i] = sec:MakeLabel({ Text = "" })
 end

 -- Rewriting 32 labels every second is a waste of a frame budget; the
 -- signature gate means the panel only redraws when the roster or a value
 -- actually moved.
 local lastSig = nil
 local function render()
  local list = {}
  for _, player in ipairs(Players:GetPlayers()) do
   local value, origin = streakOf(player)
   list[#list + 1] = {
    name = player.Name,
    value = value,
    origin = origin,
    num = tonumber(value) or -1,
   }
  end
  table.sort(list, function(a, b)
   if a.num ~= b.num then return a.num > b.num end
   return string.lower(a.name) < string.lower(b.name)
  end)

		-- Counted per origin, not reduced to one: different players can resolve
		-- from different places in the same lobby, and reporting an arbitrary
		-- one of them would make the panel look confident about a guess.
		local sig, counts = "", {}
		for _, row in ipairs(list) do
			sig = sig .. row.name .. "=" .. row.value .. ";"
			if row.origin ~= "" then counts[row.origin] = (counts[row.origin] or 0) + 1 end
		end
  if sig == lastSig then return end
  lastSig = sig

  for i = 1, #rows do
   local row = list[i]
   if row then
    rows[i]:Set(string.format("%-20s %s", row.name, row.value))
   else
    rows[i]:Set("")
   end
  end

		local parts = {}
		for origin, count in pairs(counts) do
			parts[#parts + 1] = origin .. " x" .. tostring(count)
		end
		table.sort(parts)
		status:Set(string.format(
			"%d in server, from %s",
			#list,
			#parts > 0 and table.concat(parts, ", ") or "-"
		))
 end

 render()
 task.spawn(function()
  while not S.unloaded do
   task.wait(1)
   pcall(render)
  end
 end)
end
--------------------------------------------------------------------
-- 17c. Name tag
--------------------------------------------------------------------
-- Roblox replicates Player.Name from the server, so what another player sees is
-- server data and not something this script can set. SPOOF_PROTOCOL.md measured
-- the boundary directly: forging WeaponDamage to 999 on the client left the
-- server computing the same 13 damage, because a local write reaches no server
-- calculation. A name is the same shape of value.
--
-- What is available here is Humanoid.DisplayName, which changes how THIS client
-- draws the name over a character. The panel says "this client only" in the
-- section title so the scope cannot be mistaken. The probe below fires nothing:
-- it lists remotes whose names suggest a server-side name or title channel, so
-- a real one can be wired deliberately instead of guessed at.

if C.SpoofName == nil then C.SpoofName = "" end
if C.SpoofNameOn == nil then C.SpoofNameOn = false end

local function spoofHumanoid()
 local character = Players.LocalPlayer.Character
 if not character then return nil end
 local ok, humanoid = pcall(function() return character:FindFirstChildOfClass("Humanoid") end)
 return ok and humanoid or nil
end

local function applyNameTag()
 local humanoid = spoofHumanoid()
 if not humanoid then return "no character yet" end
 local name = tostring(C.SpoofName or "")
 if not C.SpoofNameOn or name == "" then
  humanoid.DisplayName = Players.LocalPlayer.DisplayName
  return "off - showing your real name"
 end
 humanoid.DisplayName = name
 return "showing " .. name .. " here only"
end

local function nameCandidates()
 local found, seen = {}, {}
 local ok, items = pcall(function()
  return game:GetService("ReplicatedStorage"):GetDescendants()
 end)
 if not ok then return found end
 for _, item in ipairs(items) do
  local remote = item:IsA("RemoteEvent") or item:IsA("RemoteFunction")
  local lower = string.lower(item.Name)
  local named = string.find(lower, "name", 1, true)
   or string.find(lower, "title", 1, true)
   or string.find(lower, "nick", 1, true)
  if remote and named and not seen[item] then
   seen[item] = true
   found[#found + 1] = item:GetFullName()
  end
 end
 return found
end

do
 local sec = tabConfig:MakeSection("Name tag (this client only)")
 local status
 local function refresh()
  if status then status:Set(applyNameTag()) end
 end

 bind(sec:MakeToggle({
  Text = "Use a different name here",
  Description = "local view only - the server still tells everyone else your real name",
  Flag = "SpoofNameOn", Default = C.SpoofNameOn,
  Callback = function(v)
   C.SpoofNameOn = v
   refresh()
  end,
 }), "SpoofNameOn")

 bind(sec:MakeTextBox({
  Text = "Name shown to you", Flag = "SpoofName", Default = C.SpoofName,
  Callback = function(t)
   C.SpoofName = t
   refresh()
  end,
 }), "SpoofName")

 status = sec:MakeLabel({ Text = "idle" })

 sec:MakeButton({
  Text = "Apply to current character",
  Callback = function() refresh() end,
 })

 sec:MakeButton({
  Text = "List name/title remotes (fires nothing)",
  Style = "primary",
  Callback = function()
   local found = nameCandidates()
   if #found == 0 then
    status:Set("no name/title remote in ReplicatedStorage - nothing server-side to wire")
    return
   end
   status:Set("candidates: " .. table.concat(found, ", "))
  end,
 })

 local conn = Players.LocalPlayer.CharacterAdded:Connect(function()
  task.wait(0.5)
  refresh()
 end)
 if type(noReloadTrack) == "function" then
  noReloadTrack(conn)
 end
end
--------------------------------------------------------------------
-- 17d. Back to the main menu
--------------------------------------------------------------------
-- This game keeps its menu in PlayerGui.MainFrames and hides it while
-- LocalPlayer:GetAttribute("InMatch") is true. That attribute is server-owned,
-- so a client write to it would be a local lie, and the dumped client contains
-- no remote for leaving: every FireServer/InvokeServer was searched for
-- Leave / Match / Lobby / Menu / Exit / Back and none of them is one.
--
-- So the section offers the two things a client can actually do, and the status
-- line always names the state it observed instead of claiming success:
--   * show the menu locally - MainFrames.Enabled, which the game's own router
--     owns and can hide again on its next InMatch update
--   * leave the match - a rejoin teleport, the only client-side action that
--     actually clears InMatch, because the server resets it when you arrive

local function menuFrames()
 local gui = Players.LocalPlayer:FindFirstChild("PlayerGui")
 local frames = gui and gui:FindFirstChild("MainFrames")
 if frames and frames:IsA("ScreenGui") then return frames end
 return nil
end

local function matchState()
 local ok, value = pcall(function() return Players.LocalPlayer:GetAttribute("InMatch") end)
 if not ok then return nil end
 return value == true
end

do
 local sec = tabConfig:MakeSection("Back to the main menu")
 local status = sec:MakeLabel({ Text = "reading menu state..." })

 local function report(extra)
  local frames = menuFrames()
  local state = "menu state unknown"
  if matchState() == true then
   state = "in a match"
  elseif matchState() == false then
   state = "not in a match"
  end
  local menu = "no MainFrames"
  if frames then
   menu = frames.Enabled and "menu visible" or "menu hidden"
  end
  local line = state .. " - " .. menu
  if extra then line = line .. " - " .. extra end
  status:Set(line)
 end

 sec:MakeButton({
  Text = "Show the game menu",
  Callback = function()
   local frames = menuFrames()
   if not frames then
    report("nothing to show")
    return
   end
   frames.Enabled = true
   local menu = frames:FindFirstChild("MenuFrames")
   if menu and menu:IsA("GuiObject") then menu.Visible = true end
   report("enabled locally")
  end,
 })

 sec:MakeButton({
  Text = "Leave this match (rejoin server)",
  Callback = function()
   report("rejoining...")
   local ok, err = pcall(function()
    game:GetService("TeleportService"):Teleport(game.PlaceId, Players.LocalPlayer)
   end)
   if not ok then report("teleport refused: " .. tostring(err)) end
  end,
 })

 report()
end
--------------------------------------------------------------------
-- 17e. Automatic knife throw
--------------------------------------------------------------------
-- Same two calls auto-win uses (AW.throw): ThrowReplicate announces the knife,
-- ReportHit{kind="throw"} is what the server bills. Only the aim differs --
-- AW.throw derives the vector from a detected enemy, this derives it from the
-- camera, so the knife goes wherever the crosshair points.
--
-- The hit report is sent only when the crosshair is actually on a character.
-- The throw still fires with no victim, because that is just the knife leaving
-- the hand; reporting a hit on nothing would be a fabricated payload with no
-- victim to name.

if C.AutoThrow == nil then C.AutoThrow = false end
if C.AutoThrowKey == nil then C.AutoThrowKey = "Semicolon" end
if C.AutoThrowInterval == nil then C.AutoThrowInterval = 0.45 end
if C.AutoThrowRange == nil then C.AutoThrowRange = 300 end

AW.aimEnabled = false
AW.aimCounters = { throws = 0, hits = 0, errors = 0 }

-- The two remotes are resolved once at load (AW.remotes, above). On a client
-- that had not replicated `Remotes` yet they stay nil for the whole session,
-- which reads as "the knife is held and nothing ever leaves the hand" -- the
-- failure this function exists to fix. Cheap when already resolved.
function AW.resolveRemotes()
	if AW.throwRemote and AW.hitRemote then return true end
	local storage = game:GetService("ReplicatedStorage")
	if not AW.remotes then
		local ok, folder = pcall(function() return storage:FindFirstChild("Remotes", true) end)
		if ok and folder then AW.remotes = folder end
	end
	if AW.remotes then
		AW.throwRemote = AW.throwRemote or AW.remotes:FindFirstChild("ThrowReplicate")
		AW.hitRemote = AW.hitRemote or AW.remotes:FindFirstChild("ReportHit")
	end
	if not AW.throwRemote or not AW.hitRemote then
		-- Last resort: the folder is named something else, so match the remotes
		-- themselves. Read-only; nothing is fired while looking.
		local ok, items = pcall(function() return storage:GetDescendants() end)
		if ok then
			for _, item in ipairs(items) do
				local isRemote = item:IsA("RemoteEvent") or item:IsA("RemoteFunction")
				if isRemote and not AW.throwRemote and item.Name == "ThrowReplicate" then
					AW.throwRemote = item
				end
				if isRemote and not AW.hitRemote and item.Name == "ReportHit" then
					AW.hitRemote = item
				end
			end
		end
	end
	return AW.throwRemote ~= nil or AW.hitRemote ~= nil
end

AW.resolveRemotes()

function AW.playerFromPart(part)
 local model = part
 while model and model ~= Workspace do
  local player = Players:GetPlayerFromCharacter(model)
  if player then return player, model end
  model = model.Parent
 end
 return nil
end

function AW.aimRay()
 local camera = Workspace.CurrentCamera
 if not camera then return nil end
 local origin = camera.CFrame.Position
 local direction = camera.CFrame.LookVector * C.AutoThrowRange
 local params = RaycastParams.new()
 pcall(function() params.FilterType = Enum.RaycastFilterType.Exclude end)
 if params.FilterType == nil then
  pcall(function() params.FilterType = Enum.RaycastFilterType.Blacklist end)
 end
 params.FilterDescendantsInstances = { lp.Character }
 params.IgnoreWater = true
 local result = Workspace:Raycast(origin, direction, params)
 if result then return result.Position, result.Instance end
 return origin + direction, nil
end

function AW.throwAimed()
 local character, humanoid, root = AW.char()
	if not character or not humanoid or humanoid.Health <= 0 then return false end
	-- The throw does not need the hit remote, so a missing one must not stop the
	-- knife leaving the hand; it only decides whether damage can be reported.
	AW.resolveRemotes()
	local hitPos, hitPart = AW.aimRay()
 if not hitPos then return false end
 local origin = root.Position + Vector3.new(0, 2, 0)
 local delta = hitPos - origin
 if delta.Magnitude < 0.5 then return false end
 local dir = delta.Unit

 local id = AW.throwId
 AW.throwId = AW.throwId + 1

 if AW.throwRemote then
  pcall(function()
   AW.throwRemote:FireServer({
    origin      = origin,
    target      = origin + dir * 1000,
    id          = id,
    ownerUserId = lp.UserId,
    toolName    = "Knife",
    power       = 1,
    effects     = {},
   })
  end)
 end

 local victim, victimModel = nil, nil
 if hitPart then victim, victimModel = AW.playerFromPart(hitPart) end
	if victim and victimModel and AW.hitRemote then
  local vHum = victimModel:FindFirstChildOfClass("Humanoid")
  local vRoot = victimModel:FindFirstChild("HumanoidRootPart") or victimModel.PrimaryPart
  local sent = pcall(function()
   AW.hitRemote:FireServer({
    kind         = "throw",
    throwId      = id,
    ownerUserId  = lp.UserId,
    targetUserId = victim.UserId,
    targetModel  = victimModel,
    at           = Workspace:GetServerTimeNow(),
    origin       = origin,
    to           = vRoot and vRoot.Position or hitPos,
    vel          = dir * 420,
    hitPart      = hitPart,
    hitPos       = hitPos,
    headshot     = hitPart.Name == "Head",
   })
  end)
  if sent then
   AW.aimCounters.hits = AW.aimCounters.hits + 1
   AW.noteHit(victimModel, vHum and vHum.Health or 0, "throw")
  else
   AW.aimCounters.errors = AW.aimCounters.errors + 1
  end
 end

	AW.aimCounters.throws = AW.aimCounters.throws + 1
	-- AW.lastThrow belongs to auto-win's interval; writing it here throttled the
	-- other feature. This one tracks its own clock in lastAimThrow.
	return true
end

function AW.aimTick()
 if not AW.aimEnabled then return end
 local character, humanoid = AW.char()
 if not character or not humanoid or humanoid.Health <= 0 then return end
 if os.clock() - (AW.lastAimThrow or 0) < C.AutoThrowInterval then return end
 AW.lastAimThrow = os.clock()
 AW.equip(humanoid, character)
 AW.throwAimed()
end

function AW.setAutoThrow(enabled)
 AW.aimEnabled = enabled and true or false
 if A.push then A.push("AutoThrow", AW.aimEnabled) end
 return AW.aimEnabled
end

function AW.toggleAutoThrow()
 return AW.setAutoThrow(not AW.aimEnabled)
end

on(RunService.Heartbeat, function()
 pcall(AW.aimTick)
end)

on(UIS.InputBegan, function(input, processed)
 if processed then return end
 local kc = input.KeyCode
 if kc == Enum.KeyCode.Unknown then return end
 if kc.Name ~= tostring(C.AutoThrowKey) then return end
 AW.toggleAutoThrow()
end)

do
 local sec = tabCombat:MakeSection("Automatic knife throw")
 local status = sec:MakeLabel({ Text = "off" })

	local function report()
		-- Resolve on demand: the remotes are looked up once at load, and a client
		-- that had not replicated them yet would otherwise report "ON" forever
		-- while nothing ever left the hand.
		AW.resolveRemotes()
		status:Set(string.format(
			"%s - %d thrown, %d on a player - throw:%s hit:%s",
			AW.aimEnabled and "ON" or "off",
			AW.aimCounters.throws, AW.aimCounters.hits,
			AW.throwRemote and "ok" or "MISSING",
			AW.hitRemote and "ok" or "MISSING"
		))
	end

 bind(sec:MakeToggle({
  Text = "Throw at the crosshair",
  Description = "same calls as auto-win; toggle key " .. tostring(C.AutoThrowKey),
  Flag = "AutoThrow", Default = C.AutoThrow,
  Callback = function(value)
   AW.setAutoThrow(value)
   report()
  end,
 }), "AutoThrow")

 sec:MakeButton({
  Text = "Refresh counters",
  Callback = report,
 })

 report()
end
--------------------------------------------------------------------
-- 18. Go
--------------------------------------------------------------------

if not startSolver() then
	warn("[Aegis] aim-ui: solver did not bind")
end

A.setStatus("ready · " .. tostring(C.DriveMode) .. " · " .. tostring(C.Part))

return string.format(
	"aim-ui ready %s · solver=%s trigger=%s fov=%dpx part=%s npc=%s overlay=%s",
	VERSION, tostring(C.DriveMode), tostring(C.Activation), C.FOV,
	tostring(C.Part), C.NPCCheck and "on" or "off", tostring(overlay.kind)
)
