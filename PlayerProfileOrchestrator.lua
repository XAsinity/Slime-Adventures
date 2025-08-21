-- PlayerProfileOrchestrator.lua
-- Version: v3.0-inventory-folder-integration
-- (See prompt for full commentary)

local DataStoreService   = game:GetService("DataStoreService")
local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local RunService         = game:GetService("RunService")

local PlayerProfileOrchestrator = {}

local CONFIG = {
	DataStoreName                    = "PlayerUnified_v1",
	KeyPrefix                        = "Player_",
	SchemaVersion                    = 1,
	SaveIntervalSeconds              = 60,
	QuickDirtySweepSeconds           = 7,
	MaxWriteRetries                  = 6,
	RetryBackoffBase                 = 0.5,
	PlayerSaveTimeout                = 10,
	AlwaysFullSerialize              = true,
	ForceDirtyOnLeave                = true,

	FireInventoryRestored            = true,
	RestoreValidationDelaySeconds    = 0.35,
	SecondPassDelaySeconds           = 0.15,
	PostSecondPassHeartbeatDelay     = 0.15,
	FailIfStillAbsent                = true,
	MinWorldGuardHeartbeatDelay      = 0.1,
	VerboseValidation                = true,

	Debug                            = true,
	VerboseSaves                     = true,
	TraceSerialize                   = false,

	FinalFlushWaitForInFlightSeconds = 8,
	BindToCloseGlobalTimeout         = 25,
	BindToClosePerPlayerRetryDelay   = 0.4,

	BackpackGuard = {
		Enable = true,
		MaxWaitSeconds = 0.6,
		SettleHeartbeats = 1,
		Log = true,
		ForceValidationSlack = 0.25,
	},
}

-- State
local store               = DataStoreService:GetDataStore(CONFIG.DataStoreName)
local modulesByName       = {}
local modulesOrdered      = {}
local profiles            = {}
local dirtyPlayers        = {}
local savingInFlight      = {}
local lastSaveAt          = {}
local joinClock           = {}
local initialized         = false

local restorePhase        = {}
local inventoryRestoredFlag = {}
local waitingCoroutines   = {}
local finalFlushed        = {}

local preExitCallbacks    = {}

-- Inventory bridge
local InventoryService = require(script.Parent:WaitForChild("InventoryService"))
InventoryService.Init()

-- Pre-exit callbacks
function PlayerProfileOrchestrator.RegisterPreExitCallback(fn)
	if type(fn) == "function" then
		table.insert(preExitCallbacks, fn)
	end
end

local function firePreExitCallbacks(player, profile)
	for _,cb in ipairs(preExitCallbacks) do
		local ok,err = pcall(cb, player, profile)
		if not ok then
			warn("[PPO] Pre-exit callback error:", err)
		end
	end
end

-- Logging
local function dprint(...) if CONFIG.Debug then print("[PPO]", ...) end end
local function vprint(...) if CONFIG.VerboseSaves then print("[PPO]", ...) end end
local function valprint(...) if CONFIG.VerboseValidation then print("[PPO][Validate]", ...) end end
local function gprint(...) if CONFIG.BackpackGuard.Enable and CONFIG.BackpackGuard.Log then print("[PPO][BPG]", ...) end end

-- Utilities
local function deepCopy(v)
	if type(v) ~= "table" then return v end
	local t={}
	for k,val in pairs(v) do
		t[k]=deepCopy(val)
	end
	return t
end

local function keyFor(uid) return CONFIG.KeyPrefix .. tostring(uid) end

local function newBlankProfile(uid)
	return {
		schemaVersion = CONFIG.SchemaVersion,
		dataVersion   = 1,
		userId        = uid,
		updatedAt     = os.time(),
		core          = {},
		inventory     = {},
		extra         = {},
	}
end

