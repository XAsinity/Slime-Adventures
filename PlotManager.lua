-- PlotManager (Robust, auto-initializing)
-- Version: 2.6 (force teleport on assign, zone attribute mirroring, explicit registration, assignment lock, per-user assign serialization)
-- Notes:
--  - Adds ForceTeleportOnAssign: teleports player to their plot spawn immediately after assignment (not only on CharacterAdded)
--  - Mirrors assignment to a plot's SlimeZone (AssignedUserId/ZoneOccupied) when enabled
--  - Optional explicit plot registration via PlotManager:RegisterPlot(...) and a BindableEvent "RegisterPlot"
--  - Stronger attribute normalization & discovery remain

local Players     = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local Workspace   = game:GetService("Workspace")
local RunService  = game:GetService("RunService")

local PlotManager = {}

local function tryRequire(name)
	local candidates = {}
	if script and script.Parent then table.insert(candidates, script.Parent) end
	if script and script.Parent and script.Parent.Parent then table.insert(candidates, script.Parent.Parent) end
	local SSS = game:GetService("ServerScriptService")
	if SSS then
		table.insert(candidates, SSS)
		local modules = SSS:FindFirstChild("Modules")
		if modules then table.insert(candidates, modules) end
	end
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	if ReplicatedStorage then
		table.insert(candidates, ReplicatedStorage)
		local repModules = ReplicatedStorage:FindFirstChild("Modules")
		if repModules then table.insert(candidates, repModules) end
	end
	for _, container in ipairs(candidates) do
		local inst = container and container:FindFirstChild(name)
		if inst and inst:IsA("ModuleScript") then
			local ok, mod = pcall(function() return require(inst) end)
			if ok and type(mod) == "table" then
				return mod
			end
		end
	end
	return nil
end

local WorldAssetCleanup = tryRequire("WorldAssetCleanup")

-- Config --------------------------------------------------------------------
PlotManager.IndexAttribute = PlotManager.IndexAttribute or "Index"
PlotManager.MaxPlayers = PlotManager.MaxPlayers or 6
PlotManager.PlotNamePattern = PlotManager.PlotNamePattern or "^Player(%d+)$"
PlotManager.Config = PlotManager.Config or {
	ClearOwnedAssetsOnRelease = false,
	ClearNeutralFolderOnRelease = false,
	NeutralFolderName = "Slimes",
	NeutralPerPlayerSubfolders = true,
	Debug = false,
	SpawnAssignmentWaitSeconds = 1.5,
	SpawnAssignmentReattempts = 2,
	SpawnAssignmentCheckInterval = 0.05,
}
if PlotManager.Config.MirrorZoneAttributes == nil then
	PlotManager.Config.MirrorZoneAttributes = true
else
	PlotManager.Config.MirrorZoneAttributes = PlotManager.Config.MirrorZoneAttributes and true or false
end
if PlotManager.Config.AllowExplicitRegistration == nil then
	PlotManager.Config.AllowExplicitRegistration = true
else
	PlotManager.Config.AllowExplicitRegistration = PlotManager.Config.AllowExplicitRegistration and true or false
end
if PlotManager.Config.UseExplicitRegistrationOnly == nil then
	PlotManager.Config.UseExplicitRegistrationOnly = false
else
	PlotManager.Config.UseExplicitRegistrationOnly = PlotManager.Config.UseExplicitRegistrationOnly and true or false
end
-- NEW: force teleport immediately after assignment
if PlotManager.Config.ForceTeleportOnAssign == nil then
	PlotManager.Config.ForceTeleportOnAssign = true
else
	PlotManager.Config.ForceTeleportOnAssign = PlotManager.Config.ForceTeleportOnAssign and true or false
end

if WorldAssetCleanup and type(WorldAssetCleanup.Configure) == "function" then
	pcall(function()
		WorldAssetCleanup.Configure({
			IncludeNeutralOnLeave = PlotManager.Config.ClearNeutralFolderOnRelease,
			NeutralFolderName = PlotManager.Config.NeutralFolderName,
			NeutralPerPlayerSubfolders = PlotManager.Config.NeutralPerPlayerSubfolders,
		})
	end)
end

-- Public state
PlotManager.Plots = PlotManager.Plots or {}               -- array of Model
PlotManager.PlayerToPlot = PlotManager.PlayerToPlot or {} -- map userId -> Model

-- Internal placement storage (for user-placed models tracked via RegisterPlacement)
local placements = {}

-- Handshake keys
local ATTR_PLOT_ASSIGNED_NAME = "PlotAssignedName"
local ATTR_PLOT_ASSIGNED_AT = "PlotAssignedAt"

-- Utilities -----------------------------------------------------------------
local function dprint(...)
	if PlotManager.Config and PlotManager.Config.Debug then
		print("[PlotManager]", ...)
	end
end

local function generateGuid()
	local ok,g = pcall(HttpService.GenerateGUID, HttpService, false)
	if ok and g then return g end
	return string.format("%08x-%04x-%04x-%04x-%04x%08x",
		math.random(0,0xFFFFFFFF), math.random(0,0xFFFF),
		math.random(0,0xFFFF), math.random(0,0xFFFF),
		math.random(0,0xFFFF), math.random(0,0xFFFFFFFF))
end

local function isModel(x) return typeof(x) == "Instance" and x:IsA("Model") end

local function safePrimary(model)
	if not model then return nil end
	if model.PrimaryPart then return model.PrimaryPart end
	for _,d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			model.PrimaryPart = d
			return d
		end
	end
	return nil
end

