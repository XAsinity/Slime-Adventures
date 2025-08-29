-- InventoryService.lua
-- Version: v3.1.0-grand-unified-support
-- (patched: AddInventoryItem/RemoveInventoryItem now sync profile immediately and request ForceFullSaveNow
--  to improve persistence reliability for purchases/consumes)

local InventoryService = {}
InventoryService.__Version = "v3.1.0-grand-unified-support"
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
local PlayerProfileService = require(game:GetService("ServerScriptService").Modules:WaitForChild("PlayerProfileService"))

--------------------------------------------------
-- REGISTRY
--------------------------------------------------
local Serializers = {}

function InventoryService.RegisterSerializer(name, serializer)
	Serializers[name] = serializer
end

local function resolveSerializerName(serializer)
	return (serializer and serializer.Name) or "UnknownSerializer"
end

--------------------------------------------------
-- LOG HELPERS
--------------------------------------------------
local function dprint(...) if DEBUG then print("[InvSvc]", ...) end end
local function warnLog(...) warn("[InvWarn]", ...) end

--------------------------------------------------
-- PLAYER STATE
--------------------------------------------------
local PlayerState = {}

local function ensureState(player)
	-- expects a player Instance (this service keys state by player Instance)
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
	}
	PlayerState[player] = st
	return st
end

local function markDirty(player, reason)
	-- player must be Instance
	local st = ensureState(player)
	st.dirtyReasons[reason or "Unknown"] = true
end

--------------------------------------------------
-- HELPER: resolve player object from player or userId
--------------------------------------------------
local function resolvePlayer(playerOrId)
	if not playerOrId then return nil end
	-- Prefer Roblox typeof check for Instance when available
	if typeof and typeof(playerOrId) == "Instance" and playerOrId:IsA("Player") then
		return playerOrId
	end
	-- Fallback: table-like with UserId (roblox userdata)
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
	for _,ev in ipairs(st.captureEvents) do sum += ev.count end
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
-- SERIALIZE PLAYER (grand serializer aware)
--------------------------------------------------
local function buildBlob(player, st)
	local blob = { v=st.snapshotVersion, fields={} }
	for name,f in pairs(st.fields) do
		blob.fields[name] = { v=f.version, list=f.list, meta=f.meta }
	end
	return blob
end

local DebugFlags = require(script.Parent:WaitForChild("DebugFlags"))
local function invdbg(...)
	if DebugFlags.EggDebug then
		print("[EggDbg][InvSvc]", ...)
	end
end

