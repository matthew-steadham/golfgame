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
--   Hud.snapHoleStatCardInvisible() / fadeHoleStatCardIn()
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
local mainFadeOriginal: {[Instance]: {[string]: number}} = {}
local holeStatFadeTweens: {Tween} = {}

-- HoleStatCard slide positions. "Up" is the parked/original position; "down" is visible.
local HSC_TWEEN_IN = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HSC_TWEEN_OUT = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local HOLE_SHOT_STATS_UP = UDim2.new(0.18, 0, 0.5, 0)
local HOLE_SHOT_STATS_DOWN = UDim2.new(0.18, 0, 1, 0)
local SHOT_LANG_UP = UDim2.new(1, 0, 0.5, 0)
local SHOT_LANG_DOWN = UDim2.new(1, 0, 1, 0)

local holeNumbersTween: Tween? = nil
local shotLanguageTween: Tween? = nil
local holeNumbersDown = false
local shotLanguageDown = false
local holeNumbersPendingTween = false
local shotLanguagePendingTween = false

local function guiObject(inst: any): GuiObject?
	return if inst and inst:IsA("GuiObject") then inst else nil
end

local function setHoleNumbersDown(down: boolean, animate: boolean, replayFromUp: boolean?)
	holeNumbersDown = down
	local shotStats = guiObject(evo and evo.hscShotStats)
	if not shotStats then
		holeNumbersPendingTween = animate
		return
	end
	holeNumbersPendingTween = false
	if holeNumbersTween then
		holeNumbersTween:Cancel()
		holeNumbersTween = nil
	end

	local target = if down then HOLE_SHOT_STATS_DOWN else HOLE_SHOT_STATS_UP
	if not animate then
		shotStats.Position = target
		return
	end
	if down and replayFromUp then
		shotStats.Position = HOLE_SHOT_STATS_UP
	end

	local tween = TweenService:Create(shotStats, if down then HSC_TWEEN_IN else HSC_TWEEN_OUT, { Position = target })
	holeNumbersTween = tween
	tween.Completed:Once(function()
		if holeNumbersTween == tween then
			holeNumbersTween = nil
		end
	end)
	tween:Play()
end

local function setShotLanguageDown(down: boolean, animate: boolean, replayFromUp: boolean?)
	shotLanguageDown = down
	local lang = guiObject(evo and evo.hscLanguageFrame)
	if not lang then
		shotLanguagePendingTween = animate
		return
	end
	shotLanguagePendingTween = false
	if shotLanguageTween then
		shotLanguageTween:Cancel()
		shotLanguageTween = nil
	end

	local target = if down then SHOT_LANG_DOWN else SHOT_LANG_UP
	if not animate then
		lang.Position = target
		return
	end
	if down and replayFromUp then
		lang.Position = SHOT_LANG_UP
	end

	local tween = TweenService:Create(lang, if down then HSC_TWEEN_IN else HSC_TWEEN_OUT, { Position = target })
	shotLanguageTween = tween
	tween.Completed:Once(function()
		if shotLanguageTween == tween then
			shotLanguageTween = nil
		end
	end)
	tween:Play()
end

local function syncHoleStatCardTweenPositions()
	local animateNumbers = holeNumbersPendingTween
	local animateLanguage = shotLanguagePendingTween
	setHoleNumbersDown(holeNumbersDown, animateNumbers, animateNumbers and holeNumbersDown)
	setShotLanguageDown(shotLanguageDown, animateLanguage, animateLanguage and shotLanguageDown)
