-- SlimeHungerService (Revised)
-- Changes:
--   * Scans workspace:GetDescendants() so nested slimes under Player plots are found.
--   * Adds optional attribute HungerActive for debug.
--   * Minor defensive guards.

local RunService = game:GetService("RunService")

local HUNGER = {
	BaseDecayFractionPerSecond = 0.02 / 15,  -- 2% every 15s
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

local lastCollapse  = 0
local lastDiscovery = 0

local function dprint(...)
	if HUNGER.DEBUG then
		print("[SlimeHungerService]", ...)
	end
end

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
	-- Always keep FedFraction in sync for growth
	slime:SetAttribute("FedFraction", val)
end

local function initSlime(slime, now)
	if slime:GetAttribute("CurrentFullness") == nil then
		slime:SetAttribute("CurrentFullness", 1)
	end
	if slime:GetAttribute("LastHungerUpdate") == nil then
		slime:SetAttribute("LastHungerUpdate", now)
	end
	if slime:GetAttribute("HungerDecayRate") == nil then
		slime:SetAttribute("HungerDecayRate", HUNGER.BaseDecayFractionPerSecond)
	end
	if slime:GetAttribute("FedFraction") == nil then
		slime:SetAttribute("FedFraction", slime:GetAttribute("CurrentFullness"))
	end
	if HUNGER.MarkActiveAttribute then
		slime:SetAttribute("HungerActive", true)
	end
	dprint("Initialized hunger on", slime, "cf=", slime:GetAttribute("CurrentFullness"))
end

local function discover(now)
	for _,inst in ipairs(workspace:GetDescendants()) do
		if inst:IsA("Model") and inst.Name == "Slime" then
			if inst:GetAttribute("CurrentFullness") == nil then
				initSlime(inst, now)
			end
		end
	end
end

local SlimeHungerService = {}

function SlimeHungerService.Feed(slime, restoreFraction)
	if typeof(slime) ~= "Instance" or not slime:IsA("Model") or slime.Name ~= "Slime" then
		return false
	end
	if not slime.Parent then return false end
	local now = os.time()
	local current = computeCurrent(slime, now)
	if current == nil then
		initSlime(slime, now)
		current = 1
	end
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

RunService.Heartbeat:Connect(function()
	local now = os.time()
	if now - lastDiscovery >= HUNGER.DiscoveryInterval then
		lastDiscovery = now
		discover(now)
	end
	if now - lastCollapse >= HUNGER.CollapseInterval then
		lastCollapse = now
		for _,inst in ipairs(workspace:GetDescendants()) do
			if inst:IsA("Model") and inst.Name=="Slime" and inst:GetAttribute("CurrentFullness") ~= nil then
				collapse(inst, now)
			end
		end
	end
end)

return SlimeHungerService