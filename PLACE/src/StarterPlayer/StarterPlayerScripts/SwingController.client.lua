--!strict
-- SwingController  (LocalScript -> StarterPlayer/StarterPlayerScripts)
-- Re-implemented Live Pre-Shot Path Tracer for tuning alignment math vectors.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local Mods = ReplicatedStorage.Shared.Modules
local MouseSwingCapture = require(Mods.MouseSwingCapture)
local ShotModel = require(Mods.ShotModel)
local ShotShape = require(Mods.ShotShape)
local Ballistics = require(Mods.Ballistics)
local GroundResolver = require(Mods.GroundResolver)
local CourseLoader = require(Mods.CourseLoader)
local Difficulty = require(Mods.Difficulty)
local ShotTypes = require(Mods.ShotTypes)
local Clubs = require(Mods.Clubs)
local SwingConfig = require(Mods.SwingConfig)
local CourseData = require(Mods.CourseData)
local Tracers = require(Mods.TracerController)

-- ===== tunables =====
-- ===== course data =====
local HOLE_NAME = "georgia"       -- the baked hole to play
local SPAWN_XZ = Vector2.new(-1416.529, -31.367)  -- world (x, z) on the hole to start the ball -- SET THIS
local FALLBACK_SURFACE = 4         -- surface id used ONLY if GetTerrainData omits one (4 = green)
local COURSE_Y_OFFSET = 0           -- studs subtracted from raw world height; 0 = ball shares the mesh's native frame
local PIN_XZ = Vector2.new(0, 0)    -- world (x, z) of the cup on the green -- SET THIS
local PAR = 4                       -- par for this hole (for the scorecard print)
local AIM_RATE_DEG = 40
local SHAPE_RATE = 1.5
local CAM_BACK = 6
local CAM_HEIGHT = 4
local CAM_LOOKAHEAD = 60
local PLAYBACK_SPEED = 1
local FOLLOW_BACK = 22
local FOLLOW_HEIGHT = 8
local AIM_SMOOTH = 12
local TRACK_SMOOTH = 2
local CHASE_Y_SMOOTH = 4
local FLY_IN_TIME = 0.25
-- ====================

local BALL_RADIUS = 0.0762
local CUP_RADIUS = 0.1928 -- regulation cup, used for the visual flagstick

-- terrain() is the SINGLE sampler the flight, live preview, and bounce/roll all read.
-- CourseLoader.GetTerrainData(courseName, x, z) returns (height, normal, surfaceId) and requires CourseLoader.Load(courseName) first.
-- We use the RAW world height so the ball shares the imported mesh's frame (the data encodes native world heights).
-- COURSE_Y_OFFSET is an optional manual nudge only.
local courseOk, courseData = pcall(CourseLoader.Load, HOLE_NAME)
if not courseOk then
	warn(string.format(
		"[SwingController] CourseLoader.Load('%s') failed (%s) -- using flat ground. Check that "
			.. "ReplicatedStorage.CourseData.%s exists with Height/Surface modules and attributes.",
		HOLE_NAME, tostring(courseData), HOLE_NAME))
end
local useCourse = courseOk

local function rawTerrain(x: number, z: number): ({ height: number, normal: Vector3, surface: number })?
	local ok, height, normal, surface = pcall(CourseLoader.GetTerrainData, HOLE_NAME, x, z)
	if ok and typeof(height) == "number" then
		return {
			height = height,
			normal = if typeof(normal) == "Vector3" then normal else Vector3.yAxis,
			surface = if typeof(surface) == "number" then surface else FALLBACK_SURFACE,
		}
	end
	return nil
end

local function terrain(x: number, z: number)
	if useCourse then
		local data = rawTerrain(x, z)
		if data then
			return {
				height = data.height - COURSE_Y_OFFSET,
				normal = data.normal,
				surface = data.surface,
			}
		end
	end
	return { height = -COURSE_Y_OFFSET, normal = Vector3.yAxis, surface = 2 } -- flat fallback (fairway)
end

-- start the ball on the hole at the sampled ground height
local TEE = Vector3.new(SPAWN_XZ.X, terrain(SPAWN_XZ.X, SPAWN_XZ.Y).height + BALL_RADIUS, SPAWN_XZ.Y)

-- the cup: a world point on the green. The drop-in is decided by physics in GroundResolver;
-- this just places a visible flagstick + hole to aim at.
local cupCenter = Vector3.new(PIN_XZ.X, terrain(PIN_XZ.X, PIN_XZ.Y).height, PIN_XZ.Y)