local function migrateIfNeeded(p)
	if type(p)~="table" or not p.schemaVersion then return false end
	if p.schemaVersion < CONFIG.SchemaVersion then
		p.schemaVersion = CONFIG.SchemaVersion
	end
	return true
end

local function loadProfile(uid)
	local key = keyFor(uid)
	local data
	local ok,err = pcall(function() data=store:GetAsync(key) end)
	if not ok then
		warn("[PPO] GetAsync failed", uid, err)
	end
	if not data or type(data)~="table" then
		dprint("Creating blank profile for userId="..uid)
		return newBlankProfile(uid)
	end
	if not migrateIfNeeded(data) then
		warn("[PPO] Invalid profile; resetting for", uid)
		return newBlankProfile(uid)
	end
	data.inventory = data.inventory or {}
	return data
end

-- Module registration (non-inventory modules)
function PlayerProfileOrchestrator.RegisterModule(mod)
	assert(mod and mod.Name, "Module must have Name")
	if modulesByName[mod.Name] then
		warn("[PPO] Duplicate module:", mod.Name)
		return
	end
	modulesByName[mod.Name] = mod
	table.insert(modulesOrdered, mod)
	table.sort(modulesOrdered, function(a,b)
		return (a.Priority or 100) < (b.Priority or 100)
	end)
	if mod.Init then
		local ok,err = pcall(function() mod:Init(PlayerProfileOrchestrator) end)
		if not ok then warn("[PPO] Module Init error", mod.Name, err) end
	end
	dprint("Registered module: "..mod.Name)
end

function PlayerProfileOrchestrator.MarkDirty(player, reason)
	if player and profiles[player] then
		dirtyPlayers[player] = reason or "Dirty"
	end
end

-- Inventory Bridge Helpers
local function inventoryBlobToArrays(blob)
	if not blob or not blob.fields then return {} end
	local inv = {}
	for fieldName, rec in pairs(blob.fields) do
		inv[fieldName] = rec.list or {}
	end
	return inv
end

local function captureInventorySnapshotIntoProfile(player)
	local profile = profiles[player]; if not profile then return end
	local blob = InventoryService.ExportPlayerSnapshot(player)
	if blob and blob.fields then
		profile.inventory = inventoryBlobToArrays(blob)
	end
end

-- SaveCallback: InventoryService notifies us; update profile + mark dirty
InventoryService.SetSaveCallback(function(player, blob, reason, finalFlag)
	local profile = profiles[player]
	if not profile then return end
	profile.inventory = inventoryBlobToArrays(blob)
	if not finalFlag then
		dirtyPlayers[player] = reason or "InventoryUpdate"
	end
end)

-- Serialization / Save
local function serializeAll(player)
	local profile = profiles[player]
	if not profile then return end
	for _,mod in ipairs(modulesOrdered) do
		if mod.Serialize then
			if CONFIG.TraceSerialize then
				dprint("Serialize call "..mod.Name.." for "..player.Name)
			end
			local ok,err=pcall(function() mod:Serialize(player, profile) end)
			if not ok then
				warn("[PPO] Serialize error", mod.Name, err)
			end
		end
	end
	captureInventorySnapshotIntoProfile(player)
end

local function forceFinalSerializeAll(player, reason)
	local profile = profiles[player]
	if not profile then return end
	for _,mod in ipairs(modulesOrdered) do
		local ok,err
		if mod.ForceFinalSerialize then
			ok,err = pcall(function() mod:ForceFinalSerialize(player, profile, reason) end)
		elseif mod.Serialize then
			ok,err = pcall(function() mod:Serialize(player, profile) end)
		end
		if ok == false then
			warn("[PPO] Final serialize error", mod.Name, err)
		end
	end
	captureInventorySnapshotIntoProfile(player)
end

