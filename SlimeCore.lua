-- SlimeCore.lua
-- Fully consolidated module combining:
--   ModelUtils, ColorUtil, SlimeAppearance, SlimeConfig, SlimeMutation,
--   SlimeFactory, GrowthScaling, GrowthService, SlimeHungerService,
--   GrowthPersistenceService.
--
-- External dependencies that remain separate:
--   RNG, SizeRNG, SlimeAI
--
-- Usage:
--   local SlimeCore = require(path.to.SlimeCore)
--   SlimeCore.Init()                      -- starts Growth & Hunger loops
--   SlimeCore.GrowthPersistenceService:Init(orchestrator) -- init persistence orchestrator
--
-- Note: GrowthPersistenceService is decoupled and expects an orchestrator object
-- that implements MarkDirty(player, reason) and SaveNow(player, reason, opts).
-- This preserves no-circular-dependency behavior.

local SlimeCore = {}

----------------------------------------------------------
-- External dependencies (expected to exist in Modules folder)
----------------------------------------------------------
local ModulesRoot = script.Parent
local RNG = require(ModulesRoot:WaitForChild("RNG"))
local SizeRNG = require(ModulesRoot:WaitForChild("SizeRNG"))
local SlimeAI = require(ModulesRoot:WaitForChild("SlimeAI"))

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

----------------------------------------------------------
-- ModelUtils
----------------------------------------------------------
local ModelUtils = {}
do
	local REMOVE_CLASSES = {
		BodyVelocity=true,BodyAngularVelocity=true,BodyPosition=true,BodyGyro=true,
		BodyForce=true,BodyThrust=true,AlignPosition=true,AlignOrientation=true,
		VectorForce=true,LinearVelocity=true,AngularVelocity=true
	}

	local function isBasePart(inst)
		if typeof(inst) ~= "Instance" then return false end
		return inst:IsA("BasePart")
	end

	function ModelUtils.CleanPhysics(model)
		if not model then return end
		for _,d in ipairs(model:GetDescendants()) do
			if d and d.ClassName and REMOVE_CLASSES[d.ClassName] then
				pcall(function() d:Destroy() end)
			end
		end
	end

	function ModelUtils.AutoWeld(model, primary)
		if not model then return nil end
		primary = primary or model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
		if not primary then return nil end
		if model.PrimaryPart ~= primary then model.PrimaryPart = primary end

		for _,d in ipairs(model:GetDescendants()) do
			if isBasePart(d) then
				d.Anchored = true
				d.Massless = (d ~= primary)
			end
		end

		for _,c in ipairs(primary:GetChildren()) do
			if typeof(c) == "Instance" and c:IsA("WeldConstraint") then
				pcall(function() c:Destroy() end)
			end
		end

		for _,d in ipairs(model:GetDescendants()) do
			if isBasePart(d) and d ~= primary then
				for _,c in ipairs(d:GetChildren()) do
					if typeof(c) == "Instance" and c:IsA("WeldConstraint") then
						pcall(function() c:Destroy() end)
					end
				end
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = primary
				weld.Part1 = d
				weld.Parent = primary
			end
		end

		primary.Anchored = false
		for _,d in ipairs(model:GetDescendants()) do
			if isBasePart(d) and d ~= primary then
				d.Anchored = false
			end
		end
		return primary
	end

	function ModelUtils.UniformScale(model, scale)
		if not scale or scale == 1 then return end
		for _,d in ipairs(model:GetDescendants()) do
			if typeof(d) == "Instance" and d:IsA("BasePart") then
				d.Size = d.Size * scale
			end
		end
	end
end
SlimeCore.ModelUtils = ModelUtils

----------------------------------------------------------
-- ColorUtil
----------------------------------------------------------
local ColorUtil = {}
do
	function ColorUtil.ColorToHex(c)
		if not c then return "FFFFFF" end
		return string.format("%02X%02X%02X",
			math.floor(c.R*255+0.5),
			math.floor(c.G*255+0.5),
			math.floor(c.B*255+0.5))
	end

	function ColorUtil.HexToColor(hex)
		if type(hex)~="string" or #hex<6 then return nil end
		hex = hex:gsub("^#","")
		local r = tonumber(hex:sub(1,2),16)
		local g = tonumber(hex:sub(3,4),16)
		local b = tonumber(hex:sub(5,6),16)
		if not r or not g or not b then return nil end
		return Color3.fromRGB(r,g,b)
	end
end
SlimeCore.ColorUtil = ColorUtil

----------------------------------------------------------
-- SlimeAppearance
----------------------------------------------------------
local SlimeAppearance = {}
do
	SlimeAppearance.RarityPalettes = {
		Common = {
			bodies = {
				Color3.fromRGB(120,230,120),
				Color3.fromRGB(110,210,140),
				Color3.fromRGB(130,240,150),
			},
			accent = {
				Color3.fromRGB(90,200,110),
				Color3.fromRGB(100,185,125),
			},
			mutationChance = 0.07,
			eyeMutationChance = 0.01
		},
		Rare = {
			bodies = {
				Color3.fromRGB(120,180,255),
				Color3.fromRGB(140,190,250),
				Color3.fromRGB(105,170,235),
			},
			accent = {
				Color3.fromRGB(90,140,220),
				Color3.fromRGB(70,120,210),
			},
			mutationChance = 0.12,
			eyeMutationChance = 0.02
		},
		Epic = {
			bodies = {
				Color3.fromRGB(215,120,255),
				Color3.fromRGB(200,100,240),
				Color3.fromRGB(225,140,255),
			},
			accent = {
				Color3.fromRGB(170,70,220),
				Color3.fromRGB(185,90,230),
			},
			mutationChance = 0.20,
			eyeMutationChance = 0.04
		},
		Legendary = {
			bodies = {
				Color3.fromRGB(255,200,60),
				Color3.fromRGB(255,180,40),
				Color3.fromRGB(255,220,90),
			},
			accent = {
				Color3.fromRGB(235,150,30),
				Color3.fromRGB(255,155,20),
			},
			mutationChance = 0.30,
			eyeMutationChance = 0.07
		}
	}

	SlimeAppearance.MutationBodyColors = {
		Color3.fromRGB(255, 60,120),
		Color3.fromRGB( 60,255,230),
		Color3.fromRGB(255,255,255),
		Color3.fromRGB(160, 60,255),
		Color3.fromRGB( 40,255, 90),
	}

	SlimeAppearance.MutationEyeColors = {
		Color3.fromRGB(255,50,50),
		Color3.fromRGB(50,50,255),
		Color3.fromRGB(255,255,80),
		Color3.fromRGB(255,120,255),
	}

	function SlimeAppearance.Generate(rarity, rng, rarityMutationBonus)
		rng = rng or RNG.New()
		local config = SlimeAppearance.RarityPalettes[rarity] or SlimeAppearance.RarityPalettes.Common
		local bodyMutChance = (config.mutationChance or 0.1) + (rarityMutationBonus or 0)
		local eyeMutChance = (config.eyeMutationChance or 0.01) + (rarityMutationBonus or 0)*0.3

		local mutatedBody = RNG.Bool(bodyMutChance, rng)
		local mutatedEyes = RNG.Bool(eyeMutChance, rng)

		local bodyColor
		local accentColor
		if mutatedBody then
			bodyColor = RNG.Pick(SlimeAppearance.MutationBodyColors, rng)
			accentColor = RNG.DriftColor(bodyColor, 0.08, 0.08, 0.06, rng)
		else
			bodyColor = RNG.DriftColor(RNG.Pick(config.bodies, rng), 0.04,0.04,0.04, rng)
			accentColor = RNG.DriftColor(RNG.Pick(config.accent, rng), 0.05,0.05,0.05, rng)
		end

		local eyeColor = Color3.new(0,0,0)
		if mutatedEyes then
			eyeColor = RNG.Pick(SlimeAppearance.MutationEyeColors, rng)
		end

		return {
			BodyColor = bodyColor,
			AccentColor = accentColor,
			EyeColor = eyeColor,
			MutatedBody = mutatedBody,
			MutatedEyes = mutatedEyes
		}
	end
