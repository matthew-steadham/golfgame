--!strict
-- HudController.luau  (ModuleScript in ReplicatedStorage.Shared.Modules)
--
-- The EvoSwing HUD cluster, lifted out of SwingController as one unit because it is
-- one cohesive thing: the power/shape meter, the swing-feedback colours, the stats
-- card + its slide, and the post-shot fade curtain all share the `evo` GUI refs and
-- call into each other (the fade restores the stats colours; the result paints the
-- strokes). Splitting them apart would only create a circular dependency.
--
-- What deliberately stays in the controller: `MAX_SWING_TILT_DEG`, the `*_TOL`
-- swing-quality tolerances, `swinging`, and `updateHUD` -- those read swing/club/shape
-- state, so they're controller glue, not rendering.
--
-- API:
--   Hud.init()                                   -- resolve the GUI (and re-resolve on respawn)
--   Hud.setPowerRing(p) / setDownRing(p)
--   Hud.setShapeAngle(deg) / setMeterVisible(v)
--   Hud.setPowerLabel(distanceFraction) / showPowerLabel(v)
--   Hud.resetSwingFeedback()
--   Hud.slideStatsIn() / slideStatsOut()
--   Hud.postShotTransition()
--   Hud.showSwingResult(swing, distanceFraction, backGood, downGood, pathGood, faceGood)

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Mods = ReplicatedStorage.Shared.Modules
local ShotModel = require(Mods.ShotModel)
local SwingConfig = require(Mods.SwingConfig)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Hud = {}

-- ===== GUI resolution =====
local evo: any = nil
local function bindEvoGui()
	local sg = playerGui:WaitForChild("EvoSwing", 20)
	if not sg then
		warn("[HudController] EvoSwing ScreenGui never appeared in PlayerGui -- meter disabled.")
		return
	end
	local root = sg:WaitForChild("Root", 10)
	local inner = root and root:WaitForChild("EvoSwing", 10)
	local maxPower = inner and inner:WaitForChild("MaxPower", 10)
	if not maxPower then
		warn("[HudController] Found EvoSwing but not Root/EvoSwing/MaxPower -- check the names.")
		return
	end
	local ring = maxPower:FindFirstChild("PowerRing")
	local downRing = maxPower:FindFirstChild("DownswingRing")
	local targetRing = maxPower:FindFirstChild("TargetRing") -- guide ring: how far to pull the backswing
	evo = {
		gui = sg,
		scale = ring and ring:FindFirstChild("UIScale"),
		powerStroke = ring and ring:FindFirstChild("UIStroke"),
		downScale = downRing and downRing:FindFirstChild("UIScale"),
		downStroke = downRing and downRing:FindFirstChild("UIStroke"),
		targetScale = targetRing and targetRing:FindFirstChild("UIScale"),
		shape = maxPower:FindFirstChild("Shape"),
		power = maxPower:FindFirstChild("Power"),
	}
	local stats = inner:FindFirstChild("Statistics")
	local slide = stats and stats:FindFirstChild("Slide")
	local cardParent = slide or stats -- cards now live under Statistics.Slide
	evo.slide = slide
	local function statLabel(n: string)
		local fr = cardParent and cardParent:FindFirstChild(n)
		return fr and fr:FindFirstChildWhichIsA("TextLabel")
	end
	evo.statContact = statLabel("Contact")
	evo.statRhythm = statLabel("Rhythm")
	evo.statPath = statLabel("Swing Path") or statLabel("SwingPath")
	evo.statTransition = statLabel("Transition")
	if slide then slide.Position = UDim2.new(1, 0, 0, 0) end -- start parked off-screen right
	if not slide then warn("[HudController] Statistics.Slide not found.") end

	evo.root = root
	local fade = sg:FindFirstChild("Fade")
	evo.fade = fade
	if fade and fade:IsA("GuiObject") then
		fade.Visible = true
		fade.BackgroundTransparency = 1 -- invisible until a transition plays
		fade.ZIndex = 1000              -- sit above the HUD so it can mask the cut
	end
	if not fade then warn("[HudController] EvoSwing.Fade frame not found (post-shot curtain disabled).") end

	if not evo.scale then warn("[HudController] MaxPower.PowerRing.UIScale not found.") end
	if not evo.downScale then warn("[HudController] MaxPower.DownswingRing.UIScale not found.") end
	if not evo.targetScale then warn("[HudController] MaxPower.TargetRing.UIScale not found (power-target guide disabled).") end
	if not evo.shape then warn("[HudController] MaxPower.Shape not found.") end
	if not evo.power then warn("[HudController] MaxPower.Power label not found.") end
	if not stats then warn("[HudController] Root.EvoSwing.Statistics not found.") end
