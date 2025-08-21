local SlimeConfig = {}

SlimeConfig.AverageScaleBasic = 1.0 -- reference scale (expected mean)

SlimeConfig.Tiers = {
	Basic = {
		-- Base ranges for an average-sized slime (size_norm=1)
		UnfedGrowthDurationRange = {540, 900},    -- seconds (9–15 min)
		FedGrowthDurationRange   = {120, 480},    -- seconds (2–8 min)
		BaseMaxSizeRange         = {0.85, 1.10},  -- before jackpots
		StartScaleFractionRange  = {0.010, 0.020},
		FeedBufferPerItem        = 15,
		FeedBufferMax            = 120,
		AbsoluteMaxScaleCap      = 200,           -- hard safety clamp
		-- Size duration scaling
		DurationExponentAlpha    = 0.6,
		DurationBreakPoint       = 64,
		DurationLogK             = 0.35,
		-- Value scaling
		ValueBaseFull            = 150,
		ValueSizeExponent        = 1.15,
		MutationValuePerStage    = 0.08,
		RarityLuckPremiumPerLevel= 0.02,
		-- Mutation base (you can tweak later)
		BaseMutationChance       = 0.02,
		MutationChancePerStage   = 0.005,
		-- Jackpot cascade (rare size multipliers)
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
		-- Mutation visual rules (placeholder)
		MutationColorJitter = {
			H = 0.05,
			S = 0.07,
			V = 0.08,
		},
		-- Which part names are allowed to color-drift (lower-case match)
		MutablePartNamePatterns = {
			"inner","outer","ball","body","slime","core"
		},
	}
}

function SlimeConfig.GetTierConfig(tier)
	return SlimeConfig.Tiers[tier] or SlimeConfig.Tiers.Basic
end

return SlimeConfig