-- EggService.lua
-- Version: v4.0.0-placement-cap-snapshot-purge-stable
--
-- COMPLETE UPDATED EGG SERVICE
-- Combines:
--   * Strict placement cap (counts ONLY currently placed / unhatched eggs)
--   * Safe hatching (egg model always destroyed, slot freed immediately)
--   * Optional manual hatch (remote) or automatic hatch loop
--   * Residual duplicate / orphan egg purge
--   * Optional snapshot export (for final serializer flushes)
--   * Robust dedupe by EggId (earliest wins)
--   * Adoption (after server start) without exceeding cap
--   * Clean, minimal logging (toggle DEBUG)
--   * Defensive against double hatch & re-registration races
--
-- NOTE:
--   Your client PlaceEgg remote must call:
--      PlaceEgg:FireServer(hitCFrame, tool)
--   Where hitCFrame is a CFrame of desired placement and tool is the egg Tool instance
--   (If you only pass hitCFrame, this script will attempt to auto-detect a tool held/equipped.)
--
--   Manual hatch remote (if enabled) is HatchEggRequest, passing (worldEggModel)
--
-- SAFETY CHECKLIST:
--   - On hatch: placed count decremented BEFORE heavy work
--   - HatchInProgress prevents double-execution
--   - worldEgg is moved to graveyard folder prior to destruction to avoid adopt events
--   - Residual purge (immediate + delayed passes) cleans stray copies
--   - Adoption skips models flagged Hatched/Hatching
--
-- If you need a trimmed version (no snapshots/purge), ask for "minimal".

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

local ModulesRoot         = script.Parent
local PlotManager         = require(ModulesRoot:WaitForChild("PlotManager"))
local SlimeAI             = require(ModulesRoot:WaitForChild("SlimeAI"))
local SlimeAppearance     = require(ModulesRoot:WaitForChild("SlimeAppearance"))
local ModelUtils          = require(ModulesRoot:WaitForChild("ModelUtils"))
local RNG                 = require(ModulesRoot:WaitForChild("RNG"))
local SlimeConfig         = require(ModulesRoot:WaitForChild("SlimeConfig"))
local SizeRNG             = require(ModulesRoot:WaitForChild("SizeRNG"))
local GrowthScaling       = require(ModulesRoot:WaitForChild("GrowthScaling"))
local SlimeMutation       = require(ModulesRoot:WaitForChild("SlimeMutation"))

-- PlayerDataService is optional (wrapped in pcall)
local PlayerDataService
do
	local ok, res = pcall(function()
		return require(ModulesRoot:FindFirstChild("PlayerDataService"))
	end)
	if ok then PlayerDataService = res end
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

-- Hatching mode
local MANUAL_HATCH_MODE             = true   -- If true, player triggers hatch (via HatchEggRemote)
local AUTO_HATCH_WHEN_READY         = false  -- If true AND MANUAL_HATCH_MODE==false, eggs hatch automatically

-- Hatch timings
local HATCH_TIME_RANGE              = {60,120} -- seconds (use small values like {4,6} for quick test)

-- Placement cap (simultaneous placed eggs)
local BASE_PLACEMENT_CAP            = 3      -- base max eggs placed (unhatched)
-- (Add upgrade / gamepass bonuses by editing GetEggPlacementCap if needed.)

-- Placement cooldown (seconds) - 0 disables
local PLACE_COOLDOWN                = 0

-- Polling
local HATCH_POLL_INTERVAL           = 0.5
local HATCH_GUI_UPDATE_INTERVAL     = 0.5

-- Ground placement (simplified off by default). If you need advanced ray logic, extend here.
local USE_GROUND_RAYCAST            = false

-- Tool metadata auto-fix
local AUTO_REPAIR_TOOL_METADATA     = true

-- GUI / Timer
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

-- Growth / appearance basics
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

-- Persistence in-place (anti reroll)
local EGG_HATCH_INPLACE_PERSIST     = true
local SAVE_ON_HATCH_IMMEDIATE       = true
local POST_HATCH_SAVE_FALLBACK_DELAY= 3

-- Snapshots (world eggs)
local SNAPSHOT_EXPORT_ENABLED       = true

