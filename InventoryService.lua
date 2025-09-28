-- InventoryService.lua
-- Version: v3.1.3-grand-unified-support (normalized field names & restore fixes)
-- Updates:
--  - Added InventoryService.FinalizePlayer to safely produce a final snapshot, update profile inventory and request verified save.
--  - Added InventoryService.MarkDirty (public wrapper) and made RemoveInventoryItem mark explicit clears so UpdateProfileInventory can persist removals.
--  - Adjusted UpdateProfileInventory to allow explicit clearing when the service has explicitly removed items (so sells/consumes persist).
--  - Defensive onPlayerRemoving now calls FinalizePlayer safely; onPlayerRemoving will clear PlayerState after finalization.
--  - Kept the canonical 'cs' -> 'capturedSlimes' handling and legacy short-key merge logic.
--  - Patched updateInventoryFolder to be non-destructive, reuse placeholder folders, and deduplicate numeric placeholder folders that contain the same id as a canonical folder.
--  - FIXES: remove worldSlimes entries when a slime is captured; improved removal matching for captured slimes so sells/consumes persist.
--  - FIX: added sanitizeInventoryOnProfile earlier so it's defined before use and to avoid lint/warning about unknown global.
--  - Added runtime configuration helpers: InventoryService.SetDebug(enabled) and InventoryService.Configure(opts) to toggle debug/serialize behaviors at runtime.
--  - PATCH (2025-09-03): deferred confirmation for DescendantRemoving / AncestryChanged handlers to avoid treating quick reparent moves (equip/unequip) as permanent removals.
--  - PATCH (2025-09-03): heavy safety guard to prevent all-empty snapshots from overwriting a non-empty persisted profile; optional backup on prevention.
-----------------------------------------------------------------------

local InventoryService = {}
InventoryService.__Version = "v3.1.3-grand-unified-support"
InventoryService.Name = "InventoryService"

--------------------------------------------------
-- CONFIG
--------------------------------------------------
local DEBUG                       = false	
local LOG_SERIALIZE_VERBOSE       = true
local LOG_EMPTY_SUPPRESS          = false
local AUTO_PERIODIC_SERIALIZE     = true
local SERIALIZE_INTERVAL_SECONDS  = 5
local MAX_ENTRIES_PER_FIELD       = 5000
local CORRELATION_TIMEOUT         = 3.0
local PLAYER_INVENTORY_FOLDER     = "Inventory"
local ENTRY_FOLDER_PREFIX         = "Entry_"
local ENTRY_DATA_VALUE_NAME       = "Data"

local AUTO_CLEANUP_REMOVED_TOOLS  = true

local GuardConfig = {
	InitialWindowSeconds = 15,
	Fields = {
		worldSlimes = { Watch=true, LargeDropFraction=0.80, IgnoreWhenCorrelated=true,  LogEveryChange=false },
		worldEggs   = { Watch=true, LargeDropFraction=0.85, IgnoreWhenCorrelated=false, LogEveryChange=false },
	},
	-- Heavy guard toggles (added)
	PreventEmptyOverwrite = true,    -- if true, do not allow an all-empty snapshot to overwrite a non-empty persisted profile
	BackupOnPrevent = true,          -- if true, create a backup under profile.meta.__inventoryBackup when preventing an overwrite
	BackupFieldName = "__inventoryBackup",
	Debug = false,
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
--------------------------------------------------
local SlimeCore = nil
local SlimeCoreAvailable = false
local GrowthPersistenceOrchestrator = nil

--------------------------------------------------
-- REGISTRY
--------------------------------------------------
local Serializers = {}
local SerializerMeta = {}

function InventoryService.RegisterSerializer(name, serializer)
	Serializers[name] = serializer

	local isFunc = type(serializer) == "function"
	local isTable = type(serializer) == "table"
	local hasSerialize = false
	local hasRestore = false

	if isFunc then
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
		_warned = false,
	}

	if not SerializerMeta[name].hasSerialize and not SerializerMeta[name].hasRestore then
		SerializerMeta[name]._warned = true
		warn(("[InvSvc] Registered serializer '%s' does not expose Serialize/Restore and will be skipped at runtime. type=%s"):format(tostring(name), typeof(serializer)))
	else
		print(("[InvSvc] Registered serializer '%s' (Serialize=%s, Restore=%s)"):format(tostring(name), tostring(SerializerMeta[name].hasSerialize), tostring(SerializerMeta[name].hasRestore)))
	end
end

local function resolveSerializerName(serializer)
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
local function waitForInventoryReady(player, timeout)
	timeout = timeout or 5
	local start = os.clock()
	repeat
		if player:GetAttribute("InventoryReady") then return true end
		task.wait(0.07)
	until not player.Parent or (os.clock() - start) > timeout
	return false
end

local function setInventoryReady(player)
	player:SetAttribute("InventoryReady", true)
end

local function dprint(...)
	if DEBUG then
		print(("[InvSvc][%s]"):format(os.time()), ...)
	end
end
local function warnLog(...)
	warn(("[InvWarn][%s]"):format(os.time()), ...)
end

--------------------------------------------------
-- ADD/REPLACE: Safe removal helpers
-- Placed here right after log helpers so they are available to other functions below.
--------------------------------------------------
local function _safeGetAttr(inst, name)
	if not inst or type(inst.GetAttribute) ~= "function" then return nil end
	local ok, v = pcall(function() return inst:GetAttribute(name) end)
	if ok then return v end
	return nil
end

local function _inspectInstanceAttrs(inst)
	local keys = {
		"ToolUniqueId","ToolUid","ServerRestore","PreserveOnServer","PreserveOnClient",
		"OwnerUserId","SlimeId","SlimeItem","FoodId","PersistentCaptured","PersistentFoodTool",
		"RestoreStamp","RecentlyPlacedSaved","RecentlyPlacedSavedAt","RecentlyPlacedSavedBy",
		"StagedByManager","RestoreBatchId","_RestoreGuard_Attempts"
	}
	local out = {}
	for _,k in ipairs(keys) do
		local ok, v = pcall(function() return inst:GetAttribute(k) end)
		if ok then out[k] = v end
	end
	return out
end

local function _looksLikeRestoredOrPersistent(inst)
	if not inst then return false end
	if type(inst.GetAttribute) ~= "function" then return false end
	if _safeGetAttr(inst, "ServerRestore") then return true end
	if _safeGetAttr(inst, "PreserveOnServer") or _safeGetAttr(inst, "PreserveOnClient") then return true end
	if _safeGetAttr(inst, "SlimeItem") or _safeGetAttr(inst, "SlimeId") then return true end
	if _safeGetAttr(inst, "PersistentCaptured") or _safeGetAttr(inst, "PersistentFoodTool") then return true end
	if _safeGetAttr(inst, "RestoreStamp") or _safeGetAttr(inst, "RecentlyPlacedSaved") or _safeGetAttr(inst, "RecentlyPlacedSavedAt") then
		return true
	end
	return false
end

-- safeRemoveOrDefer(inst, reason, opts)
-- - opts.grace: seconds to treat recent RestoreStamp/RecentlyPlacedSaved as protected (default 3)
-- - opts.force: true to force destructive Destroy() even if protected (use with caution)
-- Returns: success:boolean, code:string
local function safeRemoveOrDefer(inst, reason, opts)
	opts = opts or {}
	local grace = (type(opts.grace) == "number" and opts.grace) or 3.0
	local force = opts.force and true or false

	if not inst or (typeof and typeof(inst) ~= "Instance") then
		warn(("[InvSafe] safeRemoveOrDefer invalid instance (reason=%s)"):format(tostring(reason)))
		return false, "invalid_instance"
	end

	-- Protect newly-restored / preserved / persistent objects unless forced.
	local recentStamp = nil
	pcall(function()
		recentStamp = inst.GetAttribute and (inst:GetAttribute("RestoreStamp") or inst:GetAttribute("RecentlyPlacedSaved") or inst:GetAttribute("RecentlyPlacedSavedAt"))
	end)
	if not force then
		-- If explicit flags present, skip
		if _looksLikeRestoredOrPersistent(inst) then
			-- If it's stamped, allow grace window check
			if type(recentStamp) == "number" then
				if (tick() - tonumber(recentStamp)) <= grace then
					local attrs = _inspectInstanceAttrs(inst)
					local okEnc, attrsJson = pcall(function() return HttpService:JSONEncode(attrs) end)
					warn(("[InvSafe] SKIP removal (protected->recent) name=%s full=%s reason=%s attrs=%s")
						:format(tostring(inst.Name), (pcall(function() return inst:GetFullName() end) and inst:GetFullName() or "<getfullname-err>"), tostring(reason), okEnc and attrsJson or tostring(attrs)))
					warn(debug.traceback("[InvSafe] caller stack (skip):", 2))
					return false, "skipped_protected_recent"
				end
			else
				-- No numeric stamp but flagged -> skip
				local attrs = _inspectInstanceAttrs(inst)
				local okEnc, attrsJson = pcall(function() return HttpService:JSONEncode(attrs) end)
				warn(("[InvSafe] SKIP removal (protected flag) name=%s full=%s reason=%s attrs=%s")
					:format(tostring(inst.Name), (pcall(function() return inst:GetFullName() end) and inst:GetFullName() or "<getfullname-err>"), tostring(reason), okEnc and attrsJson or tostring(attrs)))
				warn(debug.traceback("[InvSafe] caller stack (skip):", 2))
				return false, "skipped_protected_flag"
			end
		end
	end

	-- Log removal attempt
	local attrs = _inspectInstanceAttrs(inst)
	local okEnc, attrsJson = pcall(function() return HttpService:JSONEncode(attrs) end)
	warn(("[InvSafe] Removing instance name=%s full=%s reason=%s attrs=%s")
		:format(tostring(inst.Name), (pcall(function() return inst:GetFullName() end) and inst:GetFullName() or "<getfullname-err>"), tostring(reason), okEnc and attrsJson or tostring(attrs)))
	warn(debug.traceback("[InvSafe] caller stack (remove):", 2))

	-- Try non-destructive parent detach first
	local ok, err = pcall(function() inst.Parent = nil end)
	if not ok then
		warn(("[InvSafe] Parent=nil failed for %s err=%s; attempting Destroy()"):format(tostring(inst.Name), tostring(err)))
		local ok2, err2 = pcall(function() inst:Destroy() end)
		if not ok2 then
			warn(("[InvSafe] Destroy() failed for %s err=%s"):format(tostring(inst.Name), tostring(err2)))
			return false, "destroy_failed"
		end
		return true, "destroyed_fallback"
	else
		if opts.force then
			local ok3, err3 = pcall(function() inst:Destroy() end)
			if not ok3 then
				warn(("[InvSafe] Forced Destroy() failed for %s err=%s"):format(tostring(inst.Name), tostring(err3)))
				return false, "destroy_failed"
			end
			return true, "destroyed"
		end
		-- Detached successfully
		return true, "detached"
	end
end

-- Expose for other local usage in this module
InventoryService._safeRemoveOrDefer = safeRemoveOrDefer
InventoryService._looksLikeRestoredOrPersistent = _looksLikeRestoredOrPersistent
InventoryService._inspectInstanceAttrs = _inspectInstanceAttrs

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
		fields = {},        -- canonical field -> { list = {...}, lastCount = n, version = x, meta = {} }
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
local CANONICAL_FROM_SHORT = {
	et = "eggTools",
	ft = "foodTools",
	we = "worldEggs",
	ws = "worldSlimes",
	cs = "capturedSlimes",
}
local SHORT_FROM_CANONICAL = {
	eggTools = "et",
	foodTools = "ft",
	worldEggs = "we",
	worldSlimes = "ws",
	capturedSlimes = "cs",
}

local function canonicalizeFieldName(name)
	if not name then return nil end
	if CANONICAL_FROM_SHORT[name] then return CANONICAL_FROM_SHORT[name] end
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

local function wait_for_profile(player, timeoutSeconds)
	if not player then return nil end
	timeoutSeconds = tonumber(timeoutSeconds) or 2
	local prof = safe_get_profile_for_player(player)
	if prof then return prof end
	if type(PlayerProfileService.WaitForProfile) == "function" then
		local ok, p = pcall(function() return PlayerProfileService.WaitForProfile(player, timeoutSeconds) end)
		if ok and type(p) == "table" then return p end
	end
	local deadline = os.clock() + timeoutSeconds
	while os.clock() < deadline do
		prof = safe_get_profile_for_player(player)
		if prof then return prof end
		task.wait(0.08)
	end
	return nil
end

