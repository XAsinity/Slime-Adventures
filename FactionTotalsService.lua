-- FactionTotalsService
-- Global cross-server aggregation of total coins paid out per faction.
-- Responsibilities:
--   * Maintain per-faction running total in memory
--   * Persist totals to DataStore (batched)
--   * Broadcast updates cross-server via MessagingService
--   * Notify local clients via RemoteEvent
--   * Expose synchronous getters for other server modules

local DataStoreService  = game:GetService("DataStoreService")
local MessagingService  = game:GetService("MessagingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local REMOTES_FOLDER = ReplicatedStorage:WaitForChild("Remotes")
local UPDATE_EVENT   = REMOTES_FOLDER:WaitForChild("FactionTotalsUpdate")       -- RemoteEvent
local REQUEST_FUNC   = REMOTES_FOLDER:WaitForChild("RequestFactionTotals")      -- RemoteFunction

----------------------------------------------------------------
-- Configuration
----------------------------------------------------------------
local CONFIG = {
	DataStoreName         = "FactionTotalsV1",
	KeyPrefix             = "FactionTotal_",    -- final key: KeyPrefix .. faction
	Factions              = { "Pacifist", "Orion" },

	-- Batching behavior
	FlushIntervalSeconds  = 15,     -- periodic flush interval
	MaxUnflushedDelta     = 5_000,  -- if accumulated delta for a faction exceeds this, flush early
	MaxWriteRetries       = 5,      -- retries for DataStore writes
	RetryBackoffBase      = 0.5,    -- seconds (exponential backoff)

	-- Messaging
	MessagingTopic        = "FactionTotalsUpdateV1",

	Debug                 = false,
}

----------------------------------------------------------------
-- Internal State
----------------------------------------------------------------
local store             = DataStoreService:GetDataStore(CONFIG.DataStoreName)
local totals            = {}  -- cached persisted total (after last successful save + in-memory increments)
local dirtyDeltas       = {}  -- accumulated unsaved increments per faction
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
			-- After update, re-read to align cache safely
			local _, finalRead = pcall(function() return store:GetAsync(key) end)
			if type(finalRead) == "number" then
				totals[faction] = finalRead
			else
				-- fallback if read fails, but we still trust the increment happened
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
				-- Only update if incoming total is newer / larger
				loadFaction(faction) -- ensure loaded
				if total > (totals[faction] or 0) then
					totals[faction] = total
					dprint("Received cross-server update", faction, total)
					-- Reset dirty delta if our unsaved increments are already included
					if dirtyDeltas[faction] and totals[faction] >= (totals[faction] + dirtyDeltas[faction]) then
						dirtyDeltas[faction] = 0
					end
					-- Broadcast to local clients
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
-- Increment Logic
----------------------------------------------------------------
local function applyLocalIncrement(faction, amount)
	if not validateFaction(faction) then
		warn("[FactionTotalsService] Invalid faction increment:", faction)
		return
	end
	if type(amount) ~= "number" or amount <= 0 then
		return
	end

	-- Ensure loaded
	loadFaction(faction)

	dirtyDeltas[faction] = (dirtyDeltas[faction] or 0) + amount
	totals[faction]      = (totals[faction] or 0) + amount

	-- Immediate client notification (local server)
	UPDATE_EVENT:FireAllClients({
		faction = faction,
		total   = totals[faction]
	})

	-- Cross-server broadcast (non-authoritative; final authoritative total persisted on flush)
	publishUpdate(faction, totals[faction])

	-- If delta large enough, flush early
	if dirtyDeltas[faction] >= CONFIG.MaxUnflushedDelta then
		flushFaction(faction)
	end
end

----------------------------------------------------------------
-- RemoteFunction Handler
----------------------------------------------------------------
REQUEST_FUNC.OnServerInvoke = function(player)
	-- Ensure all needed factions loaded
	for _,faction in ipairs(CONFIG.Factions) do
		loadFaction(faction)
	end
	-- Merge in unsaved deltas (totals already reflect them) and return snapshot
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

	-- Load base totals for each faction proactively (optional)
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
-- Public API
----------------------------------------------------------------
local Service = {}

function Service.AddPayout(faction, amount)
	applyLocalIncrement(faction, amount)
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