-- Cleanup / Purge
local RESIDUAL_PURGE_ENABLED        = true
local RESIDUAL_PURGE_EXTRA_PASSES   = {0.25, 1} -- seconds after hatch
local ORPHAN_EGG_GRACE_SECONDS      = 10
local GRAVEYARD_FOLDER_NAME         = "_EggGraveyard"

-- Clear on leave (false keeps them until normal cleanup / snapshot)
local CLEAR_EGGS_ON_LEAVE           = false
local CLEAR_DEFER_SECONDS           = 0.05

-- Optional attributes
local REJECT_PREVIEW_ATTRIBUTE      = "Preview"

----------------------------------------------------------
-- STATE
----------------------------------------------------------
-- PlacedEggs: model -> rec { HatchAt, OwnerUserId, Zone, Gui, LastGuiUpdate }
local PlacedEggs       = {}
local PlacedCountByUid = {} -- userId -> count
local HatchInProgress  = {} -- eggId -> true (during hatch)
local GraveyardFolder  = nil

-- Snapshots: userId -> { { eggId=..., hatchAt=..., hatchTime=..., placedAt=..., rarity=..., valueBase=..., valuePerGrowth=... }, ... }
local EggSnapshot      = {}

-- Dedupe registry (EggId -> model reference)
local EggIdSeenWorld   = {}

----------------------------------------------------------
-- LOG HELPERS
----------------------------------------------------------
local function dprint(...)
	if DEBUG then
		print("[EggService]", ...)
	end
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
	-- Extend with upgrades / multipliers if desired:
	-- local bonus = 0
	-- return BASE_PLACEMENT_CAP + bonus
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
			plr:SetAttribute("ActiveEggs", GetPlacedCount(userId))
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

	local maxScale, luckLevels = SizeRNG.GenerateMaxSize(tier, rng)
	local sizeNorm  = maxScale / (SlimeConfig.AverageScaleBasic or 1)
	local startFraction =
		(SizeRNG.GenerateStartFraction and SizeRNG.GenerateStartFraction(tier, rng))
		or rng:NextNumber(cfg.StartScaleFractionRange[1], cfg.StartScaleFractionRange[2])

	local startScaleDesired = maxScale * startFraction
	local startScale = computeSafeStartScale(slime, startScaleDesired)

	local sFactor   = GrowthScaling.SizeDurationFactor(tier, sizeNorm)
	local baseUnfed = rng:NextNumber(cfg.UnfedGrowthDurationRange[1], cfg.UnfedGrowthDurationRange[2])
	local baseFed   = rng:NextNumber(cfg.FedGrowthDurationRange[1], cfg.FedGrowthDurationRange[2])
	local unfedDur  = baseUnfed * sFactor
	local fedDur    = baseFed   * sFactor
	local feedMult  = unfedDur / fedDur
	local initialProgress = startScale / maxScale

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

	SlimeMutation.InitSlime(slime)
	SlimeMutation.RecomputeValueFull(slime)
end

