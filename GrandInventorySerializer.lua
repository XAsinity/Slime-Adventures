-- GrandInventorySerializer (updated: position validation + data sanitization for DataStore)
-- Additional fixes:
--  - Deferred re-parent / reposition for world eggs when player's plot isn't available at restore time
--  - Ensure RestoreLpx/Lpy/Lpz attributes are written for restored eggs so deferred reposition can use them
--  - Minor robustness improvements in we_restore (player-path) and ws_restore
--  - Preserve offline hatch countdown semantics on restore (compute_restored_hatchAt unchanged, but restore path ensures placedAt/cr preserved)

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace           = game:GetService("Workspace")
local RunService          = game:GetService("RunService")
local HttpService         = game:GetService("HttpService")
local ServerStorage       = game:GetService("ServerStorage")
local Players             = game:GetService("Players")

local GrandInventorySerializer = {}

GrandInventorySerializer.CONFIG = {
	Debug = true,
	WorldSlime = {
		MaxWorldSlimesPerPlayer  = 60,
		UseLocalCoords           = true,
		DedupeOnSerialize        = true,
		DedupeOnRestore          = true,
		SkipSecondPassIfComplete = true,
		MarkWorldSlimeAttribute  = true,
	},
	WorldEgg = {
		MaxWorldEggsPerPlayer = 60,
		UseLocalCoords = true,
		OfflineEggProgress = true,
		TemplateFolders = { "Assets", "EggTemplates", "WorldEggs" },
		DefaultTemplateName = "Egg",
		RestoreEggsReady = false,
		AcceptMissingManualHatchGraceSeconds = 10,
		AutoCaptureOnEggPlacement = true,
	},
	FoodTool = {
		MaxFood                  = 120,
		TemplateFolders          = { "FoodTemplates", "Assets", "InventoryTemplates" },
		FallbackHandleSize       = Vector3.new(1,1,1),
		InstrumentLifeCycle      = true,
		LifeCycleWatchSeconds    = 60,
		FastAuditDelay           = 0.30,
		PostRestoreAuditDelay    = 0.85,
		EnablePostRestoreAudit   = true,
		EnableRebuildOnMissing   = true,
		RequireStableHeartbeats  = true,
		StableHeartbeatCount     = 6,
		AggregationMode          = "individual",
		Debug                    = true,
	},
	EggTool = {
		MaxEggTools                  = 60,
		TemplateFolder               = "ToolTemplates",
		TemplateName                 = "EggToolTemplate",
		FallbackHandleSize           = Vector3.new(1,1,1),
		InstrumentLifeCycle          = true,
		LifeCycleWatchSeconds        = 5,
		AssignUidIfMissingOnSerialize= true,
		AssignUidIfMissingOnRestore  = true,
		LogAssignedUids              = false,
		RepairAfterRestore           = true,
		RepairLogEach                = false,
		Debug                        = false,
	},
	CapturedSlime = {
		MaxStored              = 120,
		TemplateFolder         = "ToolTemplates",
		TemplateNameCaptured   = "CapturedSlimeTool",
		DeduplicateOnRestore   = true,
		RequireStableHeartbeats= true,
		StableHeartbeatCount   = 6,
		LifeCycleWatchSeconds  = 5,
		PostRestoreAuditDelay  = 0.85,
		EnablePostRestoreAudit = true,
		EnableRebuildOnMissing = true,
		Debug                  = true,
	},
}

if not RunService:IsServer() then
	return
end

local function dprint(...)
	if GrandInventorySerializer.CONFIG.Debug then
		print("[GrandInvSer]", ...)
	end
end

local clock = tick
local DebugFlags = nil
pcall(function()
	DebugFlags = require(ServerScriptService.Modules:WaitForChild("DebugFlags"))
end)
local function eggdbg(...) if DebugFlags and DebugFlags.EggDebug and GrandInventorySerializer.CONFIG.Debug then print("[EggDbg][GrandInvSer]", ...) end end

local _cachedPPS = nil
local function getPPS()
	if _cachedPPS then return _cachedPPS end
	local ok, mod = pcall(function()
		local m = ServerScriptService:FindFirstChild("Modules")
		if m then
			local inst = m:FindFirstChild("PlayerProfileService")
			if inst then
				return require(inst)
			end
		end
		return require(ServerScriptService.Modules:WaitForChild("PlayerProfileService"))
	end)
	if ok and type(mod) == "table" then
		_cachedPPS = mod
		return _cachedPPS
	end
	return nil
end


