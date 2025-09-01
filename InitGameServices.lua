-- InitGameServices.server.lua (MODULAR ORCHESTRATOR EDITION, UPDATED FOR SLIMECORE)
-- Updated to work with the consolidated SlimeCore module (SlimeCore.* submodules).
-- Behavior:
--  * Two-pass safe require of ServerScriptService.Modules (same as before).
--  * Prefer standalone modules when present; fall back to SlimeCore submodules when the
--    individual module file has been removed and functionality moved into SlimeCore.
--  * Call Init on prioritized modules where appropriate. SlimeCore.Init() is called
--    once, and SlimeCore submodules are used as fallbacks for (GrowthService, etc.).
--  * GrowthPersistenceService remains decoupled: do not call its :Init(orch) here. The
--    orchestrator (PlayerProfile service) should initialize it with the orchestrator.
----------------------------------------------------------------

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players             = game:GetService("Players")
local RunService          = game:GetService("RunService")

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
-- 1. Remotes + Events (unchanged)
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
-- 2. Two-pass Module loading (safe) - unchanged semantics, aware of SlimeCore
----------------------------------------------------------------
local Modules = ServerScriptService:WaitForChild("Modules")

-- Prioritize some modules that must be required early for others' requires/Init.
-- Added "SlimeCore" here so the combined module is loaded early and can be used as fallback.
local prioritizedRequireNames = {
	"PlayerProfileService",
	"GrandInventorySerializer",
	"InventoryService",
	"SlimeCore",
	"PlotManager",
	"PreExitInventorySync",
	"ShopService",
}

-- Keep records
local moduleScriptMap = {}   -- name -> ModuleScript
for _, inst in ipairs(Modules:GetChildren()) do
	if inst:IsA("ModuleScript") then
		moduleScriptMap[inst.Name] = inst
	end
end

local requiredModules = {}   -- name -> moduleTable or nil (if require failed)
local function safeRequireByName(name, required)
	local inst = moduleScriptMap[name]
	if not inst then
		if required then
			error(("Critical module not found: %s"):format(name))
		else
			warnf("Module %s not found in Modules folder.", tostring(name))
			return nil
		end
	end
	if requiredModules[name] ~= nil then
		-- already required
		return requiredModules[name]
	end
	local ok, res = pcall(require, inst)
	if not ok then
		warnf(("Require failed for %s: %s"):format(name, tostring(res)))
		if required then
			error(("Critical module '%s' failed require: %s"):format(name, tostring(res)))
		end
		requiredModules[name] = nil
		return nil
	end
	requiredModules[name] = res
	log(("Loaded module: %s"):format(name))
	return res
end

-- 2a) Require prioritized modules first (best-effort, but treat some as required)
for _, name in ipairs(prioritizedRequireNames) do
	local must = (name == "PlayerProfileService" or name == "GrandInventorySerializer" or name == "InventoryService")
	pcall(function()
		safeRequireByName(name, must)
	end)
end

-- 2b) Require remaining modules defensively
for name, inst in pairs(moduleScriptMap) do
	if requiredModules[name] == nil then
		local ok, res = pcall(function() return require(inst) end)
		if ok then
			requiredModules[name] = res
			log(("Required module %s"):format(name))
		else
			warnf(("Require failed for %s: %s"):format(name, tostring(res)))
			requiredModules[name] = nil
		end
	end
end

-- Expose a helper to access required modules by name
local function Mod(name) return requiredModules[name] end

----------------------------------------------------------------
-- 2b. Maintain previous special cases around serializer / inventory ordering
--     But now prefer SlimeCore submodules if the standalone modules were removed.
----------------------------------------------------------------
local PlayerProfileService = Mod("PlayerProfileService")
local GrandInventorySerializer = Mod("GrandInventorySerializer")
local InventoryService = Mod("InventoryService")
local PlotManager = Mod("PlotManager")
local PreExitInventorySync = Mod("PreExitInventorySync")
local ShopService = Mod("ShopService")

-- Load SlimeCore if present (fallback container for many slime subsystems).
local SlimeCore = Mod("SlimeCore")