local function applyAppearance(slime, primary, rng)
	local rarity = slime:GetAttribute("Rarity") or "Common"
	local app
	local ok,err = pcall(function()
		app = SlimeAppearance.Generate(rarity, rng, slime:GetAttribute("MutationRarityBonus"))
	end)
	if not ok then warn("[EggService] SlimeAppearance.Generate failed:", err) end
	if not app then return end

	slime:SetAttribute("BodyColor",   RNG.ColorToHex(app.BodyColor))
	slime:SetAttribute("AccentColor", RNG.ColorToHex(app.AccentColor))
	slime:SetAttribute("EyeColor",    RNG.ColorToHex(app.EyeColor))

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
-- DESTROY / PURGE HELPERS
----------------------------------------------------------
local function destroyEggModel(model, reason)
	if not model then return end
	if model:GetAttribute("EggDestroyed") then return end
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
					destroyEggModel(desc, "Residual-".. (phase or "immediate"))
					removed += 1
				end
			end
		end
	end

	-- Player plot first
	for _,plr in ipairs(Players:GetPlayers()) do
		if plr.UserId == ownerUserId then
			local okPlot, plot = pcall(function() return PlotManager:GetPlayerPlot(plr) end)
			if okPlot and plot then scan(plot) end
			break
		end
	end
	-- Workspace fallback
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

	-- Remove from placement first
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

	-- Detach to graveyard
	ensureGraveyard()
	worldEgg.Parent = GraveyardFolder

	-- In-place persistence
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

	-- Capture pivot before destroy
	local eggPivotCF
	pcall(function() eggPivotCF = worldEgg:GetPivot() end)

	-- Build slime
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

	local rng = RNG.New()
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

	-- Determine zone (for AI)
	local zone = rec and rec.Zone
	if not zone and ownerPlayer then
		local okPlot, playerPlot = pcall(function() return PlotManager:GetPlayerPlot(ownerPlayer) end)
		if okPlot and playerPlot then
			zone = PlotManager:GetSlimeZone(playerPlot)
		end
	end

	-- Parenting
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

	-- Position
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

	-- Destroy egg model
	destroyEggModel(worldEgg, "HatchComplete")

	-- Persistence Save
	if PlayerDataService and ownerPlayer then
		if not markEggPersistSucceeded then
			if SAVE_ON_HATCH_IMMEDIATE and PlayerDataService.SaveImmediately then
				local okSave, err = pcall(function()
					PlayerDataService.SaveImmediately(ownerPlayer, "EggHatched")
				end)
				if not okSave then
					warn("[EggService] Immediate save failed:", err)
					PlayerDataService.MarkDirty(ownerPlayer, "EggHatched")
				end
			else
				PlayerDataService.MarkDirty(ownerPlayer, "EggHatched")
				task.delay(POST_HATCH_SAVE_FALLBACK_DELAY, function()
					if slime.Parent then
						PlayerDataService.MarkDirty(ownerPlayer, "EggHatchedDeferred")
					end
				end)
			end
		else
			PlayerDataService.MarkDirty(ownerPlayer, "SlimeFromEgg")
		end
	end

	task.defer(function()
		if slime.Parent then
			pcall(function()
				SlimeAI.Start(slime, zone)
			end)
		end
	end)

	if HATCH_DEBUG_VERBOSE then
		print(("[EggService][SpawnPosition] id=%s pos=%s")
			:format(slime:GetAttribute("SlimeId"),
				tostring(slime.PrimaryPart and slime.PrimaryPart.Position)))
	end
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
-- OFFLINE ADJUST (optional minimal fix)
----------------------------------------------------------
local function adjustOfflineEgg(egg)
	-- Optional time correction (kept simple)
	local placedAt = egg:GetAttribute("PlacedAt")
	local hatchTime= egg:GetAttribute("HatchTime")
	if not (placedAt and hatchTime) then return end
	local expected = placedAt + hatchTime
	local now = os.time()
	if expected <= now and (egg:GetAttribute("HatchAt") or expected) > now then
		egg:SetAttribute("HatchAt", now)
	end
end

