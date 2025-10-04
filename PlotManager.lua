-- PlotManager (Robust, auto-initializing)
-- Version: 2.3
-- Behaviors:
--  - Automatically Init()s on require (defensive)
--  - Recursively discovers plot Models in Workspace by:
--      - name pattern Player%d+ OR
--      - attribute IsPlot=true OR
--      - attributes Index/PlotIndex/PlayerIndex
--  - Sorts discovered plots by Index (number parsed from name or Index attribute) for deterministic assignment
--  - Assigns already-connected players immediately and hooks PlayerAdded/CharacterAdded/PlayerRemoving
--  - Defensive/idempotent: safe to call Init repeatedly or to call Init without a bound self
--  - Provides placement API (RegisterPlacement, RemovePlacement, etc.) similar to the prior module

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
}

if WorldAssetCleanup and type(WorldAssetCleanup.Configure) == "function" then
	pcall(function()
		WorldAssetCleanup.Configure({
			IncludeNeutralOnLeave = PlotManager.Config.ClearNeutralFolderOnRelease,
			NeutralFolderName = PlotManager.Config.NeutralFolderName,
			NeutralPerPlayerSubfolders = PlotManager.Config.NeutralPerPlayerSubfolders,
		})
	end)
end

-- Public state (guarantee existence)
PlotManager.Plots = PlotManager.Plots or {}        -- array of Model
PlotManager.PlayerToPlot = PlotManager.PlayerToPlot or {} -- map userId -> Model

-- Internal placement storage
local placements = {}

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

-- Recursively discover plots anywhere in Workspace
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
					-- determine index
					local idxNum = nil
					if tonumber(idxAttr) then
						idxNum = tonumber(idxAttr)
					elseif nameMatch and tonumber(nameMatch) then
						idxNum = tonumber(nameMatch)
					else
						-- fallback: use next available index (will be sorted later)
						idxNum = nil
					end
					table.insert(found, { model = child, index = idxNum })
				end
			end
			if #child:GetChildren() > 0 then rec(child) end
		end
	end

	rec(Workspace)

	-- If none found by attributes/pattern, consider direct children PlayerN names as last resort
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

	-- Assign indexes where missing: use order of discovery and fill gaps
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

	-- Sort by index ascending
	table.sort(found, function(a,b) return (a.index or 0) < (b.index or 0) end)

	-- Build plots array
	local plots = {}
	for _,rec in ipairs(found) do
		tagPlot(rec.model, rec.index)
		table.insert(plots, rec.model)
	end

	return plots
end

-- Internal helpers for placement bookkeeping
local function ensureBucket(userId)
	local bucket = placements[userId]
	if not bucket then
		bucket = { list = {}, index = {} }
		placements[userId] = bucket
	end
	return bucket
end

-- Public API ---------------------------------------------------------------
function PlotManager:GetPlotOrigin(plot)
	if not plot then return nil end
	local direct = plot:FindFirstChild("SlimeZone")
	if direct and direct:IsA("BasePart") then return direct end
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
		warn(string.format("[PlotManager][DEBUG] No available plot for player '%s' (UserId=%d)",
			player.Name,
			player.UserId
			))
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

function PlotManager:AssignPlayer(player)
	if not player or not player.UserId then return nil end

	-- If already assigned and plot still valid, return it
	local existing = self.PlayerToPlot[player.UserId]
	if existing and existing.Parent and existing:GetAttribute("Occupied") then
		debugPlotAssignment(player, existing)
		return existing
	end

	-- Try to find an unoccupied plot
	for _, plot in ipairs(self.Plots) do
		if plot and plot.Parent and not plot:GetAttribute("Occupied") then
			plot:SetAttribute("Occupied", true)
			plot:SetAttribute("UserId", player.UserId)
			self.PlayerToPlot[player.UserId] = plot
			if player.SetAttribute and plot:GetAttribute(self.IndexAttribute) then
				pcall(function() player:SetAttribute("PlotIndex", plot:GetAttribute(self.IndexAttribute)) end)
			end
			dprint(("Assigned %s to plot %s"):format(player.Name, plot.Name))
			debugPlotAssignment(player, plot)
			return plot
		end
	end

	-- No plot available
	debugPlotAssignment(player, nil)
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
	cleanupOptions.neutralPerPlayerSubfolders = cleanupOptions.neutralPerPlayerSubfolders
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

	local opts = options or {}
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
		-- Clear assets first (respects config inside ClearPlot)
		self:ClearPlot(plot, player.UserId)
		if plot.Parent then
			plot:SetAttribute("Occupied", false)
			plot:SetAttribute("UserId", 0)
		end
	end
	self.PlayerToPlot[player.UserId] = nil
	placements[player.UserId] = nil -- Clear placement records
	dprint(("Released plot for %s"):format(player.Name))
end

-- Character spawn -----------------------------------------------------------
function PlotManager:FindSpawnPart(plotModel)
	if not plotModel then return nil end
	local spawnPart = plotModel:FindFirstChild("Spawn")
	if spawnPart and spawnPart:IsA("BasePart") then
		return spawnPart
	end
	for _, d in ipairs(plotModel:GetDescendants()) do
		if d:IsA("BasePart") then return d end
	end
	return nil
end

function PlotManager:OnCharacterAdded(player, character)
	local plot = self:GetPlayerPlot(player)
	if not plot then
		pcall(function() self:AssignPlayer(player) end)
		plot = self:GetPlayerPlot(player)
		if not plot then
			dprint(("OnCharacterAdded: no plot for %s; spawn will use default spawn"):format(player.Name))
			return
		end
	end
	local spawnPart = self:FindSpawnPart(plot)
	if spawnPart then
		local hrp = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 5)
		if hrp then
			pcall(function() hrp.CFrame = spawnPart.CFrame + Vector3.new(0, 3, 0) end)
		end
	end
end

-- Initialization ------------------------------------------------------------
function PlotManager:Init()
	-- Make safe if invoked without colon (self == nil)
	if not self then self = PlotManager end

	if self._initialized then
		dprint("Init() already called; skipping.")
		return self
	end
	self._initialized = true

	-- Ensure tables exist
	self.Plots = self.Plots or {}
	self.PlayerToPlot = self.PlayerToPlot or {}

	-- Discover plots (recursive)
	local ok, plots = pcall(discoverPlotsRecursive)
	if not ok then
		warn("[PlotManager] discoverPlotsRecursive failed:", plots)
		plots = {}
	end
	self.Plots = plots or {}

	dprint(("PlotManager initialized. Plots discovered: %d"):format(#self.Plots))

	-- Hook PlayerAdded and PlayerRemoving
	Players.PlayerAdded:Connect(function(player)
		pcall(function()
			if not self.PlayerToPlot[player.UserId] then
				local assigned = self:AssignPlayer(player)
				if not assigned then
					if player.SetAttribute then
						pcall(function() player:SetAttribute("PlotIndex", 0) end)
					end
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

	-- Assign plots for players already connected
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

	return self
end

-- Auto-init on require (server-side). This ensures module self-initializes even if loader didn't call Init.
-- Only auto-init when running on server (ServerScriptService); avoid running in client contexts.
local function autoInitIfServer()
	if RunService:IsServer() then
		-- Defer slightly to allow other modules that run immediately on require to finish (helps ordering races)
		task.defer(function()
			pcall(function() PlotManager:Init() end)
		end)
	end
end

autoInitIfServer()

return PlotManager