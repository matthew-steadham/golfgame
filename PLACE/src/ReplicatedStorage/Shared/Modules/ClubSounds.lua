--!strict
-- ClubSounds: plays a club-hit sound based on the club used.
-- Put six Sound instances named exactly: Driver, Wood, Hybrid, Iron, Wedge, Putt
-- in the container below (SoundService by default). They're treated as 2D templates -- each hit
-- plays a fresh clone, so rapid shots never cut each other off.

local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

local ClubSounds = {}

-- Where your six named Sound instances live. Change this if you keep them somewhere else
-- (e.g. ReplicatedStorage:WaitForChild("Sounds")).
local SOUND_CONTAINER: Instance = SoundService
local templateCache: { [string]: Sound } = {}
local warnedMissing: { [string]: boolean } = {}

-- Map a club (by display name) to its sound category. Names are matched loosely so "3-Wood",
-- "5-Iron", "P Wedge", etc. all resolve. Add cases here if you introduce oddly-named clubs.
local function categoryFor(club: { name: string }): string?
	local name = string.lower(club.name)
	if string.find(name, "putt") then -- "Putter"
		return "Putt"
	elseif string.find(name, "driver") then
		return "Driver"
	elseif string.find(name, "wood") then
		return "Wood"
	elseif string.find(name, "hybrid") then
		return "Hybrid"
	elseif string.find(name, "wedge") then
		return "Wedge"
	elseif string.find(name, "iron") then
		return "Iron"
	end
	return nil
end

local function getTemplate(category: string): Sound?
	local cached = templateCache[category]
	if cached and cached.Parent then
		return cached
	end

	local template = SOUND_CONTAINER:FindFirstChild(category)
	if template and template:IsA("Sound") then
		templateCache[category] = template
		return template
	end

	if not warnedMissing[category] then
		warn(`[ClubSounds] missing Sound "{category}" in {SOUND_CONTAINER:GetFullName()}`)
		warnedMissing[category] = true
	end
	return nil
end

function ClubSounds.play(club: { name: string }?)
	if not club then
		return
	end
	local category = categoryFor(club)
	if not category then
		return
	end
	local template = getTemplate(category)
	if not template then
		return
	end
	-- Clone-and-play so overlapping shots don't restart a single instance.
	local sound = template:Clone()
	sound.Parent = SOUND_CONTAINER -- parent is a service, so it plays 2D (non-positional)
	sound:Play()
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	Debris:AddItem(sound, 10) -- safety cleanup if Ended never fires
end

return ClubSounds