----------------------------------------------------------
-- REGISTER / DEDUPE / ADOPT
----------------------------------------------------------
local function registerEggModel(worldEgg)
	if PlacedEggs[worldEgg] then return end
	if not worldEgg or not worldEgg.Parent then return end
	if worldEgg:GetAttribute("Hatching") or worldEgg:GetAttribute("Hatched") then return end

	-- Guarantee EggId
	local eggId = worldEgg:GetAttribute("EggId")
	if not eggId then
		eggId = HttpService:GenerateGUID(false)
		worldEgg:SetAttribute("EggId", eggId)
		if DEBUG then dprint("Assigned missing EggId="..eggId) end
	end

	-- Dedupe: keep earliest
	local prior = EggIdSeenWorld[eggId]
	if prior and prior ~= worldEgg and prior.Parent then
		local pa = prior:GetAttribute("PlacedAt") or math.huge
		local pb = worldEgg:GetAttribute("PlacedAt") or math.huge
		if pb >= pa then
			-- Destroy later copy
			destroyEggModel(worldEgg, "DedupeLater")
			return
		else
			destroyEggModel(prior, "DedupeLaterOlderReplaced")
		end
	end
	EggIdSeenWorld[eggId] = worldEgg

	local owner = worldEgg:GetAttribute("OwnerUserId")
	local hatchAt= worldEgg:GetAttribute("HatchAt")
	if not (owner and hatchAt) then return end

	adjustOfflineEgg(worldEgg)

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
					-- Over cap or no owner; destroy stray
					destroyEggModel(desc, "AdoptOverCapOrNoOwner")
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

	-- Basic cooldown
	local last = player:GetAttribute("LastEggPlace") or 0
	if PLACE_COOLDOWN > 0 and os.clock() - last < PLACE_COOLDOWN then
		return dfail("Cooldown")
	end

	-- Validate tool
	if tool and tool:IsA("Tool") then
		ensureToolMetadata(tool, player)
		if tool:GetAttribute("OwnerUserId") ~= player.UserId then return dfail("OwnerMismatch") end
		if not tool:GetAttribute("ServerIssued") then return dfail("NotServerIssued") end
		if tool:GetAttribute(REJECT_PREVIEW_ATTRIBUTE) then return dfail("PreviewTool") end
	else
		-- Auto-detect tool if not provided
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
	worldEgg.Parent = Workspace

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

	if tool.Parent then
		tool:Destroy()
	end

	dprint(("Placed egg eggId=%s hatchIn=%ds placed=%d/%d")
		:format(eggId, hatchTime, GetPlacedCount(player.UserId), GetEggPlacementCap(player)))
end

-- Remote handler wrapper (accepts (hitCFrame) or (hitCFrame, tool))
local function onPlaceEggRemote(player, a, b)
	if typeof(a) == "CFrame" then
		placeEgg(player, a, b)
	else
		dfail("BadRemoteArgs")
	end
end

----------------------------------------------------------
-- MANUAL HATCH REMOTE
----------------------------------------------------------
local function onManualHatch(player, worldEgg)
	if not MANUAL_HATCH_MODE then return end
	if not (worldEgg and worldEgg:IsA("Model") and PlacedEggs[worldEgg]) then return end
	local rec = PlacedEggs[worldEgg]
	if rec.OwnerUserId ~= player.UserId then return end
	if rec.HatchAt > os.time() then
		return -- Not ready
	end
	hatchEgg(worldEgg)
end

----------------------------------------------------------
-- POLL LOOP
----------------------------------------------------------
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
					-- Update timer label (build if missing)
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

		-- Orphan purge
		if RESIDUAL_PURGE_ENABLED then
			for _,plr in ipairs(Players:GetPlayers()) do
				local okPlot, plot = pcall(function() return PlotManager:GetPlayerPlot(plr) end)
				if okPlot and plot then
					for _,desc in ipairs(plot:GetDescendants()) do
						if desc:IsA("Model") and desc.Name=="Egg" and not PlacedEggs[desc] then
							local hat = desc:GetAttribute("HatchAt")
							if desc:GetAttribute("Hatching") or desc:GetAttribute("Hatched") then
								destroyEggModel(desc, "OrphanTransitional")
							elseif hat and type(hat)=="number" and (now - hat) > ORPHAN_EGG_GRACE_SECONDS then
								destroyEggModel(desc, "OrphanExpired")
							end
						end
					end
				end
			end
		end

		task.wait(HATCH_POLL_INTERVAL)
	end
end

----------------------------------------------------------
-- LEAVE CLEANUP
----------------------------------------------------------
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

----------------------------------------------------------
-- INIT
----------------------------------------------------------
function EggService.Init()
	if _initialized then
		dprint("Init() ignored (already initialized). Version=".. EggService.__Version)
		return EggService
	end
	_initialized = true

	-- Remote wiring
	PlaceEggEvent.OnServerEvent:Connect(onPlaceEggRemote)
	if MANUAL_HATCH_MODE and HatchEggRemote then
		HatchEggRemote.OnServerEvent:Connect(onManualHatch)
	end

	-- Adoption (delay for plot setup)
	task.delay(2, adoptExistingEggs)

	-- Poll loop
	task.spawn(pollLoop)

	-- Player removing
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

----------------------------------------------------------
-- DEBUG UTILITIES
----------------------------------------------------------
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