local function serializePlayer(player, reason, finalFlag)
	local st = PlayerState[player]; if not st then return end
	st.lastSerialize = os.clock()
	local oldCounts = {}
	for name,f in pairs(st.fields) do
		oldCounts[name] = f.lastCount or 0
	end

	local anyChange = false

	-- GrandInventorySerializer support (if only one serializer registered)
	if Serializers["GrandInventorySerializer"] and Serializers["GrandInventorySerializer"].Serialize then
		local serializer = Serializers["GrandInventorySerializer"]
		local nm = resolveSerializerName(serializer)
		local ok, multiRes = pcall(function()
			return serializer:Serialize(player, finalFlag)
		end)
		if not ok then
			warnLog("Serialize error "..nm.." "..tostring(multiRes))
			return
		end
		-- multiRes is a table mapping fieldName->array
		for field,list in pairs(multiRes) do
			list = clamp(list)
			local count = #list
			local old = oldCounts[field] or 0
			local guardR = (count ~= old) and guardEval(player, st, field, old, count) or {accept=true, code="noChange"}
			local fld = st.fields[field] or { list={}, lastCount=0, version=0, meta=nil }
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
			st.fields[field] = fld
			updateInventoryFolder(player, field, list)
			if LOG_SERIALIZE_VERBOSE and (count>0 or not LOG_EMPTY_SUPPRESS) then
				print(("[InvSerialize] %s field=%s count=%d (raw=%d)%s")
					:format(player.Name, field, count, count, finalFlag and " (FINAL)" or ""))
			end
			if guardR and guardR.suspicious then
				print(("[InvGuard][SUSPECT] %s field=%s old=%d new=%d code=%s drop=%d")
					:format(player.Name, field, guardR.old or -1, guardR.new or -1, guardR.code, guardR.drop or -1))
			elseif guardR and guardR.correlated then
				print(("[InvGuard][Correlated] %s field=%s info=%s")
					:format(player.Name, field, guardR.code))
			end
			if finalFlag then
				print(("[InvFinalSerialize] %s field=%s count=%d (FINAL)"):format(player.Name, field, count))
			end
			if count ~= old then anyChange = true end
		end

	else
		-- Legacy: Multiple serializers
		for name,serializer in pairs(Serializers) do
			local nm = resolveSerializerName(serializer)
			local ok,res = pcall(function()
				return serializer:Serialize(player, finalFlag)
			end)
			if not ok then
				warnLog("Serialize error "..nm.." "..tostring(res))
			else
				local list = clamp(res or {})
				local count = #list
				local old = oldCounts[nm] or 0
				local guardR = (count ~= old) and guardEval(player, st, nm, old, count) or {accept=true, code="noChange"}
				local fld = st.fields[nm] or { list={}, lastCount = 0, version=0, meta=nil }
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
				st.fields[nm] = fld
				updateInventoryFolder(player, nm, list)
				if LOG_SERIALIZE_VERBOSE and (count>0 or not LOG_EMPTY_SUPPRESS) then
					print(("[InvSerialize] %s field=%s count=%d (raw=%d)%s")
						:format(player.Name, nm, count, count, finalFlag and " (FINAL)" or ""))
				end
				if guardR and guardR.suspicious then
					print(("[InvGuard][SUSPECT] %s field=%s old=%d new=%d code=%s drop=%d")
						:format(player.Name, nm, guardR.old or -1, guardR.new or -1, guardR.code, guardR.drop or -1))
				elseif guardR and guardR.correlated then
					print(("[InvGuard][Correlated] %s field=%s info=%s")
						:format(player.Name, nm, guardR.code))
				end
				if finalFlag then
					print(("[InvFinalSerialize] %s field=%s count=%d (FINAL)"):format(player.Name, nm, count))
				end
				if count ~= old then anyChange = true end
			end
		end
	end

	if anyChange then
		st.snapshotVersion = (st.snapshotVersion or 0) + 1
		-- Instead of SaveCallback, mark dirty and save via PlayerProfileService
		PlayerProfileService.SaveNow(player, reason or "InventoryUpdate")
		if finalFlag then
			PlayerProfileService.ForceFullSaveNow(player, reason or "InventoryFinal")
		end
	end

	if not finalFlag then
		st.dirtyReasons = {}
	end
end

--------------------------------------------------
-- RESTORE / MERGE
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

