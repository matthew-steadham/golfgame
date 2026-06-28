--!strict
-- Clubs: the bag. Each club's PERFECT full-swing launch (from calibration), in
-- human units (mph, deg, rpm) -- ShotModel converts to the integrator's units.
-- Add the rest of your bag here as you tune each club's launch trio against the
-- BallFlightTest harness. The aero constants in Ballistics never change; only these.

export type Club = {
	name: string,
	fullSpeed: number,   -- mph, ball speed for a flushed full swing
	launchAngle: number, -- deg
	backspin: number,    -- rpm, flushed full-swing backspin
}

local Clubs: { [string]: Club } = {
	Driver  = { name = "Driver",   fullSpeed = 167, launchAngle = 10.9, backspin = 2686  },
	Wood3   = { name = "3-Wood",   fullSpeed = 158, launchAngle = 9.2,  backspin = 3655  },
	Wood5   = { name = "5-Wood",   fullSpeed = 152, launchAngle = 9.4,  backspin = 4350  },
	Hybrid5 = { name = "5-Hybrid", fullSpeed = 146, launchAngle = 10.2, backspin = 4437  },
	Iron5   = { name = "5-Iron",   fullSpeed = 142, launchAngle = 12.1, backspin = 5363  },
	Iron6   = { name = "6-Iron",   fullSpeed = 137, launchAngle = 14.1, backspin = 6204  },
	Iron7   = { name = "7-Iron",   fullSpeed = 132, launchAngle = 16.3, backspin = 7097  },
	Iron8   = { name = "8-Iron",   fullSpeed = 127, launchAngle = 18.1, backspin = 7998  },
	Iron9   = { name = "9-Iron",   fullSpeed = 120, launchAngle = 20.4, backspin = 8647  },
	PWedge  = { name = "P Wedge",  fullSpeed = 115, launchAngle = 24.2, backspin = 9304  },
	Wedge50 = { name = "50-Wedge", fullSpeed = 109, launchAngle = 25.5, backspin = 9650  },
	Wedge56 = { name = "56-Wedge", fullSpeed = 102, launchAngle = 28.2, backspin = 10200 },
	Wedge60 = { name = "60-Wedge", fullSpeed = 78,  launchAngle = 31.0, backspin = 9400  },
	Putter  = { name = "Putter",   fullSpeed = 16,  launchAngle = 0.0, backspin = 0      },
}

return Clubs
