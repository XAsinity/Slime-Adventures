-- EggService.lua
-- Version: v4.0.0-placement-cap-snapshot-purge-stable (updated to persist hatched slimes with canonical id)
-- (updated to keep PlayerProfileService / InventoryService in sync for worldEgg -> worldSlime lifecycle)
-- Uses consolidated SlimeCore when available to obtain ModelUtils, Appearance, RNG, Config, etc.

local EggService = {}
EggService.__Version = "v4.0.0-placement-cap-snapshot-purge-stable"
local _initialized = false

----------------------------------------------------------
-- SERVICES
----------------------------------------------------------
local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local Workspace           = game:GetService("Workspace")
local HttpService         = game:GetService("HttpService")
local ServerScriptService = game:GetService("ServerScriptService")
local ModulesRoot         = script.Parent

-- Prefer the consolidated SlimeCore module (non-blocking). If present, use its submodules.
-- Fall back to existing standalone modules only if SlimeCore is not available or the submodule missing.
local SlimeCore = nil
do
	local inst = ModulesRoot:FindFirstChild("SlimeCore")
	if inst and inst:IsA("ModuleScript") then
		local ok, sc = pcall(require, inst)
		if ok and type(sc) == "table" then
			SlimeCore = sc
		end
	end
end

local function safeRequire(name)
	-- non-blocking require for a module next to this script
	local inst = ModulesRoot:FindFirstChild(name)
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst)
		if ok then return mod end
	end
	return nil
end

-- Acquire implementations (prefer SlimeCore submodules)
local ModelUtils    = (SlimeCore and SlimeCore.ModelUtils)    or safeRequire("ModelUtils")    or {}
local SlimeAI       = (SlimeCore and SlimeCore.SlimeAI)       or safeRequire("SlimeAI")       or {}
local RNG           = (SlimeCore and SlimeCore.RNG)           or safeRequire("RNG")           or {}
local SlimeConfig   = (SlimeCore and SlimeCore.SlimeConfig)   or safeRequire("SlimeConfig")   or {}
local SizeRNG       = (SlimeCore and SlimeCore.SizeRNG)       or safeRequire("SizeRNG")       or {}
local GrowthScaling = (SlimeCore and SlimeCore.GrowthScaling) or safeRequire("GrowthScaling") or {}
local SlimeMutation = (SlimeCore and SlimeCore.SlimeMutation) or safeRequire("SlimeMutation") or {}
local SlimeAppearance = (SlimeCore and (SlimeCore.SlimeAppearance or SlimeCore.Appearance)) or safeRequire("SlimeAppearance") or {}

-- Ensure minimal helpers exist on fallbacks to avoid runtime nil errors
if not ModelUtils.CleanPhysics then ModelUtils.CleanPhysics = function() end end
if not ModelUtils.AutoWeld then ModelUtils.AutoWeld = function() end end

-- If Appearance is a very small table or missing Generate, provide a safe stub that returns nil
if type(SlimeAppearance) ~= "table" then SlimeAppearance = {} end
if type(SlimeAppearance.Generate) ~= "function" then
	SlimeAppearance.Generate = function() return nil end
end
-- Provide a ColorToHex helper fallback (RNG.ColorToHex if available or simple hex)
if type(SlimeAppearance.ColorToHex) ~= "function" then
	if RNG and type(RNG.ColorToHex) == "function" then
		SlimeAppearance.ColorToHex = RNG.ColorToHex
	else
		SlimeAppearance.ColorToHex = function(_) return "#FFFFFF" end
	end
end

-- If SlimeConfig lacks GetTierConfig, provide a safe default
if type(SlimeConfig.GetTierConfig) ~= "function" then
	SlimeConfig.GetTierConfig = function(_) return {
		BaseMaxSizeRange = {0.85, 1.10},
		StartScaleFractionRange = {0.010, 0.020},
		AbsoluteMaxScaleCap = 200,
		SizeJackpot = {},
		UnfedGrowthDurationRange = {540,900},
		FedGrowthDurationRange = {120,480},
		FeedBufferMax = 120,
		AverageScaleBasic = 1,
		} end
end

-- Persistence / inventory services (added)
local PlayerDataService
do
	local ok, res = pcall(function()
		return safeRequire("PlayerDataService")
	end)
	if ok then PlayerDataService = res end
end
local PlayerProfileService = nil
local InventoryService = nil
do
	-- PlayerProfileService/InventoryService may be in the same Modules folder
	-- Use pcall so file doesn't hard-fail if not present during tests
	local inst = ModulesRoot:FindFirstChild("PlayerProfileService")
	if inst then
		pcall(function() PlayerProfileService = require(inst) end)
	end
	inst = ModulesRoot:FindFirstChild("InventoryService")
	if inst then
		pcall(function() InventoryService = require(inst) end)
	end
end

-- Remotes
local Remotes        = ReplicatedStorage:WaitForChild("Remotes")
local PlaceEggEvent  = Remotes:WaitForChild("PlaceEgg")
local HatchEggRemote = Remotes:FindFirstChild("HatchEggRequest") -- optional manual hatch remote

-- Assets
local Assets       = ReplicatedStorage:WaitForChild("Assets")
local EggTemplate  = Assets:WaitForChild("Egg")
local SlimeTemplate= Assets:WaitForChild("Slime")

----------------------------------------------------------
-- CONFIG
----------------------------------------------------------
local DEBUG                         = true
local SHOW_FAIL_REASONS             = true
local MANUAL_HATCH_MODE             = true
local AUTO_HATCH_WHEN_READY         = false
local HATCH_TIME_RANGE              = {60,120}
local BASE_PLACEMENT_CAP            = 3
local PLACE_COOLDOWN                = 0
local HATCH_POLL_INTERVAL           = 0.5
local HATCH_GUI_UPDATE_INTERVAL     = 0.5
local USE_GROUND_RAYCAST            = false
local AUTO_REPAIR_TOOL_METADATA     = true
local HATCH_TIMER_NAME              = "HatchTimer"
local HATCH_GUI_SIZE                = UDim2.new(0,110,0,34)
local HATCH_GUI_OFFSET_Y            = 2.5
local HATCH_TIME_DECIMALS           = 0
local HATCH_LOW_WARN_THRESHOLD      = 5
local HATCH_WARN_COLOR              = Color3.fromRGB(255,170,70)
local HATCH_FLASH_RATE              = 4
local HATCH_GUI_FONT                = Enum.Font.GothamBold
local HATCH_GUI_TEXTCOLOR           = Color3.fromRGB(255,255,255)
local HATCH_GUI_TEXTSTROKE          = Color3.fromRGB(0,0,0)
local HATCH_GUI_TEXTSTROKE_T        = 0.4
local DEFAULT_HUNGER_DECAY          = (0.02 / 15)
local MIN_PART_AXIS                 = 0.05
local BODY_PART_CANDIDATES          = { "Outer","Inner","Body","Core","Main","Torso","Slime","Base" }
local MIN_VISIBLE_START_SCALE       = 0.18
local SPAWN_UPWARD_OFFSET           = 0.18
local VISIBILITY_DEBUG              = true
local FORCE_SLIME_PARENT_UNDER_WORKSPACE = true
local SLIME_PARENT_FOLDER_NAME      = "Slimes"
local USE_PER_PLAYER_SUBFOLDERS     = true
local FORCE_PROMOTE_ASSEMBLY_ROOT   = true
local LOG_ROOT_PROMOTION            = true
local EGG_HATCH_INPLACE_PERSIST     = true
local SAVE_ON_HATCH_IMMEDIATE       = true
local POST_HATCH_SAVE_FALLBACK_DELAY= 3
local SNAPSHOT_EXPORT_ENABLED       = true
local RESIDUAL_PURGE_ENABLED        = true
local RESIDUAL_PURGE_EXTRA_PASSES   = {0.25, 1}
local ORPHAN_EGG_GRACE_SECONDS      = 10
local GRAVEYARD_FOLDER_NAME         = "_EggGraveyard"
local CLEAR_EGGS_ON_LEAVE           = false
local CLEAR_DEFER_SECONDS           = 0.05
local REJECT_PREVIEW_ATTRIBUTE      = "Preview"

----------------------------------------------------------
-- STATE
----------------------------------------------------------
local PlacedEggs       = {}
local PlacedCountByUid = {}
local HatchInProgress  = {}
local GraveyardFolder  = nil
local EggSnapshot      = {}
local EggIdSeenWorld   = {}

----------------------------------------------------------
-- LOG HELPERS
----------------------------------------------------------
local function dprint(...)
	if DEBUG then print("[EggService]", ...) end
end
local function dfail(reason, detail)
	if not SHOW_FAIL_REASONS then return end
	if detail then
		warn(("[EggService][PlaceFail][%s] %s"):format(tostring(reason), tostring(detail)))
	else
		warn(("[EggService][PlaceFail][%s]"):format(tostring(reason)))
	end
end

----------------------------------------------------------
-- CAP HELPERS
----------------------------------------------------------
local function GetEggPlacementCap(player)
	return BASE_PLACEMENT_CAP
end
local function GetPlacedCount(userId)
	return PlacedCountByUid[userId] or 0
end
local function IncrementPlaced(userId)
	PlacedCountByUid[userId] = (PlacedCountByUid[userId] or 0) + 1
end
local function DecrementPlaced(userId)
	if PlacedCountByUid[userId] then
		PlacedCountByUid[userId] -= 1
		if PlacedCountByUid[userId] < 0 then
			PlacedCountByUid[userId] = 0
		end
	end
end
local function CanPlaceEgg(player)
	return GetPlacedCount(player.UserId) < GetEggPlacementCap(player)
end
EggService.CanPlaceEgg          = CanPlaceEgg
EggService.GetEggPlacementCap   = GetEggPlacementCap
EggService.GetPlacedEggCount    = function(player) return GetPlacedCount(player.UserId) end
local function updatePlayerAttr(userId)
	for _,plr in ipairs(Players:GetPlayers()) do
		if plr.UserId == userId then
			pcall(function() plr:SetAttribute("ActiveEggs", GetPlacedCount(userId)) end)
			break
		end
	end
end

----------------------------------------------------------
-- GRAVEYARD / UTILITY
----------------------------------------------------------
local function ensureGraveyard()
	if GraveyardFolder and GraveyardFolder.Parent then return GraveyardFolder end
	local existing = Workspace:FindFirstChild(GRAVEYARD_FOLDER_NAME)
	if not existing then
		existing = Instance.new("Folder")
		existing.Name = GRAVEYARD_FOLDER_NAME
		existing.Parent = Workspace
	end
	GraveyardFolder = existing
	return existing
end

----------------------------------------------------------
-- SNAPSHOT HELPERS
----------------------------------------------------------