local function rawSaveSnapshot(player, snapshot, reason)
	local key = keyFor(player.UserId)
	local attempt, success, lastErr = 0,false,nil
	while attempt < CONFIG.MaxWriteRetries and not success do
		attempt += 1
		local ok,err = pcall(function()
			store:UpdateAsync(key, function()
				return snapshot
			end)
		end)
		if ok then
			success = true
		else
			lastErr = err
			warn(("[PPO] Save failed %s attempt %d: %s"):format(player.Name, attempt, tostring(err)))
			task.wait(CONFIG.RetryBackoffBase * 2^(attempt-1) * (0.85 + math.random()*0.3))
		end
	end
	return success, lastErr
end

local function saveProfile(player, forceReason, opts)
	if not player.Parent then return false end
	local profile = profiles[player]; if not profile then return false end
	local reason = forceReason or dirtyPlayers[player]
	if not reason then return true end

	if savingInFlight[player] then
		dprint("Coalesce save "..player.Name)
		return true
	end

	savingInFlight[player] = true
	local finalFlush = opts and opts.finalFlush

	if CONFIG.AlwaysFullSerialize and not finalFlush then
		serializeAll(player)
	end

	profile.dataVersion += 1
	profile.updatedAt = os.time()
	local snapshot = deepCopy(profile)

	local success, err = rawSaveSnapshot(player, snapshot, reason)
	if success then
		vprint(("Saved %s v%d reason=%s%s"):format(
			player.Name, profile.dataVersion, tostring(reason),
			finalFlush and " (FINAL)" or ""
			))
		dirtyPlayers[player]=nil
		lastSaveAt[player]=os.time()
	else
		warn("[PPO] FINAL save failure", player.Name, err)
	end
	savingInFlight[player]=false
	return success
end

function PlayerProfileOrchestrator.SaveNow(player, reason)
	PlayerProfileOrchestrator.MarkDirty(player, reason or "Manual")
	return saveProfile(player)
end

function PlayerProfileOrchestrator:ForceLeaveFlush(player, reason)
	if finalFlushed[player] then
		dprint("Skip duplicate final flush "..player.Name)
		return
	end
	local profile = profiles[player]
	if not profile then return end

	local startWait = os.clock()
	while savingInFlight[player] and (os.clock() - startWait) < CONFIG.FinalFlushWaitForInFlightSeconds do
		task.wait(0.1)
	end

	forceFinalSerializeAll(player, reason or "FinalFlush")
	dirtyPlayers[player] = reason or "FinalFlush"
	saveProfile(player, dirtyPlayers[player], { finalFlush = true })
	finalFlushed[player] = true
end

function PlayerProfileOrchestrator.GetProfile(player)
	local p=profiles[player]; return p and deepCopy(p) or nil
end

-- Inventory events
local function ensureEvents()
	local rs = ReplicatedStorage
	local function assure(name)
		local ev = rs:FindFirstChild(name)
		if not ev then
			ev = Instance.new("BindableEvent")
			ev.Name = name
			ev.Parent = rs
		end
		return ev
	end
	return {
		pre = assure("PersistInventoryPreRestore"),
		main = assure("PersistInventoryRestored"),
		validate = assure("PersistInventoryValidation"),
	}
end

local eventsCache
local function fireInventoryEvent(kind, ...)
	if not CONFIG.FireInventoryRestored then return end
	eventsCache = eventsCache or ensureEvents()
	local ev = eventsCache[kind]
	if ev then ev:Fire(...) end
end

-- WAIT FOR STABLE BACKPACK
local function safeId(inst)
	if not inst then return "nil" end
	local ok,id = pcall(function() return inst:GetFullName() end)
	if ok then return id end
	return tostring(inst)
end

