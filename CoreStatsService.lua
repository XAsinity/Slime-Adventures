-- CoreStatsService.lua (v1.1)
-- Coins / standings with dirty signaling & leaderstats bridge.

local CoreStatsService = {
	Name = "CoreStatsService",
	Priority = 50,
	RequiresSubtree = "core",
}

local Players = game:GetService("Players")

local CONFIG = {
	StartingCoins      = 500,
	StandingsClampMin  = 0.0,
	StandingsClampMax  = 1.0,
	Debug              = true,
}

local Orchestrator
local registeredFactions = {}

local function dprint(...) if CONFIG.Debug then print("[CoreStats]", ...) end end

local function ensureSubtree(profile)
	profile.core = profile.core or {}
	local c = profile.core
	c.coins     = (type(c.coins)=="number") and c.coins or CONFIG.StartingCoins
	c.standings = c.standings or {}
	c.wipeGen   = c.wipeGen or 1
	for f,init in pairs(registeredFactions) do
		if type(c.standings[f]) ~= "number" then
			c.standings[f] = init
		end
	end
end

function CoreStatsService:Init(orch)
	Orchestrator = orch
	dprint("Init complete")
end

function CoreStatsService:OnProfileLoaded(player, profile)
	ensureSubtree(profile)
end

function CoreStatsService:RestoreToPlayer(player, profile)
	ensureSubtree(profile)
	local c = profile.core
	local ls = player:FindFirstChild("leaderstats")
	if not ls then
		ls = Instance.new("Folder")
		ls.Name = "leaderstats"
		ls.Parent = player
	end
	local coins = ls:FindFirstChild("Coins")
	if not coins then
		coins = Instance.new("IntValue")
		coins.Name = "Coins"
		coins.Parent = ls
	end
	coins.Value = c.coins

	if not coins:GetAttribute("__CoreBridge") then
		coins:SetAttribute("__CoreBridge", true)
		coins.Changed:Connect(function()
			if not profile.core then return end
			local newV = coins.Value
			if profile.core.coins ~= newV then
				profile.core.coins = newV
				player:SetAttribute("CoinsStored", newV)
				Orchestrator.MarkDirty(player, "CoinsChanged")
			end
		end)
	end

	player:SetAttribute("CoinsStored", c.coins)
	player:SetAttribute("WipeGeneration", c.wipeGen or 1)
	for f,val in pairs(c.standings) do
		player:SetAttribute("Standing_"..f, val)
	end
end

function CoreStatsService:Serialize(player, profile)
	ensureSubtree(profile)
	-- coins kept current by leaderstats listener
end

--------------------------------------------------------
-- Public
--------------------------------------------------------
function CoreStatsService.RegisterFaction(name, initialStanding)
	if type(name)~="string" or name=="" then return end
	if registeredFactions[name] then return end
	registeredFactions[name] = typeof(initialStanding)=="number" and initialStanding or 0
	dprint("Registered faction", name, registeredFactions[name])
end

function CoreStatsService.SetStanding(player, faction, value)
	local prof = Orchestrator.GetProfile(player)
	if not prof then return end
	ensureSubtree(prof)
	local c = prof.core
	if not registeredFactions[faction] then
		CoreStatsService.RegisterFaction(faction, value or 0)
	end
	local clampVal = math.clamp(value or 0, CONFIG.StandingsClampMin, CONFIG.StandingsClampMax)
	c.standings[faction] = clampVal
	player:SetAttribute("Standing_"..faction, clampVal)
	Orchestrator.MarkDirty(player, "StandingChange")
end

function CoreStatsService.GetStanding(player, faction)
	local prof = Orchestrator.GetProfile(player)
	if not prof then return registeredFactions[faction] or 0 end
	ensureSubtree(prof)
	local v = prof.core.standings[faction]
	if type(v)~="number" then
		v = registeredFactions[faction] or 0
		prof.core.standings[faction]=v
		Orchestrator.MarkDirty(player, "StandingInit")
	end
	return v
end

function CoreStatsService.GetCoins(player)
	local prof = Orchestrator.GetProfile(player)
	return (prof and prof.core and prof.core.coins) or 0
end

function CoreStatsService.SetCoins(player, amount)
	local prof = Orchestrator.GetProfile(player)
	if not prof then return end
	ensureSubtree(prof)
	amount = math.floor(amount)
	if prof.core.coins ~= amount then
		prof.core.coins = amount
		player:SetAttribute("CoinsStored", amount)
		Orchestrator.MarkDirty(player, "CoinsSet")
		local ls=player:FindFirstChild("leaderstats")
		local c=ls and ls:FindFirstChild("Coins")
		if c and c.Value~=amount then c.Value=amount end
	end
end

function CoreStatsService.AdjustCoins(player, delta)
	CoreStatsService.SetCoins(player, CoreStatsService.GetCoins(player)+delta)
end

return CoreStatsService