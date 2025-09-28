-- FoodService (dynamic lookup, explicit ToolTemplates priority, verbose debug on failure)
-- Robust lookup + debug + folder-child dump when a template is not found.
-- Updated: attachClientLocalScriptIfMissing now prefers cloning bootstrap from the template Tool itself
-- (not just the template container). If the LocalScript asset is missing, a small client wrapper LocalScript
-- will be created on the server that requires ReplicatedStorage.Modules.FoodClient on the client so runtime
-- tools always get the bootstrap.

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService          = game:GetService("RunService")
local HttpService         = game:GetService("HttpService")
local ServerStorage       = game:GetService("ServerStorage")

local Modules             = ServerScriptService:WaitForChild("Modules")
local PlayerProfileService = require(Modules:WaitForChild("PlayerProfileService"))
local InventoryService     = require(Modules:WaitForChild("InventoryService"))

-- Use the consolidated SlimeCore (contains SlimeHungerService)
local SlimeCore = nil
local SlimeHungerService = nil
pcall(function()
	SlimeCore = require(Modules:WaitForChild("SlimeCore"))
	if SlimeCore then
		SlimeHungerService = SlimeCore.SlimeHungerService
	end
end)

local FoodDefinitions = {}
FoodDefinitions.Defaults = {
	RestoreFraction = 0.25,
	FeedBufferBonus = 15,
	Charges = 1,
	Consumable = true,
	CooldownOverride = nil,
	RequireOwnership = true,
	ClientPromptRadius = 8,
	ClientRemoveRadius = 10,
	ClientActivationRadius = 4,
	AutoFeedNearby = false,
	AutoFeedCooldown = 1,
	ShowFullnessPercent = false,
	OnlyWhenNotFull = false,
	FullnessHideThreshold = 0.999,
}
FoodDefinitions.Foods = {
	BasicFood = {
		Label = "Basic Food",
		RestoreFraction = 0.25,
		FeedBufferBonus = 15,
		Charges = 1,
		Rarity = "Common",
	},
}
function FoodDefinitions.resolve(id)
	if not id then return nil end
	local base = FoodDefinitions.Foods[id]
	if not base then return nil end
	local merged = {}
	for k,v in pairs(FoodDefinitions.Defaults) do merged[k]=v end
	for k,v in pairs(base) do merged[k]=v end
	return merged
end

local FoodEffects = {}
function FoodEffects.applyExtraEffects(slime, player, foodDef, context)
	if not foodDef or not foodDef.ExtraEffects then return end
	for _,effect in ipairs(foodDef.ExtraEffects) do
		if effect.Type == "GrowthBoost" then
			FoodEffects.applyTimedScalar(slime, "GrowthRateBoost", effect.Amount, effect.Duration)
		elseif effect.Type == "MutationChanceBonus" then
			FoodEffects.applyTimedScalar(slime, "MutationChanceBonus", effect.Amount, effect.Duration)
		elseif effect.Type == "MovementBoost" then
			FoodEffects.applyTimedScalar(slime, "MovementScalarBonus", effect.Amount, effect.Duration)
		else
			warn("[FoodEffects] Unknown effect type:", effect.Type)
		end
	end
end
function FoodEffects.applyTimedScalar(slime, attrName, amount, duration)
	if not slime or not slime.Parent then return end
	local aggregateName = attrName .. "_Aggregate"
	local current = slime:GetAttribute(aggregateName) or 0
	slime:SetAttribute(aggregateName, current + amount)
	task.delay(duration, function()
		if slime.Parent then
			local cur = slime:GetAttribute(aggregateName) or 0
			slime:SetAttribute(aggregateName, math.max(0, cur - amount))
		end
	end)
end

local FoodService = {}

local CONFIG = {
	Debug                          = true,
	MarkDirtyOnGrant               = true, -- defensive fallback if config copied from other languages
	SaveImmediatelyOnGrant         = true,
	DeferredSaveAfterGrantSeconds  = 0,
	MarkDirtyOnConsume             = true,
	SaveImmediatelyOnConsume       = true,
	PendingPersistPollSeconds      = 4,
	DefaultFeedCooldownSeconds     = 5,
	AttachServerIssuedFlag         = true,
	BackfillOwnerAfterParent       = true,
	FoodTemplatesFolderName        = "FoodTemplates",
	AssetsFolderName               = "Assets",
	FallbackFoodHandleModel        = "SlimeFoodBasic",
	FallbackHandleSize             = Vector3.new(1,1,1),
	GrantLogThrottle               = 0.25,
	FeedLogThrottle                = 0.15,
	VerifyReplication              = true,
	ReplicationWaitHeartbeats      = 4,
	ReplicationDebugListOnFail     = true,
	ClientLocalScriptModulePath    = { "Modules", "FoodClientBase" },
}

