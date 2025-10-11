-- SlimeAI.lua
-- Version: v1.3.3-fullfix-rp (Aug 2025) - Smooth pivot + pre-hop crouch polish
-- NOTE: This file is your original SlimeAI with small, targeted visual-smoothing changes:
--   * SmoothPivot scheduling (doPivot now schedules an eased pivot rather than instant PivotTo)
--   * Pre-hop "crouch" animation during HopPrep to give anticipation to hops
-- All core physics behavior (AssemblyLinearVelocity hop), gating, and persistence remain unchanged.

local RunService = game:GetService("RunService")
local Players    = game:GetService("Players")
local Replicated = game:GetService("ReplicatedStorage")

local SlimeAI = {}
SlimeAI.__Version = "v1.3.3-fullfix-rp-smooth"
warn("[SlimeAI] SOURCE LOADED "..SlimeAI.__Version)

local ACTIVE = {} -- [Model] = data

--------------------------------------------------------------------------------
-- CONFIG (added SmoothPivotDuration & PreHopCrouchAmount)
--------------------------------------------------------------------------------
local CONFIG = {
	IdleMinTime                  = 4.0,
	IdleMaxTime                  = 8.0,
	WanderChanceFromIdle         = 0.30,
	WanderDurationRange          = {7, 13},

	HungryThreshold              = 0.55,
	HungryCloseEnough            = 10.0,
	HungryRetargetInterval       = 1.0,

	WanderHorizontalSpeedRange   = {3.8, 6.2},
	WanderVerticalSpeedRange     = {8.5, 11.5},
	HungryHorizontalSpeedRange   = {3.4, 5.4},
	HungryVerticalSpeedRange     = {8.2, 10.6},

	WanderHopIntervalRange       = {0.95, 1.25},
	HungryHopIntervalRange       = {0.90, 1.15},

	PathCoherenceHopCount        = 5,
	WanderJitterAngleDeg         = 6,
	RepathAngularThreshold       = 18,
	HeadingSmoothingAlpha        = 0.25,
	ForwardRetentionChance       = 0.55,

	HungryJitterAngleDeg          = 4,
	HungryHeadingSmoothingAlpha   = 0.12,
	HungryPathCoherenceHopCount   = 3,
	HungryRepathAngularThreshold  = 12,
	HungryForwardRetentionChance  = 0.30,

	HungryPredictLookAheadBase    = 0.28,
	HungryPredictLookAheadPerStud = 0.008,
	HungryMaxPredictLookAhead     = 0.8,
	HungryReducedPredictLookAhead = false,
	HungryMinRetargetDist         = 1.25,

	MaxTurnSpeedDegPerSec         = 220,
	HungryTurnSpeedDegPerSec      = 340,
	HungryTurnBoostAngle          = 50,
	HungryLargeAngleQuickHopDelay = {0.30, 0.50},
	HungryLargeAngleThreshold     = 35,

	HungryRevectorPrepAngle       = 8,
	HungryAirHardSteerPerSec      = 12.0,
	HungryGroundHardSteerPerSec   = 20.0,
	HungryAllowMidAirYaw          = true,
	HungryMidAirTurnScale         = 0.50,

	HungryContinuousChase         = false,
	HungryContinuousSpeedRange    = {10, 14},
	HungryContinuousTurnDegPerSec = 480,
	HungryContinuousTurnBoostAngle= 55,
	HungryContinuousAirControlPerSec = 10.0,
	HungryContinuousHopInterval   = {0.9, 1.4},
	HungryContinuousHopImpulse    = {6, 9},
	HungryContinuousYawLerpFactor = 14.0,

	HopPrepTimeRange              = {0.10, 0.16},

	MinimumHopDistance            = 5.0,
	AdaptiveDistanceGain          = 1.35,
	MaxAdaptiveHorizMag           = 10.0,
	HopHorizontalMinClamp         = 2.5,

	MinPredictedHorizontalDistanceWander = 7.0,
	MinPredictedHorizontalDistanceHungry = 7.5,
	MinHopFlightTimeThreshold            = 0.10,
	GravityOverride                      = nil,

	IdleFacingEnabled             = true,
	IdleMicroFacingIntervalRange  = {7, 13},
	IdleTurnAngleDegRange         = {25, 60},
	IdleCenterBiasChance          = 0.40,
	IdleMicroHopChance            = 0.012,
	IdleMicroHopYRange            = {1.3, 2.0},
	IdleMicroHorizontalMax        = 0.5,

	GravityRayLength              = 8,
	GroundedHeightFactor          = 0.75,
	MinGroundHeight               = 0.6,
	ClampZoneEdgeFactor           = 0.94,
	WanderRadiusFallback          = 40,

	HopDampingOnLand              = 0.55,
	MaxTiltCorrectionDeg          = 35,
	TiltCorrectionSpeed           = 6,

	ModelForwardYawOffsetDeg      = 180,
	MinAngularErrorToTurn         = 4.0,

	Splat = {
		Enabled                = true,
		ChancePerLanding       = 0.90,
		MinDistanceBetween     = 2.0,
		MaxPerSlimeActive      = 10,
		GlobalMaxActive        = 400,
		FadeTimeRange          = {6, 10},
		MinScaleBase           = 0.7,
		MaxScaleBase           = 1.4,
		ShrinkFraction         = 0.35,
		RayDown                = 16,
		SurfaceOffset          = 0.02,
		AlignToNormal          = true,
		ColorBlendAlpha        = 0.45,
		ColorSource            = "PrimaryPart",
		ReusePoolSize          = 120,
		PerSlimeCooldown       = 0.15,
		SizeExponent           = 0.55,
		MinSizeFactor          = 0.25,
		MaxSizeFactor          = 6.0,
		MinAbsoluteScale       = 0.25,
		MaxAbsoluteScale       = 6.0,
		RandomBiasPower        = 0.85,
		AnisotropyRange        = {0.85,1.15},
		Debug                  = false,
		DebugDetailed          = false,
	},

	ZoneClamp = {
		Enabled            = true,
		HorizontalThreshold= 0.18,
		CooldownSeconds    = 0.40,
		SkipAfterHopSeconds= 0.50,
		GroundOnly         = true,
		PreserveY          = true,
	},

	TransformGating = {
		LowVerticalSpeedThreshold = 0.5,
		SkipAfterHopSeconds       = 0.50,
		OrientationCooldown       = 0.25,
		IdleFacingCooldown        = 0.40,
		TiltCooldown              = 0.40,
		-- Added clamp cooldown so comparisons never hit nil
		ClampCooldown             = 0.40,
		-- Added: smooth pivot duration (how long to interpolate rotations)
		SmoothPivotDuration       = 0.12,
	},

	Debug                = false,
	HopDebug             = false,
	InstrumentGrounded   = true,

	ForceFirstHopAfterSeconds = nil, -- set to nil when satisfied hops work

	AssignNetworkToOwner = true,

	-- Visual polish params:
	-- How far (world studs) the model will "crouch" visually before hop (applied as a small pivot offset)
	PreHopCrouchAmount = 0.14, -- tuned small; multiplied by CurrentSizeScale
	-- How long smoothing pivots should take (can be overridden via TransformGating)
	SmoothPivotDuration = 0.12,

	DebugOverrides = {
		Enable = false,
		IdleMinTime = 0.6,
		IdleMaxTime = 1.2,
		WanderChanceFromIdle = 1.0,
		ForceFirstHopAfterSeconds = 1.0,
	},
}

