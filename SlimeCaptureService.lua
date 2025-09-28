-- SlimeCaptureService.lua
-- Consolidated: merged SlimePreviewBuilder logic into this module so captured-tool visuals
-- can be rebuilt on rejoin / restore. Hardened attribute reads at capture-time to ensure
-- captured tools always carry value/scale/color attributes suitable for serializer persistence.
-- PATCH: Mark newly-created captured tools as PreserveOnServer=true and ServerIssued=true
-- to ensure serializers include them when collecting capturedSlimes (temporary mitigation).
-- PATCH 2: Infer MaxSizeScale when it's missing at capture-time so visuals built from
--           GrowthProgress render at the correct fractional size instead of defaulting to 1.
-----------------------------------------------------------------------

local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local HttpService        = game:GetService("HttpService")
local RunService         = game:GetService("RunService")
local ServerModules      = game:GetService("ServerScriptService").Modules
local PlayerProfileService = require(ServerModules:WaitForChild("PlayerProfileService"))
local InventoryService     = require(ServerModules:WaitForChild("InventoryService"))

local Remotes       = ReplicatedStorage:WaitForChild("Remotes")
local PickupRequest = Remotes:WaitForChild("SlimePickupRequest")
local PickupResult  = Remotes:WaitForChild("SlimePickupResult")

local TOOL_TEMPLATES = ReplicatedStorage:WaitForChild("ToolTemplates")
local TOOL_TEMPLATE  = TOOL_TEMPLATES:FindFirstChild("CapturedSlimeTool")

local ASSETS = ReplicatedStorage:FindFirstChild("Assets")

local CONFIG = {
	MaxCaptureDistance      = 60,
	ValuePerGrowth          = 1.0,
	BASE_WEIGHT_LBS         = 15,
	PlayerCaptureCooldown   = 1.0,
	StripScriptsInToolCopy  = true,
	Debug                   = false,

	USE_GENERIC_CAPTURED_TOOL_NAME = true,
	GENERIC_CAPTURED_NAME          = "CapturedSlime",

	-- Save behavior
	ImmediateSave             = true,
	SaveReason                = "PostCapture",
	WaitHeartbeatBeforeSave   = true,
	SaveDelayAfterDestroy     = 0.05,

	-- Diagnostics: post-capture inventory audit
	PostSaveAuditLog          = true,
	PostSaveAuditDelay        = 0.1,

	-- Visual restore
	SlimeTemplatePath         = {"Assets","Slime"},
	PreviewFolderName         = "CapturedPreviews",
}

local lastCaptureAt = {}

local function dprint(...)
	if CONFIG.Debug then
		print("[SlimeCaptureService]", ...)
	end
end

local function warnlog(...)
	warn("[SlimeCaptureService]", ...)
end

-- Utility: safe attribute extraction and color->hex helpers
local function toHex6(c)
	if typeof and typeof(c) == "Color3" then
		return string.format("%02X%02X%02X",
			math.floor(c.R*255+0.5),
			math.floor(c.G*255+0.5),
			math.floor(c.B*255+0.5))
	end
	if type(c) == "string" then
		local s = c:gsub("^#","")
		if #s == 6 then return s:upper() end
	end
	return "FFFFFF"
end

local function normalizeHex(val, fallback)
	if typeof and typeof(val) == "Color3" then return toHex6(val) end
	if type(val) == "string" then
		val = val:gsub("^#","")
		if #val == 6 then return val:upper() end
	end
	if typeof and typeof(fallback) == "Color3" then return toHex6(fallback) end
	return "FFFFFF"
end

local function findPrimary(model)
	if not model then return nil end
	if model.PrimaryPart then return model.PrimaryPart end
	for _, c in ipairs(model:GetChildren()) do
		if c:IsA("BasePart") then
			model.PrimaryPart = c
			return c
		end
	end
	return nil
end

