-- PlotManager (Robust Placement & Local Coordinate System + Plot Asset Clearing)
-- Version: 2.1 (Aug 2025)
--
-- Changes in 2.1:
--   * Added automatic server-side clearing of player-owned dynamic assets (slimes, eggs, decor, any
--     model or part with attribute OwnerUserId == player.UserId) from their plot when they leave.
--   * Added optional clearing of the player's neutral slime subfolder (if enabled).
--   * Added public APIs:
--       PlotManager:ClearPlayerPlot(player [, options])
--       PlotManager:ClearPlot(plot, userId [, options])
--     (options.neutral=true to also clear neutral folder; default uses internal config.)
--   * Players.PlayerRemoving connection added in :Init() to perform ReleasePlayer + Clear.
--   * ReleasePlayer now calls internal _ClearOwnedAssets before freeing the plot.
--
-- Goals (original):
--   * Preserve simple plot assignment API (AssignPlayer, GetPlayerPlot, etc.).
--   * Per-player placement registry storing LOCAL transforms for re-anchoring.
--   * Origin chosen by SlimeZone part or fallback base part.
--
-- NOTE:
--   This module does NOT persist placements; PlayerDataService handles persistence externally.
--   Clearing assets occurs AFTER PlayerDataService saves (it listens to PlayerRemoving too).
--   If you rely on offline persistence of world objects, disable clearing via
--     PlotManager.Config.ClearOwnedAssetsOnRelease = false
--   before initialization.
--
-- Public API Recap:
--   PlotManager:Init()
--   PlotManager:AssignPlayer(player)
--   PlotManager:ReleasePlayer(player)              -- Frees plot + clears owned assets (if enabled)
--   PlotManager:GetPlayerPlot(player)
--   PlotManager:GetSlimeZone(plot)
--   PlotManager:GetPlotOrigin(plot)
--   PlotManager:WorldToLocal(plot, worldCF)
--   PlotManager:LocalToWorld(plot, localCF)
--   PlotManager:RegisterPlacement(player, modelOrCF, kind, extra?)
--   PlotManager:UpdatePlacementCF(player, placementId, newWorldCF)
--   PlotManager:UpdatePlacementLocalCF(player, placementId, newLocalCF)
--   PlotManager:RemovePlacement(player, placementId)
--   PlotManager:GetPlacements(player)
--   PlotManager:FindPlacement(player, predicateFn)
--   PlotManager:FindPlacementById(player, id)
--   PlotManager:FindPlacementByModel(model)
--   PlotManager:ReanchorAll(player)
--   PlotManager:ClearPlayerPlot(player [, options])
--   PlotManager:ClearPlot(plot, userId [, options])
--
-- Internal record structure (placements):
--   { id, kind, time, localCF, worldCF, extra, model }

local Players     = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local Workspace   = game:GetService("Workspace")

local PlotManager = {}

-- Configuration -------------------------------------------------------------
PlotManager.Plots = {}
PlotManager.PlayerToPlot = {}
PlotManager.IndexAttribute = "Index"
PlotManager.MaxPlayers = 6
PlotManager.PlotNamePattern = "^Player(%d+)$"

PlotManager.Config = {
	-- Clear dynamic owned assets (slimes, eggs, decor with OwnerUserId) on player leave
	ClearOwnedAssetsOnRelease = false, -- CHANGED: keep assets so serializers can see them
	-- Also clear the player's neutral slime subfolder (if it exists)
	ClearNeutralFolderOnRelease = false, -- avoid premature deletion
	-- Neutral folder naming (mirrors PlayerDataService conventions if used)
	NeutralFolderName = "Slimes",
	NeutralPerPlayerSubfolders = true,

	-- Debug printing
	Debug = false,
}

-- Internal placement storage:
-- placements[userId] = { list = {record,...}, index = { [id]=record } }
local placements = {}

-- Utilities ----------------------------------------------------------------
local function dprint(...)
	if PlotManager.Config.Debug then
		print("[PlotManager]", ...)
	end
end

local function tagPlot(plotModel, index)
	plotModel:SetAttribute("Occupied", false)
	plotModel:SetAttribute("UserId", 0)
	plotModel:SetAttribute(PlotManager.IndexAttribute, index)
end

local function ensureBucket(userId)
	local bucket = placements[userId]
	if not bucket then
		bucket = { list = {}, index = {} }
		placements[userId] = bucket
	end
	return bucket
end

local function generateGuid()
	local ok,g = pcall(HttpService.GenerateGUID, HttpService, false)
	if ok and g then return g end
	return string.format("%08x-%04x-%04x-%04x-%04x%08x",
		math.random(0,0xFFFFFFFF), math.random(0,0xFFFF),
		math.random(0,0xFFFF), math.random(0,0xFFFF),
		math.random(0,0xFFFF), math.random(0,0xFFFFFFFF))
end

local function isModel(x) return typeof(x)=="Instance" and x:IsA("Model") end

local function safePrimary(model)
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

-- Initialization ------------------------------------------------------------
function PlotManager:Init()
	self.Plots = {}
	for i = 1, self.MaxPlayers do
		local plot = workspace:FindFirstChild("Player" .. i)
		if plot and plot:IsA("Model") then
			tagPlot(plot, i)
			table.insert(self.Plots, plot)
		end
	end

	-- REPLACED broken PlayerRemoving logic (was referencing undefined playerPlots & destroying too early)
	Players.PlayerRemoving:Connect(function(player)
		-- Leave plot + assets intact for final serializers; release after delay.
		task.delay(8, function()
			-- Only release if player truly gone
			if Players:GetPlayerByUserId(player.UserId) then return end
			-- Do NOT clear assets (config disabled); just free metadata.
			self:ReleasePlayer(player)
		end)
	end)
