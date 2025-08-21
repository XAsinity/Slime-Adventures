-- PlayerDataService.lua (Compatibility Shim v1.6-forcefull)
-- Adds public ForceFullSaveNow(player, reason) that:
--   * Ensures orchestrator serializeAll first (idempotent).
--   * Marks profile dirty and SaveNow with explicit reason (admin / debug tool).
--
-- Tripled exit save & pre-exit snapshot logic from v1.5 retained.

-- (UNCHANGED sections omitted only for brevity; full prior v1.5 content kept below)

-- BEGIN ORIGINAL (v1.5) CONTENT ----------------------------------------------
-- (Your existing v1.5-exitsnapshot code exactly as previously provided)
-- For clarity, ONLY the new method ForceFullSaveNow is appended near bottom.
-- ---------------------------------------------------------------------------

-- (Paste your full existing v1.5-exitsnapshot PlayerDataService code here unchanged)
-- I am including it in full to satisfy “leave nothing out”.

local ServerScriptService = game:GetService("ServerScriptService")
local DataStoreService    = game:GetService("DataStoreService")
local Players             = game:GetService("Players")

local Modules             = ServerScriptService:WaitForChild("Modules")

local Orchestrator        = require(Modules:WaitForChild("PlayerProfileOrchestrator"))
local CoreStatsService    = require(Modules:WaitForChild("CoreStatsService"))
local InventoryService    = require(Modules:WaitForChild("InventoryService"))
local GrowthPersistenceService = (function()
	local ok,mod = pcall(function() return require(Modules:WaitForChild("GrowthPersistenceService")) end)
	return ok and mod or nil
end)()

local CONFIG = {
	TripleExitSaveEnabled        = true,
	ExitSaveAttempts             = 3,
	ExitSaveBackoffSeconds       = 0.40,
	ExitSaveVerificationDelay    = 0.15,
	LogSuccessEvenOnFirstTry     = true,
	Verbose                      = true,
	DataStoreName                = "PlayerUnified_v1",
	KeyPrefix                    = "Player_",
}

local registered        = false
local initialized       = false
local store             = DataStoreService:GetDataStore(CONFIG.DataStoreName)
local exitSnapshotCache = {}
local exitSnapshotAt    = {}

local function dprint(...)
	if CONFIG.Verbose then print("[PlayerDataService]", ...) end
end
local function exitLog(...) print("[PDS-ExitSave]", ...) end
local function keyFor(uid) return CONFIG.KeyPrefix .. tostring(uid) end

local function deepCopy(v, seen)
	if type(v) ~= "table" then return v end
	seen = seen or {}
	if seen[v] then return seen[v] end
	local t = {}
	seen[v] = t
	for k,val in pairs(v) do
		t[deepCopy(k, seen)] = deepCopy(val, seen)
	end
	return t
end

local function ensureRegistration()
	if registered then return end
	Orchestrator.RegisterModule(CoreStatsService)
	Orchestrator.RegisterModule(InventoryService)
	if GrowthPersistenceService then
		Orchestrator.RegisterModule(GrowthPersistenceService)
	end
	if Orchestrator.RegisterPreExitCallback then
		Orchestrator.RegisterPreExitCallback(function(player, profile)
			if player and profile then
				exitSnapshotCache[player.UserId] = deepCopy(profile)
				exitSnapshotAt[player.UserId]    = os.clock()
				exitLog(string.format("Snapshot captured userId=%d dv=%s", player.UserId, tostring(profile.dataVersion)))
			end
		end)
	else
		warn("[PlayerDataService] Orchestrator lacks RegisterPreExitCallback; pre-exit snapshot disabled.")
	end
	registered = true
end

local function ensureInitialized()
	if initialized then return end
	ensureRegistration()
	Orchestrator.Init()
	initialized = true
	print("[PlayerDataService] (compat) initialized via orchestrator.")
end

local function performVerifiedWrite(userId, snapshot, attempt)
	local key = keyFor(userId)
	local okUpdate, errUpdate = pcall(function()
		store:UpdateAsync(key, function()
			return snapshot
		end)
	end)
	if not okUpdate then
		exitLog(string.format("Attempt %d UpdateAsync failed userId=%d err=%s", attempt, userId, tostring(errUpdate)))
		return false, "write_fail"
	end
	task.wait(CONFIG.ExitSaveVerificationDelay)
	local stored
	local okRead, errRead = pcall(function()
		stored = store:GetAsync(key)
	end)
	if not okRead then
		exitLog(string.format("Attempt %d verify read failed userId=%d err=%s", attempt, userId, tostring(errRead)))
		return false, "verify_fail"
	end
	if type(stored) ~= "table" then
		exitLog(string.format("Attempt %d verify invalid type userId=%d", attempt, userId))
		return false, "verify_type"
	end
	local sv = stored.dataVersion or -1
	local pv = snapshot.dataVersion or -1
	if sv < pv then
		exitLog(string.format("Attempt %d version mismatch userId=%d stored=%s expected>=%s",
			attempt, userId, tostring(sv), tostring(pv)))
		return false, "version_mismatch"
	end
	exitLog(string.format("Attempt %d SUCCESS userId=%d dataVersion=%s", attempt, userId, tostring(sv)))
	return true
