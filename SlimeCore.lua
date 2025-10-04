-- SlimeCore.lua
-- Fully consolidated module combining:
--   ModelUtils, ColorUtil, SlimeAppearance, SlimeConfig, SlimeMutation,
--   SlimeFactory, GrowthScaling, GrowthService, SlimeHungerService,
--   GrowthPersistenceService.
-- Added: syncModelGrowthIntoProfile to copy authoritative model attributes
--        into the cached PlayerProfile.inventory.worldSlimes entry and push
--        an inventory update so UI reflects growth changes in-session.
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
local SlimeTypeRegistry = require(ModulesRoot:WaitForChild("SlimeTypeRegistry"))

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function getRestoreGraceUntil(slime)
	if not slime or typeof(slime) ~= "Instance" then return nil end
	local untilTs = slime:GetAttribute("_RestoreTimerGraceUntil")
	if type(untilTs) == "number" then return untilTs end
	return nil
end

local function getRestoreGraceRemaining(slime, nowEpoch)
	nowEpoch = nowEpoch or os.time()
	local untilTs = getRestoreGraceUntil(slime)
	if not untilTs then return 0 end
	return math.max(0, untilTs - nowEpoch)
end

local function isWithinRestoreGrace(slime, nowEpoch)
	return getRestoreGraceRemaining(slime, nowEpoch) > 0
end

local function finalizeRestoreGraceIfExpired(slime, nowEpoch)
	nowEpoch = nowEpoch or os.time()
	local untilTs = getRestoreGraceUntil(slime)
	if not untilTs then return false end
	if nowEpoch >= untilTs then
		slime:SetAttribute("_RestoreTimerGraceUntil", nil)
		slime:SetAttribute("RestoreTimerGraceEndedAt", nowEpoch)
		return true
	end
	return false
end

local BASE_WEIGHT_LBS = 15
local MIN_SCALE = 0.05

local function safeGetAttribute(inst, name)
	if not inst or type(inst.GetAttribute) ~= "function" then return nil end
	local ok, value = pcall(function()
		return inst:GetAttribute(name)
	end)
	if ok then return value end
	return nil
end

local function computeWeightScaleFromAttributes(inst)
	local weightPounds = safeGetAttribute(inst, "WeightPounds")
	if type(weightPounds) == "number" and weightPounds > 0 then
		local ratio = weightPounds / BASE_WEIGHT_LBS
		if ratio > 0 then
			local scale = ratio ^ (1/3)
			if scale > 0 and scale < 1e6 then
				return scale
			end
		end
	end
	local weightScalar = safeGetAttribute(inst, "WeightScalar")
	if type(weightScalar) == "number" and weightScalar > 0 then
		local scale = weightScalar ^ (1/3)
		if scale > 0 and scale < 1e6 then
			return scale
		end
	end
	return nil
end

local function alignScaleAttributesFromWeight(inst)
	local target = computeWeightScaleFromAttributes(inst)
	if not target then return nil end

	local currentMax = safeGetAttribute(inst, "MaxSizeScale")
	if type(currentMax) == "number" and math.abs(currentMax - target) <= 1e-4 then
		return nil
	end

	local currentStart = safeGetAttribute(inst, "StartSizeScale")
	local startFraction = nil
	if type(currentStart) == "number" and type(currentMax) == "number" and currentMax > 0 then
		startFraction = math.clamp(currentStart / currentMax, 0, 1)
	end
	if not startFraction then
		local prog = safeGetAttribute(inst, "GrowthProgress")
		if type(prog) == "number" and prog > 0 and prog < 1 then
			startFraction = math.clamp(prog, 0, 1)
		end
	end
	if not startFraction then
		startFraction = 0.05
	end

	local newStart = math.max(target * startFraction, MIN_SCALE)
	inst:SetAttribute("StartSizeScale", newStart)

	local growthProgress = safeGetAttribute(inst, "GrowthProgress")
	if type(growthProgress) == "number" then
		growthProgress = math.clamp(growthProgress, 0, 1)
	else
		growthProgress = nil
	end
	if growthProgress == nil then
		local currentScale = safeGetAttribute(inst, "CurrentSizeScale")
		if type(currentScale) == "number" and target ~= newStart then
			growthProgress = math.clamp((currentScale - newStart) / (target - newStart), 0, 1)
		else
			growthProgress = 0
		end
	end

	inst:SetAttribute("MaxSizeScale", target)

	local newCurrent = newStart + (target - newStart) * growthProgress
	if newCurrent < MIN_SCALE then newCurrent = MIN_SCALE end
	inst:SetAttribute("CurrentSizeScale", newCurrent)
	inst:SetAttribute("_LastAppliedSizeScale", newCurrent)

	return newCurrent
end

local function ensureWeightAlignedMax(inst, currentMax, epsilon)
	local target = computeWeightScaleFromAttributes(inst)
	if not target then return currentMax end
	local threshold = epsilon or 1e-4
	if type(currentMax) ~= "number" or currentMax <= 0 or math.abs(currentMax - target) > threshold then
		inst:SetAttribute("MaxSizeScale", target)
		return target
	end
	return currentMax
end

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
SlimeCore.SlimeTypeRegistry = SlimeTypeRegistry