local function waitForStableBackpack(player, maxSeconds, settleHeartbeats)
	if not CONFIG.BackpackGuard.Enable then return true end
	maxSeconds = maxSeconds or CONFIG.BackpackGuard.MaxWaitSeconds
	settleHeartbeats = settleHeartbeats or CONFIG.BackpackGuard.SettleHeartbeats

	local deadline = os.clock() + maxSeconds
	local stableBp
	while os.clock() < deadline do
		if not player.Parent then return false end
		local bp = player:FindFirstChildOfClass("Backpack")
		if bp then
			RunService.Heartbeat:Wait()
			if bp.Parent and player:FindFirstChildOfClass("Backpack") == bp then
				stableBp = bp
				break
			end
		else
			RunService.Heartbeat:Wait()
		end
	end
	if stableBp then
		local waited = CONFIG.BackpackGuard.MaxWaitSeconds - math.max(0, deadline - os.clock())
		gprint(("Stable backpack for %s (id=%s) after %.3fs")
			:format(player.Name, safeId(stableBp), waited))
		for i=1, settleHeartbeats do
			RunService.Heartbeat:Wait()
		end
		return true
	else
		gprint(("No stable backpack found for %s within %.2fs; proceeding.")
			:format(player.Name, maxSeconds))
		return false
	end
end

-- Module callbacks & restore + inventory bridge
local function runModuleCallbacks(player, profile)
	for _,m in ipairs(modulesOrdered) do
		if m.OnProfileLoaded then
			local ok,err = pcall(function() m:OnProfileLoaded(player, profile) end)
			if not ok then warn("[PPO] OnProfileLoaded error", m.Name, err) end
		end
	end
	fireInventoryEvent("pre", player)

	local function doInventoryRestore()
		if not profiles[player] or not player.Parent then return end
		local invData = profile.inventory
		if invData and type(invData)=="table" then
			local blob = { v=1, fields={} }
			for fieldName, list in pairs(invData) do
				if type(list)=="table" then
					blob.fields[fieldName] = { v=1, list=list }
				end
			end
			InventoryService.RestorePlayer(player, blob)
		end
	end

	local function doOtherRestores()
		for _,m in ipairs(modulesOrdered) do
			if m.RestoreToPlayer then
				local ok,err = pcall(function() m:RestoreToPlayer(player, profile) end)
				if not ok then warn("[PPO] Restore error", m.Name, err) end
			end
		end
	end

	local function chainRestore()
		doInventoryRestore()
		doOtherRestores()
	end

	if CONFIG.BackpackGuard.Enable then
		if not player.Character then
			player.CharacterAdded:Once(function()
				waitForStableBackpack(player,
					CONFIG.BackpackGuard.MaxWaitSeconds,
					CONFIG.BackpackGuard.SettleHeartbeats)
				chainRestore()
			end)
		else
			waitForStableBackpack(player,
				CONFIG.BackpackGuard.MaxWaitSeconds,
				CONFIG.BackpackGuard.SettleHeartbeats)
			chainRestore()
		end
	else
		chainRestore()
	end
end

-- Validation & second pass
local function wakeWaiting(player)
	local waiters = waitingCoroutines[player]
	if waiters then
		for _,thread in ipairs(waiters) do
			task.defer(coroutine.resume, thread, true)
		end
		waitingCoroutines[player] = nil
	end
end

local function finishInventoryRestored(player)
	if inventoryRestoredFlag[player] then return end
	inventoryRestoredFlag[player]=true
	fireInventoryEvent("main", player)
	wakeWaiting(player)
	dprint("Inventory restore complete for "..player.Name)
end

local function snapshotExpectedCounts(profile)
	local inv = profile.inventory or {}
	return {
		foodTools       = #(inv.foodTools or {}),
		eggTools        = #(inv.eggTools or {}),
		capturedSlimes  = #(inv.capturedSlimes or {}),
		worldSlimes     = #(inv.worldSlimes or {}),
		worldEggs       = #(inv.worldEggs or {}),
	}
end