if CONFIG.DebugOverrides.Enable then
	CONFIG.IdleMinTime              = CONFIG.DebugOverrides.IdleMinTime
	CONFIG.IdleMaxTime              = CONFIG.DebugOverrides.IdleMaxTime
	CONFIG.WanderChanceFromIdle     = CONFIG.DebugOverrides.WanderChanceFromIdle
	CONFIG.ForceFirstHopAfterSeconds= CONFIG.DebugOverrides.ForceFirstHopAfterSeconds
end

local OFFSET_RAD = math.rad(CONFIG.ModelForwardYawOffsetDeg)

--------------------------------------------------------------------------------
-- Logging
--------------------------------------------------------------------------------
local function dprint(...) if CONFIG.Debug then print("[SlimeAI]", ...) end end
local function sprint(...) if CONFIG.Splat.Debug then print("[SlimeSplat]", ...) end end

--------------------------------------------------------------------------------
-- Attribute helpers (unchanged)
--------------------------------------------------------------------------------
local function getFullness(model)
	local f = model:GetAttribute("FedFraction")
	if f == nil then f = model:GetAttribute("CurrentFullness") end
	return f and math.clamp(f,0,1) or 1
end

local function getOwnerCharacter(model)
	local uid = model:GetAttribute("OwnerUserId"); if not uid then return nil end
	local plr = Players:GetPlayerByUserId(uid)
	return plr and plr.Character or nil
end

local function getOwnerRootAndVelocity(model)
	local ch = getOwnerCharacter(model); if not ch then return nil end
	local hrp = ch:FindFirstChild("HumanoidRootPart"); if not hrp then return nil end
	return hrp, hrp.AssemblyLinearVelocity
end

--------------------------------------------------------------------------------
-- Geometry (unchanged)
--------------------------------------------------------------------------------
local function ensurePrimary(model)
	if model.PrimaryPart then return model.PrimaryPart end
	local p = model:FindFirstChildWhichIsA("BasePart")
	if p then model.PrimaryPart = p end
	return model.PrimaryPart
end

local function grounded(prim, model)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {model}
	local origin = prim.Position
	local result = workspace:Raycast(origin, Vector3.new(0,-CONFIG.GravityRayLength,0), params)
	if not result then
		if CONFIG.InstrumentGrounded then model:SetAttribute("AIIsGrounded", false) end
		return false
	end
	local effectiveHeight = math.max(prim.Size.Y, CONFIG.MinGroundHeight)
	local isG = (origin.Y - result.Position.Y) <= (effectiveHeight * CONFIG.GroundedHeightFactor)
	if CONFIG.InstrumentGrounded then model:SetAttribute("AIIsGrounded", isG) end
	return isG
end

local function clampToZone(pos, zonePart, spawnPos)
	if zonePart and zonePart.Parent then
		local half = zonePart.Size * 0.5 * CONFIG.ClampZoneEdgeFactor
		return Vector3.new(
			math.clamp(pos.X, zonePart.Position.X - half.X, zonePart.Position.X + half.X),
			pos.Y,
			math.clamp(pos.Z, zonePart.Position.Z - half.Z, zonePart.Position.Z + half.Z)
		)
	else
		local r = CONFIG.WanderRadiusFallback
		return Vector3.new(
			math.clamp(pos.X, spawnPos.X - r, spawnPos.X + r),
			pos.Y,
			math.clamp(pos.Z, spawnPos.Z - r, spawnPos.Z + r)
		)
	end
end

local function randomInZone(zonePart, spawnPos)
	if zonePart and zonePart.Parent then
		local half = zonePart.Size * 0.5 * CONFIG.ClampZoneEdgeFactor
		return zonePart.Position + Vector3.new(math.random(-half.X,half.X),0,math.random(-half.Z,half.Z))
	else
		local r = CONFIG.WanderRadiusFallback
		return spawnPos + Vector3.new(math.random(-r,r),0,math.random(-r,r))
	end
end

local function makeFacingCF(position, forward)
	forward = Vector3.new(forward.X,0,forward.Z)
	if forward.Magnitude < 1e-4 then forward = Vector3.new(0,0,-1) else forward = forward.Unit end
	local cf = CFrame.lookAt(position, position + forward, Vector3.new(0,1,0))
	if CONFIG.ModelForwardYawOffsetDeg ~= 0 then
		cf = cf * CFrame.Angles(0, OFFSET_RAD, 0)
	end
	return cf
end

local function getLogicalForward(cf)
	local f = cf.LookVector
	if CONFIG.ModelForwardYawOffsetDeg ~= 0 then
		f = (CFrame.fromAxisAngle(Vector3.new(0,1,0), -OFFSET_RAD) * f)
	end
	f = Vector3.new(f.X,0,f.Z)
	if f.Magnitude < 1e-4 then f = Vector3.new(0,0,-1) end
	return f.Unit
end

local function angleBetween(a,b)
	a=Vector3.new(a.X,0,a.Z); b=Vector3.new(b.X,0,b.Z)
	if a.Magnitude<1e-4 or b.Magnitude<1e-4 then return 0 end
	a=a.Unit; b=b.Unit
	return math.deg(math.acos(math.clamp(a:Dot(b), -1,1)))
end

