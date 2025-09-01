-- InventoryService.lua
-- Version: v3.1.3-grand-unified-support (normalized field names & restore fixes)
-- Updated: Defensive merge behavior to avoid empty incoming snapshots clobbering existing inventory,
--          improved UpdateProfileInventory to merge into profile rather than wholesale replace,
--          added diagnostic logging when clears are suppressed.
-- - Prevent accidental deletion of worldEggs/worldSlimes/etc when an incoming restore payload contains
--   empty lists that are likely stale.
-- - Preserve existing non-empty service state when encountering non-final empty incoming lists.
-- - Merge into profile.inventory in UpdateProfileInventory to avoid replacing with an empty table.
-- - Integrates with SlimeCore (optional) to initialize Growth/Hunger services and to wire GrowthPersistenceService.
-----------------------------------------------------------------------

local InventoryService = {}
InventoryService.__Version = "v3.1.3-grand-unified-support"
InventoryService.Name = "InventoryService"

--------------------------------------------------
-- CONFIG
--------------------------------------------------
local DEBUG                       = true
local LOG_SERIALIZE_VERBOSE       = true
local LOG_EMPTY_SUPPRESS          = false
local AUTO_PERIODIC_SERIALIZE     = true
local SERIALIZE_INTERVAL_SECONDS  = 5
local MAX_ENTRIES_PER_FIELD       = 5000
local CORRELATION_TIMEOUT         = 3.0
local PLAYER_INVENTORY_FOLDER     = "Inventory"
local ENTRY_FOLDER_PREFIX         = "Entry_"
local ENTRY_DATA_VALUE_NAME       = "Data"

local GuardConfig = {
	InitialWindowSeconds = 15,
	Fields = {
		worldSlimes = { Watch=true, LargeDropFraction=0.80, IgnoreWhenCorrelated=true,  LogEveryChange=false },
		worldEggs   = { Watch=true, LargeDropFraction=0.85, IgnoreWhenCorrelated=false, LogEveryChange=false },
	}
}

--------------------------------------------------
-- SERVICES
--------------------------------------------------
local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local ServerScriptService = game:GetService("ServerScriptService")
local PlayerProfileService = require(ServerScriptService.Modules:WaitForChild("PlayerProfileService"))

--------------------------------------------------
-- Optional external integration (SlimeCore)
-- We'll attempt to require SlimeCore during Init() and wire GrowthPersistenceService,
-- start Growth/Hunger loops, and flush player slimes on remove.
--------------------------------------------------
local SlimeCore = nil
local SlimeCoreAvailable = false
local GrowthPersistenceOrchestrator = nil

--------------------------------------------------
-- REGISTRY
--------------------------------------------------
local Serializers = {}     -- canonical storage mapping name -> serializer (for external needs)
local SerializerMeta = {}  -- metadata cache mapping name -> { serializer=..., hasSerialize=bool, hasRestore=bool, isFunction=bool }

-- Register serializer and validate its shape early (one-time check + stored metadata)
function InventoryService.RegisterSerializer(name, serializer)
	Serializers[name] = serializer

	local isFunc = type(serializer) == "function"
	local isTable = type(serializer) == "table"
	local hasSerialize = false
	local hasRestore = false

	if isFunc then
		-- function-style serializer: treat as Serialize-capable (legacy)
		hasSerialize = true
		hasRestore = false
	elseif isTable then
		hasSerialize = type(serializer.Serialize) == "function"
		hasRestore  = type(serializer.Restore)  == "function"
	end

	SerializerMeta[name] = {
		serializer = serializer,
		hasSerialize = hasSerialize or false,
		hasRestore = hasRestore or false,
		isFunction = isFunc,
		_warned = false, -- internal flag if we emitted a registration warning
	}

	-- One-time info / warning
	if not SerializerMeta[name].hasSerialize and not SerializerMeta[name].hasRestore then
		SerializerMeta[name]._warned = true
		warn(("[InvSvc] Registered serializer '%s' does not expose Serialize/Restore and will be skipped at runtime. type=%s"):format(tostring(name), typeof(serializer)))
	else
		print(("[InvSvc] Registered serializer '%s' (Serialize=%s, Restore=%s)"):format(tostring(name), tostring(SerializerMeta[name].hasSerialize), tostring(SerializerMeta[name].hasRestore)))
	end
end

local function resolveSerializerName(serializer)
	-- prefer explicit Name property, fall back to table key lookup
	if type(serializer) == "table" and serializer.Name then
		return serializer.Name
	end
	for k,v in pairs(Serializers) do
		if v == serializer then return k end
	end
	return "UnknownSerializer"
end

--------------------------------------------------
-- LOG HELPERS
--------------------------------------------------
local function dprint(...)
	if DEBUG then
		print(("[InvSvc][%s]"):format(os.time()), ...)
	end
end
local function warnLog(...)
	warn(("[InvWarn][%s]"):format(os.time()), ...)
end

--------------------------------------------------
-- PLAYER STATE
--------------------------------------------------
local PlayerState = {}

local function ensureState(player)
	local st = PlayerState[player]
	if st then return st end
	st = {
		restoredAt = os.clock(),
		restoreCompleted = false,
		lastSerialize = 0,
		snapshotVersion = 0,
		fields = {},
		dirtyReasons = {},
		captureEvents = nil,
		lastProfileVersion = nil,
	}
	PlayerState[player] = st
	return st
end

local function markDirty(player, reason)
	local st = ensureState(player)
	st.dirtyReasons[reason or "Unknown"] = true
end

--------------------------------------------------
-- Helper: canonical field name mapping
--------------------------------------------------
-- InventoryService internal canonical field names (long form):
-- eggTools, foodTools, worldEggs, worldSlimes, capturedSlimes
-- Serializer (GrandInventorySerializer) field keys: et, ft, we, ws
local CANONICAL_FROM_SHORT = {
	et = "eggTools",
	ft = "foodTools",
	we = "worldEggs",
	ws = "worldSlimes",
}
local SHORT_FROM_CANONICAL = {
	eggTools = "et",
	foodTools = "ft",
	worldEggs = "we",
	worldSlimes = "ws",
}

local function canonicalizeFieldName(name)
	if not name then return nil end
	if CANONICAL_FROM_SHORT[name] then return CANONICAL_FROM_SHORT[name] end
	-- accept common long forms unchanged
	return name
end

--------------------------------------------------
-- HELPER: resolve player object from player or userId
--------------------------------------------------
local function resolvePlayer(playerOrId)
	if not playerOrId then return nil end
	if typeof and typeof(playerOrId) == "Instance" and playerOrId:IsA("Player") then
		return playerOrId
	end
	if type(playerOrId) == "table" and playerOrId.UserId then
		return playerOrId
	end
	if type(playerOrId) == "number" then
		return Players:GetPlayerByUserId(playerOrId)
	end
	if type(playerOrId) == "string" then
		return Players:FindFirstChild(playerOrId)
	end
	return nil
end

--------------------------------------------------
-- PLAYER PROFILE (safe helpers)
--------------------------------------------------
local function safe_get_profile_for_player(player)
	if not player then return nil end
	local tries = {
		function() return PlayerProfileService.GetProfile(player.UserId) end,
		function() return PlayerProfileService:GetProfile(player.UserId) end,
		function() return PlayerProfileService.GetProfile(tostring(player.UserId)) end,
		function() return PlayerProfileService.GetProfile(player) end,
	}
	for _,fn in ipairs(tries) do
		local ok, res = pcall(fn)
		if ok and type(res) == "table" then
			return res
		end
	end
	return nil
end