local function cloneShallow(tbl)
	if not tbl then return nil end
	local t = {}
	for k,v in pairs(tbl) do t[k]=v end
	return t
end

local function tagPlot(plotModel, index)
	if not plotModel or not plotModel:IsA("Model") then return end
	if plotModel:GetAttribute("Occupied") == nil then
		plotModel:SetAttribute("Occupied", false)
	end
	if plotModel:GetAttribute("UserId") == nil then
		plotModel:SetAttribute("UserId", 0)
	end
	if index then
		plotModel:SetAttribute(PlotManager.IndexAttribute, index)
	end
end

-- Normalize plot attributes
local function normalizePlotAttributes(plotModel)
	if not plotModel or not plotModel:IsA("Model") then return end
	local function safeGetAttr(k) local ok,v = pcall(function() return plotModel:GetAttribute(k) end) if ok then return v end return nil end
	local function safeSetAttr(k, v) pcall(function() plotModel:SetAttribute(k, v) end) end

	local assigned = safeGetAttr("AssignedUserId") or safeGetAttr("AssignedUid") or safeGetAttr("AssignedUser") or nil
	local userIdAttr = safeGetAttr("UserId") or safeGetAttr("OwnerUserId") or safeGetAttr("User") or nil
	local persistent = safeGetAttr("AssignedPersistentId") or safeGetAttr("PersistentId") or safeGetAttr("OwnerPersistentId") or nil

	local uid = assigned and (tonumber(assigned) or assigned) or (userIdAttr and (tonumber(userIdAttr) or userIdAttr)) or nil
	if uid then
		local num = tonumber(uid) or uid
		safeSetAttr("UserId", num)
		safeSetAttr("AssignedUserId", num)
		safeSetAttr("OwnerUserId", num)
	end
	if persistent then
		safeSetAttr("AssignedPersistentId", tostring(persistent))
		safeSetAttr("PersistentId", tostring(persistent))
	end
end

-- SlimeZone helpers (inlined)
local function _findZonePart(plotModel)
	if not plotModel then return nil end
	-- Prefer explicit "Spawn" first (so plates named Spawn are honored)
	local spawn = plotModel:FindFirstChild("Spawn")
	if spawn and spawn:IsA("BasePart") then return spawn end
	-- Then prefer "SlimeZone"
	local zone = plotModel:FindFirstChild("SlimeZone")
	if zone and zone:IsA("BasePart") then return zone end
	for _, d in ipairs(plotModel:GetDescendants()) do
		if d:IsA("BasePart") and (d.Name == "Spawn" or d.Name == "SlimeZone") then
			return d
		end
	end
	for _, d in ipairs(plotModel:GetDescendants()) do
		if d:IsA("BasePart") then return d end
	end
	return nil
end

local function _ensureZoneDefaults(zone)
	if not zone then return end
	pcall(function()
		if zone:GetAttribute("AssignedUserId") == nil then zone:SetAttribute("AssignedUserId", 0) end
		if zone:GetAttribute("AssignedPersistentId") == nil then zone:SetAttribute("AssignedPersistentId", "") end
		if zone:GetAttribute("ZoneOccupied") == nil then zone:SetAttribute("ZoneOccupied", false) end
	end)
end

PlotManager.Zone = PlotManager.Zone or {}

function PlotManager.Zone.ReserveIfAvailable(plotModel, userId, persistentId)
	if not plotModel then return false, "no-plot" end
	local zone = _findZonePart(plotModel)
	if not zone then return false, "no-zone" end
	_ensureZoneDefaults(zone)
	local cur = tonumber(zone:GetAttribute("AssignedUserId")) or 0
	if cur ~= 0 then return false, "occupied" end
	pcall(function()
		zone:SetAttribute("AssignedUserId", tonumber(userId) or 0)
		zone:SetAttribute("AssignedPersistentId", persistentId and tostring(persistentId) or "")
		zone:SetAttribute("AssignedAt", os.time())
		zone:SetAttribute("ZoneOccupied", (userId and userId ~= 0) and true or false)
	end)
	pcall(function()
		plotModel:SetAttribute("AssignedUserId", tonumber(userId) or 0)
		plotModel:SetAttribute("AssignedPersistentId", persistentId and tostring(persistentId) or "")
		plotModel:SetAttribute("PlotAssignedAt", os.time())
	end)
	return true
end

function PlotManager.Zone.ForceAssign(plotModel, userId, persistentId)
	if not plotModel then return false, "no-plot" end
	local zone = _findZonePart(plotModel)
	if zone then
		pcall(function()
			zone:SetAttribute("AssignedUserId", tonumber(userId) or 0)
			zone:SetAttribute("AssignedPersistentId", persistentId and tostring(persistentId) or "")
			zone:SetAttribute("AssignedAt", os.time())
			zone:SetAttribute("ZoneOccupied", (userId and userId ~= 0) and true or false)
		end)
	end
	pcall(function()
		plotModel:SetAttribute("AssignedUserId", tonumber(userId) or 0)
		plotModel:SetAttribute("AssignedPersistentId", persistentId and tostring(persistentId) or "")
		plotModel:SetAttribute("PlotAssignedAt", os.time())
	end)
	return true
end

function PlotManager.Zone.ClearAssignment(plotModel)
	if not plotModel then return false, "no-plot" end
	local zone = _findZonePart(plotModel)
	if zone then
		pcall(function()
			zone:SetAttribute("AssignedUserId", 0)
			zone:SetAttribute("AssignedPersistentId", "")
			zone:SetAttribute("AssignedAt", nil)
			zone:SetAttribute("ZoneOccupied", false)
		end)
	end
	pcall(function()
		plotModel:SetAttribute("AssignedUserId", 0)
		plotModel:SetAttribute("AssignedPersistentId", "")
		plotModel:SetAttribute("PlotAssignedAt", nil)
	end)
	return true