local slimeCooldowns = {}
local grantLogLast   = {}
local feedLogLast    = {}
local pendingPersist = {}

local function log(...) if CONFIG.Debug then print("[FoodService]", ...) end end
local function warnf(...) warn("[FoodService]", ...) end

log("FoodService module loaded (debug)")

local function throttled(map, throttle, key)
	local now = os.clock()
	local last = map[key] or 0
	if (now - last) >= throttle then
		map[key] = now
		return true
	end
	return false
end

local function markDirty(player, reason)
	pcall(function() PlayerProfileService.SaveNow(player, reason or "FoodChange") end)
end

local function saveImmediate(player, reason)
	pcall(function()
		if type(PlayerProfileService.ForceFullSaveNow) == "function" then
			PlayerProfileService.ForceFullSaveNow(player, reason or "FoodChange")
		else
			PlayerProfileService.SaveNow(player, reason or "FoodChange")
		end
	end)
end

local function normalizeParams(amountOrOpts, opts)
	local amount = 1
	local o = {}
	if type(amountOrOpts) == "number" then
		amount = math.max(1, math.floor(amountOrOpts))
	elseif type(amountOrOpts) == "boolean" then
		o.skipPersist = amountOrOpts
	elseif type(amountOrOpts) == "table" then
		for k,v in pairs(amountOrOpts) do o[k]=v end
	end
	if type(opts) == "table" then
		for k,v in pairs(opts) do o[k]=v end
	elseif type(opts) == "boolean" then
		o.skipPersist = opts
	end
	return amount, o
end

local function getBackpack(player)
	return player:FindFirstChildOfClass("Backpack")
end

local function buildToolFromTemplateFolder(folder, toolName)
	if not folder then return nil end
	local t = Instance.new("Tool")
	t.Name = toolName or folder.Name or "Food"
	for _,child in ipairs(folder:GetChildren()) do
		local okType = (type(child.IsA) == "function" and child:IsA("LocalScript")) or (type(child.IsA) == "function" and child:IsA("Script")) or (type(child.IsA) == "function" and child:IsA("ModuleScript"))
			or (type(child.IsA) == "function" and child:IsA("BasePart")) or (type(child.IsA) == "function" and child:IsA("Decal")) or (type(child.IsA) == "function" and child:IsA("Attachment"))
			or (type(child.IsA) == "function" and child:IsA("Sound")) or (type(child.IsA) == "function" and child:IsA("MeshPart")) or (type(child.IsA) == "function" and child:IsA("SpecialMesh"))
		if okType then
			local ok, clone = pcall(function() return child:Clone() end)
			if ok and clone then
				clone.Parent = t
			end
		end
	end
	return t
end

-- Diagnostic helper: dump ToolTemplates children for debug
local function dumpToolTemplatesChildren()
	local tt = ReplicatedStorage:FindFirstChild("ToolTemplates")
	if not tt then
		log("ToolTemplates folder not present at dump time")
		return
	end
	local names = {}
	for i,c in ipairs(tt:GetChildren()) do
		table.insert(names, string.format("%d:%s(%s)", i, c.Name, c.ClassName))
	end
	log("ToolTemplates children:", table.concat(names, ", "))
end

