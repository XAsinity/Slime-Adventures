-- FactionTotalsService
-- Now routes all per-player coin payouts through PlayerProfileService for up-to-date persistence

local DataStoreService  = game:GetService("DataStoreService")
local MessagingService  = game:GetService("MessagingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local PlayerProfileService = require(ServerScriptService.Modules:WaitForChild("PlayerProfileService"))

local REMOTES_FOLDER = ReplicatedStorage:WaitForChild("Remotes")
local UPDATE_EVENT   = REMOTES_FOLDER:WaitForChild("FactionTotalsUpdate")
local REQUEST_FUNC   = REMOTES_FOLDER:WaitForChild("RequestFactionTotals")

----------------------------------------------------------------
-- Configuration
----------------------------------------------------------------
local CONFIG = {
	DataStoreName         = "FactionTotalsV1",
	KeyPrefix             = "FactionTotal_",
	Factions              = { "Pacifist", "Orion" },
	FlushIntervalSeconds  = 15,
	MaxUnflushedDelta     = 5_000,
	MaxWriteRetries       = 5,
	RetryBackoffBase      = 0.5,
	MessagingTopic        = "FactionTotalsUpdateV1",
	Debug                 = false,
}

----------------------------------------------------------------
-- Internal State
----------------------------------------------------------------
local store             = DataStoreService:GetDataStore(CONFIG.DataStoreName)
local totals            = {}
local dirtyDeltas       = {}
local lastFlushAttempt  = 0
local initialized       = false

----------------------------------------------------------------
-- Utility
----------------------------------------------------------------
local function dprint(...)
	if CONFIG.Debug then
		print("[FactionTotalsService]", ...)
	end
end

local function keyFor(faction)
	return CONFIG.KeyPrefix .. faction
end

local function validateFaction(faction)
	for _,f in ipairs(CONFIG.Factions) do
		if f == faction then return true end
	end
	return false
end

----------------------------------------------------------------
-- DataStore IO
----------------------------------------------------------------
local function loadFaction(faction)
	if totals[faction] ~= nil then
		return totals[faction]
	end
	local key = keyFor(faction)
	local ok, val = pcall(function()
		return store:GetAsync(key)
	end)
	if ok and type(val) == "number" then
		totals[faction] = val
	else
		totals[faction] = 0
	end
	dprint("Loaded", faction, "total =", totals[faction])
	return totals[faction]
end

local function flushFaction(faction)
	local delta = dirtyDeltas[faction]
	if not delta or delta == 0 then
		return true
	end
	local key = keyFor(faction)

	local retries = 0
	while retries < CONFIG.MaxWriteRetries do
		local ok, err = pcall(function()
			store:UpdateAsync(key, function(old)
				local base = (type(old) == "number") and old or 0
				local newTotal = base + delta
				return newTotal
			end)
		end)
		if ok then
			local _, finalRead = pcall(function() return store:GetAsync(key) end)
			if type(finalRead) == "number" then
				totals[faction] = finalRead
			else
				totals[faction] = (totals[faction] or 0) + delta
			end
			dprint("Flushed", faction, "delta", delta, "-> total", totals[faction])
			dirtyDeltas[faction] = 0
			return true
		else
			retries += 1
			warn(("[FactionTotalsService] Flush failed for %s (attempt %d): %s"):format(faction, retries, err))
			task.wait(CONFIG.RetryBackoffBase * 2^(retries-1))
		end
	end
	return false
end

local function flushAll(force)
	for _,faction in ipairs(CONFIG.Factions) do
		if force or (dirtyDeltas[faction] and dirtyDeltas[faction] ~= 0) then
			flushFaction(faction)
		end
	end
end

----------------------------------------------------------------
-- Messaging
----------------------------------------------------------------
local function publishUpdate(faction, totalValue)
	local ok, err = pcall(function()
		MessagingService:PublishAsync(CONFIG.MessagingTopic, {
			faction = faction,
			total   = totalValue,
			ts      = os.time(),
		})
	end)
	if not ok then
		warn("[FactionTotalsService] Publish failed:", err)
	end
end

local function subscribe()
	local ok, err = pcall(function()
		MessagingService:SubscribeAsync(CONFIG.MessagingTopic, function(message)
			local data = message.Data
			if type(data) ~= "table" then return end
			local faction = data.faction
			local total   = data.total
			if validateFaction(faction) and type(total) == "number" then
				loadFaction(faction)
				if total > (totals[faction] or 0) then
					totals[faction] = total
					dprint("Received cross-server update", faction, total)
					if dirtyDeltas[faction] and totals[faction] >= (totals[faction] + dirtyDeltas[faction]) then
						dirtyDeltas[faction] = 0
					end
					UPDATE_EVENT:FireAllClients({
						faction = faction,
						total   = total
					})
				end
			end
		end)
	end)
	if not ok then
		warn("[FactionTotalsService] Subscribe failed:", err)
	end
end

----------------------------------------------------------------
-- Increment Logic (MODIFIED: relay to PlayerProfileService)
----------------------------------------------------------------
local function applyLocalIncrement(faction, amount, player)
	if not validateFaction(faction) then
		warn("[FactionTotalsService] Invalid faction increment:", faction)
		return
	end
	if type(amount) ~= "number" or amount <= 0 then
		return
	end

	loadFaction(faction)

	dirtyDeltas[faction] = (dirtyDeltas[faction] or 0) + amount
	totals[faction]      = (totals[faction] or 0) + amount

	UPDATE_EVENT:FireAllClients({
		faction = faction,
		total   = totals[faction]
	})

	publishUpdate(faction, totals[faction])

	if dirtyDeltas[faction] >= CONFIG.MaxUnflushedDelta then
		flushFaction(faction)
	end

	-- Relay payout to PlayerProfileService for per-player persistence
	if player and player:IsA("Player") then
		PlayerProfileService.IncrementCoins(player, amount)
		PlayerProfileService.SaveNow(player, "FactionPayout")
		PlayerProfileService.ForceFullSaveNow(player, "FactionPayoutImmediate")
	end
end

----------------------------------------------------------------
-- RemoteFunction Handler
----------------------------------------------------------------
REQUEST_FUNC.OnServerInvoke = function(player)
	for _,faction in ipairs(CONFIG.Factions) do
		loadFaction(faction)
	end
	local snapshot = {}
	for _,faction in ipairs(CONFIG.Factions) do
		snapshot[faction] = totals[faction] or 0
	end
	return snapshot
end

----------------------------------------------------------------
-- Background Flush Loop
----------------------------------------------------------------
local function startFlushLoop()
	task.spawn(function()
		while true do
			task.wait(CONFIG.FlushIntervalSeconds)
			flushAll(false)
		end
	end)
end

----------------------------------------------------------------
-- Initialization
----------------------------------------------------------------
local function init()
	if initialized then return end
	initialized = true

	for _,faction in ipairs(CONFIG.Factions) do
		loadFaction(faction)
		dirtyDeltas[faction] = 0
	end

	subscribe()
	startFlushLoop()
	dprint("Initialized FactionTotalsService")
end

init()

----------------------------------------------------------------
-- Public API (MODIFIED: AddPayout now requires player)
----------------------------------------------------------------
local Service = {}

function Service.AddPayout(faction, amount, player)
	applyLocalIncrement(faction, amount, player)
end

function Service.GetTotal(faction)
	return loadFaction(faction)
end

function Service.GetAllTotals()
	local out = {}
	for _,faction in ipairs(CONFIG.Factions) do
		out[faction] = loadFaction(faction)
	end
	return out
end

function Service.Flush(force)
	flushAll(force)
end

return Service