local function safe_get_profile_any(candidate)
	if not candidate then return nil end
	if type(candidate) == "table" and candidate.inventory ~= nil then
		return candidate
	end
	if type(candidate) == "table" and type(candidate.FindFirstChildOfClass) == "function" then
		return safe_get_profile_for_player(candidate)
	end
	if tonumber(candidate) then
		local uid = tonumber(candidate)
		local ok, res = pcall(function() return PlayerProfileService.GetProfile(uid) end)
		if ok and type(res) == "table" then return res end
	end
	if type(candidate) == "string" then
		local pl = Players:FindFirstChild(candidate)
		if pl then
			local p = safe_get_profile_for_player(pl)
			if p then return p end
		end
		local ok, res = pcall(function() return PlayerProfileService.GetProfile(candidate) end)
		if ok and type(res) == "table" then return res end
	end
	return nil
end

-- New helper: perform a short bounded wait for a player's profile (and persistentId) using PPS.WaitForProfile if available.
local function wait_for_profile(player, timeoutSeconds)
	if not player then return nil end
	timeoutSeconds = tonumber(timeoutSeconds) or 2
	-- quick check first
	local prof = safe_get_profile_for_player(player)
	if prof then return prof end
	-- prefer using PPS.WaitForProfile if available
	if type(PlayerProfileService.WaitForProfile) == "function" then
		local ok, p = pcall(function() return PlayerProfileService.WaitForProfile(player, timeoutSeconds) end)
		if ok and type(p) == "table" then return p end
	end
	-- fallback polling loop
	local deadline = os.clock() + timeoutSeconds
	while os.clock() < deadline do
		prof = safe_get_profile_for_player(player)
		if prof then return prof end
		task.wait(0.08)
	end
	return nil
end

--------------------------------------------------
-- PLAYER INVENTORY FOLDER MANAGEMENT
--------------------------------------------------
local function getInventoryFolder(player)
	local inv = player:FindFirstChild(PLAYER_INVENTORY_FOLDER)
	if not inv then
		inv = Instance.new("Folder")
		inv.Name = PLAYER_INVENTORY_FOLDER
		inv.Parent = player
		if DEBUG then
			print(("[InvFolder] Created root inventory folder for %s"):format(player.Name))
		end
	end
	return inv
end

local function ensureFieldFolder(player, fieldName)
	-- Always use canonical long field names here to avoid duplicate short/long folders
	fieldName = canonicalizeFieldName(fieldName) or fieldName

	local inv = getInventoryFolder(player)
	local fld = inv:FindFirstChild(fieldName)
	if not fld then
		fld = Instance.new("Folder")
		fld.Name = fieldName
		fld.Parent = inv
		local countVal = Instance.new("IntValue")
		countVal.Name = "Count"
		countVal.Value = 0
		countVal.Parent = fld
		if DEBUG then
			print(("[InvFolder] Created field folder %s/%s"):format(player.Name, fieldName))
		end
	end
	if not fld:FindFirstChild("Count") then
		local countVal = Instance.new("IntValue")
		countVal.Name = "Count"
		countVal.Value = 0
		countVal.Parent = fld
	end
	return fld
end

local function jsonEncodeSafe(value)
	local ok,res = pcall(function()
		return HttpService:JSONEncode(value)
	end)
	if ok then
		return res
	else
		return "{}"
	end
end