-- Re-query ReplicatedStorage on each lookup. Prefer ToolTemplates first.
local function findFoodTemplateInStores(foodId)
	local FOOD_TEMPLATES = ReplicatedStorage:FindFirstChild("ToolTemplates") -- prefer ToolTemplates
	local ASSETS_FOLDER  = ReplicatedStorage:FindFirstChild(CONFIG.AssetsFolderName)
	local otherInventory = ReplicatedStorage:FindFirstChild("InventoryTemplates")
	local foodTemplates = ReplicatedStorage:FindFirstChild(CONFIG.FoodTemplatesFolderName)
	local serverToolTemplates = ServerStorage and ServerStorage:FindFirstChild("ToolTemplates")

	local searchFolders = {
		FOOD_TEMPLATES,
		foodTemplates,
		ASSETS_FOLDER,
		otherInventory,
		serverToolTemplates,
	}

	local function inspectFolder(folder)
		if not folder then return nil, nil end

		-- direct child Tool by name
		if foodId then
			local spec = folder:FindFirstChild(foodId)
			if spec and type(spec.IsA) == "function" and spec:IsA("Tool") then
				return spec, folder
			end
		end

		-- generic fallback tool named "Food"
		local generic = folder:FindFirstChild("Food")
		if generic and type(generic.IsA) == "function" and generic:IsA("Tool") then
			return generic, folder
		end

		-- traverse children for nested tools or folder-based templates
		for _, child in ipairs(folder:GetChildren()) do
			if type(child.IsA) == "function" and child:IsA("Tool") then
				if foodId and tostring(child.Name) == tostring(foodId) then
					return child, folder
				end
				local ok, attr = pcall(function() return child:GetAttribute("FoodId") end)
				if ok and attr and tostring(attr) == tostring(foodId) then
					return child, folder
				end
			end

			if (type(child.IsA) == "function" and child:IsA("Folder")) or (type(child.IsA) == "function" and child:IsA("Model")) then
				-- find tool inside nested folder
				for _, sub in ipairs(child:GetChildren()) do
					if type(sub.IsA) == "function" and sub:IsA("Tool") then
						if foodId and tostring(sub.Name) == tostring(foodId) then
							return sub, child
						end
						local ok2, attr2 = pcall(function() return sub:GetAttribute("FoodId") end)
						if ok2 and attr2 and tostring(attr2) == tostring(foodId) then
							return sub, child
						end
					end
				end

				-- folder-as-template auto-wrap
				if tostring(child.Name) == tostring(foodId) then
					local hasLocalScriptOrPart = false
					for _, c in ipairs(child:GetChildren()) do
						if (type(c.IsA) == "function" and c:IsA("LocalScript")) or (type(c.IsA) == "function" and c:IsA("BasePart")) or (type(c.IsA) == "function" and c:IsA("MeshPart")) or (type(c.IsA) == "function" and c:IsA("Decal")) or (type(c.IsA) == "function" and c:IsA("Sound")) then
							hasLocalScriptOrPart = true
							break
						end
					end
					if hasLocalScriptOrPart then
						local wrapped = buildToolFromTemplateFolder(child, foodId)
						if wrapped then
							pcall(function() wrapped:SetAttribute("_AutoWrappedFromFolder", true) end)
							return wrapped, child
						end
					end
				end
			end
		end

		return nil, nil
	end

	for _, folder in ipairs(searchFolders) do
		local spec, container = inspectFolder(folder)
		if spec then
			return spec, container
		end
	end

	return nil, nil
end






local function getTemplate(foodId)
	-- first check ToolTemplates explicitly (most likely location)
	local tt = ReplicatedStorage:FindFirstChild("ToolTemplates")
	if tt then
		local direct = tt:FindFirstChild(foodId)
		if direct and type(direct.IsA) == "function" and direct:IsA("Tool") then
			pcall(function() log(("getTemplate: foodId=%s -> found=Tool container=%s"):format(foodId, tt:GetFullName())) end)
			return direct, tt
		end
	end

	local found, container = findFoodTemplateInStores(foodId)

	-- If not found, dump ToolTemplates contents to help debug misplacement/typos
	if not found then
		pcall(function()
			log(("getTemplate: foodId=%s -> found=%s container=%s"):format(tostring(foodId), tostring(nil), tostring(nil)))
			dumpToolTemplatesChildren()
		end)
	else
		pcall(function()
			log(("getTemplate: foodId=%s -> found=%s container=%s")
				:format(tostring(foodId),
					tostring(found and found.ClassName or "<nil>"),
					tostring(container and container:GetFullName() or "<nil>")))
		end)
	end

	return found, container
end


-- Helper: search for a Tool instance owned by player with matching identifier (local copy for FoodService)
local function findToolForPlayerById(player, id)
	if not player or not id then return nil end
	local function matches(tool, idVal)
		if not tool then return false end
		local ok, t = pcall(function()
			if type(tool.GetAttribute) == "function" then
				local tu = tool:GetAttribute("ToolUniqueId") or tool:GetAttribute("ToolUid")
				if tu and tostring(tu) == tostring(idVal) then return true end
				local sid = tool:GetAttribute("SlimeId") or tool:GetAttribute("slimeId")
				if sid and tostring(sid) == tostring(idVal) then return true end
			end
			-- child value objects
			local c = tool:FindFirstChild("ToolUniqueId") or tool:FindFirstChild("ToolUid")
			if c and c.Value and tostring(c.Value) == tostring(idVal) then return true end
			local c2 = tool:FindFirstChild("SlimeId") or tool:FindFirstChild("slimeId")
			if c2 and c2.Value and tostring(c2.Value) == tostring(idVal) then return true end
			-- name fallback
			if tostring(tool.Name) == tostring(idVal) then return true end
			return false
		end)
		if ok then return t end
		return false
	end

	-- Check player's Backpack, Character, and workspace under player's model
	local places = {}
	pcall(function() table.insert(places, player:FindFirstChild("Backpack")) end)
	pcall(function() if player.Character then table.insert(places, player.Character) end end)
	pcall(function()
		local wsModel = workspace:FindFirstChild(player.Name)
		if wsModel then table.insert(places, wsModel) end
	end)

	for _, parent in ipairs(places) do
		if parent and parent.GetDescendants then
			for _,inst in ipairs(parent:GetDescendants()) do
				if inst and inst.IsA and inst:IsA("Tool") then
					if matches(inst, id) then return inst end
				end
			end
		end
	end

	return nil