end

-- Discovery -----------------------------------------------------------------
local function discoverPlotsRecursive()
	local found = {}

	local function rec(parent)
		for _,child in ipairs(parent:GetChildren()) do
			if child:IsA("Model") then
				local nameMatch = nil
				if type(child.Name) == "string" then
					nameMatch = child.Name:match(PlotManager.PlotNamePattern)
				end
				local isPlotAttr = child:GetAttribute("IsPlot")
				local idxAttr = child:GetAttribute(PlotManager.IndexAttribute) or child:GetAttribute("PlotIndex") or child:GetAttribute("PlayerIndex")

				if nameMatch or isPlotAttr or idxAttr then
					local idxNum = nil
					if tonumber(idxAttr) then
						idxNum = tonumber(idxAttr)
					elseif nameMatch and tonumber(nameMatch) then
						idxNum = tonumber(nameMatch)
					end
					table.insert(found, { model = child, index = idxNum })
				end
			end
			if #child:GetChildren() > 0 then rec(child) end
		end
	end

	rec(Workspace)

	if #found == 0 then
		for _,child in ipairs(Workspace:GetChildren()) do
			if child:IsA("Model") and type(child.Name) == "string" then
				local m = child.Name:match(PlotManager.PlotNamePattern)
				if m then
					table.insert(found, { model = child, index = tonumber(m) })
				end
			end
		end
	end

	local nextIdx = 1
	for _,rec in ipairs(found) do
		if not rec.index then
			while true do
				local taken = false
				for _,r2 in ipairs(found) do
					if r2.index == nextIdx then taken = true; break end
				end
				if not taken then break end
				nextIdx = nextIdx + 1
			end
			rec.index = nextIdx
			nextIdx = nextIdx + 1
		end
	end

	table.sort(found, function(a,b) return (a.index or 0) < (b.index or 0) end)

	local plots = {}
	for _,rec in ipairs(found) do
		tagPlot(rec.model, rec.index)
		normalizePlotAttributes(rec.model)
		table.insert(plots, rec.model)
	end

	return plots
end

-- Placement bookkeeping (for systems that opt-in to it) ---------------------
local function ensureBucket(userId)
	local bucket = placements[userId]
	if not bucket then
		bucket = { list = {}, index = {} }
		placements[userId] = bucket
	end
	return bucket
end

local function setPlotAssignedOnPlayer(player, plot)
	if not player then return end
	pcall(function()
		if player.SetAttribute then
			player:SetAttribute(ATTR_PLOT_ASSIGNED_NAME, plot and plot.Name or nil)
			player:SetAttribute(ATTR_PLOT_ASSIGNED_AT, plot and os.time() or nil)
		end
	end)
end

-- Assignment locks and per-user assign guard --------------------------------
local _assignmentLocks = setmetatable({}, { __mode = "k" })
local function acquirePlotLock(plot)
	if not plot then return false end
	if _assignmentLocks[plot] then return false end
	_assignmentLocks[plot] = true
	return true
end
local function releasePlotLock(plot)
	if plot then _assignmentLocks[plot] = nil end
end

local _assignInFlight = {}
local function acquireUserAssign(userId)
	if not userId then return false end
	if _assignInFlight[userId] then return false end
	_assignInFlight[userId] = true
	return true
end
local function releaseUserAssign(userId)
	if userId then _assignInFlight[userId] = nil end
end

-- Public API ---------------------------------------------------------------
function PlotManager:GetPlotOrigin(plot)
	if not plot then return nil end
	-- Prefer "Spawn", then "SlimeZone"
	local spawn = plot:FindFirstChild("Spawn")
	if spawn and spawn:IsA("BasePart") then return spawn end
	local direct = plot:FindFirstChild("SlimeZone")
	if direct and direct:IsA("BasePart") then return direct end
	for _,d in ipairs(plot:GetDescendants()) do
		if d:IsA("BasePart") and (d.Name == "Spawn" or d.Name == "SlimeZone") then return d end
	end
	for _,d in ipairs(plot:GetDescendants()) do
		if d:IsA("BasePart") then return d end
	end
	return nil
end

function PlotManager:WorldToLocal(plot, worldCF)
	local origin = self:GetPlotOrigin(plot)
	if not origin then return worldCF end
	return origin.CFrame:ToObjectSpace(worldCF)
end

function PlotManager:LocalToWorld(plot, localCF)
	local origin = self:GetPlotOrigin(plot)
	if not origin then return localCF end
	return origin.CFrame * localCF
end

-- Explicit registration API
function PlotManager:RegisterPlot(plotModel, index)
	if not plotModel or not plotModel:IsA("Model") then return false end
	tagPlot(plotModel, index)
	normalizePlotAttributes(plotModel)
	pcall(function() plotModel:SetAttribute("IsPlot", true) end)
	for _, m in ipairs(self.Plots) do
		if m == plotModel then
			return true
		end
	end
	table.insert(self.Plots, plotModel)
	table.sort(self.Plots, function(a,b)
		local ai = tonumber(a:GetAttribute(self.IndexAttribute)) or math.huge
		local bi = tonumber(b:GetAttribute(self.IndexAttribute)) or math.huge
		return ai < bi
	end)
	dprint(("RegisterPlot: %s (Index=%s)"):format(plotModel.Name, tostring(index or plotModel:GetAttribute(self.IndexAttribute) or "?")))
	return true
end

