--!strict
-- ShotDistance: tracks how far the current shot has travelled and reports it as display text.
-- SwingController calls begin(ball, mode) at impact; this module then reads the ball's position
-- each frame on its own (no per-frame hook needed) and fires Changed(count, unit) as it flies and
-- rolls, settling on the final number when the ball stops. DistanceHud renders it.
--
-- Units: "shot" -> yards (YDS). "putt" -> feet (FT), or inches (IN) under a foot.
-- World scale: 1 stud = 0.28 m.

local RunService = game:GetService("RunService")

local Signal = require(script.Parent.Signal)

local YARDS_PER_STUD = 0.28 / 0.9144
local FEET_PER_STUD = 0.28 / 0.3048

local ShotDistance = {}
ShotDistance.Changed = Signal.new() -- (count: string, unit: string)
ShotDistance.Hidden = Signal.new()

local conn: RBXScriptConnection? = nil
local origin = Vector3.zero -- ball position at impact; distance is measured straight-line from here
local mode = "shot"

local function horiz(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz) -- yardage is horizontal only
end

local function textFor(distStuds: number): (string, string)
	if mode == "putt" then
		local feet = distStuds * FEET_PER_STUD
		if feet < 1 then
			return tostring(math.floor(feet * 12 + 0.5)), " IN"
		end
		return tostring(math.floor(feet + 0.5)), " FT"
	end
	return tostring(math.floor(distStuds * YARDS_PER_STUD + 0.5)), " YDS"
end

function ShotDistance.stop()
	if conn then
		conn:Disconnect()
		conn = nil
	end
end

-- Call at impact. mode: "shot" (yards) or "putt" (feet/inches).
function ShotDistance.begin(ball: BasePart?, shotMode: string?)
	ShotDistance.stop()
	if not ball then
		return
	end
	origin = ball.Position
	mode = shotMode or "shot"

	local lastCount, lastUnit = textFor(0)
	ShotDistance.Changed:Fire(lastCount, lastUnit) -- show 0 immediately on the hit

	local stableTime = 0
	conn = RunService.Heartbeat:Connect(function(dt)
		if not ball.Parent then
			ShotDistance.stop()
			return
		end
		local count, unit = textFor(horiz(ball.Position, origin))
		if count == lastCount and unit == lastUnit then
			stableTime += dt
			if stableTime > 1 then -- about 1s after the number stops changing, the ball has rested
				ShotDistance.stop()
			end
		else
			stableTime = 0
			lastCount, lastUnit = count, unit
			ShotDistance.Changed:Fire(count, unit)
		end
	end)
end

-- Optional: hide the readout entirely (e.g. on a new hole). begin() alone resets for the next shot.
function ShotDistance.hide()
	ShotDistance.stop()
	ShotDistance.Hidden:Fire()
end

return ShotDistance
