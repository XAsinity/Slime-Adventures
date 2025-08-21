-- SlimeFactory.lua
-- Unified construction / restoration for slimes (hatch + persistence restore).
-- Version: 1.2 (adds LastGrowthUpdate / OfflineGrowthApplied / AgeSeconds restore + PersistedGrowthProgress floor)
--
-- Public:
--   SlimeFactory.BuildNew(params) -> slime Model | nil, err
--   SlimeFactory.RestoreFromSnapshot(entry, player, plotModel) -> slime Model | nil
--
-- Notes (v1.2 changes):
--   * Restores 'lg' (LastGrowthUpdate), 'og' (OfflineGrowthApplied), 'ag' (AgeSeconds) if present.
--   * Initializes PersistedGrowthProgress to GrowthProgress so GrowthService's non-regression
--     logic has a floor immediately (prevents early micro-stamp from setting a lower floor).
--   * Ensures Hunger defaults remain consistent.
--
-- Dependencies (must exist in ServerScriptService/Modules):
--   RNG, SlimeAppearance, SlimeMutation, SizeRNG, GrowthScaling, ModelUtils, SlimeAI
--
-- Template location:
--   ReplicatedStorage/Assets/Slime  (change TEMPLATE_PATH if needed)

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Modules = ServerScriptService:WaitForChild("Modules")

local RNG             = require(Modules:WaitForChild("RNG"))
local SlimeAppearance = require(Modules:WaitForChild("SlimeAppearance"))
local SlimeMutation   = require(Modules:WaitForChild("SlimeMutation"))
local SizeRNG         = require(Modules:WaitForChild("SizeRNG"))
local GrowthScaling   = require(Modules:WaitForChild("GrowthScaling"))
local ModelUtils      = require(Modules:WaitForChild("ModelUtils"))
local SlimeAI         = require(Modules:WaitForChild("SlimeAI"))

local SlimeFactory = {}

-- CONFIG ---------------------------------------------------------------------
local TEMPLATE_PATH = { "Assets", "Slime" }
local FALLBACK_NAME = "Slime"

local MIN_PART_AXIS  = 0.05
local BODY_PART_CANDIDATES = { "Outer","Inner","Body","Core","Main","Torso","Slime","Base" }

-- INTERNAL HELPERS -----------------------------------------------------------
local function findTemplate()
	local node = ReplicatedStorage
	for _,seg in ipairs(TEMPLATE_PATH) do
		node = node and node:FindFirstChild(seg)
	end
	if node and node:IsA("Model") then return node end
	return ReplicatedStorage:FindFirstChild(FALLBACK_NAME)
end

local function choosePrimary(model)
	if model.PrimaryPart and model.PrimaryPart:IsA("BasePart") then return model.PrimaryPart end
	for _,cand in ipairs(BODY_PART_CANDIDATES) do
		local p = model:FindFirstChild(cand)
		if p and p:IsA("BasePart") then
			model.PrimaryPart = p
			return p
		end
	end
	for _,c in ipairs(model:GetChildren()) do
		if c:IsA("BasePart") then
			model.PrimaryPart = c
			return c
		end
	end
	return nil
end

local function captureOriginalData(model, primary)
	for _,part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part:SetAttribute("OriginalSize", part.Size)
			if part == primary then
				part:SetAttribute("OriginalRelCF", CFrame.new())
			else
				part:SetAttribute("OriginalRelCF", primary.CFrame:ToObjectSpace(part.CFrame))
			end
		end
	end
end

local function computeSafeStartScale(model, desired)
	local needed = 0
	for _,p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			local s = p.Size
			needed = math.max(needed, MIN_PART_AXIS/math.max(s.X,1e-6))
			needed = math.max(needed, MIN_PART_AXIS/math.max(s.Y,1e-6))
			needed = math.max(needed, MIN_PART_AXIS/math.max(s.Z,1e-6))
		end
	end
	return math.max(desired, needed)