-- Placement helpers (unchanged API)
function PlotManager:RegisterPlacement(player, modelOrCF, kind, extra)
	if not player or not player:IsA("Player") then
		return nil, nil, "InvalidPlayer"
	end
	if type(kind) ~= "string" or kind == "" then
		return nil, nil, "InvalidKind"
	end
	local plot = self:GetPlayerPlot(player)
	if not plot then
		return nil, nil, "PlayerHasNoPlot"
	end

	local worldCF
	local model
	if isModel(modelOrCF) then
		model = modelOrCF
		local prim = safePrimary(model)
		if prim then
			worldCF = model:GetPivot()
		else
			worldCF = CFrame.new()
		end
	else
		if typeof(modelOrCF) ~= "CFrame" then
			return nil, nil, "NeedModelOrCFrame"
		end
		worldCF = modelOrCF
	end

	local localCF = self:WorldToLocal(plot, worldCF)

	local bucket = ensureBucket(player.UserId)
	local id = generateGuid()
	local record = {
		id = id,
		kind = kind,
		time = os.time(),
		localCF = localCF,
		worldCF = worldCF,
		extra = cloneShallow(extra),
		model = model,
	}

	table.insert(bucket.list, record)
	bucket.index[id] = record

	if model then
		model:SetAttribute("PlacementId", id)
		model:SetAttribute("PlacementKind", kind)
		model:SetAttribute("OwnerUserId", model:GetAttribute("OwnerUserId") or player.UserId)
		local pos = localCF.Position
		model:SetAttribute("LocalPX", pos.X)
		model:SetAttribute("LocalPY", pos.Y)
		model:SetAttribute("LocalPZ", pos.Z)
	end

	return id, record
end

function PlotManager:UpdatePlacementCF(player, placementId, newWorldCF)
	local plot = self:GetPlayerPlot(player)
	if not plot then return false end
	local bucket = placements[player.UserId]; if not bucket then return false end
	local rec = bucket.index[placementId]; if not rec then return false end
	if typeof(newWorldCF) ~= "CFrame" then return false end
	rec.worldCF = newWorldCF
	rec.localCF = self:WorldToLocal(plot, newWorldCF)
	if rec.model and rec.model.Parent then
		pcall(function() rec.model:PivotTo(newWorldCF) end)
	end
	return true
end

function PlotManager:RemovePlacement(player, placementId)
	local bucket = placements[player.UserId]; if not bucket then return false end
	local rec = bucket.index[placementId]; if not rec then return false end
	bucket.index[placementId] = nil
	for i,r in ipairs(bucket.list) do
		if r.id == placementId then
			table.remove(bucket.list, i)
			break
		end
	end
	if rec.model and rec.model.Parent then
		rec.model:SetAttribute("PlacementId", nil)
		rec.model:SetAttribute("PlacementKind", nil)
	end
	return true
end

function PlotManager:GetPlacements(player)
	local bucket = placements[player.UserId]
	if not bucket then return {} end
	local out = {}
	for _,rec in ipairs(bucket.list) do
		table.insert(out, {
			id = rec.id,
			kind = rec.kind,
			time = rec.time,
			localCF = rec.localCF,
			worldCF = rec.worldCF,
			extra = cloneShallow(rec.extra),
		})
	end
	return out
end

function PlotManager:FindPlacementByModel(model)
	if not isModel(model) then return nil end
	local pid = model:GetAttribute("PlacementId")
	if not pid then return nil end
	local ownerUserId = model:GetAttribute("OwnerUserId")
	if ownerUserId and placements[ownerUserId] then
		return placements[ownerUserId].index[pid]
	end
	for _,bucket in pairs(placements) do
		local rec = bucket.index[pid]
		if rec then return rec end
	end
	return nil
end

function PlotManager:ReanchorAll(player)
	local plot = self:GetPlayerPlot(player)
	if not plot then return end
	local bucket = placements[player.UserId]
	if not bucket then return end
	for _,rec in ipairs(bucket.list) do
		rec.worldCF = self:LocalToWorld(plot, rec.localCF)
		if rec.model and rec.model.Parent then
			pcall(function() rec.model:PivotTo(rec.worldCF) end)
		end
	end
end

-- Spawn helpers -------------------------------------------------------------
function PlotManager:FindSpawnPart(plotModel)
	if not plotModel then return nil end
	local spawnPart = plotModel:FindFirstChild("Spawn")
	if spawnPart and spawnPart:IsA("BasePart") then
		return spawnPart
	end
	local zone = plotModel:FindFirstChild("SlimeZone")
	if zone and zone:IsA("BasePart") then
		return zone
	end
	for _, d in ipairs(plotModel:GetDescendants()) do
		if d:IsA("BasePart") and (d.Name == "Spawn" or d.Name == "SlimeZone") then return d end
	end
	for _, d in ipairs(plotModel:GetDescendants()) do
		if d:IsA("BasePart") then return d end
	end
	return nil
end

function PlotManager:_teleportPlayerToPlotSpawn(player, plot)
	if not player or not plot then return end
	local character = player.Character
	if not character then return end
	local hrp = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 3)
	if not hrp then return end
	local spawnPart = self:FindSpawnPart(plot)
	if not spawnPart then return end
	pcall(function()
		hrp.CFrame = spawnPart.CFrame + Vector3.new(0, 3, 0)
	end)
	dprint(("[SPAWN_DEBUG] Player %s (uid=%s) teleported to plot=%s spawn"):format(player.Name, tostring(player.UserId), plot.Name))
end

