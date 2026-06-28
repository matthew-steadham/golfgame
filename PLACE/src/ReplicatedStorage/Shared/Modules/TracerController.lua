--!strict
-- TracerController.luau  (ModuleScript in ReplicatedStorage.Shared.Modules)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Mods = ReplicatedStorage.Shared.Modules
local Ballistics = require(Mods.Ballistics)

local Tracers = {}

local AdornFolder: Folder? = nil
local linePool: { LineHandleAdornment } = {}

-- Visual Settings
local PREVIEW_COLOR = Color3.fromRGB(75, 186, 255)
local FLIGHT_COLOR = Color3.fromRGB(75, 186, 255)

local START_THICKNESS = 15
local END_THICKNESS = 50
local FLIGHT_THICKNESS = 15 -- Fixed thickness for the actual shot

local function ensureFolder(): Folder
	if not AdornFolder or not AdornFolder:IsDescendantOf(workspace) then
		local existing = workspace:FindFirstChild("TracerAdornFolder")
		if existing and existing:IsA("Folder") then
			AdornFolder = existing
		else
			local f = Instance.new("Folder")
			f.Name = "TracerAdornFolder"
			f.Parent = workspace
			AdornFolder = f
		end
	end
	return AdornFolder :: Folder
end

function Tracers.clear()
	for _, adorn in linePool do
		adorn.Visible = false
	end
end

local distPart: Part? = nil
local distGui: BillboardGui? = nil
local distLabel: TextLabel? = nil
local distLabel2: TextLabel? = nil

local function ensureDistanceMarker()
	if distPart then return end
	local p = Instance.new("Part")
	p.Name = "DistanceMarker"
	p.Size = Vector3.new(0.2, 0.2, 0.2)
	p.Transparency = 1
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
	p.Parent = workspace
	local gui = game.ReplicatedStorage.Assets.DistanceMarker:Clone()

	gui.Parent = p

	local lbl = gui.Frame.Text1
	local lbl2 = gui.Frame.Text2

	distPart, distGui, distLabel, distLabel2 = p, gui, lbl, lbl2
end

function Tracers.showDistance(worldPos: Vector3, value: number, unit: string?)
	ensureDistanceMarker()
	local p = distPart :: Part
	local lbl = distLabel :: TextLabel
	local lbl2 = distLabel2 :: TextLabel
	local gui = distGui :: BillboardGui
	p.Position = worldPos
	lbl.Text = string.format("%d %s", math.floor(value + 0.5), unit or "YDS")
	lbl2.Text = string.format("%d %s", math.floor(value + 0.5), unit or "YDS")
	gui.Enabled = true
end

function Tracers.hideDistance()
	if distGui then distGui.Enabled = false end
end

local PREVIEW_PEAK_T = 0.15     
local PREVIEW_FADE_IN = 0.01    
local PREVIEW_POST_APEX = 0.03  

local function previewTransparency(frac: number, apexFrac: number): number
	local fadeOutStart = math.clamp(apexFrac + PREVIEW_POST_APEX, PREVIEW_FADE_IN, 1)
	if frac <= PREVIEW_FADE_IN then
		local a = if PREVIEW_FADE_IN > 0 then frac / PREVIEW_FADE_IN else 1
		return 1 + (PREVIEW_PEAK_T - 1) * a              
	elseif frac < fadeOutStart then
		return PREVIEW_PEAK_T                             
	else
		local denom = 0.75 - fadeOutStart
		local a = if denom > 0 then (frac - fadeOutStart) / denom else 1
		return PREVIEW_PEAK_T + (1 - PREVIEW_PEAK_T) * a 
	end
end

function Tracers.updateLivePreview(points: { Vector3 }, busy: boolean)
	if busy or #points <= 1 then
		Tracers.clear()
		return
	end
	local folder = ensureFolder()
	local neededSegments = #points - 1
	while #linePool < neededSegments do
		local line = Instance.new("LineHandleAdornment")
		line.AlwaysOnTop = true
		line.Adornee = workspace.Terrain 
		line.Parent = folder
		table.insert(linePool, line)
	end

	local cum = table.create(#points)
	cum[1] = 0
	local apexIdx, apexY = 1, points[1].Y
	for i = 2, #points do
		cum[i] = cum[i - 1] + (points[i] - points[i - 1]).Magnitude
		if points[i].Y > apexY then
			apexY = points[i].Y
			apexIdx = i
		end
	end
	local total = cum[#points]
	local apexFrac = if total > 0 then cum[apexIdx] / total else 0

	Tracers.clear()
	for i = 1, neededSegments do
		local pA = points[i]
		local pB = points[i + 1]
		local line = linePool[i]
		line.CFrame = CFrame.lookAt(pA, pB)
		line.Length = (pB - pA).Magnitude

		local midFrac = if total > 0 then (cum[i] + cum[i + 1]) * 0.5 / total else 0

		-- Overwrite visual styling every frame for preview state
		line.Color3 = PREVIEW_COLOR
		line.Thickness = START_THICKNESS + (END_THICKNESS - START_THICKNESS) * midFrac
		line.Transparency = previewTransparency(midFrac, apexFrac)
		line.Visible = true
	end
end

function Tracers.updateProgressive(path: Ballistics.Path, currentIndex: number)
	if currentIndex <= 1 then
		Tracers.clear()
		return
	end
	local folder = ensureFolder()
	local neededSegments = currentIndex - 1
	while #linePool < neededSegments do
		local line = Instance.new("LineHandleAdornment")
		line.AlwaysOnTop = true
		line.Adornee = workspace.Terrain 
		line.Parent = folder
		table.insert(linePool, line)
	end

	Tracers.clear()
	for i = 1, neededSegments do
		local pA = path[i].pos
		local pB = path[i + 1].pos
		local line = linePool[i]
		line.CFrame = CFrame.lookAt(pA, pB)
		line.Length = (pB - pA).Magnitude

		-- Overwrite visual styling every frame for flight state
		line.Color3 = FLIGHT_COLOR
		line.Thickness = FLIGHT_THICKNESS
		line.Transparency = .15 
		line.Visible = true
	end
end

return Tracers