end



-- Improved attachClientLocalScriptIfMissing
-- Behavior summary:
--  - If the tool already contains a LocalScript named "FoodClientBootstrap", do nothing.
--  - Otherwise prefer cloning "FoodClientBootstrap" from the template Tool itself (if provided).
--  - Then try the templateContainer (folder) for a LocalScript.
--  - Then try ReplicatedStorage.Modules.FoodClientBootstrap.
--  - If no LocalScript is available but ReplicatedStorage.Modules contains a ModuleScript named "FoodClient",
--    create a small wrapper LocalScript (server-side) that will require the module on the client and call Attach.
local function attachClientLocalScriptIfMissing(tool, templateTool, templateContainer)
	if not tool or type(tool.GetChildren) ~= "function" then return end

	-- If the canonical bootstrap is already present, return
	for _, child in ipairs(tool:GetChildren()) do
		if type(child.IsA) == "function" and child:IsA("LocalScript") and child.Name == "FoodClientBootstrap" then
			return
		end
	end

	-- 1) Try to clone FoodClientBootstrap from the template Tool itself (preferred)
	if templateTool and type(templateTool.GetChildren) == "function" then
		local candidate = templateTool:FindFirstChild("FoodClientBootstrap")
		if candidate and type(candidate.IsA) == "function" and candidate:IsA("LocalScript") then
			local ok, clone = pcall(function() return candidate:Clone() end)
			if ok and clone then
				clone.Parent = tool
				return
			end
		end
		-- also allow any LocalScript present in the template tool to be used if bootstrap named script not present
		for _, child in ipairs(templateTool:GetChildren()) do
			if type(child.IsA) == "function" and child:IsA("LocalScript") then
				local ok, clone = pcall(function() return child:Clone() end)
				if ok and clone then
					clone.Parent = tool
					return
				end
			end
		end
	end

	-- 2) Try to clone FoodClientBootstrap from templateContainer (folder)
	if templateContainer and type(templateContainer.GetChildren) == "function" then
		local candidate = templateContainer:FindFirstChild("FoodClientBootstrap")
		if candidate and type(candidate.IsA) == "function" and candidate:IsA("LocalScript") then
			local ok, clone = pcall(function() return candidate:Clone() end)
			if ok and clone then
				clone.Parent = tool
				return
			end
		end
		-- fallback: clone any LocalScript from the container if present
		for _, child in ipairs(templateContainer:GetChildren()) do
			if type(child.IsA) == "function" and child:IsA("LocalScript") then
				local ok, clone = pcall(function() return child:Clone() end)
				if ok and clone then
					clone.Parent = tool
					return
				end
			end
		end
	end

	-- 3) Look in ReplicatedStorage.Modules for canonical bootstrap or module
	local rsModules = ReplicatedStorage:FindFirstChild("Modules")
	if rsModules then
		local template = rsModules:FindFirstChild("FoodClientBootstrap")
		if template and type(template.IsA) == "function" and template:IsA("LocalScript") then
			local ok, clone = pcall(function() return template:Clone() end)
			if ok and clone then
				clone.Parent = tool
				return
			end
		end

		-- If canonical LocalScript absent, but FoodClient ModuleScript exists, create a wrapper LocalScript.
		local mod = rsModules:FindFirstChild("FoodClient")
		if mod and type(mod.IsA) == "function" and mod:IsA("ModuleScript") then
			local ok, wrapper = pcall(function()
				local ls = Instance.new("LocalScript")
				ls.Name = "FoodClientBootstrap"
				ls.Source = [[
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local localPlayer = Players.LocalPlayer
if not localPlayer then return end
local modules = ReplicatedStorage:WaitForChild("Modules")
local ok, FoodClient = pcall(function() return require(modules:WaitForChild("FoodClient")) end)
if ok and FoodClient and type(FoodClient.Attach) == "function" then
	pcall(function() FoodClient.Attach(script.Parent) end)
end
]]
				return ls
			end)
			if ok and wrapper then
				wrapper.Parent = tool
				return
			end
		end
	end

	-- Nothing to attach
	local containerName = "<nil>"
	if templateContainer then
		local ok, full = pcall(function() return templateContainer:GetFullName() end)
		if ok and full then containerName = full end
	end
	warn(("[FoodService] No FoodClient bootstrap available to attach to tool '%s' (templateContainer=%s)"):format(
		tostring(tool.Name), tostring(containerName)))