-- Plot assignment -----------------------------------------------------------
local function debugPlotAssignment(player, plot)
	if plot then
		print(string.format("[PlotManager][DEBUG] Assigned plot '%s' (Index=%s) to player '%s' (UserId=%d)",
			plot.Name,
			tostring(plot:GetAttribute(PlotManager.IndexAttribute)),
			player.Name,
			player.UserId
			))
	else
		warn(string.format("[PlotManager][DEBUG] No available plot for player '%s' (UserId=%d)", player.Name, player.UserId))
	end
end

function PlotManager:GetPlayerPlot(player)
	if not player then return nil end
	return self.PlayerToPlot[player.UserId]
end

function PlotManager:GetPlotByUserId(userId)
	local uid = tonumber(userId)
	if not uid then return nil end
	return self.PlayerToPlot[uid]
end

function PlotManager:GetPlotByPersistentId(persistentId)
	if persistentId == nil then return nil end
	for _,plot in ipairs(self.Plots) do
		if plot and plot.Parent then
			local pid = plot:GetAttribute("AssignedPersistentId") or plot:GetAttribute("PersistentId")
			if pid ~= nil and tostring(pid) == tostring(persistentId) then
				return plot
			end
		end
	end
	return nil
end

function PlotManager:FindPlotForUserWithFallback(playerOrUserId, persistentId)
	local userId = nil
	local playerObj = nil
	if typeof(playerOrUserId) == "Instance" and playerOrUserId:IsA("Player") then
		playerObj = playerOrUserId
		userId = playerOrUserId.UserId
		persistentId = persistentId or (playerOrUserId.GetAttribute and playerOrUserId:GetAttribute("PersistentId"))
	else
		userId = tonumber(playerOrUserId)
	end

	if not persistentId and playerObj and playerObj.GetAttribute then
		pcall(function()
			local pid = playerObj:GetAttribute("PersistentId")
			if pid and type(pid) == "string" then persistentId = pid end
		end)
	end

	if not persistentId and playerObj then
		local pps = tryRequire("PlayerProfileService")
		if pps and type(pps.GetOrAssignPersistentId) == "function" then
			local ok, pid = pcall(function() return pps.GetOrAssignPersistentId(playerObj) end)
			if ok and pid then persistentId = pid end
		end
	end

	local candidates = {}
	for _,plot in ipairs(self.Plots) do
		if plot and plot.Parent then
			local assignedUid = plot:GetAttribute("AssignedUserId")
			local plotUid = plot:GetAttribute("UserId")
			local assignedPid = plot:GetAttribute("AssignedPersistentId") or plot:GetAttribute("PersistentId")

			if assignedUid and userId and tonumber(assignedUid) == tonumber(userId) then
				table.insert(candidates, {plot=plot, score=100, reason="AssignedUserId"})
			elseif assignedPid and persistentId and tostring(assignedPid) == tostring(persistentId) then
				table.insert(candidates, {plot=plot, score=95, reason="AssignedPersistentId"})
			elseif plotUid and userId and tonumber(plotUid) == tonumber(userId) then
				table.insert(candidates, {plot=plot, score=90, reason="UserId"})
			else
				local foundOwner = false
				for _,desc in ipairs(plot:GetDescendants()) do
					if desc.GetAttribute then
						local o = desc:GetAttribute("OwnerUserId")
						if o and userId and tonumber(o) == tonumber(userId) then
							table.insert(candidates, {plot=plot, score=50, reason="OwnerUserId"})
							foundOwner = true
							break
						end
					end
				end
				if not foundOwner and playerObj and plot:GetAttribute(self.IndexAttribute) and playerObj.GetAttribute and playerObj:GetAttribute("PlotIndex") then
					local pidx = playerObj:GetAttribute("PlotIndex")
					local midx = plot:GetAttribute(self.IndexAttribute)
					if pidx and midx and tonumber(pidx) == tonumber(midx) then
						table.insert(candidates, {plot=plot, score=40, reason="PlotIndexMatch"})
					end
				end
			end
		end
	end

	if #candidates == 0 and playerObj and playerObj.GetAttribute and playerObj:GetAttribute("PlotIndex") then
		local wantIdx = playerObj:GetAttribute("PlotIndex")
		for _,plot in ipairs(self.Plots) do
			if plot and plot.Parent then
				local pidx = plot:GetAttribute(self.IndexAttribute)
				if pidx and tonumber(pidx) == tonumber(wantIdx) then
					table.insert(candidates, {plot=plot, score=30, reason="NameIndexFallback"})
				end
			end
		end
	end

	if #candidates == 0 then
		return nil
	end

	for _,c in ipairs(candidates) do
		if self:GetPlotOrigin(c.plot) then
			c.score = c.score + 5
		end
	end

	table.sort(candidates, function(a,b)
		if a.score == b.score then
			local ai = a.plot:GetAttribute(PlotManager.IndexAttribute) or 0
			local bi = b.plot:GetAttribute(PlotManager.IndexAttribute) or 0
			return ai < bi
		end
		return a.score > b.score
	end)

	return candidates[1].plot
end

function PlotManager:WaitForPlotAssignment(player, timeoutSeconds)
	if not player then return nil end
	if type(timeoutSeconds) ~= "number" then timeoutSeconds = PlotManager.Config.SpawnAssignmentWaitSeconds or 1.5 end
	local start = os.clock()
	if not player.GetAttribute then return nil end
	local assigned = nil
	pcall(function() assigned = player:GetAttribute(ATTR_PLOT_ASSIGNED_NAME) end)
	while (not assigned) and (os.clock() - start) < timeoutSeconds do
		task.wait(PlotManager.Config.SpawnAssignmentCheckInterval or 0.05)
		pcall(function() assigned = player:GetAttribute(ATTR_PLOT_ASSIGNED_NAME) end)
	end
	return assigned