local function listLiveCounts(player)
	local counts = { foodTools=0, eggTools=0, capturedSlimes=0 }
	local bp = player:FindFirstChildOfClass("Backpack")
	if bp then
		for _,t in ipairs(bp:GetChildren()) do
			if t:IsA("Tool") then
				if t:GetAttribute("FoodItem") or t:GetAttribute("FoodId") then counts.foodTools += 1 end
				if t:GetAttribute("EggId") and not t:GetAttribute("Placed") then counts.eggTools += 1 end
				if t:GetAttribute("SlimeItem") or t:GetAttribute("SlimeId") then counts.capturedSlimes += 1 end
			end
		end
	end
	return counts
end

local function needsSecondPass(expected, live)
	for k,v in pairs(expected) do
		if (k=="foodTools" or k=="eggTools" or k=="capturedSlimes") and v>0 then
			if live[k] == 0 then return true end
		end
	end
	return false
end

local function secondPassRestore(player)
	local profile = profiles[player]
	if not profile then return end
	captureInventorySnapshotIntoProfile(player)
end

local function validateAndMaybeSecondPass(player)
	local profile = profiles[player]
	if not profile or not player.Parent then return end

	captureInventorySnapshotIntoProfile(player)

	local expected = snapshotExpectedCounts(profile)
	local live     = listLiveCounts(player)

	if CONFIG.VerboseValidation then
		valprint(string.format("%s expected food=%d egg=%d cap=%d worldS=%d worldE=%d | live food=%d egg=%d cap=%d",
			player.Name,
			expected.foodTools, expected.eggTools, expected.capturedSlimes,
			expected.worldSlimes, expected.worldEggs,
			live.foodTools, live.eggTools, live.capturedSlimes))
	end

	local pass = not needsSecondPass(expected, live)
	fireInventoryEvent("validate", player, {
		expected = expected,
		live     = live,
		pass     = pass,
		phase    = restorePhase[player] and restorePhase[player].state or "initial"
	})
	if pass then
		restorePhase[player] = { state="validated", validatedAt=os.clock() }
		task.delay(CONFIG.MinWorldGuardHeartbeatDelay, function()
			if player.Parent then finishInventoryRestored(player) end
		end)
	else
		restorePhase[player] = { state="pass2_scheduled" }
		task.delay(CONFIG.SecondPassDelaySeconds, function()
			if not profiles[player] or not player.Parent then return end
			secondPassRestore(player)
			task.delay(CONFIG.PostSecondPassHeartbeatDelay, function()
				if not profiles[player] or not player.Parent then return end
				captureInventorySnapshotIntoProfile(player)
				local expected2 = snapshotExpectedCounts(profile)
				local live2     = listLiveCounts(player)
				local pass2     = not needsSecondPass(expected2, live2)
				fireInventoryEvent("validate", player, {
					expected=expected2, live=live2, pass=pass2, phase="secondPass"
				})
				if pass2 then
					restorePhase[player] = { state="validated2", validatedAt=os.clock() }
					finishInventoryRestored(player)
				else
					restorePhase[player] = { state="failed" }
					if CONFIG.FailIfStillAbsent then
						local anyExpected = (expected2.foodTools + expected2.eggTools + expected2.capturedSlimes) > 0
						if anyExpected then
							warn(("[PPO][HARD FAIL] Inventory still absent after second pass for %s."):format(player.Name))
						else
							warn(("[PPO][WARN] Second pass ended but nothing expected for %s (no data)."):format(player.Name))
						end
					end
					finishInventoryRestored(player)
				end
			end)
		end)
	end
end

-- Player lifecycle
local function onPlayerAdded(player)
	joinClock[player]=os.clock()
	local profile = loadProfile(player.UserId)
	profiles[player]=profile
	dirtyPlayers[player]="InitialLoad"
	restorePhase[player]={ state="initial" }

	runModuleCallbacks(player, profile)

	local validationDelay = CONFIG.RestoreValidationDelaySeconds
	if CONFIG.BackpackGuard.Enable then
		validationDelay = math.max(validationDelay,
			CONFIG.BackpackGuard.MaxWaitSeconds + CONFIG.BackpackGuard.ForceValidationSlack)
	end

	task.delay(validationDelay, function()
		if profiles[player] and player.Parent and not inventoryRestoredFlag[player] then
			validateAndMaybeSecondPass(player)
		end
	end)

	task.delay(1, function()
		if profiles[player] and player.Parent then
			PlayerProfileOrchestrator.MarkDirty(player, "BarrierFinal")
			saveProfile(player)
		end
	end)
