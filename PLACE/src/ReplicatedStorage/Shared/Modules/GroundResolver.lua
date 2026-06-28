--!strict
-- GroundResolver
-- Simulates the ball from its landing (Ballistics.Result) through bounce + roll to
-- rest, using the terrain's height, slope normal, and Surface ID. Deterministic and
-- fixed-step, so the server can revalidate. Returns a path that continues seamlessly
-- from the flight (same {t,pos,vel} samples) plus where and on what it came to rest.
--
-- Place under ReplicatedStorage/Shared/Modules.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Ballistics = require(ReplicatedStorage.Shared.Modules.Ballistics)

export type TerrainSample = { height: number, normal: Vector3, surface: number }
export type TerrainFn = (x: number, z: number) -> TerrainSample

export type RestResult = {
	position: Vector3,
	surface: number,
	water: boolean,
	outOfBounds: boolean,
	rollStuds: number,
	time: number,
	holed: boolean,
}

local BALL_RADIUS = 0.0762
local G = Ballistics.CFG.G
local DT = 1 / 240
local UP = Vector3.yAxis

-- surface physics by Surface ID (match your bake's SURFACE_IDS)
--   e         = restitution (bounce height)
--   rollDecel = rolling resistance, studs/s^2
--   fric      = tangential friction at impact (check/grab)
local SURF = {
	[1] = { e = 0.30, rollDecel = 18, fric = 0.50 }, -- tee
	[2] = { e = 0.30, rollDecel = 18, fric = 0.50 }, -- fairway
	[3] = { e = 0.20, rollDecel = 55, fric = 0.85 }, -- rough: deadens, short roll
	[4] = { e = 0.32, rollDecel = 5, fric = 0.45 }, -- green: soft bounce, smooth roll
	[5] = { e = 0.10, rollDecel = 90, fric = 0.95 }, -- bunker: plugs
}
local WATER_ID = 6
local OOB_ID = 0
local DEFAULT = SURF[2]

local BOUNCE_TO_ROLL_VN = 7.0   -- studs/s upward post-bounce; below this -> roll
local REST_SPEED = 1.2          -- studs/s; below this on gentle ground -> rest
local REST_SLOPE_DOT = 0.985    -- n . up above this = gentle enough to settle
local SPIN_RETAIN = 0.55        -- fraction of spin kept per bounce
local MAX_STEPS = 3000          -- safety cap (~12.5 s of ground phase)

local CUP_RADIUS = 0.1928       -- studs (regulation 4.25 in cup)
local CUP_CAPTURE_SPEED = 6.0   -- studs/s; faster than this the ball is too hot and rolls over
local CUP_SINK = 0.25           -- studs the ball drops below the green when holed

-- min horizontal distance from point C to the segment A->B (so a fast putt can't skip the cup)
local function segDistXZ(ax, az, bx, bz, cx, cz): number
	local dx, dz = bx - ax, bz - az
	local len2 = dx * dx + dz * dz
	local tproj = if len2 > 1e-9 then ((cx - ax) * dx + (cz - az) * dz) / len2 else 0
	tproj = math.clamp(tproj, 0, 1)
	local ex, ez = cx - (ax + tproj * dx), cz - (az + tproj * dz)
	return math.sqrt(ex * ex + ez * ez)
end

local GroundResolver = {}

function GroundResolver.resolve(
	landing: Ballistics.Result,
	terrain: TerrainFn,
	opts: { dt: number?, cup: { center: Vector3, radius: number?, captureSpeed: number? }? }?
): (Ballistics.Path, RestResult)
	local dt = (opts and opts.dt) or DT
	local g = Vector3.new(0, -G, 0)

	local cup = opts and opts.cup
	local cupCenter = cup and cup.center
	local cupRadius = (cup and cup.radius) or CUP_RADIUS
	local cupCaptureSpeed = (cup and cup.captureSpeed) or CUP_CAPTURE_SPEED

	local pos = landing.position
	local vel = landing.velocity
	local spin = landing.spin
	local t = landing.time
	local rolling = false
	local startFlat = Vector3.new(pos.X, 0, pos.Z)
	local path: Ballistics.Path = {}

	local function rest(): RestResult
		local s = terrain(pos.X, pos.Z)
		return {
			position = pos,
			surface = s.surface,
			water = false,
			outOfBounds = false,
			rollStuds = (Vector3.new(pos.X, 0, pos.Z) - startFlat).Magnitude,
			time = t,
			holed = false,
		}
	end

	for _ = 1, MAX_STEPS do
		local here = terrain(pos.X, pos.Z)
		if here.surface == WATER_ID then
			return path, { position = pos, surface = WATER_ID, water = true, outOfBounds = false, rollStuds = 0, time = t, holed = false }
		elseif here.surface == OOB_ID then
			return path, { position = pos, surface = OOB_ID, water = false, outOfBounds = true, rollStuds = 0, time = t, holed = false }
		end

		if rolling then
			local n = here.normal
			local surf = SURF[here.surface] or DEFAULT
			local accel = g - n * g:Dot(n) -- gravity along the slope (downhill)
			if vel.Magnitude > 1e-4 then
				accel -= vel.Unit * surf.rollDecel -- rolling resistance
			end
			vel += accel * dt
			vel -= n * vel:Dot(n) -- keep velocity tangent to the surface
			local prevPos = pos
			local newPos = prevPos + vel * dt
			-- holed? slow enough AND the step's path passes within the cup
			if cupCenter and vel.Magnitude < cupCaptureSpeed
				and segDistXZ(prevPos.X, prevPos.Z, newPos.X, newPos.Z, cupCenter.X, cupCenter.Z) < cupRadius
			then
				t += dt
				local sunk = Vector3.new(cupCenter.X, cupCenter.Y - CUP_SINK, cupCenter.Z)
				path[#path + 1] = { t = t, pos = sunk, vel = Vector3.zero }
				return path, {
					position = sunk, surface = 4, water = false, outOfBounds = false,
					rollStuds = (Vector3.new(sunk.X, 0, sunk.Z) - startFlat).Magnitude,
					time = t, holed = true,
				}
			end
			pos = newPos
			local s2 = terrain(pos.X, pos.Z)
			pos = Vector3.new(pos.X, s2.height + BALL_RADIUS, pos.Z) -- sit on the surface
			t += dt
			path[#path + 1] = { t = t, pos = pos, vel = vel }
			if vel.Magnitude < REST_SPEED and s2.normal:Dot(UP) > REST_SLOPE_DOT then
				return path, rest()
			end
		else
			-- airborne hop (gravity only -- aero was spent during the flight)
			local newVel = vel + g * dt
			local newPos = pos + newVel * dt
			local s2 = terrain(newPos.X, newPos.Z)
			local groundCenterY = s2.height + BALL_RADIUS

			if newPos.Y <= groundCenterY then
				-- CONTACT: resolve the bounce on this surface
				local n = s2.normal
				local surf = SURF[s2.surface] or DEFAULT
				local vn = newVel:Dot(n)
				if vn < 0 then
					local vNorm = n * vn
					local vTang = newVel - vNorm
					-- contact-point slip includes the ball's spin (this drives the check)
					local slip = vTang + n:Cross(spin) * BALL_RADIUS
					slip -= n * slip:Dot(n)
					local jn = (1 + surf.e) * -vn -- normal impulse magnitude
					local fric = Vector3.zero
					if slip.Magnitude > 1e-4 then
						fric = -slip.Unit * math.min(surf.fric * jn, slip.Magnitude)
					end
					vel = (vTang + fric) + n * (-surf.e * vn)
					spin *= SPIN_RETAIN
					pos = Vector3.new(newPos.X, groundCenterY, newPos.Z)
					t += dt
					path[#path + 1] = { t = t, pos = pos, vel = vel }
					if vel:Dot(n) < BOUNCE_TO_ROLL_VN then
						rolling = true
						vel -= n * vel:Dot(n) -- strip the (small) normal velocity to roll
					end
				else
					rolling = true -- skimming along; begin rolling
					pos = Vector3.new(newPos.X, groundCenterY, newPos.Z)
				end
			else
				vel = newVel
				pos = newPos
				t += dt
				path[#path + 1] = { t = t, pos = pos, vel = vel }
			end
		end
	end

	return path, rest()
end

-- Exposed so callers (e.g. the putt model in SwingController) share ONE source of truth
-- for green roll: retuning SURF/REST_SPEED here keeps the putt power calibration in lockstep.
GroundResolver.SURF = SURF
GroundResolver.REST_SPEED = REST_SPEED

return GroundResolver
