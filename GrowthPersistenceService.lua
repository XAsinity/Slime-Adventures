-- GrowthPersistenceService.lua (v2.0 – decoupled, no circular require)
-- Purpose:
--   * Periodically "stamp" each owned slime's GrowthProgress into a persisted floor attribute
--     (PersistedGrowthProgress) and mark the player's profile dirty so the value is saved.
--   * Respond immediately to an external BindableEvent "GrowthStampDirty" to force an on-demand stamp + save.
--
-- Major Changes from v1.1:
--   1. REMOVED direct require of PlayerDataService to eliminate circular dependency.
--      Instead, we receive Orchestrator (PlayerProfileOrchestrator) via :Init(orch).
--      Use orch.MarkDirty(player, reason) and orch.SaveNow(player, reason, opts).
--   2. Added defensive nil checks & graceful degradation if Orchestrator methods missing.
--   3. Added lightweight caching of workspace slime descendants per stamp pass to avoid
--      repeated workspace:GetDescendants() per player loop (one scan each stamp cycle).
--   4. Added per-player debounce for rapid successive GrowthStampDirty events.
--   5. Added CONFIG options for performance tuning (folders to scan, max per cycle, etc.).
--   6. Safe shutdown handling if run context ends.
--
-- Priority:
--   Keep Priority AFTER any world slime restore serializers so that slimes exist
--   when the first stamp attempt happens (original was 140).
--
-- Persistence Contract:
--   This service itself does not serialize fields; it only mutates slime attributes
--   and marks profile dirty. Serializers that record these attributes remain unchanged.
--
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local GrowthPersistenceService = {
	Name     = "GrowthPersistenceService",
	Priority = 140,
}

----------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------
local CONFIG = {
	Debug                   = true,

	StampIntervalSeconds    = 45,   -- Minimum interval between automatic periodic stamps
	PollStepSeconds         = 8,    -- Heartbeat for checking whether to do a periodic stamp

	EventDebounceSeconds    = 2.5,  -- Ignore multiple GrowthStampDirty events for same player within this window
	ScanRoots               = { workspace }, -- Root instances to scan for slimes
	SlimeModelName          = "Slime",
	OwnerAttr               = "OwnerUserId",
	GrowthAttr              = "GrowthProgress",
	PersistedAttr           = "PersistedGrowthProgress",
	LastUpdateAttr          = "LastGrowthUpdate",

	MaxSlimesPerCycle       = 5000, -- Safety cap to avoid runaway cost (adjust to your game scale)
	YieldEvery              = 350,  -- Cooperative yield interval during large scans

	SkipStampIfLower        = true, -- Only raise persisted floor (never lower)
	MarkDirtyReasonPeriodic = "GrowthPeriodic",
	MarkDirtyReasonEvent    = "GrowthStamp",
	SaveReasonEventFlush    = "GrowthStampFlush",

	SaveEventSkipWorldFlag  = { skipWorld = true }, -- Passed to Orchestrator.SaveNow (if supported)
}

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------
local Orchestrator
local lastPeriodicStamp = 0
local playerEventDebounce = {}   -- [player] = last event stamp os.clock()
local running = true

----------------------------------------------------------------
-- UTIL
----------------------------------------------------------------
local function dprint(...)
	if CONFIG.Debug then
		print("[GrowthPersist]", ...)
	end
end

local function safeMarkDirty(player, reason)
	if Orchestrator and Orchestrator.MarkDirty then
		local ok,err = pcall(Orchestrator.MarkDirty, player, reason)
		if not ok then warn("[GrowthPersist] MarkDirty error:", err) end
	end
end

local function safeSaveNow(player, reason, opts)
	if Orchestrator and Orchestrator.SaveNow then
		local ok,err = pcall(Orchestrator.SaveNow, player, reason, opts)
		if not ok then warn("[GrowthPersist] SaveNow error:", err) end
	end
end