end

-- Plot / Player Mapping -----------------------------------------------------
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

function PlotManager:AssignPlayer(player)
	if self.PlayerToPlot[player.UserId] then
		debugPlotAssignment(player, self.PlayerToPlot[player.UserId])
		return self.PlayerToPlot[player.UserId]
	end
	for _, plot in ipairs(self.Plots) do
		if not plot:GetAttribute("Occupied") then
			plot:SetAttribute("Occupied", true)
			plot:SetAttribute("UserId", player.UserId)
			self.PlayerToPlot[player.UserId] = plot
			player:SetAttribute("PlotIndex", plot:GetAttribute(self.IndexAttribute))
			dprint(("Assigned %s to plot %s"):format(player.Name, plot.Name))
			debugPlotAssignment(player, plot)
			return plot
		end
	end
	debugPlotAssignment(player, nil)
	return nil
end

-- Internal clearing helper
local function clearOwnedAssetsInContainer(container, userId)
	for _,desc in ipairs(container:GetDescendants()) do
		-- We target Models (slimes, eggs, decor) and optionally loose parts
		if desc:IsA("Model") then
			local owner = desc:GetAttribute("OwnerUserId")
			if owner == userId then
				-- Heuristic: dynamic asset if it has OwnerUserId OR SlimeId/EggId/Placed
				if desc:GetAttribute("SlimeId") or desc:GetAttribute("EggId")
					or desc.Name == "Slime" or desc.Name == "Egg"
					or desc:GetAttribute("Placed") then
					pcall(function() desc:Destroy() end)
				end
			end
		elseif desc:IsA("BasePart") then
			local owner = desc:GetAttribute("OwnerUserId")
			if owner == userId then
				-- A stray owned part (maybe decor)
				pcall(function() desc:Destroy() end)
			end
		end
	end
end

-- Public clear for a given plot/userId
function PlotManager:ClearPlot(plot, userId, options)
	if not plot or not plot.Parent or not userId then return end
	if not PlotManager.Config.ClearOwnedAssetsOnRelease then return end
	clearOwnedAssetsInContainer(plot, userId)

	-- Neutral folder clearing (if configured)
	local opts = options or {}
	local doNeutral = opts.neutral
	if doNeutral == nil then
		doNeutral = PlotManager.Config.ClearNeutralFolderOnRelease
	end
	if doNeutral then
		local root = Workspace:FindFirstChild(PlotManager.Config.NeutralFolderName)
		if root then
			if PlotManager.Config.NeutralPerPlayerSubfolders then
				-- Scan only subfolder named after player if exists
				for _,sub in ipairs(root:GetChildren()) do
					if sub:IsA("Folder") then
						clearOwnedAssetsInContainer(sub, userId)
					end
				end
			else
				clearOwnedAssetsInContainer(root, userId)
			end
		end
	end
	dprint(("[ClearPlot] Cleared owned assets for userId=%d on plot=%s"):format(userId, plot.Name))
end

-- Public convenience: clear for player
function PlotManager:ClearPlayerPlot(player, options)
	if not player or not player:IsA("Player") then return end
	local plot = self.PlayerToPlot[player.UserId]
	if plot then
		self:ClearPlot(plot, player.UserId, options)
	end
end

function PlotManager:ReleasePlayer(player)
	local plot = self.PlayerToPlot[player.UserId]
	if plot then
		-- Clear assets first so if some other system scans the now unowned plot, it's clean.
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

function PlotManager:GetPlayerPlot(player)
	return self.PlayerToPlot[player.UserId]
end

-- Origin Part & Zone --------------------------------------------------------
function PlotManager:GetSlimeZone(plot)
	if not plot then return nil end
	local direct = plot:FindFirstChild("SlimeZone")
	if direct and direct:IsA("BasePart") then return direct end
	for _,desc in ipairs(plot:GetDescendants()) do
		if desc:IsA("BasePart") and desc.Name == "SlimeZone" then
			return desc
		end
	end
	return nil
end

function PlotManager:GetPlotOrigin(plot)
	if not plot then return nil end
	local origin = self:GetSlimeZone(plot)
	if origin then return origin end
	for _,d in ipairs(plot:GetDescendants()) do
		if d:IsA("BasePart") then return d end
	end
	return nil
end

-- World<->Local Transform Helpers ------------------------------------------
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

-- Placement Registration ----------------------------------------------------
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

function PlotManager:UpdatePlacementLocalCF(player, placementId, newLocalCF)
	local plot = self:GetPlayerPlot(player)
	if not plot then return false end
	local bucket = placements[player.UserId]; if not bucket then return false end
	local rec = bucket.index[placementId]; if not rec then return false end
	if typeof(newLocalCF) ~= "CFrame" then return false end
	rec.localCF = newLocalCF
	rec.worldCF = self:LocalToWorld(plot, newLocalCF)
	if rec.model and rec.model.Parent then
		pcall(function() rec.model:PivotTo(rec.worldCF) end)
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

function PlotManager:FindPlacement(player, predicate)
	if type(predicate) ~= "function" then return nil end
	local bucket = placements[player.UserId]; if not bucket then return nil end
	for _,rec in ipairs(bucket.list) do
		if predicate(rec) then return rec end
	end
	return nil
end

function PlotManager:FindPlacementById(player, placementId)
	local bucket = placements[player.UserId]; if not bucket then return nil end
	return bucket.index[placementId]
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
	if not plot then return end
	local spawnPart = self:FindSpawnPart(plot)
	if spawnPart then
		local hrp = character:WaitForChild("HumanoidRootPart", 5)
		if hrp then
			hrp.CFrame = spawnPart.CFrame + Vector3.new(0, 3, 0)
		end
	end
end

return PlotManager