end
local function bindEvoGui()
	mainFadeOriginal = {}
	local sg = playerGui:WaitForChild("MainUI", 20)
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
	-- Distance readout lives under Root (a frame named "Distance"). Searched recursively so it
	-- works whether DistanceCount/Units sit directly in it or under a nested Background frame.
	local distFrame = root and root:FindFirstChild("Distance") -- direct child (not PreShot/Distance)
	evo.distFrame = distFrame
	if distFrame then distFrame.Visible = false end -- shown only while a shot is live
	evo.distCount = distFrame and distFrame:FindFirstChild("DistanceCount", true)
	evo.distUnit = distFrame and distFrame:FindFirstChild("Units", true)
	evo.distSingle = distFrame and distFrame:FindFirstChildWhichIsA("TextLabel", true)

	-- Pre-shot info panel (Root/PreShot). Navigated explicitly because names repeat.
	local preShot = root and root:FindFirstChild("PreShot")
	evo.preShotFrame = preShot
	if preShot then
		preShot.Visible = true -- shown while aiming; hidden while a shot is live
		local shotFrame = preShot:FindFirstChild("ShotType")
		evo.psShotIcon = shotFrame and shotFrame:FindFirstChild("TypeIcon")
		evo.psShotText = shotFrame and shotFrame:FindFirstChild("ShotType")
		local distFr = preShot:FindFirstChild("Distance")
		evo.psDistCount = distFr and distFr:FindFirstChild("DistanceCount")
		evo.psDistUnits = distFr and distFr:FindFirstChild("Units")
		local lieAny = distFr and distFr:FindFirstChild("LieType", true)
		evo.psLie = if lieAny and lieAny:IsA("TextLabel") then lieAny
			elseif lieAny then lieAny:FindFirstChildWhichIsA("TextLabel")
			else nil
		local clubFrame = preShot:FindFirstChild("Club")
		evo.psClubIcon = clubFrame and clubFrame:FindFirstChild("TypeIcon")
		evo.psClubText = clubFrame and clubFrame:FindFirstChild("ClubType")
	end

	-- HoleStatCard (Root/HoleStatCard): always-on per-hole shot tracker.
	local hsc = root and root:FindFirstChild("HoleStatCard")
	evo.hscCard = hsc
	if hsc then
		local shotStats = hsc:FindFirstChild("HoleShotStats")
		evo.hscShotStats = shotStats
		evo.hscNumbers = shotStats and shotStats:FindFirstChild("HoleNumbers")
		evo.hscGraphics = shotStats and shotStats:FindFirstChild("HoleGraphics")
		evo.hscHoleNumber = shotStats and shotStats:FindFirstChild("HoleNumber")
		local lang = hsc:FindFirstChild("CurrentShotLanguage")
		evo.hscLanguage = lang and lang:FindFirstChild("Text")
		evo.hscLanguageFrame = lang
		local sd = hsc:FindFirstChild("ScoreDiff")
		evo.hscScoreDiff = sd and sd:FindFirstChild("ScoreDiff")
		local avatar = hsc:FindFirstChild("Avatar")
		if avatar then
			local img = avatar:FindFirstChildWhichIsA("ImageLabel")
			if not img then
				img = Instance.new("ImageLabel")
				img.Name = "Headshot"
				img.BackgroundTransparency = 1
				img.Size = UDim2.fromScale(1, 1)
				img.Parent = avatar
			end
			img.Image = `rbxthumb://type=AvatarHeadShot&id={player.UserId}&w=150&h=150`
		end
	end
	syncHoleStatCardTweenPositions()
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
		if c.Name == "MainUI" then task.spawn(bindEvoGui) end
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

-- ===== MainUI element fade =====
local function rememberTransparency(inst: Instance, prop: string)
	local obj = inst :: any
	local byProp = mainFadeOriginal[inst]
	if not byProp then
		byProp = {}
		mainFadeOriginal[inst] = byProp
	end
	if byProp[prop] == nil then
		byProp[prop] = obj[prop]
	end
end

local function collectFadeGoals(root: GuiObject?, faded: boolean): {[Instance]: {[string]: number}}
	local goals: {[Instance]: {[string]: number}} = {}
	if not root then return goals end

	local function add(inst: Instance, prop: string)
		rememberTransparency(inst, prop)
		local byProp = mainFadeOriginal[inst]
		local goal = goals[inst]
		if not goal then
			goal = {}
			goals[inst] = goal
		end
		goal[prop] = if faded then 1 else byProp[prop]
	end

	local items = { root }
	for _, inst in root:GetDescendants() do
		items[#items + 1] = inst
	end
	for _, inst in items do
		if inst:IsA("GuiObject") then
			add(inst, "BackgroundTransparency")
		end
		if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then
			add(inst, "TextTransparency")
			add(inst, "TextStrokeTransparency")
		end
		if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
			add(inst, "ImageTransparency")
		end
		if inst:IsA("UIStroke") then
			add(inst, "Transparency")
		end
		if inst:IsA("CanvasGroup") then
			add(inst, "GroupTransparency")
		end
	end
	return goals
end

local function collectMainFadeGoals(faded: boolean): {[Instance]: {[string]: number}}
	return collectFadeGoals(guiObject(evo and evo.root), faded)
end

local function collectHoleStatFadeGoals(): {[Instance]: {[string]: number}}
	return collectFadeGoals(guiObject(evo and evo.hscCard), false)
end

local function tweenMainFade(faded: boolean, duration: number, onDone: (() -> ())?)
	local goals = collectMainFadeGoals(faded)
	local remaining = 0
	for inst, props in goals do
		remaining += 1
		local tween = TweenService:Create(inst, TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), props)
		tween.Completed:Once(function()
			remaining -= 1
			if remaining <= 0 and onDone then
				onDone()
				onDone = nil
			end
		end)
		tween:Play()
	end
	if remaining == 0 and onDone then
		onDone()
	end