local function iterSlimesOnce()
	-- Single-pass scan; return array of slime models.
	local slimes = {}
	for _,root in ipairs(CONFIG.ScanRoots) do
		if root and root.Parent then
			for _,desc in ipairs(root:GetDescendants()) do
				if desc:IsA("Model") and desc.Name == CONFIG.SlimeModelName then
					slimes[#slimes+1] = desc
					if #slimes >= CONFIG.MaxSlimesPerCycle then
						warn(("[GrowthPersist] Reached MaxSlimesPerCycle (%d); truncating scan."):format(CONFIG.MaxSlimesPerCycle))
						return slimes
					end
					if (#slimes % CONFIG.YieldEvery) == 0 then task.wait() end
				end
			end
		end
	end
	return slimes
end

local function stampSlime(model)
	-- Validate
	if not (model and model.Parent and model:IsA("Model") and model.Name == CONFIG.SlimeModelName) then
		return
	end
	local gp = model:GetAttribute(CONFIG.GrowthAttr)
	if gp then
		local persisted = model:GetAttribute(CONFIG.PersistedAttr)
		if not CONFIG.SkipStampIfLower or (not persisted or gp > persisted) then
			model:SetAttribute(CONFIG.PersistedAttr, gp)
		end
	end
	model:SetAttribute(CONFIG.LastUpdateAttr, os.time())
end

local function stampPlayerSlimes(player, slimeList)
	local userId = player.UserId
	for _,slime in ipairs(slimeList) do
		if slime:GetAttribute(CONFIG.OwnerAttr) == userId then
			stampSlime(slime)
		end
	end
end

----------------------------------------------------------------
-- EVENT HANDLER
----------------------------------------------------------------
local function handleOnDemandStamp(userId, reason)
	local player = Players:GetPlayerByUserId(userId)
	if not player then return end

	-- Debounce
	local now = os.clock()
	local last = playerEventDebounce[player]
	if last and (now - last) < CONFIG.EventDebounceSeconds then
		dprint(("Debounce: Ignore GrowthStampDirty for %s (%.2fs < %.2fs)")
			:format(player.Name, now - last, CONFIG.EventDebounceSeconds))
		return
	end
	playerEventDebounce[player] = now

	-- Scan once globally, then stamp only this player's slimes
	local slimes = iterSlimesOnce()
	stampPlayerSlimes(player, slimes)

	safeMarkDirty(player, reason or CONFIG.MarkDirtyReasonEvent)
	safeSaveNow(player, CONFIG.SaveReasonEventFlush, CONFIG.SaveEventSkipWorldFlag)
	dprint(("On-demand growth stamp complete for %s (slimes inspected=%d)"):format(player.Name, #slimes))
end

----------------------------------------------------------------
-- PERIODIC LOOP
----------------------------------------------------------------
local function periodicLoop()
	while running do
		task.wait(CONFIG.PollStepSeconds)
		if not running then break end
		local now = os.clock()
		if now - lastPeriodicStamp >= CONFIG.StampIntervalSeconds then
			lastPeriodicStamp = now
			local slimes = iterSlimesOnce()
			if #slimes > 0 then
				for _,player in ipairs(Players:GetPlayers()) do
					stampPlayerSlimes(player, slimes)
					safeMarkDirty(player, CONFIG.MarkDirtyReasonPeriodic)
				end
				dprint(("Periodic stamp: scanned %d slime models."):format(#slimes))
			else
				dprint("Periodic stamp: no slimes found.")
			end
		end
	end
end

----------------------------------------------------------------
-- LIFECYCLE API (called by orchestrator)
----------------------------------------------------------------
function GrowthPersistenceService:Init(orch)
	Orchestrator = orch

	-- Bindable event (optional external trigger)
	local evt = ReplicatedStorage:FindFirstChild("GrowthStampDirty")
	if evt and evt:IsA("BindableEvent") then
		evt.Event:Connect(function(userId, reason)
			handleOnDemandStamp(userId, reason)
		end)
	else
		dprint("No GrowthStampDirty BindableEvent found (optional).")
	end

	-- Start periodic coroutine
	task.spawn(periodicLoop)
	dprint("Initialized (decoupled).")
end

function GrowthPersistenceService:OnProfileLoaded() end
function GrowthPersistenceService:RestoreToPlayer() end
function GrowthPersistenceService:Serialize() end

----------------------------------------------------------------
-- CLEANUP (Studio stop safeguard)
----------------------------------------------------------------
game:BindToClose(function()
	running = false
end)

return GrowthPersistenceService