--------------------------------------------------------------------------------
-- Transform gating (updated to account for pending smooth pivots and nil-safe)
--------------------------------------------------------------------------------
local function canPivot(data, prim, now, purpose)
	-- If there's a pending smooth pivot in progress, block new pivots
	if data.PendingSmoothPivot then return false end

	-- Must be grounded
	if not data.GroundedNow then return false end

	-- Use safe defaults if TransformGating fields are nil (protect against missing config edits)
	local tg = CONFIG.TransformGating or {}
	local skipAfterHop = tg.SkipAfterHopSeconds or 0.50
	local lowVertThresh = tg.LowVerticalSpeedThreshold or 0.5
	local clampCooldown = tg.ClampCooldown or (CONFIG.ZoneClamp and CONFIG.ZoneClamp.CooldownSeconds) or 0.4
	local orientCooldown = tg.OrientationCooldown or 0.25
	local idleFacingCooldown = tg.IdleFacingCooldown or 0.40
	local tiltCooldown = tg.TiltCooldown or 0.40

	-- Hop cooldown gating
	if data.LastHopLaunchAt and (now - data.LastHopLaunchAt) < skipAfterHop then return false end

	-- Vertical motion gating
	if math.abs(prim.AssemblyLinearVelocity.Y) > lowVertThresh then return false end

	-- Purpose-specific cooldown checks
	if purpose == "Clamp" then
		if data.LastClampAt and (now - data.LastClampAt) < clampCooldown then return false end
	elseif purpose == "Orient" then
		if data.LastOrientAt and (now - data.LastOrientAt) < orientCooldown then return false end
	elseif purpose == "IdleFacing" then
		if data.LastIdleFacingAt and (now - data.LastIdleFacingAt) < idleFacingCooldown then return false end
	elseif purpose == "Tilt" then
		if data.LastTiltAt and (now - data.LastTiltAt) < tiltCooldown then return false end
	end

	return true
end

-- Easing helpers
local function easeOutQuad(t) return 1 - (1 - t) * (1 - t) end
local function easeInOutSin(t) return 0.5 * (1 - math.cos(math.pi * t)) end

-- Do a scheduled, smooth pivot instead of an immediate snap.
local function scheduleSmoothPivot(data, fromCF, toCF, duration, label)
	data.PendingSmoothPivot = {
		From = fromCF,
		To = toCF,
		Start = time(),
		Duration = math.max(0.01, duration or CONFIG.SmoothPivotDuration),
		Label = label,
	}
	-- mark which subsystem requested pivot; LastPivotBy updated now for diagnostics
	data.Model:SetAttribute("LastPivotBy", label)
end

-- Convenience wrapper: replaced doPivot immediate with scheduled smooth pivot
local function doPivot(data, prim, targetCF, label)
	-- Build a current-from pivot that preserves current model pivot
	local ok, from = pcall(function() return data.Model:GetPivot() end)
	if not ok or not from then
		from = prim.CFrame
	end
	local dur = (CONFIG.TransformGating and CONFIG.TransformGating.SmoothPivotDuration) or CONFIG.SmoothPivotDuration
	scheduleSmoothPivot(data, from, targetCF, dur, label)
end

--------------------------------------------------------------------------------
-- When a pending smooth pivot is active, drive it here (called each update)
--------------------------------------------------------------------------------
local function processPendingSmoothPivot(data, prim, now)
	local pend = data.PendingSmoothPivot
	if not pend then return end
	local elapsed = now - pend.Start
	local t = math.clamp(elapsed / pend.Duration, 0, 1)
	local eased = easeOutQuad(t)
	local cf = pend.From:Lerp(pend.To, eased)
	-- Safe guarded single write per update to drive the interpolation
	local ok, err = pcall(function() data.Model:PivotTo(cf) end)
	if not ok then
		-- if pivot fails, clear to avoid infinite loop
		data.PendingSmoothPivot = nil
		return
	end
	if t >= 1 then
		-- finalize timestamp according to label semantics
		local lbl = pend.Label or ""
		if lbl == "SlimeAI-Clamp" then
			data.LastClampAt = now
		elseif lbl == "SlimeAI-IdleOrient" then
			data.LastIdleFacingAt = now
		elseif lbl == "SlimeAI-Tilt" then
			data.LastTiltAt = now
		else
			-- general orientation pivot
			data.LastOrientAt = now
		end
		-- clear pending
		data.PendingSmoothPivot = nil
	end
end

--------------------------------------------------------------------------------
-- Clamp (uses scheduleSmoothPivot via doPivot)
--------------------------------------------------------------------------------
local function guardedZoneClamp(data, prim, now)
	local zc = CONFIG.ZoneClamp
	if not zc.Enabled then return end
	if zc.GroundOnly and not data.GroundedNow then return end
	if not canPivot(data, prim, now, "Clamp") then return end
	local clamped = clampToZone(prim.Position, data.Zone, data.SpawnPosition)
	local delta = clamped - prim.Position
	local horizMag = Vector3.new(delta.X,0,delta.Z).Magnitude
	if horizMag < zc.HorizontalThreshold then return end
	local pos = zc.PreserveY and Vector3.new(clamped.X, prim.Position.Y, clamped.Z) or clamped
	local forward = getLogicalForward(prim.CFrame)
	-- schedule a smooth pivot to the clamped position + facing direction
	doPivot(data, prim, makeFacingCF(pos, forward), "SlimeAI-Clamp")
end

--------------------------------------------------------------------------------
-- Orientation (uses scheduleSmoothPivot via doPivot)
--------------------------------------------------------------------------------
local function tryYawPivot(data, prim, desiredDir, now, label)
	if not desiredDir or desiredDir.Magnitude < 1e-4 then return end
	desiredDir = Vector3.new(desiredDir.X,0,desiredDir.Z).Unit
	local purpose = (label == "SlimeAI-IdleOrient") and "IdleFacing" or "Orient"
	if not canPivot(data, prim, now, purpose) then return end
	local current = getLogicalForward(prim.CFrame)
	if angleBetween(current, desiredDir) < CONFIG.MinAngularErrorToTurn then return end
	-- schedule smooth pivot rather than instantaneous
	doPivot(data, prim, makeFacingCF(prim.Position, desiredDir), label)
end

local function orientationMaintenance(data, prim, now)
	if data.HopPrep then return end
	if data.State ~= "Wander" and data.State ~= "Hungry" then return end
	if not data.TargetPoint then return end
	local dir = data.TargetPoint - prim.Position
	dir = Vector3.new(dir.X,0,dir.Z)
	if dir.Magnitude < 1 then return end
	tryYawPivot(data, prim, dir, now, "SlimeAI-Orient")
end

--------------------------------------------------------------------------------
-- Tilt (unchanged except uses smooth pivot scheduling)
--------------------------------------------------------------------------------
local function tiltCorrect(data, prim, now)
	if not canPivot(data, prim, now, "Tilt") then return end
	local up = prim.CFrame.UpVector
	local ang = math.deg(math.acos(math.clamp(up:Dot(Vector3.new(0,1,0)), -1,1)))
	if ang <= CONFIG.MaxTiltCorrectionDeg then return end
	local forward = getLogicalForward(prim.CFrame)
	local target = prim.CFrame:Lerp(makeFacingCF(prim.Position, forward), math.clamp(CONFIG.TiltCorrectionSpeed*(1/60),0,1))
	-- Schedule a short smooth pivot for tilt correction
	scheduleSmoothPivot(data, data.Model:GetPivot(), target, CONFIG.TransformGating.TiltCooldown or 0.08, "SlimeAI-Tilt")
