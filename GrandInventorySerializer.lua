-- GrandInventorySerializer.lua
-- Now routes all persistence through PlayerProfileService

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace           = game:GetService("Workspace")
local RunService          = game:GetService("RunService")
local HttpService         = game:GetService("HttpService")
local ServerStorage       = game:GetService("ServerStorage")

local PlayerProfileService = require(ServerScriptService.Modules:WaitForChild("PlayerProfileService"))

local GrandInventorySerializer = {}

-- Unified config
GrandInventorySerializer.CONFIG = {
	Debug = true,
	WorldSlime = {
		MaxWorldSlimesPerPlayer  = 60,
		UseLocalCoords           = true,
		DedupeOnSerialize        = true,
		DedupeOnRestore          = true,
		SkipSecondPassIfComplete = true,
		MarkWorldSlimeAttribute  = true,
	},
	WorldEgg = {
		MaxWorldEggsPerPlayer = 60,
		UseLocalCoords = true,
		OfflineEggProgress = true,
		TemplateFolders = { "Assets", "EggTemplates", "WorldEggs" },
		DefaultTemplateName = "Egg",
		RestoreEggsReady = false,
		AcceptMissingManualHatchGraceSeconds = 10,
		AutoCaptureOnEggPlacement = true,
	},
	FoodTool = {
		MaxFood                  = 120,
		TemplateFolders          = { "FoodTemplates", "Assets", "InventoryTemplates" },
		FallbackHandleSize       = Vector3.new(1,1,1),
		InstrumentLifeCycle      = true,
		LifeCycleWatchSeconds    = 60, -- Increase to 60 seconds for debugging
		FastAuditDelay           = 0.30,
		PostRestoreAuditDelay    = 0.85,
		EnablePostRestoreAudit   = true,
		EnableRebuildOnMissing   = true,
		RequireStableHeartbeats  = true,
		StableHeartbeatCount     = 6,
		AggregationMode          = "individual",
	},
	EggTool = {
		MaxEggTools                  = 60,
		TemplateFolder               = "ToolTemplates",
		TemplateName                 = "EggToolTemplate",
		FallbackHandleSize           = Vector3.new(1,1,1),
		InstrumentLifeCycle          = true,
		LifeCycleWatchSeconds        = 5,
		AssignUidIfMissingOnSerialize= true,
		AssignUidIfMissingOnRestore  = true,
		LogAssignedUids              = true,
		RepairAfterRestore           = true,
		RepairLogEach                = true,
	},
	CapturedSlime = {
		MaxStored              = 120,
		TemplateFolder         = "ToolTemplates",
		TemplateNameCaptured   = "CapturedSlimeTool",
		DeduplicateOnRestore   = true,
		RequireStableHeartbeats= true,
		StableHeartbeatCount   = 6,
		LifeCycleWatchSeconds  = 5,
		PostRestoreAuditDelay  = 0.85,
		EnablePostRestoreAudit = true,
		EnableRebuildOnMissing = true,
	},
}

local function dprint(...)
	if GrandInventorySerializer.CONFIG.Debug then print("[GrandInvSer]", ...) end
end

local clock = tick

local DebugFlags = require(ServerScriptService.Modules:WaitForChild("DebugFlags"))

local function eggdbg(...)
	if DebugFlags and DebugFlags.EggDebug then
		print("[EggDbg][GrandInvSer]", ...)
	end
end

local we_lastSnapshot = {}

-------------------------------------------------------------------------------
-- WorldSlime Serializer
-------------------------------------------------------------------------------
local WSCONFIG = GrandInventorySerializer.CONFIG.WorldSlime
local WS_ATTR_MAP = {
	GrowthProgress="gp", ValueFull="vf", CurrentValue="cv", ValueBase="vb",
	ValuePerGrowth="vg", MutationStage="ms", Tier="ti", FedFraction="ff",
	CurrentSizeScale="sz", BodyColor="bc", AccentColor="ac", EyeColor="ec",
	MovementScalar="mv", WeightScalar="ws", MutationRarityBonus="mb", WeightPounds="wt",
	MaxSizeScale="mx", StartSizeScale="st", SizeLuckRolls="lr",
	FeedBufferSeconds="fb", FeedBufferMax="fx", HungerDecayRate="hd",
	CurrentFullness="cf", FeedSpeedMultiplier="fs", LastHungerUpdate="lu",
	LastGrowthUpdate="lg", OfflineGrowthApplied="og", AgeSeconds="ag",
	PersistedGrowthProgress="pgf",
}
local colorKeys = { bc=true, ac=true, ec=true }
local ws_liveIndex = {}
local ws_restoredOnce = {}

-- Forward-declare staging constant early so static analyzers see it before use
local RESTORE_STAGE_DELAY = 1.2  -- was 0.6

-- ORIGINAL FILE HAD DUPLICATE RESTORE_GRACE / CACHE DECLS HERE.
-- Replace with a single canonical declaration and a safe profile helper.

local RESTORE_GRACE_SECONDS = 12

-- caches used to protect against race between Restore and periodic Serialize
local _restoreGrace = {}                -- keyed by userId => tick() when restore started
local _lastRestoredInventory = {}       -- keyed by userId => snapshot table

-- Helper: safely obtain profile from PlayerProfileService without throwing
local function safe_get_profile(player)
	if not PlayerProfileService then return nil end
	if not player then return nil end
	if not player.Parent and not player.UserId then
		dprint("[safe_get_profile] Player object has no Parent and no UserId, skipping profile lookup for:", tostring(player.Name or player))
		return
	end

	local function try(fn, desc)
		local ok, res = pcall(fn)
		if not ok then
			dprint(("[safe_get_profile] candidate '%s' call FAILED: %s"):format(tostring(desc), tostring(res)))
			return nil
		end
		if type(res) == "table" then
			dprint(("[safe_get_profile] candidate '%s' succeeded (profile table)"):format(tostring(desc)))
			return res
		end
		dprint(("[safe_get_profile] candidate '%s' returned %s (not a profile)"):format(tostring(desc), tostring(type(res))))
		return nil
	end

	local candidates = {}

	-- Prefer numeric userId if available (call as function and as method)
	if player and player.UserId then
		table.insert(candidates, { fn = function() return PlayerProfileService.GetProfile(player.UserId) end, desc = "GetProfile(userId) (no self)" })
		table.insert(candidates, { fn = function() return PlayerProfileService.GetProfile(tostring(player.UserId)) end, desc = "GetProfile(tostring(userId)) (no self)" })
		table.insert(candidates, { fn = function() return PlayerProfileService:GetProfile(player.UserId) end, desc = "GetProfile(userId) (colon)" })
	end

	-- Fallbacks: try passing player object/name/string forms (no service self)
	table.insert(candidates, { fn = function() return PlayerProfileService.GetProfile(player) end, desc = "GetProfile(player) (no self)" })
	table.insert(candidates, { fn = function() return PlayerProfileService.GetProfile(tostring(player)) end, desc = "GetProfile(tostring(player)) (no self)" })
	if player and player.Name then
		table.insert(candidates, { fn = function() return PlayerProfileService.GetProfile(player.Name) end, desc = "GetProfile(player.Name) (no self)" })
		table.insert(candidates, { fn = function() return PlayerProfileService:GetProfile(player.Name) end, desc = "GetProfile(player.Name) (colon)" })
	end

	for _, candidate in ipairs(candidates) do
		local prof = try(candidate.fn, candidate.desc)
		if prof then return prof end
	end

	dprint("[safe_get_profile] No profile found for:", tostring(player and (player.Name or player.UserId) or "nil"))
	return nil
end

-- NEW: find existing tool by UID in Backpack/Character/ServerStorage to avoid duplicate restores
local function find_existing_tool_by_uid(player, uid)
	if not player or not uid then return nil end
	local function checkContainer(container)
		if not container then return nil end
		for _, item in ipairs(container:GetChildren()) do
			if item:IsA("Tool") then
				local tid = item:GetAttribute("ToolUniqueId") or item:GetAttribute("ToolUid") or item:GetAttribute("uid")
				if tid and tostring(tid) == tostring(uid) then
					return item
				end
			end
		end
		return nil
	end

	-- Check Backpack and Character
	local bp = player:FindFirstChildOfClass("Backpack")
	local found = checkContainer(bp) or checkContainer(player.Character)
	if found then return found end

	-- Check staged/restored tools in ServerStorage (descendants)
	for _, inst in ipairs(ServerStorage:GetDescendants()) do
		if inst:IsA("Tool") then
			local tid = inst:GetAttribute("ToolUniqueId") or inst:GetAttribute("ToolUid") or inst:GetAttribute("uid")
			local owner = inst:GetAttribute("OwnerUserId")
			if tid and tostring(tid) == tostring(uid) then
				return inst
			end
			-- also allow matching tools by owner+no-uid (defensive)
			if owner and tostring(owner) == tostring(player.UserId) and tid == nil then
				return inst
			end
		end
	end

	return nil
end

-- Helper: quick check for any live inventory (purchased/collected) to avoid returning cached
-- restore snapshot if the player already has new tools/items.
local function _hasLiveInventory(player)
	-- legacy check: any qualifying tool in Backpack/Character counts as live inventory
	if not player then return false end
	local function checkContainer(container)
		if not container then return false end
		for _,c in ipairs(container:GetChildren()) do
			if ft_qualifies and ft_qualifies(c) then return true end
			if c:IsA("Tool") and (c:GetAttribute("EggId") or c:GetAttribute("ServerIssued")) then return true end
			if c:IsA("Tool") and c:GetAttribute("SlimeItem") then return true end
		end
		return false
	end
	if checkContainer(player:FindFirstChildOfClass("Backpack")) then return true end
	if player.Character and checkContainer(player.Character) then return true end

	-- Also consider staged server-side tools that were built during Restore (present in ServerStorage)
	-- Tools staged there will typically carry ServerRestore/ServerIssued/PreserveOnServer and OwnerUserId.
	-- Presence of staged tools should NOT be treated as a "post-restore live change" (we handle that separately),
	-- but this function retains a broader meaning (live inventory anywhere).
	for _,inst in ipairs(ServerStorage:GetDescendants()) do
		if inst:IsA("Tool") then
			local owner = inst:GetAttribute("OwnerUserId")
			if owner and tostring(owner) == tostring(player.UserId) then
				return true
			end
		end
	end
	return false
