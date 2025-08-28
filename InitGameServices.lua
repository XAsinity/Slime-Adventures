-- InitGameServices.server.lua (MODULAR ORCHESTRATOR EDITION, UPDATED FOR GRAND SERIALIZER)
-- Unified bootstrap for ALL server-side systems with new persistence architecture (v2025-08 update).
--
-- Order of initialization:
--   1. Core Remotes + PersistInventoryRestored BindableEvent
--   2. PlayerDataService (compat shim -> PlayerProfileOrchestrator + modules)
--   3. PlotManager (plots / origin references)
--   4. Feature / Domain Modules (Capture, Faction Totals, Slime Buyer, Food, Hunger, Growth,
--      GrowthPersistenceService, Egg, EggHatchService, WorldAssetCleanup, Shop)
--   5. Faction logging snapshot
--   6. Shutdown flush (faction totals + cleanup)
--   7. Ready signal (GameServicesReady BindableEvent)
--   8. Periodic persistence summaries
--
-- Notes:
--   * PlayerDataService wraps orchestrator; legacy module calls still work (Get, SetCoins, etc).
--   * Orchestrator now fires PersistInventoryRestored after restore automatically.
--   * WorldSlime / WorldEgg restore & guard logic implemented inside serializers and InventoryService.
----------------------------------------------------------------

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players             = game:GetService("Players")

local function log(...)  print("[InitGameServices]", ...) end
local function warnf(...) warn("[InitGameServices]", ...) end

----------------------------------------------------------------
-- Configuration (adjust as needed)
----------------------------------------------------------------
local CONFIG = {
	LogPlayerStandings      = true,
	LogFactionTotalsSnapshot= true,
	PersistenceSummaryInterval = 120,
	Factions                = { "Pacifist", "Orion" },
	RegisterFactions        = {
		Pacifist = 0.50,
		Orion    = 0.15,
	},
}

----------------------------------------------------------------
-- 1. Remotes + Events
----------------------------------------------------------------
local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if not remotesFolder then
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = "Remotes"
	remotesFolder.Parent = ReplicatedStorage
	log("Created Remotes folder.")
end

local function ensureRemote(name, className)
	className = className or "RemoteEvent"
	local r = remotesFolder:FindFirstChild(name)
	if not r then
		r = Instance.new(className)
		r.Name = name
		r.Parent = remotesFolder
		log("Created remote: "..name)
	end
	return r
end

-- Gameplay / systems
ensureRemote("PlaceEgg")
ensureRemote("HatchEggRequest")
ensureRemote("SlimePickupRequest")
ensureRemote("SlimePickupResult")
ensureRemote("FeedSlime")

-- Shop / inventory
ensureRemote("PurchaseEgg")
ensureRemote("PurchaseResult")
ensureRemote("RequestInventory")
ensureRemote("InventoryUpdate")

-- Music / misc
ensureRemote("UpdateMusicVolume")

-- Post-inventory restore BindableEvent (fired by orchestrator after restore)
local invRestoredEvent = ReplicatedStorage:FindFirstChild("PersistInventoryRestored")
if not invRestoredEvent then
	invRestoredEvent = Instance.new("BindableEvent")
	invRestoredEvent.Name = "PersistInventoryRestored"
	invRestoredEvent.Parent = ReplicatedStorage
	log("Created BindableEvent: PersistInventoryRestored")
end

----------------------------------------------------------------
-- 2. PlayerProfileService (Unified Data Owner) + GRAND SERIALIZER REGISTRATION
----------------------------------------------------------------
local Modules = ServerScriptService:WaitForChild("Modules")

local function safeRequire(name, required)
	local ok, result = pcall(function()
		local m = Modules:FindFirstChild(name)
		if not m then error("Module "..name.." not found") end
		return require(m)
	end)
	if ok then
		log("Loaded module: "..name)
		return result
	else
		warnf("Failed to load "..name..": "..tostring(result))
		if required then
			warnf("Required module '"..name.."' missing; aborting initialization.")
			error("Critical module missing: "..name)
		end
		return nil
	end
end

local PlayerProfileService = safeRequire("PlayerProfileService", true)
local GrandInventorySerializer = safeRequire("GrandInventorySerializer", true)
local InventoryService = safeRequire("InventoryService", true)

-- Ensure PlotManager is initialized before InventoryService so restores find plots.
local PlotManager = safeRequire("PlotManager")
local plotInitOk = false
if PlotManager and PlotManager.Init then
	local ok, err = pcall(function() PlotManager:Init() end)
	if ok then
		plotInitOk = true
		log("PlotManager initialized early for persistence ordering.")
	else
		warnf("PlotManager Init error: "..tostring(err))
	end
