-- ShopService v3.6 (Shop-side safe food grant) - updated with catalog RFs and quantity-aware purchases
-- Updated to use centralized CoinService for coin operations (TrySpendCoins/RefundCoins/GetCoins)
-- to ensure single-script coin control for purchases and refunds.

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

-- Ensure RemoteFunctions for catalog/preview exist (created if missing)
local GetEggCatalogRF = Remotes:FindFirstChild("GetEggCatalog")
local GetEggPreviewRF = Remotes:FindFirstChild("GetEggPreview")
if not GetEggCatalogRF then
	GetEggCatalogRF = Instance.new("RemoteFunction")
	GetEggCatalogRF.Name = "GetEggCatalog"
	GetEggCatalogRF.Parent = Remotes
end
if not GetEggPreviewRF then
	GetEggPreviewRF = Instance.new("RemoteFunction")
	GetEggPreviewRF.Name = "GetEggPreview"
	GetEggPreviewRF.Parent = Remotes
end

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

local function safeGetAttr(inst, attr)
	if not inst or type(inst.GetAttribute) ~= "function" then return nil end
	local ok, value = pcall(function() return inst:GetAttribute(attr) end)
	if ok then return value end
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

-- New: CoinService centralizes coin operations (TrySpendCoins / RefundCoins / GetCoins / faction standing)
local CoinService = nil
do
	local ok, svc = pcall(function()
		-- Prefer Modules coin service if present
		local mod = Modules and Modules:FindFirstChild("CoinService")
		if mod then return require(mod) end
		-- Fallback: ReplicatedStorage.Modules
		local rsMods = safeFindReplicated("Modules")
		if rsMods then
			local m = rsMods:FindFirstChild("CoinService")
			if m then return require(m) end
		end
		return nil
	end)
	if ok and svc then
		CoinService = svc
	else
		-- If we couldn't load a dedicated CoinService module, we still support coin ops via PlayerProfileService.
		CoinService = {
			GetCoins = function(player) local ok, res = pcall(function() return PlayerProfileService.GetCoins(player) end) if ok and res then return res end return 0 end,
			IncrementCoins = function(player, delta) pcall(function() PlayerProfileService.IncrementCoins(player, delta) end) end,
			TrySpendCoins = function(player, amount)
				local ok, res = pcall(function()
					local cur = PlayerProfileService.GetCoins(player) or 0
					if cur < amount then return false, "insufficient" end
					PlayerProfileService.IncrementCoins(player, -amount)
					return true
				end)
				if ok then return res end
				return false, "error"
			end,
			RefundCoins = function(player, amount) pcall(function() PlayerProfileService.IncrementCoins(player, amount) end) end,
			GetFactionStanding = function() return 0 end,
			AdjustFactionStanding = function() return nil end,
			ApplySale = function(player, cost, opts) local ok,res = pcall(function() return true end) return true end,
		}
	end
end

-- FoodService may live in Modules; require defensively and fallback to ReplicatedStorage.Modules
local FoodService = nil
do
	local ok, fs = pcall(function() return require(Modules:WaitForChild("FoodService")) end)
	if ok and fs then FoodService = fs end
	if not FoodService then
		local ms = safeFindReplicated("Modules")
		if ms then
			local replica = ms:FindFirstChild("FoodService")
			if replica then
				local ok2, fs2 = pcall(function() return require(replica) end)
				if ok2 then
					FoodService = fs2
				else
					warn("[ShopService] Failed to require replicated FoodService:", fs2)
				end
			end
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
local DEFAULT_EGG_TYPE = "Egg"
local EGG_RARITY_TAGS = {
	common = true,
	rare = true,
	epic = true,
	legendary = true,
}

local EggPurchaseOptions = {
	Basic     = {cost = 50,   forcedRarity = nil,         eggType = DEFAULT_EGG_TYPE},
	Rare      = {cost = 150,  forcedRarity = "Rare",      eggType = DEFAULT_EGG_TYPE},
	Epic      = {cost = 350,  forcedRarity = "Epic",      eggType = DEFAULT_EGG_TYPE},
	Legendary = {cost = 1000, forcedRarity = "Legendary", eggType = DEFAULT_EGG_TYPE},
}

