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
	Debug = false,
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
		Debug                    = false,
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
		Debug                  = false,
	},
}

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

-- Helpers: numeric/finite check
local function isFiniteNumber(n)
	if type(n) ~= "number" then return false end
	if n ~= n then return false end -- NaN
	if n == math.huge or n == -math.huge then return false end
	return true
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

-- WorldSlime
local WSCONFIG = GrandInventorySerializer.CONFIG.WorldSlime
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
local ws_restoredOnce = {}

local function ws_colorToHex(c)
	return string.format("%02X%02X%02X",
		math.floor(c.R*255+0.5),
		math.floor(c.G*255+0.5),
		math.floor(c.B*255+0.5))
end
local function ws_hexToColor3(hex)
	if typeof and typeof(hex)=="Color3" then return hex end
	if type(hex)~="string" then return nil end
	hex=hex:gsub("^#","")
	if #hex~=6 then return nil end
	local r=tonumber(hex:sub(1,2),16)
	local g=tonumber(hex:sub(3,4),16)
	local b=tonumber(hex:sub(5,6),16)
	if r and g and b then return Color3.fromRGB(r,g,b) end
	return nil
end
local function ws_ensureIndex(player)
	if not ws_liveIndex[player.UserId] then ws_liveIndex[player.UserId] = {} end
	return ws_liveIndex[player.UserId]
end
local function ws_registerModel(player, model)
	local id = model:GetAttribute("SlimeId")
	if not id then return end
	local idx=ws_ensureIndex(player)
	local key = tostring(id)
	-- If an existing indexed model is present and different, remove the incoming duplicate (or choose policy)
	if idx[key] and idx[key]~=model and idx[key].Parent then
		dprint("Duplicate live slime SlimeId="..tostring(key).." destroying extra.")
		pcall(function() model:Destroy() end)
		return
	end
	idx[key]=model
	if WSCONFIG.MarkWorldSlimeAttribute then
		model:SetAttribute("WorldSlime", true)
	end
