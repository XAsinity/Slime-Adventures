-- FoodService v3.2.1-persist-flag
-- Adds PersistentFoodTool marker & destruction watcher for diagnostics.
-- (Other logic identical to v3.2 except for small additions.)
--
local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService          = game:GetService("RunService")
local HttpService         = game:GetService("HttpService")

local ModulesRS      = ReplicatedStorage:WaitForChild("Modules")
local FoodDefinitions= require(ModulesRS:WaitForChild("FoodDefinitions"))
local FoodEffects    = require(ModulesRS:WaitForChild("FoodEffects"))

local hungerModule = ServerScriptService:FindFirstChild("Modules")
	and ServerScriptService.Modules:FindFirstChild("SlimeHungerService")
	or ServerScriptService:FindFirstChild("SlimeHungerService")
local SlimeHungerService = hungerModule and require(hungerModule)

local PlayerDataService
local function tryPDS()
	if PlayerDataService then return true end
	local ok, mod = pcall(function()
		return require(ServerScriptService.Modules:WaitForChild("PlayerDataService"))
	end)
	if ok then PlayerDataService = mod return true end
	return false
end
tryPDS()

local FoodService = {}

local CONFIG = {
	Debug                          = true,
	MarkDirtyOnGrant               = true,
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
}

local slimeCooldowns = {}
local grantLogLast   = {}
local feedLogLast    = {}
local pendingPersist = {}
local FOOD_TEMPLATES = ReplicatedStorage:FindFirstChild(CONFIG.FoodTemplatesFolderName)
local ASSETS_FOLDER  = ReplicatedStorage:FindFirstChild(CONFIG.AssetsFolderName)

local function log(...) if CONFIG.Debug then print("[FoodService]", ...) end end
local function warnf(...) warn("[FoodService]", ...) end

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
	if not tryPDS() then
		pendingPersist[player.UserId] = true
		return
	end
	PlayerDataService.MarkDirty(player, reason or "FoodChange")
end

local function saveImmediate(player, reason)
	if not tryPDS() then
		pendingPersist[player.UserId] = true
		return
	end
	PlayerDataService.SaveImmediately(player, reason or "FoodChange", { skipWorld=true })
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

task.spawn(function()
	while true do
		task.wait(CONFIG.PendingPersistPollSeconds)
		if next(pendingPersist) ~= nil and tryPDS() then
			for userId,_ in pairs(pendingPersist) do
				local plr = Players:GetPlayerByUserId(userId)
				if plr then
					saveImmediate(plr, "PendingFoodPersistPoll")
				end
				pendingPersist[userId] = nil
			end
		end
	end
end)

local function getTemplate(foodId)
	if FOOD_TEMPLATES then
		local spec = FOOD_TEMPLATES:FindFirstChild(foodId)
		if spec and spec:IsA("Tool") then return spec end
	end
	return nil
end

local function ensureVisualHandle(tool, def)
	if tool:FindFirstChild("Handle") then return end
	if def and def.VisualModel and ASSETS_FOLDER then
		local model = ASSETS_FOLDER:FindFirstChild(def.VisualModel)
		if model and model:IsA("Model") then
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
	local template = getTemplate(foodId)
	local tool
	
	if template then
		tool = template:Clone()
	else
		tool = Instance.new("Tool")
		tool.Name = foodId
		warnf("No template for foodId="..tostring(foodId).."; using fallback tool.")
	end
	tool:SetAttribute("FoodItem", true)
	tool:SetAttribute("FoodId", foodId)
	tool:SetAttribute("RestoreFraction", def.RestoreFraction)
	tool:SetAttribute("FeedBufferBonus", def.FeedBufferBonus)
	tool:SetAttribute("Consumable", def.Consumable)
	tool:SetAttribute("Charges", def.Charges)
	tool:SetAttribute("StableHeartbeats", 6)  -- matches RequiredHeartbeats
	if def.CooldownOverride then
		tool:SetAttribute("FeedCooldownOverride", def.CooldownOverride)
	end
	if CONFIG.AttachServerIssuedFlag then
		tool:SetAttribute("ServerIssued", true)
	end
	tool:SetAttribute("OwnerUserId", player.UserId)
	tool:SetAttribute("ToolUniqueId", HttpService:GenerateGUID(false))
	tool:SetAttribute("PersistentFoodTool", true)
	ensureVisualHandle(tool, def)

	-- Destruction watcher (server) for diagnostics
	tool.Destroying:Connect(function()
		if tool:GetAttribute("ServerRestore") or tool:GetAttribute("PersistentFoodTool") then
			warnf(string.format("Diagnostic: Food tool %s (FoodId=%s) destroyed server-side (PersistentFoodTool=true)", tool.Name, foodId))
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
		if t:IsA("Tool") then
			table.insert(lines, string.format("%s(Food=%s)", t.Name, tostring(t:GetAttribute("FoodId"))))
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
		warnf("Replication verification failed for tool "..tool.Name)
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
		if throttled(grantLogLast, CONFIG.GrantLogThrottle, player.UserId.."|"..foodId) then
			log(("Granted %s foodId=%s Charges=%s (x%d)")
				:format(player.Name, foodId, tostring(tool:GetAttribute("Charges")), amount))
		end
		verifyReplication(player, tool)
		table.insert(granted, tool)
	end

	if not options.skipPersist then
		if CONFIG.MarkDirtyOnGrant then
			markDirty(player, amount>1 and "FoodBatchGrant" or "FoodGrant")
		end
		if CONFIG.SaveImmediatelyOnGrant or options.immediateOverride then
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
			saveImmediate(player, "FoodBatchGrantImmediate")
		end
	end
	return all
end

local function toolValidForPlayer(player, tool)
	if not tool or not tool:IsA("Tool") then return false, "Invalid tool" end
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
	if not slime or not slime:IsA("Model") or slime.Name~="Slime" then
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
	if not SlimeHungerService or not SlimeHungerService.Feed then
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
	local okFeed = SlimeHungerService.Feed(slime, restore)
	if not okFeed then return false, "Feed rejected" end
	local after = slime:GetAttribute("FedFraction")

	applyFeedBuffer(slime, tool:GetAttribute("FeedBufferBonus") or def.FeedBufferBonus)
	FoodEffects.applyExtraEffects(slime, player, def, {
		restoreFractionApplied = restore,
		before = before,
		after  = after,
	})

	slimeCooldowns[slime] = now

	local consumed = false
	if tool:GetAttribute("Consumable") then
		consumed = consumeCharge(tool)
	end

	if throttled(feedLogLast, CONFIG.FeedLogThrottle, player.UserId.."|"..tostring(slime:GetAttribute("SlimeId") or "")) then
		log(("Feed %s Food=%s +%.0f%% (%.2f->%.2f) consumed=%s")
			:format(player.Name, fid, restore*100, before or -1, after or -1, tostring(consumed)))
	end

	if CONFIG.MarkDirtyOnConsume then markDirty(player, "FoodConsume") end
	if CONFIG.SaveImmediatelyOnConsume then saveImmediate(player, "FoodConsumeImmediate") end

	return true
end

-- Integrity & misc retained (unchanged except no extra logging tweaks) --

return FoodService