end

local function fadeMainOut(duration: number?, onDone: (() -> ())?)
	if evo and evo.root then evo.root.Visible = true end
	tweenMainFade(true, duration or 0.25, onDone)
end

local function cancelHoleStatFadeTweens()
	for _, tween in holeStatFadeTweens do
		tween:Cancel()
	end
	holeStatFadeTweens = {}
end

local function snapHoleStatCardInvisible()
	cancelHoleStatFadeTweens()
	local card = guiObject(evo and evo.hscCard)
	if card then
		card.Visible = false
	end
end

local function fadeHoleStatCardIn(duration: number?)
	local card = guiObject(evo and evo.hscCard)
	if not card then return end
	cancelHoleStatFadeTweens()
	local goals = collectHoleStatFadeGoals()
	card.Visible = true
	for inst, props in goals do
		local obj = inst :: any
		for prop, _ in props do
			obj[prop] = 1
		end
	end

	local remaining = 0
	local tweenInfo = TweenInfo.new(duration or 0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
	for inst, props in goals do
		remaining += 1
		local tween = TweenService:Create(inst, tweenInfo, props)
		holeStatFadeTweens[#holeStatFadeTweens + 1] = tween
		tween.Completed:Once(function()
			remaining -= 1
			if remaining <= 0 then
				holeStatFadeTweens = {}
			end
		end)
		tween:Play()
	end
	if remaining == 0 then
		holeStatFadeTweens = {}
	end
end

local function restoreMainFadeInstant()
	local goals = collectMainFadeGoals(false)
	for inst, props in goals do
		local obj = inst :: any
		for prop, value in props do
			obj[prop] = value
		end
	end
end
-- ===== post-shot transition =====
-- When the ball settles: hide the HUD, play the full-screen "Fade" curtain to soften the cut,
-- then show the HUD again behind the opaque curtain. No fade -- the HUD is a hard Visible toggle
-- on Root. The "Fade" curtain is a sibling of Root (outside it), so hiding Root never hides it.
-- (duration stays in the signature for the existing call sites but is unused.)
local function animateFade(toFaded: boolean, duration: number, onDone: (() -> ())?)
	if evo and evo.root then
		evo.root.Visible = not toFaded
	end
	if onDone then onDone() end
end

local function restoreFadeInstant()
	restoreMainFadeInstant()
	if evo and evo.root then
		evo.root.Visible = true
	end
end

local function setMainVisible(v: boolean)
	if evo and evo.root then
		evo.root.Visible = v
	end
end

local BLACK_SCREEN_FADE_TIME = 1.0

-- Full-screen curtain: ease BackgroundTransparency 1->0, fire onMid at the peak,
-- then ease 0->1. Total wall-clock time == `total`.
local function playFadeCurtain(total: number, onMid: (() -> ())?, onDone: (() -> ())?)
	if not (evo and evo.fade) then if onMid then onMid() end if onDone then onDone() end return end
	local half = total / 2
	local tIn = TweenService:Create(
		evo.fade,
		TweenInfo.new(half, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 0 }
	)
	tIn.Completed:Once(function()
		if onMid then onMid() end
		local tOut = TweenService:Create(
			evo.fade,
			TweenInfo.new(half, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
			{ BackgroundTransparency = 1 }
		)
		tOut.Completed:Once(function()
			if onDone then onDone() end
		end)
		tOut:Play()
	end)
	tIn:Play()
end

local function playBlackScreenTransition(onBlack: (() -> ())?, onDone: (() -> ())?)
	animateFade(true, 0, function()
		playFadeCurtain(BLACK_SCREEN_FADE_TIME * 2, function()
			if onBlack then onBlack() end
			restoreFadeInstant()
			slideStatsOut()
			setStatColor(COL_NEUTRAL)
		end, onDone)
	end)
end
local function postShotTransition(onBlack: (() -> ())?, onDone: (() -> ())?)
	fadeMainOut(0.25, function()
		playBlackScreenTransition(onBlack, onDone)
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
			evo.statContact.Text = string.format("%+.2f� | %s", faceDeg, st)
		end
		evo.statContact.TextColor3 = faceGood and COL_GOOD or COL_BAD
	end
	-- Swing Path (push/pull)
	if evo.statPath then
		if pathGood then
			evo.statPath.Text = "PERFECT"
		else
			local st = if pathDeg < -0.5 then "PULL" elseif pathDeg > 0.5 then "PUSH" else "STRAIGHT"
			evo.statPath.Text = string.format("%+.2f� | %s", pathDeg, st)
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

-- Update the combined distance readout. count/unit come from ShotDistance; the slide's own
-- animation handles show/hide, so this only sets text.
local function setDistance(count: string, unit: string)
	if not evo then return end
	if evo.distCount and evo.distUnit then
		evo.distCount.Text = count
		evo.distUnit.Text = unit
	elseif evo.distSingle then
		evo.distSingle.Text = count .. " " .. unit
	end
end

-- Pre-shot icons: fill in your uploaded image asset ids ("rbxassetid://..."). "" leaves it as-is.
local CLUB_ICONS = { driver = "rbxassetid://80801183478260", wood = "rbxassetid://107835159837886", hybrid = "rbxassetid://132359343703407", iron = "rbxassetid://140328105074819", wedge = "rbxassetid://101014132912785", putter = "rbxassetid://107780614986900" }
local SHOTTYPE_ICONS = { approach = "rbxassetid://106752018009849", punch = "rbxassetid://86033431440377", chip = "rbxassetid://139045569886178"} -- keyed by shot type id (lowercase), e.g. ["approach"] = "rbxassetid://..."
local LIE_NAMES = {
	[0] = "Out of Bounds", [1] = "Tee", [2] = "Fairway", [3] = "Rough", [4] = "Green",
	[5] = "Bunker", [6] = "Water", [7] = "Cart Path", [8] = "Pine Straw",
}

local function clubCategory(clubName: string): string
	local n = string.lower(clubName)
	if string.find(n, "putt") then return "putter"
	elseif string.find(n, "driver") then return "driver"
	elseif string.find(n, "wood") then return "wood"
	elseif string.find(n, "hybrid") then return "hybrid"
	elseif string.find(n, "wedge") then return "wedge"
	elseif string.find(n, "iron") then return "iron" end
	return ""
end

-- Populate the pre-shot panel. info = { club, shotTypeId, shotTypeName, distance, units, surfaceId }
local function setPreShot(info)
	if not evo then return end
	if evo.psClubText then evo.psClubText.Text = info.club or "" end
	if evo.psClubIcon then
		local ic = CLUB_ICONS[clubCategory(info.club or "")]
		if ic and ic ~= "" then evo.psClubIcon.Image = ic end
	end
	if evo.psShotText then evo.psShotText.Text = info.shotTypeName or "" end
	if evo.psShotIcon then
		local ic = SHOTTYPE_ICONS[string.lower(info.shotTypeId or "")]
		if ic and ic ~= "" then evo.psShotIcon.Image = ic end
	end
	if evo.psDistCount then evo.psDistCount.Text = info.distance or "" end
	if evo.psDistUnits then evo.psDistUnits.Text = info.units or "" end
	if evo.psLie then evo.psLie.Text = LIE_NAMES[info.surfaceId] or "" end
end

-- Toggle which panel shows: PreShot while aiming, the shot-travelled Distance while a shot is
-- live. showPreShot=true -> PreShot on / Distance off; false -> the reverse.
local function setPreShotPhase(showPreShot: boolean)
	if not evo then return end
	if evo.preShotFrame then evo.preShotFrame.Visible = showPreShot end
	if evo.distFrame then evo.distFrame.Visible = not showPreShot end
end

-- HoleStatCard colors + categories.
local HSC_CURRENT = Color3.fromRGB(255, 255, 255)
local HSC_IDLE = Color3.fromRGB(81, 104, 122) -- #51687A
local HSC_EXTREME = Color3.fromRGB(12, 38, 55) -- #0C2637
local HSC_CATEGORIES = { "Condor", "AlbatrossOrBetter", "Eagle", "Birdie", "Par", "Bogey", "DoubleBogey", "TripleOrWorse" }
local HSC_LANG = {
	Condor = "CONDOR", AlbatrossOrBetter = "ALBATROSS", Eagle = "EAGLE", Birdie = "BIRDIE", Par = "PAR",
	Bogey = "BOGEY", DoubleBogey = "DOUBLE BOGEY", TripleOrWorse = "TRIPLE BOGEY",
}

local function hscCategory(rel: number): string
	if rel <= -4 then return "Condor"
	elseif rel <= -3 then return "AlbatrossOrBetter"
	elseif rel == -2 then return "Eagle"
	elseif rel == -1 then return "Birdie"
	elseif rel == 0 then return "Par"
	elseif rel == 1 then return "Bogey"
	elseif rel == 2 then return "DoubleBogey"
	else return "TripleOrWorse" end
end

-- Update the always-on per-hole shot tracker. info = { shot, par, hole, toParText }
-- shot = the shot number the player is currently on (strokes taken + 1).
local function setHoleStatCard(info)
	if not evo then return end
	local shot, par = info.shot, info.par
	local rel = shot - par
	local extreme = rel <= -3 or rel >= 3

	if evo.hscHoleNumber and evo.hscHoleNumber:IsA("TextLabel") then evo.hscHoleNumber.Text = tostring(info.hole) end
	if evo.hscScoreDiff and evo.hscScoreDiff:IsA("TextLabel") then evo.hscScoreDiff.Text = info.toParText or "" end
	if evo.hscLanguage and evo.hscLanguage:IsA("TextLabel") then
		evo.hscLanguage.Text = "FOR " .. (HSC_LANG[hscCategory(rel)] or "PAR")
	end

	-- number row: 1..par visible; exactly one highlighted (current shot, or After when over par)
	local numbers = evo.hscNumbers
	if numbers then
		for k = 1, 5 do
			local lbl = numbers:FindFirstChild(tostring(k))
			if lbl and lbl:IsA("TextLabel") then
				lbl.Visible = k <= par
				if k == shot and shot <= par then
					lbl.TextColor3 = if extreme then HSC_EXTREME else HSC_CURRENT
				else
					lbl.TextColor3 = HSC_IDLE
				end
			end
		end
		local after = numbers:FindFirstChild("After")
		if after and after:IsA("TextLabel") then
			if shot > par then
				after.Visible = true
				after.Text = tostring(shot)
				after.TextColor3 = if extreme then HSC_EXTREME else HSC_CURRENT
			else
				after.Visible = false
			end
		end
	end

	-- graphics behave like the number row: outer frames for this par's categories stay visible
	-- (retaining order/columns), and only the current shot's category shows its "Inner"; every
	-- other visible category hides its "Inner" -- an empty slot that keeps the alignment.
	local graphics = evo.hscGraphics
	if graphics then
		local cat = hscCategory(rel)
		local active = {} -- category names in play: shots 1..par, plus the current over-par one
		for k = 1, par do
			active[hscCategory(k - par)] = true
		end
		if shot > par then
			active[cat] = true
		end
		for _, frame in graphics:GetChildren() do
			if frame:IsA("GuiObject") then
				local isActive = active[frame.Name] == true
				frame.Visible = isActive
				local inner = frame:FindFirstChild("Inner")
				if inner then
					inner.Visible = isActive and frame.Name == cat
				end
			end
		end
	end
end

-- HoleStatCard entrance/exit tweens.
local function tweenHoleNumbersIn()
	setHoleNumbersDown(true, true, true)
end

local function tweenHoleNumbersOut()
	if not holeNumbersDown and not holeNumbersPendingTween then return end
	setHoleNumbersDown(false, true, false)
end

local function tweenShotLanguageIn()
	if shotLanguageDown and not shotLanguagePendingTween then return end
	setShotLanguageDown(true, true, true)
end

local function tweenShotLanguageOut()
	if not shotLanguageDown and not shotLanguagePendingTween then return end
	setShotLanguageDown(false, true, false)
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
Hud.setMainVisible = setMainVisible
Hud.fadeMainOut = fadeMainOut
Hud.snapHoleStatCardInvisible = snapHoleStatCardInvisible
Hud.fadeHoleStatCardIn = fadeHoleStatCardIn
Hud.playBlackScreenTransition = playBlackScreenTransition
Hud.setPowerLabel = setPowerLabel
Hud.showPowerLabel = showPowerLabel
Hud.setDownRing = setDownRing
Hud.resetSwingFeedback = resetSwingFeedback
Hud.slideStatsIn = slideStatsIn
Hud.slideStatsOut = slideStatsOut
Hud.setDistance = setDistance
Hud.setPreShot = setPreShot
Hud.setPreShotPhase = setPreShotPhase
Hud.setHoleStatCard = setHoleStatCard
Hud.tweenHoleNumbers = tweenHoleNumbersIn
Hud.tweenHoleNumbersIn = tweenHoleNumbersIn
Hud.tweenHoleNumbersOut = tweenHoleNumbersOut
Hud.tweenShotLanguage = tweenShotLanguageIn
Hud.tweenShotLanguageIn = tweenShotLanguageIn
Hud.tweenShotLanguageOut = tweenShotLanguageOut
Hud.postShotTransition = postShotTransition

return Hud
