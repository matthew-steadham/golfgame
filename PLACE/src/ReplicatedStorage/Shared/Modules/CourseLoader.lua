--!strict
local CourseLoader = {}

type TileMeta = {
	Key: string,
	Folder: Folder,
	MinX: number, MaxX: number,
	MinY: number, MaxY: number,
	CenterX: number, CenterY: number,
	Width: number,
	Height: number,
}

type TileData = {
	HeightBuffer: buffer,
	SurfaceBuffer: buffer,
	Width: number,
	Height: number,
	MinX: number, MaxX: number,
	MinY: number, MaxY: number,
	CenterX: number, CenterY: number, -- Precalculated for fast distance checks
	InvSizeX: number,
	InvSizeY: number,
	GridSpacingX: number,
	GridSpacingZ: number,
}

type CourseSession = {
	Folder: Folder,
	TilesX: number,
	TilesY: number,
	MinH: number,
	MaxH: number,
	HeightRange: number,
	StudsPerMeter: number,
	Tiles: { TileMeta },
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

local function readTileMeta(folder: Folder, tx: number, ty: number): TileMeta?
	local tileFolder = folder:FindFirstChild(string.format("Tile_%d_%d", tx, ty))
	if not tileFolder or not tileFolder:IsA("Folder") then
		return nil
	end
	local tile = tileFolder :: Folder

	local minX = tile:GetAttribute("minX") :: number
	local maxX = tile:GetAttribute("maxX") :: number
	local minY = tile:GetAttribute("minY") :: number
	local maxY = tile:GetAttribute("maxY") :: number

	return {
		Key = getTileKey(tx, ty),
		Folder = tile,
		MinX = minX, MaxX = maxX,
		MinY = minY, MaxY = maxY,
		CenterX = (minX + maxX) / 2,
		CenterY = (minY + maxY) / 2,
		Width = tile:GetAttribute("width") :: number,
		Height = tile:GetAttribute("height") :: number,
	}
end

local function contains(minX: number, maxX: number, minY: number, maxY: number, x: number, z: number): boolean
	return x >= minX and x <= maxX and z >= minY and z <= maxY
end

-- Core loading function for a specific tile
local function loadTile(session: CourseSession, meta: TileMeta): TileData?
	local cached = session.LoadedTiles[meta.Key]
	if cached then return cached end

	local tileFolder = meta.Folder
	local rawHeightString = require(tileFolder:WaitForChild("Height") :: ModuleScript) :: string
	local rawSurfaceString = require(tileFolder:WaitForChild("Surface") :: ModuleScript) :: string

	local sizeX = meta.MaxX - meta.MinX
	local sizeY = meta.MaxY - meta.MinY

	local tileData: TileData = {
		HeightBuffer = buffer.fromstring(rawHeightString),
		SurfaceBuffer = buffer.fromstring(rawSurfaceString),
		Width = meta.Width,
		Height = meta.Height,
		MinX = meta.MinX, MaxX = meta.MaxX,
		MinY = meta.MinY, MaxY = meta.MaxY,
		CenterX = meta.CenterX, CenterY = meta.CenterY,
		InvSizeX = if sizeX ~= 0 then 1 / sizeX else 0,
		InvSizeY = if sizeY ~= 0 then 1 / sizeY else 0,
		GridSpacingX = sizeX / meta.Width,
		GridSpacingZ = sizeY / meta.Height,
	}

	session.LoadedTiles[meta.Key] = tileData
	return tileData
end

function CourseLoader.Load(courseName: string)
	if activeSessions[courseName] then return activeSessions[courseName] end

	local folder = game:GetService("ReplicatedStorage"):WaitForChild("CourseData"):WaitForChild(courseName) :: Folder
	local tilesX = folder:GetAttribute("tilesX") :: number
	local tilesY = folder:GetAttribute("tilesY") :: number
	local minH = folder:GetAttribute("minH") :: number
	local maxH = folder:GetAttribute("maxH") :: number
	local tiles: { TileMeta } = table.create(tilesX * tilesY)

	for ty = 0, tilesY - 1 do
		for tx = 0, tilesX - 1 do
			local meta = readTileMeta(folder, tx, ty)
			if meta then
				tiles[#tiles + 1] = meta
			end
		end
	end

	activeSessions[courseName] = {
		Folder = folder,
		TilesX = tilesX,
		TilesY = tilesY,
		MinH = minH,
		MaxH = maxH,
		HeightRange = maxH - minH,
		StudsPerMeter = folder:GetAttribute("studsPerMeter") :: number,
		Tiles = tiles,
		LoadedTiles = {}
	}

	return activeSessions[courseName]
end

--- Run this periodically (e.g., every 0.5 seconds or whenever the ball moves significantly)
--- to stream tiles in and out around a focal world position (X, Z).
function CourseLoader.UpdateStreaming(courseName: string, focalX: number, focalZ: number)
	local session = activeSessions[courseName]
	if not session then return end

	local radiusSq = STREAM_RADIUS * STREAM_RADIUS
	for _, meta in session.Tiles do
		local dx = focalX - meta.CenterX
		local dz = focalZ - meta.CenterY
		local tileKey = meta.Key

		if dx * dx + dz * dz <= radiusSq then
			if not session.LoadedTiles[tileKey] then
				loadTile(session, meta)
			end
		elseif session.LoadedTiles[tileKey] then
			session.LoadedTiles[tileKey] = nil :: any
		end
	end
end

function CourseLoader.GetTerrainData(courseName: string, x: number, z: number)
	local session = activeSessions[courseName]
	if not session then error("Course session not loaded: " .. courseName) end

	local targetTile: TileData? = nil
	for _, tile in session.LoadedTiles do
		if contains(tile.MinX, tile.MaxX, tile.MinY, tile.MaxY, x, z) then
			targetTile = tile
			break
		end
	end

	if not targetTile then
		-- If the physics loop asks for a tile that isn't streamed in yet, panic-load it instantly
		for _, meta in session.Tiles do
			if contains(meta.MinX, meta.MaxX, meta.MinY, meta.MaxY, x, z) then
				targetTile = loadTile(session, meta)
				break
			end
		end
	end

	if not targetTile then
		return session.MinH, Vector3.new(0, 1, 0), 0
	end

	local tile = targetTile :: TileData
	local w, h = tile.Width, tile.Height

	local u = ((x - tile.MinX) * tile.InvSizeX) * w
	local v = ((tile.MaxY - z) * tile.InvSizeY) * h

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

	local heightRange = session.HeightRange
	local finalHeight = session.MinH + (rawHeight / 65535) * heightRange

	local dh_du = (h10 - h00) * (1 - ty_weight) + (h11 - h01) * ty_weight
	local dh_dv = (h01 - h00) * (1 - tx_weight) + (h11 - h10) * tx_weight

	local dh_dx = (dh_du / 65535) * heightRange / tile.GridSpacingX
	local dh_dz = -(dh_dv / 65535) * heightRange / tile.GridSpacingZ

	local normal = Vector3.new(-dh_dx, 1, -dh_dz).Unit

	return finalHeight, normal, surfaceId
end

return CourseLoader