function InventoryService.RestorePlayer(player, savedData)
	local st = ensureState(player)
	local incomingFields = (savedData and savedData.fields) or {}

	if Serializers["GrandInventorySerializer"] and Serializers["GrandInventorySerializer"].Restore then
		local serializer = Serializers["GrandInventorySerializer"]
		local fieldArrays = {}
		for fieldName, payload in pairs(incomingFields) do
			if type(payload)=="table" and payload.list and type(payload.list)=="table" then
				fieldArrays[fieldName] = payload.list
			elseif type(payload)=="table" and (payload[1] ~= nil or next(payload)==nil) then
				fieldArrays[fieldName] = payload
			else
				fieldArrays[fieldName] = {}
			end
		end
		local ok,err = pcall(function() serializer:Restore(player, fieldArrays) end)
		if not ok then warnLog("Restore error grandInventory "..tostring(err)) end

		for fieldName, list in pairs(fieldArrays) do
			local existing = st.fields[fieldName] and st.fields[fieldName].list or nil
			if existing and #existing > 0 then
				local idx = indexById(existing)
				local added = 0
				for _,e in ipairs(list) do
					local id = type(e)=="table" and (e.Id or e.id or e.UID or e.uid or e.EggId or e.SlimeId or e.ToolId)
					if id then
						id = tostring(id)
						if not idx[id] then
							table.insert(existing, e)
							idx[id] = e
							added += 1
						end
					else
						table.insert(existing, e)
						added += 1
					end
				end
				st.fields[fieldName] = {
					list = existing,
					lastCount = #existing,
					version = (st.fields[fieldName].version or 0) + 1,
					meta = { mergeApplied = true, added = added }
				}
				updateInventoryFolder(player, fieldName, existing)
				print(("[InvRestore][Merge] %s field=%s added=%d final=%d")
					:format(player.Name, fieldName, added, #existing))
			else
				st.fields[fieldName] = {
					list = list,
					lastCount = #list,
					version = (incomingFields[fieldName] and incomingFields[fieldName].v) or 1,
					meta = incomingFields[fieldName] and incomingFields[fieldName].meta or nil
				}
				updateInventoryFolder(player, fieldName, list)
				print(("[InvRestore] %s field=%s count=%d (initial)")
					:format(player.Name, fieldName, #list))
			end
		end
	else
		for name,serializer in pairs(Serializers) do
			local nm = resolveSerializerName(serializer)
			local payload = incomingFields[nm]
			local list
			if payload then
				if type(payload)=="table" and payload.list and type(payload.list)=="table" then
					list = payload.list
				elseif type(payload)=="table" and (payload[1] ~= nil or next(payload)==nil) then
					list = payload
				else
					list = {}
				end
			else
				list = {}
			end

			local ok,err = pcall(function() serializer:Restore(player, list) end)
			if not ok then warnLog("Restore error "..nm.." "..tostring(err)) end

			local existing = st.fields[nm] and st.fields[nm].list or nil
			if existing and #existing > 0 then
				local idx = indexById(existing)
				local added = 0
				for _,e in ipairs(list) do
					local id = type(e)=="table" and (e.Id or e.id or e.UID or e.uid or e.EggId or e.SlimeId or e.ToolId)
					if id then
						id = tostring(id)
						if not idx[id] then
							table.insert(existing, e)
							idx[id] = e
							added += 1
						end
					else
						table.insert(existing, e)
						added += 1
					end
				end
				st.fields[nm] = {
					list = existing,
					lastCount = #existing,
					version = (st.fields[nm].version or 0) + 1,
					meta = { mergeApplied = true, added = added }
				}
				updateInventoryFolder(player, nm, existing)
				print(("[InvRestore][Merge] %s field=%s added=%d final=%d")
					:format(player.Name, nm, added, #existing))
			else
				st.fields[nm] = {
					list = list,
					lastCount = #list,
					version = (payload and payload.v) or 1,
					meta = payload and payload.meta or nil
				}
				updateInventoryFolder(player, nm, list)
				print(("[InvRestore] %s field=%s count=%d (initial)")
					:format(player.Name, nm, #list))
			end
		end
	end

	st.restoreCompleted = true
	print(("[InvRestore] Completed for %s"):format(player.Name))
end

--------------------------------------------------
-- PUBLIC APIS (Add/Remove runtime items)
--
-- Important change: AddInventoryItem and RemoveInventoryItem now attempt to
-- sync the PlayerProfileService profile immediately and force a full save
-- (best-effort, wrapped in pcall). This reduces the chance of "runtime state
-- changed but profile saved without the inventory entries" races that caused
-- items to be missing on next join.
--------------------------------------------------

-- AddInventoryItem: accepts player Instance or userId (number). Returns true on success.
function InventoryService.AddInventoryItem(playerOrId, fieldName, itemData)
	local ply = resolvePlayer(playerOrId)
	if not ply then
		warn("[InvSvc] AddInventoryItem: player not found for", tostring(playerOrId))
		return false, "no player"
	end
	local st = ensureState(ply)
	st.fields[fieldName] = st.fields[fieldName] or { list = {}, lastCount = 0, version = 0, meta = nil }
	table.insert(st.fields[fieldName].list, itemData)
	st.fields[fieldName].lastCount = #st.fields[fieldName].list
	st.fields[fieldName].version = (st.fields[fieldName].version or 0) + 1
	-- mark dirty & record reason
	st.dirtyReasons["AddInventoryItem"] = true
	-- update per-player folder for runtime visibility
	updateInventoryFolder(ply, fieldName, st.fields[fieldName].list)
	if DEBUG then
		print(("[InvSvc] Added item to %s.%s (now %d)"):format(ply.Name, fieldName, #st.fields[fieldName].list))
	end

	-- Immediately sync runtime inventory into profile cache and request a persisted save.
	-- Best-effort; wrap in pcall so failures do not block game flow.
	pcall(function()
		InventoryService.UpdateProfileInventory(ply)
	end)
	pcall(function()
		-- ForceFullSaveNow is synchronous to reduce last-write race windows.
		PlayerProfileService.ForceFullSaveNow(ply, "InventoryAddImmediate")
	end)

	return true
end

-- RemoveInventoryItem: accepts player Instance or userId (number), category, idField, idValue
-- Returns true if item removed (first matching)
function InventoryService.RemoveInventoryItem(playerOrId, category, idField, idValue)
	local ply = resolvePlayer(playerOrId)
	if not ply then
		warn("[InvSvc] RemoveInventoryItem: player not found for", tostring(playerOrId))
		return false, "no player"
	end
	local st = ensureState(ply)
	local fld = st.fields[category]
	if not fld or not fld.list then
		-- nothing to remove
		return false, "no field"
	end
	for i = #fld.list, 1, -1 do
		local entry = fld.list[i]
		if type(entry) == "table" and entry[idField] == idValue then
			table.remove(fld.list, i)
			fld.lastCount = #fld.list
			fld.version = (fld.version or 0) + 1
			st.dirtyReasons["RemoveInventoryItem"] = true
			-- update runtime folder representation
			updateInventoryFolder(ply, category, fld.list)
			if DEBUG then
				print(("[InvSvc] Removed item from %s.%s idField=%s id=%s (now %d)"):format(ply.Name, category, tostring(idField), tostring(idValue), #fld.list))
			end

			-- Immediately sync runtime inventory into profile cache and request a persisted save.
			pcall(function()
				InventoryService.UpdateProfileInventory(ply)
			end)
			pcall(function()
				PlayerProfileService.ForceFullSaveNow(ply, "InventoryRemoveImmediate")
			end)

			return true
		end
	end
	return false, "not found"
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
end

-- Helper: Update PlayerProfileService inventory from current InventoryService state
function InventoryService.UpdateProfileInventory(player)
	-- expects a player Instance (we key PlayerState by Instance)
	local st = PlayerState[player]
	if not st then return end
	local profile = PlayerProfileService.GetProfile(player)
	if not profile then return end
	profile.inventory = {}
	for field, data in pairs(st.fields) do
		-- Only copy the list, not meta/version
		profile.inventory[field] = data.list or {}
	end
	-- Save a snapshot asynchronously; callers may call ForceFullSaveNow if they need sync
	PlayerProfileService.SaveNow(player, "InventorySync")
end

--------------------------------------------------
-- PERIODIC LOOP
--------------------------------------------------
local function periodicLoop()
	while true do
		task.wait(1)
		if not AUTO_PERIODIC_SERIALIZE then continue end
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

--------------------------------------------------
-- PLAYER HOOKS
--------------------------------------------------
local function onPlayerAdded(player)
	ensureState(player)
	getInventoryFolder(player)
	-- Restore inventory from PlayerProfileService
	local profile = PlayerProfileService.GetProfile(player)
	if profile and profile.inventory then
		InventoryService.RestorePlayer(player, { fields = profile.inventory })
	end
	if DEBUG then
		print(("[InvSvc] Player added, inventory root ready: %s"):format(player.Name))
	end
end

local function onPlayerRemoving(player)
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

	for _,p in ipairs(Players:GetPlayers()) do
		onPlayerAdded(p)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	if not RunService:IsClient() then
		task.spawn(periodicLoop)
	end

	-- Count serializers for informational print
	local sCount = 0
	for _,_ in pairs(Serializers) do sCount += 1 end
	print(("[InvSvc] InventoryService %s initialized AutoPeriodic=%s Interval=%ds Serializers=%d")
		:format(InventoryService.__Version, tostring(AUTO_PERIODIC_SERIALIZE),
			SERIALIZE_INTERVAL_SECONDS, sCount))
	return InventoryService
end

return InventoryService