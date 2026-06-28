--!strict
local CourseLoader = {}

type TileData = {
	HeightBuffer: buffer,
	SurfaceBuffer: buffer,
	Width: number,
	Height: number,
	MinX: number, MaxX: number,
	MinY: number, MaxY: number,
	CenterX: number, CenterY: number, -- Precalculated for fast distance checks
}

type CourseSession = {
	Folder: Folder,
	TilesX: number,
	TilesY: number,
	MinH: number,
	MaxH: number,
	StudsPerMeter: number,
	LoadedTiles: { [string]: TileData }
}

local activeSessions: { [string]: CourseSession } = {}

-- Configurable streaming radius (in studs)
local STREAM_RADIUS = 600 

local function getCellHeight(buf: buffer, u: number, v: number, w: number, h: number): number
	if u < 0 or u >= w or v < 0 or v >= h then return 0 end
	local idx = (v * w + u) * 2
	return buffer.readu16(buf, idx)
end

local function getTileKey(tx: number, ty: number): string
	return tx .. "_" .. ty
end

-- Core loading function for a specific tile
local function loadTile(session: CourseSession, tx: number, ty: number): TileData?
	local tileKey = getTileKey(tx, ty)
	if session.LoadedTiles[tileKey] then return session.LoadedTiles[tileKey] end

	local tileFolder = session.Folder:FindFirstChild(string.format("Tile_%d_%d", tx, ty)) :: Folder?
	if not tileFolder then return nil end

	local rawHeightString = require(tileFolder:WaitForChild("Height") :: ModuleScript) :: string
	local rawSurfaceString = require(tileFolder:WaitForChild("Surface") :: ModuleScript) :: string

	local minX = tileFolder:GetAttribute("minX") :: number
	local maxX = tileFolder:GetAttribute("maxX") :: number
	local minY = tileFolder:GetAttribute("minY") :: number
	local maxY = tileFolder:GetAttribute("maxY") :: number

	local tileData: TileData = {
		HeightBuffer = buffer.fromstring(rawHeightString),
		SurfaceBuffer = buffer.fromstring(rawSurfaceString),
		Width = tileFolder:GetAttribute("width") :: number,
		Height = tileFolder:GetAttribute("height") :: number,
		MinX = minX, MaxX = maxX,
		MinY = minY, MaxY = maxY,
		CenterX = (minX + maxX) / 2,
		CenterY = (minY + maxY) / 2,
	}

	session.LoadedTiles[tileKey] = tileData
	return tileData
end

function CourseLoader.Load(courseName: string)
	if activeSessions[courseName] then return activeSessions[courseName] end

	local folder = game:GetService("ReplicatedStorage"):WaitForChild("CourseData"):WaitForChild(courseName) :: Folder

	activeSessions[courseName] = {
		Folder = folder,
		TilesX = folder:GetAttribute("tilesX") :: number,
		TilesY = folder:GetAttribute("tilesY") :: number,
		MinH = folder:GetAttribute("minH") :: number,
		MaxH = folder:GetAttribute("maxH") :: number,
		StudsPerMeter = folder:GetAttribute("studsPerMeter") :: number,
		LoadedTiles = {}
	}

	return activeSessions[courseName]
end

--- Run this periodically (e.g., every 0.5 seconds or whenever the ball moves significantly)
--- to stream tiles in and out around a focal world position (X, Z).
function CourseLoader.UpdateStreaming(courseName: string, focalX: number, focalZ: number)
	local session = activeSessions[courseName]
	if not session then return end

	for ty = 0, session.TilesY - 1 do
		for tx = 0, session.TilesX - 1 do
			local tileKey = getTileKey(tx, ty)

			-- 1. Grab attributes to check distance before loading the heavy strings
			local tileFolder = session.Folder:FindFirstChild(string.format("Tile_%d_%d", tx, ty)) :: Folder?
			if not tileFolder then continue end

			local minX = tileFolder:GetAttribute("minX") :: number
			local maxX = tileFolder:GetAttribute("maxX") :: number
			local minY = tileFolder:GetAttribute("minY") :: number
			local maxY = tileFolder:GetAttribute("maxY") :: number

			local centerX = (minX + maxX) / 2
			local centerY = (minY + maxY) / 2

			-- Quick 2D Euclidean distance calculation
			local distance = math.sqrt((focalX - centerX)^2 + (focalZ - centerY)^2)

			if distance <= STREAM_RADIUS then
				-- Within range: Load and cache the data
				if not session.LoadedTiles[tileKey] then
					loadTile(session, tx, ty)
				end
			else
				-- Out of range: Wipe the buffers from memory
				if session.LoadedTiles[tileKey] then
					session.LoadedTiles[tileKey] = nil :: any
				end
			end
		end
	end
