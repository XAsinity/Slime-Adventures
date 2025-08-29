-- PlayerProfileService.lua
-- Unified profile/persistence module (compatible with PlayerProfileOrchestrator)

local DataStoreService = game:GetService("DataStoreService")
local Players          = game:GetService("Players")
local DATASTORE_NAME   = "PlayerUnified_v1"
local KEY_PREFIX       = "Player_"

local store            = DataStoreService:GetDataStore(DATASTORE_NAME)
local profileCache     = {}
local dirtyPlayers     = {}

local function log(...)
	print("[PlayerProfileService]", ...)
end

local function keyFor(uid)
	return KEY_PREFIX .. tostring(uid)
end

local function deepCopy(v, seen)
	if type(v) ~= "table" then return v end
	seen = seen or {}
	if seen[v] then return seen[v] end
	local t = {}
	seen[v] = t
	for k, val in pairs(v) do
		t[deepCopy(k, seen)] = deepCopy(val, seen)
	end
	return t
end

local function defaultProfile(userId)
	return {
		schemaVersion = 1,
		dataVersion   = 1,
		userId        = userId,
		updatedAt     = os.time(),
		core          = {
			coins     = 0,
			standings = {},
			wipeGen   = 1,
		},
		inventory     = {
			eggTools      = {},
			foodTools     = {},
			capturedSlimes= {},
			worldSlimes   = {},
			worldEggs     = {},
		},
		extra         = {},
		meta          = {}, -- store transient markers (eg. lastPreExitSnapshot)
	}
end

local function ensureKeys(data, userId)
	if not data.schemaVersion then data.schemaVersion = 1 end
	if not data.dataVersion then data.dataVersion = 1 end
	if not data.userId then data.userId = userId end
	if not data.updatedAt then data.updatedAt = os.time() end
	data.core = data.core or defaultProfile(userId).core
	data.inventory = data.inventory or defaultProfile(userId).inventory
	data.extra = data.extra or {}
	data.meta = data.meta or {}
	return data
end

-- helper: resolve various inputs to a numeric userId (player object, userId, or player name)
local function resolveUserId(playerOrId, shortWait)
	-- numeric id passed directly
	if type(playerOrId) == "number" then
		return playerOrId
	end

	-- Accept Roblox Player Instance (typeof returns "Instance" in Luau) or userdata/table with .UserId
	-- Using typeof if available keeps it robust in Studio/Server environments.
	local okType, t = pcall(function() return typeof and typeof(playerOrId) end)
	if okType and t == "Instance" and playerOrId and playerOrId.UserId then
		return playerOrId.UserId
	end
	-- some runtimes may return "userdata" for Player objects; accept any value that has UserId
	if (type(playerOrId) == "userdata" or type(playerOrId) == "table") and playerOrId and playerOrId.UserId then
		return playerOrId.UserId
	end

	-- string: try to coerce to number first, then try to match by name
	if type(playerOrId) == "string" then
		local n = tonumber(playerOrId)
		if n then return n end

		-- quick checks for a Player instance by name
		local p = Players:FindFirstChild(playerOrId)
		if p and p.UserId then return p.UserId end

		for _, pl in ipairs(Players:GetPlayers()) do
			if pl.Name == playerOrId then
				return pl.UserId
			end
		end

		-- optional short wait for PlayerAdded (non-blocking-ish). shortWait true => wait ~2s, otherwise full fallback (~30s) kept by callers
		local timeout = shortWait and 2 or 30
		local found = nil
		local conn
		conn = Players.PlayerAdded:Connect(function(p)
			if p.Name == playerOrId then
				found = p
				if conn then conn:Disconnect() end
			end
		end)
		local started = os.clock()
		while not found and os.clock() - started < timeout do
			task.wait(0.1)
		end
		if conn and conn.Connected then conn:Disconnect() end
		if found then return found.UserId end
	end

	return nil
end

local function loadProfile(userId)
	local key = keyFor(userId)
	local data
	local ok, err = pcall(function()
		data = store:GetAsync(key)
	end)
	if not ok or type(data) ~= "table" then
		log("No profile found for userId", userId, "creating default.")
		data = defaultProfile(userId)
	end
	data = ensureKeys(data, userId)
	profileCache[userId] = data

	-- Debug: log inventory counts on load to help diagnose missing items
	log(string.format("[PPS][DEBUG] loaded profile %s eggTools=%d foodTools=%d capturedSlimes=%d worldSlimes=%d worldEggs=%d dataVersion=%s",
		tostring(userId),
		#(data.inventory and data.inventory.eggTools or {}),
		#(data.inventory and data.inventory.foodTools or {}),
		#(data.inventory and data.inventory.capturedSlimes or {}),
		#(data.inventory and data.inventory.worldSlimes or {}),
		#(data.inventory and data.inventory.worldEggs or {}),
		tostring(data.dataVersion)
		))

	return data