end

function Hud.init()
	task.spawn(bindEvoGui)
	-- if the GUI resets on respawn, rebind the next time it appears
	playerGui.ChildAdded:Connect(function(c)
		if c.Name == "EvoSwing" then task.spawn(bindEvoGui) end
	end)
end

-- ===== meter setters =====
-- The fill ring and the dialed-power guide share this mapping so the guide sits
-- exactly where "perfect power" is: p in [0,1] -> visual Scale in [MIN, 1] (linear).
local POWER_RING_MIN_SCALE = 0.5
local function ringScale(p: number): number
	return POWER_RING_MIN_SCALE + math.clamp(p, 0, 1) * (1 - POWER_RING_MIN_SCALE)
end
local function setPowerRing(p: number)        -- live backswing fill
	if evo and evo.scale then evo.scale.Scale = ringScale(p) end
end
local function setPowerTarget(p: number)      -- guide: how far to pull back (the dialed power)
	if evo and evo.targetScale then evo.targetScale.Scale = ringScale(p) end
end
local function setShapeAngle(deg: number)
	if evo and evo.shape then evo.shape.Rotation = deg end
end
local function setMeterVisible(v: boolean)
	if evo and evo.gui then evo.gui.Enabled = v end
end
local function setPowerLabel(distanceFraction: number)
	if evo and evo.power then evo.power.Text = string.format("%d%%", math.floor(distanceFraction * 100 + 0.5)) end
end
local function showPowerLabel(v: boolean)
	if evo and evo.power then evo.power.Visible = v end
end

-- ===== feedback colours =====
local COL_NEUTRAL = Color3.fromRGB(255, 251, 254)
local COL_GOOD = Color3.fromRGB(87, 187, 233)
local COL_BAD = Color3.fromRGB(168, 47, 59)

local function setStroke(stroke: any, color: Color3)
	if stroke then stroke.Color = color end
end
local function colorShapeFrames(color: Color3)
	if not (evo and evo.shape) then return end
	for _, ch in evo.shape:GetChildren() do
		if ch:IsA("Frame") then ch.BackgroundColor3 = color end
	end
end
local function setDownRing(p: number)
	if evo and evo.downScale then evo.downScale.Scale = math.clamp(p, 0, 1) end
end
local function setStatColor(color: Color3)
	if not evo then return end
	if evo.statContact then evo.statContact.TextColor3 = color end
	if evo.statRhythm then evo.statRhythm.TextColor3 = color end
	if evo.statPath then evo.statPath.TextColor3 = color end
	if evo.statTransition then evo.statTransition.TextColor3 = color end
end
local function resetSwingFeedback()
	setDownRing(0)
	setStroke(evo and evo.powerStroke, COL_NEUTRAL)
	setStroke(evo and evo.downStroke, COL_NEUTRAL)
	colorShapeFrames(COL_NEUTRAL)
	setStatColor(COL_NEUTRAL)
end

-- ===== stats card slide =====
local SLIDE_IN = UDim2.new(0, 0, 0, 0)
local SLIDE_OUT = UDim2.new(1, 0, 0, 0)
local slideTween: Tween? = nil
local function slideStatsOut()
	if slideTween then slideTween:Cancel() slideTween = nil end
	if evo and evo.slide then evo.slide.Position = SLIDE_OUT end
end
local function slideStatsIn()
	if not (evo and evo.slide) then return end
	if slideTween then slideTween:Cancel() end
	slideTween = TweenService:Create(
		evo.slide,
		TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{ Position = SLIDE_IN }
	)
	slideTween:Play()