end

local function applyScale(model, primary, scale)
	if not scale or scale <= 0 then return end
	for _,p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			local orig = p:GetAttribute("OriginalSize") or p.Size
			p:SetAttribute("OriginalSize", orig)
			local ns = orig * scale
			p.Size = Vector3.new(
				math.max(ns.X, MIN_PART_AXIS),
				math.max(ns.Y, MIN_PART_AXIS),
				math.max(ns.Z, MIN_PART_AXIS)
			)
		end
	end
	local rootCF = primary.CFrame
	for _,p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") and p ~= primary then
			local rel = p:GetAttribute("OriginalRelCF")
			if rel then
				local posRel = rel.Position * scale
				local rotRel = rel - rel.Position
				p.CFrame = rootCF * (CFrame.new(posRel) * rotRel)
			end
		end
	end
	model:SetAttribute("CurrentSizeScale", scale)
end

-- Color helper ---------------------------------------------------------------
local function hexToColor3(hex)
	if typeof(hex) == "Color3" then return hex end
	if type(hex) ~= "string" then return nil end
	hex = hex:gsub("#","")
	if #hex ~= 6 then return nil end
	local r = tonumber(hex:sub(1,2),16)
	local g = tonumber(hex:sub(3,4),16)
	local b = tonumber(hex:sub(5,6),16)
	if r and g and b then
		return Color3.fromRGB(r,g,b)
	end
	return nil
end

local function applyAppearanceFromAttributes(slime)
	local bodyC = hexToColor3(slime:GetAttribute("BodyColor"))
	local accentC = hexToColor3(slime:GetAttribute("AccentColor"))
	local eyeC = hexToColor3(slime:GetAttribute("EyeColor"))
	if not (bodyC or accentC or eyeC) then return end
	local primary = slime.PrimaryPart or slime:FindFirstChildWhichIsA("BasePart")
	for _,part in ipairs(slime:GetDescendants()) do
		if part:IsA("BasePart") then
			local ln = part.Name:lower()
			if eyeC and ln:find("eye") then
				part.Color = eyeC
			elseif primary and part == primary and bodyC then
				part.Color = bodyC
			elseif accentC then
				part.Color = accentC
			end
		end
	end
end

local function initGrowth(slime, params)
	local startScale = slime:GetAttribute("StartSizeScale")
	local maxScale   = slime:GetAttribute("MaxSizeScale")
	if not (startScale and maxScale) then
		local rng = RNG.New()
		local tier = slime:GetAttribute("Tier") or params.Tier or "Basic"
		local baseMax, _luck = SizeRNG.GenerateMaxSize(tier, rng)
		local startFrac = SizeRNG.GenerateStartFraction(tier, rng)
		local startDesired = baseMax * startFrac
		local safe = computeSafeStartScale(slime, startDesired)
		slime:SetAttribute("MaxSizeScale", baseMax)
		slime:SetAttribute("StartSizeScale", safe)
		slime:SetAttribute("GrowthProgress", safe / baseMax)
		slime:SetAttribute("CurrentSizeScale", safe)
	end
end