local function pushSnapshot(model)

	if not SNAPSHOT_EXPORT_ENABLED then return end
	if not model or not model.Parent then return end
	local owner = model:GetAttribute("OwnerUserId")
	local eggId = model:GetAttribute("EggId")
	if not (owner and eggId) then return end

	local list = EggSnapshot[owner]
	if not list then
		list = {}
		EggSnapshot[owner] = list
	end

	local updated = false
	for i,e in ipairs(list) do
		if e.eggId == eggId then
			list[i] = {
				eggId=eggId,
				hatchAt=model:GetAttribute("HatchAt"),
				hatchTime=model:GetAttribute("HatchTime"),
				placedAt=model:GetAttribute("PlacedAt"),
				rarity=model:GetAttribute("Rarity"),
				valueBase=model:GetAttribute("ValueBase"),
				valuePerGrowth=model:GetAttribute("ValuePerGrowth"),
			}
			updated = true
			break
		end
	end
	if not updated then
		list[#list+1] = {
			eggId=eggId,
			hatchAt=model:GetAttribute("HatchAt"),
			hatchTime=model:GetAttribute("HatchTime"),
			placedAt=model:GetAttribute("PlacedAt"),
			rarity=model:GetAttribute("Rarity"),
			valueBase=model:GetAttribute("ValueBase"),
			valuePerGrowth=model:GetAttribute("ValuePerGrowth"),
		}
	end

	dprint(string.format("PushSnapshot exporting count=%d", #list)) -- fixed

end

local function removeSnapshotEntry(userId, eggId)
	if not SNAPSHOT_EXPORT_ENABLED then return end
	local list = EggSnapshot[userId]; if not list then return end
	for i=#list,1,-1 do
		if list[i].eggId == eggId then
			table.remove(list,i)
			break
		end
	end
	if #list == 0 then
		EggSnapshot[userId] = nil
	end
end

function EggService.ExportWorldEggSnapshot(userId)
	if not SNAPSHOT_EXPORT_ENABLED then return {} end
	local src = EggSnapshot[userId]
	if not src then return {} end
	local copy = {}
	for _,e in ipairs(src) do
		copy[#copy+1] = {
			eggId=e.eggId,
			hatchAt=e.hatchAt,
			hatchTime=e.hatchTime,
			placedAt=e.placedAt,
			rarity=e.rarity,
			valueBase=e.valueBase,
			valuePerGrowth=e.valuePerGrowth
		}
	end
	return copy
end

function EggService.InjectSnapshotFromModels(userId)
	if not SNAPSHOT_EXPORT_ENABLED then return end
	EggSnapshot[userId] = nil
	for model,rec in pairs(PlacedEggs) do
		if rec.OwnerUserId == userId then
			pushSnapshot(model)
		end
	end
end

----------------------------------------------------------
-- APPEARANCE / SLIME BUILD HELPERS
----------------------------------------------------------
local function choosePrimary(model)
	if model.PrimaryPart then return model.PrimaryPart end
	for _,cand in ipairs(BODY_PART_CANDIDATES) do
		local p = model:FindFirstChild(cand)
		if p and p:IsA("BasePart") then model.PrimaryPart = p return p end
	end
	for _,c in ipairs(model:GetChildren()) do
		if c:IsA("BasePart") then
			model.PrimaryPart = c
			return c
		end
	end
	return nil
end

local function captureOriginalData(model, primary)
	for _,part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part:SetAttribute("OriginalSize", part.Size)
			if part == primary then
				part:SetAttribute("OriginalRelCF", CFrame.new())
			else
				part:SetAttribute("OriginalRelCF", primary.CFrame:ToObjectSpace(part.CFrame))
			end
		end
	end
end

local function computeSafeStartScale(model, desired)
	local needed = 0
	for _,p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			local s=p.Size
			needed = math.max(needed, MIN_PART_AXIS/math.max(s.X,1e-6))
			needed = math.max(needed, MIN_PART_AXIS/math.max(s.Y,1e-6))
			needed = math.max(needed, MIN_PART_AXIS/math.max(s.Z,1e-6))
		end
	end
	return math.max(desired, needed)
end

local function applyInitialScale(model, primary, scale)
	for _,p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			local orig = p:GetAttribute("OriginalSize")
			if orig then
				local ns = orig * scale
				p.Size = Vector3.new(
					math.max(ns.X, MIN_PART_AXIS),
					math.max(ns.Y, MIN_PART_AXIS),
					math.max(ns.Z, MIN_PART_AXIS)
				)
			end
		end
	end
	local rootCF = primary.CFrame
	for _,p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") and p ~= primary then
			local rel = p:GetAttribute("OriginalRelCF")
			if rel then
				local posRel = rel.Position * scale
				local rotRel = rel - rel.Position
				p.CFrame = rootCF * (CFrame.new(posRel) * rotRel)
			end
		end
	end
end

local function initializeGrowthAttributes(slime, rng)
	local tier = "Basic"
	slime:SetAttribute("Tier", tier)
	local cfg = SlimeConfig.GetTierConfig(tier)

	local maxScale, luckLevels = (SizeRNG and SizeRNG.GenerateMaxSize) and SizeRNG.GenerateMaxSize(tier, rng) or 1, 0
	local sizeNorm  = maxScale / (SlimeConfig.AverageScaleBasic or 1)
	local startFraction =
		(SizeRNG and SizeRNG.GenerateStartFraction and SizeRNG.GenerateStartFraction(tier, rng))
		or (rng and rng.NextNumber and rng:NextNumber(cfg.StartScaleFractionRange[1], cfg.StartScaleFractionRange[2])) or (cfg.StartScaleFractionRange[1] or 0.01)

	local startScaleDesired = maxScale * startFraction
	local startScale = computeSafeStartScale(slime, startScaleDesired)

	local sFactor   = (GrowthScaling and GrowthScaling.SizeDurationFactor) and GrowthScaling.SizeDurationFactor(tier, sizeNorm) or 1
	local baseUnfed = (rng and rng.NextNumber) and rng:NextNumber(cfg.UnfedGrowthDurationRange[1], cfg.UnfedGrowthDurationRange[2]) or (cfg.UnfedGrowthDurationRange[1] or 600)
	local baseFed   = (rng and rng.NextNumber) and rng:NextNumber(cfg.FedGrowthDurationRange[1], cfg.FedGrowthDurationRange[2]) or (cfg.FedGrowthDurationRange[1] or 120)
	local unfedDur  = baseUnfed * sFactor
	local fedDur    = baseFed   * sFactor
	local feedMult  = (fedDur ~= 0) and (unfedDur / fedDur) or 1
	local initialProgress = (maxScale ~= 0) and (startScale / maxScale) or 0

	slime:SetAttribute("MaxSizeScale",     maxScale)
	slime:SetAttribute("StartSizeScale",   startScale)
	slime:SetAttribute("CurrentSizeScale", startScale)
	slime:SetAttribute("GrowthProgress",   initialProgress)
	slime:SetAttribute("UnfedGrowthDuration", unfedDur)
	slime:SetAttribute("FedGrowthDuration",   fedDur)
	slime:SetAttribute("FeedSpeedMultiplier", feedMult)
	slime:SetAttribute("FeedBufferSeconds",   0)
	slime:SetAttribute("FeedBufferMax",       cfg.FeedBufferMax)
	slime:SetAttribute("SizeLuckRolls",       luckLevels)
	slime:SetAttribute("SizeNorm",            sizeNorm)

	if SlimeMutation and type(SlimeMutation.InitSlime) == "function" then
		SlimeMutation.InitSlime(slime)
	end
	if SlimeMutation and type(SlimeMutation.RecomputeValueFull) == "function" then
		SlimeMutation.RecomputeValueFull(slime)
	end
end

local function applyAppearance(slime, primary, rng)
	local rarity = slime:GetAttribute("Rarity") or "Common"
	local app
	local ok,err = pcall(function()
		app = SlimeAppearance.Generate(rarity, rng, slime:GetAttribute("MutationRarityBonus"))
	end)
	if not ok then warn("[EggService] SlimeAppearance.Generate failed:", err) end
	if not app then return end

	-- Color helpers may live on SlimeAppearance or RNG.ColorToHex; try both safely
	local colorToHex = (SlimeAppearance and SlimeAppearance.ColorToHex) or (RNG and RNG.ColorToHex)
	if colorToHex then
		slime:SetAttribute("BodyColor",   colorToHex(app.BodyColor))
		slime:SetAttribute("AccentColor", colorToHex(app.AccentColor))
		slime:SetAttribute("EyeColor",    colorToHex(app.EyeColor))
	else
		slime:SetAttribute("BodyColor",   "#FFFFFF")
		slime:SetAttribute("AccentColor", "#FFFFFF")
		slime:SetAttribute("EyeColor",    "#FFFFFF")
	end

	for _,part in ipairs(slime:GetDescendants()) do
		if part:IsA("BasePart") then
			local ln = part.Name:lower()
			if ln:find("eye") then
				part.Color = app.EyeColor
			elseif part == primary then
				part.Color = app.BodyColor
			else
				part.Color = app.AccentColor
			end
		end
	end
end

local function visibilitySummary(slime)
	if not VISIBILITY_DEBUG then return end
	local minAxis = math.huge
	local maxTrans = -1
	for _,p in ipairs(slime:GetDescendants()) do
		if p:IsA("BasePart") then
			minAxis = math.min(minAxis, p.Size.X, p.Size.Y, p.Size.Z)
			maxTrans= math.max(maxTrans, p.Transparency)
		end
	end
	print(("[EggService][Visibility] SlimeId=%s minPartAxis=%.4f maxTransparency=%.2f")
		:format(tostring(slime:GetAttribute("SlimeId")), minAxis==math.huge and -1 or minAxis, maxTrans))
end

----------------------------------------------------------
-- Ensure runtime inventory entry contains canonical id & immediate persist helper
-- (existing helpers for worldEggs retained)
----------------------------------------------------------
local function ensureInventoryEntryHasId(player, eggId, payloadTable)
	if not player or not eggId then return end
	local ok, inv = pcall(function() return player:FindFirstChild("Inventory") end)
	if not ok or not inv then return end
	local worldEggs = inv:FindFirstChild("worldEggs")
	if not worldEggs then return end

	local encoded = nil
	local successEncode, enc = pcall(function() return HttpService:JSONEncode(payloadTable) end)
	if successEncode then encoded = enc else encoded = nil end

	for _,entry in ipairs(worldEggs:GetChildren()) do
		if entry:IsA("Folder") then
			local data = entry:FindFirstChild("Data")
			if data and type(data.Value) == "string" and data.Value ~= "" then
				local ok2, t = pcall(function() return HttpService:JSONDecode(data.Value) end)
				if ok2 and type(t) == "table" and (t.id == eggId or t.eggId == eggId) then
					if entry.Name ~= ("Entry_"..eggId) then
						pcall(function() entry.Name = "Entry_"..eggId end)
					end
					return true
				end
			end
		end
	end

	for _,entry in ipairs(worldEggs:GetChildren()) do
		if entry:IsA("Folder") then
			local data = entry:FindFirstChild("Data")
			local shouldSet = false
			if not data then
				shouldSet = true
			elseif not data.Value or data.Value == "" then
				shouldSet = true
			else
				local ok2, t = pcall(function() return HttpService:JSONDecode(data.Value) end)
				if not ok2 or type(t) ~= "table" or (not t.id and not t.eggId) then
					shouldSet = true
				end
			end
			if shouldSet then
				if not data then
					data = Instance.new("StringValue")
					data.Name = "Data"
					data.Parent = entry
				end
				local payload = payloadTable or {}
				payload.id = tostring(eggId)
				payload.eggId = payload.eggId or payload.id
				local ok3, enc2 = pcall(function() return HttpService:JSONEncode(payload) end)
				if ok3 then
					pcall(function() data.Value = enc2 end)
					pcall(function() entry.Name = "Entry_"..eggId end)
				else
					pcall(function() data.Value = HttpService:JSONEncode({ id = tostring(eggId) }) end)
					pcall(function() entry.Name = "Entry_"..eggId end)
				end

				if InventoryService and InventoryService.UpdateProfileInventory then
					pcall(function() InventoryService.UpdateProfileInventory(player) end)
				end
				if PlayerProfileService and type(PlayerProfileService.SaveNow) == "function" then
					pcall(function() PlayerProfileService.SaveNow(player, "EggRegistered_ImmediatePersist") end)
					pcall(function() PlayerProfileService.SaveNow(player.UserId, "EggRegistered_ImmediatePersist") end)
				end
				if PlayerDataService and type(PlayerDataService.SaveImmediately) == "function" then
					pcall(function() PlayerDataService.SaveImmediately(player, "EggRegistered_ImmediatePersist") end)
				end
				return true
			end
		end
	end

	local okC, newEntry = pcall(function()
		local f = Instance.new("Folder")
		f.Name = "Entry_"..eggId
		local data = Instance.new("StringValue")
		data.Name = "Data"
		data.Value = encoded or HttpService:JSONEncode({ id = tostring(eggId) })
		data.Parent = f
		f.Parent = worldEggs
		return f
	end)
	if okC and newEntry then
		if InventoryService and InventoryService.UpdateProfileInventory then
			pcall(function() InventoryService.UpdateProfileInventory(player) end)
		end
		if PlayerProfileService and type(PlayerProfileService.SaveNow) == "function" then
			pcall(function() PlayerProfileService.SaveNow(player, "EggRegistered_ImmediatePersist") end)
			pcall(function() PlayerProfileService.SaveNow(player.UserId, "EggRegistered_ImmediatePersist") end)
		end
		if PlayerDataService and type(PlayerDataService.SaveImmediately) == "function" then
			pcall(function() PlayerDataService.SaveImmediately(player, "EggRegistered_ImmediatePersist") end)
		end
		return true
	end

	return false
end

-- New helper: aggressively remove any local Entry_<id> folder(s) under player's Inventory.worldEggs
-- This is a defensive/local-only cleanup to avoid leftover folder visibility/race artifacts in the runtime Inventory folder.
local function removeInventoryEntryFolderByIdForPlayer(player, folderName, id)
	if not player or not id or not folderName then return end
	local ok, inv = pcall(function() return player:FindFirstChild("Inventory") end)
	if not ok or not inv then return end
	local folder = inv:FindFirstChild(folderName)
	if not folder then return end

	local entryName = "Entry_" .. tostring(id)

	-- Destroy exact match first
	pcall(function()
		local f = folder:FindFirstChild(entryName)
		if f and f.Parent then
			f:Destroy()
			if DEBUG then dprint(("Removed local inventory folder %s for player=%s"):format(entryName, player.Name)) end
		end
	end)

	-- Also defensively remove any folder whose Data JSON decodes to this id/eggId
	pcall(function()
		for _,child in ipairs(folder:GetChildren()) do
			if child:IsA("Folder") then
				local data = child:FindFirstChild("Data")
				if data and type(data.Value) == "string" and data.Value ~= "" then
					local ok2, t = pcall(function() return HttpService:JSONDecode(data.Value) end)
					if ok2 and type(t) == "table" and (t.id == tostring(id) or t.eggId == tostring(id) or t.EggId == tostring(id)) then
						if child.Parent then
							child:Destroy()
							if DEBUG then dprint(("Removed local inventory folder (by Data) %s for player=%s"):format(child.Name, player.Name)) end
						end
					end
				end
			end
		end
	end)
end

-- New small helper to perform a couple of retry passes to catch races where a later merge re-adds the folder
local function removeInventoryEntryFolderWithRetries(player, folderName, id)
	pcall(function()
		removeInventoryEntryFolderByIdForPlayer(player, folderName, id)
	end)
	-- short retry (race window)
	task.delay(0.15, function()
		pcall(function()
			removeInventoryEntryFolderByIdForPlayer(player, folderName, id)
		end)
	end)
	-- delayed retry to catch later mergers
	task.delay(1.0, function()
		pcall(function()
			removeInventoryEntryFolderByIdForPlayer(player, folderName, id)
		end)
	end)
end

-- New helper: robustly remove any lingering worldEggs inventory entries for a player/userId
-- Tries InventoryService (by player), PlayerProfileService (by userId), and finally edits loaded profile in-memory.
local function safeRemoveWorldEggForPlayer(playerOrUser, eggId)
	if not eggId then return end

	-- Resolve player and userId
	local ply = nil
	local uid = nil
	if type(playerOrUser) == "number" then
		uid = playerOrUser
		ply = Players:GetPlayerByUserId(uid)
	end
	if type(playerOrUser) == "table" and playerOrUser.UserId then
		uid = playerOrUser.UserId
		ply = playerOrUser
	end
	-- Avoid using colon expression directly in a logical expression (parser quirk).
	if type(playerOrUser) == "userdata" and playerOrUser.IsA then
		local ok, isPlayer = pcall(function() return playerOrUser:IsA("Player") end)
		if ok and isPlayer then
			ply = playerOrUser
			uid = ply.UserId
		end
	end

	-- 1) InventoryService removal (fast path for online player)
	if ply and InventoryService and type(InventoryService.RemoveInventoryItem) == "function" then
		pcall(function()
			-- try several common id fields; immediate option if supported
			InventoryService.RemoveInventoryItem(ply, "worldEggs", "eggId", eggId, { immediate = true })
			InventoryService.RemoveInventoryItem(ply, "worldEggs", "EggId", eggId, { immediate = true })
			InventoryService.RemoveInventoryItem(ply, "worldEggs", "id", eggId, { immediate = true })
			-- make sure inventory folder mirrors profile
			if type(InventoryService.UpdateProfileInventory) == "function" then
				InventoryService.UpdateProfileInventory(ply)
			end
		end)
	end

	-- 2) PlayerProfileService removal by userId (persisted store)
	if uid and PlayerProfileService and type(PlayerProfileService.RemoveInventoryItem) == "function" then
		pcall(function()
			PlayerProfileService.RemoveInventoryItem(uid, "worldEggs", "eggId", eggId)
			PlayerProfileService.RemoveInventoryItem(uid, "worldEggs", "EggId", eggId)
			PlayerProfileService.RemoveInventoryItem(uid, "worldEggs", "id", eggId)
			-- force an async save to persist the removal
			if type(PlayerProfileService.SaveNow) == "function" then
				PlayerProfileService.SaveNow(uid, "EggRemoved_Ensure")
			end
		end)
	end

	-- 3) Fallback: edit loaded profile in-memory if present
	if uid and PlayerProfileService and type(PlayerProfileService.GetProfile) == "function" then
		pcall(function()
			local ok, prof = pcall(function() return PlayerProfileService.GetProfile(uid) end)
			if ok and prof and type(prof) == "table" and prof.inventory and prof.inventory.worldEggs then
				local removed = 0
				for i = #prof.inventory.worldEggs, 1, -1 do
					local e = prof.inventory.worldEggs[i]
					if type(e) == "table" then
						if tostring(e.eggId or e.EggId or e.id or e.Id) == tostring(eggId) then
							table.remove(prof.inventory.worldEggs, i)
							removed = removed + 1
						end
					end
				end
				if removed > 0 and type(PlayerProfileService.SaveNow) == "function" then
					PlayerProfileService.SaveNow(uid, "EggRemoved_InMemoryFallback")
				end
			end
		end)
	end

	-- 4) Local runtime folder cleanup (defensive): remove Entry_<eggId> from the player's Inventory folder if present
	-- This is a defensive local-only operation to avoid Explorer/UI leftover duplicates during concurrent inventory merges.
	pcall(function()
		local targetPlayer = ply
		if not targetPlayer and uid then
			targetPlayer = Players:GetPlayerByUserId(uid)
		end
		if targetPlayer then
			removeInventoryEntryFolderWithRetries(targetPlayer, "worldEggs", eggId)
		end
	end)