local function isFiniteNumber(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function computeValueBase(valueFull, perGrowth)
	valueFull   = (valueFull and valueFull > 0) and valueFull or 150
	perGrowth   = perGrowth or CONFIG.ValuePerGrowth
	local denom = 1 + perGrowth
	if denom <= 0 then denom = 1 end
	return math.max(1, math.floor(valueFull / denom))
end

-- Safer computeWeightLbs: attempt attribute read via pcall and primary part fallback
local function computeWeightLbs(slime)
	local scale = 1
	if slime and type(slime.GetAttribute) == "function" then
		local ok, v = pcall(function() return slime:GetAttribute("CurrentSizeScale") end)
		if ok and type(v) == "number" then scale = v end
	end
	if type(scale) ~= "number" then
		local prim = findPrimary(slime)
		if prim and type(prim.GetAttribute) == "function" then
			local ok2, v2 = pcall(function() return prim:GetAttribute("CurrentSizeScale") end)
			if ok2 and type(v2) == "number" then scale = v2 end
		end
	end
	if type(scale) ~= "number" or scale <= 0 then scale = 1 end
	return (scale ^ 3) * CONFIG.BASE_WEIGHT_LBS
end

-- read a child Value instance by name (NumberValue/StringValue/etc.)
local function readChildValue(inst, name)
	if not inst or type(inst.FindFirstChild) ~= "function" then return nil end
	local c = inst:FindFirstChild(name)
	if not c then return nil end
	if c.Value ~= nil then return c.Value end
	return nil
end

-- readModelAttribute with multiple fallbacks and legacy names table
local function readModelAttribute(model, name, legacyKeys)
	if not model then return nil end
	-- try model attribute
	if type(model.GetAttribute) == "function" then
		local ok, v = pcall(function() return model:GetAttribute(name) end)
		if ok and v ~= nil then return v end
	end
	-- try primary part attribute
	local prim = findPrimary(model)
	if prim and type(prim.GetAttribute) == "function" then
		local ok2, v2 = pcall(function() return prim:GetAttribute(name) end)
		if ok2 and v2 ~= nil then return v2 end
	end
	-- try child Value on model or prim
	local ch = readChildValue(model, name)
	if ch ~= nil then return ch end
	if prim then
		local ch2 = readChildValue(prim, name)
		if ch2 ~= nil then return ch2 end
	end
	-- legacy keys
	if legacyKeys and type(legacyKeys) == "table" then
		for _, k in ipairs(legacyKeys) do
			if type(model.GetAttribute) == "function" then
				local okk, vv = pcall(function() return model:GetAttribute(k) end)
				if okk and vv ~= nil then return vv end
			end
			if prim and type(prim.GetAttribute) == "function" then
				local okp, vvp = pcall(function() return prim:GetAttribute(k) end)
				if okp and vvp ~= nil then return vvp end
			end
			local cv = readChildValue(model, k)
			if cv ~= nil then return cv end
			if prim then
				local cv2 = readChildValue(prim, k)
				if cv2 ~= nil then return cv2 end
			end
		end
	end
	return nil
end

-- clone visual model into tool
local function cloneVisual(slime, tool)
	if not slime or not tool then return nil end
	local clone = slime:Clone()
	local partCount = 0
	if CONFIG.StripScriptsInToolCopy then
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ModuleScript") then
				pcall(function() d:Destroy() end)
			elseif d:IsA("BasePart") then
				d.CanCollide = false
				d.CanTouch   = false
				d.CanQuery   = false
				pcall(function() d.Massless = true end)
				d.Anchored   = false
				partCount += 1
			end
		end
	else
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then
				d.CanCollide = false
				pcall(function() d.Massless = true end)
				partCount += 1
			end
		end
	end
	clone.Name = "SlimeVisual"
	clone.Parent = tool
	pcall(function() tool:SetAttribute("SlimmedVisualParts", partCount) end)
	return clone
end

-- weld visual to handle
local function weldVisual(tool)
	local handle = tool:FindFirstChild("Handle")
	local visual = tool:FindFirstChild("SlimeVisual")
	if not (handle and visual and visual:IsA("Model")) then return end
	local prim = visual.PrimaryPart or findPrimary(visual)
	if not prim then return end
	pcall(function() visual:PivotTo(handle.CFrame) end)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = handle
	weld.Part1 = prim
	weld.Parent = handle
	for _, p in ipairs(visual:GetDescendants()) do
		if p:IsA("BasePart") and p ~= prim then
			local w = Instance.new("WeldConstraint")
			w.Part0 = prim
			w.Part1 = p
			w.Parent = p
			p.CanCollide = false
			pcall(function() p.Massless = true end)
		end
	end
end

local FULL_ATTR_LIST = {
	"GrowthProgress","CurrentValue","ValueFull","ValueBase","ValuePerGrowth",
	"MutationStage","Tier","WeightPounds","FedFraction","BodyColor","AccentColor","EyeColor",
	"MovementScalar","WeightScalar","MutationRarityBonus",
	"MaxSizeScale","StartSizeScale","CurrentSizeScale","SizeLuckRolls",
	"FeedBufferSeconds","FeedBufferMax","HungerDecayRate","CurrentFullness",
	"FeedSpeedMultiplier","LastHungerUpdate","Rarity",
}

-- Hardened buildTool: read attributes from model defensively and compute sensible defaults
local function buildTool(slime, player)
	if not TOOL_TEMPLATE then
		return nil, "Missing CapturedSlimeTool template"
	end
	if not slime then
		return nil, "Missing slime model"
	end

	local tool = TOOL_TEMPLATE:Clone()
	pcall(function() tool:SetAttribute("PersistentCaptured", true) end)

	if CONFIG.USE_GENERIC_CAPTURED_TOOL_NAME then
		tool.Name = CONFIG.GENERIC_CAPTURED_NAME
	else
		tool.Name = "CapturedSlime"
	end

	-- read helpers with legacy keys
	local function r(key, legacy)
		return readModelAttribute(slime, key, legacy)
	end

	local slimeId = r("SlimeId", {"id","Id"}) or HttpService:GenerateGUID(false)

	local growthRaw = r("GrowthProgress", {"gp","growth"})
	local growth = tonumber(growthRaw) or 0
	if growth < 0 then growth = 0 end
	if growth > 1 then growth = 1 end

	local valueFull = tonumber(r("ValueFull", {"Value","vf"})) or 150
	local valuePerGrowth = tonumber(r("ValuePerGrowth", {"vg"})) or CONFIG.ValuePerGrowth

	local currentValue = tonumber(r("CurrentValue", {"cv"}))
	if not currentValue then
		currentValue = math.floor((valueFull or 150) * (growth or 0))
	end

	local valueBase = tonumber(r("ValueBase")) or computeValueBase(valueFull, valuePerGrowth)
	local weightLbs = tonumber(r("WeightPounds")) or computeWeightLbs(slime)
	local rarity = r("Rarity") or "Common"

	-- === New: read size attributes early and infer MaxSizeScale when missing ===
	local curScaleRaw = r("CurrentSizeScale")
	local startScaleRaw = r("StartSizeScale")
	local maxScaleRaw = r("MaxSizeScale")

	local curScale = tonumber(curScaleRaw)
	local startScale = tonumber(startScaleRaw)
	local maxScale = tonumber(maxScaleRaw)

	-- If MaxSizeScale is missing but we have a current scale and a growth fraction,
	-- infer MaxSizeScale = CurrentSizeScale / GrowthProgress, with safety clamps.
	if (not maxScale) and curScale and isFiniteNumber(curScale) and growth and growth > 0 then
		local inferred = curScale / math.max(growth, 0.01) -- avoid division by tiny numbers
		-- clamp inferred to a reasonable range to avoid nonsense values
		if inferred and isFiniteNumber(inferred) and inferred > 0 and inferred < 100 then
			maxScale = inferred
			dprint(("Inferred MaxSizeScale=%.4f from CurrentSizeScale=%.4f and GrowthProgress=%.4f"):format(maxScale, curScale, growth))
		end
	end
	-- ======================================================================

	local prim = findPrimary(slime)
	local baseBodyColor = prim and prim.Color or Color3.new(1,1,1)
	local bodyHex = normalizeHex(r("BodyColor"), baseBodyColor)
	local accentHex = normalizeHex(r("AccentColor"), Color3.new(1,1,1))
	local eyeHex = normalizeHex(r("EyeColor"), Color3.new(0,0,0))

	-- set canonical attributes (coerce types)
	pcall(function() tool:SetAttribute("SlimeItem", true) end)
	pcall(function() tool:SetAttribute("SlimeId", tostring(slimeId)) end)
	pcall(function() tool:SetAttribute("OwnerUserId", player and player.UserId or 0) end)
	pcall(function() tool:SetAttribute("CapturedAt", os.time()) end)

	pcall(function() tool:SetAttribute("GrowthProgress", tonumber(growth) or 0) end)
	pcall(function() tool:SetAttribute("ValueFull", tonumber(valueFull) or 150) end)
	pcall(function() tool:SetAttribute("ValueBase", tonumber(valueBase) or computeValueBase(valueFull, valuePerGrowth)) end)
	pcall(function() tool:SetAttribute("ValuePerGrowth", tonumber(valuePerGrowth) or CONFIG.ValuePerGrowth) end)
	pcall(function() tool:SetAttribute("CurrentValue", tonumber(currentValue) or 0) end)
	pcall(function() tool:SetAttribute("WeightPounds", tonumber(weightLbs) or computeWeightLbs(slime)) end)
	pcall(function() tool:SetAttribute("Rarity", tostring(rarity or "Common")) end)

	pcall(function() tool:SetAttribute("BodyColor", tostring(bodyHex)) end)
	pcall(function() tool:SetAttribute("AccentColor", tostring(accentHex)) end)
	pcall(function() tool:SetAttribute("EyeColor", tostring(eyeHex)) end)

	-- Ensure we persist any inferred/current size attributes so visual builder has what it needs
	if curScale and isFiniteNumber(curScale) then
		pcall(function() tool:SetAttribute("CurrentSizeScale", curScale) end)
	end
	if startScale and isFiniteNumber(startScale) then
		pcall(function() tool:SetAttribute("StartSizeScale", startScale) end)
	end
	if maxScale and isFiniteNumber(maxScale) then
		pcall(function() tool:SetAttribute("MaxSizeScale", maxScale) end)
	end

	-- copy remaining attributes if present
	for _, attr in ipairs(FULL_ATTR_LIST) do
		if tool:GetAttribute(attr) == nil then
			local v = r(attr)
			if v ~= nil then
				if attr == "BodyColor" or attr == "AccentColor" or attr == "EyeColor" then
					v = normalizeHex(v)
				end
				-- coerce numeric-like strings to numbers
				local nv = tonumber(v)
				if nv ~= nil then v = nv end
				pcall(function() tool:SetAttribute(attr, v) end)
			end
		end
	end

	-- ensure unique id
	if not tool:GetAttribute("ToolUniqueId") then
		pcall(function() tool:SetAttribute("ToolUniqueId", HttpService:GenerateGUID(false)) end)
	end

	-- capture visual
	cloneVisual(slime, tool)
	weldVisual(tool)
	return tool
end

-- Best-effort removal of worldSlimes references (defensive)
local function removeWorldSlimeReferences(player, slimeId, toolUniqueId)
	if not slimeId then return end
	-- PlayerProfileService attempt
	pcall(function()
		if type(PlayerProfileService.RemoveInventoryItem) == "function" then
			PlayerProfileService.RemoveInventoryItem(player, "worldSlimes", { SlimeId = slimeId })
		elseif type(PlayerProfileService.RemoveInventoryItemByField) == "function" then
			PlayerProfileService.RemoveInventoryItemByField(player, "worldSlimes", "SlimeId", slimeId)
		end
	end)

	-- InventoryService attempt
	pcall(function()
		if type(InventoryService.RemoveInventoryItem) == "function" then
			-- try common signatures
			local ok1 = pcall(function() InventoryService.RemoveInventoryItem(player, "worldSlimes", "SlimeId", slimeId) end)
			if not ok1 then
				pcall(function() InventoryService.RemoveInventoryItem(player, "worldSlimes", { SlimeId = slimeId }) end)
			end
		end
		if type(InventoryService.RemoveInventoryItemByField) == "function" then
			pcall(function() InventoryService.RemoveInventoryItemByField(player, "worldSlimes", "SlimeId", slimeId) end)
		end
		if type(InventoryService.CancelPendingRestore) == "function" then
			pcall(function() InventoryService.CancelPendingRestore(player, "worldSlimes", slimeId) end)
		end
	end)

	dprint("removeWorldSlimeReferences attempted for", player and player.Name or "<nil>", slimeId)
end

-- ---------------------------
-- Slime preview builder (merged)
-- ---------------------------
local function findSlimeTemplate()
	local configured = CONFIG.SlimeTemplatePath
	local path = nil
	if type(configured) == "table" then
		path = configured
	elseif type(configured) == "string" then
		path = { configured }
	else
		path = { "Assets", "Slime" }
	end

	local node = ReplicatedStorage
	for _, seg in ipairs(path) do
		if not node then return nil end
		node = node:FindFirstChild(seg)
		if not node then return nil end
	end
	if node and node:IsA("Model") then return node end

	local assetsNode = ReplicatedStorage:FindFirstChild("Assets")
	if assetsNode then
		local s = assetsNode:FindFirstChild("Slime")
		if s and s:IsA("Model") then return s end
	end
	return nil
end

local function deepCloneAndSanitize(template)
	if not template then return nil end
	local clone = template:Clone()
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ModuleScript") then
			pcall(function() d:Destroy() end)
		elseif d:IsA("BasePart") then
			pcall(function()
				d.Anchored = false
				d.CanCollide = false
				d.CanTouch = false
				d.CanQuery = false
				pcall(function() d.Massless = true end)
			end)
		end
	end
	return clone
end

local function applyScaleToModel(model, scale)
	if not model or not scale then return end
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			local ok, orig = pcall(function() return p:GetAttribute("OriginalSize") end)
			local original = (ok and orig) or p.Size
			if not ok then p:SetAttribute("OriginalSize", original) end
			local ns = original * scale
			p.Size = Vector3.new(math.max(ns.X, 0.05), math.max(ns.Y, 0.05), math.max(ns.Z, 0.05))
		end
	end
	pcall(function() model:SetAttribute("CurrentSizeScale", scale) end)
end

local function decodeColorString(v)
	if typeof and typeof(v) == "Color3" then return v end
	if type(v) == "string" then
		local hex = v:gsub("^#","")
		if #hex == 6 then
			local r = tonumber(hex:sub(1,2),16)
			local g = tonumber(hex:sub(3,4),16)
			local b = tonumber(hex:sub(5,6),16)
			if r and g and b then return Color3.fromRGB(r,g,b) end
		end
	end
	return nil
end

local function applyColorsToModel(model, attrs)
	local bc = decodeColorString(attrs.BodyColor or attrs.bc)
	local ac = decodeColorString(attrs.AccentColor or attrs.ac)
	local ec = decodeColorString(attrs.EyeColor or attrs.ec)
	if not (bc or ac or ec) then return end
	for _, p in ipairs(model:GetDescendants()) do
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

local function BuildVisualFromTool(tool)
	if not tool or not tool:IsA("Tool") then return nil end
	if tool:FindFirstChild("SlimeVisual") then
		dprint("Tool already has SlimeVisual:", tool.Name)
		return tool:FindFirstChild("SlimeVisual")
	end

	local template = findSlimeTemplate()
	if not template then
		dprint("Slime template not found; cannot build visual for tool:", tool.Name)
		return nil
	end

	local model = deepCloneAndSanitize(template)
	model.Name = "SlimeVisual"

	local scale = tool:GetAttribute("CurrentSizeScale") or tool:GetAttribute("StartSizeScale")
	if not scale then
		local gp = tool:GetAttribute("GrowthProgress")
		local mx = tool:GetAttribute("MaxSizeScale")
		if gp and mx then scale = gp * mx end
	end
	if not scale then scale = 1 end

	applyScaleToModel(model, scale)
	local attrs = {
		BodyColor = tool:GetAttribute("BodyColor"),
		AccentColor = tool:GetAttribute("AccentColor"),
		EyeColor = tool:GetAttribute("EyeColor"),
		bc = tool:GetAttribute("BodyColor"),
		ac = tool:GetAttribute("AccentColor"),
		ec = tool:GetAttribute("EyeColor"),
	}
	applyColorsToModel(model, attrs)

	model.Parent = tool
	pcall(function() if not model.PrimaryPart then findPrimary(model) end end)
	local handle = tool:FindFirstChild("Handle")
	if handle and model.PrimaryPart then
		pcall(function() model:SetPrimaryPartCFrame(handle.CFrame) end)
	end

	weldVisual(tool)
	dprint("Built visual from tool attributes for", tool.Name, "SlimeId=", tostring(tool:GetAttribute("SlimeId")))
	return model
end

local function EnsureToolVisual(tool)
	if not tool or not tool:IsA("Tool") then return false end
	local okAttr, isSlime = pcall(function() return tool:GetAttribute("SlimeItem") end)
	if not okAttr or not isSlime then return false end
	if tool:FindFirstChild("SlimeVisual") then return true end

	local model = BuildVisualFromTool(tool)
	if not model then
		local handle = tool:FindFirstChild("Handle")
		if not handle then
			handle = Instance.new("Part")
			handle.Name = "Handle"
			handle.Size = Vector3.new(1,1,1)
			handle.CanCollide = false
			handle.Parent = tool
			tool.RequiresHandle = true
		end
		local marker = Instance.new("Part")
		marker.Name = "SlimeVisual"
		marker.Size = Vector3.new(0.6,0.6,0.6)
		marker.CanCollide = false
		marker.Anchored = false
		pcall(function() marker.Massless = true end)
		local color = decodeColorString(tool:GetAttribute("BodyColor")) or Color3.fromRGB(150,200,150)
		marker.Color = color
		marker.Parent = tool
		pcall(function()
			local w = Instance.new("WeldConstraint")
			w.Part0 = handle
			w.Part1 = marker
			w.Parent = handle
		end)
		dprint("Fallback visual created for tool:", tool.Name)
		return true
	end
	return true
end

local function RestorePlayerCapturedVisuals(player)
	if not player then return end
	task.defer(function()
		task.wait(0.15)
		local backpack = player:FindFirstChildOfClass("Backpack")
		local char = player.Character
		if backpack then
			for _, item in ipairs(backpack:GetChildren()) do
				pcall(function() EnsureToolVisual(item) end)
			end
		end
		if char then
			for _, item in ipairs(char:GetChildren()) do
				if item:IsA("Tool") then
					pcall(function() EnsureToolVisual(item) end)
				end
			end
		end
		if backpack and not backpack:FindFirstChild("__SlimeCaptureHooked") then
			local marker = Instance.new("Folder")
			marker.Name = "__SlimeCaptureHooked"
			marker.Parent = backpack
			backpack.ChildAdded:Connect(function(child)
				if child and child:IsA("Tool") then
					task.wait(0.03)
					pcall(function() EnsureToolVisual(child) end)
				end
			end)
		end
	end)
end

-- validate capture
local function validate(player, slime)
	if typeof and typeof(slime) ~= "Instance" then return false, "Not a slime." end
	if not slime or not slime:IsA("Model") or slime.Name ~= "Slime" then
		return false, "Not a slime."
	end
	if slime:GetAttribute("Capturing") then return false, "Busy." end
	local char = player.Character
	if not char then return false, "No character." end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then return false, "No HRP." end
	local prim = findPrimary(slime)
	if not prim then return false, "Invalid slime." end
	if (prim.Position - hrp.Position).Magnitude > CONFIG.MaxCaptureDistance then return false, "Too far." end
	local owner = slime:GetAttribute("OwnerUserId")
	if owner and owner ~= 0 and owner ~= player.UserId then return false, "Owned." end
	local now = os.clock()
	if now - (lastCaptureAt[player.UserId] or 0) < CONFIG.PlayerCaptureCooldown then return false, "Cooldown." end
	return true
end

local function perform(player, slime)
	local ok, err = validate(player, slime)
	if not ok then return false, err end
	lastCaptureAt[player.UserId] = os.clock()

	pcall(function() slime:SetAttribute("Capturing", true) end)
	pcall(function() slime:SetAttribute("Retired", true) end)

	local slimeId = nil
	do
		local v = readModelAttribute(slime, "SlimeId", {"id","Id"})
		slimeId = v or HttpService:GenerateGUID(false)
	end

	local tool, terr = buildTool(slime, player)
	if not tool then
		pcall(function() slime:SetAttribute("Capturing", nil) end)
		pcall(function() slime:SetAttribute("Retired", nil) end)
		return false, terr
	end

	if not tool:GetAttribute("ToolUniqueId") then
		pcall(function() tool:SetAttribute("ToolUniqueId", HttpService:GenerateGUID(false)) end)
	end

	local toolUniqueId = tool:GetAttribute("ToolUniqueId")

	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		pcall(function() tool:Destroy() end)
		pcall(function() slime:SetAttribute("Capturing", nil) end)
		pcall(function() slime:SetAttribute("Retired", nil) end)
		return false, "No backpack."
	end

	-- Put tool into backpack so InventoryService sees a live Tool instance
	tool.Parent = backpack

	-- mark tool as live
	pcall(function()
		-- PATCH: mark as preserved/server-issued so serializers that filter on these flags include this item.
		-- These are conservative, temporary markers to help Inventory/Serializer logic pick up the captured tool.
		tool:SetAttribute("ServerIssued", true)
		tool:SetAttribute("ServerRestore", false)
		tool:SetAttribute("PreserveOnServer", true)
		tool:SetAttribute("PreserveOnClient", false)
	end)

	local capturedData = {
		SlimeId = tool:GetAttribute("SlimeId"),
		ToolUniqueId = tool:GetAttribute("ToolUniqueId"),
		CapturedAt = tool:GetAttribute("CapturedAt"),
		OwnerUserId = player.UserId,
		Rarity = tool:GetAttribute("Rarity"),
		WeightPounds = tool:GetAttribute("WeightPounds"),
		CurrentValue = tool:GetAttribute("CurrentValue"),
		GrowthProgress = tool:GetAttribute("GrowthProgress"),
		BodyColor = tool:GetAttribute("BodyColor"),
		AccentColor = tool:GetAttribute("AccentColor"),
		EyeColor = tool:GetAttribute("EyeColor"),
		ValueFull = tool:GetAttribute("ValueFull"),
		ValueBase = tool:GetAttribute("ValueBase"),
	}

	-- Add to PlayerProfileService inventory
	local okAddProfile, addProfileErr = pcall(function()
		if type(PlayerProfileService.AddInventoryItem) == "function" then
			PlayerProfileService.AddInventoryItem(player, "capturedSlimes", capturedData)
		else
			error("PlayerProfileService.AddInventoryItem missing")
		end
	end)
	if not okAddProfile then
		warnlog("PlayerProfileService.AddInventoryItem failed:", tostring(addProfileErr))
		if tool and tool.Parent then pcall(function() tool:Destroy() end) end
		pcall(function() slime:SetAttribute("Capturing", nil) end)
		pcall(function() slime:SetAttribute("Retired", nil) end)
		return false, "Failed to add to profile inventory"
	end

	-- InventoryService runtime state
	pcall(function()
		if type(InventoryService.AddInventoryItem) == "function" then
			InventoryService.AddInventoryItem(player, "capturedSlimes", capturedData)
		end
	end)

	-- remove worldSlime references
	pcall(function() removeWorldSlimeReferences(player, slimeId, toolUniqueId) end)

	-- Destroy world slime model
	pcall(function() slime:Destroy() end)

	-- Ensure visual exists for the tool (idempotent)
	pcall(function() EnsureToolVisual(tool) end)

	-- Persist immediately if configured
	if CONFIG.ImmediateSave then
		if CONFIG.WaitHeartbeatBeforeSave then
			RunService.Heartbeat:Wait()
		end
		if CONFIG.SaveDelayAfterDestroy and CONFIG.SaveDelayAfterDestroy > 0 then
			task.wait(CONFIG.SaveDelayAfterDestroy)
		end

		local okSave, saveRes = pcall(function()
			if type(PlayerProfileService.SaveNowAndWait) == "function" then
				return PlayerProfileService.SaveNowAndWait(player, 3, true)
			elseif type(PlayerProfileService.ForceFullSaveNow) == "function" then
				return PlayerProfileService.ForceFullSaveNow(player, CONFIG.SaveReason)
			else
				PlayerProfileService.SaveNow(player, CONFIG.SaveReason)
				return true
			end
		end)
		if not okSave then
			warnlog("Save call failed:", tostring(saveRes))
		end
	end

	if CONFIG.PostSaveAuditLog and type(PlayerProfileService.GetProfile) == "function" then
		task.delay(CONFIG.PostSaveAuditDelay, function()
			local okProf, prof = pcall(function() return PlayerProfileService.GetProfile(player) end)
			if okProf and prof and prof.inventory then
				local cs = prof.inventory.capturedSlimes and #prof.inventory.capturedSlimes or 0
				local ws = prof.inventory.worldSlimes and #prof.inventory.worldSlimes or 0
				dprint(("Post-capture audit for %s: capturedSlimes=%d worldSlimes=%d"):format(player.Name, cs, ws))
				if cs > 0 then
					local sample = prof.inventory.capturedSlimes[#prof.inventory.capturedSlimes]
					if sample and sample.ToolUniqueId then
						dprint("Sample captured ToolUniqueId:", sample.ToolUniqueId)
					end
				end
			else
				if not okProf then
					dprint("Post-capture audit: GetProfile failed")
				else
					dprint("Post-capture audit: no profile or inventory for", player.Name)
				end
			end
		end)
	end

	return true, {
		ToolName       = tool.Name,
		WeightPounds   = tool:GetAttribute("WeightPounds"),
		CurrentValue   = tool:GetAttribute("CurrentValue"),
		GrowthProgress = tool:GetAttribute("GrowthProgress"),
		Rarity         = tool:GetAttribute("Rarity"),
	}
end

-- Remote handler
PickupRequest.OnServerEvent:Connect(function(player, slime)
	local success, dataOrErr = perform(player, slime)
	PickupResult:FireClient(player, {
		success = success,
		message = success and "Captured slime." or tostring(dataOrErr),
		data    = success and dataOrErr or nil
	})
end)

-- Hook player join to attempt to repair visuals after serializer restores tools
Players.PlayerAdded:Connect(function(player)
	task.defer(function()
		task.wait(0.15)
		pcall(function() RestorePlayerCapturedVisuals(player) end)
	end)
end)

-- Public API
local SlimeCaptureService = {
	PerformCapture = perform,
	EnsureToolVisual = EnsureToolVisual,
	RestorePlayerCapturedVisuals = RestorePlayerCapturedVisuals,
	BuildVisualFromTool = BuildVisualFromTool,
	CONFIG = CONFIG,
}

return SlimeCaptureService