end

local function ensureVisualHandle(tool, def)
	if tool:FindFirstChild("Handle") then return end
	local ASSETS_FOLDER  = ReplicatedStorage:FindFirstChild(CONFIG.AssetsFolderName)
	if def and def.VisualModel and ASSETS_FOLDER then
		local model = ASSETS_FOLDER:FindFirstChild(def.VisualModel)
		if model and type(model.IsA) == "function" and model:IsA("Model") then
			local c = model:Clone()
			local prim = c.PrimaryPart or c:FindFirstChildWhichIsA("BasePart")
			if prim then prim.Name = "Handle" end
			for _,child in ipairs(c:GetChildren()) do child.Parent = tool end
			c:Destroy()
			return
		end
	end
	local h = Instance.new("Part")
	h.Name = "Handle"
	h.Size = CONFIG.FallbackHandleSize
	h.TopSurface = Enum.SurfaceType.Smooth
	h.BottomSurface = Enum.SurfaceType.Smooth
	h.Parent = tool
end

local function createFoodTool(player, foodId, def)
	local template, templateContainer = getTemplate(foodId)

	pcall(function()
		log(("createFoodTool: foodId=%s template=%s templateParent=%s")
			:format(tostring(foodId),
				tostring(template and (template.ClassName .. "('"..tostring(template.Name).."')") or "<nil>"),
				tostring((template and template.Parent and (pcall(function() return template.Parent:GetFullName() end) and template.Parent:GetFullName() or "<parent>")) or (templateContainer and (pcall(function() return templateContainer:GetFullName() end) and templateContainer:GetFullName() or "<container>") or "<nil>"))))
	end)

	local tool
	if template then
		tool = template:Clone()
	else
		tool = Instance.new("Tool")
		tool.Name = foodId
		warnf("No template for foodId="..tostring(foodId).."; using fallback tool.")
	end

	pcall(function() tool:SetAttribute("FoodItem", true) end)
	pcall(function() tool:SetAttribute("FoodId", foodId) end)
	pcall(function() tool:SetAttribute("RestoreFraction", def.RestoreFraction) end)
	pcall(function() tool:SetAttribute("FeedBufferBonus", def.FeedBufferBonus) end)
	pcall(function() tool:SetAttribute("Consumable", def.Consumable) end)
	pcall(function() tool:SetAttribute("Charges", def.Charges) end)
	pcall(function() tool:SetAttribute("StableHeartbeats", 6) end)
	if def.CooldownOverride then
		pcall(function() tool:SetAttribute("FeedCooldownOverride", def.CooldownOverride) end)
	end
	if CONFIG.AttachServerIssuedFlag then
		pcall(function() tool:SetAttribute("ServerIssued", true) end)
	end
	pcall(function() tool:SetAttribute("OwnerUserId", player.UserId) end)
	pcall(function() tool:SetAttribute("ToolUniqueId", HttpService:GenerateGUID(false)) end)
	pcall(function() tool:SetAttribute("PersistentFoodTool", true) end)

	ensureVisualHandle(tool, def)
	-- pass both the template tool and the templateContainer so the attach function can prefer the correct source
	attachClientLocalScriptIfMissing(tool, template, templateContainer)

	tool.Destroying:Connect(function()
		if CONFIG.Debug then
			print("[FoodService][Debug] Tool Destroying:", tool.Name, "FoodId:", foodId, "Parent:", tostring(tool.Parent))
			if tool:GetAttribute("ServerRestore") or tool:GetAttribute("PersistentFoodTool") then
				warnf(string.format("Diagnostic: Food tool %s (FoodId=%s) destroyed server-side (PersistentFoodTool=true)", tool.Name, foodId))
			end
		end
	end)

	return tool
end

local function listBackpack(player)
	local bp = getBackpack(player)
	if not bp then
		print("[FoodService][DebugList] No backpack for", player.Name)
		return
	end
	local lines={}
	for _,t in ipairs(bp:GetChildren()) do
		if type(t.IsA) == "function" and t:IsA("Tool") then
			table.insert(lines, string.format("%s(Food=%s uid=%s)", t.Name, tostring(t:GetAttribute("FoodId")), tostring(t:GetAttribute("ToolUniqueId"))))
		end
	end
	print("[FoodService][DebugList]", player.Name, table.concat(lines, "; "))
end
FoodService.DebugListServerBackpack = listBackpack

