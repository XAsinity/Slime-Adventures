local ModelUtils = {}

local REMOVE_CLASSES = {
	BodyVelocity=true,BodyAngularVelocity=true,BodyPosition=true,BodyGyro=true,
	BodyForce=true,BodyThrust=true,AlignPosition=true,AlignOrientation=true,
	VectorForce=true,LinearVelocity=true,AngularVelocity=true
}

local function isPart(x) return x:IsA("BasePart") end

function ModelUtils.CleanPhysics(model)
	for _,d in ipairs(model:GetDescendants()) do
		if REMOVE_CLASSES[d.ClassName] then d:Destroy() end
	end
end

function ModelUtils.AutoWeld(model, primary)
	primary = primary or model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	if not primary then return nil end
	if model.PrimaryPart ~= primary then model.PrimaryPart = primary end

	-- Anchor everything first
	for _,d in ipairs(model:GetDescendants()) do
		if isPart(d) then
			d.Anchored = true
			d.Massless = (d ~= primary)
		end
	end

	-- Clear existing welds from primary
	for _,c in ipairs(primary:GetChildren()) do
		if c:IsA("WeldConstraint") then c:Destroy() end
	end

	for _,d in ipairs(model:GetDescendants()) do
		if isPart(d) and d ~= primary then
			for _,c in ipairs(d:GetChildren()) do
				if c:IsA("WeldConstraint") then c:Destroy() end
			end
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = primary
			weld.Part1 = d
			weld.Parent = primary
		end
	end

	primary.Anchored = false
	for _,d in ipairs(model:GetDescendants()) do
		if isPart(d) and d ~= primary then
			d.Anchored = false
		end
	end
	return primary
end

function ModelUtils.UniformScale(model, scale)
	if not scale or scale == 1 then return end
	for _,d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Size = d.Size * scale
		end
	end
end

return ModelUtils