-- RNG.lua (Unified Random Utilities)
-- Replaces old RNG module. Backwards compatible for existing callers while adding:
--   * Streams (deterministic sub RNGs)
--   * Jackpot cascade helper
--   * Safer chance clamps
--   * Mutation roll helper with optional extra additive chance
--
-- Usage:
--   local RNG = require(Modules.RNG)
--   local r = RNG.New()                 -- Random.new with dynamic seed
--   local s = RNG.Stream(12345)         -- Deterministic stream object
--   local val = RNG.Float(0,1)          -- Global root stream
--   local pick = RNG.WeightedChoice({{item="A",weight=5},{item="B",weight=1}})
--
-- Stream object has same API subset: s:Float(a,b), s:Int(a,b), s:Bool(prob), etc.

local HttpService = game:GetService("HttpService")

local RNG = {}
local _root = Random.new()

----------------------------------------------------------------------
-- Global / Root management
----------------------------------------------------------------------
function RNG.SetGlobalSeed(seed)
	_root = Random.new(seed or 0)
end

local function _r(r) return r or _root end

function RNG.New(seed)
	if seed == nil then
		-- Derive a seed mixing root randomness + time
		seed = math.floor((_root:NextNumber() * 1e9) + (tick()*1000)) % 2^31
	end
	return Random.new(seed)
end

----------------------------------------------------------------------
-- Stream object wrapper
----------------------------------------------------------------------
local StreamMethods = {}
StreamMethods.__index = StreamMethods

function StreamMethods:Float(min, max) return self._r:NextNumber(min, max) end
function StreamMethods:Int(min, max) return self._r:NextInteger(min, max) end
function StreamMethods:Bool(prob)
	prob = math.clamp(prob or 0, 0, 1)
	return self._r:NextNumber() < prob
end
function StreamMethods:NextNumber(a,b) return self._r:NextNumber(a,b) end
function StreamMethods:NextInteger(a,b) return self._r:NextInteger(a,b) end
function StreamMethods:Gaussian(min, max, samples)
	samples = samples or 3
	local sum = 0
	for _=1,samples do sum += self._r:NextNumber() end
	local avg = sum / samples
	return min + (max - min) * avg
end
function StreamMethods:Clone()
	return setmetatable({ _r = RNG.New(self._r:NextInteger(0,2^31-1)) }, StreamMethods)
end
function StreamMethods:Raw() return self._r end

function RNG.Stream(seed)
	return setmetatable({ _r = RNG.New(seed) }, StreamMethods)
end

function RNG.Split(n, baseSeed)
	local streams = {}
	local base = RNG.New(baseSeed)
	for i=1,n do
		streams[i] = RNG.Stream(base:NextInteger(0, 2^31-1))
	end
	return streams
end

----------------------------------------------------------------------
-- Basic draws
----------------------------------------------------------------------
function RNG.Float(min, max, r) return _r(r):NextNumber(min, max) end
function RNG.Int(min, max, r) return _r(r):NextInteger(min, max) end

function RNG.Bool(prob, r)
	prob = math.clamp(prob or 0, 0, 1)
	return _r(r):NextNumber() < prob
end

