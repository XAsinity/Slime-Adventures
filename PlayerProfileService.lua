-- PlayerProfileService.lua (quality-of-life / race reduction / save-coalescing updates)
-- Patched: centralized CONFIG.Debug now controls all previously noisy logs.
-- Additional safety: prevent suspicious writes after failures or unexpected zeroing.
-- - Adds pre-save validation to block potentially destructive saves (e.g., full-zero writes) unless explicitly overridden.
-- - Validates against the authoritative datastore state when possible (prevents in-memory-zero overwrite).
-- - Tracks last persisted snapshot (profile.meta.__lastSavedSnapshot) and uses it to validate subsequent saves.
-- - Throttles excessive SaveNow calls per-user and defers to verified writes after recent failures.
-- - Adds optional PRODUCTION_SAFE_MODE (when true, suspicious SetAsync and verified saves are blocked and audited).
-- - Hardened sanitizeForDatastore with recursion depth / node count limits to avoid UpdateAsync transform stack overflows.
-- - Fixed debug.shadow crash: captured original Lua debug library and use it for tracebacks.
-- - Added PlayerProfileService.ApplySale for atomic sale application (coins + inventory removals + verified persist).
-- - Default CONFIG.Debug = false (no spam). Set CONFIG.Debug=true for verbose debug.
-----------------------------------------------------------------------

local DataStoreService     = game:GetService("DataStoreService")
local Players              = game:GetService("Players")
local ServerScriptService  = game:GetService("ServerScriptService")
local RunService           = game:GetService("RunService")
local HttpService          = game:GetService("HttpService")
local ServerStorage        = game:GetService("ServerStorage")

local DATASTORE_NAME   = "PlayerUnified_v1"
local KEY_PREFIX       = "Player_"

local store            = DataStoreService:GetDataStore(DATASTORE_NAME)

local PlayerProfileService = {}

local LUA_DEBUG = debug
local CONFIG = {
	Debug = false,
}
local PRODUCTION_SAFE_MODE = true
local PPS_DEBUG_UPDATEASYNC = CONFIG.Debug

local profileCache     = {}
local dirtyPlayers     = {}
local saveScheduled    = {}
local saveLocks        = {}
local lastSaveResult   = {}
local SAVE_DEBOUNCE_SECONDS = 0.35
local PERIODIC_FLUSH_INTERVAL = 5
local EXIT_SAVE_ATTEMPTS      = 3
local EXIT_SAVE_BACKOFF       = 0.4
local EXIT_SAVE_VERIFY_DELAY  = 0.15

local SUSPICIOUS_SAVE_BLOCK_WINDOW = 5
local SAVE_RATE_WINDOW = 1
local SAVE_RATE_LIMIT = 10
local ALLOW_DESTRUCTIVE_TOKEN = "ALLOW_DESTRUCTIVE_SAVE"

local saveRequestTimestamps = {}
local MAX_SANITIZE_DEPTH = 8
local MAX_SANITIZE_NODES = 5000

-- New: dedupe / cooldown tracking for verified saves (reduce UpdateAsync bursts)
local lastVerifiedSaveTs = {}            -- [userId] = os.clock() of last successful verified save
local VERIFIED_SAVE_DEDUP_WINDOW = 5     -- seconds to dedupe verified saves per-user

local function debug(...)
	if CONFIG.Debug then
		print("[PlayerProfileService][DEBUG]", ...)
	end
end

local function info(...)
	print("[PlayerProfileService][INFO]", ...)
end

local function log(...)
	debug(...)
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
		local copiedKey = (type(k) == "table") and deepCopy(k, seen) or k
		t[copiedKey] = deepCopy(val, seen)
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
			coins     = 500,
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
		meta          = {},
		persistentId  = nil, -- assigned on loadProfile
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

local function generatePersistentId(userId)
	local guid = HttpService:GenerateGUID(false)
	return guid
end

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

local function stripSelfArg(...)
	local args = { ... }
	if args[1] == PlayerProfileService then
		table.remove(args, 1)
	end
	return table.unpack(args)
end

local scheduleSave

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
		debug(("sanitizeInventoryOnLoad: sanitized inventory for userId=%s"):format(tostring(userId)))
	end
	return changed
end

