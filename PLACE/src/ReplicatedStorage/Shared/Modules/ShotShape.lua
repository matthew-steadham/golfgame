--!strict
-- ShotShape
-- Classifies an intentional shot-shape coordinate into a readable name.
--   x: -1 draw .. +1 fade      y: +1 low .. -1 high
-- Used by the HUD to tell the player what shot they've dialed in. The actual
-- launch effect is applied in ShotModel (opts.shape).

local ShotShape = {}
local DZ = 0.2 -- deadzone: inside this is "straight" / "stock"

local function cap(s: string): string
	return s:sub(1, 1):upper() .. s:sub(2)
end

function ShotShape.describe(x: number, y: number): string
	local curve = if x < -DZ then "draw" elseif x > DZ then "fade" else "straight"
	local height = if y > DZ then "low" elseif y < -DZ then "high" else "stock"
	if height == "stock" and curve == "straight" then
		return "Stock"
	elseif height == "stock" then
		return cap(curve)
	elseif curve == "straight" then
		return cap(height) .. " straight"
	end
	return cap(height) .. " " .. curve
end

return ShotShape