end

--------------------------------------------------------------------------------
-- Hop logic (added HopPrep.StartTime and pre-hop crouch animation)
--------------------------------------------------------------------------------
local function applyHop(prim, dir, horizMag, vertMag)
	prim.AssemblyLinearVelocity = dir * horizMag + Vector3.new(0, vertMag, 0)
end

local function scheduleHop(data, dir, horizMag, vertMag, opts)
	opts = opts or {}
	horizMag = math.max(horizMag, CONFIG.HopHorizontalMinClamp)
	if data.LastHopHorizontalDistance and data.LastHopHorizontalDistance < CONFIG.MinimumHopDistance then
		horizMag = math.min(horizMag * CONFIG.AdaptiveDistanceGain, CONFIG.MaxAdaptiveHorizMag)
	end
	if not opts.micro then
		local gravity = CONFIG.GravityOverride or workspace.Gravity
		if gravity > 0 then
			local flightTime = (2*vertMag)/gravity
			if flightTime >= CONFIG.MinHopFlightTimeThreshold then
				local predicted = horizMag * flightTime
				local targetMin = (data.State=="Hungry") and CONFIG.MinPredictedHorizontalDistanceHungry
					or CONFIG.MinPredictedHorizontalDistanceWander
				if predicted < targetMin then
					local need = targetMin / flightTime
					horizMag = math.min(math.max(need, horizMag, CONFIG.HopHorizontalMinClamp), CONFIG.MaxAdaptiveHorizMag)
				end
			end
		end
	end
	data.HopPrep = {
		Dir      = dir.Unit,
		HorizMag = horizMag,
		VertMag  = vertMag,
		StartTime= time(),
		EndTime  = time() + data.RNG:NextNumber(CONFIG.HopPrepTimeRange[1], CONFIG.HopPrepTimeRange[2]),
		Micro    = opts.micro or false,
	}
end

local function updateHopPrep(data, prim, now)
	if not data.HopPrep then return end
	-- Run pre-hop crouch visual: move model slightly down towards hop end then restore
	local hp = data.HopPrep
	local total = math.max(1e-3, hp.EndTime - hp.StartTime)
	local elapsed = math.clamp(now - hp.StartTime, 0, total)
	local t = elapsed / total
	-- crouch curve: easeIn then quick release at end (sin based)
	local crouchFactor = math.sin(math.min(1, math.max(0, t)) * math.pi)
	local scale = data.Model:GetAttribute("CurrentSizeScale") or 1
	local crouchAmount = (CONFIG.PreHopCrouchAmount or 0.12) * scale
	-- compute a crouch CF and perform a small pivot to make the model look like it's compressing
	local forward = hp.Dir or getLogicalForward(prim.CFrame)
	local crouchPos = prim.Position + Vector3.new(0, -crouchAmount * crouchFactor, 0)
	-- Apply a small, immediate pivot toward crouchCF but do so gently (lerp a portion)
	local crouchCF = makeFacingCF(crouchPos, forward)
	-- If a main smooth pivot is ongoing, let it run; else apply a light pivot toward crouchCF
	if not data.PendingSmoothPivot then
		-- small immediate lerp (1/3 of the way) to avoid abruptness from many writes
		local ok, cur = pcall(function() return data.Model:GetPivot() end)
		cur = (ok and cur) or crouchCF
		local lerpCF = cur:Lerp(crouchCF, math.clamp(0.34 * crouchFactor, 0, 1))
		pcall(function() data.Model:PivotTo(lerpCF) end)
	end

	-- When time to actually launch
	if now >= hp.EndTime then
		-- Try yaw pivot to orient the hop (still schedule smooth pivot if needed)
		if data.GroundedNow then
			tryYawPivot(data, prim, hp.Dir, now, "SlimeAI-HopYaw")
		end
		applyHop(prim, hp.Dir, hp.HorizMag, hp.VertMag)
		data.LastHopLaunchAt = now
		data.Model:SetAttribute("LastHopAt", now)
		if CONFIG.HopDebug then
			print(("[SlimeAI][Hop] id=%s H=%.2f V=%.2f dir=(%.2f,%.2f,%.2f)")
				:format(tostring(data.Model:GetAttribute("SlimeId")),
					hp.HorizMag, hp.VertMag,
					hp.Dir.X, hp.Dir.Y, hp.Dir.Z))
		end
		data.LastLaunchPos = prim.Position
		data.HopPrep = nil
	end
end

--------------------------------------------------------------------------------
-- Heading coherence (unchanged)
--------------------------------------------------------------------------------
local function blendDir(oldDir,newDir,alpha)
	if not oldDir then return newDir end
	oldDir = Vector3.new(oldDir.X,0,oldDir.Z)
	newDir = Vector3.new(newDir.X,0,newDir.Z)
	if oldDir.Magnitude < 1e-4 then oldDir = newDir end
	if newDir.Magnitude < 1e-4 then return oldDir end
	return (oldDir.Unit*(1-alpha) + newDir.Unit*alpha).Unit
end

local function maybeUpdateHeading(data, toTarget, jitterDeg, repathAng, smoothingAlpha, retentionChance, coherenceCount)
	local base = Vector3.new(toTarget.X,0,toTarget.Z)
	if base.Magnitude < 0.5 then
		return data.CoherentHeading or Vector3.new(1,0,0)
	end
	base = base.Unit
	if data.CoherentHeading then
		local diffAng = angleBetween(data.CoherentHeading, base)
		if diffAng < repathAng and data.RNG:NextNumber() < retentionChance then
			return data.CoherentHeading
		end
	end
	local jitter = math.rad(data.RNG:NextNumber(-jitterDeg, jitterDeg))
	local c,s = math.cos(jitter), math.sin(jitter)
	local x = base.X*c - base.Z*s
	local z = base.X*s + base.Z*c
	local proposed = Vector3.new(x,0,z).Unit
	if data.CoherentHeading then
		proposed = blendDir(data.CoherentHeading, proposed, smoothingAlpha)
	end
	data.CoherentHeading = proposed
	data.CoherentHopRemaining = coherenceCount - 1
	return proposed
end

local function getMoveDir(data, targetPos, params)
	if not data.Model.PrimaryPart then return Vector3.new(1,0,0) end
	local toTarget = targetPos - data.Model.PrimaryPart.Position
	toTarget = Vector3.new(toTarget.X,0,toTarget.Z)
	if not data.CoherentHeading or data.CoherentHopRemaining <= 0 then
		maybeUpdateHeading(
			data, toTarget,
			params.jitterDeg,
			params.repathAngularThreshold,
			params.smoothingAlpha,
			params.forwardRetention,
			params.coherenceCount
		)
	else
		data.CoherentHopRemaining -= 1
	end
	return data.CoherentHeading or Vector3.new(1,0,0)
