-- MusicVolumePersistence.server.lua (v3) - Explicit remote tracking + immediate queued save.
-- Changes from v2:
--  * Uses RemoteEvent UpdateMusicVolume for authoritative player intent.
--  * Immediately updates LocalMusicVolume and marks dirty.
--  * Adds short debounce & batched save queue (ensures save even on fast leave).
--  * Keeps replication fallback (client writes NumberValue too), but remote is primary signal.
--  * Optional DEBUG prints more granular info.

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local STORE_NAME = "MusicVolumeV1"
local KEY_PREFIX = "MV_"
local DEFAULT_VOLUME = 0.5
local AUTOSAVE_INTERVAL = 60
local MAX_RETRIES = 3
local IMMEDIATE_SAVE_DELAY = 4        -- seconds after last change to attempt a save
local DEBUG = true
local FORCE_OFFLINE_IN_STUDIO = false

local function dprint(...)
	if DEBUG then
		print("[MusicVolumePersistence]", ...)
	end
end

-- Remote reference
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local updateEvent = remotes:WaitForChild("UpdateMusicVolume")

local offlineMode = (RunService:IsStudio() and FORCE_OFFLINE_IN_STUDIO)
local dataStore
local dirty = {}            -- userId -> true if unsaved change
local lastKnown = {}        -- userId -> current volume
local lastChangeTick = {}   -- userId -> time() of last change
local lastAutosaveTick = time()

-- Helpers
local function dsKey(uid) return KEY_PREFIX .. tostring(uid) end
local function isStudioAccessError(errStr) return tostring(errStr):find("StudioAccessToApisNotAllowed", 1, true) ~= nil end
local function isRetryable(errStr)
	local s = tostring(errStr)
	return s:find("502") or s:find("504") or s:find("timeout") or s:lower():find("throttle") or s:find("TooManyRequests")
end

-- Init DataStore
if not offlineMode then
	local ok, err = pcall(function()
		dataStore = DataStoreService:GetDataStore(STORE_NAME)
	end)
	if not ok then
		if isStudioAccessError(err) then
			warn("[MusicVolumePersistence] Studio API disabled; offline mode.")
		else
			warn("[MusicVolumePersistence] DataStore init failed; offline mode. Err:", err)
		end
		offlineMode = true
	end
end

local function saveVolumeImmediate(userId, volume)
	if offlineMode or not dataStore then return true end
	local tries = 0
	while tries < MAX_RETRIES do
		tries += 1
		local ok, err = pcall(function()
			dataStore:UpdateAsync(dsKey(userId), function() return volume end)
		end)
		if ok then
			dprint("Saved volume", volume, "uid", userId)
			return true
		else
			if isStudioAccessError(err) then
				warn("[MusicVolumePersistence] Studio API disabled mid-session; offline mode.")
				offlineMode = true
				return false
			end
			if not isRetryable(err) then
				warn("[MusicVolumePersistence] Non-retryable save error", err)
				return false
			end
			task.wait(0.5 * tries)
		end
	end
	warn("[MusicVolumePersistence] Failed to save after retries uid", userId)
	return false
end

local function flagDirty(uid, volume)
	lastKnown[uid] = volume
	dirty[uid] = true
	lastChangeTick[uid] = time()
	dprint("Volume changed to", volume, "uid", uid)
end

local function loadVolume(player)
	local uid = player.UserId
	local volume = DEFAULT_VOLUME

	if not offlineMode and dataStore then
		local ok, result = pcall(function()
			return dataStore:GetAsync(dsKey(uid))
		end)
		if ok and typeof(result) == "number" then
			volume = math.clamp(result, 0, 1)
			dprint("Loaded volume", volume, "for", uid)
		else
			if not ok then
				if isStudioAccessError(result) then
					warn("[MusicVolumePersistence] Switching offline (Studio API).")
					offlineMode = true
				else
					warn("[MusicVolumePersistence] Load failed for", uid, result)
				end
			else
				dprint("No stored volume, default for", uid)
			end
		end
	end

	lastKnown[uid] = volume
	dirty[uid] = false
	lastChangeTick[uid] = time()

	-- Ensure NumberValue exists
	local val = player:FindFirstChild("LocalMusicVolume")
	if not val then
		val = Instance.new("NumberValue")
		val.Name = "LocalMusicVolume"
		val.Parent = player
	end
	val.Value = volume

	-- Replication fallback watcher
	val.Changed:Connect(function()
		local v = math.clamp(val.Value, 0, 1)
		if lastKnown[uid] ~= v then
			flagDirty(uid, v)
		end
	end)
end

local function saveIfDirty(uid, reason)
	if dirty[uid] then
		local vol = lastKnown[uid]
		if typeof(vol) == "number" then
			dprint("Attempting save (reason="..reason..") uid "..uid.." vol "..vol)
			if saveVolumeImmediate(uid, vol) then
				dirty[uid] = false
			end
		end
	end
end

local function onPlayerRemoving(player)
	saveIfDirty(player.UserId, "PlayerRemoving")
	dirty[player.UserId] = nil
	lastKnown[player.UserId] = nil
	lastChangeTick[player.UserId] = nil
end

Players.PlayerAdded:Connect(loadVolume)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- Remote handler
updateEvent.OnServerEvent:Connect(function(player, newVolume)
	if typeof(newVolume) ~= "number" then return end
	local uid = player.UserId
	local v = math.clamp(newVolume, 0, 1)

	-- Update NumberValue (which also covers replication)
	local val = player:FindFirstChild("LocalMusicVolume")
	if not val then
		val = Instance.new("NumberValue")
		val.Name = "LocalMusicVolume"
		val.Parent = player
	end
	if val.Value ~= v then
		val.Value = v
		-- Changed event will call flagDirty, but we can ensure early:
		flagDirty(uid, v)
	end
end)

-- Background loops: autosave + short-delay immediate saves.
task.spawn(function()
	while task.wait(5) do
		local now = time()
		-- Periodic autosave
		if now - lastAutosaveTick >= AUTOSAVE_INTERVAL then
			lastAutosaveTick = now
			for _,plr in ipairs(Players:GetPlayers()) do
				saveIfDirty(plr.UserId, "Autosave")
			end
		end
		-- Immediate after short delay from last change
		for _,plr in ipairs(Players:GetPlayers()) do
			local uid = plr.UserId
			if dirty[uid] and (now - (lastChangeTick[uid] or 0) >= IMMEDIATE_SAVE_DELAY) then
				saveIfDirty(uid, "PostChangeDelay")
			end
		end
	end
end)

game:BindToClose(function()
	for _,plr in ipairs(Players:GetPlayers()) do
		saveIfDirty(plr.UserId, "Shutdown")
	end
end)