local function verifyReplication(player, tool)
	if not CONFIG.VerifyReplication then return end
	for _=1, CONFIG.ReplicationWaitHeartbeats do
		if not tool.Parent then
			RunService.Heartbeat:Wait()
		else
			local bp = getBackpack(player)
			if bp and tool:IsDescendantOf(bp) then return end
			if player.Character and tool:IsDescendantOf(player.Character) then return end
			RunService.Heartbeat:Wait()
		end
	end
	if CONFIG.Debug then
		warnf("Replication verification failed for tool "..tostring(tool.Name))
		if CONFIG.ReplicationDebugListOnFail then
			listBackpack(player)
		end
	end
end

function FoodService.GiveFood(player, foodId, amountOrOpts, opts)
	if not player or not player.Parent then return nil end
	local amount, options = normalizeParams(amountOrOpts, opts)
	local backpack = getBackpack(player)
	if not backpack then
		warnf("Backpack missing for "..player.Name)
		return nil
	end
	local def = FoodDefinitions.resolve(foodId)
	if not def then
		warnf("Unknown foodId "..tostring(foodId))
		return nil
	end

	local granted = {}
	for i=1, amount do
		local tool = createFoodTool(player, foodId, def)
		tool.Parent = backpack

		if CONFIG.BackfillOwnerAfterParent and not tool:GetAttribute("OwnerUserId") then
			tool:SetAttribute("OwnerUserId", player.UserId)
		end

		pcall(function()
			tool:SetAttribute("RecentlyPlacedSaved", true)
			tool:SetAttribute("RecentlyPlacedSavedAt", os.time())
		end)

		if throttled(grantLogLast, CONFIG.GrantLogThrottle, player.UserId.."|"..foodId) then
			log(("Granted %s foodId=%s Charges=%s (x%d)"):format(player.Name, foodId, tostring(tool:GetAttribute("Charges")), amount))
		end
		verifyReplication(player, tool)
		table.insert(granted, tool)

		local foodItemData = {
			FoodId = foodId,
			ToolUniqueId = tool:GetAttribute("ToolUniqueId"),
			Charges = tool:GetAttribute("Charges"),
			ServerIssued = true,
			GrantedAt = os.time(),
			-- canonical id fields to prevent serializer/other code from inventing alternate ids
			id = tool:GetAttribute("ToolUniqueId"),
			uid = tool:GetAttribute("ToolUniqueId"),
			-- helpful clarity fields
			OwnerUserId = player.UserId,
			RestoreFraction = tool:GetAttribute("RestoreFraction"),
			FeedBufferBonus = tool:GetAttribute("FeedBufferBonus"),
			Consumable = tool:GetAttribute("Consumable"),
		}

		pcall(function()
			if type(PlayerProfileService.AddInventoryItem) == "function" then
				PlayerProfileService.AddInventoryItem(player, "foodTools", foodItemData)
			end
		end)

		local okInvAdd, invAddErr = pcall(function()
			if InventoryService and type(InventoryService.AddInventoryItem) == "function" then
				return InventoryService.AddInventoryItem(player, "foodTools", foodItemData)
			end
		end)
		if not okInvAdd then
			warnf("[FoodService] InventoryService.AddInventoryItem failed: %s", tostring(invAddErr))
		else
			pcall(function()
				if InventoryService and type(InventoryService.EnsureEntryHasId) == "function" then
					InventoryService.EnsureEntryHasId(player, "foodTools", tool:GetAttribute("ToolUniqueId"), foodItemData)
				end
			end)
		end
	end

	if not options.skipPersist then
		if CONFIG.MarkDirtyOnGrant then
			markDirty(player, amount>1 and "FoodBatchGrant" or "FoodGrant")
		end

		if CONFIG.SaveImmediatelyOnGrant or options.immediateOverride then
			local okSync, syncErr = pcall(function()
				if InventoryService and type(InventoryService.UpdateProfileInventory) == "function" then
					InventoryService.UpdateProfileInventory(player)
				end
			end)
			if not okSync then
				warnf("[FoodService] InventoryService.UpdateProfileInventory failed: %s", tostring(syncErr))
			end

			saveImmediate(player, amount>1 and "FoodBatchGrantImmediate" or "FoodGrantImmediate")
			if CONFIG.DeferredSaveAfterGrantSeconds > 0 then
				task.delay(CONFIG.DeferredSaveAfterGrantSeconds, function()
					if player.Parent then saveImmediate(player, "FoodGrantDeferredConfirm") end
				end)
			end
		end
	end

	return (amount==1) and granted[1] or granted
end