end

--------------------------------------------------------------------------------
-- State management (unchanged)
--------------------------------------------------------------------------------
local function setState(data, newState)
	if data.State == newState then return end
	data.State = newState
	data.Model:SetAttribute("AIState", newState)
	if newState == "Idle" then
		data.NextDecisionAt = time() + data.RNG:NextNumber(CONFIG.IdleMinTime, CONFIG.IdleMaxTime)
		data.TargetPoint = nil
		data.CoherentHeading = nil
		data.CoherentHopRemaining = 0
		data.NextIdleFacingAt = CONFIG.IdleFacingEnabled
			and (time() + data.RNG:NextNumber(CONFIG.IdleMicroFacingIntervalRange[1], CONFIG.IdleMicroFacingIntervalRange[2]))
			or math.huge
	elseif newState == "Wander" then
		data.WanderEndTime = time() + data.RNG:NextNumber(CONFIG.WanderDurationRange[1], CONFIG.WanderDurationRange[2])
		data.TargetPoint = nil
		data.CoherentHeading = nil
		data.CoherentHopRemaining = 0
	elseif newState == "Hungry" then
		data.NextRetargetOwnerAt = 0
		data.TargetPoint = nil
		data.CoherentHeading = nil
		data.CoherentHopRemaining = 0
		data.NextContinuousHopAt = 0
	end
	data.HopPrep = nil
end

local function chooseIdleExit(data)
	if getFullness(data.Model) < CONFIG.HungryThreshold then
		return "Hungry"
	end
	if data.RNG:NextNumber() < CONFIG.WanderChanceFromIdle then
		return "Wander"
	end
	return "Idle"
end

--------------------------------------------------------------------------------
-- State update logic (unchanged aside from HopPrep -> updateHopPrep now calls pre-hop crouch)
--------------------------------------------------------------------------------
local function updateIdle(dt, data, prim, now)
	if CONFIG.IdleFacingEnabled and now >= (data.NextIdleFacingAt or 0) then
		data.NextIdleFacingAt = now + data.RNG:NextNumber(
			CONFIG.IdleMicroFacingIntervalRange[1],
			CONFIG.IdleMicroFacingIntervalRange[2]
		)
		local desiredDir
		if data.RNG:NextNumber() < CONFIG.IdleCenterBiasChance and data.Zone and data.Zone.Parent then
			desiredDir = data.Zone.Position - prim.Position
		else
			local yaw = math.rad(data.RNG:NextNumber(CONFIG.IdleTurnAngleDegRange[1], CONFIG.IdleTurnAngleDegRange[2]) *
				(data.RNG:NextNumber()<0.5 and -1 or 1))
			local baseF = getLogicalForward(prim.CFrame)
			local c,s = math.cos(yaw), math.sin(yaw)
			desiredDir = Vector3.new(baseF.X*c - baseF.Z*s,0, baseF.X*s + baseF.Z*c)
		end
		if desiredDir then
			tryYawPivot(data, prim, desiredDir, now, "SlimeAI-IdleOrient")
		end
	end

	if data.GroundedNow and data.RNG:NextNumber() < CONFIG.IdleMicroHopChance * dt then
		local dir = getLogicalForward(prim.CFrame)
		scheduleHop(data, dir, data.RNG:NextNumber(0, CONFIG.IdleMicroHorizontalMax),
			data.RNG:NextNumber(CONFIG.IdleMicroHopYRange[1], CONFIG.IdleMicroHopYRange[2]), {micro=true})
	end

	if now >= data.NextDecisionAt then
		setState(data, chooseIdleExit(data))
	end
end

local function updateWander(dt, data, prim, now)
	if not data.TargetPoint then
		data.TargetPoint = randomInZone(data.Zone, data.SpawnPosition)
		data.Model:SetAttribute("MovementTarget", data.TargetPoint)
	end
	if (prim.Position - data.TargetPoint).Magnitude <= 4 or now > data.WanderEndTime then
		setState(data,"Idle"); return
	end
	if data.GroundedNow and not data.HopPrep and (not data.NextHopAt or now >= data.NextHopAt) then
		local dir = getMoveDir(data, data.TargetPoint, {
			jitterDeg             = CONFIG.WanderJitterAngleDeg,
			repathAngularThreshold= CONFIG.RepathAngularThreshold,
			smoothingAlpha        = CONFIG.HeadingSmoothingAlpha,
			forwardRetention      = CONFIG.ForwardRetentionChance,
			coherenceCount        = CONFIG.PathCoherenceHopCount
		})
		scheduleHop(
			data,
			dir,
			data.RNG:NextNumber(CONFIG.WanderHorizontalSpeedRange[1], CONFIG.WanderHorizontalSpeedRange[2]) *
				(data.MovementScalar or 1)/(data.WeightScalar or 1),
			data.RNG:NextNumber(CONFIG.WanderVerticalSpeedRange[1], CONFIG.WanderVerticalSpeedRange[2]) /
				math.sqrt(data.WeightScalar or 1)
		)
		data.NextHopAt = now + data.RNG:NextNumber(CONFIG.WanderHopIntervalRange[1], CONFIG.WanderHopIntervalRange[2])
	end
end

local function hungryContinuousMove(dt, data, prim, now)
	if not data.TargetPoint then return end
	local to = data.TargetPoint - prim.Position
	if to.Magnitude < 0.5 then return end
	local desired = Vector3.new(to.X,0,to.Z).Unit
	local fwd = getLogicalForward(prim.CFrame)
	local blend = math.clamp(CONFIG.HungryContinuousYawLerpFactor * dt, 0, 1)
	local blended = (fwd*(1-blend) + desired*blend)
	if blended.Magnitude < 1e-4 then blended = desired end
	if canPivot(data, prim, now, "Orient") then
		tryYawPivot(data, prim, blended, now, "SlimeAI-Orient")
	end
	local vel = prim.AssemblyLinearVelocity
	local horiz = Vector3.new(vel.X,0,vel.Z)
	local targetSpeed = data.RNG:NextNumber(CONFIG.HungryContinuousSpeedRange[1], CONFIG.HungryContinuousSpeedRange[2]) *
		(data.MovementScalar or 1)/(data.WeightScalar or 1)
	if data.LastContinuousSpeed then targetSpeed = (targetSpeed + data.LastContinuousSpeed)*0.5 end
	data.LastContinuousSpeed = targetSpeed
	local targetHoriz = desired * targetSpeed
	local alpha = math.clamp((data.GroundedNow and 1 or CONFIG.HungryContinuousAirControlPerSec * dt), 0, 1)
	local newHoriz = horiz:Lerp(targetHoriz, alpha)
	prim.AssemblyLinearVelocity = Vector3.new(newHoriz.X, vel.Y, newHoriz.Z)
	if data.GroundedNow and now >= (data.NextContinuousHopAt or 0) then
		local yImpulse = data.RNG:NextNumber(CONFIG.HungryContinuousHopImpulse[1], CONFIG.HungryContinuousHopImpulse[2])
		local curV = prim.AssemblyLinearVelocity
		prim.AssemblyLinearVelocity = Vector3.new(curV.X, yImpulse, curV.Z)
		data.LastHopLaunchAt = now
		data.Model:SetAttribute("LastHopAt", now)
		data.NextContinuousHopAt = now + data.RNG:NextNumber(CONFIG.HungryContinuousHopInterval[1], CONFIG.HungryContinuousHopInterval[2])
	end