end

function PlotManager:AssignPlayer(player)
	if not player or not player.UserId then return nil end
	local userId = player.UserId

	local gotUserLock = acquireUserAssign(userId)
	if not gotUserLock then
		local waitStart = os.clock()
		while _assignInFlight[userId] and (os.clock() - waitStart) < 0.5 do
			task.wait(0.03)
		end
		releaseUserAssign(userId)
		return self.PlayerToPlot[userId]
	end

	local ok, result = pcall(function()
		local existing = self.PlayerToPlot[userId]
		if existing and existing.Parent and existing:GetAttribute("Occupied") then
			normalizePlotAttributes(existing)
			setPlotAssignedOnPlayer(player, existing)
			debugPlotAssignment(player, existing)
			if PlotManager.Config.MirrorZoneAttributes then
				pcall(function() PlotManager.Zone.ForceAssign(existing, userId, existing:GetAttribute("AssignedPersistentId")) end)
			end
			if PlotManager.Config.ForceTeleportOnAssign then
				task.defer(function() self:_teleportPlayerToPlotSpawn(player, existing) end)
			end
			return existing
		end

		local persistentId = nil
		pcall(function() persistentId = (player.GetAttribute and player:GetAttribute("PersistentId")) end)

		local preMarked = self:FindPlotForUserWithFallback(player, persistentId)
		if preMarked and preMarked.Parent then
			if acquirePlotLock(preMarked) then
				local successAssign = false
				local occupied = preMarked:GetAttribute("Occupied")
				local ownerId = preMarked:GetAttribute("UserId")
				if (not occupied) or tonumber(ownerId) == tonumber(userId) then
					preMarked:SetAttribute("Occupied", true)
					preMarked:SetAttribute("UserId", userId)
					pcall(function() preMarked:SetAttribute("AssignedUserId", userId) end)
					pcall(function() preMarked:SetAttribute("OwnerUserId", userId) end)
					if persistentId then
						pcall(function() preMarked:SetAttribute("AssignedPersistentId", tostring(persistentId)) end)
					end

					normalizePlotAttributes(preMarked)

					self.PlayerToPlot[userId] = preMarked
					if player.SetAttribute and preMarked:GetAttribute(self.IndexAttribute) then
						pcall(function() player:SetAttribute("PlotIndex", preMarked:GetAttribute(self.IndexAttribute)) end)
					end
					setPlotAssignedOnPlayer(player, preMarked)
					if PlotManager.Config.MirrorZoneAttributes then
						pcall(function() PlotManager.Zone.ForceAssign(preMarked, userId, persistentId) end)
					end
					if PlotManager.Config.ForceTeleportOnAssign then
						task.defer(function() self:_teleportPlayerToPlotSpawn(player, preMarked) end)
					end
					dprint(("Assigned (pre-marked) %s to plot %s"):format(player.Name, preMarked.Name))
					debugPlotAssignment(player, preMarked)
					successAssign = true
				end
				releasePlotLock(preMarked)

				if successAssign and (not persistentId) then
					pcall(function()
						local pps = tryRequire("PlayerProfileService")
						if pps and type(pps.GetOrAssignPersistentId) == "function" then
							local ok2, pid = pcall(function() return pps.GetOrAssignPersistentId(player) end)
							if ok2 and pid then
								persistentId = pid
								pcall(function() preMarked:SetAttribute("AssignedPersistentId", tostring(pid)) end)
								if PlotManager.Config.MirrorZoneAttributes then
									pcall(function() PlotManager.Zone.ForceAssign(preMarked, userId, pid) end)
								end
							end
						end
					end)
					return preMarked
				end
				if successAssign then return preMarked end
			end
		end

		for _, plot in ipairs(self.Plots) do
			if plot and plot.Parent then
				if not plot:GetAttribute("Occupied") then
					if acquirePlotLock(plot) then
						local assigned = false
						local occNow = plot:GetAttribute("Occupied")
						if not occNow then
							local quickPid = nil
							pcall(function() quickPid = (player.GetAttribute and player:GetAttribute("PersistentId")) end)
							plot:SetAttribute("Occupied", true)
							plot:SetAttribute("UserId", userId)
							plot:SetAttribute("OwnerUserId", userId)
							pcall(function() plot:SetAttribute("AssignedUserId", userId) end)
							if quickPid then
								pcall(function() plot:SetAttribute("AssignedPersistentId", tostring(quickPid)) end)
							end

							normalizePlotAttributes(plot)

							self.PlayerToPlot[userId] = plot
							if player.SetAttribute and plot:GetAttribute(self.IndexAttribute) then
								pcall(function() player:SetAttribute("PlotIndex", plot:GetAttribute(self.IndexAttribute)) end)
							end
							setPlotAssignedOnPlayer(player, plot)
							if PlotManager.Config.MirrorZoneAttributes then
								pcall(function() PlotManager.Zone.ForceAssign(plot, userId, quickPid) end)
							end
							if PlotManager.Config.ForceTeleportOnAssign then
								task.defer(function() self:_teleportPlayerToPlotSpawn(player, plot) end)
							end
							dprint(("Assigned %s to plot %s"):format(player.Name, plot.Name))
							debugPlotAssignment(player, plot)
							assigned = true
						end
						releasePlotLock(plot)

						if assigned then
							pcall(function()
								local pps = tryRequire("PlayerProfileService")
								if pps and type(pps.GetOrAssignPersistentId) == "function" then
									local ok2, pid = pcall(function() return pps.GetOrAssignPersistentId(player) end)
									if ok2 and pid then
										pcall(function() plot:SetAttribute("AssignedPersistentId", tostring(pid)) end)
										if PlotManager.Config.MirrorZoneAttributes then
											pcall(function() PlotManager.Zone.ForceAssign(plot, userId, pid) end)
										end
									end
								end
							end)
							return plot
						end
					end
				end
			end
		end

		debugPlotAssignment(player, nil)
		return nil
	end)

	releaseUserAssign(userId)
	if ok then return result end
	return nil