end

local function saveProfile(userId, reason)
	local profile = profileCache[userId]
	if not profile then return false, "no profile" end
	profile.updatedAt = os.time()
	profile.dataVersion = (profile.dataVersion or 1) + 1
	local key = keyFor(userId)
	local ok, err = pcall(function()
		store:SetAsync(key, profile)
	end)
	if ok then
		log("Saved profile for userId", userId, "reason:", reason or "unspecified")
		dirtyPlayers[userId] = nil
		return true
	else
		log("Save FAILED for userId", userId, "err:", err)
		return false, err
	end
end

local function markDirty(userId)
	dirtyPlayers[userId] = true
end

task.spawn(function()
	while true do
		for userId in pairs(dirtyPlayers) do
			saveProfile(userId, "Periodic")
		end
		task.wait(5)
	end
end)

local PlayerProfileService = {}

function PlayerProfileService.GetProfile(playerOrId)
	-- Accept player object, numeric userId, or numeric/string name.
	local userId = resolveUserId(playerOrId)
	if not userId then
		-- Last-resort: if a string name was passed, try a slightly longer wait (to preserve previous behavior)
		if type(playerOrId) == "string" then
			userId = resolveUserId(playerOrId, false)
		end
	end

	if not userId then
		log("GetProfile called with invalid playerOrId:", tostring(playerOrId), "type=", type(playerOrId))
		return nil
	end

	-- Return cached profile or load from datastore
	return profileCache[userId] or loadProfile(userId)
end

function PlayerProfileService.Get(playerOrId)
	return PlayerProfileService.GetProfile(playerOrId)
end

function PlayerProfileService.SetCoins(playerOrId, amount)
	local userId = resolveUserId(playerOrId)
	if not userId then
		log("SetCoins: invalid playerOrId:", tostring(playerOrId))
		return
	end

	local profile = PlayerProfileService.GetProfile(userId)
	if not profile then
		log("SetCoins: no profile for userId", tostring(userId))
		return
	end
	profile.core = profile.core or {}
	profile.core.coins = amount
	markDirty(userId)

	-- Update live player if available
	local ply = Players:GetPlayerByUserId(userId)
	if ply and ply.SetAttribute then
		pcall(function() ply:SetAttribute("CoinsStored", amount) end)
	end
	if ply then
		local ls = ply:FindFirstChild("leaderstats")
		if ls then
			local coins = ls:FindFirstChild("Coins")
			if coins then
				coins.Value = amount
			end
		end
	end
end

function PlayerProfileService.IncrementCoins(playerOrId, delta)
	local userId = resolveUserId(playerOrId)
	if not userId then
		log("IncrementCoins: invalid playerOrId:", tostring(playerOrId))
		return
	end

	local profile = PlayerProfileService.GetProfile(userId)
	if not profile then
		log("IncrementCoins: no profile for userId", tostring(userId))
		return
	end
	profile.core = profile.core or {}
	profile.core.coins = (profile.core.coins or 0) + (delta or 0)
	markDirty(userId)

	local newAmount = profile.core.coins
	local ply = Players:GetPlayerByUserId(userId)
	if ply and ply.SetAttribute then
		pcall(function() ply:SetAttribute("CoinsStored", newAmount) end)
	end
	if ply then
		local ls = ply:FindFirstChild("leaderstats")
		if ls then
			local coins = ls:FindFirstChild("Coins")
			if coins then
				coins.Value = newAmount
			end
		end
	end
end

function PlayerProfileService.GetCoins(playerOrId)
	local profile = PlayerProfileService.GetProfile(playerOrId)
	if not profile then
		log("GetCoins: no profile for", tostring(playerOrId))
		return 0
	end
	return (profile.core and profile.core.coins) or 0
end

function PlayerProfileService.SetStanding(player, faction, value)
	local profile = PlayerProfileService.GetProfile(player)
	profile.core = profile.core or {}
	profile.core.standings = profile.core.standings or {}
	profile.core.standings[faction] = value
	markDirty(player.UserId)