end

local function hungryHopMode(dt, data, prim, now)
	if data.GroundedNow and not data.HopPrep and (not data.NextHopAt or now >= data.NextHopAt) and data.TargetPoint then
		local dir = getMoveDir(data, data.TargetPoint, {
			jitterDeg             = CONFIG.HungryJitterAngleDeg,
			repathAngularThreshold= CONFIG.HungryRepathAngularThreshold,
			smoothingAlpha        = CONFIG.HungryHeadingSmoothingAlpha,
			forwardRetention      = CONFIG.HungryForwardRetentionChance,
			coherenceCount        = CONFIG.HungryPathCoherenceHopCount
		})
		scheduleHop(
			data,
			dir,
			data.RNG:NextNumber(CONFIG.HungryHorizontalSpeedRange[1], CONFIG.HungryHorizontalSpeedRange[2]) *
				(data.MovementScalar or 1)/(data.WeightScalar or 1),
			data.RNG:NextNumber(CONFIG.HungryVerticalSpeedRange[1], CONFIG.HungryVerticalSpeedRange[2]) /
				math.sqrt(data.WeightScalar or 1)
		)
		data.NextHopAt = now + data.RNG:NextNumber(CONFIG.HungryHopIntervalRange[1], CONFIG.HungryHopIntervalRange[2])

		local logicalForward = getLogicalForward(prim.CFrame)
		local angErr = angleBetween(logicalForward, dir)
		if angErr >= CONFIG.HungryLargeAngleThreshold then
			local qMin,qMax = table.unpack(CONFIG.HungryLargeAngleQuickHopDelay)
			data.NextHopAt = math.min(data.NextHopAt, now + data.RNG:NextNumber(qMin,qMax))
		end
	end

	-- Mid-air steering
	if not data.GroundedNow and data.TargetPoint then
		local vel = prim.AssemblyLinearVelocity
		local horiz = Vector3.new(vel.X,0,vel.Z)
		local speed = horiz.Magnitude
		if speed > 0.1 then
			local to = Vector3.new(data.TargetPoint.X - prim.Position.X, 0, data.TargetPoint.Z - prim.Position.Z)
			if to.Magnitude > 0.5 then
				local desired = to.Unit
				local blend = math.clamp(CONFIG.HungryAirHardSteerPerSec * dt, 0, 1)
				local newHoriz = (horiz.Unit*(1-blend) + desired*blend)
				if newHoriz.Magnitude > 1e-4 then
					newHoriz = newHoriz.Unit * speed
					prim.AssemblyLinearVelocity = Vector3.new(newHoriz.X, vel.Y, newHoriz.Z)
				end
			end
		end
	end
end

local function updateHungry(dt, data, prim, now)
	if getFullness(data.Model) >= CONFIG.HungryThreshold then
		setState(data,"Idle"); return
	end
	if now >= (data.NextRetargetOwnerAt or 0) then
		local hrp, vel = getOwnerRootAndVelocity(data.Model)
		if hrp then
			local dist = (hrp.Position - prim.Position).Magnitude
			if (not data.TargetPoint) or (hrp.Position - data.TargetPoint).Magnitude >= CONFIG.HungryMinRetargetDist then
				if CONFIG.HungryReducedPredictLookAhead or not vel then
					data.TargetPoint = hrp.Position
				else
					local lookAhead = CONFIG.HungryPredictLookAheadBase
						+ math.min(dist * CONFIG.HungryPredictLookAheadPerStud, CONFIG.HungryMaxPredictLookAhead)
					data.TargetPoint = hrp.Position + vel * lookAhead
				end
				data.Model:SetAttribute("MovementTarget", data.TargetPoint)
			end
		else
			setState(data,"Idle"); return
		end
		data.NextRetargetOwnerAt = now + CONFIG.HungryRetargetInterval
	end
	if data.TargetPoint and (prim.Position - data.TargetPoint).Magnitude <= CONFIG.HungryCloseEnough then
		setState(data,"Idle"); return
	end

	if CONFIG.HungryContinuousChase then
		hungryContinuousMove(dt, data, prim, now)
	else
		hungryHopMode(dt, data, prim, now)
	end
end

--------------------------------------------------------------------------------
-- Splats (unchanged)
--------------------------------------------------------------------------------
local SplatRuntime = { AssetParts={}, Pool={}, Active={}, GlobalActiveCount=0, Initialized=false }

local function hexToColor3(hex)
	if typeof(hex) == "Color3" then return hex end
	if not hex then return Color3.fromRGB(140,255,140) end
	hex = tostring(hex)
	if #hex < 6 then return Color3.fromRGB(140,255,140) end
	local r = tonumber(hex:sub(1,2),16) or 140
	local g = tonumber(hex:sub(3,4),16) or 255
	local b = tonumber(hex:sub(5,6),16) or 140
	return Color3.fromRGB(r,g,b)
end