end

function PlotManager:ClearPlot(plot, userId, options)
	if not plot or not plot.Parent or not userId then return end
	local opts = options or {}
	if opts.force ~= true and not PlotManager.Config.ClearOwnedAssetsOnRelease then
		dprint(("ClearPlot skipped (config disabled) for userId=%d on plot=%s"):format(userId, plot.Name))
		return
	end
	local cleanupOptions = {
		neutral = opts.neutral,
		neutralFolderName = opts.neutralFolderName,
		neutralPerPlayerSubfolders = opts.neutralPerPlayerSubfolders,
	}
	if cleanupOptions.neutral == nil then
		cleanupOptions.neutral = PlotManager.Config.ClearNeutralFolderOnRelease
	end
	cleanupOptions.neutralFolderName = cleanupOptions.neutralFolderName or PlotManager.Config.NeutralFolderName
	if cleanupOptions.neutralPerPlayerSubfolders == nil then
		cleanupOptions.neutralPerPlayerSubfolders = PlotManager.Config.NeutralPerPlayerSubfolders
	end
	if WorldAssetCleanup and type(WorldAssetCleanup.CleanupPlot) == "function" then
		local ok = pcall(function()
			WorldAssetCleanup.CleanupPlot(plot, userId, cleanupOptions)
		end)
		if ok then
			dprint(("[ClearPlot] Cleared via WorldAssetCleanup for userId=%d on plot=%s"):format(userId, plot.Name))
			return
		else
			warn("[PlotManager] WorldAssetCleanup.CleanupPlot failed; falling back to legacy clear")
		end
	end
	local function clearOwnedAssetsInContainer(container)
		if not container then return end
		for _,desc in ipairs(container:GetDescendants()) do
			if desc:IsA("Model") then
				local owner = desc:GetAttribute("OwnerUserId")
				if owner == userId then
					if desc:GetAttribute("SlimeId") or desc:GetAttribute("EggId")
						or desc.Name == "Slime" or desc.Name == "Egg"
						or desc:GetAttribute("Placed") then
						pcall(function() desc:Destroy() end)
					end
				end
			elseif desc:IsA("BasePart") then
				local owner = desc:GetAttribute("OwnerUserId")
				if owner == userId then
					pcall(function() desc:Destroy() end)
				end
			end
		end
	end

	clearOwnedAssetsInContainer(plot)

	local doNeutral = opts.neutral
	if doNeutral == nil then
		doNeutral = PlotManager.Config.ClearNeutralFolderOnRelease
	end
	if doNeutral then
		local root = Workspace:FindFirstChild(PlotManager.Config.NeutralFolderName)
		if root then
			if PlotManager.Config.NeutralPerPlayerSubfolders then
				for _,sub in ipairs(root:GetChildren()) do
					if sub:IsA("Folder") then
						clearOwnedAssetsInContainer(sub)
					end
				end
			else
				clearOwnedAssetsInContainer(root)
			end
		end
	end
	dprint(("[ClearPlot] Cleared owned assets for userId=%d on plot=%s"):format(userId, plot.Name))
end

function PlotManager:ClearPlayerPlot(player, options)
	if not player or not player:IsA("Player") then return end
	local plot = self.PlayerToPlot[player.UserId]
	if plot then
		self:ClearPlot(plot, player.UserId, options)
	end
end

function PlotManager:ReleasePlayer(player)
	if not player or not player.UserId then return end
	local plot = self.PlayerToPlot[player.UserId]
	if plot then
		if WorldAssetCleanup and type(WorldAssetCleanup.ScheduleCleanup) == "function" then
			pcall(function()
				WorldAssetCleanup.ScheduleCleanup(player.UserId, plot, {
					neutral = PlotManager.Config.ClearNeutralFolderOnRelease,
					neutralFolderName = PlotManager.Config.NeutralFolderName,
					neutralPerPlayerSubfolders = PlotManager.Config.NeutralPerPlayerSubfolders,
				})
			end)
		end
		self:ClearPlot(plot, player.UserId)
		if plot.Parent then
			plot:SetAttribute("Occupied", false)
			plot:SetAttribute("UserId", 0)
			pcall(function() plot:SetAttribute("AssignedUserId", nil) end)
			pcall(function() plot:SetAttribute("AssignedPersistentId", nil) end)
			pcall(function() plot:SetAttribute("OwnerUserId", nil) end)
			if PlotManager.Config.MirrorZoneAttributes then
				pcall(function() PlotManager.Zone.ClearAssignment(plot) end)
			end
		end
	end
	if player and player.SetAttribute then
		pcall(function()
			player:SetAttribute(ATTR_PLOT_ASSIGNED_NAME, nil)
			player:SetAttribute(ATTR_PLOT_ASSIGNED_AT, nil)
		end)
	end
	self.PlayerToPlot[player.UserId] = nil
	placements[player.UserId] = nil
	dprint(("Released plot for %s"):format(player.Name))
end