function FoodService.GiveFoods(player, foodIdList, opts)
	if not player or not player.Parent or type(foodIdList)~="table" then return {} end
	local _, options = normalizeParams(nil, opts)
	local all={}
	for _,fid in ipairs(foodIdList) do
		local tool = FoodService.GiveFood(player, fid, { skipPersist=true })
		if tool then table.insert(all, tool) end
	end
	if not options.skipPersist then
		if CONFIG.MarkDirtyOnGrant then markDirty(player, "FoodBatchGrant") end
		if CONFIG.SaveImmediatelyOnGrant or options.immediateOverride then
			pcall(function()
				if InventoryService and type(InventoryService.UpdateProfileInventory) == "function" then
					InventoryService.UpdateProfileInventory(player)
				end
			end)
			saveImmediate(player, "FoodBatchGrantImmediate")
		end
	end
	return all
end

local function toolValidForPlayer(player, tool)
	if not tool or not (type(tool.IsA) == "function" and tool:IsA("Tool")) then return false, "Invalid tool" end
	local bp = getBackpack(player)
	local inChar = player.Character and tool:IsDescendantOf(player.Character)
	local inBP   = bp and tool:IsDescendantOf(bp)
	if not (inChar or inBP) then return false, "Not in char/backpack" end
	if not tool:GetAttribute("FoodItem") then return false, "Missing FoodItem attr" end
	if tool:GetAttribute("OwnerUserId") and tool:GetAttribute("OwnerUserId") ~= player.UserId then
		return false, "Owner mismatch"
	end
	if not tool:GetAttribute("FoodId") then return false, "Missing FoodId" end
	return true
end

local function slimeOwnershipOk(player, slime, requireOwner)
	if not slime or not (type(slime.IsA) == "function" and slime:IsA("Model")) or slime.Name~="Slime" then
		return false, "Not a slime"
	end
	if not slime.Parent then return false, "Removed" end
	if requireOwner and slime:GetAttribute("OwnerUserId") ~= player.UserId then
		return false, "Ownership mismatch"
	end
	return true
end

local function consumeCharge(tool)
	local charges = tool:GetAttribute("Charges")
	if charges == nil then return false end
	charges -= 1
	if charges <= 0 then
		if CONFIG.Debug then
			print("[FoodService][DestroyTrace] Destroying tool due to zero charges:", tool.Name, "ToolUniqueId:", tool:GetAttribute("ToolUniqueId"))
			for _,attr in ipairs({"FoodItem","FoodId","OwnerUserId","PersistentFoodTool","ServerIssued"}) do
				print("  ", attr, "=", tostring(tool:GetAttribute(attr)))
			end
			print(debug.traceback())
		end
		tool:SetAttribute("Charges", 0)
		tool:Destroy()
	else
		tool:SetAttribute("Charges", charges)
	end
	return true
end

local function applyFeedBuffer(slime, bonus)
	if (bonus or 0) <= 0 then return end
	local cur = slime:GetAttribute("FeedBufferSeconds") or 0
	local cap = slime:GetAttribute("FeedBufferMax") or 0
	local nv  = cur + bonus
	if cap > 0 then nv = math.min(nv, cap) end
	slime:SetAttribute("FeedBufferSeconds", nv)
end

