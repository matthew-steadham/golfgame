-- ProfileTemplate
-- Single source of truth for the shape of a player's saved data.
-- Lives in ReplicatedStorage so both the server (authoritative writes) and, later, the client
-- (read-only replicated subset + Luau types) can reference the same schema.
--
-- Migrations: bump DATA_VERSION when you change the shape in a way Reconcile() can't handle on
-- its own. Reconcile (called in DataService) backfills any NEW leaf fields automatically, so for
-- purely additive changes you don't even need a version bump -- just add the field here.

local ProfileTemplate = {}

ProfileTemplate.DATA_VERSION = 1

ProfileTemplate.Template = {
	meta = {
		dataVersion = 1, -- stamped to DATA_VERSION on load; drives future migrations
		createdAt = 0, -- os.time() of first ever load
		lastPlayed = 0, -- os.time() of most recent load
		playtimeSec = 0, -- cumulative seconds in-game
	},

	currency = {
		coins = 0, -- soft currency, earned in-game
		bucks = 0, -- premium currency (Robux-purchased); leave at 0 until monetization exists
	},

	progression = {
		xp = 0,
		level = 1,
		unlockedCourses = {}, -- array of courseId strings
	},

	bag = {
		ownedClubs = {}, -- array of clubId
		ownedBalls = {}, -- array of ballId
		equipped = {}, -- { driver = id, threeWood = id, ..., putter = id, ball = id }
		cosmetics = { owned = {}, equipped = {} },
	},

	stats = {
		roundsPlayed = 0,
		holesPlayed = 0,
		careerEarnings = 0, -- lifetime coins earned (never decremented)
		handicapIndex = 0, -- 0 = unestablished; computed later from records
		scoringAvg = 0,
		fairwaysPct = 0,
		girPct = 0, -- greens in regulation
		puttsPerRound = 0,
		longestDriveYds = 0,
	},

	records = {
		bestByCourse = {}, -- { [courseId] = { strokes = n, date = os.time() } }
		bestByHole = {}, -- { [holeId]   = { strokes = n, date = os.time() } }
	},

	settings = {
		swingSensitivity = 1.0,
		units = "yards", -- "yards" | "meters"
		gridEnabled = true, -- putting-green break grid
	},
}

export type Data = typeof(ProfileTemplate.Template)

return ProfileTemplate
