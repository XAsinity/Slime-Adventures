-- CoreStatsService.lua (v1.3)
-- Coins / standings with dirty signaling & leaderstats bridge.
-- Updates:
--  - Prefer attribute bridge as canonical sync of Coins -> PlayerProfileService to avoid duplicate SetCoins/SaveNow calls.
--  - CoreStatsService.SetCoins now sets attribute and leaderstats and only falls back to direct profile writes if the bridge is not installed.
--  - All PlayerProfileService calls wrapped in pcall for safety.
-----------------------------------------------------------------------

local CoreStatsService = {
	Name = "CoreStatsService",
	Priority = 50,
	RequiresSubtree = "core",
}

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local PlayerProfileService = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("PlayerProfileService"))

local CONFIG = {
	StartingCoins      = 500,
	StandingsClampMin  = 0.0,
	StandingsClampMax  = 1.0,
	Debug              = true,
}

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
	-- No orchestrator needed, use PlayerProfileService
	dprint("Init complete (PlayerProfileService integration)")
end

function CoreStatsService:OnProfileLoaded(player, profile)
	-- ensure profile shape
	if type(profile) == "table" then
		ensureSubtree(profile)
	end
end

local function ensureLeaderstats(player)
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
	return ls, coins
end

local function installCoinsAttributeBridge(player)
	-- Install a bridge that listens for the player's "CoinsStored" attribute changes and writes
	-- the authoritative value into PlayerProfileService (coalesced via SaveNow).
	-- Avoid installing multiple listeners by marking the player with an attribute.
	if not player or not player:IsDescendantOf(Players) then return end
	local marker = player:GetAttribute("__CoreCoinsBridgeInstalled")
	if marker then return end
	-- mark installed early so racing callers know the bridge exists
	pcall(function() player:SetAttribute("__CoreCoinsBridgeInstalled", true) end)

	-- Listen for attribute changes
	local conn
	conn = player:GetAttributeChangedSignal("CoinsStored"):Connect(function()
		if not player or not player:IsDescendantOf(Players) then
			if conn and conn.Connected then pcall(function() conn:Disconnect() end) end
			return
		end
		local newV = player:GetAttribute("CoinsStored")
		if type(newV) ~= "number" then return end

		-- Update PlayerProfileService authoritative value (SetCoins marks dirty and SaveNow is coalesced).
		pcall(function()
			-- SetCoins updates in-memory profile and marks it dirty
			PlayerProfileService.SetCoins(player, math.floor(newV))
			-- Request an async save (coalesced). SaveNow is debounced inside PlayerProfileService.
			PlayerProfileService.SaveNow(player, "CoreStats_CoinsAttrSync")
		end)

		-- Also update leaderstats IntValue for immediate UI reflection
		local ls = player:FindFirstChild("leaderstats")
		if ls then
			local coinsVal = ls:FindFirstChild("Coins")
			if coinsVal and coinsVal.Value ~= newV then
				coinsVal.Value = newV
			end
		end
	end)
end

function CoreStatsService:RestoreToPlayer(player, profile)
	-- Populate leaderstats from profile and ensure the attribute bridge is installed.
	if profile and type(profile) == "table" then
		ensureSubtree(profile)
	end

	local c = (profile and profile.core) or {}
	local ls, coinsVal = ensureLeaderstats(player)

	-- Use authoritative value from PlayerProfileService when possible
	local coinValue = nil
	if profile and type(profile) == "table" and profile.core and type(profile.core.coins) == "number" then
		coinValue = profile.core.coins
	else
		-- fallback: ask PlayerProfileService.GetCoins (best-effort)
		local ok, v = pcall(function() return PlayerProfileService.GetCoins(player) end)
		if ok and type(v) == "number" then coinValue = v end
	end
	coinValue = coinValue or (c.coins or CONFIG.StartingCoins or 0)

	-- Apply to leaderstats value and attribute
	if coinsVal then
		coinsVal.Value = coinValue
	end
	pcall(function() player:SetAttribute("CoinsStored", coinValue) end)

	-- Install attribute bridge once per player
	installCoinsAttributeBridge(player)

	-- Expose other core attributes
	pcall(function() player:SetAttribute("WipeGeneration", (c.wipeGen or 1)) end)
	if profile and profile.core and profile.core.standings then
		for f,val in pairs(profile.core.standings) do
			pcall(function() player:SetAttribute("Standing_"..f, val) end)
		end
	end