local function buildPin(center: Vector3)
	local old = workspace:FindFirstChild("Pin")
	if old then old:Destroy() end
	local folder = Instance.new("Folder")
	folder.Name = "Pin"

	local function part(name, size, cf, color, material, shape)
		local p = Instance.new("Part")
		p.Name, p.Size, p.CFrame, p.Color, p.Material = name, size, cf, color, material
		p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
		if shape then p.Shape = shape end
		p.Parent = folder
		return p
	end

	local VERT = CFrame.Angles(0, 0, math.rad(90)) -- stand a Cylinder's axis up along Y
	part("Cup", Vector3.new(0.6, CUP_RADIUS * 2, CUP_RADIUS * 2),
		CFrame.new(center.X, center.Y - 0.3, center.Z) * VERT,
		Color3.fromRGB(15, 15, 15), Enum.Material.Slate, Enum.PartType.Cylinder)

	local POLE_H = 7.6
	part("Flagstick", Vector3.new(POLE_H, 0.08, 0.08),
		CFrame.new(center.X, center.Y + POLE_H / 2, center.Z) * VERT,
		Color3.fromRGB(235, 235, 235), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)

	part("Flag", Vector3.new(0.05, 0.7, 1.1),
		CFrame.new(center.X, center.Y + POLE_H - .35, center.Z-0.55),
		Color3.fromRGB(200, 40, 40), Enum.Material.Fabric)

	folder.Parent = workspace
end
buildPin(cupCenter)

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
camera.CameraType = Enum.CameraType.Scriptable
UserInputService.MouseIconEnabled = false

local function lockCharacter(char: Model)
	local hum = char:WaitForChild("Humanoid") :: Humanoid
	hum.WalkSpeed = 0
	hum.JumpHeight = 0
end
if player.Character then lockCharacter(player.Character) end
player.CharacterAdded:Connect(lockCharacter)

-- ball
local ball = Instance.new("Part")
ball.Shape = Enum.PartType.Ball
ball.Size = Vector3.one * (0.1524)
ball.Material = Enum.Material.SmoothPlastic
ball.Color = Color3.new(1, 1, 1)
ball.Anchored = true
ball.CanCollide = false
ball.Position = TEE
ball.Parent = workspace

-- HUD
local gui = Instance.new("ScreenGui")
gui.Name = "SwingHUD"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")
local label = Instance.new("TextLabel")
label.Size = UDim2.fromOffset(380, 48)
label.Position = UDim2.fromOffset(16, 16)
label.BackgroundColor3 = Color3.new(0, 0, 0)
label.BackgroundTransparency = 0.45
label.TextColor3 = Color3.new(1, 1, 1)
label.TextXAlignment = Enum.TextXAlignment.Left
label.TextYAlignment = Enum.TextYAlignment.Top
label.Font = Enum.Font.Code
label.TextSize = 16
label.Parent = gui

-- Dynamically compile and sort the club bag from the Clubs module
local clubOrder = {}
for _, item in pairs(Clubs) do
	if typeof(item) == "table" and item.fullSpeed and item.launchAngle then
		table.insert(clubOrder, item)
	end
end

-- Sort from highest ball speed (Driver) to lowest (Wedges), ensuring Putter is always last
table.sort(clubOrder, function(a, b)
	if a.name == "Putter" then return false end
	if b.name == "Putter" then return true end
	return a.fullSpeed > b.fullSpeed
end)
local currentClub = Clubs.Iron7
local ballPos = TEE
local strokes = 0
local aimYaw = 0
local shape = Vector2.zero
local busy = false
local forceSnapNextFrame = true
local lastPreviewSig: string? = nil -- preview cache: only re-sim when inputs change

-- Adornment Pool Settings
-- Adornment pool, tracers, and the yardage marker now live in TracerController;
-- the names below are aliased so every call site in this file stays unchanged.
local clearAdornments = Tracers.clear
local showDistanceMarker = Tracers.showDistance
local hideDistanceMarker = Tracers.hideDistance

-- Apply the active difficulty's forgiveness to a raw swing before it reaches the ball.
-- Easy tiers shrink accidental path/face/tempo error and lift mishit contact toward pure.
local function forgive(swing)
	local d = Difficulty.get()
	return {
		valid = swing.valid,
		power = swing.power,
		overswing = swing.overswing,
		backTime = swing.backTime,
		downTime = swing.downTime,
		tempo = (swing.tempo or 0) * (1 - d.tempoForgiveness),       -- rhythm
		path = (swing.path or 0) * (1 - d.pathForgiveness),          -- push/pull
		faceOffset = (swing.faceOffset or 0) * (1 - d.contactForgiveness), -- hook/slice
	}
end

-- Tracer renderers live in TracerController.
-- Live-preview passes `busy` through so the pre-shot line still hides itself mid-swing exactly as before.
local updateProgressiveTracer = Tracers.updateProgressive
local function updateLivePreviewTracer(points: {Vector3})
	Tracers.updateLivePreview(points, busy)
end

local function aimDirection(): Vector3
	return Vector3.new(math.sin(aimYaw), 0, math.cos(aimYaw))
end

local function addressTarget(): CFrame
	local aim = aimDirection()
	local currentBallPos = ball.Position
	local camPos = currentBallPos - aim * CAM_BACK + Vector3.new(0, CAM_HEIGHT, 0)
	return CFrame.lookAt(camPos, currentBallPos + aim * CAM_LOOKAHEAD)
end

local function updateCamera(dt: number)
	if forceSnapNextFrame then
		forceSnapNextFrame = false
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = addressTarget()
	else
		camera.CFrame = camera.CFrame:Lerp(addressTarget(), 1 - math.exp(-AIM_SMOOTH * dt))
	end
