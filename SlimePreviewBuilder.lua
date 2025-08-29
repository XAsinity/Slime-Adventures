-- SlimePreviewBuilder.lua
-- Builds a non-interactive preview model for a captured slime tool (client/server-safe).
-- Updated to avoid an infinite-yield on WaitForChild("ColorUtil") by using a tolerant,
-- short-timeout lookup across likely ModuleScript locations and a fallback stub.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- Safe module resolver: attempts to find and require a ModuleScript by name from a few places.
-- Will wait up to `timeout` seconds (default 2s) but will not yield indefinitely.
local function safeRequireModule(name, timeout)
	timeout = timeout or 2
	local startT = os.clock()

	local searchLocations = {
		-- Common places where "Modules" folder may be located
		ReplicatedStorage:FindFirstChild("Modules"),
		ServerScriptService:FindFirstChild("Modules"),
		-- fallback to the script's parent (same folder as this ModuleScript)
		script.Parent,
	}

	-- Try immediate finds first
	local found = nil
	for _, loc in ipairs(searchLocations) do
		if loc and loc.FindFirstChild then
			local candidate = loc:FindFirstChild(name)
			if candidate and candidate:IsA("ModuleScript") then
				found = candidate
				break
			end
		end
	end

	-- If not found immediately, poll briefly up to timeout
	while not found and (os.clock() - startT) < timeout do
		for _, loc in ipairs(searchLocations) do
			if loc and loc.FindFirstChild then
				local candidate = loc:FindFirstChild(name)
				if candidate and candidate:IsA("ModuleScript") then
					found = candidate
					break
				end
			end
		end
		if found then break end
		task.wait(0.1)
	end

	if not found then
		return nil, ("Module %s not found in expected locations within %.2fs"):format(name, timeout)
	end

	local ok, moduleOrErr = pcall(require, found)
	if not ok then
		return nil, ("Failed to require %s: %s"):format(name, tostring(moduleOrErr))
	end
	return moduleOrErr, nil
end

-- Try to require ColorUtil safely
local ColorUtil, err = safeRequireModule("ColorUtil", 2)
if not ColorUtil then
	warn("[SlimePreviewBuilder] ColorUtil not found via safeRequire:", tostring(err))
	-- Provide a minimal fallback to avoid hard failures. Behavior is reduced but non-blocking.
	ColorUtil = {}

	function ColorUtil.HexToColor(hex)
		if type(hex) ~= "string" or #hex < 6 then return nil end
		hex = hex:gsub("^#","")
		local r = tonumber(hex:sub(1,2),16)
		local g = tonumber(hex:sub(3,4),16)
		local b = tonumber(hex:sub(5,6),16)
		if not r or not g or not b then return nil end
		return Color3.fromRGB(r,g,b)
	end

	function ColorUtil.ColorToHex(c)
		if typeof(c) ~= "Color3" then return "000000" end
		return string.format("%02X%02X%02X",
			math.floor(c.R*255+0.5),
			math.floor(c.G*255+0.5),
			math.floor(c.B*255+0.5))
	end

	warn("[SlimePreviewBuilder] Using fallback ColorUtil stub; slime preview color decoding may be reduced.")
end

local SlimePreviewBuilder = {}

local SLIME_TEMPLATE_PATH = {"Assets","Slime"}
local MIN_PART_AXIS = 0.05

local function findTemplate()
	local node = ReplicatedStorage
	for _,seg in ipairs(SLIME_TEMPLATE_PATH) do
		node = node and node:FindFirstChild(seg)
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
	if typeof(v) == "Color3" then return v end
	if type(v) == "string" then
		local ok, col = pcall(function() return ColorUtil.HexToColor(v) end)
		if ok then return col end
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