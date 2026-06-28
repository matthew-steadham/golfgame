--!strict
-- SwingAnalyzer
-- Pure, device-agnostic logic: a swing trajectory in -> a SwingInput out.
-- POWER and TEMPO are TIME-based (the backswing's duration sets power; the downswing's
-- duration vs backswing/3 sets tempo). Positions only shape path/face and contact wobble.

local Config = require(script.Parent.SwingConfig)

type SwingSample = Config.SwingSample
type SwingTrajectory = Config.SwingTrajectory
type SwingInput = Config.SwingInput

local SwingAnalyzer = {}

function SwingAnalyzer.analyze(trajectory: SwingTrajectory, cfg: any): SwingInput
	cfg = cfg or Config
	local samples = trajectory.samples

	local result: SwingInput = {
		power = 0, overswing = 0, tempo = 0, path = 0,
		faceOffset = 0, contact = 0, valid = false,
	}
	if #samples < 3 or not trajectory.transitionT then
		return result -- not enough motion to be a real swing
	end

	local startT = trajectory.startT
	local transitionT = trajectory.transitionT
	local impactT = trajectory.impactT
	local topPos = trajectory.topPos or Vector2.zero
	local impactPos = trajectory.impactPos or Vector2.zero

	-- commit gate: did the backswing pull back far enough to be a real swing?
	if topPos.Y < cfg.MinBackswingTravel then
		return result
	end

	-- 1) POWER + OVERSWING -- from how LONG the backswing was held -------
	local backTime = math.max(transitionT - startT, 1e-3)
	local power = math.clamp(backTime / cfg.FullBackswingTime, 0, 1)
	local overswing = math.clamp((backTime - cfg.FullBackswingTime) / cfg.OverswingTime, 0, 1)

	-- 2) TEMPO -- ideal backswing:downswing is 3:1 at EVERY power ---------
	local downTime = impactT - transitionT
	local incomplete = downTime < 0.05 -- released without a real downswing
	downTime = math.max(downTime, 1e-3)
	local ratio = backTime / downTime
	-- negative = rushed (downswing too quick), positive = lazy/decelerating
	local tempo = math.clamp((ratio - cfg.IdealTempoRatio) / cfg.TempoToleranceRatio, -1, 1)

	-- 3) SWING PATH (push/pull): how angled the BACKSWING was (lateral vs depth)
	local pathRaw = 0
	if math.abs(topPos.Y) > 1e-3 then
		pathRaw = topPos.X / math.abs(topPos.Y)
	end
	local path = math.clamp(pathRaw / cfg.MaxPathDeviation, -1, 1)

	-- 4) FACE / CONTACT (hook/slice): lateral lean of the DOWNSWING arc
	local downVec = impactPos - topPos
	local faceRaw = 0
	if math.abs(downVec.Y) > 1e-3 then
		faceRaw = downVec.X / math.abs(downVec.Y)
	end
	local faceOffset = math.clamp(faceRaw / cfg.MaxPathDeviation, -1, 1)

	-- 5) an aborted strike (no real downswing) saps distance
	if incomplete then
		power *= 0.4
	end

	result.backTime = backTime
	result.downTime = downTime
	result.power = power
	result.overswing = overswing
	result.tempo = tempo
	result.faceOffset = faceOffset
	result.path = path
	result.valid = true
	return result
end

return SwingAnalyzer
