--!strict
-- ScoreUtil: golf scoring helpers shared by RoundState, the HUD card, and the scorecard.

local ScoreUtil = {}

-- Running score vs par, golf-style: 0 -> "E", positive -> "+N", negative -> "-N".
function ScoreUtil.formatToPar(rel: number): string
	if rel == 0 then
		return "E"
	elseif rel > 0 then
		return string.format("+%d", rel)
	else
		return string.format("%d", rel) -- negative value already carries the minus sign
	end
end

-- Name for a hole score relative to par (-3 Albatross ... +3 Triple Bogey, else "+N"/"-N").
function ScoreUtil.relName(rel: number): string
	local names = {
		[-4] = "Condor",
		[-3] = "Albatross",
		[-2] = "Eagle",
		[-1] = "Birdie",
		[0] = "Par",
		[1] = "Bogey",
		[2] = "Double Bogey",
		[3] = "Triple Bogey",
		[4] = "Quad Bogey"
	}
	return names[rel] or string.format("%+d", rel)
end

-- Convenience: name straight from raw strokes + par.
function ScoreUtil.scoreName(strokes: number, par: number): string
	return ScoreUtil.relName(strokes - par)
end

return ScoreUtil
