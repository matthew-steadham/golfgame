-- RoundState: the LOCAL player's live round (client-side, transient, singleton). SwingController
-- writes to it at the shot and hole-out hooks; the HUD card and scorecard read it and listen on
-- Changed. This is NOT persisted -- only the final result is submitted to the server at round end.

local ScoreUtil = require(script.Parent.ScoreUtil)
local Signal = require(script.Parent.Signal)

export type HoleResult = { hole: number, par: number, strokes: number }

local RoundState = {}
RoundState.Changed = Signal.new() -- fires (no args) on any change; listeners re-read the fields
RoundState.HoleCompleted = Signal.new() -- fires (HoleResult) when a hole is holed out

-- Live fields. Read via the getters or directly; treat as read-only outside this module.
RoundState.courseId = ""
RoundState.currentHole = 1
RoundState.currentPar = 4
RoundState.currentStrokes = 0
RoundState.card = {} :: { HoleResult } -- completed holes, in order
RoundState.pars = {} :: { number } -- par per hole for the whole course (may be partial/empty)
RoundState.active = false

local function changed()
	RoundState.Changed:Fire()
end

-- Begin a fresh round. courseId is for the eventual server submit; may be "".
function RoundState.StartRound(courseId: string?, pars: { number }?)
	RoundState.courseId = courseId or ""
	RoundState.pars = pars or {}
	RoundState.currentHole = 1
	RoundState.currentPar = 4
	RoundState.currentStrokes = 0
	RoundState.card = {}
	RoundState.active = true
	changed()
end

-- Move onto hole n (par p). Resets the in-progress stroke count.
function RoundState.StartHole(n: number, par: number)
	RoundState.currentHole = n
	RoundState.currentPar = par
	RoundState.currentStrokes = 0
	changed()
end

-- Set the in-progress stroke count for the current hole (call right after your strokes += 1).
function RoundState.SetStrokes(n: number)
	RoundState.currentStrokes = n
	changed()
end

-- Record the current hole complete in `strokes`; append to the card. Returns the HoleResult.
function RoundState.HoleOut(strokes: number, par: number): HoleResult
	local result: HoleResult = { hole = RoundState.currentHole, par = par, strokes = strokes }
	table.insert(RoundState.card, result)
	RoundState.currentStrokes = 0
	changed()
	RoundState.HoleCompleted:Fire(result)
	return result
end

-- Running score vs par over COMPLETED holes only (in-progress hole isn't scored until holed).
function RoundState.GetToPar(): number
	local rel = 0
	for _, r in RoundState.card do
		rel += r.strokes - r.par
	end
	return rel
end

function RoundState.GetToParText(): string
	return ScoreUtil.formatToPar(RoundState.GetToPar())
end

-- (strokes, par) totals over completed holes -- for the scorecard footer.
function RoundState.GetTotals(): (number, number)
	local s, p = 0, 0
	for _, r in RoundState.card do
		s += r.strokes
		p += r.par
	end
	return s, p
end

return RoundState
