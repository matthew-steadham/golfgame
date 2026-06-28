--!strict
-- ShotModel.luau
-- Bridges a SwingInput + Club + dialed shape into a Ballistics.Launch.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Ballistics = require(ReplicatedStorage.Shared.Modules.Ballistics)

export type SwingInput = {
	power: number?, overswing: number?, tempo: number?,
	path: number?, faceOffset: number?, contact: number?, valid: boolean,
}

export type Club = {
	name: string, fullSpeed: number, launchAngle: number, backspin: number,
}

export type ShotOpts = {
	aimDirection: Vector3,
	position: Vector3,
	lie: string?,
	shape: Vector2?,
	seed: number?,
	isTracerPreview: boolean?,
	powerScale: number?, -- dialed distance as a fraction of full (W/S)
	speedMult: number?,  -- PGA 2K25 Shift: Enforces the shot-type power ceilings
	launchAdd: number?,  -- shot-type launch-angle offset (deg)
	spinMult: number?,   -- shot-type backspin multiplier
}

export type ShotProfile = {
	speedMult: number,
	launchAdd: number,
	spinMult: number,
}

local RPM_TO_RADS = 2 * math.pi / 60
local MPH = Ballistics.MPH_TO_STUDS

local CFG = {
	OVERSWING_BONUS       = 0.04,  
	RHYTHM_POWER_PENALTY  = 0.20,  
	PATH_START_DEG        = 8.0,   
	FACE_ANGLE_MAX        = 14.0,  
	SHAPE_SIDESPIN_FACTOR = 0.18,  
	SHAPE_SPIN_PCT        = 0.30,  
}

local LIE = {
	tee     = { speed = 1.00, spin = 1.00, launch = 0.0 },
	fairway = { speed = 1.00, spin = 1.00, launch = 0.0 },
	rough   = { speed = 0.92, spin = 0.60, launch = 1.5 },
	bunker  = { speed = 0.75, spin = 0.85, launch = 2.0 },
}

-- Centralized PGA Tour 2K25 Profile Database
local SHOT_PROFILES: { [string]: ShotProfile } = {
	Normal = { speedMult = 1.00, launchAdd = 0.0,  spinMult = 1.00 },
	Punch  = { speedMult = 0.85, launchAdd = -6.0, spinMult = 0.55 }, 
	Pitch  = { speedMult = 0.65, launchAdd = 3.0,  spinMult = 1.25 }, 
	Flop   = { speedMult = 0.48, launchAdd = 15.0, spinMult = 1.40 }, 
	Chip   = { speedMult = 0.35, launchAdd = -4.0, spinMult = 0.30 }, -- Tuned down for real 2K short-game compression
	Splash = { speedMult = 0.55, launchAdd = 6.0,  spinMult = 1.15 }, 
}

local ShotModel = {}
ShotModel.CFG = CFG

local function baselineTerrain(_x: number, _z: number): number
	return 0
end

-- Safely retrieves a profile with a fallback to "Normal"
function ShotModel.getProfile(shotType: string): ShotProfile
	return SHOT_PROFILES[shotType] or SHOT_PROFILES.Normal
end

function ShotModel.resolve(swing: SwingInput, club: Club, opts: ShotOpts): Ballistics.Launch
	local lie = LIE[opts.lie or "fairway"] or LIE.fairway
	local swPower = swing.power or 1.0
	local swOverswing = swing.overswing or 0.0
	local swRhythm = swing.tempo or 0.0      
	local swPath = swing.path or 0.0         
	local swFace = swing.faceOffset or 0.0   

	local powerScale = opts.powerScale or 1.0
	local speedMult = opts.speedMult or 1.0   
	local launchAdd = opts.launchAdd or 0.0
	local spinMult = opts.spinMult or 1.0

	-- 1) DISTANCE & SPEED MODEL
	local rhythmMod = 1 - CFG.RHYTHM_POWER_PENALTY * math.clamp(math.abs(swRhythm), 0, 1)
	local speedMph = club.fullSpeed
		* swPower
		* rhythmMod
		* (1 + swOverswing * CFG.OVERSWING_BONUS)
		* lie.speed
		* powerScale
		* speedMult

	-- 2) LAUNCH GEOMETRY
	local launchDeg = club.launchAngle + lie.launch + launchAdd
	local shape = opts.shape or Vector2.zero

	-- 3) SPIN VECTOR DYNAMICS
	local baselineSpin = club.backspin 
		* lie.spin 
		* spinMult 
		* (1 - shape.Y * CFG.SHAPE_SPIN_PCT)

	local faceTiltRad = math.rad(swFace * CFG.FACE_ANGLE_MAX)
	local backspinRpm = baselineSpin * math.cos(faceTiltRad)
	local swingSidespinRpm = baselineSpin * math.sin(faceTiltRad)

	local intentionalSidespinRpm = shape.X * baselineSpin * CFG.SHAPE_SIDESPIN_FACTOR

	local baseAim = Vector3.new(opts.aimDirection.X, 0, opts.aimDirection.Z).Unit
	local sideAxis = Vector3.new(baseAim.Z, 0, -baseAim.X)

	-- 4) LOOKAHEAD + CORRECTION
	local shapeCorrectionDeg = 0
	if math.abs(intentionalSidespinRpm) > 1e-3 then
		local lookaheadLaunch = Ballistics.makeLaunch({
			position = opts.position,
			aimDirection = baseAim,
			ballSpeed = speedMph * MPH,
			launchAngleDeg = launchDeg,
			backspin = backspinRpm * RPM_TO_RADS,
			sidespin = intentionalSidespinRpm * RPM_TO_RADS,
		})
		local lookaheadPath = Ballistics.simulate(lookaheadLaunch, { groundHeight = baselineTerrain })
		local travel = lookaheadPath[#lookaheadPath].pos - opts.position
		local forwardDistance = travel:Dot(baseAim)
		local lateralDrift = travel:Dot(sideAxis)
		if forwardDistance > 10 and math.abs(lateralDrift) > 0.1 then
			shapeCorrectionDeg = -math.deg(math.atan2(lateralDrift, forwardDistance))
		end
	end

	-- 5) SWING PATH (backswing) -> START DIRECTION
	local swingStartDeg = swPath * CFG.PATH_START_DEG

	-- 6) FINAL ASSEMBLY
	local finalSidespinRpm = intentionalSidespinRpm + swingSidespinRpm
	local startDeg = shapeCorrectionDeg + swingStartDeg
	local finalSpeedStuds = speedMph * MPH

	local aimed = CFrame.fromAxisAngle(Vector3.yAxis, math.rad(startDeg)) * baseAim

	return Ballistics.makeLaunch({
		position = opts.position,
		aimDirection = aimed,
		ballSpeed = finalSpeedStuds,
		launchAngleDeg = launchDeg,
		backspin = backspinRpm * RPM_TO_RADS,
		sidespin = finalSidespinRpm * RPM_TO_RADS,
	})
end

return ShotModel