--!strict
-- CourseData.luau  (ModuleScript in ReplicatedStorage)
--
-- Authoring: in workspace.CourseMarkers create one Folder per hole named with its
-- number (e.g. "Hole01"). Inside each: a "Tee" Part, a "Pin" Part, and optionally
-- an "Aim" Folder holding ordered Parts "A1", "A2", ... (the intended landing line).
-- Give each hole Folder a "Par" attribute.
--
-- Runtime:
--   local holes = CourseData.load(workspace.CourseMarkers)
--   local target = CourseData.aimTarget(holes[n], ballXZ)  -- Vector2 to aim at

export type Hole = {
	number: number,
	par: number,
	teeXZ: Vector2,
	pinXZ: Vector2,
	line: { Vector2 },   -- tee -> aim points -> pin
}

local CourseData = {}

local function xz(p: BasePart): Vector2
	return Vector2.new(p.Position.X, p.Position.Z)
end

function CourseData.load(root: Instance): { Hole }
	local holes: { Hole } = {}
	for _, hf in root:GetChildren() do
		local n = tonumber(string.match(hf.Name, "%d+"))
		local tee = hf:FindFirstChild("Tee")
		local pin = hf:FindFirstChild("Pin")
		if n and tee and tee:IsA("BasePart") and pin and pin:IsA("BasePart") then
			local line = { xz(tee) }
			local aim = hf:FindFirstChild("Aim")
			if aim then
				local pts = {}
				for _, p in aim:GetChildren() do
					if p:IsA("BasePart") then table.insert(pts, p) end
				end
				table.sort(pts, function(a, b) return a.Name < b.Name end) -- A1, A2, ...
				for _, p in pts do table.insert(line, xz(p)) end
			end
			table.insert(line, xz(pin))
			holes[n] = {
				number = n,
				par = (hf:GetAttribute("Par") :: number?) or 4,
				teeXZ = xz(tee),
				pinXZ = xz(pin),
				line = line,
			}
		end
	end
	return holes
end

-- Where to aim for a shot taken from ballXZ: the next strategic point down the
-- hole. From the tee this is the fairway landing (or the pin on a par 3); once the
-- ball is past a landing point, the aim advances to the next, then to the flag.
function CourseData.aimTarget(hole: Hole, ballXZ: Vector2): Vector2
	local line = hole.line
	if #line < 2 then return hole.pinXZ end

	-- cumulative length to each vertex
	local cum = table.create(#line)
	cum[1] = 0
	for i = 2, #line do
		cum[i] = cum[i - 1] + (line[i] - line[i - 1]).Magnitude
	end

	-- project the ball onto the polyline -> how far it has progressed
	local prog = 0
	for i = 1, #line - 1 do
		local a, b = line[i], line[i + 1]
		local ab = b - a
		local len2 = ab:Dot(ab)
		local t = if len2 > 0 then math.clamp((ballXZ - a):Dot(ab) / len2, 0, 1) else 0
		prog = math.max(prog, cum[i] + t * (b - a).Magnitude)
	end

	-- aim at the first vertex beyond the ball's progress (2-stud deadband)
	for j = 2, #line do
		if cum[j] > prog + 2 then return line[j] end
	end
	return hole.pinXZ
end

return CourseData