end

function CoreStatsService:Serialize(player, profile)
	ensureSubtree(profile)
	-- coins kept current by the attribute bridge which syncs to PlayerProfileService
end

--------------------------------------------------------
-- Public
--------------------------------------------------------
function CoreStatsService.RegisterFaction(name, initialStanding)
	if type(name)~="string" or name=="" then return end
	if registeredFactions[name] then return end
	registeredFactions[name] = type(initialStanding)=="number" and initialStanding or 0
	dprint("Registered faction", name, registeredFactions[name])
end

function CoreStatsService.SetStanding(player, faction, value)
	if not player or not player.UserId then return end
	local prof = nil
	pcall(function() prof = PlayerProfileService.GetProfile(player.UserId) end)
	if not prof then
		-- Try to ensure we have a profile first (non-blocking)
		prof = (type(PlayerProfileService.WaitForProfile) == "function") and PlayerProfileService.WaitForProfile(player, 1) or prof
		if not prof then return end
	end
	ensureSubtree(prof)
	if not registeredFactions[faction] then
		CoreStatsService.RegisterFaction(faction, value or 0)
	end
	local clampVal = math.clamp(value or 0, CONFIG.StandingsClampMin, CONFIG.StandingsClampMax)
	prof.core.standings[faction] = clampVal
	-- reflect on player
	pcall(function() player:SetAttribute("Standing_"..faction, clampVal) end)
	-- persist (async, coalesced)
	pcall(function() PlayerProfileService.SaveNow(player, "StandingChange") end)
end

function CoreStatsService.GetStanding(player, faction)
	local prof = nil
	pcall(function() prof = PlayerProfileService.GetProfile(player) end)
	if not prof then return registeredFactions[faction] or 0 end
	ensureSubtree(prof)
	local v = prof.core.standings[faction]
	if type(v)~="number" then
		v = registeredFactions[faction] or 0
		prof.core.standings[faction]=v
		pcall(function() PlayerProfileService.SaveNow(player, "StandingInit") end)
	end
	return v
end

function CoreStatsService.GetCoins(player)
	local ok, v = pcall(function() return PlayerProfileService.GetCoins(player) end)
	if ok and type(v) == "number" then return v end
	-- fallback to profile direct read (best-effort)
	local prof = nil
	pcall(function() prof = PlayerProfileService.GetProfile(player) end)
	return (prof and prof.core and prof.core.coins) or 0
end

function CoreStatsService.SetCoins(player, amount)
	-- New behavior:
	--  - Ensure attribute bridge is installed.
	--  - Update leaderstats immediately, then set CoinsStored attribute.
	--  - If the bridge was not previously installed (startup race), do a direct SetCoins + SaveNow fallback.
	if not player or not player.UserId then return end
	amount = math.floor(amount or 0)

	-- Ensure leaderstats exists and update for immediate UI
	local ls = player:FindFirstChild("leaderstats")
	if not ls then
		ls = Instance.new("Folder")
		ls.Name = "leaderstats"
		ls.Parent = player
	end
	local c = ls:FindFirstChild("Coins")
	if not c then
		c = Instance.new("IntValue")
		c.Name = "Coins"
		c.Parent = ls
	end
	if c.Value ~= amount then
		c.Value = amount
	end

	-- Check whether bridge was installed prior to our call
	local bridgeInstalled = false
	pcall(function() bridgeInstalled = player:GetAttribute("__CoreCoinsBridgeInstalled") and true or false end)

	-- Ensure bridge is installed (will set marker)
	installCoinsAttributeBridge(player)

	-- Set attribute (the bridge will call PlayerProfileService.SetCoins + SaveNow)
	pcall(function() player:SetAttribute("CoinsStored", amount) end)

	-- If the bridge was not installed before this call, do a direct write/fallback so the profile is updated immediately.
	if not bridgeInstalled then
		-- Direct authoritative update as fallback (wrapped in pcall)
		pcall(function()
			PlayerProfileService.SetCoins(player, amount)
			PlayerProfileService.SaveNow(player, "CoinsSet_Fallback")
		end)
	end
end

function CoreStatsService.AdjustCoins(player, delta)
	local current = CoreStatsService.GetCoins(player) or 0
	CoreStatsService.SetCoins(player, current + (delta or 0))
end

return CoreStatsService