local FoodPurchaseOptions = {
	BasicFood = { cost = 10, displayName = "Basic Food" },
}

local ALWAYS_USE_GENERIC_EGG_TOOL_NAME = false
local GENERIC_EGG_TOOL_NAME = "Egg"

----------------------------------------------------------------
-- Egg tool creation (moved up so catalog handlers can use resolveEggDisplayName)
----------------------------------------------------------------
local function resolveEggDisplayName(eggType)
	local trimmed = nil
	if type(eggType) == "string" then
		trimmed = string.match(eggType, "^%s*(.-)%s*$")
	end
	if not trimmed or trimmed == "" then
		return DEFAULT_EGG_TYPE
	end
	local lower = string.lower(trimmed)
	if lower == string.lower(DEFAULT_EGG_TYPE) or EGG_RARITY_TAGS[lower] then
		return DEFAULT_EGG_TYPE
	end
	return trimmed .. " Egg"
end

local function normalizeEggTool(tool)
	if not tool or type(tool.IsA) ~= "function" or not tool:IsA("Tool") then return end
	if not tool:GetAttribute("EggId") then return end
	local attrType = safeGetAttr(tool, "EggType")
	local name = resolveEggDisplayName(attrType)
	if tool.Name ~= name then
		pcall(function() tool.Name = name end)
	end
	local shouldNormalizeType = attrType == nil
	if not shouldNormalizeType and type(attrType) == "string" then
		local lower = string.lower(attrType)
		if lower == string.lower(DEFAULT_EGG_TYPE) or EGG_RARITY_TAGS[lower] then
			shouldNormalizeType = true
		end
	end
	if shouldNormalizeType then
		pcall(function() tool:SetAttribute("EggType", DEFAULT_EGG_TYPE) end)
	end
end

local function createEggTool(player, purchaseKey)
	local opt = EggPurchaseOptions[purchaseKey]
	if not opt then return nil, "Invalid egg key" end
	local rng   = RNG.New()
	local stats = EggConfig.GenerateEggStats(rng, opt.forcedRarity)
	if not EggToolTemplate then return nil, "Missing EggToolTemplate" end
	local tool  = EggToolTemplate:Clone()
	local eggId = HttpService:GenerateGUID(false)
	local eggType = opt and opt.eggType
	if type(eggType) ~= "string" or eggType == "" then
		eggType = DEFAULT_EGG_TYPE
	end
	stats.EggType = eggType

	if ALWAYS_USE_GENERIC_EGG_TOOL_NAME then
		tool.Name = GENERIC_EGG_TOOL_NAME
	else
		tool.Name = resolveEggDisplayName(eggType)
	end

	tool:SetAttribute("EggId", eggId)
	tool:SetAttribute("ServerIssued", true)
	tool:SetAttribute("OwnerUserId", player.UserId)
	tool:SetAttribute("StatsVersion", STATS_VERSION)
	tool:SetAttribute("EggType", eggType)

	-- Ensure deterministic unique key for inventory merging/dedupe
	if not tool:GetAttribute("ToolUniqueId") then
		tool:SetAttribute("ToolUniqueId", HttpService:GenerateGUID(false))
	end

	for k,v in pairs(stats) do
		tool:SetAttribute(k, v)
	end
	normalizeEggTool(tool)
	return tool
end

----------------------------------------------------------------
-- Catalog / preview RF handlers (server-side)
----------------------------------------------------------------
local function sampleStatsForEgg(purchaseKey)
	local opt = EggPurchaseOptions and EggPurchaseOptions[purchaseKey]
	if not opt then return nil end
	local stats = {}
	pcall(function()
		local rng = RNG.New()
		stats = EggConfig.GenerateEggStats(rng, opt.forcedRarity) or {}
	end)
	-- Compact numeric stats for safe client display
	local compact = {}
	for k, v in pairs(stats) do
		if type(v) == "number" then
			compact[k] = math.floor((v) * 1000 + 0.5) / 1000
		else
			compact[k] = v
		end
	end
	return compact