end

-- ===== post-shot transition =====
-- When the ball settles: fade the entire HUD (everything under Root) to invisible
-- over ~0.5s, then play a full-screen "Fade" curtain (ease in, then out) to soften
-- the cut to the next shot. The HUD is restored instantly behind the opaque curtain.
local fadeChannels: { any }? = nil
local fadeConn: RBXScriptConnection? = nil

local function collectFadeChannels(container: Instance)
	local list = {}
	local function add(obj: Instance, prop: string)
		table.insert(list, { obj = obj, prop = prop, orig = (obj :: any)[prop] })
	end
	for _, d in container:GetDescendants() do
		if d:IsA("GuiObject") then add(d, "BackgroundTransparency") end
		if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
			add(d, "TextTransparency")
			add(d, "TextStrokeTransparency")
		end
		if d:IsA("ImageLabel") or d:IsA("ImageButton") then add(d, "ImageTransparency") end
		if d:IsA("UIStroke") then add(d, "Transparency") end
	end
	return list
end

local function ensureFadeChannels()
	if not fadeChannels and evo and evo.root then
		fadeChannels = collectFadeChannels(evo.root)
	end
	return fadeChannels
end

-- Lerp every channel toward fully transparent (toFaded) or back to its original value.
local function animateFade(toFaded: boolean, duration: number, onDone: (() -> ())?)
	local chans = ensureFadeChannels()
	if not chans then if onDone then onDone() end return end
	if fadeConn then fadeConn:Disconnect() fadeConn = nil end
	local from = {}
	for i, ch in chans do from[i] = (ch.obj :: any)[ch.prop] end
	local t0 = os.clock()
	fadeConn = RunService.Heartbeat:Connect(function()
		local a = math.clamp((os.clock() - t0) / duration, 0, 1)
		for i, ch in chans do
			local target = if toFaded then 1 else ch.orig
			local o = ch.obj :: any
			o[ch.prop] = from[i] + (target - from[i]) * a
		end
		if a >= 1 then
			if fadeConn then fadeConn:Disconnect() fadeConn = nil end
			if onDone then onDone() end
		end
	end)
end

local function restoreFadeInstant()
	local chans = ensureFadeChannels()
	if not chans then return end
	if fadeConn then fadeConn:Disconnect() fadeConn = nil end
	for _, ch in chans do
		local o = ch.obj :: any
		o[ch.prop] = ch.orig
	end
end

-- Full-screen curtain: ease BackgroundTransparency 1->0, fire onMid at the peak,
-- then ease 0->1. Total wall-clock time == `total`.
local function playFadeCurtain(total: number, onMid: (() -> ())?)
	if not (evo and evo.fade) then if onMid then onMid() end return end
	local half = total / 2
	local tIn = TweenService:Create(
		evo.fade,
		TweenInfo.new(half, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 0 }
	)
	tIn.Completed:Once(function()
		if onMid then onMid() end
		TweenService:Create(
			evo.fade,
			TweenInfo.new(half, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
			{ BackgroundTransparency = 1 }
		):Play()
	end)
	tIn:Play()
end

local function postShotTransition()
	animateFade(true, 0.5, function()        -- 1) dissolve the HUD
		playFadeCurtain(2.0, function()      -- 2) curtain in -> (restore) -> out
			restoreFadeInstant()             -- HUD back to full opacity, hidden behind curtain
			slideStatsOut()                  -- park the stats card for the next shot
			setStatColor(COL_NEUTRAL)        -- reset stat text colours
		end)
	end)
end

