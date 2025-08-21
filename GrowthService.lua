-- GrowthService.lua
-- Version: v2.7.5-nilfix-micro-stamp-flush
-- Base: v2.7.4-micro-stamp-flush  (v2.7.3-micro-stamp earlier)
--
-- v2.7.5 CHANGES / FIXES:
--   * FIX: Added missing debug print helper dprint(). Previous versions
--     referenced dprint() inside updateSlime() (on growth completion) but never
--     defined it, causing "attempt to call a nil value" runtime errors
--     (stack trace pointing to updateSlime line where dprint was invoked).
--     Root cause of your reported error.
--   * Defensive guard: attemptMutationOnStep now safely returns if the
--     mutation function is absent (should not be, but prevents future nil calls).
--   * Optional safety initialization comment retained.
--
-- v2.7.4 Recap:
--   * Clarified comments, optional initialization of PersistedGrowthProgress floor.
--
-- v2.7.3 Recap:
--   * Micro progress stamping (MICRO_PROGRESS_THRESHOLD / MICRO_DEBOUNCE_SECONDS)
--   * GrowthService.FlushPlayerSlimes(userId) API for leave flush
--
-- Existing features (unchanged): offline growth, persisted floor non-regression,
-- periodic timestamp stamping, mutation hooks, hunger scaling.

local RunService = game:GetService("RunService")
local Workspace  = game:GetService("Workspace")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ServerScriptService:FindFirstChild("Modules") or script.Parent
if not Modules:FindFirstChild("SlimeMutation") then
	local root = ServerScriptService:FindFirstChild("Modules")
	if root then Modules = root end
end
local SlimeMutation = require(Modules:WaitForChild("SlimeMutation"))

local GrowthService = {}

----------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------
local CONFIG = {
	VALUE_STEP        = 0.05,
	RESIZE_EPSILON    = 1e-4,
	MIN_AXIS          = 0.05,
	USE_EASED_VALUE   = false,
	MUTATION_ON_STEP  = true,
	DEBUG             = false,
	DEBUG_INIT        = false,
	HungerGrowthEnabled = true,

	-- OFFLINE GROWTH
	OFFLINE_GROWTH_ENABLED           = true,
	OFFLINE_GROWTH_MAX_SECONDS       = 12 * 3600,
	OFFLINE_GROWTH_VERBOSE           = true,
	OFFLINE_GROWTH_APPLY_ANIMATE     = false,
	GROWTH_TIMESTAMP_UPDATE_INTERVAL = 5,
	INIT_OFFLINE_ASSUME_SECONDS      = 0,
	SECOND_PASS_REAPPLY_WINDOW       = 2.0,
	DEFER_OFFLINE_APPLY_ONE_HEARTBEAT = true,
	NON_REGRESS_SECOND_PASS_WINDOW   = 4.0,

	-- Debug instrumentation
	OFFLINE_DEBUG                    = true,
	OFFLINE_DEBUG_ATTR_SNAPSHOT      = true,
	OFFLINE_DEBUG_TAG                = "[GrowthOffline]",

	-- Dirty stamp debounce (seconds per player)
	STAMP_DIRTY_DEBOUNCE             = 6,

	-- Micro progress stamping thresholds
	MICRO_PROGRESS_THRESHOLD         = 0.005,
	MICRO_DEBOUNCE_SECONDS           = 1.0,
}

local HUNGER_GROWTH = {
	Enabled = true,
	MinMultiplier = 0.40,
	MaxMultiplier = 1.00,
	HardStopWhenEmpty = false,
}

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------
local SlimeCache = {}
local PendingOffline = {}
local lastStampDirtyByPlayer = {}
local growthDirtyEvent = ReplicatedStorage:FindFirstChild("GrowthStampDirty")
if not growthDirtyEvent then
	growthDirtyEvent = Instance.new("BindableEvent")
	growthDirtyEvent.Name = "GrowthStampDirty"
	growthDirtyEvent.Parent = ReplicatedStorage
end

local lastPersistedProgress = {} -- slimeId -> floor
local microCumulative       = {} -- slimeId -> cum delta
local lastMicroStampByPlayer = {} -- userId -> epoch

