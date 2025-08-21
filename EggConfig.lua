local RNG = require(script.Parent:WaitForChild("RNG"))
local EggConfig = {}

-- Unified 1–2 minute hatch time (60–120s) for every rarity
-- If later you want longer hatch times for higher rarities, adjust per rarity here.
local UNIFIED_HATCH = {60, 120, mode = "center"}

EggConfig.Rarities = {
	Common = {
		weight = 60,
		hatchTime = UNIFIED_HATCH,
		baseSizeScale = {0.80, 1.05, mode = "center"},
		maxSizeScale = 1.6,
		growthBaseDuration = {120, 480},
		growthMaxExtra = {300, 300},
		startScaleFraction = {0.01, 0.015},
		latePhaseFraction = 0.10,
		valueBase = {15, 25},
		valuePerGrowth = {2, 4},
		weightScalar = {0.9, 1.1},
		movementScalar = {0.9, 1.1},
		mutationBonus = 0.0
	},
	Rare = {
		weight = 30,
		hatchTime = UNIFIED_HATCH,
		baseSizeScale = {0.90, 1.20, mode = "center"},
		maxSizeScale = 1.9,
		growthBaseDuration = {240, 600},
		growthMaxExtra = {360, 420},
		startScaleFraction = {0.01, 0.018},
		latePhaseFraction = 0.12,
		valueBase = {35, 55},
		valuePerGrowth = {4, 6},
		weightScalar = {0.95, 1.15},
		movementScalar = {1.0, 1.15},
		mutationBonus = 0.02
	},
	Epic = {
		weight = 9,
		hatchTime = UNIFIED_HATCH,
		baseSizeScale = {1.00, 1.30},
		maxSizeScale = 2.3,
		growthBaseDuration = {360, 840},
		growthMaxExtra = {480, 600},
		startScaleFraction = {0.012, 0.02},
		latePhaseFraction = 0.15,
		valueBase = {70, 95},
		valuePerGrowth = {6, 9},
		weightScalar = {1.0, 1.2},
		movementScalar = {1.05, 1.2},
		mutationBonus = 0.04
	},
	Legendary = {
		weight = 1,
		hatchTime = UNIFIED_HATCH,
		baseSizeScale = {1.15, 1.50, mode = "center"},
		maxSizeScale = 2.8,
		growthBaseDuration = {600, 1200},
		growthMaxExtra = {600, 900},
		startScaleFraction = {0.015, 0.025},
		latePhaseFraction = 0.18,
		valueBase = {120, 160},
		valuePerGrowth = {10, 14},
		weightScalar = {1.05, 1.25},
		movementScalar = {1.10, 1.25},
		mutationBonus = 0.08
	}
}

function EggConfig.RollRarity(rng)
	rng = rng or RNG.New()
	local weightTable = {}
	for name, data in pairs(EggConfig.Rarities) do
		table.insert(weightTable, {item = name, weight = data.weight})
	end
	return RNG.WeightedChoice(weightTable, rng)
end

local function rollRange(rangeDef, rng)
	local min, max = rangeDef[1], rangeDef[2]
	local mode = rangeDef.mode
	return RNG.RollRange(min, max, mode, rng)
end

local function rollFixedOrRange(field, rng)
	if typeof(field) == "table" then
		return RNG.RollRange(field[1], field[2], nil, rng)
	else
		return field
	end
end

function EggConfig.GenerateEggStats(rng, forcedRarity)
	rng = rng or RNG.New()
	local rarity = forcedRarity or EggConfig.RollRarity(rng)
	local def = EggConfig.Rarities[rarity] or EggConfig.Rarities.Common

	local stats = {
		Rarity = rarity,
		RarityWeight = def.weight,
		HatchTime = rollRange(def.hatchTime, rng),

		BaseSizeScale = rollRange(def.baseSizeScale, rng),
		MaxSizeScale = def.maxSizeScale,

		GrowthBaseDuration = rollRange(def.growthBaseDuration, rng),
		GrowthMaxExtra = rollRange(def.growthMaxExtra, rng),
		StartScaleFraction = rollFixedOrRange(def.startScaleFraction, rng),
		LatePhaseFraction = def.latePhaseFraction or 0.1,

		GrowthRate = 0,

		ValueBase = math.floor(rollRange(def.valueBase, rng)),
		ValuePerGrowth = math.floor(rollRange(def.valuePerGrowth, rng)),

		WeightScalar = RNG.Float(def.weightScalar[1], def.weightScalar[2], rng),
		MovementScalar = RNG.Float(def.movementScalar[1], def.movementScalar[2], rng),
		MutationRarityBonus = def.mutationBonus,
	}

	return stats
end

return EggConfig