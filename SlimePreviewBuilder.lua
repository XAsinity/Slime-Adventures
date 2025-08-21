-- SlimePreviewBuilder.lua
-- Builds a non-interactive preview model for a captured slime tool (client-side).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ColorUtil = require(ReplicatedStorage.Modules:WaitForChild("ColorUtil"))

local SlimePreviewBuilder = {}

local SLIME_TEMPLATE_PATH = {"Assets","Slime"}
local MIN_PART_AXIS = 0.05

local function findTemplate()
	local node = ReplicatedStorage
	for _,seg in ipairs(SLIME_TEMPLATE_PATH) do
		node = node:FindFirstChild(seg)
		if not node then return nil end
	end
	if node and node:IsA("Model") then return node end
	return nil
end

local function deepClone(template)
	local clone = template:Clone()
	for _,d in ipairs(clone:GetDescendants()) do
		if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ModuleScript") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
		end
	end
	return clone
end

local function applyScale(model, scale)
	for _,p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			local s = p.Size * scale
			p.Size = Vector3.new(
				math.max(s.X, MIN_PART_AXIS),
				math.max(s.Y, MIN_PART_AXIS),
				math.max(s.Z, MIN_PART_AXIS)
			)
		end
	end
end

local function decodeColor(v)
	if typeof(v)=="Color3" then return v end
	if type(v)=="string" then
		return ColorUtil.HexToColor(v)
	end
	return nil
end

local function applyColors(model, attrs)
	local bc = decodeColor(attrs.BodyColor or attrs.bc)
	local ac = decodeColor(attrs.AccentColor or attrs.ac)
	local ec = decodeColor(attrs.EyeColor or attrs.ec)

	if not (bc or ac or ec) then return end
	for _,p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			local lname = p.Name:lower()
			if ec and (lname:find("eye") or lname:find("pupil")) then
				p.Color = ec
			elseif bc then
				p.Color = bc
			end
		end
	end
end

function SlimePreviewBuilder.BuildFromTool(tool)
	if not tool then return nil end

	local attrs = {}
	for _,a in ipairs({
		"SlimeId","Rarity","GrowthProgress","MaxSizeScale","StartSizeScale",
		"CurrentSizeScale","BodyColor","AccentColor","EyeColor","MutationStage"
		}) do
		attrs[a] = tool:GetAttribute(a)
	end

	local template = findTemplate()
	local model
	if template then
		model = deepClone(template)
	else
		model = Instance.new("Model")
		model.Name = "SlimePreview"
		local part = Instance.new("Part")
		part.Size = Vector3.new(2,2,2)
		part.Anchored = true
		part.Name = "Body"
		part.Parent = model
		model.PrimaryPart = part
	end
	model.Name = "SlimePreview"

	local scale = attrs.CurrentSizeScale or attrs.StartSizeScale
	if not scale and attrs.GrowthProgress and attrs.MaxSizeScale then
		scale = attrs.GrowthProgress * attrs.MaxSizeScale
	end
	if not scale then scale = 1 end
	applyScale(model, scale)
	applyColors(model, attrs)

	model:SetAttribute("Preview", true)
	model:SetAttribute("SlimeId", attrs.SlimeId or "Unknown")

	return model
end

return SlimePreviewBuilder