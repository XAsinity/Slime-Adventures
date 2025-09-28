-- ShopService v3.6 (Shop-side safe food grant) - fixed syntax issues
-- Notes:
--  - Replaced boolean short-circuit expressions used at top-level (e.g. `A and A:FindFirstChild(...)`)
--    with explicit nil-checks. Some environments/linters in Roblox Studio can report confusing parse
--    errors for those patterns when combined with certain constructs; this file uses explicit checks
--    to avoid that.
--  - Kept the "safeGiveFood" approach: try to clone a ReplicatedStorage template first, fall back
--    to calling FoodService.GiveFood only if no template exists.
--  - Ensures ToolUniqueId, registers with PlayerProfileService/InventoryService best-effort, and
--    rolls back coins on failure.

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local HttpService         = game:GetService("HttpService")
local RunService          = game:GetService("RunService")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PurchaseEggEvent      = Remotes:WaitForChild("PurchaseEgg")
local PurchaseResultEvent   = Remotes:WaitForChild("PurchaseResult")
local RequestInventoryEvent = Remotes:WaitForChild("RequestInventory")
local InventoryUpdateEvent  = Remotes:WaitForChild("InventoryUpdate")

-- Explicit nil-safe retrieval helpers to avoid boolean-shortcircuit-in-expression usage
local function safeFindReplicated(name)
	local ok, val = pcall(function() return ReplicatedStorage:FindFirstChild(name) end)
	if ok then return val end
	return nil
end

local function safeWaitForModules()
	local ok, val = pcall(function() return ServerScriptService:WaitForChild("Modules") end)
	if ok then return val end
	return nil
end

local ToolTemplates = safeFindReplicated("ToolTemplates")
local EggToolTemplate = nil
if ToolTemplates then
	local ok, v = pcall(function() return ToolTemplates:FindFirstChild("EggToolTemplate") end)
	if ok then EggToolTemplate = v end
end

local Modules = safeWaitForModules() or ServerScriptService:FindFirstChild("Modules")
if not Modules then
	warn("[ShopService] Modules folder missing under ServerScriptService; some requires may fail.")
end

local EggConfig   = require(Modules:WaitForChild("EggConfig"))
local RNG         = require(Modules:WaitForChild("RNG"))
local PlayerProfileService = require(Modules:WaitForChild("PlayerProfileService"))
local InventoryService = nil
do
	local ok, svc = pcall(function() return require(Modules:WaitForChild("InventoryService")) end)
	if ok then InventoryService = svc end
end

-- FoodService may live in Modules; require defensively and fallback to ReplicatedStorage.Modules
local FoodService = nil
do
	local ok, fs = pcall(function() return require(Modules:WaitForChild("FoodService")) end)
	if ok and fs then FoodService = fs end
	if not FoodService then
		local ms = safeFindReplicated("Modules")
		if ms then
			local ok2, fs2 = pcall(function() return require(ms:WaitForChild("FoodService")) end)
			if ok2 then FoodService = fs2 end
		end
	end
end

local ShopService = {}
local _inited = false
local STATS_VERSION = 1

local function log(...) print("[ShopService]", ...) end
local function warnlog(...) warn("[ShopService]", ...) end

----------------------------------------------------------------
-- Config
----------------------------------------------------------------
local EggPurchaseOptions = {
	Basic     = {cost = 50,   forcedRarity = nil},
	Rare      = {cost = 150,  forcedRarity = "Rare"},
	Epic      = {cost = 350,  forcedRarity = "Epic"},
	Legendary = {cost = 1000, forcedRarity = "Legendary"},
}

local FoodPurchaseOptions = {
	BasicFood = { cost = 10, displayName = "Basic Food" },
}

local ALWAYS_USE_GENERIC_EGG_TOOL_NAME = true
local GENERIC_EGG_TOOL_NAME = "Egg"

----------------------------------------------------------------
-- Coins helpers (PlayerProfileService routed)
----------------------------------------------------------------
local function getCoins(player)
	local ok, val = pcall(function() return PlayerProfileService.GetCoins(player) end)
	if ok then return val or 0 end
	return 0
end

local function addCoins(player, delta)
	pcall(function() PlayerProfileService.IncrementCoins(player, delta) end)
end

