-- PlayerProfileService.lua (quality-of-life / race reduction / save-coalescing updates)
-- Updated to integrate with SlimeCore.GrowthPersistenceService as orchestrator consumer.
-- Fixes applied:
--  - Forward-declared PlayerProfileService early to avoid "Unknown global 'PlayerProfileService'" linter warning.
--  - Replaced the nested/redundant pcall+FindFirstChild logic for requiring SlimeCore with a single guarded require,
--    removing the duplicated condition that triggered the "DuplicateCondition" warning.
--  - Made a few small defensive disconnects consistent (use simple conn:Disconnect when conn exists).
-----------------------------------------------------------------------

local DataStoreService     = game:GetService("DataStoreService")
local Players              = game:GetService("Players")
local ServerScriptService  = game:GetService("ServerScriptService")
local RunService           = game:GetService("RunService")

local DATASTORE_NAME   = "PlayerUnified_v1"
local KEY_PREFIX       = "Player_"

local store            = DataStoreService:GetDataStore(DATASTORE_NAME)

-- Public module table (forward-declared early to avoid linter unknown-global warnings)
local PlayerProfileService = {}

-- In-memory caches and helpers
local profileCache     = {}    -- userId -> profile table
local dirtyPlayers     = {}    -- userId -> true (needs save)
local saveScheduled    = {}    -- userId -> true (a debounced async save is scheduled)
local saveLocks        = {}    -- userId -> true (save currently running)
local lastSaveResult   = {}    -- userId -> { ts=os.clock(), success=bool } last save outcome
local SAVE_DEBOUNCE_SECONDS = 0.35
local PERIODIC_FLUSH_INTERVAL = 5

local EXIT_SAVE_ATTEMPTS      = 3
local EXIT_SAVE_BACKOFF       = 0.4
local EXIT_SAVE_VERIFY_DELAY  = 0.15

local function log(...)
	print("[PlayerProfileService]", ...)
end

local function keyFor(uid)
	return KEY_PREFIX .. tostring(uid)
end

-- shallow+deep copy helper (handles nested tables)
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
		meta          = {}, -- transient markers (eg. lastPreExitSnapshot)
		-- persistentId will be assigned on-first-load (see loadProfile)
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
	-- preserve persistentId if present; do not overwrite here
	return data
end

-- Persistent ID generation
local function generatePersistentId(userId)
	local uid = tonumber(userId) or 0
	local low = os.time() % 1000000
	local pid = (uid * 1000000) + low
	return pid
end

-- Resolve player/userId/name/profile to numeric userId (defensive)
local function resolveUserId(playerOrId, shortWait)
	if type(playerOrId) == "number" then return playerOrId end

	if type(playerOrId) == "table" and (playerOrId.userId or playerOrId.UserId) then
		return tonumber(playerOrId.userId or playerOrId.UserId)
	end

	local okType = (typeof ~= nil)
	if okType and typeof(playerOrId) == "Instance" then
		local success, isPlayer = pcall(function() return playerOrId:IsA("Player") end)
		if success and isPlayer and playerOrId.UserId then
			return playerOrId.UserId
		end
	end

	if type(playerOrId) == "table" and playerOrId.UserId then
		return playerOrId.UserId
	end

	if type(playerOrId) == "string" then
		local n = tonumber(playerOrId)
		if n then return n end

		local p = Players:FindFirstChild(playerOrId)
		if p and p.UserId then return p.UserId end

		for _,pl in ipairs(Players:GetPlayers()) do
			if pl.Name == playerOrId then return pl.UserId end
		end

		local timeout = shortWait and 2 or 30
		local found = nil
		local conn
		conn = Players.PlayerAdded:Connect(function(pl)
			if pl.Name == playerOrId then
				found = pl
				if conn then conn:Disconnect() end
			end
		end)
		local started = os.clock()
		while not found and os.clock() - started < timeout do
			task.wait(0.08)
		end
		if conn and conn.Connected then conn:Disconnect() end
		if found then return found.UserId end
	end

	return nil