end
SlimeCore.SlimeAppearance = SlimeAppearance

----------------------------------------------------------
-- SlimeConfig
----------------------------------------------------------
local SlimeConfig = {}
do
	SlimeConfig.AverageScaleBasic = 1.0

	SlimeConfig.Tiers = {
		Basic = {
			UnfedGrowthDurationRange = {540, 900},
			FedGrowthDurationRange   = {120, 480},
			BaseMaxSizeRange         = {0.85, 1.10},
			StartScaleFractionRange  = {0.010, 0.020},
			FeedBufferPerItem        = 15,
			FeedBufferMax            = 120,
			AbsoluteMaxScaleCap      = 200,
			DurationExponentAlpha    = 0.6,
			DurationBreakPoint       = 64,
			DurationLogK             = 0.35,
			ValueBaseFull            = 150,
			ValueSizeExponent        = 1.15,
			MutationValuePerStage    = 0.08,
			RarityLuckPremiumPerLevel= 0.02,
			BaseMutationChance       = 0.02,
			MutationChancePerStage   = 0.005,
			SizeJackpot = {
				{ p = 1/500,    mult = {1.15,1.25} },
				{ p = 1/5000,   mult = {1.30,1.50} },
				{ p = 1/50000,  mult = {1.80,2.20} },
				{ p = 1/500000, mult = {3.00,4.00} },
				{ p = 1/5e6,    mult = {6.00,8.00} },
				{ p = 1/5e7,    mult = {12.0,16.0} },
				{ p = 1/5e8,    mult = {24.0,32.0} },
				{ p = 1/5e9,    mult = {48.0,64.0} },
			},
			MutationColorJitter = { H = 0.05, S = 0.07, V = 0.08 },
			MutablePartNamePatterns = { "inner","outer","ball","body","slime","core" },
		}
	}

	function SlimeConfig.GetTierConfig(tier)
		return SlimeConfig.Tiers[tier] or SlimeConfig.Tiers.Basic
	end
end
SlimeCore.SlimeConfig = SlimeConfig

----------------------------------------------------------
-- GrowthScaling (integrated)
----------------------------------------------------------
local GrowthScaling = {}
do
	function GrowthScaling.SizeDurationFactor(tier, size_norm)
		local cfg = SlimeConfig.GetTierConfig(tier)
		local alpha = cfg.DurationExponentAlpha
		local BREAK = cfg.DurationBreakPoint
		local k = cfg.DurationLogK
		if size_norm <= BREAK then
			return size_norm ^ alpha
		else
			return (BREAK ^ alpha) * (1 + k * math.log(size_norm / BREAK))
		end
	end
end
SlimeCore.GrowthScaling = GrowthScaling