local function updateLeaderstats(player)
	if not player then return end
	local ls = player:FindFirstChild("leaderstats")
	if not ls then return end
	local coinValue = ls:FindFirstChild("Coins") or ls:FindFirstChild("coins") or ls:FindFirstChild("CoinsValue")
	if coinValue and (coinValue:IsA("IntValue") or coinValue:IsA("NumberValue")) then
		local ok, val = pcall(function() return getCoins(player) end)
		if ok and type(val) == "number" then
			coinValue.Value = val
		end
	end
end

----------------------------------------------------------------
-- Verified save helper
----------------------------------------------------------------
local function requestVerifiedSave(playerOrId, timeoutSeconds)
	timeoutSeconds = tonumber(timeoutSeconds) or 3
	local ok, res = pcall(function()
		if type(PlayerProfileService.SaveNowAndWait) == "function" then
			return PlayerProfileService.SaveNowAndWait(playerOrId, timeoutSeconds, true)
		elseif type(PlayerProfileService.ForceFullSaveNow) == "function" then
			return PlayerProfileService.ForceFullSaveNow(playerOrId, "ShopService_VerifiedFallback")
		else
			pcall(function() PlayerProfileService.SaveNow(playerOrId, "ShopService_AsyncFallback") end)
			if type(PlayerProfileService.WaitForSaveComplete) == "function" then
				local done, success = PlayerProfileService.WaitForSaveComplete(playerOrId, timeoutSeconds)
				return done and success
			end
			return false
		end
	end)
	if not ok then
		warn("[ShopService] requestVerifiedSave: PlayerProfileService save call failed:", tostring(res))
		return false
	end
	return res == true or (res ~= nil and res ~= false)
end

----------------------------------------------------------------
-- Food ID resolution helpers
----------------------------------------------------------------
local function findFoodIdCandidate(itemKey)
	if not itemKey then return nil end
	-- 1) direct match in FoodDefinitions if FoodService.Definitions available
	if FoodService and FoodService.Definitions and type(FoodService.Definitions.resolve) == "function" then
		if FoodService.Definitions.Foods and FoodService.Definitions.Foods[itemKey] then
			return itemKey
		end
		for fid, entry in pairs(FoodService.Definitions.Foods or {}) do
			if entry.Label and tostring(entry.Label):lower() == tostring(itemKey):lower() then
				return fid
			end
		end
	end

	-- 2) Search configured FoodPurchaseOptions keys (backwards compat)
	if FoodPurchaseOptions[itemKey] then
		return itemKey
	end
	for k,v in pairs(FoodPurchaseOptions) do
		if type(v) == "table" and v.displayName and tostring(v.displayName):lower() == tostring(itemKey):lower() then
			return k
		end
	end

	-- 3) Search ReplicatedStorage folders for a Tool matching itemKey or displayName, including nested folders
	local function searchInFolder(folder)
		if not folder then return nil end
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA("Tool") then
				if tostring(child.Name):lower() == tostring(itemKey):lower() then
					local fid = nil
					pcall(function() fid = child:GetAttribute("FoodId") end)
					return fid or child.Name, child
				end
				local attrLabel = nil
				pcall(function() attrLabel = child:GetAttribute("Label") end)
				if attrLabel and tostring(attrLabel):lower() == tostring(itemKey):lower() then
					local fid = nil
					pcall(function() fid = child:GetAttribute("FoodId") end)
					return fid or child.Name, child
				end
			elseif child:IsA("Folder") or child:IsA("Model") then
				-- nested: try inside
				for _, sub in ipairs(child:GetChildren()) do
					if sub:IsA("Tool") then
						if tostring(sub.Name):lower() == tostring(itemKey):lower() then
							local fid = nil
							pcall(function() fid = sub:GetAttribute("FoodId") end)
							return fid or sub.Name, sub
						end
						local attrLabel = nil
						pcall(function() attrLabel = sub:GetAttribute("Label") end)
						if attrLabel and tostring(attrLabel):lower() == tostring(itemKey):lower() then
							local fid = nil
							pcall(function() fid = sub:GetAttribute("FoodId") end)
							return fid or sub.Name, sub
						end
					end
				end
			end
		end
		return nil
	end

	local searchFolders = {
		safeFindReplicated("FoodTemplates"),
		safeFindReplicated("Assets"),
		safeFindReplicated("InventoryTemplates"),
		safeFindReplicated("ToolTemplates"),
	}
	for _, folder in ipairs(searchFolders) do
		local fid, inst = searchInFolder(folder)
		if fid then return fid end
	end

	-- 4) Last-chance: return itemKey itself
	return itemKey
