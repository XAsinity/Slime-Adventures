-- Debug helper (Client) - drop into StarterPlayerScripts
-- Purpose: when you equip a Tool that appears to be a food tool, this will:
--  - print the tool name and resolved food def radii (if FoodDefinitions available)
--  - scan workspace:GetDescendants() for Model named "Slime"
--  - for each Slime print: FullName, PrimaryPart name, raw OwnerUserId attribute value, type(owner), tonumber(owner), FedFraction, distance to player HRP
--  - print whether slimeEligible() would allow creating a prompt (ownership + fullness checks) and whether distance <= ClientPromptRadius
-- Use this to diagnose attribute races, attribute types (string vs number), and distance vs radii issues.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local RS = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
if not player then return end

-- Attempt to require FoodDefinitions (non-yielding)
local FoodDefinitions = nil
pcall(function()
	FoodDefinitions = require(RS:WaitForChild("Modules"):WaitForChild("FoodDefinitions"))
end)

local SCAN_INTERVAL = 0.35

local function safeGetAttr(inst, name)
	if not inst or type(inst.GetAttribute) ~= "function" then return nil end
	local ok, v = pcall(function() return inst:GetAttribute(name) end)
	if ok then return v end
	return nil
end

local function resolveDefForTool(tool)
	if not tool then return nil end
	local fid = safeGetAttr(tool, "FoodId") or tool.Name
	if FoodDefinitions and type(FoodDefinitions.resolve) == "function" then
		local ok, def = pcall(function() return FoodDefinitions.resolve(fid) end)
		if ok and def then return def end
	end
	-- fallback defaults to show something
	return {
		ClientPromptRadius = 8,
		ClientActivationRadius = 4,
		ClientRemoveRadius = 10,
		RequireOwnership = true,
		OnlyWhenNotFull = false,
		FullnessHideThreshold = 0.999,
	}
end

local function distToSlimeFromPlayer(slime)
	if not slime then return math.huge end
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	local pp = slime.PrimaryPart or slime:FindFirstChildWhichIsA("BasePart")
	if not root or not pp then return math.huge end
	return (pp.Position - root.Position).Magnitude
end

local function inspectSlimesAndPrint(tool)
	local def = resolveDefForTool(tool)
	print(string.format("[DEBUG] Inspecting slimes for tool=%s fid=%s promptRadius=%.2f activationRadius=%.2f requireOwnership=%s",
		tostring(tool and tool.Name or "<nil>"),
		tostring(safeGetAttr(tool, "FoodId") or "<nil>"),
		tonumber(def.ClientPromptRadius) or -1,
		tonumber(def.ClientActivationRadius) or -1,
		tostring(def.RequireOwnership)))
	local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	for _,inst in ipairs(Workspace:GetDescendants()) do
		if inst:IsA("Model") and inst.Name == "Slime" then
			local fullname = inst:GetFullName()
			local pp = inst.PrimaryPart and inst.PrimaryPart.Name or (inst:FindFirstChildWhichIsA("BasePart") and inst:FindFirstChildWhichIsA("BasePart").Name) or "<no-PrimaryPart>"
			local rawOwner = safeGetAttr(inst, "OwnerUserId")
			local ownerType = typeof(rawOwner)
			local ownerNum = tonumber(rawOwner)
			local fed = safeGetAttr(inst, "FedFraction")
			local fedType = typeof(fed)
			local d = distToSlimeFromPlayer(inst)
			local ownershipOk = true
			if def.RequireOwnership then
				if ownerNum and ownerNum == player.UserId then
					ownershipOk = true
				else
					ownershipOk = false
				end
			end
			local fullnessOk = true
			if def.OnlyWhenNotFull then
				if typeof(fed) == "number" and fed >= (def.FullnessHideThreshold or 0.999) then
					fullnessOk = false
				end
			end
			local withinPromptRadius = (d <= (def.ClientPromptRadius or 0))
			print(string.format("  Slime: %s | PrimaryPart=%s | Owner_raw=%s (%s) | Owner_num=%s | Fed=%s (%s) | dist=%.2f | ownerOk=%s fullnessOk=%s withinRadius=%s",
				fullname,
				pp,
				tostring(rawOwner),
				ownerType,
				tostring(ownerNum),
				tostring(fed),
				fedType,
				d,
				tostring(ownershipOk),
				tostring(fullnessOk),
				tostring(withinPromptRadius)))
		end
	end
end

-- Track current equipped tool for this player
local currentTool = nil
local scanConn = nil
local function startScanning(tool)
	if scanConn then scanConn:Disconnect(); scanConn = nil end
	currentTool = tool
	print("[DEBUG] startScanning for tool:", tool and tool.Name or "<nil>")
	scanConn = RunService.Heartbeat:Connect(function()
		-- throttle scan interval
		local last = tick()
		-- simple timed loop using wait inside; use time-based gating to avoid flooding
	end)
	-- We'll use a simple spawn/loop to respect SCAN_INTERVAL (safer in Studio)
	spawn(function()
		while currentTool and currentTool.Parent and currentTool.Parent:IsDescendantOf(player.Character) do
			pcall(function()
				inspectSlimesAndPrint(currentTool)
			end)
			task.wait(SCAN_INTERVAL)
		end
		-- ended
		print("[DEBUG] scan loop ended for tool:", tostring(currentTool and currentTool.Name or "<nil>"))
	end)
end

local function stopScanning()
	currentTool = nil
	if scanConn then
		pcall(function() scanConn:Disconnect() end)
		scanConn = nil
	end
	print("[DEBUG] stopScanning")
end

-- Hook to character tools
local function hookTool(tool)
	if not tool or not tool:IsA("Tool") then return end
	if tool:GetAttribute("_DebugHooked") then return end
	tool:SetAttribute("_DebugHooked", true)
	tool.Equipped:Connect(function()
		-- only respond to tools that appear to be food (FoodItem attr or name contains "Food")
		local isFood = false
		local ok, v = pcall(function() return tool:GetAttribute("FoodItem") end)
		if ok and v then isFood = true end
		if not isFood then
			if string.find(tostring(tool.Name or ""), "Food") then isFood = true end
		end
		print("[DEBUG] Tool EQUIPPED (client):", tool:GetFullName(), "FoodItemAttr=", tostring(ok and v or "<err>"))
		if isFood then
			startScanning(tool)
		else
			print("[DEBUG] Equipped tool is not identified as food, skipping scans.")
		end
	end)
	tool.Unequipped:Connect(function()
		print("[DEBUG] Tool UNEQUIPPED (client):", tool:GetFullName())
		stopScanning()
	end)
end

-- Hook existing tools in backpack/character and future tools
local function setupHooks()
	local bp = player:FindFirstChildOfClass("Backpack")
	if bp then
		for _,t in ipairs(bp:GetChildren()) do
			if t:IsA("Tool") then hookTool(t) end
		end
		bp.ChildAdded:Connect(function(c) if c:IsA("Tool") then hookTool(c) end end)
	end
	if player.Character then
		for _,t in ipairs(player.Character:GetChildren()) do
			if t:IsA("Tool") then hookTool(t) end
		end
	end
	player.CharacterAdded:Connect(function(char)
		char.ChildAdded:Connect(function(c) if c:IsA("Tool") then hookTool(c) end end)
		-- also hook any pre-existing tools
		for _,t in ipairs(char:GetChildren()) do if t:IsA("Tool") then hookTool(t) end end
	end)
end

setupHooks()
print("[DEBUG] debug_food_owner_scan.lua initialized - equip a food tool to begin live scans.")