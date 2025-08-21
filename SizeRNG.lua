local SlimeConfig = require(script.Parent:WaitForChild("SlimeConfig"))
local RNG = require(script.Parent:WaitForChild("RNG"))

local SizeRNG = {}

function SizeRNG.GenerateMaxSize(tier, rng)
	local cfg = SlimeConfig.GetTierConfig(tier)
	rng = rng or RNG.New()
	local base = rng:NextNumber(cfg.BaseMaxSizeRange[1], cfg.BaseMaxSizeRange[2])
	-- Cascade jackpot multipliers
	local jackpotMultiplier, levels = RNG.CascadeJackpots(cfg.SizeJackpot, rng, cfg.AbsoluteMaxScaleCap / base)
	local final = base * jackpotMultiplier
	if final > cfg.AbsoluteMaxScaleCap then
		final = cfg.AbsoluteMaxScaleCap
	end
	return final, levels
end

function SizeRNG.GenerateStartFraction(tier, rng)
	local cfg = SlimeConfig.GetTierConfig(tier)
	rng = rng or RNG.New()
	return rng:NextNumber(cfg.StartScaleFractionRange[1], cfg.StartScaleFractionRange[2])
end

return SizeRNG