local function updateInventoryFolder(player, fieldName, list)
	-- ensure canonical fieldName
	fieldName = canonicalizeFieldName(fieldName) or fieldName

	local fld = ensureFieldFolder(player, fieldName)
	local countVal = fld:FindFirstChild("Count")
	if countVal then
		countVal.Value = #list
	end
	for _,child in ipairs(fld:GetChildren()) do
		if child:IsA("Folder") and child.Name:match("^"..ENTRY_FOLDER_PREFIX) then
			child:Destroy()
		end
	end
	for i,entry in ipairs(list) do
		local entryFolderName
		local id = type(entry)=="table" and (entry.Id or entry.id or entry.UID or entry.uid or entry.EggId or entry.SlimeId or entry.ToolId)
		if id then
			entryFolderName = ENTRY_FOLDER_PREFIX..tostring(id)
		else
			entryFolderName = ENTRY_FOLDER_PREFIX..tostring(i)
		end
		local ef = Instance.new("Folder")
		ef.Name = entryFolderName
		ef.Parent = fld
		local dataVal = Instance.new("StringValue")
		dataVal.Name = ENTRY_DATA_VALUE_NAME
		dataVal.Value = jsonEncodeSafe(entry)
		dataVal.Parent = ef
	end
	if DEBUG then
		print(("[InvFolder] Updated %s.%s entries=%d"):format(player.Name, fieldName, #list))
	end
end

--------------------------------------------------
-- CAPTURE CORRELATION
--------------------------------------------------
local function pruneCaptureEvents(st)
	if not st.captureEvents then return end
	local cutoff = os.clock() - CORRELATION_TIMEOUT
	for i=#st.captureEvents,1,-1 do
		if st.captureEvents[i].t < cutoff then table.remove(st.captureEvents, i) end
	end
	if #st.captureEvents == 0 then st.captureEvents = nil end
end

local function countRecentCaptures(st)
	pruneCaptureEvents(st)
	if not st.captureEvents then return 0 end
	local sum = 0
	for _,ev in ipairs(st.captureEvents) do sum = sum + ev.count end
	return sum
end

function InventoryService.NotifyCapture(player, slimeId)
	local st = ensureState(player)
	st.captureEvents = st.captureEvents or {}
	st.captureEvents[#st.captureEvents+1] = { t=os.clock(), count=1, slimeId=slimeId }
	if DEBUG then
		print(("[InvSvc][CaptureEvent] player=%s slimeId=%s recent=%d")
			:format(player.Name, tostring(slimeId), countRecentCaptures(st)))
	end
end

--------------------------------------------------
-- GUARD (non-blocking)
--------------------------------------------------
local function correlatedShrink(oldC,newC,st,field)
	if newC >= oldC then return false,"noShrink" end
	if field ~= "worldSlimes" then return false, "fieldNotCorrelated" end
	local captures = countRecentCaptures(st)
	if captures == 0 then return false, "noRecentCaptures" end
	local shrink = oldC - newC
	if shrink <= captures then
		return true, ("capturesExplain(%d<=%d)"):format(shrink, captures)
	end
	return false, ("capturesInsufficient(%d>%d)"):format(shrink, captures)
end

local function guardEval(player, st, field, oldC, newC)
	local cfg = GuardConfig.Fields[field]
	if not cfg or not cfg.Watch then return {accept=true, code="unwatched"} end
	local elapsed = os.clock() - st.restoredAt
	local inWindow = elapsed <= GuardConfig.InitialWindowSeconds
	if oldC == nil then return {accept=true, code="first"} end
	if newC == oldC then return {accept=true, code="noChange"} end
	local drop = oldC - newC
	if drop <= 0 then return {accept=true, code="growth"} end
	local corr,reason = correlatedShrink(oldC,newC,st,field)
	if corr and cfg.IgnoreWhenCorrelated then
		return {accept=true, code="corr:"..reason, correlated=true}
	end
	local large = oldC>0 and (drop / oldC) >= (cfg.LargeDropFraction or 0.9)
	if large and inWindow then
		return {accept=true, suspicious=true, code="largeEarlyDrop", old=oldC,new=newC,drop=drop}
	end
	return {accept=true, code="shrink", old=oldC,new=newC,drop=drop}
end

--------------------------------------------------
-- UTIL
--------------------------------------------------
local function clamp(list)
	if not list then return {} end
	if #list <= MAX_ENTRIES_PER_FIELD then return list end
	local t={}
	for i=1,MAX_ENTRIES_PER_FIELD do t[i]=list[i] end
	return t
end

--------------------------------------------------
-- Defensive merge helpers
--------------------------------------------------
-- Decide whether to preserve an existing non-empty list when incoming is empty.
-- This prevents stale/partial snapshots from clobbering authoritative in-memory state.
local function shouldPreserveExistingOnEmpty(existingList, incomingList)
	-- existingList: may be nil or table
	-- incomingList: may be nil or table
	if not existingList or #existingList == 0 then
		-- nothing to preserve
		return false
	end
	incomingList = incomingList or {}
	if #incomingList == 0 then
		-- incoming is empty but existing non-empty -> preserve
		return true
	end
	return false
end

-- Diagnostic helper when we suppressed a clear
local function logSuppressedClear(player, field)
	warnLog(("[InvMerge] Suppressed clearing of %s for %s because incoming snapshot was empty while existing state contained items"):format(field, player.Name))
	-- keep an easily searchable logline
end

--------------------------------------------------
-- SERIALIZE PLAYER (grand serializer aware)
--------------------------------------------------
local function buildBlob(player, st)
	local blob = { v=st.snapshotVersion, fields={} }
	for name,f in pairs(st.fields) do
		blob.fields[name] = { v=f.version, list=f.list, meta=f.meta }
	end
	return blob
end

local DebugFlags = nil
pcall(function() DebugFlags = require(script.Parent:WaitForChild("DebugFlags")) end)
local function invdbg(...)
	if DebugFlags and DebugFlags.EggDebug then
		print("[EggDbg][InvSvc]", ...)
	end
end

-- Wrapper to request a verified save (preferVerified true uses SaveNowAndWait to perform verified write).
local function requestVerifiedSave(playerOrId, timeoutSeconds)
	timeoutSeconds = tonumber(timeoutSeconds) or 3
	local ok, res = pcall(function()
		if type(PlayerProfileService.SaveNowAndWait) == "function" then
			return PlayerProfileService.SaveNowAndWait(playerOrId, timeoutSeconds, true)
		else
			if type(PlayerProfileService.ForceFullSaveNow) == "function" then
				return PlayerProfileService.ForceFullSaveNow(playerOrId, "InventoryService_VerifiedFallback")
			else
				PlayerProfileService.SaveNow(playerOrId, "InventoryService_VerifiedFallback")
				if type(PlayerProfileService.WaitForSaveComplete) == "function" then
					local done, success = PlayerProfileService.WaitForSaveComplete(playerOrId, timeoutSeconds)
					return done and success
				end
				return false
			end
		end
	end)
	if not ok then
		warnLog(("requestVerifiedSave: PlayerProfileService.SaveNowAndWait/ForceFullSaveNow call failed: %s"):format(tostring(res)))
		return false
	end
	return res and true or false
end

local function serializePlayer(player, reason, finalFlag)
	local st = PlayerState[player]; if not st then return end
	st.lastSerialize = os.clock()
	local correlationId = HttpService:GenerateGUID(false)
	local oldCounts = {}
	for name,f in pairs(st.fields) do
		oldCounts[name] = f.lastCount or 0
	end

	local anyChange = false

	-- Prefer the PlayerProfileService SerializeInventory adapter when available.
	local serializedPayload = nil
	local ok, err = pcall(function()
		if type(PlayerProfileService.SerializeInventory) == "function" then
			serializedPayload = PlayerProfileService.SerializeInventory(player, finalFlag)
		else
			-- fallback to direct registered serializer (GrandInventorySerializer)
			local meta = SerializerMeta["GrandInventorySerializer"]
			if meta and meta.hasSerialize then
				if meta.isFunction then
					serializedPayload = meta.serializer(player, finalFlag)
				else
					serializedPayload = meta.serializer:Serialize(player, finalFlag)
				end
			else
				-- fallback: iterate all serializers to build a combined payload (less efficient)
				serializedPayload = {}
				for name, metaEntry in pairs(SerializerMeta) do
					if metaEntry.hasSerialize then
						local ok2, result = pcall(function()
							if metaEntry.isFunction then
								return metaEntry.serializer(player, finalFlag)
							else
								return metaEntry.serializer:Serialize(player, finalFlag)
							end
						end)
						if ok2 and type(result) == "table" then
							for fName, list in pairs(result) do
								serializedPayload[fName] = list
							end
						end
					end
				end
			end
		end
	end)
	if not ok then
		warnLog("Serialize error: "..tostring(err))
		return
	end

	local multiRes = serializedPayload or {}

	dprint(("Serialize[%s] produced payload for player=%s reason=%s"):format(correlationId, player.Name, tostring(reason)))

	for field,list in pairs(multiRes or {}) do
		-- convert serializer short names to canonical long names for internal state
		local canonical = canonicalizeFieldName(field) or field
		list = clamp(list)
		local count = #list
		local old = (PlayerState[player] and PlayerState[player].fields[canonical] and PlayerState[player].fields[canonical].lastCount) or 0
		local guardR = (count ~= old) and guardEval(player, PlayerState[player], canonical, old, count) or {accept=true, code="noChange"}
		local fld = PlayerState[player].fields[canonical] or { list={}, lastCount=0, version=0, meta=nil }
		fld.list = list
		fld.lastCount = count
		fld.version = (fld.version or 0) + 1
		if guardR and guardR.suspicious then
			fld.meta = {
				suspect = true,
				code = guardR.code,
				old = guardR.old,
				new = guardR.new,
				drop = guardR.drop,
				ts = os.clock(),
			}
		else
			fld.meta = nil
		end
		PlayerState[player].fields[canonical] = fld
		updateInventoryFolder(player, canonical, list)
		if LOG_SERIALIZE_VERBOSE and (count>0 or not LOG_EMPTY_SUPPRESS) then
			print(("[InvSerialize][%s] %s field=%s count=%d (raw=%d)%s")
				:format(correlationId, player.Name, canonical, count, count, finalFlag and " (FINAL)" or ""))
		end
		if guardR and guardR.suspicious then
			print(("[InvGuard][%s][SUSPECT] %s field=%s old=%d new=%d code=%s drop=%d")
				:format(correlationId, player.Name, canonical, guardR.old or -1, guardR.new or -1, guardR.code, guardR.drop or -1))
		elseif guardR and guardR.correlated then
			print(("[InvGuard][%s][Correlated] %s field=%s info=%s")
				:format(correlationId, player.Name, canonical, guardR.code))
		end
		if finalFlag then
			print(("[InvFinalSerialize][%s] %s field=%s count=%d (FINAL)"):format(correlationId, player.Name, canonical, count))
		end
		if count ~= old then anyChange = true end
	end

	if anyChange then
		PlayerState[player].snapshotVersion = (PlayerState[player].snapshotVersion or 0) + 1

		-- Async best-effort save (non-blocking)
		local ok1, err1 = pcall(function()
			PlayerProfileService.SaveNow(player, reason or "InventoryUpdate")
		end)
		if not ok1 then
			warnLog(("SaveNow failed for %s reason=%s err=%s"):format(player.Name, tostring(reason), tostring(err1)))
		else
			dprint(("SaveNow requested for %s reason=%s"):format(player.Name, tostring(reason)))
		end

		-- If this is a final serialization, request a verified save via PlayerProfileService.SaveNowAndWait (preferVerified).
		if finalFlag then
			local ok2, res2 = pcall(function()
				if type(PlayerProfileService.SaveNowAndWait) == "function" then
					return PlayerProfileService.SaveNowAndWait(player, 3, true)
				elseif type(PlayerProfileService.ForceFullSaveNow) == "function" then
					return PlayerProfileService.ForceFullSaveNow(player, reason or "InventoryFinal")
				else
					PlayerProfileService.SaveNow(player, reason or "InventoryFinal")
					if type(PlayerProfileService.WaitForSaveComplete) == "function" then
						local done, success = PlayerProfileService.WaitForSaveComplete(player, 3)
						return done and success
					end
					return false
				end
			end)
			if not ok2 then
				warnLog(("Verified save (final) call failed for %s reason=%s err=%s"):format(player.Name, tostring(reason), tostring(res2)))
			else
				dprint(("Verified save requested/completed for %s reason=%s success=%s"):format(player.Name, tostring(reason), tostring(res2)))
			end
		end
	end

	if not finalFlag then
		PlayerState[player].dirtyReasons = {}
	end
end

--------------------------------------------------
-- RESTORE / MERGE (canonicalization & serializer payload normalization)
--------------------------------------------------
local function indexById(list)
	local map = {}
	for _,e in ipairs(list) do
		if type(e)=="table" then
			local id = e.Id or e.id or e.UID or e.uid or e.EggId or e.SlimeId or e.ToolId
			if id then map[tostring(id)] = e end
		end
	end
	return map
end

-- Helper: merge short-key folders into canonical folders on the player's Inventory instance
local function migrate_short_folders_to_canonical(player)
	local inv = player:FindFirstChild(PLAYER_INVENTORY_FOLDER)
	if not inv then return end
	for short, canon in pairs(CANONICAL_FROM_SHORT) do
		local shortFld = inv:FindFirstChild(short)
		local canonFld = inv:FindFirstChild(canon)
		if shortFld and shortFld:IsA("Folder") then
			-- move Entry_* subfolders into canonical folder
			if not canonFld then
				canonFld = Instance.new("Folder")
				canonFld.Name = canon
				canonFld.Parent = inv
				local countVal = Instance.new("IntValue")
				countVal.Name = "Count"
				countVal.Value = 0
				countVal.Parent = canonFld
			end
			for _,child in ipairs(shortFld:GetChildren()) do
				if child:IsA("Folder") and child.Name:match("^"..ENTRY_FOLDER_PREFIX) then
					child.Parent = canonFld
				end
			end
			-- update counts and remove old folder
			local cnt = 0
			for _,c in ipairs(canonFld:GetChildren()) do if c:IsA("Folder") and c.Name:match("^"..ENTRY_FOLDER_PREFIX) then cnt = cnt + 1 end end
			local countVal = canonFld:FindFirstChild("Count")
			if countVal then countVal.Value = cnt end
			-- remove the short folder now that entries moved
			pcall(function() shortFld:Destroy() end)
		end
	end
end

-- Normalize a "restore target" so we do not pass username strings to serializers.
-- Preferred returned types (in order): profile table (if available), Player instance, numeric userId
-- Returns: target (profile table | Player instance | number) or nil if none resolvable
local function normalizeRestoreTarget(playerArg, profile)
	-- If we already have a profile table, prefer that
	if type(profile) == "table" and profile.inventory ~= nil then
		return profile
	end

	-- If playerArg is a Player instance, return it
	if type(playerArg) == "table" and type(playerArg.FindFirstChildOfClass) == "function" then
		return playerArg
	end

	-- If playerArg itself is a profile table, return it
	if type(playerArg) == "table" and playerArg.inventory ~= nil then
		return playerArg
	end

	-- If playerArg is a number or numeric string, return numeric userId
	if tonumber(playerArg) then
		return tonumber(playerArg)
	end

	-- If playerArg is a string, attempt resolution:
	if type(playerArg) == "string" then
		-- try to find a live Player instance first
		local pl = Players:FindFirstChild(playerArg)
		if pl then return pl end

		-- try to obtain profile by name (PPS may accept username)
		local prof = safe_get_profile_any(playerArg)
		if prof then return prof end

		-- Last resort: try GetUserIdFromNameAsync (pcall) -> numeric userId
		local ok, res = pcall(function() return Players:GetUserIdFromNameAsync(playerArg) end)
		if ok and res and tonumber(res) then
			return tonumber(res)
		end
	end

	-- nothing resolvable
	return nil
end

function InventoryService.RestorePlayer(player, savedData)
	local st = ensureState(player)
	-- If we've already completed restore for this player, skip to avoid duplicate work
	if st.restoreCompleted then
		dprint(("RestorePlayer: already completed for %s; skipping"):format(player.Name))
		return
	end

	local incomingFields = (savedData and savedData.fields) or {}

	-- Defensive: log incoming savedData summary
	dprint(("RestorePlayer called for %s - incomingFields=%d"):format(player.Name, (incomingFields and (function() local c=0; for k,_ in pairs(incomingFields) do c=c+1 end return c end)() or 0)))

	-- Normalize incoming fields: accept both short and long keys and coerce into canonical long keys
	local normalized = {}
	for fieldName, payload in pairs(incomingFields) do
		local canonical = canonicalizeFieldName(fieldName) or fieldName
		if type(payload) == "table" then
			-- payload may be shape { list = {...} } or an array
			if type(payload.list) == "table" then
				normalized[canonical] = payload.list
			elseif payload[1] ~= nil or next(payload) == nil then
				-- array-style payload or empty table
				normalized[canonical] = payload
			else
				-- Possibly wrapped blob (fields[name] = { v=..., list=... } ); handle common shape
				if type(payload.list) == "table" then
					normalized[canonical] = payload.list
				else
					normalized[canonical] = {}
					dprint(("RestorePlayer: unknown payload shape for field %s; coercing to empty list"):format(fieldName))
				end
			end
		else
			normalized[canonical] = {}
			dprint(("RestorePlayer: non-table payload for field %s; coercing to empty list"):format(fieldName))
		end
	end

	-- Before calling serializer, attempt to resolve the PlayerProfileService profile (short retry)
	local profile = safe_get_profile_for_player(player)
	if not profile then
		-- small retry/backoff to allow late profile preload
		local maxRetries = 12
		local waitSec = 0.125
		for attempt = 1, maxRetries do
			if profile then break end
			dprint(("RestorePlayer: profile not found for %s; retry %d/%d (waiting %.2fs)"):format(player.Name, attempt, maxRetries, waitSec))
			task.wait(waitSec)
			profile = safe_get_profile_for_player(player)
			if attempt == 3 then waitSec = 0.25 end
			if profile then
				dprint(("RestorePlayer: profile resolved for %s on attempt %d"):format(player.Name, attempt))
				break
			end
		end
	end

	-- FINAL short bounded wait attempt using PPS.WaitForProfile (if available) to reduce race windows.
	if not profile then
		profile = wait_for_profile(player, 1.5)
		if profile then
			dprint(("RestorePlayer: WaitForProfile returned profile for %s"):format(player.Name))
		end
	end

	-- Log profile identity (helps diagnose mismatches)
	if profile then
		pcall(function()
			local uid = profile.userId or profile.UserId or profile.id or "unknown"
			dprint(("RestorePlayer: profile object for %s: %s (userId=%s)"):format(player.Name, tostring(profile), tostring(uid)))
		end)
	else
		dprint(("RestorePlayer: no profile available for %s at Restore time (will still attempt payload restore)"):format(player.Name))
	end

	-- Migrate any existing short-form folders in player's Inventory (avoid duplicates)
	migrate_short_folders_to_canonical(player)

	-- Build serializer-shaped payload (short keys) from normalized canonical data
	local serializerPayload = {
		et = normalized["eggTools"] or {},
		ft = normalized["foodTools"] or {},
		we = normalized["worldEggs"] or {},
		ws = normalized["worldSlimes"] or {},
	}

	-- Determine canonical restore target to pass to serializers:
	-- Prefer profile table, then Player instance, then numeric userId.
	local restoreTarget = normalizeRestoreTarget(player, profile)
	-- If normalize didn't return a profile but we have 'profile' available, use it
	if not restoreTarget and profile then restoreTarget = profile end
	-- Final fallback: if nothing, use numeric player.UserId
	if not restoreTarget then restoreTarget = tonumber(player.UserId) end

	-- Log our chosen restoreTarget type for diagnostics
	do
		local t = type(restoreTarget)
		if t == "table" and restoreTarget.inventory then
			dprint(("RestorePlayer: chosen restoreTarget=profile table userId=%s for %s"):format(tostring(restoreTarget.userId or restoreTarget.UserId or "unknown"), player.Name))
		elseif t == "table" and type(restoreTarget.FindFirstChildOfClass) == "function" then
			dprint(("RestorePlayer: chosen restoreTarget=Player instance (%s) for %s"):format(tostring(restoreTarget.Name or "unknown"), player.Name))
		elseif t == "number" then
			dprint(("RestorePlayer: chosen restoreTarget=userId=%s for %s"):format(tostring(restoreTarget), player.Name))
		else
			dprint(("RestorePlayer: chosen restoreTarget (%s) is fallback player ref for %s"):format(tostring(t), player.Name))
		end
	end

	-- If a PlayerProfileService adapter exists, call it with short-key payload; else call GrandInventorySerializer.Restore
	local usedAdapter = false
	if type(PlayerProfileService.RestoreInventory) == "function" then
		-- Prefer passing the profile table to the PPS adapter to avoid race issues.
		local ppsTarget = profile
		if not ppsTarget then
			-- try a short wait for profile to be available before calling adapter
			ppsTarget = wait_for_profile(player, 1.5)
		end

		local ok, err = pcall(function()
			if ppsTarget then
				PlayerProfileService.RestoreInventory(ppsTarget, serializerPayload)
			else
				-- fallback: still call with Player instance to allow adapter to schedule/poll as it sees fit
				PlayerProfileService.RestoreInventory(player, serializerPayload)
			end
		end)
		if not ok then
			warnLog("PlayerProfileService.RestoreInventory failed: "..tostring(err))
		else
			usedAdapter = true
			dprint(("PlayerProfileService.RestoreInventory invoked for %s (ppsTargetType=%s)"):format(player.Name, tostring(type(ppsTarget))))
		end
	end

	if not usedAdapter then
		local meta = SerializerMeta["GrandInventorySerializer"]
		if meta and meta.hasRestore then
			-- Ensure we prefer passing the profile table to the serializer when possible to avoid races.
			local serTarget = restoreTarget
			if type(serTarget) ~= "table" or (type(serTarget) == "table" and not serTarget.inventory) then
				-- attempt a short wait to get the profile if available
				local profTry = profile or wait_for_profile(player, 1.5)
				if profTry then
					serTarget = profTry
				end
			end

			-- Pass canonical restore target to serializer (profile preferred, else player instance, else numeric userId)
			local ok1, err1 = pcall(function()
				-- We prefer calling with (target, payload) shape so serializer can handle profile or userId
				if type(meta.serializer.Restore) == "function" then
					meta.serializer:Restore(serTarget, serializerPayload)
				else
					meta.serializer.Restore(serTarget, serializerPayload)
				end
			end)
			if not ok1 then
				warnLog("Restore error grandInventory (payload) "..tostring(err1))
			else
				dprint(("GrandInventorySerializer.Restore invoked for %s - passed target type=%s fields=%d"):format(player.Name, type(serTarget), (function() local c=0; for _ in pairs(serializerPayload) do c=c+1 end return c end)()))
			end

			-- Additionally call with profile fallback (explicit) if we have profile and it's not already the restoreTarget
			if profile and profile ~= serTarget then
				local ok2, err2 = pcall(function()
					meta.serializer:Restore(profile, serializerPayload)
				end)
				if not ok2 then
					warnLog("Restore error grandInventory (profile fallback) "..tostring(err2))
				else
					dprint(("GrandInventorySerializer.Restore(profile) invoked for %s (fallback)"):format(player.Name))
				end
			else
				if not profile then
					dprint(("GrandInventorySerializer.Restore: no profile fallback available for %s"):format(player.Name))
				end
			end
		else
			-- Legacy per-serializer restore (defensive): feed canonical lists
			for name, metaEntry in pairs(SerializerMeta) do
				local nm = name
				local payload = normalized[nm] or {}
				local list = payload
				if metaEntry.hasRestore then
					local ok,err = pcall(function()
						return metaEntry.serializer:Restore(player, list)
					end)
					if not ok then warnLog("Restore error "..nm.." "..tostring(err)) end
				end

				local existing = st.fields[nm] and st.fields[nm].list or nil
				-- Defensive: if incoming empty but existing non-empty, preserve existing
				if shouldPreserveExistingOnEmpty(existing, list) then
					logSuppressedClear(player, nm)
				elseif existing and #existing > 0 then
					local idx = indexById(existing)
					local added = 0
					for _,e in ipairs(list) do
						local id = type(e)=="table" and (e.Id or e.id or e.UID or e.uid or e.EggId or e.SlimeId or e.ToolId)
						if id then
							id = tostring(id)
							if not idx[id] then
								table.insert(existing, e)
								idx[id] = e
								added = added + 1
							end
						else
							table.insert(existing, e)
							added = added + 1
						end
					end
					st.fields[nm] = {
						list = existing,
						lastCount = #existing,
						version = (st.fields[nm].version or 0) + 1,
						meta = { mergeApplied = true, added = added }
					}
					updateInventoryFolder(player, nm, existing)
					if added > 0 then
						print(("[InvRestore][Merge] %s field=%s added=%d final=%d")
							:format(player.Name, nm, added, #existing))
					end
				else
					st.fields[nm] = {
						list = list,
						lastCount = #list,
						version = (incomingFields[nm] and incomingFields[nm].v) or 1,
						meta = incomingFields[nm] and incomingFields[nm].meta or nil
					}
					updateInventoryFolder(player, nm, list)
					print(("[InvRestore] %s field=%s count=%d (initial)"):format(player.Name, nm, #list))
				end
			end
		end
	end

	-- Merge normalized (canonical) payloads into InventoryService state
	for fieldName, list in pairs(normalized) do
		list = type(list) == "table" and list or {}
		local existing = st.fields[fieldName] and st.fields[fieldName].list or nil

		-- Defensive: if incoming list is empty but we have existing non-empty list, preserve existing state.
		if shouldPreserveExistingOnEmpty(existing, list) then
			logSuppressedClear(player, fieldName)
			-- keep existing state untouched; still update folder counts as necessary (existing already present)
			updateInventoryFolder(player, fieldName, existing)
		else
			-- Normal merge behavior: add non-duplicates to existing, or set initial
			if existing and #existing > 0 then
				local idx = indexById(existing)
				local added = 0
				for _,e in ipairs(list) do
					if type(e) ~= "table" then
						table.insert(existing, e)
						added = added + 1
					else
						local id = e.Id or e.id or e.UID or e.uid or e.EggId or e.SlimeId or e.ToolId
						if id then
							id = tostring(id)
							if not idx[id] then
								table.insert(existing, e)
								idx[id] = e
								added = added + 1
							end
						else
							table.insert(existing, e)
							added = added + 1
						end
					end
				end
				st.fields[fieldName] = {
					list = existing,
					lastCount = #existing,
					version = (st.fields[fieldName].version or 0) + 1,
					meta = { mergeApplied = true, added = added }
				}
				updateInventoryFolder(player, fieldName, existing)
				if added > 0 then
					print(("[InvRestore][Merge] %s field=%s added=%d final=%d")
						:format(player.Name, fieldName, added, #existing))
				end
			else
				st.fields[fieldName] = {
					list = list,
					lastCount = #list,
					version = (incomingFields[fieldName] and incomingFields[fieldName].v) or 1,
					meta = incomingFields[fieldName] and incomingFields[fieldName].meta or nil
				}
				updateInventoryFolder(player, fieldName, list)
				print(("[InvRestore] %s field=%s count=%d (initial)"):format(player.Name, fieldName, #list))
			end
		end
	end

	st.restoreCompleted = true
	print(("[InvRestore] Completed for %s"):format(player.Name))
end

--------------------------------------------------
-- PUBLIC APIS (Add/Remove runtime items)
--------------------------------------------------
function InventoryService.AddInventoryItem(playerOrId, fieldName, itemData, opts)
	local ply = resolvePlayer(playerOrId)
	if not ply then
		warn("[InvSvc] AddInventoryItem: player not found for", tostring(playerOrId))
		return false, "no player"
	end
	opts = opts or {}
	local st = ensureState(ply)
	fieldName = canonicalizeFieldName(fieldName) or fieldName
	st.fields[fieldName] = st.fields[fieldName] or { list = {}, lastCount = 0, version = 0, meta = nil }
	table.insert(st.fields[fieldName].list, itemData)
	st.fields[fieldName].lastCount = #st.fields[fieldName].list
	st.fields[fieldName].version = (st.fields[fieldName].version or 0) + 1
	st.dirtyReasons["AddInventoryItem"] = true
	updateInventoryFolder(ply, fieldName, st.fields[fieldName].list)
	if DEBUG then
		print(("[InvSvc] Added item to %s.%s (now %d)"):format(ply.Name, fieldName, #st.fields[fieldName].list))
	end

	local okUpd, errUpd = pcall(function()
		InventoryService.UpdateProfileInventory(ply)
	end)
	if not okUpd then warnLog("UpdateProfileInventory failed for add:", tostring(errUpd)) end

	-- By default, request an async SaveNow (coalesced). If caller requests immediate durability, perform verified save.
	if opts.immediate then
		local okSave, resSave = pcall(function()
			return requestVerifiedSave(ply, 3)
		end)
		if okSave and resSave then
			dprint(("Verified save succeeded for %s after AddInventoryItem"):format(ply.Name))
		else
			-- fallback: schedule async save
			pcall(function() PlayerProfileService.SaveNow(ply, "InventoryAddImmediate_Fallback") end)
			dprint(("SaveNow (async) requested for %s after AddInventoryItem (verified unavailable)"):format(ply.Name))
		end
	else
		-- coalesced async save recommended for frequent add operations
		pcall(function() PlayerProfileService.SaveNow(ply, "InventoryAdd") end)
	end

	return true
end

function InventoryService.RemoveInventoryItem(playerOrId, category, idField, idValue, opts)
	local ply = resolvePlayer(playerOrId)
	if not ply then
		warn("[InvSvc] RemoveInventoryItem: player not found for", tostring(playerOrId))
		return false, "no player"
	end
	opts = opts or {}
	category = canonicalizeFieldName(category) or category
	local st = ensureState(ply)
	local fld = st.fields[category]
	if not fld or not fld.list then
		return false, "no field"
	end
	for i = #fld.list, 1, -1 do
		local entry = fld.list[i]
		if type(entry) == "table" and entry[idField] == idValue then
			table.remove(fld.list, i)
			fld.lastCount = #fld.list
			fld.version = (fld.version or 0) + 1
			st.dirtyReasons["RemoveInventoryItem"] = true
			updateInventoryFolder(ply, category, fld.list)
			if DEBUG then
				print(("[InvSvc] Removed item from %s.%s idField=%s id=%s (now %d)"):format(ply.Name, category, tostring(idField), tostring(idValue), #fld.list))
			end

			local okUpd, errUpd = pcall(function()
				InventoryService.UpdateProfileInventory(ply)
			end)
			if not okUpd then warnLog("UpdateProfileInventory failed for remove:", tostring(errUpd)) end

			if opts.immediate then
				local okSave, saved = pcall(function() return requestVerifiedSave(ply, 3) end)
				if okSave and saved then
					dprint(("Verified save succeeded for %s after RemoveInventoryItem"):format(ply.Name))
				else
					pcall(function() PlayerProfileService.SaveNow(ply, "InventoryRemoveImmediate_Fallback") end)
					dprint(("SaveNow (async) requested for %s after RemoveInventoryItem (verified unavailable)"):format(ply.Name))
				end
			else
				pcall(function() PlayerProfileService.SaveNow(ply, "InventoryRemove") end)
			end

			return true
		end
	end
	return false, "not found"
end

--------------------------------------------------
-- New helper: Ensure an Entry_<id> folder exists under a player's field folder
-- and that it contains a Data StringValue with JSON including id/eggId. Best-effort persists.
-- This complements EggService's ensureInventoryEntryHasId behavior so InventoryService can be the canonical place.
--------------------------------------------------
function InventoryService.EnsureEntryHasId(playerOrId, fieldName, idValue, payloadTable)
	local ply = resolvePlayer(playerOrId)
	if not ply then return false, "no player" end
	fieldName = canonicalizeFieldName(fieldName) or fieldName
	local fld = ensureFieldFolder(ply, fieldName)
	if not fld then return false, "no folder" end

	local canonicalId = tostring(idValue)

	-- Try to find an existing entry already containing this id in its Data.Value
	for _,entry in ipairs(fld:GetChildren()) do
		if entry:IsA("Folder") then
			local data = entry:FindFirstChild(ENTRY_DATA_VALUE_NAME)
			if data and type(data.Value) == "string" and data.Value ~= "" then
				local ok, t = pcall(function() return HttpService:JSONDecode(data.Value) end)
				if ok and type(t) == "table" and (t.id == canonicalId or t.eggId == canonicalId) then
					-- ensure canonical name
					local desiredName = ENTRY_FOLDER_PREFIX .. canonicalId
					if entry.Name ~= desiredName then
						pcall(function() entry.Name = desiredName end)
					end
					return true
				end
			end
		end
	end

	-- Find a candidate entry lacking proper Data and fill it
	for _,entry in ipairs(fld:GetChildren()) do
		if entry:IsA("Folder") then
			local data = entry:FindFirstChild(ENTRY_DATA_VALUE_NAME)
			local shouldSet = false
			if not data then
				shouldSet = true
			elseif not data.Value or data.Value == "" then
				shouldSet = true
			else
				local ok, t = pcall(function() return HttpService:JSONDecode(data.Value) end)
				if not ok or type(t) ~= "table" or (not t.id and not t.eggId) then
					shouldSet = true
				end
			end
			if shouldSet then
				if not data then
					data = Instance.new("StringValue")
					data.Name = ENTRY_DATA_VALUE_NAME
					data.Parent = entry
				end
				payloadTable = payloadTable or {}
				payloadTable.id = tostring(payloadTable.id or canonicalId)
				payloadTable.eggId = payloadTable.eggId or payloadTable.id
				local okEnc, enc = pcall(function() return HttpService:JSONEncode(payloadTable) end)
				if okEnc then
					pcall(function() data.Value = enc end)
				else
					pcall(function() data.Value = HttpService:JSONEncode({ id = canonicalId }) end)
				end
				pcall(function() entry.Name = ENTRY_FOLDER_PREFIX .. canonicalId end)

				-- update Count value
				local cnt = 0
				for _,c in ipairs(fld:GetChildren()) do if c:IsA("Folder") and c.Name:match("^"..ENTRY_FOLDER_PREFIX) then cnt = cnt + 1 end end
				local cv = fld:FindFirstChild("Count")
				if cv then pcall(function() cv.Value = cnt end) end

				-- best-effort persist/update
				pcall(function() InventoryService.UpdateProfileInventory(ply) end)
				pcall(function() PlayerProfileService.SaveNow(ply, "EnsureEntryHasId") end)
				return true
			end
		end
	end

	-- Nothing to reuse, create a new Entry_<id> folder
	local okC, newEntry = pcall(function()
		local f = Instance.new("Folder")
		f.Name = ENTRY_FOLDER_PREFIX .. canonicalId
		local data = Instance.new("StringValue")
		data.Name = ENTRY_DATA_VALUE_NAME
		payloadTable = payloadTable or {}
		payloadTable.id = tostring(payloadTable.id or canonicalId)
		payloadTable.eggId = payloadTable.eggId or payloadTable.id
		data.Value = (pcall(function() return HttpService:JSONEncode(payloadTable) end) and HttpService:JSONEncode(payloadTable)) or HttpService:JSONEncode({ id = canonicalId })
		data.Parent = f
		f.Parent = fld
		return f
	end)
	if okC and newEntry then
		-- update Count value
		local cnt = 0
		for _,c in ipairs(fld:GetChildren()) do if c:IsA("Folder") and c.Name:match("^"..ENTRY_FOLDER_PREFIX) then cnt = cnt + 1 end end
		local cv = fld:FindFirstChild("Count")
		if cv then pcall(function() cv.Value = cnt end) end

		pcall(function() InventoryService.UpdateProfileInventory(ply) end)
		pcall(function() PlayerProfileService.SaveNow(ply, "EnsureEntryHasId") end)
		return true
	end

	return false, "create_failed"
end

--------------------------------------------------
-- SERIALIZE / SAVE HELPERS (exposed functions kept)
--------------------------------------------------
function InventoryService.MarkDirty(playerOrId, reason)
	local ply = resolvePlayer(playerOrId)
	if not ply then return end
	markDirty(ply, reason or "ManualDirty")
end

function InventoryService.ForceSave(playerOrId, reason)
	local ply = resolvePlayer(playerOrId)
	if not ply then return end
	serializePlayer(ply, reason or "ForceSave", false)
end

function InventoryService.ExportPlayerSnapshot(player)
	local st = PlayerState[player]; if not st then return nil end
	return buildBlob(player, st)
end

function InventoryService.DebugPrintPlayer(player)
	local st = PlayerState[player]
	if not st then print("[InvSvc] No state for", player and player.Name or tostring(player)) return end
	print(("[InvSvc][Debug] %s restored=%s version=%d")
		:format(player.Name, tostring(st.restoreCompleted), st.snapshotVersion))
	for nm,f in pairs(st.fields) do
		print(("  field=%s count=%d v=%d suspect=%s merge=%s")
			:format(nm, f.lastCount or 0, f.version or 0,
				f.meta and tostring(f.meta.suspect) or "false",
				f.meta and tostring(f.meta.mergeApplied) or "false"))
	end
end

function InventoryService.FlushAll(reason)
	for _,plr in ipairs(Players:GetPlayers()) do
		serializePlayer(plr, reason or "FlushAll", false)
	end
end

function InventoryService.FinalizePlayer(player, reason)
	serializePlayer(player, reason or "Final", true)
	-- Additionally, if SlimeCore GrowthPersistenceService is available and decoupled,
	-- we can call orchestrator SaveNow for this player to flush growth persistence.
	if GrowthPersistenceOrchestrator and type(GrowthPersistenceOrchestrator.SaveNow) == "function" then
		pcall(function() GrowthPersistenceOrchestrator:SaveNow(player, "FinalizePlayer") end)
	end
end

-- Helper: Update PlayerProfileService inventory from current InventoryService state
-- Modified to merge into the existing profile.inventory instead of replacing with an empty table,
-- and to avoid writing empty lists that would clear existing non-empty fields accidentally.
function InventoryService.UpdateProfileInventory(player)
	local st = PlayerState[player]
	if not st then return end
	local profile = safe_get_profile_for_player(player)
	if not profile then
		warnLog(("UpdateProfileInventory: no profile loaded for %s; skipping"):format(player.Name))
		return
	end

	-- capture before-state counts
	local before = {}
	if profile.inventory then
		for k,v in pairs(profile.inventory) do before[k] = #v end
	end

	-- Ensure profile.inventory exists
	profile.inventory = profile.inventory or {}

	-- Merge Service state into profile.inventory.
	-- For each field known to the service, apply its list. Do not remove fields that the service does not manage.
	for field, data in pairs(st.fields) do
		local canonical = canonicalizeFieldName(field) or field
		local incoming = data.list or {}
		local existing = profile.inventory[canonical]

		-- If incoming empty but existing non-empty, preserve existing to avoid accidental clearing
		if shouldPreserveExistingOnEmpty(existing, incoming) then
			logSuppressedClear(player, canonical)
			-- ensure the profile.inventory keeps the existing list unchanged
		else
			-- otherwise set/overwrite the field
			profile.inventory[canonical] = incoming
		end
	end

	-- Note: do not remove keys from profile.inventory that service doesn't mention here.
	-- This avoids accidental data deletion due to out-of-order saves.

	local after = {}
	for k,v in pairs(profile.inventory) do after[k] = #v end

	dprint(("UpdateProfileInventory: player=%s profile inventory updated (before=%s)(after=%s)")
		:format(player.Name, jsonEncodeSafe(before), jsonEncodeSafe(after)))

	-- Use async SaveNow to persist these inventory updates (non-blocking)
	local ok, err = pcall(function() PlayerProfileService.SaveNow(player, "InventorySync") end)
	if not ok then
		warnLog(("SaveNow failed in UpdateProfileInventory for %s err=%s"):format(player.Name, tostring(err)))
	else
		dprint(("SaveNow requested for %s after UpdateProfileInventory"):format(player.Name))
	end
end

--------------------------------------------------
-- PERIODIC LOOP
--------------------------------------------------
local function periodicLoop()
	while true do
		task.wait(1)
		if not AUTO_PERIODIC_SERIALIZE then
			-- continue semantics
		else
			local now = os.clock()
			for _,plr in ipairs(Players:GetPlayers()) do
				local st = PlayerState[plr]
				if st then
					local due = now - st.lastSerialize >= SERIALIZE_INTERVAL_SECONDS
					local dirty = next(st.dirtyReasons) ~= nil
					if due or dirty then
						serializePlayer(plr, dirty and "Dirty" or "Periodic", false)
					end
				end
			end
		end
	end
end

--------------------------------------------------
-- PLAYER HOOKS
--------------------------------------------------
local function tryGetProfileWithRetries(player, maxRetries, delaySeconds)
	maxRetries = maxRetries or 8
	delaySeconds = delaySeconds or 0.12
	local attempt = 0
	local prof = nil
	while attempt < maxRetries do
		attempt = attempt + 1
		prof = safe_get_profile_for_player(player)
		if prof then
			dprint(("Profile resolved for %s after %d attempt(s)"):format(player.Name, attempt))
			return prof
		end
		dprint(("Profile not available for %s yet (attempt %d/%d). Waiting %.2fs"):format(player.Name, attempt, maxRetries, delaySeconds))
		task.wait(delaySeconds)
		if attempt == 2 then delaySeconds = 0.25 end
	end
	local ok, p = pcall(function() return PlayerProfileService.GetProfile(player.UserId) end)
	if ok and type(p) == "table" then
		dprint(("Profile resolved for %s on final direct GetProfile"):format(player.Name))
		return p
	end
	return nil
end

local function onPlayerAdded(player)
	ensureState(player)
	getInventoryFolder(player)

	local profile = tryGetProfileWithRetries(player, 8, 0.12)
	if profile and profile.inventory then
		dprint(("onPlayerAdded: invoking RestorePlayer for %s using profile inventory"):format(player.Name))
		InventoryService.RestorePlayer(player, { fields = profile.inventory })
	else
		dprint(("onPlayerAdded: profile missing or empty for %s; will attempt Restore when/if profile becomes available"):format(player.Name))
		task.delay(0.5, function()
			if player.Parent then
				-- perform a short wait-for-profile before performing a delayed restore
				local prof2 = wait_for_profile(player, 1.5) or safe_get_profile_for_player(player)
				if prof2 and prof2.inventory then
					dprint(("Delayed restore: invoking RestorePlayer for %s (delayed)"):format(player.Name))
					InventoryService.RestorePlayer(player, { fields = prof2.inventory })
				end
			end
		end)
	end

	if DEBUG then
		print(("[InvSvc] Player added, inventory root ready: %s"):format(player.Name))
	end
end

local function onPlayerRemoving(player)
	-- flush growth-related progress if SlimeCore present
	if SlimeCoreAvailable and SlimeCore and SlimeCore.GrowthService and type(SlimeCore.GrowthService.FlushPlayerSlimes) == "function" then
		pcall(function() SlimeCore.GrowthService.FlushPlayerSlimes(player.UserId) end)
	end

	InventoryService.FinalizePlayer(player, "Leave")
	PlayerState[player] = nil
end

--------------------------------------------------
-- INIT
--------------------------------------------------
function InventoryService.Init()
	if InventoryService.__Initialized then
		dprint("Init() already called.")
		return InventoryService
	end
	InventoryService.__Initialized = true

	if not Serializers["GrandInventorySerializer"] then
		local success, GrandInventorySerializer = pcall(function()
			return require(script.Parent:WaitForChild("GrandInventorySerializer"))
		end)
		if success and GrandInventorySerializer then
			InventoryService.RegisterSerializer("GrandInventorySerializer", GrandInventorySerializer)
			print("[InvSvc] GrandInventorySerializer registered successfully.")
		else
			warn("[InvSvc] Failed to require GrandInventorySerializer:", GrandInventorySerializer)
		end
	end

	-- Attempt to load SlimeCore (optional integration). If present, start its services and init GrowthPersistenceService
	local function tryRequireSlimeCore()
		-- try common locations: same folder as this script, ServerScriptService.Modules, ReplicatedStorage.Modules
		local candidates = {
			function() return script.Parent:FindFirstChild("SlimeCore") end,
			function() local ms = ServerScriptService:FindFirstChild("Modules"); return ms and ms:FindFirstChild("SlimeCore") end,
			function() return ServerScriptService:FindFirstChild("SlimeCore") end,
			function() return game:GetService("ReplicatedStorage"):FindFirstChild("SlimeCore") end,
		}
		for _,finder in ipairs(candidates) do
			local inst = nil
			pcall(function() inst = finder() end)
			if inst and inst.IsA and inst:IsA("ModuleScript") then
				local ok, mod = pcall(function() return require(inst) end)
				if ok and type(mod) == "table" then
					return mod
				end
			end
		end
		return nil
	end

	local okSC, sc = pcall(tryRequireSlimeCore)
	if okSC and sc and type(sc) == "table" then
		SlimeCore = sc
		SlimeCoreAvailable = true
		dprint("SlimeCore detected - initializing optional systems.")

		-- start growth/hunger loops if present
		pcall(function()
			if SlimeCore.Init and type(SlimeCore.Init) == "function" then
				SlimeCore.Init()
				dprint("SlimeCore.Init() invoked.")
			end
		end)

		-- Provide an orchestrator to GrowthPersistenceService: MarkDirty(player, reason) and SaveNow(player, reason, opts)
		if SlimeCore.GrowthPersistenceService and type(SlimeCore.GrowthPersistenceService.Init) == "function" then
			-- Orchestrator object that GrowthPersistenceService expects
			GrowthPersistenceOrchestrator = {
				MarkDirty = function(playerOrUser, reason)
					-- Accept player instance, numeric userId, or profile table
					local ply = nil
					if type(playerOrUser) == "number" then
						ply = Players:GetPlayerByUserId(playerOrUser)
					elseif type(playerOrUser) == "table" and type(playerOrUser.FindFirstChildOfClass) == "function" then
						ply = playerOrUser
					end
					-- prefer using InventoryService.MarkDirty to keep state consistent
					pcall(function()
						if ply then
							InventoryService.MarkDirty(ply, reason or "GrowthPersist_MarkDirty")
						end
					end)
					-- Also attempt a best-effort SaveNow if a player instance is available
					pcall(function()
						if ply then
							PlayerProfileService.SaveNow(ply, reason or "GrowthPersist_MarkDirty_SaveNow")
						elseif type(playerOrUser) == "number" then
							PlayerProfileService.SaveNow(playerOrUser, reason or "GrowthPersist_MarkDirty_SaveNow")
						elseif type(playerOrUser) == "table" and playerOrUser.userId then
							local uid = tonumber(playerOrUser.userId) or tonumber(playerOrUser.UserId)
							if uid then PlayerProfileService.SaveNow(uid, reason or "GrowthPersist_MarkDirty_SaveNow") end
						end
					end)
				end,
				SaveNow = function(playerOrUser, reason, opts)
					-- Best-effort call into PlayerProfileService.SaveNow with varying input types
					pcall(function()
						if type(playerOrUser) == "number" then
							local online = Players:GetPlayerByUserId(playerOrUser)
							if online then
								PlayerProfileService.SaveNow(online, reason or "GrowthPersist_SaveNow")
							else
								PlayerProfileService.SaveNow(playerOrUser, reason or "GrowthPersist_SaveNow")
							end
						elseif type(playerOrUser) == "table" and type(playerOrUser.FindFirstChildOfClass) == "function" then
							PlayerProfileService.SaveNow(playerOrUser, reason or "GrowthPersist_SaveNow")
						elseif type(playerOrUser) == "table" and playerOrUser.userId then
							local uid = tonumber(playerOrUser.userId) or tonumber(playerOrUser.UserId)
							if uid then PlayerProfileService.SaveNow(uid, reason or "GrowthPersist_SaveNow") end
						end
					end)
				end
			}

			-- Initialize the growth persistence service with our orchestrator (non-blocking)
			pcall(function() SlimeCore.GrowthPersistenceService:Init(GrowthPersistenceOrchestrator) end)
			dprint("GrowthPersistenceService.Init invoked with orchestrator.")
		else
			dprint("SlimeCore present but GrowthPersistenceService.Init not found; skipping orchestrator hookup.")
		end
	else
		dprint("SlimeCore not detected; continuing without integrated growth persistence.")
	end

	-- Subscribe to PlayerProfileService.ProfileReady so we can restore players as soon as their profile loads.
	if PlayerProfileService and PlayerProfileService.ProfileReady and type(PlayerProfileService.ProfileReady.Connect) == "function" then
		PlayerProfileService.ProfileReady:Connect(function(userId, profile)
			local uidNum = tonumber(userId) or userId
			local ply = Players:GetPlayerByUserId(tonumber(uidNum) or -1)
			if not ply then
				if type(userId) == "string" then
					ply = Players:FindFirstChild(userId)
				end
			end
			if not ply then
				return
			end

			ensureState(ply)
			local st = PlayerState[ply]
			if st and st.restoreCompleted then
				dprint(("ProfileReady: player %s already restored; skipping"):format(ply.Name))
				return
			end

			task.spawn(function()
				dprint(("ProfileReady: invoking RestorePlayer for %s (userId=%s)"):format(ply.Name, tostring(userId)))
				local ok, err = pcall(function()
					-- prefer passing the profile table that PPS provided to avoid races
					InventoryService.RestorePlayer(ply, { fields = (profile and profile.inventory) or {} })
				end)
				if not ok then
					warnLog(("ProfileReady RestorePlayer failed for %s err=%s"):format(ply.Name, tostring(err)))
				end
			end)
		end)
	end

	for _,p in ipairs(Players:GetPlayers()) do
		onPlayerAdded(p)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	if not RunService:IsClient() then
		task.spawn(periodicLoop)
	end

	local sCount = 0
	for _,_ in pairs(Serializers) do sCount = sCount + 1 end
	print(("[InvSvc] InventoryService %s initialized AutoPeriodic=%s Interval=%ds Serializers=%d")
		:format(InventoryService.__Version, tostring(AUTO_PERIODIC_SERIALIZE),
			SERIALIZE_INTERVAL_SECONDS, sCount))
	return InventoryService
end

return InventoryService