-- PUBLIC: BuildNew -----------------------------------------------------------
function SlimeFactory.BuildNew(params)
	params = params or {}
	local template = findTemplate()
	if not template then return nil, "NoTemplate" end
	local slime = template:Clone()
	slime.Name = "Slime"

	-- Core attributes
	slime:SetAttribute("OwnerUserId", params.OwnerUserId or 0)
	slime:SetAttribute("SlimeId", params.SlimeId or game.HttpService:GenerateGUID(false))
	if params.Rarity       then slime:SetAttribute("Rarity", params.Rarity) end
	if params.MovementScalar then slime:SetAttribute("MovementScalar", params.MovementScalar) end
	if params.WeightScalar then slime:SetAttribute("WeightScalar", params.WeightScalar) end
	if params.WeightPounds then slime:SetAttribute("WeightPounds", params.WeightPounds) end
	if params.MutationRarityBonus then slime:SetAttribute("MutationRarityBonus", params.MutationRarityBonus) end
	if params.Tier then slime:SetAttribute("Tier", params.Tier) end
	if params.MutationStage then slime:SetAttribute("MutationStage", params.MutationStage) end

	slime:SetAttribute("ValueBase", params.ValueBase or 0)
	slime:SetAttribute("ValuePerGrowth", params.ValuePerGrowth or 0)
	slime:SetAttribute("GrowthProgress", params.GrowthProgress or 0)

	slime:SetAttribute("FedFraction", params.FedFraction or 1)
	slime:SetAttribute("CurrentFullness", params.CurrentFullness or params.FedFraction or 1)
	slime:SetAttribute("LastHungerUpdate", params.LastHungerUpdate or os.time())
	slime:SetAttribute("HungerDecayRate", params.HungerDecayRate or (0.02/15))

	local primary = choosePrimary(slime)
	if not primary then slime:Destroy() return nil, "NoPrimary" end
	captureOriginalData(slime, primary)

	initGrowth(slime, params)
	if params.CurrentSizeScale then
		applyScale(slime, primary, params.CurrentSizeScale)
	else
		applyScale(slime, primary, slime:GetAttribute("CurrentSizeScale") or 1)
	end

	SlimeMutation.InitSlime(slime)
	SlimeMutation.RecomputeValueFull(slime)

	-- Appearance
	if params.BodyColor or params.AccentColor or params.EyeColor then
		if params.BodyColor then slime:SetAttribute("BodyColor", params.BodyColor) end
		if params.AccentColor then slime:SetAttribute("AccentColor", params.AccentColor) end
		if params.EyeColor then slime:SetAttribute("EyeColor", params.EyeColor) end
		applyAppearanceFromAttributes(slime)
	else
		local rng = RNG.New()
		local rarity = slime:GetAttribute("Rarity") or "Common"
		local app = SlimeAppearance.Generate(rarity, rng, slime:GetAttribute("MutationRarityBonus"))
		slime:SetAttribute("BodyColor", RNG.ColorToHex(app.BodyColor))
		slime:SetAttribute("AccentColor", RNG.ColorToHex(app.AccentColor))
		slime:SetAttribute("EyeColor", RNG.ColorToHex(app.EyeColor))
		applyAppearanceFromAttributes(slime)
	end

	pcall(function() ModelUtils.AutoWeld(slime, primary) end)

	return slime
end