----------------------------------------------------------------------
-- Weighted choice
-- Accepts array of {item=..., weight=number} or a dict { itemName = weight }
----------------------------------------------------------------------
function RNG.WeightedChoice(weights, r)
	r = _r(r)
	local total = 0
	local listMode = (#weights > 0)
	if listMode then
		for _,row in ipairs(weights) do total += row.weight end
		if total <= 0 then return nil end
		local roll = r:NextNumber() * total
		local acc = 0
		for _,row in ipairs(weights) do
			acc += row.weight
			if roll <= acc then return row.item end
		end
	else
		for _,wt in pairs(weights) do total += wt end
		if total <= 0 then return nil end
		local roll = r:NextNumber() * total
		local acc = 0
		for k,wt in pairs(weights) do
			acc += wt
			if roll <= acc then return k end
		end
	end
	return nil
end

----------------------------------------------------------------------
-- Gaussian / shaped ranges
----------------------------------------------------------------------
function RNG.Gaussian(min, max, samples, r)
	samples = samples or 3
	local sum = 0
	r = _r(r)
	for _=1,samples do sum += r:NextNumber() end
	local avg = sum / samples
	return min + (max - min) * avg
end

function RNG.RollRange(min, max, mode, r)
	local rand = _r(r)
	if mode == "gaussian" or mode == "center" then
		return RNG.Gaussian(min, max, 4, rand)
	elseif mode == "low" then
		local u = rand:NextNumber()
		u = u*u
		return min + (max - min) * u
	elseif mode == "high" then
		local u = rand:NextNumber()
		u = 1 - (1-u)*(1-u)
		return min + (max - min) * u
	else
		return rand:NextNumber(min, max)
	end
end

----------------------------------------------------------------------
-- Safe chance clamp
----------------------------------------------------------------------
function RNG.SafeChance(prob)
	return math.clamp(prob or 0, 0, 1)
end

----------------------------------------------------------------------
-- Mutation roll (defensive colon or dot)
-- dot-call:   RNG.RollMutation(baseChance, perStage, stage, extraAdd, r)
-- colon-call: RNG:RollMutation(stage, r)
----------------------------------------------------------------------
function RNG.RollMutation(a, b, c, d, e)
	if type(a) == "table" and a == RNG then
		-- colon misuse path: a=RNG, b=stage, c=r
		local stage = b or 0
		local r = c
		local baseChance = 0.02
		local perStage   = 0.005
		local prob = baseChance + perStage * stage
		return RNG.Bool(prob, r)
	end
	local baseChance = a or 0.02
	local perStage   = b or 0
	local stage      = c or 0
	local extraAdd   = d or 0
	local r          = e
	local prob = baseChance + perStage * stage + extraAdd
	return RNG.Bool(prob, r)
end

----------------------------------------------------------------------
-- Cascade jackpot (generic)
-- jackpotTable: array { { p = probability, mult = {min,max} }, ... }
-- Returns: finalMultiplier, levelsTriggered
----------------------------------------------------------------------
function RNG.CascadeJackpots(jackpotTable, rng, cap)
	rng = rng or _root
	local mult = 1
	local levels = 0
	for _,entry in ipairs(jackpotTable) do
		if rng:NextNumber() < entry.p then
			levels += 1
			local m = rng:NextNumber(entry.mult[1], entry.mult[2])
			mult *= m
			if cap and mult >= cap then
				mult = cap
				break
			end
		else
			break
		end
	end
	return mult, levels
end

----------------------------------------------------------------------
-- List pick
----------------------------------------------------------------------
function RNG.Pick(list, r)
	if #list == 0 then return nil end
	return list[RNG.Int(1, #list, r)]
end

----------------------------------------------------------------------
-- Color utilities
----------------------------------------------------------------------
function RNG.DriftColor(color, hRange, sRange, vRange, r)
	hRange = hRange or 0.04
	sRange = sRange or 0.05
	vRange = vRange or 0.05
	local rand = _r(r)
	local h,s,v = color:ToHSV()
	h = (h + rand:NextNumber(-hRange, hRange)) % 1
	s = math.clamp(s + rand:NextNumber(-sRange, sRange), 0, 1)
	v = math.clamp(v + rand:NextNumber(-vRange, vRange), 0, 1)
	return Color3.fromHSV(h,s,v)
end

function RNG.ColorToHex(c)
	return string.format("#%02X%02X%02X",
		math.floor(c.R*255+0.5),
		math.floor(c.G*255+0.5),
		math.floor(c.B*255+0.5))
end

----------------------------------------------------------------------
-- Serialization helpers (optional)
----------------------------------------------------------------------
function RNG.SerializeSeeded(seed)
	return HttpService:JSONEncode({seed=seed})
end

function RNG.DeserializeSeeded(json)
	local ok,data = pcall(HttpService.JSONDecode, HttpService, json)
	if ok and data and data.seed then
		return RNG.New(data.seed)
	end
	return RNG.New()
end

return RNG