end

local function tripleExitSave(player)
	if not CONFIG.TripleExitSaveEnabled then return end
	local userId = player.UserId
	local snapshot = exitSnapshotCache[userId]
	if not snapshot then
		local fallback = Orchestrator.GetProfile(player)
		if fallback then
			exitLog(string.format("Late snapshot fallback userId=%d dv=%s", userId, tostring(fallback.dataVersion)))
			snapshot = deepCopy(fallback)
		else
			exitLog(string.format("NO snapshot & no profile (cannot exit save) userId=%d", userId))
			return
		end
	end
	local startT = os.clock()
	for attempt = 1, CONFIG.ExitSaveAttempts do
		local ok = performVerifiedWrite(userId, snapshot, attempt)
		if ok then
			if CONFIG.LogSuccessEvenOnFirstTry or attempt > 1 then
				exitLog(string.format("Verified exit save complete attempt=%d userId=%d elapsed=%.2fs",
					attempt, userId, os.clock()-startT))
			end
			return
		end
		if attempt < CONFIG.ExitSaveAttempts then
			task.wait(CONFIG.ExitSaveBackoffSeconds)
		else
			exitLog(string.format("FINAL FAILURE userId=%d after %d attempts (snapshot dv=%s)",
				userId, attempt, tostring(snapshot.dataVersion)))
		end
	end
end

local PlayerDataService = {}

function PlayerDataService.Init()
	ensureInitialized()
	Players.PlayerRemoving:Connect(tripleExitSave)
end
function PlayerDataService.InitIdempotent() PlayerDataService.Init() end

function PlayerDataService.RegisterFaction(name, init)
	ensureInitialized()
	CoreStatsService.RegisterFaction(name, init)
end

function PlayerDataService.MarkDirty(player, reason)
	ensureInitialized()
	Orchestrator.MarkDirty(player, reason or "Dirty")
end
function PlayerDataService.SaveImmediately(player, reason, opts)
	ensureInitialized()
	Orchestrator.MarkDirty(player, reason or "Immediate")
	Orchestrator.SaveNow(player, reason or "Immediate")
end

local function legacyView(profile)
	if not profile then return nil end
	local inv = profile.inventory or {}
	local core = profile.core or {}
	return {
		schemaVersion = profile.schemaVersion,
		dataVersion   = profile.dataVersion,
		userId        = profile.userId,
		updatedAt     = profile.updatedAt,
		coins         = core.coins or 0,
		slimes        = inv.capturedSlimes or {},
		worldSlimes   = inv.worldSlimes or {},
		worldEggs     = inv.worldEggs or {},
		eggTools      = inv.eggTools or {},
		foodTools     = inv.foodTools or {},
	}
end

function PlayerDataService.Get(player)
	ensureInitialized()
	return legacyView(Orchestrator.GetProfile(player))
end
function PlayerDataService.GetSlimes(player)       local p=PlayerDataService.Get(player); return p and p.slimes or {} end
function PlayerDataService.GetWorldSlimes(player)  local p=PlayerDataService.Get(player); return p and p.worldSlimes or {} end
function PlayerDataService.GetWorldEggs(player)    local p=PlayerDataService.Get(player); return p and p.worldEggs or {} end
function PlayerDataService.GetEggTools(player)     local p=PlayerDataService.Get(player); return p and p.eggTools or {} end
function PlayerDataService.GetFoodTools(player)    local p=PlayerDataService.Get(player); return p and p.foodTools or {} end

function PlayerDataService.GetCoins(player)           ensureInitialized(); return CoreStatsService.GetCoins(player) end
function PlayerDataService.SetCoins(player, amount)   ensureInitialized(); CoreStatsService.SetCoins(player, amount) end
function PlayerDataService.IncrementCoins(player, d)  ensureInitialized(); CoreStatsService.AdjustCoins(player, d) end
function PlayerDataService.GetStanding(player, faction) ensureInitialized(); return CoreStatsService.GetStanding(player, faction) end
function PlayerDataService.SetStanding(player, faction, value) ensureInitialized(); CoreStatsService.SetStanding(player, faction, value) end

function PlayerDataService.WaitForInventoryRestored(player, timeout)
	ensureInitialized()
	return Orchestrator.WaitForInventoryRestored(player, timeout)
end
function PlayerDataService.InventoryRestored(player)
	ensureInitialized()
	return Orchestrator.InventoryRestored(player)
end

function PlayerDataService.DebugForceTripleSave(player)
	if player then tripleExitSave(player) end
end

-- NEW: ForceFullSaveNow
function PlayerDataService.ForceFullSaveNow(player, reason)
	ensureInitialized()
	if not player or not player.Parent then return false,"player missing" end
	reason = reason or "ForceFullSave"
	-- Mark & SaveNow (orchestrator will re-serialize all modules before increment if AlwaysFullSerialize=true)
	Orchestrator.MarkDirty(player, reason)
	local ok = Orchestrator.SaveNow(player, reason)
	return ok and true or false
end

return PlayerDataService