end

function PlayerProfileService.GetStanding(player, faction)
	local profile = PlayerProfileService.GetProfile(player)
	profile.core = profile.core or {}
	profile.core.standings = profile.core.standings or {}
	return profile.core.standings[faction] or 0
end

function PlayerProfileService.AddInventoryItem(player, category, itemData)
	local profile = PlayerProfileService.GetProfile(player)
	profile.inventory = profile.inventory or defaultProfile(player.UserId).inventory
	if profile.inventory[category] then
		table.insert(profile.inventory[category], itemData)
		markDirty(player.UserId)
	end
end

function PlayerProfileService.RemoveInventoryItem(player, category, itemIdField, itemId)
	local profile = PlayerProfileService.GetProfile(player)
	profile.inventory = profile.inventory or defaultProfile(player.UserId).inventory
	local items = profile.inventory[category]
	if items then
		for i = #items, 1, -1 do
			if items[i][itemIdField] == itemId then
				table.remove(items, i)
				markDirty(player.UserId)
				break
			end
		end
	end
end

function PlayerProfileService.SaveNow(player, reason)
	log("SaveNow requested for userId", player.UserId, "reason:", reason or "Manual (async)")
	-- best-effort async save so callers can stamp meta without blocking
	task.spawn(function()
		saveProfile(player.UserId, reason or "Manual")
	end)
end

function PlayerProfileService.ForceFullSaveNow(player, reason)
	log("ForceFullSaveNow invoked for userId", player.UserId, "reason:", reason or "ForceFullSave")
	-- synchronous save for callers that require immediate persistence
	saveProfile(player.UserId, reason or "ForceFullSave")
end

local EXIT_SAVE_ATTEMPTS      = 3
local EXIT_SAVE_BACKOFF       = 0.4
local EXIT_SAVE_VERIFY_DELAY  = 0.15

local function performVerifiedWrite(userId, snapshot, attempt)
	local key = keyFor(userId)
	local okUpdate, errUpdate = pcall(function()
		store:UpdateAsync(key, function()
			return snapshot
		end)
	end)
	if not okUpdate then
		log(string.format("Attempt %d UpdateAsync failed userId=%d err=%s", attempt, userId, tostring(errUpdate)))
		return false
	end
	task.wait(EXIT_SAVE_VERIFY_DELAY)
	local stored
	local okRead, errRead = pcall(function()
		stored = store:GetAsync(key)
	end)
	if not okRead or type(stored) ~= "table" then
		log(string.format("Attempt %d verify failed userId=%d", attempt, userId))
		return false
	end
	local sv = stored.dataVersion or -1
	local pv = snapshot.dataVersion or -1
	if sv < pv then
		log(string.format("Attempt %d version mismatch userId=%d stored=%s expected>=%s",
			attempt, userId, tostring(sv), tostring(pv)))
		return false
	end
	log(string.format("Attempt %d SUCCESS userId=%d dataVersion=%s", attempt, userId, tostring(sv)))
	return true
end

local function tripleExitSave(player)
	local userId = player.UserId
	local snapshot = deepCopy(profileCache[userId] or defaultProfile(userId))
	local startT = os.clock()
	for attempt = 1, EXIT_SAVE_ATTEMPTS do
		local ok = performVerifiedWrite(userId, snapshot, attempt)
		if ok then
			log(string.format("Verified exit save complete attempt=%d userId=%d elapsed=%.2fs",
				attempt, userId, os.clock()-startT))
			return
		end
		if attempt < EXIT_SAVE_ATTEMPTS then
			task.wait(EXIT_SAVE_BACKOFF)
		else
			log(string.format("FINAL FAILURE userId=%d after %d attempts (snapshot dv=%s)",
				userId, attempt, tostring(snapshot.dataVersion)))
		end
	end
end

Players.PlayerRemoving:Connect(tripleExitSave)

game:BindToClose(function()
	for _, player in ipairs(Players:GetPlayers()) do
		tripleExitSave(player)
	end
	task.wait(0.5)
end)

-- Best-effort preload when players join to reduce race windows for services that query profiles early.
Players.PlayerAdded:Connect(function(player)
	task.spawn(function()
		local prof = PlayerProfileService.GetProfile(player)
		if prof then
			log("Preloaded profile for", player.Name, "userId=", prof.userId)
		else
			log("Preload failed for", player.Name)
		end
	end)
end)

return PlayerProfileService