local function sanitizeForDatastore(obj)
	local removedSomething = false
	local visitedNodes = 0

	local function isFiniteNumber(n)
		return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
	end

	local function sanitizeString(s)
		if type(s) ~= "string" then return tostring(s) end
		local out = {}
		for i = 1, #s do
			local b = string.byte(s, i)
			if b == 9 or b == 10 or b == 13 or b >= 32 then
				out[#out+1] = string.char(b)
			else
				removedSomething = true
			end
		end
		return table.concat(out)
	end

	local function walk(value, depth, seen)
		depth = depth or 0
		seen = seen or {}
		if visitedNodes > MAX_SANITIZE_NODES then
			removedSomething = true
			return nil
		end
		visitedNodes = visitedNodes + 1
		local t = type(value)
		if t == "nil" or t == "boolean" then
			return value
		end
		if t == "number" then
			if isFiniteNumber(value) then
				return value
			else
				removedSomething = true
				return 0
			end
		end
		if t == "string" then
			return sanitizeString(value)
		end
		if t == "table" then
			if depth >= MAX_SANITIZE_DEPTH then
				removedSomething = true
				local ok, s = pcall(function() return HttpService:JSONEncode(value) end)
				if ok and s and #s < 200 then return s end
				return "[table:depth-limited]"
			end
			if seen[value] then
				removedSomething = true
				return nil
			end
			seen[value] = true
			local out = {}
			for k, v in pairs(value) do
				local vv = walk(v, depth + 1, seen)
				if vv ~= nil then
					if type(k) == "number" and k == math.floor(k) and k >= 1 then
						out[k] = vv
					else
						out[tostring(k)] = vv
					end
				else
					removedSomething = true
				end
				if visitedNodes > MAX_SANITIZE_NODES then
					removedSomething = true
					break
				end
			end
			return out
		end
		if typeof then
			local okty, ty = pcall(function() return typeof(value) end)
			if okty and ty then
				if ty == "Color3" then
					removedSomething = true
					return string.format("#%02X%02X%02X", math.floor(value.R*255+0.5), math.floor(value.G*255+0.5), math.floor(value.B*255+0.5))
				end
				if ty == "Vector3" then
					removedSomething = true
					return { x = value.X, y = value.Y, z = value.Z }
				end
				if ty == "CFrame" then
					removedSomething = true
					local p = value.Position
					return { x = p.X, y = p.Y, z = p.Z }
				end
				if ty == "Instance" then
					local ok, s = pcall(function() return value:GetFullName() end)
					removedSomething = true
					if ok and s then return "[Instance]"..s end
					return "[Instance]"..tostring(value)
				end
			end
		end
		local ok, s = pcall(function() return tostring(value) end)
		if ok then
			removedSomething = true
			return s
		end
		removedSomething = true
		return nil
	end

	local ok, cleaned = pcall(function() return walk(obj, 0, {}) end)
	if not ok or cleaned == nil then
		removedSomething = true
		cleaned = {
			schemaVersion = (obj and obj.schemaVersion) or 1,
			dataVersion = (obj and obj.dataVersion) or 1,
			userId = (obj and obj.userId) or nil,
			core = { coins = (obj and obj.core and obj.core.coins) or 0 },
			inventory = { worldSlimes = {}, worldEggs = {}, eggTools = {}, foodTools = {}, capturedSlimes = {} },
			extra = {},
		}
	end
	return cleaned, removedSomething
end

local function summarizeProfile(profile)
	if not profile or type(profile) ~= "table" then
		return { coins = 0, captured = 0, world = 0 }
	end
	local coins = 0
	pcall(function() coins = tonumber((profile.core and profile.core.coins) or 0) or 0 end)
	local captured = 0
	pcall(function() captured = (profile.inventory and profile.inventory.capturedSlimes and #profile.inventory.capturedSlimes) or 0 end)
	local world = 0
	pcall(function() world = (profile.inventory and profile.inventory.worldSlimes and #profile.inventory.worldSlimes) or 0 end)
	return { coins = coins, captured = captured, world = world }
end

local function safeReadStoredProfile(userId)
	local key = keyFor(userId)
	local stored = nil
	local ok, res = pcall(function() return store:GetAsync(key) end)
	if ok and type(res) == "table" then
		return res
	end
	return nil
end

local function validateBeforeSave(userId, newProfile, reason)
	reason = tostring(reason or "")
	if reason:find(ALLOW_DESTRUCTIVE_TOKEN, 1, true) then
		return true, "override-token"
	end
	local stored = safeReadStoredProfile(userId)
	if stored and type(stored) == "table" then
		stored = ensureKeys(stored, userId)
		local storedSummary = summarizeProfile(stored)
		local newSummary = summarizeProfile(newProfile)
		if storedSummary.coins > 0 and newSummary.coins == 0 then
			return false, "coins-zeroed-stored"
		end
		if storedSummary.coins > 0 and newSummary.coins < math.max(0, math.floor(storedSummary.coins * 0.1)) then
			return false, "coins-large-drop-stored"
		end
		if storedSummary.captured > 0 and newSummary.captured == 0 then
			if newSummary.coins >= storedSummary.coins then
				return true, "ok-sale-captured"
			end
			return false, "captured-zeroed-stored"
		end
		if storedSummary.world > 0 and newSummary.world == 0 then
			if newSummary.coins >= storedSummary.coins then
				return true, "ok-sale-world"
			end
			return false, "world-zeroed-stored"
		end
		return true, "ok-stored"
	end
	local lastSnapshot = nil
	pcall(function()
		local prof = profileCache[userId]
		if prof and prof.meta and prof.meta.__lastSavedSnapshot then
			lastSnapshot = prof.meta.__lastSavedSnapshot
		end
	end)
	if not lastSnapshot then
		return true, "no-last-snapshot"
	end
	local oldS = summarizeProfile(lastSnapshot)
	local newS = summarizeProfile(newProfile)
	if oldS.coins > 0 and newS.coins == 0 then
		return false, "coins-zeroed"
	end
	if oldS.coins > 0 and newS.coins < math.max(0, math.floor(oldS.coins * 0.1)) then
		return false, "coins-large-drop"
	end
	if oldS.captured > 0 and newS.captured == 0 then
		if newS.coins >= oldS.coins then
			return true, "ok-sale-captured"
		end
		return false, "captured-zeroed"
	end
	if oldS.world > 0 and newS.world == 0 then
		if newS.coins >= oldS.coins then
			return true, "ok-sale-world"
		end
		return false, "world-zeroed"
	end
	return true, "ok"
end

local function appendAuditRecord(tag, payloadTable)
	local ok, js = pcall(function() return HttpService:JSONEncode(payloadTable) end)
	if not ok then
		js = tostring(payloadTable)
	end
	local folder = ServerStorage:FindFirstChild("PPS_Audit")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "PPS_Audit"
		folder.Parent = ServerStorage
	end
	local name = ("%s_%d"):format(tag or "audit", os.time())
	local sv = Instance.new("StringValue")
	sv.Name = name
	sv.Value = js
	sv.Parent = folder
	local children = folder:GetChildren()
	if #children > 500 then
		table.sort(children, function(a,b) return a.Name < b.Name end)
		for i = 1, #children - 500 do
			pcall(function() children[i]:Destroy() end)
		end
	end
end

local function loadProfile(userId)
	local key = keyFor(userId)
	local data = nil
	local lastErr = nil
	for attempt = 1, 3 do
		local ok, res = pcall(function()
			return store:GetAsync(key)
		end)
		if ok then
			data = res
			break
		else
			lastErr = res
			task.wait(0.08 * attempt)
		end
	end
	if type(data) ~= "table" then
		if lastErr then
			debug(("GetAsync attempts failed for userId=%s; treating as no profile present (datastore err=%s)"):format(tostring(userId), tostring(lastErr)))
		else
			debug("No profile found for userId", userId, "- creating default.")
		end
		data = defaultProfile(userId)
	end
	data = ensureKeys(data, userId)
	pcall(function() sanitizeInventoryOnLoad(data, userId) end)
	pcall(function()
		data.meta = data.meta or {}
		data.meta.__lastSavedSnapshot = deepCopy(data)
	end)
	if not data.persistentId or type(data.persistentId) ~= "string" then
		local pid = generatePersistentId(userId)
		data.persistentId = pid
		scheduleSave(userId, "AssignPersistentId")
		debug(("[PPS][PersistentId] Assigned persistentId=%s to userId=%s (will persist)"):format(tostring(pid), tostring(userId)))
	end
	profileCache[userId] = data
	debug(string.format("[PPS][DEBUG] loaded profile %s coins=%s eggTools=%d foodTools=%d capturedSlimes=%d worldSlimes=%d worldEggs=%d dataVersion=%s persistentId=%s",
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

local function saveProfileInternal(userId, reason)
	if not userId then return false, "no userId" end
	if saveLocks[userId] then
		return false, "locked"
	end
	saveRequestTimestamps[userId] = saveRequestTimestamps[userId] or {}
	local nowTs = os.clock()
	table.insert(saveRequestTimestamps[userId], nowTs)
	while #saveRequestTimestamps[userId] > 0 and (nowTs - saveRequestTimestamps[userId][1]) > SAVE_RATE_WINDOW do
		table.remove(saveRequestTimestamps[userId], 1)
	end
	if #saveRequestTimestamps[userId] > SAVE_RATE_LIMIT then
		debug(("Throttling saves for userId=%s because of high rate (%d requests in %.2fs)"):format(tostring(userId), #saveRequestTimestamps[userId], SAVE_RATE_WINDOW))
		return false, "throttled"
	end
	local last = lastSaveResult[userId]
	if last and last.success == false and (os.clock() - last.ts) < SUSPICIOUS_SAVE_BLOCK_WINDOW then
		debug(("Recent save failure for userId=%s; deferring non-verified save (reason=%s)"):format(tostring(userId), tostring(reason)))
		return false, "recent-failure"
	end
	saveLocks[userId] = true
	local profile = profileCache[userId]
	if not profile then
		saveLocks[userId] = nil
		return false, "no profile"
	end
	local allow, vreason = validateBeforeSave(userId, profile, reason)
	if not allow then
		saveLocks[userId] = nil
		local summary = summarizeProfile(profile)
		local trace = ""
		pcall(function()
			if LUA_DEBUG and type(LUA_DEBUG.traceback) == "function" then
				trace = LUA_DEBUG.traceback()
			else
				trace = "no-debug-traceback-available"
			end
		end)
		if PRODUCTION_SAFE_MODE then
			local audit = {
				ts = os.time(),
				userId = userId,
				reason = reason or "unspecified",
				validation = vreason,
				profileSummary = summary,
				traceback = trace,
			}
			appendAuditRecord("blocked_save", audit)
			warn(("Prevented suspicious SetAsync save for userId=%s reason=%s validation=%s (audit recorded)"):format(tostring(userId), tostring(reason or "unspecified"), tostring(vreason)))
			debug(("[PPS][BLOCKED] user=%s reason=%s validation=%s profileSummary=%s"):format(tostring(userId), tostring(reason or "unspecified"), tostring(vreason), tostring(HttpService:JSONEncode(summary))))
		else
			warn(("Prevented suspicious SetAsync save for userId=%s reason=%s validation=%s"):format(tostring(userId), tostring(reason or "unspecified"), tostring(vreason)))
			debug(("[PPS][BLOCKED] user=%s reason=%s validation=%s profileSummary=%s"):format(tostring(userId), tostring(reason or "unspecified"), tostring(vreason), tostring(HttpService:JSONEncode(summary))))
		end
		return false, "blocked_suspicious_save"
	end
	profile.updatedAt = os.time()
	profile.dataVersion = (profile.dataVersion or 1) + 1
	local key = keyFor(userId)
	debug(string.format("[PPS][DEBUG] SetAsync save userId=%s coins=%s reason=%s dataVersion=%s persistentId=%s",
		tostring(userId),
		tostring((profile.core and profile.core.coins) or 0),
		tostring(reason or "unspecified"),
		tostring(profile.dataVersion or "?"),
		tostring(profile.persistentId or "nil")
		))
	local sanitized, removed = sanitizeForDatastore(profile)
	if not sanitized or type(sanitized) ~= "table" then
		local trace = ""
		pcall(function()
			if LUA_DEBUG and type(LUA_DEBUG.traceback) == "function" then
				trace = LUA_DEBUG.traceback()
			else
				trace = "no-debug-traceback-available"
			end
		end)
		appendAuditRecord("sanitize_failed_setasync", { ts = os.time(), userId = userId, reason = reason or "", profileSummary = summarizeProfile(profile), traceback = trace })
		saveLocks[userId] = nil
		return false, "sanitize_failed"
	end
	if removed then
		debug(("sanitizeForDatastore: removed or converted unsupported fields prior to SetAsync for userId=%s"):format(tostring(userId)))
	end
	local ok, res = pcall(function()
		store:SetAsync(key, sanitized)
	end)
	if ok then
		dirtyPlayers[userId] = nil
		profile.meta = profile.meta or {}
		profile.meta.__lastSavedSnapshot = deepCopy(profile)
		fireSaveComplete(userId, true)
		saveLocks[userId] = nil
		lastSaveResult[userId] = { ts = os.clock(), success = true }
		debug("Saved profile for userId", userId, "reason:", reason or "unspecified")
		return true
	else
		fireSaveComplete(userId, false)
		saveLocks[userId] = nil
		lastSaveResult[userId] = { ts = os.clock(), success = false }
		warn("SetAsync Save FAILED for userId", userId, "err:", res)
		local trace = ""
		pcall(function()
			if LUA_DEBUG and type(LUA_DEBUG.traceback) == "function" then
				trace = LUA_DEBUG.traceback()
			else
				trace = "no-debug-traceback-available"
			end
		end)
		appendAuditRecord("save_failed", { ts = os.time(), userId = userId, reason = reason or "", err = tostring(res), profileSummary = summarizeProfile(profile), traceback = trace })
		return false, res
	end
end

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

local function performVerifiedWrite(userId, snapshot, attempt)
	local key = keyFor(userId)
	local preSanitized, preRemoved = sanitizeForDatastore(snapshot)
	if not preSanitized or type(preSanitized) ~= "table" then
		appendAuditRecord("pre_sanitize_failed", { ts = os.time(), userId = userId, attempt = attempt, snapshot_summary = summarizeProfile(snapshot) })
		debug("performVerifiedWrite: pre-sanitization failed; aborting update for userId", userId)
		return false
	end
	local okUpdate, errUpdate = pcall(function()
		store:UpdateAsync(key, function(old)
			if PPS_DEBUG_UPDATEASYNC then
				local okDiag, payload = pcall(function()
					local function safeExtractWorld(obj)
						if type(obj) ~= "table" or type(obj.inventory) ~= "table" then return nil end
						return obj.inventory.worldSlimes
					end
					return HttpService:JSONEncode({
						userId = tostring(userId),
						old_dataVersion = (old and old.dataVersion) or nil,
						snap_dataVersion = (snapshot and snapshot.dataVersion) or nil,
						old_worldSlimes = safeExtractWorld(old),
						snapshot_worldSlimes = safeExtractWorld(snapshot),
					})
				end)
				if okDiag and payload then
					debug("[PPS][DEBUG][UpdateAsync] merge compare: "..tostring(payload))
				else
					debug("[PPS][DEBUG][UpdateAsync] could not JSONEncode merge compare")
				end
			end
			if type(old) == "table" and tonumber(old.dataVersion) and tonumber(snapshot.dataVersion) then
				if tonumber(old.dataVersion) >= tonumber(snapshot.dataVersion) then
					for k, v in pairs(snapshot) do
						if v ~= nil then
							if type(v) == "table" then
								if type(old[k]) ~= "table" then
									old[k] = deepCopy(v)
								end
							else
								if old[k] == nil then old[k] = v end
							end
						end
					end
					old.inventory = old.inventory or {}
					local oldWS = old.inventory.worldSlimes or {}
					local snapWS = (snapshot and snapshot.inventory and snapshot.inventory.worldSlimes) or {}
					local byId = {}
					for _, entry in ipairs(oldWS) do
						if type(entry) == "table" then
							local id = entry.SlimeId or entry.id or entry.Id
							if id then byId[tostring(id)] = entry end
						end
					end
					for _, sentry in ipairs(snapWS) do
						if type(sentry) == "table" then
							local sid = sentry.SlimeId or sentry.id or sentry.Id
							if sid then
								local existing = byId[tostring(sid)]
								if existing then
									if sentry.GrowthProgress ~= nil then existing.GrowthProgress = sentry.GrowthProgress end
									if sentry.PersistedGrowthProgress ~= nil then existing.PersistedGrowthProgress = sentry.PersistedGrowthProgress end
									if sentry.LastGrowthUpdate ~= nil then existing.LastGrowthUpdate = sentry.LastGrowthUpdate end
									if sentry.Timestamp ~= nil then existing.Timestamp = sentry.Timestamp end
								else
									table.insert(oldWS, deepCopy(sentry))
								end
							else
								table.insert(oldWS, deepCopy(sentry))
							end
						else
							table.insert(oldWS, sentry)
						end
					end
					old.inventory.worldSlimes = oldWS
					local cleaned, removed = sanitizeForDatastore(old)
					if not cleaned or type(cleaned) ~= "table" then
						return {
							schemaVersion = old.schemaVersion or 1,
							dataVersion = old.dataVersion or 1,
							userId = old.userId,
							core = { coins = (old.core and old.core.coins) or 0 },
							inventory = { worldSlimes = old.inventory.worldSlimes or {}, worldEggs = old.inventory.worldEggs or {} },
							extra = old.extra or {},
						}
					end
					return cleaned
				end
			end
			local merged = {}
			if type(old) == "table" then
				for k,v in pairs(old) do merged[k] = v end
			end
			if type(snapshot) == "table" then
				for k,v in pairs(snapshot) do merged[k] = v end
			end
			local cleaned, removed = sanitizeForDatastore(merged)
			if not cleaned or type(cleaned) ~= "table" then
				return {
					schemaVersion = merged.schemaVersion or 1,
					dataVersion = merged.dataVersion or 1,
					userId = merged.userId,
					core = { coins = (merged.core and merged.core.coins) or 0 },
					inventory = { worldSlimes = (merged.inventory and merged.inventory.worldSlimes) or {}, worldEggs = (merged.inventory and merged.inventory.worldEggs) or {} },
					extra = merged.extra or {},
				}
			end
			return cleaned
		end)
	end)
	if not okUpdate then
		debug(string.format("Attempt %d UpdateAsync failed userId=%d err=%s", attempt, userId, tostring(errUpdate)))
		return false
	end
	task.wait(EXIT_SAVE_VERIFY_DELAY)
	local stored, okRead, errRead
	okRead, errRead = pcall(function()
		stored = store:GetAsync(key)
	end)
	if not okRead or type(stored) ~= "table" then
		debug(string.format("Attempt %d verify failed userId=%d readErr=%s", attempt, userId, tostring(errRead)))
		return false
	end
	local sv = stored.dataVersion or -1
	local pv = snapshot.dataVersion or -1
	if sv < pv then
		debug(string.format("Attempt %d version mismatch userId=%d stored=%s expected>=%s", attempt, userId, tostring(sv), tostring(pv)))
		return false
	end
	debug(string.format("Attempt %d SUCCESS userId=%d dataVersion=%s", attempt, userId, tostring(sv)))
	return true
end

function PlayerProfileService.GetProfile(...)
	local playerOrId = stripSelfArg(...)
	local userId = resolveUserId(playerOrId)
	if not userId then
		if type(playerOrId) == "string" then
			userId = resolveUserId(playerOrId, false)
		end
	end
	if not userId then
		debug("GetProfile called with invalid playerOrId:", tostring(playerOrId))
		return nil
	end
	if profileCache[userId] then return profileCache[userId] end
	return loadProfile(userId)
end
PlayerProfileService.Get = PlayerProfileService.GetProfile

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

function PlayerProfileService.GetOrAssignPersistentId(...)
	local playerOrProfile = stripSelfArg(...)
	local userId = resolveUserId(playerOrProfile)
	if not userId then
		if type(playerOrProfile) == "table" and (playerOrProfile.userId or playerOrProfile.UserId) then
			userId = tonumber(playerOrProfile.userId or playerOrProfile.UserId)
		end
	end
	if not userId then return nil end
	local profile = PlayerProfileService.GetProfile(userId)
	if not profile then return nil end
	if type(playerOrProfile) == "table" and playerOrProfile.inventory and playerOrProfile ~= profile then
	end
	if profile.persistentId and type(profile.persistentId) == "string" then
		return profile.persistentId
	end
	local pid = generatePersistentId(userId or profile.userId)
	profile.persistentId = pid
	scheduleSave(userId, "AssignPersistentId")
	debug(("[PPS][PersistentId] Assigned persistentId=%s to userId=%s via GetOrAssign"):format(tostring(pid), tostring(userId)))
	return pid
end

local function markDirty(userId)
	if not userId then return end
	dirtyPlayers[userId] = true
	scheduleSave(userId, "DirtyMark")
end

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

function PlayerProfileService.SetCoins(playerOrId, amount, opts)
	local userId = resolveUserId(playerOrId)
	if not userId then
		debug("SetCoins: invalid playerOrId:", tostring(playerOrId))
		return false, "no user"
	end
	local profile = PlayerProfileService.GetProfile(userId)
	if not profile then
		debug("SetCoins: no profile for userId", tostring(userId))
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
		debug("IncrementCoins: invalid playerOrId:", tostring(playerOrId))
		return false, "no user"
	end
	local profile = PlayerProfileService.GetProfile(userId)
	if not profile then
		debug("IncrementCoins: no profile for userId", tostring(userId))
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

function PlayerProfileService.AddInventoryItem(playerOrId, category, itemData)
	local userId = resolveUserId(playerOrId)
	if not userId then
		debug("AddInventoryItem: invalid playerOrId:", tostring(playerOrId))
		return false, "no user"
	end
	local profile = PlayerProfileService.GetProfile(userId)
	if not profile then
		debug("AddInventoryItem: no profile for userId", tostring(userId))
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
			debug("AddInventoryItem: worldSlimes items require an id; rejecting malformed item for userId", userId)
			return false, "missing id"
		end
	elseif category == "worldEggs" then
		if not cid then
			debug("AddInventoryItem: worldEggs items require an id; rejecting malformed item for userId", userId)
			return false, "missing id"
		end
	elseif category == "capturedSlimes" then
		if not cid then
			debug("AddInventoryItem: capturedSlimes items require ToolUniqueId/ToolUid or SlimeId; rejecting malformed item for userId", userId)
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
		debug("RemoveInventoryItem: invalid playerOrId:", tostring(playerOrId))
		return false, "no user"
	end
	local profile = PlayerProfileService.GetProfile(userId)
	if not profile then
		debug("RemoveInventoryItem: no profile for userId", tostring(userId))
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

function PlayerProfileService.ApplySale(...)
	local playerOrId, soldSlimeIds, soldToolUids, payout, reason = stripSelfArg(...)
	local userId = resolveUserId(playerOrId)
	if not userId then return false, "no user" end
	payout = tonumber(payout) or 0
	soldSlimeIds = type(soldSlimeIds) == "table" and soldSlimeIds or {}
	soldToolUids = type(soldToolUids) == "table" and soldToolUids or {}
	reason = tostring(reason or "ApplySale")
	local profile = PlayerProfileService.GetProfile(userId)
	if not profile then return false, "no profile" end
	profile.core = profile.core or {}
	profile.core.coins = (profile.core.coins or 0) + payout
	local function removeCapturedByUid(profileTbl, uid)
		if not profileTbl or not profileTbl.inventory or not profileTbl.inventory.capturedSlimes then return end
		local list = profileTbl.inventory.capturedSlimes
		for i = #list, 1, -1 do
			local entry = list[i]
			if entry then
				if tostring(entry.ToolUniqueId) == tostring(uid) or tostring(entry.ToolUid) == tostring(uid) or tostring(entry.ToolId) == tostring(uid) or tostring(entry.SlimeId) == tostring(uid) then
					table.remove(list, i)
				end
			end
		end
	end
	local function removeWorldById(profileTbl, sid)
		if not profileTbl or not profileTbl.inventory or not profileTbl.inventory.worldSlimes then return end
		local list = profileTbl.inventory.worldSlimes
		for i = #list, 1, -1 do
			local entry = list[i]
			if entry and (tostring(entry.SlimeId or entry.id or entry.Id) == tostring(sid)) then
				table.remove(list, i)
			end
		end
	end
	for _, uid in ipairs(soldToolUids) do
		pcall(removeCapturedByUid, profile, uid)
	end
	for _, sid in ipairs(soldSlimeIds) do
		pcall(removeWorldById, profile, sid)
	end
	markDirty(userId)
	local ok = PlayerProfileService.ForceFullSaveNow(playerOrId, reason or "ApplySale_Verified")
	if not ok then
		PlayerProfileService.SaveNow(playerOrId, reason or "ApplySale_AsyncFallback")
		appendAuditRecord("apply_sale_persist_failed", { ts = os.time(), userId = userId, payout = payout, soldSlimeIds = soldSlimeIds, soldToolUids = soldToolUids, reason = reason })
		return false, "persist_failed"
	end
	return true, { coins = profile.core.coins, removedWorld = #soldSlimeIds, removedCaptured = #soldToolUids }
end

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

function PlayerProfileService.SaveNow(...)
	local playerOrId, reason = stripSelfArg(...)
	local userId = resolveUserId(playerOrId)
	if not userId then
		if type(playerOrId) == "table" and playerOrId.userId then userId = tonumber(playerOrId.userId) end
	end
	if not userId then
		debug("SaveNow requested with invalid playerOrId:", tostring(playerOrId))
		return
	end
	debug("SaveNow requested for userId", userId, "reason:", reason or "Manual (async)")
	scheduleSave(userId, reason or "Manual")
end

function PlayerProfileService.ForceFullSaveNow(...)
	local playerOrId, reason = stripSelfArg(...)
	local opts = nil
	-- accepted call forms may pass an opts table as third arg (backwards compatible)
	if select("#", ...) >= 3 then
		local maybeOpts = select(3, ...)
		if type(maybeOpts) == "table" then opts = maybeOpts end
	end

	local userId = resolveUserId(playerOrId)
	if not userId and type(playerOrId) == "table" and playerOrId.userId then userId = tonumber(playerOrId.userId) end
	if not userId then
		debug("ForceFullSaveNow invoked with invalid playerOrId:", tostring(playerOrId))
		return false
	end

	info("ForceFullSaveNow invoked for userId", userId, "reason:", reason or "ForceFullSave")

	-- If a verified save succeeded very recently, skip duplicate verified save attempts.
	local now = os.clock()
	local lastOk = lastVerifiedSaveTs[userId]
	if lastOk and (now - lastOk) <= VERIFIED_SAVE_DEDUP_WINDOW then
		debug(("ForceFullSaveNow: skipping duplicate verified save for userId=%s within dedupe window (%.2fs elapsed)"):format(tostring(userId), now - lastOk))
		-- ensure meta stamp exists and return success to callers expecting a synchronous true
		local prof = profileCache[userId]
		if prof then
			prof.meta = prof.meta or {}
			prof.meta.__lastSavedSnapshot = deepCopy(prof)
		end
		fireSaveComplete(userId, true)
		return true
	end

	-- Short wait if another save in progress but don't block too long
	if saveLocks[userId] then
		local waitStart = os.clock()
		while saveLocks[userId] and (os.clock() - waitStart) < 1.0 do
			task.wait(0.05)
		end
		if saveLocks[userId] then
			debug("ForceFullSaveNow aborted: another save in progress for userId", userId)
			-- schedule a non-verified save and return false to avoid blocking callers during shutdown
			scheduleSave(userId, reason or "ForceFullSave_EarlyAbort")
			return false
		end
	end

	-- snapshot current profile
	local snapshot = deepCopy(profileCache[userId] or defaultProfile(userId))
	snapshot.updatedAt = os.time()
	snapshot.dataVersion = (snapshot.dataVersion or 1) + 1

	-- validate
	local allow, vreason = validateBeforeSave(userId, snapshot, reason)
	if not allow then
		local trace = ""
		pcall(function()
			if LUA_DEBUG and type(LUA_DEBUG.traceback) == "function" then
				trace = LUA_DEBUG.traceback()
			else
				trace = "no-debug-traceback-available"
			end
		end)
		local audit = { ts = os.time(), userId = userId, reason = reason or "unspecified", validation = vreason, profileSummary = summarizeProfile(snapshot), traceback = trace }
		appendAuditRecord("blocked_verified_save", audit)
		warn(("Prevented suspicious ForceFullSaveNow for userId=%s reason=%s validation=%s (audit recorded)"):format(tostring(userId), tostring(reason or "unspecified"), tostring(vreason)))
		debug("[PPS][BLOCKED VERIFIED TRACEBACK]", trace)
		return false
	end

	-- If we're being called from the InventoryService_VerifiedFallback (finalization flow),
	-- use a short/fail-fast strategy: attempt a single verified write, and if it fails schedule an async save and return.
	local isShutdownFallback = false
	if type(reason) == "string" and reason:find("InventoryService_VerifiedFallback", 1, true) then
		isShutdownFallback = true
	end

	saveLocks[userId] = true
	local startT = os.clock()
	local okOverall = false

	if isShutdownFallback then
		-- quick single-attempt, fail-fast path
		local ok = false
		pcall(function()
			ok = performVerifiedWrite(userId, snapshot, 1)
		end)
		if ok then
			okOverall = true
			lastVerifiedSaveTs[userId] = os.clock()
		else
			-- schedule async save and return quickly; don't block longer during shutdown
			scheduleSave(userId, "ForceFullSave_ScheduleAfterFallback")
			okOverall = false
		end
	else
		-- normal path (preserve original retry behavior but slightly shortened to avoid long blocking)
		local attempts = EXIT_SAVE_ATTEMPTS or 3
		local backoff = EXIT_SAVE_BACKOFF or 0.4
		for attempt = 1, attempts do
			local ok = false
			pcall(function() ok = performVerifiedWrite(userId, snapshot, attempt) end)
			if ok then
				okOverall = true
				lastVerifiedSaveTs[userId] = os.clock()
				break
			else
				-- if we're late in shutdown (Player removed) or many datastore queue warnings seen, don't spin too long
				if attempt < attempts then
					task.wait(backoff * attempt)
				end
			end
		end
	end

	saveLocks[userId] = nil

	if okOverall then
		local prof = profileCache[userId]
		if prof then
			prof.meta = prof.meta or {}
			prof.meta.__lastSavedSnapshot = deepCopy(prof)
		end
		lastSaveResult[userId] = { ts = os.clock(), success = true }
		fireSaveComplete(userId, true)
		debug(("ForceFullSaveNow succeeded for userId=%s (duration=%.2fs)"):format(tostring(userId), os.clock() - startT))
		return true
	else
		lastSaveResult[userId] = { ts = os.clock(), success = false }
		fireSaveComplete(userId, false)
		appendAuditRecord("verified_save_failed", { ts = os.time(), userId = userId, reason = reason or "", attempts = EXIT_SAVE_ATTEMPTS })
		warn(("ForceFullSaveNow failed for userId=%s after attempts; scheduled async save"):format(tostring(userId)))
		-- Ensure a fallback async save is scheduled so we don't lose data
		scheduleSave(userId, "ForceFullSave_FallbackScheduled")
		return false
	end
end

task.spawn(function()
	while true do
		task.wait(PERIODIC_FLUSH_INTERVAL)
		for uid, _ in pairs(dirtyPlayers) do
			local prof = profileCache[uid]
			if prof then
				scheduleSave(uid, "PeriodicFlush")
			end
		end
	end
end)

PlayerProfileService.WaitForSaveComplete = WaitForSaveComplete
PlayerProfileService.SaveNow = PlayerProfileService.SaveNow
PlayerProfileService.ForceFullSaveNow = PlayerProfileService.ForceFullSaveNow

return PlayerProfileService