end

-- Helper to normalize method vs function call (strip self if PlayerProfileService passed as first arg)
local function stripSelfArg(...)
	local args = { ... }
	if args[1] == PlayerProfileService then
		table.remove(args, 1)
	end
	return table.unpack(args)
end

-- Forward declaration for scheduleSave to avoid "unknown global" warnings when referenced earlier
-- (defined further down)
local scheduleSave

-- Bindable events (ProfileReady and SaveComplete)
local _ProfileReadyBindable = nil
local _SaveCompleteBindable = nil

do
	local ok, ev = pcall(function()
		local be = Instance.new("BindableEvent")
		be.Name = "ProfileReady"
		local parent = ServerScriptService:FindFirstChild("Modules") or ServerScriptService
		if parent:FindFirstChild("ProfileReady") then
			return parent:FindFirstChild("ProfileReady")
		end
		be.Parent = parent
		return be
	end)
	if ok and ev then _ProfileReadyBindable = ev end
end

do
	local ok, ev = pcall(function()
		local be = Instance.new("BindableEvent")
		be.Name = "SaveComplete"
		local parent = ServerScriptService:FindFirstChild("Modules") or ServerScriptService
		if parent:FindFirstChild("SaveComplete") then
			return parent:FindFirstChild("SaveComplete")
		end
		be.Parent = parent
		return be
	end)
	if ok and ev then _SaveCompleteBindable = ev end
end

-- fire helpers
local function fireProfileReady(userId, profile)
	if _ProfileReadyBindable and _ProfileReadyBindable.Fire then
		pcall(function() _ProfileReadyBindable:Fire(userId, profile) end)
	end
end
local function fireSaveComplete(userId, success)
	if _SaveCompleteBindable and _SaveCompleteBindable.Fire then
		pcall(function() _SaveCompleteBindable:Fire(tonumber(userId) or userId, success and true or false) end)
	end
	lastSaveResult[tonumber(userId)] = { ts = os.clock(), success = success and true or false }
end

-- WaitForSaveComplete with shortcut if a recent save already finished
local function WaitForSaveComplete(playerOrId, timeoutSeconds)
	timeoutSeconds = tonumber(timeoutSeconds) or 2
	local userId = resolveUserId(playerOrId)
	if not userId then return false end

	local last = lastSaveResult[userId]
	if last and (os.clock() - last.ts) <= timeoutSeconds then
		return true, last.success
	end

	local done = false
	local success = false
	local conn
	if _SaveCompleteBindable and _SaveCompleteBindable.Event then
		conn = _SaveCompleteBindable.Event:Connect(function(evUserId, evSuccess)
			if tonumber(evUserId) == tonumber(userId) then
				done = true
				success = evSuccess and true or false
			end
		end)
	end

	local start = os.clock()
	while not done and (os.clock() - start) < timeoutSeconds do
		task.wait(0.05)
	end

	if conn then
		pcall(function() conn:Disconnect() end)
	end
	return done, success
end

-- Inventory sanitization helpers (remove malformed / id-less entries and dedupe)
local function getCanonicalId(category, entry)
	if not entry or type(entry) ~= "table" then return nil end
	if category == "worldSlimes" then
		return entry.id or entry.SlimeId or entry.slimeId or nil
	end
	if category == "worldEggs" then
		return entry.id or entry.EggId or entry.eggId or nil
	end
	if category == "capturedSlimes" then
		return entry.ToolUniqueId or entry.ToolUid or entry.ToolId or entry.SlimeId or nil
	end
	if category == "eggTools" then
		return entry.ToolUid or entry.ToolUniqueId or entry.EggId or nil
	end
	if category == "foodTools" then
		return entry.ToolUniqueId or entry.ToolUid or entry.fid or entry.FoodId or nil
	end
	return entry.id or nil
end