-- ===== stats card =====
-- readout scales: push/pull degree = actual start-direction; face is a nominal angle
local PATH_DEG_SCALE = ShotModel.CFG.PATH_START_DEG -- displayed push/pull = actual start direction
local FACE_DEG_SCALE = ShotModel.CFG.FACE_ANGLE_MAX  -- displayed face = actual spin-axis tilt
local function setStats(swing: any, distanceFraction: number, backGood: boolean, downGood: boolean, pathGood: boolean, faceGood: boolean)
	if not evo then return end
	local faceDeg = (swing.faceOffset or 0) * FACE_DEG_SCALE   -- downswing: hook/slice
	local pathDeg = (swing.path or 0) * PATH_DEG_SCALE          -- backswing: push/pull
	local backT = swing.backTime or 0
	local downT = swing.downTime or 0
	local powerRaw = backT / SwingConfig.FullBackswingTime      -- can exceed 1 (overswing)
	local idealDown = backT / SwingConfig.IdealTempoRatio
	local rhythmS = downT - idealDown                           -- + = decelerating, - = rushed
	-- rhythm modifies delivered power; show the net vs the dialed target
	local rhythmMod = 1 - ShotModel.CFG.RHYTHM_POWER_PENALTY * math.clamp(math.abs(swing.tempo or 0), 0, 1)
	local effPower = math.clamp(swing.power or 0, 0, 1) * rhythmMod
		* (1 + (swing.overswing or 0) * ShotModel.CFG.OVERSWING_BONUS)
	local powerDev = (effPower - distanceFraction) * 100

	-- Contact (hook/slice) -- PERFECT replaces the readout when good
	if evo.statContact then
		if faceGood then
			evo.statContact.Text = "PERFECT"
		else
			local st = if faceDeg < -0.5 then "CLOSED" elseif faceDeg > 0.5 then "OPEN" else "PURE"
			evo.statContact.Text = string.format("%+.2f° | %s", faceDeg, st)
		end
		evo.statContact.TextColor3 = faceGood and COL_GOOD or COL_BAD
	end
	-- Swing Path (push/pull)
	if evo.statPath then
		if pathGood then
			evo.statPath.Text = "PERFECT"
		else
			local st = if pathDeg < -0.5 then "PULL" elseif pathDeg > 0.5 then "PUSH" else "STRAIGHT"
			evo.statPath.Text = string.format("%+.2f° | %s", pathDeg, st)
		end
		evo.statPath.TextColor3 = pathGood and COL_GOOD or COL_BAD
	end
	-- Rhythm
	if evo.statRhythm then
		if downGood then
			evo.statRhythm.Text = "PERFECT"
		else
			evo.statRhythm.Text = string.format("%+.2fs | %+.2f%% POWER", rhythmS, powerDev)
		end
		evo.statRhythm.TextColor3 = downGood and COL_GOOD or COL_BAD
	end
	-- Transition -- keeps the % and appends PERFECT when good
	if evo.statTransition then
		local flag
		if backGood then
			flag = "PERFECT"
		elseif powerRaw > 1.0 then
			flag = "OVERSWING"
		elseif (swing.power or 0) < distanceFraction then
			flag = "SHORT"
		else
			flag = "LONG"
		end
		evo.statTransition.Text = string.format("%d%% | %s", math.floor(powerRaw * 100 + 0.5), flag)
		evo.statTransition.TextColor3 = backGood and COL_GOOD or COL_BAD
	end
end

-- Paint the full swing-result feedback in one call: ring strokes, shape frames, and
-- the stats card. (Was four inlined lines in the controller's onCompleted.)
function Hud.showSwingResult(swing: any, distanceFraction: number, backGood: boolean, downGood: boolean, pathGood: boolean, faceGood: boolean)
	setStroke(evo and evo.powerStroke, backGood and COL_GOOD or COL_BAD)
	setStroke(evo and evo.downStroke, downGood and COL_GOOD or COL_BAD)
	colorShapeFrames(pathGood and COL_GOOD or COL_BAD)
	setStats(swing, distanceFraction, backGood, downGood, pathGood, faceGood)
end

-- public surface
Hud.setPowerRing = setPowerRing
Hud.setPowerTarget = setPowerTarget
Hud.setShapeAngle = setShapeAngle
Hud.setMeterVisible = setMeterVisible
Hud.setPowerLabel = setPowerLabel
Hud.showPowerLabel = showPowerLabel
Hud.setDownRing = setDownRing
Hud.resetSwingFeedback = resetSwingFeedback
Hud.slideStatsIn = slideStatsIn
Hud.slideStatsOut = slideStatsOut
Hud.postShotTransition = postShotTransition

return Hud