end

----------------------------------------------------------------
-- Inventory snapshot helper
----------------------------------------------------------------
local function buildInventorySnapshot(player)
	local snap = { Coins = getCoins(player), Eggs = {}, Foods = {} }
	local bp = player:FindFirstChildOfClass("Backpack")
	if bp then
		for _,t in ipairs(bp:GetChildren()) do
			if t:IsA("Tool") then
				if t:GetAttribute("EggId") and not t:GetAttribute("Placed") then
					table.insert(snap.Eggs, {
						EggId         = t:GetAttribute("EggId"),
						Rarity        = t:GetAttribute("Rarity"),
						HatchTime     = t:GetAttribute("HatchTime"),
						Weight        = t:GetAttribute("WeightScalar"),
						Move          = t:GetAttribute("MovementScalar"),
						ValueBase     = t:GetAttribute("ValueBase"),
						ValuePerGrowth= t:GetAttribute("ValuePerGrowth"),
						ToolName      = t.Name
					})
				elseif t:GetAttribute("FoodItem") then
					table.insert(snap.Foods, {
						FoodId      = t:GetAttribute("FoodId") or t.Name,
						Name        = t.Name,
						Restore     = t:GetAttribute("RestoreFraction"),
						BufferBonus = t:GetAttribute("FeedBufferBonus"),
						Charges     = t:GetAttribute("Charges"),
						Consumable  = t:GetAttribute("Consumable")
					})
				end
			end
		end
	end
	return snap
end

local function sendInventory(player)
	InventoryUpdateEvent:FireClient(player, buildInventorySnapshot(player))
end

function ShopService.GetInventory(player)
	return buildInventorySnapshot(player)
end

----------------------------------------------------------------
-- Egg tool creation (unchanged)
----------------------------------------------------------------
local function createEggTool(player, purchaseKey)
	local opt = EggPurchaseOptions[purchaseKey]
	if not opt then return nil, "Invalid egg key" end
	local rng   = RNG.New()
	local stats = EggConfig.GenerateEggStats(rng, opt.forcedRarity)
	if not EggToolTemplate then return nil, "Missing EggToolTemplate" end
	local tool  = EggToolTemplate:Clone()
	local eggId = HttpService:GenerateGUID(false)

	if ALWAYS_USE_GENERIC_EGG_TOOL_NAME then
		tool.Name = GENERIC_EGG_TOOL_NAME
	else
		tool.Name = (stats.Rarity or "Egg") .. " Egg"
	end

	tool:SetAttribute("EggId", eggId)
	tool:SetAttribute("ServerIssued", true)
	tool:SetAttribute("OwnerUserId", player.UserId)
	tool:SetAttribute("StatsVersion", STATS_VERSION)

	-- Ensure deterministic unique key for inventory merging/dedupe
	if not tool:GetAttribute("ToolUniqueId") then
		tool:SetAttribute("ToolUniqueId", HttpService:GenerateGUID(false))
	end

	for k,v in pairs(stats) do
		tool:SetAttribute(k, v)
	end
	return tool
end

----------------------------------------------------------------
-- Safe food granting (Shop-side clone fallback)
----------------------------------------------------------------
local function findTemplateInstance(foodId)
	-- Search ReplicatedStorage in multiple folders and nested children for a Tool matching foodId
	local function inspectFolder(folder)
		if not folder then return nil end
		for _,child in ipairs(folder:GetChildren()) do
			if child:IsA("Tool") then
				if child.Name == foodId then return child end
				local ok, attr = pcall(function() return child:GetAttribute("FoodId") end)
				if ok and attr == foodId then return child end
			elseif child:IsA("Folder") or child:IsA("Model") then
				for _,sub in ipairs(child:GetChildren()) do
					if sub:IsA("Tool") then
						if sub.Name == foodId then return sub end
						local ok, attr = pcall(function() return sub:GetAttribute("FoodId") end)
						if ok and attr == foodId then return sub end
					end
				end
			end
		end
		return nil
	end

	local folders = {
		safeFindReplicated("FoodTemplates"),
		safeFindReplicated("ToolTemplates"),
		safeFindReplicated("InventoryTemplates"),
		safeFindReplicated("Assets"),
	}
	for _,f in ipairs(folders) do
		local res = inspectFolder(f)
		if res then return res end
	end
	return nil
