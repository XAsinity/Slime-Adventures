local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Simple, robust require helper:
-- Try to require ModuleScript named `moduleName` from a set of parent containers.
-- If not found, try to require SlimeCore from the same parents and return SlimeCore[slimeCoreField] (or SlimeCore[moduleName]).
local function tryRequire(moduleName, slimeCoreField)
	local parents = {
		script.Parent,
		-- prefer ServerScriptService.Modules if present
		(ServerScriptService:FindFirstChild("Modules") or nil),
		ServerScriptService,
		ReplicatedStorage,
	}

	-- Try each parent for the named module
	for _, parent in ipairs(parents) do
		if parent then
			local inst = parent:FindFirstChild(moduleName)
			if inst and inst:IsA("ModuleScript") then
				local ok, mod = pcall(require, inst)
				if ok and mod ~= nil then
					return mod
				end
			end
		end
	end

	-- Try SlimeCore in the same parents and return requested field
	for _, parent in ipairs(parents) do
		if parent then
			local scInst = parent:FindFirstChild("SlimeCore")
			if scInst and scInst:IsA("ModuleScript") then
				local okSc, sc = pcall(require, scInst)
				if okSc and type(sc) == "table" then
					if slimeCoreField and sc[slimeCoreField] then
						return sc[slimeCoreField]
					end
					if slimeCoreField == nil and sc[moduleName] then
						return sc[moduleName]
					end
				end
			end
		end
	end

	return nil
end

-- Acquire SlimeConfig and RNG (standalone preferred, else from SlimeCore)
local SlimeConfig = tryRequire("SlimeConfig", "SlimeConfig")
local RNG = tryRequire("RNG", "RNG")

-- Defensive local requires (if placed next to typical Modules folder)
if not SlimeConfig and script.Parent then
	local inst = script.Parent:FindFirstChild("SlimeConfig")
	if inst and inst:IsA("ModuleScript") then
		pcall(function() SlimeConfig = require(inst) end)
	end
end
if not RNG and script.Parent then
	local inst = script.Parent:FindFirstChild("RNG")
	if inst and inst:IsA("ModuleScript") then
		pcall(function() RNG = require(inst) end)
	end
end

-- Final fallback stubs so SizeRNG doesn't crash if everything missing.
if not RNG then
	RNG = {}
	function RNG.New() return Random.new() end
	function RNG.CascadeJackpots(jt, r, cap) return 1, 0 end
end
if not SlimeConfig then
	SlimeConfig = {
		GetTierConfig = function(_) return {
			BaseMaxSizeRange = {0.85, 1.10},
			StartScaleFractionRange = {0.010, 0.020},
			AbsoluteMaxScaleCap = 200,
			SizeJackpot = {},
			} end
	}
end

local SizeRNG = {}