end

-- Detect explicit post-restore live changes (purchases / player-acquired tools).
-- Returns true only if there are qualifying tools in Backpack/Character that do NOT
-- have server-restore markers (ServerRestore/ServerIssued/PreserveOnServer).
local function _hasPostRestoreLiveChanges(player)
	if not player then return false end
	local function checkContainer(container)
		if not container then return false end
		for _,c in ipairs(container:GetChildren()) do
			if not c:IsA("Tool") then continue end
			-- Skip obvious server-restored items
			local isServerRestored = c:GetAttribute("ServerRestore") or c:GetAttribute("ServerIssued") or c:GetAttribute("PreserveOnServer")
			if not isServerRestored then
				-- This looks like a genuine live/purchased tool
				return true
			end
		end
		return false
	end
	if checkContainer(player:FindFirstChildOfClass("Backpack")) then return true end
	if player.Character and checkContainer(player.Character) then return true end
	return false
end

local function ws_colorToHex(c)
	return string.format("%02X%02X%02X",
		math.floor(c.R*255+0.5),
		math.floor(c.G*255+0.5),
		math.floor(c.B*255+0.5))
end
local function ws_hexToColor3(hex)
	if typeof(hex)=="Color3" then return hex end
	if type(hex)~="string" then return nil end
	hex=hex:gsub("^#","")
	if #hex~=6 then return nil end
	local r=tonumber(hex:sub(1,2),16)
	local g=tonumber(hex:sub(3,4),16)
	local b=tonumber(hex:sub(5,6),16)
	if r and g and b then return Color3.fromRGB(r,g,b) end
	return nil
end
local function ws_ensureIndex(player)
	if not ws_liveIndex[player.UserId] then ws_liveIndex[player.UserId] = {} end
	return ws_liveIndex[player.UserId]
end
local function ws_registerModel(player, model)
	local id = model:GetAttribute("SlimeId")
	if not id then return end
	local idx=ws_ensureIndex(player)
	if idx[id] and idx[id]~=model and idx[id].Parent then
		dprint("Duplicate live slime SlimeId="..id.." destroying extra.")
		print("[GrandInvSer][DestroyTrace] Destroying duplicate slime:", model:GetFullName())
		print(debug.traceback())
		pcall(function() model:Destroy() end)
		return
	end
	idx[id]=model
	if WSCONFIG.MarkWorldSlimeAttribute then
		model:SetAttribute("WorldSlime", true)
	end