end

GetEggCatalogRF.OnServerInvoke = function(player)
	local out = {}
	for key, opt in pairs(EggPurchaseOptions or {}) do
		table.insert(out, {
			key = key,
			displayName = resolveEggDisplayName(opt.eggType or DEFAULT_EGG_TYPE),
			cost = opt.cost or 0,
			rarity = opt.forcedRarity or "Normal",
			sampleStats = sampleStatsForEgg(key),
		})
	end
	table.sort(out, function(a,b) return (a.cost or 0) < (b.cost or 0) end)
	return out
end

GetEggPreviewRF.OnServerInvoke = function(player, key)
	if not key then return nil end
	return sampleStatsForEgg(key)
end

----------------------------------------------------------------
-- Coins helpers (now routed through CoinService)
----------------------------------------------------------------
local function getCoins(player)
	if CoinService and type(CoinService.GetCoins) == "function" then
		local ok, val = pcall(function() return CoinService.GetCoins(player) end)
		if ok then return tonumber(val) or 0 end
	end
	-- fallback
	local ok, val = pcall(function() return PlayerProfileService.GetCoins and PlayerProfileService.GetCoins(player) end)
	if ok and tonumber(val) then return tonumber(val) end
	return 0
end

local function addCoins(player, delta)
	if not player then return end
	if CoinService and type(CoinService.IncrementCoins) == "function" then
		pcall(function() CoinService.IncrementCoins(player, delta) end)
		return
	end
	pcall(function() PlayerProfileService.IncrementCoins(player, delta) end)
end

local function trySpendCoins(player, amount)
	if CoinService and type(CoinService.TrySpendCoins) == "function" then
		local ok, reason = pcall(function() return CoinService.TrySpendCoins(player, amount) end)
		if ok then
			-- If TrySpendCoins returns boolean true or (true, reason)
			if reason == nil then
				-- PlayerProfileService.TrySpendCoins may return boolean or (true, nil)
				return true, nil
			end
			if reason == true then
				return true, nil
			end
			-- If returned (false, "reason")
			if reason == false then return false, "insufficient" end
			if type(reason) == "string" then
				if reason == "insufficient" then return false, reason end
				-- treat truthy return as success
				if tostring(reason) == "true" then return true, nil end
			end
		end
		-- if pcall failed, fall through
	end
	-- fallback naive attempt (non-atomic)
	local cur = getCoins(player) or 0
	if cur < amount then return false, "Not enough coins" end
	addCoins(player, -amount)
	return true, nil
end

local function refundCoins(player, amount)
	if CoinService and type(CoinService.RefundCoins) == "function" then
		pcall(function() CoinService.RefundCoins(player, amount) end)
		return
	end
	addCoins(player, amount)
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
local normalizeEggTool_local = normalizeEggTool -- keep local alias if needed

