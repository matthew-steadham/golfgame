--!strict
-- Difficulty
-- Single source of truth for the difficulty tiers. Every aid, meter, and swing
-- tolerance reads from here, so tuning a tier -- or adding a new one -- is one edit.
-- Set the active tier with Difficulty.set("Pro"); read it with Difficulty.get().
--
-- Forgiveness fields are 0..1: 0 = raw/unforgiving (your error reaches the ball in
-- full), 1 = maximum assist (error is fully ironed out). Penalties (lie, etc.) still
-- APPLY on every tier; the *Info flags only control whether the player is shown them.
--
-- Swing Bias: when true, drawing/fading requires physically angling the swing path
-- (the capture frame tilts). When false the swing is strictly vertical and the dialed
-- shape is applied automatically -- only Pro and above demand the angled execution.

export type Settings = {
	name: string,
	scoreMultiplier: number, -- scoring / XP multiplier for the tier
	swingBias: boolean,      -- angled swing-path requirement (vertical swing if false)

	-- visual aids
	preShotPath: boolean,    -- predicted ball path drawn at address
	distanceMarker: boolean, -- yardage label at the end of the pre-shot path
	windPrediction: boolean,
	puttPreview: boolean,
	greenGrid: boolean,
	distanceMeters: boolean, -- club / shot-distance readouts
	lieInfo: boolean,        -- shows the lie's effect BEFORE the shot (penalty still applies)

	-- swing feedback
	swingMeter: boolean,     -- the on-screen power/rhythm rings + stats
	swingFeedback: boolean,  -- post-shot good/bad colouring

	-- swing feel (0..1 forgiveness; sensitivity is an input-gain multiplier)
	pathForgiveness: number,    -- softens push/pull (swing path) error
	tempoForgiveness: number,   -- softens rhythm error
	contactForgiveness: number, -- softens hook/slice (face) error
	swingSensitivity: number,   -- >1 = twitchier (less motion per unit), <1 = calmer
}

local TIERS: { [string]: Settings } = {
	-- 1) Beginner / Perfect Swing: vertical swing, max forgiveness, every aid on.
	Beginner = {
		name = "Beginner", scoreMultiplier = 1.00, swingBias = false,
		preShotPath = true, distanceMarker = true, windPrediction = true,
		puttPreview = true, greenGrid = true, distanceMeters = true, lieInfo = true,
		swingMeter = true, swingFeedback = true,
		pathForgiveness = 0.95, tempoForgiveness = 0.95, contactForgiveness = 0.95, swingSensitivity = 0.75,
	},
	-- 2) Amateur: vertical swing; rhythm starts to bite; full meters.
	Amateur = {
		name = "Amateur", scoreMultiplier = 1.07, swingBias = false,
		preShotPath = true, distanceMarker = true, windPrediction = true,
		puttPreview = true, greenGrid = true, distanceMeters = true, lieInfo = true,
		swingMeter = true, swingFeedback = true,
		pathForgiveness = 0.80, tempoForgiveness = 0.75, contactForgiveness = 0.80, swingSensitivity = 0.85,
	},
	-- 3) Pro-Am: vertical swing, tighter transition + contact; arcade/sim middle ground.
	ProAm = {
		name = "Pro-Am", scoreMultiplier = 1.26, swingBias = false,
		preShotPath = true, distanceMarker = true, windPrediction = true,
		puttPreview = true, greenGrid = true, distanceMeters = true, lieInfo = true,
		swingMeter = true, swingFeedback = true,
		pathForgiveness = 0.50, tempoForgiveness = 0.50, contactForgiveness = 0.45, swingSensitivity = 1.00,
	},
	-- 4) Pro (default ranked): Swing Bias becomes mandatory; meters still on.
	Pro = {
		name = "Pro", scoreMultiplier = 1.39, swingBias = true,
		preShotPath = true, distanceMarker = true, windPrediction = true,
		puttPreview = true, greenGrid = true, distanceMeters = true, lieInfo = true,
		swingMeter = true, swingFeedback = true,
		pathForgiveness = 0.25, tempoForgiveness = 0.25, contactForgiveness = 0.25, swingSensitivity = 1.05,
	},
	-- 5) Master: angled bias, near-zero margin, on-screen helpers stripped.
	Master = {
		name = "Master", scoreMultiplier = 1.51, swingBias = true,
		preShotPath = false, distanceMarker = false, windPrediction = false,
		puttPreview = false, greenGrid = true, distanceMeters = false, lieInfo = true,
		swingMeter = false, swingFeedback = false,
		pathForgiveness = 0.10, tempoForgiveness = 0.10, contactForgiveness = 0.10, swingSensitivity = 1.25,
	},
	-- 6) Legend: ultimate sim -- everything stripped, zero forgiveness.
	Legend = {
		name = "Legend", scoreMultiplier = 1.68, swingBias = true,
		preShotPath = false, distanceMarker = false, windPrediction = false,
		puttPreview = false, greenGrid = false, distanceMeters = false, lieInfo = false,
		swingMeter = false, swingFeedback = false,
		pathForgiveness = 0.0, tempoForgiveness = 0.0, contactForgiveness = 0.0, swingSensitivity = 1.45,
	},
}

local Difficulty = {}
Difficulty.Tiers = TIERS
Difficulty.Order = { "Beginner", "Amateur", "ProAm", "Pro", "Master", "Legend" }

local current: Settings = TIERS.Pro -- recommended default ranked setting

function Difficulty.set(name: string)
	local t = TIERS[name]
	if t then
		current = t
	else
		warn("[Difficulty] unknown tier: " .. tostring(name))
	end
end

function Difficulty.get(): Settings
	return current
end

return Difficulty
