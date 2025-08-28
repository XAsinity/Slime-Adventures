-- Minimal PreExitInventorySync stub: captures server-side inventory and forces a save on PlayerRemoving
local Players        = game:GetService("Players")
local Workspace      = game:GetService("Workspace")
local ServerStorage  = game:GetService("ServerStorage")
local HttpService    = game:GetService("HttpService")

local PlayerProfileService = require(game.ServerScriptService.Modules:WaitForChild("PlayerProfileService"))

local PreExitInventorySync = {}

local function collect_world_slimes(userId)
	local out = {}
	for _,inst in ipairs(Workspace:GetDescendants()) do
		if inst:IsA("Model") and inst.Name == "Slime" and tostring(inst:GetAttribute("OwnerUserId")) == tostring(userId) then
			local entry = { id = inst:GetAttribute("SlimeId"), px = 0, py = 0, pz = 0 }
			local prim = inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart")
			if prim then
				local cf = prim:GetPivot()
				entry.px, entry.py, entry.pz = cf.X, cf.Y, cf.Z
			end
			out[#out+1] = entry
		end
	end
	return out
end

local function collect_world_eggs(userId)
	local out = {}
	for _,inst in ipairs(Workspace:GetDescendants()) do
		if inst:IsA("Model") and inst.Name == "Egg" and tostring(inst:GetAttribute("OwnerUserId")) == tostring(userId) then
			local prim = inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart")
			local cf = prim and prim:GetPivot() or CFrame.new()
			local id = inst:GetAttribute("EggId") or ("Egg_"..tostring(math.random(1,1e9)))
			out[#out+1] = { id = id, px = cf.X, py = cf.Y, pz = cf.Z, ht = inst:GetAttribute("HatchTime"), ha = inst:GetAttribute("HatchAt"), tr = 0 }
		end
	end
	return out
end

local function collect_staged_tools(userId)
	local eggTools, foodTools, captured = {}, {}, {}
	for _,inst in ipairs(ServerStorage:GetDescendants()) do
		if inst:IsA("Tool") then
			local owner = inst:GetAttribute("OwnerUserId")
			if tostring(owner) == tostring(userId) then
				if inst:GetAttribute("FoodItem") or inst:GetAttribute("FoodId") then
					table.insert(foodTools, { nm = inst.Name, fid = inst:GetAttribute("FoodId"), uid = inst:GetAttribute("ToolUniqueId") })
				elseif inst:GetAttribute("SlimeItem") or inst:GetAttribute("Captured") then
					table.insert(captured, { nm = inst.Name, id = inst:GetAttribute("SlimeId"), uid = inst:GetAttribute("ToolUniqueId") })
				else
					table.insert(eggTools, { nm = inst.Name, id = inst:GetAttribute("EggId") or inst:GetAttribute("ToolUniqueId"), uid = inst:GetAttribute("ToolUniqueId") })
				end
			end
		end
	end
	return nil, eggTools, foodTools, captured  -- Fix: remove undefined 'world' global
end

function PreExitInventorySync.Init()
	-- safe attach: idempotent
	if PreExitInventorySync._installed then return end
	PreExitInventorySync._installed = true

	Players.PlayerRemoving:Connect(function(player)
		if not player then return end
		local ok, err = pcall(function()
			local uid = player.UserId
			-- collect server-side inventories
			local worldSlimes = collect_world_slimes(uid)
			local worldEggs   = collect_world_eggs(uid)
			local _, eggTools, foodTools, captured = collect_staged_tools(uid)

			-- obtain profile (use GetProfile helper)
			local profile = PlayerProfileService.GetProfile(player)
			if not profile then
				-- nothing we can do
				return
			end

			profile.inventory = profile.inventory or {}
			profile.inventory.worldSlimes    = worldSlimes or {}
			profile.inventory.worldEggs      = worldEggs   or {}
			profile.inventory.eggTools       = eggTools    or {}
			profile.inventory.foodTools      = foodTools   or {}
			profile.inventory.capturedSlimes = captured     or {}

			profile.meta = profile.meta or {}
			profile.meta.lastPreExitSnapshot = os.time()

			-- request immediate persistence
			pcall(function() PlayerProfileService.SaveNow(player, "PreExitInventorySync") end)
			pcall(function() PlayerProfileService.ForceFullSaveNow(player, "PreExitInventorySync_Force") end)
		end)
		if not ok then
			warn("[PreExitInventorySync] PlayerRemoving handler error for", player and player.Name or "nil", err)
		end
	end)
end

return PreExitInventorySync