end

camera.CameraType = Enum.CameraType.Scriptable
camera.CFrame = addressTarget()

-- ===== course routing =====================================================
-- Optional 18-hole play driven by markers in workspace.CourseMarkers (see CourseData.luau).
-- Place a "Tee" and "Pin" Part per "HoleNN" Folder, an "Aim" folder of ordered Parts for the intended line, and a "Par" attribute.
-- If no markers exist, the controller falls back to the single-hole config (HOLE_NAME / SPAWN_XZ / PIN_XZ / PAR) unchanged.
local courseMarkers = workspace:FindFirstChild("CourseMarkers")
local holes = (courseMarkers and CourseData.load(courseMarkers)) or {}
local currentHole = 1
local pendingHole: number? = nil -- set on hole-out; consumed once the putt drops

-- Aim from the ball's current lie toward the next strategic point of the hole:
-- the fairway landing off the tee, advancing to the flag as you move up.
-- With no markers, aims straight at the cup.
local function aimAtTarget()
	local h = holes[currentHole]
	local ballXZ = Vector2.new(ballPos.X, ballPos.Z)
	local target = if h then CourseData.aimTarget(h, ballXZ) else Vector2.new(cupCenter.X, cupCenter.Z)
	local d = target - ballXZ
	if d.Magnitude > 0.01 then
		aimYaw = math.atan2(d.X, d.Y) -- d.Y is world Z; matches aimDirection()'s (sin, _, cos)
	end
end

-- Move the ball to hole n's tee (snapped to the baked surface), reposition the flag, and aim down the hole.
-- Returns false if hole n has no markers.
local function startHole(n: number): boolean
	local h = holes[n]
	if not h then return false end
	currentHole = n
	local tg = terrain(h.teeXZ.X, h.teeXZ.Y)
	TEE = Vector3.new(h.teeXZ.X, tg.height + BALL_RADIUS, h.teeXZ.Y)
	cupCenter = Vector3.new(h.pinXZ.X, terrain(h.pinXZ.X, h.pinXZ.Y).height, h.pinXZ.Y)
	buildPin(cupCenter)
	ball.Position = TEE
	ballPos = TEE
	strokes = 0
	shape = Vector2.zero
	aimAtTarget()
	forceSnapNextFrame = true
	lastPreviewSig = nil
	clearAdornments()
	camera.CFrame = addressTarget()
	return true
end

-- ===== shot type, distance dial, scout cam =====
local DIST_RATE = 0.1     -- distance-fraction change per second (W/S at address)
local POWER_MIN = 0.75     -- the power dial spans 75%..100% for EVERY shot type
local POWER_MAX = 1.0      -- shot type changes ball flight (launch/spin), never this range
local SCOUT_SPEED = 130    -- studs/s the scout cam dollies down the line (W/S in scout)
local SCOUT_MAX = 450      -- studs the scout cam can travel out
local SCOUT_BACK = 16
local SCOUT_HEIGHT = 14

local distanceFraction = 1.0
local shotTypeIndex = 2    -- default "Approach"
local scoutMode = false
local scoutDistance = 60

local function currentShotType()
	return ShotTypes.Order[shotTypeIndex]
end

-- ===== EvoSwing HUD (rendering extracted to HudController) =====
-- These three stay controller-side: the tilt scale and the swing-quality tolerances are swing logic, and `swinging` is shared state read across input/playback.
local MAX_SWING_TILT_DEG = 15 -- swing-path tilt at full draw/fade
local swinging = false
local POWER_TOL = 0.10 -- backswing: |fill - desired| under this is good
local OVER_TOL = 0.15  -- ...and overswing under this
local TEMPO_TOL = 0.30 -- downswing: |tempo| under this is good
local PATH_TOL = 0.30  -- club path: |path| under this is good
local FACE_TOL = 0.30  -- contact: |face| under this is good

local Hud = require(Mods.HudController)
Hud.init()
local setPowerRing = Hud.setPowerRing
local setShapeAngle = Hud.setShapeAngle
local setMeterVisible = Hud.setMeterVisible
local showPowerLabel = Hud.showPowerLabel
local setDownRing = Hud.setDownRing
local resetSwingFeedback = Hud.resetSwingFeedback
local slideStatsOut = Hud.slideStatsOut
local slideStatsIn = Hud.slideStatsIn
local postShotTransition = Hud.postShotTransition
-- setPowerLabel and the power-target guide both read the live distance dial:
local function setPowerLabel() Hud.setPowerLabel(distanceFraction) end
local function setPowerTarget() Hud.setPowerTarget(distanceFraction) end

local capture = MouseSwingCapture.new()
capture.sensitivity = Difficulty.get().swingSensitivity
local diffIndex = table.find(Difficulty.Order, "Pro") or 3