end
local function ws_scan(player)
	local out, seen = {}, {}
	for _,inst in ipairs(Workspace:GetDescendants()) do
		-- combine condition onto one line to avoid parser issues with leading 'and' on new lines
		if inst:IsA("Model") and inst.Name=="Slime" and inst:GetAttribute("OwnerUserId")==player.UserId and not inst:GetAttribute("Retired") and not inst:FindFirstAncestorWhichIsA("Tool") then
			local id=inst:GetAttribute("SlimeId")
			if id and not seen[id] then
				seen[id]=true
				out[#out+1]=inst
				ws_registerModel(player, inst)
			end
		end
	end
	return out
end

local function ws_applyColors(model)
	for attr,short in pairs({ BodyColor="bc", AccentColor="ac", EyeColor="ec" }) do
		local v=model:GetAttribute(attr)
		if typeof(v)=="string" then
			local c=ws_hexToColor3(v)
			if c then
				model:SetAttribute(attr, c)
				model:SetAttribute(attr.."_Hex", v)
			end
		end
	end
end

local function ws_serialize(player, isFinal)
	print("[DEBUG][ws_serialize] Called for player:", player.Name, "isFinal:", tostring(isFinal))
	local slimes = ws_scan(player)
	print("[DEBUG][ws_serialize] Found slimes:", #slimes)
	local list = {}
	local seen = {}
	local now = os.time()
	local plot, origin

	for _,m in ipairs(Workspace:GetChildren()) do
		if m:IsA("Model") and m:GetAttribute("UserId") == player.UserId and m.Name:match("^Player%d+$") then
			plot = m
			break
		end
	end
	if plot then
		print("[DEBUG][ws_serialize] Found plot:", plot:GetFullName())
		local zone = plot:FindFirstChild("SlimeZone")
		if zone and zone:IsA("BasePart") then origin = zone end
	end
	for _,m in ipairs(slimes) do
		local sid = m:GetAttribute("SlimeId")
		if WSCONFIG.DedupeOnSerialize and sid and seen[sid] then
			print("[DEBUG][ws_serialize] Skipping duplicate slime:", sid)
		else
			local prim = m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart")
			if prim then
				local cf = prim.CFrame
				local entry = { px = cf.X, py = cf.Y, pz = cf.Z }
				if WSCONFIG.UseLocalCoords and origin then
					local lcf = origin.CFrame:ToObjectSpace(cf)
					entry.lpx, entry.lpy, entry.lpz = lcf.X, lcf.Y, lcf.Z
					entry.lry = math.atan2(-lcf.LookVector.X, -lcf.LookVector.Z)
				else
					entry.ry = math.atan2(-cf.LookVector.X, -cf.LookVector.Z)
				end
				for attr,short in pairs(WS_ATTR_MAP) do
					local v = m:GetAttribute(attr)
					if v ~= nil then
						if colorKeys[short] and typeof(v) == "Color3" then
							v = ws_colorToHex(v)
						end
						entry[short] = v
					end
				end
				entry.id = sid
				entry.lg = now
				print("[DEBUG][ws_serialize] Adding slime entry:", entry)
				list[#list+1] = entry
				if sid then seen[sid] = true end
				if #list >= WSCONFIG.MaxWorldSlimesPerPlayer then
					print("[DEBUG][ws_serialize] MaxWorldSlimesPerPlayer reached.")
					break
				end
			end
		end
	end
	print("[DEBUG][ws_serialize] Final list count:", #list)
	return list
end 

local function ws_restore(player, list)
	print("[DEBUG][ws_restore] Called for player:", player and player.Name or "nil", "list count:", list and #list or 0)
	if not player or not list or #list == 0 then
		print("[DEBUG][ws_restore] No data to restore.")
		return
	end

	local now = os.time()
	ws_scan(player)

	-- attempt to find player's plot origin (reuse same logic as serialize)
	local plot, origin
	for _, m in ipairs(Workspace:GetChildren()) do
		if m:IsA("Model") and m:GetAttribute("UserId") == player.UserId and m.Name:match("^Player%d+$") then
			plot = m
			break
		end
	end
	if plot then
		local zone = plot:FindFirstChild("SlimeZone")
		if zone and zone:IsA("BasePart") then origin = zone end
	end

	local parent = plot or Workspace
	local restored = 0

	for _, e in ipairs(list) do
		if restored >= WSCONFIG.MaxWorldSlimesPerPlayer then
			dprint("[WorldSlime] MaxWorldSlimesPerPlayer reached during restore.")
			break
		end

		-- build a minimal Slime model (prefer to clone an existing live template if available)
		local m = Instance.new("Model")
		m.Name = "Slime"

		local prim = Instance.new("Part")
		prim.Name = "Body"
		prim.Size = Vector3.new(2, 2, 2)
		prim.TopSurface = Enum.SurfaceType.Smooth
		prim.BottomSurface = Enum.SurfaceType.Smooth
		prim.Parent = m
		m.PrimaryPart = prim

		-- set ownership/id attributes
		if e.id then m:SetAttribute("SlimeId", e.id) end
		m:SetAttribute("OwnerUserId", player.UserId)

		-- restore mapped attributes (converting color hex to Color3 when needed)
		for attr, short in pairs(WS_ATTR_MAP) do
			local v = e[short]
			if v ~= nil then
				if colorKeys[short] and type(v) == "string" then
					local c = ws_hexToColor3(v)
					if c then v = c end
				end
				m:SetAttribute(attr, v)
			end
		end

		-- preserve the recorded timestamp if present
		if e.lg then m:SetAttribute("PersistedGrowthProgress", e.lg) end

		-- position the slime using local coordinates if available
		local targetCF
		if origin and e.lpx then
			-- defensive logging: ensure we have all three local components
			if e.lpx and (e.lpz == nil) then
				dprint(("[WorldSlime][Restore] Missing local Z for slime id=%s; entry keys=%s"):format(tostring(e.id), HttpService:JSONEncode(e)))
			end
			-- BUGFIX: use e.lpz (local z) not e.lz
			targetCF = origin.CFrame * CFrame.new(e.lpx, e.lpy, e.lpz)
			if e.lry then targetCF = targetCF * CFrame.Angles(0, e.lry, 0) end
		else
			targetCF = CFrame.new(e.px or 0, e.py or 0, e.pz or 0)
			if e.ry then targetCF = targetCF * CFrame.Angles(0, e.ry, 0) end
		end

		-- parent then pivot to avoid transient client-side cleanup race
		m.Parent = parent
		pcall(function() m:PivotTo(targetCF) end)

		if WSCONFIG.MarkWorldSlimeAttribute then
			m:SetAttribute("WorldSlime", true)
		end

		-- register in live index to prevent duplicates
		ws_registerModel(player, m)

		restored = restored + 1
	end

	dprint(("WorldSlime: Restore complete count=%d"):format(restored))
end

-------------------------------------------------------------------------------
-- WorldEgg Serializer
-------------------------------------------------------------------------------
local WECONFIG = GrandInventorySerializer.CONFIG.WorldEgg
local WE_ATTR_MAP = {
	Rarity="ra", ValueBase="vb", ValuePerGrowth="vg", WeightScalar="ws",
	MovementScalar="mv", MutationRarityBonus="mb"
}

local function we_findPlayerPlot(player)
	for _,m in ipairs(Workspace:GetChildren()) do
		-- combine condition into a single line to avoid line-start 'and' tokens
		if m:IsA("Model") and m.Name:match("^Player%d+$") and m:GetAttribute("UserId")==player.UserId then
			return m
		end
	end
	return nil
end
local function we_getPlotOrigin(plot)
	if not plot then return nil end
	local z=plot:FindFirstChild("SlimeZone")
	if z and z:IsA("BasePart") then return z end
	for _,d in ipairs(plot:GetDescendants()) do
		if d:IsA("BasePart") and d.Name=="SlimeZone" then return d end
	end
	return nil
end
local function we_locateEggTemplate(eggId)
	for _,folderName in ipairs(WECONFIG.TemplateFolders) do
		local folder=ReplicatedStorage:FindFirstChild(folderName)
		if folder then
			local specific= eggId and folder:FindFirstChild(eggId)
			if specific and specific:IsA("Model") then return specific end
			local generic=folder:FindFirstChild(WECONFIG.DefaultTemplateName)
			if generic and generic:IsA("Model") then return generic end
		end
	end
	return nil
end
local function we_enumeratePlotEggs(player)
	-- Attempt to locate the player's plot/plot origin (may be nil)
	local plot = we_findPlayerPlot(player)
	local origin = we_getPlotOrigin(plot)
	-- use both tick() (monotonic) and os.time() (epoch) so we can compare against attributes saved
	-- in either time-base. Some systems may write PlacedAt/HatchAt as os.time(); others use tick().
	local now_tick = tick()
	local now_os = os.time()
	local list = {}
	local seen = {}

	-- Helper to accept a candidate egg Model if matches placed/manual and owner, then record entry
	local function acceptEgg(desc)
		if not desc or not desc:IsA("Model") then return end

		local placed     = desc:GetAttribute("Placed")
		local manualHatch= desc:GetAttribute("ManualHatch")
		local ownerUserId= desc:GetAttribute("OwnerUserId")
		local isPreview  = desc:GetAttribute("Preview") or desc.Name:match("Preview")

		-- Accept if explicit owner matches, or if the egg is under the player's plot (covers quick placement before attrs).
		local ownerMatch = tostring(ownerUserId) == tostring(player.UserId)
		if not ownerMatch and plot and desc:IsDescendantOf(plot) then
			ownerMatch = true
		end
		if not ownerMatch then return end

		-- Skip obvious transient previews that are not placed/manual-hatch.
		if isPreview and not placed and not manualHatch then return end

		-- If neither Placed nor ManualHatch are set, allow recent placements to be captured
		-- (covers race where server-side snapshot runs before client sets flags).
		if not placed and not manualHatch then
			local placedAtRaw = tonumber(desc:GetAttribute("PlacedAt"))
			if not placedAtRaw then
				-- no PlacedAt and not explicitly placed -> only accept if config allows auto-capture on placement
				if not WECONFIG.AutoCaptureOnEggPlacement then return end
				-- if we don't have a timestamp, be conservative and accept (covers server-created placements)
			else
				local grace = WECONFIG.AcceptMissingManualHatchGraceSeconds or 10
				-- Determine age in seconds in an appropriate time-base:
				local placedAge
				if placedAtRaw > 1e8 then
					-- looks like epoch time (os.time)
					placedAge = now_os - placedAtRaw
				else
					-- looks like tick() value
					placedAge = now_tick - placedAtRaw
				end
				if placedAge > grace then
					-- too old and still missing flags -> treat as not placed
					return
				end
			end
		end

		local prim = desc.PrimaryPart or desc:FindFirstChildWhichIsA("BasePart")
		if not prim then return end

		local eggId = desc:GetAttribute("EggId") or ("Egg_"..math.random(1,1e9))
		if seen[eggId] then return end
		seen[eggId] = true

		-- Fill sensible fallbacks for hatch times if missing
		local hatchAtRaw = tonumber(desc:GetAttribute("HatchAt"))
		local hatchTime = tonumber(desc:GetAttribute("HatchTime"))
		if not hatchTime then
			hatchTime = tonumber(desc:GetAttribute("EstimatedHatchTime")) or 0
		end

		local remaining
		-- If explicit HatchAt present, compute remaining using appropriate time-base
		if hatchAtRaw then
			if hatchAtRaw > 1e8 then
				remaining = math.max(0, hatchAtRaw - now_os)
			else
				remaining = math.max(0, hatchAtRaw - now_tick)
			end
		else
			-- No HatchAt: try deriving from PlacedAt (if present) then compare in the matching time-base,
			-- otherwise assume hatchTime seconds from now.
			local placedAtRaw = tonumber(desc:GetAttribute("PlacedAt"))
			if placedAtRaw then
				if placedAtRaw > 1e8 then
					local hatchAtEpoch = placedAtRaw + (hatchTime or 0)
					remaining = math.max(0, hatchAtEpoch - now_os)
					hatchAtRaw = hatchAtEpoch
				else
					local hatchAtTick = placedAtRaw + (hatchTime or 0)
					remaining = math.max(0, hatchAtTick - now_tick)
					hatchAtRaw = hatchAtTick
				end
			else
				remaining = math.max(0, (hatchTime or 0))
				hatchAtRaw = (hatchTime or 0) + now_tick
			end
		end

		local cf = prim:GetPivot()
		local e = {
			id = eggId,
			ht = hatchTime,
			ha = hatchAtRaw,
			tr = remaining,
			px = cf.X, py = cf.Y, pz = cf.Z,
			-- Use now_os (epoch) as a sensible fallback for PlacedAt when attribute missing.
			-- This avoids referencing an undefined 'now' variable.
			cr = desc:GetAttribute("PlacedAt") or (now_os - (hatchTime or 0)),
		}

		if origin then
			local onCF = origin.CFrame:ToObjectSpace(cf)
			e.lpx, e.lpy, e.lz = onCF.X, onCF.Y, onCF.Z
		end
		for attr,short in pairs(WE_ATTR_MAP) do
			local v = desc:GetAttribute(attr)
			if v ~= nil then e[short] = v end
		end
		list[#list+1] = e
	end

	-- First, collect eggs under the player's plot (if any)
	if plot then
		dprint("[WorldEggSer][Debug] Enumerating plot:", plot:GetFullName(), "for player", player.Name)
		for _,desc in ipairs(plot:GetDescendants()) do
			if desc:IsA("Model") and desc.Name == "Egg" then
				acceptEgg(desc)
			end
		end
	end

	-- Second, also scan all Workspace descendants for eggs owned by the player (covers stray/legacy placement)
	for _,desc in ipairs(Workspace:GetDescendants()) do
		if desc:IsA("Model") and desc.Name == "Egg" then
			-- if we already processed this egg via plot scan it'll be deduped by EggId
			acceptEgg(desc)
		end
	end

	eggdbg(string.format("Enumerate done uid=%d count=%d", player.UserId, #list))
	dprint("[WorldEggSer][Debug] Total eggs found for serialization:", #list)
	return list, plot, origin
end
local function we_serialize(player, isFinal)
	local t0 = clock()
	local ok, liveList, plot, origin = pcall(function()
		local ll, pl, orp = we_enumeratePlotEggs(player)
		return ll, pl, orp
	end)
	if not ok then
		warn("[WorldEggSer] enumerate error:", liveList)
		liveList={}
	end
	dprint(string.format(
		"WorldEgg: Serialize player=%s final=%s count=%d source=live",
		player.Name, tostring(isFinal), #liveList))
	return liveList
end

local function we_restore(player, list)
	print("[DEBUG][we_restore] Called for player:", player and player.Name or "nil", "list count:", list and #list or 0)
	if not player or not list or #list == 0 then
		print("[DEBUG][we_restore] No data to restore.")
		return
	end

	local now = os.time()
	ws_scan(player)
	local plot, origin
	for _, m in ipairs(Workspace:GetChildren()) do
		if m:IsA("Model") and m:GetAttribute("UserId") == player.UserId and m.Name:match("^Player%d+$") then
			plot = m
			break
		end
	end
	if plot then
		print("[DEBUG][we_restore] Found plot:", plot:GetFullName())
		local zone = plot:FindFirstChild("SlimeZone")
		if zone and zone:IsA("BasePart") then origin = zone end
	end
	local parent = plot or Workspace
	local restored = 0
	for _, e in ipairs(list) do
		if restored >= WECONFIG.MaxWorldEggsPerPlayer then
			warn("[WorldEggSer] Max reached during restore")
			break
		end
		local template = we_locateEggTemplate(e.id) or we_locateEggTemplate(WECONFIG.DefaultTemplateName)
		local m
		if template then
			m = template:Clone()
		else
			m = Instance.new("Model")
			local part = Instance.new("Part")
			part.Shape = Enum.PartType.Ball
			part.Size = Vector3.new(2,2,2)
			part.Name = "Handle"
			part.TopSurface = Enum.SurfaceType.Smooth
			part.BottomSurface = Enum.SurfaceType.Smooth
			part.Parent = m
			m.PrimaryPart = part
		end
		m.Name = "Egg"
		m:SetAttribute("EggId", e.id)
		m:SetAttribute("Placed", true)
		m:SetAttribute("ManualHatch", true)
		m:SetAttribute("PlacedAt", e.cr)
		m:SetAttribute("OwnerUserId", player.UserId)
		m:SetAttribute("HatchTime", e.ht)
		for attr,short in pairs(WE_ATTR_MAP) do
			local v = e[short]; if v ~= nil then m:SetAttribute(attr, v) end
		end
		local hatchAt
		if WECONFIG.RestoreEggsReady then
			hatchAt = now
		elseif WECONFIG.OfflineEggProgress then
			hatchAt = e.ha
		else
			hatchAt = now + (e.tr or 0)
		end
		m:SetAttribute("HatchAt", hatchAt)
		local prim = m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart")
		if not prim then
			local part = Instance.new("Part")
			part.Name = "Handle"
			part.Size = Vector3.new(2,2,2)
			part.Parent = m
			m.PrimaryPart = part
		end
		m.Parent = parent
		local targetCF
		if origin and e.lpx then
			targetCF = origin.CFrame * CFrame.new(e.lpx,e.lpy,e.lz)
		else
			targetCF = CFrame.new(e.px or 0, e.py or 0, e.pz or 0)
		end
		pcall(function() m:PivotTo(targetCF) end)
		restored += 1
	end
	dprint(("WorldEgg: Restore complete count=%d"):format(restored))
end

-------------------------------------------------------------------------------
-- FoodTool Serializer
-------------------------------------------------------------------------------
local FTCONFIG = GrandInventorySerializer.CONFIG.FoodTool
local FT_ATTRS = {
	FoodId="fid", RestoreFraction="rf", FeedBufferBonus="fb",
	Consumable="cs", Charges="ch", FeedCooldownOverride="cd",
	OwnerUserId="ow", ToolUniqueId="uid"
}
local ft_restoreBatchCounter=0
local function ft_dprint(...) 
	if FTCONFIG.Debug then print("[FoodSer]", ...) end
end

ft_qualifies = function(tool)
	-- Use an explicit sequence of checks to avoid confusing the Luau parser
	if not tool then return false end
	if type(tool.IsA) ~= "function" then return false end
	if not tool:IsA("Tool") then return false end
	-- Consider a tool qualifying if it has either FoodItem or FoodId attribute
	return tool:GetAttribute("FoodItem") ~= nil or tool:GetAttribute("FoodId") ~= nil
end
local function ft_enumerate(container, out)
	if not container then return end
	for _,c in ipairs(container:GetChildren()) do
		if ft_qualifies(c) then out[#out+1]=c end
	end
end
-- PATCH: Add detailed logging to ft_collectFood scan and ensure correct parenting/attributes
local function ft_collectFood(player)
	local out = {}
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		print("[FoodSer][Scan] Backpack children:")
		for _,c in ipairs(backpack:GetChildren()) do
			print("  ", c.Name, "FoodItem:", tostring(c:GetAttribute("FoodItem")), "FoodId:", tostring(c:GetAttribute("FoodId")), "Parent:", tostring(c.Parent))
		end
		ft_enumerate(backpack, out)
	end
	if player.Character then
		print("[FoodSer][Scan] Character children:")
		for _,c in ipairs(player.Character:GetChildren()) do
			print("  ", c.Name, "FoodItem:", tostring(c:GetAttribute("FoodItem")), "FoodId:", tostring(c:GetAttribute("FoodId")), "Parent:", tostring(c.Parent))
		end
		ft_enumerate(player.Character, out)
	end
	print("[FoodSer][Scan] Qualified food tools found:", #out)
	for _,tool in ipairs(out) do
		tool:SetAttribute("OwnerUserId", player.UserId)
	end
	return out
end
local function ft_findTemplate(fid)
	for _,folderName in ipairs(FTCONFIG.TemplateFolders) do
		local folder = ReplicatedStorage:FindFirstChild(folderName)
		if folder then
			if fid then
				local spec = folder:FindFirstChild(fid)
				if spec and spec:IsA("Tool") then return spec end
			end
			local generic = folder:FindFirstChild("Food")
			if generic and generic:IsA("Tool") then return generic end
		end
	end
	return nil
end
local function ft_instrumentLifecycle(player, tool)
	if not FTCONFIG.InstrumentLifeCycle then return end
	local t0 = tick()
	tool.AncestryChanged:Connect(function(_, parent)
		if tick() - t0 <= FTCONFIG.LifeCycleWatchSeconds and not parent then
			print(("[FoodSer][LC] %s removed %.2fs after restore"):format(tool.Name, tick() - t0))
			print(debug.traceback("[FoodSer][LC] Removed traceback"))
		end
	end)
	tool.Destroying:Connect(function()
		if tick() - t0 <= FTCONFIG.LifeCycleWatchSeconds then
			print(("[FoodSer][LC] %s destroyed %.2fs after restore"):format(tool.Name, tick() - t0))
			print(debug.traceback("[FoodSer][LC] Destroyed traceback"))
		end
	end)
end

-- Forward-declare egg-tool lifecycle hook to silence analyzer before it's defined later
local et_instrumentLifecycle = nil
local et_cleanupPreview = nil

local function auditBackpack(player, label)
	-- default label to avoid runtime error when callers omit it
	label = label or "Audit"
	local backpack = player:FindFirstChildOfClass("Backpack")
	print(("[FoodSer][Audit][%s] Backpack contents:"):format(tostring(label)))
	if backpack then
		for _,t in ipairs(backpack:GetChildren()) do
			print("  ", t.Name, "FoodItem:", tostring(t:GetAttribute("FoodItem")), "FoodId:", tostring(t:GetAttribute("FoodId")), "Parent:", tostring(t.Parent))
		end
	end
end

-- default local hook (silences UnknownGlobal warnings)
local periodicBackpackAudit = auditBackpack


local function ft_serialize(player, isFinal)
	auditBackpack(player, "PreSerialize")
	local tools = ft_collectFood(player)
	local list = {}
	local seenUids = {}
	ft_dprint(("Serialize mode=%s toolCount=%d final=%s"):format(
		FTCONFIG.AggregationMode, #tools, tostring(isFinal))
	)
	if FTCONFIG.AggregationMode == "individual" then
		for _,tool in ipairs(tools) do
			-- Skip server-restored / server-issued / preserved food tools so we don't persist restore-clones back into profile
			if tool:GetAttribute("ServerRestore") or tool:GetAttribute("ServerIssued") or tool:GetAttribute("PreserveOnServer") or tool:GetAttribute("PreserveOnClient") then
				ft_dprint("Serialize: skipping server-restored/preserved food tool:", tool.Name)
				continue
			end

			local entry = { nm = tool.Name }
			for attr, short in pairs(FT_ATTRS) do
				local v = tool:GetAttribute(attr)
				if v ~= nil then entry[short]=v end
			end
			entry.fid = entry.fid or tool:GetAttribute("FoodId") or tool.Name
			if not entry.uid or entry.uid == "" then
				local existing = tool:GetAttribute("ToolUniqueId")
				if existing and existing ~= "" then
					entry.uid = existing
				else
					entry.uid = HttpService:GenerateGUID(false)
					tool:SetAttribute("ToolUniqueId", entry.uid)
				end
			end

			local uidKey = entry.uid and tostring(entry.uid) or nil
			if uidKey then
				if seenUids[uidKey] then
					ft_dprint("Serialize: skipping duplicate food uid=" .. uidKey)
				else
					seenUids[uidKey] = true
					list[#list+1] = entry
				end
			else
				-- No uid -> include but still count toward cap
				list[#list+1] = entry
			end

			if #list >= FTCONFIG.MaxFood then
				ft_dprint("MaxFood cap reached during serialize.")
				break
			end
		end
	end
	ft_dprint("Serialize produced count="..#list..(isFinal and " (FINAL)" or ""))
	return list
end
local function ft_ensureHandle(tool, size)
	if tool:FindFirstChild("Handle") then return end
	local h=Instance.new("Part")
	h.Name="Handle"
	h.Size=size or FTCONFIG.FallbackHandleSize
	h.TopSurface=Enum.SurfaceType.Smooth
	h.BottomSurface=Enum.SurfaceType.Smooth
	h.Parent=tool
end
local function ft_buildTool(entry, player)
	local template = ft_findTemplate(entry.fid or entry.nm)
	local tool
	if template then
		local ok,clone = pcall(function() return template:Clone() end)
		if ok and clone then tool=clone end
	end
	if not tool then
		tool=Instance.new("Tool")
		tool.Name = entry.nm or entry.fid or "Food"
		ft_ensureHandle(tool)
		print("[FoodSer][Debug] Created new tool (no template):", tool.Name)
		print(debug.traceback())
	else
		tool.Name = entry.nm or tool.Name
		ft_ensureHandle(tool)
		print("[FoodSer][Debug] Cloned template tool:", tool.Name)
		print(debug.traceback())
	end
	tool:SetAttribute("FoodItem", true)
	tool:SetAttribute("FoodId", entry.fid or tool.Name)
	tool:SetAttribute("OwnerUserId", player.UserId)
	tool:SetAttribute("PersistentFoodTool", true)
	tool:SetAttribute("__FoodSerVersion", FTCONFIG.Version or "1.5.0")
	tool:SetAttribute("ToolUniqueId", entry.uid or HttpService:GenerateGUID(false))
	-- Mark server-origin so client-side template/cleanup logic won't immediately remove it
	tool:SetAttribute("ServerIssued", true)
	tool:SetAttribute("ServerRestore", true)
	tool:SetAttribute("PreserveOnServer", true)
	tool:SetAttribute("RestoreStamp", tick())
	tool:SetAttribute("RestoreBatchId", os.time())
	-- Add this logging
	print("[FoodSer][Debug] Tool attributes after build:", tool.Name)
	for _,attr in pairs({"FoodItem","FoodId","ToolUniqueId","OwnerUserId"}) do
		print("  ", attr, "=", tostring(tool:GetAttribute(attr)))
	end
	return tool
end
local function ft_restore(player, list)
	print("[FoodSer][Restore][DEBUG] Incoming list:", HttpService:JSONEncode(list))
	if not list or #list==0 then
		ft_dprint("[FoodSer][Restore] none")
		return
	end
	local backpack=player:FindFirstChildOfClass("Backpack")
	if not backpack then
		task.delay(0.25,function()
			if player.Parent then ft_restore(player,list) end
		end)
		return
	end
	ft_restoreBatchCounter += 1
	local batch = ft_restoreBatchCounter
	ft_dprint(("[FoodSer][Restore] entries=%d batch=%d"):format(#list, batch))
	local createdEntries={}
	for _,e in ipairs(list) do
		if #createdEntries >= FTCONFIG.MaxFood then
			ft_dprint("MaxFood cap reached during restore.")
			break
		end
		if not e.uid or e.uid=="" then
			e.uid = HttpService:GenerateGUID(false)
		end

		-- NEW: if a tool with this UID already exists (Backpack/Character/ServerStorage), reuse/mark it and skip creating duplicate
		local existing = find_existing_tool_by_uid(player, e.uid)
		if existing then
			ft_dprint(("Restore: found existing tool for uid=%s name=%s parent=%s - skipping create"):format(e.uid, tostring(existing.Name), tostring(existing.Parent)))
			-- ensure server-preserve metadata is present so cleanup doesn't remove it
			existing:SetAttribute("PreserveOnServer", true)
			existing:SetAttribute("RestoreStamp", tick())
			existing:SetAttribute("RestoreBatchId", tostring(os.time()) .. "-" .. HttpService:GenerateGUID(false))
			if FTCONFIG.RequireStableHeartbeats then
				existing:SetAttribute("StableHeartbeats", 0)
			end
			createdEntries[#createdEntries+1]=e
			continue
		end

		local tool = ft_buildTool(e, player)
		-- Add server-side preserve/stabilization attributes immediately so cleanup/LC sees them
		tool:SetAttribute("PreserveOnServer", true)
		tool:SetAttribute("RestoreStamp", tick())
		tool:SetAttribute("RestoreBatchId", tostring(os.time()) .. "-" .. HttpService:GenerateGUID(false))
		if FTCONFIG.RequireStableHeartbeats then
			tool:SetAttribute("StableHeartbeats", 0)
		end
		dprint("[EggToolSer][Restore] Marked tool PreserveOnServer/RestoreStamp:", tool.Name, tool:GetAttribute("EggId") or tool:GetAttribute("ToolUniqueId"))

		-- Attach ancestry/destroy watchers and server-preserve hint
		local watchStart = tick()
		tool:SetAttribute("PreserveOnClient", true)
		tool.AncestryChanged:Connect(function(_, parent)
			if tick() - watchStart <= FTCONFIG.LifeCycleWatchSeconds and not parent then
				print(("[FoodSer][LC] %s removed %.2fs after restore"):format(tool.Name, tick() - watchStart))
				print(debug.traceback("[FoodSer][LC] Removed traceback"))
			end
		end)
		tool.Destroying:Connect(function()
			if tick() - watchStart <= FTCONFIG.LifeCycleWatchSeconds then
				print(("[FoodSer][LC] %s destroyed %.2fs after restore"):format(tool.Name, tick() - watchStart))
				print(debug.traceback("[FoodSer][LC] Destroyed traceback"))
			end
		end)
		-- Avoid client cleanup races by staging in ServerStorage, then move to backpack.
		tool.Parent = ServerStorage
		task.delay(RESTORE_STAGE_DELAY, function()
			if not backpack.Parent then return end
			if tool and tool.Parent ~= backpack then
				pcall(function() tool.Parent = backpack end)
			end
		end)

		et_instrumentLifecycle(player, tool)

		-- stabilize heartbeats if requested (mirror CapturedSlime behavior)
		if FTCONFIG.RequireStableHeartbeats then
			tool:SetAttribute("StableHeartbeats", 0)
		end

		-- Add this logging
		print("[FoodSer][Restore][Lifecycle] Tool:", tool.Name, "FoodItem:", tostring(tool:GetAttribute("FoodItem")), "FoodId:", tostring(tool:GetAttribute("FoodId")), "Parent:", tostring(tool.Parent))
		createdEntries[#createdEntries+1]=e

		-- Post-restore re-parent + audit (avoid client initialization race)
		local postDelay = math.max(FTCONFIG.PostRestoreAuditDelay or 0.85, 2.0) -- allow extra time for clients to init
		task.delay(postDelay, function()
			if not backpack.Parent then return end
			if tool and tool.Parent ~= backpack then
				pcall(function() tool.Parent = backpack end)
				print("[FoodSer][Restore][PostDelay] Re-parented tool after delay:", tool.Name, "Parent:", tostring(tool.Parent))
			end
			if type(periodicBackpackAudit) == "function" then
				periodicBackpackAudit(player, "PostRestoreEgg")
			end
		end)
	end

	print("[FoodSer][Restore] Backpack contents after restore:")
	for _,t in ipairs(backpack:GetChildren()) do
		print("  ", t.Name, "FoodItem:", tostring(t:GetAttribute("FoodItem")))

	end

	-- guard audit call (avoid nil-call if function not set for some reason)
	if type(periodicBackpackAudit) == "function" then
		periodicBackpackAudit(player)
	end

	-- start short stable-heartbeat pass so periodic serializes will see restored tools
	if FTCONFIG.RequireStableHeartbeats then
		local hbCount = 0
		local hbConn
		hbConn = RunService.Heartbeat:Connect(function()
			hbCount = hbCount + 1
			for _, tool in ipairs(backpack:GetChildren()) do
				if tool:IsA("Tool") and tool:GetAttribute("FoodItem") then
					local cur = tool:GetAttribute("StableHeartbeats") or 0
					if cur < FTCONFIG.StableHeartbeatCount then
						tool:SetAttribute("StableHeartbeats", math.min(FTCONFIG.StableHeartbeatCount, cur + 1))
					end
				end
			end
			if hbCount >= FTCONFIG.StableHeartbeatCount then
				hbConn:Disconnect()
			end
		end)
	end
end

-------------------------------------------------------------------------------
-- EggTool Serializer
-------------------------------------------------------------------------------
local ETCONFIG = GrandInventorySerializer.CONFIG.EggTool
local ET_UID_KEY   = "ToolUniqueId"
local ET_UID_SHORT = "uid"
local ET_REQUIRED_VISUAL_PART = "Handle"
local ET_ATTR_SHORT = {
	EggId="id", Rarity="ra", HatchTime="ht", ValueBase="vb",
	ValuePerGrowth="vg", MovementScalar="ms", WeightScalar="ws",
	MutationRarityBonus="mb", ServerIssued="si", OwnerUserId="ou"
}
local function et_getTemplate()
	local folder = ReplicatedStorage:FindFirstChild(ETCONFIG.TemplateFolder)
	if not folder then return nil end
	local tmpl = folder:FindFirstChild(ETCONFIG.TemplateName)
	if tmpl and tmpl:IsA("Tool") then return tmpl end
	return nil
end
local function et_toolLooksPlaceholder(tool)
	local parts={}
	for _,d in ipairs(tool:GetDescendants()) do
		if d:IsA("BasePart") then parts[#parts+1]=d end
	end
	if #parts==0 then return true end
	if #parts==1 then
		if (parts[1].Size - ETCONFIG.FallbackHandleSize).Magnitude < 0.001 then
			return true
		end
	end
	return false
end
local function et_ensureHandle(tool)
	if tool:FindFirstChild(ET_REQUIRED_VISUAL_PART) then return end
	local h=Instance.new("Part")
	h.Name=ET_REQUIRED_VISUAL_PART
	h.Size=ETCONFIG.FallbackHandleSize
	h.CanCollide=false
	h.Anchored=false
	h.Parent=tool
end

et_cleanupPreview = function(tool)
	if not tool then return end
	local uid = tool:GetAttribute(ET_UID_KEY) or tool:GetAttribute("EggId")
	local owner = tool:GetAttribute("OwnerUserId")
	-- Remove obvious preview models: those without Placed, or explicit Preview flag,
	-- and that match the tool by EggId/ToolUniqueId or OwnerUserId.
	for _,desc in ipairs(Workspace:GetDescendants()) do
		if desc:IsA("Model") then
			local placed = desc:GetAttribute("Placed")
			local isPreviewFlag = desc:GetAttribute("Preview") or desc.Name:match("Preview")
			local descEggId = desc:GetAttribute("EggId")
			local descOwner = desc:GetAttribute("OwnerUserId")
			local descPreviewUid = desc:GetAttribute("PreviewOwnerUid") or desc:GetAttribute("PreviewSourceUid")
			if (not placed) and (isPreviewFlag or descPreviewUid or descEggId or descOwner) then
				local matchUid = (uid and descPreviewUid and tostring(descPreviewUid) == tostring(uid))
				local matchEgg = (uid and descEggId and tostring(descEggId) == tostring(uid))
				local matchOwner = (owner and descOwner and tostring(descOwner) == tostring(owner))
				if matchUid or matchEgg or matchOwner or isPreviewFlag then
					pcall(function() desc:Destroy() end)
				end
			end
		end
	end
end

-- Assign implementation to forward-declared local to ensure it is initialized
et_instrumentLifecycle = function(player, tool)
	if not ETCONFIG.InstrumentLifeCycle then return end
	local t0 = tick()
	tool.AncestryChanged:Connect(function(_, parent)
		if tick() - t0 <= ETCONFIG.LifeCycleWatchSeconds and not parent then
			-- Cleanup possible preview remnants when a restored tool is removed quickly
			if type(et_cleanupPreview) == "function" then
				pcall(et_cleanupPreview, tool)
			end
			print(("[EggToolSer][LC] %s removed %.2fs after restore"):format(tool.Name, tick() - t0))
			print(debug.traceback("[EggToolSer][LC] Removed traceback"))
		end
	end)
	tool.Destroying:Connect(function()
		if tick() - t0 <= ETCONFIG.LifeCycleWatchSeconds then
			-- Cleanup previews on destroy as well
			if type(et_cleanupPreview) == "function" then
				pcall(et_cleanupPreview, tool)
			end
			print(("[EggToolSer][LC] %s destroyed %.2fs after restore"):format(tool.Name, tick() - t0))
			print(debug.traceback("[EggToolSer][LC] Destroyed traceback"))
		end
	end)
end

local function et_applyEntry(tool, entry)
	-- Support both short-key (uid/ra/id/ht/...) and legacy/long-key ("EggId","Rarity","HatchTime",...)
	for attr, short in pairs(ET_ATTR_SHORT) do
		local v = entry[short]
		if v == nil then v = entry[attr] end
		if v ~= nil then
			tool:SetAttribute(attr, v)
		end
	end
	-- Backwards-compatible name fields
	if entry.nm and tool.Name == nil then
		tool.Name = entry.nm
	end
	if entry.ToolName then
		tool.Name = entry.ToolName
	end
	-- EggId legacy key fallback
	if entry.id and tool:GetAttribute("EggId") == nil then
		tool:SetAttribute("EggId", entry.id)
	elseif entry.EggId and tool:GetAttribute("EggId") == nil then
		tool:SetAttribute("EggId", entry.EggId)
	end
	-- OwnerUserId legacy fallback
	if entry.ou and tool:GetAttribute("OwnerUserId") == nil then
		tool:SetAttribute("OwnerUserId", entry.ou)
	elseif entry.OwnerUserId and tool:GetAttribute("OwnerUserId") == nil then
		tool:SetAttribute("OwnerUserId", entry.OwnerUserId)
	end
	-- UID: accept short 'uid', legacy 'ToolUniqueId' or the attribute key itself
	local uid = entry[ET_UID_SHORT] or entry[ET_UID_KEY] or entry.ToolUniqueId
	if uid and not tool:GetAttribute(ET_UID_KEY) then
		tool:SetAttribute(ET_UID_KEY, uid)
	end
end

local function et_cloneTemplate(template)
	local ok, clone = pcall(function() return template:Clone() end)
	if ok and clone then return clone end
	return nil
end
local function et_buildToolFromEntry(entry, template)
	local tool
	if template then
		tool = et_cloneTemplate(template)
		print("[EggToolSer][Debug] Cloned template tool:", tool and tool.Name or "nil")
		print(debug.traceback())
	end
	if not tool then
		tool = Instance.new("Tool")
		-- name fallback: prefer explicit ToolName, then nm
		tool.Name = entry.ToolName or entry.nm or "Egg"
		et_ensureHandle(tool)
		print("[EggToolSer][Debug] Created new tool (no template):", tool.Name)
		print(debug.traceback())
	else
		tool.Name = entry.ToolName or entry.nm or tool.Name or "Egg"
		et_ensureHandle(tool)
	end
	et_applyEntry(tool, entry)
	tool:SetAttribute("ServerIssued", true)
	tool:SetAttribute("ServerRestore", true)
	tool:SetAttribute("PreserveOnServer", true)
	tool:SetAttribute("RestoreStamp", tick())
	tool:SetAttribute("RestoreBatchId", tostring(os.time()) .. "-" .. HttpService:GenerateGUID(false))
	print("[EggToolSer][Debug] Tool attributes after build:", tool.Name)
	for attr,short in pairs(ET_ATTR_SHORT) do
		print("  ", attr, "=", tostring(tool:GetAttribute(attr)))
	end
	return tool
end

local function et_repairVisual(tool)
	if not ETCONFIG.RepairAfterRestore then return end
	if not tool or not tool.Parent then return end
	if not et_toolLooksPlaceholder(tool) then return end
	local attrs={}
	for attr,_ in pairs(ET_ATTR_SHORT) do
		attrs[attr]=tool:GetAttribute(attr)
	end
	local uid = tool:GetAttribute(ET_UID_KEY)
	local parent = tool.Parent
	print("[EggToolSer][Repair][Destroying] Tool:", tool.Name, "Parent:", tostring(parent))
	print(debug.traceback())
	-- cleanup any preview models linked to this tool before replacing
	pcall(et_cleanupPreview, tool)
	tool.Parent=nil
	tool:Destroy()
	local entry={ nm="Egg" }
	for attr,short in pairs(ET_ATTR_SHORT) do
		local v=attrs[attr]; if v~=nil then entry[short]=v end
	end
	if uid then entry[ET_UID_SHORT]=uid end
	local newTool = et_buildToolFromEntry(entry, et_getTemplate())
	newTool.Parent=parent
	print("[EggToolSer][Repair][Replaced] New tool:", newTool.Name, "Parent:", tostring(newTool.Parent))
	print(debug.traceback())
	if ETCONFIG.RepairLogEach then
		dprint("Repaired placeholder egg tool (EggId="..tostring(attrs.EggId)..")")
	end
end


-------------------------------------------------------------------------------
-- CapturedSlime Serializer
-------------------------------------------------------------------------------
local CSCONFIG = GrandInventorySerializer.CONFIG.CapturedSlime
local CS_EXPORT_ATTRS = {
	Version="ver", SlimeId="id", Rarity="ra", GrowthProgress="gp",
	CurrentValue="cv", ValueFull="vf", ValueBase="vb", ValuePerGrowth="vg",
	MutationStage="ms", Tier="ti", WeightPounds="wt", FedFraction="ff",
	BodyColor="bc", AccentColor="ac", EyeColor="ec", CapturedAt="ca",
	MovementScalar="mv", WeightScalar="ws", MutationRarityBonus="mb",
	MaxSizeScale="mx", StartSizeScale="st", CurrentSizeScale="css",
	SizeLuckRolls="lr", FeedBufferSeconds="fb", FeedBufferMax="fx",
	HungerDecayRate="hd", CurrentFullness="cf", FeedSpeedMultiplier="fs",
	LastHungerUpdate="lu",
}
local CS_COLOR_KEYS={ bc=true, ac=true, ec=true }
local CS_ENTRY_VERSION=1
local CS_UID_KEY = "ToolUniqueId"

local function cs_hexToColor(s)
	if type(s)~="string" or #s<6 then return nil end
	s = s:gsub("^#","")
	if #s<6 then return nil end
	local r=tonumber(s:sub(1,2),16)
	local g=tonumber(s:sub(3,4),16)
	local b=tonumber(s:sub(5,6),16)
	if not (r and g and b) then return nil end
	return Color3.fromRGB(r,g,b)
end

local function cs_getTemplate()
	local folder=ReplicatedStorage:FindFirstChild(CSCONFIG.TemplateFolder)
	if not folder then return nil end
	local tmpl=folder:FindFirstChild(CSCONFIG.TemplateNameCaptured)
	if tmpl and tmpl:IsA("Tool") then return tmpl end
	return nil
end

local function cs_ensureHandle(tool)
	if tool:FindFirstChild("Handle") then return end
	local h=Instance.new("Part")
	h.Name="Handle"
	h.Size=Vector3.new(1,1,1)
	h.CanCollide=false
	h.Anchored=false
	h.Parent=tool
end

local function cs_applyEntry(tool, entry)
	for attr,short in pairs(CS_EXPORT_ATTRS) do
		if attr ~= "Version" then
			local v = entry[short]
			if v~=nil then
				if CS_COLOR_KEYS[short] and type(v)=="string" then
					local c=cs_hexToColor(v); if c then v=c end
				end
				tool:SetAttribute(attr, v)
			end
		end
	end
	tool:SetAttribute("SlimeItem", true)
	tool:SetAttribute("SlimeId", tool:GetAttribute("SlimeId") or entry.id)
	tool:SetAttribute("ServerIssued", true)
	tool:SetAttribute("ServerRestore", true)
	tool:SetAttribute("PersistentCaptured", true)
	tool:SetAttribute("__CapSerVersion", CSCONFIG.Version or "3.4")
end

local function cs_buildTool(entry)
	local tool
	local template=cs_getTemplate()
	if template then
		local ok,clone=pcall(function() return template:Clone() end)
		if ok and clone then
			tool=clone
			print("[CapSer][Debug] Cloned template tool:", tool.Name)
			print(debug.traceback())
		end
	end
	if not tool then
		tool=Instance.new("Tool")
		tool.Name = entry.nm or "CapturedSlime"
		cs_ensureHandle(tool)
		print("[CapSer][Debug] Created new tool (no template):", tool.Name)
		print(debug.traceback())
	end
	cs_applyEntry(tool, entry)
	print("[CapSer][Debug] Tool attributes after build:", tool.Name)
	for attr,short in pairs(CS_EXPORT_ATTRS) do
		if attr ~= "Version" then
			print("  ", attr, "=", tostring(tool:GetAttribute(attr)))
		end
	end
	return tool
end

local function cs_instrumentLifecycle(player, tool)
	if not CSCONFIG.RequireStableHeartbeats then return end
	local t0 = tick()
	tool.AncestryChanged:Connect(function(_, parent)
		if tick() - t0 <= CSCONFIG.LifeCycleWatchSeconds and not parent then
			print(("[CapSer][LC] %s removed %.2fs after restore"):format(tool.Name, tick() - t0))
			print(debug.traceback("[CapSer][LC] Removed traceback"))
		end
	end)
	tool.Destroying:Connect(function()
		if tick() - t0 <= CSCONFIG.LifeCycleWatchSeconds then
			print(("[CapSer][LC] %s destroyed %.2fs after restore"):format(tool.Name, tick() - t0))
			print(debug.traceback("[CapSer][LC] Destroyed traceback"))
		end
	end)
end

local function cs_serialize(player, isFinal)
	local tools = {}
	local bp = player:FindFirstChildOfClass("Backpack")
	if bp then
		for _,tool in ipairs(bp:GetChildren()) do
			if tool:IsA("Tool") and tool:GetAttribute("SlimeItem") then
				-- Skip server-restored / server-issued / preserved captured-slime tools so we don't re-persist restore-clones
				if tool:GetAttribute("ServerRestore") or tool:GetAttribute("ServerIssued") or tool:GetAttribute("PreserveOnServer") or tool:GetAttribute("PreserveOnClient") then
					dprint("CapturedSlime: skipping server-restored/preserved tool: " .. tostring(tool.Name))
				else
					tools[#tools+1] = tool
				end
			end
		end
	end
	local list = {}
	local seenUids = {}
	for _,tool in ipairs(tools) do
		local uid = tool:GetAttribute(CS_UID_KEY)
		local uidKey = uid and tostring(uid) or nil
		if uidKey and seenUids[uidKey] then
			dprint(("CapturedSlime: skipping duplicate uid=%s name=%s"):format(uidKey, tostring(tool.Name)))
		else
			if uidKey then seenUids[uidKey] = true end
			local entry = { nm = tool.Name }
			for attr, short in pairs(CS_EXPORT_ATTRS) do
				if attr ~= "Version" then
					local v = tool:GetAttribute(attr)
					if CS_COLOR_KEYS[short] and typeof(v) == "Color3" then
						v = ws_colorToHex(v)
					end
					if v ~= nil then entry[short] = v end
				end
			end
			entry.id = entry.id or tool:GetAttribute("SlimeId")
			entry.ver = CS_ENTRY_VERSION
			entry.uid = uid
			list[#list+1] = entry
			if #list >= CSCONFIG.MaxStored then
				dprint("CapturedSlime: MaxStored reached during serialize")
				break
			end
		end
	end
	dprint("CapturedSlime: Serialize count="..#list..(isFinal and " (FINAL)" or ""))
	return list
end

local function cs_restore(player, list)
	print("[CapSer][Restore][DEBUG] Incoming list:", HttpService:JSONEncode(list))
	if not list or #list == 0 then
		dprint("CapturedSlime: Restore: none")
		return
	end

	local bp = player:FindFirstChildOfClass("Backpack")
	if not bp then
		task.delay(0.25, function()
			if player.Parent then cs_restore(player, list) end
		end)
		return
	end

	dprint("CapturedSlime: Restore entries=" .. #list)
	local seen = {}
	local accepted, skipped = 0, 0

	for _, e in ipairs(list) do
		local id = e.id
		if id and seen[id] and CSCONFIG.DeduplicateOnRestore then
			skipped = skipped + 1
			continue
		end

		-- Only set seen[id] when id is non-nil (avoid "table index is nil" errors)
		if id then
			seen[id] = true
		end

		if accepted >= CSCONFIG.MaxStored then
			dprint("CapturedSlime: MaxStored reached during restore")
			break
		end

		-- NEW: skip if tool with same uid already exists
		local uid = e.uid or e.ToolUniqueId
		if uid then
			local existing = find_existing_tool_by_uid(player, uid)
			if existing then
				dprint(("CapturedSlime: skipping existing tool uid=%s name=%s"):format(tostring(uid), tostring(existing.Name)))
				existing:SetAttribute("PreserveOnServer", true)
				existing:SetAttribute("RestoreStamp", tick())
				existing:SetAttribute("RestoreBatchId", tostring(os.time()) .. "-" .. HttpService:GenerateGUID(false))
				if CSCONFIG.RequireStableHeartbeats then
					existing:SetAttribute("StableHeartbeats", 0)
				end
				accepted = accepted + 1
				continue
			end
		end

		local tool = cs_buildTool(e)
		tool:SetAttribute("RestoreStamp", tick())
		tool:SetAttribute("RestoreBatchId", tostring(os.time()) .. "-" .. HttpService:GenerateGUID(false))
		-- Stage in ServerStorage to avoid immediate client cleanup, then move to backpack
		tool.Parent = ServerStorage
		task.delay(RESTORE_STAGE_DELAY, function()
			if not bp.Parent then return end
			if tool and tool.Parent ~= bp then
				pcall(function() tool.Parent = bp end)
			end
		end)

		cs_instrumentLifecycle(player, tool)
		accepted = accepted + 1
	end

	dprint(("CapturedSlime: Restore complete accepted=%d skipped=%d"):format(accepted, skipped))

	if CSCONFIG.RequireStableHeartbeats then
		local hbCount = 0
		local hbConn
		hbConn = RunService.Heartbeat:Connect(function()
			hbCount = hbCount + 1
			for _, tool in ipairs(bp:GetChildren()) do
				if tool:IsA("Tool") and tool:GetAttribute("SlimeItem") then
					local cur = tool:GetAttribute("StableHeartbeats") or 0
					if cur < CSCONFIG.StableHeartbeatCount then
						tool:SetAttribute("StableHeartbeats", math.min(CSCONFIG.StableHeartbeatCount, cur + 1))
					end
				end
			end
			if hbCount >= CSCONFIG.StableHeartbeatCount then
				hbConn:Disconnect()
			end
		end)
	end
end

-- EggTool serializer/restore helpers (serialize + restore)
local function et_serialize(player, isFinal, placedEggIds)
	local list = {}
	local bp = player:FindFirstChildOfClass("Backpack")
	local seenUids = {}
	-- ensure placedEggIds is a set table keyed by tostring(id)
	local placedEggIdsLocal = placedEggIds or {}

	if bp then
		for _, tool in ipairs(bp:GetChildren()) do
			if not tool:IsA("Tool") then continue end

			-- Skip server-restored / server-issued / preserved tools so they don't get saved back into profile
			if tool:GetAttribute("ServerRestore") or tool:GetAttribute("ServerIssued") or tool:GetAttribute("PreserveOnServer") or tool:GetAttribute("PreserveOnClient") then
				dprint("et_serialize: skipping server-restored/preserved tool: " .. tostring(tool.Name))
				continue
			end

			local hasEggId = tool:GetAttribute("EggId") or tool:GetAttribute("ToolUniqueId") or tool:GetAttribute("EggTool")
			if not hasEggId then continue end

			-- If this tool corresponds to an egg already placed in world during this snapshot, skip it (dedupe)
			local eggId = tool:GetAttribute("EggId")
			if eggId and placedEggIdsLocal[tostring(eggId)] then
				dprint(("et_serialize: skipping tool for egg placed in world: %s (tool=%s)"):format(tostring(eggId), tostring(tool.Name)))
				continue
			end

			local entry = { nm = tool.Name }
			for attr, short in pairs(ET_ATTR_SHORT) do
				local v = tool:GetAttribute(attr)
				if v ~= nil then entry[short] = v end
			end
			entry[ET_UID_SHORT] = entry[ET_UID_SHORT] or tool:GetAttribute(ET_UID_KEY) or tool:GetAttribute("ToolUniqueId")

			local uidKey = entry[ET_UID_SHORT] and tostring(entry[ET_UID_SHORT]) or nil
			if uidKey then
				if seenUids[uidKey] then
					dprint("et_serialize: skipping duplicate uid=" .. uidKey)
				else
					seenUids[uidKey] = true
					list[#list + 1] = entry
				end
			else
				list[#list + 1] = entry
			end

			if #list >= ETCONFIG.MaxEggTools then break end
		end
	end
	dprint(("EggTool: Serialize count=%d (%s)"):format(#list, tostring(isFinal)))
	return list
end

local function et_restore(player, list)
	if not list or #list == 0 then
		dprint("EggTool: Restore: none")
		return
	end

	local bp = player:FindFirstChildOfClass("Backpack")
	if not bp then
		task.delay(0.25, function()
			if player.Parent then et_restore(player, list) end
		end)
		return
	end

	for _, entry in ipairs(list) do
		if ETCONFIG.AssignUidIfMissingOnRestore and not (entry[ET_UID_SHORT] or entry.uid or entry.ToolUniqueId) then
			entry[ET_UID_SHORT] = HttpService:GenerateGUID(false)
		end

		-- NEW: avoid duplicating egg tools if one with same UID already exists
		local uid = entry[ET_UID_SHORT] or entry.uid or entry.ToolUniqueId
		if uid then
			local existing = find_existing_tool_by_uid(player, uid)
			if existing then
				dprint(("EggTool: Restore skipping existing tool uid=%s name=%s parent=%s"):format(tostring(uid), tostring(existing.Name), tostring(existing.Parent)))
				existing:SetAttribute("PreserveOnServer", true)
				existing:SetAttribute("RestoreStamp", tick())
				existing:SetAttribute("RestoreBatchId", tostring(os.time()) .. "-" .. HttpService:GenerateGUID(false))
				if ETCONFIG.AssignUidIfMissingOnRestore and not existing:GetAttribute("ToolUniqueId") then
					existing:SetAttribute("ToolUniqueId", uid)
				end
				continue
			end
		end

		local tool = et_buildToolFromEntry(entry, et_getTemplate())
		tool:SetAttribute("RestoreStamp", tick())
		tool:SetAttribute("RestoreBatchId", tostring(os.time()) .. "-" .. HttpService:GenerateGUID(false))
		tool.Parent = ServerStorage

		task.delay(RESTORE_STAGE_DELAY, function()
			if not bp.Parent then return end
			if tool and tool.Parent ~= bp then
				pcall(function() tool.Parent = bp end)
			end
		end)

		et_instrumentLifecycle(player, tool)

		if ETCONFIG.RepairAfterRestore then
			-- defer repair to avoid interfering with initial client setup
			task.defer(function()
				pcall(et_repairVisual, tool)

			end)
		end
	end
end

-- GrandInventorySerializer:Serialize (clean, reliable)
function GrandInventorySerializer:Serialize(player, isFinal)
	if not player then return {} end
	dprint(("[GrandInventorySerializer:Serialize] Called for player=%s isFinal=%s"):format(tostring(player.Name), tostring(isFinal)))

	local lockTs = _restoreGrace[player.UserId]
	if lockTs and (tick() - lockTs) <= RESTORE_GRACE_SECONDS and not isFinal then
		local cached = _lastRestoredInventory[player.UserId]
		if cached then
			dprint("[GrandInventorySerializer:Serialize] Returning cached restore snapshot for player=" .. tostring(player.Name))
			return {
				worldSlimes    = cached.worldSlimes             or {},
				worldEggs      = cached.worldEggs      or {},
				foodTools      = cached.foodTools      or {},
				eggTools       = cached.eggTools       or {},
				capturedSlimes = cached.capturedSlimes or {},
			}
		end
	end

	local worldSlimes    = ws_serialize(player, isFinal)
	local worldEggs      = we_serialize(player, isFinal)
	local placedEggIds = {}
	if type(worldEggs) == "table" then
		for _, e in ipairs(worldEggs) do
			if e and e.id then placedEggIds[tostring(e.id)] = true end
		end
	end
	local foodTools      = ft_serialize(player, isFinal)
	local eggTools       = et_serialize(player, isFinal, placedEggIds)
	local capturedSlimes = cs_serialize(player, isFinal)

	local data = {
		worldSlimes    = worldSlimes,
		worldEggs      = worldEggs,
		foodTools      = foodTools,
		eggTools       = eggTools,
		capturedSlimes = capturedSlimes,
	}

	local profile = safe_get_profile(player)

	-- GUARD: if all collected lists are empty but profile already contains items, do NOT overwrite with empties.
	local function all_lists_empty(t)
		if not t then return true end
		return (#(t.worldSlimes or {}) == 0) and (#(t.worldEggs or {}) == 0)
			and (#(t.foodTools or {}) == 0) and (#(t.eggTools or {}) == 0)
			and (#(t.capturedSlimes or {}) == 0)
	end
	if profile and profile.inventory and all_lists_empty(data) and not all_lists_empty(profile.inventory) then
		dprint(("[GrandInventorySerializer:Serialize] Detected non-empty profile.inventory but serializer produced empties — skipping save for %s"):format(player.Name))
		return data
	end

	if profile and profile.meta and profile.meta.lastPreExitSnapshot then
		local age = os.time() - (profile.meta.lastPreExitSnapshot or 0)
		if age >= 0 and age < 30 and not isFinal then
			dprint(("[GrandInventorySerializer:Serialize] Skipping periodic save because recent pre-exit snapshot exists (age=%.1fs) for %s"):format(age, player.Name))
			return data
		end
	end

	if profile then
		profile.inventory = profile.inventory or {}
		profile.inventory.worldSlimes    = data.worldSlimes
		profile.inventory.worldEggs      = data.worldEggs
		profile.inventory.foodTools      = data.foodTools
		profile.inventory.eggTools       = data.eggTools
		profile.inventory.capturedSlimes = data.capturedSlimes

		if isFinal then
			profile.meta = profile.meta or {}
			profile.meta.lastPreExitSnapshot = os.time()
		end

		local ok, err = pcall(function()
			PlayerProfileService.SaveNow(player, isFinal and "GrandInventoryFinal" or "GrandInventoryUpdate")
		end)
		if not ok then
			warn("[GrandInventorySerializer:Serialize] SaveNow failed for player=" .. tostring(player.Name) .. " err=" .. tostring(err))
		end

		if isFinal then
			local ok2, err2 = pcall(function()
				PlayerProfileService.ForceFullSaveNow(player, "GrandInventoryFinal")
			end)
			if not ok2 then
				warn("[GrandInventorySerializer:Serialize] ForceFullSaveNow failed for player=" .. tostring(player.Name) .. " err=" .. tostring(err2))
			end
		end
	else
		dprint("[GrandInventorySerializer:Serialize] No profile found for player: " .. tostring(player.Name))
	end

	return data
end

-- Cleanup orphaned slimes in world and player plot
local function ws_cleanupOrphanedSlimes(player, validSlimeIds)
	if not player or type(validSlimeIds) ~= "table" then return end
	local userId = player.UserId
	local function isOrphan(slime)
		local sid = slime:GetAttribute("SlimeId")
		return sid and not validSlimeIds[sid]
	end

	for _, plot in ipairs(Workspace:GetChildren()) do
		if plot:IsA("Model") and plot.Name:match("^Player%d+$") and tostring(plot:GetAttribute("UserId")) == tostring(userId) then
			for _, obj in ipairs(plot:GetChildren()) do
				if obj:IsA("Model") and obj.Name == "Slime" and tostring(obj:GetAttribute("OwnerUserId")) == tostring(userId) then
					if isOrphan(obj) then
						dprint("[GrandInvSer][Cleanup] Destroying orphaned slime in plot: " .. obj:GetFullName())
						pcall(function() obj:Destroy() end)
					end
				end
			end
		end
	end

	for _, obj in ipairs(Workspace:GetChildren()) do
		if obj:IsA("Model") and obj.Name == "Slime" and tostring(obj:GetAttribute("OwnerUserId")) == tostring(userId) then
			if isOrphan(obj) then
				dprint("[GrandInvSer][Cleanup] Destroying stray orphaned slime: " .. obj:GetFullName())
				pcall(function() obj:Destroy() end)
			end
		end
	end
end

-- Clean, robust Restore entrypoint
function GrandInventorySerializer:Restore(player, data)
	if not player then return end
	dprint(("[GrandInventorySerializer:Restore] Called for player=%s"):format(tostring(player.Name)))
	dprint("[GrandInventorySerializer:Restore] Data received: " .. tostring(data and "present" or "nil"))

	-- Log the incoming payload for diagnosis (safe JSON encode)
	if data then
		local ok, j = pcall(function() return HttpService:JSONEncode({
			ws = #((data.worldSlimes) or {}),
			we = #((data.worldEggs) or {}),
			ft = #((data.foodTools) or {}),
			et = #((data.eggTools) or {}),
			cs = #((data.capturedSlimes) or {})
			}) end)
		if ok then dprint("[GrandInventorySerializer:Restore] incoming counts: " .. j) end
	end

	_lastRestoredInventory[player.UserId] = {
		worldSlimes    = data and data.worldSlimes    or {},
		worldEggs      = data and data.worldEggs      or {},
		foodTools      = data and data.foodTools      or {},
		eggTools       = data and data.eggTools       or {},
		capturedSlimes = data and data.capturedSlimes or {},
	}

	_restoreGrace[player.UserId] = tick()
	task.delay(RESTORE_GRACE_SECONDS + 0.1, function()
		_restoreGrace[player.UserId] = nil
		_lastRestoredInventory[player.UserId] = nil
	end)

	local profile = safe_get_profile(player)
	-- Only stamp meta / SaveNow immediately if incoming data contains something meaningful.
	local hasPayload = data and ( (#(data.worldSlimes or {})>0) or (#(data.worldEggs or {})>0) or (#(data.foodTools or {})>0) or (#(data.eggTools or {})>0) or (#(data.capturedSlimes or {})>0) )
	if profile and hasPayload then
		profile.meta = profile.meta or {}
		profile.meta.lastPreExitSnapshot = os.time()
		pcall(function() PlayerProfileService.SaveNow(player, "GrandInventoryRestore_MetaStamp") end)
	else
		dprint(("[GrandInventorySerializer:Restore] Not saving meta/stamp for %s — no payload to persist."):format(player.Name))
	end

	if data then
		if data.worldSlimes    then ws_restore(player, data.worldSlimes) end
		if data.worldEggs      then we_restore(player, data.worldEggs) end
		if data.foodTools      then ft_restore(player, data.foodTools) end
		if data.eggTools       then et_restore(player, data.eggTools) end
		if data.capturedSlimes then cs_restore(player, data.capturedSlimes) end
	end

	-- Avoid unconditional save that may write empties; only save if we actually had payload and staged meta above
	if hasPayload and profile then
		pcall(function() PlayerProfileService.SaveNow(player, "GrandInventoryRestore") end)
	else
		dprint(("[GrandInventorySerializer:Restore] Skipping unconditional SaveNow for %s (no payload)."):format(player.Name))
	end
end

-- Should we skip lifecycle-driven destruction for this instance?
local function shouldSkipLifecycleDestroy(inst)
	if not inst or type(inst.IsA) ~= "function" then return false end
	if not inst.GetAttribute then return false end

	if inst:GetAttribute("PreserveOnServer")
		or inst:GetAttribute("PreserveOnClient")
		or inst:GetAttribute("ServerRestore")
		or inst:GetAttribute("ServerIssued") then

		return true
	end

	local stamp = inst:GetAttribute("RestoreStamp")
	if type(stamp) == "number" then
		local graceSeconds = RESTORE_GRACE_SECONDS or 3
		if tick() - stamp <= graceSeconds then
			return true
		end
	end

	return false
end

-- Ensure et_instrumentLifecycle fallback exists
if type(et_instrumentLifecycle) ~= "function" then
	et_instrumentLifecycle = function(player, tool)
		if type(cs_instrumentLifecycle) == "function" then
			pcall(cs_instrumentLifecycle, player, tool)
		end
	end
end

local StagedToolManager = require(game.ServerScriptService.Modules.StagedToolManager)

return GrandInventorySerializer -- EOF