-- Character spawn -----------------------------------------------------------
function PlotManager:OnCharacterAdded(player, character)
	local userId = player and player.UserId
	-- Slightly longer, more robust wait
	local reattempts = (PlotManager.Config.SpawnAssignmentReattempts or 2) + 1
	local timeout = tonumber(PlotManager.Config.SpawnAssignmentWaitSeconds) or 1.5
	local interval = PlotManager.Config.SpawnAssignmentCheckInterval or 0.05

	local function checkAssignmentConsistent()
		local plot = self:GetPlayerPlot(player)
		if not plot then return false, nil end
		local pname = nil
		pcall(function() pname = (player.GetAttribute and player:GetAttribute(ATTR_PLOT_ASSIGNED_NAME)) end)
		if pname and pname == plot.Name and plot:GetAttribute("Occupied") then
			return true, plot
		end
		local pidx = nil
		pcall(function() pidx = (player.GetAttribute and player:GetAttribute("PlotIndex")) end)
		local midx = plot:GetAttribute(self.IndexAttribute)
		if pidx and midx and tonumber(pidx) == tonumber(midx) and plot:GetAttribute("Occupied") then
			return true, plot
		end
		return false, plot
	end

	local finalPlot = nil
	for attempt = 1, reattempts do
		local start = os.clock()
		repeat
			local ok2, plot = checkAssignmentConsistent()
			if ok2 and plot then
				finalPlot = plot
				break
			end
			task.wait(interval)
		until (os.clock() - start) >= timeout

		if finalPlot then break end
		pcall(function() self:AssignPlayer(player) end)
	end

	if not finalPlot then
		local ok3, plot = checkAssignmentConsistent()
		if ok3 then finalPlot = plot end
	end

	if not finalPlot then
		pcall(function() self:AssignPlayer(player) end)
		finalPlot = self:GetPlayerPlot(player)
	end

	if not finalPlot then
		dprint(("OnCharacterAdded: no plot for %s; spawn will use default spawn"):format(player.Name))
		return
	end

	-- Teleport now (also happens on assign if ForceTeleportOnAssign)
	self:_teleportPlayerToPlotSpawn(player, finalPlot)
end

-- Initialization ------------------------------------------------------------
function PlotManager:Init()
	if not self then self = PlotManager end
	if self._initialized then
		dprint("Init() already called; skipping.")
		return self
	end
	self._initialized = true

	self.Plots = self.Plots or {}
	self.PlayerToPlot = self.PlayerToPlot or {}

	if PlotManager.Config.UseExplicitRegistrationOnly then
		self.Plots = {}
		dprint("Plot discovery skipped (UseExplicitRegistrationOnly=true). Awaiting RegisterPlot calls.")
	else
		local ok, plots = pcall(discoverPlotsRecursive)
		if not ok then
			warn("[PlotManager] discoverPlotsRecursive failed:", plots)
			plots = {}
		end
		self.Plots = plots or {}
	end

	for _, p in ipairs(self.Plots) do
		pcall(function() normalizePlotAttributes(p) end)
	end

	if PlotManager.Config.AllowExplicitRegistration then
		local SSS = game:GetService("ServerScriptService")
		local modulesFolder = SSS:FindFirstChild("Modules") or SSS
		local be = modulesFolder:FindFirstChild("RegisterPlot")
		if not be then
			local created = Instance.new("BindableEvent")
			created.Name = "RegisterPlot"
			created.Parent = modulesFolder
			be = created
		end
		be.Event:Connect(function(model, idx)
			pcall(function() self:RegisterPlot(model, idx) end)
		end)
	end

	dprint(("PlotManager initialized. Plots discovered: %d"):format(#self.Plots))

	Players.PlayerAdded:Connect(function(player)
		pcall(function()
			if not self.PlayerToPlot[player.UserId] then
				local assigned = self:AssignPlayer(player)
				if not assigned and player.SetAttribute then
					pcall(function() player:SetAttribute("PlotIndex", 0) end)
				end
			else
				local plot = self.PlayerToPlot[player.UserId]
				if plot and plot:GetAttribute(self.IndexAttribute) and player.SetAttribute then
					pcall(function() player:SetAttribute("PlotIndex", plot:GetAttribute(self.IndexAttribute)) end)
				end
			end

			player.CharacterAdded:Connect(function(character)
				task.defer(function()
					pcall(function() self:OnCharacterAdded(player, character) end)
				end)
			end)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		task.delay(8, function()
			if Players:GetPlayerByUserId(player.UserId) then return end
			pcall(function() self:ReleasePlayer(player) end)
		end)
	end)

	for _,pl in ipairs(Players:GetPlayers()) do
		pcall(function()
			if not self.PlayerToPlot[pl.UserId] then
				local assigned = self:AssignPlayer(pl)
				if assigned and pl.Character then
					pcall(function() self:OnCharacterAdded(pl, pl.Character) end)
				end
			else
				local plot = self.PlayerToPlot[pl.UserId]
				if plot and plot:GetAttribute(self.IndexAttribute) and pl.SetAttribute then
					pcall(function() pl:SetAttribute("PlotIndex", plot:GetAttribute(self.IndexAttribute)) end)
				end
			end
		end)
	end

	function PlotManager.SyncPlotAttributes()
		for _, plot in ipairs(PlotManager.Plots) do
			pcall(function() normalizePlotAttributes(plot) end)
		end
		dprint("SyncPlotAttributes: normalized attributes for all discovered plots")
	end

	return self
end

local function autoInitIfServer()
	if RunService:IsServer() then
		task.defer(function()
			pcall(function() PlotManager:Init() end)
		end)
	end
end

autoInitIfServer()

return PlotManager