local function sanitizeInventoryOnLoad(profile, userId)
	if not profile or type(profile) ~= "table" or type(profile.inventory) ~= "table" then return false end
	local inv = profile.inventory
	local fields = { "eggTools", "foodTools", "worldEggs", "worldSlimes", "capturedSlimes" }
	local changed = false
	for _, fname in ipairs(fields) do
		local list = inv[fname]
		if list and type(list) == "table" then
			local seen = {}
			local cleaned = {}
			for _, entry in ipairs(list) do
				if type(entry) == "table" then
					local cid = getCanonicalId(fname, entry)
					if cid then
						local key = tostring(cid)
						if not seen[key] then
							seen[key] = true
							cleaned[#cleaned+1] = entry
						else
							changed = true
						end
					else
						changed = true
					end
				else
					changed = true
				end
			end
			inv[fname] = cleaned
		end
	end
	if changed and userId then
		dirtyPlayers[userId] = true
		pcall(function() scheduleSave(userId, "SanitizeInventory") end)
		log(("sanitizeInventoryOnLoad: sanitized inventory for userId=%s"):format(tostring(userId)))
	end
	return changed
end

-- Data store read/write primitives --------------------------------------------

local function loadProfile(userId)
	local key = keyFor(userId)
	local data
	local ok, err = pcall(function()
		data = store:GetAsync(key)
	end)
	if not ok or type(data) ~= "table" then
		log("No profile found for userId", userId, "- creating default.")
		data = defaultProfile(userId)
	end
	data = ensureKeys(data, userId)

	pcall(function() sanitizeInventoryOnLoad(data, userId) end)

	if not data.persistentId then
		local pid = generatePersistentId(userId)
		data.persistentId = pid
		scheduleSave(userId, "AssignPersistentId")
		log(("[PPS][PersistentId] Assigned persistentId=%s to userId=%s (will persist)"):format(tostring(pid), tostring(userId)))
	end

	profileCache[userId] = data

	log(string.format("[PPS][DEBUG] loaded profile %s coins=%s eggTools=%d foodTools=%d capturedSlimes=%d worldSlimes=%d worldEggs=%d dataVersion=%s persistentId=%s",
		tostring(userId),
		tostring((data.core and data.core.coins) or 0),
		#(data.inventory and data.inventory.eggTools or {}),
		#(data.inventory and data.inventory.foodTools or {}),
		#(data.inventory and data.inventory.capturedSlimes or {}),
		#(data.inventory and data.inventory.worldSlimes or {}),
		#(data.inventory and data.inventory.worldEggs or {}),
		tostring(data.dataVersion),
		tostring(data.persistentId or "nil")
		))

	fireProfileReady(userId, data)
	return data
end

-- internal saver (SetAsync path) with per-user locking
local function saveProfileInternal(userId, reason)
	if not userId then return false, "no userId" end
	if saveLocks[userId] then
		return false, "locked"
	end
	saveLocks[userId] = true
	local profile = profileCache[userId]
	if not profile then
		saveLocks[userId] = nil
		return false, "no profile"
	end
	profile.updatedAt = os.time()
	profile.dataVersion = (profile.dataVersion or 1) + 1

	local key = keyFor(userId)
	log(string.format("[PPS][DEBUG] SetAsync save userId=%s coins=%s reason=%s dataVersion=%s persistentId=%s",
		tostring(userId),
		tostring((profile.core and profile.core.coins) or 0),
		tostring(reason or "unspecified"),
		tostring(profile.dataVersion or "?"),
		tostring(profile.persistentId or "nil")
		))

	local ok, res = pcall(function()
		store:SetAsync(key, profile)
	end)
	if ok then
		dirtyPlayers[userId] = nil
		fireSaveComplete(userId, true)
		saveLocks[userId] = nil
		log("Saved profile for userId", userId, "reason:", reason or "unspecified")
		return true
	else
		fireSaveComplete(userId, false)
		saveLocks[userId] = nil
		log("SetAsync Save FAILED for userId", userId, "err:", res)
		return false, res
	end
end

-- Debounced SaveNow: coalesce multiple calls into a single save (non-blocking)
scheduleSave = function(userId, reason)
	if not userId then return end
	dirtyPlayers[userId] = true
	if saveScheduled[userId] then
		return
	end
	saveScheduled[userId] = true
	task.spawn(function()
		task.wait(SAVE_DEBOUNCE_SECONDS)
		saveScheduled[userId] = nil
		local ok, err = saveProfileInternal(userId, reason or "Manual")
		if not ok then
			if err == "locked" then
				task.wait(0.08)
				pcall(function() saveProfileInternal(userId, reason or "ManualRetry") end)
			end
		end
	end)
end

-- Verified write helper: UpdateAsync + readback + version check (protected by saveLocks)
local function performVerifiedWrite(userId, snapshot, attempt)
	local key = keyFor(userId)
	local okUpdate, errUpdate = pcall(function()
		store:UpdateAsync(key, function(old)
			return snapshot
		end)
	end)
	if not okUpdate then
		log(string.format("Attempt %d UpdateAsync failed userId=%d err=%s", attempt, userId, tostring(errUpdate)))
		return false
	end

	task.wait(EXIT_SAVE_VERIFY_DELAY)
	local stored, okRead, errRead
	okRead, errRead = pcall(function()
		stored = store:GetAsync(key)
	end)
	if not okRead or type(stored) ~= "table" then
		log(string.format("Attempt %d verify failed userId=%d readErr=%s", attempt, userId, tostring(errRead)))
		return false
	end
	local sv = stored.dataVersion or -1
	local pv = snapshot.dataVersion or -1
	if sv < pv then
		log(string.format("Attempt %d version mismatch userId=%d stored=%s expected>=%s", attempt, userId, tostring(sv), tostring(pv)))
		return false
	end
	log(string.format("Attempt %d SUCCESS userId=%d dataVersion=%s", attempt, userId, tostring(sv)))
	return true
end

-- API: GetProfile (loads and caches) -- robust to colon vs dot invocation
function PlayerProfileService.GetProfile(...)
	local playerOrId = stripSelfArg(...)
	local userId = resolveUserId(playerOrId)
	if not userId then
		if type(playerOrId) == "string" then
			userId = resolveUserId(playerOrId, false)
		end
	end
	if not userId then
		log("GetProfile called with invalid playerOrId:", tostring(playerOrId))
		return nil
	end
	if profileCache[userId] then return profileCache[userId] end
	return loadProfile(userId)
end
PlayerProfileService.Get = PlayerProfileService.GetProfile

-- WaitForProfile: wait bounded for profile being loaded (uses bindable) -- robust to colon vs dot
function PlayerProfileService.WaitForProfile(...)
	local playerOrId, timeoutSeconds = stripSelfArg(...)
	timeoutSeconds = timeoutSeconds or 5
	local prof = PlayerProfileService.GetProfile(playerOrId)
	if prof then return prof end

	local userId = resolveUserId(playerOrId, true)
	if not userId then return nil end

	if profileCache[userId] then return profileCache[userId] end

	local resolved = nil
	local conn
	local done = false
	if _ProfileReadyBindable and _ProfileReadyBindable.Event then
		conn = _ProfileReadyBindable.Event:Connect(function(evUserId, profile)
			if tostring(evUserId) == tostring(userId) then
				resolved = profile
				done = true
			end
		end)
	end
	local start = os.clock()
	while not done and (os.clock() - start) < timeoutSeconds do
		task.wait(0.05)
		if profileCache[userId] then
			resolved = profileCache[userId]
			done = true
			break
		end
	end
	if conn then
		pcall(function() conn:Disconnect() end)
	end
	return resolved
end

-- GetOrAssignPersistentId: ensure profile has a persistent numeric id and persist it (schedule) -- robust to colon vs dot
function PlayerProfileService.GetOrAssignPersistentId(...)
	local playerOrProfile = stripSelfArg(...)
	local userId = resolveUserId(playerOrProfile)
	local profile = nil
	if userId then
		profile = PlayerProfileService.GetProfile(userId)
	end
	if type(playerOrProfile) == "table" and playerOrProfile.inventory then
		profile = playerOrProfile
		userId = tonumber(profile.userId or profile.UserId) or userId
	end
	if not profile and userId then
		profile = PlayerProfileService.GetProfile(userId)
	end
	if not profile then return nil end

	if profile.persistentId and tonumber(profile.persistentId) then
		return tonumber(profile.persistentId)
	end

	local pid = generatePersistentId(userId or profile.userId)
	profile.persistentId = pid
	scheduleSave(userId, "AssignPersistentId")
	log(("[PPS][PersistentId] Assigned persistentId=%s to userId=%s via GetOrAssign"):format(tostring(pid), tostring(userId)))
	return pid
end

-- markDirty exposes to module functions
local function markDirty(userId)
	if not userId then return end
	dirtyPlayers[userId] = true
	scheduleSave(userId, "DirtyMark")
end

-- Expose MarkDirty method for external orchestrators (handles colon and dot calls)
function PlayerProfileService.MarkDirty(self_or_player, maybe_player)
	local userId = nil
	if self_or_player == PlayerProfileService then
		userId = resolveUserId(maybe_player)
	else
		userId = resolveUserId(self_or_player)
	end
	if not userId then return end
	markDirty(userId)
end

-- Coin helpers (update profile + leaderstats + schedule save)
function PlayerProfileService.SetCoins(playerOrId, amount, opts)
	local userId = resolveUserId(playerOrId)
	if not userId then
		log("SetCoins: invalid playerOrId:", tostring(playerOrId))
		return false, "no user"
	end
	local profile = PlayerProfileService.GetProfile(userId)
	if not profile then
		log("SetCoins: no profile for userId", tostring(userId))
		return false, "no profile"
	end
	profile.core = profile.core or {}
	profile.core.coins = tonumber(amount) or 0
	markDirty(userId)

	local ply = Players:GetPlayerByUserId(userId)
	if ply then
		task.spawn(function()
			if ply.SetAttribute then
				pcall(function() ply:SetAttribute("CoinsStored", profile.core.coins) end)
			end
			local ls = ply:FindFirstChild("leaderstats")
			if ls then
				local coins = ls:FindFirstChild("Coins")
				if coins then coins.Value = profile.core.coins end
			end
		end)
	end

	opts = opts or {}
	if opts.saveNow then
		PlayerProfileService.SaveNow(playerOrId, "SetCoinsImmediate")
	end
	return true
end

function PlayerProfileService.IncrementCoins(playerOrId, delta, opts)
	local userId = resolveUserId(playerOrId)
	if not userId then
		log("IncrementCoins: invalid playerOrId:", tostring(playerOrId))
		return false, "no user"
	end
	local profile = PlayerProfileService.GetProfile(userId)
	if not profile then
		log("IncrementCoins: no profile for userId", tostring(userId))
		return false, "no profile"
	end
	profile.core = profile.core or {}
	profile.core.coins = (profile.core.coins or 0) + (delta or 0)
	markDirty(userId)

	local newAmount = profile.core.coins
	local ply = Players:GetPlayerByUserId(userId)
	if ply then
		task.spawn(function()
			if ply.SetAttribute then pcall(function() ply:SetAttribute("CoinsStored", newAmount) end) end
			local ls = ply:FindFirstChild("leaderstats")
			if ls then
				local coins = ls:FindFirstChild("Coins")
				if coins then coins.Value = newAmount end
			end
		end)
	end

	if opts and opts.saveNow then
		PlayerProfileService.SaveNow(playerOrId, "IncrementCoinsImmediate")
	end

	return true, newAmount
end

function PlayerProfileService.GetCoins(playerOrId)
	local profile = PlayerProfileService.GetProfile(playerOrId)
	if not profile then
		return 0
	end
	return (profile.core and profile.core.coins) or 0
end

-- Inventory helpers
function PlayerProfileService.AddInventoryItem(playerOrId, category, itemData)
	local userId = resolveUserId(playerOrId)
	if not userId then
		log("AddInventoryItem: invalid playerOrId:", tostring(playerOrId))
		return false, "no user"
	end
	local profile = PlayerProfileService.GetProfile(userId)
	if not profile then
		log("AddInventoryItem: no profile for userId", tostring(userId))
		return false, "no profile"
	end
	profile.inventory = profile.inventory or defaultProfile(userId).inventory

	local function inventoryContains(profile, category, canonicalId)
		if not canonicalId or not profile or not profile.inventory or not profile.inventory[category] then return false end
		for _, entry in ipairs(profile.inventory[category]) do
			local cid = getCanonicalId(category, entry)
			if cid and tostring(cid) == tostring(canonicalId) then
				return true
			end
		end
		return false
	end

	local cid = getCanonicalId(category, itemData)
	if category == "worldSlimes" then
		if not cid then
			log("AddInventoryItem: worldSlimes items require an id; rejecting malformed item for userId", userId)
			return false, "missing id"
		end
	elseif category == "worldEggs" then
		if not cid then
			log("AddInventoryItem: worldEggs items require an id; rejecting malformed item for userId", userId)
			return false, "missing id"
		end
	elseif category == "capturedSlimes" then
		if not cid then
			log("AddInventoryItem: capturedSlimes items require ToolUniqueId/ToolUid or SlimeId; rejecting malformed item for userId", userId)
			return false, "missing id"
		end
	end

	if profile.inventory[category] then
		if cid and inventoryContains(profile, category, cid) then
			return true
		end
		table.insert(profile.inventory[category], itemData)
		markDirty(userId)
		return true
	end
	return false, "invalid category"
end

function PlayerProfileService.RemoveInventoryItem(playerOrId, category, itemIdField, itemId)
	local userId = resolveUserId(playerOrId)
	if not userId then
		log("RemoveInventoryItem: invalid playerOrId:", tostring(playerOrId))
		return false, "no user"
	end
	local profile = PlayerProfileService.GetProfile(userId)
	if not profile then
		log("RemoveInventoryItem: no profile for userId", tostring(userId))
		return false, "no profile"
	end
	profile.inventory = profile.inventory or defaultProfile(userId).inventory
	local items = profile.inventory[category]
	if items then
		for i = #items, 1, -1 do
			if items[i][itemIdField] == itemId then
				table.remove(items, i)
				markDirty(userId)
				return true
			end
		end
	end
	return false, "not found"
end

-- Save API ---------------------------------------------------------------

-- SaveNow: schedule a debounced async SetAsync save. Fires SaveComplete when completed.
function PlayerProfileService.SaveNow(...)
	local playerOrId, reason = stripSelfArg(...)
	local userId = resolveUserId(playerOrId)
	if not userId then
		if type(playerOrId) == "table" and playerOrId.userId then userId = tonumber(playerOrId.userId) end
	end
	if not userId then
		log("SaveNow requested with invalid playerOrId:", tostring(playerOrId))
		return
	end
	log("SaveNow requested for userId", userId, "reason:", reason or "Manual (async)")
	scheduleSave(userId, reason or "Manual")
end

-- ForceFullSaveNow: perform a verified write (UpdateAsync + verification). Blocking-ish.
function PlayerProfileService.ForceFullSaveNow(...)
	local playerOrId, reason = stripSelfArg(...)
	local userId = resolveUserId(playerOrId)
	if not userId and type(playerOrId) == "table" and playerOrId.userId then userId = tonumber(playerOrId.userId) end
	if not userId then
		log("ForceFullSaveNow invoked with invalid playerOrId:", tostring(playerOrId))
		return false
	end
	log("ForceFullSaveNow invoked for userId", userId, "reason:", reason or "ForceFullSave")

	if saveLocks[userId] then
		local waitStart = os.clock()
		while saveLocks[userId] and (os.clock() - waitStart) < 2 do
			task.wait(0.06)
		end
		if saveLocks[userId] then
			log("ForceFullSaveNow aborted: another save in progress for userId", userId)
			return false
		end
	end

	local snapshot = deepCopy(profileCache[userId] or defaultProfile(userId))
	snapshot.updatedAt = os.time()
	snapshot.dataVersion = (snapshot.dataVersion or 1) + 1

	saveLocks[userId] = true
	local startT = os.clock()
	local okOverall = false
	for attempt = 1, EXIT_SAVE_ATTEMPTS do
		local ok = performVerifiedWrite(userId, snapshot, attempt)
		if ok then
			okOverall = true
			break
		end
		if attempt < EXIT_SAVE_ATTEMPTS then
			task.wait(EXIT_SAVE_BACKOFF)
		end
	end
	saveLocks[userId] = nil

	if okOverall then
		profileCache[userId] = snapshot
		dirtyPlayers[userId] = nil
		fireSaveComplete(userId, true)
		log(string.format("Verified save complete userId=%d elapsed=%.2fs", userId, os.clock()-startT))
		return true
	else
		fireSaveComplete(userId, false)
		log(string.format("Verified save FAILED userId=%d after %d attempts (snapshot dv=%s)", userId, EXIT_SAVE_ATTEMPTS, tostring(snapshot.dataVersion)))
		return false
	end
end

-- SaveNowAndWait: convenience helper
function PlayerProfileService.SaveNowAndWait(...)
	local playerOrId, timeoutSeconds, preferVerified = stripSelfArg(...)
	timeoutSeconds = tonumber(timeoutSeconds) or 2
	if preferVerified then
		local ok = PlayerProfileService.ForceFullSaveNow(playerOrId, "SaveNowAndWait_Verified")
		return ok
	else
		PlayerProfileService.SaveNow(playerOrId, "SaveNowAndWait_Async")
		local done, success = WaitForSaveComplete(playerOrId, timeoutSeconds)
		return done and success
	end
end

-- Periodic flusher: flush dirty profiles in background (coalesced saves)
task.spawn(function()
	while true do
		for userId in pairs(dirtyPlayers) do
			scheduleSave(userId, "Periodic")
		end
		task.wait(PERIODIC_FLUSH_INTERVAL)
	end
end)

-- Exit save helper for PlayerRemoving and server shutdown (verified, sequential)
local function tripleExitSave(player)
	local userId = player and player.UserId
	if not userId then return end
	local snapshot = deepCopy(profileCache[userId] or defaultProfile(userId))
	snapshot.updatedAt = os.time()
	snapshot.dataVersion = (snapshot.dataVersion or 1) + 1

	if saveLocks[userId] then
		local start = os.clock()
		while saveLocks[userId] and (os.clock() - start) < 2 do task.wait(0.05) end
		if saveLocks[userId] then
			log("tripleExitSave: skipping because save lock busy for userId", userId)
			fireSaveComplete(userId, false)
			return
		end
	end
	saveLocks[userId] = true

	local startT = os.clock()
	local succeeded = false
	for attempt = 1, EXIT_SAVE_ATTEMPTS do
		local ok = performVerifiedWrite(userId, snapshot, attempt)
		if ok then
			succeeded = true
			break
		end
		if attempt < EXIT_SAVE_ATTEMPTS then task.wait(EXIT_SAVE_BACKOFF) end
	end
	saveLocks[userId] = nil

	if succeeded then
		profileCache[userId] = snapshot
		dirtyPlayers[userId] = nil
		fireSaveComplete(userId, true)
		log(string.format("Verified exit save complete userId=%d elapsed=%.2fs", userId, os.clock()-startT))
	else
		fireSaveComplete(userId, false)
		log(string.format("Verified exit save FAILED userId=%d after %d attempts", userId, EXIT_SAVE_ATTEMPTS))
	end
end

Players.PlayerRemoving:Connect(function(player)
	pcall(function() tripleExitSave(player) end)
	profileCache[player.UserId] = nil
	dirtyPlayers[player.UserId] = nil
end)

game:BindToClose(function()
	for _, player in ipairs(Players:GetPlayers()) do
		local ok, _ = pcall(function() tripleExitSave(player) end)
		task.wait(0.1)
	end
	task.wait(0.2)
end)

-- Preload profiles for players when they join (reduce race windows)
Players.PlayerAdded:Connect(function(player)
	task.spawn(function()
		local prof = PlayerProfileService.GetProfile(player)
		if prof then
			log("Preloaded profile for", player.Name, "userId=", prof.userId)
			if prof.persistentId and player.SetAttribute then
				pcall(function() player:SetAttribute("PersistentId", prof.persistentId) end)
			end
		else
			local p2 = PlayerProfileService.WaitForProfile(player, 2)
			if p2 then
				log("Preloaded profile via WaitForProfile for", player.Name)
				if p2.persistentId and player.SetAttribute then
					pcall(function() player:SetAttribute("PersistentId", p2.persistentId) end)
				end
			end
		end
	end)
end)

-- Expose events
if _ProfileReadyBindable then
	PlayerProfileService._ProfileReadyBindable = _ProfileReadyBindable
	PlayerProfileService.ProfileReady = _ProfileReadyBindable.Event
else
	PlayerProfileService._ProfileReadyBindable = nil
	PlayerProfileService.ProfileReady = {
		Connect = function() return { Disconnect = function() end } end
	}
end

if _SaveCompleteBindable then
	PlayerProfileService._SaveCompleteBindable = _SaveCompleteBindable
	PlayerProfileService.SaveComplete = _SaveCompleteBindable.Event
else
	PlayerProfileService._SaveCompleteBindable = nil
	PlayerProfileService.SaveComplete = {
		Connect = function() return { Disconnect = function() end } end
	}
end

-- WaitForSaveComplete exposed
PlayerProfileService.WaitForSaveComplete = WaitForSaveComplete

-- Inventory Serializer adapter (optional): delegate to GrandInventorySerializer when present.
pcall(function()
	local ok, serializer = pcall(function()
		return require(script.Parent:WaitForChild("GrandInventorySerializer"))
	end)
	if ok and serializer and type(serializer.Serialize) == "function" then
		PlayerProfileService.SerializeInventory = function(playerOrProfile, isFinal)
			if type(playerOrProfile) == "table" and playerOrProfile.inventory then
				local ok, res = pcall(function() return serializer.Serialize(playerOrProfile, isFinal) end)
				return ok and res or {}
			end
			local prof = PlayerProfileService.GetProfile(playerOrProfile)
			if prof then
				local ok, res = pcall(function() return serializer.Serialize(prof, isFinal) end)
				return ok and res or {}
			end
			local ok, res = pcall(function() return serializer.Serialize(playerOrProfile, isFinal) end)
			return ok and res or {}
		end
		PlayerProfileService.RestoreInventory = function(playerOrProfile, payload)
			local ok, err = pcall(function() return serializer.Restore(playerOrProfile, payload) end)
			return ok, err
		end
	else
		PlayerProfileService.SerializeInventory = function() return {} end
		PlayerProfileService.RestoreInventory = function() return false, "no-serializer" end
	end
end)

-- Expose GetOrAssignPersistentId API (already defined)
PlayerProfileService.GetOrAssignPersistentId = PlayerProfileService.GetOrAssignPersistentId

-- Attempt to initialize SlimeCore.GrowthPersistenceService with this orchestrator (PlayerProfileService)
-- Simplified and guarded require to avoid duplicate-check lint errors and redundant conditions.
do
	local scModule = script.Parent:FindFirstChild("SlimeCore")
	if scModule and scModule:IsA("ModuleScript") then
		local ok, SlimeCore = pcall(require, scModule)
		if ok and type(SlimeCore) == "table" and type(SlimeCore.GrowthPersistenceService) == "table" and type(SlimeCore.GrowthPersistenceService.Init) == "function" then
			pcall(function() SlimeCore.GrowthPersistenceService:Init(PlayerProfileService) end)
			log("SlimeCore.GrowthPersistenceService initialized with PlayerProfileService as orchestrator.")
		end
	end
end

-- Final return
return PlayerProfileService