local DEBUG = _G.DEBUG
local dprint = _G.dprint or function(...) end
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
	SlimeAppearance.ColorFamilies = {
		Verdant = {
			bodies = {
				Color3.fromRGB(120,230,120),
				Color3.fromRGB(112,218,128),
				Color3.fromRGB(138,242,150),
				Color3.fromRGB(118,236,102),
				Color3.fromRGB(142,255,142),
			},
			accents = {
				Color3.fromRGB(84,198,112),
				Color3.fromRGB(96,210,124),
				Color3.fromRGB(90,208,96),
			},
			bodyJitter = {0.035, 0.045, 0.045},
			accentJitter = {0.045, 0.055, 0.045},
		},
		Moss = {
			bodies = {
				Color3.fromRGB(92,188,110),
				Color3.fromRGB(84,176,118),
				Color3.fromRGB(102,204,128),
				Color3.fromRGB(96,194,104),
			},
			accents = {
				Color3.fromRGB(72,156,92),
				Color3.fromRGB(88,170,110),
				Color3.fromRGB(70,150,120),
			},
			bodyJitter = {0.035, 0.05, 0.04},
			accentJitter = {0.045, 0.05, 0.04},
		},
		Lagoon = {
			bodies = {
				Color3.fromRGB(90,220,205),
				Color3.fromRGB(70,204,212),
				Color3.fromRGB(52,192,188),
				Color3.fromRGB(108,236,222),
			},
			accents = {
				Color3.fromRGB(54,188,178),
				Color3.fromRGB(66,202,198),
				Color3.fromRGB(72,210,206),
			},
			bodyJitter = {0.05, 0.05, 0.04},
			accentJitter = {0.05, 0.06, 0.045},
		},
		Azure = {
			bodies = {
				Color3.fromRGB(120,182,255),
				Color3.fromRGB(100,170,242),
				Color3.fromRGB(140,194,250),
				Color3.fromRGB(105,176,232),
			},
			accents = {
				Color3.fromRGB(82,148,230),
				Color3.fromRGB(70,136,218),
				Color3.fromRGB(92,158,235),
			},
			bodyJitter = {0.05, 0.05, 0.05},
			accentJitter = {0.055, 0.055, 0.045},
		},
		Amethyst = {
			bodies = {
				Color3.fromRGB(210,140,255),
				Color3.fromRGB(196,120,242),
				Color3.fromRGB(225,155,255),
				Color3.fromRGB(188,108,236),
			},
			accents = {
				Color3.fromRGB(170,80,220),
				Color3.fromRGB(184,96,232),
				Color3.fromRGB(166,70,210),
			},
			bodyJitter = {0.05, 0.06, 0.05},
			accentJitter = {0.055, 0.06, 0.05},
		},
		Sunset = {
			bodies = {
				Color3.fromRGB(255,200,92),
				Color3.fromRGB(255,178,66),
				Color3.fromRGB(242,188,118),
				Color3.fromRGB(255,210,130),
			},
			accents = {
				Color3.fromRGB(230,150,40),
				Color3.fromRGB(240,168,72),
				Color3.fromRGB(212,140,52),
			},
			bodyJitter = {0.06, 0.05, 0.05},
			accentJitter = {0.06, 0.05, 0.05},
		},
		Frost = {
			bodies = {
				Color3.fromRGB(220,245,255),
				Color3.fromRGB(205,235,255),
				Color3.fromRGB(236,255,246),
				Color3.fromRGB(198,228,242),
			},
			accents = {
				Color3.fromRGB(190,225,245),
				Color3.fromRGB(176,212,236),
				Color3.fromRGB(200,238,252),
			},
			bodyJitter = {0.04, 0.05, 0.05},
			accentJitter = {0.045, 0.05, 0.05},
		},
		Shadow = {
			bodies = {
				Color3.fromRGB(60,90,120),
				Color3.fromRGB(42,72,96),
				Color3.fromRGB(30,60,82),
				Color3.fromRGB(72,52,108),
			},
			accents = {
				Color3.fromRGB(36,64,88),
				Color3.fromRGB(48,76,110),
				Color3.fromRGB(58,84,122),
			},
			bodyJitter = {0.035, 0.045, 0.035},
			accentJitter = {0.04, 0.045, 0.035},
		},
	}

	SlimeAppearance.DefaultFamilyWeights = {
		{ item = "Verdant", weight = 1.0 },
		{ item = "Moss",    weight = 0.8 },
		{ item = "Lagoon",  weight = 0.45 },
		{ item = "Azure",   weight = 0.32 },
		{ item = "Amethyst",weight = 0.24 },
		{ item = "Sunset",  weight = 0.12 },
		{ item = "Frost",   weight = 0.08 },
		{ item = "Shadow",  weight = 0.05 },
	}

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
			familyWeights = {
				{ item = "Verdant", weight = 1.0 },
				{ item = "Moss",    weight = 0.8 },
				{ item = "Lagoon",  weight = 0.5 },
				{ item = "Azure",   weight = 0.32 },
				{ item = "Amethyst",weight = 0.22 },
				{ item = "Sunset",  weight = 0.12 },
				{ item = "Frost",   weight = 0.08 },
				{ item = "Shadow",  weight = 0.05 },
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
			familyWeights = {
				{ item = "Verdant", weight = 0.75 },
				{ item = "Moss",    weight = 0.55 },
				{ item = "Lagoon",  weight = 0.55 },
				{ item = "Azure",   weight = 0.50 },
				{ item = "Amethyst",weight = 0.38 },
				{ item = "Sunset",  weight = 0.18 },
				{ item = "Frost",   weight = 0.12 },
				{ item = "Shadow",  weight = 0.08 },
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
			familyWeights = {
				{ item = "Verdant", weight = 0.6 },
				{ item = "Moss",    weight = 0.45 },
				{ item = "Lagoon",  weight = 0.55 },
				{ item = "Azure",   weight = 0.60 },
				{ item = "Amethyst",weight = 0.55 },
				{ item = "Sunset",  weight = 0.25 },
				{ item = "Frost",   weight = 0.18 },
				{ item = "Shadow",  weight = 0.12 },
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
			familyWeights = {
				{ item = "Verdant", weight = 0.42 },
				{ item = "Moss",    weight = 0.35 },
				{ item = "Lagoon",  weight = 0.55 },
				{ item = "Azure",   weight = 0.65 },
				{ item = "Amethyst",weight = 0.70 },
				{ item = "Sunset",  weight = 0.40 },
				{ item = "Frost",   weight = 0.25 },
				{ item = "Shadow",  weight = 0.15 },
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
		Color3.fromRGB(255, 92,200),
		Color3.fromRGB( 90,255,255),
		Color3.fromRGB(255,200,120),
		Color3.fromRGB( 36, 36, 72),
		Color3.fromRGB(212,255,120),
	}

	SlimeAppearance.MutationEyeColors = {
		Color3.fromRGB(255,50,50),
		Color3.fromRGB(50,50,255),
		Color3.fromRGB(255,255,80),
		Color3.fromRGB(255,120,255),
		Color3.fromRGB(120,255,220),
		Color3.fromRGB(255,180,90),
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
			local weights = config.familyWeights or SlimeAppearance.DefaultFamilyWeights
			local familyName = RNG.WeightedChoice(weights, rng)
			local family = SlimeAppearance.ColorFamilies[familyName] or SlimeAppearance.ColorFamilies.Verdant
			local baseBody = RNG.Pick(family and family.bodies or config.bodies, rng)
			if not baseBody and config.bodies then
				baseBody = RNG.Pick(config.bodies, rng)
			end
			if not baseBody then
				baseBody = Color3.fromRGB(120, 230, 120)
			end
			local baseAccent = RNG.Pick(family and family.accents or config.accent, rng)
			if not baseAccent and config.accent then
				baseAccent = RNG.Pick(config.accent, rng)
			end
			if not baseAccent then
				baseAccent = Color3.fromRGB(90, 200, 110)
			end
			local bodyJitter = (family and family.bodyJitter) or {0.04, 0.04, 0.04}
			local accentJitter = (family and family.accentJitter) or {0.05, 0.05, 0.05}
			bodyColor = RNG.DriftColor(baseBody, bodyJitter[1], bodyJitter[2], bodyJitter[3], rng)
			accentColor = RNG.DriftColor(baseAccent, accentJitter[1], accentJitter[2], accentJitter[3], rng)
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
			BaseMaxSizeRange         = {0.90, 1.35},
			StartScaleFractionRange  = {0.012, 0.028},
			FeedBufferPerItem        = 15,
			FeedBufferMax            = 120,
			AbsoluteMaxScaleCap      = 200,
			DurationExponentAlpha    = 0.6,
			DurationBreakPoint       = 64,
			DurationLogK             = 0.35,
			ValueBaseFull            = 150,
			ValueSizeExponent        = 1.15,
			RarityLuckPremiumPerLevel= 0.02,
			Mutation = {
				BaseChance = 0.006,
				ChancePerLuckRoll = 0.0015,
				LegacyStageValueBonus = 0.08,
				ValueMultCap = 5.0,
				TypeWeights = {
					Food = 0.45,
					Color = 0.30,
					Size = 0.20,
					Physical = 0.05,
				},
				ValueMultipliers = {
					Food = 1.05,
					Color = 1.12,
					Size = 1.18,
					Physical = 1.35,
				},
				Color = {
					MultiPartChance = 0.4,
					Jitter = { H = 0.18, S = 0.22, V = 0.24 },
				},
				Size = {
					ScaleBoostRange = {1.12, 1.28},
					AdjustCurrentScale = true,
				},
				Physical = {
					HighlightFillColor    = Color3.fromRGB(240, 255, 180),
					HighlightOutlineColor = Color3.fromRGB(90, 110, 50),
					HighlightTransparency = 0.18,
					NeonizeParts          = true,
				},
				Food = {
					PlaceholderValueMult = 1.05,
				},
			},
			SizeJackpot = {
				{ p = 1/90,        mult = {1.08,1.18} },
				{ p = 1/320,       mult = {1.20,1.35} },
				{ p = 1/1200,      mult = {1.38,1.65} },
				{ p = 1/6000,      mult = {1.80,2.20} },
				{ p = 1/40000,     mult = {2.40,3.20} },
				{ p = 1/250000,    mult = {3.80,5.00} },
				{ p = 1/1500000,   mult = {6.00,8.50} },
				{ p = 1/25000000,  mult = {12.0,18.0} },
				{ p = 1/500000000, mult = {30.0,45.0} },
				{ p = 1/2000000000,mult = {60.0,80.0} },
			},
			MutationColorJitter = { H = 0.12, S = 0.18, V = 0.20 },
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
	local MAX_HISTORY = 25
	local function getHistory(slime)
		local raw = slime:GetAttribute("MutationHistory")
		if not raw or raw == "" then return {} end
		local ok, data = pcall(HttpService.JSONDecode, HttpService, raw)
		if ok and type(data) == "table" then return data end
		return {}
	end
	local function setHistory(slime, tbl)
		if type(tbl) == "table" and #tbl > MAX_HISTORY then
			while #tbl > MAX_HISTORY do table.remove(tbl, 1) end
		end
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

	local function gatherMutableParts(slime, cfg)
		local results = {}
		for _,p in ipairs(slime:GetDescendants()) do
			if typeof(p) == "Instance" and p:IsA("BasePart") and lowercaseMatchAny(p.Name, cfg.MutablePartNamePatterns) then
				table.insert(results, p)
			end
		end
		return results
	end

	local function resolveJitter(jitter, fallback)
		local baseH = (fallback and (fallback.H or fallback[1])) or 0.12
		local baseS = (fallback and (fallback.S or fallback[2])) or 0.18
		local baseV = (fallback and (fallback.V or fallback[3])) or 0.20
		if jitter then
			baseH = jitter.H or jitter[1] or baseH
			baseS = jitter.S or jitter[2] or baseS
			baseV = jitter.V or jitter[3] or baseV
		end
		return baseH, baseS, baseV
	end

	local function resolveValueMultiplier(mutCfg, mutType)
		local map = mutCfg.ValueMultipliers
		if map and map[mutType] then
			local val = tonumber(map[mutType])
			if val and val > 0 then return val end
		end
		return 1
	end

	local function applyColorMutation(slime, tierCfg, mutCfg, rng)
		local mutable = gatherMutableParts(slime, tierCfg)
		if #mutable == 0 then
			return { valueMult = resolveValueMultiplier(mutCfg, "Color"), details = { parts = {} } }
		end
		local colorCfg = mutCfg.Color or {}
		local jitterBase = tierCfg.MutationColorJitter or { H = 0.12, S = 0.18, V = 0.20 }
		local h, s, v = resolveJitter(colorCfg.Jitter, jitterBase)
		rng = getRaw(rng)
		local mutateAll = RNG.Bool(colorCfg.MultiPartChance or 0.35, rng)
		local mutatedParts = {}
		if mutateAll then
			for _,part in ipairs(mutable) do
				part.Color = RNG.DriftColor(part.Color, h, s, v, rng)
				table.insert(mutatedParts, part.Name)
			end
		else
			local target = mutable[RNG.Int(1, #mutable, rng)]
			target.Color = RNG.DriftColor(target.Color, h * 1.15, s * 1.1, v * 1.1, rng)
			table.insert(mutatedParts, target.Name)
		end
		return {
			valueMult = resolveValueMultiplier(mutCfg, "Color"),
			details = { parts = mutatedParts, mode = mutateAll and "spread" or "focus" },
		}
	end

	local function applyFoodMutation(slime, _tierCfg, mutCfg, _rng)
		local count = (slime:GetAttribute("MutationFoodStubCount") or 0) + 1
		slime:SetAttribute("MutationFoodStubCount", count)
		slime:SetAttribute("MutationFoodStub", true)
		return {
			valueMult = resolveValueMultiplier(mutCfg, "Food"),
			details = { placeholder = true, count = count },
		}
	end

	local function applySizeMutation(slime, tierCfg, mutCfg, rng)
		rng = getRaw(rng)
		local sizeCfg = mutCfg.Size or {}
		local range = sizeCfg.ScaleBoostRange or {1.10, 1.22}
		local minBoost = tonumber(range[1]) or 1.10
		local maxBoost = tonumber(range[2]) or minBoost
		if maxBoost < minBoost then maxBoost = minBoost end
		local boost = RNG.Float(minBoost, maxBoost, rng)
		local currentMax = slime:GetAttribute("MaxSizeScale") or tierCfg.BaseMaxSizeRange and tierCfg.BaseMaxSizeRange[2] or 1
		if currentMax <= 0 then currentMax = 1 end
		local newMax = currentMax * boost
		local cap = tonumber(tierCfg.AbsoluteMaxScaleCap) or math.huge
		if newMax > cap then newMax = cap end
		newMax = ensureWeightAlignedMax(slime, newMax, 1e-4)
		slime:SetAttribute("MaxSizeScale", newMax)
		slime:SetAttribute("MutationSizeBoost", (slime:GetAttribute("MutationSizeBoost") or 1) * (newMax / math.max(currentMax, 1e-4)))
		if sizeCfg.AdjustCurrentScale ~= false then
			local progress = math.clamp(tonumber(slime:GetAttribute("GrowthProgress")) or 0, 0, 1)
			local startScale = tonumber(slime:GetAttribute("StartSizeScale")) or newMax
			local eased = progress * progress * (3 - 2 * progress)
			local targetScale = startScale + (newMax - startScale) * eased
			slime:SetAttribute("CurrentSizeScale", targetScale)
			local refreshToken = (slime:GetAttribute("ForceScaleRefresh") or 0) + 1
			slime:SetAttribute("ForceScaleRefresh", refreshToken)
		end
		return {
			valueMult = resolveValueMultiplier(mutCfg, "Size"),
			details = { boost = boost, newMax = newMax },
		}
	end

	local function applyPhysicalMutation(slime, tierCfg, mutCfg, rng)
		rng = getRaw(rng)
		local physicalCfg = mutCfg.Physical or {}
		local mutable = gatherMutableParts(slime, tierCfg)
		local mutatedParts = {}
		local jitterPreset = physicalCfg.Jitter or { H = 0.22, S = 0.26, V = 0.26 }
		local h, s, v = resolveJitter(jitterPreset, tierCfg.MutationColorJitter)
		for _,part in ipairs(mutable) do
			part.Color = RNG.DriftColor(part.Color, h, s, v, rng)
			if physicalCfg.NeonizeParts then
				part.Material = Enum.Material.Neon
			end
			table.insert(mutatedParts, part.Name)
		end
		local highlight = slime:FindFirstChild("MutationHighlight")
		if not highlight or not highlight:IsA("Highlight") then
			highlight = Instance.new("Highlight")
			highlight.Name = "MutationHighlight"
			highlight.DepthMode = Enum.HighlightDepthMode.Occluded
			highlight.Parent = slime
		end
		highlight.Adornee = slime
		highlight.FillColor = physicalCfg.HighlightFillColor or Color3.fromRGB(242, 255, 196)
		highlight.FillTransparency = physicalCfg.HighlightTransparency or 0.18
		highlight.OutlineColor = physicalCfg.HighlightOutlineColor or Color3.fromRGB(120, 135, 70)
		highlight.OutlineTransparency = 0.05
		return {
			valueMult = resolveValueMultiplier(mutCfg, "Physical"),
			details = { highlight = true, parts = mutatedParts },
		}
	end

	local MUTATION_APPLIERS = {
		Food = applyFoodMutation,
		Color = applyColorMutation,
		Size = applySizeMutation,
		Physical = applyPhysicalMutation,
	}

	local function pickMutationType(mutCfg, rng)
		rng = getRaw(rng)
		local weights = mutCfg.TypeWeights
		if weights then
			local choice = RNG.WeightedChoice(weights, rng)
			if choice then return choice end
		end
		return "Color"
	end

	function SlimeMutation.RecomputeValueFull(slime)
		local tier = slime:GetAttribute("Tier") or "Basic"
		local cfg = SlimeConfig.GetTierConfig(tier)
		local maxScale = slime:GetAttribute("MaxSizeScale") or 1
		local sizeNorm = maxScale / (SlimeConfig.AverageScaleBasic or 1)
		local luckLevels = slime:GetAttribute("SizeLuckRolls") or 0
		local mutationMult = slime:GetAttribute("MutationValueMult") or 1
		if type(mutationMult) ~= "number" or mutationMult <= 0 then mutationMult = 1 end
		local rarityPremium = 1 + luckLevels * (cfg.RarityLuckPremiumPerLevel or 0)
		local valueFull = (cfg.ValueBaseFull or 150) * (sizeNorm ^ (cfg.ValueSizeExponent or 1.15)) * rarityPremium * mutationMult
		slime:SetAttribute("ValueFull", valueFull)
		local prog = slime:GetAttribute("GrowthProgress") or 0
		slime:SetAttribute("CurrentValue", valueFull * prog)
	end

	function SlimeMutation.InitSlime(slime)
		local legacyStage = slime:GetAttribute("MutationStage")
		if legacyStage ~= nil then
			local stageNum = tonumber(legacyStage) or 0
			if slime:GetAttribute("MutationCount") == nil then
				slime:SetAttribute("MutationCount", stageNum)
			end
			if slime:GetAttribute("MutationValueMult") == nil then
				local tier = slime:GetAttribute("Tier") or "Basic"
				local cfg = SlimeConfig.GetTierConfig(tier)
				local mutCfg = cfg.Mutation or {}
				local bonus = mutCfg.LegacyStageValueBonus or 0.08
				slime:SetAttribute("MutationValueMult", 1 + stageNum * bonus)
			end
			slime:SetAttribute("MutationStage", nil)
		end
		if slime:GetAttribute("MutationHistory") == nil then setHistory(slime, {}) end
		if slime:GetAttribute("MutationValueMult") == nil then slime:SetAttribute("MutationValueMult", 1) end
		if slime:GetAttribute("MutationCount") == nil then slime:SetAttribute("MutationCount", 0) end
		if slime:GetAttribute("MutationLastType") == nil then slime:SetAttribute("MutationLastType", "") end
		if slime:GetAttribute("MutationHasPhysical") == nil then slime:SetAttribute("MutationHasPhysical", false) end
		if slime:GetAttribute("MutationFoodStub") == nil then slime:SetAttribute("MutationFoodStub", false) end
		if slime:GetAttribute("MutationFoodStubCount") == nil then slime:SetAttribute("MutationFoodStubCount", 0) end
		if slime:GetAttribute("MutationSizeBoost") == nil then slime:SetAttribute("MutationSizeBoost", 1) end
		if slime:GetAttribute("ForceScaleRefresh") == nil then slime:SetAttribute("ForceScaleRefresh", 0) end
	end

	function SlimeMutation.AttemptMutation(slime, rng, opts)
		opts = opts or {}
		local rawRng = getRaw(rng)
		local tier = slime:GetAttribute("Tier") or "Basic"
		local cfg = SlimeConfig.GetTierConfig(tier)
		local mutCfg = cfg.Mutation or {}
		local baseChance = mutCfg.BaseChance or 0.003
		local luckLevels = tonumber(slime:GetAttribute("SizeLuckRolls")) or 0
		local chance = baseChance + (mutCfg.ChancePerLuckRoll or 0) * luckLevels + (opts.extraChance or 0)
		chance = math.clamp(chance, 0, 1)
		local success = opts.force or RNG.Bool(chance, rawRng)
		if not success then return false end

		local mutType = opts.forceType or pickMutationType(mutCfg, rawRng)
		local handler = MUTATION_APPLIERS[mutType]
		if not handler then
			mutType = "Color"
			handler = MUTATION_APPLIERS.Color
		end
		local result = nil
		if handler then
			local ok, payload = pcall(handler, slime, cfg, mutCfg, rawRng)
			if ok then
				result = payload
			else
				warn(string.format("[SlimeMutation] Mutation handler '%s' failed: %s", tostring(mutType), tostring(payload)))
			end
		end
		local appliedMult = (result and result.valueMult) or resolveValueMultiplier(mutCfg, mutType)
		if type(appliedMult) ~= "number" or appliedMult <= 0 then appliedMult = 1 end
		local currentMult = slime:GetAttribute("MutationValueMult") or 1
		if type(currentMult) ~= "number" or currentMult <= 0 then currentMult = 1 end
		local combinedMult = currentMult * appliedMult
		local valueMultCap = mutCfg.ValueMultCap
		if valueMultCap and combinedMult > valueMultCap then combinedMult = valueMultCap end
		if combinedMult < 0.01 then combinedMult = 0.01 end
		slime:SetAttribute("MutationValueMult", combinedMult)
		local count = (slime:GetAttribute("MutationCount") or 0) + 1
		slime:SetAttribute("MutationCount", count)
		slime:SetAttribute("MutationLastType", mutType)
		slime:SetAttribute("MutationLastApplied", os.time())
		if mutType == "Physical" then
			slime:SetAttribute("MutationHasPhysical", true)
		end

		local hist = getHistory(slime)
		local details = result and result.details or nil
		table.insert(hist, {
			type = mutType,
			time = os.time(),
			details = details,
			valueMult = appliedMult,
			totalValueMult = slime:GetAttribute("MutationValueMult"),
		})
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
	local DEFAULT_TEMPLATE_PATH = { "Assets", "Slime" }
	local FALLBACK_NAME = "Slime"
	local MIN_PART_AXIS  = 0.05
	local BODY_PART_CANDIDATES = { "Outer","Inner","Body","Core","Main","Torso","Slime","Base" }
	local RESTORE_TIMER_GRACE_SECONDS = 6
	local DEFAULT_SLIME_TYPE = (SlimeTypeRegistry and SlimeTypeRegistry.GetDefaultType and SlimeTypeRegistry.GetDefaultType()) or "Basic"
	local LEGACY_WELD_CLASSES = {
		Weld = true,
		ManualWeld = true,
		Snap = true,
	}

	local function findTemplate(slimeType)
		slimeType = (type(slimeType) == "string" and slimeType ~= "" and slimeType) or DEFAULT_SLIME_TYPE
		if SlimeTypeRegistry then
			local byType = SlimeTypeRegistry.ResolveSlimeTemplate(slimeType)
			if byType and typeof(byType) == "Instance" and byType:IsA("Model") then
				return byType
			end
			if slimeType ~= DEFAULT_SLIME_TYPE then
				local fallback = SlimeTypeRegistry.ResolveSlimeTemplate(DEFAULT_SLIME_TYPE)
				if fallback and typeof(fallback) == "Instance" and fallback:IsA("Model") then
					return fallback
				end
			end
		end
		local node = ReplicatedStorage
		for _,seg in ipairs(DEFAULT_TEMPLATE_PATH) do
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

	local CORNER_SIGNS = {
		Vector3.new(-1,-1,-1), Vector3.new(-1,-1, 1), Vector3.new(-1, 1,-1), Vector3.new(-1, 1, 1),
		Vector3.new( 1,-1,-1), Vector3.new( 1,-1, 1), Vector3.new( 1, 1,-1), Vector3.new( 1, 1, 1),
	}

	local function refreshLegacyWelds(model)
		if not model then return end
		for _, inst in ipairs(model:GetDescendants()) do
			if inst and LEGACY_WELD_CLASSES[inst.ClassName] and inst.Part0 and inst.Part1 then
				local ok, rel = pcall(function()
					return inst.Part0.CFrame:ToObjectSpace(inst.Part1.CFrame)
				end)
				if ok and rel then
					pcall(function()
						inst.C0 = rel
						inst.C1 = CFrame.new()
					end)
				end
			end
		end
	end

	local function ensureOriginalBounds(model, primary)
		if not model or not primary or typeof(primary) ~= "Instance" or not primary:IsA("BasePart") then return end
		local minY, maxY = nil, nil
		local lastApplied = model:GetAttribute("_LastAppliedSizeScale")
		if type(lastApplied) ~= "number" or lastApplied <= 0 then
			lastApplied = model:GetAttribute("CurrentSizeScale") or model:GetAttribute("StartSizeScale") or 1
		end
		for _,part in ipairs(model:GetDescendants()) do
			if typeof(part) == "Instance" and part:IsA("BasePart") then
				local relCF
				if part == primary then
					relCF = CFrame.new()
				else
					relCF = part:GetAttribute("OriginalRelCF")
				end
				local origSize = part:GetAttribute("OriginalSize")
				if not origSize then
					local captured = part.Size
					if type(lastApplied) == "number" and lastApplied > 0 then
						captured = captured / lastApplied
					end
					origSize = captured
					part:SetAttribute("OriginalSize", origSize)
				end
				if typeof(relCF) ~= "CFrame" then
					local okDerive, derived = pcall(function() return primary.CFrame:ToObjectSpace(part.CFrame) end)
					if okDerive and derived then
						local basePos = derived.Position
						if type(lastApplied) == "number" and lastApplied ~= 0 then
							basePos = basePos / lastApplied
						end
						local rx, ry, rz = derived:ToOrientation()
						relCF = CFrame.new(basePos) * CFrame.fromOrientation(rx, ry, rz)
						part:SetAttribute("OriginalRelCF", relCF)
						part:SetAttribute("OriginalRelOffset", relCF.Position)
					end
				end
				if typeof(relCF) == "CFrame" and origSize then
					for _,sign in ipairs(CORNER_SIGNS) do
						local cornerLocal = Vector3.new(origSize.X * 0.5 * sign.X, origSize.Y * 0.5 * sign.Y, origSize.Z * 0.5 * sign.Z)
						local corner = relCF:PointToWorldSpace(cornerLocal)
						local y = corner.Y
						if minY == nil or y < minY then minY = y end
						if maxY == nil or y > maxY then maxY = y end
					end
				end
			end
		end
		if minY then model:SetAttribute("OriginalMinYOffset", minY) end
		if maxY then model:SetAttribute("OriginalMaxYOffset", maxY) end
		if minY and maxY then model:SetAttribute("OriginalVerticalSpan", maxY - minY) end
	end

	local function adjustModelHeightForScale(model, primary, oldScale, newScale)
		if not model or not primary or typeof(primary) ~= "Instance" or not primary:IsA("BasePart") then
			return primary and primary.CFrame or nil
		end
		local originalMin = model:GetAttribute("OriginalMinYOffset")
		if type(originalMin) ~= "number" then
			return primary.CFrame
		end
		oldScale = (type(oldScale) == "number" and oldScale > 0) and oldScale or model:GetAttribute("_LastAppliedSizeScale") or model:GetAttribute("CurrentSizeScale") or model:GetAttribute("StartSizeScale") or 1
		if type(newScale) ~= "number" or newScale <= 0 then newScale = oldScale end
		local oldMin = originalMin * oldScale
		local newMin = originalMin * newScale
		local delta = oldMin - newMin
		if math.abs(delta) < 1e-4 then
			return primary.CFrame
		end
		local rootCF = primary.CFrame
		local target = rootCF + (rootCF.UpVector * delta)
		local ok = pcall(function()
			model:PivotTo(target)
		end)
		if not ok then
			pcall(function()
				primary.CFrame = target
			end)
		end
		local newPrimary = model.PrimaryPart or primary
		return newPrimary.CFrame
	end

	local function captureOriginalData(model, primary)
		pcall(function() print("[WS_DBG captureOriginalData(SlimeCore)] model=", (model and model.Name) or "<nil>", "primary=", (primary and primary.Name) or "<nil>") end)
		for _,part in ipairs(model:GetDescendants()) do
			if typeof(part) == "Instance" and part:IsA("BasePart") then
				part:SetAttribute("OriginalSize", part.Size)
				if part == primary then
					part:SetAttribute("OriginalRelOffset", Vector3.new(0,0,0))
					part:SetAttribute("OriginalRelYaw", 0)
					part:SetAttribute("OriginalRelCF", CFrame.new())
				else
					local ok, rel = pcall(function()
						if primary and primary:IsA("BasePart") then
							return primary.CFrame:ToObjectSpace(part.CFrame)
						end
						return nil
					end)
					if ok and rel then
						part:SetAttribute("OriginalRelCF", rel)
						part:SetAttribute("OriginalRelOffset", rel.Position)
						local yaw = nil
						pcall(function() yaw = math.atan2(-rel.LookVector.X, -rel.LookVector.Z) end)
						if yaw then part:SetAttribute("OriginalRelYaw", yaw) end
						pcall(function()
							local sid = model.GetAttribute and model:GetAttribute("SlimeId") or "<nil>"
							print("[WS_DBG captureOriginalData] SlimeId=", tostring(sid), "part=", part.Name, "OriginalRelOffset=", tostring(part:GetAttribute("OriginalRelOffset")), "OriginalRelYaw=", tostring(part:GetAttribute("OriginalRelYaw")))
						end)
					else
						pcall(function() print("[WS_DBG captureOriginalData(SlimeCore)] missing primary or ToObjectSpace failed for part=", part.Name) end)
						part:SetAttribute("OriginalRelOffset", nil)
						part:SetAttribute("OriginalRelYaw", nil)
					end
				end
			end
		end
		local baseScale = model:GetAttribute("CurrentSizeScale") or model:GetAttribute("StartSizeScale") or 1
		model:SetAttribute("OriginalBaseScale", baseScale > 0 and baseScale or 1)
		model:SetAttribute("_LastAppliedSizeScale", model:GetAttribute("OriginalBaseScale"))
		ensureOriginalBounds(model, primary)
	end

	SlimeFactory._EnsureOriginalBounds = ensureOriginalBounds
	SlimeFactory._AdjustModelHeightForScale = adjustModelHeightForScale
	SlimeFactory._RefreshLegacyWelds = refreshLegacyWelds

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

	-- Replace SlimeFactory.applyScale with this implementation (keeps rotation, scales offsets)
	local function applyScale(model, primary, scale)
		if not scale or scale <= 0 then return end
		ensureOriginalBounds(model, primary)
		local oldScale = model:GetAttribute("_LastAppliedSizeScale")
		if type(oldScale) ~= "number" or oldScale <= 0 then
			oldScale = model:GetAttribute("CurrentSizeScale") or model:GetAttribute("StartSizeScale") or model:GetAttribute("OriginalBaseScale") or 1
		end

		for _, p in ipairs(model:GetDescendants()) do
			if typeof(p) == "Instance" and p:IsA("BasePart") then
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

		if not primary or not primary:IsA("BasePart") then
			model:SetAttribute("CurrentSizeScale", scale)
			model:SetAttribute("_LastAppliedSizeScale", scale)
			return
		end

		local rootCF = adjustModelHeightForScale(model, primary, oldScale, scale)
		if typeof(rootCF) ~= "CFrame" then
			rootCF = primary.CFrame
		end

			local anchorStates = {}
			for _, p in ipairs(model:GetDescendants()) do
				if typeof(p) == "Instance" and p:IsA("BasePart") then
					anchorStates[p] = p.Anchored
					p.Anchored = true
					p.AssemblyLinearVelocity = Vector3.zero
					p.AssemblyAngularVelocity = Vector3.zero
				end
			end

			for _, p in ipairs(model:GetDescendants()) do
			if typeof(p) == "Instance" and p:IsA("BasePart") and p ~= primary then
				local relCF = p:GetAttribute("OriginalRelCF")
				if typeof(relCF) ~= "CFrame" then
					local okDerive, derived = pcall(function() return primary.CFrame:ToObjectSpace(p.CFrame) end)
					if okDerive and derived then
						relCF = derived
						local currentScale = model:GetAttribute("CurrentSizeScale") or model:GetAttribute("StartSizeScale") or oldScale or 1
						if currentScale ~= 0 then
							local basePos = derived.Position / currentScale
							local rx, ry, rz = derived:ToOrientation()
							relCF = CFrame.new(basePos) * CFrame.fromOrientation(rx, ry, rz)
						else
							relCF = derived
						end
						p:SetAttribute("OriginalRelCF", relCF)
						p:SetAttribute("OriginalRelOffset", relCF.Position)
					end
				end
				if typeof(relCF) == "CFrame" then
					local offset = relCF.Position * scale
					local rx, ry, rz = relCF:ToOrientation()
					local desired = rootCF * (CFrame.new(offset) * CFrame.fromOrientation(rx, ry, rz))
					pcall(function() p.CFrame = desired end)
				end
			end
		end

		refreshLegacyWelds(model)

				for part, wasAnchored in pairs(anchorStates) do
					pcall(function()
						part.Anchored = wasAnchored and true or false
					end)
				end

		model:SetAttribute("CurrentSizeScale", scale)
		model:SetAttribute("_LastAppliedSizeScale", scale)
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
		local resolvedType = nil
		if type(params.SlimeType) == "string" and params.SlimeType ~= "" then
			resolvedType = params.SlimeType
		elseif type(params.Breed) == "string" and params.Breed ~= "" then
			resolvedType = params.Breed
		end
		resolvedType = resolvedType or DEFAULT_SLIME_TYPE
		params.SlimeType = resolvedType
		params.Breed = params.Breed or resolvedType
		local typeDef = SlimeTypeRegistry and SlimeTypeRegistry.Get and SlimeTypeRegistry.Get(resolvedType)
		if typeDef and type(typeDef) == "table" then
			params.Tier = params.Tier or typeDef.tier
		end
		local template = findTemplate(resolvedType)
		if not template then return nil, "NoTemplate" end
		local slime = template:Clone()
		slime.Name = "Slime"

		slime:SetAttribute("OwnerUserId", params.OwnerUserId or 0)
		slime:SetAttribute("SlimeId", params.SlimeId or HttpService:GenerateGUID(false))
		slime:SetAttribute("SlimeType", resolvedType)
		slime:SetAttribute("Breed", params.Breed)
		if params.Rarity       then slime:SetAttribute("Rarity", params.Rarity) end
		if params.MovementScalar then slime:SetAttribute("MovementScalar", params.MovementScalar) end
		if params.WeightScalar then slime:SetAttribute("WeightScalar", params.WeightScalar) end
		if params.WeightPounds then slime:SetAttribute("WeightPounds", params.WeightPounds) end
		if params.MutationRarityBonus then slime:SetAttribute("MutationRarityBonus", params.MutationRarityBonus) end
		if params.Tier then slime:SetAttribute("Tier", params.Tier) end
		if params.MutationCount then slime:SetAttribute("MutationCount", params.MutationCount) end
		if params.MutationValueMult then slime:SetAttribute("MutationValueMult", params.MutationValueMult) end
		if params.MutationLastType then slime:SetAttribute("MutationLastType", params.MutationLastType) end
		if params.MutationLastApplied then slime:SetAttribute("MutationLastApplied", params.MutationLastApplied) end
		if params.MutationHasPhysical ~= nil then slime:SetAttribute("MutationHasPhysical", params.MutationHasPhysical) end
		if params.MutationFoodStub ~= nil then slime:SetAttribute("MutationFoodStub", params.MutationFoodStub) end
		if params.MutationFoodStubCount then slime:SetAttribute("MutationFoodStubCount", params.MutationFoodStubCount) end
		if params.MutationSizeBoost then slime:SetAttribute("MutationSizeBoost", params.MutationSizeBoost) end
		if params.MutationHistory then
			if type(params.MutationHistory) == "table" then
				local ok, encoded = pcall(HttpService.JSONEncode, HttpService, params.MutationHistory)
				if ok then slime:SetAttribute("MutationHistory", encoded) end
			elseif type(params.MutationHistory) == "string" then
				slime:SetAttribute("MutationHistory", params.MutationHistory)
			end
		end

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
		local weightAlignedScale = alignScaleAttributesFromWeight(slime)
		local targetScale = params.CurrentSizeScale or weightAlignedScale or slime:GetAttribute("CurrentSizeScale") or 1
		targetScale = tonumber(targetScale) or 1
		if targetScale <= 0 then targetScale = 1 end
		if targetScale < MIN_SCALE then targetScale = MIN_SCALE end
		applyScale(slime, primary, targetScale)

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

		-- Ensure persisted progress is initialized for newly created slimes so storage reflects current state.
		slime:SetAttribute("PersistedGrowthProgress", slime:GetAttribute("GrowthProgress") or 0)
		slime:SetAttribute("FactoryVisualReady", true)

		return slime
	end

	local function pick(...)
		for i = 1, select("#", ...) do
			local v = select(i, ...)
			if v ~= nil then return v end
		end
		return nil
	end

	function SlimeFactory.RestoreFromSnapshot(snapshot, player, plot)
		snapshot = snapshot or {}
		if type(snapshot) ~= "table" then
			return nil, "InvalidSnapshot"
		end

		local ownerId = pick(snapshot.OwnerUserId, snapshot.ow, snapshot.ownerUserId, snapshot.ownerId)
		if not ownerId and player then
			local ok, val = pcall(function()
				return player.UserId or (player.GetAttribute and player:GetAttribute("OwnerUserId"))
			end)
			if ok and val then ownerId = val end
		end

		local params = {
			OwnerUserId = ownerId,
			SlimeId = pick(snapshot.id, snapshot.SlimeId),
			Rarity = pick(snapshot.Rarity, snapshot.ra),
			MovementScalar = pick(snapshot.MovementScalar, snapshot.mv),
			WeightScalar = pick(snapshot.WeightScalar, snapshot.ws),
			WeightPounds = pick(snapshot.WeightPounds, snapshot.wt),
			MutationRarityBonus = pick(snapshot.MutationRarityBonus, snapshot.mb),
			Tier = pick(snapshot.Tier, snapshot.ti),
			MutationCount = pick(snapshot.MutationCount, snapshot.mc),
			MutationValueMult = pick(snapshot.MutationValueMult, snapshot.mm),
			MutationLastType = pick(snapshot.MutationLastType, snapshot.mt),
			MutationLastApplied = pick(snapshot.MutationLastApplied, snapshot.ma),
			MutationHasPhysical = pick(snapshot.MutationHasPhysical, snapshot.mp),
			MutationFoodStub = pick(snapshot.MutationFoodStub, snapshot.mf),
			MutationFoodStubCount = pick(snapshot.MutationFoodStubCount, snapshot.mfc),
			MutationSizeBoost = pick(snapshot.MutationSizeBoost, snapshot.mbs),
			MutationHistory = pick(snapshot.MutationHistory, snapshot.mh),
			ValueBase = pick(snapshot.ValueBase, snapshot.vb),
			ValuePerGrowth = pick(snapshot.ValuePerGrowth, snapshot.vg),
			GrowthProgress = pick(snapshot.GrowthProgress, snapshot.gp),
			FedFraction = pick(snapshot.FedFraction, snapshot.ff),
			CurrentFullness = pick(snapshot.CurrentFullness, snapshot.cf),
			LastHungerUpdate = pick(snapshot.LastHungerUpdate, snapshot.lu),
			HungerDecayRate = pick(snapshot.HungerDecayRate, snapshot.hd),
			CurrentSizeScale = pick(snapshot.CurrentSizeScale, snapshot.sz),
			StartSizeScale = pick(snapshot.StartSizeScale, snapshot.st),
			MaxSizeScale = pick(snapshot.MaxSizeScale, snapshot.mx),
			BodyColor = pick(snapshot.BodyColor, snapshot.bc),
			AccentColor = pick(snapshot.AccentColor, snapshot.ac),
			EyeColor = pick(snapshot.EyeColor, snapshot.ec),
			SlimeType = pick(snapshot.SlimeType, snapshot.slimeType, snapshot.Breed, snapshot.breed),
			Breed = pick(snapshot.Breed, snapshot.breed, snapshot.SlimeType, snapshot.slimeType),
		}

		local slime, err = SlimeFactory.BuildNew(params)
		if not slime then
			return nil, err or "BuildFailed"
		end

		local function setAttr(name, ...)
			local value = pick(...)
			if value ~= nil then
				slime:SetAttribute(name, value)
			end
		end

		local snapshotAttrMap = {
			{"GrowthProgress", "gp"},
			{"ValueFull", "vf"},
			{"CurrentValue", "cv"},
			{"ValueBase", "vb"},
			{"ValuePerGrowth", "vg"},
			{"MutationCount", "mc"},
			{"MutationValueMult", "mm"},
			{"MutationLastType", "mt"},
			{"MutationLastApplied", "ma"},
			{"MutationHasPhysical", "mp"},
			{"MutationFoodStub", "mf"},
			{"MutationFoodStubCount", "mfc"},
			{"MutationSizeBoost", "mbs"},
			{"MutationHistory", "mh"},
			{"Tier", "ti"},
			{"FedFraction", "ff"},
			{"CurrentSizeScale", "sz"},
			{"BodyColor", "bc"},
			{"AccentColor", "ac"},
			{"EyeColor", "ec"},
			{"MovementScalar", "mv"},
			{"WeightScalar", "ws"},
			{"MutationRarityBonus", "mb"},
			{"WeightPounds", "wt"},
			{"MaxSizeScale", "mx"},
			{"StartSizeScale", "st"},
			{"SizeLuckRolls", "lr"},
			{"FeedBufferSeconds", "fb"},
			{"FeedBufferMax", "fx"},
			{"HungerDecayRate", "hd"},
			{"CurrentFullness", "cf"},
			{"FeedSpeedMultiplier", "fs"},
			{"LastHungerUpdate", "lu"},
			{"LastGrowthUpdate", "lg"},
			{"OfflineGrowthApplied", "og"},
			{"AgeSeconds", "ag"},
			{"PersistedGrowthProgress", "pgf"},
		}
		for _, pair in ipairs(snapshotAttrMap) do
			local attr, short = pair[1], pair[2]
			setAttr(attr, snapshot[attr], snapshot[short])
		end

		setAttr("SlimeType", snapshot.SlimeType, snapshot.slimeType, snapshot.Breed, snapshot.breed)
		setAttr("Breed", snapshot.Breed, snapshot.breed, snapshot.SlimeType, snapshot.slimeType)

		setAttr("PersistedGrowthProgress", snapshot.PersistedGrowthProgress, snapshot.pgf, snapshot.GrowthProgress, snapshot.gp)

		slime:SetAttribute("ServerRestore", true)
		slime:SetAttribute("_RestoreInProgress", true)
		slime:SetAttribute("_FactoryRestoreBuilt", true)
		slime:SetAttribute("FactoryVisualReady", true)

		pcall(function() applyAppearanceFromAttributes(slime) end)

		local now = os.time()
		local graceSeconds = RESTORE_TIMER_GRACE_SECONDS
		if type(snapshot.RestoreGraceSeconds) == "number" and snapshot.RestoreGraceSeconds >= 0 then
			graceSeconds = snapshot.RestoreGraceSeconds
		end

		local storedHunger = slime:GetAttribute("LastHungerUpdate")
		if storedHunger then slime:SetAttribute("_RestoreOriginalLastHungerUpdate", storedHunger) end
		slime:SetAttribute("LastHungerUpdate", now)
		local cf = slime:GetAttribute("CurrentFullness")
		if cf ~= nil then slime:SetAttribute("FedFraction", cf) end

		local storedGrowth = slime:GetAttribute("LastGrowthUpdate")
		if storedGrowth then slime:SetAttribute("_RestoreOriginalLastGrowthUpdate", storedGrowth) end
		slime:SetAttribute("LastGrowthUpdate", now)

		slime:SetAttribute("_RestoreTimerGraceUntil", now + graceSeconds)
		slime:SetAttribute("RestoreTimerGraceSeconds", graceSeconds)
		slime:SetAttribute("RestoreTimerGraceAppliedAt", now)

		return slime
	end

	SlimeFactory.CreateFromSnapshot = SlimeFactory.RestoreFromSnapshot
	SlimeFactory.BuildFromSnapshot = SlimeFactory.RestoreFromSnapshot

	-- Replacement SlimeFactory.RestoreFromSnapshot (full implementation above in BuildNew block for clarity)
	-- Note: RestoreFromSnapshot implemented earlier in full above inside this block (function present).

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
		DEFER_OFFLINE_APPLY_ONE_HEARTBEAT = false,
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
	local refreshLegacyWelds = SlimeFactory._RefreshLegacyWelds

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

	local function restoreOriginalOfflineTimestamps(slime)
		local restored = false
		if not slime or not slime.Parent then return restored end
		local originalGrowth = slime:GetAttribute("_RestoreOriginalLastGrowthUpdate")
		if type(originalGrowth) == "number" then
			local prev = slime:GetAttribute("LastGrowthUpdate")
			slime:SetAttribute("LastGrowthUpdate", originalGrowth)
			slime:SetAttribute("_RestoreOriginalLastGrowthUpdate", nil)
			restored = true
			logOffline(slime, "restore_last_growth", {prev=prev, restored=originalGrowth})
		end
		local originalHunger = slime:GetAttribute("_RestoreOriginalLastHungerUpdate")
		if type(originalHunger) == "number" then
			local prev = slime:GetAttribute("LastHungerUpdate")
			slime:SetAttribute("LastHungerUpdate", originalHunger)
			slime:SetAttribute("_RestoreOriginalLastHungerUpdate", nil)
			logOffline(slime, "restore_last_hunger", {prev=prev, restored=originalHunger})
		end
		return restored
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

	-- Hunger multiplier: prefer SlimeCore.SlimeHungerService.GetHungerMultiplier if available,
	-- otherwise fall back to default fed fraction formula.
	local function hungerMultiplier(slime)
		if not (CONFIG.HungerGrowthEnabled) then return 1 end
		if isWithinRestoreGrace(slime) then return 1 end
		-- prefer the unified hunger service exposed on SlimeCore if present
		if SlimeCore and SlimeCore.SlimeHungerService and type(SlimeCore.SlimeHungerService.GetHungerMultiplier) == "function" then
			local ok, val = pcall(function() return SlimeCore.SlimeHungerService.GetHungerMultiplier(slime) end)
			if ok and type(val) == "number" then
				return val
			end
		end
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
		local primary = slime.PrimaryPart or slime:FindFirstChildWhichIsA("BasePart")
		local currentScale = slime:GetAttribute("CurrentSizeScale") or slime:GetAttribute("StartSizeScale") or 1
		if type(slime:GetAttribute("_LastAppliedSizeScale")) ~= "number" or slime:GetAttribute("_LastAppliedSizeScale") <= 0 then
			slime:SetAttribute("_LastAppliedSizeScale", currentScale)
		end
		if type(slime:GetAttribute("OriginalBaseScale")) ~= "number" or slime:GetAttribute("OriginalBaseScale") <= 0 then
			slime:SetAttribute("OriginalBaseScale", 1)
		end
		for _,p in ipairs(slime:GetDescendants()) do
			if typeof(p) == "Instance" and p:IsA("BasePart") then
				if not p:GetAttribute("OriginalSize") then
					local baseSize = p.Size
					if currentScale ~= 0 then
						baseSize = baseSize / currentScale
					end
					p:SetAttribute("OriginalSize", baseSize)
				end
				if primary and primary:IsA("BasePart") then
					local relCF = p:GetAttribute("OriginalRelCF")
					if typeof(relCF) ~= "CFrame" then
						if p == primary then
							relCF = CFrame.new()
						else
							local okDerive, derived = pcall(function() return primary.CFrame:ToObjectSpace(p.CFrame) end)
							if okDerive and derived then
								local basePos = derived.Position
								if currentScale ~= 0 then basePos = basePos / currentScale end
								local rx, ry, rz = derived:ToOrientation()
								relCF = CFrame.new(basePos) * CFrame.fromOrientation(rx, ry, rz)
							end
						end
						if typeof(relCF) == "CFrame" then
							p:SetAttribute("OriginalRelCF", relCF)
							p:SetAttribute("OriginalRelOffset", relCF.Position)
						end
					end
				end
			end
		end
		if SlimeFactory and type(SlimeFactory._EnsureOriginalBounds) == "function" then
			SlimeFactory._EnsureOriginalBounds(slime, primary)
		end
	end

	local function applyScale(slime, newScale)
		if not newScale or newScale <= 0 then return end
		local primary = slime.PrimaryPart or slime:FindFirstChildWhichIsA("BasePart")
		if SlimeFactory and type(SlimeFactory._EnsureOriginalBounds) == "function" then
			SlimeFactory._EnsureOriginalBounds(slime, primary)
		end
		local oldScale = slime:GetAttribute("_LastAppliedSizeScale")
		if type(oldScale) ~= "number" or oldScale <= 0 then
			oldScale = slime:GetAttribute("CurrentSizeScale") or slime:GetAttribute("StartSizeScale") or slime:GetAttribute("OriginalBaseScale") or 1
		end
		for _,p in ipairs(slime:GetDescendants()) do
			if typeof(p) == "Instance" and p:IsA("BasePart") then
				local orig = p:GetAttribute("OriginalSize")
				if not orig then
					orig = p.Size
					if oldScale ~= 0 then
						orig = orig / oldScale
					end
					p:SetAttribute("OriginalSize", orig)
				end
				local s = orig * newScale
				p.Size = Vector3.new(math.max(s.X, CONFIG.MIN_AXIS), math.max(s.Y, CONFIG.MIN_AXIS), math.max(s.Z, CONFIG.MIN_AXIS))
			end
		end
		if not primary or not primary:IsA("BasePart") then
			slime:SetAttribute("CurrentSizeScale", newScale)
			slime:SetAttribute("_LastAppliedSizeScale", newScale)
			return
		end

		local rootCF = primary.CFrame
		if SlimeFactory and type(SlimeFactory._AdjustModelHeightForScale) == "function" then
			local adjusted = SlimeFactory._AdjustModelHeightForScale(slime, primary, oldScale, newScale)
			if typeof(adjusted) == "CFrame" then
				rootCF = adjusted
				primary = slime.PrimaryPart or primary
			end
		end

			local anchorStates = {}
			for _,p in ipairs(slime:GetDescendants()) do
				if typeof(p) == "Instance" and p:IsA("BasePart") then
					anchorStates[p] = p.Anchored
					p.Anchored = true
					p.AssemblyLinearVelocity = Vector3.zero
					p.AssemblyAngularVelocity = Vector3.zero
				end
			end

			for _,p in ipairs(slime:GetDescendants()) do
			if typeof(p) == "Instance" and p:IsA("BasePart") and p ~= primary then
				local relCF = p:GetAttribute("OriginalRelCF")
				if typeof(relCF) ~= "CFrame" then
					local okDerive, derived = pcall(function() return primary.CFrame:ToObjectSpace(p.CFrame) end)
					if okDerive and derived then
						relCF = derived
						local currentScale = slime:GetAttribute("CurrentSizeScale") or slime:GetAttribute("StartSizeScale") or oldScale or 1
						if currentScale ~= 0 then
							local basePos = derived.Position / currentScale
							local rx, ry, rz = derived:ToOrientation()
							relCF = CFrame.new(basePos) * CFrame.fromOrientation(rx, ry, rz)
						else
							relCF = derived
						end
						p:SetAttribute("OriginalRelCF", relCF)
						p:SetAttribute("OriginalRelOffset", relCF.Position)
					end
				end
				if typeof(relCF) == "CFrame" then
					local offset = relCF.Position * newScale
					local rx, ry, rz = relCF:ToOrientation()
					local desired = rootCF * (CFrame.new(offset) * CFrame.fromOrientation(rx, ry, rz))
					pcall(function() p.CFrame = desired end)
				end
			end
		end

		if refreshLegacyWelds then
			refreshLegacyWelds(slime)
		end

				for part, wasAnchored in pairs(anchorStates) do
					pcall(function()
						part.Anchored = wasAnchored and true or false
					end)
				end

		slime:SetAttribute("CurrentSizeScale", newScale)
		slime:SetAttribute("_LastAppliedSizeScale", newScale)
	end

	-- Sync model attributes into the authoritative cached profile (player inventory) and push inventory update.
	-- This is lazy/defensive: it requires PlayerProfileService/InventoryService at call time (pcall),
	-- and marks the profile dirty and calls InventoryService.UpdateProfileInventory to update clients.
	local function syncModelGrowthIntoProfile(slime)
		if not slime or not slime.Parent then return end
		local owner = nil
		local sid = nil
		pcall(function()
			owner = slime:GetAttribute("OwnerUserId")
			sid = slime:GetAttribute("SlimeId")
		end)
		if not owner or not sid then return end

		-- require PlayerProfileService / InventoryService lazily (avoid module init cycles)
		local PlayerProfileService = nil
		local InventoryService = nil
		local ok, svc = pcall(function() return require(ModulesRoot:WaitForChild("PlayerProfileService")) end)
		if ok and svc then PlayerProfileService = svc end
		local ok2, inv = pcall(function() return require(ModulesRoot:WaitForChild("InventoryService")) end)
		if ok2 and inv then InventoryService = inv end

		-- must have PPS to update cached profile; otherwise bail
		if not PlayerProfileService or type(PlayerProfileService.GetProfile) ~= "function" then return end

		local profile = nil
		pcall(function() profile = PlayerProfileService.GetProfile(owner) end)
		if not profile then
			-- try a short WaitForProfile if available
			if PlayerProfileService and type(PlayerProfileService.WaitForProfile) == "function" then
				local okp, p = pcall(function() return PlayerProfileService.WaitForProfile(owner, 0.25) end)
				if okp then profile = p end
			end
		end
		if not profile or type(profile) ~= "table" then return end

		profile.inventory = profile.inventory or {}
		profile.inventory.worldSlimes = profile.inventory.worldSlimes or {}

		-- gather model attrs
		local gp = slime:GetAttribute("GrowthProgress")
		local pgp = slime:GetAttribute("PersistedGrowthProgress")
		local lgu = slime:GetAttribute("LastGrowthUpdate")
		local ts  = slime:GetAttribute("Timestamp") or lgu

		-- hunger attributes
		local cf = slime:GetAttribute("CurrentFullness")
		local ff = slime:GetAttribute("FedFraction")
		local lhu = slime:GetAttribute("LastHungerUpdate")
		local hdr = slime:GetAttribute("HungerDecayRate")

		local pos = nil
		local prim = slime.PrimaryPart or slime:FindFirstChildWhichIsA("BasePart")
		if prim then
			local okp, cf2 = pcall(function() return prim:GetPivot() end)
			if okp and cf2 then pos = { x = cf2.X, y = cf2.Y, z = cf2.Z } end
		end

		local updated = false
		for i,entry in ipairs(profile.inventory.worldSlimes) do
			if type(entry) == "table" then
				local id = entry.SlimeId or entry.id or entry.Id
				if id and tostring(id) == tostring(sid) then
					if gp ~= nil then entry.GrowthProgress = gp; updated = true end
					if pgp ~= nil then entry.PersistedGrowthProgress = pgp; updated = true end
					if lgu ~= nil then entry.LastGrowthUpdate = lgu; updated = true end
					if ts  ~= nil then entry.Timestamp = ts; updated = true end
					if pos then entry.Position = pos; updated = true end

					-- hunger
					if cf ~= nil then entry.CurrentFullness = cf; updated = true end
					if ff ~= nil then entry.FedFraction = ff; updated = true end
					if lhu ~= nil then entry.LastHungerUpdate = lhu; updated = true end
					if hdr ~= nil then entry.HungerDecayRate = hdr; updated = true end

					profile.inventory.worldSlimes[i] = entry
					break
				end
			end
		end

		if not updated then
			local newEntry = { id = sid, SlimeId = sid }
			if gp ~= nil then newEntry.GrowthProgress = gp end
			if pgp ~= nil then newEntry.PersistedGrowthProgress = pgp end
			if lgu ~= nil then newEntry.LastGrowthUpdate = lgu end
			if ts ~= nil then newEntry.Timestamp = ts end
			if pos then newEntry.Position = pos end
			-- hunger
			if cf ~= nil then newEntry.CurrentFullness = cf end
			if ff ~= nil then newEntry.FedFraction = ff end
			if lhu ~= nil then newEntry.LastHungerUpdate = lhu end
			if hdr ~= nil then newEntry.HungerDecayRate = hdr end

			table.insert(profile.inventory.worldSlimes, newEntry)
			updated = true
		end

		if updated then
			-- mark dirty and push inventory update (best-effort)
			pcall(function() if PlayerProfileService.MarkDirty then PlayerProfileService.MarkDirty(owner) end end)
			if InventoryService and type(InventoryService.UpdateProfileInventory) == "function" then
				local ply = Players:GetPlayerByUserId(owner)
				pcall(function() InventoryService.UpdateProfileInventory(ply) end)
			end
		end
	end

	local function computeOfflineDelta(slime)
		if not CONFIG.OFFLINE_GROWTH_ENABLED then
			logOffline(slime, "detect_delta_result", {delta=0, reason="disabled"})
			return 0
		end
		local now = os.time()
		if isWithinRestoreGrace(slime, now) then
			logOffline(slime, "detect_delta_result", {delta=0, reason="restore_grace"})
			return 0
		end
		restoreOriginalOfflineTimestamps(slime)
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
			-- keep inventory/UI in sync: attempt to copy authoritative model attributes to profile
			pcall(function() syncModelGrowthIntoProfile(slime) end)
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
		local sid = nil
		if slime and slime.GetAttribute then
			local ok, val = pcall(function() return slime:GetAttribute("SlimeId") end)
			if ok then sid = val end
		end

		if offlineDelta <= 0 then
			return 0
		end

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

		local bufferConsume = math.min(feedBuffer, offlineDelta)
		local normalTime    = offlineDelta - bufferConsume

		local hungerBufferMultiplier = hungerMultiplier(slime)
		local hungerNormalMultiplier = hungerBufferMultiplier
		local hungerProjection = nil
		local hungerDeltaUsed = nil
		local projectionNow = os.time()
		if SlimeCore and SlimeCore.SlimeHungerService and type(SlimeCore.SlimeHungerService.ProjectOfflineFullness) == "function" then
			local lastHunger = slime:GetAttribute("LastHungerUpdate")
			local hungerDelta = nil
			if lastHunger then
				hungerDelta = math.max(0, projectionNow - lastHunger)
			end
			if not hungerDelta or hungerDelta == 0 then
				hungerDelta = offlineDelta
			end
			local deltaForProjection = math.min(offlineDelta, hungerDelta or offlineDelta)
			if deltaForProjection > 0 then
				local okProj, proj = pcall(function()
					return SlimeCore.SlimeHungerService.ProjectOfflineFullness(slime, deltaForProjection, projectionNow)
				end)
				if okProj and proj then
					hungerProjection = proj
					hungerDeltaUsed = deltaForProjection
					local startFed = proj.startFullness or 1
					local minFed = proj.minFullness or 0
					local maxFed = proj.maxFullness or 1
					local rate = proj.effectiveRate or 0
					local decayBudget = proj.elapsed or deltaForProjection
					local currentFed = startFed
					local function fedToMultiplier(avgFed)
						local clamped = math.clamp(avgFed or currentFed or minFed, minFed, maxFed)
						local MIN_HUNGER_MULT = 0.40
						local MAX_HUNGER_MULT = 1.00
						return MIN_HUNGER_MULT + (MAX_HUNGER_MULT - MIN_HUNGER_MULT) * clamped
					end
					local function integrateSegment(duration)
						if duration <= 0 then return 0 end
						local originalBudget = decayBudget
						local decayWindow = math.min(duration, decayBudget)
						local integral = 0
						local decayUsed = 0
						if decayWindow > 0 and rate > 0 and currentFed > minFed then
							local timeToMin = (currentFed - minFed) / rate
							timeToMin = math.max(0, timeToMin)
							local active = math.min(decayWindow, timeToMin)
							if active > 0 then
								local fedAfter = currentFed - rate * active
								integral = integral + (currentFed + fedAfter) * 0.5 * active
								currentFed = fedAfter
								decayWindow = decayWindow - active
								decayUsed = decayUsed + active
							end
							if decayWindow > 0 then
								integral = integral + minFed * decayWindow
								currentFed = minFed
								decayUsed = decayUsed + decayWindow
							end
						elseif decayWindow > 0 then
							integral = integral + currentFed * decayWindow
							decayUsed = decayWindow
						end
						decayBudget = math.max(decayBudget - decayUsed, 0)
						local flatDuration = duration - math.min(duration, originalBudget)
						if flatDuration > 0 then
							integral = integral + currentFed * flatDuration
						end
						return integral
					end
					local bufferIntegral = integrateSegment(bufferConsume)
					local avgBufferFed = (bufferConsume > 0) and (bufferIntegral / bufferConsume) or currentFed
					hungerBufferMultiplier = fedToMultiplier(avgBufferFed)
					local normalIntegral = integrateSegment(normalTime)
					local avgNormalFed = (normalTime > 0) and (normalIntegral / normalTime) or currentFed
					hungerNormalMultiplier = fedToMultiplier(avgNormalFed)
				end
			end
		end

		local function segmentIncrement(seconds, speedMultiplier)
			if seconds <= 0 or progress >= 1 then
				return 0
			end
			local inc = (seconds * speedMultiplier) / unfedDuration
			local cap = 1 - progress
			if inc > cap then inc = cap end
			progress = progress + inc
			return inc
		end

		local inc1 = segmentIncrement(bufferConsume, feedMult * hungerBufferMultiplier)
		local inc2 = segmentIncrement(normalTime, hungerNormalMultiplier)
		local totalInc = inc1 + inc2

		if totalInc > 0 then
			slime:SetAttribute("GrowthProgress", progress)
			-- keep inventory/UI in sync for this immediate authoritative change
			pcall(function() syncModelGrowthIntoProfile(slime) end)
		end

		if bufferConsume > 0 then
			local newBuffer = math.max(0, feedBuffer - bufferConsume)
			slime:SetAttribute("FeedBufferSeconds", newBuffer)
		end

		slime:SetAttribute("AgeSeconds", (slime:GetAttribute("AgeSeconds") or 0) + offlineDelta)
		if CONFIG.OFFLINE_GROWTH_VERBOSE then
			slime:SetAttribute("OfflineGrowthApplied", (slime:GetAttribute("OfflineGrowthApplied") or 0) + offlineDelta)
		end

		if hungerProjection and SlimeCore and SlimeCore.SlimeHungerService and type(SlimeCore.SlimeHungerService.ApplyOfflineDecay) == "function" then
			pcall(function()
				SlimeCore.SlimeHungerService.ApplyOfflineDecay(slime, hungerDeltaUsed or hungerProjection.elapsed or offlineDelta, projectionNow)
			end)
		end

		-- Persist progress immediately to reduce race with PreExit saves.
		writePersistedProgress(slime)

		-- Recompute visual scale and stats to keep model and attributes in sync after offline growth.
		pcall(function()
			local startScale = slime:GetAttribute("StartSizeScale") or 1
			local maxScale = slime:GetAttribute("MaxSizeScale") or startScale
			maxScale = ensureWeightAlignedMax(slime, maxScale, CONFIG.RESIZE_EPSILON)
			if type(startScale) ~= "number" or startScale <= 0 then
				startScale = maxScale
				slime:SetAttribute("StartSizeScale", startScale)
			elseif type(maxScale) == "number" and maxScale > 0 and startScale > maxScale then
				startScale = math.max(maxScale * 0.5, MIN_SCALE)
				slime:SetAttribute("StartSizeScale", startScale)
			end
			local eased = (function(t) return t*t*(3 - 2*t) end)(progress)
			local targetScale = startScale + (maxScale - startScale) * eased
			local currentScale = slime:GetAttribute("CurrentSizeScale") or targetScale
			if math.abs(targetScale - currentScale) > (CONFIG.RESIZE_EPSILON or 1e-4) then
				applyScale(slime, targetScale)
				slime:SetAttribute("CurrentSizeScale", targetScale)
				local cache = SlimeCache and SlimeCache[slime]
				if cache then cache.lastScale = targetScale end
			end

			if SlimeMutation and type(SlimeMutation.RecomputeValueFull) == "function" then
				SlimeMutation.RecomputeValueFull(slime)
			end
		end)

		-- Persist metadata and debug info
		logOffline(slime, "apply_offline_after", {
			progress_after=progress,
			progress_inc=totalInc,
			inc_buffer=inc1,
			inc_normal=inc2,
			feedBuffer_after=slime:GetAttribute("FeedBufferSeconds"),
			reapply=isReapply,
			hunger_buffer_mult=hungerBufferMultiplier,
			hunger_normal_mult=hungerNormalMultiplier
		})

		return totalInc
	end

	local function initCacheIfNeeded(slime)
		local cache = SlimeCache[slime]
		if cache and cache.initialized then return cache end

		captureOriginalSizes(slime)

		local alignedScale = alignScaleAttributesFromWeight(slime)
		if alignedScale then
			applyScale(slime, alignedScale)
		end

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
			lastForceScale = slime:GetAttribute("ForceScaleRefresh"),
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
		if isWithinRestoreGrace(slime) then
			PendingOffline[slime] = true
			if CONFIG.OFFLINE_DEBUG then
				logOffline(slime, "defer_offline_grace", {grace=getRestoreGraceRemaining(slime)})
			end
			return
		end
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
		local progress = slime:GetAttribute("GrowthProgress")
		if progress == nil or type(progress) ~= "number" then return end
		local maxScale = slime:GetAttribute("MaxSizeScale")
		maxScale = ensureWeightAlignedMax(slime, maxScale, CONFIG.RESIZE_EPSILON)
		local startScale = slime:GetAttribute("StartSizeScale")
		if type(startScale) ~= "number" or startScale <= 0 then
			startScale = maxScale or 1
			if startScale <= 0 then startScale = 1 end
			slime:SetAttribute("StartSizeScale", startScale)
		end
		if type(maxScale) ~= "number" or maxScale <= 0 then
			maxScale = startScale
			slime:SetAttribute("MaxSizeScale", maxScale)
		end
		if startScale > maxScale then
			startScale = math.max(maxScale * 0.5, MIN_SCALE)
			slime:SetAttribute("StartSizeScale", startScale)
		end
		progress = math.clamp(progress, 0, 1)

		local cache = initCacheIfNeeded(slime)
		local nowEpoch = os.time()
		slime:SetAttribute("AgeSeconds", (slime:GetAttribute("AgeSeconds") or 0) + dt)
		if getRestoreGraceRemaining(slime, nowEpoch) > 0 then
			return
		end
		finalizeRestoreGraceIfExpired(slime, nowEpoch)

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
				-- keep inventory/UI in sync for in-session growth changes
				pcall(function() syncModelGrowthIntoProfile(slime) end)
			end
		end

		local eased = (function(t) return t*t*(3 - 2*t) end)(progress)
		local targetScale = startScale + (maxScale - startScale) * eased
		local currentScale = slime:GetAttribute("CurrentSizeScale") or targetScale
		local forceToken = slime:GetAttribute("ForceScaleRefresh")
		if forceToken ~= cache.lastForceScale then
			applyScale(slime, targetScale)
			slime:SetAttribute("CurrentSizeScale", targetScale)
			cache.lastScale = targetScale
			cache.lastForceScale = forceToken
		elseif math.abs(targetScale - currentScale) > CONFIG.RESIZE_EPSILON then
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

		if CONFIG.OFFLINE_GROWTH_ENABLED then
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

	-- Keep this method lightweight: explicitly write persisted progress + stamp dirty for pre-leave flow.
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
		local cf = slime:GetAttribute("CurrentFullness")
		if cf == nil then cf = HUNGER.MaxFullness end
		if isWithinRestoreGrace(slime, now) then
			return clamp(cf, HUNGER.MinFullness, HUNGER.MaxFullness)
		end
		local last = slime:GetAttribute("LastHungerUpdate")
		local rate = slime:GetAttribute("HungerDecayRate")
		if last == nil or rate == nil then
			return clamp(cf, HUNGER.MinFullness, HUNGER.MaxFullness)
		end
		local elapsed = now - last
		if elapsed <= 0 then
			return clamp(cf, HUNGER.MinFullness, HUNGER.MaxFullness)
		end
		local stage = (HUNGER.UseStageScaling and (slime:GetAttribute("MutationCount") or 0)) or 0
		local effectiveRate = rate * (1 + stage * (HUNGER.StageDecayMultiplier or 0))
		local f = cf - elapsed * effectiveRate
		return clamp(f, HUNGER.MinFullness, HUNGER.MaxFullness)
	end

	local function collapse(slime, now)
		if not slime.Parent then return end
		if isWithinRestoreGrace(slime, now) then
			local cf = slime:GetAttribute("CurrentFullness")
			local val = clamp(cf ~= nil and cf or HUNGER.MaxFullness, HUNGER.MinFullness, HUNGER.MaxFullness)
			slime:SetAttribute("FedFraction", val)
			return
		end
		finalizeRestoreGraceIfExpired(slime, now)
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

	local function projectOfflineFullness(slime, elapsedSeconds, now)
		if not slime or typeof(slime) ~= "Instance" then return nil end
		now = now or os.time()
		if elapsedSeconds == nil then
			local last = slime:GetAttribute("LastHungerUpdate")
			if last then
				elapsedSeconds = math.max(0, now - last)
			else
				elapsedSeconds = 0
			end
		else
			elapsedSeconds = math.max(0, elapsedSeconds)
		end

		local startFullness = slime:GetAttribute("CurrentFullness")
		if startFullness == nil then
			startFullness = slime:GetAttribute("FedFraction")
		end
		if startFullness == nil then
			startFullness = HUNGER.MaxFullness
		end
		startFullness = clamp(startFullness, HUNGER.MinFullness, HUNGER.MaxFullness)

		local rate = slime:GetAttribute("HungerDecayRate")
		if rate == nil then rate = HUNGER.BaseDecayFractionPerSecond end
		local stage = (HUNGER.UseStageScaling and (slime:GetAttribute("MutationCount") or 0)) or 0
		local effectiveRate = rate * (1 + stage * (HUNGER.StageDecayMultiplier or 0))
		if effectiveRate < 0 then effectiveRate = 0 end

		local minF = HUNGER.MinFullness
		local maxF = HUNGER.MaxFullness
		local timeToMin
		if effectiveRate > 0 then
			timeToMin = (startFullness - minF) / effectiveRate
		else
			timeToMin = math.huge
		end
		timeToMin = math.max(0, timeToMin or 0)

		local decayDuration = math.min(elapsedSeconds, timeToMin)
		local endFullness
		if effectiveRate > 0 then
			endFullness = startFullness - effectiveRate * decayDuration
		else
			endFullness = startFullness
		end
		if elapsedSeconds > timeToMin then
			endFullness = minF
		end
		endFullness = clamp(endFullness, minF, maxF)

		local integral
		if elapsedSeconds <= 0 then
			integral = startFullness * 0
		elseif effectiveRate <= 0 then
			integral = startFullness * elapsedSeconds
		else
			local activeDuration = math.min(elapsedSeconds, timeToMin)
			local fedAfterActive = startFullness
			if activeDuration > 0 then
				fedAfterActive = startFullness - effectiveRate * activeDuration
				integral = (startFullness + fedAfterActive) * 0.5 * activeDuration
			else
				integral = 0
			end
			if elapsedSeconds > timeToMin then
				integral = integral + (minF * (elapsedSeconds - timeToMin))
			end
		end

		local avgFullness = (elapsedSeconds > 0) and (integral / elapsedSeconds) or startFullness

		return {
			startFullness = startFullness,
			endFullness = endFullness,
			avgFullness = avgFullness,
			effectiveRate = effectiveRate,
			minFullness = minF,
			maxFullness = maxF,
			timeToMin = timeToMin,
			elapsed = elapsedSeconds,
			now = now,
			integral = integral,
		}
	end

	function SlimeHungerService.ProjectOfflineFullness(slime, elapsedSeconds, now)
		return projectOfflineFullness(slime, elapsedSeconds, now)
	end

	function SlimeHungerService.ApplyOfflineDecay(slime, elapsedSeconds, now)
		local projection = projectOfflineFullness(slime, elapsedSeconds, now)
		if not projection then return nil end
		local applyNow = projection.now or os.time()
		slime:SetAttribute("CurrentFullness", projection.endFullness)
		slime:SetAttribute("FedFraction", projection.endFullness)
		slime:SetAttribute("LastHungerUpdate", applyNow)
		return projection
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
		finalizeRestoreGraceIfExpired(slime, now)
		return true
	end

	function SlimeHungerService.GetCurrentFullness(slime)
		return computeCurrent(slime, os.time())
	end

	function SlimeHungerService.GetHungerMultiplier(slime)
		if isWithinRestoreGrace(slime) then return 1 end
		local fed = slime:GetAttribute("FedFraction")
		if fed == nil then return 1 end
		return 0.40 + (1.00 - 0.40) * fed
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

-- Public helper for feeding slimes from other modules
function SlimeCore.FeedSlime(slime, restoreFraction)
	return SlimeCore.SlimeHungerService.Feed(slime, restoreFraction)
end

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

	function GrowthPersistenceService.FlushPlayerSlimesAndSave(userId, timeoutSeconds)
		local player = Players_local:GetPlayerByUserId(userId)
		local slimes = iterSlimesOnce()

		if player then
			stampPlayerSlimes(player, slimes)
		else
			dprint("FlushPlayerSlimesAndSave: player not found, stamping by userId", userId)
			for _, slime in ipairs(slimes) do
				local owner = slime:GetAttribute(CONFIG.OwnerAttr)
				if owner and tostring(owner) == tostring(userId) then
					stampSlime(slime)
				end
			end
		end

		safeMarkDirty(player or userId, CONFIG.MarkDirtyReasonEvent)

		if Orchestrator then
			local orchestratorArg = player or userId

			if Orchestrator.SaveNowAndWait then
				local ok, result = pcall(function()
					if CONFIG.SaveEventSkipWorldFlag and type(CONFIG.SaveEventSkipWorldFlag) == "table" then
						return Orchestrator:SaveNowAndWait(orchestratorArg, timeoutSeconds or 6, CONFIG.SaveEventSkipWorldFlag)
					else
						return Orchestrator:SaveNowAndWait(orchestratorArg, timeoutSeconds or 6)
					end
				end)
				if not ok then
					dprint("FlushPlayerSlimesAndSave: SaveNowAndWait error", result)
					return false, "save_error"
				end

				if result == true then
					return true
				elseif result == false or result == nil then
					dprint("FlushPlayerSlimesAndSave: SaveNowAndWait returned falsy:", tostring(result))
					return false, "save_failed"
				else
					return true
				end

			elseif Orchestrator.SaveNow then
				safeSaveNow(orchestratorArg, CONFIG.SaveReasonEventFlush, CONFIG.SaveEventSkipWorldFlag)
				return true
			else
				dprint("FlushPlayerSlimesAndSave: Orchestrator has no SaveNow/SaveNowAndWait")
				return false, "orchestrator_no_save"
			end
		end

		dprint("FlushPlayerSlimesAndSave: no orchestrator available")
		return false, "no_orchestrator"
	end

	function GrowthPersistenceService.FlushPlayerSlimes(userId, timeoutSeconds)
		return GrowthPersistenceService.FlushPlayerSlimesAndSave(userId, timeoutSeconds)
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