----------------------------------------------------------------
-- UTIL
----------------------------------------------------------------
local function dprint(...)
	if CONFIG.DEBUG then
		print("[GrowthService]", ...)
	end
end

local function safeFormat(n)
	if type(n) ~= "number" then return tostring(n) end
	return string.format("%.6f", n)
end

local function smallJSON(t)
	local parts={}
	for k,v in pairs(t) do
		local val
		if type(v)=="number" then
			val = safeFormat(v)
		elseif type(v)=="boolean" then
			val = v and "true" or "false"
		elseif type(v)=="string" then
			val = string.format("%q", v)
		else
			val = string.format("%q", tostring(v))
		end
		parts[#parts+1]=string.format("%q:%s", tostring(k), val)
	end
	return "{"..table.concat(parts,",").."}"
end

local function logOffline(slime, phase, info)
	if not CONFIG.OFFLINE_DEBUG then return end
	if not slime or not slime.Parent then return end
	info = info or {}
	info.phase = phase
	info.sid = tostring(slime:GetAttribute("SlimeId") or slime:GetDebugId())
	info.gp = slime:GetAttribute("GrowthProgress")
	info.floor = slime:GetAttribute("PersistedGrowthProgress")
	info.lg = slime:GetAttribute("LastGrowthUpdate")
	info.fb = slime:GetAttribute("FeedBufferSeconds")
	info.ff = slime:GetAttribute("FedFraction")
	info.age = slime:GetAttribute("AgeSeconds")
	local line = CONFIG.OFFLINE_DEBUG_TAG .. smallJSON(info)
	if CONFIG.OFFLINE_DEBUG_ATTR_SNAPSHOT then
		slime:SetAttribute("OfflineDebugLast", line:sub(1, 2000))
		slime:SetAttribute("OfflineDebugJSON", line)
	end
end

----------------------------------------------------------------
-- Dirty marking (full stamp)
----------------------------------------------------------------
local function markStampDirty(slime, reason)
	local uid = slime:GetAttribute("OwnerUserId")
	if not uid then return end
	local now = os.time()
	local last = lastStampDirtyByPlayer[uid] or 0
	if (now - last) >= CONFIG.STAMP_DIRTY_DEBOUNCE then
		lastStampDirtyByPlayer[uid] = now
		if CONFIG.OFFLINE_DEBUG then
			logOffline(slime, "emit_growth_stamp", {reason=reason})
		end
		growthDirtyEvent:Fire(uid, reason or "Stamp")
	end
end

-- Micro progress stamp
local function tryMicroProgressStamp(slime, progress, prevProgress)
	if progress == prevProgress then return end
	local sid = slime:GetAttribute("SlimeId")
	if not sid then return end
	local uid = slime:GetAttribute("OwnerUserId")
	if not uid then return end

	local floor = lastPersistedProgress[sid]
	if not floor then
		floor = slime:GetAttribute("PersistedGrowthProgress") or progress
		lastPersistedProgress[sid] = floor
		microCumulative[sid] = 0
	end

	local deltaSinceFloor = progress - floor
	microCumulative[sid] = (microCumulative[sid] or 0) + (progress - prevProgress)

	if deltaSinceFloor >= CONFIG.MICRO_PROGRESS_THRESHOLD then
		local now = os.time()
		local lastMicro = lastMicroStampByPlayer[uid] or 0
		if (now - lastMicro) >= CONFIG.MICRO_DEBOUNCE_SECONDS then
			slime:SetAttribute("PersistedGrowthProgress", progress)
			lastPersistedProgress[sid] = progress
			microCumulative[sid] = 0
			lastMicroStampByPlayer[uid] = now
			if CONFIG.OFFLINE_DEBUG then
				logOffline(slime, "micro_stamp", {
					reason="threshold",
					progress=progress,
					floor_before=floor,
					th=CONFIG.MICRO_PROGRESS_THRESHOLD
				})
			end
			growthDirtyEvent:Fire(uid, "MicroProgress")
		end
	end
end

----------------------------------------------------------------
-- Math / hunger helpers
----------------------------------------------------------------
local function ease(t) return t*t*(3 - 2*t) end

local function hungerMultiplier(slime)
	if not (CONFIG.HungerGrowthEnabled and HUNGER_GROWTH.Enabled) then return 1 end
	local fed = slime:GetAttribute("FedFraction")
	if fed == nil then return 1 end
	if HUNGER_GROWTH.HardStopWhenEmpty and fed <= 0 then return 0 end
	return HUNGER_GROWTH.MinMultiplier + (HUNGER_GROWTH.MaxMultiplier - HUNGER_GROWTH.MinMultiplier) * fed
end

----------------------------------------------------------------
-- Mutation
----------------------------------------------------------------
local function attemptMutationOnStep(slime)
	if not CONFIG.MUTATION_ON_STEP then return end
	if not SlimeMutation or type(SlimeMutation.AttemptMutation) ~= "function" then return end
	SlimeMutation.AttemptMutation(slime)
	if type(SlimeMutation.RecomputeValueFull) == "function" then
		SlimeMutation.RecomputeValueFull(slime)
	end
end

----------------------------------------------------------------
-- Size helpers
----------------------------------------------------------------
local function captureOriginalSizes(slime)
	for _,p in ipairs(slime:GetDescendants()) do
		if p:IsA("BasePart") then
			if not p:GetAttribute("OriginalSize") then
				p:SetAttribute("OriginalSize", p.Size)
			end
		end
	end
end

local function applyScale(slime, newScale)
	for _,p in ipairs(slime:GetDescendants()) do
		if p:IsA("BasePart") then
			local orig = p:GetAttribute("OriginalSize")
			if not orig then
				orig = p.Size
				p:SetAttribute("OriginalSize", orig)
			end
			local s = orig * newScale
			p.Size = Vector3.new(
				math.max(s.X, CONFIG.MIN_AXIS),
				math.max(s.Y, CONFIG.MIN_AXIS),
				math.max(s.Z, CONFIG.MIN_AXIS)
			)
		end
	end
end

----------------------------------------------------------------
-- OFFLINE CORE
----------------------------------------------------------------
local function computeOfflineDelta(slime)
	if not CONFIG.OFFLINE_GROWTH_ENABLED then
		logOffline(slime, "detect_delta_result", {delta=0, reason="disabled"})
		return 0
	end
	local now = os.time()
	local last = slime:GetAttribute("LastGrowthUpdate")
	logOffline(slime, "detect_delta_start", {now=now, last=last})

	if not last or type(last) ~= "number" then
		if CONFIG.INIT_OFFLINE_ASSUME_SECONDS > 0 then
			local assumed = math.min(CONFIG.INIT_OFFLINE_ASSUME_SECONDS, CONFIG.OFFLINE_GROWTH_MAX_SECONDS)
			slime:SetAttribute("LastGrowthUpdate", now - assumed)
			logOffline(slime, "detect_delta_result", {delta=assumed, reason="no_last_assumed"})
			return assumed
		else
			slime:SetAttribute("LastGrowthUpdate", now)
			logOffline(slime, "detect_delta_result", {delta=0, reason="no_last"})
			return 0
		end
	end

	local delta = now - last
	if delta <= 0 then
		logOffline(slime, "detect_delta_result", {delta=0, reason="non_positive"})
		return 0
	end
	if delta > CONFIG.OFFLINE_GROWTH_MAX_SECONDS then
		delta = CONFIG.OFFLINE_GROWTH_MAX_SECONDS
	end
	logOffline(slime, "detect_delta_result", {delta=delta, reason="ok"})
	return delta
end

local function writePersistedProgress(slime)
	local gp = slime:GetAttribute("GrowthProgress")
	if gp then
		local prior = slime:GetAttribute("PersistedGrowthProgress")
		if (not prior) or gp > prior then
			slime:SetAttribute("PersistedGrowthProgress", gp)
		end
		local sid = slime:GetAttribute("SlimeId")
		if sid then
			lastPersistedProgress[sid] = gp
			microCumulative[sid] = 0
		end
	end
end

local function finalizeOfflineStamp(slime, alsoPersistProgress, stampReason)
	if not CONFIG.OFFLINE_GROWTH_ENABLED then return end
	slime:SetAttribute("LastGrowthUpdate", os.time())
	if alsoPersistProgress then
		writePersistedProgress(slime)
	end
	logOffline(slime, "finalize_stamp", {persist=alsoPersistProgress})
	markStampDirty(slime, stampReason or "finalize_stamp")
end

local function applyOfflineGrowth(slime, offlineDelta, isReapply)
	if offlineDelta <= 0 then return 0 end
	local progress = slime:GetAttribute("GrowthProgress") or 0
	if progress >= 1 then
		slime:SetAttribute("AgeSeconds", (slime:GetAttribute("AgeSeconds") or 0) + offlineDelta)
		logOffline(slime, "apply_offline_skipped", {reason="already_complete", delta=offlineDelta})
		return 0
	end

	local feedMult      = slime:GetAttribute("FeedSpeedMultiplier") or 1
	local feedBuffer    = slime:GetAttribute("FeedBufferSeconds") or 0
	local unfedDuration = slime:GetAttribute("UnfedGrowthDuration") or 600
	if unfedDuration <= 0 then unfedDuration = 600 end
	local hungerSpeed   = hungerMultiplier(slime)

	logOffline(slime, "apply_offline_before", {
		delta=offlineDelta,
		progress_before=progress,
		feedBuffer=feedBuffer,
		unfed=unfedDuration,
		hunger=hungerSpeed,
		feedMult=feedMult,
		reapply=isReapply
	})

	local function segmentIncrement(seconds, speedMultiplier)
		if seconds <= 0 or progress >= 1 then return 0 end
		local inc = (seconds * speedMultiplier) / unfedDuration
		local cap = 1 - progress
		if inc > cap then inc = cap end
		progress += inc
		return inc
	end

	local bufferConsume = math.min(feedBuffer, offlineDelta)
	local normalTime    = offlineDelta - bufferConsume

	local inc1 = segmentIncrement(bufferConsume, feedMult * hungerSpeed)
	local inc2 = segmentIncrement(normalTime, hungerSpeed)
	local totalInc = inc1 + inc2

	if totalInc > 0 then
		slime:SetAttribute("GrowthProgress", progress)
	end
	if bufferConsume > 0 then
		slime:SetAttribute("FeedBufferSeconds", math.max(0, feedBuffer - bufferConsume))
	end
	slime:SetAttribute("AgeSeconds", (slime:GetAttribute("AgeSeconds") or 0) + offlineDelta)

	if CONFIG.OFFLINE_GROWTH_VERBOSE then
		slime:SetAttribute("OfflineGrowthApplied", (slime:GetAttribute("OfflineGrowthApplied") or 0) + offlineDelta)
	end

	writePersistedProgress(slime)

	logOffline(slime, "apply_offline_after", {
		progress_after=progress,
		progress_inc=totalInc,
		inc_buffer=inc1,
		inc_normal=inc2,
		feedBuffer_after=slime:GetAttribute("FeedBufferSeconds"),
		reapply=isReapply
	})

	return totalInc
end

----------------------------------------------------------------
-- CACHE INIT
----------------------------------------------------------------
local function initCacheIfNeeded(slime)
	local cache = SlimeCache[slime]
	if cache and cache.initialized then return cache end

	captureOriginalSizes(slime)

	local gp = slime:GetAttribute("GrowthProgress") or 0
	local floor = slime:GetAttribute("PersistedGrowthProgress")
	if floor and type(floor)=="number" and gp < floor then
		logOffline(slime, "floor_correction_init", {from=gp, to=floor})
		slime:SetAttribute("GrowthProgress", floor)
		gp = floor
	elseif not floor then
		slime:SetAttribute("PersistedGrowthProgress", gp)
	end

	local sid = slime:GetAttribute("SlimeId")
	if sid and not lastPersistedProgress[sid] then
		lastPersistedProgress[sid] = slime:GetAttribute("PersistedGrowthProgress") or gp
		microCumulative[sid] = 0
	end

	local startScale = slime:GetAttribute("CurrentSizeScale") or slime:GetAttribute("StartSizeScale") or 1
	cache = {
		lastScale = startScale,
		initialized = true,
		lastStampUpdate = os.time(),
		offlineAppliedAt = nil,
		reapplied = false,
	}
	SlimeCache[slime] = cache

	if CONFIG.DEBUG_INIT then
		dprint(string.format("Managing slime %s startScale=%.3f prog=%.4f",
			tostring(slime:GetAttribute("SlimeId")), startScale, gp))
	end
	return cache
end

----------------------------------------------------------------
-- OFFLINE APPLY SCHEDULING
----------------------------------------------------------------
local function scheduleOfflineApply(slime)
	if not CONFIG.OFFLINE_GROWTH_ENABLED then return end
	if CONFIG.DEFER_OFFLINE_APPLY_ONE_HEARTBEAT then
		PendingOffline[slime] = true
	else
		local delta = computeOfflineDelta(slime)
		if delta > 0 then
			applyOfflineGrowth(slime, delta, false)
			finalizeOfflineStamp(slime, true, "immediate_offline")
			local cache = SlimeCache[slime]
			if cache then cache.offlineAppliedAt = os.time() end
		else
			finalizeOfflineStamp(slime, true, "immediate_no_delta")
		end
	end
end

----------------------------------------------------------------
-- PER-FRAME UPDATE
----------------------------------------------------------------
local function updateSlime(slime, dt)
	if not slime.Parent or slime:GetAttribute("DisableGrowth") then return end
	local maxScale   = slime:GetAttribute("MaxSizeScale")
	local startScale = slime:GetAttribute("StartSizeScale")
	local progress   = slime:GetAttribute("GrowthProgress")
	if maxScale == nil or startScale == nil or progress == nil then return end

	local cache = initCacheIfNeeded(slime)

	if PendingOffline[slime] then
		PendingOffline[slime] = nil
		local delta = computeOfflineDelta(slime)
		if delta > 0 then
			applyOfflineGrowth(slime, delta, false)
		end
		finalizeOfflineStamp(slime, true, "deferred_offline")
		cache.offlineAppliedAt = os.time()
	end

	if CONFIG.OFFLINE_GROWTH_ENABLED and cache.offlineAppliedAt and not cache.reapplied then
		if (os.time() - cache.offlineAppliedAt) <= CONFIG.NON_REGRESS_SECOND_PASS_WINDOW then
			local floor = slime:GetAttribute("PersistedGrowthProgress")
			local gp2 = slime:GetAttribute("GrowthProgress") or 0
			if floor and gp2 < floor then
				logOffline(slime, "second_pass_floor", {from=gp2, to=floor})
				slime:SetAttribute("GrowthProgress", floor)
				cache.reapplied = true
				progress = floor
			end
		end
	end

	local prevProgress = progress
	local fb = slime:GetAttribute("FeedBufferSeconds") or 0
	local feedMult = slime:GetAttribute("FeedSpeedMultiplier") or 1
	local unfedDur = slime:GetAttribute("UnfedGrowthDuration") or 600
	if fb > 0 then
		fb = math.max(0, fb - dt)
		slime:SetAttribute("FeedBufferSeconds", fb)
	end
	local speedMult = (fb > 0 and feedMult or 1) * hungerMultiplier(slime)
	if progress < 1 and speedMult > 0 and unfedDur > 0 then
		progress = math.min(1, progress + (dt * speedMult) / unfedDur)
		if progress ~= prevProgress then
			slime:SetAttribute("GrowthProgress", progress)
			tryMicroProgressStamp(slime, progress, prevProgress)
		end
	end

	local eased = ease(progress)
	local targetScale = startScale + (maxScale - startScale) * eased
	local currentScale = slime:GetAttribute("CurrentSizeScale") or targetScale
	if math.abs(targetScale - currentScale) > CONFIG.RESIZE_EPSILON then
		applyScale(slime, targetScale)
		slime:SetAttribute("CurrentSizeScale", targetScale)
		cache.lastScale = targetScale
	end

	local vf = slime:GetAttribute("ValueFull")
	if vf then
		local valProg = CONFIG.USE_EASED_VALUE and eased or progress
		slime:SetAttribute("CurrentValue", vf * valProg)
	end

	if progress < 1 then
		local prevStep = math.floor(prevProgress / CONFIG.VALUE_STEP)
		local newStep  = math.floor(progress / CONFIG.VALUE_STEP)
		if newStep > prevStep then
			attemptMutationOnStep(slime)
		end
	else
		if not slime:GetAttribute("GrowthCompleted") then
			slime:SetAttribute("GrowthCompleted", true)
			dprint("Growth complete", slime:GetAttribute("SlimeId"))
		end
	end

	slime:SetAttribute("AgeSeconds", (slime:GetAttribute("AgeSeconds") or 0) + dt)

	if CONFIG.OFFLINE_GROWTH_ENABLED then
		local nowEpoch = os.time()
		local lastStamp = cache.lastStampUpdate or 0
		if nowEpoch - lastStamp >= CONFIG.GROWTH_TIMESTAMP_UPDATE_INTERVAL then
			slime:SetAttribute("LastGrowthUpdate", nowEpoch)
			writePersistedProgress(slime)
			cache.lastStampUpdate = nowEpoch
			logOffline(slime, "timestamp_update", {now=nowEpoch})
			markStampDirty(slime, "timestamp_update")
		else
			if CONFIG.OFFLINE_DEBUG then
				logOffline(slime, "timestamp_throttle_skip", {now=nowEpoch, last=lastStamp})
			end
		end
	end
end

----------------------------------------------------------------
-- ENUMERATION
----------------------------------------------------------------
local function enumerateSlimes()
	for s,_ in pairs(SlimeCache) do
		if not s.Parent then
			SlimeCache[s] = nil
			PendingOffline[s] = nil
		end
	end
	for _,inst in ipairs(Workspace:GetDescendants()) do
		if inst:IsA("Model") and inst.Name=="Slime" and inst:GetAttribute("GrowthProgress") ~= nil then
			if not SlimeCache[inst] then
				SlimeCache[inst] = { initialized=false }
				if CONFIG.OFFLINE_GROWTH_ENABLED then
					scheduleOfflineApply(inst)
				end
			end
		end
	end
end

----------------------------------------------------------------
-- LOOP
----------------------------------------------------------------
RunService.Heartbeat:Connect(function(dt)
	enumerateSlimes()
	for slime,_ in pairs(SlimeCache) do
		if slime.Parent then
			updateSlime(slime, dt)
		end
	end
end)

----------------------------------------------------------------
-- PUBLIC API
----------------------------------------------------------------
function GrowthService.GetManagedCount()
	local c=0; for _ in pairs(SlimeCache) do c+=1 end; return c
end

function GrowthService.DebugEnumerate()
	for slime,cache in pairs(SlimeCache) do
		local prog  = slime:GetAttribute("GrowthProgress") or -1
		local floor = slime:GetAttribute("PersistedGrowthProgress") or -1
		local scale = slime:GetAttribute("CurrentSizeScale") or -1
		print("[GrowthService][Managed]",
			slime:GetFullName(),
			string.format("Prog=%.4f Floor=%.4f Scale=%.3f Init=%s OfflineAt=%s",
				prog, floor, scale, tostring(cache.initialized),
				cache.offlineAppliedAt and os.date("%H:%M:%S", cache.offlineAppliedAt) or "nil"))
	end
end

function GrowthService.FlushPlayerSlimes(userId)
	for slime,_ in pairs(SlimeCache) do
		if slime.Parent and slime:GetAttribute("OwnerUserId") == userId then
			writePersistedProgress(slime)
			slime:SetAttribute("LastGrowthUpdate", os.time())
			markStampDirty(slime, "pre_leave_flush")
			if CONFIG.OFFLINE_DEBUG then
				logOffline(slime, "pre_leave_flush", {})
			end
		end
	end
end

return GrowthService