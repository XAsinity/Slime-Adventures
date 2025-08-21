local RNG = require(script.Parent:WaitForChild("RNG"))
local SlimeAppearance = {}

-- Base palettes per rarity
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

-- Mutation palettes
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
	-- Mutation chance boosted by rarity stats (e.g., MutationRarityBonus)
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

return SlimeAppearance