local function isFiniteNumber(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- Safe accessor for tier config with sensible defaults matching SlimeCore expectations.
local function getTierConfigSafe(tier)
	local cfg = nil
	if SlimeConfig then
		if type(SlimeConfig.GetTierConfig) == "function" then
			pcall(function() cfg = SlimeConfig.GetTierConfig(tier) end)
		elseif type(SlimeConfig.GetConfig) == "function" then
			pcall(function() cfg = SlimeConfig.GetConfig(tier) end)
		end
	end
	cfg = cfg or {}
	cfg.BaseMaxSizeRange = cfg.BaseMaxSizeRange or {0.85, 1.10}
	cfg.StartScaleFractionRange = cfg.StartScaleFractionRange or {0.010, 0.020}
	cfg.AbsoluteMaxScaleCap = cfg.AbsoluteMaxScaleCap or 200
	cfg.SizeJackpot = cfg.SizeJackpot or {}
	return cfg
end

-- GenerateMaxSize:
-- Returns: finalMaxSize (number), jackpotLevels (number)
-- Robust against malformed config, RNG implementations, division by zero, and INF / NaN results.
function SizeRNG.GenerateMaxSize(tier, rng)
	local cfg = getTierConfigSafe(tier)

	-- Obtain rng stream: prefer provided, else RNG.New() if available, else Random.new()
	if not rng then
		if RNG and type(RNG.New) == "function" then
			pcall(function() rng = RNG.New() end)
		else
			rng = Random.new()
		end
	end

	-- Determine numeric low/high for base
	local lo = tonumber(cfg.BaseMaxSizeRange[1]) or 0.85
	local hi = tonumber(cfg.BaseMaxSizeRange[2]) or 1.10
	if lo > hi then lo, hi = hi, lo end

	-- Draw base using available RNG API
	local base = nil
	if rng and type(rng.NextNumber) == "function" then
		local ok, val = pcall(function() return rng:NextNumber(lo, hi) end)
		if ok and isFiniteNumber(val) then base = val end
	end
	if base == nil and rng and type(rng.Float) == "function" then
		local ok, val = pcall(function() return rng:Float(lo, hi) end)
		if ok and isFiniteNumber(val) then base = val end
	end
	if base == nil then
		base = lo + (math.random() * (hi - lo))
	end

	if not isFiniteNumber(base) or base <= 0 then
		base = math.max(0.0001, lo)
	end

	-- Compute a safe ratio to pass to jackpot routine (avoid division by zero)
	local safeRatio = nil
	if isFiniteNumber(cfg.AbsoluteMaxScaleCap) and cfg.AbsoluteMaxScaleCap > 0 then
		safeRatio = cfg.AbsoluteMaxScaleCap / math.max(base, 1e-6)
	end

	-- Default jackpot results
	local jackpotMultiplier = 1
	local levels = 0

	-- Call RNG.CascadeJackpots if present, but guard against errors and invalid returns
	if RNG and type(RNG.CascadeJackpots) == "function" then
		local ok, m, lv = pcall(function()
			return RNG.CascadeJackpots(cfg.SizeJackpot, rng, safeRatio)
		end)
		if ok and isFiniteNumber(m) and m > 0 then
			jackpotMultiplier = m
			levels = tonumber(lv) or 0
		else
			jackpotMultiplier = 1
			levels = 0
		end
	end

	-- Compute final and clamp to absolute cap; guard against INF/NaN
	local final = base * jackpotMultiplier
	if not isFiniteNumber(final) then
		final = cfg.AbsoluteMaxScaleCap
	end
	if isFiniteNumber(cfg.AbsoluteMaxScaleCap) then
		if final > cfg.AbsoluteMaxScaleCap then final = cfg.AbsoluteMaxScaleCap end
		if final <= 0 then final = math.max(0.0001, lo) end
	end

	return final, levels
end

function SizeRNG.GenerateStartFraction(tier, rng)
	local cfg = getTierConfigSafe(tier)

	-- Obtain rng stream
	if not rng then
		if RNG and type(RNG.New) == "function" then
			pcall(function() rng = RNG.New() end)
		else
			rng = Random.new()
		end
	end

	local lo = tonumber(cfg.StartScaleFractionRange[1]) or 0.010
	local hi = tonumber(cfg.StartScaleFractionRange[2]) or 0.020
	if lo > hi then lo, hi = hi, lo end

	local frac = nil
	if rng and type(rng.NextNumber) == "function" then
		local ok, val = pcall(function() return rng:NextNumber(lo, hi) end)
		if ok and isFiniteNumber(val) then frac = val end
	end
	if frac == nil and rng and type(rng.Float) == "function" then
		local ok, val = pcall(function() return rng:Float(lo, hi) end)
		if ok and isFiniteNumber(val) then frac = val end
	end
	if frac == nil then
		frac = lo + (math.random() * (hi - lo))
	end

	-- clamp and validate
	if not isFiniteNumber(frac) or frac <= 0 then
		frac = lo
	end
	if frac < lo then frac = lo end
	if frac > hi then frac = hi end

	return frac
end

return SizeRNG