-- ShopService v3.3 (generic naming)
-- Changes from v3.2:
--   * Egg tool names are now ALWAYS the generic string "Egg" (no rarity prefix).
--   * Added config ALWAYS_USE_GENERIC_EGG_TOOL_NAME (true by default).
--   * Food purchase unchanged.
--   * Inventory snapshot still exposes rarity via attributes; UI can choose to display or hide.
--   * Removed player-facing rarity / weight from tool name to keep persistence & enumeration stable.
--
-- If you later want to show rarity, do it in UI by reading tool attributes (Rarity, ValueBase, etc.)
-- instead of encoding it into the Tool.Name (prevents churn in persistence diffs).

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local HttpService         = game:GetService("HttpService")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PurchaseEggEvent      = Remotes:WaitForChild("PurchaseEgg")
local PurchaseResultEvent   = Remotes:WaitForChild("PurchaseResult")
local RequestInventoryEvent = Remotes:WaitForChild("RequestInventory")
local InventoryUpdateEvent  = Remotes:WaitForChild("InventoryUpdate")

local ToolTemplates   = ReplicatedStorage:WaitForChild("ToolTemplates")
local EggToolTemplate = ToolTemplates:WaitForChild("EggToolTemplate")

local Modules     = ServerScriptService:WaitForChild("Modules")
local EggConfig   = require(Modules:WaitForChild("EggConfig"))
local RNG         = require(Modules:WaitForChild("RNG"))
local FoodService = require(Modules:WaitForChild("FoodService"))

local PlayerDataService
pcall(function() PlayerDataService = require(Modules:WaitForChild("PlayerDataService")) end)

local ShopService = {}
local _inited = false
local STATS_VERSION = 1

-- In-flight purchase suppression flag per player
local purchaseGuard = {}

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

-- NEW: enforce a single stable name for every egg tool
local ALWAYS_USE_GENERIC_EGG_TOOL_NAME = true
local GENERIC_EGG_TOOL_NAME = "Egg"

----------------------------------------------------------------
local function log(...) print("[ShopService]", ...) end

----------------------------------------------------------------
-- Coins helpers (NO immediate persistence here – deferred until after tool parent)
----------------------------------------------------------------
local function getCoins(player)
	if PlayerDataService and PlayerDataService.GetCoins then
		return PlayerDataService.GetCoins(player)
	end
	local ls = player:FindFirstChild("leaderstats")
	local c = ls and ls:FindFirstChild("Coins")
	return c and c.Value or 0
end

local function setCoinsNoImmediate(player, amount)
	if PlayerDataService and PlayerDataService.SetCoins then
		PlayerDataService.SetCoins(player, amount)
	else
		local ls = player:FindFirstChild("leaderstats")
		local c = ls and ls:FindFirstChild("Coins")
		if c then c.Value = amount end
	end
end

local function addCoinsNoImmediate(player, delta)
	setCoinsNoImmediate(player, math.max(0, getCoins(player) + delta))
end

----------------------------------------------------------------
-- Inventory snapshot
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
-- Egg tool creation
----------------------------------------------------------------
local function createEggTool(player, purchaseKey)
	local opt = EggPurchaseOptions[purchaseKey]
	if not opt then return nil, "Invalid egg key" end
	local rng   = RNG.New()
	local stats = EggConfig.GenerateEggStats(rng, opt.forcedRarity)
	local tool  = EggToolTemplate:Clone()
	local eggId = HttpService:GenerateGUID(false)

	-- Name logic simplified: always "Egg"
	if ALWAYS_USE_GENERIC_EGG_TOOL_NAME then
		tool.Name = GENERIC_EGG_TOOL_NAME
	else
		-- Fallback (if you ever disable the flag)
		tool.Name = (stats.Rarity or "Egg") .. " Egg"
	end

	tool:SetAttribute("EggId", eggId)
	tool:SetAttribute("ServerIssued", true)
	tool:SetAttribute("OwnerUserId", player.UserId)
	tool:SetAttribute("StatsVersion", STATS_VERSION)
	for k,v in pairs(stats) do
		tool:SetAttribute(k, v)
	end
	return tool
end

----------------------------------------------------------------
-- Purchase responses
----------------------------------------------------------------
local function fail(player, msg)
	PurchaseResultEvent:FireClient(player, {
		success = false,
		message = msg,
		remainingCoins = getCoins(player)
	})
end

local function ok(player, msg)
	PurchaseResultEvent:FireClient(player, {
		success = true,
		message = msg,
		remainingCoins = getCoins(player)
	})
end

----------------------------------------------------------------
-- Purchase handler (consolidated persistence)
----------------------------------------------------------------
local function onPurchase(player, purchaseType, itemKey)
	if purchaseGuard[player] then
		return fail(player, "Purchase in progress")
	end
	purchaseGuard[player] = true
	local cleanup = function() purchaseGuard[player] = nil end

	purchaseType = tostring(purchaseType or "")

	if purchaseType == "Egg" then
		local opt = EggPurchaseOptions[itemKey]; if not opt then cleanup(); return fail(player, "Unknown egg") end
		if getCoins(player) < opt.cost then cleanup(); return fail(player, "Not enough coins") end

		-- Deduct coins (no immediate save)
		addCoinsNoImmediate(player, -opt.cost)

		-- Create tool
		local tool, err = createEggTool(player, itemKey)
		if not tool then
			addCoinsNoImmediate(player, opt.cost) -- refund
			cleanup()
			return fail(player, "Creation failed: "..tostring(err))
		end

		local bp = player:FindFirstChildOfClass("Backpack")
		if not bp then
			addCoinsNoImmediate(player, opt.cost)
			tool:Destroy()
			cleanup()
			return fail(player, "No backpack")
		end

		tool.Parent = bp

		-- Single authoritative save AFTER tool is in backpack
		if PlayerDataService and PlayerDataService.SaveImmediately then
			PlayerDataService.SaveImmediately(player, "PostEggPurchase")
		end

		ok(player, ("Bought egg"))
		sendInventory(player)
		cleanup()
		return

	elseif purchaseType == "Food" then
		local opt = FoodPurchaseOptions[itemKey]; if not opt then cleanup(); return fail(player, "Unknown food") end
		if getCoins(player) < opt.cost then cleanup(); return fail(player, "Not enough coins") end

		addCoinsNoImmediate(player, -opt.cost)

		local tool = FoodService.GiveFood(player, itemKey, true)
		if not tool then
			addCoinsNoImmediate(player, opt.cost)
			cleanup()
			return fail(player, "Food creation failed")
		end

		if PlayerDataService and PlayerDataService.SaveImmediately then
			PlayerDataService.SaveImmediately(player, "PostFoodPurchase")
		end
		ok(player, ("Bought %s"):format(opt.displayName or itemKey))
		sendInventory(player)
		cleanup()
		return
	else
		cleanup()
		return fail(player, "Invalid purchase type")
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
	RequestInventoryEvent.OnServerEvent:Connect(sendInventory)
	PurchaseEggEvent.OnServerEvent:Connect(onPurchase)
	hookPersistenceRestore()
	log("Initialized OK (Module).")
end

return ShopService