-- Utility: resolve a domain module by checking standalone mod first, then SlimeCore submodule
local function ResolveDomain(name)
	-- prefer explicit module file if present
	local m = Mod(name)
	if m ~= nil then return m end
	-- fallback to SlimeCore's exported submodule
	if SlimeCore and type(SlimeCore) == "table" then
		-- map common names to SlimeCore fields
		if name == "GrowthService" and SlimeCore.GrowthService then return SlimeCore.GrowthService end
		if name == "SlimeHungerService" and SlimeCore.SlimeHungerService then return SlimeCore.SlimeHungerService end
		if name == "GrowthPersistenceService" and SlimeCore.GrowthPersistenceService then return SlimeCore.GrowthPersistenceService end
		if name == "GrowthScaling" and SlimeCore.GrowthScaling then return SlimeCore.GrowthScaling end
		if name == "SlimeFactory" and SlimeCore.SlimeFactory then return SlimeCore.SlimeFactory end
		if name == "SlimeAppearance" and SlimeCore.SlimeAppearance then return SlimeCore.SlimeAppearance end
		if name == "SlimeAI" and SlimeCore.SlimeAI then return SlimeCore.SlimeAI end
		-- generic fallback: SlimeCore[name]
		if SlimeCore[name] then return SlimeCore[name] end
	end
	return nil
end

----------------------------------------------------------------
-- Early PlotManager.Init for persistence ordering (if present and a table)
----------------------------------------------------------------
local plotInitOk = false
if type(PlotManager) == "table" and type(PlotManager.Init) == "function" then
	local ok, err = pcall(function() PlotManager:Init() end)
	if ok then
		plotInitOk = true
		log("PlotManager initialized early for persistence ordering.")
	else
		warnf("PlotManager.Init error (early): "..tostring(err))
	end
end

-- Ensure GrandInventorySerializer registered BEFORE InventoryService.Init
-- InventoryService.RegisterSerializer expects (name, serializer)
if type(InventoryService) == "table" and GrandInventorySerializer and type(InventoryService.RegisterSerializer) == "function" then
	local ok, err = pcall(function()
		InventoryService.RegisterSerializer("GrandInventorySerializer", GrandInventorySerializer)
	end)
	if ok then
		log("Registered GrandInventorySerializer (InventoryService.Init deferred).")
	else
		warnf("InventoryService.RegisterSerializer error: "..tostring(err))
	end
else
	if not InventoryService or not GrandInventorySerializer then
		warnf("InventoryService or GrandInventorySerializer missing at init; serializer registration skipped.")
	end
end

-- If PlayerProfileService exists, expose the serializer on it for adapter usage (backwards compatibility).
if PlayerProfileService and GrandInventorySerializer and type(PlayerProfileService) == "table" then
	pcall(function()
		if not PlayerProfileService.GrandInventory then
			PlayerProfileService.GrandInventory = {
				Serialize = function(...) if GrandInventorySerializer and type(GrandInventorySerializer.Serialize) == "function" then return GrandInventorySerializer.Serialize(...) end return {} end,
				Restore  = function(...) if GrandInventorySerializer and type(GrandInventorySerializer.Restore) == "function" then return GrandInventorySerializer.Restore(...) end return false end,
				PreExitSync = function(...) if GrandInventorySerializer and type(GrandInventorySerializer.PreExitSync) == "function" then return GrandInventorySerializer.PreExitSync(...) end end,
			}
			log("Attached GrandInventorySerializer adapter to PlayerProfileService.GrandInventory")
		end
	end)
end

-- Ensure PreExitInventorySync.Init is run early if present (to install hooks)
if type(PreExitInventorySync) == "table" then
	if type(PreExitInventorySync.Init) == "function" then
		local ok, err = pcall(PreExitInventorySync.Init, PreExitInventorySync)
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