end

-- Register GrandInventorySerializer AFTER plot manager init and BEFORE InventoryService.Init
if InventoryService and GrandInventorySerializer then
	InventoryService.RegisterSerializer(GrandInventorySerializer)
	-- Defer InventoryService.Init until core feature modules (and PreExitInventorySync)
	-- are loaded so restore runs with the full environment available.
	log("Registered GrandInventorySerializer (InventoryService.Init deferred).")
else
	warnf("InventoryService or GrandInventorySerializer missing at init.")
end

-- Ensure PreExitInventorySync is required and initialized EARLY so it can install
-- its PlayerRemoving/PreExit capture hook before any final serialize happens.
local PreExitInventorySync = safeRequire("PreExitInventorySync")
if PreExitInventorySync then
	if type(PreExitInventorySync.Init) == "function" then
		local ok, err = pcall(PreExitInventorySync.Init)
		if ok then
			log("PreExitInventorySync.Init() run early (pre-inventory).")
		else
			warnf("PreExitInventorySync.Init error (early): "..tostring(err))
		end
	else
		log("PreExitInventorySync required (no Init()); module loaded early.")
	end
else
	log("PreExitInventorySync not present; proceeding without early pre-exit hook.")
end

-- Register factions before Init (so profile blank creation seeds correct standings)
for faction, initStanding in pairs(CONFIG.RegisterFactions) do
	-- If you have faction logic, add it here or in PlayerProfileService
end

-- No need to call PlayerDataService.Init() or PlayerProfileOrchestrator.Init()

----------------------------------------------------------------
-- 3. PlotManager + assignment
----------------------------------------------------------------
local function assignPlayerPlot(player)
	if not plotInitOk or not PlotManager or not PlotManager.AssignPlayer then return end
	local plot = PlotManager:AssignPlayer(player)
	if not plot then
		warnf("No plot available for "..player.Name)
	else
		player:SetAttribute("HasPlot", true)
	end
end

local function releasePlayerPlot(player)
	if plotInitOk and PlotManager and PlotManager.ReleasePlayer then
		pcall(function() PlotManager:ReleasePlayer(player) end)
	end
end

local function onCharacterAdded(player, character)
	if plotInitOk and PlotManager and PlotManager.OnCharacterAdded then
		pcall(function() PlotManager:OnCharacterAdded(player, character) end)
	end
end

Players.PlayerAdded:Connect(function(player)
	assignPlayerPlot(player)
	player.CharacterAdded:Connect(function(char) onCharacterAdded(player, char) end)
end)
Players.PlayerRemoving:Connect(releasePlayerPlot)
for _,p in ipairs(Players:GetPlayers()) do
	assignPlayerPlot(p)
	p.CharacterAdded:Connect(function(char) onCharacterAdded(p, char) end)
end

----------------------------------------------------------------
-- 4. Feature / Domain Modules
----------------------------------------------------------------
-- (All loaded via safeRequire; only critical ones MUST succeed earlier.)
local SlimeCaptureService      = safeRequire("SlimeCaptureService")
local FactionTotalsService     = safeRequire("FactionTotalsService")
local FactionSlimeBuyerService = safeRequire("FactionSlimeBuyerService")
local FoodService              = safeRequire("FoodService")
local SlimeHungerService       = safeRequire("SlimeHungerService")
local GrowthService            = safeRequire("GrowthService")
local GrowthPersistenceService = safeRequire("GrowthPersistenceService")
local EggService               = safeRequire("EggService")
local EggHatchService          = safeRequire("EggHatchService")
local WorldAssetCleanup        = safeRequire("WorldAssetCleanup")
local ShopService              = safeRequire("ShopService")
local CoreStatsService         = safeRequire("CoreStatsService")
if PreExitInventorySync then
	log("PreExitInventorySync loaded to capture final inventory on leave (prevents accidental wipe).")
end
-- PreExitInventorySync removed intentionally; final saves handled via GrandInventorySerializer PlayerRemoving hook below.

if GrowthPersistenceService and GrowthPersistenceService.Init then
	local ok, err = pcall(GrowthPersistenceService.Init)
	if ok then
		log("GrowthPersistenceService initialized.")
	else
		warnf("GrowthPersistenceService.Init error: "..tostring(err))
	end
end