-- ===== PUTTING (2K-style: power dial -> roll distance) =====
-- The putt power dial spans PUTT_MIN_POWER..100%. Launch speed is LINEAR in power, so roll
-- distance is ~QUADRATIC: 100% rolls PUTT_MAX_FT on flat, ~10% rolls ~1 ft, ~3% is a sub-inch
-- tap. The reticle shows where a perfectly filled putt at the current dial stops on flat; the
-- player reads slope and adjusts. Green roll is pulled from GroundResolver so retuning it there
-- can't desync the putt power -- V_MAX and the reticle rederive from those constants every time.
local STUDS_PER_FT = 0.3048 / 0.28        -- 1 ft in studs (world scale: 1 stud = 0.28 m)
local PUTT_MAX_FT = 100                    -- flat distance a 100% putt rolls (the longest stroke)
local PUTT_MIN_POWER = 0.03               -- dial floor (~1 in tap); below ~2.6% the ball won't move
local PUTT_DIST_RATE = 0.35               -- power-dial change per second (W/S while putting)
local PUTT_FACE_DEG = 4.0                  -- launch-angle (deg) per unit face miss -> line skill
local PUTT_PATH_DEG = 1.0                  -- launch-angle (deg) per unit path miss
local PUTT_DECEL = GroundResolver.SURF[4].rollDecel  -- studs/s^2 on the green (surface id 4)
local PUTT_REST = GroundResolver.REST_SPEED          -- studs/s the ball rests below

local function isPutt(): boolean
	return currentClub.name == "Putter"
end

-- launch speed (studs/s) that rolls `distStuds` on flat green: inverse of the roll integrator
local function speedForDistance(distStuds: number): number
	return math.sqrt(2 * PUTT_DECEL * distStuds + PUTT_REST * PUTT_REST)
end
local PUTT_V_MAX = speedForDistance(PUTT_MAX_FT * STUDS_PER_FT) -- the 100%-power launch speed

-- flat distance (ft) a perfectly-filled putt at dial fraction p rolls. v0 = p * V_MAX (linear),
-- so distance is ~p^2 * PUTT_MAX_FT (the rest-speed cutoff trims the very low end).
local function puttReachFt(p: number): number
	local v0 = p * PUTT_V_MAX
	local d = (v0 * v0 - PUTT_REST * PUTT_REST) / (2 * PUTT_DECEL)
	return math.max(0, d) / STUDS_PER_FT
end

-- Putter swings on the calmer 1:1 putting tempo + finer sensitivity; everything else 3:1.
local function applySwingProfile()
	if currentClub.name == "Putter" then
		capture._config.IdealTempoRatio = SwingConfig.Putting.IdealTempoRatio
		capture._config.MousePixelsPerUnit = SwingConfig.Putting.MousePixelsPerUnit
	else
		capture._config.IdealTempoRatio = SwingConfig.IdealTempoRatio
		capture._config.MousePixelsPerUnit = SwingConfig.MousePixelsPerUnit
	end
end

applySwingProfile()

local function updateHUD()
	if isPutt() then
		local ft = puttReachFt(distanceFraction)
		local val, unit = ft, "ft"
		if ft < 1 then val, unit = ft * 12, "in" end
		label.Text = string.format("Club: Putter\nAim: %d %s  (%d%%)", math.floor(val + 0.5), unit, math.floor(distanceFraction * 100 + 0.5))
	else
		label.Text = string.format(
			"Club: %s   Shot: %s\nDist: %d%%   Shape: %s",
			currentClub.name, currentShotType().name,
			math.floor(distanceFraction * 100 + 0.5), ShotShape.describe(shape.X, shape.Y)
		)
	end
end