--------------------------------------------------
-- sanitizeInventoryOnProfile helper (DECLARED EARLY to avoid unknown-global warnings)
-- Ensures profile.inventory tables are clean (no nil holes), coerces non-tables to empty tables,
-- and trims accidental nils from lists. This is intentionally defensive and light-weight.
--------------------------------------------------
local function sanitizeInventoryOnProfile(profile)
	if not profile or type(profile) ~= "table" then return end
	if not profile.inventory or type(profile.inventory) ~= "table" then
		profile.inventory = {}
		return
	end

	for field, v in pairs(profile.inventory) do
		-- Only keep table values and coerce others to empty table
		if type(v) ~= "table" then
			profile.inventory[field] = {}
		else
			-- Rebuild as a dense array preserving non-nil entries
			local out = {}
			for _, item in ipairs(v) do
				if item ~= nil then table.insert(out, item) end
			end
			profile.inventory[field] = out
		end
	end
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

-- Utility: search for a Tool instance owned by player with matching identifier
local function findToolForPlayerById(player, id)
	if not player or not id then return nil end
	local function matches(tool, idVal)
		if not tool then return false end
		local ok, t = pcall(function()
			if type(tool.GetAttribute) == "function" then
				local tu = tool:GetAttribute("ToolUniqueId") or tool:GetAttribute("ToolUid")
				if tu and tostring(tu) == tostring(idVal) then return true end
				local sid = tool:GetAttribute("SlimeId") or tool:GetAttribute("slimeId")
				if sid and tostring(sid) == tostring(idVal) then return true end
			end
			-- child value objects
			local c = tool:FindFirstChild("ToolUniqueId") or tool:FindFirstChild("ToolUid")
			if c and c.Value and tostring(c.Value) == tostring(idVal) then return true end
			local c2 = tool:FindFirstChild("SlimeId") or tool:FindFirstChild("slimeId")
			if c2 and c2.Value and tostring(c2.Value) == tostring(idVal) then return true end
			-- name fallback
			if tostring(tool.Name) == tostring(idVal) then return true end
			return false
		end)
		if ok then return t end
		return false
	end

	-- Check player's Backpack, Character, and workspace under player's model
	local places = {}
	pcall(function() table.insert(places, player:FindFirstChild("Backpack")) end)
	pcall(function() if player.Character then table.insert(places, player.Character) end end)
	-- workspace may contain a tool instance parented to workspace under player model
	pcall(function()
		local wsModel = workspace:FindFirstChild(player.Name)
		if wsModel then table.insert(places, wsModel) end
	end)

	for _, parent in ipairs(places) do
		if parent and parent.GetDescendants then
			for _,inst in ipairs(parent:GetDescendants()) do
				if inst and inst.IsA and inst:IsA("Tool") then
					if matches(inst, id) then return inst end
				end
			end
		end
	end

	return nil
end

