-- SlimeMutation.lua (patched to accept either Stream or plain Random RNG)
-- Central mutation handling scaffold.

local HttpService = game:GetService("HttpService")

local SlimeConfig = require(script.Parent:WaitForChild("SlimeConfig"))
local RNG         = require(script.Parent:WaitForChild("RNG"))

local SlimeMutation = {}

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function getHistory(slime)
	local raw = slime:GetAttribute("MutationHistory")
	if not raw or raw == "" then
		return {}
	end
	local ok, data = pcall(HttpService.JSONDecode, HttpService, raw)
	if ok and type(data) == "table" then
		return data
	end
	return {}
end

local function setHistory(slime, tbl)
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, tbl)
	if ok then
		slime:SetAttribute("MutationHistory", encoded)
	end
end

local function lowercaseMatchAny(name, patterns)
	name = name:lower()
	for _,pat in ipairs(patterns) do
		if string.find(name, pat) then return true end
	end
	return false
end

-- Accept either our Stream wrapper or a plain Random or nil.
local function getRaw(rng)
	if not rng then
		return RNG.New()
	end
	-- Stream wrapper has :Raw()
	if type(rng) == "table" and rng.Raw then
		local ok, inner = pcall(function() return rng:Raw() end)
		if ok and inner then return inner end
	end
	-- Assume it's already a Random
	return rng
end

----------------------------------------------------------------------
-- Visual mutation placeholder
----------------------------------------------------------------------
function SlimeMutation.ApplyVisualStage(slime, stage, rng)
	local tier = slime:GetAttribute("Tier") or "Basic"
	local cfg = SlimeConfig.GetTierConfig(tier)
	rng = getRaw(rng)

	local mutable = {}
	for _,p in ipairs(slime:GetDescendants()) do
		if p:IsA("BasePart") and lowercaseMatchAny(p.Name, cfg.MutablePartNamePatterns) then
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

----------------------------------------------------------------------
-- Value recomputation
----------------------------------------------------------------------
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

----------------------------------------------------------------------
-- Public init
----------------------------------------------------------------------
function SlimeMutation.InitSlime(slime)
	if slime:GetAttribute("MutationStage") == nil then
		slime:SetAttribute("MutationStage", 0)
	end
	if slime:GetAttribute("MutationHistory") == nil then
		setHistory(slime, {})
	end
	if slime:GetAttribute("MutationValueMult") == nil then
		slime:SetAttribute("MutationValueMult", 1)
	end
end

----------------------------------------------------------------------
-- Attempt mutation
-- opts.extraChance additive probability
-- opts.force bypass chance
----------------------------------------------------------------------
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
	table.insert(hist, {
		stage = newStage,
		time = os.time(),
		type = "ColorDrift"
	})
	setHistory(slime, hist)

	SlimeMutation.RecomputeValueFull(slime)
	return true
end

return SlimeMutation