function FoodService.HandleFeed(player, slime, tool)
	local okT, reasonT = toolValidForPlayer(player, tool); if not okT then return false, reasonT end
	local fid = tool:GetAttribute("FoodId")
	local def = FoodDefinitions.resolve(fid); if not def then return false, "Unknown food def" end
	local okS, reasonS = slimeOwnershipOk(player, slime, def.RequireOwnership); if not okS then return false, reasonS end

	-- Use SlimeCore's feeding API (SlimeCore.FeedSlime) if available
	if not SlimeCore or type(SlimeCore.FeedSlime) ~= "function" then
		return false, "Hunger service missing"
	end

	local now = os.time()
	local last = slimeCooldowns[slime] or 0
	local cd = tool:GetAttribute("FeedCooldownOverride") or def.CooldownOverride or CONFIG.DefaultFeedCooldownSeconds
	if now - last < cd then
		return false, ("Cooldown %.1fs left"):format(cd - (now - last))
	end

	local restore = math.clamp(tool:GetAttribute("RestoreFraction") or def.RestoreFraction or 0, 0, 1)
	local before = slime:GetAttribute("FedFraction")

	-- Attempt feeding via SlimeCore API
	local okFeed = SlimeCore.FeedSlime(slime, restore)
	if not okFeed then return false, "Feed rejected" end
	local after = slime:GetAttribute("FedFraction")

	-- Apply feed buffer and extra effects
	applyFeedBuffer(slime, tool:GetAttribute("FeedBufferBonus") or def.FeedBufferBonus)
	FoodEffects.applyExtraEffects(slime, player, def, {
		restoreFractionApplied = restore,
		before = before,
		after  = after,
	})

	slimeCooldowns[slime] = now

	local consumed = false
	if tool:GetAttribute("Consumable") then
		-- capture identifying ids before tool may be destroyed
		local toolUid = tool:GetAttribute("ToolUniqueId") or tool:GetAttribute("ToolUid")
		local ownerUserId = tool:GetAttribute("OwnerUserId") or player.UserId

		-- Remove inventory entry (profile/state) first (immediate) so persistent state is updated before tool destruction
		pcall(function()
			if type(PlayerProfileService.RemoveInventoryItem) == "function" then
				PlayerProfileService.RemoveInventoryItem(player, "foodTools", "ToolUniqueId", toolUid)
			end
		end)

		local okInvRem, invRemErr = pcall(function()
			if InventoryService and type(InventoryService.RemoveInventoryItem) == "function" then
				-- request immediate removal/persist of this tool id (best-effort)
				return InventoryService.RemoveInventoryItem(player, "foodTools", "ToolUniqueId", toolUid, { immediate = true })
			end
		end)
		if not okInvRem then
			warnf("[FoodService] InventoryService.RemoveInventoryItem failed: %s", tostring(invRemErr))
		end

		-- Also attempt to remove the tool instance from character/backpack immediately so it's not present on next join
		pcall(function()
			-- prefer InventoryService safe removal helper if available
			local foundTool = nil
			-- try local finder first (fast, avoids cross-module dependency)
			local okFindLocal, localTool = pcall(function() return findToolForPlayerById(player, toolUid) end)
			if okFindLocal and localTool then
				foundTool = localTool
			else
				-- fallback to InventoryService's potential helper (if it exposes one)
				local okHas, okRes = pcall(function() return InventoryService and InventoryService.FindToolForPlayerById end)
				if okHas and type(okRes) == "function" then
					local ok2, inst2 = pcall(function() return okRes(player, toolUid) end)
					if ok2 and inst2 then foundTool = inst2 end
				end
			end

			if foundTool then
				if InventoryService and InventoryService._safeRemoveOrDefer then
					pcall(function() InventoryService._safeRemoveOrDefer(foundTool, "FoodConsumed", { force = true, grace = 0.2 }) end)
				else
					pcall(function() foundTool.Parent = nil end)
					pcall(function() foundTool:Destroy() end)
				end
			else
				-- fallback: if the server-side reference 'tool' is parented, detach/destroy safely
				if tool and tool.Parent then
					pcall(function() tool.Parent = nil end)
					pcall(function() tool:Destroy() end)
				end
			end
		end)

		consumed = true
	end

	if throttled(feedLogLast, CONFIG.FeedLogThrottle, player.UserId.."|"..tostring(slime:GetAttribute("SlimeId") or "")) then
		log(("Feed %s Food=%s +%.0f%% (%.2f->%.2f) consumed=%s")
			:format(player.Name, fid, restore*100, before or -1, after or -1, tostring(consumed)))
	end

	if CONFIG.MarkDirtyOnConsume then
		markDirty(player, "FoodConsume")
	end

	if CONFIG.SaveImmediatelyOnConsume then
		pcall(function()
			if InventoryService and type(InventoryService.UpdateProfileInventory) == "function" then
				InventoryService.UpdateProfileInventory(player)
			end
		end)
		saveImmediate(player, "FoodConsumeImmediate")
	end

	return true
end

--[[ --- FEED REMOTE LOGIC (NEW) ---
	Allows SlimeCaptureUI Feed button to call FeedRemote:FireServer(slime, tool)
	Returns result to client via FeedResult remote.
--]]

local FeedRemote    = ReplicatedStorage:FindFirstChild("FeedSlime")
local FeedResult    = ReplicatedStorage:FindFirstChild("FeedResult")

if FeedRemote and typeof(FeedRemote) == "Instance" and FeedRemote:IsA("RemoteEvent") then
	FeedRemote.OnServerEvent:Connect(function(player, slime, tool)
		local success, msg = false, ""
		local ok, err = pcall(function()
			success = FoodService.HandleFeed(player, slime, tool)
			if not success then
				msg = "Feed failed"
			else
				msg = "Fed!"
			end
		end)
		if not ok then
			success = false
			msg = err or "Exception"
		end
		-- Optionally send feedback to client
		if FeedResult and typeof(FeedResult) == "Instance" and FeedResult:IsA("RemoteEvent") then
			FeedResult:FireClient(player, { success = success, message = msg })
		end
	end)
end

FoodService.Definitions = FoodDefinitions
FoodService.Effects = FoodEffects

return FoodService