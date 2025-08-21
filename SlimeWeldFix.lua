local SlimeWeldFix = {}

function SlimeWeldFix.Fix(model)
	if not model or not model.PrimaryPart then return end
	local inner = model.PrimaryPart
	inner.RootPriority = 100  -- dominate root selection
	inner.Massless = false     -- keep real mass here

	-- Remove existing weld constraints so we can rebuild
	for _,wc in ipairs(model:GetDescendants()) do
		if wc:IsA("WeldConstraint") then wc:Destroy() end
	end

	for _,part in ipairs(model:GetChildren()) do
		if part:IsA("BasePart") and part ~= inner then
			part.Massless = true
			part.Anchored = false
			-- Rebuild weld with inner as Part0
			local w = Instance.new("WeldConstraint")
			w.Part0 = inner
			w.Part1 = part
			w.Parent = inner
			-- Optional: disable collisions on decorative parts
			if part.Name ~= "Outer" then
				part.CanCollide = false
			end
		end
	end

	-- Final sanity: if after a physics step the root is still not inner, fall back to switching PrimaryPart
	task.delay(0.05, function()
		if inner.AssemblyRootPart ~= inner then
			warn("[SlimeWeldFix] Inner still not root; promoting real root as primary.")
			model.PrimaryPart = inner.AssemblyRootPart
		end
	end)
end

return SlimeWeldFix