local function initSplats()
	if SplatRuntime.Initialized or not CONFIG.Splat.Enabled then return end
	local assets = Replicated:FindFirstChild("Assets"); if not assets then return end
	local root = assets:FindFirstChild("SlimeSlop"); if not root then return end
	local modelFolder = root:FindFirstChild("Model"); if not modelFolder then return end
	for _,child in ipairs(modelFolder:GetChildren()) do
		if child:IsA("BasePart") or child:IsA("Model") then
			table.insert(SplatRuntime.AssetParts, child)
		end
	end
	SplatRuntime.Initialized = true
	sprint("Splat assets:", #SplatRuntime.AssetParts)
end

local function pickSplatAsset()
	if #SplatRuntime.AssetParts == 0 then return nil end
	return SplatRuntime.AssetParts[math.random(1,#SplatRuntime.AssetParts)]
end

local function obtainSplatClone()
	local inst = table.remove(SplatRuntime.Pool)
	if inst and inst.Parent == nil then return inst end
	local asset = pickSplatAsset()
	return asset and asset:Clone() or nil
end

local function recycleSplat(rec)
	local inst = rec.Instance
	local owner = rec.OwnerData
	if owner and owner.SplatActiveCount then
		owner.SplatActiveCount = math.max(owner.SplatActiveCount - 1, 0)
	end
	if not inst then return end
	if #SplatRuntime.Pool < CONFIG.Splat.ReusePoolSize then
		inst.Parent = nil
		table.insert(SplatRuntime.Pool, inst)
	else
		inst:Destroy()
	end
end

local function updateActiveSplats(now, dt)
	if not CONFIG.Splat.Enabled then return end
	local i = 1
	while i <= #SplatRuntime.Active do
		local rec = SplatRuntime.Active[i]
		local inst = rec.Instance
		if not inst or not inst.Parent then
			recycleSplat(rec)
			table.remove(SplatRuntime.Active, i)
			SplatRuntime.GlobalActiveCount -= 1
		else
			local alpha = (now - rec.Start)/(rec.End - rec.Start)
			if alpha >= 1 then
				recycleSplat(rec)
				table.remove(SplatRuntime.Active, i)
				SplatRuntime.GlobalActiveCount -= 1
			else
				alpha = math.clamp(alpha,0,1)
				local newSize = rec.StartSize:Lerp(rec.EndSize, alpha)
				if rec.ApplySize and inst:IsA("BasePart") then
					inst.Size = newSize
				end
				if inst:IsA("BasePart") then
					inst.Transparency = alpha
				else
					for _,p in ipairs(inst:GetDescendants()) do
						if p:IsA("BasePart") then p.Transparency = alpha end
					end
				end
				i += 1
			end
		end
	end
end

local function computeSplatSizeFactor(data)
	local S = CONFIG.Splat
	local startScale = data.Model:GetAttribute("StartSizeScale") or 1
	local currentScale= data.Model:GetAttribute("CurrentSizeScale") or startScale
	if startScale <= 0 then startScale = 1 end
	local growthRatio = currentScale / startScale
	local sized = growthRatio ^ (S.SizeExponent or 1)
	sized = math.clamp(sized, S.MinSizeFactor, S.MaxSizeFactor)
	return sized, growthRatio
end

local function getSplatBaseColor(data, prim)
	local S=CONFIG.Splat
	if S.ColorSource == "PrimaryPart" and prim then
		return prim.Color
	elseif S.ColorSource == "AttributeAccent" then
		return hexToColor3(data.Model:GetAttribute("AccentColor"))
	else
		return hexToColor3(data.Model:GetAttribute("BodyColor"))
	end
end

local function placeSplat(data, prim)
	local S=CONFIG.Splat
	if not S.Enabled then return end
	if SplatRuntime.GlobalActiveCount >= S.GlobalMaxActive then return end
	if not prim then return end
	local now = time()
	if data.LastSplatAt and (now - data.LastSplatAt) < S.PerSlimeCooldown then return end
	if data.SplatActiveCount and data.SplatActiveCount >= S.MaxPerSlimeActive then return end
	if data.LastSplatPos and (prim.Position - data.LastSplatPos).Magnitude < S.MinDistanceBetween then return end
	if math.random() > S.ChancePerLanding then return end

	initSplats(); if not SplatRuntime.Initialized then return end
	local clone = obtainSplatClone(); if not clone then return end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { data.Model }

	local result = workspace:Raycast(prim.Position, Vector3.new(0,-S.RayDown,0), params)
	local pos = prim.Position - Vector3.new(0,prim.Size.Y*0.5,0)
	local normal = Vector3.new(0,1,0)
	if result then
		pos = result.Position + result.Normal * S.SurfaceOffset
		normal = result.Normal
	end

	local forward = getLogicalForward(prim.CFrame)
	if math.abs(forward:Dot(normal)) > 0.95 then
		local ang = math.rad(math.random(0,359))
		forward = Vector3.new(math.cos(ang),0,math.sin(ang))
	end

	if S.AlignToNormal then
		local right = forward:Cross(normal).Unit
		forward = normal:Cross(right).Unit
		local cf = CFrame.fromMatrix(pos, right, normal)
		if clone:IsA("BasePart") then clone.CFrame = cf else clone:PivotTo(cf) end
	else
		if clone:IsA("BasePart") then clone.CFrame = CFrame.new(pos) else clone:PivotTo(CFrame.new(pos)) end
	end

	local baseColor = getSplatBaseColor(data, prim)
	local function tint(part)
		if not part:IsA("BasePart") then return end
		part.Anchored=false
		part.CanCollide=false
		part.CanTouch=false
		part.CanQuery=false
		part.Color = part.Color:Lerp(baseColor, S.ColorBlendAlpha)
	end
	if clone:IsA("BasePart") then
		tint(clone)
	else
		for _,p in ipairs(clone:GetDescendants()) do tint(p) end
	end

	local sizeFactor, growthRatio = computeSplatSizeFactor(data)
	local u = math.random()
	local biased = u ^ (S.RandomBiasPower or 1)
	local dynamicMin = S.MinScaleBase * sizeFactor
	local dynamicMax = S.MaxScaleBase * sizeFactor
	if dynamicMax < dynamicMin then dynamicMax = dynamicMin end
	local rawScale = dynamicMin + (dynamicMax - dynamicMin)*biased
	rawScale = math.clamp(rawScale, S.MinAbsoluteScale, S.MaxAbsoluteScale)

	local arMin, arMax = S.AnisotropyRange[1], S.AnisotropyRange[2]
	local stretchX = math.random()*(arMax - arMin)+arMin
	local stretchZ = math.random()*(arMax - arMin)+arMin

	local baseSize
	if clone:IsA("BasePart") then
		baseSize = clone.Size
	else
		local _,bbSize = clone:GetBoundingBox()
		baseSize = bbSize
	end
	if baseSize.Magnitude <= 0 then baseSize = Vector3.new(3,0.3,3) end

	local startSize = Vector3.new(
		baseSize.X * rawScale * stretchX,
		baseSize.Y * rawScale,
		baseSize.Z * rawScale * stretchZ
	)
	local endSize = startSize * S.ShrinkFraction

	local applySize = false
	if clone:IsA("BasePart") then
		clone.Size = startSize
		applySize = true
	end

	local randomYaw = math.rad(math.random(0,359))
	if clone:IsA("BasePart") then
		clone.CFrame = clone.CFrame * CFrame.Angles(0, randomYaw, 0)
	else
		clone:PivotTo(clone:GetPivot() * CFrame.Angles(0, randomYaw, 0))
	end

	clone.Parent = workspace

	local fadeTime = math.random()*(S.FadeTimeRange[2]-S.FadeTimeRange[1]) + S.FadeTimeRange[1]
	table.insert(SplatRuntime.Active, {
		Instance = clone,
		Start = now,
		End   = now + fadeTime,
		StartSize = startSize,
		EndSize   = endSize,
		ApplySize = applySize,
		OwnerData = data,
	})
	SplatRuntime.GlobalActiveCount += 1
	data.LastSplatPos = pos
	data.LastSplatAt  = now
	data.SplatActiveCount = (data.SplatActiveCount or 0) + 1

	if CONFIG.Splat.Debug then
		sprint(("Splat growthRatio=%.3f sizeFactor=%.3f rawScale=%.3f active=%d/%d")
			:format(growthRatio, sizeFactor, rawScale, data.SplatActiveCount, CONFIG.Splat.MaxPerSlimeActive))
	end
end

--------------------------------------------------------------------------------
-- Per-slime update (now processes PendingSmoothPivot and HopPrep pre-crouch)
--------------------------------------------------------------------------------
local function perSlimeUpdate(dt, data)
	local model = data.Model
	if not model.Parent then ACTIVE[model] = nil return end
	local prim = ensurePrimary(model)
	if not prim then ACTIVE[model] = nil return end

	local now = time()
	data.GroundedNow = grounded(prim, model)

	-- Forced first hop (debug)
	if CONFIG.ForceFirstHopAfterSeconds and not data.ForcedHopDone then
		if (now - data.StartedAt) >= CONFIG.ForceFirstHopAfterSeconds then
			data.ForcedHopDone = true
			local dir = getLogicalForward(prim.CFrame)
			scheduleHop(data, dir, 5, 10)
		end
	end

	-- First: process any pending smooth pivot (interpolated rotation/position)
	processPendingSmoothPivot(data, prim, now)

	-- Next: handle HopPrep (pre-hop crouch + actual apply when EndTime reached)
	updateHopPrep(data, prim, now)

	-- Landing handling
	updateHopPrep(data, prim, now) -- ensure we checked (harmless if not present)

	if data.GroundedNow then
		if data.WasAir and data.LastLaunchPos then
			local dv = prim.Position - data.LastLaunchPos
			data.LastHopHorizontalDistance = Vector3.new(dv.X,0,dv.Z).Magnitude
			placeSplat(data, prim)
			local v = prim.AssemblyLinearVelocity
			prim.AssemblyLinearVelocity = Vector3.new(v.X*CONFIG.HopDampingOnLand, v.Y, v.Z*CONFIG.HopDampingOnLand)
		end
		data.WasAir = false
	else
		data.WasAir = true
	end

	-- State logic
	if data.State == "Idle" then
		updateIdle(dt, data, prim, now)
	elseif data.State == "Wander" then
		updateWander(dt, data, prim, now)
	elseif data.State == "Hungry" then
		updateHungry(dt, data, prim, now)
	else
		setState(data,"Idle")
	end

	-- Orientation maintenance (low frequency)
	orientationMaintenance(data, prim, now)

	-- Transforms / corrections (clamp/tilt) - they schedule smooth pivots now
	guardedZoneClamp(data, prim, now)
	tiltCorrect(data, prim, now)
end

--------------------------------------------------------------------------------
-- Heartbeat
--------------------------------------------------------------------------------
RunService.Heartbeat:Connect(function(dt)
	local now = time()
	for _,data in pairs(ACTIVE) do
		perSlimeUpdate(dt, data)
	end
	updateActiveSplats(now, dt)
end)

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------
function SlimeAI.Start(model, zonePart, spawnOverride)
	local prim = ensurePrimary(model)
	if not prim then
		warn("[SlimeAI] Cannot start; no primary part.")
		return
	end

	-- Root promotion safeguard (EggService should have done this)
	local root = prim.AssemblyRootPart
	if root and root ~= prim then
		warn(string.format("[SlimeAI] PrimaryPart %s not assembly root %s; promoting root.", prim.Name, root.Name))
		model.PrimaryPart = root
		prim = root
	end

	-- Unanchor
	for _,p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then p.Anchored = false end
	end

	-- Ownership
	if CONFIG.AssignNetworkToOwner then
		local uid = model:GetAttribute("OwnerUserId")
		local plr = uid and Players:GetPlayerByUserId(uid)
		pcall(function() prim:SetNetworkOwner(plr or nil) end)
	else
		pcall(function() prim:SetNetworkOwner(nil) end)
	end

	local function coerceSpawnPosition(value)
		if value == nil then return nil end
		local valueType = typeof(value)
		if valueType == "CFrame" then
			return value.Position
		elseif valueType == "Vector3" then
			return value
		elseif valueType == "Instance" then
			local ok, pos = pcall(function()
				if value:IsA("BasePart") then
					return value.Position
				end
				return nil
			end)
			if ok then return pos end
		elseif valueType == "table" then
			local ok, pos = pcall(function()
				if value.Position then return value.Position end
				if value.x and value.y and value.z then return Vector3.new(value.x, value.y, value.z) end
				if value.X and value.Y and value.Z then return Vector3.new(value.X, value.Y, value.Z) end
				return nil
			end)
			if ok then return pos end
		end
		return nil
	end

	local function isFiniteVector(vec)
		if typeof(vec) ~= "Vector3" then return false end
		if vec.X ~= vec.X or vec.Y ~= vec.Y or vec.Z ~= vec.Z then return false end
		if math.abs(vec.X) == math.huge or math.abs(vec.Y) == math.huge or math.abs(vec.Z) == math.huge then return false end
		return true
	end

	local spawnPosition = coerceSpawnPosition(spawnOverride)
	if spawnPosition == nil then
		local attr = model:GetAttribute("SpawnPosition")
		spawnPosition = coerceSpawnPosition(attr)
	end
	if spawnPosition == nil then
		spawnPosition = prim.Position
	elseif not isFiniteVector(spawnPosition) then
		spawnPosition = prim.Position
	end
	model:SetAttribute("SpawnPosition", spawnPosition)
	if typeof(zonePart) == "Instance" and zonePart:IsA("BasePart") then
		pcall(function()
			model:SetAttribute("ClampZoneName", zonePart:GetFullName())
		end)
	end

	ACTIVE[model] = {
		Model = model,
		Zone  = zonePart,
		RNG   = Random.new(math.floor(os.clock()*1e6)%1e6),
		State = "Idle",
		SpawnPosition = spawnPosition,
		StartedAt = time(),
		NextDecisionAt = time() + math.random(CONFIG.IdleMinTime*1000, CONFIG.IdleMaxTime*1000)/1000,
		SplatActiveCount = 0,
	}

	model:SetAttribute("AIState","Idle")
	model:SetAttribute("MovementTarget", Vector3.zero)
	warn("[SlimeAI] Start called for slimeId="..tostring(model:GetAttribute("SlimeId")))
end

return SlimeAI