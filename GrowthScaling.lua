local SlimeConfig = require(script.Parent:WaitForChild("SlimeConfig"))

local GrowthScaling = {}

-- Returns factor to multiply base durations by (larger size => longer).
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

return GrowthScaling