end
local function ws_scan_by_userid(userId)
	local out, seen = {}, {}
	for _,inst in ipairs(Workspace:GetDescendants()) do
		if inst:IsA("Model") and inst.Name=="Slime" and tostring(inst:GetAttribute("OwnerUserId"))==tostring(userId) and not inst:GetAttribute("Retired") and not inst:FindFirstAncestorWhichIsA("Tool") then
			local id=inst:GetAttribute("SlimeId")
			if id and not seen[tostring(id)] then
				seen[tostring(id)]=true
				out[#out+1]=inst
			end
		end
	end
	return out
end
local function ws_scan(player)
	if not player then return {} end
	local out, seen = {}, {}
	for _,inst in ipairs(Workspace:GetDescendants()) do
		if inst:IsA("Model") and inst.Name=="Slime" and inst:GetAttribute("OwnerUserId")==player.UserId and not inst:GetAttribute("Retired") and not inst:FindFirstAncestorWhichIsA("Tool") then
			local id=inst:GetAttribute("SlimeId")
			if id and not seen[tostring(id)] then
				seen[tostring(id)]=true
				out[#out+1]=inst
				ws_registerModel(player, inst)
			end
		end
	end
	return out
end

local function ws_serialize(player, isFinal, profile)
	if not player and profile and profile.userId then
		if profile.worldSlimes and #profile.worldSlimes > 0 then
			return profile.worldSlimes
		end
		local list = ws_scan_by_userid(profile.userId or profile.UserId)
		return list
	end
	if not player then
		return {}
	end
	local slimes = ws_scan(player)
	local list = {}
	local seen = {}
	local now = os.time()
	local plot, origin
	for _,m in ipairs(Workspace:GetChildren()) do
		if m:IsA("Model") and m:GetAttribute("UserId") == player.UserId and m.Name:match("^Player%d+$") then
			plot = m
			break
		end
	end
	if plot then
		local zone = plot:FindFirstChild("SlimeZone")
		if zone and zone:IsA("BasePart") then origin = zone end
	end
	for _,m in ipairs(slimes) do
		local sid = m:GetAttribute("SlimeId")
		local sidKey = sid and tostring(sid) or nil
		if WSCONFIG.DedupeOnSerialize and sidKey and seen[sidKey] then
			-- skip duplicate
		else
			local prim = m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart")
			if prim then
				local cf = prim.CFrame
				local entry = { px = cf.X, py = cf.Y, pz = cf.Z }
				if WSCONFIG.UseLocalCoords and origin then
					local lcf = origin.CFrame:ToObjectSpace(cf)
					entry.lpx, entry.lpy, entry.lpz = lcf.X, lcf.Y, lcf.Z
					entry.lry = math.atan2(-lcf.LookVector.X, -lcf.LookVector.Z)
				else
					entry.ry = math.atan2(-cf.LookVector.X, -cf.LookVector.Z)
				end
				for attr,short in pairs(WS_ATTR_MAP) do
					local v = m:GetAttribute(attr)
					if v ~= nil then
						if colorKeys[short] and typeof and typeof(v) == "Color3" then
							v = ws_colorToHex(v)
						end
						entry[short] = v
					end
				end
				entry.id = sid
				entry.lg = now
				list[#list+1] = entry
				if sidKey then seen[sidKey] = true end
				if #list >= WSCONFIG.MaxWorldSlimesPerPlayer then break end
			end
		end
	end
	return list
end

-- Helper: find existing live slime by SlimeId (add above ws_restore if not present)
local function ws_findExistingSlimeById(slimeId)
	if not slimeId then return nil end
	local sidKey = tostring(slimeId)
	for _,inst in ipairs(Workspace:GetDescendants()) do
		if inst:IsA("Model") and inst.Name == "Slime" then
			local sid = inst:GetAttribute("SlimeId")
			if sid and tostring(sid) == sidKey then
				-- ignore retired / detached / tool-children
				if inst:GetAttribute("Retired") then
					-- prefer non-retired instances; continue searching
				else
					if not inst.Parent then
						-- skip destroyed / orphaned
					else
						if inst:FindFirstAncestorWhichIsA("Tool") then
							-- skip ones parented under tools
						else
							-- prefer instances with PrimaryPart if multiple; but return the first healthy one
							return inst
						end
					end
				end
			end
		end
	end
	return nil
end

local function ws_restore(player, list)
	if not list or #list == 0 then return end
	local now = os.time()
	-- populate live index for this player
	if player then ws_scan(player) end

	-- find plot/origin
	local plot, origin
	if player then
		pcall(function() plot = we_findPlayerPlot_by_userid(player.UserId) end)
		if not plot then pcall(function() plot = _we_findPlayerPlot(player) end) end
		origin = (plot and _we_getPlotOrigin(plot)) or nil
	else
		-- try infer owner/potential plot from payload
		local ownerUid
		for _,e in ipairs(list) do
			if e and e.ow then ownerUid = tonumber(e.ow) or ownerUid end
			if not ownerUid and e and e.OwnerUserId then ownerUid = tonumber(e.OwnerUserId) or ownerUid end
			if ownerUid then break end
		end
		if ownerUid then
			pcall(function() plot = we_findPlayerPlot_by_userid(ownerUid) end)
			if not plot then pcall(function() plot = we_findPlayerPlot_by_persistentId(ownerUid) end) end
			origin = (plot and _we_getPlotOrigin(plot)) or nil
		end
	end

	local parent = plot or Workspace
	local restored = 0
	local restoredModels = {}
	local restoredIds = {}
	local persistentId = player and getPersistentIdFor(player) or nil

	-- Resolve SlimeFactory/ModelUtils/SlimeAI robustly:
	-- Try standalone modules first, then fall back to a consolidated SlimeCore module that exposes these.
	local SlimeFactory, ModelUtils, SlimeAI
	do
		local function tryRequireFromModules(name)
			local ok, mod = pcall(function()
				local ms = ServerScriptService:FindFirstChild("Modules")
				if ms then
					local inst = ms:FindFirstChild(name)
					if inst and inst:IsA("ModuleScript") then
						return require(inst)
					end
				end
				-- also try direct child of ServerScriptService (some layouts)
				local direct = ServerScriptService:FindFirstChild(name)
				if direct and direct:IsA("ModuleScript") then
					return require(direct)
				end
				return nil
			end)
			if ok and type(mod) == "table" then return mod end
			return nil
		end

		local function tryRequireSlimeCore()
			local ok, sc = pcall(function()
				-- try common locations for a SlimeCore module
				local candidates = {
					function() return script and script.Parent and script.Parent:FindFirstChild("SlimeCore") end,
					function() local m = ServerScriptService:FindFirstChild("Modules"); return m and m:FindFirstChild("SlimeCore") end,
					function() return ServerScriptService:FindFirstChild("SlimeCore") end,
					function() return ReplicatedStorage:FindFirstChild("SlimeCore") end,
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

		SlimeFactory = tryRequireFromModules("SlimeFactory")
		ModelUtils  = tryRequireFromModules("ModelUtils")
		SlimeAI     = tryRequireFromModules("SlimeAI")

		if not (SlimeFactory and ModelUtils and SlimeAI) then
			local sc = tryRequireSlimeCore()
			if sc then
				-- attempt to map commonly exported names
				SlimeFactory = SlimeFactory or sc.SlimeFactory or sc.Factory or sc.Slime or sc.Restore
				ModelUtils  = ModelUtils  or sc.ModelUtils   or sc.Model or sc.Utils
				SlimeAI     = SlimeAI     or sc.SlimeAI      or sc.AI or sc.Brain
			end
		end

		-- best-effort logging for debugging
		if GrandInventorySerializer.CONFIG.Debug then
			if not SlimeFactory then dprint("ws_restore: SlimeFactory not found; will use fallback minimal creation") end
			if not ModelUtils then dprint("ws_restore: ModelUtils not found; weld/repair will be skipped") end
			if not SlimeAI then dprint("ws_restore: SlimeAI not found; AI start will be skipped") end
		end
	end

	-- small helpers
	local function clamp_local(v, maxmag)
		if not v then return v end
		if math.abs(v) > maxmag then return (v > 0) and maxmag or -maxmag end
		return v
	end
	local function is_local_coords_present(lx,ly,lz) return (lx ~= nil) or (ly ~= nil) or (lz ~= nil) end

	for _, e in ipairs(list) do
		if restored >= WSCONFIG.MaxWorldSlimesPerPlayer then break end
		if type(e) ~= "table" then continue end

		local sid = e.id
		local sidKey = sid and tostring(sid) or nil

		-- skip duplicates already restored in this pass
		if sidKey and restoredIds[sidKey] then
			dprint(("Skipping duplicate slime restore sid=%s"):format(tostring(sid)))
			continue
		end

		-- Defensive: skip malformed entries that have no canonical id and no meaningful attributes.
		if not sidKey then
			local hasMeaningfulAttr = false
			if e.ow or e.OwnerUserId or e.OwnerPersistentId then hasMeaningfulAttr = true end
			if not hasMeaningfulAttr then
				for attr, short in pairs(WS_ATTR_MAP) do
					if e[short] ~= nil then hasMeaningfulAttr = true; break end
				end
			end
			if not hasMeaningfulAttr then
				if e.px or e.py or e.pz or e.lpx or e.lpy or e.lpz then hasMeaningfulAttr = true end
			end
			if not hasMeaningfulAttr then
				dprint(("ws_restore: skipping malformed worldSlime payload entry (no id, no attrs) player=%s"):format(tostring(player and player.UserId or "<nil>")))
				continue
			end
		end

		-- if live slime exists, update it (avoid duplicating)
		local existing = sidKey and ws_findExistingSlimeById(sidKey) or nil
		if existing then
			dprint(("ws_restore: found existing Slime for id=%s; updating"):format(tostring(sid)))
			pcall(function()
				existing:SetAttribute("OwnerUserId", player and player.UserId or e.ow or existing:GetAttribute("OwnerUserId"))
				if persistentId then existing:SetAttribute("OwnerPersistentId", persistentId) end
				for attr, short in pairs(WS_ATTR_MAP) do
					local v = e[short]
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
				-- stash restore coords for deferred reparenting if needed
				if e.lpx then existing:SetAttribute("RestoreLpx", e.lpx) end
				if e.lpy then existing:SetAttribute("RestoreLpy", e.lpy) end
				if e.lpz then existing:SetAttribute("RestoreLpz", e.lpz) end
				if e.px then existing:SetAttribute("RestorePX", e.px) end
				if e.py then existing:SetAttribute("RestorePY", e.py) end
				if e.pz then existing:SetAttribute("RestorePZ", e.pz) end
			end)

			-- ensure there is a PrimaryPart; if not and SlimeFactory exists, replace with factory-built model
			local prim = existing.PrimaryPart or existing:FindFirstChildWhichIsA("BasePart")
			if not prim and SlimeFactory and type(SlimeFactory.RestoreFromSnapshot) == "function" then
				local ok, new = pcall(function() return SlimeFactory.RestoreFromSnapshot(e, player, plot) end)
				if ok and new then
					ws_registerModel(player, new)
					table.insert(restoredModels, new)
					if sidKey then restoredIds[sidKey] = true end
					restored = restored + 1
					dprint(("Replaced invalid existing slime id=%s with SlimeFactory.RestoreFromSnapshot"):format(tostring(sid)))
					continue
				end
			end

			-- reposition/update transform robustly (same CF logic as create path)
			prim = existing.PrimaryPart or existing:FindFirstChildWhichIsA("BasePart")
			local usedRef = "<none>"
			if prim then
				local lpx = tonumber(e.lpx) or nil
				local lpy = tonumber(e.lpy) or nil
				local lpz = tonumber(e.lpz) or nil
				local px  = tonumber(e.px) or nil
				local py  = tonumber(e.py) or nil
				local pz  = tonumber(e.pz) or nil

				local targetCF = nil
				if origin and is_local_coords_present(lpx,lpy,lpz) then
					local sx, sy, sz = lpx or 0, lpy or 0, lpz or 0
					if math.abs(sx) > (MAX_LOCAL_COORD_MAG or 200) or math.abs(sz) > (MAX_LOCAL_COORD_MAG or 200) then
						sx = clamp_local(sx, MAX_LOCAL_COORD_MAG or 200)
						sz = clamp_local(sz, MAX_LOCAL_COORD_MAG or 200)
					end
					targetCF = origin.CFrame * CFrame.new(sx, sy or 0, sz)
					if e.lry then targetCF = targetCF * CFrame.Angles(0, tonumber(e.lry) or 0, 0) end
					usedRef = "origin"
				elseif plot and is_local_coords_present(lpx,lpy,lpz) then
					local okp, plotPivot = pcall(function() return plot:GetPivot() end)
					if okp and plotPivot then
						local sx, sy, sz = lpx or 0, lpy or 0, lpz or 0
						if math.abs(sx) > (MAX_LOCAL_COORD_MAG or 200) or math.abs(sz) > (MAX_LOCAL_COORD_MAG or 200) then
							sx = clamp_local(sx, MAX_LOCAL_COORD_MAG or 200); sz = clamp_local(sz, MAX_LOCAL_COORD_MAG or 200)
						end
						targetCF = plotPivot * CFrame.new(sx, sy or 0, sz)
						if e.lry then targetCF = targetCF * CFrame.Angles(0, tonumber(e.lry) or 0, 0) end
						usedRef = "plotPivot"
					end
				else
					local ax, ay, az = px or prim.Position.X, py or prim.Position.Y, pz or prim.Position.Z
					targetCF = CFrame.new(ax, ay, az)
					if e.ry then targetCF = targetCF * CFrame.Angles(0, tonumber(e.ry) or 0, 0) end
					usedRef = "absolute"
				end

				-- simple CF validity guard
				local okCF, pos = pcall(function() return targetCF and targetCF.Position end)
				if okCF and pos and isFiniteNumber(pos.X) and isFiniteNumber(pos.Y) and isFiniteNumber(pos.Z) then
					local okAnch, prevA = pcall(function() return prim and prim.Anchored end)
					pcall(function() if prim then prim.Anchored = true end end)
					pcall(function() existing:PivotTo(targetCF) end)
					pcall(function() existing.Parent = parent end)
					-- restore anchor after short delay
					task.delay(2.5, function()
						pcall(function()
							if prim and prim.Parent then
								if okAnch then prim.Anchored = prevA else prim.Anchored = false end
							end
						end)
					end)
				else
					pcall(function() existing.Parent = parent end)
				end
			else
				-- as last resort, set parent
				pcall(function() existing.Parent = parent end)
			end

			-- ensure we register and start AI/weld
			pcall(function() ws_registerModel(player, existing) end)
			pcall(function()
				if ModelUtils and type(ModelUtils.AutoWeld) == "function" then pcall(function() ModelUtils.AutoWeld(existing, existing.PrimaryPart or existing:FindFirstChildWhichIsA("BasePart")) end) end
				if SlimeAI and type(SlimeAI.Start) == "function" then pcall(function() SlimeAI.Start(existing, nil) end) end
			end)

			restored = restored + 1
			if sidKey then restoredIds[sidKey] = true end
			table.insert(restoredModels, existing)
			dprint(("Updated existing slime id=%s for userId=%s using=%s"):format(tostring(sid), tostring(player and player.UserId or "<nil>"), tostring(usedRef or "<none>")))
			continue
		end

		-- No existing slime: prefer SlimeFactory.RestoreFromSnapshot when available (creates full model/template)
		if SlimeFactory and type(SlimeFactory.RestoreFromSnapshot) == "function" then
			local ok, new = pcall(function() return SlimeFactory.RestoreFromSnapshot(e, player or { UserId = (e.ow or (player and player.UserId) or nil) }, plot) end)
			if ok and new then
				-- SlimeFactory already parents to plot (pass 'plot' to factory), but ensure index & AI
				ws_registerModel(player or { UserId = (e.ow or (player and player.UserId) or nil) }, new)
				pcall(function() if SlimeAI and type(SlimeAI.Start) == "function" then SlimeAI.Start(new, nil) end end)
				table.insert(restoredModels, new)
				restored = restored + 1
				if sidKey then restoredIds[sidKey] = true end
				dprint(("Created slime via SlimeFactory id=%s for userId=%s"):format(tostring(sid), tostring(player and player.UserId or "<nil>")))
				continue
			else
				dprint(("SlimeFactory restore failed or returned nil; falling back to minimal create for id=%s"):format(tostring(sid)))
			end
		end

		-- Fallback minimal model creation (preserve serialized attributes so other systems can repair)
		local m = Instance.new("Model")
		m.Name = "Slime"
		local prim = Instance.new("Part")
		prim.Name = "Body"
		prim.Size = Vector3.new(2,2,2)
		prim.TopSurface = Enum.SurfaceType.Smooth
		prim.BottomSurface = Enum.SurfaceType.Smooth
		prim.Parent = m
		m.PrimaryPart = prim

		if e.id then m:SetAttribute("SlimeId", e.id) end
		m:SetAttribute("OwnerUserId", player and player.UserId or e.ow or nil)
		if persistentId then m:SetAttribute("OwnerPersistentId", persistentId) end

		for attr, short in pairs(WS_ATTR_MAP) do
			local v = e[short]
			if v ~= nil then
				if colorKeys[short] and type(v) == "string" then
					local c = ws_hexToColor3(v)
					if c then v = c end
				end
				m:SetAttribute(attr, v)
			end
		end
		if e.lg then m:SetAttribute("PersistedGrowthProgress", e.lg) end

		-- store restore coords for later reposition attempts
		if e.lpx then m:SetAttribute("RestoreLpx", e.lpx) end
		if e.lpy then m:SetAttribute("RestoreLpy", e.lpy) end
		if e.lpz then m:SetAttribute("RestoreLpz", e.lpz) end
		if e.px then m:SetAttribute("RestorePX", e.px) end
		if e.py then m:SetAttribute("RestorePY", e.py) end
		if e.pz then m:SetAttribute("RestorePZ", e.pz) end

		m:SetAttribute("PreserveOnServer", true)
		m:SetAttribute("RestoreStamp", tick())
		m.Parent = parent

		-- position fallback: try local->plot->absolute similar to earlier logic
		local lpx = tonumber(e.lpx)
		local lpy = tonumber(e.lpy)
		local lpz = tonumber(e.lpz)
		local px  = tonumber(e.px)
		local py  = tonumber(e.py)
		local pz  = tonumber(e.pz)
		local targetCF, usedRef = nil, "<none>"
		if origin and is_local_coords_present(lpx,lpy,lpz) then
			local sx, sy, sz = lpx or 0, lpy or 0, lpz or 0
			if math.abs(sx) > (MAX_LOCAL_COORD_MAG or 200) or math.abs(sz) > (MAX_LOCAL_COORD_MAG or 200) then
				sx = clamp_local(sx, MAX_LOCAL_COORD_MAG or 200); sz = clamp_local(sz, MAX_LOCAL_COORD_MAG or 200)
			end
			targetCF = origin.CFrame * CFrame.new(sx, sy or 0, sz)
			if e.lry then targetCF = targetCF * CFrame.Angles(0, tonumber(e.lry) or 0, 0) end
			usedRef = "origin"
		elseif plot and is_local_coords_present(lpx,lpy,lpz) then
			local okp, plotPivot = pcall(function() return plot:GetPivot() end)
			if okp and plotPivot then
				local sx, sy, sz = lpx or 0, lpy or 0, lpz or 0
				if math.abs(sx) > (MAX_LOCAL_COORD_MAG or 200) or math.abs(sz) > (MAX_LOCAL_COORD_MAG or 200) then
					sx = clamp_local(sx, MAX_LOCAL_COORD_MAG or 200); sz = clamp_local(sz, MAX_LOCAL_COORD_MAG or 200)
				end
				targetCF = plotPivot * CFrame.new(sx, sy or 0, sz)
				if e.lry then targetCF = targetCF * CFrame.Angles(0, tonumber(e.lry) or 0, 0) end
				usedRef = "plotPivot"
			end
		else
			targetCF = CFrame.new(px or 0, py or 0, pz or 0)
			if e.ry then targetCF = targetCF * CFrame.Angles(0, tonumber(e.ry) or 0, 0) end
			usedRef = "absolute"
		end

		local ok, pos = pcall(function() return targetCF and targetCF.Position end)
		if ok and pos and isFiniteNumber(pos.X) and isFiniteNumber(pos.Y) and isFiniteNumber(pos.Z) then
			pcall(function() prim.Anchored = true end)
			pcall(function() m:PivotTo(targetCF) end)
			pcall(function() ws_registerModel(player or { UserId = (e.ow or (player and player.UserId) or nil) }, m) end)
			task.delay(2.5, function()
				pcall(function() prim.Anchored = false end)
			end)
		else
			pcall(function() ws_registerModel(player or { UserId = (e.ow or (player and player.UserId) or nil) }, m) end)
		end

		restored = restored + 1
		if sidKey then restoredIds[sidKey] = true end
		table.insert(restoredModels, m)
		dprint(("Fallback-created slime id=%s parent=%s using=%s"):format(tostring(e.id), tostring(parent and parent:GetFullName()), tostring(usedRef or "<none>")))
	end

	-- If we restored into Workspace while plot still absent, schedule deferred reposition to plot (keeps previous behavior)
	if (not we_findPlayerPlot_by_userid((player and player.UserId) or nil)) and #restoredModels > 0 then
		task.spawn(function()
			local attempts = 12
			for i=1,attempts do
				task.wait(0.25)
				local plotNow = nil
				pcall(function() plotNow = we_findPlayerPlot_by_userid(player and player.UserId or nil) end)
				if plotNow then
					local originNow = _we_getPlotOrigin(plotNow)
					for _, mm in ipairs(restoredModels) do
						if mm and mm.Parent then
							local lpx = mm:GetAttribute("RestoreLpx")
							local lpy = mm:GetAttribute("RestoreLpy")
							local lpz = mm:GetAttribute("RestoreLpz")
							if originNow and lpx and lpz then
								local ok2, newCF = pcall(function()
									return originNow.CFrame * CFrame.new(tonumber(lpx) or 0, tonumber(lpy) or 0, tonumber(lpz) or 0)
								end)
								if ok2 and newCF then
									local prim = mm.PrimaryPart or mm:FindFirstChildWhichIsA("BasePart")
									local okAnch, prevA = pcall(function() return prim and prim.Anchored end)
									pcall(function() if prim then prim.Anchored = true end end)
									pcall(function() mm:PivotTo(newCF) end)
									pcall(function() mm.Parent = plotNow end)
									task.delay(2.5, function()
										pcall(function()
											if prim and prim.Parent then
												if okAnch then prim.Anchored = prevA else prim.Anchored = false end
											end
										end)
									end)
								else
									pcall(function() mm.Parent = plotNow end)
									task.delay(2.5, function() pcall(function() local prim = mm.PrimaryPart or mm:FindFirstChildWhichIsA("BasePart"); if prim and prim.Parent then prim.Anchored = false end end) end)
								end
							else
								pcall(function() mm.Parent = plotNow end)
								task.delay(2.5, function() pcall(function() local prim = mm.PrimaryPart or mm:FindFirstChildWhichIsA("BasePart"); if prim and prim.Parent then prim.Anchored = false end end) end)
							end
						end
					end
					return
				end
			end
			-- cleanup anchors if no plot found
			for _, mm in ipairs(restoredModels) do
				task.delay(2.5, function() pcall(function() local prim = mm.PrimaryPart or mm:FindFirstChildWhichIsA("BasePart"); if prim and prim.Parent then prim.Anchored = false end end) end)
			end
		end)
	end
end

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

local function normalize_time_to_epoch(value, now_tick, now_os)
	if not value then return nil end
	local n = tonumber(value)
	if not n then return nil end
	if n > 1e8 then
		return n
	end
	if now_tick and now_os then
		return now_os + (n - now_tick)
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

local function we_restore(player, list)
	if not player or not list or #list == 0 then return end
	local now = os.time()
	local now_tick = tick()
	ws_scan(player)
	local plot = nil
	pcall(function() plot = we_findPlayerPlot_by_userid(player.UserId) end)
	if not plot then pcall(function() plot = we_findPlayerPlot(player) end) end
	local origin = we_getPlotOrigin(plot)
	local parent = plot or Workspace
	local persistentId = getPersistentIdFor(player)
	local restoredIds = {}
	local restored = 0
	local restoredModels = {}

	for _, e in ipairs(list) do
		if restored >= WECONFIG.MaxWorldEggsPerPlayer then break end
		local eggId = e.id
		if eggId and restoredIds[eggId] then
			dprint(("Skipping duplicate egg restore id=%s"):format(tostring(eggId)))
			continue
		end
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
		m:SetAttribute("OwnerUserId", player.UserId)
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
		local prim = m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart")
		if not prim then
			local part = Instance.new("Part")
			part.Name = "Handle"
			part.Size = Vector3.new(2,2,2)
			part.Parent = m
			m.PrimaryPart = part
			prim = part
		end
		m:SetAttribute("PreserveOnServer", true)
		m:SetAttribute("RestoreStamp", tick())
		-- store restore-local coords on the model (so deferred reposition can use them)
		if e.lpx or e.lpy or e.lz then
			if e.lpx then m:SetAttribute("RestoreLpx", e.lpx) end
			if e.lpy then m:SetAttribute("RestoreLpy", e.lpy) end
			if e.lz  then m:SetAttribute("RestoreLpz", e.lz) end
		end
		-- store absolute coords as backup
		if e.px or e.py or e.pz then
			if e.px then m:SetAttribute("RestorePX", e.px) end
			if e.py then m:SetAttribute("RestorePY", e.py) end
			if e.pz then m:SetAttribute("RestorePZ", e.pz) end
		end
		m.Parent = parent

		-- anchor while positioning
		local okAnchor, prevAnchored = pcall(function() return prim.Anchored end)
		pcall(function() prim.Anchored = true end)

		local targetCF = nil
		local lpx = safe_num(e.lpx)
		local lpy = safe_num(e.lpy)
		local lpz = safe_num(e.lz)
		local px  = safe_num(e.px)
		local py  = safe_num(e.py)
		local pz  = safe_num(e.pz)
		local function is_local_coords_present() return (lpx ~= nil) or (lpy ~= nil) or (lpz ~= nil) end
		local function clamp_local(v, maxmag)
			if not v then return v end
			if math.abs(v) > maxmag then
				return (v > 0) and maxmag or -maxmag
			end
			return v
		end
		if origin and is_local_coords_present() then
			local sx, sy, sz = lpx or 0, lpy or 0, lpz or 0
			if math.abs(sx) > MAX_LOCAL_COORD_MAG or math.abs(sz) > MAX_LOCAL_COORD_MAG then
				sx = clamp_local(sx, MAX_LOCAL_COORD_MAG)
				sz = clamp_local(sz, MAX_LOCAL_COORD_MAG)
			end
			targetCF = origin.CFrame * CFrame.new(sx, sy or 0, sz)
		elseif plot and is_local_coords_present() then
			local okp, plotPivot = pcall(function() return plot:GetPivot() end)
			if okp and plotPivot then
				local sx, sy, sz = lpx or 0, lpy or 0, lpz or 0
				if math.abs(sx) > MAX_LOCAL_COORD_MAG or math.abs(sz) > MAX_LOCAL_COORD_MAG then
					sx = clamp_local(sx, MAX_LOCAL_COORD_MAG)
					sz = clamp_local(sz, MAX_LOCAL_COORD_MAG)
				end
				targetCF = plotPivot * CFrame.new(sx, sy or 0, sz)
			end
		end
		if not targetCF then
			local ax, ay, az = px or 0, py or 0, pz or 0
			targetCF = CFrame.new(ax, ay, az)
		end

		-- Validate CF and fallback if invalid/out-of-range
		local function cfIsValid(cf)
			local ok, pos = pcall(function() return cf.Position end)
			if not ok or not pos then return false end
			if not (isFiniteNumber(pos.X) and isFiniteNumber(pos.Y) and isFiniteNumber(pos.Z)) then return false end
			return true
		end
		local function clampYToOrigin(cf, originObj)
			if not originObj then return cf end
			local pos = cf.Position
			local originY = originObj.Position and originObj.Position.Y or pos.Y
			local maxDelta = 2000
			if math.abs(pos.Y - originY) > maxDelta then
				return CFrame.new(pos.X, originY + 2, pos.Z)
			end
			return cf
		end

		if not cfIsValid(targetCF) then
			dprint("[we_restore] invalid targetCF computed; falling back to safe pivot/origin/ground")
			if origin then
				targetCF = origin.CFrame * CFrame.new(0, 2, 0)
			elseif plot then
				local ok, plotPivot = pcall(function() return plot:GetPivot() end)
				if ok and plotPivot then
					targetCF = plotPivot * CFrame.new(0, 2, 0)
				else
					targetCF = CFrame.new(0, 5, 0)
				end
			else
				targetCF = CFrame.new(0, 5, 0)
			end
		else
			if origin then targetCF = clampYToOrigin(targetCF, origin) end
		end

		-- Extra guard: if targetCF Y extremely high or low relative to workspace (abs > 1e5), clamp
		local pyCheck = targetCF.Position and targetCF.Position.Y or nil
		if pyCheck and (math.abs(pyCheck) > 1e5 or not isFiniteNumber(pyCheck)) then
			if origin then
				targetCF = origin.CFrame * CFrame.new(0, 2, 0)
			else
				targetCF = CFrame.new(0,5,0)
			end
		end

		pcall(function() m:PivotTo(targetCF) end)

		-- restore anchoring after a delay
		task.delay(3.5, function()
			pcall(function()
				if prim and prim.Parent then
					if okAnchor then
						prim.Anchored = prevAnchored
					else
						prim.Anchored = false
					end
				end
				if m and m.Parent then
					pcall(function()
						m:SetAttribute("RestoreStamp", nil)
						m:SetAttribute("PreserveOnServer", nil)
					end)
				end
			end)
		end)

		restored = restored + 1
		if eggId then restoredIds[eggId] = true end
		table.insert(restoredModels, m)
	end

	-- If we restored to Workspace (no plot) attempt deferred reparent + reposition (same logic as we_restore_by_userid)
	if not we_findPlayerPlot_by_userid(player.UserId) and #restoredModels > 0 then
		task.spawn(function()
			local attempts = 12
			for i=1,attempts do
				task.wait(0.25)
				local plotNow = we_findPlayerPlot_by_userid(player.UserId)
				if plotNow then
					local originNow = we_getPlotOrigin(plotNow)
					for _, mm in ipairs(restoredModels) do
						if mm and mm.Parent then
							local lpx = mm:GetAttribute("RestoreLpx")
							local lpy = mm:GetAttribute("RestoreLpy")
							local lpz = mm:GetAttribute("RestoreLpz")
							if originNow and lpx and lpz then
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
			-- no plot found; cleanup attributes on restored models
			for _, mm in ipairs(restoredModels) do
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
end

-- Replacement we_restore_by_userid (userId-path): dedupe+robust placement
-- Replacement we_restore_by_userid (userId-path): dedupe+robust placement
local function we_restore_by_userid(userId, list)
	if not userId or not list or #list == 0 then return end
	local now = os.time()
	local now_tick = tick()

	-- helper: find existing egg by EggId anywhere in workspace
	local function findExistingEggById(eggId)
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
			continue
		end

		-- If existing egg exists, update and reposition rather than duplicating
		local existing = eggId and findExistingEggById(eggId) or nil
		if existing then
			dprint(("we_restore_by_userid: found existing Egg for id=%s; updating"):format(tostring(eggId)))
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

			-- Ensure PrimaryPart
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

			-- store restore coords
			if e.lpx then existing:SetAttribute("RestoreLpx", e.lpx) end
			if e.lpy then existing:SetAttribute("RestoreLpy", e.lpy) end
			if e.lz or e.lpz then existing:SetAttribute("RestoreLpz", (e.lz or e.lpz)) end
			if e.px then existing:SetAttribute("RestorePX", e.px) end
			if e.py then existing:SetAttribute("RestorePY", e.py) end
			if e.pz then existing:SetAttribute("RestorePZ", e.pz) end

			-- reposition attempt
			local lpx = safe_num(e.lpx)
			local lpy = safe_num(e.lpy)
			local lpz = safe_num(e.lz or e.lpz)
			local px  = safe_num(e.px)
			local py  = safe_num(e.py)
			local pz  = safe_num(e.pz)
			local function is_local_coords_present() return lpx or lpy or lpz end
			local function clamp_local(v, maxmag)
				if not v then return v end
				if math.abs(v) > maxmag then return (v>0) and maxmag or -maxmag end
				return v
			end
			local targetCF = nil
			local usedRef = "<none>"
			if origin and is_local_coords_present() then
				local sx, sy, sz = lpx or 0, lpy or 0, lpz or 0
				if math.abs(sx) > MAX_LOCAL_COORD_MAG or math.abs(sz) > MAX_LOCAL_COORD_MAG then
					sx = clamp_local(sx, MAX_LOCAL_COORD_MAG); sz = clamp_local(sz, MAX_LOCAL_COORD_MAG)
				end
				targetCF = origin.CFrame * CFrame.new(sx, sy or 0, sz)
				usedRef = "origin"
			elseif plot and is_local_coords_present() then
				local okp, plotPivot = pcall(function() return plot:GetPivot() end)
				if okp and plotPivot then
					local sx, sy, sz = lpx or 0, lpy or 0, lpz or 0
					if math.abs(sx) > MAX_LOCAL_COORD_MAG or math.abs(sz) > MAX_LOCAL_COORD_MAG then
						sx = clamp_local(sx, MAX_LOCAL_COORD_MAG); sz = clamp_local(sz, MAX_LOCAL_COORD_MAG)
					end
					targetCF = plotPivot * CFrame.new(sx, sy or 0, sz)
					usedRef = "plotPivot"
				end
			else
				local ax, ay, az = px or 0, py or 0, pz or 0
				targetCF = CFrame.new(ax, ay, az)
				usedRef = "absolute"
			end

			local function cfIsValid(cf)
				if typeof then
					if typeof(cf) ~= "CFrame" then return false end
				else
					if type(cf) ~= "userdata" then return false end
				end
				local ok, pos = pcall(function() return cf.Position end)
				if not ok or not pos then return false end
				return (isFiniteNumber(pos.X) and isFiniteNumber(pos.Y) and isFiniteNumber(pos.Z))
			end
			local function clampYToOrigin(cf, originObj)
				if not originObj then return cf end
				local ok, pos = pcall(function() return cf.Position end)
				if not ok or not pos then return cf end
				local originY = originObj.Position and originObj.Position.Y or pos.Y
				local maxDelta = 2000
				if math.abs(pos.Y - originY) > maxDelta then
					return CFrame.new(pos.X, originY + 2, pos.Z)
				end
				return cf
			end

			if cfIsValid(targetCF) then
				if origin then targetCF = clampYToOrigin(targetCF, origin) end
				local okAnch, prevA = pcall(function() return prim and prim.Anchored end)
				pcall(function() if prim then prim.Anchored = true end end)
				pcall(function() existing:PivotTo(targetCF) end)
				pcall(function() existing.Parent = parent end)
				task.delay(3.5, function()
					pcall(function()
						if prim and prim.Parent then
							if okAnch then prim.Anchored = prevA else prim.Anchored = false end
						end
						pcall(function()
							existing:SetAttribute("RestoreStamp", nil)
							existing:SetAttribute("PreserveOnServer", nil)
						end)
					end)
				end)
			else
				pcall(function() existing.Parent = parent end)
			end

			restored = restored + 1
			if eggId then restoredIds[eggId] = true end
			table.insert(restoredModels, existing)
			dprint(("Updated existing egg id=%s for userId=%s using=%s"):format(tostring(eggId), tostring(userId), usedRef))
			continue
		end

		-- No existing egg: create as before (but robust)
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

		-- compute and validate CF
		local lpx = safe_num(e.lpx)
		local lpy = safe_num(e.lpy)
		local lpz = safe_num(e.lz or e.lpz)
		local px  = safe_num(e.px)
		local py  = safe_num(e.py)
		local pz  = safe_num(e.pz)
		local function is_local_coords_present() return lpx or lpy or lpz end
		local function clamp_local(v, maxmag)
			if not v then return v end
			if math.abs(v) > maxmag then
				return (v > 0) and maxmag or -maxmag
			end
			return v
		end
		local usedRef = "<none>"
		local targetCF = nil
		if origin and is_local_coords_present() then
			local sx, sy, sz = lpx or 0, lpy or 0, lpz or 0
			if math.abs(sx) > MAX_LOCAL_COORD_MAG or math.abs(sz) > MAX_LOCAL_COORD_MAG then
				sx = clamp_local(sx, MAX_LOCAL_COORD_MAG); sz = clamp_local(sz, MAX_LOCAL_COORD_MAG)
			end
			targetCF = origin.CFrame * CFrame.new(sx, sy or 0, sz)
			usedRef = "origin"
		elseif plot and is_local_coords_present() then
			local okp, plotPivot = pcall(function() return plot:GetPivot() end)
			if okp and plotPivot then
				local sx, sy, sz = lpx or 0, lpy or 0, lpz or 0
				if math.abs(sx) > MAX_LOCAL_COORD_MAG or math.abs(sz) > MAX_LOCAL_COORD_MAG then
					sx = clamp_local(sx, MAX_LOCAL_COORD_MAG); sz = clamp_local(sz, MAX_LOCAL_COORD_MAG)
				end
				targetCF = plotPivot * CFrame.new(sx, sy or 0, sz)
				usedRef = "plotPivot"
			end
		else
			local ax, ay, az = px or 0, py or 0, pz or 0
			targetCF = CFrame.new(ax, ay, az)
			usedRef = "absolute"
		end

		local function cfIsValid(cf)
			if typeof then
				if typeof(cf) ~= "CFrame" then return false end
			else
				if type(cf) ~= "userdata" then return false end
			end
			local ok, pos = pcall(function() return cf.Position end)
			if not ok or not pos then return false end
			if not (isFiniteNumber(pos.X) and isFiniteNumber(pos.Y) and isFiniteNumber(pos.Z)) then return false end
			return true
		end
		local function clampYToOrigin(cf, originObj)
			if not originObj then return cf end
			local ok, pos = pcall(function() return cf.Position end)
			if not ok or not pos then return cf end
			local originY = originObj.Position and originObj.Position.Y or pos.Y
			local maxDelta = 2000
			if math.abs(pos.Y - originY) > maxDelta then
				return CFrame.new(pos.X, originY + 2, pos.Z)
			end
			return cf
		end

		local okAnchor, prevAnchored = pcall(function() return prim and prim.Anchored end)
		pcall(function() prim.Anchored = true end)
		if not cfIsValid(targetCF) then
			dprint("[we_restore_by_userid] invalid targetCF computed; falling back to safe pivot/origin/ground (userId)", tostring(userId))
			if origin then
				targetCF = origin.CFrame * CFrame.new(0, 2, 0)
				usedRef = "origin_fallback"
			elseif plot then
				local ok, plotPivot = pcall(function() return plot:GetPivot() end)
				if ok and plotPivot then
					targetCF = plotPivot * CFrame.new(0, 2, 0)
					usedRef = "plotPivot_fallback"
				else
					targetCF = CFrame.new(0, 5, 0)
					usedRef = "abs_fallback"
				end
			else
				targetCF = CFrame.new(0, 5, 0)
				usedRef = "abs_fallback"
			end
		else
			if origin then targetCF = clampYToOrigin(targetCF, origin) end
		end

		pcall(function() m:PivotTo(targetCF) end)
		restored = restored + 1
		table.insert(restoredModels, m)
		if eggId then restoredIds[eggId] = true end
		dprint(("Created egg id=%s for userId=%s parent=%s using=%s"):format(tostring(e.id), tostring(userId), tostring(parent and parent:GetFullName()), usedRef))
	end

	-- deferred reposition/reparent if plot appears later
	if not we_findPlayerPlot_by_userid(userId) and #restoredModels > 0 then
		task.spawn(function()
			local attempts = 12
			for i=1,attempts do
				task.wait(0.25)
				local plotNow = we_findPlayerPlot_by_userid(userId)
				if plotNow then
					local originNow = we_getPlotOrigin(plotNow)
					for _, mm in ipairs(restoredModels) do
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
			for _, mm in ipairs(restoredModels) do
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
end
-- THIS IS THE SPLIT











-- FoodTool / EggTool code unchanged in general but left here for completeness (omitted commentary)

local FTCONFIG = GrandInventorySerializer.CONFIG.FoodTool
local FT_ATTRS = {
	FoodId="fid", RestoreFraction="rf", FeedBufferBonus="fb",
	Consumable="cs", Charges="ch", FeedCooldownOverride="cd",
	OwnerUserId="ow", ToolUniqueId="uid"
}
local ft_restoreBatchCounter=0
local function ft_dprint(...)
	if FTCONFIG.Debug then print("[FoodSer]", ...) end
end

local function ft_qualifies(tool)
	if not tool then return false end
	if type(tool.IsA) ~= "function" then return false end
	if not tool:IsA("Tool") then return false end
	return tool:GetAttribute("FoodItem") ~= nil or tool:GetAttribute("FoodId") ~= nil
end
local function ft_enumerate(container, out)
	if not container then return end
	for _,c in ipairs(container:GetChildren()) do
		if ft_qualifies(c) then out[#out+1]=c end
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
	for _,s in ipairs(ServerStorage:GetDescendants()) do
		if s:IsA("Tool") then
			local owner = s:GetAttribute("OwnerUserId")
			if owner and tostring(owner) == tostring(player.UserId) and ft_qualifies(s) then
				table.insert(out, s)
			end
		end
	end
	for _,tool in ipairs(out) do
		tool:SetAttribute("OwnerUserId", player.UserId)
	end
	return out
end

local function ft_findTemplate(fid)
	for _,folderName in ipairs(FTCONFIG.TemplateFolders) do
		local folder = ReplicatedStorage:FindFirstChild(folderName)
		if folder then
			if fid then
				local spec = folder:FindFirstChild(fid)
				if spec and spec:IsA("Tool") then return spec end
			end
			local generic = folder:FindFirstChild("Food")
			if generic and generic:IsA("Tool") then return generic end
		end
	end
	return nil
end

local function ft_ensureHandle(tool, size)
	if tool:FindFirstChild("Handle") then return end
	local h=Instance.new("Part")
	h.Name="Handle"
	h.Size=size or FTCONFIG.FallbackHandleSize
	h.TopSurface=Enum.SurfaceType.Smooth
	h.BottomSurface=Enum.SurfaceType.Smooth
	h.Parent=tool
end

local function ft_serialize(player, isFinal, profile)
	if (not player or type(player.FindFirstChildOfClass) ~= "function") and profile and type(profile) == "table" then
		if profile.inventory and profile.inventory.foodTools and #profile.inventory.foodTools > 0 then
			local copy = {}
			for i,v in ipairs(profile.inventory.foodTools) do copy[i] = v end
			return copy
		end
		return {}
	end
	local tools = ft_collectFood(player)
	local list = {}
	local seenUids = {}
	if FTCONFIG.AggregationMode == "individual" then
		for _,tool in ipairs(tools) do
			if tool:GetAttribute("ServerRestore") or tool:GetAttribute("ServerIssued") or tool:GetAttribute("PreserveOnServer") or tool:GetAttribute("PreserveOnClient") then
				continue
			end
			local entry = { nm = tool.Name }
			for attr, short in pairs(FT_ATTRS) do
				local v = tool:GetAttribute(attr)
				if v ~= nil then entry[short]=v end
			end
			entry.fid = entry.fid or tool:GetAttribute("FoodId") or tool.Name
			if not entry.uid or entry.uid == "" then
				local existing = tool:GetAttribute("ToolUniqueId") or tool:GetAttribute("ToolUid")
				if existing and existing ~= "" then
					entry.uid = existing
				else
					entry.uid = HttpService:GenerateGUID(false)
					tool:SetAttribute("ToolUniqueId", entry.uid)
				end
			end
			local uidKey = entry.uid and tostring(entry.uid) or nil
			if uidKey then
				if seenUids[uidKey] then
				else
					seenUids[uidKey] = true
					list[#list+1] = entry
				end
			else
				list[#list+1] = entry
			end
			if #list >= FTCONFIG.MaxFood then break end
		end
	end
	local prof = profile or safe_get_profile(player)
	if prof and prof.inventory and #list == 0 and type(prof.inventory.foodTools) == "table" and #prof.inventory.foodTools > 0 then
		local copy = {}
		for i,v in ipairs(prof.inventory.foodTools) do copy[i] = v end
		return copy
	end
	return list
end

local function ft_buildTool(entry, player)
	local template = ft_findTemplate(entry.fid or entry.nm)
	local tool
	if template then
		local ok,clone = pcall(function() return template:Clone() end)
		if ok and clone then tool=clone end
	end
	if not tool then
		tool=Instance.new("Tool")
		tool.Name = entry.nm or entry.fid or "Food"
		ft_ensureHandle(tool)
	else
		tool.Name = entry.nm or tool.Name
		ft_ensureHandle(tool)
	end
	tool:SetAttribute("FoodItem", true)
	tool:SetAttribute("FoodId", entry.fid or tool.Name)
	tool:SetAttribute("OwnerUserId", player.UserId)
	tool:SetAttribute("PersistentFoodTool", true)
	tool:SetAttribute("__FoodSerVersion", FTCONFIG.Version or "1.0")
	tool:SetAttribute("ToolUniqueId", entry.uid or HttpService:GenerateGUID(false))
	tool:SetAttribute("ServerIssued", true)
	tool:SetAttribute("ServerRestore", true)
	tool:SetAttribute("PreserveOnServer", true)
	tool:SetAttribute("RestoreStamp", tick())
	tool:SetAttribute("RestoreBatchId", os.time())
	return tool
end

local function ft_restoreImmediate(player, list, backpack)
	ft_restoreBatchCounter += 1
	local batch = ft_restoreBatchCounter
	ft_dprint(("entries=%d batch=%d"):format(#list, batch))
	local createdEntries={}
	for _,e in ipairs(list) do
		if #createdEntries >= FTCONFIG.MaxFood then break end
		if not e.uid or e.uid=="" then e.uid = HttpService:GenerateGUID(false) end
		local function findByUid(container)
			if not container then return nil end
			for _,it in ipairs(container:GetChildren()) do
				if it:IsA("Tool") then
					local tid = it:GetAttribute("ToolUniqueId") or it:GetAttribute("ToolUid")
					if tid and tostring(tid) == tostring(e.uid) then return it end
				end
			end
			return nil
		end
		local existing = findByUid(backpack) or findByUid(player.Character) or (function()
			for _,s in ipairs(ServerStorage:GetDescendants()) do
				if s:IsA("Tool") then
					local tid = s:GetAttribute("ToolUniqueId") or s:GetAttribute("ToolUid")
					if tid and tostring(tid) == tostring(e.uid) then return s end
				end
			end
			return nil
		end)()
		if existing then
			existing:SetAttribute("OwnerUserId", player.UserId)
			existing:SetAttribute("ServerRestore", true)
			existing:SetAttribute("PreserveOnServer", true)
			existing.Parent = backpack
			createdEntries[#createdEntries+1] = existing
		else
			local tool = ft_buildTool(e, player)
			tool:SetAttribute("ServerRestore", true)
			tool:SetAttribute("PreserveOnServer", true)
			tool.Parent = backpack
			createdEntries[#createdEntries+1] = tool
		end
	end
	local prof = safe_get_profile(player)
	local PPS = getPPS()
	if prof and type(prof) == "table" then
		if not prof.inventory then prof.inventory = {} end
		if prof.inventory.foodTools == nil or #prof.inventory.foodTools == 0 then
			prof.inventory.foodTools = prof.inventory.foodTools or {}
			for _,entry in ipairs(list) do table.insert(prof.inventory.foodTools, entry) end
			-- sanitize before saving
			if PPS then
				sanitizeInventoryOnProfile(prof)
				pcall(function() PPS.SaveNow(player, "GrandInvSer_FoodRestore") end)
			end
		end
	end
end

local function ft_restore(player, list)
	ft_dprint("[FoodSer][Restore] incoming list size=", list and #list or 0, "for", player and player.Name or "nil")
	if not list or #list==0 then return end
	local backpack = player and player:FindFirstChildOfClass("Backpack")
	if backpack then
		ft_restoreImmediate(player, list, backpack)
		return
	end
	local uid = tonumber((player and player.UserId) or (list and list[1] and list[1].OwnerUserId) or nil)
	local pid = nil
	if player then
		pid = getPersistentIdFor(player)
	end
	if not uid and player and player.UserId then uid = player.UserId end
	if uid then
		pendingRestores[uid] = pendingRestores[uid] or {}
		pendingRestores[uid].ft = pendingRestores[uid].ft or {}
		for _,e in ipairs(list) do table.insert(pendingRestores[uid].ft, e) end
		pendingRestores[uid].timeout = os.time() + PENDING_DEFAULT_TIMEOUT
		dprint(("Scheduled foodTools restore for userId=%s entries=%d"):format(tostring(uid), #pendingRestores[uid].ft))
		return
	end
	if pid then
		pendingRestoresByPersistentId[pid] = pendingRestoresByPersistentId[pid] or {}
		pendingRestoresByPersistentId[pid].ft = pendingRestoresByPersistentId[pid].ft or {}
		for _,e in ipairs(list) do table.insert(pendingRestoresByPersistentId[pid].ft, e) end
		pendingRestoresByPersistentId[pid].timeout = os.time() + PENDING_DEFAULT_TIMEOUT
		dprint(("Scheduled foodTools restore for persistentId=%s entries=%d"):format(tostring(pid), #pendingRestoresByPersistentId[pid].ft))
		return
	end
	ft_dprint("ft_restore: cannot determine userId or persistentId to schedule pending restore; aborting.")
end

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
		if tool:GetAttribute("ServerRestore") or tool:GetAttribute("ServerIssued") or tool:GetAttribute("PreserveOnServer") or tool:GetAttribute("PreserveOnClient") then
			continue
		end
		local entry = {
			EggId = tool:GetAttribute("EggId"),
			Rarity = tool:GetAttribute("Rarity"),
			HatchTime = tool:GetAttribute("HatchTime"),
			Weight = tool:GetAttribute("WeightScalar"),
			Move = tool:GetAttribute("MovementScalar"),
			ValueBase = tool:GetAttribute("ValueBase"),
			ValuePerGrowth = tool:GetAttribute("ValuePerGrowth"),
			ToolName = tool.Name,
			ToolUid = tool:GetAttribute("ToolUniqueId") or tool:GetAttribute("ToolUid") or nil,
			OwnerUserId = tool:GetAttribute("OwnerUserId") or player.UserId,
		}
		if not entry.ToolUid or entry.ToolUid == "" then
			if ETCONFIG.AssignUidIfMissingOnSerialize then
				entry.ToolUid = HttpService:GenerateGUID(false)
				tool:SetAttribute("ToolUniqueId", entry.ToolUid)
			end
		end
		local key = tostring(entry.ToolUid or entry.EggId or tool.Name)
		if not seen[key] then
			seen[key] = true
			table.insert(list, entry)
		end
		if #list >= ETCONFIG.MaxEggTools then break end
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

local function et_restoreImmediate(player, list, backpack)
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
			found:SetAttribute("ServerRestore", true)
			found:SetAttribute("PreserveOnServer", true)
			found.Parent = backpack
		else
			local tool = et_buildTool(entry, player)
			tool.Parent = backpack
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
				sanitizeInventoryOnProfile(prof)
				pcall(function() PPS.SaveNow(player, "GrandInvSer_EggRestore") end)
			end
		end
	end
end

local function et_restore(player, list)
	et_dprint("[ET][Restore] incoming count=", list and #list or 0, "for", player and player.Name or "nil")
	if not list or #list == 0 then return end
	local backpack = player and player:FindFirstChildOfClass("Backpack")
	if backpack then
		et_restoreImmediate(player, list, backpack)
		return
	end
	local uid = tonumber((player and player.UserId) or (list and list[1] and list[1].OwnerUserId) or nil)
	local pid = nil
	if player then pid = getPersistentIdFor(player) end
	if not uid and player and player.UserId then uid = player.UserId end
	if uid then
		pendingRestores[uid] = pendingRestores[uid] or {}
		pendingRestores[uid].et = pendingRestores[uid].et or {}
		for _,e in ipairs(list) do table.insert(pendingRestores[uid].et, e) end
		pendingRestores[uid].timeout = os.time() + PENDING_DEFAULT_TIMEOUT
		dprint(("Scheduled eggTools restore for userId=%s entries=%d"):format(tostring(uid), #pendingRestores[uid].et))
		return
	end
	if pid then
		pendingRestoresByPersistentId[pid] = pendingRestoresByPersistentId[pid] or {}
		pendingRestoresByPersistentId[pid].et = pendingRestoresByPersistentId[pid].et or {}
		for _,e in ipairs(list) do table.insert(pendingRestoresByPersistentId[pid].et, e) end
		pendingRestoresByPersistentId[pid].timeout = os.time() + PENDING_DEFAULT_TIMEOUT
		dprint(("Scheduled eggTools restore for persistentId=%s entries=%d"):format(tostring(pid), #pendingRestoresByPersistentId[pid].et))
		return
	end
	et_dprint("et_restore: cannot determine userId or persistentId to schedule pending restore; aborting.")
end

-- Replace the existing local function processPendingForPlayer(player) with this version.
-- Adds verbose debug traces to help diagnose missing pending restores.

local function processPendingForPlayer(player)
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
		dprint(("[processPendingForPlayer] found pendingRestoresByName[%s] (et=%d ft=%d we=%d) - merging into pendingRestores[%s]"):format(
			tostring(nameKey),
			(byName.et and #byName.et) or 0,
			(byName.ft and #byName.ft) or 0,
			(byName.we and #byName.we) or 0,
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
		pending.timeout = math.max(pending.timeout or 0, byName.timeout or 0)
		pendingRestoresByName[nameKey] = nil
	end

	local pid = getPersistentIdFor(player)
	if pid then
		local byPid = pendingRestoresByPersistentId[pid]
		if byPid then
			dprint(("[processPendingForPlayer] found pendingRestoresByPersistentId[%s] (et=%d ft=%d we=%d) - merging into pendingRestores[%s]"):format(
				tostring(pid),
				(byPid.et and #byPid.et) or 0,
				(byPid.ft and #byPid.ft) or 0,
				(byPid.we and #byPid.we) or 0,
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
			pending.timeout = math.max(pending.timeout or 0, byPid.timeout or 0)
			pendingRestoresByPersistentId[pid] = nil
		end
	end

	if not pending then
		dprint(("[processPendingForPlayer] no pending queue for uid=%s (name=%s) - nothing to do"):format(tostring(uid), tostring(nameKey)))
		return
	end

	-- Summarize pending contents
	dprint(("[processPendingForPlayer] merged pending for uid=%s name=%s -> et=%d ft=%d we=%d timeout=%s"):format(
		tostring(uid),
		tostring(nameKey),
		(pending.et and #pending.et) or 0,
		(pending.ft and #pending.ft) or 0,
		(pending.we and #pending.we) or 0,
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
			dprint(("[processPendingForPlayer] Backpack ready for uid=%s (name=%s). Applying pending: et=%d ft=%d we=%d"):format(
				tostring(uid),
				tostring(nameKey),
				(pending.et and #pending.et) or 0,
				(pending.ft and #pending.ft) or 0,
				(pending.we and #pending.we) or 0
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

-- Public helper: process pending restores for a Player instance (safe-guarded)
function GrandInventorySerializer.ProcessPendingForPlayer(player)
	if not player then return false end
	local ok, err = pcall(function()
		-- call the internal processor if available
		if type(processPendingForPlayer) == "function" then
			processPendingForPlayer(player)
		end
	end)
	if not ok then
		-- non-fatal: log if debug enabled
		dprint("ProcessPendingForPlayer error:", tostring(err))
	end
	return ok
end

-- Public helper: process pending restores for a userId (will look up Player and call above)
function GrandInventorySerializer.ProcessPendingForUserId(userId)
	if not userId then return false end
	local uid = tonumber(userId)
	if not uid then return false end
	local pl = Players:GetPlayerByUserId(uid)
	if pl then
		return GrandInventorySerializer.ProcessPendingForPlayer(pl)
	end
	-- player not online — cannot complete immediate processing
	return false
end


-- Debug / inspection helpers for pending restores
-- Insert immediately after ProcessPendingForPlayer / ProcessPendingForUserId

-- Returns a shallow snapshot table of pending restores and prints a short summary
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

	-- Print summary counts
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

	-- Print small details for each queue (first few items)
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

	-- Return the snapshot for programmatic inspection if caller wants it
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

	-- If a player with matching persistentId is online, process
	for _, pl in ipairs(Players:GetPlayers()) do
		local ok, ppid = pcall(function() return getPersistentIdFor(pl) end)
		if ok and ppid and tonumber(ppid) == pid then
			dprint("ProcessPendingForPersistentId: found online player", pl.Name, "-> calling ProcessPendingForPlayer")
			return GrandInventorySerializer.ProcessPendingForPlayer(pl)
		end
	end

	-- If not online, report whether any queued data exists for this persistentId
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
	-- If player online, call the processor
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

function GrandInventorySerializer.Serialize(...)
	local a1, a2 = _normalize_call_args({ ... })
	if type(a1) == "boolean" then
		local isFinal = a1 and true or false
		local prof = nil
		local out = {}
		local ok, res = pcall(function() return ws_serialize(nil, isFinal, prof) end)
		out.ws = ensureList((ok and res) and res or {}, "ws", nil)
		ok, res = pcall(function() return we_serialize(nil, isFinal, prof) end)
		out.we = ensureList((ok and res) and res or {}, "we", nil)
		ok, res = pcall(function() return et_serialize(nil, isFinal, prof) end)
		out.et = ensureList((ok and res) and res or {}, "et", nil)
		ok, res = pcall(function() return ft_serialize(nil, isFinal, prof) end)
		out.ft = ensureList((ok and res) and res or {}, "ft", nil)
		return out
	end
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
	out.ws = ensureList((ok and res) and res or {}, "ws", player)
	ok, res = pcall(function() return we_serialize(player, isFinal, prof) end)
	out.we = ensureList((ok and res) and res or {}, "we", player)
	ok, res = pcall(function() return et_serialize(player, isFinal, prof) end)
	out.et = ensureList((ok and res) and res or {}, "et", player)
	ok, res = pcall(function() return ft_serialize(player, isFinal, prof) end)
	out.ft = ensureList((ok and res) and res or {}, "ft", player)
	if isFinal and prof and type(prof) == "table" and prof.inventory then
		local inv = prof.inventory
		if out.et and #out.et == 0 and inv.eggTools and #inv.eggTools > 0 then
			local copy = {}
			for i,v in ipairs(inv.eggTools) do copy[i] = v end
			out.et = copy
		end
		if out.ft and #out.ft == 0 and inv.foodTools and #inv.foodTools > 0 then
			local copy = {}
			for i,v in ipairs(inv.foodTools) do copy[i] = v end
			out.ft = copy
		end
		if out.we and #out.we == 0 and inv.worldEggs and #inv.worldEggs > 0 then
			local copy = {}
			for i,v in ipairs(inv.worldEggs) do copy[i] = v end
			out.we = copy
		end
		if out.ws and #out.ws == 0 and inv.worldSlimes and #inv.worldSlimes > 0 then
			local copy = {}
			for i,v in ipairs(inv.worldSlimes) do copy[i] = v end
			out.ws = copy
		end
	end
	return out
end

-- Replace the existing GrandInventorySerializer.Restore(...) function with this version.
-- Adds diagnostic dprint() statements at all points where pending restores are scheduled
-- so we can observe why a restore may not be applied (which key it was stored under).
-- Replacement GrandInventorySerializer.Restore(...) that keeps original scheduling behavior
-- but attempts to immediately process pending restores when we can resolve an online player.
-- Paste this in place of the existing Restore(...) implementation.

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
	if type(a1) == "table" and (a1.ws ~= nil or a1.we ~= nil or a1.et ~= nil or a1.ft ~= nil) then
		payload = a1
	elseif type(a2) == "table" and (a2.ws ~= nil or a2.we ~= nil or a2.et ~= nil or a2.ft ~= nil) then
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
				or (inv.worldEggs and #inv.worldEggs>0) or (inv.worldSlimes and #inv.worldSlimes>0)
			if hasInv then
				payload = { ws = inv.worldSlimes or {}, we = inv.worldEggs or {}, et = inv.eggTools or {}, ft = inv.foodTools or {} }
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
	local function safeCount(t) if not t or type(t)~="table" then return 0 end return #t end
	dprint(("payload counts - ws=%d we=%d et=%d ft=%d"):format(safeCount(payload.ws), safeCount(payload.we), safeCount(payload.et), safeCount(payload.ft)))

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
					dprint(("Scheduling we_restore_by_userid for uid=%s entries=%d (pid=%s)"):format(tostring(uid), #filtered, tostring(pid)))
					pcall(function() we_restore_by_userid(uid, filtered) end)
				else
					dprint(("Filtered worldEggs -> no entries to restore for uid=%s (pid=%s)"):format(tostring(uid), tostring(pid)))
				end
			else
				local keyName = callerName or (profile and (profile.playerName or profile.name))
				local pid = nil
				if profile then pid = getPersistentIdFor(profile) end
				if keyName and type(keyName) == "string" and keyName ~= "" then
					local maybeUid = nil
					for _,pl in ipairs(Players:GetPlayers()) do
						if pl.Name == keyName then
							maybeUid = pl.UserId
							break
						end
					end
					local filtered = filterEggsAgainstLiveSlimes(payload.we, maybeUid, pid)
					if #filtered > 0 then
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

	-- Merge payload into in-memory profile if we have one (preserve existing behavior)
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
		mergeFieldIfNonEmpty("eggTools", payload.et, "et")
		mergeFieldIfNonEmpty("foodTools", payload.ft, "ft")
		mergeFieldIfNonEmpty("worldEggs", payload.we, "we")
		mergeFieldIfNonEmpty("worldSlimes", payload.ws, "ws")
		local applied = (inv.eggTools and #inv.eggTools>0) or (inv.foodTools and #inv.foodTools>0) or (inv.worldEggs and #inv.worldEggs>0) or (inv.worldSlimes and #inv.worldSlimes>0)
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
function GrandInventorySerializer.PreExitSync(...)
	local a1, a2 = _normalize_call_args({ ... })
	local player, profile = nil, nil

	-- Resolve player / profile similar to other functions
	if type(a1) == "table" and type(a1.FindFirstChildOfClass) == "function" then
		player = a1
	elseif type(a2) == "table" and type(a2.FindFirstChildOfClass) == "function" then
		player = a2
	end

	if type(a1) == "table" and a1.inventory ~= nil then
		profile = a1
	elseif type(a2) == "table" and a2.inventory ~= nil then
		profile = a2
	end

	if not profile and player then
		profile = safe_get_profile(player)
	end

	-- Try quick resolve from numeric/string args
	if not profile then
		if a1 ~= nil then
			profile = safe_wait_for_profile(a1, 1) or safe_get_profile(a1)
		end
		if not profile and a2 ~= nil then
			profile = safe_wait_for_profile(a2, 1) or safe_get_profile(a2)
		end
	end

	-- If we can find a player instance, or a profile with userId, gather live worldEggs
	local live_we = nil
	if player then
		-- returns list of live eggs for this player's plot
		local ok, list = pcall(function() return we_enumeratePlotEggs(player) end)
		if ok and type(list) == "table" then live_we = list end
	else
		-- try by profile userId
		local uid = tonumber((profile and (profile.userId or profile.UserId or profile.id)) or nil)
		if uid then
			local ok, list = pcall(function() return we_enumeratePlotEggs_by_userid(uid) end)
			if ok and type(list) == "table" then live_we = list end
		end
	end

	-- If we couldn't enumerate live eggs, fall back to nothing (we won't accidentally strip data)
	if not live_we then live_we = {} end

	-- Ensure profile exists and inventory shape is present
	if not profile and player then
		profile = safe_get_profile(player) or nil
	end
	if profile and type(profile) == "table" then
		profile.inventory = profile.inventory or {}
		-- Replace the profile's worldEggs with the live enumeration result (merged only if live list present)
		-- Only overwrite if we have a reliable live_we (empty list is a valid state if no eggs present)
		profile.inventory.worldEggs = live_we

		-- Sanitize inventory before saving to avoid DataStore issues
		pcall(function() sanitizeInventoryOnProfile(profile) end)

		-- Attempt to SaveNow via PPS if available
		local PPS = getPPS()
		if PPS and type(PPS.SaveNow) == "function" then
			if player and type(player.FindFirstChildOfClass) == "function" then
				pcall(function() PPS.SaveNow(player, "GrandInvSer_PreExitSync") end)
			else
				local uid = tonumber(profile.userId or profile.UserId or profile.id)
				if uid then
					pcall(function() PPS.SaveNow(uid, "GrandInvSer_PreExitSync") end)
				end
			end
		end
	end
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
}

return GrandInventorySerializer