-- Fixes the duplicated condition and adds a couple of common alternate key checks.
local function dedupe_by_id(entries)
	local out = {}
	local seen = {}
	for _, e in ipairs(entries or {}) do
		if type(e) ~= "table" then
			table.insert(out, e)
		else
			-- canonical id lookup (avoid duplicate checks)
			local id = e.id or e.SlimeId or e.EggId or e.Id
			-- fallbacks for uncommon variants
			if not id then
				id = e.slimeId or e.SLIME_ID or e.uuid or e.uid or e.ToolUniqueId or e.ToolUid
			end

			if id then
				local k = tostring(id)
				if not seen[k] then
					seen[k] = true
					table.insert(out, e)
				end
			else
				-- no id available � keep entry (can't dedupe reliably)
				table.insert(out, e)
			end
		end
	end
	return out
end

-- Merge incoming list into a cached player profile's worldSlimes (dedupe by id).
-- This reduces risk of duplicate entries being appended to profile.inventory.worldSlimes by multiple restores.
local function merge_incoming_into_profile_worldslimes(userId, incoming)
	if not incoming or type(incoming) ~= "table" then return false end

	-- Try to require PlayerProfileService safely
	local ok, PPS = pcall(function()
		local ms = ServerScriptService and ServerScriptService:FindFirstChild("Modules")
		if ms and ms:FindFirstChild("PlayerProfileService") then
			return require(ms:FindFirstChild("PlayerProfileService"))
		end
		-- best-effort fallback if module placed elsewhere
		if ServerScriptService and ServerScriptService:FindFirstChild("PlayerProfileService") then
			return require(ServerScriptService:FindFirstChild("PlayerProfileService"))
		end
		return nil
	end)
	if not ok or not PPS or type(PPS.GetProfile) ~= "function" then return false end

	local profile = nil
	pcall(function() profile = PPS.GetProfile(userId) end)
	if not profile then return false end

	profile.inventory = profile.inventory or {}
	local old = profile.inventory.worldSlimes or {}
	local merged = {}
	local seen = {}

	-- add existing canonical entries first (normalize their id strings)
	for _, entry in ipairs(old) do
		if type(entry) == "table" then
			local id = entry.id or entry.SlimeId or entry.Id
			if id then
				seen[tostring(id)] = true
				merged[#merged+1] = entry
			else
				merged[#merged+1] = entry
			end
		end
	end

	-- add deduped incoming entries
	local dedupedIncoming = dedupe_by_id(incoming)
	for _, entry in ipairs(dedupedIncoming) do
		if type(entry) ~= "table" then
			table.insert(merged, entry)
		else
			local id = entry.id or entry.SlimeId or entry.Id
			if id then
				if not seen[tostring(id)] then
					seen[tostring(id)] = true
					table.insert(merged, entry)
				end
			else
				table.insert(merged, entry)
			end
		end
	end

	-- If changed, assign and mark dirty
	local changed = false
	if #merged ~= #old then changed = true end
	if not changed then
		-- shallow compare ids
		for i = 1, math.min(#merged, #old) do
			local a = merged[i]; local b = old[i]
			local aid = a and (a.id or a.SlimeId or a.Id)
			local bid = b and (b.id or b.SlimeId or b.Id)
			if tostring(aid) ~= tostring(bid) then changed = true; break end
		end
	end
	if changed then
		profile.inventory.worldSlimes = merged
		-- Mark dirty so PlayerProfileService will persist via its normal flow
		pcall(function()
			if type(PPS.MarkDirty) == "function" then
				-- MarkDirty may have different signatures; call defensively
				pcall(function() PPS.MarkDirty(PPS, userId) end)
				pcall(function() PPS.MarkDirty(userId) end)
			end
		end)
		if GrandInventorySerializer and GrandInventorySerializer.CONFIG and GrandInventorySerializer.CONFIG.Debug then
			pcall(function()
				print(("[WorldSlimeService] merged incoming worldSlimes into profile for userId=%s, newCount=%d"):format(tostring(userId), tonumber(#merged) or #merged))
			end)
		end
	end
	return changed
end

-- Helpers: numeric/finite check


local function waitForInventoryReady(player, timeout)
	timeout = timeout or 8 -- seconds
	if not player then return end
	local start = os.clock()
	-- Wait for InventoryService to set InventoryReady attribute
	while os.clock() - start < timeout do
		if player:GetAttribute("InventoryReady") then
			return true
		end
		-- Optionally, check for inventory folder existence
		local invFolder = player:FindFirstChild("Inventory") or workspace:FindFirstChild(player.Name .. "_Inventory")
		if invFolder then
			return true
		end
		task.wait(0.12)
	end
	-- Timed out
	return false
end

local function isFiniteNumber(n)
	return type(n)=="number" and n==n and n~=math.huge and n~=-math.huge
end

local RESTORE_GRACE_SECONDS = 12
local _restoreGrace = {}
local _lastRestoredInventory = {}

local pendingRestores = {}
local pendingRestoresByName = {}
local pendingRestoresByPersistentId = {}

local PENDING_DEFAULT_TIMEOUT = 60

local plotByUserId = {}
local plotModelToUserId = {}
local plotByPersistentId = {}
local plotModelToPersistentId = {}


local MAX_LOCAL_COORD_MAG = 200
local function safe_num(v) if v == nil then return nil end local n = tonumber(v) return n end
local function posStr(vec) if not vec then return "<nil>" end return string.format("%.3f, %.3f, %.3f", vec.X or vec.x or 0, vec.Y or vec.y or 0, vec.Z or vec.z or 0) end

local function tonum(v)
	if v == nil then return nil end
	if type(v) == "number" then return v end
	return tonumber(v)
end

-- Periodic reaper for stale pending restores (prune entries past their timeout)
task.spawn(function()
	while true do
		task.wait(30) -- run every 30s
		local now = os.time()
		-- prune by userId
		for uid, bundle in pairs(pendingRestores) do
			if type(bundle) == "table" and bundle.timeout and bundle.timeout < now then
				pcall(function() pendingRestores[uid] = nil end)
			end
		end
		-- prune by name
		for name, bundle in pairs(pendingRestoresByName) do
			if type(bundle) == "table" and bundle.timeout and bundle.timeout < now then
				pcall(function() pendingRestoresByName[name] = nil end)
			end
		end
		-- prune by persistentId
		for pid, bundle in pairs(pendingRestoresByPersistentId) do
			if type(bundle) == "table" and bundle.timeout and bundle.timeout < now then
				pcall(function() pendingRestoresByPersistentId[pid] = nil end)
			end
		end
	end
end)

local function mark_restored_instance(inst, ownerUserId, toolUid)
	if not inst then return end
	pcall(function()
		if type(inst.SetAttribute) == "function" then
			if ownerUserId ~= nil then
				pcall(function() inst:SetAttribute("OwnerUserId", ownerUserId) end)
			end
			if toolUid ~= nil then
				-- support both ToolUniqueId and ToolUid variants
				pcall(function() inst:SetAttribute("ToolUniqueId", toolUid) end)
				pcall(function() inst:SetAttribute("ToolUid", toolUid) end)
			end
			pcall(function() inst:SetAttribute("ServerRestore", true) end)
			pcall(function() inst:SetAttribute("PreserveOnServer", true) end)
			pcall(function() inst:SetAttribute("RestoreStamp", tick()) end)
			-- Also set RecentlyPlacedSaved so WorldAssetCleanup/other flows see it's a recently saved placement.
			pcall(function() inst:SetAttribute("RecentlyPlacedSaved", os.time()) end)
		end
	end)
end

local function registerPlotModel(plotModel)
	if not plotModel or not plotModel:IsA("Model") then return end
	local top = plotModel
	while top.Parent and top.Parent ~= Workspace do
		top = top.Parent
	end
	if not top or not top:IsA("Model") then return end
	local candidate = top
	if not tostring(candidate.Name):match("^Player%d+$") then
		if tostring(plotModel.Name):match("^Player%d+$") then
			candidate = plotModel
		else
			return
		end
	end
	plotModel = candidate
	local uidAttr = plotModel:GetAttribute("UserId") or plotModel:GetAttribute("OwnerUserId") or plotModel:GetAttribute("AssignedUserId")
	local uid = tonum(uidAttr)
	local pidAttr = plotModel:GetAttribute("AssignedPersistentId") or plotModel:GetAttribute("PersistentId") or plotModel:GetAttribute("OwnerPersistentId")
	local pid = tonum(pidAttr)
	if uid then
		local prev = plotByUserId[uid]
		if prev and prev ~= plotModel then
			plotModelToUserId[prev] = nil
		end
		plotByUserId[uid] = plotModel
		plotModelToUserId[plotModel] = uid
		dprint(("Registered plot=%s -> userId=%s"):format(tostring(plotModel:GetFullName()), tostring(uid)))
	end
	if pid then
		local prev = plotByPersistentId[pid]
		if prev and prev ~= plotModel then
			plotModelToPersistentId[prev] = nil
		end
		plotByPersistentId[pid] = plotModel
		plotModelToPersistentId[plotModel] = pid
		dprint(("Registered plot=%s -> persistentId=%s"):format(tostring(plotModel:GetFullName()), tostring(pid)))
	end
	pcall(function()
		if plotModel.GetAttributeChangedSignal then
			plotModel:GetAttributeChangedSignal("UserId"):Connect(function()
				local new = tonum(plotModel:GetAttribute("UserId"))
				if not new then return end
				local old = plotModelToUserId[plotModel]
				if old and plotByUserId[old] == plotModel then plotByUserId[old] = nil end
				plotByUserId[new] = plotModel
				plotModelToUserId[plotModel] = new
				dprint(("UserId changed; registered plot=%s -> userId=%s"):format(tostring(plotModel:GetFullName()), tostring(new)))
			end)
			plotModel:GetAttributeChangedSignal("OwnerUserId"):Connect(function()
				local new = tonum(plotModel:GetAttribute("OwnerUserId"))
				if not new then return end
				local old = plotModelToUserId[plotModel]
				if old and plotByUserId[old] == plotModel then plotByUserId[old] = nil end
				plotByUserId[new] = plotModel
				plotModelToUserId[plotModel] = new
				dprint(("OwnerUserId changed; registered plot=%s -> userId=%s"):format(tostring(plotModel:GetFullName()), tostring(new)))
			end)
			plotModel:GetAttributeChangedSignal("AssignedUserId"):Connect(function()
				local new = tonum(plotModel:GetAttribute("AssignedUserId"))
				if not new then return end
				local old = plotModelToUserId[plotModel]
				if old and plotByUserId[old] == plotModel then plotByUserId[old] = nil end
				plotByUserId[new] = plotModel
				plotModelToUserId[plotModel] = new
				dprint(("AssignedUserId changed; registered plot=%s -> userId=%s"):format(tostring(plotModel:GetFullName()), tostring(new)))
			end)
			plotModel:GetAttributeChangedSignal("AssignedPersistentId"):Connect(function()
				local new = tonum(plotModel:GetAttribute("AssignedPersistentId"))
				if not new then return end
				local old = plotModelToPersistentId[plotModel]
				if old and plotByPersistentId[old] == plotModel then plotByPersistentId[old] = nil end
				plotByPersistentId[new] = plotModel
				plotModelToPersistentId[plotModel] = new
				dprint(("AssignedPersistentId changed; registered plot=%s -> persistentId=%s"):format(tostring(plotModel:GetFullName()), tostring(new)))
			end)
		end
	end)
	plotModel.AncestryChanged:Connect(function(child, parent)
		if not parent then
			local uidHere = plotModelToUserId[plotModel]
			if uidHere then
				if plotByUserId[uidHere] == plotModel then plotByUserId[uidHere] = nil end
				plotModelToUserId[plotModel] = nil
				dprint(("Plot removed: unregistered plot=%s for userId=%s"):format(tostring(plotModel:GetFullName()), tostring(uidHere)))
			end
			local pidHere = plotModelToPersistentId[plotModel]
			if pidHere then
				if plotByPersistentId[pidHere] == plotModel then plotByPersistentId[pidHere] = nil end
				plotModelToPersistentId[plotModel] = nil
				dprint(("Plot removed: unregistered plot=%s for persistentId=%s"):format(tostring(plotModel:GetFullName()), tostring(pidHere)))
			end
		end
	end)
end

local function scanAndRegisterPlotsOnStartup()
	for _,child in ipairs(Workspace:GetChildren()) do
		if child:IsA("Model") and tostring(child.Name):match("^Player%d+$") then
			registerPlotModel(child)
		end
	end
end

Workspace.ChildAdded:Connect(function(child)
	if child and child:IsA("Model") and tostring(child.Name):match("^Player%d+$") then
		task.defer(function()
			registerPlotModel(child)
		end)
	end
end)

function GrandInventorySerializer.RegisterPlotModelForUser(plotModel, userId, persistentId)
	if not plotModel or not userId then return end
	local uid = tonum(userId)
	if not uid then return end
	plotModel:SetAttribute("AssignedUserId", uid)
	if persistentId then
		plotModel:SetAttribute("AssignedPersistentId", tonumber(persistentId))
	end
	registerPlotModel(plotModel)
end

local function normalize_time_to_epoch(value, now_tick, now_os)
	if not value then return nil end
	local n = tonumber(value)
	if not n then return nil end
	-- treat epoch-like numbers as already epoch seconds
	if n > 1e8 then
		return n
	end
	-- if caller provided both tick() and os.time(), convert tick-based value into epoch seconds
	if now_tick and now_os then
		return now_os + (n - now_tick)
	end
	return nil
end


local function we_findPlayerPlot_by_userid(userId)
	if not userId then return nil end
	local uid = tonum(userId)
	if uid and plotByUserId[uid] and plotByUserId[uid].Parent then
		return plotByUserId[uid]
	end
	for _,m in ipairs(Workspace:GetChildren()) do
		if m:IsA("Model") and tostring(m.Name):match("^Player%d+$") then
			local attr = tonum(m:GetAttribute("UserId")) or tonum(m:GetAttribute("OwnerUserId")) or tonum(m:GetAttribute("AssignedUserId"))
			if attr and uid and attr == uid then
				registerPlotModel(m)
				return m
			end
		end
	end
	for _,desc in ipairs(Workspace:GetDescendants()) do
		if desc:IsA("Model") then
			local attr = tonum(desc:GetAttribute("OwnerUserId")) or tonum(desc:GetAttribute("UserId")) or tonum(desc:GetAttribute("AssignedUserId"))
			if attr and uid and attr == uid then
				local parentModel = desc
				while parentModel and not parentModel:IsA("Model") and parentModel.Parent do parentModel = parentModel.Parent end
				if parentModel then registerPlotModel(parentModel) end
				return parentModel
			end
		end
	end
	return nil
end

local function we_findPlayerPlot_by_persistentId(persistentId)
	if not persistentId then return nil end
	local pid = tonum(persistentId)
	if pid and plotByPersistentId[pid] and plotByPersistentId[pid].Parent then
		return plotByPersistentId[pid]
	end
	for _,m in ipairs(Workspace:GetChildren()) do
		if m:IsA("Model") and tostring(m.Name):match("^Player%d+$") then
			local attr = tonum(m:GetAttribute("AssignedPersistentId")) or tonum(m:GetAttribute("PersistentId")) or tonum(m:GetAttribute("OwnerPersistentId"))
			if attr and pid and attr == pid then
				registerPlotModel(m)
				return m
			end
		end
	end
	for _,desc in ipairs(Workspace:GetDescendants()) do
		if desc:IsA("Model") then
			local attr = tonum(desc:GetAttribute("OwnerPersistentId")) or tonum(desc:GetAttribute("AssignedPersistentId")) or tonum(desc:GetAttribute("PersistentId"))
			if attr and pid and attr == pid then
				local parentModel = desc
				while parentModel and not parentModel:IsA("Model") and parentModel.Parent do parentModel = parentModel.Parent end
				if parentModel then registerPlotModel(parentModel) end
				return parentModel
			end
		end
	end
	return nil
end

local function safe_get_profile(playerOrId)
	local PPS = getPPS()
	if not PPS then return nil end
	local function try(fn, desc)
		local ok, res = pcall(fn)
		if not ok then
			dprint(("[safe_get_profile] candidate '%s' call FAILED: %s"):format(tostring(desc), tostring(res)))
			return nil
		end
		if type(res) == "table" then
			dprint(("[safe_get_profile] candidate '%s' succeeded (profile table)"):format(tostring(desc)))
			return res
		end
		return nil
	end
	if type(playerOrId) == "table" and type(playerOrId.FindFirstChildOfClass) == "function" then
		local player = playerOrId
		local candidates = {
			{ fn = function() return PPS.GetProfile(player.UserId) end, desc = "GetProfile(userId) (no self)" },
			{ fn = function() return PPS.GetProfile(tostring(player.UserId)) end, desc = "GetProfile(tostring(userId)) (no self)" },
			{ fn = function() return PPS.GetProfile(player) end, desc = "GetProfile(player) (no self)" },
			{ fn = function() return PPS.GetProfile(tostring(player)) end, desc = "GetProfile(tostring(player)) (no self)" },
		}
		for _, candidate in ipairs(candidates) do
			local prof = try(candidate.fn, candidate.desc)
			if prof then return prof end
		end
		if type(PPS.WaitForProfile) == "function" then
			local ok, p = pcall(function() return PPS.WaitForProfile(player, 1) end)
			if ok and p then return p end
		end
		return nil
	end
	if type(playerOrId) == "table" and playerOrId.inventory ~= nil then
		return playerOrId
	end
	local candidates = {}
	if type(playerOrId) == "number" or tonumber(playerOrId) then
		local idnum = tonumber(playerOrId)
		table.insert(candidates, { fn = function() return PPS.GetProfile(idnum) end, desc = "GetProfile(userId number)" })
	end
	if type(playerOrId) == "string" then
		table.insert(candidates, { fn = function() return PPS.GetProfile(playerOrId) end, desc = "GetProfile(string) (no self)" })
		table.insert(candidates, { fn = function() return PPS.GetProfile(tostring(playerOrId)) end, desc = "GetProfile(tostring) (no self)" })
	end
	for _, candidate in ipairs(candidates) do
		local prof = try(candidate.fn, candidate.desc)
		if prof then return prof end
	end
	if type(PPS.WaitForProfile) == "function" then
		local ok, p = pcall(function() return PPS.WaitForProfile(playerOrId, 1) end)
		if ok and type(p) == "table" then return p end
		return nil
	end
	return nil
end

local function safe_wait_for_profile(candidate, timeout)
	local PPS = getPPS()
	if not PPS or type(PPS.WaitForProfile) ~= "function" then return nil end
	if not candidate then return nil end
	if type(candidate) == "table" and type(candidate.FindFirstChildOfClass) == "function" then
		local ok, p = pcall(function() return PPS.WaitForProfile(candidate, timeout) end)
		if ok and type(p) == "table" then return p end
		return nil
	end
	if type(candidate) == "string" or type(candidate) == "number" or tonumber(candidate) then
		local ok, p = pcall(function() return PPS.WaitForProfile(candidate, timeout) end)
		if ok and type(p) == "table" then return p end
		return nil
	end
	return nil
end

local function getPersistentIdFor(profileOrPlayer)
	local PPS = getPPS()
	if not PPS then
		if type(profileOrPlayer) == "table" then
			return tonumber(profileOrPlayer.persistentId) or nil
		end
		return nil
	end
	if type(profileOrPlayer) == "table" and profileOrPlayer.persistentId then
		return tonumber(profileOrPlayer.persistentId)
	end
	if type(profileOrPlayer) == "table" and type(profileOrPlayer.FindFirstChildOfClass) == "function" then
		local prof = safe_get_profile(profileOrPlayer)
		if prof and prof.persistentId then return tonumber(prof.persistentId) end
		if type(PPS.GetOrAssignPersistentId) == "function" then
			local ok, pid = pcall(function() return PPS.GetOrAssignPersistentId(profileOrPlayer) end)
			if ok and pid then return tonumber(pid) end
		end
		return nil
	end
	if type(profileOrPlayer) == "table" and profileOrPlayer.inventory then
		if profileOrPlayer.persistentId then return tonumber(profileOrPlayer.persistentId) end
		if type(PPS.GetOrAssignPersistentId) == "function" then
			local ok, pid = pcall(function() return PPS.GetOrAssignPersistentId(profileOrPlayer) end)
			if ok and pid then return tonumber(pid) end
		end
		return nil
	end
	if tonumber(profileOrPlayer) then
		local prof = safe_get_profile(tonumber(profileOrPlayer))
		if prof and prof.persistentId then return tonumber(prof.persistentId) end
		if type(PPS.GetOrAssignPersistentId) == "function" then
			local ok, pid = pcall(function() return PPS.GetOrAssignPersistentId(tonumber(profileOrPlayer)) end)
			if ok and pid then return tonumber(pid) end
		end
	end
	if type(profileOrPlayer) == "string" then
		if type(PPS.GetOrAssignPersistentId) == "function" then
			local ok, pid = pcall(function() return PPS.GetOrAssignPersistentId(profileOrPlayer) end)
			if ok and pid then return tonumber(pid) end
		end
	end
	return nil
end

local function resolvePlayerAndProfile(arg1, arg2)
	local playerInstance = nil
	local nameCandidate = nil
	local isFinal = false
	local function isPlayer(x) return type(x) == "table" and type(x.FindFirstChildOfClass) == "function" end
	if isPlayer(arg1) then
		playerInstance = arg1
		isFinal = arg2 or false
	elseif isPlayer(arg2) then
		playerInstance = arg2
		isFinal = arg1 or false
	else
		if type(arg1) == "string" or type(arg1) == "number" or tonumber(arg1) then
			nameCandidate = arg1
			isFinal = arg2 or false
		elseif type(arg2) == "string" or type(arg2) == "number" or tonumber(arg2) then
			nameCandidate = arg2
			isFinal = arg1 or false
		else
			isFinal = arg2 or arg1 or false
		end
	end
	local profile = nil
	if playerInstance then
		profile = safe_get_profile(playerInstance)
	else
		if nameCandidate ~= nil then
			profile = safe_get_profile(nameCandidate)
			if not playerInstance and type(nameCandidate) == "string" then
				for _,pl in ipairs(Players:GetPlayers()) do
					if pl.Name == nameCandidate then
						playerInstance = pl
						break
					end
				end
			elseif not playerInstance and tonumber(nameCandidate) then
				playerInstance = Players:GetPlayerByUserId(tonumber(nameCandidate))
			end
		else
			if type(arg1) == "table" and arg1.inventory ~= nil then
				profile = arg1
			elseif type(arg2) == "table" and arg2.inventory ~= nil then
				profile = arg2
			end
		end
	end
	if not profile and playerInstance then
		profile = safe_get_profile(playerInstance)
	end
	if type(isFinal) ~= "boolean" then isFinal = not not isFinal end
	return playerInstance, profile, isFinal
end

local function debug_profile_inventory(playerOrProfile, label)
	local prof = nil
	if type(playerOrProfile) == "table" and playerOrProfile.inventory ~= nil then
		prof = playerOrProfile
	elseif type(playerOrProfile) == "table" and type(playerOrProfile.FindFirstChildOfClass) == "function" then
		prof = safe_get_profile(playerOrProfile)
	else
		prof = safe_get_profile(playerOrProfile)
	end
	if not prof then
		dprint(("[Profile][%s] profile nil for %s"):format(label, tostring(playerOrProfile and (playerOrProfile.Name or tostring(playerOrProfile)) or "nil")))
		return
	end
	local inv = prof.inventory or {}
	dprint(("[Profile][%s] for %s - eggTools=%d foodTools=%d worldEggs=%d worldSlimes=%d capturedSlimes=%d persistentId=%s"):format(
		label,
		(tostring((prof.playerName or prof.name) or (prof.userId or prof.UserId) or "unknown")),
		#(inv.eggTools or {}),
		#(inv.foodTools or {}),
		#(inv.worldEggs or {}),
		#(inv.worldSlimes or {}),
		#(inv.capturedSlimes or {}),
		tostring(prof.persistentId or "nil")
		))
end

-- Local wrappers for external functions to satisfy static analysis / avoid UnknownGlobal warnings.
-- These call the real implementations if they exist at runtime, using rawget on _G to avoid direct global lookups.
local function _we_findPlayerPlot(player)
	-- Use rawget(_G, "we_findPlayerPlot") instead of referencing we_findPlayerPlot directly
	-- so static analysis won't flag an UnknownGlobal while still calling the real function at runtime.
	local fn = rawget(_G, "we_findPlayerPlot")
	if type(fn) == "function" then
		return fn(player)
	end
	return nil
end

local function _we_getPlotOrigin(plot)
	-- Same pattern for we_getPlotOrigin
	local fn = rawget(_G, "we_getPlotOrigin")
	if type(fn) == "function" then
		return fn(plot)
	end
	return nil
end



-----------------------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- 1) Helper: findPlotForUserWithFallback
-- Paste this after we_findPlayerPlot_by_userid / we_findPlayerPlot_by_persistentId / we_getPlotOrigin helpers.
--------------------------------------------------------------------------------
-- findPlotForUserWithFallback (drop-in)
-- findPlotForUserWithFallback (drop-in)
-- findPlotForUserWithFallback (drop-in)
local function findPlotForUserWithFallback(userId, persistentId, nameKey)
	-- Try by userid -> internal index functions
	if userId then
		local ok, p = pcall(function() return we_findPlayerPlot_by_userid(userId) end)
		if ok and p then return p end
		ok, p = pcall(function() return we_findPlayerPlot_by_persistentId(userId) end)
		if ok and p then return p end
	end

	-- Try by persistent id explicitly
	if persistentId then
		local ok, p = pcall(function() return we_findPlayerPlot_by_persistentId(persistentId) end)
		if ok and p then return p end
	end

	-- Scan Workspace Player%d+ models for matching attributes as fallback
	for _, m in ipairs(Workspace:GetChildren()) do
		if m:IsA("Model") and tostring(m.Name):match("^Player%d+$") then
			local uidAttr = tonumber(m:GetAttribute("UserId")) or tonumber(m:GetAttribute("OwnerUserId")) or tonumber(m:GetAttribute("AssignedUserId"))
			if uidAttr and userId and tonumber(uidAttr) == tonumber(userId) then
				return m
			end
			local pidAttr = tonumber(m:GetAttribute("AssignedPersistentId")) or tonumber(m:GetAttribute("PersistentId")) or tonumber(m:GetAttribute("OwnerPersistentId"))
			if pidAttr and persistentId and tonumber(pidAttr) == tonumber(persistentId) then
				return m
			end
			-- name fallback (rare)
			if nameKey and tostring(m.Name) == tostring(nameKey) then
				return m
			end
		end
	end

	return nil
end

-----------------------------------------------------------------------------------------------------------


-- WorldSlime
-- Hardened serializer + restore for WorldSlimes (GrandInventorySerializer integration)
-- Changes:
--  - Added normalization/sanitization helpers for incoming/outgoing payloads.
--  - ws_serialize ensures output contains plain-number/string/boolean values and hex colors.
--  - ws_restore is defensive: accepts legacy/variant field names, coerces types, removes malformed entries,
--    dedupes, and prefers updating existing live models rather than duplicating.
--  - Added a few small constant guards (MAX_LOCAL_COORD_MAG) and utility functions (isFiniteNumber, parseNumber).
-----------------------------------------------------------------------
-- WorldSlimeService.lua
-- Hardened WorldSlime serialization & restore helpers (section extracted from GrandInventorySerializer)
-- This file contains the WS (world-slime) related functions: normalization, serialize, restore,
-- plus helpers used to safely resolve plot candidates that may be strings or Instances.

-- WorldSlimeManager (patched)
-- Full WS section with improved restore behavior that attempts to use SlimeFactory/SlimeCore creation paths
-- and robustly falls back to minimal model creation only when higher-level APIs are unavailable.
-- This patch aims to restore slimes using the project's SlimeCore/SlimeFactory APIs (many candidate names tried)
-- and to correctly honor absolute Position or local lpx/lpy/lpz values from incoming payloads.

-- WorldSlime section (patched)
-- Replaces the previous WorldSlime code block. Drop-in for GrandInventorySerializer module.

-- WorldSlimeService_fixed.lua
-- Hardened WorldSlime restore/serialize + duplicate-safety improvements for GrandInventorySerializer.
-- Notes:
--  - Adds a small in-flight restore lock to avoid race-creation duplicates.
--  - Makes dedupe/eliminate logic prefer models with higher RestoreStamp / LastGrowthUpdate, then partCount.
--  - Re-checks for existing SlimeId immediately before creating to avoid race windows.
--  - Ensures isFiniteNumber helper present.
--  - Exposes robust utilities at GrandInventorySerializer._internal.WorldSlime
-- Replace your WorldSlime section with this block.

-- WorldSlimeService (updated: dedupe + reuse existing model + in-flight locks)
-- Drop-in WorldSlime section for GrandInventorySerializer
-- Includes:
--  - dedupe_by_id, merge_incoming_into_profile_worldslimes
--  - in-flight create/persist lock per SlimeId
--  - reuse existing Workspace model when SlimeId already present (avoid creating duplicates)
--  - robust registration and eliminateDuplicate logic

local WSCONFIG = GrandInventorySerializer and GrandInventorySerializer.CONFIG and GrandInventorySerializer.CONFIG.WorldSlime or {}
local WS_ATTR_MAP = {
	GrowthProgress="gp", ValueFull="vf", CurrentValue="cv", ValueBase="vb",
	ValuePerGrowth="vg", MutationStage="ms", Tier="ti", FedFraction="ff",
	CurrentSizeScale="sz", BodyColor="bc", AccentColor="ac", EyeColor="ec",
	MovementScalar="mv", WeightScalar="ws", MutationRarityBonus="mb", WeightPounds="wt",
	MaxSizeScale="mx", StartSizeScale="st", SizeLuckRolls="lr",
	FeedBufferSeconds="fb", FeedBufferMax="fx", HungerDecayRate="hd",
	CurrentFullness="cf", FeedSpeedMultiplier="fs", LastHungerUpdate="lu",
	LastGrowthUpdate="lg", OfflineGrowthApplied="og", AgeSeconds="ag",
	PersistedGrowthProgress="pgf",
}
local colorKeys = { bc=true, ac=true, ec=true }
local ws_liveIndex = {}
local MAX_LOCAL_COORD_MAG = (WSCONFIG and WSCONFIG.MaxLocalCoordMag) or 400

local function safe_typeof(v)
	local ok, t = pcall(function() return typeof and typeof(v) end)
	if ok then return t end
	return type(v)
end
local function isColor3(v) return safe_typeof(v) == "Color3" end

local function ws_colorToHex(c)
	local ok = pcall(function() assert(c and c.R) end)
	if not ok then return tostring(c) end
	return string.format("%02X%02X%02X",
		math.floor(c.R*255+0.5),
		math.floor(c.G*255+0.5),
		math.floor(c.B*255+0.5))
end

local function ws_hexToColor3(hex)
	if isColor3(hex) then return hex end
	if type(hex) == "table" and (hex.r or hex.R) then
		local r = tonumber(hex.r or hex.R) or 0
		local g = tonumber(hex.g or hex.G) or 0
		local b = tonumber(hex.b or hex.B) or 0
		return Color3.fromRGB(r,g,b)
	end
	if type(hex) ~= "string" then return nil end
	hex = hex:gsub("^#","")
	if #hex ~= 6 then return nil end
	local r = tonumber(hex:sub(1,2),16)
	local g = tonumber(hex:sub(3,4),16)
	local b = tonumber(hex:sub(5,6),16)
	if r and g and b then return Color3.fromRGB(r,g,b) end
	return nil
end

local function parseNumber(v)
	if type(v) == "number" and isFiniteNumber(v) then return v end
	if type(v) == "string" then
		local n = tonumber(v)
		if n and isFiniteNumber(n) then return n end
	end
	return nil
end

local function safeString(v)
	if v == nil then return nil end
	return tostring(v)
end

-- In-flight creation lock keyed by SlimeId to avoid concurrent create races
local _IN_FLIGHT = {}
local function inflight_acquire(key)
	if not key then return false end
	if _IN_FLIGHT[key] then return false end
	_IN_FLIGHT[key] = true
	return true
end
local function inflight_release(key)
	if not key then return end
	_IN_FLIGHT[key] = nil
end

-- Index registration, with duplicate prevention
local function ws_ensureIndex(player)
	if not player or not player.UserId then return {} end
	if not ws_liveIndex[player.UserId] then ws_liveIndex[player.UserId] = {} end
	return ws_liveIndex[player.UserId]
end

-- Finds an existing Slime model in Workspace by SlimeId, ignoring retired / tool-parented entries.
local function ws_findExistingSlimeById(slimeId)
	if not slimeId then return nil end
	local sidKey = tostring(slimeId)
	for _, inst in ipairs(Workspace:GetDescendants()) do
		if inst:IsA("Model") and inst.Name == "Slime" then
			local ok, sid = pcall(function() return inst:GetAttribute("SlimeId") end)
			if ok and sid and tostring(sid) == sidKey then
				-- skip retired or tool-parented ones
				local okRet, ret = pcall(function() return inst:GetAttribute("Retired") end)
				if okRet and ret then
					-- retired - skip
				else
					if not inst:FindFirstAncestorWhichIsA("Tool") then
						return inst
					end
				end
			end
		end
	end
	return nil
end

-- Helper to compute model ranking for dedupe:
-- Prefer models with (1) non-nil RestoreStamp (higher better), (2) LastGrowthUpdate (higher better), (3) larger part count.
local function model_rank_for_keep(m)
	if not m then return {stamp=0,growth=0,parts=0} end
	local stamp = 0
	pcall(function() stamp = tonumber(m:GetAttribute("RestoreStamp")) or stamp end)
	local lg = 0
	pcall(function() lg = tonumber(m:GetAttribute("LastGrowthUpdate")) or lg end)
	local cnt = 0
	for _, d in ipairs(m:GetDescendants()) do if d:IsA("BasePart") then cnt = cnt + 1 end end
	return {stamp = stamp, growth = lg, parts = cnt}
end

-- ws_registerModel: register live model and eliminate duplicates at registration time
-- Modified to prefer existing model reuse and avoid destructive races.
local function ws_registerModel(player, model)
	if not player or not model then return end
	local ok, id = pcall(function() return model:GetAttribute("SlimeId") end)
	if not ok or not id then return end
	local idx = ws_ensureIndex(player)
	local key = tostring(id)

	-- If another model with same ID already indexed, choose which to keep based on rank
	if idx[key] and idx[key] ~= model and idx[key].Parent then
		local a = idx[key]; local b = model
		local ra = model_rank_for_keep(a)
		local rb = model_rank_for_keep(b)
		-- prefer higher (stamp, growth, parts) lexicographically
		if (rb.stamp > ra.stamp) or (rb.stamp == ra.stamp and rb.growth > ra.growth) or (rb.stamp == ra.stamp and rb.growth == ra.growth and rb.parts > ra.parts) then
			-- new model looks better: destroy old and index new
			pcall(function() a:Destroy() end)
			idx[key] = b
		else
			-- existing model is better: destroy new one (or reparent it out)
			pcall(function()
				if b and b.Parent then
					-- attempt to merge attributes onto the keep model then destroy the duplicate
					for attr,_ in pairs(WS_ATTR_MAP) do
						local okv, vv = pcall(function() return b:GetAttribute(attr) end)
						if okv and vv ~= nil then
							pcall(function() a:SetAttribute(attr, vv) end)
						end
					end
					-- propagate RestoreStamp if new one has it
					local okrs, rsv = pcall(function() return b:GetAttribute("RestoreStamp") end)
					if okrs and rsv then pcall(function() a:SetAttribute("RestoreStamp", rsv) end) end
				end
				b:Destroy()
			end)
			return
		end
	end

	-- No indexed conflict; ensure we are not indexing a retired/tool-parented model
	local okRet, ret = pcall(function() return model:GetAttribute("Retired") end)
	if okRet and ret then return end
	if model:FindFirstAncestorWhichIsA("Tool") then return end

	idx[key] = model
	if WSCONFIG and WSCONFIG.MarkWorldSlimeAttribute then
		pcall(function() model:SetAttribute("WorldSlime", true) end)
	end
end

-- Scanning helpers (ignore temporary restore-in-progress models)
local function ws_scan_by_userid(userId)
	local out, seen = {}, {}
	for _, inst in ipairs(Workspace:GetDescendants()) do
		if inst:IsA("Model") and inst.Name == "Slime" and tostring(inst:GetAttribute("OwnerUserId")) == tostring(userId) and not inst:GetAttribute("Retired") and not inst:FindFirstAncestorWhichIsA("Tool") then
			local inFlight = false
			pcall(function() inFlight = inst:GetAttribute("_RestoreInProgress") or false end)
			if inFlight then continue end
			local id = inst:GetAttribute("SlimeId")
			if id and not seen[tostring(id)] then
				seen[tostring(id)] = true
				out[#out+1] = inst
			end
		end
	end
	return out
end

local function ws_scan(player)
	if not player then return {} end
	local out, seen = {}, {}
	for _, inst in ipairs(Workspace:GetDescendants()) do
		if inst:IsA("Model") and inst.Name == "Slime" then
			local owner = nil
			pcall(function() owner = inst:GetAttribute("OwnerUserId") end)
			if owner and tonumber(owner) == tonumber(player.UserId) and not inst:GetAttribute("Retired") and not inst:FindFirstAncestorWhichIsA("Tool") then
				local inFlight = false
				pcall(function() inFlight = inst:GetAttribute("_RestoreInProgress") or false end)
				if inFlight then continue end
				local id = inst:GetAttribute("SlimeId")
				if id and not seen[tostring(id)] then
					seen[tostring(id)] = true
					out[#out+1] = inst
					-- register but tolerant: ws_registerModel will attempt to dedupe sensibly
					pcall(function() ws_registerModel(player, inst) end)
				end
			end
		end
	end
	return out
end

-- resolvePlotCandidate: ensure availability
local function resolvePlotCandidate(plotCandidate)
	if type(plotCandidate) == "userdata" then
		local ok, isModel = pcall(function() return plotCandidate and plotCandidate.IsA and plotCandidate:IsA("Model") end)
		if ok and isModel then return plotCandidate end
		if ok and plotCandidate then return plotCandidate end
	end
	if type(plotCandidate) == "table" and type(plotCandidate.FindFirstChild) == "function" then return plotCandidate end
	if type(plotCandidate) == "string" and plotCandidate ~= "" then
		local p = Workspace:FindFirstChild(plotCandidate)
		if p and p:IsA("Model") then return p end
		local tryFolders = {
			Workspace:FindFirstChild("Plots"),
			Workspace:FindFirstChild("PlayerPlots"),
			Workspace:FindFirstChild("Player1"),
			Workspace:FindFirstChild("PlotsFolder"),
		}
		for _, folder in ipairs(tryFolders) do
			if folder and type(folder.FindFirstChild) == "function" then
				local c = folder:FindFirstChild(plotCandidate)
				if c and c:IsA("Model") then return c end
			end
		end
		for _, m in ipairs(Workspace:GetChildren()) do
			if m:IsA("Model") and tostring(m.Name) == plotCandidate then return m end
		end
		local ss = ServerStorage and ServerStorage:FindFirstChild(plotCandidate)
		if ss and ss:IsA("Model") then return ss end
		local rs = ReplicatedStorage and ReplicatedStorage:FindFirstChild(plotCandidate)
		if rs and rs:IsA("Model") then return rs end
	end
	return nil
end

-- Outgoing normalization
-- ws_normalizeOutgoingEntry (WorldSlime outgoing normalization)
local function ws_normalizeOutgoingEntry(raw)
	local entry = {}
	if raw.px ~= nil or raw.py ~= nil or raw.pz ~= nil then
		entry.px = parseNumber(raw.px)
		entry.py = parseNumber(raw.py)
		entry.pz = parseNumber(raw.pz)
	end
	if raw.lpx ~= nil or raw.lpy ~= nil or raw.lpz ~= nil then
		entry.lpx = parseNumber(raw.lpx)
		entry.lpy = parseNumber(raw.lpy)
		entry.lpz = parseNumber(raw.lpz)
	end
	if raw.ry ~= nil then entry.ry = parseNumber(raw.ry) end
	if raw.lry ~= nil then entry.lry = parseNumber(raw.lry) end

	for attr, short in pairs(WS_ATTR_MAP) do
		local v = raw[short]
		if v ~= nil then
			if colorKeys[short] and isColor3(v) then
				v = ws_colorToHex(v)
			end
			if short == "lu" then
				local now_tick = tick()
				local now_os = os.time()
				local maybe = normalize_time_to_epoch and normalize_time_to_epoch(v, now_tick, now_os) or nil
				if maybe then v = maybe end
			end
			if type(v) == "number" and not isFiniteNumber(v) then v = nil end
			entry[short] = v
		end
	end

	if raw.id ~= nil then entry.id = safeString(raw.id) end
	if raw.lg ~= nil then entry.lg = parseNumber(raw.lg) end
	if raw.ow ~= nil then entry.ow = parseNumber(raw.ow) or nil end
	return entry
end

-- ws_serialize: gather profile + live instances into normalized list
-- ws_serialize (WorldSlimes: gather profile + live instances into normalized list)
local function ws_serialize(player, isFinal, profile)
	local function shallow_clone(t)
		if type(t) ~= "table" then return t end
		local out = {}
		for k, v in pairs(t) do out[k] = v end
		return out
	end

	local function normalize_preserve(raw)
		local rc = shallow_clone(raw)
		local norm = ws_normalizeOutgoingEntry(rc) or {}
		for k, v in pairs(rc) do if norm[k] == nil then norm[k] = v end end
		return norm
	end

	local now_tick_global = tick()
	local now_os_global = os.time()

	local function processInstanceModel(m, origin)
		local sid = nil
		pcall(function() sid = m:GetAttribute("SlimeId") end)
		local sidKey = sid and tostring(sid) or nil
		local prim = m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart")
		if not prim then return nil, sidKey end
		local cf = prim.CFrame
		local raw_entry = { px = cf.X, py = cf.Y, pz = cf.Z }
		if WSCONFIG and WSCONFIG.UseLocalCoords and origin then
			local ok, lcf = pcall(function() return origin.CFrame:ToObjectSpace(cf) end)
			if ok and lcf then
				raw_entry.lpx, raw_entry.lpy, raw_entry.lpz = lcf.X, lcf.Y, lcf.Z
				raw_entry.lry = math.atan2(-lcf.LookVector.X, -lcf.LookVector.Z)
			end
		else
			raw_entry.ry = math.atan2(-cf.LookVector.X, -cf.LookVector.Z)
		end
		for attr, short in pairs(WS_ATTR_MAP) do
			local v = nil
			pcall(function() v = m:GetAttribute(attr) end)
			if v ~= nil then
				if colorKeys[short] and isColor3(v) then v = ws_colorToHex(v) end
				if short == "lu" then
					local maybe = normalize_time_to_epoch and normalize_time_to_epoch(v, now_tick_global, now_os_global) or nil
					if maybe then v = maybe end
				end
				if type(v) == "number" and not isFiniteNumber(v) then v = nil end
				raw_entry[short] = v
			end
		end
		if sid ~= nil then raw_entry.id = sid end
		if isFinal then raw_entry.lg = os.time() end

		local entry = normalize_preserve(raw_entry)

		if entry.lpx and math.abs(entry.lpx) > MAX_LOCAL_COORD_MAG then
			entry.lpx = (entry.lpx > 0) and MAX_LOCAL_COORD_MAG or -MAX_LOCAL_COORD_MAG
		end
		if entry.lpz and math.abs(entry.lpz) > MAX_LOCAL_COORD_MAG then
			entry.lpz = (entry.lpz > 0) and MAX_LOCAL_COORD_MAG or -MAX_LOCAL_COORD_MAG
		end

		return entry, sidKey
	end

	local function gatherLiveInstances(ply, prof)
		local list = {}
		local origin = nil
		if ply then
			list = ws_scan(ply)
			local plot = nil
			for _, m in ipairs(Workspace:GetChildren()) do
				local ok, val = pcall(function() return (tonumber(m:GetAttribute("UserId")) or tonumber(m:GetAttribute("OwnerUserId"))) end)
				if ok and val == ply.UserId and tostring(m.Name):match("^Player%d+$") then
					plot = m; break
				end
			end
			if plot then
				local zone = plot:FindFirstChild("SlimeZone")
				if zone and zone:IsA("BasePart") then origin = zone end
			end
			return list, origin
		end
		if prof and (prof.userId or prof.UserId) then
			return ws_scan_by_userid(prof.userId or prof.UserId), nil
		end
		return {}, nil
	end

	local invListFromProfile = {}
	if profile and type(profile) == "table" then
		if type(profile.worldSlimes) == "table" and #profile.worldSlimes > 0 then
			for _, raw in ipairs(profile.worldSlimes) do invListFromProfile[#invListFromProfile+1] = raw end
		elseif type(profile.inventory) == "table" and type(profile.inventory.worldSlimes) == "table" and #profile.inventory.worldSlimes > 0 then
			for _, raw in ipairs(profile.inventory.worldSlimes) do invListFromProfile[#invListFromProfile+1] = raw end
		end
	end

	local out = {}
	local seen = {}
	for _, raw in ipairs(invListFromProfile) do
		if type(raw) == "table" then
			local norm = normalize_preserve(raw)
			if norm.id then seen[tostring(norm.id)] = true end
			out[#out+1] = norm
			if #out >= (WSCONFIG and WSCONFIG.MaxWorldSlimesPerPlayer or 60) then return out end
		end
	end

	local liveInstances, origin = gatherLiveInstances(player, profile)
	for _, m in ipairs(liveInstances) do
		local entry, sidKey = processInstanceModel(m, origin)
		if entry then
			if not (sidKey and seen[sidKey]) then
				out[#out+1] = entry
				if sidKey then seen[sidKey] = true end
				if #out >= (WSCONFIG and WSCONFIG.MaxWorldSlimesPerPlayer or 60) then break end
			end
		end
	end

	return out
end

-- Incoming normalization
-- ws_normalizeIncomingEntry (WorldSlime incoming normalization)
local function ws_normalizeIncomingEntry(raw)
	if type(raw) ~= "table" then return nil end
	local now_tick = tick()
	local now_os = os.time()
	local e = {}
	-- owner
	if raw.ow then e.ow = parseNumber(raw.ow)
	elseif raw.OwnerUserId then e.ow = parseNumber(raw.OwnerUserId)
	elseif raw.OwnerPersistentId then e.ow = parseNumber(raw.OwnerPersistentId) end

	-- id variants
	if raw.id then e.id = safeString(raw.id)
	elseif raw.SlimeId then e.id = safeString(raw.SlimeId)
	elseif raw.EggId then e.id = safeString(raw.EggId) end

	-- coords
	if raw.px or raw.py or raw.pz then
		e.px = parseNumber(raw.px); e.py = parseNumber(raw.py); e.pz = parseNumber(raw.pz)
	elseif raw.x or raw.y or raw.z then
		e.px = parseNumber(raw.x); e.py = parseNumber(raw.y); e.pz = parseNumber(raw.z)
	end
	-- local coords
	if raw.lpx or raw.lpy or raw.lpz then
		e.lpx = parseNumber(raw.lpx); e.lpy = parseNumber(raw.lpy); e.lpz = parseNumber(raw.lpz)
	elseif raw.localX or raw.localY or raw.localZ then
		e.lpx = parseNumber(raw.localX); e.lpy = parseNumber(raw.localY); e.lpz = parseNumber(raw.localZ)
	end

	-- Position table
	if raw.Position and type(raw.Position) == "table" then
		local P = raw.Position
		e.px = e.px or parseNumber(P.x or P.X or P[1])
		e.py = e.py or parseNumber(P.y or P.Y or P[2])
		e.pz = e.pz or parseNumber(P.z or P.Z or P[3])
	end

	if raw.ry then e.ry = parseNumber(raw.ry) end
	if raw.lry then e.lry = parseNumber(raw.lry) end

	-- Preserve explicit last-growth 'lg'
	if raw.lg then e.lg = parseNumber(raw.lg) end

	-- Accept Timestamp / ts
	if not e.lg then
		if raw.Timestamp then
			e.lg = parseNumber(raw.Timestamp)
		elseif raw.ts then
			e.lg = parseNumber(raw.ts)
		elseif raw.timestamp then
			e.lg = parseNumber(raw.timestamp)
		end
	end

	for attr, short in pairs(WS_ATTR_MAP) do
		local v = raw[short]
		if v == nil then v = raw[attr] end
		if v ~= nil then
			if colorKeys[short] then
				if type(v) == "table" and (v.r or v.R) and (v.g or v.G) and (v.b or v.B) then
					local rr = tonumber(v.r or v.R) or 0
					local gg = tonumber(v.g or v.G) or 0
					local bb = tonumber(v.b or v.B) or 0
					v = ws_colorToHex(Color3.fromRGB(rr, gg, bb))
				end
			else
				if type(v) == "string" then
					local maybeNum = tonumber(v)
					if maybeNum then v = maybeNum end
				end
			end

			if short == "lu" then
				local normalized = normalize_time_to_epoch and normalize_time_to_epoch(v, now_tick, now_os) or nil
				if normalized then v = normalized end
			end

			e[short] = v
		end
	end

	-- require id or positional/attr data
	local hasMeaningful = false
	if e.id then hasMeaningful = true end
	if e.px or e.py or e.pz or e.lpx or e.lpy or e.lpz then hasMeaningful = true end
	for _, short in pairs(WS_ATTR_MAP) do
		if e[short] ~= nil then hasMeaningful = true; break end
	end
	if not hasMeaningful then return nil end

	-- clamp local coords
	if e.lpx and math.abs(e.lpx) > MAX_LOCAL_COORD_MAG then
		e.lpx = (e.lpx > 0) and MAX_LOCAL_COORD_MAG or -MAX_LOCAL_COORD_MAG
	end
	if e.lpz and math.abs(e.lpz) > MAX_LOCAL_COORD_MAG then
		e.lpz = (e.lpz > 0) and MAX_LOCAL_COORD_MAG or -MAX_LOCAL_COORD_MAG
	end

	return e
end




-- buildFactoryEntry (safe copy)
local function buildFactoryEntry(e)
	if type(e) ~= "table" then return e end
	local fe = {}
	for attr, short in pairs(WS_ATTR_MAP) do
		if e[short] ~= nil then
			fe[short] = e[short]; fe[attr] = e[short]
		elseif e[attr] ~= nil then
			fe[short] = e[attr]; fe[attr] = e[attr]
		end
	end
	local copyKeys = { "id","SlimeId","OwnerUserId","ow","px","py","pz","lpx","lpy","lpz","ry","lry","ts","lg","Timestamp","Position" }
	for _, k in ipairs(copyKeys) do if e[k] ~= nil then fe[k] = e[k] end end
	if type(e.Position) == "table" then
		local pos = e.Position
		fe.px = fe.px or (pos.x or pos.X or pos[1])
		fe.py = fe.py or (pos.y or pos.Y or pos[2])
		fe.pz = fe.pz or (pos.z or pos.Z or pos[3])
	end
	if not fe.OwnerUserId and fe.ow then fe.OwnerUserId = tonumber(fe.ow) end
	fe.__raw = e
	return fe
end

-- tryCreateUsingFactoryModules: re-check existing before creating; mark in-flight before parenting
-- Uses inflight_acquire/release to avoid duplicate concurrent creations.
local function tryCreateUsingFactoryModules(factoryModule, coreModule, factoryEntry, player, plot)
	local candidates = {
		"RestoreFromSnapshot","RestoreWorldSlime","Restore","RestoreSlime",
		"CreateFromSnapshot","CreateWorldSlime","CreateSlime","Create",
		"BuildFromSnapshot","BuildWorldSlime","BuildSlime"
	}

	-- check pre-existing by SlimeId to avoid race
	if factoryEntry and factoryEntry.id then
		local already = ws_findExistingSlimeById(factoryEntry.id)
		if already then
			dprint("tryCreateUsingFactoryModules: found existing for id", tostring(factoryEntry.id))
			return already
		end
	end

	local function tryCall(tbl)
		if not tbl or type(tbl) ~= "table" then return nil end
		for _, name in ipairs(candidates) do
			if type(tbl[name]) == "function" then
				local ok, res = pcall(function() return tbl[name](factoryEntry, player, plot) end)
				if ok and res then
					-- mark in-flight early to avoid duplication during concurrent restores
					pcall(function() res:SetAttribute("_RestoreInProgress", true) end)
					-- ensure SlimeId is set as early as possible
					if factoryEntry and factoryEntry.id then
						pcall(function()
							if not res:GetAttribute("SlimeId") then res:SetAttribute("SlimeId", factoryEntry.id) end
						end)
					end
					return res
				end
			end
		end
		return nil
	end

	-- Acquire inflight lock (if id present)
	local key = factoryEntry and factoryEntry.id and tostring(factoryEntry.id) or nil
	local acquired = key and inflight_acquire(key) or true
	if not acquired then
		-- Someone else is creating; try to find the instance now
		if key then
			local foundNow = ws_findExistingSlimeById(key)
			if foundNow then return foundNow end
			-- fallback to nil
		end
	end

	-- try on factoryModule first, then coreModule
	local created = nil
	local ok, err = pcall(function()
		created = tryCall(factoryModule) or tryCall(coreModule)
		-- fallback: attempt SlimeFactory nested on coreModule
		if not created and coreModule and type(coreModule) == "table" then
			local sf = coreModule.SlimeFactory or coreModule.Factory
			created = tryCall(sf)
		end
	end)
	if key then inflight_release(key) end

	-- If created, best-effort ensure SlimeId already set and mark _RestoreInProgress
	if created then
		pcall(function()
			if factoryEntry and factoryEntry.id and (not pcall(function() return created:GetAttribute("SlimeId") end)) then
				created:SetAttribute("SlimeId", factoryEntry.id)
			end
			created:SetAttribute("_RestoreInProgress", true)
		end)
	end

	return created
end

-- clearPreserveFlagsAndRecompute (tolerant)
local function clearPreserveFlagsAndRecompute(model)
	if not model then return end
	pcall(function() model:SetAttribute("ServerRestore", nil) end)
	pcall(function() model:SetAttribute("PreserveOnServer", nil) end)
	pcall(function() model:SetAttribute("RestoreStamp", nil) end)

	local function tryImmediate()
		local function callInModule(mod)
			if not mod or type(mod) ~= "table" then return false end
			for _, fname in ipairs({"ApplyOfflineDecay","RecomputeHunger","Recompute","UpdateHunger","ApplyHungerState"}) do
				if type(mod[fname]) == "function" then
					local ok = pcall(function() mod[fname](model) end)
					if ok then return true end
				end
			end
			return false
		end

		local tryMods = {}
		pcall(function()
			local ms = ServerScriptService and ServerScriptService:FindFirstChild("Modules")
			if ms then table.insert(tryMods, ms:FindFirstChild("SlimeCore")) end
			table.insert(tryMods, ServerScriptService and ServerScriptService:FindFirstChild("SlimeCore"))
			table.insert(tryMods, ReplicatedStorage and ReplicatedStorage:FindFirstChild("SlimeCore"))
			table.insert(tryMods, ServerScriptService and ServerScriptService:FindFirstChild("SlimeHungerService"))
			table.insert(tryMods, ReplicatedStorage and ReplicatedStorage:FindFirstChild("SlimeHungerService"))
		end)

		for _, cand in ipairs(tryMods) do
			if cand and cand.IsA and cand:IsA("ModuleScript") then
				local ok2, mod = pcall(function() return require(cand) end)
				if ok2 and type(mod) == "table" then
					if callInModule(mod) then return true end
					if mod.SlimeHungerService and callInModule(mod.SlimeHungerService) then return true end
				end
			elseif type(cand) == "table" then
				if callInModule(cand) then return true end
			end
		end

		return false
	end

	local okNow = pcall(function() return tryImmediate() end)
	if not okNow then
		task.defer(function()
			pcall(function() tryImmediate() end)
		end)
	end
end

-- Utility to count BaseParts
local function partCount(model)
	if not model then return 0 end
	local c = 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then c = c + 1 end
	end
	return c
end

-- eliminateDuplicateFor: robustly pick best model from pair
local function eliminateDuplicateFor(created, sidKey, parent)
	pcall(function() if created and created.Parent == nil then created.Parent = parent or Workspace end end)
	task.wait(0.01)

	if not sidKey then
		local ok, got = pcall(function() return created and created:GetAttribute("SlimeId") end)
		if ok and got then sidKey = tostring(got) end
	end
	if not sidKey then return created end

	local other = ws_findExistingSlimeById(sidKey)
	if other and other ~= created then
		local ra = model_rank_for_keep(other)
		local rb = model_rank_for_keep(created)
		-- prefer the one with higher stamp, then growth, then parts
		local keepOther = false
		if (ra.stamp > rb.stamp) or (ra.stamp == rb.stamp and ra.growth > rb.growth) or (ra.stamp == rb.stamp and ra.growth == rb.growth and ra.parts >= rb.parts) then
			keepOther = true
		end

		if keepOther then
			-- merge useful attributes from created into other then destroy created
			pcall(function()
				for attr,_ in pairs(WS_ATTR_MAP) do
					local ok, v = pcall(function() return created:GetAttribute(attr) end)
					if ok and v ~= nil then
						pcall(function() other:SetAttribute(attr, v) end)
					end
				end
			end)
			pcall(function() created:Destroy() end)
			return other
		else
			pcall(function() other:Destroy() end)
			return created
		end
	end
	return created
end

-- dedupe_now: scan workspace and remove duplicate Slime models keeping best candidate
local function dedupe_now()
	local seen = {}
	local removed = 0
	for _, m in ipairs(Workspace:GetDescendants()) do
		if m:IsA("Model") and m.Name == "Slime" then
			local ok, sid = pcall(function() return m:GetAttribute("SlimeId") end)
			if ok and sid then
				local key = tostring(sid)
				local inFlight = false
				pcall(function() inFlight = m:GetAttribute("_RestoreInProgress") or false end)
				-- if we encounter duplicates, keep the best-ranked one
				if seen[key] then
					local keep = seen[key]
					local ra = model_rank_for_keep(keep)
					local rb = model_rank_for_keep(m)
					local keepCurrent = (ra.stamp > rb.stamp) or (ra.stamp == rb.stamp and ra.growth > rb.growth) or (ra.stamp == rb.stamp and ra.growth == rb.growth and ra.parts >= rb.parts)
					if not keepCurrent then
						pcall(function() keep:Destroy() end)
						seen[key] = m
					else
						pcall(function() m:Destroy() end)
					end
					removed = removed + 1
				else
					seen[key] = m
				end
			end
		end
	end
	dprint("dedupe_now removed", removed, "duplicates")
	return removed
end

-- tryCreateUsingFactoryModules already defined above; ws_restore uses it


-- Replacement finalizeRestoreModel with visual graft attempt
-- Paste this function in GrandInventorySerializer.lua replacing the prior finalizeRestoreModel definition.

local function dprintf(...)
	local ok, _ = pcall(function() end)
	return ok
end

local function try_find_slime_template()
	-- Try common locations: ReplicatedStorage.Assets.Slime, ReplicatedStorage.Slime, ServerStorage.Slime
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if assets then
		local s = assets:FindFirstChild("Slime")
		if s and s:IsA("Model") then return s end
	end
	local s2 = ReplicatedStorage:FindFirstChild("Slime")
	if s2 and s2:IsA("Model") then return s2 end
	local s3 = ReplicatedStorage:FindFirstChild("SlimeTemplate")
	if s3 and s3:IsA("Model") then return s3 end
	return nil
end

local function sanitize_and_clone_visual(templateModel)
	if not templateModel or not templateModel:IsA("Model") then return nil, "bad-template" end
	local ok, clone = pcall(function() return templateModel:Clone() end)
	if not ok or not clone then return nil, "clone-failed" end

	-- remove scripts and make parts non-colliding initially
	for _,desc in ipairs(clone:GetDescendants()) do
		if desc:IsA("Script") or desc:IsA("LocalScript") or desc:IsA("ModuleScript") then
			pcall(function() desc:Destroy() end)
		elseif desc:IsA("BasePart") then
			pcall(function()
				desc.Anchored = true     -- anchored while we position
				desc.CanCollide = false
				desc.CanTouch = false
				desc.CanQuery = false
				-- keep OriginalSize if present, but ensure attribute exists
				if not pcall(function() return desc:GetAttribute("OriginalSize") end) then
					desc:SetAttribute("OriginalSize", desc.Size)
				end
			end)
		end
	end

	-- ensure PrimaryPart exists on the clone (pick first BasePart if needed)
	if not clone.PrimaryPart then
		for _,c in ipairs(clone:GetDescendants()) do
			if c:IsA("BasePart") then
				clone.PrimaryPart = c
				break
			end
		end
	end

	if not clone.PrimaryPart then
		return nil, "visual-no-primary"
	end

	return clone, nil
end

local function ensure_model_primary(model)
	if not model or not model.Parent then return nil end
	if model.PrimaryPart and model.PrimaryPart:IsDescendantOf(model) then return model.PrimaryPart end
	-- try common candidate names
	local candidates = { "Outer","Inner","Body","Core","Main","Torso","Slime","Base","Handle" }
	for _,name in ipairs(candidates) do
		local p = model:FindFirstChild(name)
		if p and p:IsA("BasePart") then
			model.PrimaryPart = p
			return p
		end
	end
	-- fallback to first BasePart found
	for _,c in ipairs(model:GetDescendants()) do
		if c:IsA("BasePart") then
			model.PrimaryPart = c
			return c
		end
	end
	return nil
end

local function apply_colors_and_scale_to_visual(clone, sourceAttrs)
	-- sourceAttrs: table with BodyColor/AccentColor/EyeColor/CurrentSizeScale etc
	if not clone or type(sourceAttrs) ~= "table" then return end

	local function decodeColor(val)
		if not val then return nil end
		if type(val) == "string" then
			local hex = val:gsub("^#","")
			if #hex == 6 then
				local r = tonumber(hex:sub(1,2),16)
				local g = tonumber(hex:sub(3,4),16)
				local b = tonumber(hex:sub(5,6),16)
				if r and g and b then return Color3.fromRGB(r,g,b) end
			end
		end
		if typeof and typeof(val) == "Color3" then return val end
		return nil
	end

	local bc = decodeColor(sourceAttrs.BodyColor)
	local ac = decodeColor(sourceAttrs.AccentColor)
	local ec = decodeColor(sourceAttrs.EyeColor)
	local scale = tonumber(sourceAttrs.CurrentSizeScale or sourceAttrs.StartSizeScale) or nil

	for _,p in ipairs(clone:GetDescendants()) do
		if p:IsA("BasePart") then
			local ln = (p.Name or ""):lower()
			if ec and (ln:find("eye") or ln:find("pupil")) then
				p.Color = ec
			elseif ac and ln:find("accent") then
				p.Color = ac
			elseif bc then
				-- avoid overwriting explicit accent parts
				if not ln:find("accent") then p.Color = bc end
			end

			if scale and scale > 0 then
				local orig = p:GetAttribute("OriginalSize") or p.Size
				local ns = orig * scale
				p.Size = Vector3.new(math.max(ns.X, 0.05), math.max(ns.Y, 0.05), math.max(ns.Z, 0.05))
			end
		end
	end
end

local function graft_template_visuals_to_model(targetModel, entry, originCF)
	if not targetModel or not targetModel.Parent then
		dprintf("graft: bad targetModel")
		return false
	end

	local eggId = nil


	dprintf("graft: attempting for model=", targetModel:GetFullName(), "SlimeId=", tostring(eggId))

	local tpl = try_find_slime_template()
	if not tpl then
		dprintf("graft: template not found")
		return false
	end

	local clone, err = sanitize_and_clone_visual(tpl)
	if not clone then
		dprintf("graft: sanitize/clone failed:", tostring(err))
		return false
	end
	clone.Name = "SlimeVisual"

	-- ensure primaries
	local visualPrim = clone.PrimaryPart
	local modelPrim = ensure_model_primary(targetModel)
	if not modelPrim then
		dprintf("graft: target model has no PrimaryPart:", targetModel:GetFullName())
		-- still parent clone so dev can inspect
		clone.Parent = targetModel
		return false
	end

	-- determine final target CFrame
	local targetCF = originCF
	if not targetCF and modelPrim then targetCF = modelPrim.CFrame end
	if not targetCF and visualPrim then targetCF = visualPrim.CFrame end

	-- set clone position BEFORE unanchoring/parenting to avoid falling
	if targetCF then
		pcall(function()
			if clone.PrimaryPart then
				clone:SetPrimaryPartCFrame(targetCF)
			else
				for _,p in ipairs(clone:GetDescendants()) do
					if p:IsA("BasePart") then p.CFrame = targetCF end
				end
			end
		end)
	end

	-- parent the visual to the target model
	clone.Parent = targetModel

	-- re-resolve prims after parenting
	visualPrim = clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart")
	modelPrim  = targetModel.PrimaryPart or ensure_model_primary(targetModel)

	if not visualPrim or not modelPrim then
		dprintf("graft: missing prims after parenting. visualPrim=", tostring(visualPrim), " modelPrim=", tostring(modelPrim))
		return false
	end

	-- un-anchor parts and disable collisions then weld using WeldConstraint
	for _,p in ipairs(clone:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = false
			p.CanCollide = false
			p.CanTouch = false
			p.CanQuery = false
		end
	end

	-- Ensure both parts are non-anchored before creating constraint
	pcall(function() modelPrim.Anchored = false end)
	pcall(function() visualPrim.Anchored = false end)

	local ok, errW = pcall(function()
		local wc = Instance.new("WeldConstraint")
		wc.Part0 = modelPrim
		wc.Part1 = visualPrim
		wc.Parent = modelPrim
	end)
	if not ok then
		dprintf("graft: WeldConstraint creation failed:", tostring(errW))
		-- leave clone parented for inspection
		return false
	end

	-- apply appearance/scale if provided by entry or model attributes
	local attrs = {}
	if type(entry) == "table" then
		for k,v in pairs(entry) do attrs[k] = v end
	end
	-- prefer model attributes if present
	pcall(function()
		local bc = targetModel:GetAttribute("BodyColor"); if bc then attrs.BodyColor = attrs.BodyColor or bc end
		local ac = targetModel:GetAttribute("AccentColor"); if ac then attrs.AccentColor = attrs.AccentColor or ac end
		local ec = targetModel:GetAttribute("EyeColor"); if ec then attrs.EyeColor = attrs.EyeColor or ec end
		local cs = targetModel:GetAttribute("CurrentSizeScale"); if cs then attrs.CurrentSizeScale = attrs.CurrentSizeScale or cs end
	end)

	pcall(function() apply_colors_and_scale_to_visual(clone, attrs) end)

	-- mark clone so other flows can detect it
	pcall(function() clone:SetAttribute("ServerRestoreVisual", true) end)
	pcall(function() clone:SetAttribute("RestoreStamp", tick()) end)

	dprintf("graft: success for SlimeId=", tostring(eggId), "visualParent=", clone.Parent and clone.Parent:GetFullName())

	return true
end



local function finalizeRestoreModel(model, entry, origin, plotInst, targetCF, SlimeCoreMod, ModelUtilsLocal, SlimeFactory, SlimeAI_local)
	if not model then return end

	-- existing integration hook (call internal finalize if present)
	pcall(function()
		if GrandInventorySerializer and GrandInventorySerializer._internal and GrandInventorySerializer._internal.WorldSlime and type(GrandInventorySerializer._internal.WorldSlime.finalizeRestoreModel) == "function" then
			GrandInventorySerializer._internal.WorldSlime.finalizeRestoreModel(model, entry, origin, plotInst, targetCF, SlimeCoreMod, ModelUtilsLocal, SlimeFactory, SlimeAI_local)
			return
		end
	end)

	-- global finalize hook fallback
	local okGlobal, didGlobal = pcall(function()
		if type(_G) == "table" and type(_G.finalizeRestoreModel) == "function" then
			_G.finalizeRestoreModel(model, entry, origin, plotInst, targetCF, SlimeCoreMod, ModelUtilsLocal, SlimeFactory, SlimeAI_local)
			return true
		end
		return false
	end)
	if okGlobal and didGlobal then return end

	-- try a handful of common named API calls on SlimeFactory/SlimeCoreMod
	local function try_names(mod)
		if not mod or type(mod) ~= "table" then return false end
		local names = {"FinalizeRestore","Finalize","RestoreFinalize","RestoreFromSnapshot","Restore","FinalizeModel","InitSlime","ApplyVisuals"}
		for _,n in ipairs(names) do
			if type(mod[n]) == "function" then
				pcall(function() mod[n](model, entry, plotInst) end)
				return true
			end
		end
		return false
	end
	if try_names(SlimeFactory) then return end
	if try_names(SlimeCoreMod) then return end

	-- graft attempt disabled to avoid welding template visuals during server restore
	local graftOk = false -- (disabled) 
	-- pcall(function() graftOk = graft_template_visuals_to_model(model, entry, targetCF) end)
	if graftOk then
		-- mark restore attributes and return
		pcall(function()
			model:SetAttribute("_RestoreInProgress", nil)
			model:SetAttribute("RestoreStamp", tick())
			model:SetAttribute("ServerRestore", true)
		end)
		return
	end

	-- Minimal fallback: safe placement/pivot/anchor/scale handling

	local parent = plotInst or Workspace
	pcall(function() model.Parent = parent end)

	-- Ensure PrimaryPart: prefer explicit, otherwise pick largest BasePart
	local prim = nil
	pcall(function() prim = model.PrimaryPart end)
	if not prim then
		pcall(function() prim = model:FindFirstChildWhichIsA("BasePart") end)
	end
	if not prim then
		local best, bestVol = nil, 0
		for _,part in ipairs(model:GetDescendants()) do
			if part and type(part.IsA) == "function" and part:IsA("BasePart") then
				local vol = (part.Size.X * part.Size.Y * part.Size.Z) or 0
				if vol > bestVol then best = part; bestVol = vol end
			end
		end
		if best then
			prim = best
			pcall(function() model.PrimaryPart = prim end)
		end
	end

	-- Mark as in-flight
	pcall(function() model:SetAttribute("_RestoreInProgress", true) end)
	pcall(function() model:SetAttribute("ServerRestore", true) end)

	-- Helper to zero velocities
	local function zeroVelocity(part)
		if not part or type(part.IsA) ~= "function" or not part:IsA("BasePart") then return end
		pcall(function() part.Velocity = Vector3.new(0,0,0) end)
		pcall(function() part.RotVelocity = Vector3.new(0,0,0) end)
		pcall(function() part.AssemblyLinearVelocity = Vector3.new(0,0,0) end)
		pcall(function() part.AssemblyAngularVelocity = Vector3.new(0,0,0) end)
	end

	-- Anchor and zero velocity on all BaseParts, record prior anchored/collide states
	local prevAnchored, prevCanCollide = {}, {}
	for _,bp in ipairs(model:GetDescendants()) do
		if bp and type(bp.IsA) == "function" and bp:IsA("BasePart") then
			local okA, a = pcall(function() return bp.Anchored end)
			if okA then prevAnchored[bp] = a end
			local okC, c = pcall(function() return bp.CanCollide end)
			if okC then prevCanCollide[bp] = c end

			pcall(function() bp.Anchored = true end)
			local lname = (bp.Name or ""):lower()
			local enableCollision = false
			if lname:find("body") or lname:find("base") or lname:find("root") or bp == prim then enableCollision = true end
			if not enableCollision and (bp.Size and (bp.Size.Magnitude >= 0.5)) then enableCollision = true end
			if enableCollision then pcall(function() bp.CanCollide = true end) end

			zeroVelocity(bp)
		end
	end

	-- PivotTo targetCF if provided and primary present
	if targetCF and prim then
		pcall(function() model:PivotTo(targetCF) end)
		pcall(function() model.Parent = parent end)
	elseif prim then
		pcall(function() model.Parent = parent end)
	else
		pcall(function() model.Parent = parent end)
	end

	-- Try ModelUtils.UniformScale if available (best-effort)
	pcall(function()
		if ModelUtilsLocal and type(ModelUtilsLocal.UniformScale) == "function" then
			local maybeScale = nil
			if type(entry) == "table" then maybeScale = tonumber(entry.CurrentSizeScale or entry.sz or entry.StartSizeScale) end
			if not maybeScale then
				local ok, v = pcall(function() return model:GetAttribute("CurrentSizeScale") end)
				if ok and v then maybeScale = tonumber(v) end
			end
			if maybeScale then
				pcall(function() ModelUtilsLocal.UniformScale(model, maybeScale) end)
			end
		end
	end)

	-- Release anchors after short delay and run recompute/init calls
	task.delay(1.0, function()
		for bp, _ in pairs(prevAnchored) do
			if bp and bp.Parent then
				pcall(function()
					local prev = prevAnchored[bp]
					if prev == true then bp.Anchored = true else bp.Anchored = false end
					if prevCanCollide[bp] ~= nil then bp.CanCollide = prevCanCollide[bp] end
				end)
			end
		end

		pcall(function()
			model:SetAttribute("_RestoreInProgress", nil)
			model:SetAttribute("RestoreStamp", tick())
			model:SetAttribute("ServerRestore", true)
			pcall(function() model:SetAttribute("RecentlyPlacedSaved", os.time()) end)
		end)

		pcall(function()
			if SlimeCoreMod and type(SlimeCoreMod.Recompute) == "function" then
				SlimeCoreMod.Recompute(model)
			end
		end)
	end)
end

-- ws_restore (WorldSlimes restore; dedupe + reuse existing models + in-flight locks)
local function ws_restore(player, list)
	if not list or type(list) ~= "table" or #list == 0 then
		if GrandInventorySerializer and GrandInventorySerializer.CONFIG and GrandInventorySerializer.CONFIG.Debug then
			dprint("ws_restore: nothing to restore for player", tostring(player and player.UserId or "<nil>"))
		end
		return
	end
	if player then
		waitForInventoryReady(player)
	end
	local normalized = {}
	for _, raw in ipairs(list) do
		local ok, n = pcall(function() return ws_normalizeIncomingEntry(raw) end)
		if ok and type(n) == "table" then
			table.insert(normalized, n)
		else
			if GrandInventorySerializer and GrandInventorySerializer.CONFIG and GrandInventorySerializer.CONFIG.Debug then
				dprint("ws_restore: dropped malformed entry for player", tostring(player and player.UserId or "<nil>"))
			end
		end
	end
	if #normalized == 0 then return end

	-- If we have a player or a userId, merge incoming entries into the cached profile worldSlimes first
	-- This prevents duplicate entries accumulating in profile.inventory.worldSlimes across multiple restore passes.
	if player and player.UserId then
		pcall(function() merge_incoming_into_profile_worldslimes(player.UserId, normalized) end)
	end

	if player then
		pcall(function() ws_scan(player) end)
	end

	local plotRaw = nil
	if player then
		local ok, p = pcall(function() return we_findPlayerPlot_by_userid(player.UserId) end)
		if ok and p then
			plotRaw = p
		else
			local ok2, p2 = pcall(function() return _we_findPlayerPlot and _we_findPlayerPlot(player) end)
			if ok2 and p2 then plotRaw = p2 end
		end
	else
		local ownerUid = nil
		for _, e in ipairs(normalized) do
			if not ownerUid and e and e.ow then ownerUid = tonumber(e.ow) or ownerUid end
			if ownerUid then break end
		end
		if ownerUid then
			local ok1, pr = pcall(function() return we_findPlayerPlot_by_userid and we_findPlayerPlot_by_userid(ownerUid) end)
			if ok1 and pr then plotRaw = pr end
			if not plotRaw then
				local ok2, pr2 = pcall(function() return we_findPlayerPlot_by_persistentId and we_findPlayerPlot_by_persistentId(ownerUid) end)
				if ok2 and pr2 then plotRaw = pr2 end
			end
		end
	end

	local plotInst = resolvePlotCandidate(plotRaw)
	local origin = nil
	if plotInst then
		local ok, o = pcall(function() return _we_getPlotOrigin and _we_getPlotOrigin(plotInst) end)
		if ok and o then origin = o end
	end

	local parent = plotInst or Workspace
	local restored = 0
	local restoredModels = {}
	local restoredIds = {}
	local persistentId = player and getPersistentIdFor and getPersistentIdFor(player) or nil

	-- Require modules
	local SlimeFactory, ModelUtilsLocal, SlimeAI_local, SlimeCoreMod
	do
		local function tryRequire(name)
			local ok, mod = pcall(function()
				local ms = ServerScriptService:FindFirstChild("Modules")
				if ms then
					local inst = ms:FindFirstChild(name)
					if inst and inst:IsA("ModuleScript") then return require(inst) end
				end
				local direct = ServerScriptService:FindFirstChild(name)
				if direct and direct:IsA("ModuleScript") then return require(direct) end
				local rs = ReplicatedStorage and ReplicatedStorage:FindFirstChild(name)
				if rs and rs:IsA("ModuleScript") then return require(rs) end
				return nil
			end)
			if ok and type(mod) == "table" then return mod end
			return nil
		end

		local function trySlimeCore()
			local ok, sc = pcall(function()
				local candidates = {
					function() if script and script.Parent then return script.Parent:FindFirstChild("SlimeCore") end end,
					function() local m = ServerScriptService:FindFirstChild("Modules"); if m then return m:FindFirstChild("SlimeCore") end end,
					function() return ServerScriptService:FindFirstChild("SlimeCore") end,
					function() return ReplicatedStorage and ReplicatedStorage:FindFirstChild("SlimeCore") end,
				}
				for _, finder in ipairs(candidates) do
					local inst = finder()
					if inst and inst:IsA("ModuleScript") then
						return require(inst)
					end
				end
				return nil
			end)
			if ok and type(sc) == "table" then return sc end
			return nil
		end

		SlimeFactory = tryRequire("SlimeFactory")
		ModelUtilsLocal = tryRequire("ModelUtils")
		SlimeAI_local = tryRequire("SlimeAI")
		SlimeCoreMod = trySlimeCore()

		if SlimeCoreMod then
			if not SlimeFactory then
				SlimeFactory = SlimeCoreMod.SlimeFactory or SlimeCoreMod.Factory or SlimeCoreMod.Restore or SlimeCoreMod
			end
			if not ModelUtilsLocal then
				ModelUtilsLocal = SlimeCoreMod.ModelUtils or SlimeCoreMod.Model
			end
			if not SlimeAI_local then
				SlimeAI_local = SlimeCoreMod.SlimeAI or SlimeCoreMod.AI
			end
		end
	end

	local function clamp_local(v, maxmag)
		if v == nil then return nil end
		if math.abs(v) > maxmag then return (v > 0) and maxmag or -maxmag end
		return v
	end
	local function is_local_coords_present(lx, ly, lz)
		return (lx ~= nil) or (ly ~= nil) or (lz ~= nil)
	end

	local function buildFactoryEntry(e)
		if type(e) ~= "table" then return e end
		local fe = {}
		for attr, short in pairs(WS_ATTR_MAP) do
			if e[short] ~= nil then
				fe[short] = e[short]; fe[attr] = e[short]
			elseif e[attr] ~= nil then
				fe[short] = e[attr]; fe[attr] = e[attr]
			end
		end
		local copyKeys = { "id","SlimeId","OwnerUserId","ow","px","py","pz","lpx","lpy","lpz","ry","lry","ts","lg","Timestamp","Position" }
		for _, k in ipairs(copyKeys) do if e[k] ~= nil then fe[k] = e[k] end end
		if type(e.Position) == "table" then
			local pos = e.Position
			fe.px = fe.px or (pos.x or pos.X or pos[1])
			fe.py = fe.py or (pos.y or pos.Y or pos[2])
			fe.pz = fe.pz or (pos.z or pos.Z or pos[3])
		end
		if not fe.OwnerUserId and fe.ow then fe.OwnerUserId = tonumber(fe.ow) end
		fe.__raw = e
		return fe
	end

	for _, e in ipairs(normalized) do
		if restored >= (WSCONFIG and WSCONFIG.MaxWorldSlimesPerPlayer or 60) then break end
		if type(e) ~= "table" then break end

		local sid = e.id
		local sidKey = sid and tostring(sid) or nil

		-- Skip duplicates in-restoration set
		if sidKey and restoredIds[sidKey] then
			if GrandInventorySerializer and GrandInventorySerializer.CONFIG and GrandInventorySerializer.CONFIG.Debug then
				dprint("ws_restore: skipping duplicate slime id in batch", tostring(sid))
			end
		else
			local existing = nil
			if sidKey then existing = ws_findExistingSlimeById(sidKey) end
			local skip_existing_remaining = false

			if existing then
				-- Update attributes on existing model
				pcall(function()
					local ownerUidVal = (player and player.UserId) or e.ow or existing:GetAttribute("OwnerUserId")
					existing:SetAttribute("OwnerUserId", ownerUidVal)
					if persistentId then existing:SetAttribute("OwnerPersistentId", persistentId) end
					for attr, short in pairs(WS_ATTR_MAP) do
						local v = e[short]
						if v == nil then v = e[attr] end
						if v ~= nil then
							if colorKeys[short] and type(v) == "string" then
								local c = ws_hexToColor3(v)
								if c then existing:SetAttribute(attr, c) else existing:SetAttribute(attr, v) end
							else
								existing:SetAttribute(attr, v)
							end
						end
					end
					if e.lg then existing:SetAttribute("PersistedGrowthProgress", e.lg) end
					if e.lpx then existing:SetAttribute("RestoreLpx", e.lpx) end
					if e.lpy then existing:SetAttribute("RestoreLpy", e.lpy) end
					if e.lpz then existing:SetAttribute("RestoreLpz", e.lpz) end
					if e.px then existing:SetAttribute("RestorePX", e.px) end
					if e.py then existing:SetAttribute("RestorePY", e.py) end
					if e.pz then existing:SetAttribute("RestorePZ", e.pz) end
				end)

				local prim = existing.PrimaryPart or existing:FindFirstChildWhichIsA("BasePart")
				if (not prim) and (SlimeFactory or SlimeCoreMod) then
					local factoryEntry = buildFactoryEntry(e)
					local created = tryCreateUsingFactoryModules(SlimeFactory, SlimeCoreMod, factoryEntry, player, plotInst)
					if created then
						pcall(function() ws_registerModel(player, created) end)
						table.insert(restoredModels, created)
						if sidKey then restoredIds[sidKey] = true end
						restored = restored + 1
						skip_existing_remaining = true
					end
				end

				if not skip_existing_remaining then
					local prim2 = existing and (existing.PrimaryPart or existing:FindFirstChildWhichIsA("BasePart"))
					if prim2 then
						local lpx = parseNumber(e.lpx)
						local lpy = parseNumber(e.lpy)
						local lpz = parseNumber(e.lpz)
						local px = parseNumber(e.px)
						local py = parseNumber(e.py)
						local pz = parseNumber(e.pz)

						local targetCF = nil
						local hasLocal = is_local_coords_present(lpx, lpy, lpz)

						if origin and hasLocal then
							local sx, sy, sz = lpx or 0, lpy or 0, lpz or 0
							sx = clamp_local(sx, MAX_LOCAL_COORD_MAG); sz = clamp_local(sz, MAX_LOCAL_COORD_MAG)
							targetCF = origin.CFrame * CFrame.new(sx, sy or 0, sz)
							if e.lry then targetCF = targetCF * CFrame.Angles(0, tonumber(e.lry) or 0, 0) end
						elseif plotInst and hasLocal then
							local okp, plotPivot = pcall(function() return plotInst:GetPivot() end)
							if okp and plotPivot then
								local sx, sy, sz = lpx or 0, lpy or 0, lpz or 0
								sx = clamp_local(sx, MAX_LOCAL_COORD_MAG); sz = clamp_local(sz, MAX_LOCAL_COORD_MAG)
								targetCF = plotPivot * CFrame.new(sx, sy or 0, sz)
								if e.lry then targetCF = targetCF * CFrame.Angles(0, tonumber(e.lry) or 0, 0) end
							end
						else
							local ax, ay, az = px or prim2.Position.X, py or prim2.Position.Y, pz or prim2.Position.Z
							targetCF = CFrame.new(ax, ay, az)
							if e.ry then targetCF = targetCF * CFrame.Angles(0, tonumber(e.ry) or 0, 0) end
						end

						local okCF, pos = pcall(function() return targetCF and targetCF.Position end)
						if okCF and pos and isFiniteNumber(pos.X) and isFiniteNumber(pos.Y) and isFiniteNumber(pos.Z) then
							local okAnch, prevA = pcall(function() return prim2 and prim2.Anchored end)
							pcall(function() if prim2 then prim2.Anchored = true end end)
							pcall(function() existing:PivotTo(targetCF) end)
							pcall(function() existing.Parent = parent end)
							task.delay(2.5, function()
								pcall(function()
									if prim2 and prim2.Parent then
										if okAnch then prim2.Anchored = prevA else prim2.Anchored = false end
									end
								end)
							end)
						else
							pcall(function() existing.Parent = parent end)
						end
					else
						pcall(function() if existing then existing.Parent = parent end end)
					end
					pcall(function() if existing then ws_registerModel(player, existing) end end)
					pcall(function()
						if ModelUtilsLocal and type(ModelUtilsLocal.AutoWeld) == "function" and existing then
							pcall(function() ModelUtilsLocal.AutoWeld(existing, existing.PrimaryPart or existing:FindFirstChildWhichIsA("BasePart")) end)
						end
						if SlimeAI_local and type(SlimeAI_local.Start) == "function" and existing then
							pcall(function() SlimeAI_local.Start(existing, nil) end)
						end
					end)
					restored = restored + 1
					if sidKey then restoredIds[sidKey] = true end
					if existing then table.insert(restoredModels, existing) end
				end
			else
				-- No existing: create (but re-check immediately prior to creating)
				local precheck = nil
				if sidKey then precheck = ws_findExistingSlimeById(sidKey) end
				if precheck then
					-- some other concurrent step created it; treat as existing next iteration
					existing = precheck
					pcall(function() ws_registerModel(player, existing) end)
					if sidKey then restoredIds[sidKey] = true end
				else
					-- Prevent concurrent creators for this SlimeId
					local lockKey = sidKey
					local gotLock = (not lockKey) or inflight_acquire(lockKey)
					if not gotLock then
						-- Another thread creating; try find again and skip if found
						local foundNow = nil
						if lockKey then foundNow = ws_findExistingSlimeById(lockKey) end
						if foundNow then
							pcall(function() ws_registerModel(player, foundNow) end)
							if lockKey then restoredIds[lockKey] = true end
							if foundNow then table.insert(restoredModels, foundNow); restored = restored + 1 end
						else
							-- cannot acquire lock but no model found; fall back to waiting briefly then try again
							task.wait(0.05)
							local foundLater = lockKey and ws_findExistingSlimeById(lockKey) or nil
							if foundLater then
								pcall(function() ws_registerModel(player, foundLater) end)
								if lockKey then restoredIds[lockKey] = true end
								if foundLater then table.insert(restoredModels, foundLater); restored = restored + 1 end
							end
						end
					else
						-- We own lock; attempt factory create or fallback placeholder
						local created = nil
						local successCreate = false
						if SlimeFactory or SlimeCoreMod then
							local factoryEntry = buildFactoryEntry(e)
							-- check again before creation to minimize race
							if factoryEntry and factoryEntry.id then
								local found = ws_findExistingSlimeById(factoryEntry.id)
								if found then
									created = found
								else
									created = tryCreateUsingFactoryModules(SlimeFactory, SlimeCoreMod, factoryEntry, player or { UserId = (e.ow or (player and player.UserId) or nil) }, plotInst)
								end
							else
								created = tryCreateUsingFactoryModules(SlimeFactory, SlimeCoreMod, buildFactoryEntry(e), player or { UserId = (e.ow or (player and player.UserId) or nil) }, plotInst)
							end
						end

						if created then
							successCreate = true
							-- mark attributes early and set in-flight flag (tryCreate already sets it)
							pcall(function()
								if e.id and not created:GetAttribute("SlimeId") then created:SetAttribute("SlimeId", e.id) end
								created:SetAttribute("OwnerUserId", (player and player.UserId) or e.ow or created:GetAttribute("OwnerUserId"))
								if persistentId then created:SetAttribute("OwnerPersistentId", persistentId) end
								for attr, short in pairs(WS_ATTR_MAP) do
									local v = (e[short] ~= nil) and e[short] or e[attr]
									if v ~= nil then
										if colorKeys[short] and type(v) == "string" then
											local c = ws_hexToColor3(v)
											if c then created:SetAttribute(attr, c) else created:SetAttribute(attr, v) end
										else
											created:SetAttribute(attr, v)
										end
									end
								end
								if e.lu then pcall(function() created:SetAttribute("LastHungerUpdate", tonumber(e.lu) or parseNumber(e.lu)) end) end
							end)
							pcall(function() created.Parent = parent end)
							pcall(function() ws_registerModel(player or { UserId = (e.ow or (player and player.UserId) or nil) }, created) end)

							created = eliminateDuplicateFor(created, tostring(e.id), parent)

							pcall(function() if SlimeAI_local and type(SlimeAI_local.Start) == "function" then SlimeAI_local.Start(created, nil) end end)
							local lpx = parseNumber(e.lpx); local lpy = parseNumber(e.lpy); local lpz = parseNumber(e.lpz)
							local px = parseNumber(e.px); local py = parseNumber(e.py); local pz = parseNumber(e.pz)
							local targetCF = nil
							local hasLocal = is_local_coords_present(lpx, lpy, lpz)
							if origin and hasLocal then
								local sx, sy, sz = lpx or 0, lpy or 0, lpz or 0
								sx = clamp_local(sx, MAX_LOCAL_COORD_MAG); sz = clamp_local(sz, MAX_LOCAL_COORD_MAG)
								targetCF = origin.CFrame * CFrame.new(sx, sy or 0, sz)
							elseif plotInst and hasLocal then
								local okp, plotPivot = pcall(function() return plotInst:GetPivot() end)
								if okp and plotPivot then
									local sx, sy, sz = lpx or 0, lpy or 0, lpz or 0
									sx = clamp_local(sx, MAX_LOCAL_COORD_MAG); sz = clamp_local(sz, MAX_LOCAL_COORD_MAG)
									targetCF = plotPivot * CFrame.new(sx, sy or 0, sz)
								end
							else
								targetCF = CFrame.new(px or 0, py or 0, pz or 0)
							end
							pcall(function() finalizeRestoreModel(created, e, origin, plotInst, targetCF, SlimeCoreMod, ModelUtilsLocal, SlimeFactory, SlimeAI_local) end)
							pcall(function() clearPreserveFlagsAndRecompute(created) end)

							restored = restored + 1
							if sidKey then restoredIds[sidKey] = true end
							table.insert(restoredModels, created)
						else
							-- fallback simple placeholder model
							local m = Instance.new("Model")
							m.Name = "Slime"
							local prim = Instance.new("Part")
							prim.Name = "Body"
							prim.Size = Vector3.new(2,2,2)
							prim.TopSurface = Enum.SurfaceType.Smooth
							prim.BottomSurface = Enum.SurfaceType.Smooth
							prim.Parent = m
							m.PrimaryPart = prim
							if e.id then pcall(function() m:SetAttribute("SlimeId", e.id) end) end
							pcall(function() m:SetAttribute("OwnerUserId", (player and player.UserId) or e.ow or nil) end)
							if persistentId then pcall(function() m:SetAttribute("OwnerPersistentId", persistentId) end) end
							local merged = buildFactoryEntry(e)
							for attr, short in pairs(WS_ATTR_MAP) do
								local v = (merged[short] ~= nil) and merged[short] or merged[attr]
								if v ~= nil then
									if colorKeys[short] and type(v) == "string" then
										local c = ws_hexToColor3(v)
										if c then v = c end
									end
									pcall(function() m:SetAttribute(attr, v) end)
								end
							end

							if merged.lg then
								pcall(function() m:SetAttribute("LastGrowthUpdate", tonumber(merged.lg)) end)
							end

							if merged.lu then pcall(function() m:SetAttribute("LastHungerUpdate", tonumber(merged.lu) or parseNumber(merged.lu)) end) end

							if merged.lpx then pcall(function() m:SetAttribute("RestoreLpx", merged.lpx) end) end
							if merged.lpy then pcall(function() m:SetAttribute("RestoreLpy", merged.lpy) end) end
							if merged.lpz then pcall(function() m:SetAttribute("RestoreLpz", merged.lpz) end) end
							if merged.px then pcall(function() m:SetAttribute("RestorePX", merged.px) end) end
							if merged.py then pcall(function() m:SetAttribute("RestorePY", merged.py) end) end
							if merged.pz then pcall(function() m:SetAttribute("RestorePZ", merged.pz) end) end
							pcall(function() m:SetAttribute("PreserveOnServer", true) end)
							pcall(function() m:SetAttribute("RestoreStamp", tick()) end)

							-- Mark placeholder as restored before parenting so cleanup/guard logic can detect it
							pcall(function()
								mark_restored_instance(m, (player and player.UserId) or e.ow or nil, nil)
							end)

							pcall(function() m.Parent = parent end)
							pcall(function() prim.Anchored = true end)
							local lpx = merged.lpx; local lpy = merged.lpy; local lpz = merged.lpz
							local px = merged.px; local py = merged.py; local pz = merged.pz
							local targetCF = nil
							local hasLocal = is_local_coords_present(lpx, lpy, lpz)
							if origin and hasLocal then
								local sx, sy, sz = lpx or 0, lpy or 0, lpz or 0
								sx = clamp_local(sx, MAX_LOCAL_COORD_MAG); sz = clamp_local(sz, MAX_LOCAL_COORD_MAG)
								targetCF = origin.CFrame * CFrame.new(sx, sy or 0, sz)
							elseif plotInst and hasLocal then
								local okp, plotPivot = pcall(function() return plotInst:GetPivot() end)
								if okp and plotPivot then
									local sx, sy, sz = lpx or 0, lpy or 0, lpz or 0
									sx = clamp_local(sx, MAX_LOCAL_COORD_MAG); sz = clamp_local(sz, MAX_LOCAL_COORD_MAG)
									targetCF = plotPivot * CFrame.new(sx, sy or 0, sz)
								end
							else
								targetCF = CFrame.new(px or 0, py or 0, pz or 0)
							end
							pcall(function() finalizeRestoreModel(m, merged, origin, plotInst, targetCF, SlimeCoreMod, ModelUtilsLocal, SlimeFactory, SlimeAI_local) end)
							pcall(function() clearPreserveFlagsAndRecompute(m) end)

							restored = restored + 1
							if sidKey then restoredIds[sidKey] = true end
							table.insert(restoredModels, m)
						end
						-- release inflight lock if we acquired it earlier
						if lockKey then inflight_release(lockKey) end


					end
				end
			end
		end
	end
end

-- ws_restore_by_userid (userId-path)
local function ws_restore_by_userid(userId, list)
	if not userId or not list or type(list) ~= "table" or #list == 0 then
		if GrandInventorySerializer and GrandInventorySerializer.CONFIG and GrandInventorySerializer.CONFIG.Debug then
			dprint("ws_restore_by_userid: nothing to restore for userId", tostring(userId or "<nil>"))
		end
		return
	end

	local uid = tonumber(userId) or nil
	local player = nil
	if uid then
		pcall(function() player = Players:GetPlayerByUserId(uid) end)
	end
	if player then
		waitForInventoryReady(player)
	end
	-- First, normalize and dedupe the incoming batch.
	local normalized = {}
	for _, raw in ipairs(list) do
		local ok, n = pcall(function() return ws_normalizeIncomingEntry(raw) end)
		if ok and type(n) == "table" then
			normalized[#normalized+1] = n
		end
	end
	if #normalized == 0 then return end
	normalized = dedupe_by_id(normalized)

	-- Merge into cached profile to prevent multiple restore passes from appending duplicate entries
	pcall(function() merge_incoming_into_profile_worldslimes(uid, normalized) end)

	-- If player is online, call ws_restore with the normalized list (creation will be dedup-aware)
	if player then
		pcall(function() ws_restore(player, normalized) end)
		return
	end

	-- Otherwise augment entries with owner info and run restore (which will register models and avoid duplicates)
	local augmented = {}
	for _, entry in ipairs(normalized) do
		if type(entry) == "table" then
			local ecopy = {}
			for k,v in pairs(entry) do ecopy[k] = v end
			if ecopy.ow == nil and ecopy.OwnerUserId == nil and uid then
				ecopy.ow = uid
			end
			table.insert(augmented, ecopy)
		else
			table.insert(augmented, entry)
		end
	end

	pcall(function() ws_restore(nil, augmented) end)
end

-- Expose utilities into GrandInventorySerializer._internal.WorldSlime
if GrandInventorySerializer then
	GrandInventorySerializer._internal = GrandInventorySerializer._internal or {}
	GrandInventorySerializer._internal.WorldSlime = GrandInventorySerializer._internal.WorldSlime or {}
	GrandInventorySerializer._internal.WorldSlime.dedupe_by_id = dedupe_by_id
	GrandInventorySerializer._internal.WorldSlime.merge_incoming_into_profile_worldslimes = merge_incoming_into_profile_worldslimes
	GrandInventorySerializer._internal.WorldSlime.ws_restore = ws_restore
	GrandInventorySerializer._internal.WorldSlime.ws_restore_by_userid = ws_restore_by_userid
	GrandInventorySerializer._internal.WorldSlime.ws_serialize = ws_serialize
	GrandInventorySerializer._internal.WorldSlime.ws_findExistingSlimeById = ws_findExistingSlimeById
	GrandInventorySerializer._internal.WorldSlime.ws_scan = ws_scan
end

dprint("WorldSlimeService_fixed.lua loaded (dedupe + in-flight locks enabled).")

-- End of WorldSlime section
-- WorldEgg
local WECONFIG = GrandInventorySerializer.CONFIG.WorldEgg
local WE_ATTR_MAP = {
	Rarity="ra", ValueBase="vb", ValuePerGrowth="vg", WeightScalar="ws",
	MovementScalar="mv", MutationRarityBonus="mb"
}

local function we_getPlotOrigin(plot)
	if not plot then return nil end
	local z=plot:FindFirstChild("SlimeZone")
	if z and z:IsA("BasePart") then return z end
	for _,d in ipairs(plot:GetDescendants()) do
		if d:IsA("BasePart") and d.Name=="SlimeZone" then return d end
	end
	return nil
end

local function we_locateEggTemplate(eggId)
	for _,folderName in ipairs(WECONFIG.TemplateFolders) do
		local folder=ReplicatedStorage:FindFirstChild(folderName)
		if folder then
			local specific= eggId and folder:FindFirstChild(eggId)
			if specific and specific:IsA("Model") then return specific end
			local generic=folder:FindFirstChild(WECONFIG.DefaultTemplateName)
			if generic and generic:IsA("Model") then return generic end
		end
	end
	return nil
end

local function we_findPlayerPlot(player)
	if not player then return nil end
	local ok, plot = pcall(function() return we_findPlayerPlot_by_userid(player.UserId) end)
	if ok and plot then return plot end
	local pid = nil
	if player.GetAttribute then pid = tonum(player:GetAttribute("PersistentId")) end
	if not pid then pid = getPersistentIdFor(player) end
	if pid then
		local ok2, plot2 = pcall(function() return we_findPlayerPlot_by_persistentId(pid) end)
		if ok2 and plot2 then return plot2 end
	end
	for _,m in ipairs(Workspace:GetChildren()) do
		if m:IsA("Model") and tostring(m.Name):match("^Player%d+$") then
			local attr = m:GetAttribute("UserId") or m:GetAttribute("OwnerUserId") or m:GetAttribute("AssignedUserId")
			if attr and tostring(attr) == tostring(player.UserId) then return m end
			local patt = m:GetAttribute("AssignedPersistentId") or m:GetAttribute("PersistentId") or m:GetAttribute("OwnerPersistentId")
			if patt and tostring(patt) == tostring(pid) then return m end
		end
	end
	for _,desc in ipairs(Workspace:GetDescendants()) do
		if desc:IsA("Model") then
			local attr = desc:GetAttribute("OwnerUserId") or desc:GetAttribute("UserId") or desc:GetAttribute("AssignedUserId")
			if attr and tostring(attr) == tostring(player.UserId) then
				local candidate = desc
				while candidate.Parent and not candidate.Parent:IsA("Workspace") and candidate.Parent ~= Workspace do
					candidate = candidate.Parent
				end
				if candidate and candidate:IsA("Model") then return candidate end
			end
			local pAttr = desc:GetAttribute("OwnerPersistentId") or desc:GetAttribute("AssignedPersistentId") or desc:GetAttribute("PersistentId")
			if pAttr and pid and tostring(pAttr) == tostring(pid) then
				local candidate = desc
				while candidate.Parent and not candidate.Parent:IsA("Workspace") and candidate.Parent ~= Workspace do
					candidate = candidate.Parent
				end
				if candidate and candidate:IsA("Model") then return candidate end
			end
		end
	end
	return nil
end



local function compute_restored_hatchAt(entry, now_os, now_tick)
	now_os = now_os or os.time()
	now_tick = now_tick or tick()
	local function tonumber_safe(v) if v == nil then return nil end return tonumber(v) end
	local tr = tonumber_safe(entry.tr)
	if tr and tr >= 0 then
		return now_os + tr, ("from tr (remaining)=%s"):format(tostring(tr))
	end
	local ha_raw = tonumber_safe(entry.ha)
	if ha_raw then
		local ha_epoch = normalize_time_to_epoch(ha_raw, now_tick, now_os)
		if ha_epoch then
			if ha_epoch >= now_os - 60 then
				return ha_epoch, ("ha(epoch) used (ha=%s)"):format(tostring(ha_epoch))
			end
			if ha_epoch >= now_os - (3600 * 24) then
				return ha_epoch, ("ha(epoch, stale but used) (ha=%s)"):format(tostring(ha_epoch))
			end
		end
	end
	local ht = tonumber_safe(entry.ht) or tonumber_safe(entry.HatchTime)
	local placedRaw = tonumber_safe(entry.PlacedAt) or tonumber_safe(entry.placedAt) or tonumber_safe(entry.cr) or tonumber_safe(entry.placed_at)
	if ht and ht > 0 and placedRaw then
		local placed_epoch = normalize_time_to_epoch(placedRaw, now_tick, now_os)
		if placed_epoch then
			return placed_epoch + ht, ("derived from placedAt + ht (%s + %s)"):format(tostring(placed_epoch), tostring(ht))
		end
	end
	return now_os + 1, "fallback: now+1"
end


local _WE_RESTORE_IN_FLIGHT = {} -- In-flight lock for EggId

local function we_inflight_acquire(eggId)
	if not eggId then return false end
	if _WE_RESTORE_IN_FLIGHT[eggId] then return false end
	_WE_RESTORE_IN_FLIGHT[eggId] = true
	return true
end
local function we_inflight_release(eggId)
	if not eggId then return end
	_WE_RESTORE_IN_FLIGHT[eggId] = nil
end

local function we_findExistingEggById(eggId)
	if not eggId then return nil end
	for _,inst in ipairs(Workspace:GetDescendants()) do
		if inst:IsA("Model") and inst.Name == "Egg" then
			local eid = inst:GetAttribute("EggId")
			if eid and tostring(eid) == tostring(eggId) then
				return inst
			end
		end
	end
	return nil
end

local function we_enumeratePlotEggs(player)
	local plot = nil
	if player then
		plot = we_findPlayerPlot_by_userid(player.UserId) or we_findPlayerPlot(player)
	end
	local origin = we_getPlotOrigin(plot)
	local now_tick = tick()
	local now_os = os.time()
	local list = {}
	local seen = {}
	local function acceptEgg(desc)
		if not desc or not desc:IsA("Model") then return end
		local placed     = desc:GetAttribute("Placed")
		local manualHatch= desc:GetAttribute("ManualHatch")
		local ownerUserId= desc:GetAttribute("OwnerUserId")
		local ownerPersistent = desc:GetAttribute("OwnerPersistentId")
		local isPreview  = desc:GetAttribute("Preview") or (desc.Name and desc.Name:match("Preview"))
		local ownerMatch = false
		if player and ownerUserId and tostring(ownerUserId) == tostring(player.UserId) then ownerMatch = true end
		if not ownerMatch and plot and desc:IsDescendantOf(plot) then ownerMatch = true end
		if not ownerMatch then
			local pid = getPersistentIdFor(player)
			if pid and ownerPersistent and tonumber(ownerPersistent) == tonumber(pid) then ownerMatch = true end
		end
		if not ownerMatch then return end
		if isPreview and not placed and not manualHatch then return end
		if not placed and not manualHatch then
			local placedAtRaw = tonumber(desc:GetAttribute("PlacedAt"))
			if not placedAtRaw then
				if not WECONFIG.AutoCaptureOnEggPlacement then return end
			else
				local grace = WECONFIG.AcceptMissingManualHatchGraceSeconds or 10
				local placedAge
				if placedAtRaw > 1e8 then
					placedAge = now_os - placedAtRaw
				else
					placedAge = now_tick - placedAtRaw
				end
				if placedAge > grace then return end
			end
		end
		local prim = desc.PrimaryPart or desc:FindFirstChildWhichIsA("BasePart")
		if not prim then return end
		local eggId = desc:GetAttribute("EggId") or ("Egg_"..math.random(1,1e9))
		if seen[eggId] then return end
		seen[eggId] = true
		local rawHatchAt = desc:GetAttribute("HatchAt")
		local ha_epoch = nil
		if rawHatchAt ~= nil then
			ha_epoch = normalize_time_to_epoch(tonumber(rawHatchAt), now_tick, now_os)
		end
		local hatchTime = tonumber(desc:GetAttribute("HatchTime"))
		if not hatchTime then hatchTime = tonumber(desc:GetAttribute("EstimatedHatchTime")) or 0 end
		local remaining, hatchAtRawForPayload
		if ha_epoch then
			remaining = math.max(0, ha_epoch - now_os)
			hatchAtRawForPayload = ha_epoch
		else
			local placedAtRaw = tonumber(desc:GetAttribute("PlacedAt"))
			if placedAtRaw then
				local placed_epoch = normalize_time_to_epoch(placedAtRaw, now_tick, now_os)
				if placed_epoch then
					local hatchAtEpoch = placed_epoch + (hatchTime or 0)
					remaining = math.max(0, hatchAtEpoch - now_os)
					hatchAtRawForPayload = hatchAtEpoch
				else
					remaining = math.max(0, (hatchTime or 0))
					hatchAtRawForPayload = now_os + remaining
				end
			else
				remaining = math.max(0, (hatchTime or 0))
				hatchAtRawForPayload = now_os + remaining
			end
		end
		local cf = prim:GetPivot()
		local e = {
			id = eggId,
			ht = hatchTime,
			ha = hatchAtRawForPayload,
			tr = remaining,
			px = cf.X, py = cf.Y, pz = cf.Z,
			cr = (function()
				local placedRaw = desc:GetAttribute("PlacedAt")
				if placedRaw then
					local maybe = normalize_time_to_epoch(tonumber(placedRaw), now_tick, now_os)
					if maybe then return maybe end
				end
				return now_os - (hatchTime or 0)
			end)(),
		}
		if origin then
			local onCF = origin.CFrame:ToObjectSpace(cf)
			e.lpx, e.lpy, e.lz = onCF.X, onCF.Y, onCF.Z
		end
		for attr,short in pairs(WE_ATTR_MAP) do
			local v = desc:GetAttribute(attr)
			if v ~= nil then e[short] = v end
		end
		list[#list+1] = e
	end
	if plot then
		for _,desc in ipairs(plot:GetDescendants()) do
			if desc:IsA("Model") and desc.Name == "Egg" then acceptEgg(desc) end
		end
	end
	for _,desc in ipairs(Workspace:GetDescendants()) do
		if desc:IsA("Model") and desc.Name == "Egg" then acceptEgg(desc) end
	end
	eggdbg(("Enumerate done uid=%s count=%d"):format(tostring(player and player.UserId or "nil"), #list))
	return list, plot, origin
end

local function we_enumeratePlotEggs_by_userid(userId)
	local plot = we_findPlayerPlot_by_userid(userId) or we_findPlayerPlot_by_persistentId(userId)
	local origin = we_getPlotOrigin(plot)
	local now_tick = tick()
	local now_os = os.time()
	local list = {}
	local seen = {}
	local profileForPid = safe_get_profile(tonumber(userId) or userId)
	local persistentId = nil
	if profileForPid then persistentId = getPersistentIdFor(profileForPid) end
	local function acceptEgg(desc)
		if not desc or not desc:IsA("Model") then return end
		local placed     = desc:GetAttribute("Placed")
		local manualHatch= desc:GetAttribute("ManualHatch")
		local ownerUserId= desc:GetAttribute("OwnerUserId")
		local ownerPersistent = desc:GetAttribute("OwnerPersistentId")
		local isPreview  = desc:GetAttribute("Preview") or (desc.Name and desc.Name:match("Preview"))
		local ownerMatch = tostring(ownerUserId) == tostring(userId)
		if not ownerMatch and plot and desc:IsDescendantOf(plot) then ownerMatch = true end
		if not ownerMatch and ownerPersistent and persistentId and tonumber(ownerPersistent) == tonumber(persistentId) then
			ownerMatch = true
		end
		if not ownerMatch then return end
		if isPreview and not placed and not manualHatch then return end
		if not placed and not manualHatch then
			local placedAtRaw = tonumber(desc:GetAttribute("PlacedAt"))
			if not placedAtRaw then
				if not WECONFIG.AutoCaptureOnEggPlacement then return end
			else
				local grace = WECONFIG.AcceptMissingManualHatchGraceSeconds or 10
				local placedAge
				if placedAtRaw > 1e8 then placedAge = now_os - placedAtRaw else placedAge = now_tick - placedAtRaw end
				if placedAge > grace then return end
			end
		end
		local prim = desc.PrimaryPart or desc:FindFirstChildWhichIsA("BasePart")
		if not prim then return end
		local eggId = desc:GetAttribute("EggId") or ("Egg_"..math.random(1,1e9))
		if seen[eggId] then return end
		seen[eggId] = true
		local rawHatchAt = desc:GetAttribute("HatchAt")
		local ha_epoch = nil
		if rawHatchAt ~= nil then
			ha_epoch = normalize_time_to_epoch(tonumber(rawHatchAt), now_tick, now_os)
		end
		local hatchTime = tonumber(desc:GetAttribute("HatchTime"))
		if not hatchTime then hatchTime = tonumber(desc:GetAttribute("EstimatedHatchTime")) or 0 end
		local remaining, hatchAtRawForPayload
		if ha_epoch then
			remaining = math.max(0, ha_epoch - now_os)
			hatchAtRawForPayload = ha_epoch
		else
			local placedAtRaw = tonumber(desc:GetAttribute("PlacedAt"))
			if placedAtRaw then
				local placed_epoch = normalize_time_to_epoch(placedAtRaw, now_tick, now_os)
				if placed_epoch then
					local hatchAtEpoch = placed_epoch + (hatchTime or 0)
					remaining = math.max(0, hatchAtEpoch - now_os)
					hatchAtRawForPayload = hatchAtEpoch
				else
					remaining = math.max(0, (hatchTime or 0))
					hatchAtRawForPayload = now_os + remaining
				end
			else
				remaining = math.max(0, (hatchTime or 0))
				hatchAtRawForPayload = now_os + remaining
			end
		end
		local cf = prim:GetPivot()
		local e = {
			id = eggId,
			ht = hatchTime,
			ha = hatchAtRawForPayload,
			tr = remaining,
			px = cf.X, py = cf.Y, pz = cf.Z,
			cr = (function()
				local placedRaw = desc:GetAttribute("PlacedAt")
				if placedRaw then
					local maybe = normalize_time_to_epoch(tonumber(placedRaw), now_tick, now_os)
					if maybe then return maybe end
				end
				return now_os - (hatchTime or 0)
			end)(),
		}
		if origin then
			local onCF = origin.CFrame:ToObjectSpace(cf)
			e.lpx, e.lpy, e.lz = onCF.X, onCF.Y, onCF.Z
		end
		for attr,short in pairs(WE_ATTR_MAP) do
			local v = desc:GetAttribute(attr)
			if v ~= nil then e[short] = v end
		end
		list[#list+1] = e
	end
	if plot then
		for _,desc in ipairs(plot:GetDescendants()) do
			if desc:IsA("Model") and desc.Name == "Egg" then acceptEgg(desc) end
		end
	end
	for _,desc in ipairs(Workspace:GetDescendants()) do
		if desc:IsA("Model") and desc.Name == "Egg" then acceptEgg(desc) end
	end
	eggdbg(("Enumerate done uid=%s count=%d"):format(tostring(userId), #list))
	return list, plot, origin
end

local function we_serialize(player, isFinal, profile)
	if not player and profile then
		if profile.worldEggs and #profile.worldEggs > 0 then
			return profile.worldEggs
		end
		if profile.userId or profile.UserId then
			local list = we_enumeratePlotEggs_by_userid(tostring(profile.userId or profile.UserId))
			return list
		end
		return {}
	end
	if not player then return {} end
	local ok, liveList, plot, origin = pcall(function()
		local ll, pl, orp = we_enumeratePlotEggs(player)
		return ll, pl, orp
	end)
	if not ok then
		warn("[WorldEggSer] enumerate error:", liveList)
		liveList={}
	end
	return liveList
end



local function getExistingSlimeIdsForUser(userId, persistentId)
	local ids = {}
	if (not userId) and (not persistentId) then return ids end
	for _, inst in ipairs(Workspace:GetDescendants()) do
		if inst:IsA("Model") and inst.Name == "Slime" then
			local ownerUid = inst:GetAttribute("OwnerUserId")
			local ownerPid = inst:GetAttribute("OwnerPersistentId")
			if (ownerUid and userId and tostring(ownerUid) == tostring(userId)) or (ownerPid and persistentId and tostring(ownerPid) == tostring(persistentId)) then
				local sid = inst:GetAttribute("SlimeId")
				if sid then ids[tostring(sid)] = true end
			end
		end
	end
	return ids
end

local function filterEggsAgainstLiveSlimes(eggList, userId, persistentId)
	if not eggList or #eggList == 0 then return eggList end
	local existing = getExistingSlimeIdsForUser(userId, persistentId)
	if not existing or next(existing) == nil then return eggList end
	local out = {}
	for _, e in ipairs(eggList) do
		local id = e and (e.id or e.EggId or e.Id)
		if not id then
			table.insert(out, e)
		else
			if not existing[tostring(id)] then
				table.insert(out, e)
			else
				dprint(("Dropping worldEgg payload entry id=%s because matching Slime exists for userId=%s/pid=%s"):format(tostring(id), tostring(userId), tostring(persistentId)))
			end
		end
	end
	return out
end

-- Position validation & clamping are handled inside we_restore functions below

-- Data sanitization helpers (to avoid DataStore errors)
-- sanitizeForDataStore + sanitizeInventoryOnProfile (data-safety before saving)
local function color3ToHex(c)
	if typeof and typeof(c) == "Color3" then
		return string.format("#%02X%02X%02X", math.floor(c.R*255+0.5), math.floor(c.G*255+0.5), math.floor(c.B*255+0.5))
	end
	-- fallback
	if type(c) == "table" and c.R and c.G and c.B then
		return string.format("#%02X%02X%02X", math.floor(c.R*255+0.5), math.floor(c.G*255+0.5), math.floor(c.B*255+0.5))
	end
	return tostring(c)
end

local function vector3ToTable(v)
	if typeof and typeof(v) == "Vector3" then
		return { x = v.X, y = v.Y, z = v.Z }
	end
	if type(v) == "table" and v.x and v.y and v.z then
		return { x = tonumber(v.x) or 0, y = tonumber(v.y) or 0, z = tonumber(v.z) or 0 }
	end
	return nil
end

local function cframeToTable(cf)
	-- keep only position for safety
	if typeof and typeof(cf) == "CFrame" then
		local p = cf.Position
		return { x = p.X, y = p.Y, z = p.Z }
	end
	return nil
end

local function sanitizeForDataStore(value, depth)
	depth = depth or 0
	if depth > 10 then return nil end
	local t = type(value)
	if t == "number" then
		if not isFiniteNumber(value) then return nil end
		return value
	end
	if t == "boolean" then return value end
	if t == "string" then
		-- ensure it's a string; can't guarantee UTF-8 validity, but convert other types to tostring
		return tostring(value)
	end
	if t == "table" then
		local out = {}
		local numericIndex = 0
		for k, v in pairs(value) do
			local sk = tostring(k)
			local sv = sanitizeForDataStore(v, depth + 1)
			if sv ~= nil then
				-- If table is used as array (continuous integer keys starting at 1), keep numeric indices numeric
				if type(k) == "number" and k == math.floor(k) and k >= 1 then
					-- preserve as array element
					numericIndex = numericIndex + 1
					out[numericIndex] = sv
				else
					out[sk] = sv
				end
			end
		end
		-- if empty, return nil to avoid storing empty placeholders
		if next(out) == nil then return nil end
		return out
	end

	-- Roblox / userdata specific conversions
	if typeof then
		local ty = typeof(value)
		if ty == "Color3" then return color3ToHex(value) end
		if ty == "Vector3" then return vector3ToTable(value) end
		if ty == "CFrame" then return cframeToTable(value) end
		if ty == "Instance" then
			-- replace Instance with a descriptive string path if possible
			local ok, s = pcall(function() return value:GetFullName() end)
			if ok and s then return "[Instance]"..s end
			return "[Instance]"..tostring(value)
		end
	end

	-- fallback: stringify other userdata/types if safe
	local ok, s = pcall(function() return tostring(value) end)
	if ok then return s end
	return nil
end

local function sanitizeInventoryOnProfile(profile)
	if not profile or type(profile) ~= "table" or type(profile.inventory) ~= "table" then return end
	local inv = profile.inventory
	local fields = { "eggTools", "foodTools", "worldEggs", "worldSlimes", "capturedSlimes" }
	for _, fname in ipairs(fields) do
		if inv[fname] and type(inv[fname]) == "table" then
			local cleaned = {}
			for i,entry in ipairs(inv[fname]) do
				local sv = sanitizeForDataStore(entry, 0)
				if sv ~= nil then
					cleaned[#cleaned + 1] = sv
				else
					-- entry was not suitable for store; log if debug enabled
					dprint(("sanitizeInventoryOnProfile: dropped %s entry %d for profile %s"):format(fname, i, tostring(profile.userId or profile.UserId or profile.id or "unknown")))
				end
				if #cleaned >= 2000 then break end
			end
			-- assign cleaned only if non-empty, else leave as empty table to avoid losing structure
			inv[fname] = cleaned
		end
	end
end

-- We'll call sanitizeInventoryOnProfile before SaveNow in PreExitSync and after merges in Restore

-- Replace the existing we_restore(...) and we_restore_by_userid(...) functions in GrandInventorySerializer.lua
-- with the versions below. These are complete function bodies � copy & paste them to replace the originals.
-- Key fix: no top-level "if ... player ... restoredModels" checks remain. All deferred logic runs inside task.spawn closures
-- that capture locals inside the closure so static analysis (UnknownGlobal) won't flag 'player', 'restoredModels', etc.


local function collect_world_eggs()
	local out = {}
	for _, inst in ipairs(workspace:GetDescendants()) do
		if inst:IsA("Model") and inst.Name == "Egg" then
			local eggId = inst:GetAttribute("EggId") or inst:GetAttribute("eggId") or inst:GetAttribute("id")
			local owner = inst:GetAttribute("OwnerUserId") or inst:GetAttribute("owner") -- accept variants
			local prim = inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart")
			local pos = nil
			if prim then
				local ok, pivot = pcall(function() return prim:GetPivot() end)
				if ok and pivot then pos = { x = pivot.X, y = pivot.Y, z = pivot.Z } end
			end

			local entry = {
				EggId = eggId,
				eggId = eggId,
				id = eggId,
				OwnerUserId = owner,
				Position = pos,
				ParentName = inst.Parent and inst.Parent.Name or nil,
				placedAt = inst:GetAttribute("placedAt") or inst:GetAttribute("PlacedAt") or inst:GetAttribute("placed_at"),
				hatchAt = inst:GetAttribute("hatchAt") or inst:GetAttribute("HatchAt") or inst:GetAttribute("ha"),
				rawAttrs = {}, -- preserve everything for debugging if needed
			}

			-- copy any other interesting attributes in compact form so restore has many fallbacks
			local attrs = {"cr","px","py","pz","ht","lpx","lpy"}
			for _,k in ipairs(attrs) do
				local v = inst:GetAttribute(k)
				if v ~= nil then entry.rawAttrs[k] = v end
			end

			out[#out+1] = entry
		end
	end
	return out
end




-- Patched we_restore (world eggs) with safer deferred reparent/reposition logic.
-- we_restore (world eggs) - patched deferred reposition + robust create/update
local function we_restore(player, list)
	if not list or type(list) ~= "table" or #list == 0 then
		if GrandInventorySerializer and GrandInventorySerializer.CONFIG and GrandInventorySerializer.CONFIG.Debug then
			dprint("we_restore: nothing to restore for player", tostring(player and player.UserId or "<nil>"))
		end
		return
	end
	if player then
		waitForInventoryReady(player)
	end

	local plot = we_findPlayerPlot_by_userid(player.UserId)
	local origin = we_getPlotOrigin(plot)
	local parent = plot or Workspace
	local restored = 0
	local restoredModels = {}
	local restoredIds = {}

	for _, e in ipairs(list) do
		if restored >= WECONFIG.MaxWorldEggsPerPlayer then break end
		local eggId = e.id
		if eggId and restoredIds[eggId] then
			dprint(("Skipping duplicate egg restore id=%s"):format(tostring(eggId)))
		else
			local gotLock = eggId and we_inflight_acquire(eggId) or true
			if not gotLock then
				local foundNow = eggId and we_findExistingEggById(eggId) or nil
				if foundNow then
					dprint(("we_restore: found existing Egg for id=%s during inflight lock; updating"):format(tostring(eggId)))
					
				end
			end

			local existing = eggId and we_findExistingEggById(eggId) or nil
			if existing then
				existing:SetAttribute("Placed", true)
				existing:SetAttribute("ManualHatch", true)
				if e.cr then existing:SetAttribute("PlacedAt", e.cr) end
				local nuid = tonumber(player.UserId) or player.UserId
				existing:SetAttribute("OwnerUserId", nuid)
				existing:SetAttribute("HatchTime", e.ht)
				for attr,short in pairs(WE_ATTR_MAP) do
					local v = e[short]
					if v ~= nil then existing:SetAttribute(attr, v) end
				end
				local computedHatchAt, hatchReason = compute_restored_hatchAt(e, os.time(), tick())
				if WECONFIG.RestoreEggsReady then
					computedHatchAt = os.time()
					hatchReason = "RestoreEggsReady"
				end
				existing:SetAttribute("HatchAt", computedHatchAt)
				if GrandInventorySerializer.CONFIG.Debug then pcall(function() existing:SetAttribute("HatchRestoreReason", tostring(hatchReason)) end) end
				local prim = existing.PrimaryPart or existing:FindFirstChildWhichIsA("BasePart")
				if not prim then
					local p = Instance.new("Part")
					p.Name = "Handle"
					p.Size = Vector3.new(2,2,2)
					p.TopSurface = Enum.SurfaceType.Smooth
					p.BottomSurface = Enum.SurfaceType.Smooth
					p.Parent = existing
					existing.PrimaryPart = p
					prim = p
				end
				if e.lpx then existing:SetAttribute("RestoreLpx", e.lpx) end
				if e.lpy then existing:SetAttribute("RestoreLpy", e.lpy) end
				if e.lz or e.lpz then existing:SetAttribute("RestoreLpz", (e.lz or e.lpz)) end
				if e.px then existing:SetAttribute("RestorePX", e.px) end
				if e.py then existing:SetAttribute("RestorePY", e.py) end
				if e.pz then existing:SetAttribute("RestorePZ", e.pz) end

				restored = restored + 1
				if eggId then restoredIds[eggId] = true end
				table.insert(restoredModels, existing)
				dprint(("Updated existing egg id=%s for userId=%s"):format(tostring(eggId), tostring(player.UserId)))
			else
				local template = we_locateEggTemplate(e.id) or we_locateEggTemplate(WECONFIG.DefaultTemplateName)
				local m
				if template then
					local ok, clone = pcall(function() return template:Clone() end)
					if ok and clone then m = clone end
				end
				if not m then
					m = Instance.new("Model")
					local part = Instance.new("Part")
					part.Shape = Enum.PartType.Ball
					part.Size = Vector3.new(2,2,2)
					part.Name = "Handle"
					part.TopSurface = Enum.SurfaceType.Smooth
					part.BottomSurface = Enum.SurfaceType.Smooth
					part.Parent = m
					m.PrimaryPart = part
				end
				m.Name = "Egg"
				if e.id then m:SetAttribute("EggId", e.id) end
				m:SetAttribute("Placed", true)
				m:SetAttribute("ManualHatch", true)
				if e.cr then m:SetAttribute("PlacedAt", e.cr) end
				local nuid = tonumber(player.UserId) or player.UserId
				m:SetAttribute("OwnerUserId", nuid)
				m:SetAttribute("HatchTime", e.ht)
				for attr,short in pairs(WE_ATTR_MAP) do
					local v = e[short]
					if v ~= nil then m:SetAttribute(attr, v) end
				end
				local computedHatchAt, hatchReason = compute_restored_hatchAt(e, os.time(), tick())
				if WECONFIG.RestoreEggsReady then
					computedHatchAt = os.time()
					hatchReason = "RestoreEggsReady"
				end
				m:SetAttribute("HatchAt", computedHatchAt)
				if GrandInventorySerializer.CONFIG.Debug then pcall(function() m:SetAttribute("HatchRestoreReason", tostring(hatchReason)) end) end
				if e.lpx or e.lpy or e.lz then
					if e.lpx then m:SetAttribute("RestoreLpx", e.lpx) end
					if e.lpy then m:SetAttribute("RestoreLpy", e.lpy) end
					if e.lz or e.lpz then m:SetAttribute("RestoreLpz", (e.lz or e.lpz)) end
				end
				local prim = m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart")
				if not prim then
					local part = Instance.new("Part")
					part.Name = "Handle"
					part.Size = Vector3.new(2,2,2)
					part.TopSurface = Enum.SurfaceType.Smooth
					part.BottomSurface = Enum.SurfaceType.Smooth
					part.Parent = m
					m.PrimaryPart = part
					prim = part
				end
				m:SetAttribute("PreserveOnServer", true)
				m:SetAttribute("RestoreStamp", tick())
				m.Parent = parent

				restored = restored + 1
				table.insert(restoredModels, m)
				if eggId then restoredIds[eggId] = true end
				dprint(("Created egg id=%s for userId=%s parent=%s"):format(tostring(e.id), tostring(player.UserId), tostring(parent and parent:GetFullName())))
			end
			if eggId then we_inflight_release(eggId) end
		end
	end

	-- === Deferred reparent/reposition closure (do not omit) ===
	task.spawn(function()
		local _player = player
		local _restored = restoredModels
		local _persistent = player and getPersistentIdFor(player) or nil
		local _profile = (function() local ok, p = pcall(function() return safe_get_profile(player) end) if ok then return p end return nil end)()

		if not (_restored and #_restored > 0) then return end

		local function resolvePlot(uid, pid, nameKey)
			if type(findPlotForUserWithFallback) == "function" then
				local ok, res = pcall(function() return findPlotForUserWithFallback(uid, pid, nameKey) end)
				if ok and res then return res end
			end
			if uid then
				local ok1, p1 = pcall(function() return we_findPlayerPlot_by_userid(uid) end)
				if ok1 and p1 then return p1 end
			end
			if pid then
				local ok2, p2 = pcall(function() return we_findPlayerPlot_by_persistentId(pid) end)
				if ok2 and p2 then return p2 end
			end
			for _, m in ipairs(Workspace:GetChildren()) do
				if m:IsA("Model") and tostring(m.Name):match("^Player%d+$") then
					local uidAttr = tonumber(m:GetAttribute("UserId")) or tonumber(m:GetAttribute("OwnerUserId")) or tonumber(m:GetAttribute("AssignedUserId"))
					if uidAttr and uid and tonumber(uidAttr) == tonumber(uid) then
						return m
					end
					local pidAttr = tonumber(m:GetAttribute("AssignedPersistentId")) or tonumber(m:GetAttribute("PersistentId")) or tonumber(m:GetAttribute("OwnerPersistentId"))
					if pidAttr and pid and tonumber(pidAttr) == tonumber(pid) then
						return m
					end
					if nameKey and tostring(m.Name) == tostring(nameKey) then
						return m
					end
				end
			end
			return nil
		end

		local attempts = 40
		local waitInterval = 0.25
		local uid = _player and _player.UserId or nil
		local pid = _persistent
		local nameKey = (_player and _player.Name) or (_profile and (_profile.playerName or _profile.name))

		for i = 1, attempts do
			task.wait(waitInterval)
			local foundPlot = resolvePlot(uid, pid, nameKey)
			if foundPlot then
				local originNow = we_getPlotOrigin(foundPlot)
				for _, mm in ipairs(_restored) do
					if mm and mm.Parent then
						local lpx = mm:GetAttribute("RestoreLpx")
						local lpy = mm:GetAttribute("RestoreLpy")
						local lpz = mm:GetAttribute("RestoreLpz")
						if originNow and lpx and lpy and lpz then
							local ok, newCF = pcall(function()
								return originNow.CFrame * CFrame.new(tonumber(lpx) or 0, tonumber(lpy) or 0, tonumber(lpz) or 0)
							end)
							if ok and newCF then
								local prim = mm.PrimaryPart or mm:FindFirstChildWhichIsA("BasePart")
								local okAnch, prevA = pcall(function() return prim and prim.Anchored end)
								pcall(function() if prim then prim.Anchored = true end end)
								pcall(function() mm:PivotTo(newCF) end)
								pcall(function() mm.Parent = foundPlot end)
								task.delay(3.5, function()
									pcall(function()
										if prim and prim.Parent then
											if okAnch then prim.Anchored = prevA else prim.Anchored = false end
										end
										pcall(function()
											mm:SetAttribute("RestoreStamp", nil)
											mm:SetAttribute("PreserveOnServer", nil)
										end)
									end)
								end)
							else
								pcall(function() mm.Parent = foundPlot end)
								task.delay(3.5, function()
									pcall(function()
										mm:SetAttribute("RestoreStamp", nil)
										mm:SetAttribute("PreserveOnServer", nil)
										local prim = mm.PrimaryPart or mm:FindFirstChildWhichIsA("BasePart")
										if prim and prim.Parent then prim.Anchored = false end
									end)
								end)
							end
						else
							pcall(function() mm.Parent = foundPlot end)
							task.delay(3.5, function()
								pcall(function()
									mm:SetAttribute("RestoreStamp", nil)
									mm:SetAttribute("PreserveOnServer", nil)
									local prim = mm.PrimaryPart or mm:FindFirstChildWhichIsA("BasePart")
									if prim and prim.Parent then prim.Anchored = false end
								end)
							end)
						end
					end
				end
				if GrandInventorySerializer and GrandInventorySerializer.CONFIG and GrandInventorySerializer.CONFIG.Debug then
					dprint(("we_restore: deferred reposition succeeded after %d attempts for userId=%s"):format(i, tostring(uid)))
				end
				return
			end
		end

		for _, mm in ipairs(_restored) do
			task.delay(3.5, function()
				pcall(function()
					if mm and mm.Parent then
						mm:SetAttribute("RestoreStamp", nil)
						mm:SetAttribute("PreserveOnServer", nil)
						local prim = mm.PrimaryPart or mm:FindFirstChildWhichIsA("BasePart")
						if prim and prim.Parent then prim.Anchored = false end
					end
				end)
			end)
		end
		if GrandInventorySerializer and GrandInventorySerializer.CONFIG and GrandInventorySerializer.CONFIG.Debug then
			dprint(("we_restore: deferred reposition timed out after %d attempts for userId=%s; left in workspace"):format(attempts, tostring(_player and _player.UserId)))
		end
	end)
end

-- Patched we_restore_by_userid (userId-path) with safer deferred reparent/reposition logic.
-- we_restore_by_userid (userId-path for world eggs)
-- we_restore_by_userid (userId-path for world eggs)
local function we_restore_by_userid(userId, list)
	if not userId or not list or type(list) ~= "table" or #list == 0 then
		if GrandInventorySerializer and GrandInventorySerializer.CONFIG and GrandInventorySerializer.CONFIG.Debug then
			dprint("we_restore_by_userid: nothing to restore for userId", tostring(userId or "<nil>"))
		end
		return
	end

	local now = os.time()
	local now_tick = tick()
	local player = nil
	if tonumber(userId) then
		pcall(function() player = Players:GetPlayerByUserId(tonumber(userId)) end)
	end

	if player then
		waitForInventoryReady(player)
	end

	local plot = we_findPlayerPlot_by_userid(userId) or we_findPlayerPlot_by_persistentId(userId)
	local origin = we_getPlotOrigin(plot)
	local parent = plot or Workspace
	local restored = 0
	local restoredModels = {}
	local restoredIds = {}
	local prof = safe_get_profile(tonumber(userId) or userId)
	local persistentId = nil
	if prof then persistentId = getPersistentIdFor(prof) end

	for _, e in ipairs(list) do
		if restored >= WECONFIG.MaxWorldEggsPerPlayer then break end
		local eggId = e.id
		if eggId and restoredIds[eggId] then
			dprint(("Skipping duplicate egg restore id=%s (by userId)"):format(tostring(eggId)))
		else
			local gotLock = eggId and we_inflight_acquire(eggId) or true
			if not gotLock then
				local foundNow = eggId and we_findExistingEggById(eggId) or nil
				if foundNow then
					dprint(("we_restore_by_userid: found existing Egg for id=%s during inflight lock; updating"):format(tostring(eggId)))
					
				end
			end

			local existing = eggId and we_findExistingEggById(eggId) or nil
			if existing then
				existing:SetAttribute("Placed", true)
				existing:SetAttribute("ManualHatch", true)
				if e.cr then existing:SetAttribute("PlacedAt", e.cr) end
				local nuid = tonumber(userId) or userId
				existing:SetAttribute("OwnerUserId", nuid)
				if persistentId then existing:SetAttribute("OwnerPersistentId", persistentId) end
				existing:SetAttribute("HatchTime", e.ht)
				for attr,short in pairs(WE_ATTR_MAP) do
					local v = e[short]
					if v ~= nil then existing:SetAttribute(attr, v) end
				end
				local computedHatchAt, hatchReason = compute_restored_hatchAt(e, now, now_tick)
				if WECONFIG.RestoreEggsReady then
					computedHatchAt = now
					hatchReason = "RestoreEggsReady"
				end
				existing:SetAttribute("HatchAt", computedHatchAt)
				if GrandInventorySerializer.CONFIG.Debug then pcall(function() existing:SetAttribute("HatchRestoreReason", tostring(hatchReason)) end) end
				local prim = existing.PrimaryPart or existing:FindFirstChildWhichIsA("BasePart")
				if not prim then
					local p = Instance.new("Part")
					p.Name = "Handle"
					p.Size = Vector3.new(2,2,2)
					p.TopSurface = Enum.SurfaceType.Smooth
					p.BottomSurface = Enum.SurfaceType.Smooth
					p.Parent = existing
					existing.PrimaryPart = p
					prim = p
				end
				if e.lpx then existing:SetAttribute("RestoreLpx", e.lpx) end
				if e.lpy then existing:SetAttribute("RestoreLpy", e.lpy) end
				if e.lz or e.lpz then existing:SetAttribute("RestoreLpz", (e.lz or e.lpz)) end
				if e.px then existing:SetAttribute("RestorePX", e.px) end
				if e.py then existing:SetAttribute("RestorePY", e.py) end
				if e.pz then existing:SetAttribute("RestorePZ", e.pz) end

				restored = restored + 1
				if eggId then restoredIds[eggId] = true end
				table.insert(restoredModels, existing)
				dprint(("Updated existing egg id=%s for userId=%s"):format(tostring(eggId), tostring(userId)))
			else
				local template = we_locateEggTemplate(e.id) or we_locateEggTemplate(WECONFIG.DefaultTemplateName)
				local m
				if template then
					local ok, clone = pcall(function() return template:Clone() end)
					if ok and clone then m = clone end
				end
				if not m then
					m = Instance.new("Model")
					local part = Instance.new("Part")
					part.Shape = Enum.PartType.Ball
					part.Size = Vector3.new(2,2,2)
					part.Name = "Handle"
					part.TopSurface = Enum.SurfaceType.Smooth
					part.BottomSurface = Enum.SurfaceType.Smooth
					part.Parent = m
					m.PrimaryPart = part
				end
				m.Name = "Egg"
				if e.id then m:SetAttribute("EggId", e.id) end
				m:SetAttribute("Placed", true)
				m:SetAttribute("ManualHatch", true)
				if e.cr then m:SetAttribute("PlacedAt", e.cr) end
				local nuid = tonumber(userId) or userId
				m:SetAttribute("OwnerUserId", nuid)
				if persistentId then m:SetAttribute("OwnerPersistentId", persistentId) end
				m:SetAttribute("HatchTime", e.ht)
				for attr,short in pairs(WE_ATTR_MAP) do
					local v = e[short]
					if v ~= nil then m:SetAttribute(attr, v) end
				end
				local computedHatchAt, hatchReason = compute_restored_hatchAt(e, now, now_tick)
				if WECONFIG.RestoreEggsReady then
					computedHatchAt = now
					hatchReason = "RestoreEggsReady"
				end
				m:SetAttribute("HatchAt", computedHatchAt)
				if GrandInventorySerializer.CONFIG.Debug then pcall(function() m:SetAttribute("HatchRestoreReason", tostring(hatchReason)) end) end
				if e.lpx or e.lpy or e.lz then
					if e.lpx then m:SetAttribute("RestoreLpx", e.lpx) end
					if e.lpy then m:SetAttribute("RestoreLpy", e.lpy) end
					if e.lz or e.lpz then m:SetAttribute("RestoreLpz", (e.lz or e.lpz)) end
				end
				local prim = m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart")
				if not prim then
					local part = Instance.new("Part")
					part.Name = "Handle"
					part.Size = Vector3.new(2,2,2)
					part.TopSurface = Enum.SurfaceType.Smooth
					part.BottomSurface = Enum.SurfaceType.Smooth
					part.Parent = m
					m.PrimaryPart = part
					prim = part
				end
				m:SetAttribute("PreserveOnServer", true)
				m:SetAttribute("RestoreStamp", tick())
				m.Parent = parent

				restored = restored + 1
				table.insert(restoredModels, m)
				if eggId then restoredIds[eggId] = true end
				dprint(("Created egg id=%s for userId=%s parent=%s"):format(tostring(e.id), tostring(userId), tostring(parent and parent:GetFullName())))
			end
			if eggId then we_inflight_release(eggId) end
		end
	end

	-- === Deferred reposition/reparent closure (do not omit) ===
	task.spawn(function()
		local _uid = userId
		local _restored = restoredModels
		local _prof = prof
		local _pid = persistentId

		if not (_restored and #_restored > 0) then return end

		local function resolvePlotForUid(uid)
			if type(findPlotForUserWithFallback) == "function" then
				local ok, res = pcall(function() return findPlotForUserWithFallback(uid, nil, nil) end)
				if ok and res then return res end
			end
			local ok1, p1 = pcall(function() return we_findPlayerPlot_by_userid(uid) end)
			if ok1 and p1 then return p1 end
			local pidLocal = nil
			if _prof then pidLocal = getPersistentIdFor(_prof) end
			if pidLocal then
				local ok2, p2 = pcall(function() return we_findPlayerPlot_by_persistentId(pidLocal) end)
				if ok2 and p2 then return p2 end
			end
			for _, m in ipairs(Workspace:GetChildren()) do
				if m:IsA("Model") and tostring(m.Name):match("^Player%d+$") then
					local a = m:GetAttribute("UserId") or m:GetAttribute("OwnerUserId") or m:GetAttribute("AssignedUserId")
					if a and tostring(a) == tostring(uid) then return m end
				end
			end
			return nil
		end

		local attempts = 40
		local waitInterval = 0.25
		for i = 1, attempts do
			task.wait(waitInterval)
			local plotNow = resolvePlotForUid(_uid)
			if plotNow then
				local originNow = we_getPlotOrigin(plotNow)
				for _, mm in ipairs(_restored) do
					if mm and mm.Parent then
						local lpx = mm:GetAttribute("RestoreLpx")
						local lpy = mm:GetAttribute("RestoreLpy")
						local lpz = mm:GetAttribute("RestoreLpz")
						if originNow and lpx and lpy and lpz then
							local ok, newCF = pcall(function()
								return originNow.CFrame * CFrame.new(tonumber(lpx) or 0, tonumber(lpy) or 0, tonumber(lpz) or 0)
							end)
							if ok and newCF then
								local prim = mm.PrimaryPart or mm:FindFirstChildWhichIsA("BasePart")
								local okAnch, prevA = pcall(function() return prim and prim.Anchored end)
								pcall(function() if prim then prim.Anchored = true end end)
								pcall(function() mm:PivotTo(newCF) end)
								pcall(function() mm.Parent = plotNow end)
								task.delay(3.5, function()
									pcall(function()
										if prim and prim.Parent then
											if okAnch then prim.Anchored = prevA else prim.Anchored = false end
										end
										pcall(function()
											mm:SetAttribute("RestoreStamp", nil)
											mm:SetAttribute("PreserveOnServer", nil)
										end)
									end)
								end)
							else
								pcall(function() mm.Parent = plotNow end)
								task.delay(3.5, function()
									pcall(function()
										mm:SetAttribute("RestoreStamp", nil)
										mm:SetAttribute("PreserveOnServer", nil)
										local prim = mm.PrimaryPart or mm:FindFirstChildWhichIsA("BasePart")
										if prim and prim.Parent then prim.Anchored = false end
									end)
								end)
							end
						else
							pcall(function() mm.Parent = plotNow end)
							task.delay(3.5, function()
								pcall(function()
									mm:SetAttribute("RestoreStamp", nil)
									mm:SetAttribute("PreserveOnServer", nil)
									local prim = mm.PrimaryPart or mm:FindFirstChildWhichIsA("BasePart")
									if prim and prim.Parent then prim.Anchored = false end
								end)
							end)
						end
					end
				end
				return
			end
		end

		for _, mm in ipairs(_restored) do
			task.delay(3.5, function()
				pcall(function()
					if mm and mm.Parent then
						mm:SetAttribute("RestoreStamp", nil)
						mm:SetAttribute("PreserveOnServer", nil)
						local prim = mm.PrimaryPart or mm:FindFirstChildWhichIsA("BasePart")
						if prim and prim.Parent then prim.Anchored = false end
					end
				end)
			end)
		end
	end)
end

-- THIS IS THE SPLIT











-- FoodTool / EggTool code unchanged in general but left here for completeness (omitted commentary)
-- FoodTool section (updated, paste this block into GrandInventorySerializer.lua to replace the existing FoodTool code)
-- Improvements:
--  - Defensive config defaults (avoid nil FTCONFIG)
--  - Safer HttpService GUID generation (pcall)
--  - Guarded ServerStorage scanning (pcall)
--  - Avoid mutating nil globals and protect attribute sets with pcall
--  - Expose internal helpers on GrandInventorySerializer._internal.FoodTool for external use / testing

-- FoodTool section (replacement) for GrandInventorySerializer
-- Paste this whole block into GrandInventorySerializer.lua replacing the existing FoodTool section.
-- Fixes: retry template resolution after fallback restore so restored tools pick up template visuals
-- and no longer appear as the fallback yellow sphere.

local FTCONFIG = (GrandInventorySerializer and GrandInventorySerializer.CONFIG and GrandInventorySerializer.CONFIG.FoodTool) or {}
local FT_ATTRS = {
	FoodId="fid", RestoreFraction="rf", FeedBufferBonus="fb",
	Consumable="cs", Charges="ch", FeedCooldownOverride="cd",
	OwnerUserId="ow", ToolUniqueId="uid"
}
local ft_restoreBatchCounter = 0

local function ft_dprint(...) if FTCONFIG and FTCONFIG.Debug then print("[FoodSer]", ...) end end

local function safeGenerateGUID()
	if HttpService and type(HttpService.GenerateGUID) == "function" then
		local ok, res = pcall(function() return HttpService:GenerateGUID(false) end)
		if ok and res then return res end
	end
	return tostring(os.time()) .. "-" .. tostring(math.random(1, 1e9))
end

local function safeSetAttribute(obj, name, value)
	if not obj or type(obj.SetAttribute) ~= "function" then return end
	pcall(function() obj:SetAttribute(name, value) end)
end

local function safeGetAttribute(obj, name)
	if not obj or type(obj.GetAttribute) ~= "function" then return nil end
	local ok, v = pcall(function() return obj:GetAttribute(name) end)
	if ok then return v end
	return nil
end

local function ft_qualifies(tool)
	if not tool then return false end
	if type(tool.IsA) ~= "function" then return false end
	if not tool:IsA("Tool") then return false end
	local ok, v1 = pcall(function() return tool:GetAttribute("FoodItem") end)
	local ok2, v2 = pcall(function() return tool:GetAttribute("FoodId") end)
	if (ok and v1 ~= nil) or (ok2 and v2 ~= nil) then
		return true
	end
	return false
end

local function ft_enumerate(container, out)
	if not container or type(container.GetChildren) ~= "function" or type(out) ~= "table" then return end
	for _, c in ipairs(container:GetChildren()) do
		if ft_qualifies(c) then out[#out+1] = c end
	end
end

local function ft_collectFood(player)
	if not player or type(player.FindFirstChildOfClass) ~= "function" then
		ft_dprint("[ft_collectFood] no player instance available; returning empty list")
		return {}
	end
	local out = {}
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then ft_enumerate(backpack, out) end
	if player.Character then ft_enumerate(player.Character, out) end

	if typeof and ServerStorage then
		local ok, desc = pcall(function() return ServerStorage:GetDescendants() end)
		if ok and type(desc) == "table" then
			for _, s in ipairs(desc) do
				if s and type(s.IsA) == "function" and s:IsA("Tool") then
					local owner = safeGetAttribute(s, "OwnerUserId")
					if owner and tostring(owner) == tostring(player.UserId) and ft_qualifies(s) then
						table.insert(out, s)
					end
				end
			end
		end
	end

	for _, tool in ipairs(out) do
		safeSetAttribute(tool, "OwnerUserId", player.UserId)
	end

	return out
end

-- Respect configured TemplateFolders and common fallbacks (ToolTemplates, FoodTemplates, Assets, InventoryTemplates, ServerStorage.ToolTemplates)
local function ft_findTemplate(fid)
	local tryFolders = {}
	-- Prefer explicit configured folders from FTCONFIG.TemplateFolders if provided
	if FTCONFIG and type(FTCONFIG.TemplateFolders) == "table" then
		for _, name in ipairs(FTCONFIG.TemplateFolders) do
			if name and type(name) == "string" then
				table.insert(tryFolders, function() return ReplicatedStorage and ReplicatedStorage:FindFirstChild(name) end)
			end
		end
	end
	-- Add common folders (ToolTemplates first because FoodService uses it)
	table.insert(tryFolders, function() return ReplicatedStorage and ReplicatedStorage:FindFirstChild("ToolTemplates") end)
	table.insert(tryFolders, function() return ReplicatedStorage and ReplicatedStorage:FindFirstChild("FoodTemplates") end)
	table.insert(tryFolders, function() return ReplicatedStorage and ReplicatedStorage:FindFirstChild("Assets") end)
	table.insert(tryFolders, function() return ReplicatedStorage and ReplicatedStorage:FindFirstChild("InventoryTemplates") end)
	table.insert(tryFolders, function() return ServerStorage and ServerStorage:FindFirstChild("ToolTemplates") end)

	for _, getter in ipairs(tryFolders) do
		local folder = nil
		pcall(function() folder = getter() end)
		if folder and type(folder.FindFirstChild) == "function" then
			if fid then
				local spec = nil
				pcall(function() spec = folder:FindFirstChild(fid) end)
				if spec and type(spec.IsA) == "function" and (spec:IsA("Tool") or spec:IsA("Model") or spec:IsA("Folder")) then
					return spec, folder
				end
			end
			local generic = nil
			pcall(function() generic = folder:FindFirstChild("Food") end)
			if generic and type(generic.IsA) == "function" and generic:IsA("Tool") then
				return generic, folder
			end
		end
	end

	-- last-resort explicit names
	local fallbackNames = { "SlimeFoodBasic", "FoodHandle", "Food" }
	for _, name in ipairs(fallbackNames) do
		local ok, found = pcall(function()
			local a = ReplicatedStorage and ReplicatedStorage:FindFirstChild("Assets")
			if a and a:FindFirstChild(name) then return a:FindFirstChild(name) end
			if ReplicatedStorage and ReplicatedStorage:FindFirstChild(name) then return ReplicatedStorage:FindFirstChild(name) end
			if ServerStorage and ServerStorage:FindFirstChild(name) then return ServerStorage:FindFirstChild(name) end
			return nil
		end)
		if ok and found and (found:IsA("Tool") or found:IsA("Model") or found:IsA("Folder")) then
			return found, found.Parent
		end
	end

	return nil, nil
end

-- Replacement ft_ensureHandle: ensures a real Handle BasePart and welds visuals to it.
-- Paste this into GrandInventorySerializer.lua replacing the previous ft_ensureHandle function.

-- ft_ensureHandle: ensure a proper Handle part and weld visuals to it (replacement)
local function ft_ensureHandle(tool, templateSource, preferredSize)
	if not tool then return end

	-- Helper to make a BasePart suitable as a Handle
	local function configureHandlePart(part, size)
		if not part or not part:IsA("BasePart") then return end
		pcall(function() part.Name = "Handle" end)
		pcall(function() part.Anchored = false end)
		pcall(function() part.CanCollide = false end)
		pcall(function() part.Size = size or part.Size end)
		pcall(function() tool.PrimaryPart = part end)
	end

	-- 1) Find an existing valid Handle (direct child)
	local existingHandle = nil
	if type(tool.FindFirstChild) == "function" then
		local cand = tool:FindFirstChild("Handle")
		if cand and cand:IsA("BasePart") then
			existingHandle = cand
		end
	end

	-- 2) If no direct Handle, attempt to locate a BasePart in templateSource to reuse as handle
	if not existingHandle and templateSource and type(templateSource.GetChildren) == "function" then
		for _, c in ipairs(templateSource:GetChildren()) do
			if c and type(c.IsA) == "function" and c:IsA("BasePart") then
				if tostring(c.Name) == "Handle" then existingHandle = c:Clone(); break end
				if not existingHandle then existingHandle = c:Clone() end
			end
		end
	end

	-- 3) If still none, create a small handle part
	if not existingHandle then
		local h = Instance.new("Part")
		h.Name = "Handle"
		h.Size = preferredSize or ((FTCONFIG and FTCONFIG.FallbackHandleSize) or Vector3.new(1,1,1))
		h.TopSurface = Enum.SurfaceType.Smooth
		h.BottomSurface = Enum.SurfaceType.Smooth
		h.CanCollide = false
		h.Anchored = false
		pcall(function() h.Parent = tool end)
		existingHandle = h
	else
		-- If we cloned a part from template, parent into tool
		if existingHandle.Parent ~= tool then
			pcall(function() existingHandle.Parent = tool end)
		end
	end

	-- Configure and assign as PrimaryPart
	configureHandlePart(existingHandle, preferredSize)

	-- Weld visuals to handle: find Models/BaseParts that are visual children and weld their PrimaryPart (or the part itself) to Handle.
	local handlePart = tool:FindFirstChild("Handle")
	if not handlePart or not handlePart:IsA("BasePart") then
		return
	end

	local function weldParts(partA, partB)
		if not partA or not partB then return end
		local ok, _ = pcall(function()
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = partA
			weld.Part1 = partB
			weld.Parent = partA
		end)
		pcall(function() partA.Anchored = false end)
		pcall(function() partB.Anchored = false end)
		pcall(function() partA.CanCollide = false end)
		pcall(function() partB.CanCollide = false end)
	end

	-- Weld direct BasePart children (except Handle)
	for _, child in ipairs(tool:GetChildren()) do
		if child and child ~= handlePart then
			local ok, isPart = pcall(function() return child:IsA("BasePart") end)
			if ok and isPart then
				pcall(function() weldParts(handlePart, child) end)
			else
				local ok2, isModel = pcall(function() return child:IsA("Model") end)
				if ok2 and isModel then
					local prim = nil
					pcall(function() prim = child.PrimaryPart end)
					if not prim then
						local ok3, found = pcall(function() return child:FindFirstChildWhichIsA("BasePart") end)
						if ok3 then prim = found end
					end
					if prim and prim:IsA("BasePart") then
						pcall(function() weldParts(handlePart, prim) end)
					end
				end
			end
		end
	end

	-- Ensure PrimaryPart set to handle as fallback
	pcall(function() if not tool.PrimaryPart then tool.PrimaryPart = handlePart end end)

	-- Mark Tool to require handle
	pcall(function() tool.RequiresHandle = true end)
end

local function ft_serialize(player, isFinal, profile)
	if not player or type(player.FindFirstChildOfClass) ~= "function" then
		if profile and type(profile) == "table" and profile.inventory and profile.inventory.foodTools and #profile.inventory.foodTools > 0 then
			local copy = {}
			for i, v in ipairs(profile.inventory.foodTools) do copy[i] = v end
			return copy
		end
		return {}
	end

	local tools = ft_collectFood(player)
	local list = {}
	local seenUids = {}
	local aggMode = FTCONFIG and FTCONFIG.AggregationMode or "individual"

	if aggMode == "individual" then
		for _, tool in ipairs(tools) do
			local skip = false
			pcall(function()
				if safeGetAttribute(tool, "ServerRestore") or safeGetAttribute(tool, "ServerIssued") or safeGetAttribute(tool, "PreserveOnServer") or safeGetAttribute(tool, "PreserveOnClient") then
					skip = true
				end
			end)
			if not skip then
				local entry = { nm = tool.Name }
				for attr, short in pairs(FT_ATTRS) do
					local v = safeGetAttribute(tool, attr)
					if v ~= nil then entry[short] = v end
				end
				entry.fid = entry.fid or (safeGetAttribute(tool, "FoodId") or tool.Name)

				local uidVal = safeGetAttribute(tool, "ToolUniqueId") or safeGetAttribute(tool, "ToolUid")
				if not uidVal or uidVal == "" then
					uidVal = safeGenerateGUID()
					pcall(function() tool:SetAttribute("ToolUniqueId", uidVal) end)
				end
				entry.uid = uidVal

				local uidKey = entry.uid and tostring(entry.uid) or nil
				if uidKey then
					if not seenUids[uidKey] then
						seenUids[uidKey] = true
						list[#list + 1] = entry
					end
				else
					list[#list + 1] = entry
				end

				if #list >= (FTCONFIG and FTCONFIG.MaxFood or 120) then break end
			end
		end
	else
		for _, tool in ipairs(tools) do
			local ok, v = pcall(function() return tool end)
			if ok and v then
				local entry = { nm = tool.Name }
				for attr, short in pairs(FT_ATTRS) do
					local vv = safeGetAttribute(tool, attr)
					if vv ~= nil then entry[short] = vv end
				end
				entry.fid = entry.fid or (safeGetAttribute(tool, "FoodId") or tool.Name)
				local uidVal = safeGetAttribute(tool, "ToolUniqueId") or safeGetAttribute(tool, "ToolUid") or safeGenerateGUID()
				entry.uid = uidVal
				list[#list + 1] = entry
				if #list >= (FTCONFIG and FTCONFIG.MaxFood or 120) then break end
			end
		end
	end

	local prof = profile or (type(player) == "table" and safe_get_profile and safe_get_profile(player))
	if prof and prof.inventory and #list == 0 and type(prof.inventory.foodTools) == "table" and #prof.inventory.foodTools > 0 then
		local copy = {}
		for i, v in ipairs(prof.inventory.foodTools) do copy[i] = v end
		return copy
	end

	return list
end

-- helper: clone visual children (parts, meshes, decals, sounds, attachments, LocalScript) from a template into a tool
local function ft_cloneVisualsFromTemplateIntoTool(template, tool)
	if not template or not tool then return false end
	local anyCloned = false

	-- If template is a Tool, copy its direct children
	if type(template.IsA) == "function" and template:IsA("Tool") then
		for _, child in ipairs(template:GetChildren()) do
			if child and type(child.IsA) == "function" then
				local isVisual = child:IsA("BasePart") or child:IsA("MeshPart") or child:IsA("SpecialMesh") or child:IsA("Decal") or child:IsA("Sound") or child:IsA("Attachment") or child:IsA("LocalScript")
				if isVisual then
					local ok, cl = pcall(function() return child:Clone() end)
					if ok and cl then
						cl.Parent = tool
						anyCloned = true
					end
				end
			end
		end
	else
		-- For Model/Folder, copy interesting descendants
		local descendants = nil
		pcall(function() descendants = template.GetDescendants and template:GetDescendants() end)
		if descendants and type(descendants) == "table" then
			for _, child in ipairs(descendants) do
				if child and type(child.IsA) == "function" then
					local isVisual = child:IsA("BasePart") or child:IsA("MeshPart") or child:IsA("SpecialMesh") or child:IsA("Decal") or child:IsA("Sound") or child:IsA("Attachment") or child:IsA("LocalScript")
					if isVisual then
						local ok, cl = pcall(function() return child:Clone() end)
						if ok and cl then
							cl.Parent = tool
							anyCloned = true
						end
					end
				end
			end
		end
	end

	-- set PrimaryPart if we have a Handle now
	local h = tool:FindFirstChild("Handle")
	if h and h:IsA("BasePart") then
		pcall(function() tool.PrimaryPart = h end)
	end

	return anyCloned
end

-- helper: attach a LocalScript from a template container (if available) to the tool (one copy)
local function ft_attachLocalScriptFromContainer(templateContainer, tool)
	if not templateContainer or not tool then return false end
	if type(templateContainer.GetChildren) ~= "function" then return false end
	for _, child in ipairs(templateContainer:GetChildren()) do
		if child and type(child.IsA) == "function" and child:IsA("LocalScript") then
			local ok, cl = pcall(function() return child:Clone() end)
			if ok and cl then
				cl.Parent = tool
				return true
			end
		end
	end
	return false
end

-- Build/restore tool from entry; if template missing create visible fallback and schedule retries to graft template visuals if/when template appears
-- ft_buildTool: updated tool builder with graft retry schedule
local function ft_buildTool(entry, player)
	local template, templateContainer = nil, nil
	local ok, spec, cont = pcall(function() return ft_findTemplate(entry and (entry.fid or entry.FoodId or entry.nm)) end)
	if ok then template, templateContainer = spec, cont end

	local tool = nil
	if template and type(template.IsA) == "function" and template:IsA("Tool") then
		local okc, clone = pcall(function() return template:Clone() end)
		if okc and clone then
			tool = clone
			ft_dprint("ft_buildTool: cloned Tool template:", tostring(template.Name))
		end
	end

	if not tool and template and (template:IsA("Model") or template:IsA("Folder")) then
		local okwrap, wrapped = pcall(function()
			local t = Instance.new("Tool")
			t.Name = (entry and (entry.nm or entry.fid or entry.FoodId)) or (template.Name or "Food")
			for _, c in ipairs(template:GetChildren()) do
				if c and type(c.IsA) == "function" then
					if c:IsA("BasePart") or c:IsA("MeshPart") or c:IsA("SpecialMesh") or c:IsA("Decal") or c:IsA("Sound") or c:IsA("Attachment") or c:IsA("LocalScript") then
						local ok2c, cl = pcall(function() return c:Clone() end)
						if ok2c and cl then cl.Parent = t end
					end
				end
			end
			return t
		end)
		if okwrap and wrapped then
			tool = wrapped
			ft_dprint("ft_buildTool: wrapped Model/Folder template into Tool:", tostring(template.Name))
		end
	end

	if not tool then
		tool = Instance.new("Tool")
		tool.Name = (entry and (entry.nm or entry.fid or entry.FoodId)) or "Food"
		ft_ensureHandle(tool, templateContainer, (FTCONFIG and FTCONFIG.FallbackHandleSize) or Vector3.new(1,1,1))
		ft_dprint("ft_buildTool: created fallback Tool for", tostring((entry and (entry.fid or entry.FoodId)) or "<nil>"))
	end

	-- Ensure handle/primary part present
	ft_ensureHandle(tool, templateContainer, (FTCONFIG and FTCONFIG.FallbackHandleSize) or Vector3.new(1,1,1))

	-- canonical attributes (do not overwrite sensible existing values)
	safeSetAttribute(tool, "FoodItem", true)
	safeSetAttribute(tool, "FoodId", (entry and (entry.fid or entry.FoodId or entry.nm)) or tool.Name)
	safeSetAttribute(tool, "OwnerUserId", (player and player.UserId) or safeGetAttribute(tool, "OwnerUserId"))
	safeSetAttribute(tool, "PersistentFoodTool", true)
	safeSetAttribute(tool, "__FoodSerVersion", (FTCONFIG and FTCONFIG.Version) or "1.0")

	-- ToolUniqueId assignment
	local existingUid = safeGetAttribute(tool, "ToolUniqueId") or safeGetAttribute(tool, "ToolUid")
	local assignUid = existingUid
	if (not assignUid or assignUid == "") and entry and (entry.uid or entry.ToolUniqueId or entry.ToolUid) then
		assignUid = entry.uid or entry.ToolUniqueId or entry.ToolUid
	end
	if not assignUid or assignUid == "" then assignUid = safeGenerateGUID() end
	safeSetAttribute(tool, "ToolUniqueId", assignUid)

	-- Mark restore/preserve flags
	safeSetAttribute(tool, "ServerIssued", true)
	safeSetAttribute(tool, "ServerRestore", true)
	safeSetAttribute(tool, "PreserveOnServer", true)
	safeSetAttribute(tool, "RestoreStamp", tick())
	safeSetAttribute(tool, "RestoreBatchId", os.time())

	-- copy small attributes from entry if present
	pcall(function() if entry and entry.ch then safeSetAttribute(tool, "Charges", tonumber(entry.ch) or entry.Charges or FTCONFIG.Charges) end end)
	pcall(function() if entry and entry.cs ~= nil then safeSetAttribute(tool, "Consumable", entry.cs) end end)
	pcall(function() if entry and entry.rf ~= nil then safeSetAttribute(tool, "RestoreFraction", entry.rf) end end)
	pcall(function() if entry and entry.fb ~= nil then safeSetAttribute(tool, "FeedBufferBonus", entry.fb) end end)

	-- Attach LocalScript from template container if available
	pcall(function() ft_attachLocalScriptFromContainer(templateContainer, tool) end)

	-- Retry grafting of template visuals has been disabled.
	-- Reason: avoid late graft/weld of fallback tool visuals that causes duplicate/grafted models on restore.

	return tool
end

local function ft_restoreImmediate(player, list, backpack)
	ft_restoreBatchCounter = ft_restoreBatchCounter + 1
	local batch = ft_restoreBatchCounter
	ft_dprint(("entries=%d batch=%d"):format(#list, batch))
	if not player or not list or #list == 0 then return end
	if not backpack then backpack = player:FindFirstChildOfClass("Backpack") end
	if not backpack then
		ft_dprint("ft_restoreImmediate: no backpack available; aborting immediate restore")
		return
	end

	local createdEntries = {}
	for _, e in ipairs(list) do
		if #createdEntries >= (FTCONFIG and FTCONFIG.MaxFood or 120) then break end
		if not e.uid or e.uid == "" then e.uid = safeGenerateGUID() end

		local function findByUid(container)
			if not container or type(container.GetChildren) ~= "function" then return nil end
			for _, it in ipairs(container:GetChildren()) do
				if it and type(it.IsA) == "function" and it:IsA("Tool") then
					local tid = safeGetAttribute(it, "ToolUniqueId") or safeGetAttribute(it, "ToolUid")
					if tid and tostring(tid) == tostring(e.uid) then return it end
				end
			end
			return nil
		end

		local existing = findByUid(backpack) or (player and findByUid(player.Character))
		if not existing then
			if ServerStorage then
				local ok, desc = pcall(function() return ServerStorage:GetDescendants() end)
				if ok and type(desc) == "table" then
					for _, s in ipairs(desc) do
						if s and type(s.IsA) == "function" and s:IsA("Tool") then
							local tid = safeGetAttribute(s, "ToolUniqueId") or safeGetAttribute(s, "ToolUid")
							if tid and tostring(tid) == tostring(e.uid) then existing = s; break end
						end
					end
				end
			end
		end

		if existing then
			pcall(function()
				pcall(function() existing:SetAttribute("OwnerUserId", player.UserId) end)
				mark_restored_instance(existing, player.UserId, e.uid)
				pcall(function() existing.Parent = backpack end)
				ft_dprint("[FoodSer][RestoreImmediate] Tool restored to Backpack: " .. tostring(existing.Name))
			end)
			createdEntries[#createdEntries + 1] = existing
		else
			local tool = ft_buildTool(e, player)
			pcall(function()
				mark_restored_instance(tool, player.UserId, e.uid)
				pcall(function() tool.Parent = backpack end)
			end)
			ft_dprint("[FoodSer][RestoreImmediate] Tool created and parented to Backpack: " .. tostring(tool.Name))

			pcall(function()
				local debugTool = tool
				task.delay(0.5, function()
					local okP, parent = pcall(function() return debugTool and debugTool.Parent end)
					ft_dprint("[FT Debug]", tostring(debugTool and debugTool.Name), "parent@0.5s =", (okP and (parent and (parent.GetFullName and parent:GetFullName()) or tostring(parent)) or "<err>"))
					local attrs = {}
					for _, k in ipairs({"ToolUniqueId","ToolUid","ServerRestore","PreserveOnServer","RestoreStamp","RecentlyPlacedSaved","OwnerUserId","FoodId"}) do
						pcall(function() attrs[k] = (debugTool.GetAttribute and debugTool:GetAttribute(k)) end)
					end
					if HttpService and type(HttpService.JSONEncode) == "function" then
						ft_dprint("[FT Debug] attrs@0.5s:", HttpService:JSONEncode(attrs))
					else
						ft_dprint("[FT Debug] attrs@0.5s:", tostring(attrs))
					end
				end)
			end)

			createdEntries[#createdEntries + 1] = tool
		end
	end

	local prof = (safe_get_profile and safe_get_profile(player)) or nil
	local PPS = getPPS and getPPS()
	if prof and type(prof) == "table" then
		if not prof.inventory then prof.inventory = {} end
		if prof.inventory.foodTools == nil or #prof.inventory.foodTools == 0 then
			prof.inventory.foodTools = prof.inventory.foodTools or {}
			for _, entry in ipairs(list) do table.insert(prof.inventory.foodTools, entry) end
			if PPS then
				pcall(function() sanitizeInventoryOnProfile(prof) end)
				pcall(function() PPS.SaveNow(player, "GrandInvSer_FoodRestore") end)
			end
		end
	end
end

local function ft_restore(player, list)
	ft_dprint("[FoodSer][Restore] incoming list size=", list and #list or 0, "for", player and player.Name or "nil")
	if not list or #list == 0 then return end
	if player then
		waitForInventoryReady(player)
	end
	local backpack = player and player:FindFirstChildOfClass("Backpack")
	if backpack then
		ft_restoreImmediate(player, list, backpack)
		return
	end

	local uid = tonumber((player and player.UserId) or (list and list[1] and list[1].OwnerUserId) or nil)
	local pid = player and getPersistentIdFor and getPersistentIdFor(player) or nil
	if not uid and player and player.UserId then uid = player.UserId end

	if uid then
		pendingRestores[uid] = pendingRestores[uid] or {}
		pendingRestores[uid].ft = pendingRestores[uid].ft or {}
		for _, e in ipairs(list) do table.insert(pendingRestores[uid].ft, e) end
		pendingRestores[uid].timeout = os.time() + (PENDING_DEFAULT_TIMEOUT or 60)
		ft_dprint(("Scheduled foodTools restore for userId=%s entries=%d"):format(tostring(uid), #pendingRestores[uid].ft))
		return
	end

	if pid then
		pendingRestoresByPersistentId[pid] = pendingRestoresByPersistentId[pid] or {}
		pendingRestoresByPersistentId[pid].ft = pendingRestoresByPersistentId[pid].ft or {}
		for _, e in ipairs(list) do table.insert(pendingRestoresByPersistentId[pid].ft, e) end
		pendingRestoresByPersistentId[pid].timeout = os.time() + (PENDING_DEFAULT_TIMEOUT or 60)
		ft_dprint(("Scheduled foodTools restore for persistentId=%s entries=%d"):format(tostring(pid), #pendingRestoresByPersistentId[pid].ft))
		return
	end

	ft_dprint("ft_restore: cannot determine userId or persistentId to schedule pending restore; aborting.")
end

GrandInventorySerializer._internal = GrandInventorySerializer._internal or {}
GrandInventorySerializer._internal.FoodTool = GrandInventorySerializer._internal.FoodTool or {}
GrandInventorySerializer._internal.FoodTool.ft_serialize = ft_serialize
GrandInventorySerializer._internal.FoodTool.ft_restore = ft_restore
GrandInventorySerializer._internal.FoodTool.ft_restoreImmediate = ft_restoreImmediate
GrandInventorySerializer._internal.FoodTool.ft_buildTool = ft_buildTool
GrandInventorySerializer._internal.FoodTool.ft_collectFood = ft_collectFood

ft_dprint("FoodTool section loaded (updated).")

-- EggTool
local ETCONFIG = GrandInventorySerializer.CONFIG.EggTool
local function et_dprint(...) if ETCONFIG.Debug then print("[EggSer]", ...) end end

local function et_qualifies(tool)
	if not tool then return false end
	if type(tool.IsA) ~= "function" then return false end
	if not tool:IsA("Tool") then return false end
	return tool:GetAttribute("EggId") ~= nil or tool:GetAttribute("EggTool") ~= nil
end

local function et_collect(player)
	if not player or type(player.FindFirstChildOfClass) ~= "function" then return {} end
	local out = {}
	local bp = player:FindFirstChildOfClass("Backpack")
	if bp then for _,c in ipairs(bp:GetChildren()) do if et_qualifies(c) then table.insert(out,c) end end end
	if player.Character then for _,c in ipairs(player.Character:GetChildren()) do if et_qualifies(c) then table.insert(out,c) end end end
	for _,s in ipairs(ServerStorage:GetDescendants()) do
		if s:IsA("Tool") then
			local owner = s:GetAttribute("OwnerUserId")
			if owner and tostring(owner) == tostring(player.UserId) and et_qualifies(s) then
				table.insert(out, s)
			end
		end
	end
	return out
end

local function et_serialize(player, isFinal, profile)
	if (not player or type(player.FindFirstChildOfClass) ~= "function") and profile and type(profile) == "table" then
		if profile.inventory and profile.inventory.eggTools and #profile.inventory.eggTools > 0 then
			local copy = {}
			for i,v in ipairs(profile.inventory.eggTools) do copy[i] = v end
			return copy
		end
		return {}
	end

	local tools = et_collect(player)
	local list = {}
	local seen = {}

	for _,tool in ipairs(tools) do
		-- skip server-preserved / server-issued tools
		local skip = false
		pcall(function()
			if tool:GetAttribute("ServerRestore") or tool:GetAttribute("ServerIssued") or tool:GetAttribute("PreserveOnServer") or tool:GetAttribute("PreserveOnClient") then
				skip = true
			end
		end)

		if not skip then
			local entry = {
				EggId = tool:GetAttribute("EggId"),
				Rarity = tool:GetAttribute("Rarity"),
				HatchTime = tool:GetAttribute("HatchTime"),
				Weight = tool:GetAttribute("WeightScalar"),
				Move = tool:GetAttribute("MovementScalar"),
				ValueBase = tool:GetAttribute("ValueBase"),
				ValuePerGrowth = tool:GetAttribute("ValuePerGrowth"),
				ToolName = tool.Name,
			}
			pcall(function() entry.ToolUid = tool:GetAttribute("ToolUniqueId") or tool:GetAttribute("ToolUid") or nil end)
			pcall(function() entry.OwnerUserId = tool:GetAttribute("OwnerUserId") or player.UserId end)

			if not entry.ToolUid or entry.ToolUid == "" then
				if ETCONFIG.AssignUidIfMissingOnSerialize then
					entry.ToolUid = HttpService:GenerateGUID(false)
					pcall(function() tool:SetAttribute("ToolUniqueId", entry.ToolUid) end)
				end
			end

			local key = tostring(entry.ToolUid or entry.EggId or tool.Name)
			if not seen[key] then
				seen[key] = true
				table.insert(list, entry)
			end
			if #list >= ETCONFIG.MaxEggTools then break end
		end
	end

	local prof = profile or safe_get_profile(player)
	if prof and prof.inventory and #list == 0 and type(prof.inventory.eggTools) == "table" and #prof.inventory.eggTools > 0 then
		local copy = {}
		for i,v in ipairs(prof.inventory.eggTools) do copy[i] = v end
		return copy
	end

	return list
end

local function et_buildTool(entry, player)
	local templates = ReplicatedStorage:FindFirstChild("ToolTemplates")
	local template = nil
	if templates then template = templates:FindFirstChild("EggToolTemplate") or templates:FindFirstChild(entry.ToolName or "Egg") end
	local tool = nil
	if template and template:IsA("Tool") then local ok, clone = pcall(function() return template:Clone() end); if ok and clone then tool = clone end end
	if not tool then
		tool = Instance.new("Tool")
		tool.Name = entry.ToolName or "Egg"
		local handle = Instance.new("Part")
		handle.Name = "Handle"
		handle.Size = ETCONFIG.FallbackHandleSize or Vector3.new(1,1,1)
		handle.Parent = tool
		tool.Parent = workspace
	end
	tool:SetAttribute("EggId", entry.EggId)
	tool:SetAttribute("Rarity", entry.Rarity)
	tool:SetAttribute("HatchTime", entry.HatchTime)
	tool:SetAttribute("WeightScalar", entry.Weight)
	tool:SetAttribute("MovementScalar", entry.Move)
	tool:SetAttribute("ValueBase", entry.ValueBase)
	tool:SetAttribute("ValuePerGrowth", entry.ValuePerGrowth)
	tool:SetAttribute("OwnerUserId", player.UserId)
	tool:SetAttribute("ServerIssued", true)
	if entry.ToolUid then tool:SetAttribute("ToolUniqueId", entry.ToolUid) end
	tool:SetAttribute("ServerRestore", true)
	tool:SetAttribute("PreserveOnServer", true)
	return tool
end

-- Replace existing et_restoreImmediate(...) with this implementation
local function et_restoreImmediate(player, list, backpack)
	et_dprint("[ET][RestoreImmediate] incoming count=", #list, "for", player and player.Name or "nil")
	if not player or not list or #list == 0 then return end

	for _,entry in ipairs(list) do
		local uid = entry.ToolUid or entry.EggId
		local function findInContainer(container)
			if not container then return nil end
			for _,it in ipairs(container:GetChildren()) do
				if it:IsA("Tool") then
					local tid = it:GetAttribute("ToolUniqueId") or it:GetAttribute("ToolUid")
					local eid = it:GetAttribute("EggId")
					if (tid and uid and tostring(tid) == tostring(uid)) or (eid and entry.EggId and tostring(eid) == tostring(entry.EggId)) then
						return it
					end
				end
			end
			return nil
		end
		local found = findInContainer(backpack) or findInContainer(player.Character) or (function()
			for _,s in ipairs(ServerStorage:GetDescendants()) do
				if s:IsA("Tool") then
					local tid = s:GetAttribute("ToolUniqueId") or s:GetAttribute("ToolUid")
					local eid = s:GetAttribute("EggId")
					if (tid and uid and tostring(tid) == tostring(uid)) or (eid and entry.EggId and tostring(eid) == tostring(entry.EggId)) then
						return s
					end
				end
			end
			return nil
		end)()
		if found then
			-- mark consistently and parent
			pcall(function()
				mark_restored_instance(found, player.UserId, uid)
				pcall(function() found.Parent = backpack end)
			end)
		else
			local tool = et_buildTool(entry, player)
			pcall(function()
				mark_restored_instance(tool, player.UserId, uid)
				tool.Parent = backpack
			end)
		end
	end
	local prof = safe_get_profile(player)
	local PPS = getPPS()
	if prof and type(prof) == "table" then
		if not prof.inventory then prof.inventory = {} end
		if prof.inventory.eggTools == nil or #prof.inventory.eggTools == 0 then
			prof.inventory.eggTools = prof.inventory.eggTools or {}
			for _,entry in ipairs(list) do table.insert(prof.inventory.eggTools, entry) end
			if PPS then
				pcall(function() sanitizeInventoryOnProfile(prof) end)
				pcall(function() PPS.SaveNow(player, "GrandInvSer_EggRestore") end)
			end
		end
	end
end

-- EggTool Restore (robust, race-safe, deferred parenting, correct attributes)
local function et_restore(player, list)
	et_dprint("[ET][Restore] incoming count=", list and #list or 0, "for", player and player.Name or "nil")
	if not list or #list == 0 then return end

	if player then
		waitForInventoryReady(player)
	end
	-- Immediate restore if Backpack is ready
	local backpack = player and player:FindFirstChildOfClass("Backpack")
	if backpack then
		et_restoreImmediate(player, list, backpack)
		return
	end

	-- Otherwise, defer restore until backpack is present
	local uid = tonumber((player and player.UserId) or (list and list[1] and list[1].OwnerUserId) or nil)
	local pid = player and getPersistentIdFor and getPersistentIdFor(player) or nil
	if not uid and player and player.UserId then uid = player.UserId end

	if uid then
		pendingRestores[uid] = pendingRestores[uid] or {}
		pendingRestores[uid].et = pendingRestores[uid].et or {}
		for _,e in ipairs(list) do table.insert(pendingRestores[uid].et, e) end
		pendingRestores[uid].timeout = os.time() + (PENDING_DEFAULT_TIMEOUT or 60)
		et_dprint(("Scheduled eggTools restore for userId=%s entries=%d"):format(tostring(uid), #pendingRestores[uid].et))
		return
	end

	if pid then
		pendingRestoresByPersistentId[pid] = pendingRestoresByPersistentId[pid] or {}
		pendingRestoresByPersistentId[pid].et = pendingRestoresByPersistentId[pid].et or {}
		for _,e in ipairs(list) do table.insert(pendingRestoresByPersistentId[pid].et, e) end
		pendingRestoresByPersistentId[pid].timeout = os.time() + (PENDING_DEFAULT_TIMEOUT or 60)
		et_dprint(("Scheduled eggTools restore for persistentId=%s entries=%d"):format(tostring(pid), #pendingRestoresByPersistentId[pid].et))
		return
	end

	et_dprint("et_restore: cannot determine userId or persistentId to schedule pending restore; aborting.")
end





-- CapturedSlime serialize / restore helpers
-- Insert this block after the EggTool (et) restore/serialize functions, before processPendingForPlayer
-- It adds support for profile.inventory.capturedSlimes and pending restore queueing.
-- CapturedSlime serialize / restore helpers (fixed)
-- Paste this block into GrandInventorySerializer.lua replacing the previous captured-slime section.
-- Fixes:
--  - Replaced fragile "x and x:IsA and x:IsA(...)" patterns with explicit type checks: type(x.IsA) == "function" and x:IsA(...)
--  - Removed any 'and' chains that used colon method references in boolean expressions (these can confuse the parser).
--  - Rewrote Players/GetPlayerByUserId checks to explicit type checks + method call.
--  - Avoided use of 'continue' (not supported in some Luau runtimes).
--  - Kept defensive pcall usage and preserved original behavior.

-- CapturedSlime: merged preview-builder logic + serializer/restore improvements
-- Drop-in replacement for the CapturedSlime section of GrandInventorySerializer.lua
-- - Adds BuildVisualFromTool / EnsureToolVisual so restored tools get a physical SlimeVisual
-- - Ensures cs_buildTool constructs a visible visual when possible
-- - Calls EnsureToolVisual after placing restored tools into Backpack so players don't hold invisible tools
-- - Defensive, pcall-wrapped operations to avoid restore crashes
-- - Reuses project asset locations (ToolTemplates, ReplicatedStorage.Assets.Slime) and falls back gracefully

local CSCONFIG = GrandInventorySerializer.CONFIG and GrandInventorySerializer.CONFIG.CapturedSlime or {}
local function cs_dprint(...)
	if CSCONFIG and CSCONFIG.Debug then
		print("[CapturedSlimeSer]", ...)
	end
end
local function cs_warn(...)
	if CSCONFIG and CSCONFIG.Debug then
		warn("[CapturedSlimeSer]", ...)
	end
end

-- ----------------------------
-- Slime preview builder helpers (merged from SlimeCaptureService)
-- ----------------------------
local SLIME_TEMPLATE_PATH = CSCONFIG.SlimeTemplatePath or {"Assets","Slime"}

local function findSlimeTemplate()
	-- resolve path: accept table or string; fallback to Assets.Slime
	local configured = SLIME_TEMPLATE_PATH
	local path = nil
	if type(configured) == "table" then
		path = configured
	elseif type(configured) == "string" then
		path = { configured }
	else
		path = { "Assets", "Slime" }
	end

	local node = ReplicatedStorage
	for _, seg in ipairs(path) do
		if not node then return nil end
		if type(node.FindFirstChild) ~= "function" then return nil end
		node = node:FindFirstChild(seg)
		if not node then return nil end
	end
	if node and node:IsA("Model") then return node end

	-- fallback explicit Assets.Slime
	local assetsNode = ReplicatedStorage:FindFirstChild("Assets")
	if assetsNode then
		local s = assetsNode:FindFirstChild("Slime")
		if s and s:IsA("Model") then return s end
	end
	return nil
end

local function deepCloneAndSanitize(template)
	if not template then return nil end
	local clone = template:Clone()
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ModuleScript") then
			pcall(function() d:Destroy() end)
		elseif d:IsA("BasePart") then
			pcall(function()
				d.Anchored = false
				d.CanCollide = false
				d.CanTouch = false
				d.CanQuery = false
				if pcall(function() d.Massless = true end) then end
			end)
		end
	end
	return clone
end

local function applyScaleToModel(model, scale)
	if not model then return end
	if not scale then return end
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			local ok, orig = pcall(function() return p:GetAttribute("OriginalSize") end)
			local original = (ok and orig) or p.Size
			if not ok then p:SetAttribute("OriginalSize", original) end
			local ns = original * scale
			p.Size = Vector3.new(math.max(ns.X, 0.05), math.max(ns.Y, 0.05), math.max(ns.Z, 0.05))
		end
	end
	pcall(function() model:SetAttribute("CurrentSizeScale", scale) end)
end

local function decodeColorString(v)
	if typeof(v) == "Color3" then return v end
	if type(v) == "string" then
		local hex = v:gsub("^#","")
		if #hex == 6 then
			local r = tonumber(hex:sub(1,2),16)
			local g = tonumber(hex:sub(3,4),16)
			local b = tonumber(hex:sub(5,6),16)
			if r and g and b then
				return Color3.fromRGB(r,g,b)
			end
		end
	end
	return nil
end

local function applyColorsToModel(model, attrs)
	if not model or type(attrs) ~= "table" then return end
	local bc = decodeColorString(attrs.BodyColor or attrs.bc)
	local ac = decodeColorString(attrs.AccentColor or attrs.ac)
	local ec = decodeColorString(attrs.EyeColor or attrs.ec)

	if not (bc or ac or ec) then return end
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			local lname = p.Name:lower()
			if ec and (lname:find("eye") or lname:find("pupil")) then
				p.Color = ec
			elseif bc then
				p.Color = bc
			end
		end
	end
end

-- re-use weldVisual from SlimeCaptureService (small, safe implementation)
local function weldVisual(tool)
	if not tool or not tool:IsA("Tool") then return end
	local handle = tool:FindFirstChild("Handle")
	local visual = tool:FindFirstChild("SlimeVisual")
	if not (handle and visual and visual:IsA("Model")) then return end
	-- ensure primary
	local prim = visual.PrimaryPart
	if not prim then
		for _,c in ipairs(visual:GetDescendants()) do
			if c:IsA("BasePart") then
				visual.PrimaryPart = c
				prim = c
				break
			end
		end
	end
	if not prim then return end
	pcall(function() visual:SetPrimaryPartCFrame(handle.CFrame) end)
	pcall(function()
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = handle
		weld.Part1 = prim
		weld.Parent = handle
	end)
	for _,p in ipairs(visual:GetDescendants()) do
		if p:IsA("BasePart") and p ~= prim then
			pcall(function()
				local w = Instance.new("WeldConstraint")
				w.Part0 = prim
				w.Part1 = p
				w.Parent = p
				p.CanCollide = false
				if pcall(function() p.Massless = true end) then end
			end)
		end
	end
end

-- Build a SlimeVisual model inside a tool from attributes (idempotent)
local function BuildVisualFromTool(tool)
	if not tool or not tool:IsA("Tool") then return nil end
	if tool:FindFirstChild("SlimeVisual") then return tool:FindFirstChild("SlimeVisual") end

	local template = findSlimeTemplate()
	if not template then
		cs_dprint("Slime template not found; cannot build visual for tool:", tool.Name)
		return nil
	end

	local model = deepCloneAndSanitize(template)
	model.Name = "SlimeVisual"

	-- gather scale (prefer CurrentSizeScale, StartSizeScale, else compute from GrowthProgress*MaxSizeScale)
	local scale = tool:GetAttribute("CurrentSizeScale") or tool:GetAttribute("StartSizeScale")
	if not scale then
		local gp = tool:GetAttribute("GrowthProgress")
		local mx = tool:GetAttribute("MaxSizeScale")
		if gp and mx then scale = gp * mx end
	end
	if not scale then scale = 1 end
	applyScaleToModel(model, scale)

	local attrs = {
		BodyColor = tool:GetAttribute("BodyColor"),
		AccentColor = tool:GetAttribute("AccentColor"),
		EyeColor = tool:GetAttribute("EyeColor"),
		bc = tool:GetAttribute("BodyColor"),
		ac = tool:GetAttribute("AccentColor"),
		ec = tool:GetAttribute("EyeColor"),
	}
	applyColorsToModel(model, attrs)

	-- parent into tool
	model.Parent = tool

	-- try to position at handle if available
	local handle = tool:FindFirstChild("Handle")
	if handle then
		pcall(function()
			if model.PrimaryPart then
				model:SetPrimaryPartCFrame(handle.CFrame)
			else
				for _,c in ipairs(model:GetDescendants()) do
					if c:IsA("BasePart") then
						model.PrimaryPart = c
						model:SetPrimaryPartCFrame(handle.CFrame)
						break
					end
				end
			end
		end)
	end

	-- weld to handle
	weldVisual(tool)
	cs_dprint("Built visual for tool:", tool.Name, "SlimeId=", tostring(tool:GetAttribute("SlimeId")))
	return model
end

-- EnsureToolVisual: build visual if missing; fallback to single part so tool isn't invisible
local function EnsureToolVisual(tool)
	-- Disabled: prevent automatic creation/grafting of SlimeVisual into captured-slime Tools during restore.
	-- Returning false indicates no visual was added.
	return false
end

-- ----------------------------
-- CapturedSlime serializer / restore (updated)
-- ----------------------------

-- CapturedSlime serializer / restore (updated, standalone section)
-- Drop-in replacement for the CapturedSlime portion of GrandInventorySerializer.
-- Main fixes:
--  - More robust qualification checks for captured tools.
--  - Do NOT skip items simply because they're ServerIssued/PreserveOnServer (these flags are used by other flows).
--    Only skip items that are server-restores (ServerRestore) or explicitly marked PreserveOnClient.
--  - Safer retrieval of ToolUniqueId and generation when missing.
--  - Defensive pcall wrappers around attribute accesses.
--  - Keeps merged preview-builder helpers (EnsureToolVisual/BuildVisualFromTool) exported at the end.
-- NOTE: This section assumes the surrounding module provides:
--   - HttpService, ServerStorage, ReplicatedStorage, Players
--   - getPPS(), safe_get_profile(), sanitizeInventoryOnProfile(), pendingRestores*, PENDING_DEFAULT_TIMEOUT
--   - EnsureToolVisual(), BuildVisualFromTool(), cs_dprint()/cs_warn(), and GrandInventorySerializer table.
-- Paste this block to replace the previous captured-slime section.

local CSCONFIG = GrandInventorySerializer.CONFIG and GrandInventorySerializer.CONFIG.CapturedSlime or {}


-- Helper: determines whether a Tool looks like a captured slime (defensive)
local function cs_qualifies(tool)
	if not tool then return false end
	-- must be a Tool instance
	if type(tool.IsA) ~= "function" or not tool:IsA("Tool") then return false end
	-- check common attributes/markers, using pcall to avoid errors
	local ok, v = pcall(function() return tool:GetAttribute("PersistentCaptured") end)
	if ok and v then return true end
	ok, v = pcall(function() return tool:GetAttribute("SlimeItem") end)
	if ok and v then return true end
	ok, v = pcall(function() return tool:GetAttribute("CapturedSlimeTool") end)
	if ok and v then return true end
	ok, v = pcall(function() return tool:GetAttribute("SlimeId") end)
	if ok and v then return true end
	-- last-resort: check for child values named like SlimeId/ToolUniqueId
	if tool.FindFirstChild then
		local ch = tool:FindFirstChild("SlimeId") or tool:FindFirstChild("ToolUniqueId") or tool:FindFirstChild("ToolUid")
		if ch and ch.Value ~= nil then return true end
	end
	return false
end

-- Collect captured tools for a given player (Backpack, Character, ServerStorage)
local function cs_collectCaptured(player)
	if not player or type(player.FindFirstChildOfClass) ~= "function" then
		cs_dprint("[cs_collectCaptured] no player instance; returning empty list")
		return {}
	end
	local out = {}
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, c in ipairs(backpack:GetChildren()) do
			local ok, q = pcall(cs_qualifies, c)
			if ok and q then table.insert(out, c) end
		end
	end
	if player.Character then
		for _, c in ipairs(player.Character:GetChildren()) do
			local ok, q = pcall(cs_qualifies, c)
			if ok and q then table.insert(out, c) end
		end
	end
	-- also scan ServerStorage for authored copies that belong to this user
	if ServerStorage then
		for _, s in ipairs(ServerStorage:GetDescendants()) do
			if s and type(s.IsA) == "function" and s:IsA("Tool") then
				local okOwner, owner = pcall(function() return s:GetAttribute("OwnerUserId") end)
				if okOwner and owner and tostring(owner) == tostring(player.UserId) then
					local ok2, q = pcall(cs_qualifies, s)
					if ok2 and q then table.insert(out, s) end
				end
			end
		end
	end

	-- ensure owner attribute for items we return
	for _, tool in ipairs(out) do
		pcall(function() tool:SetAttribute("OwnerUserId", player.UserId) end)
	end
	return out
end

-- Find appropriate template for building captured tool on restore
local function cs_findTemplate(fid)
	local folderName = (CSCONFIG and CSCONFIG.TemplateFolder) or "ToolTemplates"
	local folder = ReplicatedStorage and ReplicatedStorage:FindFirstChild(folderName)
	if folder and type(folder.FindFirstChild) == "function" then
		local spec = nil
		if CSCONFIG and CSCONFIG.TemplateNameCaptured then
			spec = folder:FindFirstChild(CSCONFIG.TemplateNameCaptured)
		end
		if not spec and fid then
			spec = folder:FindFirstChild(fid)
		end
		if spec and type(spec.IsA) == "function" and spec:IsA("Tool") then return spec end
	end

	-- fallback places
	local templates = ReplicatedStorage and ReplicatedStorage:FindFirstChild("ToolTemplates")
	if templates and type(templates.IsA) == "function" and templates:IsA("Folder") then
		local t = templates:FindFirstChild("CapturedSlimeTool") or templates:FindFirstChild("CapturedSlime")
		if t and type(t.IsA) == "function" and t:IsA("Tool") then return t end
	end
	local standalone = ReplicatedStorage and ReplicatedStorage:FindFirstChild("CapturedSlimeTool")
	if standalone and type(standalone.IsA) == "function" and standalone:IsA("Tool") then return standalone end
	return nil
end

-- Build a Tool instance from serialized captured-slime entry (best-effort)
local function cs_buildTool(entry, player)
	local template = cs_findTemplate(entry and entry.SlimeId)
	local tool = nil
	if template then
		local ok, clone = pcall(function() return template:Clone() end)
		if ok and clone then tool = clone end
	end
	if not tool then
		tool = Instance.new("Tool")
		tool.Name = "CapturedSlime"
		local handle = Instance.new("Part")
		handle.Name = "Handle"
		handle.Size = Vector3.new(1, 1, 1)
		handle.Parent = tool
	end

	-- core attributes
	pcall(function() tool:SetAttribute("PersistentCaptured", true) end)
	pcall(function() tool:SetAttribute("SlimeItem", true) end)
	if entry and entry.SlimeId then pcall(function() tool:SetAttribute("SlimeId", entry.SlimeId) end) end
	if entry and entry.ToolUniqueId then pcall(function() tool:SetAttribute("ToolUniqueId", entry.ToolUniqueId) end) end
	pcall(function() tool:SetAttribute("OwnerUserId", player and player.UserId) end)
	if entry and entry.CapturedAt then pcall(function() tool:SetAttribute("CapturedAt", entry.CapturedAt) end) end
	if entry and entry.Rarity then pcall(function() tool:SetAttribute("Rarity", entry.Rarity) end) end
	if entry and entry.WeightPounds then pcall(function() tool:SetAttribute("WeightPounds", entry.WeightPounds) end) end
	if entry and entry.CurrentValue then pcall(function() tool:SetAttribute("CurrentValue", entry.CurrentValue) end) end
	if entry and entry.GrowthProgress then pcall(function() tool:SetAttribute("GrowthProgress", entry.GrowthProgress) end) end
	if entry and entry.BodyColor then pcall(function() tool:SetAttribute("BodyColor", entry.BodyColor) end) end
	if entry and entry.AccentColor then pcall(function() tool:SetAttribute("AccentColor", entry.AccentColor) end) end
	if entry and entry.EyeColor then pcall(function() tool:SetAttribute("EyeColor", entry.EyeColor) end) end

	-- mark as server-restore so other systems know this was created by restore
	pcall(function() tool:SetAttribute("ServerRestore", true) end)
	pcall(function() tool:SetAttribute("PreserveOnServer", true) end)
	pcall(function() tool:SetAttribute("RestoreStamp", tick()) end)

	-- ensure visual if possible (best-effort)
	pcall(function() EnsureToolVisual(tool) end)

	return tool
end

-- Serialize captured tools for a player/profile
local function cs_serialize(player, isFinal, profile)
	-- profile-only path
	if (not player or type(player.FindFirstChildOfClass) ~= "function") and profile and type(profile) == "table" then
		if profile.inventory and profile.inventory.capturedSlimes and #profile.inventory.capturedSlimes > 0 then
			local copy = {}
			for i, v in ipairs(profile.inventory.capturedSlimes) do copy[i] = v end
			return copy
		end
		return {}
	end

	-- gather live tools
	local tools = cs_collectCaptured(player)
	local list = {}
	local seen = {}
	local maxStored = (CSCONFIG and CSCONFIG.MaxStored) or 120

	for _, tool in ipairs(tools) do
		local skip = false
		pcall(function()
			if tool:GetAttribute("ServerRestore") then skip = true end
			if tool:GetAttribute("PreserveOnClient") then skip = true end
		end)
		if not skip then
			local entry = {}
			pcall(function() entry.SlimeId = tool:GetAttribute("SlimeId") end)
			local ok, tuid = pcall(function() return tool:GetAttribute("ToolUniqueId") end)
			if not ok or not tuid or tuid == "" then
				local ok2, alt = pcall(function() return tool:GetAttribute("ToolUid") end)
				if ok2 and alt and alt ~= "" then tuid = alt end
			end
			if not tuid or tuid == "" then
				local gen = nil
				pcall(function() gen = (HttpService and HttpService:GenerateGUID(false)) or (tostring(tick()) .. "-" .. tostring(math.random(1, 1000000))) end)
				tuid = gen or (tostring(tick()) .. "-" .. tostring(math.random(1, 1000000)))
				pcall(function() tool:SetAttribute("ToolUniqueId", tuid) end)
			end
			entry.ToolUniqueId = tuid

			pcall(function() entry.CapturedAt = tool:GetAttribute("CapturedAt") end)
			pcall(function() entry.OwnerUserId = tool:GetAttribute("OwnerUserId") end)
			if not entry.OwnerUserId and player then entry.OwnerUserId = player.UserId end
			pcall(function() entry.Rarity = tool:GetAttribute("Rarity") end)
			pcall(function() entry.WeightPounds = tool:GetAttribute("WeightPounds") end)
			pcall(function() entry.CurrentValue = tool:GetAttribute("CurrentValue") end)
			pcall(function() entry.GrowthProgress = tool:GetAttribute("GrowthProgress") end)
			pcall(function() entry.BodyColor = tool:GetAttribute("BodyColor") end)
			pcall(function() entry.AccentColor = tool:GetAttribute("AccentColor") end)
			pcall(function() entry.EyeColor = tool:GetAttribute("EyeColor") end)

			local key = tostring(entry.ToolUniqueId or entry.SlimeId or "")
			if key ~= "" then
				if not seen[key] then
					seen[key] = true
					table.insert(list, entry)
				end
			else
				table.insert(list, entry)
			end

			if #list >= maxStored then break end
		end
	end

	local prof = profile or safe_get_profile(player)
	if prof and prof.inventory and type(prof.inventory.capturedSlimes) == "table" then
		for _, entry in ipairs(prof.inventory.capturedSlimes) do
			if #list >= maxStored then break end
			if type(entry) == "table" then
				local key = tostring(entry.ToolUniqueId or entry.ToolUid or entry.SlimeId or "")
				if key ~= "" then
					if not seen[key] then
						seen[key] = true
						local c = {}
						for k, v in pairs(entry) do c[k] = v end
						if not c.ToolUniqueId or c.ToolUniqueId == "" then
							local gen = nil
							pcall(function() gen = (HttpService and HttpService:GenerateGUID(false)) or (tostring(tick()) .. "-" .. tostring(math.random(1, 1000000))) end)
							c.ToolUniqueId = gen or (tostring(tick()) .. "-" .. tostring(math.random(1, 1000000)))
						end
						table.insert(list, c)
					end
				else
					local sid = tostring(entry.SlimeId or "")
					local found = false
					if sid ~= "" then
						for _, v in ipairs(list) do
							if tostring(v.SlimeId or "") == sid then found = true; break end
						end
					end
					if not found then
						local c = {}
						for k, v in pairs(entry) do c[k] = v end
						if not c.ToolUniqueId or c.ToolUniqueId == "" then
							local gen = nil
							pcall(function() gen = (HttpService and HttpService:GenerateGUID(false)) or (tostring(tick()) .. "-" .. tostring(math.random(1, 1000000))) end)
							c.ToolUniqueId = gen or (tostring(tick()) .. "-" .. tostring(math.random(1, 1000000)))
						end
						table.insert(list, c)
					end
				end
			end
		end
	end

	if prof and prof.inventory and #list == 0 and type(prof.inventory.capturedSlimes) == "table" and #prof.inventory.capturedSlimes > 0 then
		local copy = {}
		for i, v in ipairs(prof.inventory.capturedSlimes) do copy[i] = v end
		return copy
	end

	return list
end

-- Remove worldSlime references (helper)
local function cs_removeWorldSlimeFromProfile(player, slimeId)
	if not slimeId then return end
	local PPS = getPPS()
	if PPS and type(PPS.RemoveInventoryItem) == "function" then
		pcall(function()
			pcall(function() PPS.RemoveInventoryItem(player, "worldSlimes", "SlimeId", slimeId) end)
			pcall(function() PPS.RemoveInventoryItem(player, "worldSlimes", { SlimeId = slimeId }) end)
		end)
	end

	local prof = safe_get_profile(player)
	if prof and prof.inventory and type(prof.inventory.worldSlimes) == "table" then
		local changed = false
		for i = #prof.inventory.worldSlimes, 1, -1 do
			local it = prof.inventory.worldSlimes[i]
			if it and (tostring(it.SlimeId or it.id or it.Id) == tostring(slimeId)) then
				table.remove(prof.inventory.worldSlimes, i)
				changed = true
			end
		end
		if changed then
			pcall(function() sanitizeInventoryOnProfile(prof) end)
			if PPS and type(PPS.SaveNow) == "function" then
				pcall(function() PPS.SaveNow(player, "CapturedSlime_RemoveWorldSlime") end)
			end
		end
	end

	-- Try InventoryService-like modules as fallback (best-effort)
	pcall(function()
		local mod = nil
		local ms = ServerScriptService and ServerScriptService:FindFirstChild("Modules")
		local trySources = { ms, ServerScriptService, ReplicatedStorage }
		for _, src in ipairs(trySources) do
			if not src then
			else
				local inst = src:FindFirstChild("InventoryService") or src:FindFirstChild("InvSvc") or src:FindFirstChild("Inventory")
				if inst and type(inst.IsA) == "function" and inst:IsA("ModuleScript") then
					local ok, m = pcall(function() return require(inst) end)
					if ok and type(m) == "table" then mod = m; break end
				end
			end
		end
		if mod then
			if type(mod.RemoveInventoryItem) == "function" then
				pcall(function() mod.RemoveInventoryItem(player, "worldSlimes", "SlimeId", slimeId) end)
				pcall(function() mod.RemoveInventoryItem(player, "worldSlimes", { SlimeId = slimeId }) end)
			elseif type(mod.RemoveInventoryItemByField) == "function" then
				pcall(function() mod.RemoveInventoryItemByField(player, "worldSlimes", "SlimeId", slimeId) end)
			elseif type(mod.UpdateProfileInventory) == "function" then
				local prof2 = nil
				if type(mod.GetProfileForUser) == "function" then
					local ok2, p2 = pcall(function() return mod.GetProfileForUser(player.UserId) end)
					if ok2 and type(p2) == "table" then prof2 = p2 end
				end
				if prof2 and prof2.inventory and prof2.inventory.worldSlimes then
					for i = #prof2.inventory.worldSlimes, 1, -1 do
						local it = prof2.inventory.worldSlimes[i]
						if it and (tostring(it.SlimeId or it.id or it.Id) == tostring(slimeId)) then
							table.remove(prof2.inventory.worldSlimes, i)
						end
					end
					pcall(function() mod.UpdateProfileInventory(prof2, "worldSlimes", prof2.inventory.worldSlimes) end)
				end
			end
		end
	end)
end

-- Restore helpers: immediate and scheduled restoration of captured-slime tools
-- Replace existing cs_restoreImmediate(...) with this implementation
-- Replace existing cs_restoreImmediate(...) with this implementation
local function cs_restoreImmediate(player, list, backpack)
	cs_dprint(("cs_restoreImmediate entries=%d for player=%s"):format(#list, tostring(player and player.Name or "nil")))
	if not player or not list or #list == 0 then return end
	local created = {}

	for _,entry in ipairs(list) do
		if not entry then
			-- skip nil entries defensively
		else
			if not entry.ToolUniqueId or entry.ToolUniqueId == "" then
				entry.ToolUniqueId = (HttpService and (pcall(function() return HttpService:GenerateGUID(false) end) and HttpService:GenerateGUID(false) or nil)) or tostring(tick()) .. "-" .. tostring(math.random(1,1000000))
			end
			local uid = entry.ToolUniqueId or entry.ToolUid or entry.SlimeId

			local function findByUid(container)
				if not container then return nil end
				for _, it in ipairs(container:GetChildren()) do
					if it and type(it.IsA) == "function" and it:IsA("Tool") then
						local tid = nil
						local ok, v = pcall(function() return it:GetAttribute("ToolUniqueId") end)
						if ok and v and v ~= "" then tid = v end
						if not tid then
							local ok2, v2 = pcall(function() return it:GetAttribute("ToolUid") end)
							if ok2 and v2 and v2 ~= "" then tid = v2 end
						end
						local sid = nil
						local ok3, v3 = pcall(function() return it:GetAttribute("SlimeId") end)
						if ok3 and v3 then sid = v3 end
						if (tid and uid and tostring(tid) == tostring(uid)) or (sid and entry.SlimeId and tostring(sid) == tostring(entry.SlimeId)) then
							return it
						end
					end
				end
				return nil
			end

			local existing = findByUid(backpack) or (player and findByUid(player.Character))
			if not existing and ServerStorage then
				local okSS, desc = pcall(function() return ServerStorage:GetDescendants() end)
				if okSS and type(desc) == "table" then
					for _, s in ipairs(desc) do
						if s and type(s.IsA) == "function" and s:IsA("Tool") then
							local tid = nil
							local ok, v = pcall(function() return s:GetAttribute("ToolUniqueId") end)
							if ok and v and v ~= "" then tid = v end
							if not tid then
								local ok2, v2 = pcall(function() return s:GetAttribute("ToolUid") end)
								if ok2 and v2 and v2 ~= "" then tid = v2 end
							end
							local sid = nil
							local ok3, v3 = pcall(function() return s:GetAttribute("SlimeId") end)
							if ok3 and v3 then sid = v3 end
							if (tid and uid and tostring(tid) == tostring(uid)) or (sid and entry.SlimeId and tostring(sid) == tostring(entry.SlimeId)) then
								existing = s
								break
							end
						end
					end
				end
			end

			if existing then
				pcall(function()
					mark_restored_instance(existing, player.UserId, uid)
					pcall(function() existing.Parent = backpack end)
					pcall(function() EnsureToolVisual(existing) end)
				end)

				-- Diagnostics for reused tool
				pcall(function()
					local debugTool = existing
					task.delay(0.5, function()
						local okP, parent = pcall(function() return debugTool and debugTool.Parent end)
						dprint("[CS Debug]", tostring(debugTool and debugTool.Name), "parent@0.5s =", (okP and (parent and (parent.GetFullName and parent:GetFullName()) or tostring(parent)) or "<err>"))
						local attrs = {}
						for _, k in ipairs({"ToolUniqueId","ToolUid","ServerRestore","PreserveOnServer","RestoreStamp","RecentlyPlacedSaved","OwnerUserId","SlimeId","SlimeItem"}) do
							pcall(function() attrs[k] = (debugTool.GetAttribute and debugTool:GetAttribute(k)) end)
						end
						if HttpService and type(HttpService.JSONEncode) == "function" then
							dprint("[CS Debug] attrs@0.5s:", HttpService:JSONEncode(attrs))
						else
							dprint("[CS Debug] attrs@0.5s:", tostring(attrs))
						end
					end)
					task.delay(1.5, function()
						local okP, parent = pcall(function() return debugTool and debugTool.Parent end)
						dprint("[CS Debug]", tostring(debugTool and debugTool.Name), "parent@1.5s =", (okP and (parent and (parent.GetFullName and parent:GetFullName()) or tostring(parent)) or "<err>"))
						local attrs = {}
						for _, k in ipairs({"ToolUniqueId","ToolUid","ServerRestore","PreserveOnServer","RestoreStamp","RecentlyPlacedSaved","OwnerUserId","SlimeId","SlimeItem"}) do
							pcall(function() attrs[k] = (debugTool.GetAttribute and debugTool:GetAttribute(k)) end)
						end
						if HttpService and type(HttpService.JSONEncode) == "function" then
							dprint("[CS Debug] attrs@1.5s:", HttpService:JSONEncode(attrs))
						else
							dprint("[CS Debug] attrs@1.5s:", tostring(attrs))
						end
					end)
				end)

				table.insert(created, existing)
			else
				local tool = cs_buildTool(entry, player)
				pcall(function()
					mark_restored_instance(tool, player.UserId, uid)
					tool.Parent = backpack
					pcall(function() EnsureToolVisual(tool) end)
				end)

				-- Diagnostics for newly created tool
				pcall(function()
					local debugTool = tool
					task.delay(0.5, function()
						local okP, parent = pcall(function() return debugTool and debugTool.Parent end)
						dprint("[CS Debug]", tostring(debugTool and debugTool.Name), "parent@0.5s =", (okP and (parent and (parent.GetFullName and parent:GetFullName()) or tostring(parent)) or "<err>"))
						local attrs = {}
						for _, k in ipairs({"ToolUniqueId","ToolUid","ServerRestore","PreserveOnServer","RestoreStamp","RecentlyPlacedSaved","OwnerUserId","SlimeId","SlimeItem"}) do
							pcall(function() attrs[k] = (debugTool.GetAttribute and debugTool:GetAttribute(k)) end)
						end
						if HttpService and type(HttpService.JSONEncode) == "function" then
							dprint("[CS Debug] attrs@0.5s:", HttpService:JSONEncode(attrs))
						else
							dprint("[CS Debug] attrs@0.5s:", tostring(attrs))
						end
					end)
					task.delay(1.5, function()
						local okP, parent = pcall(function() return debugTool and debugTool.Parent end)
						dprint("[CS Debug]", tostring(debugTool and debugTool.Name), "parent@1.5s =", (okP and (parent and (parent.GetFullName and parent:GetFullName()) or tostring(parent)) or "<err>"))
						local attrs = {}
						for _, k in ipairs({"ToolUniqueId","ToolUid","ServerRestore","PreserveOnServer","RestoreStamp","RecentlyPlacedSaved","OwnerUserId","SlimeId","SlimeItem"}) do
							pcall(function() attrs[k] = (debugTool.GetAttribute and debugTool:GetAttribute(k)) end)
						end
						if HttpService and type(HttpService.JSONEncode) == "function" then
							dprint("[CS Debug] attrs@1.5s:", HttpService:JSONEncode(attrs))
						else
							dprint("[CS Debug] attrs@1.5s:", tostring(attrs))
						end
					end)
				end)

				table.insert(created, tool)
			end

			if entry.SlimeId then
				pcall(function() cs_removeWorldSlimeFromProfile(player, entry.SlimeId) end)
			end
		end
	end

	local prof = safe_get_profile(player)
	local PPS = getPPS()
	if prof and type(prof) == "table" then
		prof.inventory = prof.inventory or {}
		if not prof.inventory.capturedSlimes or #prof.inventory.capturedSlimes == 0 then
			prof.inventory.capturedSlimes = prof.inventory.capturedSlimes or {}
			for _, entry in ipairs(list) do table.insert(prof.inventory.capturedSlimes, entry) end
			pcall(function() sanitizeInventoryOnProfile(prof) end)
			if PPS and type(PPS.SaveNow) == "function" then
				pcall(function() PPS.SaveNow(player, "GrandInvSer_CapturedRestore") end)
			end
		else
			local seen = {}
			for _, e in ipairs(prof.inventory.capturedSlimes or {}) do
				local k = tostring(e.ToolUniqueId or e.ToolUid or e.SlimeId or "")
				if k ~= "" then seen[k] = true end
			end
			local added = false
			for _, entry in ipairs(list) do
				local k = tostring(entry.ToolUniqueId or entry.ToolUid or entry.SlimeId or "")
				if k ~= "" then
					if not seen[k] then
						table.insert(prof.inventory.capturedSlimes, entry)
						seen[k] = true
						added = true
					end
				else
					local sid = tostring(entry.SlimeId or "")
					local exists = false
					if sid ~= "" then
						for _, e in ipairs(prof.inventory.capturedSlimes) do
							if tostring(e.SlimeId or "") == sid then exists = true; break end
						end
					end
					if not exists then
						table.insert(prof.inventory.capturedSlimes, entry)
						added = true
					end
				end
			end
			if added then
				pcall(function() sanitizeInventoryOnProfile(prof) end)
				if PPS and type(PPS.SaveNow) == "function" then
					pcall(function() PPS.SaveNow(player, "GrandInvSer_CapturedMerge") end)
				end
			end
		end
	end
end

-- CapturedSlime Restore (robust, race-safe, deferred parent, correct attributes)
local function cs_restore(player, list)
	if not list or #list == 0 then return end
	if player then
		waitForInventoryReady(player)
	end
	-- Immediate restore if Backpack available
	local backpack = player and player:FindFirstChildOfClass("Backpack")
	if backpack then
		cs_restoreImmediate(player, list, backpack)
		return
	end

	-- Otherwise, defer restore until Backpack is present
	local function insertUnique(dest, entry)
		if not dest or type(dest) ~= "table" then return end
		local keyA = tostring(entry.ToolUniqueId or entry.ToolUid or entry.SlimeId or "")
		for _, v in ipairs(dest) do
			local keyB = tostring(v.ToolUniqueId or v.ToolUid or v.SlimeId or "")
			if keyA ~= "" and keyB ~= "" and keyA == keyB then return end
			if (keyA == "" or keyB == "") and entry.SlimeId and v.SlimeId and tostring(entry.SlimeId) == tostring(v.SlimeId) then return end
		end
		table.insert(dest, entry)
	end

	local uid = player and tonumber(player.UserId)
	if uid then
		pendingRestores[uid] = pendingRestores[uid] or {}
		pendingRestores[uid].cs = pendingRestores[uid].cs or {}
		for _, e in ipairs(list) do insertUnique(pendingRestores[uid].cs, e) end
		pendingRestores[uid].timeout = os.time() + (PENDING_DEFAULT_TIMEOUT or 60)
		cs_dprint(("Scheduled cs restore for uid=%s entries=%d"):format(tostring(uid), #pendingRestores[uid].cs))
		local online = Players and Players:GetPlayerByUserId(uid)
		if online then
			pcall(function() processPendingForPlayer(online) end)
		end
		return
	end

	local prof = safe_get_profile(player)
	local pid = prof and getPersistentIdFor(prof) or nil
	if pid then
		pendingRestoresByPersistentId[pid] = pendingRestoresByPersistentId[pid] or {}
		pendingRestoresByPersistentId[pid].cs = pendingRestoresByPersistentId[pid].cs or {}
		for _, e in ipairs(list) do insertUnique(pendingRestoresByPersistentId[pid].cs, e) end
		pendingRestoresByPersistentId[pid].timeout = os.time() + (PENDING_DEFAULT_TIMEOUT or 60)
		cs_dprint(("Scheduled cs restore under pid=%s entries=%d"):format(tostring(pid), #pendingRestoresByPersistentId[pid].cs))
		for _,pl in ipairs(Players and Players:GetPlayers() or {}) do
			local ok, plPid = pcall(function() return getPersistentIdFor(pl) end)
			if ok and plPid and tonumber(plPid) == tonumber(pid) then
				pcall(function() processPendingForPlayer(pl) end)
				break
			end
		end
		return
	end

	local keyName = player and player.Name or (prof and (prof.playerName or prof.name))
	if keyName and type(keyName) == "string" and keyName ~= "" then
		pendingRestoresByName[keyName] = pendingRestoresByName[keyName] or {}
		pendingRestoresByName[keyName].cs = pendingRestoresByName[keyName].cs or {}
		for _, e in ipairs(list) do insertUnique(pendingRestoresByName[keyName].cs, e) end
		pendingRestoresByName[keyName].timeout = os.time() + (PENDING_DEFAULT_TIMEOUT or 60)
		cs_dprint(("Scheduled cs restore by name=%s entries=%d"):format(tostring(keyName), #pendingRestoresByName[keyName].cs))
		for _, pl in ipairs(Players and Players:GetPlayers() or {}) do
			if pl.Name == keyName then
				pcall(function() processPendingForPlayer(pl) end)
				break
			end
		end
		return
	end

	cs_dprint("cs_restore: could not schedule captured slime restore; no uid/pid/name determined")
end

-- Export helpers
GrandInventorySerializer._internal = GrandInventorySerializer._internal or {}
GrandInventorySerializer._internal.CapturedSlime = GrandInventorySerializer._internal.CapturedSlime or {}
GrandInventorySerializer._internal.CapturedSlime.EnsureToolVisual = EnsureToolVisual
GrandInventorySerializer._internal.CapturedSlime.BuildVisualFromTool = BuildVisualFromTool

cs_dprint("CapturedSlime serializer section loaded (updated).")
-- End of captured-slime section



-- Replace the existing local function processPendingForPlayer(player) with this version.
-- Adds verbose debug traces to help diagnose missing pending restores.

-- Replace the existing local function processPendingForPlayer(player) with this version.
-- Adds support for pending.cs (captured slimes) merging + immedia-- processPendingForPlayer (replacement)
processPendingForPlayer = function(player)

	if not player or not player.UserId then
		dprint("[processPendingForPlayer] invalid player argument")
		return
	end
	local uid = tonumber(player.UserId)
	local nameKey = player.Name
	-- Snapshot counts for quick overview
	local function countQueueEntries(q)
		if not q or type(q) ~= "table" then return 0 end
		local c = 0
		for _,v in pairs(q) do
			c = c + 1
		end
		return c
	end

	-- Log entry
	dprint(("[processPendingForPlayer] start uid=%s name=%s pendingUidKeys=%d pendingNameKeys=%d pendingPidKeys=%d"):format(
		tostring(uid),
		tostring(nameKey),
		countQueueEntries(pendingRestores),
		countQueueEntries(pendingRestoresByName),
		countQueueEntries(pendingRestoresByPersistentId)
		))

	local pending = pendingRestores[uid]
	local byName = pendingRestoresByName[nameKey]
	if byName then
		dprint(("[processPendingForPlayer] found pendingRestoresByName[%s] (et=%d ft=%d we=%d cs=%d) - merging into pendingRestores[%s]"):format(
			tostring(nameKey),
			(byName.et and #byName.et) or 0,
			(byName.ft and #byName.ft) or 0,
			(byName.we and #byName.we) or 0,
			(byName.cs and #byName.cs) or 0,
			tostring(uid)
			))
		pending = pending or {}
		if byName.et and #byName.et > 0 then
			pending.et = pending.et or {}
			for _,v in ipairs(byName.et) do table.insert(pending.et, v) end
		end
		if byName.ft and #byName.ft > 0 then
			pending.ft = pending.ft or {}
			for _,v in ipairs(byName.ft) do table.insert(pending.ft, v) end
		end
		if byName.we and #byName.we > 0 then
			pending.we = pending.we or {}
			for _,v in ipairs(byName.we) do table.insert(pending.we, v) end
		end
		if byName.cs and #byName.cs > 0 then
			pending.cs = pending.cs or {}
			for _,v in ipairs(byName.cs) do table.insert(pending.cs, v) end
		end
		pending.timeout = math.max(pending.timeout or 0, byName.timeout or 0)
		pendingRestoresByName[nameKey] = nil
	end

	local pid = getPersistentIdFor(player)
	if pid then
		local byPid = pendingRestoresByPersistentId[pid]
		if byPid then
			dprint(("[processPendingForPlayer] found pendingRestoresByPersistentId[%s] (et=%d ft=%d we=%d cs=%d) - merging into pendingRestores[%s]"):format(
				tostring(pid),
				(byPid.et and #byPid.et) or 0,
				(byPid.ft and #byPid.ft) or 0,
				(byPid.we and #byPid.we) or 0,
				(byPid.cs and #byPid.cs) or 0,
				tostring(uid)
				))
			pending = pending or {}
			if byPid.et and #byPid.et > 0 then
				pending.et = pending.et or {}
				for _,v in ipairs(byPid.et) do table.insert(pending.et, v) end
			end
			if byPid.ft and #byPid.ft > 0 then
				pending.ft = pending.ft or {}
				for _,v in ipairs(byPid.ft) do table.insert(pending.ft, v) end
			end
			if byPid.we and #byPid.we > 0 then
				pending.we = pending.we or {}
				for _,v in ipairs(byPid.we) do table.insert(pending.we, v) end
			end
			if byPid.cs and #byPid.cs > 0 then
				pending.cs = pending.cs or {}
				for _,v in ipairs(byPid.cs) do table.insert(pending.cs, v) end
			end
			pending.timeout = math.max(pending.timeout or 0, byPid.timeout or 0)
			pendingRestoresByPersistentId[pid] = nil
		end
	end

	if not pending then
		dprint(("[processPendingForPlayer] no pending queue for uid=%s (name=%s) - nothing to do"):format(tostring(uid), tostring(nameKey)))
		return
	end

	-- Summarize pending contents
	dprint(("[processPendingForPlayer] merged pending for uid=%s name=%s -> et=%d ft=%d we=%d cs=%d timeout=%s"):format(
		tostring(uid),
		tostring(nameKey),
		(pending.et and #pending.et) or 0,
		(pending.ft and #pending.ft) or 0,
		(pending.we and #pending.we) or 0,
		(pending.cs and #pending.cs) or 0,
		tostring(pending.timeout)
		))

	-- Try to perform restores while waiting for Backpack to become available
	local deadline = os.clock() + math.max(10, PENDING_DEFAULT_TIMEOUT)
	while os.clock() < deadline do
		if not player.Parent then
			dprint(("[processPendingForPlayer] player %s left before pending processing (uid=%s)"):format(tostring(nameKey), tostring(uid)))
			break
		end
		local backpack = player:FindFirstChildOfClass("Backpack")
		if backpack then
			-- Added traces: log what will be applied
			dprint(("[processPendingForPlayer] Backpack ready for uid=%s (name=%s). Applying pending: et=%d ft=%d we=%d cs=%d"):format(
				tostring(uid),
				tostring(nameKey),
				(pending.et and #pending.et) or 0,
				(pending.ft and #pending.ft) or 0,
				(pending.we and #pending.we) or 0,
				(pending.cs and #pending.cs) or 0
				))
			if pending.et and #pending.et > 0 then
				pcall(function() et_restoreImmediate(player, pending.et, backpack) end)
			end
			if pending.ft and #pending.ft > 0 then
				pcall(function() ft_restoreImmediate(player, pending.ft, backpack) end)
			end
			if pending.we and #pending.we > 0 then
				-- world eggs don't require Backpack but keep call for completeness
				pcall(function() we_restore(player, pending.we) end)
			end
			if pending.cs and #pending.cs > 0 then
				-- restore captured slime tools into backpack now
				pcall(function() cs_restoreImmediate(player, pending.cs, backpack) end)
			end
			-- Clear the uid-keyed pending bucket after attempting to apply.
			pendingRestores[uid] = nil
			dprint(("Performed pending restores for userId=%s (name=%s)"):format(tostring(uid), tostring(nameKey)))
			return
		end
		task.wait(0.25)
	end

	-- If we exit loop without applying, report and possibly drop if timed out
	if pending.timeout and os.time() > pending.timeout then
		pendingRestores[uid] = nil
		dprint(("Dropped pending restores for userId=%s due to timeout"):format(tostring(uid)))
	else
		dprint(("Backpack not ready yet for userId=%s; will retry on next CharacterAdded"):format(tostring(uid)))
	end
end




-- Insert immediately AFTER the local function processPendingForPlayer(player) ... end
-- (place this before the Players.PlayerAdded:Connect(...) block)

-- Public helpers: ProcessPendingForPlayer, ProcessPendingForUserId, DumpPendingRestores, ProcessPendingForPersistentId, ProcessPendingForName
function GrandInventorySerializer.ProcessPendingForPlayer(player)
	if not player then return false end
	local ok, err = pcall(function()
		if type(processPendingForPlayer) == "function" then
			processPendingForPlayer(player)
		end
	end)
	if not ok then
		dprint("ProcessPendingForPlayer error:", tostring(err))
	end
	return ok
end

function GrandInventorySerializer.ProcessPendingForUserId(userId)
	if not userId then return false end
	local uid = tonumber(userId)
	if not uid then return false end
	local pl = Players:GetPlayerByUserId(uid)
	if pl then
		return GrandInventorySerializer.ProcessPendingForPlayer(pl)
	end
	return false
end

function GrandInventorySerializer.DumpPendingRestores()
	local function shallowCopyTable(t)
		if not t then return {} end
		local out = {}
		for k,v in pairs(t) do out[k] = v end
		return out
	end
	local snap = {
		byUserId = shallowCopyTable(pendingRestores),
		byName = shallowCopyTable(pendingRestoresByName),
		byPersistentId = shallowCopyTable(pendingRestoresByPersistentId),
	}

	local function countEntries(tbl)
		if not tbl then return 0 end
		local c = 0
		for k,v in pairs(tbl) do
			c = c + 1
		end
		return c
	end
	dprint(("DumpPendingRestores: pending userId keys=%d name keys=%d persistentId keys=%d"):format(
		countEntries(snap.byUserId),
		countEntries(snap.byName),
		countEntries(snap.byPersistentId)
		))

	local function printQueueSummary(prefix, q)
		if not q then return end
		for key, bundle in pairs(q) do
			if type(bundle) == "table" then
				local et = (bundle.et and #bundle.et) or 0
				local ft = (bundle.ft and #bundle.ft) or 0
				local we = (bundle.we and #bundle.we) or 0
				dprint(("%s key=%s (et=%d ft=%d we=%d timeout=%s)"):format(prefix, tostring(key), et, ft, we, tostring(bundle.timeout)))
			else
				dprint(("%s key=%s (non-table value)"):format(prefix, tostring(key)))
			end
		end
	end

	printQueueSummary("ByUserId:", snap.byUserId)
	printQueueSummary("ByName:", snap.byName)
	printQueueSummary("ByPersistentId:", snap.byPersistentId)

	return snap
end

-- Try to process pending restores for a persistentId (will look for an online player with that persistentId and call ProcessPendingForPlayer)
function GrandInventorySerializer.ProcessPendingForPersistentId(persistentId)
	if not persistentId then
		dprint("ProcessPendingForPersistentId called with nil")
		return false
	end
	local pid = tonumber(persistentId)
	if not pid then
		dprint("ProcessPendingForPersistentId: invalid persistentId", tostring(persistentId))
		return false
	end

	for _, pl in ipairs(Players:GetPlayers()) do
		local ok, ppid = pcall(function() return getPersistentIdFor(pl) end)
		if ok and ppid and tonumber(ppid) == pid then
			dprint("ProcessPendingForPersistentId: found online player", pl.Name, "-> calling ProcessPendingForPlayer")
			return GrandInventorySerializer.ProcessPendingForPlayer(pl)
		end
	end

	if pendingRestoresByPersistentId[pid] then
		dprint("ProcessPendingForPersistentId: no online player found, but pending queue exists for pid=", pid)
		return false
	end

	dprint("ProcessPendingForPersistentId: no pending queue and no online player for pid=", pid)
	return false
end

-- Try to process pending restores for a pending name key (will look up the player and call ProcessPendingForPlayer)
function GrandInventorySerializer.ProcessPendingForName(nameKey)
	if not nameKey or type(nameKey) ~= "string" then
		dprint("ProcessPendingForName: invalid nameKey")
		return false
	end
	for _, pl in ipairs(Players:GetPlayers()) do
		if pl.Name == nameKey then
			dprint("ProcessPendingForName: found player", nameKey, "-> calling ProcessPendingForPlayer")
			return GrandInventorySerializer.ProcessPendingForPlayer(pl)
		end
	end

	if pendingRestoresByName[nameKey] then
		dprint("ProcessPendingForName: no online player found, but pending queue exists for nameKey=", nameKey)
		return false
	end

	dprint("ProcessPendingForName: no pending queue and no online player for nameKey=", nameKey)
	return false
end






Players.PlayerAdded:Connect(function(pl)
	pl.CharacterAdded:Connect(function() processPendingForPlayer(pl) end)
	task.defer(function() processPendingForPlayer(pl) end)
end)
for _,pl in ipairs(Players:GetPlayers()) do
	pl.CharacterAdded:Connect(function() processPendingForPlayer(pl) end)
	task.defer(function() processPendingForPlayer(pl) end)
end
Players.PlayerRemoving:Connect(function(pl)
	if pl and pl.UserId then pendingRestores[pl.UserId] = nil end
end)

local function ensureList(value, name, playerOrProfile)
	if type(value) == "table" then return value end
	dprint(("[Serialize][Coerce] Serializer '%s' returned %s for %s - coercing to empty list"):format(
		tostring(name),
		tostring(type(value)),
		tostring(playerOrProfile and (playerOrProfile.Name or playerOrProfile.playerName or playerOrProfile.name or tostring(playerOrProfile)) or "nil")
		))
	return {}
end

local function _normalize_call_args(vargs)
	local first = vargs[1]
	if first == GrandInventorySerializer then
		return vargs[2], vargs[3]
	end
	return vargs[1], vargs[2]
end
-- Corrected instanceToTable helper for GrandInventorySerializer
-- Fixes syntax error when checking/calling FindFirstChildWhichIsA.

-- instanceToTable + convertListEntriesToSerializable (helpers used by Serialize)
local function instanceToTable(inst)
	if not inst then return nil end
	local out = {}

	-- Attributes (safe)
	pcall(function()
		if inst.GetAttributes then
			for k, v in pairs(inst:GetAttributes()) do
				if out[k] == nil then out[k] = v end
			end
		end
	end)

	-- Common child value names that serializers expect
	pcall(function()
		local commonKeys = {
			"SlimeId","EggId","id","Id",
			"Breed","GrowthProgress","Timestamp","OwnerUserId","Size",
			"EyeColor","AccentColor","BodyColor",
			"ToolUniqueId","ToolUid","UID","ToolId","fid","FoodId"
		}
		for _, name in ipairs(commonKeys) do
			local c = inst:FindFirstChild(name)
			if c and c.Value ~= nil then
				if out[name] == nil then out[name] = c.Value end
			end
		end
	end)

	-- Try to capture a position if present (PrimaryPart or first BasePart)
	pcall(function()
		local p
		if inst.PrimaryPart and inst.PrimaryPart.Position then
			p = inst.PrimaryPart.Position
		else
			if inst.FindFirstChildWhichIsA then
				local bp = inst:FindFirstChildWhichIsA("BasePart")
				if bp then p = bp.Position end
			end
		end
		if p then
			if not out.Position then
				out.Position = { x = p.X, y = p.Y, z = p.Z }
			end
		end
	end)

	-- If name looks like a GUID and we don't already have an id, use it
	pcall(function()
		if (not out.id and not out.SlimeId and not out.EggId) and tostring(inst.Name):match("[A-Fa-f0-9%-]+") then
			out.id = tostring(inst.Name)
		end
	end)

	if not out.id then
		if out.SlimeId then out.id = out.SlimeId end
		if not out.id and out.EggId then out.id = out.EggId end
	end

	if next(out) then return out end
	return nil
end

local function convertListEntriesToSerializable(list)
	if not list or type(list) ~= "table" then return {} end
	local out = {}
	for _, entry in ipairs(list) do
		local t = type(entry)
		if t == "userdata" then
			local tbl = instanceToTable(entry)
			if tbl then
				table.insert(out, tbl)
			else
				local fallback = {}
				if entry and entry.Name then fallback.id = tostring(entry.Name) end
				table.insert(out, fallback)
			end
		else
			table.insert(out, entry)
		end
	end
	return out
end

local function debugSerialize(player, snapshot, tag)
	local name = player and (player.Name or "<nil>") or "<nil>"
	local uid  = player and (player.UserId or 0) or 0
	local cs = snapshot and snapshot.capturedSlimes and #snapshot.capturedSlimes or 0
	local et = snapshot and snapshot.eggTools and #snapshot.eggTools or 0
	local we = snapshot and snapshot.worldEggs and #snapshot.worldEggs or 0
	-- safe formatting (tonumber may return nil; tostring used for name)
	pcall(function()
		print(string.format("[GrandInvDebug][Serialize%s] player=%s uid=%d capturedSlimes=%d eggTools=%d worldEggs=%d time=%s",
			tag or "", tostring(name), tonumber(uid) or 0, tonumber(cs) or 0, tonumber(et) or 0, tonumber(we) or 0, os.date("%X")))
	end)
	-- If player present, also inspect Backpack runtime state quickly
	if player and type(player.FindFirstChildOfClass) == "function" then
		local ok, bp = pcall(function() return player:FindFirstChildOfClass("Backpack") end)
		if ok and bp then
			local found = 0
			for _,c in ipairs(bp:GetChildren()) do
				if type(c.IsA) == "function" and c:IsA("Tool") then
					local ok2, isSlime = pcall(function() return c:GetAttribute("SlimeItem") end)
					if ok2 and isSlime then found = found + 1 end
				end
			end
			if found > 0 and (cs == 0) then
				pcall(function()
					print(string.format("[GrandInvDebug][Serialize][MISMATCH] player=%s uid=%d BackpackSlimeTools=%d snapshotCapturedSlimes=%d",
						tostring(name), tonumber(uid) or 0, found, cs))
				end)
			end
		end
	end
end

-- GrandInventorySerializer.Serialize(...) replacement (coercion + prefer profile lists)
function GrandInventorySerializer.Serialize(...)
	local a1, a2 = _normalize_call_args({ ... })
	-- Helper to copy inventory lists from profile into out when serializer returned empty
	local function prefer_profile_lists_into_out(inv, outTbl)
		if not inv or type(inv) ~= "table" then return end
		-- eggTools
		if outTbl.et and #outTbl.et == 0 and inv.eggTools and #inv.eggTools > 0 then
			local copy = {}
			for i, v in ipairs(inv.eggTools) do copy[i] = v end
			outTbl.et = copy
		end
		-- foodTools
		if outTbl.ft and #outTbl.ft == 0 and inv.foodTools and #inv.foodTools > 0 then
			local copy = {}
			for i, v in ipairs(inv.foodTools) do copy[i] = v end
			outTbl.ft = copy
		end
		-- worldEggs
		if outTbl.we and #outTbl.we == 0 and inv.worldEggs and #inv.worldEggs > 0 then
			local copy = {}
			for i, v in ipairs(inv.worldEggs) do copy[i] = v end
			outTbl.we = copy
		end
		-- worldSlimes
		if outTbl.ws and #outTbl.ws == 0 and inv.worldSlimes and #inv.worldSlimes > 0 then
			local copy = {}
			for i, v in ipairs(inv.worldSlimes) do copy[i] = v end
			outTbl.ws = copy
		end
		-- capturedSlimes
		if outTbl.cs and #outTbl.cs == 0 and inv.capturedSlimes and #inv.capturedSlimes > 0 then
			local copy = {}
			for i, v in ipairs(inv.capturedSlimes) do copy[i] = v end
			outTbl.cs = copy
		end
	end

	-- Boolean-first branch: global/final snapshot (no player provided)
	if type(a1) == "boolean" then
		local isFinal = a1 and true or false
		local prof = nil
		local out = {}
		local ok, res = pcall(function() return ws_serialize(nil, isFinal, prof) end)
		out.ws = ensureList(convertListEntriesToSerializable((ok and res) and res or {}), "ws", nil)
		ok, res = pcall(function() return we_serialize(nil, isFinal, prof) end)
		out.we = ensureList(convertListEntriesToSerializable((ok and res) and res or {}), "we", nil)
		ok, res = pcall(function() return et_serialize(nil, isFinal, prof) end)
		out.et = ensureList(convertListEntriesToSerializable((ok and res) and res or {}), "et", nil)
		ok, res = pcall(function() return ft_serialize(nil, isFinal, prof) end)
		out.ft = ensureList(convertListEntriesToSerializable((ok and res) and res or {}), "ft", nil)
		ok, res = pcall(function() return cs_serialize(nil, isFinal, prof) end)
		out.cs = ensureList(convertListEntriesToSerializable((ok and res) and res or {}), "cs", nil)

		local function outIsAllEmpty(tbl)
			if not tbl then return true end
			local counts = 0
			counts = counts + ((tbl.ws and #tbl.ws) or 0)
			counts = counts + ((tbl.we and #tbl.we) or 0)
			counts = counts + ((tbl.et and #tbl.et) or 0)
			counts = counts + ((tbl.ft and #tbl.ft) or 0)
			counts = counts + ((tbl.cs and #tbl.cs) or 0)
			return counts == 0
		end

		if outIsAllEmpty(out) then
			pcall(function()
				for _, pl in ipairs(Players:GetPlayers()) do
					local okp, candidate = pcall(function() return safe_get_profile(pl) end)
					if okp and type(candidate) == "table" and candidate.inventory then
						prefer_profile_lists_into_out(candidate.inventory, out)
						prof = candidate
						break
					end
				end
			end)
		end

		pcall(function()
			debugSerialize(nil, { capturedSlimes = out.cs, eggTools = out.et, worldEggs = out.we }, "[NoPlayer]")
		end)

		if outIsAllEmpty(out) and prof and prof.inventory then
			local inv = prof.inventory
			local summary = ("profileDetected inventory counts: ws=%d we=%d et=%d ft=%d cs=%d"):format(
				(#(inv.worldSlimes or {})), (#(inv.worldEggs or {})), (#(inv.eggTools or {})), (#(inv.foodTools or {})), (#(inv.capturedSlimes or {}))
			)
			dprint("[Serialize][Warning] serializers returned empty for final/global snapshot but authoritative profile exists - " .. summary)
		end

		return out
	end

	-- Player/profile path
	local player, profile, isFinal = resolvePlayerAndProfile(a1, a2)
	isFinal = not not isFinal
	local prof = profile or safe_get_profile(player)
	if isFinal and not prof and player then
		local p = safe_wait_for_profile(player, 2)
		if p then prof = p; dprint("[Serialize] WaitForProfile returned profile for", tostring(player and player.Name or "unknown")) end
	end

	local out = {}
	local ok, res
	ok, res = pcall(function() return ws_serialize(player, isFinal, prof) end)
	out.ws = ensureList(convertListEntriesToSerializable((ok and res) and res or {}), "ws", player)
	ok, res = pcall(function() return we_serialize(player, isFinal, prof) end)
	out.we = ensureList(convertListEntriesToSerializable((ok and res) and res or {}), "we", player)
	ok, res = pcall(function() return et_serialize(player, isFinal, prof) end)
	out.et = ensureList(convertListEntriesToSerializable((ok and res) and res or {}), "et", player)
	ok, res = pcall(function() return ft_serialize(player, isFinal, prof) end)
	out.ft = ensureList(convertListEntriesToSerializable((ok and res) and res or {}), "ft", player)
	ok, res = pcall(function() return cs_serialize(player, isFinal, prof) end)
	out.cs = ensureList(convertListEntriesToSerializable((ok and res) and res or {}), "cs", player)

	-- If profile present and this is the final snapshot, prefer profile-stored lists when serializers returned empty
	if isFinal and prof and type(prof) == "table" and prof.inventory then
		prefer_profile_lists_into_out(prof.inventory, out)
	end

	pcall(function()
		debugSerialize(player, { capturedSlimes = out.cs, eggTools = out.et, worldEggs = out.we }, (isFinal and "[Final]" or "[Runtime]"))
	end)

	return out
end


-- Replace the existing GrandInventorySerializer.Restore(...) function with this version.
-- Adds diagnostic dprint() statements at all points where pending restores are scheduled
-- so we can observe why a restore may not be applied (which key it was stored under).
-- Replacement GrandInventorySerializer.Restore(...) that keeps original scheduling behavior
-- but attempts to immediately process pending restores when we can resolve an online player.
-- Paste this in place of the existing Restore(...) implementation.

-- GrandInventorySerializer.Restore(...) replacement
function GrandInventorySerializer.Restore(...)
	local a1, a2 = _normalize_call_args({ ... })
	local function shortSummaryOfArg(x)
		local t = type(x)
		if t == "table" then
			local k = ""
			local c = 0
			for kk,_ in pairs(x) do
				c = c + 1
				k = k .. tostring(kk)
				if c >= 6 then break end
				k = k .. ","
			end
			local len = (type(x)=="table" and #x) or 0
			return ("table(keys=%d sample=%s)"):format(len, k)
		else
			return tostring(x)
		end
	end
	dprint(("[Restore][RawArgs] a1=%s a2=%s"):format(shortSummaryOfArg(a1), shortSummaryOfArg(a2)))
	if type(a1) == "boolean" then return end
	local callerName = nil
	if type(a1) == "string" and a1 ~= "" then callerName = a1 end
	if not callerName and type(a2) == "string" and a2 ~= "" then callerName = a2 end
	if not callerName then
		local function extractNameFromProfileLike(t)
			if type(t) ~= "table" then return nil end
			local fields = { "playerName", "name", "player", "username" }
			for _,f in ipairs(fields) do
				local v = t[f]
				if type(v) == "string" and v ~= "" then return v end
			end
			return nil
		end
		callerName = extractNameFromProfileLike(a1) or extractNameFromProfileLike(a2)
	end
	local player, profile, isFinal = resolvePlayerAndProfile(a1, a2)
	if not profile then
		if type(a1) == "table" and a1.inventory ~= nil then profile = a1 end
		if not profile and type(a2) == "table" and a2.inventory ~= nil then profile = a2 end
	end
	if not profile then
		if type(a1) == "table" then
			local uidCand = a1.userId or a1.UserId or a1.id or a1.Id
			if uidCand then
				local profTry = safe_get_profile(uidCand)
				if profTry then
					profile = profTry
					dprint(("Resolved profile via safe_get_profile for passed profile-like table userId=%s"):format(tostring(uidCand)))
				else
					profile = a1
					dprint(("Accepted passed profile-like table (userId=%s) even though inventory absent"):format(tostring(uidCand)))
				end
			end
		end
		if not profile and type(a2) == "table" then
			local uidCand = a2.userId or a2.UserId or a2.id or a2.Id
			if uidCand then
				local profTry = safe_get_profile(uidCand)
				if profTry then
					profile = profTry
					dprint(("Resolved profile via safe_get_profile for passed profile-like table userId=%s (arg2)"):format(tostring(uidCand)))
				else
					profile = a2
					dprint(("Accepted passed profile-like table (userId=%s) as profile-like (arg2)"):format(tostring(uidCand)))
				end
			end
		end
	end
	if not profile and callerName then
		dprint(("No profile yet; attempting short safe_wait_for_profile for callerName='%s'"):format(tostring(callerName)))
		local profTry = safe_wait_for_profile(callerName, 1.5)
		if profTry then
			profile = profTry
			dprint(("safe_wait_for_profile resolved profile for name='%s'"):format(tostring(callerName)))
			if type(profile) == "table" and profile.userId then
				local maybePlayer = Players:GetPlayerByUserId(tonumber(profile.userId))
				if maybePlayer then player = maybePlayer end
			end
		else
			local ok, uid = pcall(function() return Players:GetUserIdFromNameAsync(callerName) end)
			if ok and uid and tonumber(uid) then
				local profTry2 = safe_wait_for_profile(tonumber(uid), 1.0)
				if profTry2 then
					profile = profTry2
					local maybePlayer = Players:GetPlayerByUserId(tonumber(uid))
					if maybePlayer then player = maybePlayer end
				end
			end
		end
	end
	local payload = nil
	if type(a1) == "table" and (a1.ws ~= nil or a1.we ~= nil or a1.et ~= nil or a1.ft ~= nil or a1.cs ~= nil) then
		payload = a1
	elseif type(a2) == "table" and (a2.ws ~= nil or a2.we ~= nil or a2.et ~= nil or a2.ft ~= nil or a2.cs ~= nil) then
		payload = a2
	end
	if not payload or type(payload) ~= "table" then
		profile = profile or (player and safe_get_profile(player))
		if not profile then
			local p = safe_wait_for_profile(player or a1 or a2, 2)
			if p then profile = p end
		end
		if profile and type(profile) == "table" and profile.inventory then
			local inv = profile.inventory
			local hasInv = (inv.eggTools and #inv.eggTools>0) or (inv.foodTools and #inv.foodTools>0)
				or (inv.worldEggs and #inv.worldEggs>0) or (inv.worldSlimes and #inv.worldSlimes>0) or (inv.capturedSlimes and #inv.capturedSlimes>0)
			if hasInv then
				payload = { ws = inv.worldSlimes or {}, we = inv.worldEggs or {}, et = inv.eggTools or {}, ft = inv.foodTools or {}, cs = inv.capturedSlimes or {} }
			else
				return
			end
		else
			return
		end
	end
	payload.ws = (type(payload.ws)=="table" and payload.ws) or {}
	payload.we = (type(payload.we)=="table" and payload.we) or {}
	payload.et = (type(payload.et)=="table" and payload.et) or {}
	payload.ft = (type(payload.ft)=="table" and payload.ft) or {}
	payload.cs = (type(payload.cs)=="table" and payload.cs) or {}
	local function safeCount(t) if not t or type(t)~="table" then return 0 end return #t end

	-- Diagnostic helpers: sample a couple of entries for logs
	local function sampleFirstN(tbl, n)
		n = n or 2
		if type(tbl) ~= "table" then return {} end
		local out = {}
		local i = 0
		for _,v in ipairs(tbl) do
			i = i + 1
			out[i] = v
			if i >= n then break end
		end
		return out
	end

	dprint(("payload counts - ws=%d we=%d et=%d ft=%d cs=%d"):format(safeCount(payload.ws), safeCount(payload.we), safeCount(payload.et), safeCount(payload.ft), safeCount(payload.cs)))
	if safeCount(payload.we) > 0 then
		local s = sampleFirstN(payload.we, 2)
		pcall(function() dprint(("[Restore][Sample] we[1..2]=%s"):format(tostring(s[1])..","..tostring(s[2] or "<nil>"))) end)
	end
	if safeCount(payload.et) > 0 then
		local s = sampleFirstN(payload.et, 2)
		pcall(function() dprint(("[Restore][Sample] et[1..2]=%s"):format(tostring(s[1])..","..tostring(s[2] or "<nil>"))) end)
	end

	-- Normalization helper: ensure worldEgg entries contain canonical fields (eggId,id,HatchAt,HatchTime,PlacedAt,OwnerUserId) and defensive restore flags
	local function normalizeWorldEggEntry(e)
		if not e or type(e) ~= "table" then return e end
		-- Canonical id fields
		local eid = e.eggId or e.id or e.EggId or e.EggID or e.Id or e.ID
		if eid then eid = tostring(eid) else eid = HttpService and HttpService:GenerateGUID(false) or tostring(os.time()) end
		e.eggId = e.eggId or e.id or e.EggId or tostring(eid)
		e.id = e.id or e.eggId

		-- Owner
		local owner = e.OwnerUserId or e.ownerUserId or e.owner or e.userId or e.UserId or e.playerId
		if owner then owner = tonumber(owner) end
		if owner and owner <= 0 then owner = nil end
		if owner then e.OwnerUserId = tonumber(owner) end

		-- PlacedAt
		local placedAt = e.placedAt or e.PlacedAt or e.cr or e.placed_at
		placedAt = tonumber(placedAt) or nil
		if placedAt then e.PlacedAt = placedAt end

		-- HatchTime and HatchAt normalization
		local hatchTime = e.hatchTime or e.ht or e.HatchTime
		hatchTime = tonumber(hatchTime) or nil
		if hatchTime then e.HatchTime = hatchTime end

		local hatchAt = e.hatchAt or e.ha or e.HatchAt
		hatchAt = tonumber(hatchAt) or nil
		-- Compute HatchAt from available info
		if not hatchAt then
			if placedAt and hatchTime then
				hatchAt = placedAt + hatchTime
			elseif hatchTime then
				hatchAt = os.time() + hatchTime
			end
		end

		-- If we still don't have HatchAt, try to find an existing model in Workspace to copy its HatchAt
		if not hatchAt and eid then
			local found = nil
			for _,m in ipairs(Workspace:GetDescendants()) do
				if m:IsA("Model") then
					local mid = nil
					pcall(function() mid = m:GetAttribute("EggId") end)
					if mid and tostring(mid) == tostring(eid) then
						found = m
						break
					end
				end
			end
			if found then
				local ok, fromAttr = pcall(function() return tonumber(found:GetAttribute("HatchAt")) end)
				if ok and fromAttr and tonumber(fromAttr) then
					hatchAt = tonumber(fromAttr)
					-- if HatchTime missing, try to infer it from placedAt
					if not hatchTime then
						local ok2, ft = pcall(function() return tonumber(found:GetAttribute("HatchTime")) end)
						if ok2 and ft then hatchTime = tonumber(ft) end
					end
				end
			end
		end

		-- Final fallbacks
		if not hatchAt then
			-- choose a conservative default hatchTime if missing (avoid extremely long or immediate expiry)
			hatchTime = hatchTime or 90
			hatchAt = os.time() + hatchTime
			e.HatchTime = e.HatchTime or hatchTime
		end

		e.HatchAt = hatchAt
		e.HatchTime = e.HatchTime or hatchTime
		e.PlacedAt = e.PlacedAt or placedAt or (e.HatchAt and (e.HatchAt - (e.HatchTime or 90)))

		-- Defensive restore markers so WorldAssetCleanup/ EggService treat restored entries as intentional
		e.RestoredByGrandInvSer = true
		e.RecentlyPlacedSaved = true
		e.RecentlyPlacedSavedAt = os.time()

		return e
	end

	-- Pre-normalize worldEgg entries so downstream restore paths receive complete data
	if payload.we and type(payload.we) == "table" and #payload.we > 0 then
		for i = 1, #payload.we do
			local ok, normalized = pcall(function() return normalizeWorldEggEntry(payload.we[i]) end)
			if ok and normalized then
				payload.we[i] = normalized
			end
		end
	end

	-- WS restore
	if payload.ws and #payload.ws > 0 then
		pcall(function() ws_restore(player, payload.ws) end)
	end

	-- Helper to extract explicit uids
	local function extractUidFromProfileExplicit(p)
		if not p then return nil end
		local cand = p.userId or p.UserId or p.id or p.playerId
		if cand then local n = tonumber(cand) if n and n > 1000 and n == math.floor(n) then return n end end
		if type(p.Identity)=="table" then local ic = p.Identity.userId or p.Identity.UserId; local n = tonumber(ic); if n and n>1000 and n==math.floor(n) then return n end end
		return nil
	end
	local function extractUidFromEntryExplicit(e)
		if not e or type(e)~="table" then return nil end
		local keys = {"OwnerUserId","ownerUserId","owner","ow","userId","UserId","playerId"}
		for _,k in ipairs(keys) do
			local v = e[k]
			if v then local n = tonumber(v) if n and n>1000 and n==math.floor(n) then return n end end
		end
		if type(e.Owner)=="table" then for _,k in ipairs({"userId","UserId","id","Id"}) do local v = e.Owner[k]; if v then local n = tonumber(v); if n and n>1000 and n==math.floor(n) then return n end end end end
		return nil
	end

	local nameResolvedUserId = nil
	if not player and not profile and callerName then
		for _,pl in ipairs(Players:GetPlayers()) do
			if pl.Name == callerName then
				player = pl
				break
			end
		end
		if not player and not profile then
			local PPS = getPPS()
			if PPS and type(PPS.GetProfile) == "function" then
				local okp, profp = pcall(function() return PPS.GetProfile(callerName) end)
				if okp and type(profp) == "table" then
					profile = profp
				end
			end
		end
		if not player and not profile then
			local ok, res = pcall(function() return Players:GetUserIdFromNameAsync(callerName) end)
			if ok and res and tonumber(res) then
				nameResolvedUserId = tonumber(res)
				local profTry = safe_get_profile(nameResolvedUserId)
				if profTry then
					profile = profTry
				else
					local PPS = getPPS()
					if PPS and type(PPS.GetProfile) == "function" then
						local ok2, p2 = pcall(function() return PPS.GetProfile(nameResolvedUserId) end)
						if ok2 and type(p2)=="table" then
							profile = p2
						elseif PPS and type(PPS.WaitForProfile)=="function" then
							local ok3, p3 = pcall(function() return PPS.WaitForProfile(nameResolvedUserId, 1) end)
							if ok3 and type(p3)=="table" then
								profile = p3
							end
						end
					end
				end
			end
		end
	end

	-- WORLD EGGS (we) handling: prefer immediate if player present, else schedule
	if payload.we and #payload.we > 0 then
		-- ensure entries are normalized again for downstream consumers
		for i = 1, #payload.we do
			pcall(function() payload.we[i] = normalizeWorldEggEntry(payload.we[i]) end)
		end

		if player then
			local pid = getPersistentIdFor(player)
			local filtered = filterEggsAgainstLiveSlimes(payload.we, player.UserId, pid)
			if #filtered > 0 then
				pcall(function() we_restore(player, filtered) end)
			end
		else
			local uid = extractUidFromProfileExplicit(profile) or extractUidFromEntryExplicit(payload.we[1]) or extractUidFromEntryExplicit(payload.we[2])
			if not uid and profile then
				local cand = profile.userId or profile.UserId or profile.id or profile.Id
				if cand then
					local n = tonumber(cand)
					if n then
						uid = n
						dprint(("Fallback: using profile.userId=%s as uid for worldEgg restoration"):format(tostring(n)))
					end
				end
			end
			if not uid and nameResolvedUserId then uid = nameResolvedUserId end

			if uid then
				local pid = (profile and getPersistentIdFor(profile)) or nil
				local filtered = filterEggsAgainstLiveSlimes(payload.we, uid, pid)
				if #filtered > 0 then
					-- Ensure filtered entries are normalized and carry restore flags
					for i = 1, #filtered do pcall(function() filtered[i] = normalizeWorldEggEntry(filtered[i]) end) end

					dprint(("Scheduling we_restore_by_userid for uid=%s entries=%d (pid=%s)"):format(tostring(uid), #filtered, tostring(pid)))
					pcall(function() we_restore_by_userid(uid, filtered) end)

					-- BEST-EFFORT: also invoke EggService.RestoreEggSnapshot(uid, filtered) if EggService is available.
					-- This gives EggService a second chance to create/register eggs directly (useful in Studio local tests).
					local okEgg, EggSvcMod = pcall(function()
						local ss = game:GetService("ServerScriptService")
						local rs = game:GetService("ReplicatedStorage")
						local maybe = nil
						-- try Modules folder first
						local ms = ss:FindFirstChild("Modules")
						if ms and ms:FindFirstChild("EggService") then
							maybe = ms:FindFirstChild("EggService")
						elseif ss:FindFirstChild("EggService") then
							maybe = ss:FindFirstChild("EggService")
						elseif rs and rs:FindFirstChild("EggService") then
							maybe = rs:FindFirstChild("EggService")
						end
						if maybe and maybe:IsA("ModuleScript") then
							return require(maybe)
						end
						return nil
					end)
					if okEgg and EggSvcMod and type(EggSvcMod.RestoreEggSnapshot) == "function" then
						pcall(function()
							-- ensure we pass the normalized filtered entries
							EggSvcMod.RestoreEggSnapshot(uid, filtered)
							dprint(("GrandInvSer: EggService.RestoreEggSnapshot invoked for uid=%s entries=%d"):format(tostring(uid), #filtered))
						end)
					end
				else
					dprint(("Filtered worldEggs -> no entries to restore for uid=%s (pid=%s)"):format(tostring(uid), tostring(pid)))
				end
			else
				local keyName = callerName or (profile and (profile.playerName or profile.name))
				local pid = nil
				if profile then pid = getPersistentIdFor(profile) end
				if keyName and type(keyName) == "string" and keyName ~= "" then
					local filtered = filterEggsAgainstLiveSlimes(payload.we, nil, pid)
					if #filtered > 0 then
						-- normalize before queueing
						for i = 1, #filtered do pcall(function() filtered[i] = normalizeWorldEggEntry(filtered[i]) end) end

						dprint(("Queueing worldEggs under pendingRestoresByName[%s] entries=%d pid=%s"):format(tostring(keyName), #filtered, tostring(pid)))
						pendingRestoresByName[keyName] = pendingRestoresByName[keyName] or {}
						pendingRestoresByName[keyName].we = pendingRestoresByName[keyName].we or {}
						for _,e in ipairs(filtered) do table.insert(pendingRestoresByName[keyName].we, e) end
						pendingRestoresByName[keyName].timeout = os.time() + PENDING_DEFAULT_TIMEOUT

						-- If a player with that name is currently online, trigger processing immediately
						for _,pl in ipairs(Players:GetPlayers()) do
							if pl.Name == keyName then
								pcall(function() processPendingForPlayer(pl) end)
								break
							end
						end
					else
						dprint(("No worldEggs to queue for nameKey=%s pid=%s after filtering"):format(tostring(keyName), tostring(pid)))
					end
				elseif pid then
					local filtered = filterEggsAgainstLiveSlimes(payload.we, nil, pid)
					if #filtered > 0 then
						-- normalize before queueing
						for i = 1, #filtered do pcall(function() filtered[i] = normalizeWorldEggEntry(filtered[i]) end) end

						dprint(("Queueing worldEggs under pendingRestoresByPersistentId[%s] entries=%d"):format(tostring(pid), #filtered))
						pendingRestoresByPersistentId[pid] = pendingRestoresByPersistentId[pid] or {}
						pendingRestoresByPersistentId[pid].we = pendingRestoresByPersistentId[pid].we or {}
						for _,e in ipairs(filtered) do table.insert(pendingRestoresByPersistentId[pid].we, e) end
						pendingRestoresByPersistentId[pid].timeout = os.time() + PENDING_DEFAULT_TIMEOUT

						-- If an online player has matching persistentId, trigger processing immediately
						for _,pl in ipairs(Players:GetPlayers()) do
							local ok, plPid = pcall(function() return getPersistentIdFor(pl) end)
							if ok and plPid and tonumber(plPid) == tonumber(pid) then
								pcall(function() processPendingForPlayer(pl) end)
								break
							end
						end
					else
						dprint(("No worldEggs to queue for persistentId=%s after filtering"):format(tostring(pid)))
					end
				else
					dprint("WorldEggs payload couldn't determine target uid/pid/name; not queued")
				end
			end
		end
	end

	-- CAPTURED SLIMES (cs)
	if payload.cs and #payload.cs > 0 then
		if player then
			dprint(("cs_restore: player present; restoring captured slimes immediately for player=%s entries=%d"):format(tostring(player.Name), #payload.cs))
			pcall(function() cs_restore(player, payload.cs) end)
		else
			local uid = extractUidFromProfileExplicit(profile) or extractUidFromEntryExplicit(payload.cs[1]) or extractUidFromEntryExplicit(payload.cs[2])
			if not uid and profile then
				local cand = profile.userId or profile.UserId or profile.id or profile.Id
				if cand then
					local n = tonumber(cand)
					if n then
						uid = n
						dprint(("Fallback: using profile.userId=%s as uid for capturedSlime restoration"):format(tostring(n)))
					end
				end
			end
			if not uid and nameResolvedUserId then uid = nameResolvedUserId end

			if uid then
				dprint(("Scheduling cs restore under pendingRestores[%s] entries=%d"):format(tostring(uid), #payload.cs))
				pendingRestores[uid] = pendingRestores[uid] or {}
				pendingRestores[uid].cs = pendingRestores[uid].cs or {}
				for _,e in ipairs(payload.cs) do table.insert(pendingRestores[uid].cs, e) end
				pendingRestores[uid].timeout = os.time() + PENDING_DEFAULT_TIMEOUT

				local online = Players:GetPlayerByUserId(uid)
				if online then
					local bp = online:FindFirstChildOfClass("Backpack")
					if bp then
						pcall(function() cs_restoreImmediate(online, pendingRestores[uid].cs, bp) end)
						pendingRestores[uid] = nil
						dprint(("cs_restoreImmediate applied for online uid=%s"):format(tostring(uid)))
					else
						pcall(function() processPendingForPlayer(online) end)
						dprint(("cs_restore: player online but backpack missing; kicked processPendingForPlayer for uid=%s"):format(tostring(uid)))
					end
				end
			else
				local keyName = callerName or (profile and (profile.playerName or profile.name))
				if keyName and type(keyName) == "string" and keyName ~= "" then
					dprint(("Scheduling cs restore under pendingRestoresByName[%s] entries=%d"):format(tostring(keyName), #payload.cs))
					pendingRestoresByName[keyName] = pendingRestoresByName[keyName] or {}
					pendingRestoresByName[keyName].cs = pendingRestoresByName[keyName].cs or {}
					for _,e in ipairs(payload.cs) do table.insert(pendingRestoresByName[keyName].cs, e) end
					pendingRestoresByName[keyName].timeout = os.time() + PENDING_DEFAULT_TIMEOUT

					-- If a player by that name is online, trigger processing
					for _,pl in ipairs(Players:GetPlayers()) do
						if pl.Name == keyName then
							pcall(function() processPendingForPlayer(pl) end)
							break
						end
					end
				elseif profile then
					local pid = getPersistentIdFor(profile)
					if pid then
						dprint(("Scheduling cs restore under pendingRestoresByPersistentId[%s] entries=%d"):format(tostring(pid), #payload.cs))
						pendingRestoresByPersistentId[pid] = pendingRestoresByPersistentId[pid] or {}
						pendingRestoresByPersistentId[pid].cs = pendingRestoresByPersistentId[pid].cs or {}
						for _,e in ipairs(payload.cs) do table.insert(pendingRestoresByPersistentId[pid].cs, e) end
						pendingRestoresByPersistentId[pid].timeout = os.time() + PENDING_DEFAULT_TIMEOUT

						-- try immediate processing for an online player with matching pid
						for _,pl in ipairs(Players:GetPlayers()) do
							local ok, plPid = pcall(function() return getPersistentIdFor(pl) end)
							if ok and plPid and tonumber(plPid) == tonumber(pid) then
								pcall(function() processPendingForPlayer(pl) end)
								break
							end
						end
					else
						dprint("cs_restore: could not determine uid/pid/name to schedule pending cs restore; aborting.")
					end
				else
					dprint("cs_restore: could not determine uid/pid/name to schedule pending cs restore; aborting.")
				end
			end
		end
	end

	-- Helper: valid UID detection & inference for tools
	local function validUid(n) if type(n)~="number" then return false end if n<=1000 then return false end return n==math.floor(n) end
	local function inferUidForTools(prof, entryA, entryB)
		local uid = extractUidFromProfileExplicit(prof)
		if validUid(uid) then return uid end
		uid = extractUidFromEntryExplicit(entryA)
		if validUid(uid) then return uid end
		uid = extractUidFromEntryExplicit(entryB)
		if validUid(uid) then return uid end
		if nameResolvedUserId and validUid(nameResolvedUserId) then return nameResolvedUserId end
		return nil
	end

	-- EGG TOOLS (et)
	if payload.et and #payload.et > 0 then
		if player then
			dprint(("et_restore: player present; restoring immediately for player=%s entries=%d"):format(tostring(player.Name), #payload.et))
			pcall(function() et_restore(player, payload.et) end)
		else
			local uid = inferUidForTools(profile, payload.et[1], payload.ft and payload.ft[1])
			local pid = nil
			if profile then pid = getPersistentIdFor(profile) end
			if uid then
				dprint(("Scheduling et restore under pendingRestores[%s] entries=%d (pid=%s)"):format(tostring(uid), #payload.et, tostring(pid)))
				pendingRestores[uid] = pendingRestores[uid] or {}
				pendingRestores[uid].et = pendingRestores[uid].et or {}
				for _,e in ipairs(payload.et) do table.insert(pendingRestores[uid].et, e) end
				pendingRestores[uid].timeout = os.time() + PENDING_DEFAULT_TIMEOUT

				-- If player is online, try to process immediately
				local online = Players:GetPlayerByUserId(uid)
				if online then
					-- If Backpack ready, do immediate application
					local bp = online:FindFirstChildOfClass("Backpack")
					if bp then
						pcall(function() et_restoreImmediate(online, pendingRestores[uid].et, bp) end)
						pendingRestores[uid] = nil
						dprint(("et_restoreImmediate applied for online uid=%s"):format(tostring(uid)))
					else
						-- ensure processing loop will run / wait for backpack
						pcall(function() processPendingForPlayer(online) end)
						dprint(("et_restore: player online but backpack missing; kicked processPendingForPlayer for uid=%s"):format(tostring(uid)))
					end
				end
			elseif pid then
				dprint(("Scheduling et restore under pendingRestoresByPersistentId[%s] entries=%d"):format(tostring(pid), #payload.et))
				pendingRestoresByPersistentId[pid] = pendingRestoresByPersistentId[pid] or {}
				pendingRestoresByPersistentId[pid].et = pendingRestoresByPersistentId[pid].et or {}
				for _,e in ipairs(payload.et) do table.insert(pendingRestoresByPersistentId[pid].et, e) end
				pendingRestoresByPersistentId[pid].timeout = os.time() + PENDING_DEFAULT_TIMEOUT

				-- Try find online player with matching persistentId and process
				for _,pl in ipairs(Players:GetPlayers()) do
					local ok, plPid = pcall(function() return getPersistentIdFor(pl) end)
					if ok and plPid and tonumber(plPid) == tonumber(pid) then
						pcall(function() processPendingForPlayer(pl) end)
						break
					end
				end
			else
				local keyName = callerName or (profile and (profile.playerName or profile.name))
				if keyName and type(keyName) == "string" and keyName ~= "" then
					dprint(("Scheduling et restore under pendingRestoresByName[%s] entries=%d"):format(tostring(keyName), #payload.et))
					pendingRestoresByName[keyName] = pendingRestoresByName[keyName] or {}
					pendingRestoresByName[keyName].et = pendingRestoresByName[keyName].et or {}
					for _,e in ipairs(payload.et) do table.insert(pendingRestoresByName[keyName].et, e) end
					pendingRestoresByName[keyName].timeout = os.time() + PENDING_DEFAULT_TIMEOUT

					-- If a player by that name is online, trigger processing
					for _,pl in ipairs(Players:GetPlayers()) do
						if pl.Name == keyName then
							pcall(function() processPendingForPlayer(pl) end)
							break
						end
					end
				else
					dprint("et_restore: could not determine uid/pid/name to schedule pending et restore; aborting.")
				end
			end
		end
	end

	-- FOOD TOOLS (ft)
	if payload.ft and #payload.ft > 0 then
		if player then
			dprint(("ft_restore: player present; restoring immediately for player=%s entries=%d"):format(tostring(player.Name), #payload.ft))
			pcall(function() ft_restore(player, payload.ft) end)
		else
			local uid = inferUidForTools(profile, payload.ft[1], payload.et and payload.et[1])
			local pid = nil
			if profile then pid = getPersistentIdFor(profile) end
			if uid then
				dprint(("Scheduling ft restore under pendingRestores[%s] entries=%d (pid=%s)"):format(tostring(uid), #payload.ft, tostring(pid)))
				pendingRestores[uid] = pendingRestores[uid] or {}
				pendingRestores[uid].ft = pendingRestores[uid].ft or {}
				for _,e in ipairs(payload.ft) do table.insert(pendingRestores[uid].ft, e) end
				pendingRestores[uid].timeout = os.time() + PENDING_DEFAULT_TIMEOUT

				-- If player is online, try to process immediately
				local online = Players:GetPlayerByUserId(uid)
				if online then
					local bp = online:FindFirstChildOfClass("Backpack")
					if bp then
						pcall(function() ft_restoreImmediate(online, pendingRestores[uid].ft, bp) end)
						pendingRestores[uid] = nil
						dprint(("ft_restoreImmediate applied for online uid=%s"):format(tostring(uid)))
					else
						pcall(function() processPendingForPlayer(online) end)
						dprint(("ft_restore: player online but backpack missing; kicked processPendingForPlayer for uid=%s"):format(tostring(uid)))
					end
				end
			elseif pid then
				dprint(("Scheduling ft restore under pendingRestoresByPersistentId[%s] entries=%d"):format(tostring(pid), #payload.ft))
				pendingRestoresByPersistentId[pid] = pendingRestoresByPersistentId[pid] or {}
				pendingRestoresByPersistentId[pid].ft = pendingRestoresByPersistentId[pid].ft or {}
				for _,e in ipairs(payload.ft) do table.insert(pendingRestoresByPersistentId[pid].ft, e) end
				pendingRestoresByPersistentId[pid].timeout = os.time() + PENDING_DEFAULT_TIMEOUT

				-- Try find online player with matching persistentId and process
				for _,pl in ipairs(Players:GetPlayers()) do
					local ok, plPid = pcall(function() return getPersistentIdFor(pl) end)
					if ok and plPid and tonumber(plPid) == tonumber(pid) then
						pcall(function() processPendingForPlayer(pl) end)
						break
					end
				end
			else
				local keyName = callerName or (profile and (profile.playerName or profile.name))
				if keyName and type(keyName) == "string" and keyName ~= "" then
					dprint(("Scheduling ft restore under pendingRestoresByName[%s] entries=%d"):format(tostring(keyName), #payload.ft))
					pendingRestoresByName[keyName] = pendingRestoresByName[keyName] or {}
					pendingRestoresByName[keyName].ft = pendingRestoresByName[keyName].ft or {}
					for _,e in ipairs(payload.ft) do table.insert(pendingRestoresByName[keyName].ft, e) end
					pendingRestoresByName[keyName].timeout = os.time() + PENDING_DEFAULT_TIMEOUT

					-- If a player by that name is online, trigger processing
					for _,pl in ipairs(Players:GetPlayers()) do
						if pl.Name == keyName then
							pcall(function() processPendingForPlayer(pl) end)
							break
						end
					end
				else
					dprint("ft_restore: could not determine uid/pid/name to schedule pending ft restore; aborting.")
				end
			end
		end
	end

	-- Merge payload into in-memory profile if we have one (preserve existing behavior but be defensive)
	local prof = profile or (player and safe_get_profile(player))
	if prof and type(prof)=="table" then
		prof.inventory = prof.inventory or {}
		local inv = prof.inventory
		local function mergeFieldIfNonEmpty(fieldName, payloadField, label)
			if type(payloadField)=="table" and #payloadField>0 then
				if not inv[fieldName] or #inv[fieldName]==0 then
					inv[fieldName] = {}
					for i,v in ipairs(payloadField) do table.insert(inv[fieldName], v) end
					dprint(("Applied payload.%s -> profile.inventory.%s"):format(label, fieldName))
				end
			end
		end

		-- Defensive merge ordering:
		-- apply worldEggs first (we), then eggTools (et) only if there are no worldEggs present
		mergeFieldIfNonEmpty("worldEggs", payload.we, "we")
		-- Only apply eggTools if payload.we is empty and there are no worldEggs already in the profile.
		if (not payload.we or #payload.we == 0) and (not inv.worldEggs or #inv.worldEggs == 0) then
			mergeFieldIfNonEmpty("eggTools", payload.et, "et")
		else
			if payload.et and #payload.et > 0 then
				dprint("Skipping merge of payload.et -> profile.inventory.eggTools because worldEggs present in payload/profile (defensive).")
			end
		end

		-- Other fields (foodTools, worldSlimes, capturedSlimes) use conservative overlay
		mergeFieldIfNonEmpty("foodTools", payload.ft, "ft")
		mergeFieldIfNonEmpty("worldSlimes", payload.ws, "ws")
		mergeFieldIfNonEmpty("capturedSlimes", payload.cs, "cs")

		local applied = (inv.eggTools and #inv.eggTools>0) or (inv.foodTools and #inv.foodTools>0) or (inv.worldEggs and #inv.worldEggs>0) or (inv.worldSlimes and #inv.worldSlimes>0) or (inv.capturedSlimes and #inv.capturedSlimes>0)
		local PPS = getPPS()
		if applied and PPS then
			-- sanitize inventory on profile prior to SaveNow to prevent DataStore errors
			pcall(function() sanitizeInventoryOnProfile(prof) end)
			local succ, uid = pcall(function() return tonumber(prof.userId or prof.UserId or prof.id) end)
			uid = (succ and uid) and uid or (player and player.UserId)
			if player then pcall(function() PPS.SaveNow(player, "GrandInvSer_RestoreMerge") end)
			elseif uid then pcall(function() PPS.SaveNow(uid, "GrandInvSer_RestoreMerge") end) end
		end
	end

	debug_profile_inventory(profile or player, "AfterRestore")
end

-- continuation / final portion of GrandInventorySerializer.lua
-- Paste this after the Restore(...) implementation above

-- Updated PreExitSync: ensure profile.inventory.worldEggs reflects live world eggs before saving.
-- Defensive: avoid mutating authoritative profile fields, avoid creating/assigning a new persistent profile when none exists,
-- and handle sanitized/partial arguments safely.
-- Replace the existing PreExitSync implementation with this safer version.
-- Key points:
--  - Resolve an authoritative profile (via safe_get_profile) before mutating anything.
--  - If no authoritative profile is found, do not mutate passed profile objects or call PPS.SaveNow.
--  - Only update inventory.worldEggs field (do not replace whole inventory), and avoid clearing non-empty worldEggs with empty enumeration.
--  - Sanitize inventory before calling SaveNow.

function GrandInventorySerializer.PreExitSync(...)
	local a1, a2 = _normalize_call_args({ ... })
	local player, profileArg = nil, nil

	-- Detect player instance in args
	if type(a1) == "table" and type(a1.FindFirstChildOfClass) == "function" then
		player = a1
	elseif type(a2) == "table" and type(a2.FindFirstChildOfClass) == "function" then
		player = a2
	end

	-- The arg that *may* be a profile-like object (snapshot) if provided
	if type(a1) == "table" and a1.inventory ~= nil then
		profileArg = a1
	elseif type(a2) == "table" and a2.inventory ~= nil then
		profileArg = a2
	end

	-- Try to resolve an authoritative profile object from PPS (do not assume profileArg is authoritative)
	local authoritativeProfile = nil
	if player then
		authoritativeProfile = safe_get_profile(player)
	end
	if not authoritativeProfile then
		-- If a profile-like arg contains a userId, try to fetch authoritative profile via safe_get_profile
		if profileArg and (profileArg.userId or profileArg.UserId or profileArg.id or profileArg.Id) then
			local uid = tonumber(profileArg.userId or profileArg.UserId or profileArg.id or profileArg.Id)
			if uid then
				authoritativeProfile = safe_get_profile(uid)
			end
		end
	end
	-- Also allow callers who passed a numeric/string id
	if not authoritativeProfile then
		if a1 ~= nil then authoritativeProfile = safe_get_profile(a1) end
		if not authoritativeProfile and a2 ~= nil then authoritativeProfile = safe_get_profile(a2) end
	end

	-- Gather live world eggs (best-effort). Do not mutate profileArg yet.
	local live_we = nil
	if player then
		local ok, list = pcall(function() return we_enumeratePlotEggs(player) end)
		if ok and type(list) == "table" then live_we = list end
	else
		local uid = tonumber((profileArg and (profileArg.userId or profileArg.UserId or profileArg.id)) or nil)
		if uid then
			local ok, list = pcall(function() return we_enumeratePlotEggs_by_userid(uid) end)
			if ok and type(list) == "table" then live_we = list end
		end
	end
	if not live_we then live_we = {} end

	-- If we DON'T have an authoritative profile, do NOT attempt to mutate/profile save.
	-- Return a sanitized snapshot for callers that expect a result (non-destructive).
	if not authoritativeProfile then
		local function deepCopy(src)
			if type(src) ~= "table" then return src end
			local dst = {}
			for k,v in pairs(src) do
				if type(v) == "table" then dst[k] = deepCopy(v) else dst[k] = v end
			end
			return dst
		end
		return { worldEggs = deepCopy(live_we) }
	end

	-- We have an authoritative profile. Apply live worldEggs conservatively.
	local function deepCopy(src)
		if type(src) ~= "table" then return src end
		local dst = {}
		for k,v in pairs(src) do
			if type(v) == "table" then dst[k] = deepCopy(v) else dst[k] = v end
		end
		return dst
	end

	authoritativeProfile.inventory = authoritativeProfile.inventory or {}
	local inv = authoritativeProfile.inventory

	-- Only overwrite worldEggs if:
	--  - live_we is non-empty (we've enumerated something live), OR
	--  - inv.worldEggs is nil (no stored data)
	if (live_we and #live_we > 0) or (not inv.worldEggs or #inv.worldEggs == 0) then
		inv.worldEggs = deepCopy(live_we)
	else
		dprint(("[PreExitSync] skipping overwrite of profile.inventory.worldEggs (authoritative already has %d entries)"):format(#(inv.worldEggs or {})))
	end

	-- Stamp metadata marker
	authoritativeProfile.meta = authoritativeProfile.meta or {}
	authoritativeProfile.meta.lastPreExitSync = os.time()

	-- Sanitize inventory on the authoritative profile before saving (defensive)
	pcall(function() sanitizeInventoryOnProfile(authoritativeProfile) end)

	-- Request SaveNow if PPS is available, preferably passing the Player instance
	local PPS = getPPS()
	if PPS and type(PPS.SaveNow) == "function" then
		if player and type(player.FindFirstChildOfClass) == "function" then
			pcall(function() PPS.SaveNow(player, "GrandInvSer_PreExitSync") end)
		else
			local uid = tonumber(authoritativeProfile.userId or authoritativeProfile.UserId or authoritativeProfile.id)
			if uid then
				pcall(function() PPS.SaveNow(uid, "GrandInvSer_PreExitSync") end)
			else
				dprint("PreExitSync: authoritative profile found but could not determine uid to SaveNow; skipping SaveNow")
			end
		end
	end

	-- Return a sanitized copy for callers
	return { worldEggs = deepCopy(inv.worldEggs or {}) }
end







-- Egg removal watcher
-- Keeps saved profiles in sync when Eggs are removed/destroyed or reparented out of Workspace.
do
	local recentRemoved = {} -- eggId -> timestamp for debounce
	local REMOVAL_DEBOUNCE_SECONDS = 2

	local function debounce_and_mark(eggId)
		if not eggId then return false end
		local now = os.clock()
		local last = recentRemoved[eggId]
		if last and (now - last) < REMOVAL_DEBOUNCE_SECONDS then
			return false
		end
		recentRemoved[eggId] = now
		-- schedule cleanup of old entries to avoid memory growth
		task.delay(REMOVAL_DEBOUNCE_SECONDS * 2, function() if recentRemoved[eggId] and (os.clock() - recentRemoved[eggId]) >= REMOVAL_DEBOUNCE_SECONDS * 2 then recentRemoved[eggId] = nil end end)
		return true
	end

	local function tryRemoveEggFromProfile(ownerUserId, eggId)
		if not eggId then return end
		-- Debounce per eggId
		if not debounce_and_mark(tostring(eggId)) then return end

		-- Try PlayerProfileService first
		local PPS = getPPS()
		if PPS and type(PPS.RemoveInventoryItem) == "function" then
			local ok, err = pcall(function()
				-- Remove by 'id' field used by serializer
				PPS.RemoveInventoryItem(ownerUserId, "worldEggs", "id", eggId)
			end)
			if ok then
				-- request async save (debounced) so profile won't re-create the egg on next join
				pcall(function()
					if ownerUserId then
						PPS.SaveNow(ownerUserId, "GrandInvSer_EggRemoved")
					end
				end)
				return
			end
		end

		-- Fallbacks: some setups use InventoryService.UpdateProfileInventory style functions.
		-- Attempt to find/require a module named InventoryService in common locations and call a remove API if available.
		local function findInvMS()
			local sources = { ServerScriptService, ServerScriptService:FindFirstChild("Modules") or ServerScriptService, game:GetService("ReplicatedStorage"), game:GetService("ReplicatedStorage"):FindFirstChild("Modules") or nil }
			for _, src in ipairs(sources) do
				if not src then continue end
				local inst = src:FindFirstChild("InventoryService") or src:FindFirstChild("InvSvc") or src:FindFirstChild("Inventory")
				if inst and inst:IsA("ModuleScript") then
					local ok, mod = pcall(function() return require(inst) end)
					if ok and type(mod) == "table" then return mod end
				end
			end
			return nil
		end

		local invMod = findInvMS()
		if invMod then
			-- Try common signatures defensively
			pcall(function()
				if type(invMod.UpdateProfileInventory) == "function" then
					-- Attempt using (userId, fieldName, newData) pattern - remove item by filtering
					-- We'll attempt to fetch profile table if supported
					local prof = nil
					if type(invMod.GetProfileForUser) == "function" then
						local ok, p = pcall(function() return invMod.GetProfileForUser(ownerUserId) end)
						if ok and type(p) == "table" then prof = p end
					end
					if prof and prof.inventory and prof.inventory.worldEggs then
						for i = #prof.inventory.worldEggs, 1, -1 do
							local it = prof.inventory.worldEggs[i]
							if it and (it.id == eggId or it.EggId == eggId) then table.remove(prof.inventory.worldEggs, i) end
						end
						pcall(function() invMod.UpdateProfileInventory(prof, "worldEggs", prof.inventory.worldEggs) end)
					else
						-- fallback: call UpdateProfileInventory(userId, "worldEggs", {}) to force reserialize later
						pcall(function() invMod.UpdateProfileInventory(ownerUserId, "worldEggs", {}) end)
					end
				elseif type(invMod.SetProfileField) == "function" then
					pcall(function() invMod.SetProfileField(ownerUserId, "worldEggs", {}) end)
				end
				-- Try to request save if available
				if type(invMod.SaveNow) == "function" then
					pcall(function() invMod.SaveNow(ownerUserId, "GrandInvSer_EggRemoved") end)
				end
			end)
		end
	end

	local function onEggInstanceRemoved(inst)
		if not inst or not inst:IsA("Model") then return end
		if tostring(inst.Name) ~= "Egg" then return end
		local eggId = inst:GetAttribute("EggId") or inst:GetAttribute("id")
		local owner = inst:GetAttribute("OwnerUserId") or inst:GetAttribute("ownerUserId") or inst:GetAttribute("Owner")
		local ownerNum = tonumber(owner)
		if eggId then
			pcall(function() tryRemoveEggFromProfile(ownerNum, eggId) end)
		end
	end

	-- Monitor destroyed instances
	Workspace.DescendantRemoving:Connect(function(desc)
		-- DescendantRemoving triggers while the instance is still accessible
		if desc and desc:IsA("Model") and tostring(desc.Name) == "Egg" then
			pcall(function() onEggInstanceRemoved(desc) end)
		end
	end)

	-- Monitor re-parent (moved out of Workspace) - watch eggs as they are added and connect AncestryChanged
	local function monitorEggAncestry(inst)
		if not inst or not inst:IsA("Model") then return end
		if tostring(inst.Name) ~= "Egg" then return end
		local conn
		conn = inst.AncestryChanged:Connect(function(child, parent)
			-- If parent is nil or not under Workspace, consider it removed from the world
			local parentOk = parent and parent:IsDescendantOf(Workspace)
			if not parentOk then
				-- run removal handler once (in a pcall)
				pcall(function() onEggInstanceRemoved(inst) end)
				if conn then conn:Disconnect() end
			end
		end)
	end

	-- Attach monitoring to current eggs and to future eggs
	for _, inst in ipairs(Workspace:GetDescendants()) do
		if inst:IsA("Model") and tostring(inst.Name) == "Egg" then
			pcall(function() monitorEggAncestry(inst) end)
		end
	end
	Workspace.DescendantAdded:Connect(function(desc)
		if desc and desc:IsA("Model") and tostring(desc.Name) == "Egg" then
			pcall(function() monitorEggAncestry(desc) end)
		end
	end)
end

-- Optionally expose a convenience SaveProfile function (minimal, non-breaking)
function GrandInventorySerializer.SaveProfileNow(playerOrProfile, reason)
	local prof = nil
	local player = nil
	if type(playerOrProfile) == "table" and playerOrProfile.inventory ~= nil then
		prof = playerOrProfile
	elseif type(playerOrProfile) == "table" and type(playerOrProfile.FindFirstChildOfClass) == "function" then
		player = playerOrProfile
		prof = safe_get_profile(player)
	elseif playerOrProfile ~= nil then
		prof = safe_get_profile(playerOrProfile)
	end
	pcall(function()
		if prof then
			sanitizeInventoryOnProfile(prof)
		end
	end)
	local PPS = getPPS()
	if PPS and type(PPS.SaveNow) == "function" then
		local ok, _ = pcall(function()
			if player then
				PPS.SaveNow(player, reason or "GrandInvSer_SaveProfileNow")
			else
				local uid = tonumber(prof and (prof.userId or prof.UserId or prof.id))
				if uid then PPS.SaveNow(uid, reason or "GrandInvSer_SaveProfileNow") end
			end
		end)
		return ok
	end
	return false
end

-- Ensure we pick up any existing plot models on startup
pcall(function()
	scanAndRegisterPlotsOnStartup()
end)

-- Expose some internals (optional) for debugging/testing
GrandInventorySerializer._internal = {
	pendingRestores = pendingRestores,
	pendingRestoresByName = pendingRestoresByName,
	pendingRestoresByPersistentId = pendingRestoresByPersistentId,
	plotByUserId = plotByUserId,
	plotByPersistentId = plotByPersistentId,
	ws_liveIndex = ws_liveIndex,
	try_find_slime_template = try_find_slime_template,
	graft_template_visuals_to_model = graft_template_visuals_to_model,
	sanitize_and_clone_visual = sanitize_and_clone_visual,
	
}

return GrandInventorySerializer