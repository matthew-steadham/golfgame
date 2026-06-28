local pieces = {}
for i = 1, #script:GetChildren() do
	local child = script:FindFirstChild("Part_" .. i)
	if child and child:IsA("ModuleScript") then
		table.insert(pieces, require(child))
	end
end
return table.concat(pieces)
