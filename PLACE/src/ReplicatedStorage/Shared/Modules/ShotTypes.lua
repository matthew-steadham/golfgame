--!strict
-- ShotTypes
-- A shot type reshapes the club's stock shot: launch, spin, and the distance band you
-- can dial with W/S (as a fraction of the club's full carry). Together with the W/S dial
-- these let you hit any yardage -- tee bombs down to delicate chips.

export type ShotType = {
	id: string,
	name: string,
	launchAdd: number,   -- degrees added to the club's launch angle
	spinMult: number,    -- backspin multiplier (more = higher, more bite)
	minFrac: number,     -- W/S distance band, as a fraction of the club's full carry
	maxFrac: number,
	defaultFrac: number, -- where the dial sits when you switch to this type
}

local ShotTypes = {}

ShotTypes.Order = {
	{ id = "tee",      name = "Tee",      launchAdd = 0,  spinMult = 1, minFrac = 0.75, maxFrac = 1.00, defaultFrac = 1.00 },
	{ id = "approach", name = "Approach", launchAdd = 0,  spinMult = 1.00, minFrac = 0.75, maxFrac = 1.00, defaultFrac = 1.00 },
	{ id = "punch",    name = "Punch",    launchAdd = 0,  spinMult = 1,    minFrac = 0.75, maxFrac = 1.00, defaultFrac = 1.00 },
	{ id = "pitch",    name = "Pitch",    launchAdd = 0,  spinMult = 1, minFrac = .75, maxFrac = 1, defaultFrac = 1 },
	{ id = "flop",     name = "Flop",     launchAdd = 0, spinMult = 1, minFrac = .75, maxFrac = 1, defaultFrac = 1 },
	{ id = "chip",     name = "Chip",     launchAdd = 0, spinMult = 1, minFrac = .75, maxFrac = 1, defaultFrac = 1 },
}

return ShotTypes
