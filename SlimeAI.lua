-- SlimeAI.lua
-- Version: v1.3.3-fullfix-rp (Aug 2025)
-- Base: v1.3.3-fullfix with root promotion safeguard + orientation maintenance.
--
-- Additions in -rp:
--   * Root promotion: if Model.PrimaryPart is not the assembly root we promote root before AI starts
--     (defensive layer in case EggService missed a model).
--   * Orientation maintenance for Wander / Hungry (gated, cooldown) re-added so slimes face travel direction.
--   * Clear comments for where to disable ForceFirstHopAfterSeconds once verified.
--
-- Physics freeze cause (documented): Applying velocity to non-assembly-root (Inner) while Outer was real root.
-- Fix strategy: (1) EggService promotes root; (2) AI double-checks; (3) All per-frame CFrame writes removed except
-- gated, low-frequency PivotTo calls (clamp / orient / tilt / hop yaw).
--
-- Diagnostics:
--   LastPivotBy attribute set to one of:
--      SlimeAI-Clamp, SlimeAI-Orient, SlimeAI-IdleOrient, SlimeAI-HopYaw, SlimeAI-Tilt
--   LastHopAt attribute updated on hop launch.

local RunService = game:GetService("RunService")
local Players    = game:GetService("Players")
local Replicated = game:GetService("ReplicatedStorage")

local SlimeAI = {}
SlimeAI.__Version = "v1.3.3-fullfix-rp"
warn("[SlimeAI] SOURCE LOADED "..SlimeAI.__Version)

local ACTIVE = {} -- [Model] = data

--------------------------------------------------------------------------------
-- CONFIG
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
		ClampCooldown             = 0.40,
	},

	Debug                = false,
	HopDebug             = false,
	InstrumentGrounded   = true,

	ForceFirstHopAfterSeconds = nil, -- set to nil when satisfied hops work

	AssignNetworkToOwner = true,

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
-- Attribute helpers
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
-- Geometry
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
-- Transform gating
--------------------------------------------------------------------------------
local function canPivot(data, prim, now, purpose)
	if not data.GroundedNow then return false end
	if data.LastHopLaunchAt and (now - data.LastHopLaunchAt) < CONFIG.TransformGating.SkipAfterHopSeconds then return false end
	if math.abs(prim.AssemblyLinearVelocity.Y) > CONFIG.TransformGating.LowVerticalSpeedThreshold then return false end
	if purpose == "Clamp" then
		if data.LastClampAt and (now - data.LastClampAt) < CONFIG.TransformGating.ClampCooldown then return false end
	elseif purpose == "Orient" then
		if data.LastOrientAt and (now - data.LastOrientAt) < CONFIG.TransformGating.OrientationCooldown then return false end
	elseif purpose == "IdleFacing" then
		if data.LastIdleFacingAt and (now - data.LastIdleFacingAt) < CONFIG.TransformGating.IdleFacingCooldown then return false end
	elseif purpose == "Tilt" then
		if data.LastTiltAt and (now - data.LastTiltAt) < CONFIG.TransformGating.TiltCooldown then return false end
	end
	return true
end

local function doPivot(model, prim, targetCF, label)
	model:SetAttribute("LastPivotBy", label)
	model:PivotTo(targetCF)
end

--------------------------------------------------------------------------------
-- Clamp
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
	doPivot(data.Model, prim, makeFacingCF(pos, forward), "SlimeAI-Clamp")
	data.LastClampAt = now
end

--------------------------------------------------------------------------------
-- Orientation
--------------------------------------------------------------------------------
local function tryYawPivot(data, prim, desiredDir, now, label)
	if not desiredDir or desiredDir.Magnitude < 1e-4 then return end
	desiredDir = Vector3.new(desiredDir.X,0,desiredDir.Z).Unit
	local purpose = (label == "SlimeAI-IdleOrient") and "IdleFacing" or "Orient"
	if not canPivot(data, prim, now, purpose) then return end
	local current = getLogicalForward(prim.CFrame)
	if angleBetween(current, desiredDir) < CONFIG.MinAngularErrorToTurn then return end
	doPivot(data.Model, prim, makeFacingCF(prim.Position, desiredDir), label)
	if label == "SlimeAI-IdleOrient" then
		data.LastIdleFacingAt = now
	else
		data.LastOrientAt = now
	end
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
-- Tilt
--------------------------------------------------------------------------------
local function tiltCorrect(data, prim, now)
	if not canPivot(data, prim, now, "Tilt") then return end
	local up = prim.CFrame.UpVector
	local ang = math.deg(math.acos(math.clamp(up:Dot(Vector3.new(0,1,0)), -1,1)))
	if ang <= CONFIG.MaxTiltCorrectionDeg then return end
	local forward = getLogicalForward(prim.CFrame)
	local target = prim.CFrame:Lerp(makeFacingCF(prim.Position, forward), math.clamp(CONFIG.TiltCorrectionSpeed*(1/60),0,1))
	doPivot(data.Model, prim, target, "SlimeAI-Tilt")
	data.LastTiltAt = now
end

--------------------------------------------------------------------------------
-- Hop logic
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
		EndTime  = time() + data.RNG:NextNumber(CONFIG.HopPrepTimeRange[1], CONFIG.HopPrepTimeRange[2]),
		Micro    = opts.micro or false,
	}
end

local function updateHopPrep(data, prim, now)
	if not data.HopPrep then return end
	if now >= data.HopPrep.EndTime then
		if data.GroundedNow then
			tryYawPivot(data, prim, data.HopPrep.Dir, now, "SlimeAI-HopYaw")
		end
		applyHop(prim, data.HopPrep.Dir, data.HopPrep.HorizMag, data.HopPrep.VertMag)
		data.LastHopLaunchAt = now
		data.Model:SetAttribute("LastHopAt", now)
		if CONFIG.HopDebug then
			print(("[SlimeAI][HopDebug] id=%s H=%.2f V=%.2f dir=(%.2f,%.2f,%.2f)")
				:format(tostring(data.Model:GetAttribute("SlimeId")),
					data.HopPrep.HorizMag, data.HopPrep.VertMag,
					data.HopPrep.Dir.X, data.HopPrep.Dir.Y, data.HopPrep.Dir.Z))
		end
		data.LastLaunchPos = prim.Position
		data.HopPrep = nil
	end
end

--------------------------------------------------------------------------------
-- Heading coherence
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
-- State management
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
-- State update logic
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
-- Per-slime update
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

	updateHopPrep(data, prim, now)

	-- Landing
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

	-- Transforms
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