end

local function safeGiveFood(player, foodId, silent)
	-- Attempt to grant by cloning existing template first (avoids server-side LocalScript.Source writes)
	local template = findTemplateInstance(foodId)
	local def = nil
	if FoodService and FoodService.Definitions and type(FoodService.Definitions.resolve) == "function" then
		def = FoodService.Definitions.resolve(foodId) or {}
	end

	if template then
		-- clone template; do not create any LocalScript with Source on the server
		local ok, tool = pcall(function() return template:Clone() end)
		if not ok or not tool then
			if not silent then warnlog("safeGiveFood: clone failed for template", tostring(foodId), tostring(tool)) end
			return nil, "clone_failed"
		end

		-- set safe attributes (do not touch any plugin-only properties)
		pcall(function() tool:SetAttribute("FoodItem", true) end)
		pcall(function() tool:SetAttribute("FoodId", foodId) end)
		if def and def.RestoreFraction then pcall(function() tool:SetAttribute("RestoreFraction", def.RestoreFraction) end) end
		if def and def.FeedBufferBonus then pcall(function() tool:SetAttribute("FeedBufferBonus", def.FeedBufferBonus) end) end
		if def and def.Consumable ~= nil then pcall(function() tool:SetAttribute("Consumable", def.Consumable) end) end
		if def and def.Charges then pcall(function() tool:SetAttribute("Charges", def.Charges) end) end
		pcall(function() tool:SetAttribute("ServerIssued", true) end)
		pcall(function() tool:SetAttribute("OwnerUserId", player.UserId) end)
		-- ensure ToolUniqueId
		pcall(function()
			local tu = tool:GetAttribute("ToolUniqueId")
			if not tu or tostring(tu) == "" then tool:SetAttribute("ToolUniqueId", HttpService:GenerateGUID(false)) end
		end)
		pcall(function() tool:SetAttribute("PersistentFoodTool", true) end)

		-- Ensure it has a handle or visible part (don't create LocalScript.Source)
		local hasHandle = false
		for _,c in ipairs(tool:GetChildren()) do
			if c.Name == "Handle" and c:IsA("BasePart") then hasHandle = true break end
		end
		if not hasHandle then
			-- simple Part fallback
			local h = Instance.new("Part")
			h.Name = "Handle"
			h.Size = Vector3.new(1,1,1)
			h.TopSurface = Enum.SurfaceType.Smooth
			h.BottomSurface = Enum.SurfaceType.Smooth
			h.Parent = tool
		end

		-- Parent into player's backpack
		local bp = player:FindFirstChildOfClass("Backpack")
		if not bp then
			-- Failure to parent: cleanup and return
			if tool and tool.Parent then pcall(function() tool:Destroy() end) end
			return nil, "no_backpack"
		end
		tool.Parent = bp

		-- Best-effort persistence registration
		pcall(function()
			if type(PlayerProfileService.AddInventoryItem) == "function" then
				PlayerProfileService.AddInventoryItem(player, "foodTools", {
					FoodId = foodId,
					ToolUniqueId = tool:GetAttribute("ToolUniqueId"),
					Charges = tool:GetAttribute("Charges"),
					ServerIssued = true,
					GrantedAt = os.time(),
				})
			end
		end)
		pcall(function()
			if InventoryService and type(InventoryService.AddInventoryItem) == "function" then
				InventoryService.AddInventoryItem(player, "foodTools", {
					FoodId = foodId,
					ToolUniqueId = tool:GetAttribute("ToolUniqueId"),
					Charges = tool:GetAttribute("Charges"),
					ServerIssued = true,
					GrantedAt = os.time(),
				})
			end
		end)

		-- Optionally trigger FoodService save/update flows (best-effort)
		pcall(function()
			if InventoryService and type(InventoryService.UpdateProfileInventory) == "function" then
				InventoryService.UpdateProfileInventory(player)
			end
			-- Let PlayerProfileService save async; Shop will also attempt a verified save after purchase
		end)

		return tool
	end

	-- No template found: fall back to calling FoodService.GiveFood in a protected pcall.
	if not FoodService or type(FoodService.GiveFood) ~= "function" then
		if not silent then warnlog("safeGiveFood: FoodService.GiveFood unavailable") end
		return nil, "foodservice_unavailable"
	end

	local okGive, toolOrErr = pcall(function()
		return FoodService.GiveFood(player, foodId, true)
	end)
	if not okGive then
		if not silent then warnlog("safeGiveFood: FoodService.GiveFood error:", tostring(toolOrErr)) end
		return nil, tostring(toolOrErr)
	end
	if not toolOrErr then
		if not silent then warnlog("safeGiveFood: FoodService.GiveFood returned nil for", tostring(foodId)) end
		return nil, "give_returned_nil"
	end
	-- Ensure ToolUniqueId present
	pcall(function()
		if type(toolOrErr.SetAttribute) == "function" then
			local tu = toolOrErr:GetAttribute("ToolUniqueId")
			if not tu or tostring(tu) == "" then toolOrErr:SetAttribute("ToolUniqueId", HttpService:GenerateGUID(false)) end
		end
	end)
	-- Best-effort register
	pcall(function()
		if type(PlayerProfileService.AddInventoryItem) == "function" then
			PlayerProfileService.AddInventoryItem(player, "foodTools", {
				FoodId = foodId,
				ToolUniqueId = toolOrErr.GetAttribute and toolOrErr:GetAttribute("ToolUniqueId") or nil,
				Charges = toolOrErr.GetAttribute and toolOrErr:GetAttribute("Charges") or nil,
				ServerIssued = true,
				GrantedAt = os.time(),
			})
		end
	end)
	pcall(function()
		if InventoryService and type(InventoryService.AddInventoryItem) == "function" then
			InventoryService.AddInventoryItem(player, "foodTools", {
				FoodId = foodId,
				ToolUniqueId = toolOrErr.GetAttribute and toolOrErr:GetAttribute("ToolUniqueId") or nil,
				Charges = toolOrErr.GetAttribute and toolOrErr:GetAttribute("Charges") or nil,
				ServerIssued = true,
				GrantedAt = os.time(),
			})
		end
	end)

	return toolOrErr
end

----------------------------------------------------------------
-- Purchase responses
----------------------------------------------------------------
local function fail(player, msg)
	pcall(function()
		PurchaseResultEvent:FireClient(player, {
			success = false,
			message = msg,
			remainingCoins = getCoins(player)
		})
	end)
end

local function ok(player, msg)
	pcall(function()
		PurchaseResultEvent:FireClient(player, {
			success = true,
			message = msg,
			remainingCoins = getCoins(player)
		})
	end)
end

----------------------------------------------------------------
-- Purchase handler (uses safeGiveFood)
----------------------------------------------------------------
local purchaseGuard = {}

local function onPurchase(player, purchaseType, itemKey)
	if not player or not player.UserId then return end
	local uid = tostring(player.UserId)

	-- Prevent concurrent purchases
	if purchaseGuard[uid] then
		return fail(player, "Purchase in progress")
	end
	purchaseGuard[uid] = true
	local cleared = false
	local function cleanup()
		if not cleared then
			purchaseGuard[uid] = nil
			cleared = true
		end
	end

	local okStatus, err = pcall(function()
		purchaseType = tostring(purchaseType or "")

		if purchaseType == "Egg" then
			local opt = EggPurchaseOptions[itemKey]; if not opt then fail(player, "Unknown egg"); return end

			local coins = getCoins(player) or 0
			if coins < opt.cost then fail(player, "Not enough coins"); return end

			-- Deduct coins
			addCoins(player, -opt.cost)
			updateLeaderstats(player)

			-- Create tool
			local tool, createErr = createEggTool(player, itemKey)
			if not tool then
				addCoins(player, opt.cost)
				updateLeaderstats(player)
				fail(player, "Creation failed: "..tostring(createErr))
				return
			end

			local bp = player:FindFirstChildOfClass("Backpack")
			if not bp then
				addCoins(player, opt.cost)
				updateLeaderstats(player)
				if tool and tool.Parent then pcall(function() tool:Destroy() end) end
				fail(player, "No backpack")
				return
			end

			tool.Parent = bp

			-- Persist inventory addition to profile
			local okAdd, addErr = pcall(function()
				PlayerProfileService.AddInventoryItem(player, "eggTools", {
					EggId         = tool:GetAttribute("EggId"),
					Rarity        = tool:GetAttribute("Rarity"),
					HatchTime     = tool:GetAttribute("HatchTime"),
					Weight        = tool:GetAttribute("WeightScalar"),
					Move          = tool:GetAttribute("MovementScalar"),
					ValueBase     = tool:GetAttribute("ValueBase"),
					ValuePerGrowth= tool:GetAttribute("ValuePerGrowth"),
					ToolName      = tool.Name,
					ServerIssued  = true,
					OwnerUserId   = player.UserId,
					StatsVersion  = STATS_VERSION,
					ToolUniqueId  = tool:GetAttribute("ToolUniqueId"),
				})
			end)
			if not okAdd then
				addCoins(player, opt.cost)
				updateLeaderstats(player)
				if tool and tool.Parent then pcall(function() tool:Destroy() end) end
				fail(player, "Failed to add to inventory: "..tostring(addErr))
				return
			end

			-- Runtime inventory registration (best-effort)
			if InventoryService then
				local okInv, invErr = pcall(function()
					InventoryService.AddInventoryItem(player, "eggTools", {
						EggId         = tool:GetAttribute("EggId"),
						Rarity        = tool:GetAttribute("Rarity"),
						HatchTime     = tool:GetAttribute("HatchTime"),
						Weight        = tool:GetAttribute("WeightScalar"),
						Move          = tool:GetAttribute("MovementScalar"),
						ValueBase     = tool:GetAttribute("ValueBase"),
						ValuePerGrowth= tool:GetAttribute("ValuePerGrowth"),
						ToolName      = tool.Name,
						ServerIssued  = true,
						OwnerUserId   = player.UserId,
						StatsVersion  = STATS_VERSION,
						ToolUniqueId  = tool:GetAttribute("ToolUniqueId"),
					})
				end)
				if not okInv then warnlog("InventoryService.AddInventoryItem for eggTools failed:", tostring(invErr)) end
			end

			-- Save
			local saved = false
			local okSave, saveErr = pcall(function() return requestVerifiedSave(player, 3) end)
			if okSave and saveErr then saved = true end
			if not saved then pcall(function() PlayerProfileService.SaveNow(player, "PostEggPurchase") end) end

			ok(player, ("Bought egg"))
			sendInventory(player)
			cleanup()
			return

		elseif purchaseType == "Food" then
			-- Resolve canonical FoodId (robust)
			local resolved = findFoodIdCandidate(itemKey)
			if not resolved then
				cleanup()
				return fail(player, "Unknown food")
			end

			local opt = FoodPurchaseOptions[itemKey] or FoodPurchaseOptions[resolved] or { cost = 0 }
			local cost = opt.cost or 0
			local coins = getCoins(player) or 0
			if coins < cost then cleanup(); return fail(player, "Not enough coins") end

			-- Deduct coins
			addCoins(player, -cost)
			updateLeaderstats(player)

			-- Try safe grant first (shop clones template safely). If that fails, fallback to FoodService.GiveFood
			local tool, errReason = safeGiveFood(player, resolved, true)
			if not tool then
				-- safeGiveFood returned nil; errReason explains why (e.g., "no_backpack", "clone_failed", "foodservice_unavailable" or an error string)
				-- Log the reason and try fallback via original key if different
				warnlog("safeGiveFood failed for", tostring(resolved), "reason=", tostring(errReason))
				-- If the resolved differs from itemKey, try fallback with itemKey via safeGiveFood (handles purchase-key->id mismatches)
				if tostring(itemKey) ~= tostring(resolved) then
					tool, errReason = safeGiveFood(player, tostring(itemKey), true)
				end
				-- If still nil, give up and attempt direct FoodService call (unprotected) as last resort
				if not tool then
					if FoodService and type(FoodService.GiveFood) == "function" then
						local okGive, giveRes = pcall(function()
							return FoodService.GiveFood(player, resolved, true)
						end)
						if not okGive or not giveRes then
							-- rollback and report
							addCoins(player, cost)
							updateLeaderstats(player)
							warnlog("FoodService.GiveFood failed after safeGiveFood fallbacks:", tostring(giveRes))
							cleanup()
							return fail(player, "Food creation failed")
						else
							tool = giveRes
						end
					else
						-- rollback and report
						addCoins(player, cost)
						updateLeaderstats(player)
						warnlog("No ways to grant food: safeGiveFood & FoodService.GiveFood unavailable/failed")
						cleanup()
						return fail(player, "Food creation failed")
					end
				end
			end

			-- Ensure ToolUniqueId is present
			if tool and type(tool.SetAttribute) == "function" then
				local tuid = nil
				pcall(function() tuid = tool:GetAttribute("ToolUniqueId") end)
				if not tuid or tostring(tuid) == "" then
					local gen = nil
					pcall(function() gen = HttpService:GenerateGUID(false) end)
					if not gen then gen = tostring(tick()) .. "-" .. tostring(math.random(1,1e6)) end
					pcall(function() tool:SetAttribute("ToolUniqueId", gen) end)
				end
			end

			-- Persist PlayerProfileService.AddInventoryItem (best-effort)
			local okAdd, addErr2 = pcall(function()
				PlayerProfileService.AddInventoryItem(player, "foodTools", {
					FoodId      = tool:GetAttribute("FoodId") or tool.Name,
					Name        = tool.Name,
					Restore     = tool:GetAttribute("RestoreFraction"),
					BufferBonus = tool:GetAttribute("FeedBufferBonus"),
					Charges     = tool:GetAttribute("Charges"),
					Consumable  = tool:GetAttribute("Consumable"),
					ServerIssued= true,
					OwnerUserId = player.UserId,
					ToolUniqueId= tool:GetAttribute("ToolUniqueId"),
				})
			end)
			if not okAdd then
				warnlog("PlayerProfileService.AddInventoryItem for foodTools failed:", tostring(addErr2))
			end

			-- Register runtime InventoryService entry so serializer sees live item
			if InventoryService then
				local okInv, invErr = pcall(function()
					InventoryService.AddInventoryItem(player, "foodTools", {
						FoodId      = tool:GetAttribute("FoodId") or tool.Name,
						Name        = tool.Name,
						Restore     = tool:GetAttribute("RestoreFraction"),
						BufferBonus = tool:GetAttribute("FeedBufferBonus"),
						Charges     = tool:GetAttribute("Charges"),
						Consumable  = tool:GetAttribute("Consumable"),
						ServerIssued= true,
						OwnerUserId = player.UserId,
						ToolUniqueId= tool:GetAttribute("ToolUniqueId"),
					})
				end)
				if not okInv then warnlog("InventoryService.AddInventoryItem for foodTools failed:", tostring(invErr)) end
			end

			-- Attempt verified save where configured
			local saved = false
			local okSave, saveErr = pcall(function() return requestVerifiedSave(player, 3) end)
			if okSave and saveErr then saved = true end
			if not saved then pcall(function() PlayerProfileService.SaveNow(player, "PostFoodPurchase") end) end

			ok(player, ("Bought %s"):format(opt.displayName or tostring(itemKey)))
			sendInventory(player)
			cleanup()
			return

		else
			fail(player, "Invalid purchase type")
			return
		end
	end)

	if not okStatus then
		-- If pcall failed with an error, attempt logging and best-effort refund
		pcall(function()
			log("ERROR in onPurchase for player", player.Name, "err=", tostring(err))
		end)
		-- best-effort refund/notify
		fail(player, "Internal error processing purchase")
	end

	cleanup()
end

----------------------------------------------------------------
-- Player join
----------------------------------------------------------------
local function onPlayerAdded(player)
	task.defer(sendInventory, player)
end

----------------------------------------------------------------
-- Persistence restore hook
----------------------------------------------------------------
local function hookPersistenceRestore()
	local evt = ReplicatedStorage:FindFirstChild("PersistInventoryRestored")
	if evt and evt:IsA("BindableEvent") then
		evt.Event:Connect(function(player)
			if player and player:IsDescendantOf(Players) then
				sendInventory(player)
			end
		end)
	end
end

----------------------------------------------------------------
-- Init
----------------------------------------------------------------
function ShopService.Init()
	if _inited then return end
	_inited = true
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _,p in ipairs(Players:GetPlayers()) do task.spawn(onPlayerAdded,p) end
	RequestInventoryEvent.OnServerEvent:Connect(sendInventory)
	PurchaseEggEvent.OnServerEvent:Connect(onPurchase)
	hookPersistenceRestore()
	log("Initialized OK (Module).")
end

return ShopService