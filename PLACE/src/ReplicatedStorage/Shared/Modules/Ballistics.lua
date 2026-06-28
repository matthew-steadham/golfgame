--!strict
-- Ballistics
-- Pure, deterministic golf-ball flight integrator. No Roblox physics, no globals,
-- no RNG -- so the SERVER can re-run this identically to validate ranked shots.
-- Units: studs and studs/s throughout (matches the terrain data + world space).

-- ============================ TUNABLES ============================
local CFG = {
	G            = 35.036,      -- studs/s^2  (9.81 m/s^2 * 3.5714286 studs/m)
	KAERO        = 0.0053505,   -- 1/stud     0.5*rho*A/m, physical aero prefactor
	BALL_RADIUS  = 0.0762,      -- studs      for spin factor S = r*omega/v
	CL_SCALE     = 0.9296,      -- lift-curve scale
	CD0          = 0.1595,      -- drag at zero spin
	CD_SLOPE     = 0.4298,      -- drag growth with spin factor
	SPIN_TAU_REF = 18.9,        -- s          spin-decay time constant at the ref speed
	DT           = 1 / 240,     -- s          fixed timestep (do not couple to framerate)
	MAX_TIME     = 12.0,        -- s          safety cap
}
-- =================================================================

local MPH_TO_STUDS = 1.596571 -- 1 mph = 0.44704 m/s * 3.5714286 studs/m
local YARDS_PER_STUD = 0.3062094
local SPIN_V_REF = 100 * MPH_TO_STUDS -- spin decay anchored to tau at 100 mph

-- spin-factor-dependent aero coefficients
local function dragCoeff(S: number): number
	return CFG.CD0 + CFG.CD_SLOPE * S
end
local function liftCoeff(S: number): number
	local cl = CFG.CL_SCALE * (-0.05 + math.sqrt(0.0025 + 0.36 * S))
	return if cl > 0 then cl else 0
end

export type Launch = {
	position: Vector3,
	velocity: Vector3,
	spin: Vector3, -- angular velocity omega, rad/s
}

export type Sample = { t: number, pos: Vector3, vel: Vector3 }
export type Path = { Sample }

export type Result = {
	landed: boolean,
	position: Vector3,
	velocity: Vector3,
	spin: Vector3,
	time: number,
	apex: number, -- max height reached (studs)
}

export type Env = {
	wind: Vector3?, -- studs/s; nil = still air
	groundHeight: ((x: number, z: number) -> number)?, -- nil = flat plane at groundY
	groundY: number?, -- flat-plane height when groundHeight is nil (default 0)
}

export type Opts = { dt: number?, maxTime: number? }

local Ballistics = {}
Ballistics.MPH_TO_STUDS = MPH_TO_STUDS
Ballistics.CFG = CFG

-- Build a launch from human-readable parameters.
export type LaunchParams = {
	position: Vector3,
	aimDirection: Vector3, -- horizontal aim (y ignored)
	ballSpeed: number, -- studs/s
	launchAngleDeg: number,
	backspin: number, -- rad/s
	sidespin: number, -- rad/s (+ curves right, - curves left)
}

function Ballistics.makeLaunch(p: LaunchParams): Launch
	local f = Vector3.new(p.aimDirection.X, 0, p.aimDirection.Z)
	assert(f.Magnitude > 1e-6, "aimDirection needs a horizontal component")
	f = f.Unit
	local up = Vector3.yAxis
	local ang = math.rad(p.launchAngleDeg)
	local vel = (f * math.cos(ang) + up * math.sin(ang)) * p.ballSpeed
	-- backspin axis = f x up -> omega x v lifts the ball; sidespin about vertical
	local omega = f:Cross(up) * p.backspin + up * p.sidespin
	return { position = p.position, velocity = vel, spin = omega }
end

-- Run the entire flight. Returns the path and a summary Result.
function Ballistics.simulate(launch: Launch, env: Env?, opts: Opts?): (Path, Result)
	local e: Env = env or {}
	local wind = e.wind or Vector3.zero
	local groundAt = e.groundHeight
	local groundY0 = e.groundY or 0
	local dt = (opts and opts.dt) or CFG.DT
	local maxT = (opts and opts.maxTime) or CFG.MAX_TIME
	local g = Vector3.new(0, -CFG.G, 0)
	local spinDecayK = dt / (CFG.SPIN_TAU_REF * SPIN_V_REF) 
	local kaero = CFG.KAERO
	local radius = CFG.BALL_RADIUS

	local function ground(x: number, z: number): number
		return if groundAt then groundAt(x, z) else groundY0
	end

	local pos = launch.position
	local vel = launch.velocity
	local omega = launch.spin
	local t = 0
	local apex = pos.Y
	local path: Path = { { t = 0, pos = pos, vel = vel } }

	while t < maxT do
		local vAir = vel - wind
		local speed = vAir.Magnitude
		local accel: Vector3
		if speed > 1e-6 then
			local S = radius * omega.Magnitude / speed
			local cd = dragCoeff(S)
			local cl = liftCoeff(S)
			local aDrag = vAir * (-kaero * cd * speed)
			local cross = omega:Cross(vAir)
			local aLift = if cross.Magnitude > 1e-6
				then cross.Unit * (kaero * cl * speed * speed)
				else Vector3.zero
			accel = g + aDrag + aLift
		else
			accel = g
		end

		vel = vel + accel * dt
		local newPos = pos + vel * dt
		omega = omega * math.exp(-speed * spinDecayK)
		t += dt

		local gy = ground(newPos.X, newPos.Z)
		if newPos.Y <= gy then
			local drop = pos.Y - newPos.Y
			local frac = if drop > 1e-6 then math.clamp((pos.Y - gy) / drop, 0, 1) else 0
			local landing = pos:Lerp(newPos, frac)
			local landT = t - dt + frac * dt
			path[#path + 1] = { t = landT, pos = landing, vel = vel }
			return path, {
				landed = true, position = landing, velocity = vel,
				spin = omega, time = landT, apex = apex,
			}
		end

		pos = newPos
		if pos.Y > apex then
			apex = pos.Y
		end
		path[#path + 1] = { t = t, pos = pos, vel = vel }
	end

	return path, {
		landed = false, position = pos, velocity = vel,
		spin = omega, time = t, apex = apex,
	}
end

-- Generates a down-sampled path array specifically for real-time path rendering.
function Ballistics.getProjectionPath(launch: Launch, env: Env?, resolutionStep: number?): {Vector3}
	local stepInterval = resolutionStep or 100
	local fullPath, _ = Ballistics.simulate(launch, env)

	local points: {Vector3} = {}
	for i = 1, #fullPath, stepInterval do
		table.insert(points, fullPath[i].pos)
	end

	if #fullPath > 0 and (fullPath[#fullPath].pos - points[#points]).Magnitude > 0.1 then
		table.insert(points, fullPath[#fullPath].pos)
	end

	return points
end

function Ballistics.carryStuds(launch: Launch, result: Result): number
	local d = result.position - launch.position
	return Vector3.new(d.X, 0, d.Z).Magnitude
end

function Ballistics.studsToYards(studs: number): number
	return studs * YARDS_PER_STUD
end

return Ballistics