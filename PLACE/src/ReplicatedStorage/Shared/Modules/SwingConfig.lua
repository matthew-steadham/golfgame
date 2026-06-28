--!strict
-- SwingConfig
-- All tunable constants and shared types for the EvoSwing input system.
-- These are the dials you'll spend the most time on. Tune them live in the
-- driving range. Nothing here is device-specific.

-- A single sampled point of a swing, in normalized "swing space":
--   origin (0,0) = address / ball line
--   +Y           = backswing (pulled back)
--   +X           = right of center
export type SwingSample = {
	pos: Vector2,
	t: number, -- os.clock() timestamp
}

export type SwingTrajectory = {
	samples: { SwingSample },
	startT: number,      -- backswing start (os.clock)
	transitionT: number, -- top / reversal
	impactT: number,     -- ball-line crossing
	topPos: Vector2,     -- swing-space position at transition
	impactPos: Vector2,  -- swing-space position at impact
}

-- The device-agnostic output every capture backend must produce.
export type SwingInput = {
	power: number,      -- 0..1 BACKSWING TIMING -> distance control
	overswing: number,  -- 0..1 held past a full backswing (risk + extra power)
	tempo: number,      -- DOWNSWING TIMING (rhythm): 0 perfect 3:1, - rushed, + lazy -> distance modifier
	path: number,       -- BACKSWING accuracy (swing path): -1 pull (left) .. +1 push (right) start dir
	faceOffset: number, -- DOWNSWING accuracy (contact): -1 hook (left) .. +1 slice (right) curve
	contact: number,    -- legacy strike-quality field (unused by the timing model)
	valid: boolean,     -- false if the swing was cancelled before commit
	backTime: number?,  -- raw backswing duration (s) -- for stat readouts
	downTime: number?,  -- raw downswing duration (s)
}

local Config = {
	-- INPUT / NORMALIZATION ----------------------------------------------
	-- Mouse pixels that equal 1.0 normalized unit on each axis. Lower = more
	-- sensitive. This is the single most feel-critical number; tune first.
	MousePixelsPerUnit = 1,
	-- Set true if a player prefers "pull up to load" instead of "pull down".
	InvertY = false,

	-- POWER IS TIME-BASED. A full-power backswing takes this long; the ring fills over
	-- this window and you transition when it reaches your target power. Total swing at
	-- 3:1 is about FullBackswingTime * 4/3 (~1.07s for 0.80s).
	FullBackswingTime = 0.8, -- s
	OverswingTime = 0.15,     -- s held past full = overswing
	-- (depth no longer sets power; it only gates "committed" and shapes path/face)
	FullBackswingTravel = .25,
	-- Minimum pull-back before the swing "commits" (filters out tiny twitches;
	-- releasing before this cancels cleanly with no penalty).
	MinBackswingTravel = 0.18,
	-- How far past full you can pull for an overswing.
	MaxOverswing = 0.20,

	-- TRANSITION / IMPACT DETECTION --------------------------------------
	-- Samples looked back over to detect the top-of-backswing reversal.
	ReversalSmoothing = 3,
	-- Downswing "meets the ball" when Y returns within this band of origin.
	ImpactLineBand = 0.04,
	-- How far Y must drop from the top before we call the downswing started
	-- (this is what makes TRANSITION its own visible phase).
	TransitionExitBand = 0.06,

	-- TEMPO --------------------------------------------------------------
	-- Ideal backswing:downswing time ratio (real golf ~3:1).
	IdealTempoRatio = 3.0,
	-- How far off-ratio maps to maximum tempo penalty.
	TempoToleranceRatio = 2.0,

	-- PATH / FACE --------------------------------------------------------
	-- Horizontal deviation (normalized) that maps to full path/face values.
	MaxPathDeviation = 0.5,

	-- CONTACT ------------------------------------------------------------
	ContactTempoWeight = 0.45,
	ContactWobbleWeight = 0.30,
	ContactFaceWeight = 0.25,
	-- Accumulated small reversals that map to a full wobble penalty.
	MaxWobble = 0.6,

	-- PUTTING ------------------------------------------------------------
	-- Override profile: putting reuses the exact same analyzer, just calmer.
	Putting = {
		MousePixelsPerUnit = 1, -- finer control for distance feel
		IdealTempoRatio = 2.0,  -- putts use an even 1:1 backswing:downswing tempo (not 3:1)
	},
}

return Config