--------------------------------------------------
-- updateInventoryFolder (REPLACED) - safe, non-destructive version
-- This replaces the original updateInventoryFolder implementation and uses safeRemoveOrDefer
-- for any destruction/detach operations to avoid races with restore logic.
--------------------------------------------------
local function updateInventoryFolder(player, fieldName, list)
	fieldName = canonicalizeFieldName(fieldName) or fieldName

	local fld = ensureFieldFolder(player, fieldName)
	local countVal = fld:FindFirstChild("Count")
	if countVal then
		countVal.Value = #list
	end

	if DEBUG then
		pcall(function()
			print(("[InvFolder_DEBUG] Updating %s.%s incomingCount=%d existingChildren=%d")
				:format(player.Name, fieldName, #list, #fld:GetChildren()))
			for i,entry in ipairs(list) do
				local t = type(entry)
				if t == "string" then
					local snippet = entry
					if #snippet > 240 then snippet = snippet:sub(1,240) .. "...(truncated)" end
					print(("[InvFolder_DEBUG] incoming[%d] type=string len=%d sample=%s"):format(i, #entry, snippet))
				elseif t == "table" then
					local keys = {}
					for k,_ in pairs(entry) do table.insert(keys, tostring(k)) end
					print(("[InvFolder_DEBUG] incoming[%d] type=table keys=%s"):format(i, table.concat(keys,",")))
				elseif t == "userdata" then
					print(("[InvFolder_DEBUG] incoming[%d] type=userdata value=%s"):format(i, tostring(entry)))
				else
					print(("[InvFolder_DEBUG] incoming[%d] type=%s value=%s"):format(i, t, tostring(entry)))
				end
			end
		end)
	end

	local st = PlayerState[player]
	local fieldMeta = st and st.fields and st.fields[fieldName] and st.fields[fieldName].meta

	if (#list == 0) and fieldMeta and fieldMeta.explicitlyCleared then
		if DEBUG then pcall(function() print(("[InvFolder_DEBUG] Explicit clear detected for %s.%s - clearing Entry_* data values (preserving folders)"):format(player.Name, fieldName)) end) end

		-- Instead of destroying Entry_* folders (which can cause races), blank Data values and keep folders.
		local cleared = 0
		for _,child in ipairs(fld:GetChildren()) do
			if child:IsA("Folder") and child.Name:match("^"..ENTRY_FOLDER_PREFIX) then
				local data = child:FindFirstChild(ENTRY_DATA_VALUE_NAME)
				if not data then
					data = Instance.new("StringValue")
					data.Name = ENTRY_DATA_VALUE_NAME
					data.Parent = child
				end
				pcall(function() data.Value = "" end)
				cleared = cleared + 1
			end
		end

		-- Update Count to reflect an empty logical list
		local cv = fld:FindFirstChild("Count")
		if cv then pcall(function() cv.Value = 0 end) end

		if DEBUG then pcall(function() print(("[InvFolder] Cleared %s.%s entries (preserved folders=%d) due to explicit clear"):format(player.Name, fieldName, cleared)) end) end
		return
	end

	local existingByName = {}
	local existingById = {}
	local placeholderFolders = {}
	for _,child in ipairs(fld:GetChildren()) do
		if child:IsA("Folder") and child.Name:match("^"..ENTRY_FOLDER_PREFIX) then
			existingByName[child.Name] = child
			local data = child:FindFirstChild(ENTRY_DATA_VALUE_NAME)
			if data and type(data.Value) == "string" and data.Value ~= "" then
				local ok, t = pcall(function() return HttpService:JSONDecode(data.Value) end)
				if ok and type(t) == "table" then
					local id = t.id or t.Id or t.eggId or t.EggId or t.SlimeId or t.slimeId or t.UID or t.uid or t.ToolUniqueId
					if id then
						existingById[tostring(id)] = child
					else
						table.insert(placeholderFolders, child)
					end
				else
					table.insert(placeholderFolders, child)
				end
			else
				table.insert(placeholderFolders, child)
			end
		end
	end

	if DEBUG then
		pcall(function()
			local ids = {}
			for k,_ in pairs(existingById) do table.insert(ids,k) end
			print(("[InvFolder_DEBUG] existingById keys for %s.%s : %s"):format(player.Name, fieldName, table.concat(ids,",")))
			print(("[InvFolder_DEBUG] placeholder count=%d"):format(#placeholderFolders))
			if st and st.fields and st.fields[fieldName] and st.fields[fieldName].list then
				local memList = st.fields[fieldName].list
				for i,m in ipairs(memList) do
					local tt = type(m)
					if tt == "string" then
						local s = m
						if #s > 160 then s = s:sub(1,160).."..." end
						print(("[InvFolder_DEBUG] PlayerState[%s] mem[%d] string sample=%s"):format(fieldName, i, s))
					elseif tt == "table" then
						local keys = {}
						for k,_ in pairs(m) do table.insert(keys, tostring(k)) end
						print(("[InvFolder_DEBUG] PlayerState[%s] mem[%d] keys=%s"):format(fieldName, i, table.concat(keys,",")))
					elseif tt == "userdata" then
						print(("[InvFolder_DEBUG] PlayerState[%s] mem[%d] type=userdata val=%s"):format(fieldName, i, tostring(m)))
					else
						print(("[InvFolder_DEBUG] PlayerState[%s] mem[%d] type=%s val=%s"):format(fieldName, i, tt, tostring(m)))
					end
				end
			end
		end)
	end

	-- local helpers inside updateInventoryFolder
	local function encodeEntry(e)
		local ok, enc = pcall(function() return HttpService:JSONEncode(e) end)
		if ok and type(enc) == "string" then return enc end
		return "{}"
	end

	local function decodeEntryStr(s)
		if not s or type(s) ~= "string" then return nil end
		local ok, dec = pcall(function() return HttpService:JSONDecode(s) end)
		if ok and type(dec) == "table" then return dec end
		return nil
	end

	local function extractId(val)
		if not val then return nil, nil end
		local t = type(val)
		if t == "table" then
			local id = val.id or val.Id or val.UID or val.uid or val.EggId or val.eggId or val.SlimeId or val.slimeId or val.ToolUniqueId
			if id then return tostring(id), val end
			return nil, nil
		elseif t == "string" then
			local ok, dec = pcall(function() return HttpService:JSONDecode(val) end)
			if ok and type(dec) == "table" then
				local id = dec.id or dec.Id or dec.SlimeId or dec.EggId or dec.UID
				if id then return tostring(id), dec end
			end
			if tostring(val):match("[A-Fa-f0-9%-]+") then
				return tostring(val), val
			end
			return nil, nil
		elseif t == "userdata" then
			local ok, id = pcall(function()
				if val.GetAttribute then
					local a = val:GetAttribute("SlimeId") or val:GetAttribute("EggId") or val:GetAttribute("id") or val:GetAttribute("Id")
					if a then return tostring(a) end
				end
				local cand = val:FindFirstChild("SlimeId") or val:FindFirstChild("EggId") or val:FindFirstChild("id") or val:FindFirstChild("Id")
				if cand and cand.Value ~= nil then return tostring(cand.Value) end
				if tostring(val.Name):match("[A-Fa-f0-9%-]+") then return tostring(val.Name) end
				return nil
			end)
			if ok and id then return tostring(id), val end
			return nil, nil
		end
		return nil, nil
	end

	local consumedFolders = {}
	local placeholderIndex = 1

	local function makeUniqueIndex()
		local idx = 1
		while true do
			local candidate = ENTRY_FOLDER_PREFIX .. tostring(idx)
			if not existingByName[candidate] and not consumedFolders[candidate] then
				return candidate
			end
			idx = idx + 1
		end
	end

	local function resolveIdFromInMemory(idx, incomingEntry)
		if not st or not st.fields or not st.fields[fieldName] or not st.fields[fieldName].list then return nil, nil end
		local memList = st.fields[fieldName].list

		local candidate = memList[idx]
		local id, resolved = extractId(candidate)
		if id then return id, resolved end

		for i,mem in ipairs(memList) do
			local id2, res2 = extractId(mem)
			if id2 and not existingById[id2] and not consumedFolders[ENTRY_FOLDER_PREFIX .. id2] then
				return id2, res2
			end
		end

		local id3, res3 = extractId(incomingEntry)
		if id3 then return id3, res3 end

		return nil, nil
	end

	-- Helper: if an Entry_<id> folder exists in any other field, move it into the current field and return it.
	local function moveCrossFieldEntryToCurrent(desiredName)
		local moved = nil
		pcall(function()
			local inv = getInventoryFolder(player)
			for _,fieldFolder in ipairs(inv:GetChildren()) do
				if fieldFolder:IsA("Folder") and fieldFolder.Name ~= fieldName then
					local cand = fieldFolder:FindFirstChild(desiredName)
					if cand then
						-- reparent into current field
						cand.Parent = fld
						moved = cand
						if DEBUG then pcall(function() print(("[InvFolder_DEBUG] Moved %s from %s -> %s for player=%s"):format(desiredName, fieldFolder.Name, fieldName, player.Name)) end) end
						break
					end
				end
			end
		end)
		return moved
	end

	for i,entry in ipairs(list) do
		local entryObj = entry
		if type(entry) == "string" then
			local ok, dec = pcall(function() return HttpService:JSONDecode(entry) end)
			if ok and type(dec) == "table" then entryObj = dec end
		end

		local entryId, memResolvedEntry = extractId(entryObj)
		if not entryId then
			local resolvedId, memEntry = resolveIdFromInMemory(i, entryObj)
			if resolvedId then
				entryId = resolvedId
				memResolvedEntry = memEntry
				if DEBUG then pcall(function() print(("[InvFolder_DEBUG] Resolved missing id for %s.%s[index=%d] -> id=%s (from in-memory or userdata)"):format(player.Name, fieldName, i, tostring(entryId))) end) end
			end
		end

		if entryId then
			local canonicalId = tostring(entryId)
			local desiredName = ENTRY_FOLDER_PREFIX .. canonicalId

			-- If an Entry_<id> existed in another field, move it into THIS field before proceeding.
			local movedFromOther = moveCrossFieldEntryToCurrent(desiredName)
			if movedFromOther then
				-- ensure it will be consumed and updated below as if it were an existing folder in this field
				existingByName[desiredName] = movedFromOther
			end

			local found = existingById[canonicalId]
			if found and found.Parent == fld then
				-- Robust merge: prefer an existing richer JSON if incoming is only { id = ... }.
				local dataVal = found:FindFirstChild(ENTRY_DATA_VALUE_NAME)
				if not dataVal then
					dataVal = Instance.new("StringValue")
					dataVal.Name = ENTRY_DATA_VALUE_NAME
					dataVal.Parent = found
				end

				-- Decode existing + incoming
				local existingTbl = decodeEntryStr(dataVal.Value)
				local incomingTbl = nil
				if memResolvedEntry then
					if type(memResolvedEntry) == "table" then incomingTbl = memResolvedEntry
					elseif type(memResolvedEntry) == "string" then incomingTbl = decodeEntryStr(memResolvedEntry) or { id = memResolvedEntry } end
				else
					if type(entry) == "string" then incomingTbl = decodeEntryStr(entry) or { id = canonicalId }
					elseif type(entryObj) == "table" then incomingTbl = entryObj
					else incomingTbl = { id = canonicalId }
					end
				end

				local function tableSize(t)
					if not t or type(t) ~= "table" then return 0 end
					local c = 0
					for k,v in pairs(t) do
						if v ~= nil then c = c + 1 end
					end
					return c
				end

				local existingCount = tableSize(existingTbl)
				local incomingCount = tableSize(incomingTbl)
				local incomingOnlyId = (incomingTbl and incomingTbl.id and incomingCount == 1)

				if existingTbl and existingCount > 1 and incomingOnlyId then
					if not existingTbl.id then existingTbl.id = canonicalId end
					dataVal.Value = encodeEntry(existingTbl)
					if DEBUG then pcall(function() print(("[InvFolder_DEBUG] Preserving richer existing payload for id=%s (incoming was id-only)"):format(canonicalId)) end) end
				else
					local merged = {}
					if type(existingTbl) == "table" then
						for k,v in pairs(existingTbl) do merged[k] = v end
					end
					if type(incomingTbl) == "table" then
						for k,v in pairs(incomingTbl) do merged[k] = v end
					end
					merged.id = merged.id or canonicalId
					dataVal.Value = encodeEntry(merged)
					if DEBUG then pcall(function() print(("[InvFolder_DEBUG] Wrote merged payload for id=%s"):format(canonicalId)) end) end
				end

				if found.Name ~= desiredName then
					pcall(function() found.Name = desiredName end)
				end
				consumedFolders[desiredName] = found
				if DEBUG then pcall(function() print(("[InvFolder_DEBUG] Reused existingById for id=%s name=%s"):format(canonicalId, desiredName)) end) end

			elseif existingByName[desiredName] and existingByName[desiredName].Parent == fld then
				local found2 = existingByName[desiredName]
				local dataVal = found2:FindFirstChild(ENTRY_DATA_VALUE_NAME)
				if not dataVal then
					dataVal = Instance.new("StringValue")
					dataVal.Name = ENTRY_DATA_VALUE_NAME
					dataVal.Parent = found2
				end
				-- If memResolvedEntry or entryObj present, write them; otherwise leave as-is
				if memResolvedEntry then
					if type(memResolvedEntry) == "table" then
						dataVal.Value = encodeEntry(memResolvedEntry)
					else
						dataVal.Value = tostring(memResolvedEntry)
					end
				else
					if type(entry) == "string" then
						dataVal.Value = entry
					elseif type(entryObj) == "table" then
						dataVal.Value = encodeEntry(entryObj)
					else
						dataVal.Value = encodeEntry({id = canonicalId})
					end
				end
				consumedFolders[desiredName] = found2
				if DEBUG then pcall(function() print(("[InvFolder_DEBUG] Reused existingByName for desiredName=%s"):format(desiredName)) end) end
			else
				-- No suitable folder in this field: create one (but we already attempted to move one from other fields above)
				local ef = Instance.new("Folder")
				ef.Name = desiredName
				ef.Parent = fld
				local dataVal = Instance.new("StringValue")
				dataVal.Name = ENTRY_DATA_VALUE_NAME
				if memResolvedEntry then
					if type(memResolvedEntry) == "table" then
						dataVal.Value = encodeEntry(memResolvedEntry)
					else
						dataVal.Value = tostring(memResolvedEntry)
					end
				else
					if type(entry) == "string" then
						dataVal.Value = entry
					elseif type(entryObj) == "table" then
						dataVal.Value = encodeEntry(entryObj)
					else
						dataVal.Value = encodeEntry({id = canonicalId})
					end
				end
				dataVal.Parent = ef
				consumedFolders[desiredName] = ef
				if DEBUG then pcall(function() print(("[InvFolder_DEBUG] Created new folder for id=%s name=%s"):format(canonicalId, desiredName)) end) end
			end
		else
			-- non-id entry: try reuse placeholder
			local reused = nil
			while placeholderIndex <= #placeholderFolders do
				local cand = placeholderFolders[placeholderIndex]
				placeholderIndex = placeholderIndex + 1
				if cand and cand.Parent == fld and (not consumedFolders[cand.Name]) then
					reused = cand
					break
				end
			end
			if reused then
				local dataVal = reused:FindFirstChild(ENTRY_DATA_VALUE_NAME)
				if not dataVal then
					dataVal = Instance.new("StringValue")
					dataVal.Name = ENTRY_DATA_VALUE_NAME
					dataVal.Parent = reused
				end
				if type(entry) == "string" then
					dataVal.Value = entry
				elseif type(entryObj) == "table" then
					dataVal.Value = encodeEntry(entryObj)
				else
					dataVal.Value = encodeEntry({}) -- best-effort
				end
				consumedFolders[reused.Name] = reused
				if DEBUG then pcall(function() print(("[InvFolder_DEBUG] Reused placeholder folder %s for non-id entry"):format(reused.Name)) end) end
			else
				local uniqueName = makeUniqueIndex()
				local ef = Instance.new("Folder")
				ef.Name = uniqueName
				ef.Parent = fld
				local dataVal = Instance.new("StringValue")
				dataVal.Name = ENTRY_DATA_VALUE_NAME
				if type(entry) == "string" then
					dataVal.Value = entry
				elseif type(entryObj) == "table" then
					dataVal.Value = encodeEntry(entryObj)
				else
					dataVal.Value = encodeEntry({})
				end
				dataVal.Parent = ef
				consumedFolders[uniqueName] = ef
				if DEBUG then pcall(function() print(("[InvFolder_DEBUG] Created new placeholder folder %s for non-id entry"):format(uniqueName)) end) end
			end
		end
	end

	-- DEFERRED/SAFE placeholder cleanup:
	-- Do NOT immediately destroy leftover placeholder folders. Instead, schedule a short delayed check (0.35s).
	for _,pf in ipairs(placeholderFolders) do
		if pf and pf.Parent == fld and (not consumedFolders[pf.Name]) then
			local folderRef = pf
			-- Slightly longer delay to avoid treating quick reparent moves or immediate restores as permanent.
			task.delay(0.35, function()
				-- ensure still present and still considered a placeholder
				if not folderRef or not folderRef.Parent or folderRef.Parent ~= fld then return end
				local data = folderRef:FindFirstChild(ENTRY_DATA_VALUE_NAME)
				local dec = nil
				if data and type(data.Value) == "string" and data.Value ~= "" then
					local ok, t = pcall(function() return HttpService:JSONDecode(data.Value) end)
					if ok and type(t) == "table" then dec = t end
				end

				-- Skip destroy if this placeholder was produced by a restore or marked to preserve
				local skipDestroy = false
				-- If folder has attributes or children that indicate restore/restore-stamp/preserve, skip
				pcall(function()
					local restoreStamp = folderRef.GetAttribute and folderRef:GetAttribute("RestoreStamp")
					local serverRestore = folderRef.GetAttribute and folderRef:GetAttribute("ServerRestore")
					local preserve = folderRef.GetAttribute and folderRef:GetAttribute("PreserveOnServer")
					if restoreStamp or serverRestore or preserve then
						skipDestroy = true
					end
				end)

				if dec then
					local possibleId = dec.ToolUniqueId or dec.ToolUid or dec.SlimeId or dec.slimeId or dec.id or dec.Id
					if possibleId then
						-- If a tool instance exists for this player with this id, skip destroying the placeholder.
						local toolInst = findToolForPlayerById(player, possibleId)
						if toolInst then
							skipDestroy = true
							if DEBUG then dprint(("InvFolder: skipping destroy of placeholder %s because matching tool exists for player %s id=%s"):format(folderRef.Name, player.Name, tostring(possibleId))) end
						end
					end
				end

				-- Additional check: if player's in-memory state still references this folder's id, skip
				if not skipDestroy and dec then
					local possibleId = dec.ToolUniqueId or dec.ToolUid or dec.SlimeId or dec.slimeId or dec.id or dec.Id
					if possibleId and st and st.fields and st.fields[fieldName] and st.fields[fieldName].list then
						for _,entry in ipairs(st.fields[fieldName].list) do
							local idCandidate = nil
							if type(entry) == "table" then
								idCandidate = entry.ToolUniqueId or entry.ToolUid or entry.SlimeId or entry.slimeId or entry.id or entry.Id
							elseif type(entry) == "string" then
								idCandidate = entry
							end
							if idCandidate and tostring(idCandidate) == tostring(possibleId) then
								skipDestroy = true
								if DEBUG then dprint(("InvFolder: skipping destroy of placeholder %s because in-memory state references id=%s"):format(folderRef.Name, tostring(possibleId))) end
								break
							end
						end
					end
				end

				if not skipDestroy then
					pcall(function()
						if DEBUG then dprint(("InvFolder: destroying leftover placeholder %s for player=%s field=%s"):format(folderRef.Name, player.Name, fieldName)) end
						-- Use safe removal helper instead of direct Destroy()
						local okRem, code = safeRemoveOrDefer(folderRef, "PlaceholderCleanup", { grace = 2 })
						if not okRem and code == "skipped_protected_recent" and DEBUG then
							dprint(("InvFolder: deferred skip of placeholder %s code=%s"):format(folderRef.Name, tostring(code)))
						end
					end)
				end
			end)
		end
	end

	-- dedupe placeholders that decode to canonical id
	for _,child in ipairs(fld:GetChildren()) do
		if child:IsA("Folder") and child.Name:match("^"..ENTRY_FOLDER_PREFIX) then
			local data = child:FindFirstChild(ENTRY_DATA_VALUE_NAME)
			if data and type(data.Value) == "string" and data.Value ~= "" then
				local ok, t = pcall(function() return HttpService:JSONDecode(data.Value) end)
				if ok and type(t) == "table" then
					local id = t.id or t.Id or t.eggId or t.EggId or t.SlimeId or t.slimeId or t.UID or t.uid or t.ToolUniqueId
					if id then
						local canonName = ENTRY_FOLDER_PREFIX .. tostring(id)
						local canonicalFolder = fld:FindFirstChild(canonName)
						if canonicalFolder and canonicalFolder ~= child and child.Name ~= canonName then
							pcall(function()
								if DEBUG then pcall(function() print(("[InvFolder_DEBUG] Removing duplicate placeholder %s because canonical %s exists and both decode id=%s"):format(child.Name, canonName, tostring(id))) end) end
								-- Use safe removal helper
								local okRem, code = safeRemoveOrDefer(child, "DedupePlaceholder", { grace = 2 })
								if not okRem and code == "skipped_protected_recent" and DEBUG then
									dprint(("InvFolder: skipped dedupe destroy for %s code=%s"):format(child.Name, tostring(code)))
								end
							end)
						end
					end
				end
			end
		end
	end

	local cnt = 0
	for _,c in ipairs(fld:GetChildren()) do
		if c:IsA("Folder") and c.Name:match("^"..ENTRY_FOLDER_PREFIX) then cnt = cnt + 1 end
	end
	local cv = fld:FindFirstChild("Count")
	if cv then pcall(function() cv.Value = cnt end) end

	if DEBUG then
		pcall(function() print(("[InvFolder] Updated %s.%s entries=%d"):format(player.Name, fieldName, #list)) end)
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
local function shouldPreserveExistingOnEmpty(existingList, incomingList)
	if not existingList or #existingList == 0 then
		return false
	end
	incomingList = incomingList or {}
	if #incomingList == 0 then
		return true
	end
	return false
end

local function logSuppressedClear(player, field)
	warnLog(("[InvMerge] Suppressed clearing of %s for %s because incoming snapshot was empty while existing state contained items"):format(field, player.Name))
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
			local meta = SerializerMeta["GrandInventorySerializer"]
			if meta and meta.hasSerialize then
				if meta.isFunction then
					serializedPayload = meta.serializer(player, finalFlag)
				else
					serializedPayload = meta.serializer:Serialize(player, finalFlag)
				end
			else
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
			-- Preserve any explicit meta flags (explicitlyCleared) if previously set
			local keepMeta = fld.meta and fld.meta.explicitlyCleared
			fld.meta = keepMeta and { explicitlyCleared = true } or nil
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

		local ok1, err1 = pcall(function()
			PlayerProfileService.SaveNow(player, reason or "InventoryUpdate")
		end)
		if not ok1 then
			warnLog(("SaveNow failed for %s reason=%s err=%s"):format(player.Name, tostring(reason), tostring(err1)))
		else
			dprint(("SaveNow requested for %s reason=%s"):format(player.Name, tostring(reason)))
		end

		if finalFlag then
			local ok2, res2 = pcall(function()
				if type(PlayerProfileService.SaveNowAndWait) == "function" then
					return PlayerProfileService.SaveNowAndWait(player, 5, true)
				elseif type(PlayerProfileService.ForceFullSaveNow) == "function" then
					return PlayerProfileService.ForceFullSaveNow(player, reason or "InventoryFinal")
				else
					PlayerProfileService.SaveNow(player, reason or "InventoryFinal")
					if type(PlayerProfileService.WaitForSaveComplete) == "function" then
						local done, success = PlayerProfileService.WaitForSaveComplete(player, 5)
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

-- REPLACE: migrate_short_folders_to_canonical -> uses safeRemoveOrDefer instead of blind Destroy
local function migrate_short_folders_to_canonical(player)
	local inv = player:FindFirstChild(PLAYER_INVENTORY_FOLDER)
	if not inv then return end
	for short, canon in pairs(CANONICAL_FROM_SHORT) do
		local shortFld = inv:FindFirstChild(short)
		local canonFld = inv:FindFirstChild(canon)
		if shortFld and shortFld:IsA("Folder") then
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
					-- Reparent into canonical field
					pcall(function() child.Parent = canonFld end)
				end
			end
			local cnt = 0
			for _,c in ipairs(canonFld:GetChildren()) do if c:IsA("Folder") and c.Name:match("^"..ENTRY_FOLDER_PREFIX) then cnt = cnt + 1 end end
			local countVal = canonFld:FindFirstChild("Count")
			if countVal then countVal.Value = cnt end
			-- Use safe removal for the legacy short folder (do not blindly Destroy)
			pcall(function()
				local ok, code = safeRemoveOrDefer(shortFld, "MigrateShortFolder", { grace = 2 })
				if not ok then
					-- if skip, just detach to keep structure stable
					pcall(function() shortFld.Parent = nil end)
				end
			end)
		end
	end
end

local function normalizeRestoreTarget(playerArg, profile)
	if type(profile) == "table" and profile.inventory ~= nil then
		return profile
	end
	if type(playerArg) == "table" and type(playerArg.FindFirstChildOfClass) == "function" then
		return playerArg
	end
	if type(playerArg) == "table" and playerArg.inventory ~= nil then
		return playerArg
	end
	if tonumber(playerArg) then
		return tonumber(playerArg)
	end
	if type(playerArg) == "string" then
		local pl = Players:FindFirstChild(playerArg)
		if pl then return pl end
		local prof = safe_get_profile_any(playerArg)
		if prof then return prof end
		local ok, res = pcall(function() return Players:GetUserIdFromNameAsync(playerArg) end)
		if ok and res and tonumber(res) then
			return tonumber(res)
		end
	end
	return nil
end

function InventoryService.RestorePlayer(player, savedData)
	local st = ensureState(player)
	if st.restoreCompleted then
		dprint(("RestorePlayer: already completed for %s; skipping"):format(player.Name))
		return
	end
	-- Wait for InventoryReady before running restore logic
	waitForInventoryReady(player, 6)
	-- ... [rest of RestorePlayer function unchanged]
	local incomingFields = (savedData and savedData.fields) or {}
	dprint(("RestorePlayer called for %s - incomingFields=%d"):format(player.Name, (incomingFields and (function() local c=0; for k,_ in pairs(incomingFields) do c=c+1 end return c end)() or 0)))
	local normalized = {}
	for fieldName, payload in pairs(incomingFields) do
		local canonical = canonicalizeFieldName(fieldName) or fieldName
		if type(payload) == "table" then
			if type(payload.list) == "table" then
				normalized[canonical] = payload.list
			elseif payload[1] ~= nil or next(payload) == nil then
				normalized[canonical] = payload
			else
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
	local profile = safe_get_profile_for_player(player)
	if not profile then
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
	if not profile then
		profile = wait_for_profile(player, 1.5)
		if profile then
			dprint(("RestorePlayer: WaitForProfile returned profile for %s"):format(player.Name))
		end
	end
	if profile then
		pcall(function()
			local uid = profile.userId or profile.UserId or profile.id or "unknown"
			dprint(("RestorePlayer: profile object for %s: %s (userId=%s)"):format(player.Name, tostring(profile), tostring(uid)))
		end)
	else
		dprint(("RestorePlayer: no profile available for %s at Restore time (will still attempt payload restore)"):format(player.Name))
	end
	migrate_short_folders_to_canonical(player)
	local serializerPayload = {
		et = normalized["eggTools"] or {},
		ft = normalized["foodTools"] or {},
		we = normalized["worldEggs"] or {},
		ws = normalized["worldSlimes"] or {},
		cs = normalized["capturedSlimes"] or {},
	}
	local restoreTarget = normalizeRestoreTarget(player, profile)
	if not restoreTarget and profile then restoreTarget = profile end
	if not restoreTarget then restoreTarget = tonumber(player.UserId) end
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
	local usedAdapter = false
	if RunService:IsServer() and type(PlayerProfileService.RestoreInventory) == "function" then
		local ppsTarget = profile
		if not ppsTarget then
			ppsTarget = wait_for_profile(player, 1.5)
		end
		local ok, err = pcall(function()
			if ppsTarget then
				PlayerProfileService.RestoreInventory(ppsTarget, serializerPayload)
			else
				PlayerProfileService.RestoreInventory(player, serializerPayload)
			end
		end)
		if not ok then
			warnLog("PlayerProfileService.RestoreInventory failed: "..tostring(err))
		else
			usedAdapter = true
			dprint(("PlayerProfileService.RestoreInventory invoked for %s (ppsTargetType=%s) [SERVER]"):format(player.Name, tostring(type(ppsTarget))))
		end
	end
	if not usedAdapter then
		local meta = SerializerMeta["GrandInventorySerializer"]
		if meta and meta.hasRestore then
			local serTarget = restoreTarget
			if type(serTarget) ~= "table" or (type(serTarget) == "table" and not serTarget.inventory) then
				local profTry = profile or wait_for_profile(player, 1.5)
				if profTry then
					serTarget = profTry
				end
			end
			local ok1, err1 = pcall(function()
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
	for fieldName, list in pairs(normalized) do
		list = type(list) == "table" and list or {}
		local existing = st.fields[fieldName] and st.fields[fieldName].list or nil
		if shouldPreserveExistingOnEmpty(existing, list) then
			logSuppressedClear(player, fieldName)
			updateInventoryFolder(player, fieldName, existing)
		else
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

-- Helper: robust matching across common id fields and string/number differences
local function matchesEntry(entry, idField, idValue)
	if not entry or not idValue then return false end
	local strId = tostring(idValue)
	if type(entry) ~= "table" then
		-- entry might be a string id
		if tostring(entry) == strId then return true end
		return false
	end
	-- check the requested idField first
	local candidate = entry[idField]
	if candidate ~= nil and tostring(candidate) == strId then return true end
	-- common alternate keys
	local altKeys = { "ToolUniqueId", "ToolUid", "UID", "uid", "ToolId", "ToolID", "SlimeId", "slimeId", "id", "Id", "EggId", "eggId" }
	for _,k in ipairs(altKeys) do
		local v = entry[k]
		if v ~= nil and tostring(v) == strId then return true end
	end
	-- nested Owner blocks sometimes:
	if entry.Owner and type(entry.Owner) == "table" then
		for _,k in ipairs(altKeys) do
			local v = entry.Owner[k]
			if v ~= nil and tostring(v) == strId then return true end
		end
	end
	return false
end

-- Remove world slime(s) from in-memory state and profile by SlimeId
local function removeWorldSlimeBySlimeId(player, slimeId)
	if not player or not slimeId then return false end
	local st = PlayerState[player]
	local removed = 0
	if st and st.fields and st.fields.worldSlimes and st.fields.worldSlimes.list then
		for i = #st.fields.worldSlimes.list, 1, -1 do
			local entry = st.fields.worldSlimes.list[i]
			local match = false
			if type(entry) == "table" then
				if entry.SlimeId and tostring(entry.SlimeId) == tostring(slimeId) then match = true end
				if not match and entry.id and tostring(entry.id) == tostring(slimeId) then match = true end
			elseif type(entry) == "string" then
				if tostring(entry) == tostring(slimeId) then match = true end
			end
			if match then
				table.remove(st.fields.worldSlimes.list, i)
				removed = removed + 1
			end
		end
		st.fields.worldSlimes.lastCount = #st.fields.worldSlimes.list
		st.fields.worldSlimes.version = (st.fields.worldSlimes.version or 0) + 1
		st.dirtyReasons["RemoveWorldSlime"] = true
		updateInventoryFolder(player, "worldSlimes", st.fields.worldSlimes.list)
	end

	-- Also try to remove from loaded profile if available
	local prof = safe_get_profile_for_player(player)
	if prof and prof.inventory and prof.inventory.worldSlimes then
		local persistedRemoved = 0
		for i = #prof.inventory.worldSlimes, 1, -1 do
			local e = prof.inventory.worldSlimes[i]
			if type(e) == "table" then
				local candidate = e.SlimeId or e.id or e.Id
				if candidate and tostring(candidate) == tostring(slimeId) then
					table.remove(prof.inventory.worldSlimes, i)
					persistedRemoved = persistedRemoved + 1
				end
			else
				if tostring(e) == tostring(slimeId) then
					table.remove(prof.inventory.worldSlimes, i)
					persistedRemoved = persistedRemoved + 1
				end
			end
		end
		if persistedRemoved > 0 then
			pcall(function() sanitizeInventoryOnProfile(prof) end)
			pcall(function() PlayerProfileService.SaveNow(player, "RemoveWorldSlime_OnCapture") end)
			dprint(("Removed %d persisted worldSlime entries for %s due to capture of SlimeId=%s"):format(persistedRemoved, player.Name, tostring(slimeId)))
		end
	end

	return removed > 0
end

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

	-- adding an item implies it's not an explicit clear anymore
	if st.fields[fieldName].meta then st.fields[fieldName].meta.explicitlyCleared = nil end

	st.dirtyReasons["AddInventoryItem"] = true

	-- Helper: attempt to extract SlimeId / ToolUniqueId from incoming itemData (table/string/userdata)
	local function inferIdsFromItem(d)
		local ids = {}
		if not d then return ids end
		local t = type(d)
		if t == "table" then
			if d.SlimeId then ids.SlimeId = tostring(d.SlimeId) end
			if d.slimeId then ids.SlimeId = ids.SlimeId or tostring(d.slimeId) end
			if d.id then ids.SlimeId = ids.SlimeId or tostring(d.id) end
			if d.ToolUniqueId then ids.ToolUniqueId = tostring(d.ToolUniqueId) end
			if d.ToolUid then ids.ToolUniqueId = ids.ToolUniqueId or tostring(d.ToolUid) end
		elseif t == "string" then
			-- string could be an id
			ids.SlimeId = tostring(d)
		elseif t == "userdata" or t == "Instance" then
			-- Try to read attributes/children safely via pcall in case the instance is nil/malformed
			pcall(function()
				if type(d.GetAttribute) == "function" then
					local a1 = d:GetAttribute("SlimeId") or d:GetAttribute("slimeId") or d:GetAttribute("id") or d:GetAttribute("Id")
					if a1 and tostring(a1) ~= "" then ids.SlimeId = tostring(a1) end
					local a2 = d:GetAttribute("ToolUniqueId") or d:GetAttribute("ToolUid")
					if a2 and tostring(a2) ~= "" then ids.ToolUniqueId = tostring(a2) end
				end
			end)

			-- Try child value objects (IntValue/StringValue etc.)
			pcall(function()
				local child = d:FindFirstChild("SlimeId") or d:FindFirstChild("slimeId") or d:FindFirstChild("id") or d:FindFirstChild("Id")
				if child and child.Value ~= nil and tostring(child.Value) ~= "" then
					ids.SlimeId = ids.SlimeId or tostring(child.Value)
				end
				local child2 = d:FindFirstChild("ToolUniqueId") or d:FindFirstChild("ToolUid")
				if child2 and child2.Value ~= nil and tostring(child2.Value) ~= "" then
					ids.ToolUniqueId = ids.ToolUniqueId or tostring(child2.Value)
				end
			end)

			-- Fallback: Name that looks like a guid/id
			pcall(function()
				if not ids.SlimeId and tostring(d.Name):match("[A-Fa-f0-9%-]+") then
					ids.SlimeId = tostring(d.Name)
				end
			end)
		end
		return ids
	end

	-- If this is a capturedSlime, proactively remove any matching worldSlime entries (by SlimeId)
	if fieldName == "capturedSlimes" then
		local ids = inferIdsFromItem(itemData)
		local sid = ids.SlimeId
		local toolUid = ids.ToolUniqueId

		-- If we didn't find an id yet but itemData is JSON string/table in player's state, try fallback decoding if needed
		if (not sid) and type(itemData) == "string" then
			local ok, dec = pcall(function() return HttpService:JSONDecode(itemData) end)
			if ok and type(dec) == "table" then
				sid = sid or (dec.SlimeId or dec.slimeId or dec.id)
				toolUid = toolUid or (dec.ToolUniqueId or dec.ToolUid)
			end
		end

		-- If still not found, try to check the last inserted element in the player's in-memory list (defensive)
		if (not sid) then
			local lst = st.fields[fieldName] and st.fields[fieldName].list
			if lst and #lst > 0 then
				local cand = lst[#lst]
				if type(cand) == "table" then
					sid = sid or (cand.SlimeId or cand.slimeId or cand.id)
					toolUid = toolUid or (cand.ToolUniqueId or cand.ToolUid)
				end
			end
		end

		if sid then
			local ok, removed = pcall(function() return removeWorldSlimeBySlimeId(ply, sid) end)
			if ok and removed and DEBUG then
				dprint(("AddInventoryItem: immediately removed matching worldSlime(s) for player=%s SlimeId=%s"):format(ply.Name, tostring(sid)))
			end
		elseif toolUid then
			-- If we don't have a SlimeId but have a ToolUniqueId, attempt removal by ToolUniqueId via RemoveInventoryItem helper (best-effort)
			pcall(function() InventoryService.RemoveInventoryItem(ply, "capturedSlimes", "ToolUniqueId", toolUid, { immediate = true }) end)
		end
	end

	updateInventoryFolder(ply, fieldName, st.fields[fieldName].list)
	if DEBUG then
		print(("[InvSvc] Added item to %s.%s (now %d)"):format(ply.Name, fieldName, #st.fields[fieldName].list))
	end

	local okUpd, errUpd = pcall(function()
		InventoryService.UpdateProfileInventory(ply)
	end)
	if not okUpd then warnLog("UpdateProfileInventory failed for add:", tostring(errUpd)) end

	if opts.immediate then
		local okSave, resSave = pcall(function()
			return requestVerifiedSave(ply, 3)
		end)
		if okSave and resSave then
			dprint(("Verified save succeeded for %s after AddInventoryItem"):format(ply.Name))
		else
			pcall(function() PlayerProfileService.SaveNow(ply, "InventoryAddImmediate_Fallback") end)
			dprint(("SaveNow (async) requested for %s after AddInventoryItem (verified unavailable)"):format(ply.Name))
		end
	else
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
	-- If no in-memory field, attempt profile-only removal fallback (unchanged behavior)
	if not fld or not fld.list then
		-- If profile is loaded while service has no state, attempt to update profile directly
		local prof = safe_get_profile_for_player(ply)
		if prof and prof.inventory and prof.inventory[category] then
			local removedAnyProfile = false
			for i = #prof.inventory[category], 1, -1 do
				local entry = prof.inventory[category][i]
				if matchesEntry(entry, idField, idValue) then
					table.remove(prof.inventory[category], i)
					removedAnyProfile = true
				end
			end
			if removedAnyProfile then
				pcall(function() sanitizeInventoryOnProfile(prof) end)
				pcall(function() PlayerProfileService.SaveNow(ply, "RemoveInventoryItem_ProfileFallback") end)
				-- Also attempt to remove any live tool instance owned by this player for the idValue
				pcall(function()
					-- only attempt Tool removal if idField suggests ToolUniqueId or SlimeId
					if idField and (tostring(idField):match("Tool") or tostring(idField):match("ToolUnique") or tostring(idField):match("SlimeId")) then
						local toolInst = findToolForPlayerById(ply, idValue)
						if toolInst and InventoryService._safeRemoveOrDefer then
							pcall(function() InventoryService._safeRemoveOrDefer(toolInst, "RemoveInventoryItem_ProfileFallback", { force = true }) end)
						end
					end
				end)
				return true
			end
		end
		return false, "no field"
	end

	local removedAny = false
	for i = #fld.list, 1, -1 do
		local entry = fld.list[i]
		if matchesEntry(entry, idField, idValue) then
			table.remove(fld.list, i)
			removedAny = true
		end
	end
	if not removedAny then return false, "not found" end

	-- update metadata & counts
	fld.lastCount = #fld.list
	fld.version = (fld.version or 0) + 1

	-- if explicit removal results in empty list, mark it so UpdateProfileInventory will clear it
	if fld.lastCount == 0 then
		fld.meta = fld.meta or {}
		fld.meta.explicitlyCleared = true
	end

	st.dirtyReasons["RemoveInventoryItem"] = true
	updateInventoryFolder(ply, category, fld.list)
	if DEBUG then
		print(("[InvSvc] Removed item(s) from %s.%s idField=%s id=%s (now %d)"):format(ply.Name, category, tostring(idField), tostring(idValue), fld.lastCount))
	end

	-- Attempt to remove any live Tool instance that matches this id (best-effort).
	-- Prefer ToolUniqueId but fall back to SlimeId-like identifiers.
	pcall(function()
		local candidateIds = {}
		if idField and idValue then
			table.insert(candidateIds, { field = idField, value = idValue })
		else
			-- If idField not provided, scan removed entries for id candidates
			-- (This branch is very defensive and should rarely run)
			for _,e in ipairs(fld.list) do
				if type(e) == "table" then
					local tu = e.ToolUniqueId or e.ToolUid or e.UID
					local sid = e.SlimeId or e.slimeId or e.id or e.Id
					if tu then table.insert(candidateIds, { field = "ToolUniqueId", value = tu }) end
					if sid then table.insert(candidateIds, { field = "SlimeId", value = sid }) end
				end
			end
		end

		for _,cand in ipairs(candidateIds) do
			if cand and cand.value then
				local okFind, toolInst = pcall(function() return findToolForPlayerById(ply, cand.value) end)
				if okFind and toolInst then
					-- Use safe removal helper exposed by InventoryService to avoid destroying newly-restored/preserved objects
					if InventoryService._safeRemoveOrDefer then
						local okRem, code = pcall(function() return InventoryService._safeRemoveOrDefer(toolInst, "RemoveInventoryItem", { force = true, grace = 0.5 }) end)
						if okRem and code then
							dprint(("RemoveInventoryItem: safe removed tool instance for player=%s id=%s code=%s"):format(ply.Name, tostring(cand.value), tostring(code)))
						end
					else
						-- fallback: try detach then destroy
						pcall(function() toolInst.Parent = nil end)
						pcall(function() toolInst:Destroy() end)
					end
				end
			end
		end
	end)

	-- If we removed a capturedSlime, also attempt to remove related worldSlime entries if they exist (no-op if none)
	if category == "capturedSlimes" then
		-- Try to infer a SlimeId from the removed idValue or from list entries removed; if idField indicates SlimeId, remove worldslime
		if idField and tostring(idField):match("SlimeId") then
			pcall(function() removeWorldSlimeBySlimeId(ply, idValue) end)
		end
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

--------------------------------------------------
-- New helper: Ensure an Entry_<id> folder exists under a player's field folder
--------------------------------------------------
function InventoryService.EnsureEntryHasId(playerOrId, fieldName, idValue, payloadTable)
	local ply = resolvePlayer(playerOrId)
	if not ply then return false, "no player" end
	fieldName = canonicalizeFieldName(fieldName) or fieldName
	local fld = ensureFieldFolder(ply, fieldName)
	if not fld then return false, "no folder" end

	local canonicalId = tostring(idValue)

	-- Normalize payload and only set eggId for egg-related categories
	payloadTable = payloadTable or {}
	payloadTable.id = tostring(payloadTable.id or canonicalId)

	if fieldName == "worldEggs" or fieldName == "eggTools" then
		payloadTable.eggId = payloadTable.eggId or payloadTable.id
	else
		-- ensure we don't accidentally propagate eggId onto non-egg entries
		payloadTable.eggId = nil
	end

	for _,entry in ipairs(fld:GetChildren()) do
		if entry:IsA("Folder") then
			local data = entry:FindFirstChild(ENTRY_DATA_VALUE_NAME)
			if data and type(data.Value) == "string" and data.Value ~= "" then
				local ok, t = pcall(function() return HttpService:JSONDecode(data.Value) end)
				if ok and type(t) == "table" and (t.id == canonicalId or t.eggId == canonicalId) then
					local desiredName = ENTRY_FOLDER_PREFIX .. canonicalId
					if entry.Name ~= desiredName then
						pcall(function() entry.Name = desiredName end)
					end
					return true
				end
			end
		end
	end

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
				-- ensure payloadTable has canonical id and only eggId for egg fields
				payloadTable = payloadTable or {}
				payloadTable.id = tostring(payloadTable.id or canonicalId)
				if fieldName == "worldEggs" or fieldName == "eggTools" then
					payloadTable.eggId = payloadTable.eggId or payloadTable.id
				else
					payloadTable.eggId = nil
				end

				local okEnc, enc = pcall(function() return HttpService:JSONEncode(payloadTable) end)
				if okEnc then
					pcall(function() data.Value = enc end)
				else
					pcall(function() data.Value = HttpService:JSONEncode({ id = canonicalId }) end)
				end
				pcall(function() entry.Name = ENTRY_FOLDER_PREFIX .. canonicalId end)

				local cnt = 0
				for _,c in ipairs(fld:GetChildren()) do if c:IsA("Folder") and c.Name:match("^"..ENTRY_FOLDER_PREFIX) then cnt = cnt + 1 end end
				local cv = fld:FindFirstChild("Count")
				if cv then pcall(function() cv.Value = cnt end) end

				pcall(function() InventoryService.UpdateProfileInventory(ply) end)
				pcall(function() PlayerProfileService.SaveNow(ply, "EnsureEntryHasId") end)
				return true
			end
		end
	end

	local okC, newEntry = pcall(function()
		local f = Instance.new("Folder")
		f.Name = ENTRY_FOLDER_PREFIX .. canonicalId
		local data = Instance.new("StringValue")
		data.Name = ENTRY_DATA_VALUE_NAME
		payloadTable = payloadTable or {}
		payloadTable.id = tostring(payloadTable.id or canonicalId)
		-- Only set eggId for egg categories
		if fieldName == "worldEggs" or fieldName == "eggTools" then
			payloadTable.eggId = payloadTable.eggId or payloadTable.id
		else
			payloadTable.eggId = nil
		end
		data.Value = (pcall(function() return HttpService:JSONEncode(payloadTable) end) and HttpService:JSONEncode(payloadTable)) or HttpService:JSONEncode({ id = canonicalId })
		data.Parent = f
		f.Parent = fld
		return f
	end)
	if okC and newEntry then
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
-- Helper: clean up legacy short keys in profile.inventory by merging them into canonical keys
--------------------------------------------------
local function merge_short_keys_into_profile_inventory(profile)
	if not profile or type(profile) ~= "table" or not profile.inventory or type(profile.inventory) ~= "table" then return end
	for short, canon in pairs(CANONICAL_FROM_SHORT) do
		if profile.inventory[short] and short ~= canon then
			-- If canonical missing, adopt short directly.
			if not profile.inventory[canon] or #profile.inventory[canon] == 0 then
				profile.inventory[canon] = profile.inventory[short]
				profile.inventory[short] = nil
				dprint(("Merged legacy short-key inventory '%s' -> '%s' for profile.userId=%s"):format(short, canon, tostring(profile.userId or profile.UserId)))
			else
				-- Both exist: merge unique by id then remove short.
				local existing = profile.inventory[canon]
				local idx = {}
				for _,e in ipairs(existing) do
					if type(e) == "table" then
						local id = e.Id or e.id or e.UID or e.uid or e.EggId or e.SlimeId or e.ToolId or e.ToolUniqueId
						if id then idx[tostring(id)] = true end
					end
				end
				local added = 0
				for _,e in ipairs(profile.inventory[short]) do
					if type(e) ~= "table" then
						table.insert(existing, e); added = added + 1
					else
						local id = e.Id or e.id or e.UID or e.uid or e.EggId or e.SlimeId or e.ToolId or e.ToolUniqueId
						if id then
							if not idx[tostring(id)] then
								table.insert(existing, e); idx[tostring(id)] = true; added = added + 1
							end
						else
							table.insert(existing, e); added = added + 1
						end
					end
				end
				profile.inventory[canon] = existing
				profile.inventory[short] = nil
				if added > 0 then
					dprint(("Merged %d entries from legacy short-key '%s' into '%s' for profile.userId=%s"):format(added, short, canon, tostring(profile.userId or profile.UserId)))
				else
					dprint(("Removed legacy short-key '%s' (no unique entries) for profile.userId=%s"):format(short, tostring(profile.userId or profile.UserId)))
				end
			end
		end
	end
end

--------------------------------------------------
-- NEW: Heavy-guard helpers (prevent accidental overwrite/wipe)
--------------------------------------------------
local function profileHasAnyInventoryData(profile)
	if not profile or type(profile) ~= "table" then return false end
	local inv = profile.inventory
	if not inv or type(inv) ~= "table" then return false end
	for k, v in pairs(inv) do
		if type(v) == "table" and #v > 0 then
			return true
		end
	end
	return false
end

local function stHasAnyInventoryData(st)
	if not st or type(st) ~= "table" or not st.fields then return false end
	for k, f in pairs(st.fields) do
		if f and type(f.list) == "table" and #f.list > 0 then
			return true
		end
	end
	return false
end

local function stHasExplicitClear(st)
	if not st or type(st) ~= "table" or not st.fields then return false end
	for k, f in pairs(st.fields) do
		if f and f.meta and f.meta.explicitlyCleared then
			return true
		end
	end
	return false
end

local function backupPersistedInventory(profile, player, reason)
	if not profile then return end
	profile.meta = profile.meta or {}
	local copy = {}
	for k, v in pairs(profile.inventory or {}) do
		if type(v) == "table" then
			local arr = {}
			for i, item in ipairs(v) do arr[i] = item end
			copy[k] = arr
		else
			copy[k] = v
		end
	end
	profile.meta[GuardConfig.BackupFieldName] = {
		ts = os.time(),
		reason = reason or "prevent_overwrite",
		inventory = copy,
	}
	-- Request SaveNow via PlayerProfileService if possible
	local ok, pps = pcall(function() return PlayerProfileService end)
	if ok and pps and type(pps.SaveNow) == "function" and player then
		pcall(function() pps.SaveNow(player, "InvGuard_BackupBeforePreventOverwrite") end)
		dprint("InvGuard: Requested SaveNow to persist inventory backup for player", tostring(player and player.Name))
	end
end

--------------------------------------------------
-- Helper: Update PlayerProfileService inventory from current InventoryService state
-- Modified to merge into the existing profile.inventory and remove legacy short keys.
-- Important: If a field was explicitly cleared by RemoveInventoryItem making it empty,
-- we WILL clear the profile's field (explicit clear). Otherwise we preserve non-empty profile values when incoming snapshot is empty.
-- Returns: true if profile was mutated/applied, false if prevented by guard
--------------------------------------------------
function InventoryService.UpdateProfileInventory(player, opts)
	local st = PlayerState[player]
	if not st then return false end
	local profile = safe_get_profile_for_player(player)
	if not profile then
		warnLog(("UpdateProfileInventory: no profile loaded for %s; skipping"):format(player.Name))
		return false
	end

	-- === NEW: Add override option to bypass guard ===
	opts = opts or {}
	local overrideEmptyGuard = opts.overrideEmptyGuard or false

	-- HEAVY GUARD: Prevent empty snapshot from overwriting an existing non-empty profile
	if GuardConfig.PreventEmptyOverwrite and not overrideEmptyGuard then
		local snapshotHasData = stHasAnyInventoryData(st)
		local profileHasData = profileHasAnyInventoryData(profile)
		local anyExplicitClear = stHasExplicitClear(st)

		-- Check for a recent PreExit/merge marker on the authoritative profile (set by PreExitInventorySync or GrandInventorySerializer.PreExitSync).
		local recentPreExit = false
		pcall(function()
			if profile.meta and type(profile.meta) == "table" then
				local ts = profile.meta.lastPreExitSnapshot or profile.meta.lastPreExitSync or profile.meta.__lastPreExitSnapshot or profile.meta.__lastPreExitSync
				if ts and tonumber(ts) then
					local window = tonumber(GuardConfig.InitialWindowSeconds) or 15
					if (os.time() - tonumber(ts)) <= window then
						recentPreExit = true
					end
				end
			end
		end)

		if (not snapshotHasData) and profileHasData and (not anyExplicitClear) and (not recentPreExit) then
			-- Prevent overwrite (no recent pre-exit merge to explain empty snapshot)
			warnLog(("[InvGuard] PREVENTED overwrite for %s - incoming snapshot all-empty while profile has data. Backing up and skipping profile mutation.\n[STATE] Service snapshot: %s\n[STATE] Profile inventory: %s")
				:format(
					player.Name,
					jsonEncodeSafe(st.fields),
					jsonEncodeSafe(profile.inventory)
				)
			)

			-- Backup current persisted inventory if configured
			if GuardConfig.BackupOnPrevent then
				pcall(function() backupPersistedInventory(profile, player, "incoming-empty-snapshot") end)
			end

			-- Update inventory folder visuals (so client sees current service state) but DO NOT mutate profile.inventory
			for field, data in pairs(st.fields) do
				local canonical = canonicalizeFieldName(field) or field
				updateInventoryFolder(player, canonical, data.list or {})
			end

			-- Annotate profile.meta with last prevented overwrite for diagnostics
			profile.meta = profile.meta or {}
			profile.meta.__lastPreventedOverwrite = { ts = os.time(), reason = "incoming-empty-snapshot" }

			-- Do not call SaveNow here to avoid an overwrite; backupPersistedInventory already requested a SaveNow.
			return false
		else
			if recentPreExit then
				dprint(("[InvGuard] recent PreExit merge detected for %s (allowing empty service snapshot to coexist with profile data)"):format(player.Name))
			end
		end
	end

	-- capture before-state counts
	local before = {}
	if profile.inventory then
		for k,v in pairs(profile.inventory) do before[k] = #v end
	end

	-- Ensure profile.inventory exists
	profile.inventory = profile.inventory or {}

	-- Merge Service state into profile.inventory.
	for field, data in pairs(st.fields) do
		local canonical = canonicalizeFieldName(field) or field
		local incoming = data.list or {}
		local existing = profile.inventory[canonical]

		-- If incoming empty but existing non-empty, preserve existing to avoid accidental clearing
		if shouldPreserveExistingOnEmpty(existing, incoming) then
			-- But allow explicit clears (RemoveInventoryItem set .meta.explicitlyCleared)
			if data.meta and data.meta.explicitlyCleared then
				-- explicit clear requested -> write empty list
				profile.inventory[canonical] = {}
				dprint(("UpdateProfileInventory: explicit clear for %s.%s applied"):format(player.Name, canonical))
			else
				logSuppressedClear(player, canonical)
				-- keep profile.inventory unchanged
			end
		else
			-- otherwise set/overwrite the field
			profile.inventory[canonical] = incoming
		end
	end

	-- If capturedSlimes exist in profile, remove matching worldSlimes entries (captured slimes shouldn't remain as world entries)
	local removedWorldSlimes = false
	if profile.inventory and profile.inventory.capturedSlimes and profile.inventory.worldSlimes then
		local cs = profile.inventory.capturedSlimes
		local ws = profile.inventory.worldSlimes
		-- build set of captured SlimeIds
		local capturedSet = {}
		for _,entry in ipairs(cs) do
			if type(entry) == "table" then
				local sid = entry.SlimeId or entry.slimeId or entry.id or entry.Id
				if sid then capturedSet[tostring(sid)] = true end
			end
		end
		if next(capturedSet) then
			for i = #ws, 1, -1 do
				local e = ws[i]
				local sid = nil
				if type(e) == "table" then
					sid = e.SlimeId or e.slimeId or e.id or e.Id
				else
					sid = tostring(e)
				end
				if sid and capturedSet[tostring(sid)] then
					table.remove(ws, i)
					removedWorldSlimes = true
				end
			end
			if removedWorldSlimes then
				profile.inventory.worldSlimes = ws
				dprint(("UpdateProfileInventory: removed worldSlimes entries that were captured for %s"):format(player.Name))
			end
		end
	end

	-- Merge any legacy short keys (cs, et, ft, ws, we) into canonical keys and remove short keys
	merge_short_keys_into_profile_inventory(profile)

	local after = {}
	for k,v in pairs(profile.inventory) do after[k] = #v end

	dprint(("UpdateProfileInventory: player=%s profile inventory updated (before=%s)(after=%s) removedWorldSlimes=%s")
		:format(player.Name, jsonEncodeSafe(before), jsonEncodeSafe(after), tostring(removedWorldSlimes)))

	-- === COIN PRESERVATION SAFEGUARD ===
	-- If the canonical profile appears to have missing/zero coins while the authoritative
	-- PlayerProfileService.GetCoins reports a positive amount, restore it into the profile
	-- to avoid triggers of PlayerProfileService's destructive-write checks later.
	pcall(function()
		profile.core = profile.core or {}
		local curCoins = profile.core.coins
		if (not curCoins) or type(curCoins) ~= "number" or curCoins == 0 then
			local okGet, authoritativeCoins = pcall(function()
				-- Best-effort read from PlayerProfileService authoritative accessor
				return PlayerProfileService and PlayerProfileService.GetCoins and PlayerProfileService.GetCoins(player)
			end)
			if okGet and tonumber(authoritativeCoins) and authoritativeCoins > 0 then
				-- Restore into the canonical profile and also use SetCoins API to ensure PlayerProfileService bookkeeping
				profile.core.coins = authoritativeCoins
				pcall(function() PlayerProfileService.SetCoins(player, authoritativeCoins) end)
				dprint(("UpdateProfileInventory: restored profile.core.coins from authoritative store for %s coins=%s"):format(player.Name, tostring(authoritativeCoins)))
			end
		end
	end)

	-- Sanitize profile inventory to ensure safe persistent shape
	pcall(function() sanitizeInventoryOnProfile(profile) end)

	-- Use async SaveNow to persist these inventory updates (non-blocking)
	local ok, err = pcall(function() PlayerProfileService.SaveNow(player, "InventorySync") end)
	if not ok then
		warnLog(("SaveNow failed in UpdateProfileInventory for %s err=%s"):format(player.Name, tostring(err)))
	else
		dprint(("SaveNow requested for %s after UpdateProfileInventory"):format(player.Name))
	end

	return true
end

--------------------------------------------------
-- FinalizePlayer: Produce final serialize snapshot, update profile inventory and request verified save.
-- This is the function that PreExitInventorySync expects to exist and call on leave flows.
-- It now respects the heavy guard: if UpdateProfileInventory prevented the merge (returned false),
-- FinalizePlayer will not request a verified save to avoid persisting an empty wipe.
--------------------------------------------------
function InventoryService.FinalizePlayer(playerOrId, reason)
	local ply = resolvePlayer(playerOrId)
	if not ply then
		-- If we were passed a userId, try to use that to call SaveNow at least
		if type(playerOrId) == "number" then
			pcall(function() PlayerProfileService.SaveNow(playerOrId, reason or "FinalizePlayer_Fallback") end)
		end
		return false, "no player"
	end

	local st = PlayerState[ply] or ensureState(ply)

	-- 1) Serialize player (final) to ensure in-memory st.fields reflect serializer output before we merge
	local okSer, serErr = pcall(function()
		serializePlayer(ply, reason or "Leave", true)
	end)
	if not okSer then
		warnLog(("FinalizePlayer: serializePlayer failed for %s err=%s"):format(ply.Name, tostring(serErr)))
	end

	-- 2) Update profile inventory from service state (this will apply explicit clears)
	local okUpd, retval = pcall(function()
		return InventoryService.UpdateProfileInventory(ply)
	end)
	if not okUpd then
		warnLog(("FinalizePlayer: UpdateProfileInventory failed for %s err=%s"):format(ply.Name, tostring(retval)))
	else
		-- If UpdateProfileInventory returned false, it means it prevented an overwrite (guard hit)
		if retval == false then
			-- guard prevented profile mutation; do not request a verified save (which would persist the empty snapshot).
			warnLog(("FinalizePlayer: Guard prevented profile overwrite for %s - skipping verified save to avoid accidental wipe."):format(ply.Name))
			return true
		end
	end

	-- 3) Request a verified save (best-effort)
	local okSave, saveRes = pcall(function()
		return requestVerifiedSave(ply, 5)
	end)
	if not okSave or not saveRes then
		-- Fallback: ForceFullSaveNow if available
		pcall(function()
			if type(PlayerProfileService.ForceFullSaveNow) == "function" then
				PlayerProfileService.ForceFullSaveNow(ply, reason or "FinalizePlayer_Fallback")
			else
				PlayerProfileService.SaveNow(ply, reason or "FinalizePlayer_Fallback")
			end
		end)
		dprint(("FinalizePlayer: Verified save unavailable for %s (fallback triggered)"):format(ply.Name))
	else
		dprint(("FinalizePlayer: Verified save succeeded for %s"):format(ply.Name))
	end

	return true
end

--------------------------------------------------
-- PERIODIC LOOP
--------------------------------------------------
local function periodicLoop()
	while true do
		task.wait(1)
		if not AUTO_PERIODIC_SERIALIZE then
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
	if RunService:IsServer() then
		local profile = tryGetProfileWithRetries(player, 8, 0.12)
		if profile and profile.inventory then
			dprint(("onPlayerAdded: invoking RestorePlayer for %s using profile inventory [SERVER]"):format(player.Name))
			InventoryService.RestorePlayer(player, { fields = profile.inventory })
		else
			dprint(("onPlayerAdded: profile missing or empty for %s; will attempt Restore when/if profile becomes available [SERVER]"):format(player.Name))
			task.delay(0.5, function()
				if player.Parent then
					local prof2 = wait_for_profile(player, 1.5) or safe_get_profile_for_player(player)
					if prof2 and prof2.inventory then
						dprint(("Delayed restore: invoking RestorePlayer for %s (delayed) [SERVER]"):format(player.Name))
						InventoryService.RestorePlayer(player, { fields = prof2.inventory })
					end
				end
			end)
		end
	else
		dprint(("onPlayerAdded: skipping restore for %s on client; server will restore"):format(player.Name))
	end
	-- Inventory is now ready AFTER restore logic runs
	setInventoryReady(player)
	if DEBUG then
		print(("[InvSvc] Player added, inventory root ready: %s"):format(player.Name))
	end
end


-- Defensive profile snapshot printer used on leave for diagnostics
local function _safePrintProfileInfo(player)
	local ok, prof = pcall(function() return safe_get_profile_for_player(player) end)
	if ok and type(prof) == "table" then
		local uid = prof.userId or prof.UserId or prof.id or tostring(player.UserId)
		local inv = prof.inventory or {}
		local counts = {}
		for k,v in pairs(inv) do counts[k] = #v end
		dprint(("LeavingProfileSnapshot: player=%s userId=%s persistentId=%s dataCounts=%s")
			:format(player.Name, tostring(uid), tostring(prof.persistentId or prof.persistentID or "unknown"), jsonEncodeSafe(counts)))
	else
		dprint(("LeavingProfileSnapshot: no profile table available for player=%s"):format(player.Name))
	end
end

local function onPlayerRemoving(player)
	-- Defensive wrapper for player leaving; avoid nil calls and log profile snapshot
	pcall(function()
		dprint(("onPlayerRemoving start for %s"):format(player.Name))
		-- Try to flush growth-related progress (if present) in a guarded way
		if SlimeCoreAvailable and SlimeCore and SlimeCore.GrowthService and type(SlimeCore.GrowthService.FlushPlayerSlimes) == "function" then
			local ok, err = pcall(function()
				SlimeCore.GrowthService.FlushPlayerSlimes(player.UserId)
			end)
			if not ok then warnLog(("FlushPlayerSlimes failed for %s: %s"):format(player.Name, tostring(err))) end
		else
			dprint(("FlushPlayerSlimes: not available for %s (SlimeCoreAvailable=%s)"):format(player.Name, tostring(SlimeCoreAvailable)))
		end

		-- Emit a short snapshot of profile inventory and persistent id for diagnostics
		_safePrintProfileInfo(player)

		-- Finalize and attempt final save; catch errors in serialize/finalize
		local okFinal, errFinal = pcall(function() InventoryService.FinalizePlayer(player, "Leave") end)
		if not okFinal then
			warnLog(("FinalizePlayer failed for %s: %s"):format(player.Name, tostring(errFinal)))
		else
			dprint(("FinalizePlayer invoked for %s"):format(player.Name))
		end

		-- Ensure we clear in-memory state only after we've attempted finalization
		PlayerState[player] = nil
		dprint(("onPlayerRemoving completed for %s (state cleared)"):format(player.Name))
	end)
end


--foodtool removel sequence begin

function InventoryService.FindToolForPlayerById(player, id)
	if not player or not id then return nil end
	local function matches(tool, idVal)
		if not tool then return false end
		if type(tool.GetAttribute) == "function" then
			local ok, tu = pcall(function() return tool:GetAttribute("ToolUniqueId") end)
			if ok and tu and tostring(tu) == tostring(idVal) then return true end
			local ok2, tu2 = pcall(function() return tool:GetAttribute("ToolUid") end)
			if ok2 and tu2 and tostring(tu2) == tostring(idVal) then return true end
			local ok3, sid = pcall(function() return tool:GetAttribute("SlimeId") end)
			if ok3 and sid and tostring(sid) == tostring(idVal) then return true end
		end
		-- check child Value objects fallback
		local child = tool:FindFirstChild("ToolUniqueId") or tool:FindFirstChild("ToolUid")
		if child and child.Value and tostring(child.Value) == tostring(idVal) then return true end
		local child2 = tool:FindFirstChild("SlimeId") or tool:FindFirstChild("slimeId")
		if child2 and child2.Value and tostring(child2.Value) == tostring(idVal) then return true end
		-- name fallback
		if tostring(tool.Name) == tostring(idVal) then return true end
		return false
	end

	-- check Backpack and Character first (fast, common)
	local containers = {}
	pcall(function() table.insert(containers, player:FindFirstChildOfClass("Backpack")) end)
	pcall(function() if player.Character then table.insert(containers, player.Character) end end)

	-- add a ServerStorage / workspace scan fallback (tools sometimes stored in ServerStorage)
	local ss = game:GetService("ServerStorage")
	if ss then pcall(function() table.insert(containers, ss) end) end

	-- scan descendants of the chosen containers
	for _, parent in ipairs(containers) do
		if parent and type(parent.GetDescendants) == "function" then
			for _, inst in ipairs(parent:GetDescendants()) do
				if inst and type(inst.IsA) == "function" and inst:IsA("Tool") then
					local ok, res = pcall(function() return matches(inst, id) end)
					if ok and res then return inst end
				end
			end
		end
	end

	-- final fallback: scan workspace for any tool owned by this user (rare)
	pcall(function()
		for _, inst in ipairs(workspace:GetDescendants()) do
			if inst and type(inst.IsA) == "function" and inst:IsA("Tool") then
				local ok, res = pcall(function() return matches(inst, id) end)
				if ok and res then
					-- ensure this tool seems owned by player (attribute or parent)
					local ownerOk, owner = pcall(function() return inst:GetAttribute("OwnerUserId") end)
					if ownerOk and tostring(owner) == tostring(player.UserId) then
						return inst
					end
				end
			end
		end
	end)

	return nil
end

-- Safely remove or defer removal of a Tool instance.
-- Parameters:
--   tool (Instance) : the Tool to remove
--   reason (string) : optional diagnostic reason
--   opts (table)    : optional { force = boolean, grace = seconds }
-- Returns true on success or false + message.
function InventoryService._safeRemoveOrDefer(tool, reason, opts)
	opts = opts or {}
	local force = opts.force or false
	local grace = tonumber(opts.grace) or 0.25

	if not tool or type(tool.IsA) ~= "function" or not tool:IsA("Tool") then
		return false, "invalid_tool"
	end

	-- If the tool is marked ServerRestore/PreserveOnServer, be conservative: unparent and mark RecentlyPlacedSaved then schedule destroy.
	local isPreserved = false
	pcall(function()
		if type(tool.GetAttribute) == "function" and (tool:GetAttribute("ServerRestore") or tool:GetAttribute("PreserveOnServer") or tool:GetAttribute("PersistentFoodTool")) then
			isPreserved = true
		end
	end)

	-- Attempt to detach first
	local detached = false
	pcall(function()
		if tool.Parent then
			tool.Parent = nil
			detached = true
		end
	end)

	-- If force or not preserved, destroy after small grace to allow replication to settle
	if force or not isPreserved then
		task.delay(grace, function()
			pcall(function()
				if tool and tool.Parent then tool.Parent = nil end
			end)
			pcall(function() if tool and tool.Destroy then tool:Destroy() end end)
		end)
		return true
	end

	-- If preserved, mark RecentlyPlacedSaved and schedule a deferred destroy (longer grace)
	pcall(function()
		if type(tool.SetAttribute) == "function" then
			tool:SetAttribute("RecentlyPlacedSaved", os.time())
			tool:SetAttribute("RecentlyPlacedSavedAt", os.time())
		end
	end)
	task.delay(math.max(0.5, grace * 4), function()
		pcall(function()
			if tool and tool.Parent then tool.Parent = nil end
			pcall(function() if tool and tool.Destroy then tool:Destroy() end end)
		end)
	end)
	return true
end
--- Food tool removal sequence ending ----
--------------------------------------------------
-- Automatic cleanup for destroyed captured-slime Tools
-- NOTE: patched handlers below defer confirmation to avoid treating short reparent moves as destruction.
--------------------------------------------------
local function _isCapturedSlimeTool(instance)
	if not instance or type(instance.IsA) ~= "function" then return false end
	if not instance:IsA("Tool") then return false end
	local persistent = instance:GetAttribute("PersistentCaptured")
	local slimeItem = instance:GetAttribute("SlimeItem")
	local capturedFlag = instance:GetAttribute("CapturedSlimeTool")
	local hasSlimeId = instance:GetAttribute("SlimeId") ~= nil
	if persistent or slimeItem or capturedFlag or hasSlimeId then return true end
	local name = instance.Name or ""
	if name:match("CapturedSlime") or name:match("Captured") then return true end
	return false
end

local function _cleanupCapturedEntryFromProfileByTool(tool)
	if not tool or type(tool.IsA) ~= "function" then return end
	if not _isCapturedSlimeTool(tool) then return end

	local uidAttr = tool:GetAttribute("OwnerUserId") or tool:GetAttribute("ownerUserId")
	local ownerUserId = tonumber(uidAttr) or nil
	local toolUid = tool:GetAttribute("ToolUniqueId") or tool:GetAttribute("ToolUid")
	local slimeId = tool:GetAttribute("SlimeId")

	-- If owner online, use InventoryService.RemoveInventoryItem to maintain consistent state and saves
	if ownerUserId then
		local ply = Players:GetPlayerByUserId(ownerUserId)
		if ply then
			-- prefer removing by ToolUniqueId if present
			if toolUid and tostring(toolUid) ~= "" then
				local ok, res = pcall(function() return InventoryService.RemoveInventoryItem(ply, "capturedSlimes", "ToolUniqueId", toolUid, { immediate = true }) end)
				if ok and res then
					dprint(("AutoCleanup: removed capturedSlime by ToolUniqueId=%s for player=%s"):format(tostring(toolUid), tostring(ply.Name)))
					return
				end
			end
			if slimeId then
				local ok2, res2 = pcall(function() return InventoryService.RemoveInventoryItem(ply, "capturedSlimes", "SlimeId", slimeId, { immediate = true }) end)
				if ok2 and res2 then
					dprint(("AutoCleanup: removed capturedSlime by SlimeId=%s for player=%s"):format(tostring(slimeId), tostring(ply.Name)))
					return
				end
			end
		else
			-- Owner offline: attempt to update profile table (if loaded) to remove entries and request save
			local prof = safe_get_profile_any(ownerUserId)
			if prof and type(prof) == "table" and prof.inventory and prof.inventory.capturedSlimes then
				local removed = 0
				for i=#prof.inventory.capturedSlimes,1,-1 do
					local entry = prof.inventory.capturedSlimes[i]
					if type(entry) == "table" then
						if toolUid and (entry.ToolUniqueId == toolUid or entry.ToolUid == toolUid) then
							table.remove(prof.inventory.capturedSlimes, i); removed = removed + 1
						elseif slimeId and (entry.SlimeId == slimeId or entry.slimeId == slimeId) then
							table.remove(prof.inventory.capturedSlimes, i); removed = removed + 1
						end
					end
				end
				if removed > 0 then
					pcall(function() PlayerProfileService.SaveNow(ownerUserId, "AutoCleanup_CapturedSlimeRemoved") end)
					dprint(("AutoCleanup: removed %d persisted capturedSlime entries for offline userId=%s"):format(removed, tostring(ownerUserId)))
					return
				end
			end
		end
	end

	-- If we cannot resolve an owner, try to infer from tool attributes and remove from any matching loaded profile lists
	local toolIdCandidates = {}
	if toolUid and tostring(toolUid) ~= "" then table.insert(toolIdCandidates, { field="ToolUniqueId", value=toolUid }) end
	if slimeId then table.insert(toolIdCandidates, { field="SlimeId", value=slimeId }) end
	if #toolIdCandidates == 0 then return end

	local anyRemoved = 0
	for _,pl in ipairs(Players:GetPlayers()) do
		local prof = safe_get_profile_for_player(pl)
		if prof and prof.inventory and prof.inventory.capturedSlimes then
			local removedHere = 0
			for _,cand in ipairs(toolIdCandidates) do
				for i=#prof.inventory.capturedSlimes,1,-1 do
					local entry = prof.inventory.capturedSlimes[i]
					if type(entry) == "table" and (entry[cand.field] == cand.value or entry.ToolUniqueId == cand.value or entry.ToolUid == cand.value or entry.SlimeId == cand.value) then
						table.remove(prof.inventory.capturedSlimes, i)
						removedHere = removedHere + 1
					end
				end
			end
			if removedHere > 0 then
				anyRemoved = anyRemoved + removedHere
				pcall(function() PlayerProfileService.SaveNow(pl, "AutoCleanup_CapturedSlimeRemoved") end)
				dprint(("AutoCleanup: removed %d entries for online player %s"):format(removedHere, pl.Name))
			end
		end
	end
	if anyRemoved > 0 then
		return
	end
end

-- Safe helper to get an instance full name without throwing
local function safeGetFullName(inst)
	if not inst then return "<nil>" end
	local ok, name = pcall(function() return inst:GetFullName() end)
	if ok and name then return name end
	return tostring(inst)
end

-- Patched: defer confirmation before treating DescendantRemoving as permanent removal
-- Replace the _onDescendantRemoving handler with this full function.
local function _onDescendantRemoving(desc)
	pcall(function()
		if not desc then return end
		if not _isCapturedSlimeTool(desc) then return end

		-- Defer to confirm real destruction (not a quick reparent/move).
		-- If the instance is being moved (reparented), Roblox will reparent shortly.
		-- We do a micro-delay and only proceed if the instance still has no Parent and is not marked as restored/preserved.
		task.delay(0.18, function()
			local ok, parent = pcall(function() return desc.Parent end)
			if ok and parent ~= nil then
				-- It was reparented (move); ignore this DescendantRemoving.
				dprint(("AutoCleanup: ignored DescendantRemoving for %s because it was reparented to %s"):format(safeGetFullName(desc), safeGetFullName(parent)))
				return
			end

			-- If the instance is explicitly marked as a server restore/preserved, skip cleanup
			local skip = false
			pcall(function()
				if desc.GetAttribute and (desc:GetAttribute("ServerRestore") or desc:GetAttribute("PreserveOnServer") or desc:GetAttribute("RestoreStamp")) then
					skip = true
				end
			end)
			if skip then
				dprint(("AutoCleanup: skipping DescendantRemoving cleanup for %s due to restore/preserve flags"):format(safeGetFullName(desc)))
				return
			end

			-- Confirmed no parent after delay -> treat as removal/destroy
			pcall(function()
				_cleanupCapturedEntryFromProfileByTool(desc)
			end)
		end)
	end)
end

-- Patched: defer confirmation before treating AncestryChanged (parent==nil) as permanent removal
-- Replace the _onAncestryChanged handler with this full function.
local function _onAncestryChanged(child, parent)
	pcall(function()
		if not child then return end
		if not _isCapturedSlimeTool(child) then return end

		-- Only react when parent becomes nil (possible removal). Reparents may transiently produce nil parent.
		if parent ~= nil then
			-- new parent is non-nil => not a removal (likely reparent/add) -> ignore
			return
		end

		-- parent == nil: schedule a deferred confirmation to avoid false positives on move
		task.delay(0.18, function()
			local ok, p = pcall(function() return child.Parent end)
			if ok and p ~= nil then
				-- got reparented quickly, ignore
				dprint(("AutoCleanup: ignored AncestryChanged nil->reparent for %s now under %s"):format(safeGetFullName(child), safeGetFullName(p)))
				return
			end

			-- Skip cleanup if tool flagged as restored/preserved
			local skip = false
			pcall(function()
				if child.GetAttribute and (child:GetAttribute("ServerRestore") or child:GetAttribute("PreserveOnServer") or child:GetAttribute("RestoreStamp")) then
					skip = true
				end
			end)
			if skip then
				dprint(("AutoCleanup: skipping AncestryChanged cleanup for %s due to restore/preserve flags"):format(safeGetFullName(child)))
				return
			end

			-- still parentless -> treat as removal
			pcall(function() _cleanupCapturedEntryFromProfileByTool(child) end)
		end)
	end)
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

	for _,p in ipairs(Players:GetPlayers()) do
		onPlayerAdded(p)
	end
	if RunService:IsServer() then
		Players.PlayerAdded:Connect(onPlayerAdded)
		Players.PlayerRemoving:Connect(onPlayerRemoving)
	end

	local function tryRequireSlimeCore()
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

		pcall(function()
			if SlimeCore.Init and type(SlimeCore.Init) == "function" then
				SlimeCore.Init()
				dprint("SlimeCore.Init() invoked.")
			end
		end)

		if SlimeCore.GrowthPersistenceService and type(SlimeCore.GrowthPersistenceService.Init) == "function" then
			GrowthPersistenceOrchestrator = {
				MarkDirty = function(playerOrUser, reason)
					local ply = nil
					if type(playerOrUser) == "number" then
						ply = Players:GetPlayerByUserId(playerOrUser)
					elseif type(playerOrUser) == "table" and type(playerOrUser.FindFirstChildOfClass) == "function" then
						ply = playerOrUser
					end
					pcall(function()
						if ply then
							InventoryService.MarkDirty(ply, reason or "GrowthPersist_MarkDirty")
						end
					end)
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

			pcall(function() SlimeCore.GrowthPersistenceService:Init(GrowthPersistenceOrchestrator) end)
			dprint("GrowthPersistenceService.Init invoked with orchestrator.")
		else
			dprint("SlimeCore present but GrowthPersistenceService.Init not found; skipping orchestrator hookup.")
		end
	else
		dprint("SlimeCore not detected; continuing without integrated growth persistence.")
	end

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
	if RunService:IsServer() then
		Players.PlayerAdded:Connect(onPlayerAdded)
		Players.PlayerRemoving:Connect(onPlayerRemoving)
	end

	if not RunService:IsClient() then
		task.spawn(periodicLoop)
	end

	if AUTO_CLEANUP_REMOVED_TOOLS then
		pcall(function()
			workspace.DescendantRemoving:Connect(_onDescendantRemoving)
		end)
		pcall(function()
			if game:GetService("ServerStorage") then
				game:GetService("ServerStorage").DescendantRemoving:Connect(_onDescendantRemoving)
			end
		end)
		pcall(function()
			workspace.DescendantAdded:Connect(function(desc)
				if desc and type(desc.IsA) == "function" and desc:IsA("Tool") then
					desc.AncestryChanged:Connect(_onAncestryChanged)
				end
			end)
			for _,inst in ipairs(workspace:GetDescendants()) do
				if inst and type(inst.IsA) == "function" and inst:IsA("Tool") then
					inst.AncestryChanged:Connect(_onAncestryChanged)
				end
			end
		end)
		dprint("Auto cleanup for removed captured-slime Tools installed.")
	end

	local sCount = 0
	for _,_ in pairs(Serializers) do sCount = sCount + 1 end
	print(("[InvSvc] InventoryService %s initialized AutoPeriodic=%s Interval=%ds Serializers=%d")
		:format(InventoryService.__Version, tostring(AUTO_PERIODIC_SERIALIZE),
			SERIALIZE_INTERVAL_SECONDS, sCount))
	return InventoryService
end

-- Public bindings for simple helpers
InventoryService.MarkDirty = function(player, reason) markDirty(player, reason) end

--------------------------------------------------
-- Runtime configuration helpers
-- - InventoryService.SetDebug(enabled) toggles debug prints at runtime.
-- - InventoryService.Configure(opts) accepts a table of config overrides.
-- - InventoryService.GetConfig() returns a snapshot of current config.
--------------------------------------------------
function InventoryService.SetDebug(enabled)
	DEBUG = enabled and true or false
	dprint(("SetDebug: DEBUG=%s"):format(tostring(DEBUG)))
	return DEBUG
end

function InventoryService.Configure(opts)
	if type(opts) ~= "table" then return end
	if opts.DEBUG ~= nil then DEBUG = opts.DEBUG and true or false end
	if opts.LOG_SERIALIZE_VERBOSE ~= nil then LOG_SERIALIZE_VERBOSE = opts.LOG_SERIALIZE_VERBOSE and true or false end
	if opts.LOG_EMPTY_SUPPRESS ~= nil then LOG_EMPTY_SUPPRESS = opts.LOG_EMPTY_SUPPRESS and true or false end
	if opts.AUTO_PERIODIC_SERIALIZE ~= nil then AUTO_PERIODIC_SERIALIZE = opts.AUTO_PERIODIC_SERIALIZE and true or false end
	if opts.SERIALIZE_INTERVAL_SECONDS ~= nil then SERIALIZE_INTERVAL_SECONDS = tonumber(opts.SERIALIZE_INTERVAL_SECONDS) or SERIALIZE_INTERVAL_SECONDS end
	if opts.AUTO_CLEANUP_REMOVED_TOOLS ~= nil then AUTO_CLEANUP_REMOVED_TOOLS = opts.AUTO_CLEANUP_REMOVED_TOOLS and true or false end

	-- GuardConfig runtime toggles
	if opts.GuardConfig and type(opts.GuardConfig) == "table" then
		for k,v in pairs(opts.GuardConfig) do
			GuardConfig[k] = v
		end
	end

	dprint(("Configure applied: DEBUG=%s LOG_SERIALIZE_VERBOSE=%s AUTO_PERIODIC=%s Interval=%s AUTO_CLEANUP=%s Guard.PreventEmpty=%s")
		:format(tostring(DEBUG), tostring(LOG_SERIALIZE_VERBOSE), tostring(AUTO_PERIODIC_SERIALIZE), tostring(SERIALIZE_INTERVAL_SECONDS), tostring(AUTO_CLEANUP_REMOVED_TOOLS), tostring(GuardConfig.PreventEmptyOverwrite)))
end

function InventoryService.GetConfig()
	return {
		DEBUG = DEBUG,
		LOG_SERIALIZE_VERBOSE = LOG_SERIALIZE_VERBOSE,
		LOG_EMPTY_SUPPRESS = LOG_EMPTY_SUPPRESS,
		AUTO_PERIODIC_SERIALIZE = AUTO_PERIODIC_SERIALIZE,
		SERIALIZE_INTERVAL_SECONDS = SERIALIZE_INTERVAL_SECONDS,
		MAX_ENTRIES_PER_FIELD = MAX_ENTRIES_PER_FIELD,
		AUTO_CLEANUP_REMOVED_TOOLS = AUTO_CLEANUP_REMOVED_TOOLS,
		GuardConfig = GuardConfig,
	}
end

return InventoryService