end

-- Utility: parse a timestamp-like field from an entry
local function _entry_timestamp(entry)
	if not entry or type(entry) ~= "table" then return 0 end
	local cand = nil
	-- common names: Timestamp, ts, lg (last growth)
	if entry.Timestamp then cand = tonumber(entry.Timestamp) end
	if not cand and entry.ts then cand = tonumber(entry.ts) end
	if not cand and entry.lg then cand = tonumber(entry.lg) end
	if not cand and entry.lg == nil and entry.Timestamp == nil and entry.ts == nil then
		-- last resort: use entry.CreatedAt or now
		if entry.CreatedAt then cand = tonumber(entry.CreatedAt) end
	end
	return cand or 0
end

-- Deduplicate profile.inventory.worldSlimes in-place by canonical id.
-- Keeps the entry with highest timestamp (or last seen if no timestamps).
local function dedupe_profile_worldslimes(profile)
	if not profile or type(profile) ~= "table" or type(profile.inventory) ~= "table" then return false end
	local ws = profile.inventory.worldSlimes
	if not ws or type(ws) ~= "table" or #ws == 0 then return false end

	local byId = {}
	local order = {}

	for _, entry in ipairs(ws) do
		if type(entry) ~= "table" then
			-- preserve non-table entries (unlikely)
			table.insert(order, entry)
		else
			local id = entry.id or entry.SlimeId or entry.slimeId or entry.Id
			if not id then
				-- entries without id can't be deduped, preserve
				table.insert(order, entry)
			else
				local key = tostring(id)
				local ts = _entry_timestamp(entry) or 0
				local prev = byId[key]
				if not prev then
					byId[key] = { entry = entry, ts = ts }
				else
					-- prefer entry with higher timestamp, else keep existing (stable)
					if ts > (prev.ts or 0) then
						byId[key] = { entry = entry, ts = ts }
					end
				end
			end
		end
	end

	-- rebuild list preserving non-id items first then canonical id entries in arbitrary order
	local out = {}
	for _, v in ipairs(order) do table.insert(out, v) end
	for k, v in pairs(byId) do
		table.insert(out, v.entry)
	end

	-- quick compare to detect change
	local changed = (#out ~= #ws)
	if not changed then
		for i = 1, #out do
			local a = out[i]; local b = ws[i]
			local aid = a and (a.id or a.SlimeId or a.Id)
			local bid = b and (b.id or b.SlimeId or b.Id)
			if tostring(aid) ~= tostring(bid) then changed = true; break end
		end
	end

	if changed then
		profile.inventory.worldSlimes = out
		-- mark dirty if possible
		if PlayerProfileService and type(PlayerProfileService.MarkDirty) == "function" then
			pcall(function() PlayerProfileService.MarkDirty(profile, "DedupeWorldSlimes") end)
			pcall(function() PlayerProfileService.MarkDirty(profile.userId or profile.UserId, "DedupeWorldSlimes") end)
		end
		-- attempt to save
		if PlayerProfileService and type(PlayerProfileService.SaveNow) == "function" then
			pcall(function()
				local uid = tonumber(profile.userId or profile.UserId)
				if uid then
					PlayerProfileService.SaveNow(uid, "DedupeWorldSlimes")
				else
					PlayerProfileService.SaveNow(profile, "DedupeWorldSlimes")
				end
			end)
		end
		if DEBUG then
			dprint(("dedupe_profile_worldslimes: deduped worldSlimes for profile userId=%s newCount=%d"):format(tostring(profile.userId or profile.UserId or "nil"), #profile.inventory.worldSlimes))
		end
		return true
	end
	return false
end

-- Persist a worldSlime entry to player's profile (primitive-only fields).
-- Important: include 'id' (canonical) so InventoryService uses it for Entry_<id> folder naming.
-- This version adds a re-ensure step after a short delay to reduce races with sanitizers.
local function persistWorldSlime(ownerPlayer, ownerUserId, slime, eggId)
	if not slime then return false end

	-- canonical id (string)
	local sid = tostring(slime:GetAttribute("SlimeId") or eggId or HttpService:GenerateGUID(false))

	-- Build a minimal, datastore-safe table only containing primitives/tables
	local entry = {
		id = sid,                      -- canonical id required by InventoryService.EnsureEntryHasId
		SlimeId = sid,
		EggId = tostring(eggId or ""),
		OwnerUserId = tonumber(ownerUserId) or nil,
		Size = tonumber(slime:GetAttribute("CurrentSizeScale") or slime:GetAttribute("StartSizeScale")) or nil,
		GrowthProgress = tonumber(slime:GetAttribute("GrowthProgress")) or nil,
		ValueBase = tonumber(slime:GetAttribute("ValueBase")) or nil,
		ValuePerGrowth = tonumber(slime:GetAttribute("ValuePerGrowth")) or nil,
		Timestamp = os.time(),
	}

	-- Optional: add a plain position table if PrimaryPart present (no CFrame/Vector3 objects)
	do
		local primary = slime.PrimaryPart or slime:FindFirstChildWhichIsA("BasePart")
		if primary then
			local p = primary.Position
			entry.Position = { x = tonumber(p.X) or 0, y = tonumber(p.Y) or 0, z = tonumber(p.Z) or 0 }
		end
	end

	-- Optional: sanitize colors to strings (if stored as hex on attributes already, this is safe)
	entry.BodyColor   = tostring(slime:GetAttribute("BodyColor") or "")
	entry.AccentColor = tostring(slime:GetAttribute("AccentColor") or "")
	entry.EyeColor    = tostring(slime:GetAttribute("EyeColor") or "")
	entry.Breed       = tostring(slime:GetAttribute("Breed") or "")

	-- Debug: log the JSON-encoded payload we intend to persist (helps diagnose sanitizer strips)
	local payloadJson = nil
	pcall(function() payloadJson = HttpService:JSONEncode(entry) end)
	dprint("[PersistWorldSlime][Payload] id=", sid, "json=", payloadJson)

	local added = false
	-- Try InventoryService path (preferred for online player)
	if ownerPlayer and InventoryService and type(InventoryService.AddInventoryItem) == "function" then
		local ok, err = pcall(function()
			InventoryService.AddInventoryItem(ownerPlayer, "worldSlimes", entry)
			-- Ensure the Entry_<id> folder is created/populated on the player's Inventory folder
			if type(InventoryService.EnsureEntryHasId) == "function" then
				pcall(function() InventoryService.EnsureEntryHasId(ownerPlayer, "worldSlimes", sid, entry) end)
			else
				-- fallback to local helper which will create Entry_<id> and Data
				pcall(function() ensureInventoryEntryHasId(ownerPlayer, sid, entry) end)
			end
			-- request an inventory->profile update
			pcall(function() InventoryService.UpdateProfileInventory(ownerPlayer) end)
		end)
		if ok then
			added = true
			-- attempt to trigger a SaveNow for the profile
			if PlayerProfileService and type(PlayerProfileService.SaveNow) == "function" then
				-- prefer userId save if available; call both to be robust
				pcall(function() PlayerProfileService.SaveNow(ownerPlayer, "SlimePersist") end)
				pcall(function() PlayerProfileService.SaveNow(ownerUserId, "SlimePersist") end)
			end

			-- Schedule a short re-check dedupe on authoritative profile to reduce duplicates created by concurrent flows
			task.delay(0.25, function()
				pcall(function()
					if PlayerProfileService and type(PlayerProfileService.GetProfile) == "function" then
						local okp, prof = pcall(function() return PlayerProfileService.GetProfile(ownerUserId) end)
						if okp and prof and type(prof) == "table" then
							dedupe_profile_worldslimes(prof)
						end
					end
				end)
			end)
		else
			warn("[EggService] InventoryService.AddInventoryItem(worldSlimes) failed:", tostring(err))
		end
	end

	-- Fallback: write into PlayerProfileService.profile.inventory if InventoryService wasn't available
	if (not added) and PlayerProfileService and type(PlayerProfileService.GetProfile) == "function" then
		local prof = nil
		local okp, profileOrErr = pcall(function() return PlayerProfileService.GetProfile(ownerUserId) end)
		if okp and profileOrErr and type(profileOrErr) == "table" then
			prof = profileOrErr
		else
			-- Try player param (some PPS implementations accept player)
			local okp2, profileOrErr2 = pcall(function() return PlayerProfileService.GetProfile(ownerPlayer) end)
			if okp2 and profileOrErr2 and type(profileOrErr2) == "table" then
				prof = profileOrErr2
			end
		end

		if prof then
			pcall(function()
				prof.inventory = prof.inventory or {}
				prof.inventory.worldSlimes = prof.inventory.worldSlimes or {}
				-- Avoid inserting duplicates by canonical id
				local seen = {}
				for _,e in ipairs(prof.inventory.worldSlimes) do
					if type(e) == "table" then
						local cid = e.id or e.SlimeId or e.slimeId
						if cid then seen[tostring(cid)] = true end
					end
				end
				if not seen[sid] then
					table.insert(prof.inventory.worldSlimes, entry)
				end
			end)
			-- dedupe right away (in-memory) to avoid multiple duplicates if multiple persisters run
			pcall(function() dedupe_profile_worldslimes(prof) end)

			-- attempt SaveNow by userId or profile object if available
			local okSave = false
			if type(PlayerProfileService.SaveNow) == "function" then
				pcall(function()
					-- prefer userId save if we have userId
					if ownerUserId then
						PlayerProfileService.SaveNow(ownerUserId, "SlimePersist")
					else
						PlayerProfileService.SaveNow(prof, "SlimePersist")
					end
				end)
				okSave = true
			end
			if okSave then added = true end
		end
	end

	-- final fallback: if PlayerDataService supports direct save/mark-dirty, ask it to persist
	if (not added) and PlayerDataService then
		local okD, errD = pcall(function()
			if ownerPlayer and type(PlayerDataService.SaveImmediately) == "function" then
				PlayerDataService.SaveImmediately(ownerPlayer, "SlimePersist")
			elseif ownerUserId and type(PlayerDataService.MarkDirty) == "function" then
				PlayerDataService.MarkDirty(ownerUserId, "SlimePersist")
			end
		end)
		if okD then added = true end
	end

	-- Mark slime model attribute so other systems know it's persisted
	pcall(function() slime:SetAttribute("Persisted", added) end)

	-- PATCH: Ensure PersistedGrowthProgress attribute is also set immediately when we persist the slime.
	-- This reduces races between visual model growth and profile saves.
	pcall(function()
		local gp = slime:GetAttribute("GrowthProgress")
		if gp ~= nil then
			slime:SetAttribute("PersistedGrowthProgress", gp)
		else
			if slime:GetAttribute("PersistedGrowthProgress") == nil then
				slime:SetAttribute("PersistedGrowthProgress", 0)
			end
		end
	end)

	-- Re-ensure step: after a short delay re-run EnsureEntryHasId + UpdateProfileInventory + SaveNow
	-- This is to catch and reapply the canonical id in case a concurrent sanitize/merge removed it.
	task.delay(0.15, function()
		pcall(function()
			if ownerPlayer then
				-- Re-ensure folder naming & data locally
				dprint("[PersistWorldSlime][ReEnsure] Re-ensuring Entry_"..tostring(sid).." for player", ownerPlayer.Name)
				if InventoryService and type(InventoryService.EnsureEntryHasId) == "function" then
					pcall(function() InventoryService.EnsureEntryHasId(ownerPlayer, "worldSlimes", sid, entry) end)
				else
					pcall(function() ensureInventoryEntryHasId(ownerPlayer, sid, entry) end)
				end
				-- Request inventory->profile update and SaveNow by userId
				if InventoryService and InventoryService.UpdateProfileInventory then
					pcall(function() InventoryService.UpdateProfileInventory(ownerPlayer) end)
				end
			end
			if PlayerProfileService and type(PlayerProfileService.SaveNow) == "function" and ownerUserId then
				pcall(function() PlayerProfileService.SaveNow(ownerUserId, "SlimePersist_ReEnsure") end)
			end

			-- Ensure we remove any lingering worldEggs entries now that slime persist is ensured.
			pcall(function() safeRemoveWorldEggForPlayer(ownerPlayer or ownerUserId, eggId) end)

			-- NEW: aggressively remove local Inventory.folder entry to avoid duplicate folder artifacts in Explorer
			-- This is a defensive/local-only operation and does not alter persisted profile directly.
			if ownerPlayer then
				pcall(function() removeInventoryEntryFolderWithRetries(ownerPlayer, "worldEggs", eggId) end)
			else
				local resolved = nil
				if ownerUserId then resolved = Players:GetPlayerByUserId(ownerUserId) end
				if resolved then pcall(function() removeInventoryEntryFolderWithRetries(resolved, "worldEggs", eggId) end) end
			end
		end)

		-- PATCH: After re-ensure, request GrowthService/GrowthPersistenceService to flush stamps and trigger a save.
		-- This helps ensure PersistedGrowthProgress is written into the player's saved profile before they leave.
		pcall(function()
			-- First try to make GrowthService write PersistedGrowthProgress attributes for player's slimes.
			if SlimeCore and SlimeCore.GrowthService and type(SlimeCore.GrowthService.FlushPlayerSlimes) == "function" then
				pcall(function() SlimeCore.GrowthService:FlushPlayerSlimes(ownerUserId) end)
			end

			-- Then attempt to ask GrowthPersistenceService to stamp & save (blocking variant if available).
			if SlimeCore and SlimeCore.GrowthPersistenceService and type(SlimeCore.GrowthPersistenceService.FlushPlayerSlimesAndSave) == "function" then
				-- prefer numeric userId
				local okSave, res = pcall(function() return SlimeCore.GrowthPersistenceService.FlushPlayerSlimesAndSave(ownerUserId, 6) end)
				if not okSave then
					dprint("[PersistWorldSlime] GrowthPersistenceService.FlushPlayerSlimesAndSave failed for", ownerUserId, res)
				end
			end
		end)
	end)

	return added
end

----------------------------------------------------------
-- DESTROY / PURGE HELPERS
----------------------------------------------------------

-- New: helper to decide whether a model should be skipped by immediate purge/dedupe logic.
-- This helper intentionally does not call destroyEggModel so it can be declared before destroyEggModel.
local function shouldSkipPurgeForModel(model)
	if not model or not model.Parent then return false end

	-- Prefer explicit restored marker set by GrandInventorySerializer
	local ok, restored = pcall(function() return model:GetAttribute("RestoredByGrandInvSer") end)
	if ok and restored then
		return true
	end

	-- Generic "recently placed & saved" marker (set by RestoreEggSnapshot / PreExitInventorySync)
	local ok2, recent = pcall(function() return model:GetAttribute("RecentlyPlacedSaved") end)
	if ok2 and recent then
		return true
	end

	-- Timestamp-based grace: if RecentlyPlacedSavedAt is present and within grace window, skip purge.
	-- This protects cases where Recent flag may have been written as a timestamp only.
	local ok3, ts = pcall(function() return tonumber(model:GetAttribute("RecentlyPlacedSavedAt")) end)
	if ok3 and ts then
		local PURGE_SKIP_GRACE = 10 -- seconds; tune as needed
		if os.time() - ts <= PURGE_SKIP_GRACE then
			return true
		end
	end

	-- Also defensively skip if model has an explicit "IgnorePurge" attribute (future-safe)
	local ok4, ip = pcall(function() return model:GetAttribute("IgnorePurge") end)
	if ok4 and ip then
		return true
	end

	return false
end

local function destroyEggModel(model, reason)
	if not model then return end
	if model:GetAttribute("EggDestroyed") then return end
	print("[EggService][Debug] destroyEggModel called for:", model.Name, "EggId:", model:GetAttribute("EggId"), "Reason:", reason, "Parent:", tostring(model.Parent))
	model:SetAttribute("EggDestroyed", true)
	model:SetAttribute("Placed", false)
	model:SetAttribute("Hatched", true)
	for _,pp in ipairs(model:GetDescendants()) do
		if pp:IsA("ProximityPrompt") then pp:Destroy() end
	end
	if DEBUG then
		dprint(("[Purge] Destroy egg EggId=%s reason=%s path=%s")
			:format(tostring(model:GetAttribute("EggId")), tostring(reason), model:GetFullName()))
	end

	local owner = model:GetAttribute("OwnerUserId")
	local eggId = model:GetAttribute("EggId")
	if owner and eggId then
		if PlayerProfileService and PlayerProfileService.RemoveInventoryItem then
			local okP, errP = pcall(function()
				PlayerProfileService.RemoveInventoryItem(owner, "worldEggs", "eggId", eggId)
				PlayerProfileService.RemoveInventoryItem(owner, "worldEggs", "EggId", eggId)
			end)
			if not okP then
				warn("[EggService] PlayerProfileService.RemoveInventoryItem failed:", tostring(errP))
			else
				-- persist removal attempt
				pcall(function() PlayerProfileService.SaveNow(owner, "EggDestroyed_Remove") end)
			end
		end

		if InventoryService and InventoryService.RemoveInventoryItem then
			local ply = Players:GetPlayerByUserId(owner)
			if ply then
				local okI, errI = pcall(function()
					InventoryService.RemoveInventoryItem(ply, "worldEggs", "eggId", eggId)
					InventoryService.RemoveInventoryItem(ply, "worldEggs", "EggId", eggId)
					InventoryService.RemoveInventoryItem(ply, "eggTools", "EggId", eggId)
					-- ensure profile update on InventoryService
					pcall(function() InventoryService.UpdateProfileInventory(ply) end)
				end)
				if not okI then
					warn("[EggService] InventoryService.RemoveInventoryItem failed:", tostring(errI))
				end
				-- also ensure the profile is saved
				if PlayerProfileService and type(PlayerProfileService.SaveNow) == "function" then
					pcall(function() PlayerProfileService.SaveNow(owner, "EggDestroyed_RemoveInventory") end)
				end
			else
				-- offline: still attempt profile removal by userId
				if PlayerProfileService and PlayerProfileService.RemoveInventoryItem then
					pcall(function()
						PlayerProfileService.RemoveInventoryItem(owner, "worldEggs", "eggId", eggId)
						PlayerProfileService.RemoveInventoryItem(owner, "worldEggs", "EggId", eggId)
						PlayerProfileService.SaveNow(owner, "EggDestroyed_RemoveInventory_Offline")
					end)
				end
			end
		end
	end

	pcall(function() model:Destroy() end)
end

local function purgeResidualEggModels(ownerUserId, eggId, phase)
	if not RESIDUAL_PURGE_ENABLED then return end
	if not eggId then return end
	local removed = 0

	local function scan(container)
		for _,desc in ipairs(container:GetDescendants()) do
			if desc:IsA("Model") and desc.Name=="Egg" then
				if desc:GetAttribute("EggId") == eggId then
					if shouldSkipPurgeForModel(desc) then
						dprint(("purgeResidualEggModels: skipped residual destroy for eggId=%s at %s"):format(tostring(eggId), tostring(desc:GetFullName())))
					else
						destroyEggModel(desc, "Residual-".. (phase or "immediate"))
						removed += 1
					end
				end
			end
		end
	end

	for _,plr in ipairs(Players:GetPlayers()) do
		if plr.UserId == ownerUserId then
			local okPlot, plot = pcall(function() return (ModulesRoot:FindFirstChild("PlotManager") and require(ModulesRoot:FindFirstChild("PlotManager")) or nil):GetPlayerPlot(plr) end)
			if okPlot and plot then scan(plot) end
			break
		end
	end
	scan(Workspace)

	if removed > 0 and DEBUG then
		dprint(string.format("[Purge] Removed %d residual eggs (eggId=%s phase=%s)", removed, eggId, tostring(phase)))
	end
end

----------------------------------------------------------
-- HATCH
----------------------------------------------------------
local function hatchEgg(worldEgg)
	if not worldEgg or not worldEgg.Parent then return end
	local eggId = worldEgg:GetAttribute("EggId") or HttpService:GenerateGUID(false)
	if HatchInProgress[eggId] then
		dprint("[HatchSeq] Duplicate hatch blocked eggId=".. eggId)
		return
	end
	HatchInProgress[eggId] = true

	local rec = PlacedEggs[worldEgg]
	if rec then
		PlacedEggs[worldEgg] = nil
		DecrementPlaced(rec.OwnerUserId)
		updatePlayerAttr(rec.OwnerUserId)
	end
	worldEgg:SetAttribute("Hatching", true)

	local ownerUserId = worldEgg:GetAttribute("OwnerUserId")
	local ownerPlayer = Players:GetPlayerByUserId(ownerUserId)
	removeSnapshotEntry(ownerUserId, eggId)

	dprint(("[HatchSeq] Start eggId=%s owner=%s placedNow=%d")
		:format(eggId, tostring(ownerUserId), GetPlacedCount(ownerUserId)))

	ensureGraveyard()
	worldEgg.Parent = GraveyardFolder

	-- Early removal attempts (try to remove egg inventory entries immediately)
	if PlayerProfileService and PlayerProfileService.RemoveInventoryItem then
		pcall(function()
			PlayerProfileService.RemoveInventoryItem(ownerUserId, "worldEggs", "eggId", eggId)
			PlayerProfileService.RemoveInventoryItem(ownerUserId, "worldEggs", "EggId", eggId)
			-- schedule an async save to persist
			if type(PlayerProfileService.SaveNow) == "function" then
				PlayerProfileService.SaveNow(ownerUserId, "EggRemoved_PreHatch")
			end
		end)
	end
	if InventoryService and InventoryService.RemoveInventoryItem then
		if ownerPlayer then
			pcall(function()
				InventoryService.RemoveInventoryItem(ownerPlayer, "worldEggs", "eggId", eggId)
				InventoryService.RemoveInventoryItem(ownerPlayer, "worldEggs", "EggId", eggId)
				InventoryService.UpdateProfileInventory(ownerPlayer)
			end)
		end
	end

	local markEggPersistSucceeded = false
	if EGG_HATCH_INPLACE_PERSIST and PlayerDataService and ownerPlayer and PlayerDataService.MarkEggHatched then
		local okMark, err = pcall(function()
			PlayerDataService.MarkEggHatched(ownerPlayer, eggId)
		end)
		if okMark then
			markEggPersistSucceeded = true
		else
			warn("[EggService] MarkEggHatched failed:", err)
		end
	end

	local eggPivotCF
	pcall(function() eggPivotCF = worldEgg:GetPivot() end)

	local slime = SlimeTemplate:Clone()
	slime.Name = "Slime"
	slime:SetAttribute("SlimeId", eggId)
	for _,attr in ipairs({
		"EggId","Rarity","OwnerUserId","MovementScalar","WeightScalar",
		"MutationRarityBonus","ValueBase","ValuePerGrowth"
		}) do
		slime:SetAttribute(attr, worldEgg:GetAttribute(attr))
	end
	slime:SetAttribute("GrowthCompleted", false)
	slime:SetAttribute("MutationStage", 0)
	slime:SetAttribute("AgeSeconds", 0)

	pcall(function() ModelUtils.CleanPhysics(slime) end)
	local primary = choosePrimary(slime)
	if not primary then
		warn("[EggService] Hatch abort: no primary part")
		destroyEggModel(worldEgg, "NoPrimary")
		HatchInProgress[eggId] = nil
		return
	end
	captureOriginalData(slime, primary)

	local rng = (RNG and RNG.New and RNG.New()) or Random.new()
	initializeGrowthAttributes(slime, rng)
	local startScale = slime:GetAttribute("StartSizeScale")
	if startScale and startScale < MIN_VISIBLE_START_SCALE then
		slime:SetAttribute("StartSizeScale", MIN_VISIBLE_START_SCALE)
		slime:SetAttribute("CurrentSizeScale", MIN_VISIBLE_START_SCALE)
	end
	applyInitialScale(slime, primary, slime:GetAttribute("StartSizeScale"))
	local okWeld, weldErr = pcall(function() ModelUtils.AutoWeld(slime, primary) end)
	if not okWeld then warn("[EggService] AutoWeld failed:", weldErr) end

	for _,p in ipairs(slime:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = false
			p.Massless = false
		end
	end
	applyAppearance(slime, primary, rng)

	if slime:GetAttribute("CurrentFullness") == nil then
		local now = os.time()
		slime:SetAttribute("CurrentFullness", 1)
		slime:SetAttribute("LastHungerUpdate", now)
		slime:SetAttribute("HungerDecayRate", DEFAULT_HUNGER_DECAY)
		slime:SetAttribute("FedFraction", 1)
	end

	local zone = rec and rec.Zone
	if not zone and ownerPlayer then
		local okPlot, playerPlot = pcall(function() return (ModulesRoot:FindFirstChild("PlotManager") and require(ModulesRoot:FindFirstChild("PlotManager")) or nil):GetPlayerPlot(ownerPlayer) end)
		if okPlot and playerPlot then
			zone = (ModulesRoot:FindFirstChild("PlotManager") and require(ModulesRoot:FindFirstChild("PlotManager")) or nil):GetPlotOrigin(playerPlot)
		end
	end

	local neutralParent
	if FORCE_SLIME_PARENT_UNDER_WORKSPACE then
		local root = Workspace:FindFirstChild(SLIME_PARENT_FOLDER_NAME)
		if not root then
			root = Instance.new("Folder")
			root.Name = SLIME_PARENT_FOLDER_NAME
			root.Parent = Workspace
		end
		if USE_PER_PLAYER_SUBFOLDERS and ownerPlayer then
			neutralParent = root:FindFirstChild(ownerPlayer.Name)
			if not neutralParent then
				neutralParent = Instance.new("Folder")
				neutralParent.Name = ownerPlayer.Name
				neutralParent.Parent = root
			end
		else
			neutralParent = root
		end
	else
		neutralParent = zone or Workspace
	end
	slime.Parent = neutralParent

	if not eggPivotCF then
		if zone then
			eggPivotCF = zone.CFrame
		else
			eggPivotCF = CFrame.new(0,5,0)
		end
	end
	eggPivotCF = eggPivotCF + Vector3.new(0, SPAWN_UPWARD_OFFSET, 0)
	pcall(function() slime:PivotTo(eggPivotCF) end)

	if FORCE_PROMOTE_ASSEMBLY_ROOT and primary then
		local root = primary.AssemblyRootPart
		if root and root ~= primary then
			slime.PrimaryPart = root
			if LOG_ROOT_PROMOTION then
				print(("[EggService][RootPromotion] SlimeId=%s PrimaryPart %s -> %s"):format(eggId, primary.Name, root.Name))
			end
		end
	end

	visibilitySummary(slime)
	-- Remove the egg model now that slime is created
	destroyEggModel(worldEgg, "HatchComplete")

	-- Persist the created slime into the player's profile (primitive-only table)
	local persisted_ok = false
	local okPersist, errPersist = pcall(function()
		persisted_ok = persistWorldSlime(ownerPlayer, ownerUserId, slime, eggId)
	end)
	if not okPersist then
		warn("[EggService] persistWorldSlime failed:", tostring(errPersist))
	end
	-- If persist succeeded, markEggPersistSucceeded should reflect that
	markEggPersistSucceeded = markEggPersistSucceeded or persisted_ok

	-- PATCH: Immediately ask GrowthService to flush persisted progress attributes for this player's slimes.
	-- This makes sure PersistedGrowthProgress attributes get written before any final profile save race.
	pcall(function()
		if SlimeCore and SlimeCore.GrowthService and type(SlimeCore.GrowthService.FlushPlayerSlimes) == "function" then
			SlimeCore.GrowthService:FlushPlayerSlimes(ownerUserId)
		end
		-- Also attempt to request the GrowthPersistenceService to stamp+save right away.
		if SlimeCore and SlimeCore.GrowthPersistenceService and type(SlimeCore.GrowthPersistenceService.FlushPlayerSlimesAndSave) == "function" then
			pcall(function() SlimeCore.GrowthPersistenceService.FlushPlayerSlimesAndSave(ownerUserId, 6) end)
		end
	end)

	-- Defensive: ensure egg inventory entries are removed after persist (final guarantee)
	pcall(function() safeRemoveWorldEggForPlayer(ownerPlayer or ownerUserId, eggId) end)

	-- If PlayerDataService path exists, make sure server data service knows about the change
	if PlayerDataService and ownerPlayer then
		if not markEggPersistSucceeded then
			if SAVE_ON_HATCH_IMMEDIATE and PlayerDataService.SaveImmediately then
				local okSave, err = pcall(function()
					PlayerDataService.SaveImmediately(ownerPlayer, "EggHatched")
				end)
				if not okSave then
					warn("[EggService] Immediate save failed:", err)
					if PlayerDataService.MarkDirty then
						pcall(function() PlayerDataService.MarkDirty(ownerPlayer, "EggHatched") end)
					end
				end
			else
				if PlayerDataService.MarkDirty then
					pcall(function() PlayerDataService.MarkDirty(ownerPlayer, "EggHatched") end)
					task.delay(POST_HATCH_SAVE_FALLBACK_DELAY, function()
						if slime.Parent and PlayerDataService.MarkDirty then
							pcall(function() PlayerDataService.MarkDirty(ownerPlayer, "EggHatchedDeferred") end)
						end
					end)
				end
			end
		else
			-- persisted via persistWorldSlime; let data service know
			if PlayerDataService and PlayerDataService.MarkDirty then
				pcall(function() PlayerDataService.MarkDirty(ownerPlayer, "SlimeFromEgg") end)
			end
		end
	end

	task.defer(function()
		if slime.Parent then
			pcall(function()
				if SlimeAI and type(SlimeAI.Start) == "function" then SlimeAI.Start(slime, zone) end
			end)
		end
	end)

	dprint(("[EggService] Hatched egg -> slime (owner=%s persisted=%s)")
		:format(tostring(ownerUserId), tostring(markEggPersistSucceeded)))

	if RESIDUAL_PURGE_ENABLED then
		purgeResidualEggModels(ownerUserId, eggId, "immediate")
		for _,delaySec in ipairs(RESIDUAL_PURGE_EXTRA_PASSES) do
			task.delay(delaySec, function()
				purgeResidualEggModels(ownerUserId, eggId, "delay".. tostring(delaySec))
			end)
		end
	end

	HatchInProgress[eggId] = nil
end

----------------------------------------------------------
-- REGISTER / DEDUPE / ADOPT
----------------------------------------------------------
local function registerEggModel(worldEgg)
	if PlacedEggs[worldEgg] then return end
	if not worldEgg or not worldEgg.Parent then return end
	if worldEgg:GetAttribute("Hatching") or worldEgg:GetAttribute("Hatched") then return end

	local eggId = worldEgg:GetAttribute("EggId")
	if not eggId then
		eggId = HttpService:GenerateGUID(false)
		worldEgg:SetAttribute("EggId", eggId)
		if DEBUG then dprint("Assigned missing EggId="..eggId) end
	end

	local prior = EggIdSeenWorld[eggId]
	if prior and prior ~= worldEgg and prior.Parent then
		local pa = prior:GetAttribute("PlacedAt") or math.huge
		local pb = worldEgg:GetAttribute("PlacedAt") or math.huge
		if pb >= pa then
			if shouldSkipPurgeForModel(worldEgg) then
				dprint(("RegisterEgg: skipped dedupe destroy for restored/new egg EggId=%s Parent=%s"):format(tostring(worldEgg:GetAttribute("EggId")), tostring(worldEgg.Parent and worldEgg.Parent:GetFullName())))
				return
			end
			destroyEggModel(worldEgg, "DedupeLater")
			return
		else
			if shouldSkipPurgeForModel(prior) then
				dprint(("RegisterEgg: skipped dedupe destroy for prior restored egg EggId=%s Parent=%s"):format(tostring(prior:GetAttribute("EggId")), tostring(prior.Parent and prior.Parent:GetFullName())))
			else
				destroyEggModel(prior, "DedupeLaterOlderReplaced")
			end
		end
	end
	EggIdSeenWorld[eggId] = worldEgg

	local owner = worldEgg:GetAttribute("OwnerUserId")
	local hatchAt= worldEgg:GetAttribute("HatchAt")
	-- Accept eggs that have HatchAt or can be derived by client; for server adoption we require owner at least.
	if not owner then return end

	PlacedEggs[worldEgg] = {
		HatchAt = worldEgg:GetAttribute("HatchAt"),
		OwnerUserId = owner,
		Zone = nil,
		Gui = nil,
		LastGuiUpdate = 0,
	}

	IncrementPlaced(owner)
	updatePlayerAttr(owner)
	pushSnapshot(worldEgg)

	-- When we add worldEgg to the player's inventory we should also mark the model as "RecentlyPlacedSaved"
	-- and request an authoritative profile save to reduce race windows where the egg is not persisted.
	if InventoryService and InventoryService.AddInventoryItem then
		local ply = Players:GetPlayerByUserId(owner)
		if ply then
			pcall(function()
				local payloadItem = {
					id = tostring(eggId),
					eggId = tostring(eggId),
					hatchAt = worldEgg:GetAttribute("HatchAt"),
					hatchTime = worldEgg:GetAttribute("HatchTime"),
					placedAt = worldEgg:GetAttribute("PlacedAt"),
					rarity = worldEgg:GetAttribute("Rarity"),
					valueBase = worldEgg:GetAttribute("ValueBase"),
					valuePerGrowth = worldEgg:GetAttribute("ValuePerGrowth"),
				}
				InventoryService.AddInventoryItem(ply, "worldEggs", payloadItem)
				pcall(function() InventoryService.UpdateProfileInventory(ply) end)

				-- ensure Entry_<id> folder is created on the player's Inventory folder
				if type(InventoryService.EnsureEntryHasId) == "function" then
					pcall(function() InventoryService.EnsureEntryHasId(ply, "worldEggs", eggId, payloadItem) end)
				else
					-- fallback to older helper in this module
					ensureInventoryEntryHasId(ply, eggId, payloadItem)
				end

				-- Immediately mark model so purge logic won't remove it while profile update races.
				pcall(function()
					worldEgg:SetAttribute("RecentlyPlacedSaved", true)
					worldEgg:SetAttribute("RecentlyPlacedSavedAt", os.time())
				end)

				-- Request an authoritative profile save shortly after adding the item to reduce race with quick leave.
				if PlayerProfileService and type(PlayerProfileService.SaveNow) == "function" then
					task.delay(0.15, function()
						pcall(function() PlayerProfileService.SaveNow(owner, "EggRegistered_SaveNow") end)
					end)
				elseif PlayerDataService and type(PlayerDataService.SaveImmediately) == "function" then
					task.delay(0.15, function()
						pcall(function() PlayerDataService.SaveImmediately(ply, "EggRegistered_SaveNow") end)
					end)
				end
			end)

			-- Defensive: schedule a dedupe pass on authoritative profile to reduce possibility of InventoryService adding duplicates
			task.delay(0.3, function()
				pcall(function()
					if PlayerProfileService and type(PlayerProfileService.GetProfile) == "function" then
						local okp, prof = pcall(function() return PlayerProfileService.GetProfile(owner) end)
						if okp and prof and type(prof) == "table" then
							dedupe_profile_worldslimes(prof)
						end
					end
				end)
			end)
		end
	end

	if DEBUG then
		dprint(("RegisterEgg eggId=%s owner=%s placed=%d/%d hatchIn=%.1fs")
			:format(eggId, tostring(owner),
				GetPlacedCount(owner), GetEggPlacementCap({UserId=owner}),
				math.max(0,(worldEgg:GetAttribute("HatchAt") or os.time()) - os.time())))
	end
end

local function adoptExistingEggs()
	local adopted = 0
	for _,desc in ipairs(Workspace:GetDescendants()) do
		if desc:IsA("Model") and desc.Name=="Egg" and desc:GetAttribute("Placed") and desc:GetAttribute("HatchAt") then
			if not PlacedEggs[desc] and not desc:GetAttribute("Hatching") and not desc:GetAttribute("Hatched") then
				local owner = desc:GetAttribute("OwnerUserId")
				if owner and GetPlacedCount(owner) < GetEggPlacementCap({UserId=owner}) then
					registerEggModel(desc)
					adopted += 1
				else
					if shouldSkipPurgeForModel(desc) then
						dprint(("AdoptExistingEggs: skipped destroy for restored egg EggId=%s Parent=%s"):format(tostring(desc:GetAttribute("EggId")), tostring(desc.Parent and desc.Parent:GetFullName())))
					else
						destroyEggModel(desc, "AdoptOverCapOrNoOwner")
					end
				end
			end
		end
	end
	if DEBUG then
		dprint("AdoptExistingEggs complete adopted=".. adopted)
	end
end

Workspace.DescendantAdded:Connect(function(inst)
	if not inst:IsA("Model") then return end
	if inst:GetAttribute("Placed") and inst:GetAttribute("HatchAt") and not PlacedEggs[inst] then
		registerEggModel(inst)
	end
end)

-- Register eggs restored to the plot by InventoryService/GrandInventorySerializer
local function onEggRestoredToPlot(desc)
	if desc:IsA("Model") and desc.Name == "Egg" and desc:GetAttribute("Placed") and desc:GetAttribute("OwnerUserId") then
		registerEggModel(desc)
	end
end

for _,plot in ipairs(Workspace:GetChildren()) do
	if plot:IsA("Model") and plot.Name:match("^Player%d+$") then
		plot.DescendantAdded:Connect(onEggRestoredToPlot)
	end
end

Workspace.ChildAdded:Connect(function(child)
	if child:IsA("Model") and child.Name:match("^Player%d+$") then
		child.DescendantAdded:Connect(onEggRestoredToPlot)
	end
end)

----------------------------------------------------------
-- TOOL METADATA
----------------------------------------------------------
local function ensureToolMetadata(tool, player)
	if not tool then return end
	if not AUTO_REPAIR_TOOL_METADATA then return end
	if not tool:GetAttribute("OwnerUserId") then tool:SetAttribute("OwnerUserId", player.UserId) end
	if not tool:GetAttribute("ServerIssued") then tool:SetAttribute("ServerIssued", true) end
	if not tool:GetAttribute("EggId") then tool:SetAttribute("EggId", HttpService:GenerateGUID(false)) end
end

----------------------------------------------------------
-- PLACEMENT
----------------------------------------------------------
local function uniformHatchTime()
	return math.random(HATCH_TIME_RANGE[1], HATCH_TIME_RANGE[2])
end

local function placeEgg(player, hitCFrame, tool)
	if typeof(hitCFrame) ~= "CFrame" then return dfail("BadHitCFrame") end
	if not CanPlaceEgg(player) then return dfail("LimitReached") end

	local last = player:GetAttribute("LastEggPlace") or 0
	if PLACE_COOLDOWN > 0 and os.clock() - last < PLACE_COOLDOWN then
		return dfail("Cooldown")
	end

	if tool and tool:IsA("Tool") then
		ensureToolMetadata(tool, player)
		if tool:GetAttribute("OwnerUserId") ~= player.UserId then return dfail("OwnerMismatch") end
		if not tool:GetAttribute("ServerIssued") then return dfail("NotServerIssued") end
		if tool:GetAttribute(REJECT_PREVIEW_ATTRIBUTE) then return dfail("PreviewTool") end
	else
		for _,cand in ipairs(player.Character and player.Character:GetChildren() or {}) do
			if cand:IsA("Tool") and cand:GetAttribute("EggId") then tool = cand break end
		end
		if not tool then
			for _,cand in ipairs(player.Backpack:GetChildren()) do
				if cand:IsA("Tool") and cand:GetAttribute("EggId") then tool = cand break end
			end
		end
		if not tool then return dfail("NoTool") end
		ensureToolMetadata(tool, player)
	end

	local eggId = tool:GetAttribute("EggId") or HttpService:GenerateGUID(false)

	local worldEgg = EggTemplate:Clone()
	worldEgg.Name = "Egg"
	worldEgg:SetAttribute("EggId", eggId)
	worldEgg:SetAttribute("OwnerUserId", player.UserId)
	worldEgg:SetAttribute("Placed", true)
	worldEgg:SetAttribute("PlacedAt", os.time())
	worldEgg:SetAttribute("ManualHatch", MANUAL_HATCH_MODE)

	local hatchTime = uniformHatchTime()
	worldEgg:SetAttribute("HatchTime", hatchTime)
	worldEgg:SetAttribute("HatchAt", os.time() + hatchTime)

	local primary = choosePrimary(worldEgg)
	if primary then
		primary.CFrame = hitCFrame
	end

	local parentFolder = nil
	local tries = 0
	repeat
		local okPlot, playerPlot = pcall(function() return (ModulesRoot:FindFirstChild("PlotManager") and require(ModulesRoot:FindFirstChild("PlotManager")) or nil):GetPlayerPlot(player) end)
		if okPlot and playerPlot then
			parentFolder = playerPlot
		else
			tries = tries + 1
			task.wait(0.1)
		end
	until parentFolder or tries > 50

	if not parentFolder then
		parentFolder = Workspace
		warn("[EggService] WARNING: Could not find plot for player, placing egg in Workspace!")
	end
	worldEgg.Parent = parentFolder

	print("[EggService][Debug] Egg parented to:", worldEgg.Parent:GetFullName())

	PlacedEggs[worldEgg] = {
		HatchAt = worldEgg:GetAttribute("HatchAt"),
		OwnerUserId = player.UserId,
		Zone = nil,
		Gui = nil,
		LastGuiUpdate = 0,
	}
	IncrementPlaced(player.UserId)
	updatePlayerAttr(player.UserId)
	pushSnapshot(worldEgg)

	player:SetAttribute("LastEggPlace", os.clock())

	local function tryRemoveEggToolFromInventory()
		if PlayerProfileService and PlayerProfileService.RemoveInventoryItem then
			pcall(function()
				PlayerProfileService.RemoveInventoryItem(player, "eggTools", "EggId", eggId)
				PlayerProfileService.RemoveInventoryItem(player, "eggTools", "eggId", eggId)
			end)
		end
		if InventoryService and InventoryService.RemoveInventoryItem then
			pcall(function()
				InventoryService.RemoveInventoryItem(player, "eggTools", "EggId", eggId)
				InventoryService.RemoveInventoryItem(player, "eggTools", "eggId", eggId)
			end)
		end
	end
	tryRemoveEggToolFromInventory()

	if InventoryService and InventoryService.AddInventoryItem then
		pcall(function()
			local payload = {
				id = tostring(eggId),
				eggId = tostring(eggId),
				hatchAt = worldEgg:GetAttribute("HatchAt"),
				hatchTime = worldEgg:GetAttribute("HatchTime"),
				placedAt = worldEgg:GetAttribute("PlacedAt"),
				rarity = worldEgg:GetAttribute("Rarity"),
				valueBase = worldEgg:GetAttribute("ValueBase"),
				valuePerGrowth = worldEgg:GetAttribute("ValuePerGrowth"),
			}
			InventoryService.AddInventoryItem(player, "worldEggs", payload)
			pcall(function() InventoryService.UpdateProfileInventory(player) end)

			-- ensure Entry_<id> folder exists and contains Data
			if type(InventoryService.EnsureEntryHasId) == "function" then
				pcall(function() InventoryService.EnsureEntryHasId(player, "worldEggs", eggId, payload) end)
			else
				ensureInventoryEntryHasId(player, eggId, payload)
			end

			-- mark recently-saved so pre-exit/cleanup won't race and destroy model
			pcall(function()
				worldEgg:SetAttribute("RecentlyPlacedSaved", true)
				worldEgg:SetAttribute("RecentlyPlacedSavedAt", os.time())
			end)

			-- request a short-delay authoritative save so the added inventory is persisted
			if PlayerProfileService and type(PlayerProfileService.SaveNow) == "function" then
				task.delay(0.15, function()
					pcall(function() PlayerProfileService.SaveNow(player.UserId, "EggPlaced_SaveNow") end)
				end)
			elseif PlayerDataService and type(PlayerDataService.SaveImmediately) == "function" then
				task.delay(0.15, function()
					pcall(function() PlayerDataService.SaveImmediately(player, "EggPlaced_SaveNow") end)
				end)
			end
		end)
	end

	if tool.Parent then
		print("[EggService][Debug] Destroying egg tool after placement:", tool.Name, "EggId:", tool:GetAttribute("EggId"), "Parent:", tostring(tool.Parent))
		tool:Destroy()
	end

	dprint(("Placed egg eggId=%s hatchIn=%ds placed=%d/%d")
		:format(eggId, hatchTime, GetPlacedCount(player.UserId), GetEggPlacementCap(player)))
end

local function onPlaceEggRemote(player, a, b)
	if typeof(a) == "CFrame" then
		placeEgg(player, a, b)
	else
		dfail("BadRemoteArgs")
	end
end

local function onManualHatch(player, worldEgg)
	if not MANUAL_HATCH_MODE then return end
	if not (worldEgg and worldEgg:IsA("Model") and PlacedEggs[worldEgg]) then return end
	local rec = PlacedEggs[worldEgg]
	if rec.OwnerUserId ~= player.UserId then return end
	if rec.HatchAt > os.time() then return end
	hatchEgg(worldEgg)
end


-- INSERT: RestoreEggSnapshot(userId, eggList)
-- Adds a second restore path that creates egg models from a profile/worldEgg snapshot.
-- Safe/defensive: tolerant of incomplete entries and missing PlotManager; will fall back to Workspace parent.

-- Replace or insert this function into EggService.lua (place after registerEggModel / pushSnapshot definitions
-- and before the final `return EggService` so those locals are available).
function EggService.RestoreEggSnapshot(userId, eggList)
	if not eggList or type(eggList) ~= "table" or #eggList == 0 then return false end
	local uid = tonumber(userId) or userId
	if not uid then return false end

	-- Try to resolve a plot folder for this user via PlotManager or by scanning Workspace
	local plotFolder = nil
	pcall(function()
		local pmModule = nil
		local ms = ModulesRoot
		if ms and ms:FindFirstChild("PlotManager") then
			local ok, pm = pcall(function() return require(ms:FindFirstChild("PlotManager")) end)
			if ok and pm then pmModule = pm end
		elseif ServerScriptService and ServerScriptService:FindFirstChild("Modules") then
			local modFolder = ServerScriptService:FindFirstChild("Modules")
			if modFolder and modFolder:FindFirstChild("PlotManager") then
				local ok2, pm2 = pcall(function() return require(modFolder:FindFirstChild("PlotManager")) end)
				if ok2 and pm2 then pmModule = pm2 end
			end
		end

		if pmModule and type(pmModule.GetPlayerPlot) == "function" then
			local okP, p = pcall(function()
				local pl = Players:GetPlayerByUserId(uid)
				if pl then return pmModule:GetPlayerPlot(pl) end
				-- fallback: some PlotManager implementations expose GetPlotFolderForUser userId API
				if type(pmModule.GetPlotFolderForUser) == "function" then
					return pmModule.GetPlotFolderForUser(uid)
				end
				return nil
			end)
			if okP and p then plotFolder = p end
		end
	end)

	-- Fallback: find any Model under Workspace whose UserId/OwnerUserId matches uid and name looks like Player%d+
	if not plotFolder then
		for _, m in ipairs(Workspace:GetChildren()) do
			if m and m:IsA("Model") and tostring(m.Name):match("^Player%d+$") then
				local ok, attr = pcall(function() return m:GetAttribute("UserId") or m:GetAttribute("OwnerUserId") or m:GetAttribute("AssignedUserId") end)
				if ok and attr and tostring(attr) == tostring(uid) then
					plotFolder = m
					break
				end
			end
		end
	end

	-- helper: ensure PrimaryPart & interaction object (Prompt / ClickDetector)
	local function ensurePrimaryAndInteraction(m)
		-- ensure primary part
		if not m.PrimaryPart then
			local handle = m:FindFirstChild("Handle") or m:FindFirstChildWhichIsA("BasePart")
			if handle then
				pcall(function() m.PrimaryPart = handle end)
			end
		end

		-- check for existing ClickDetector/ProximityPrompt
		local hasInteract = false
		for _,d in ipairs(m:GetDescendants()) do
			if d:IsA("ClickDetector") or d:IsA("ProximityPrompt") then
				hasInteract = true
				break
			end
		end

		if not hasInteract then
			-- try to clone the interaction from the EggTemplate (if present)
			local src = nil
			pcall(function()
				if EggTemplate and EggTemplate:IsA("Model") then
					-- search recursively in template
					for _,desc in ipairs(EggTemplate:GetDescendants()) do
						if desc:IsA("ProximityPrompt") or desc:IsA("ClickDetector") then
							src = desc
							break
						end
					end
				end
			end)

			if src then
				local ok, clone = pcall(function() return src:Clone() end)
				if ok and clone then
					local target = m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart") or m
					pcall(function() clone.Parent = target end)
					return
				end
			end

			-- fallback: create a minimal ClickDetector on primary/base part so client code can detect it
			local primary = m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart")
			if primary then
				local cd = Instance.new("ClickDetector")
				cd.MaxActivationDistance = 32
				pcall(function() cd.Parent = primary end)
			end
		end
	end

	local createdAny = false
	for _, entry in ipairs(eggList) do
		pcall(function()
			if type(entry) ~= "table" then return end

			-- Normalized id fields (accept many variants)
			local eggId = entry and (entry.eggId or entry.id or entry.EggId or entry.EggID) or nil
			if not eggId then
				eggId = HttpService and HttpService:GenerateGUID(false) or ("egg_" .. tostring(os.time()) .. "_" .. tostring(math.random(1, 1e6)))
			end

			-- clone template where available
			local m = nil
			local okClone, cloned = pcall(function() return (EggTemplate and EggTemplate:IsA("Model")) and EggTemplate:Clone() end)
			if okClone and cloned then
				m = cloned
			else
				m = Instance.new("Model")
				m.Name = "Egg"
				local p = Instance.new("Part")
				p.Name = "Handle"
				p.Size = Vector3.new(1,1,1)
				p.Anchored = false
				p.Parent = m
				m.PrimaryPart = p
			end

			m.Name = "Egg"
			-- attributes: normalize keys and set canonical fields
			pcall(function() m:SetAttribute("EggId", tostring(eggId)) end)
			pcall(function() m:SetAttribute("Placed", true) end)
			-- CRITICAL: ensure ManualHatch attribute is set so client hatch UI recognizes the egg
			pcall(function() m:SetAttribute("ManualHatch", MANUAL_HATCH_MODE) end)
			pcall(function() m:SetAttribute("OwnerUserId", tonumber(uid) or uid) end)

			-- placedAt / cr / placed_at variants
			local placedAt = entry and (entry.placedAt or entry.PlacedAt or entry.cr or entry.placed_at) or nil
			if placedAt then pcall(function() m:SetAttribute("PlacedAt", tonumber(placedAt) or placedAt) end) end

			-- hatch info: ht/ha/HatchTime/HatchAt
			local ht = entry and (entry.ht or entry.hatchTime or entry.HatchTime) or nil
			local ha = entry and (entry.ha or entry.hatchAt or entry.HatchAt) or nil
			if ht then pcall(function() m:SetAttribute("HatchTime", tonumber(ht)) end) end
			-- compute/normalize HatchAt: accept epoch-like or compute from placedAt+ht
			local hatchAtEpoch = nil
			if ha then
				local n = tonumber(ha)
				if n then
					hatchAtEpoch = n
				end
			end
			if not hatchAtEpoch and ht and placedAt then
				local pval = tonumber(placedAt) or nil
				local htv = tonumber(ht) or nil
				if pval and htv then
					hatchAtEpoch = pval + htv
				end
			end
			if not hatchAtEpoch and ht then
				hatchAtEpoch = os.time() + tonumber(ht)
			end
			if hatchAtEpoch then pcall(function() m:SetAttribute("HatchAt", hatchAtEpoch) end) end

			-- optional attributes from WE_ATTR_MAP in serializer
			for k,v in pairs(entry) do
				if type(k) == "string" then
					if not (k == "id" or k == "eggId" or k == "EggId" or k == "Placed" or k == "PlacedAt" or k == "OwnerUserId") then
						pcall(function() m:SetAttribute(k, v) end)
					end
				end
			end

			-- position: support px/py/pz or Position table
			local prim = m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart")
			if prim then
				local px = entry and (entry.px or (entry.Position and entry.Position.x))
				local py = entry and (entry.py or (entry.Position and entry.Position.y))
				local pz = entry and (entry.pz or (entry.Position and entry.Position.z))
				if px and py and pz then
					local okPos, cf = pcall(function() return CFrame.new(tonumber(px) or 0, tonumber(py) or 0, tonumber(pz) or 0) end)
					if okPos and cf then
						pcall(function() prim.CFrame = cf end)
					end
				end
			end

			-- parent to plotFolder if found, else to Workspace
			local targetParent = plotFolder or Workspace
			pcall(function() m.Parent = targetParent end)

			-- set RecentlyPlacedSaved markers to avoid immediate cleanup/dedupe
			local now = os.time()
			pcall(function() m:SetAttribute("RecentlyPlacedSaved", true) end)
			pcall(function() m:SetAttribute("RecentlyPlacedSavedAt", now) end)
			pcall(function() m:SetAttribute("RestoredByGrandInvSer", true) end)

			-- ensure PrimaryPart and an interaction object exist
			ensurePrimaryAndInteraction(m)

			-- ensure EggService register sees it: call registerEggModel (module-local)
			pcall(function() registerEggModel(m) end)

			-- ensure we push a snapshot to EggSnapshot for consistency
			pcall(function() pushSnapshot(m) end)

			createdAny = true
		end)
	end

	return createdAny
end

local function pollLoop()
	while true do
		local now = os.time()
		for egg,rec in pairs(PlacedEggs) do
			if not egg.Parent then
				PlacedEggs[egg] = nil
				DecrementPlaced(rec.OwnerUserId)
				updatePlayerAttr(rec.OwnerUserId)
				removeSnapshotEntry(rec.OwnerUserId, egg:GetAttribute("EggId"))
			else
				if (not rec.LastGuiUpdate) or (now - rec.LastGuiUpdate >= HATCH_GUI_UPDATE_INTERVAL) then
					local gui = egg:FindFirstChild(HATCH_TIMER_NAME)
					if not gui then
						local primary = egg.PrimaryPart or egg:FindFirstChildWhichIsA("BasePart")
						if primary then
							local billboard = Instance.new("BillboardGui")
							billboard.Name = HATCH_TIMER_NAME
							billboard.Size = HATCH_GUI_SIZE
							billboard.AlwaysOnTop = true
							billboard.MaxDistance = 0
							billboard.StudsOffsetWorldSpace = Vector3.new(0,(primary.Size.Y)*0.5 + HATCH_GUI_OFFSET_Y,0)
							billboard.Adornee = primary

							local label = Instance.new("TextLabel")
							label.Name = "TimeLabel"
							label.BackgroundTransparency = 1
							label.Size = UDim2.fromScale(1,1)
							label.Font = HATCH_GUI_FONT
							label.TextScaled = true
							label.TextColor3 = HATCH_GUI_TEXTCOLOR
							label.TextStrokeColor3 = HATCH_GUI_TEXTSTROKE
							label.TextStrokeTransparency = HATCH_GUI_TEXTSTROKE_T
							label.Text = ""
							label.Parent = billboard

							billboard.Parent = egg
						end
					end
					local billboard = egg:FindFirstChild(HATCH_TIMER_NAME)
					if billboard then
						local label = billboard:FindFirstChild("TimeLabel")
						if label then
							local remaining = rec.HatchAt - now
							if remaining <= 0 then
								label.Text = MANUAL_HATCH_MODE and "Ready!" or "Hatching..."
								label.TextColor3 = Color3.fromRGB(120,255,120)
							else
								local m = math.floor(remaining/60)
								local s = math.floor(remaining%60)
								if HATCH_TIME_DECIMALS > 0 then
									label.Text = string.format("%02d:%02d.%d", m,s, math.floor((remaining - math.floor(remaining))*10))
								else
									label.Text = string.format("%02d:%02d", m, s)
								end
								if remaining <= HATCH_LOW_WARN_THRESHOLD and HATCH_FLASH_RATE then
									local t = (math.sin(now * math.pi * HATCH_FLASH_RATE)+1)*0.5
									label.TextColor3 = HATCH_GUI_TEXTCOLOR:Lerp(HATCH_WARN_COLOR, t)
								else
									label.TextColor3 = HATCH_GUI_TEXTCOLOR
								end
							end
						end
					end
					rec.LastGuiUpdate = now
				end

				if (not MANUAL_HATCH_MODE) and AUTO_HATCH_WHEN_READY and rec.HatchAt <= now then
					hatchEgg(egg)
				end
			end
		end

		if RESIDUAL_PURGE_ENABLED then
			for _,plr in ipairs(Players:GetPlayers()) do
				local okPlot, plot = pcall(function() return (ModulesRoot:FindFirstChild("PlotManager") and require(ModulesRoot:FindFirstChild("PlotManager")) or nil):GetPlayerPlot(plr) end)
				if okPlot and plot then
					for _,desc in ipairs(plot:GetDescendants()) do
						if desc:IsA("Model") and desc.Name=="Egg" and not PlacedEggs[desc] then
							local hat = desc:GetAttribute("HatchAt")
							if desc:GetAttribute("Hatching") or desc:GetAttribute("Hatched") then
								if shouldSkipPurgeForModel(desc) then
									dprint(("pollLoop: skipped OrphanTransitional destroy for restored egg EggId=%s"):format(tostring(desc:GetAttribute("EggId"))))
								else
									destroyEggModel(desc, "OrphanTransitional")
								end
							elseif hat and type(hat)=="number" and (now - hat) > ORPHAN_EGG_GRACE_SECONDS then
								if shouldSkipPurgeForModel(desc) then
									dprint(("pollLoop: skipped OrphanExpired destroy for restored egg EggId=%s"):format(tostring(desc:GetAttribute("EggId"))))
								else
									destroyEggModel(desc, "OrphanExpired")
								end
							end
						end
					end
				end
			end
		end

		task.wait(HATCH_POLL_INTERVAL)
	end
end

local function destroyPlayerEggs(userId)
	if not CLEAR_EGGS_ON_LEAVE then return end
	for egg,rec in pairs(PlacedEggs) do
		if rec.OwnerUserId == userId then
			removeSnapshotEntry(userId, egg:GetAttribute("EggId"))
			destroyEggModel(egg, "LeaveCleanup")
			PlacedEggs[egg] = nil
		end
	end
	PlacedCountByUid[userId] = 0
	EggSnapshot[userId] = nil
	updatePlayerAttr(userId)
end

function EggService.Init()
	if _initialized then
		dprint("Init() ignored (already initialized). Version=".. EggService.__Version)
		return EggService
	end
	_initialized = true

	PlaceEggEvent.OnServerEvent:Connect(onPlaceEggRemote)
	if MANUAL_HATCH_MODE and HatchEggRemote then
		HatchEggRemote.OnServerEvent:Connect(onManualHatch)
	end

	-- Initialize SlimeCore runtime (growth/hunger) and wire GrowthPersistenceService to available save/orchestrator APIs.
	-- Defensive: only run if SlimeCore present and methods exist.
	pcall(function()
		if SlimeCore and type(SlimeCore.Init) == "function" then
			pcall(function() SlimeCore.Init() end)
			dprint("SlimeCore.Init() called")
		end

		if SlimeCore and SlimeCore.GrowthPersistenceService and type(SlimeCore.GrowthPersistenceService.Init) == "function" then
			-- create a small orchestrator object expected by GrowthPersistenceService
			local orchestrator = {}

			function orchestrator:MarkDirty(playerOrId, reason)
				-- best-effort: accept Player instance or numeric userId
				pcall(function()
					local ply = nil
					if type(playerOrId) == "table" and playerOrId.UserId then ply = playerOrId end
					if tonumber(playerOrId) and not ply then ply = Players:GetPlayerByUserId(tonumber(playerOrId)) end

					-- try to update inventory sync first (fast path)
					if InventoryService and type(InventoryService.UpdateProfileInventory) == "function" and ply then
						pcall(function() InventoryService.UpdateProfileInventory(ply) end)
					end

					-- request profile save via PlayerProfileService if available
					if PlayerProfileService and type(PlayerProfileService.SaveNow) == "function" then
						if ply then
							pcall(function() PlayerProfileService.SaveNow(ply, reason or "GrowthMarkDirty") end)
						elseif tonumber(playerOrId) then
							pcall(function() PlayerProfileService.SaveNow(tonumber(playerOrId), reason or "GrowthMarkDirty") end)
						end
					end

					-- best-effort: notify PlayerDataService
					if PlayerDataService and type(PlayerDataService.MarkDirty) == "function" then
						if ply then
							pcall(function() PlayerDataService.MarkDirty(ply, reason or "GrowthMarkDirty") end)
						elseif tonumber(playerOrId) then
							local online = Players:GetPlayerByUserId(tonumber(playerOrId))
							if online then pcall(function() PlayerDataService.MarkDirty(online, reason or "GrowthMarkDirty") end) end
						end
					end
				end)
			end

			function orchestrator:SaveNow(playerOrId, reason, opts)
				pcall(function()
					local ply = nil
					if type(playerOrId) == "table" and playerOrId.UserId then ply = playerOrId end
					if tonumber(playerOrId) and not ply then ply = Players:GetPlayerByUserId(tonumber(playerOrId)) end

					if PlayerProfileService and type(PlayerProfileService.SaveNow) == "function" then
						if ply then
							pcall(function() PlayerProfileService.SaveNow(ply, reason or "GrowthSaveNow", opts) end)
						elseif tonumber(playerOrId) then
							pcall(function() PlayerProfileService.SaveNow(tonumber(playerOrId), reason or "GrowthSaveNow", opts) end)
						end
					end

					if InventoryService and type(InventoryService.UpdateProfileInventory) == "function" and ply then
						pcall(function() InventoryService.UpdateProfileInventory(ply) end)
					end

					if PlayerDataService and type(PlayerDataService.SaveImmediately) == "function" and ply then
						pcall(function() PlayerDataService.SaveImmediately(ply, reason or "GrowthSaveNow") end)
					end
				end)
			end

			pcall(function() SlimeCore.GrowthPersistenceService:Init(orchestrator) end)
			dprint("SlimeCore.GrowthPersistenceService initialized with orchestrator")
		else
			dprint("SlimeCore GrowthPersistenceService not available or Init missing")
		end
	end)

	task.delay(2, adoptExistingEggs)
	task.spawn(pollLoop)

	Players.PlayerRemoving:Connect(function(player)
		local uid = player.UserId
		for egg,rec in pairs(PlacedEggs) do
			if rec.OwnerUserId == uid then
				if CLEAR_EGGS_ON_LEAVE and egg.Parent then
					task.defer(function()
						if egg.Parent then
							removeSnapshotEntry(uid, egg:GetAttribute("EggId"))
							destroyEggModel(egg, "LeaveDeferred")
						end
					end)
				end
				PlacedEggs[egg] = nil
			end
		end
		PlacedCountByUid[uid] = 0
		updatePlayerAttr(uid)

		-- PATCH: Before player fully leaves, attempt to flush growth progress and request a profile save so
		-- that PersistedGrowthProgress and worldSlimes entries are written and not lost by a PreExit race.
		pcall(function()
			if SlimeCore and SlimeCore.GrowthService and type(SlimeCore.GrowthService.FlushPlayerSlimes) == "function" then
				SlimeCore.GrowthService:FlushPlayerSlimes(uid)
			end
			if SlimeCore and SlimeCore.GrowthPersistenceService and type(SlimeCore.GrowthPersistenceService.FlushPlayerSlimesAndSave) == "function" then
				pcall(function() SlimeCore.GrowthPersistenceService.FlushPlayerSlimesAndSave(uid, 6) end)
			end
		end)

		if CLEAR_EGGS_ON_LEAVE then
			task.delay(CLEAR_DEFER_SECONDS, function()
				destroyPlayerEggs(uid)
			end)
		end
	end)

	print("[EggService] "..EggService.__Version..
		" Manual="..tostring(MANUAL_HATCH_MODE)..
		" AutoHatch="..tostring(AUTO_HATCH_WHEN_READY)..
		" Cap="..BASE_PLACEMENT_CAP..
		" Snapshot="..tostring(SNAPSHOT_EXPORT_ENABLED)..
		" Purge="..tostring(RESIDUAL_PURGE_ENABLED)..
		" Debug="..tostring(DEBUG))

	return EggService
end

function EggService.GetActiveEggCount()
	local n=0
	for _ in pairs(PlacedEggs) do n+=1 end
	return n
end

function EggService.DebugListEggs()
	for egg,_ in pairs(PlacedEggs) do
		print("[EggService][Egg]", egg:GetAttribute("EggId"), egg:GetAttribute("OwnerUserId"), egg.Parent)
	end
end

function EggService.DebugListSlimes()
	for _,m in ipairs(Workspace:GetDescendants()) do
		if m:IsA("Model") and m.Name=="Slime" then
			local prim = m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart")
			print("[EggService][Slime]", m:GetAttribute("SlimeId"), prim and prim.Position)
		end
	end
end

function EggService.DedupeWorldEggsManual()
	adoptExistingEggs()
end



return EggService