-- PUBLIC: RestoreFromSnapshot ------------------------------------------------
-- Short keys mapping (subset; extended for offline fields):
--  gp GrowthProgress, vf ValueFull, cv CurrentValue, vb ValueBase, vg ValuePerGrowth
--  ms MutationStage, ti Tier, ff FedFraction, sz CurrentSizeScale
--  bc BodyColor, ac AccentColor, mv MovementScalar, ws WeightScalar
--  mb MutationRarityBonus, wt WeightPounds, mx MaxSizeScale, st StartSizeScale
--  lr SizeLuckRolls, fb FeedBufferSeconds, fx FeedBufferMax, hd HungerDecayRate
--  cf CurrentFullness, fs FeedSpeedMultiplier, lu LastHungerUpdate, ec EyeColor
--  lg LastGrowthUpdate, og OfflineGrowthApplied, ag AgeSeconds
function SlimeFactory.RestoreFromSnapshot(entry, player, plot)
	local template = findTemplate()
	if not template then
		warn("[SlimeFactory] Missing slime template.")
		return nil
	end
	local slime = template:Clone()
	slime.Name = "Slime"

	local function setAttr(long, short)
		local v = entry[short]
		if v ~= nil then slime:SetAttribute(long, v) end
	end

	setAttr("GrowthProgress","gp")
	setAttr("ValueFull","vf")
	setAttr("CurrentValue","cv")
	setAttr("ValueBase","vb")
	setAttr("ValuePerGrowth","vg")
	setAttr("MutationStage","ms")
	setAttr("Tier","ti")
	setAttr("FedFraction","ff")
	setAttr("CurrentSizeScale","sz")
	setAttr("BodyColor","bc")
	setAttr("AccentColor","ac")
	setAttr("MovementScalar","mv")
	setAttr("WeightScalar","ws")
	setAttr("MutationRarityBonus","mb")
	setAttr("WeightPounds","wt")
	setAttr("MaxSizeScale","mx")
	setAttr("StartSizeScale","st")
	setAttr("SizeLuckRolls","lr")
	setAttr("FeedBufferSeconds","fb")
	setAttr("FeedBufferMax","fx")
	setAttr("HungerDecayRate","hd")
	setAttr("CurrentFullness","cf")
	setAttr("FeedSpeedMultiplier","fs")
	setAttr("LastHungerUpdate","lu")
	setAttr("EyeColor","ec")
	setAttr("LastGrowthUpdate","lg")
	setAttr("OfflineGrowthApplied","og")
	setAttr("AgeSeconds","ag")

	slime:SetAttribute("SlimeId", entry.id or game.HttpService:GenerateGUID(false))
	slime:SetAttribute("OwnerUserId", player.UserId)

	-- Seed PersistedGrowthProgress floor = current progress (prevents early regression).
	local gp = slime:GetAttribute("GrowthProgress") or 0
	if slime:GetAttribute("PersistedGrowthProgress") == nil then
		slime:SetAttribute("PersistedGrowthProgress", gp)
	end

	-- If LastGrowthUpdate missing but snapshot timestamp exists (ts), seed it so offline can compute.
	if slime:GetAttribute("LastGrowthUpdate") == nil and entry.ts then
		slime:SetAttribute("LastGrowthUpdate", entry.ts)
	end

	local primary = choosePrimary(slime)
	if primary then
		captureOriginalData(slime, primary)
		local curScale = slime:GetAttribute("CurrentSizeScale") or 1
		applyScale(slime, primary, curScale)
	end

	-- Hunger defaults
	if slime:GetAttribute("CurrentFullness") == nil then
		slime:SetAttribute("CurrentFullness", slime:GetAttribute("FedFraction") or 1)
	end
	if slime:GetAttribute("FedFraction") == nil then slime:SetAttribute("FedFraction", 1) end
	if slime:GetAttribute("LastHungerUpdate") == nil then slime:SetAttribute("LastHungerUpdate", os.time()) end
	if slime:GetAttribute("HungerDecayRate") == nil then slime:SetAttribute("HungerDecayRate", 0.02/15) end

	SlimeMutation.InitSlime(slime)
	SlimeMutation.RecomputeValueFull(slime)
	local prog = slime:GetAttribute("GrowthProgress") or 0
	local vf = slime:GetAttribute("ValueFull") or 0
	slime:SetAttribute("CurrentValue", vf * prog)

	applyAppearanceFromAttributes(slime)

	if primary then
		pcall(function() ModelUtils.AutoWeld(slime, primary) end)
	end

	slime:SetAttribute("IsRestored", true)
	slime:SetAttribute("RestoredAt", os.time())

	slime.Parent = plot

	-- Position
	if entry.px and entry.py and entry.pz then
		local cf = CFrame.new(entry.px, entry.py, entry.pz)
		if entry.rx or entry.ry or entry.rz then
			cf = cf * CFrame.Angles(entry.rx or 0, entry.ry or 0, entry.rz or 0)
		end
		if slime.PrimaryPart then
			slime.PrimaryPart.CFrame = cf
		else
			slime:PivotTo(cf)
		end
	end

	-- Defer AI start
	task.defer(function()
		if slime.Parent then
			pcall(function() SlimeAI.Start(slime, nil) end)
		end
	end)

	return slime
end

return SlimeFactory