if EggService and EggService.Init then
	local ok, err = pcall(EggService.Init)
	if ok then
		log("EggService initialized via module Init().")
	else
		warnf("EggService.Init error: "..tostring(err))
	end
end

if WorldAssetCleanup and WorldAssetCleanup.Init then
	local ok, err = pcall(WorldAssetCleanup.Init)
	if ok then
		log("WorldAssetCleanup initialized.")
	else
		warnf("WorldAssetCleanup.Init error: "..tostring(err))
	end
end

if ShopService and ShopService.Init then
	local ok, err = pcall(ShopService.Init)
	if ok then
		log("ShopService initialized as module.")
	else
		warnf("ShopService.Init error: "..tostring(err))
	end
end

----------------------------------------------------------------
-- 4b. Ensure deterministic final-save on player leave
----------------------------------------------------------------
-- If GrandInventorySerializer provides PreExitSync, prefer that. Otherwise use Serialize(..., true).
if GrandInventorySerializer then
	Players.PlayerRemoving:Connect(function(player)
		pcall(function()
			log("Pre-exit persistence triggered for", player.Name)
			if type(GrandInventorySerializer.PreExitSync) == "function" then
				GrandInventorySerializer:PreExitSync(player)
			else
				GrandInventorySerializer:Serialize(player, true)
			end
		end)
	end)
end

----------------------------------------------------------------
-- 5. Faction Logging (deferred)
----------------------------------------------------------------
if CONFIG.LogPlayerStandings or CONFIG.LogFactionTotalsSnapshot then
	Players.PlayerAdded:Connect(function(player)
		task.defer(function()
			if FactionSlimeBuyerService and CONFIG.LogPlayerStandings then
				for _,f in ipairs(CONFIG.Factions) do
					local ok, standing = pcall(function()
						return FactionSlimeBuyerService.GetStanding(player, f)
					end)
					if ok then
						print(string.format("[Standing] %s %s=%.3f", player.Name, f, standing))
					end
				end
			end
			if FactionTotalsService and CONFIG.LogFactionTotalsSnapshot and FactionTotalsService.GetAllTotals then
				local ok, totals = pcall(function() return FactionTotalsService.GetAllTotals() end)
				if ok and totals then
					local pac = totals.Pacifist or 0
					local ori = totals.Orion or 0
					print(string.format("[FactionTotals Snapshot] Pacifist=%d Orion=%d", pac, ori))
				end
			end
		end)
	end)
end

----------------------------------------------------------------
-- 6. Shutdown flush
----------------------------------------------------------------
game:BindToClose(function()
	if FactionTotalsService and FactionTotalsService.Flush then
		print("[InitGameServices] Flushing faction totals on shutdown...")
		pcall(function() FactionTotalsService.Flush(true) end)
	end
	-- WorldAssetCleanup already handles destruction on BindToClose internally if enabled.
end)

----------------------------------------------------------------
-- 7. Ready Signal
----------------------------------------------------------------
local readyEvent = Instance.new("BindableEvent")
readyEvent.Name = "GameServicesReady"
readyEvent.Parent = ReplicatedStorage
readyEvent:Fire()
log("Game services ready signal fired.")

----------------------------------------------------------------
-- 8. Periodic Persistence Summary
----------------------------------------------------------------
task.spawn(function()
	local interval = CONFIG.PersistenceSummaryInterval
	while true do
		task.wait(interval)
		local list = Players:GetPlayers()
		if #list == 0 then continue end
		if PlayerProfileService and PlayerProfileService.Get then
			for _,plr in ipairs(list) do
				local prof = PlayerProfileService.Get(plr)
				if prof then
					print(string.format(
						"[PersistSummary] %s coins=%d captured=%d worldSlimes=%d worldEggs=%d eggTools=%d foodTools=%d dv=%d",
						plr.Name,
						prof.coins or 0,
						#(prof.inventory.capturedSlimes or {}),
						#(prof.inventory.worldSlimes or {}),
						#(prof.inventory.worldEggs or {}),
						#(prof.inventory.eggTools or {}),
						#(prof.inventory.foodTools or {}),
						prof.dataVersion or -1
						))
				end
			end
		end
	end
end)

-- AFTER loading feature/domain modules, initialize InventoryService now that environment is ready.
if InventoryService and InventoryService.Init then
	local ok, err = pcall(function() InventoryService.Init() end)
	if ok then
		log("InventoryService initialized (deferred init).")
	else
		warnf("InventoryService.Init error (deferred): "..tostring(err))
	end
end

log("Initialization sequence complete.")