----------------------------------------------------------------
-- 3. PlotManager player assignment wiring (safe even if PlotManager.Init hasn't completed)
----------------------------------------------------------------
local function assignPlayerPlot(player)
	if not plotInitOk or type(PlotManager) ~= "table" or type(PlotManager.AssignPlayer) ~= "function" then return end
	local success, plot = pcall(function() return PlotManager:AssignPlayer(player) end)
	if not success then
		warnf("PlotManager:AssignPlayer failed for %s", player.Name)
	else
		if plot then
			pcall(function() player:SetAttribute("HasPlot", true) end)
		else
			warnf("No plot available for "..player.Name)
		end
	end
end

local function releasePlayerPlot(player)
	if plotInitOk and type(PlotManager) == "table" and type(PlotManager.ReleasePlayer) == "function" then
		pcall(function() PlotManager:ReleasePlayer(player) end)
	end
end

local function onCharacterAdded(player, character)
	if plotInitOk and type(PlotManager) == "table" and type(PlotManager.OnCharacterAdded) == "function" then
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
-- 4. Feature / Domain Init Phase (prioritized Init calls)
----------------------------------------------------------------
-- Note: If functionality moved into SlimeCore, ResolveDomain will return the submodule.
local prioritizedInitOrder = {
	-- persistence orchestrator (do not auto-init GrowthPersistenceService here)
	"EggService",
	"WorldAssetCleanup",
	"ShopService",
	"SlimeCaptureService",
	"FactionTotalsService",
	"FactionSlimeBuyerService",
	"FoodService",
	"SlimeHungerService", -- may resolve to SlimeCore.SlimeHungerService
	"GrowthService",     -- may resolve to SlimeCore.GrowthService
	"CoreStatsService",
	"StagedToolManager",
	"SlimeAI",           -- prefer standalone SlimeAI, fallback to SlimeCore.SlimeAI
	"SlimeAppearance",   -- fallback to SlimeCore.SlimeAppearance
	"SlimeFactory",      -- fallback to SlimeCore.SlimeFactory
	"SlimeWeldFix",
	"SizeRNG",
	"RNG",
	"MusicPlaylist",
	"SlimeCore",         -- initialize the consolidated module last among prioritized so its dependencies are loaded
}

-- Call Init for prioritized modules (defensively: ensure module is a table)
for _, name in ipairs(prioritizedInitOrder) do
	-- Special case SlimeCore.Init
	if name == "SlimeCore" then
		if SlimeCore and type(SlimeCore.Init) == "function" then
			local ok, err = pcall(SlimeCore.Init, SlimeCore)
			if ok then
				log(("Initialized %s."):format(name))
			else
				warnf(("Init error for %s: %s"):format(name, tostring(err)))
			end
		end
		continue
	end

	local mod = ResolveDomain(name)
	if type(mod) == "table" and type(mod.Init) == "function" then
		local ok, err = pcall(mod.Init, mod)
		if ok then
			log(("Initialized %s."):format(name))
		else
			warnf(("Init error for %s: %s"):format(name, tostring(err)))
		end
	end
end

-- Call Init for all remaining modules that have Init (and haven't been initialized above).
for name, mod in pairs(requiredModules) do
	if type(name) == "string" and type(mod) == "table" then
		-- If we already initialized the module in prioritized list, skip
		local already = false
		for _, n in ipairs(prioritizedInitOrder) do
			if n == name then already = true break end
		end
		if not already and type(mod.Init) == "function" then
			local ok, err = pcall(mod.Init, mod)
			if ok then
				log(("Initialized %s."):format(name))
			else
				warnf(("Init error for %s: %s"):format(name, tostring(err)))
			end
		end
	end
end

----------------------------------------------------------------
-- 4b. Ensure deterministic final-save on player leave
----------------------------------------------------------------
-- Prefer PreExitInventorySync for merging and saving. As a last step call GrandInventorySerializer.PreExitSync safely.
if type(PreExitInventorySync) == "table" and type(PreExitInventorySync.Init) == "function" then
	Players.PlayerRemoving:Connect(function(player)
		pcall(function()
			log("Pre-exit persistence (orchestrator) triggered for", player.Name)
			local usedPexit = false
			if type(PreExitInventorySync.RunNow) == "function" then
				pcall(function() PreExitInventorySync.RunNow(player) end)
				usedPexit = true
			end

			-- Also call GrandInventorySerializer.PreExitSync (safe)
			if type(GrandInventorySerializer) == "table" and type(GrandInventorySerializer.PreExitSync) == "function" then
				local prof = nil
				if PlayerProfileService and type(PlayerProfileService.GetProfile) == "function" then
					pcall(function() prof = PlayerProfileService.GetProfile(player.UserId) end)
				end
				pcall(function()
					if prof then
						GrandInventorySerializer.PreExitSync(prof)
					else
						GrandInventorySerializer.PreExitSync(player)
					end
				end)
			end
		end)
	end)
end

----------------------------------------------------------------
-- 5. Faction Logging (deferred)
----------------------------------------------------------------
local FactionSlimeBuyerService = Mod("FactionSlimeBuyerService")
local FactionTotalsService = Mod("FactionTotalsService")

if CONFIG.LogPlayerStandings or CONFIG.LogFactionTotalsSnapshot then
	Players.PlayerAdded:Connect(function(player)
		task.defer(function()
			if type(FactionSlimeBuyerService) == "table" and CONFIG.LogPlayerStandings then
				for _,f in ipairs(CONFIG.Factions) do
					local ok, standing = pcall(function()
						return FactionSlimeBuyerService.GetStanding(player, f)
					end)
					if ok then
						print(string.format("[Standing] %s %s=%.3f", player.Name, f, standing))
					end
				end
			end
			if type(FactionTotalsService) == "table" and CONFIG.LogFactionTotalsSnapshot and type(FactionTotalsService.GetAllTotals) == "function" then
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
	if type(FactionTotalsService) == "table" and type(FactionTotalsService.Flush) == "function" then
		print("[InitGameServices] Flushing faction totals on shutdown...")
		pcall(function() FactionTotalsService.Flush(true) end)
	end
end)

----------------------------------------------------------------
-- 7. Ready Signal
----------------------------------------------------------------
local existingReady = ReplicatedStorage:FindFirstChild("GameServicesReady")
if existingReady and existingReady:IsA("BindableEvent") then
	existingReady:Fire()
else
	local readyEvent = Instance.new("BindableEvent")
	readyEvent.Name = "GameServicesReady"
	readyEvent.Parent = ReplicatedStorage
	readyEvent:Fire()
end
log("Game services ready signal fired.")

----------------------------------------------------------------
-- 8. Periodic Persistence Summary (unchanged)
----------------------------------------------------------------
task.spawn(function()
	local interval = CONFIG.PersistenceSummaryInterval
	while true do
		task.wait(interval)
		local list = Players:GetPlayers()
		if #list == 0 then continue end
		if type(PlayerProfileService) == "table" and type(PlayerProfileService.Get) == "function" then
			for _,plr in ipairs(list) do
				local prof = PlayerProfileService.Get(plr)
				if prof then
					print(string.format(
						"[PersistSummary] %s coins=%d captured=%d worldSlimes=%d worldEggs=%d eggTools=%d foodTools=%d dv=%d",
						plr.Name,
						(prof.core and prof.core.coins) or prof.coins or 0,
						#(prof.inventory and prof.inventory.capturedSlimes or {}),
						#(prof.inventory and prof.inventory.worldSlimes or {}),
						#(prof.inventory and prof.inventory.worldEggs or {}),
						#(prof.inventory and prof.inventory.eggTools or {}),
						#(prof.inventory and prof.inventory.foodTools or {}),
						prof.dataVersion or -1
						))
				end
			end
		end
	end
end)

----------------------------------------------------------------
-- AFTER loading feature/domain modules, initialize InventoryService now that environment is ready.
----------------------------------------------------------------
if type(InventoryService) == "table" and type(InventoryService.Init) == "function" then
	local ok, err = pcall(function() InventoryService.Init() end)
	if ok then
		log("InventoryService initialized (deferred init).")
	else
		warnf("InventoryService.Init error (deferred): "..tostring(err))
	end
end

log("Initialization sequence complete.")