end

function CourseLoader.GetTerrainData(courseName: string, x: number, z: number)
	local session = activeSessions[courseName]
	if not session then error("Course session not loaded: " .. courseName) end

	local targetTile: TileData? = nil
	for _, tile in session.LoadedTiles do
		if x >= tile.MinX and x <= tile.MaxX and z >= tile.MinY and z <= tile.MaxY then
			targetTile = tile
			break
		end
	end

	if not targetTile then
		-- If the physics loop asks for a tile that isn't streamed in yet, panic-load it instantly
		for ty = 0, session.TilesY - 1 do
			for tx = 0, session.TilesX - 1 do
				local tileFolder = session.Folder:FindFirstChild(string.format("Tile_%d_%d", tx, ty)) :: Folder?
				if tileFolder then
					local minX = tileFolder:GetAttribute("minX") :: number
					local maxX = tileFolder:GetAttribute("maxX") :: number
					local minY = tileFolder:GetAttribute("minY") :: number
					local maxY = tileFolder:GetAttribute("maxY") :: number
					if x >= minX and x <= maxX and z >= minY and z <= maxY then
						targetTile = loadTile(session, tx, ty)
						break
					end
				end
			end
			if targetTile then break end
		end
	end

	if not targetTile then
		return session.MinH, Vector3.new(0, 1, 0), 0 
	end

	local tile = targetTile :: TileData
	local w, h = tile.Width, tile.Height

	local u = ((x - tile.MinX) / (tile.MaxX - tile.MinX)) * w
	local v = ((tile.MaxY - z) / (tile.MaxY - tile.MinY)) * h

	local su = math.clamp(math.round(u), 0, w - 1)
	local sv = math.clamp(math.round(v), 0, h - 1)
	local surfaceId = buffer.readu8(tile.SurfaceBuffer, sv * w + su)

	local u0, v0 = math.floor(u), math.floor(v)
	local u1, v1 = u0 + 1, v0 + 1
	local tx_weight, ty_weight = u - u0, v - v0

	local h00 = getCellHeight(tile.HeightBuffer, u0, v0, w, h)
	local h10 = getCellHeight(tile.HeightBuffer, u1, v0, w, h)
	local h01 = getCellHeight(tile.HeightBuffer, u0, v1, w, h)
	local h11 = getCellHeight(tile.HeightBuffer, u1, v1, w, h)

	local h0 = h00 + tx_weight * (h10 - h00)
	local h1 = h01 + tx_weight * (h11 - h01)
	local rawHeight = h0 + ty_weight * (h1 - h0)

	local finalHeight = session.MinH + (rawHeight / 65535) * (session.MaxH - session.MinH)

	local gridSpacingX = (tile.MaxX - tile.MinX) / w
	local gridSpacingZ = (tile.MaxY - tile.MinY) / h

	local dh_du = (h10 - h00) * (1 - ty_weight) + (h11 - h01) * ty_weight
	local dh_dv = (h01 - h00) * (1 - tx_weight) + (h11 - h10) * tx_weight

	local dh_dx = (dh_du / 65535) * (session.MaxH - session.MinH) / gridSpacingX
	local dh_dz = -(dh_dv / 65535) * (session.MaxH - session.MinH) / gridSpacingZ 

	local normal = Vector3.new(-dh_dx, 1, -dh_dz).Unit

	return finalHeight, normal, surfaceId
end

return CourseLoader