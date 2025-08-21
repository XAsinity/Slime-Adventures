-- GrandInventorySerializer.lua
-- Version: v1.0-grand-unified
-- Aggregates: WorldSlime, WorldEgg, FoodTool, EggTool, CapturedSlime serializers
-- Provides a single entry point: Serialize(player, isFinal), Restore(player, data)
-- Each sub-serializer is namespaced; config is unified.
-- No logic is left out; all features and configs preserved.

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace           = game:GetService("Workspace")
local RunService          = game:GetService("RunService")
local HttpService         = game:GetService("HttpService")

local GrandInventorySerializer = { Name = "grandInventory" }

-- Unified config
GrandInventorySerializer.CONFIG = {
	Debug = true,
	-- WorldSlime
	WorldSlime = {
		MaxWorldSlimesPerPlayer  = 60,
		UseLocalCoords           = true,
		DedupeOnSerialize        = true,
		DedupeOnRestore          = true,
		SkipSecondPassIfComplete = true,
		MarkWorldSlimeAttribute  = true,
	},
	-- WorldEgg
	WorldEgg = {
		MaxWorldEggsPerPlayer = 60,
		UseLocalCoords = true,
		OfflineEggProgress = true,
		TemplateFolders = { "Assets", "EggTemplates", "WorldEggs" },
		DefaultTemplateName = "Egg",
		RestoreEggsReady = false,
	},
	-- FoodTool
	FoodTool = {
		MaxFood                  = 120,
		TemplateFolders          = { "FoodTemplates", "Assets", "InventoryTemplates" },
		FallbackHandleSize       = Vector3.new(1,1,1),
		InstrumentLifeCycle      = true,
		LifeCycleWatchSeconds    = 5,
		FastAuditDelay           = 0.30,
		PostRestoreAuditDelay    = 0.85,
		EnablePostRestoreAudit   = true,
		EnableRebuildOnMissing   = true,
		RequireStableHeartbeats  = true,
		StableHeartbeatCount     = 6,
		AggregationMode          = "individual",
	},
	-- EggTool
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
	-- CapturedSlime
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
local ws_lastSnapshot = {}
local ws_liveIndex = {}
local ws_restoredOnce = {}

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
		if inst:IsA("Model")
			and inst.Name=="Slime"
			and inst:GetAttribute("OwnerUserId")==player.UserId
			and not inst:GetAttribute("Retired")
			and not inst:FindFirstAncestorWhichIsA("Tool") then
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
	local slimes=ws_scan(player)
	local list={}
	local seen={}
	local now=os.time()
	local plot, origin
	for _,m in ipairs(Workspace:GetChildren()) do
		if m:IsA("Model") and m:GetAttribute("UserId")==player.UserId and m.Name:match("^Player%d+$") then
			plot=m; break
		end
	end
	if plot then
		local zone=plot:FindFirstChild("SlimeZone")
		if zone and zone:IsA("BasePart") then origin=zone end
	end
	for _,m in ipairs(slimes) do
		local sid=m:GetAttribute("SlimeId")
		if WSCONFIG.DedupeOnSerialize and sid and seen[sid] then
			dprint("Skip duplicate live slime SlimeId="..sid)
		else
			local prim=m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart")
			if prim then
				local cf=prim.CFrame
				local entry={ px=cf.X, py=cf.Y, pz=cf.Z }
				if WSCONFIG.UseLocalCoords and origin then
					local lcf=origin.CFrame:ToObjectSpace(cf)
					entry.lpx, entry.lpy, entry.lpz = lcf.X,lcf.Y,lcf.Z
					entry.lry = math.atan2(-lcf.LookVector.X, -lcf.LookVector.Z)
				else
					entry.ry = math.atan2(-cf.LookVector.X, -cf.LookVector.Z)
				end
				for attr,short in pairs(WS_ATTR_MAP) do
					local v=m:GetAttribute(attr)
					if v~=nil then
						if colorKeys[short] and typeof(v)=="Color3" then
							v=ws_colorToHex(v)
						end
						entry[short]=v
					end
				end
				entry.id = sid
				entry.lg = now
				list[#list+1]=entry
				if sid then seen[sid]=true end
				if #list >= WSCONFIG.MaxWorldSlimesPerPlayer then
					dprint("MaxWorldSlimesPerPlayer reached.")
					break
				end
			end
		end
	end
	if #list>0 then
		ws_lastSnapshot[player.UserId]={ list=list, t=os.clock() }
	elseif isFinal then
		local snap=ws_lastSnapshot[player.UserId]
		if snap and snap.list and #snap.list>0 then
			dprint(("Final: using cached worldSlimes snapshot count=%d"):format(#snap.list))
			list = snap.list
		end
	end
	dprint(("WorldSlime: Serialize player=%s final=%s count=%d"):format(player.Name, tostring(isFinal), #list))
	return list
end
local function ws_restore(player, list)
	if not list or #list==0 then
		dprint("WorldSlime: Restore: no entries")
		return
	end
	if ws_restoredOnce[player] and WSCONFIG.SkipSecondPassIfComplete then
		local allPresent=true
		for _,e in ipairs(list) do
			local sid=e.id
			if sid then
				local idx=ws_liveIndex[player.UserId]
				if not (idx and idx[sid]) then
					allPresent=false; break
				end
			end
		end
		if allPresent then
			dprint("WorldSlime: Restore skipped (already present).")
			return
		end
	end
	ws_scan(player)
	local plot, origin
	for _,m in ipairs(Workspace:GetChildren()) do
		if m:IsA("Model") and m:GetAttribute("UserId")==player.UserId and m.Name:match("^Player%d+$") then
			plot=m; break
		end
	end
	if plot then
		local zone=plot:FindFirstChild("SlimeZone")
		if zone and zone:IsA("BasePart") then origin=zone end
	end
	local parent=plot or Workspace
	local created,reused,skipped=0,0,0
	for _,e in ipairs(list) do
		local sid=e.id
		if sid and WSCONFIG.DedupeOnRestore then
			local idx=ws_liveIndex[player.UserId]
			local existing = idx and idx[sid]
			if existing and existing.Parent then
				local cf
				if origin and e.lpx then
					cf = origin.CFrame * CFrame.new(e.lpx,e.lpy,e.lpz)
				elseif e.px then
					cf = CFrame.new(e.px,e.py,e.pz)
				end
				if cf then pcall(function() existing:PivotTo(cf) end) end
				if WSCONFIG.MarkWorldSlimeAttribute then existing:SetAttribute("WorldSlime", true) end
				ws_applyColors(existing)
				reused += 1
			else
				local slime
				local SlimeFactory
				pcall(function()
					SlimeFactory = require(ServerScriptService.Modules:WaitForChild("SlimeFactory"))
				end)
				if SlimeFactory and SlimeFactory.RestoreFromSnapshot then
					local ok,res = pcall(function()
						return SlimeFactory.RestoreFromSnapshot(e, player, parent)
					end)
					if ok then slime=res end
				end
				if not slime then
					local assets=ReplicatedStorage:FindFirstChild("Assets")
					local tmpl=assets and assets:FindFirstChild("Slime")
					if tmpl and tmpl:IsA("Model") then slime=tmpl:Clone() end
				end
				if slime then
					slime.Parent=parent
					if WSCONFIG.MarkWorldSlimeAttribute then slime:SetAttribute("WorldSlime", true) end
					slime:SetAttribute("SlimeId", sid)
					ws_registerModel(player, slime)
					ws_applyColors(slime)
					local cf
					if origin and e.lpx then
						cf = origin.CFrame * CFrame.new(e.lpx,e.lpy,e.lpz)
					elseif e.px then
						cf = CFrame.new(e.px,e.py,e.pz)
					end
					if cf then pcall(function() slime:PivotTo(cf) end) end
					created += 1
				else
					skipped += 1
				end
			end
		else
			skipped += 1
		end
		if (created + reused) >= WSCONFIG.MaxWorldSlimesPerPlayer then
			dprint("WorldSlime: MaxWorldSlimesPerPlayer reached during restore.")
			break
		end
	end
	dprint(("WorldSlime: Restore complete created=%d reused=%d skipped=%d total=%d"):
		format(created,reused,skipped,created+reused))
	ws_restoredOnce[player]=true
end

-------------------------------------------------------------------------------
-- WorldEgg Serializer
-------------------------------------------------------------------------------
local WECONFIG = GrandInventorySerializer.CONFIG.WorldEgg
local WE_ATTR_MAP = {
	Rarity="ra", ValueBase="vb", ValuePerGrowth="vg", WeightScalar="ws",
	MovementScalar="mv", MutationRarityBonus="mb"
}
local we_lastSnapshot = {}
local function we_findPlayerPlot(player)
	for _,m in ipairs(Workspace:GetChildren()) do
		if m:IsA("Model")
			and m.Name:match("^Player%d+$")
			and m:GetAttribute("UserId")==player.UserId then
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
	local plot = we_findPlayerPlot(player)
	if not plot then
		dprint("[WorldEggSer][Debug] No plot found for player", player.Name)
		return {}, plot, nil
	end
	local origin = we_getPlotOrigin(plot)
	local now = os.time()
	local list = {}
	dprint("[WorldEggSer][Debug] Enumerating plot:", plot:GetFullName(), "for player", player.Name)
	for _,desc in ipairs(plot:GetDescendants()) do
		if desc:IsA("Model") then
			local placed = desc:GetAttribute("Placed")
			local manualHatch = desc:GetAttribute("ManualHatch")
			local ownerUserId = desc:GetAttribute("OwnerUserId")
			local ownerMatch = tostring(ownerUserId) == tostring(player.UserId)
			dprint(("[WorldEggSer][Debug] Candidate: %s | Placed=%s ManualHatch=%s OwnerUserId=%s OwnerMatch=%s")
				:format(desc:GetFullName(), tostring(placed), tostring(manualHatch), tostring(ownerUserId), tostring(ownerMatch)))
			if placed and manualHatch and ownerMatch then
				local prim = desc.PrimaryPart or desc:FindFirstChildWhichIsA("BasePart")
				if prim then
					local eggId = desc:GetAttribute("EggId") or ("Egg_"..math.random(1,1e9))
					local hatchAt = desc:GetAttribute("HatchAt")
					local hatchTime = desc:GetAttribute("HatchTime")
					if hatchAt and hatchTime then
						local remaining = math.max(0, hatchAt - now)
						local cf = prim:GetPivot()
						local e = {
							id = eggId,
							ht = hatchTime,
							ha = hatchAt,
							tr = remaining,
							px = cf.X, py = cf.Y, pz = cf.Z,
							cr = desc:GetAttribute("PlacedAt") or (now - hatchTime),
						}
						if origin then
							local lcf = origin.CFrame:ToObjectSpace(cf)
							e.lpx, e.lpy, e.lpz = lcf.X, lcf.Y, lcf.Z
						end
						for attr,short in pairs(WE_ATTR_MAP) do
							local v=desc:GetAttribute(attr)
							if v~=nil then e[short]=v end
						end
						list[#list+1] = e
						dprint("[WorldEggSer][Debug] -- Egg accepted for serialization:", eggId)
					end
				end
			end
		end
	end
	dprint("[WorldEggSer][Debug] Total eggs found for serialization:", #list)
	return list, plot, origin
end
local function we_serialize(player, isFinal)
	local ok, liveList, plot, origin = pcall(function()
		local ll, pl, orp = we_enumeratePlotEggs(player)
		return ll, pl, orp
	end)
	if not ok then
		warn("[WorldEggSer] enumerate error:", liveList)
		liveList={}
	end
	if #liveList>0 then
		we_lastSnapshot[player.UserId] = { list = liveList, t = os.clock() }
	end
	local usedCache=false
	local source="live"
	if isFinal and #liveList==0 then
		local EggService
		pcall(function()
			EggService = require(script.Parent.Parent:FindFirstChild("EggService"))
		end)
		if EggService and EggService.ExportWorldEggSnapshot then
			local exOk, ex = pcall(function()
				return EggService.ExportWorldEggSnapshot(player.UserId)
			end)
			if exOk and ex and #ex>0 then
				local now=os.time()
				local bridge={}
				for _,e in ipairs(ex) do
					bridge[#bridge+1]={
						id=e.eggId, ht=e.hatchTime, ha=e.hatchAt,
						tr=math.max(0,(e.hatchAt or now)-now),
						px=0,py=0,pz=0,
						cr=e.placedAt or (e.hatchAt and (e.hatchAt-e.hatchTime)) or (now-(e.hatchTime or 0)),
						ra=e.rarity, vb=e.valueBase, vg=e.valuePerGrowth,
					}
				end
				liveList=bridge
				usedCache=true
				source="EggServiceSnapshot"
			end
		end
		if #liveList==0 then
			local snap=we_lastSnapshot[player.UserId]
			if snap and #snap.list>0 then
				liveList=snap.list
				usedCache=true
				source="LastSnapshot"
			end
		end
	end
	dprint(("WorldEgg: Serialize player=%s final=%s count=%d usedCache=%s source=%s"):
		format(player.Name, tostring(isFinal), #liveList, tostring(usedCache), source))
	return liveList
end
local function we_restore(player, list)
	if not list or #list==0 then
		dprint("WorldEgg: Restore: none")
		return
	end
	local plot=we_findPlayerPlot(player)
	if not plot then
		dprint("WorldEgg: Restore: no plot (skip)")
		return
	end
	local origin=we_getPlotOrigin(plot)
	local now=os.time()
	local restored=0
	for _,e in ipairs(list) do
		if restored >= WECONFIG.MaxWorldEggsPerPlayer then
			warn("[WorldEggSer] Max reached during restore")
			break
		end
		local template=we_locateEggTemplate(e.id) or we_locateEggTemplate(WECONFIG.DefaultTemplateName)
		local m
		if template then
			m=template:Clone()
		else
			m=Instance.new("Model")
			local part=Instance.new("Part")
			part.Shape=Enum.PartType.Ball
			part.Size=Vector3.new(2,2,2)
			part.Name="Handle"
			part.TopSurface=Enum.SurfaceType.Smooth
			part.BottomSurface=Enum.SurfaceType.Smooth
			part.Parent=m
			m.PrimaryPart=part
		end
		m.Name="Egg"
		m:SetAttribute("EggId", e.id)
		m:SetAttribute("Placed", true)
		m:SetAttribute("ManualHatch", true)
		m:SetAttribute("PlacedAt", e.cr)
		m:SetAttribute("OwnerUserId", player.UserId)
		m:SetAttribute("HatchTime", e.ht)
		for attr,short in pairs(WE_ATTR_MAP) do
			local v=e[short]; if v~=nil then m:SetAttribute(attr,v) end
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
		local prim=m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart")
		if not prim then
			local part=Instance.new("Part")
			part.Name="Handle"
			part.Size=Vector3.new(2,2,2)
			part.Parent=m
			m.PrimaryPart=part
		end
		m.Parent=plot
		local targetCF
		if origin and e.lpx then
			targetCF = origin.CFrame * CFrame.new(e.lpx,e.lpy,e.lpz)
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
local function ft_dprint(...) if FTCONFIG.Debug then print("[FoodSer]", ...) end end
local function ft_qualifies(tool)
	return tool:IsA("Tool") and (tool:GetAttribute("FoodItem") or tool:GetAttribute("FoodId"))
end
local function ft_enumerate(container, out)
	if not container then return end
	for _,c in ipairs(container:GetChildren()) do
		if ft_qualifies(c) then out[#out+1]=c end
	end
end
local function ft_collectFood(player)
	local out={}
	ft_enumerate(player:FindFirstChildOfClass("Backpack"), out)
	if player.Character then ft_enumerate(player.Character, out) end
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
	local t0=os.clock()
	tool.AncestryChanged:Connect(function(_, parent)
		if os.clock()-t0 <= FTCONFIG.LifeCycleWatchSeconds and not parent then
			print(("[FoodSer][LC] %s removed %.2fs after restore"):format(tool.Name, os.clock()-t0))
		end
	end)
	tool.Destroying:Connect(function()
		if os.clock()-t0 <= FTCONFIG.LifeCycleWatchSeconds then
			print(("[FoodSer][LC] %s destroyed %.2fs after restore"):format(tool.Name, os.clock()-t0))
		end
	end)
end
local function ft_serialize(player, isFinal)
	local tools = ft_collectFood(player)
	local list = {}
	ft_dprint(("Serialize mode=%s toolCount=%d final=%s"):format(
		FTCONFIG.AggregationMode, #tools, tostring(isFinal))
	)
	if FTCONFIG.AggregationMode == "individual" then
		for _,tool in ipairs(tools) do
			local entry = { nm = tool.Name }
			for attr, short in pairs(FT_ATTRS) do
				local v = tool:GetAttribute(attr)
				if v ~= nil then entry[short]=v end
			end
			entry.fid = entry.fid or tool:GetAttribute("FoodId") or tool.Name
			if not entry.uid or entry.uid=="" then
				local existing = tool:GetAttribute("ToolUniqueId")
				if existing and existing~="" then
					entry.uid = existing
				else
					entry.uid = HttpService:GenerateGUID(false)
					tool:SetAttribute("ToolUniqueId", entry.uid)
				end
			end
			list[#list+1]=entry
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
	else
		tool.Name = entry.nm or tool.Name
		ft_ensureHandle(tool)
	end
	tool:SetAttribute("FoodItem", true)
	for attr, short in pairs(FT_ATTRS) do
		local v = entry[short]
		if v ~= nil then tool:SetAttribute(attr, v) end
	end
	tool:SetAttribute("FoodId", tool:GetAttribute("FoodId") or entry.fid or tool.Name)
	tool:SetAttribute("OwnerUserId", player.UserId)
	tool:SetAttribute("PersistentFoodTool", true)
	tool:SetAttribute("__FoodSerVersion", FTCONFIG.Version or "1.5.0")
	if not tool:GetAttribute("ToolUniqueId") then
		tool:SetAttribute("ToolUniqueId", entry.uid or HttpService:GenerateGUID(false))
	end
	return tool
end
local function ft_restore(player, list)
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
		local tool = ft_buildTool(e, player)
		if FTCONFIG.RequireStableHeartbeats then
			tool:SetAttribute("StableHeartbeats", 0)
		end
		tool:SetAttribute("RestoreBatchId", batch)
		tool.Parent=backpack
		ft_instrumentLifecycle(player, tool)
		createdEntries[#createdEntries+1]=e
	end
	if FTCONFIG.RequireStableHeartbeats then
		local hb,count
		hb = RunService.Heartbeat:Connect(function()
			count = (count or 0)+1
			for _,t in ipairs(backpack:GetChildren()) do
				if t:IsA("Tool") and t:GetAttribute("RestoreBatchId")==batch then
					local cur=t:GetAttribute("StableHeartbeats") or 0
					if cur < FTCONFIG.StableHeartbeatCount then
						t:SetAttribute("StableHeartbeats", math.min(FTCONFIG.StableHeartbeatCount, cur+1))
					end
				end
			end
			if count >= FTCONFIG.StableHeartbeatCount then
				hb:Disconnect()
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
local function et_instrumentLifecycle(player, tool)
	if not ETCONFIG.InstrumentLifeCycle then return end
	local t0=os.clock()
	tool.AncestryChanged:Connect(function(_, parent)
		if os.clock()-t0 <= ETCONFIG.LifeCycleWatchSeconds then
			if not parent then
				print(("[EggToolSer][LC] %s removed %.2fs after restore"):format(tool.Name, os.clock()-t0))
			elseif not tool:IsDescendantOf(player) then
				print(("[EggToolSer][LC] %s moved outside player %.2fs"):format(tool.Name, os.clock()-t0))
			end
		end
	end)
	tool.Destroying:Connect(function()
		if os.clock()-t0 <= ETCONFIG.LifeCycleWatchSeconds then
			print(("[EggToolSer][LC] %s destroyed %.2fs after restore"):format(tool.Name, os.clock()-t0))
		end
	end)
end
local function et_applyEntry(tool, entry)
	for attr, short in pairs(ET_ATTR_SHORT) do
		local v = entry[short]
		if v ~= nil then
			tool:SetAttribute(attr, v)
		end
	end
	if entry.id and tool:GetAttribute("EggId")==nil then
		tool:SetAttribute("EggId", entry.id)
	end
	if entry.ou and tool:GetAttribute("OwnerUserId")==nil then
		tool:SetAttribute("OwnerUserId", entry.ou)
	end
	local uid = entry[ET_UID_SHORT]
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
	end
	if not tool then
		tool = Instance.new("Tool")
		tool.Name = entry.nm or "Egg"
		et_ensureHandle(tool)
	else
		tool.Name = entry.nm or tool.Name or "Egg"
	end
	et_ensureHandle(tool)
	et_applyEntry(tool, entry)
	tool:SetAttribute("ServerIssued", true)
	tool:SetAttribute("ServerRestore", true)
	if ETCONFIG.AssignUidIfMissingOnRestore and not tool:GetAttribute(ET_UID_KEY) then
		local newUid = entry[ET_UID_SHORT] or HttpService:GenerateGUID(false)
		tool:SetAttribute(ET_UID_KEY, newUid)
		if ETCONFIG.LogAssignedUids then
			dprint("Assign UID on restore: "..tostring(newUid))
		end
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
	tool.Parent=nil
	tool:Destroy()
	local entry={ nm="Egg" }
	for attr,short in pairs(ET_ATTR_SHORT) do
		local v=attrs[attr]; if v~=nil then entry[short]=v end
	end
	if uid then entry[ET_UID_SHORT]=uid end
	local newTool = et_buildToolFromEntry(entry, et_getTemplate())
	newTool.Parent=parent
	if ETCONFIG.RepairLogEach then
		dprint("Repaired placeholder egg tool (EggId="..tostring(attrs.EggId)..")")
	end
end
local function et_collect(player)
	local out={}
	local bp=player:FindFirstChildOfClass("Backpack")
	if bp then
		for _,c in ipairs(bp:GetChildren()) do
			if c:IsA("Tool") and c:GetAttribute("EggId") and not c:GetAttribute("Placed") then
				out[#out+1]=c
			end
		end
	end
	return out
end
local function et_serialize(player, isFinal)
	local tools = et_collect(player)
	local list={}
	for _,tool in ipairs(tools) do
		local uid = tool:GetAttribute(ET_UID_KEY)
		if (not uid) and ETCONFIG.AssignUidIfMissingOnSerialize then
			uid = HttpService:GenerateGUID(false)
			tool:SetAttribute(ET_UID_KEY, uid)
			if ETCONFIG.LogAssignedUids then
				dprint("Assign UID on serialize: "..tostring(uid))
			end
		end
		local entry={ nm = tool.Name }
		for attr,short in pairs(ET_ATTR_SHORT) do
			local v=tool:GetAttribute(attr)
			if v~=nil then entry[short]=v end
		end
		entry.id = entry.id or tool:GetAttribute("EggId")
		if uid then entry[ET_UID_SHORT]=uid end
		list[#list+1]=entry
		if #list >= ETCONFIG.MaxEggTools then
			warn("[EggToolSer] MaxEggTools reached during serialize")
			break
		end
	end
	dprint("EggTool: Serialize count="..#list..(isFinal and " (FINAL)" or ""))
	return list
end

local function findPlayerPlot(player)
	for _,m in ipairs(Workspace:GetChildren()) do
		if m:IsA("Model")
			and m.Name:match("^Player%d+$")
			and m:GetAttribute("UserId")==player.UserId then
			return m
		end
	end
	return nil
end


local function et_restore(player, list)
	if not list or #list==0 then
		dprint("EggTool: Restore: none")
		return
	end
	local bp=player:FindFirstChildOfClass("Backpack")
	if not bp then
		task.delay(0.25,function()
			if player.Parent then et_restore(player, list) end
		end)
		return
	end
	local template = et_getTemplate()
	if template then dprint("EggTool: Template located: "..template:GetFullName()) end
	dprint("EggTool: Restore entries="..#list)
	local restored=0
	for _,entry in ipairs(list) do
		if restored >= ETCONFIG.MaxEggTools then
			warn("[EggToolSer] MaxEggTools reached during restore")
			break
		end
		local tool = et_buildToolFromEntry(entry, template)
		tool.Parent=bp
		et_instrumentLifecycle(player, tool)
		restored += 1
	end
	dprint(("EggTool: Restore complete accepted=%d (multiplicity)"):format(restored))
	if ETCONFIG.RepairAfterRestore then
		for _,tool in ipairs(bp:GetChildren()) do
			if tool:IsA("Tool") and tool:GetAttribute("EggId") and not tool:GetAttribute("Placed") then
				et_repairVisual(tool)
			end
		end
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
		if attr=="Version" then continue end
		local v = entry[short]
		if v~=nil then
			if CS_COLOR_KEYS[short] and type(v)=="string" then
				local c=cs_hexToColor(v); if c then v=c end
			end
			tool:SetAttribute(attr, v)
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
		if ok and clone then tool=clone end
	end
	if not tool then tool=Instance.new("Tool") end
	tool.Name = entry.nm or "CapturedSlime"
	cs_ensureHandle(tool)
	cs_applyEntry(tool, entry)
	return tool
end
local function cs_instrumentLifecycle(player, tool)
	if not CSCONFIG.RequireStableHeartbeats then return end
	local t0=os.clock()
	tool.AncestryChanged:Connect(function(_,parent)
		if os.clock()-t0 <= CSCONFIG.LifeCycleWatchSeconds and not parent then
			print(("[CapSer][LC] %s removed %.2fs after restore"):format(tool.Name, os.clock()-t0))
		end
	end)
	tool.Destroying:Connect(function()
		if os.clock()-t0 <= CSCONFIG.LifeCycleWatchSeconds then
			print(("[CapSer][LC] %s destroyed %.2fs after restore"):format(tool.Name, os.clock()-t0))
		end
	end)
end
local function cs_collect(player)
	local out={}
	local function scan(container)
		if not container then return end
		for _,c in ipairs(container:GetChildren()) do
			if c:IsA("Tool") and (c:GetAttribute("SlimeItem") or c:GetAttribute("SlimeId")) then
				out[#out+1]=c
			end
		end
	end
	scan(player:FindFirstChildOfClass("Backpack"))
	scan(player.Character)
	return out
end
local function cs_serialize(player, isFinal)
	local tools=cs_collect(player)
	local list, seen={}, {}
	for _,tool in ipairs(tools) do
		local slimeId=tool:GetAttribute("SlimeId")
		if slimeId and seen[slimeId] and CSCONFIG.DeduplicateOnRestore then
			-- skip duplicate
		else
			seen[slimeId]=true
			local entry={ ver=CS_ENTRY_VERSION, nm=tool.Name }
			for attr,short in pairs(CS_EXPORT_ATTRS) do
				if attr~="Version" then
					local v=tool:GetAttribute(attr)
					if v~=nil then
						if CS_COLOR_KEYS[short] and typeof(v)=="Color3" then
							v=ws_colorToHex(v)
						end
						entry[short]=v
					end
				end
			end
			entry.id = entry.id or slimeId
			list[#list+1]=entry
			if #list >= CSCONFIG.MaxStored then
				dprint("CapturedSlime: MaxStored reached for "..player.Name)
				break
			end
		end
	end
	dprint("CapturedSlime: Serialize count="..#list..(isFinal and " (FINAL)" or ""))
	return list
end
local function cs_restore(player, list)
	if not list or #list==0 then
		dprint("CapturedSlime: Restore: none")
		return
	end
	local template=cs_getTemplate()
	if template then
		dprint("CapturedSlime: Template found: "..template:GetFullName())
	else
		dprint("CapturedSlime: Template NOT found (fallback).")
	end
	local bp=player:FindFirstChildOfClass("Backpack")
	if not bp then
		task.delay(0.25,function()
			if player.Parent then cs_restore(player, list) end
		end)
		return
	end
	dprint("CapturedSlime: Restore entries="..#list)
	local seen,accepted,skipped={},0,0
	for _,e in ipairs(list) do
		local id=e.id
		if id and seen[id] and CSCONFIG.DeduplicateOnRestore then
			skipped += 1
		else
			seen[id]=true
			if accepted >= CSCONFIG.MaxStored then
				dprint("CapturedSlime: MaxStored reached during restore")
				break
			end
			local tool=cs_buildTool(e)
			tool:SetAttribute("RestoreStamp", os.clock())
			if CSCONFIG.RequireStableHeartbeats then
				tool:SetAttribute("StableHeartbeats",0)
			end
			tool:SetAttribute("RestoreBatchId",1)
			tool.Parent=bp
			cs_instrumentLifecycle(player, tool)
			accepted += 1
		end
	end
	dprint(("CapturedSlime: Restore complete accepted=%d skipped=%d"):format(accepted, skipped))
	if CSCONFIG.RequireStableHeartbeats then
		local hb,count
		hb = RunService.Heartbeat:Connect(function()
			count=(count or 0)+1
			for _,tool in ipairs(bp:GetChildren()) do
				if tool:IsA("Tool") and tool:GetAttribute("SlimeItem") then
					local cur=tool:GetAttribute("StableHeartbeats") or 0
					if cur < CSCONFIG.StableHeartbeatCount then
						tool:SetAttribute("StableHeartbeats", math.min(CSCONFIG.StableHeartbeatCount, cur+1))
					end
				end
			end
			if count >= CSCONFIG.StableHeartbeatCount then
				hb:Disconnect()
			end
		end)
	end
end

-------------------------------------------------------------------------------
-- GRAND SERIALIZER INTERFACE
-------------------------------------------------------------------------------
function GrandInventorySerializer:Serialize(player, isFinal)
	return {
		worldSlimes      = ws_serialize(player, isFinal),
		worldEggs        = we_serialize(player, isFinal),
		foodTools        = ft_serialize(player, isFinal),
		eggTools         = et_serialize(player, isFinal),
		capturedSlimes   = cs_serialize(player, isFinal),
	}
end

function GrandInventorySerializer:Restore(player, data)
	if data.worldSlimes then ws_restore(player, data.worldSlimes) end
	if data.worldEggs then we_restore(player, data.worldEggs) end
	if data.foodTools then ft_restore(player, data.foodTools) end
	if data.eggTools then et_restore(player, data.eggTools) end
	if data.capturedSlimes then cs_restore(player, data.capturedSlimes) end
end

return GrandInventorySerializer