----------------------------------------------------------
-- SlimeMutation
----------------------------------------------------------
local SlimeMutation = {}
do
	local function getHistory(slime)
		local raw = slime:GetAttribute("MutationHistory")
		if not raw or raw == "" then return {} end
		local ok, data = pcall(HttpService.JSONDecode, HttpService, raw)
		if ok and type(data) == "table" then return data end
		return {}
	end
	local function setHistory(slime, tbl)
		local ok, encoded = pcall(HttpService.JSONEncode, HttpService, tbl)
		if ok then slime:SetAttribute("MutationHistory", encoded) end
	end
	local function lowercaseMatchAny(name, patterns)
		name = name:lower()
		for _,pat in ipairs(patterns) do
			if string.find(name, pat) then return true end
		end
		return false
	end

	local function getRaw(rng)
		if not rng then return RNG.New() end
		if type(rng) == "table" and rng.Raw then
			local ok, inner = pcall(function() return rng:Raw() end)
			if ok and inner then return inner end
		end
		return rng
	end

	function SlimeMutation.ApplyVisualStage(slime, stage, rng)
		local tier = slime:GetAttribute("Tier") or "Basic"
		local cfg = SlimeConfig.GetTierConfig(tier)
		rng = getRaw(rng)

		local mutable = {}
		for _,p in ipairs(slime:GetDescendants()) do
			if typeof(p) == "Instance" and p:IsA("BasePart") and lowercaseMatchAny(p.Name, cfg.MutablePartNamePatterns) then
				table.insert(mutable, p)
			end
		end
		if #mutable == 0 then return end

		if RNG.Bool(0.5, rng) then
			local driftAllH = cfg.MutationColorJitter.H or 0.05
			local driftAllS = cfg.MutationColorJitter.S or 0.06
			local driftAllV = cfg.MutationColorJitter.V or 0.08
			for _,part in ipairs(mutable) do
				part.Color = RNG.DriftColor(part.Color, driftAllH, driftAllS, driftAllV, rng)
				part:SetAttribute("MutStageApplied", stage)
			end
		else
			local target = mutable[RNG.Int(1, #mutable, rng)]
			target.Color = RNG.DriftColor(target.Color, 0.15, 0.20, 0.20, rng)
			target:SetAttribute("MutStageApplied", stage)
		end
	end

	function SlimeMutation.RecomputeValueFull(slime)
		local tier = slime:GetAttribute("Tier") or "Basic"
		local cfg = SlimeConfig.GetTierConfig(tier)
		local maxScale = slime:GetAttribute("MaxSizeScale") or 1
		local sizeNorm = maxScale / (SlimeConfig.AverageScaleBasic or 1)
		local luckLevels = slime:GetAttribute("SizeLuckRolls") or 0
		local stage = slime:GetAttribute("MutationStage") or 0
		local mutationMult = 1 + stage * (cfg.MutationValuePerStage or 0)
		local rarityPremium = 1 + luckLevels * (cfg.RarityLuckPremiumPerLevel or 0)
		local valueFull = (cfg.ValueBaseFull or 150) * (sizeNorm ^ (cfg.ValueSizeExponent or 1.15)) * rarityPremium * mutationMult
		slime:SetAttribute("ValueFull", valueFull)
		local prog = slime:GetAttribute("GrowthProgress") or 0
		slime:SetAttribute("CurrentValue", valueFull * prog)
	end

	function SlimeMutation.InitSlime(slime)
		if slime:GetAttribute("MutationStage") == nil then slime:SetAttribute("MutationStage", 0) end
		if slime:GetAttribute("MutationHistory") == nil then setHistory(slime, {}) end
		if slime:GetAttribute("MutationValueMult") == nil then slime:SetAttribute("MutationValueMult", 1) end
	end

	function SlimeMutation.AttemptMutation(slime, rng, opts)
		opts = opts or {}
		local rawRng = getRaw(rng)
		local tier = slime:GetAttribute("Tier") or "Basic"
		local cfg = SlimeConfig.GetTierConfig(tier)
		local stage = slime:GetAttribute("MutationStage") or 0
		local base = cfg.BaseMutationChance or 0.02
		local per  = cfg.MutationChancePerStage or 0.005
		local extra = opts.extraChance or 0
		local success = opts.force or RNG.RollMutation(base, per, stage, extra, rawRng)
		if not success then return false end

		local newStage = stage + 1
		slime:SetAttribute("MutationStage", newStage)

		SlimeMutation.ApplyVisualStage(slime, newStage, rawRng)

		local hist = getHistory(slime)
		table.insert(hist, { stage = newStage, time = os.time(), type = "ColorDrift" })
		setHistory(slime, hist)

		SlimeMutation.RecomputeValueFull(slime)
		return true
	end
end
SlimeCore.SlimeMutation = SlimeMutation

----------------------------------------------------------
-- SlimeFactory
----------------------------------------------------------
local SlimeFactory = {}
do
	local TEMPLATE_PATH = { "Assets", "Slime" }
	local FALLBACK_NAME = "Slime"
	local MIN_PART_AXIS  = 0.05
	local BODY_PART_CANDIDATES = { "Outer","Inner","Body","Core","Main","Torso","Slime","Base" }

	local function findTemplate()
		local node = ReplicatedStorage
		for _,seg in ipairs(TEMPLATE_PATH) do
			node = node and node:FindFirstChild(seg)
		end
		if node and typeof(node) == "Instance" and node:IsA("Model") then return node end
		local fallback = ReplicatedStorage:FindFirstChild(FALLBACK_NAME)
		if fallback and typeof(fallback) == "Instance" and fallback:IsA("Model") then return fallback end
		return nil
	end

	local function choosePrimary(model)
		if typeof(model) ~= "Instance" then return nil end
		if model.PrimaryPart and typeof(model.PrimaryPart) == "Instance" and model.PrimaryPart:IsA("BasePart") then return model.PrimaryPart end
		for _,cand in ipairs(BODY_PART_CANDIDATES) do
			local p = model:FindFirstChild(cand)
			if typeof(p) == "Instance" and p:IsA("BasePart") then model.PrimaryPart = p; return p end
		end
		for _,c in ipairs(model:GetChildren()) do
			if typeof(c) == "Instance" and c:IsA("BasePart") then model.PrimaryPart = c; return c end
		end
		return nil
	end

	local function captureOriginalData(model, primary)
		for _,part in ipairs(model:GetDescendants()) do
			if typeof(part) == "Instance" and part:IsA("BasePart") then
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
			if typeof(p) == "Instance" and p:IsA("BasePart") then
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
			if typeof(p) == "Instance" and p:IsA("BasePart") then
				local orig = p:GetAttribute("OriginalSize") or p.Size
				p:SetAttribute("OriginalSize", orig)
				local ns = orig * scale
				p.Size = Vector3.new(math.max(ns.X, MIN_PART_AXIS), math.max(ns.Y, MIN_PART_AXIS), math.max(ns.Z, MIN_PART_AXIS))
			end
		end
		local rootCF = primary and primary.CFrame or CFrame.new()
		for _,p in ipairs(model:GetDescendants()) do
			if typeof(p) == "Instance" and p:IsA("BasePart") and p ~= primary then
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

	local function hexToColor3(hex)
		if typeof(hex) == "Color3" then return hex end
		if type(hex) ~= "string" then return nil end
		hex = hex:gsub("#","")
		if #hex ~= 6 then return nil end
		local r = tonumber(hex:sub(1,2),16)
		local g = tonumber(hex:sub(3,4),16)
		local b = tonumber(hex:sub(5,6),16)
		if r and g and b then return Color3.fromRGB(r,g,b) end
		return nil
	end

	local function applyAppearanceFromAttributes(slime)
		local bodyC = hexToColor3(slime:GetAttribute("BodyColor"))
		local accentC = hexToColor3(slime:GetAttribute("AccentColor"))
		local eyeC = hexToColor3(slime:GetAttribute("EyeColor"))
		if not (bodyC or accentC or eyeC) then return end
		local primary = slime.PrimaryPart or slime:FindFirstChildWhichIsA("BasePart")
		for _,part in ipairs(slime:GetDescendants()) do
			if typeof(part) == "Instance" and part:IsA("BasePart") then
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
			local tier = slime:GetAttribute("Tier") or (params and params.Tier) or "Basic"
			local baseMax, _luck = SizeRNG.GenerateMaxSize(tier, rng)
			local startFrac = (SizeRNG.GenerateStartFraction and SizeRNG.GenerateStartFraction(tier, rng)) or 0.01
			local startDesired = baseMax * startFrac
			local safe = computeSafeStartScale(slime, startDesired)
			slime:SetAttribute("MaxSizeScale", baseMax)
			slime:SetAttribute("StartSizeScale", safe)
			slime:SetAttribute("GrowthProgress", safe / baseMax)
			slime:SetAttribute("CurrentSizeScale", safe)
		end
	end

	function SlimeFactory.BuildNew(params)
		params = params or {}
		local template = findTemplate()
		if not template then return nil, "NoTemplate" end
		local slime = template:Clone()
		slime.Name = "Slime"

		slime:SetAttribute("OwnerUserId", params.OwnerUserId or 0)
		slime:SetAttribute("SlimeId", params.SlimeId or HttpService:GenerateGUID(false))
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
		if not primary then slime:Destroy(); return nil, "NoPrimary" end
		captureOriginalData(slime, primary)

		initGrowth(slime, params)
		if params.CurrentSizeScale then
			applyScale(slime, primary, params.CurrentSizeScale)
		else
			applyScale(slime, primary, slime:GetAttribute("CurrentSizeScale") or 1)
		end

		SlimeMutation.InitSlime(slime)
		SlimeMutation.RecomputeValueFull(slime)

		if params.BodyColor or params.AccentColor or params.EyeColor then
			if params.BodyColor then slime:SetAttribute("BodyColor", params.BodyColor) end
			if params.AccentColor then slime:SetAttribute("AccentColor", params.AccentColor) end
			if params.EyeColor then slime:SetAttribute("EyeColor", params.EyeColor) end
			applyAppearanceFromAttributes(slime)
		else
			local rng = RNG.New()
			local rarity = slime:GetAttribute("Rarity") or "Common"
			local app = SlimeAppearance.Generate(rarity, rng, slime:GetAttribute("MutationRarityBonus"))
			slime:SetAttribute("BodyColor", ColorUtil.ColorToHex(app.BodyColor))
			slime:SetAttribute("AccentColor", ColorUtil.ColorToHex(app.AccentColor))
			slime:SetAttribute("EyeColor", ColorUtil.ColorToHex(app.EyeColor))
			applyAppearanceFromAttributes(slime)
		end

		pcall(function() ModelUtils.AutoWeld(slime, primary) end)

		return slime
	end

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

		setAttr("GrowthProgress","gp"); setAttr("ValueFull","vf"); setAttr("CurrentValue","cv")
		setAttr("ValueBase","vb"); setAttr("ValuePerGrowth","vg"); setAttr("MutationStage","ms")
		setAttr("Tier","ti"); setAttr("FedFraction","ff"); setAttr("CurrentSizeScale","sz")
		setAttr("BodyColor","bc"); setAttr("AccentColor","ac"); setAttr("MovementScalar","mv")
		setAttr("WeightScalar","ws"); setAttr("MutationRarityBonus","mb"); setAttr("WeightPounds","wt")
		setAttr("MaxSizeScale","mx"); setAttr("StartSizeScale","st"); setAttr("SizeLuckRolls","lr")
		setAttr("FeedBufferSeconds","fb"); setAttr("FeedBufferMax","fx"); setAttr("HungerDecayRate","hd")
		setAttr("CurrentFullness","cf"); setAttr("FeedSpeedMultiplier","fs"); setAttr("LastHungerUpdate","lu")
		setAttr("EyeColor","ec"); setAttr("LastGrowthUpdate","lg"); setAttr("OfflineGrowthApplied","og")
		setAttr("AgeSeconds","ag")

		slime:SetAttribute("SlimeId", entry.id or HttpService:GenerateGUID(false))
		slime:SetAttribute("OwnerUserId", player and player.UserId or 0)

		local gp = slime:GetAttribute("GrowthProgress") or 0
		if slime:GetAttribute("PersistedGrowthProgress") == nil then
			slime:SetAttribute("PersistedGrowthProgress", gp)
		end

		if slime:GetAttribute("LastGrowthUpdate") == nil and entry.ts then
			slime:SetAttribute("LastGrowthUpdate", entry.ts)
		end

		local primary = choosePrimary(slime)
		if primary then
			captureOriginalData(slime, primary)
			local curScale = slime:GetAttribute("CurrentSizeScale") or 1
			applyScale(slime, primary, curScale)
		end

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

		if entry.px and entry.py and entry.pz then
			local cf = CFrame.new(entry.px, entry.py, entry.pz)
			if entry.rx or entry.ry or entry.rz then
				cf = cf * CFrame.Angles(entry.rx or 0, entry.ry or 0, entry.rz or 0)
			end
			if slime.PrimaryPart then slime.PrimaryPart.CFrame = cf else slime:PivotTo(cf) end
		end

		task.defer(function()
			if slime.Parent then pcall(function() SlimeAI.Start(slime, nil) end) end
		end)

		return slime
	end
end
SlimeCore.SlimeFactory = SlimeFactory

----------------------------------------------------------
-- GrowthService
----------------------------------------------------------
local GrowthService = {}
do
	local CONFIG = {
		VALUE_STEP        = 0.05,
		RESIZE_EPSILON    = 1e-4,
		MIN_AXIS          = 0.05,
		USE_EASED_VALUE   = false,
		MUTATION_ON_STEP  = true,
		DEBUG             = false,
		DEBUG_INIT        = false,
		HungerGrowthEnabled = true,

		OFFLINE_GROWTH_ENABLED           = true,
		OFFLINE_GROWTH_MAX_SECONDS       = 12 * 3600,
		OFFLINE_GROWTH_VERBOSE           = true,
		OFFLINE_GROWTH_APPLY_ANIMATE     = false,
		GROWTH_TIMESTAMP_UPDATE_INTERVAL = 5,
		INIT_OFFLINE_ASSUME_SECONDS      = 0,
		SECOND_PASS_REAPPLY_WINDOW       = 2.0,
		DEFER_OFFLINE_APPLY_ONE_HEARTBEAT = true,
		NON_REGRESS_SECOND_PASS_WINDOW   = 4.0,

		OFFLINE_DEBUG                    = true,
		OFFLINE_DEBUG_ATTR_SNAPSHOT      = true,
		OFFLINE_DEBUG_TAG                = "[GrowthOffline]",

		STAMP_DIRTY_DEBOUNCE             = 6,
		MICRO_PROGRESS_THRESHOLD         = 0.005,
		MICRO_DEBOUNCE_SECONDS           = 1.0,
	}

	local SlimeCache = {}            -- slime instance -> cache
	local PendingOffline = {}        -- slime -> true
	local lastStampDirtyByPlayer = {}-- userId -> epoch
	local growthDirtyEvent = ReplicatedStorage:FindFirstChild("GrowthStampDirty")
	if not growthDirtyEvent then
		growthDirtyEvent = Instance.new("BindableEvent")
		growthDirtyEvent.Name = "GrowthStampDirty"
		growthDirtyEvent.Parent = ReplicatedStorage
	end

	local lastPersistedProgress = {} -- slimeId -> floor
	local microCumulative = {}       -- slimeId -> cum delta
	local lastMicroStampByPlayer = {}-- userId -> epoch

	local function dprint(...) if CONFIG.DEBUG then print("[GrowthService]", ...) end end

	local function safeFormat(n)
		if type(n) ~= "number" then return tostring(n) end
		return string.format("%.6f", n)
	end

	local function smallJSON(t)
		local parts={}
		for k,v in pairs(t) do
			local val
			if type(v)=="number" then
				val = safeFormat(v)
			elseif type(v)=="boolean" then
				val = v and "true" or "false"
			elseif type(v)=="string" then
				val = string.format("%q", v)
			else
				val = string.format("%q", tostring(v))
			end
			parts[#parts+1]=string.format("%q:%s", tostring(k), val)
		end
		return "{"..table.concat(parts,",").."}"
	end

	local function logOffline(slime, phase, info)
		if not CONFIG.OFFLINE_DEBUG then return end
		if not slime or not slime.Parent then return end
		info = info or {}
		info.phase = phase
		info.sid = tostring(slime:GetAttribute("SlimeId") or tostring(slime))
		info.gp = slime:GetAttribute("GrowthProgress")
		info.floor = slime:GetAttribute("PersistedGrowthProgress")
		info.lg = slime:GetAttribute("LastGrowthUpdate")
		info.fb = slime:GetAttribute("FeedBufferSeconds")
		info.ff = slime:GetAttribute("FedFraction")
		info.age = slime:GetAttribute("AgeSeconds")
		local line = CONFIG.OFFLINE_DEBUG_TAG .. smallJSON(info)
		if CONFIG.OFFLINE_DEBUG_ATTR_SNAPSHOT then
			slime:SetAttribute("OfflineDebugLast", line:sub(1, 2000))
			slime:SetAttribute("OfflineDebugJSON", line)
		end
	end

	local function markStampDirty(slime, reason)
		local uid = slime:GetAttribute("OwnerUserId")
		if not uid then return end
		local now = os.time()
		local last = lastStampDirtyByPlayer[uid] or 0
		if (now - last) >= CONFIG.STAMP_DIRTY_DEBOUNCE then
			lastStampDirtyByPlayer[uid] = now
			if CONFIG.OFFLINE_DEBUG then logOffline(slime, "emit_growth_stamp", {reason=reason}) end
			pcall(function() growthDirtyEvent:Fire(uid, reason or "Stamp") end)
		end
	end

	local function tryMicroProgressStamp(slime, progress, prevProgress)
		if progress == prevProgress then return end
		local sid = slime:GetAttribute("SlimeId")
		if not sid then return end
		local uid = slime:GetAttribute("OwnerUserId")
		if not uid then return end

		local floor = lastPersistedProgress[sid]
		if not floor then
			floor = slime:GetAttribute("PersistedGrowthProgress") or progress
			lastPersistedProgress[sid] = floor
			microCumulative[sid] = 0
		end

		microCumulative[sid] = (microCumulative[sid] or 0) + (progress - prevProgress)
		local deltaSinceFloor = progress - floor

		if deltaSinceFloor >= CONFIG.MICRO_PROGRESS_THRESHOLD then
			local now = os.time()
			local lastMicro = lastMicroStampByPlayer[uid] or 0
			if (now - lastMicro) >= CONFIG.MICRO_DEBOUNCE_SECONDS then
				slime:SetAttribute("PersistedGrowthProgress", progress)
				lastPersistedProgress[sid] = progress
				microCumulative[sid] = 0
				lastMicroStampByPlayer[uid] = now
				if CONFIG.OFFLINE_DEBUG then
					logOffline(slime, "micro_stamp", { reason="threshold", progress=progress, floor_before=floor, th=CONFIG.MICRO_PROGRESS_THRESHOLD })
				end
				pcall(function() growthDirtyEvent:Fire(uid, "MicroProgress") end)
			end
		end
	end

	local function hungerMultiplier(slime)
		if not (CONFIG.HungerGrowthEnabled) then return 1 end
		local fed = slime:GetAttribute("FedFraction")
		if fed == nil then return 1 end
		return 0.40 + (1.00 - 0.40) * fed
	end

	local function attemptMutationOnStep(slime)
		if not CONFIG.MUTATION_ON_STEP then return end
		if not SlimeMutation or type(SlimeMutation.AttemptMutation) ~= "function" then return end
		SlimeMutation.AttemptMutation(slime)
		if type(SlimeMutation.RecomputeValueFull) == "function" then SlimeMutation.RecomputeValueFull(slime) end
	end

	local function captureOriginalSizes(slime)
		for _,p in ipairs(slime:GetDescendants()) do
			if typeof(p) == "Instance" and p:IsA("BasePart") and not p:GetAttribute("OriginalSize") then
				p:SetAttribute("OriginalSize", p.Size)
			end
		end
	end

	local function applyScale(slime, newScale)
		for _,p in ipairs(slime:GetDescendants()) do
			if typeof(p) == "Instance" and p:IsA("BasePart") then
				local orig = p:GetAttribute("OriginalSize")
				if not orig then orig = p.Size; p:SetAttribute("OriginalSize", orig) end
				local s = orig * newScale
				p.Size = Vector3.new(math.max(s.X, CONFIG.MIN_AXIS), math.max(s.Y, CONFIG.MIN_AXIS), math.max(s.Z, CONFIG.MIN_AXIS))
			end
		end
	end

	local function computeOfflineDelta(slime)
		if not CONFIG.OFFLINE_GROWTH_ENABLED then
			logOffline(slime, "detect_delta_result", {delta=0, reason="disabled"})
			return 0
		end
		local now = os.time()
		local last = slime:GetAttribute("LastGrowthUpdate")
		logOffline(slime, "detect_delta_start", {now=now, last=last})

		if not last or type(last) ~= "number" then
			if CONFIG.INIT_OFFLINE_ASSUME_SECONDS > 0 then
				local assumed = math.min(CONFIG.INIT_OFFLINE_ASSUME_SECONDS, CONFIG.OFFLINE_GROWTH_MAX_SECONDS)
				slime:SetAttribute("LastGrowthUpdate", now - assumed)
				logOffline(slime, "detect_delta_result", {delta=assumed, reason="no_last_assumed"})
				return assumed
			else
				slime:SetAttribute("LastGrowthUpdate", now)
				logOffline(slime, "detect_delta_result", {delta=0, reason="no_last"})
				return 0
			end
		end

		local delta = now - last
		if delta <= 0 then
			logOffline(slime, "detect_delta_result", {delta=0, reason="non_positive"})
			return 0
		end
		if delta > CONFIG.OFFLINE_GROWTH_MAX_SECONDS then
			delta = CONFIG.OFFLINE_GROWTH_MAX_SECONDS
		end
		logOffline(slime, "detect_delta_result", {delta=delta, reason="ok"})
		return delta
	end

	local function writePersistedProgress(slime)
		local gp = slime:GetAttribute("GrowthProgress")
		if gp then
			local prior = slime:GetAttribute("PersistedGrowthProgress")
			if (not prior) or gp > prior then slime:SetAttribute("PersistedGrowthProgress", gp) end
			local sid = slime:GetAttribute("SlimeId")
			if sid then lastPersistedProgress[sid] = gp; microCumulative[sid] = 0 end
		end
	end

	local function finalizeOfflineStamp(slime, alsoPersistProgress, stampReason)
		if not CONFIG.OFFLINE_GROWTH_ENABLED then return end
		slime:SetAttribute("LastGrowthUpdate", os.time())
		if alsoPersistProgress then writePersistedProgress(slime) end
		logOffline(slime, "finalize_stamp", {persist=alsoPersistProgress})
		markStampDirty(slime, stampReason or "finalize_stamp")
	end

	local function applyOfflineGrowth(slime, offlineDelta, isReapply)
		if offlineDelta <= 0 then return 0 end
		local progress = slime:GetAttribute("GrowthProgress") or 0
		if progress >= 1 then
			slime:SetAttribute("AgeSeconds", (slime:GetAttribute("AgeSeconds") or 0) + offlineDelta)
			logOffline(slime, "apply_offline_skipped", {reason="already_complete", delta=offlineDelta})
			return 0
		end

		local feedMult      = slime:GetAttribute("FeedSpeedMultiplier") or 1
		local feedBuffer    = slime:GetAttribute("FeedBufferSeconds") or 0
		local unfedDuration = slime:GetAttribute("UnfedGrowthDuration") or 600
		if unfedDuration <= 0 then unfedDuration = 600 end
		local hungerSpeed   = hungerMultiplier(slime)

		logOffline(slime, "apply_offline_before", {
			delta=offlineDelta,
			progress_before=progress,
			feedBuffer=feedBuffer,
			unfed=unfedDuration,
			hunger=hungerSpeed,
			feedMult=feedMult,
			reapply=isReapply
		})

		local function segmentIncrement(seconds, speedMultiplier)
			if seconds <= 0 or progress >= 1 then return 0 end
			local inc = (seconds * speedMultiplier) / unfedDuration
			local cap = 1 - progress
			if inc > cap then inc = cap end
			progress = progress + inc
			return inc
		end

		local bufferConsume = math.min(feedBuffer, offlineDelta)
		local normalTime    = offlineDelta - bufferConsume

		local inc1 = segmentIncrement(bufferConsume, feedMult * hungerSpeed)
		local inc2 = segmentIncrement(normalTime, hungerSpeed)
		local totalInc = inc1 + inc2

		if totalInc > 0 then slime:SetAttribute("GrowthProgress", progress) end
		if bufferConsume > 0 then slime:SetAttribute("FeedBufferSeconds", math.max(0, feedBuffer - bufferConsume)) end
		slime:SetAttribute("AgeSeconds", (slime:GetAttribute("AgeSeconds") or 0) + offlineDelta)
		if CONFIG.OFFLINE_GROWTH_VERBOSE then
			slime:SetAttribute("OfflineGrowthApplied", (slime:GetAttribute("OfflineGrowthApplied") or 0) + offlineDelta)
		end

		writePersistedProgress(slime)

		logOffline(slime, "apply_offline_after", {
			progress_after=progress,
			progress_inc=totalInc,
			inc_buffer=inc1,
			inc_normal=inc2,
			feedBuffer_after=slime:GetAttribute("FeedBufferSeconds"),
			reapply=isReapply
		})

		return totalInc
	end

	local function initCacheIfNeeded(slime)
		local cache = SlimeCache[slime]
		if cache and cache.initialized then return cache end

		captureOriginalSizes(slime)

		local gp = slime:GetAttribute("GrowthProgress") or 0
		local floor = slime:GetAttribute("PersistedGrowthProgress")
		if floor and type(floor)=="number" and gp < floor then
			logOffline(slime, "floor_correction_init", {from=gp, to=floor})
			slime:SetAttribute("GrowthProgress", floor)
			gp = floor
		elseif not floor then
			slime:SetAttribute("PersistedGrowthProgress", gp)
		end

		local sid = slime:GetAttribute("SlimeId")
		if sid and not lastPersistedProgress[sid] then
			lastPersistedProgress[sid] = slime:GetAttribute("PersistedGrowthProgress") or gp
			microCumulative[sid] = 0
		end

		local startScale = slime:GetAttribute("CurrentSizeScale") or slime:GetAttribute("StartSizeScale") or 1
		cache = {
			lastScale = startScale,
			initialized = true,
			lastStampUpdate = os.time(),
			offlineAppliedAt = nil,
			reapplied = false,
		}
		SlimeCache[slime] = cache

		if CONFIG.DEBUG_INIT then
			dprint(string.format("Managing slime %s startScale=%.3f prog=%.4f",
				tostring(slime:GetAttribute("SlimeId")), startScale, gp))
		end

		return cache
	end

	local function scheduleOfflineApply(slime)
		if not CONFIG.OFFLINE_GROWTH_ENABLED then return end
		if CONFIG.DEFER_OFFLINE_APPLY_ONE_HEARTBEAT then
			PendingOffline[slime] = true
		else
			local delta = computeOfflineDelta(slime)
			if delta > 0 then
				applyOfflineGrowth(slime, delta, false)
				finalizeOfflineStamp(slime, true, "immediate_offline")
				local cache = SlimeCache[slime]
				if cache then cache.offlineAppliedAt = os.time() end
			else
				finalizeOfflineStamp(slime, true, "immediate_no_delta")
			end
		end
	end

	local function updateSlime(slime, dt)
		if not slime.Parent or slime:GetAttribute("DisableGrowth") then return end
		local maxScale   = slime:GetAttribute("MaxSizeScale")
		local startScale = slime:GetAttribute("StartSizeScale")
		local progress   = slime:GetAttribute("GrowthProgress")
		if maxScale == nil or startScale == nil or progress == nil then return end

		local cache = initCacheIfNeeded(slime)

		if PendingOffline[slime] then
			PendingOffline[slime] = nil
			local delta = computeOfflineDelta(slime)
			if delta > 0 then applyOfflineGrowth(slime, delta, false) end
			finalizeOfflineStamp(slime, true, "deferred_offline")
			cache.offlineAppliedAt = os.time()
		end

		if CONFIG.OFFLINE_GROWTH_ENABLED and cache.offlineAppliedAt and not cache.reapplied then
			if (os.time() - cache.offlineAppliedAt) <= CONFIG.NON_REGRESS_SECOND_PASS_WINDOW then
				local floor = slime:GetAttribute("PersistedGrowthProgress")
				local gp2 = slime:GetAttribute("GrowthProgress") or 0
				if floor and gp2 < floor then
					logOffline(slime, "second_pass_floor", {from=gp2, to=floor})
					slime:SetAttribute("GrowthProgress", floor)
					cache.reapplied = true
					progress = floor
				end
			end
		end

		local prevProgress = progress
		local fb = slime:GetAttribute("FeedBufferSeconds") or 0
		local feedMult = slime:GetAttribute("FeedSpeedMultiplier") or 1
		local unfedDur = slime:GetAttribute("UnfedGrowthDuration") or 600
		if fb > 0 then fb = math.max(0, fb - dt); slime:SetAttribute("FeedBufferSeconds", fb) end
		local speedMult = (fb > 0 and feedMult or 1) * hungerMultiplier(slime)
		if progress < 1 and speedMult > 0 and unfedDur > 0 then
			progress = math.min(1, progress + (dt * speedMult) / unfedDur)
			if progress ~= prevProgress then
				slime:SetAttribute("GrowthProgress", progress)
				tryMicroProgressStamp(slime, progress, prevProgress)
			end
		end

		local eased = (function(t) return t*t*(3 - 2*t) end)(progress)
		local targetScale = startScale + (maxScale - startScale) * eased
		local currentScale = slime:GetAttribute("CurrentSizeScale") or targetScale
		if math.abs(targetScale - currentScale) > CONFIG.RESIZE_EPSILON then
			applyScale(slime, targetScale)
			slime:SetAttribute("CurrentSizeScale", targetScale)
			cache.lastScale = targetScale
		end

		local vf = slime:GetAttribute("ValueFull")
		if vf then
			local valProg = CONFIG.USE_EASED_VALUE and eased or progress
			slime:SetAttribute("CurrentValue", vf * valProg)
		end

		if progress < 1 then
			local prevStep = math.floor(prevProgress / CONFIG.VALUE_STEP)
			local newStep  = math.floor(progress / CONFIG.VALUE_STEP)
			if newStep > prevStep then attemptMutationOnStep(slime) end
		else
			if not slime:GetAttribute("GrowthCompleted") then
				slime:SetAttribute("GrowthCompleted", true)
				dprint("Growth complete", slime:GetAttribute("SlimeId"))
			end
		end

		slime:SetAttribute("AgeSeconds", (slime:GetAttribute("AgeSeconds") or 0) + dt)

		if CONFIG.OFFLINE_GROWTH_ENABLED then
			local nowEpoch = os.time()
			local lastStamp = cache.lastStampUpdate or 0
			if nowEpoch - lastStamp >= CONFIG.GROWTH_TIMESTAMP_UPDATE_INTERVAL then
				slime:SetAttribute("LastGrowthUpdate", nowEpoch)
				writePersistedProgress(slime)
				cache.lastStampUpdate = nowEpoch
				logOffline(slime, "timestamp_update", {now=nowEpoch})
				markStampDirty(slime, "timestamp_update")
			else
				if CONFIG.OFFLINE_DEBUG then
					logOffline(slime, "timestamp_throttle_skip", {now=nowEpoch, last=lastStamp})
				end
			end
		end
	end

	local function enumerateSlimes()
		for s,_ in pairs(SlimeCache) do
			if not s.Parent then SlimeCache[s] = nil; PendingOffline[s] = nil end
		end
		for _,inst in ipairs(Workspace:GetDescendants()) do
			if typeof(inst) == "Instance" and inst:IsA("Model") and inst.Name=="Slime" and inst:GetAttribute("GrowthProgress") ~= nil then
				if not SlimeCache[inst] then
					SlimeCache[inst] = { initialized=false }
					if CONFIG.OFFLINE_GROWTH_ENABLED then scheduleOfflineApply(inst) end
				end
			end
		end
	end

	local heartbeatConn = nil
	function GrowthService.Start()
		if heartbeatConn then return end
		heartbeatConn = RunService.Heartbeat:Connect(function(dt)
			enumerateSlimes()
			for slime,_ in pairs(SlimeCache) do
				if slime.Parent then
					pcall(function() updateSlime(slime, dt) end)
				end
			end
		end)
	end

	function GrowthService.Stop()
		if heartbeatConn then heartbeatConn:Disconnect(); heartbeatConn = nil end
	end

	function GrowthService.GetManagedCount()
		local c=0; for _ in pairs(SlimeCache) do c+=1 end; return c
	end

	function GrowthService.DebugEnumerate()
		for slime,cache in pairs(SlimeCache) do
			local prog  = slime:GetAttribute("GrowthProgress") or -1
			local floor = slime:GetAttribute("PersistedGrowthProgress") or -1
			local scale = slime:GetAttribute("CurrentSizeScale") or -1
			print("[GrowthService][Managed]", slime:GetFullName(), string.format("Prog=%.4f Floor=%.4f Scale=%.3f Init=%s OfflineAt=%s",
				prog, floor, scale, tostring(cache.initialized),
				cache.offlineAppliedAt and os.date("%H:%M:%S", cache.offlineAppliedAt) or "nil"))
		end
	end

	function GrowthService.FlushPlayerSlimes(userId)
		for slime,_ in pairs(SlimeCache) do
			if slime.Parent and slime:GetAttribute("OwnerUserId") == userId then
				writePersistedProgress(slime)
				slime:SetAttribute("LastGrowthUpdate", os.time())
				markStampDirty(slime, "pre_leave_flush")
				if CONFIG.OFFLINE_DEBUG then logOffline(slime, "pre_leave_flush", {}) end
			end
		end
	end
end
SlimeCore.GrowthService = GrowthService

----------------------------------------------------------
-- SlimeHungerService
----------------------------------------------------------
local SlimeHungerService = {}
do
	local HUNGER = {
		BaseDecayFractionPerSecond = 0.02 / 15,
		CollapseInterval           = 5,
		DiscoveryInterval          = 3,
		ReplicateThreshold         = 0.01,
		MinFullness                = 0,
		MaxFullness                = 1,
		UseStageScaling            = false,
		StageDecayMultiplier       = 0.05,
		DEBUG                      = false,
		MarkActiveAttribute        = true,
	}

	local lastCollapse = 0
	local lastDiscovery = 0
	local heartbeatConn = nil

	local function dprint(...) if HUNGER.DEBUG then print("[SlimeHungerService]", ...) end end

	local function clamp(v,a,b)
		if v < a then return a elseif v > b then return b else return v end
	end

	local function computeCurrent(slime, now)
		local cf   = slime:GetAttribute("CurrentFullness")
		local last = slime:GetAttribute("LastHungerUpdate")
		local rate = slime:GetAttribute("HungerDecayRate")
		if cf == nil or last == nil or rate == nil then return nil end
		local elapsed = now - last
		if elapsed <= 0 then
			return clamp(cf, HUNGER.MinFullness, HUNGER.MaxFullness)
		end
		local stage = (HUNGER.UseStageScaling and (slime:GetAttribute("MutationStage") or 0)) or 0
		local effectiveRate = rate * (1 + stage * (HUNGER.StageDecayMultiplier or 0))
		local f = cf - elapsed * effectiveRate
		return clamp(f, HUNGER.MinFullness, HUNGER.MaxFullness)
	end

	local function collapse(slime, now)
		if not slime.Parent then return end
		local val = computeCurrent(slime, now)
		if val == nil then return end
		local oldRep = slime:GetAttribute("CurrentFullness") or val
		if math.abs(oldRep - val) >= HUNGER.ReplicateThreshold then
			slime:SetAttribute("CurrentFullness", val)
			slime:SetAttribute("LastHungerUpdate", now)
		end
		slime:SetAttribute("FedFraction", val)
	end

	local function initSlime(slime, now)
		if slime:GetAttribute("CurrentFullness") == nil then slime:SetAttribute("CurrentFullness", 1) end
		if slime:GetAttribute("LastHungerUpdate") == nil then slime:SetAttribute("LastHungerUpdate", now) end
		if slime:GetAttribute("HungerDecayRate") == nil then slime:SetAttribute("HungerDecayRate", HUNGER.BaseDecayFractionPerSecond) end
		if slime:GetAttribute("FedFraction") == nil then slime:SetAttribute("FedFraction", slime:GetAttribute("CurrentFullness")) end
		if HUNGER.MarkActiveAttribute then slime:SetAttribute("HungerActive", true) end
		dprint("Initialized hunger on", slime, "cf=", slime:GetAttribute("CurrentFullness"))
	end

	local function discover(now)
		for _,inst in ipairs(Workspace:GetDescendants()) do
			if typeof(inst) == "Instance" and inst:IsA("Model") and inst.Name == "Slime" then
				if inst:GetAttribute("CurrentFullness") == nil then initSlime(inst, now) end
			end
		end
	end

	function SlimeHungerService.Feed(slime, restoreFraction)
		if typeof(slime) ~= "Instance" or not (typeof(slime) == "Instance" and slime:IsA("Model")) or slime.Name ~= "Slime" then return false end
		if not slime.Parent then return false end
		local now = os.time()
		local current = computeCurrent(slime, now)
		if current == nil then initSlime(slime, now); current = 1 end
		restoreFraction = clamp(restoreFraction or 0, 0, HUNGER.MaxFullness)
		local after = clamp(current + restoreFraction, HUNGER.MinFullness, HUNGER.MaxFullness)
		slime:SetAttribute("CurrentFullness", after)
		slime:SetAttribute("LastHungerUpdate", now)
		slime:SetAttribute("FedFraction", after)
		return true
	end

	function SlimeHungerService.GetCurrentFullness(slime)
		return computeCurrent(slime, os.time())
	end

	function SlimeHungerService.Start()
		if heartbeatConn then return end
		heartbeatConn = RunService.Heartbeat:Connect(function()
			local now = os.time()
			if now - lastDiscovery >= HUNGER.DiscoveryInterval then
				lastDiscovery = now
				discover(now)
			end
			if now - lastCollapse >= HUNGER.CollapseInterval then
				lastCollapse = now
				for _,inst in ipairs(Workspace:GetDescendants()) do
					if typeof(inst) == "Instance" and inst:IsA("Model") and inst.Name=="Slime" and inst:GetAttribute("CurrentFullness") ~= nil then
						collapse(inst, now)
					end
				end
			end
		end)
	end

	function SlimeHungerService.Stop()
		if heartbeatConn then heartbeatConn:Disconnect(); heartbeatConn = nil end
	end
end
SlimeCore.SlimeHungerService = SlimeHungerService

----------------------------------------------------------
-- GrowthPersistenceService (integrated, decoupled)
-- Call: SlimeCore.GrowthPersistenceService:Init(orchestrator)
----------------------------------------------------------
local GrowthPersistenceService = {}
do
	local Players_local = Players
	local ReplicatedStorage_local = ReplicatedStorage

	GrowthPersistenceService.Name = "GrowthPersistenceService"
	GrowthPersistenceService.Priority = 140

	local CONFIG = {
		Debug                   = true,
		StampIntervalSeconds    = 45,
		PollStepSeconds         = 8,
		EventDebounceSeconds    = 2.5,
		ScanRoots               = { Workspace },
		SlimeModelName          = "Slime",
		OwnerAttr               = "OwnerUserId",
		GrowthAttr              = "GrowthProgress",
		PersistedAttr           = "PersistedGrowthProgress",
		LastUpdateAttr          = "LastGrowthUpdate",
		MaxSlimesPerCycle       = 5000,
		YieldEvery              = 350,
		SkipStampIfLower        = true,
		MarkDirtyReasonPeriodic = "GrowthPeriodic",
		MarkDirtyReasonEvent    = "GrowthStamp",
		SaveReasonEventFlush    = "GrowthStampFlush",
		SaveEventSkipWorldFlag  = { skipWorld = true },
	}

	local Orchestrator = nil
	local lastPeriodicStamp = 0
	local playerEventDebounce = {}   -- [player] = last event stamp os.clock()
	local running = true

	local function dprint(...)
		if CONFIG.Debug then
			print("[GrowthPersist]", ...)
		end
	end

	local function safeMarkDirty(player, reason)
		if Orchestrator and Orchestrator.MarkDirty then
			local ok,err = pcall(function() Orchestrator:MarkDirty(player, reason) end)
			if not ok then warn("[GrowthPersist] MarkDirty error:", err) end
		end
	end

	local function safeSaveNow(player, reason, opts)
		if Orchestrator and Orchestrator.SaveNow then
			local ok,err = pcall(function() Orchestrator:SaveNow(player, reason, opts) end)
			if not ok then warn("[GrowthPersist] SaveNow error:", err) end
		end
	end

	local function iterSlimesOnce()
		local slimes = {}
		for _,root in ipairs(CONFIG.ScanRoots) do
			if root and root.Parent then
				for _,desc in ipairs(root:GetDescendants()) do
					if typeof(desc) == "Instance" and desc:IsA("Model") and desc.Name == CONFIG.SlimeModelName then
						slimes[#slimes+1] = desc
						if #slimes >= CONFIG.MaxSlimesPerCycle then
							warn(("[GrowthPersist] Reached MaxSlimesPerCycle (%d); truncating scan."):format(CONFIG.MaxSlimesPerCycle))
							return slimes
						end
						if (#slimes % CONFIG.YieldEvery) == 0 then task.wait() end
					end
				end
			end
		end
		return slimes
	end

	local function stampSlime(model)
		if not (model and model.Parent and typeof(model) == "Instance" and model:IsA("Model") and model.Name == CONFIG.SlimeModelName) then
			return
		end
		local gp = model:GetAttribute(CONFIG.GrowthAttr)
		if gp then
			local persisted = model:GetAttribute(CONFIG.PersistedAttr)
			if not CONFIG.SkipStampIfLower or (not persisted or gp > persisted) then
				model:SetAttribute(CONFIG.PersistedAttr, gp)
			end
		end
		model:SetAttribute(CONFIG.LastUpdateAttr, os.time())
	end

	local function stampPlayerSlimes(player, slimeList)
		local userId = player.UserId
		for _,slime in ipairs(slimeList) do
			if slime:GetAttribute(CONFIG.OwnerAttr) == userId then
				stampSlime(slime)
			end
		end
	end

	local function handleOnDemandStamp(userId, reason)
		local player = Players_local:GetPlayerByUserId(userId)
		if not player then return end

		local now = os.clock()
		local last = playerEventDebounce[player]
		if last and (now - last) < CONFIG.EventDebounceSeconds then
			dprint(("Debounce: Ignore GrowthStampDirty for %s (%.2fs < %.2fs)"):format(player.Name, now - last, CONFIG.EventDebounceSeconds))
			return
		end
		playerEventDebounce[player] = now

		local slimes = iterSlimesOnce()
		stampPlayerSlimes(player, slimes)

		safeMarkDirty(player, reason or CONFIG.MarkDirtyReasonEvent)
		safeSaveNow(player, CONFIG.SaveReasonEventFlush, CONFIG.SaveEventSkipWorldFlag)
		dprint(("On-demand growth stamp complete for %s (slimes inspected=%d)"):format(player.Name, #slimes))
	end

	local function periodicLoop()
		while running do
			task.wait(CONFIG.PollStepSeconds)
			if not running then break end
			local now = os.clock()
			if now - lastPeriodicStamp >= CONFIG.StampIntervalSeconds then
				lastPeriodicStamp = now
				local slimes = iterSlimesOnce()
				if #slimes > 0 then
					for _,player in ipairs(Players_local:GetPlayers()) do
						stampPlayerSlimes(player, slimes)
						safeMarkDirty(player, CONFIG.MarkDirtyReasonPeriodic)
					end
					dprint(("Periodic stamp: scanned %d slime models."):format(#slimes))
				else
					dprint("Periodic stamp: no slimes found.")
				end
			end
		end
	end

	function GrowthPersistenceService:Init(orch)
		Orchestrator = orch

		local evt = ReplicatedStorage_local:FindFirstChild("GrowthStampDirty")
		if evt and typeof(evt) == "Instance" and evt:IsA("BindableEvent") then
			evt.Event:Connect(function(userId, reason)
				handleOnDemandStamp(userId, reason)
			end)
		else
			dprint("No GrowthStampDirty BindableEvent found (optional).")
		end

		task.spawn(periodicLoop)
		dprint("Initialized (decoupled).")
	end

	function GrowthPersistenceService:OnProfileLoaded() end
	function GrowthPersistenceService:RestoreToPlayer() end
	function GrowthPersistenceService:Serialize() end

	game:BindToClose(function() running = false end)
end
SlimeCore.GrowthPersistenceService = GrowthPersistenceService

----------------------------------------------------------
-- Expose and init helper
----------------------------------------------------------
SlimeCore.RNG = RNG
SlimeCore.SizeRNG = SizeRNG
SlimeCore.SlimeAI = SlimeAI
SlimeCore.ColorUtil = ColorUtil

function SlimeCore.Init()
	-- Start optional services (growth/hunger). Safe to call multiple times.
	if SlimeCore.GrowthService and SlimeCore.GrowthService.Start then
		pcall(function() SlimeCore.GrowthService.Start() end)
	end
	if SlimeCore.SlimeHungerService and SlimeCore.SlimeHungerService.Start then
		pcall(function() SlimeCore.SlimeHungerService.Start() end)
	end
end

return SlimeCore