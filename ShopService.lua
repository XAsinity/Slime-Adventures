-- ShopService v3.4 (PlayerProfileService-integrated)
-- Improvements:
--  - Use PlayerProfileService.SaveNowAndWait (preferVerified) via requestVerifiedSave helper.
--  - Safer fallbacks to ForceFullSaveNow or SaveNow+WaitForSaveComplete.
--  - Immediate leaderstats update after coin changes (fixed IsA precedence bug).
--  - Defensive pcall usage to avoid runtime errors during purchases.
--  - Minimal behavioral changes otherwise; rollback on failures preserved.
-----------------------------------------------------------------------

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
local PlayerProfileService = require(Modules:WaitForChild("PlayerProfileService"))

local ShopService = {}
local _inited = false
local STATS_VERSION = 1

-- use userId keyed guard
local purchaseGuard = {}

----------------------------------------------------------------
-- Config (unchanged)
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

local function log(...) print("[ShopService]", ...) end

----------------------------------------------------------------
-- Coins helpers (PlayerProfileService routed)
----------------------------------------------------------------
local function getCoins(player)
	local ok, val = pcall(function() return PlayerProfileService.GetCoins(player) end)
	if ok then return val or 0 end
	return 0
end

local function setCoins(player, amount)
	pcall(function() PlayerProfileService.SetCoins(player, amount) end)
end

local function addCoins(player, delta)
	pcall(function() PlayerProfileService.IncrementCoins(player, delta) end)
end

----------------------------------------------------------------
-- Verified save helper (prefer SaveNowAndWait then ForceFullSaveNow then SaveNow+WaitForSaveComplete)
----------------------------------------------------------------
local function requestVerifiedSave(playerOrId, timeoutSeconds)
	timeoutSeconds = tonumber(timeoutSeconds) or 3
	local ok, res = pcall(function()
		if type(PlayerProfileService.SaveNowAndWait) == "function" then
			-- prefer verified write
			return PlayerProfileService.SaveNowAndWait(playerOrId, timeoutSeconds, true)
		elseif type(PlayerProfileService.ForceFullSaveNow) == "function" then
			-- older API
			return PlayerProfileService.ForceFullSaveNow(playerOrId, "ShopService_VerifiedFallback")
		else
			-- fallback: schedule async save and wait for SaveComplete if available
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
	-- treat non-nil truthy as success
	return res == true or (res ~= nil and res ~= false)
end

----------------------------------------------------------------
-- Leaderstats updater (robust)
----------------------------------------------------------------
-- Update the player's leaderstats "Coins" IntValue immediately so UI reflects changes.
local function updateLeaderstats(player)
	if not player then return end
	local ls = player:FindFirstChild("leaderstats")
	if not ls then return end

	-- case-insensitive/robust search for the coins value
	local coinValue = ls:FindFirstChild("Coins") or ls:FindFirstChild("coins") or ls:FindFirstChild("CoinsValue")
	if coinValue and (coinValue:IsA("IntValue") or coinValue:IsA("NumberValue")) then
		local ok, val = pcall(function() return getCoins(player) end)
		if ok and type(val) == "number" then
			coinValue.Value = val
		end
	end
end

----------------------------------------------------------------
-- Inventory snapshot (unchanged)
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
	for k,v in pairs(stats) do
		tool:SetAttribute(k, v)
	end
	return tool
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
-- Purchase handler (PlayerProfileService persistence) with leaderstats updates
----------------------------------------------------------------
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

			-- Deduct coins (PlayerProfileService)
			addCoins(player, -opt.cost)
			-- Immediately update leaderstats so UI reflects change
			updateLeaderstats(player)

			-- Create tool
			local tool, createErr = createEggTool(player, itemKey)
			if not tool then
				-- refund
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
				})
			end)
			if not okAdd then
				-- rollback
				addCoins(player, opt.cost)
				updateLeaderstats(player)
				if tool and tool.Parent then pcall(function() tool:Destroy() end) end
				fail(player, "Failed to add to inventory: "..tostring(addErr))
				return
			end

			-- Immediate persistence (attempt verified, fallback async)
			local saved = false
			local okSave, saveErr = pcall(function()
				return requestVerifiedSave(player, 3)
			end)
			if okSave and saveErr then
				saved = true
			end
			if not saved then
				-- schedule async save (best-effort) and continue
				pcall(function() PlayerProfileService.SaveNow(player, "PostEggPurchase") end)
			end

			ok(player, ("Bought egg"))
			sendInventory(player)
			cleanup()
			return

		elseif purchaseType == "Food" then
			local opt = FoodPurchaseOptions[itemKey]; if not opt then cleanup(); return fail(player, "Unknown food") end
			local coins = getCoins(player) or 0
			if coins < opt.cost then cleanup(); return fail(player, "Not enough coins") end

			addCoins(player, -opt.cost)
			updateLeaderstats(player)

			local tool = nil
			local okGive, giveErr = pcall(function()
				tool = FoodService.GiveFood(player, itemKey, true)
			end)
			if not okGive or not tool then
				addCoins(player, opt.cost)
				updateLeaderstats(player)
				fail(player, "Food creation failed: "..tostring(giveErr))
				return
			end

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
				})
			end)
			if not okAdd then
				addCoins(player, opt.cost)
				updateLeaderstats(player)
				if tool and tool.Parent then pcall(function() tool:Destroy() end) end
				fail(player, "Failed to add food to inventory: "..tostring(addErr))
				return
			end

			local saved = false
			local okSave, saveErr = pcall(function()
				return requestVerifiedSave(player, 3)
			end)
			if okSave and saveErr then saved = true end
			if not saved then
				pcall(function() PlayerProfileService.SaveNow(player, "PostFoodPurchase") end)
			end

			ok(player, ("Bought %s"):format(opt.displayName or itemKey))
			sendInventory(player)
			cleanup()
			return
		else
			fail(player, "Invalid purchase type")
			return
		end
	end)

	-- If pcall failed with an error, attempt logging and best-effort refund
	if not okStatus then
		pcall(function()
			log("ERROR in onPurchase for player", player.Name, "err=", tostring(err))
		end)
		-- best-effort refund: we don't know what changed; notify client to retry inventory
		fail(player, "Internal error processing purchase")
	end

	cleanup()
end

----------------------------------------------------------------
-- Player join (unchanged)
----------------------------------------------------------------
local function onPlayerAdded(player)
	task.defer(sendInventory, player)
end

----------------------------------------------------------------
-- Persistence restore hook (unchanged)
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
-- Init (unchanged)
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