local function buildInventorySnapshot(player)
	local snap = { Coins = getCoins(player), Eggs = {}, Foods = {} }
	local bp = player:FindFirstChildOfClass("Backpack")
	if bp then
		for _,t in ipairs(bp:GetChildren()) do
			if t:IsA("Tool") then
				if t:GetAttribute("EggId") and not t:GetAttribute("Placed") then
					normalizeEggTool(t)
					table.insert(snap.Eggs, {
						EggId         = t:GetAttribute("EggId"),
						Rarity        = t:GetAttribute("Rarity"),
						EggType       = t:GetAttribute("EggType"),
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

		local appliedName, appliedLabel, appliedCharges = nil, nil, nil
		if FoodService and type(FoodService.ApplyCanonicalToolName) == "function" then
			local okApply, name, label, charges = pcall(FoodService.ApplyCanonicalToolName, tool, {
				foodId = foodId,
				definition = def,
			})
			if okApply then
				appliedName, appliedLabel, appliedCharges = name, label, charges
			end
		end

		if not appliedName then
			local fallbackLabel = (def and def.Label) or tostring(foodId)
			local fallbackCharges = safeGetAttr(tool, "Charges") or (def and def.Charges) or 0
			fallbackCharges = tonumber(fallbackCharges) or 0
			fallbackCharges = math.max(0, math.floor(fallbackCharges + 0.0001))
			appliedName = string.format("%s %d", fallbackLabel, fallbackCharges)
			appliedLabel = fallbackLabel
			appliedCharges = fallbackCharges
			pcall(function() tool.Name = appliedName end)
		end

		pcall(function()
			if appliedLabel then
				tool:SetAttribute("FoodTypeLabel", appliedLabel)
			end
		end)

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
					Charges = appliedCharges or tool:GetAttribute("Charges"),
					ServerIssued = true,
					GrantedAt = os.time(),
					FoodTypeLabel = appliedLabel,
					DisplayName = appliedName or tool.Name,
				})
			end
		end)
		pcall(function()
			if InventoryService and type(InventoryService.AddInventoryItem) == "function" then
				InventoryService.AddInventoryItem(player, "foodTools", {
					FoodId = foodId,
					ToolUniqueId = tool:GetAttribute("ToolUniqueId"),
					Charges = appliedCharges or tool:GetAttribute("Charges"),
					ServerIssued = true,
					GrantedAt = os.time(),
					FoodTypeLabel = appliedLabel,
					DisplayName = appliedName or tool.Name,
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
-- Quantity-aware Egg purchase helper (atomic spend + rollback)
----------------------------------------------------------------
local purchaseGuard = {}
local MAX_PURCHASE_QUANTITY = 10

local function handlePurchaseEggs(player, itemKey, quantity)
	quantity = tonumber(quantity) or 1
	if quantity < 1 then quantity = 1 end
	if quantity > MAX_PURCHASE_QUANTITY then quantity = MAX_PURCHASE_QUANTITY end

	local opt = EggPurchaseOptions[itemKey]; if not opt then fail(player, "Unknown egg"); return end
	local totalCost = (opt.cost or 0) * quantity

	-- Prevent concurrent purchases per-player
	local uid = tostring(player.UserId)
	if purchaseGuard[uid] then
		return fail(player, "Purchase in progress")
	end
	purchaseGuard[uid] = true
	local cleared = false
	local function cleanupGuard()
		if not cleared then purchaseGuard[uid] = nil; cleared = true end
	end

	-- Attempt to spend the totalCost atomically
	local spent, reason = trySpendCoins(player, totalCost)
	if not spent then
		cleanupGuard()
		return fail(player, "Not enough coins")
	end

	local created = {}
	local bp = player:FindFirstChildOfClass("Backpack")
	if not bp then
		-- refund and abort if no backpack
		refundCoins(player, totalCost)
		updateLeaderstats(player)
		cleanupGuard()
		return fail(player, "No backpack")
	end

	local successAll = true
	local errMsg = nil

	for i = 1, quantity do
		local tool, createErr = createEggTool(player, itemKey)
		if not tool then
			successAll = false
			errMsg = tostring(createErr or "creation failed")
			break
		end

		local okParent, parentErr = pcall(function() tool.Parent = bp end)
		if not okParent then
			successAll = false
			errMsg = tostring(parentErr or "parent failed")
			break
		end

		local okAdd, addErr = pcall(function()
			PlayerProfileService.AddInventoryItem(player, "eggTools", {
				EggId         = tool:GetAttribute("EggId"),
				Rarity        = tool:GetAttribute("Rarity"),
				EggType       = tool:GetAttribute("EggType"),
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
			successAll = false
			errMsg = tostring(addErr or "persist failed")
			break
		end

		-- runtime inventory registration (non-fatal)
		if InventoryService and type(InventoryService.AddInventoryItem) == "function" then
			pcall(function()
				InventoryService.AddInventoryItem(player, "eggTools", {
					EggId         = tool:GetAttribute("EggId"),
					Rarity        = tool:GetAttribute("Rarity"),
					EggType       = tool:GetAttribute("EggType"),
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
		end

		table.insert(created, tool)
	end

	if not successAll then
		-- rollback
		for _, t in ipairs(created) do
			pcall(function() if t and t.Parent then t:Destroy() end end)
		end
		refundCoins(player, totalCost)
		updateLeaderstats(player)
		cleanupGuard()
		return fail(player, "Purchase failed: " .. (errMsg or "unknown"))
	end

	-- Save
	local saved = false
	local okSave, saveRes = pcall(function() return requestVerifiedSave(player, 3) end)
	if okSave and saveRes then saved = true end
	if not saved then pcall(function() PlayerProfileService.SaveNow(player, "PostEggPurchase") end) end

	ok(player, ("Bought %d x %s"):format(quantity, resolveEggDisplayName(opt.eggType)))
	sendInventory(player)
	updateLeaderstats(player)
	cleanupGuard()
	return
end

----------------------------------------------------------------
-- Purchase handler (now supports quantity on Egg purchases and Food purchases)
----------------------------------------------------------------
local function onPurchase(player, purchaseType, itemKey, quantity)
	if not player or not player.UserId then return end

	local okStatus, err = pcall(function()
		purchaseType = tostring(purchaseType or "")

		if purchaseType == "Egg" then
			-- Delegate to quantity-aware helper
			handlePurchaseEggs(player, itemKey, quantity)
			return

		elseif purchaseType == "Food" then
			-- sanitize quantity
			local q = tonumber(quantity) or 1
			if q < 1 then q = 1 end
			if q > MAX_PURCHASE_QUANTITY then q = MAX_PURCHASE_QUANTITY end

			-- Resolve canonical FoodId (robust)
			local resolved = findFoodIdCandidate(itemKey)
			if not resolved then
				return fail(player, "Unknown food")
			end

			local opt = FoodPurchaseOptions[itemKey] or FoodPurchaseOptions[resolved] or { cost = 0 }
			local unitCost = tonumber(opt.cost) or 0
			local totalCost = unitCost * q

			-- Attempt to spend coins via centralized CoinService
			local spent, reason = trySpendCoins(player, totalCost)
			if not spent then return fail(player, "Not enough coins") end

			-- Give q copies of the food (safeGiveFood), with rollback on failure
			local created = {}
			local bp = player:FindFirstChildOfClass("Backpack")
			if not bp then
				-- rollback refund
				refundCoins(player, totalCost)
				updateLeaderstats(player)
				return fail(player, "No backpack")
			end

			local successAll = true
			local errMsg = nil
			for i = 1, q do
				local tool, errReason = safeGiveFood(player, resolved, true)
				if not tool then
					-- try fallback with itemKey if different
					if tostring(itemKey) ~= tostring(resolved) then
						tool, errReason = safeGiveFood(player, tostring(itemKey), true)
					end
				end

				if not tool then
					successAll = false
					errMsg = tostring(errReason or "give failed")
					break
				end

				table.insert(created, tool)

				-- persist registration for this tool (best-effort)
				local okAdd, addErr = pcall(function()
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
					warnlog("PlayerProfileService.AddInventoryItem for foodTools failed:", tostring(addErr))
				end

				if InventoryService then
					pcall(function()
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
				end
			end

			if not successAll then
				-- rollback created tools + refund
				for _, t in ipairs(created) do
					pcall(function() if t and t.Parent then t:Destroy() end end)
				end
				refundCoins(player, totalCost)
				updateLeaderstats(player)
				return fail(player, "Food grant failed: " .. (errMsg or "unknown"))
			end

			-- verified save
			local saved = false
			local okSave, saveErr = pcall(function() return requestVerifiedSave(player, 3) end)
			if okSave and saveErr then saved = true end
			if not saved then pcall(function() PlayerProfileService.SaveNow(player, "PostFoodPurchase") end) end

			ok(player, ("Bought %d x %s"):format(q, opt.displayName or tostring(itemKey)))
			sendInventory(player)
			updateLeaderstats(player)
			return

		else
			return fail(player, "Invalid purchase type")
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
	RequestInventoryEvent.OnServerEvent:Connect(function(player) sendInventory(player) end)
	PurchaseEggEvent.OnServerEvent:Connect(onPurchase)
	hookPersistenceRestore()
	log("Initialized OK (Module).")
end

return ShopService