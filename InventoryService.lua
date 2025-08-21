-- InventoryService.lua
-- Version: v3.1.0-grand-unified-support
--
-- Features:
--  * Supports registration of a single GrandInventorySerializer (or any custom combined serializer).
--  * Auto-discovery will still find any ModuleScript ending in "Serializer", but you should register GrandInventorySerializer manually for best clarity.
--  * Immediate serialization (no gating).
--  * Per-player Inventory folder tree with per-field folders and JSON entry nodes.
--  * Merge on RestorePlayer (union by recognized id keys).
--  * SaveCallback hook for orchestrator persistence.
--  * Clear logging; easy to trim with DEBUG flag.
--
-- Folder Structure:
--   player.Inventory/
--       <fieldName>/ (each list field)
--          Count (IntValue)
--          Entry_<index or id>/Data (StringValue JSON per entry)
--       Meta/  (reserved for future global values)
--
-- Serializer Contract:
--   serializer:Serialize(player, isFinal:boolean) -> table mapping fieldName to array
--   serializer:Restore(player, dataTable) -- dataTable maps fieldName to array
--   serializer.Name = "grandInventory" (for clarity)
--
-- SaveCallback signature:
--   SaveCallback(player, blobTable, reasonString, finalFlag:boolean)
--

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
local CORRELATION_TIMEOUT         = 3.0           -- capture correlation window
local PLAYER_INVENTORY_FOLDER     = "Inventory"
local ENTRY_FOLDER_PREFIX         = "Entry_"
local ENTRY_DATA_VALUE_NAME       = "Data"

-- Guard (non-blocking)
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

--------------------------------------------------
-- REGISTRY
--------------------------------------------------
local Serializers      = {}
local SerializerByName = {}

local function resolveSerializerName(serializer)
	if type(serializer) ~= "table" then return nil,"Serializer not table" end
	if type(serializer.Name) == "string" then return serializer.Name end
	if type(serializer.Name) == "function" then
		local ok,res = pcall(function() return serializer:Name() end)
		if ok and type(res) == "string" then return res end
	end
	return nil,"Serializer missing .Name string or :Name()"
end

function InventoryService.RegisterSerializer(serializer)
	local nm,err = resolveSerializerName(serializer)
	assert(nm, err)
	assert(not SerializerByName[nm], "Duplicate serializer: "..nm)
	Serializers[#Serializers+1] = serializer
	SerializerByName[nm] = serializer
	if DEBUG then print("[InvSvc] Registered serializer:", nm) end
end

-- Auto-discovery: only needed if you still want to support legacy.
local function autoDiscoverSerializers()
	local container = script.Parent
	if not container then return end
	for _,child in ipairs(container:GetChildren()) do
		if child:IsA("ModuleScript") and child.Name:lower():match("serializer$") then
			local ok,mod = pcall(require, child)
			if ok and type(mod) == "table" then
				local okReg,err = pcall(InventoryService.RegisterSerializer, mod)
				if not okReg then
					warn("[InvWarn] Failed to register serializer "..child.Name..": "..tostring(err))
				end
			else
				warn("[InvWarn] Require failed for serializer module "..child.Name)
			end
		end
	end
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
	local st = ensureState(player)
	st.dirtyReasons[reason or "Unknown"] = true
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
	if ok then return res else return "{}" end
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
-- SAVE CALLBACK
--------------------------------------------------
local SaveCallback = nil
function InventoryService.SetSaveCallback(cb) SaveCallback = cb end

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

local function serializePlayer(player, reason, finalFlag)
	local st = PlayerState[player]; if not st then return end
	st.lastSerialize = os.clock()
	local oldCounts = {}
	for name,f in pairs(st.fields) do
		oldCounts[name] = f.lastCount or 0
	end

	local anyChange = false

	-- GrandInventorySerializer support (if only one serializer registered)
	if #Serializers == 1 and Serializers[1].Serialize then
		local serializer = Serializers[1]
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
		for _,serializer in ipairs(Serializers) do
			local nm = resolveSerializerName(serializer)
			local ok,res = pcall(function()
				return serializer:Serialize(player, finalFlag)
			end)
			if not ok then
				warnLog("Serialize error "..nm.." "..tostring(res))
				-- continue to next serializer (no goto needed)
			else
				local list = clamp(res or {})
				local count = #list
				local old = oldCounts[nm] or 0
				local guardR = (count ~= old) and guardEval(player, st, nm, old, count) or {accept=true, code="noChange"}
				local fld = st.fields[nm] or { list={}, lastCount=0, version=0, meta=nil }
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
		if SaveCallback then
			local blob = buildBlob(player, st)
			local ok,err = pcall(function()
				SaveCallback(player, blob, reason or "Periodic", finalFlag)
			end)
			if not ok then warnLog("SaveCallback error: "..tostring(err)) end
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

	-- GrandInventorySerializer support
	if #Serializers == 1 and Serializers[1].Restore then
		local serializer = Serializers[1]
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

		-- Mirror legacy merge logic for each field
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
		-- Legacy: multiple serializers
		for _,serializer in ipairs(Serializers) do
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
-- PUBLIC APIS
--------------------------------------------------
function InventoryService.MarkDirty(player, reason) markDirty(player, reason or "ManualDirty") end
function InventoryService.ForceSave(player, reason) serializePlayer(player, reason or "ForceSave", false) end
function InventoryService.ExportPlayerSnapshot(player)
	local st = PlayerState[player]; if not st then return nil end
	local function buildBlob(player, st)
		local blob = { v=st.snapshotVersion, fields={} }
		for name,f in pairs(st.fields) do
			blob.fields[name] = { v=f.version, list=f.list, meta=f.meta }
		end
		return blob
	end
	return buildBlob(player, st)
end
function InventoryService.DebugPrintPlayer(player)
	local st = PlayerState[player]
	if not st then print("[InvSvc] No state for", player.Name) return end
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
	getInventoryFolder(player) -- create root early
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

	-- If you want auto-discovery, uncomment this line
	-- autoDiscoverSerializers()

	for _,p in ipairs(Players:GetPlayers()) do
		onPlayerAdded(p)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	if not RunService:IsClient() then
		task.spawn(periodicLoop)
	end

	print(("[InvSvc] InventoryService %s initialized AutoPeriodic=%s Interval=%ds Serializers=%d")
		:format(InventoryService.__Version, tostring(AUTO_PERIODIC_SERIALIZE),
			SERIALIZE_INTERVAL_SECONDS, #Serializers))
	return InventoryService
end

return InventoryService