end

local function cleanupPlayerState(player)
	profiles[player]=nil
	dirtyPlayers[player]=nil
	savingInFlight[player]=nil
	lastSaveAt[player]=nil
	joinClock[player]=nil
	restorePhase[player]=nil
	inventoryRestoredFlag[player]=nil
	waitingCoroutines[player]=nil
	finalFlushed[player]=nil
end

local function onPlayerRemoving(player)
	local profile = profiles[player]
	if profile then
		firePreExitCallbacks(player, profile)
	end
	if profile and CONFIG.ForceDirtyOnLeave and not dirtyPlayers[player] then
		dirtyPlayers[player]="LeaveDirty"
		captureInventorySnapshotIntoProfile(player)
	end
	PlayerProfileOrchestrator:ForceLeaveFlush(player, "PlayerRemoving")
	cleanupPlayerState(player)
end

-- Autosave loops
local function autosaveLoop()
	while true do
		task.wait(CONFIG.SaveIntervalSeconds)
		for plr in pairs(profiles) do
			if dirtyPlayers[plr] then
				saveProfile(plr)
			end
		end
	end
end

local function quickDirtySweep()
	while true do
		task.wait(CONFIG.QuickDirtySweepSeconds)
		for plr in pairs(dirtyPlayers) do
			if profiles[plr] and not savingInFlight[plr] then
				saveProfile(plr)
			end
		end
	end
end

-- Wait / status API
function PlayerProfileOrchestrator.WaitForInventoryRestored(player, timeout)
	if inventoryRestoredFlag[player] then return true end
	local co = coroutine.running()
	waitingCoroutines[player] = waitingCoroutines[player] or {}
	table.insert(waitingCoroutines[player], co)
	task.delay(timeout or 10, function()
		if inventoryRestoredFlag[player] then return end
		local list = waitingCoroutines[player]
		if list then
			for i,th in ipairs(list) do
				if th==co then
					table.remove(list, i)
					break
				end
			end
		end
		coroutine.resume(co, false)
	end)
	local ok = coroutine.yield()
	return ok
end

function PlayerProfileOrchestrator.InventoryRestored(player)
	return inventoryRestoredFlag[player] == true
end

-- Init
function PlayerProfileOrchestrator.Init()
	if initialized then return end
	initialized=true
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _,plr in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, plr)
	end
	task.spawn(autosaveLoop)
	task.spawn(quickDirtySweep)

	game:BindToClose(function()
		dprint("BindToClose: initiating global final flush")
		local start = os.clock()
		local list = Players:GetPlayers()
		for _,plr in ipairs(list) do
			local ok,err = pcall(function()
				PlayerProfileOrchestrator:ForceLeaveFlush(plr, "ShutdownFlush")
			end)
			if not ok then
				warn("[PPO] Shutdown flush error:", err)
			end
		end
		while true do
			local inflight = 0
			for _,flag in pairs(savingInFlight) do
				if flag then inflight += 1 end
			end
			if inflight == 0 then break end
			if os.clock() - start > CONFIG.BindToCloseGlobalTimeout then
				warn("[PPO] BindToClose timeout; proceeding with", inflight, "saves still in flight")
				break
			end
			task.wait(0.25)
		end
		dprint("BindToClose: final flush complete")
	end)

	dprint("PlayerProfileOrchestrator initialized (Inventory bridge active)")
end

return PlayerProfileOrchestrator