local function updateAimAndInput(dt: number)
	if busy then return end

	if scoutMode then
		local aim = aimDirection()
		if UserInputService:IsKeyDown(Enum.KeyCode.W) then scoutDistance += SCOUT_SPEED * dt end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) then scoutDistance -= SCOUT_SPEED * dt end
		scoutDistance = math.clamp(scoutDistance, 10, SCOUT_MAX)
		if UserInputService:IsKeyDown(Enum.KeyCode.A) then aimYaw -= math.rad(AIM_RATE_DEG) * dt end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) then aimYaw += math.rad(AIM_RATE_DEG) * dt end
		local f = ball.Position + aim * scoutDistance
		local focus = Vector3.new(f.X, terrain(f.X, f.Z).height, f.Z)
		camera.CFrame = CFrame.lookAt(focus - aim * SCOUT_BACK + Vector3.new(0, SCOUT_HEIGHT, 0), focus + aim * 25)
		setMeterVisible(false)
		updateHUD()
		return
	end

	local shapeChanged = false
	if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then
		local r = SHAPE_RATE * dt
		local x, y = shape.X, shape.Y
		local oldX = x
		if UserInputService:IsKeyDown(Enum.KeyCode.A) then x -= r end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) then x += r end
		if UserInputService:IsKeyDown(Enum.KeyCode.W) then y += r end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) then y -= r end
		shape = Vector2.new(math.clamp(x, -1, 1), math.clamp(y, -1, 1))
		if math.abs(oldX - x) > 0.001 then shapeChanged = true end
	else
		if UserInputService:IsKeyDown(Enum.KeyCode.A) then aimYaw -= math.rad(AIM_RATE_DEG) * dt end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) then aimYaw += math.rad(AIM_RATE_DEG) * dt end
		if isPutt() then
			-- putting: W/S dial the power 3%..100% (the reticle distance follows the quadratic curve)
			if UserInputService:IsKeyDown(Enum.KeyCode.W) then distanceFraction = math.min(1.0, distanceFraction + PUTT_DIST_RATE * dt) end
			if UserInputService:IsKeyDown(Enum.KeyCode.S) then distanceFraction = math.max(PUTT_MIN_POWER, distanceFraction - PUTT_DIST_RATE * dt) end
		else
			-- power dial is the same 75%..100% on every shot type; the type only changes flight
			if UserInputService:IsKeyDown(Enum.KeyCode.W) then distanceFraction = math.min(POWER_MAX, distanceFraction + DIST_RATE * dt) end
			if UserInputService:IsKeyDown(Enum.KeyCode.S) then distanceFraction = math.max(POWER_MIN, distanceFraction - DIST_RATE * dt) end
		end
	end

	-- Swing Bias: only Pro+ requires the angled swing path. On lower tiers the swing is strictly vertical and the dialed shape still applies to the ball automatically.
	local tiltDeg = Difficulty.get().swingBias and (shape.X * MAX_SWING_TILT_DEG) or 0
	capture.swingTilt = math.rad(tiltDeg)
	setShapeAngle(tiltDeg)
	setMeterVisible(Difficulty.get().swingMeter)
	setPowerLabel()
	setPowerTarget() -- guide ring sits at the dialed power so you can see where to stop
	capture.targetFraction = distanceFraction -- the fill reaches this dialed power in FullBackswingTime
	if not swinging then
		setPowerRing(0)
		resetSwingFeedback()
		showPowerLabel(true)
	end

	updateCamera(dt)
	updateHUD()

	-- Real-time path preview. Only re-simulate when an input actually changes;
	-- when lined up and still this does zero flight sims per frame.
	local bp = ball.Position
	local sig = string.format(
		"%.4f|%.3f|%.3f|%s|%.2f|%.2f|%.2f|%s|%.3f|%d",
		aimYaw, shape.X, shape.Y, currentClub.name, bp.X, bp.Y, bp.Z, Difficulty.get().name,
		distanceFraction, shotTypeIndex
	)
	if sig ~= lastPreviewSig then
		lastPreviewSig = sig
		if isPutt() then
			local ft = puttReachFt(distanceFraction)
			local rp = ball.Position + aimDirection() * (ft * STUDS_PER_FT)
			rp = Vector3.new(rp.X, terrain(rp.X, rp.Z).height + 0.05, rp.Z)
			if Difficulty.get().preShotPath then
				updateLivePreviewTracer({ ball.Position, rp })
				local val, unit = ft, "FT"
				if ft < 1 then val, unit = ft * 12, "IN" end
				showDistanceMarker(rp, val, unit)
			else
				clearAdornments()
				hideDistanceMarker()
			end
			return
		end

		local previewSwing = {
			valid = true,
			power = 1.0,
			tempo = 0.0, -- perfect rhythm: preview shows the full dialed distance
			overswing = 0.0,
			contact = 1.0,
			path = 0.0,
			faceOffset = 0.0,
		}

		local st = currentShotType()
		-- DYNAMIC CHANGE: Fetch PGA 2K25 integrated physics multipliers via the profile table
		local profile = ShotModel.getProfile(st.name)

		local previewLaunch = ShotModel.resolve(previewSwing, currentClub, {
			aimDirection = aimDirection(),
			position = bp,
			lie = "fairway",
			shape = shape,
			seed = 0,
			powerScale = distanceFraction,
			speedMult = profile.speedMult,
			launchAdd = profile.launchAdd,
			spinMult = profile.spinMult,
		})

		local pathPoints = Ballistics.getProjectionPath(previewLaunch, {
			groundHeight = function(x, z) return terrain(x, z).height end,
		}, 12)

		local diff = Difficulty.get()
		if diff.preShotPath then
			updateLivePreviewTracer(pathPoints)
			if diff.distanceMarker and #pathPoints > 1 then
				local landing = pathPoints[#pathPoints]
				local carryYd = Ballistics.studsToYards(
					(Vector3.new(landing.X, 0, landing.Z) - Vector3.new(bp.X, 0, bp.Z)).Magnitude)
				showDistanceMarker(landing, carryYd)
			else
				hideDistanceMarker()
			end
		else
			clearAdornments()
			hideDistanceMarker()
		end
	end
end

RunService:BindToRenderStep("GolfCameraAim", Enum.RenderPriority.Camera.Value, updateAimAndInput)

local function playback(path: Ballistics.Path)
	busy = true
	RunService:UnbindFromRenderStep("GolfCameraAim")
	clearAdornments()

	local apexIndex, apexY = 1, -math.huge
	for idx, smp in path do
		if smp.pos.Y > apexY then
			apexY = smp.pos.Y
			apexIndex = idx
		end
	end

	local initialAim = aimDirection()
	local startBallPos = ball.Position
	local fixedCamPos = startBallPos - initialAim * CAM_BACK + Vector3.new(0, CAM_HEIGHT, 0)
	local lookTarget = startBallPos + initialAim * CAM_LOOKAHEAD

	local descending, flyClock, anchorY = false, 0, 0
	local chaseDir = initialAim
	local apexCamCF = camera.CFrame

	local clock, i = 0, 1

	local function updatePlaybackLoop(frameDt: number)
		clock += frameDt * PLAYBACK_SPEED
		while i < #path and path[i + 1].t <= clock do
			i += 1
		end
		local atEnd = i >= #path

		local ballNow: Vector3
		if atEnd then
			ballNow = path[#path].pos
		else
			local a, b = path[i], path[i + 1]
			local span = b.t - a.t
			local f = if span > 0 then math.clamp((clock - a.t) / span, 0, 1) else 0
			local sf = f * f * (3 - 2 * f)
			ballNow = a.pos:Lerp(b.pos, sf)
		end

		ball.Position = ballNow

		if i <= apexIndex then
			-- ASCENT VIEW
			lookTarget = lookTarget:Lerp(ballNow, 1 - math.exp(-TRACK_SMOOTH * frameDt))
			camera.CFrame = CFrame.lookAt(fixedCamPos, lookTarget)
			updateProgressiveTracer(path, i)
		else
			-- DESCENT VIEW (Fly/Chase view cuts in)
			if not descending then
				descending = true
				flyClock = 0
				anchorY = ballNow.Y
				apexCamCF = camera.CFrame
				local net = path[#path].pos - startBallPos
				local h = Vector3.new(net.X, 0, net.Z)
				chaseDir = if h.Magnitude > 1 then h.Unit else initialAim

				clearAdornments() -- Instantly drop tracer on camera shift
			end

			flyClock += frameDt
			anchorY += (ballNow.Y - anchorY) * (1 - math.exp(-CHASE_Y_SMOOTH * frameDt))

			local anchor = Vector3.new(ballNow.X, anchorY, ballNow.Z)
			local targetCamPos = anchor - chaseDir * FOLLOW_BACK + Vector3.new(0, FOLLOW_HEIGHT, 0)

			local lookOffset = chaseDir * CAM_LOOKAHEAD
			local horizonLookTarget = ballNow + Vector3.new(lookOffset.X, CAM_HEIGHT * 0.5, lookOffset.Z)

			local blendFactor = math.clamp((clock - path[apexIndex].t) / 2, 0, 1)
			local dynamicLookTarget = ballNow:Lerp(horizonLookTarget, blendFactor)

			local chaseCF = CFrame.lookAt(targetCamPos, dynamicLookTarget)

			if flyClock < FLY_IN_TIME then
				local u = flyClock / FLY_IN_TIME
				local factor = u * u
				camera.CFrame = apexCamCF:Lerp(chaseCF, factor)
			else
				camera.CFrame = chaseCF
			end
		end

		if atEnd then
			RunService:UnbindFromRenderStep("GolfCameraTrack")
			clearAdornments()

			local endPos = path[#path].pos
			ball.Position = endPos
			ballPos = endPos

			-- next lie: if the putt just dropped, cut to the next tee; otherwise re-aim from where the ball rests toward the next point of this hole.
			if pendingHole then
				local nxt = pendingHole; pendingHole = nil
				if not startHole(nxt) and not startHole(1) then aimAtTarget() end
			else
				aimAtTarget()
			end

			camera.CameraType = Enum.CameraType.Scriptable
			camera.CFrame = addressTarget()
			forceSnapNextFrame = true

			task.defer(function()
				camera.CameraType = Enum.CameraType.Scriptable
				camera.CFrame = addressTarget()
				busy = false
				postShotTransition() -- shot is done: dissolve HUD, then curtain-cut to next shot
				RunService:BindToRenderStep("GolfCameraAim", Enum.RenderPriority.Camera.Value, updateAimAndInput)
			end)
		end
	end

	RunService:BindToRenderStep("GolfCameraTrack", Enum.RenderPriority.Camera.Value, updatePlaybackLoop)
end

capture.onUpdated = function(state)
	if not swinging then
		swinging = true
		slideStatsOut() -- hide last shot's stats as the new swing begins
	end
	showPowerLabel(false)
	setPowerRing(state.power) -- frozen at committed power once past the top
	-- the downswing ring picks up where the power ring stopped and shrinks toward 0.25;
	-- it freezes wherever it is at impact (stops short on a rushed downswing)
	if state.committedPower > 0 then
		setDownRing(state.committedPower + (0.25 - state.committedPower) * state.downProgress)
	else
		setDownRing(0)
	end
end

local function scoreTerm(rel: number): string
	local names = {
		[-3] = "albatross", [-2] = "eagle", [-1] = "birdie",
		[0] = "par", [1] = "bogey", [2] = "double bogey", [3] = "triple bogey",
	}
	return names[rel] or string.format("%+d", rel)
end

capture.onCompleted = function(swing)
	if busy or not swing.valid then
		return
	end

	strokes += 1
	hideDistanceMarker()
	swinging = false

	-- Forgive FIRST: the cards/colours reflect the FORGIVEN swing -- exactly what the ball does.
	-- On Legend (zero forgiveness) the card equals your raw swing 1:1; easier tiers iron out the error, so the card shows the smaller, assisted miss the ball actually flies.
	local fSwing = forgive(swing)

	local backGood = math.abs(fSwing.power - distanceFraction) < POWER_TOL and fSwing.overswing < OVER_TOL
	local downGood = math.abs(fSwing.tempo) < TEMPO_TOL
	local pathGood = math.abs(fSwing.path) < PATH_TOL
	local faceGood = math.abs(fSwing.faceOffset) < FACE_TOL
	Hud.showSwingResult(fSwing, distanceFraction, backGood, downGood, pathGood, faceGood)
	task.delay(0.5, function()
		if busy and not swinging then slideStatsIn() end -- reveal only while the ball is in flight
	end)

	local flightPath, restInfo
	if isPutt() then
		-- PUTTING: roll-only. Launch speed is LINEAR in the filled power (v0 = power * V_MAX), so
		-- roll distance is ~quadratic -- a flushed 100% putt rolls PUTT_MAX_FT, a mistimed one short.
		-- Slope is handled by GroundResolver, so reading the green is the player's job.
		local v0 = math.max(fSwing.power, 0) * PUTT_V_MAX
		local startDeg = (fSwing.faceOffset or 0) * PUTT_FACE_DEG + (fSwing.path or 0) * PUTT_PATH_DEG
		local dir = CFrame.fromAxisAngle(Vector3.yAxis, math.rad(startDeg)) * aimDirection()
		local landing = { position = ball.Position, velocity = dir * v0, spin = Vector3.zero, time = 0 }
		flightPath = {}
		local groundPath, ri = GroundResolver.resolve(landing, terrain, { cup = { center = cupCenter } })
		for _, smp in groundPath do flightPath[#flightPath + 1] = smp end
		restInfo = ri
	else
		local st = currentShotType()
		-- DYNAMIC CHANGE: Fetch PGA 2K25 integrated physics multipliers via the profile table
		local profile = ShotModel.getProfile(st.name)

		local launch = ShotModel.resolve(fSwing, currentClub, {
			aimDirection = aimDirection(),
			position = ball.Position,
			lie = "fairway",
			shape = shape,
			seed = math.floor(os.clock() * 1000),
			powerScale = 1.0, -- swing.power already encodes the filled power; dial is the target guide
			speedMult = profile.speedMult,
			launchAdd = profile.launchAdd,
			spinMult = profile.spinMult,
		})

		local fp, result = Ballistics.simulate(launch, {
			groundHeight = function(x, z) return terrain(x, z).height end,
		})

		local groundPath, ri = GroundResolver.resolve(result, terrain, { cup = { center = cupCenter } })
		for _, smp in groundPath do fp[#fp + 1] = smp end
		flightPath, restInfo = fp, ri
	end

	if restInfo.holed then
		local par = (holes[currentHole] and holes[currentHole].par) or PAR
		print(string.format("HOLED OUT in %d (par %d) -- %s.",
			strokes, par, scoreTerm(strokes - par)))
		strokes = 0
		pendingHole = currentHole + 1 -- consumed when the ball finishes dropping
	elseif restInfo.water then
		print("In the water.")
	elseif restInfo.outOfBounds then
		print("Out of bounds.")
	end

	playback(flightPath)
end

capture.onCancelled = function() setPowerRing(0) resetSwingFeedback() swinging = false end
capture:Arm()

UserInputService.InputBegan:Connect(function(input: InputObject, gpe: boolean)
	if gpe then return end
	local kc = input.KeyCode

	-- Handle Club Selection Exclusively via Q and E Cycling
	local clubChanged = false
	if kc == Enum.KeyCode.Q or kc == Enum.KeyCode.E then
		-- Find current club index in our dynamic array
		local currentClubIdx = table.find(clubOrder, currentClub) or 7 -- Fallback to mid-bag default if untracked

		if kc == Enum.KeyCode.E then
			-- Cycle Next
			currentClubIdx = (currentClubIdx % #clubOrder) + 1
		elseif kc == Enum.KeyCode.Q then
			-- Cycle Previous
			currentClubIdx = currentClubIdx - 1
			if currentClubIdx < 1 then
				currentClubIdx = #clubOrder
			end
		end

		currentClub = clubOrder[currentClubIdx]
		clubChanged = true
	end

	if clubChanged then
		-- AUTO-CORRECT ILLEGAL STATES: Prevent long clubs from using short-game stances
		local clubName = currentClub.name:lower()
		local currentTypeID = currentShotType().id:lower()

		-- Robust short-game filter matching P-Wedge, 50, 56, 60, and general wedges
		local isWedge = string.find(clubName, "wedge") 
			or string.find(clubName, "50") 
			or string.find(clubName, "56") 
			or string.find(clubName, "60") 
			or string.find(clubName, "p wedge")

		if not isWedge and (currentTypeID == "pitch" or currentTypeID == "flop" or currentTypeID == "chip" or currentTypeID == "splash") then
			-- Force reset long clubs back to standard baseline approach
			for idx, shotTypeData in ipairs(ShotTypes.Order) do
				if shotTypeData.id == "approach" then
					shotTypeIndex = idx
					break
				end
			end
		end

		-- Snap distance fraction back to the active stance's default percentage
		distanceFraction = currentShotType().defaultFrac
		applySwingProfile() -- putter swaps to 1:1 putting tempo; other clubs back to 3:1
		if currentClub.name == "Putter" then
			-- seed the power dial to the stroke that reaches the cup (player then adjusts for slope)
			local flat = Vector3.new(ball.Position.X, 0, ball.Position.Z)
			local cupFlat = Vector3.new(cupCenter.X, 0, cupCenter.Z)
			local cupFt = (cupFlat - flat).Magnitude / STUDS_PER_FT
			distanceFraction = math.clamp(math.sqrt(math.min(cupFt, PUTT_MAX_FT) / PUTT_MAX_FT), PUTT_MIN_POWER, 1.0)
		end

		lastPreviewSig = nil -- Force a visual update of the path tracer line
		print("Selected Club: " .. currentClub.name .. " | Active Shot Stance: " .. currentShotType().name)

	elseif kc == Enum.KeyCode.Z or kc == Enum.KeyCode.X then
		-- 1) Determine allowed shot IDs based on the club name string matching rules
		local clubName = currentClub.name:lower()
		local allowedIDs: {string} = {}

		local isWedge = string.find(clubName, "wedge") 
			or string.find(clubName, "50") 
			or string.find(clubName, "56") 
			or string.find(clubName, "60") 
			or string.find(clubName, "p wedge")

		if isWedge then
			-- Wedges get short game tools: Approach, Pitch, Flop, and Chip
			allowedIDs = { "approach", "pitch", "flop", "chip" }
		else
			-- Driver down to 9i get long/mid distance options: Approach and Punch only
			allowedIDs = { "approach", "punch" }
		end

		-- 2) Find our current stance position in the allowed list using IDs
		local currentTypeID = currentShotType().id:lower()
		local allowedIndex = table.find(allowedIDs, currentTypeID) or 1

		-- 3) Cycle forward on X, backward on Z
		local nextAllowedIndex = allowedIndex
		if kc == Enum.KeyCode.X then
			nextAllowedIndex = (allowedIndex % #allowedIDs) + 1
		elseif kc == Enum.KeyCode.Z then
			nextAllowedIndex = allowedIndex - 1
			if nextAllowedIndex < 1 then
				nextAllowedIndex = #allowedIDs
			end
		end

		local targetTypeID = allowedIDs[nextAllowedIndex]

		-- 4) Match against ShotTypes.Order IDs to update the master state index
		local foundMatch = false
		for idx, shotTypeData in ipairs(ShotTypes.Order) do
			if shotTypeData.id:lower() == targetTypeID then
				shotTypeIndex = idx
				foundMatch = true
				break
			end
		end

		if not foundMatch then
			shotTypeIndex = 2 
		end

		-- 5) PGA TOUR 2K25 RESET: Snap the distance dial to the new stance's default fraction
		local activeStance = currentShotType()
		distanceFraction = activeStance.defaultFrac

		lastPreviewSig = nil -- Flushes path tracer cache to re-simulate mechanics instantly
		print("Shot type changed to: " .. activeStance.name .. " (Range: " .. tostring(activeStance.minFrac*100) .. "% - " .. tostring(activeStance.maxFrac*100) .. "%)")

	elseif kc == Enum.KeyCode.C then
		scoutMode = not scoutMode
		if scoutMode then
			scoutDistance = 60
			capture:Disarm()
			clearAdornments()
			print("Scout cam ON -- W/S dolly, A/D aim, C to return")
		else
			capture:Arm()
			forceSnapNextFrame = true
			lastPreviewSig = nil
			print("Scout cam OFF")
		end
	elseif kc == Enum.KeyCode.T then
		diffIndex = (diffIndex % #Difficulty.Order) + 1
		Difficulty.set(Difficulty.Order[diffIndex])
		capture.sensitivity = Difficulty.get().swingSensitivity
		lastPreviewSig = nil 
		local d = Difficulty.get()
		print(string.format("Difficulty: %s (%.2fx, Swing Bias %s)", d.name, d.scoreMultiplier, d.swingBias and "ON" or "OFF"))
	elseif kc == Enum.KeyCode.R then
		if not startHole(currentHole) then
			ball.Position = TEE
			ballPos = TEE
			strokes = 0
			shape = Vector2.zero
			aimAtTarget()
			forceSnapNextFrame = true
			lastPreviewSig = nil
			camera.CFrame = addressTarget()
			clearAdornments()
		end
	end
end)

-- begin play: hole 1 if the course is marked, otherwise aim the single hole at its cup
if not startHole(1) then
	aimAtTarget()
	forceSnapNextFrame = true
	camera.CFrame = addressTarget()
end

print(string.format("Ready -- A/D aim, W/S distance, Shift+WASD shape, LMB swing. 1-5 club, G shot type, C scout, T difficulty (%s), R reset.", Difficulty.get().name))