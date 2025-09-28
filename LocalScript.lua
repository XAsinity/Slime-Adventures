-- Temporary debug: drop into StarterPlayerScripts to inspect FoodClient/tool/slime state (client-side).
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
if not player then return end
task.defer(function()
	wait(1) -- let things initialize

	local function listTools()
		print("---- DEBUG: Listing Tools in Backpack and Character ----")
		local function inspectTool(tool, where)
			if not tool then return end
			print(("Tool: %s (parent=%s)"):format(tool.Name, tostring(tool.Parent and tool.Parent:GetFullName() or "<nil>")))
			-- attributes
			local attrs = {"_FoodClientAttached","FoodItem","FoodId","Charges","Consumable","ToolUniqueId","ServerIssued","ServerRestore"}
			for _,a in ipairs(attrs) do
				local ok, v = pcall(function() return tool:GetAttribute(a) end)
				if ok then print(("  attr %s = %s"):format(a, tostring(v))) end
			end
			-- localscripts under the tool
			for _,c in ipairs(tool:GetChildren()) do
				if c:IsA("LocalScript") then
					print("  Contains LocalScript:", c.Name)
				end
			end
		end

		local bp = player:FindFirstChildOfClass("Backpack")
		if bp then
			for _,t in ipairs(bp:GetChildren()) do
				if t:IsA("Tool") then inspectTool(t, "Backpack") end
			end
		else
			print("  No Backpack found")
		end

		local char = player.Character
		if char then
			for _,t in ipairs(char:GetChildren()) do
				if t:IsA("Tool") then inspectTool(t, "Character") end
			end
		end
	end

	local function findProximityPrompts()
		print("---- DEBUG: Searching for existing FoodFeedPrompt prompts in Workspace ----")
		for _,p in ipairs(Workspace:GetDescendants()) do
			if p:IsA("ProximityPrompt") and p.Name == "FoodFeedPrompt" then
				print("Found prompt at:", p:GetFullName(), "MaxActivationDistance=", p.MaxActivationDistance)
			end
		end
	end

	local function listSlimes()
		print("---- DEBUG: Listing Slime models (PrimaryPart, OwnerUserId, FedFraction, distance) ----")
		local rootFolders = { Workspace, Workspace:FindFirstChild("Slimes") }
		local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		for _,root in ipairs(rootFolders) do
			if root and root.Parent then
				for _,desc in ipairs(root:GetDescendants()) do
					if desc:IsA("Model") and desc.Name == "Slime" then
						local pp = desc.PrimaryPart or desc:FindFirstChildWhichIsA("BasePart")
						local ownerOk, owner = pcall(function() return desc:GetAttribute("OwnerUserId") end)
						local fedOk, fed = pcall(function() return desc:GetAttribute("FedFraction") end)
						local d = math.huge
						if hrp and pp then
							d = (pp.Position - hrp.Position).Magnitude
						end
						print(("Slime: %s  PrimaryPart=%s  OwnerUserId=%s  Fed=%s  dist=%.2f"):format(
							desc:GetFullName(),
							(pp and pp.Name or "<nil>"),
							(ownerOk and tostring(owner) or "<error>"),
							(fedOk and tostring(fed) or "<error>"),
							d))
					end
				end
			end
		end
	end

	local function printResolvedDef(tool)
		if not tool then return end
		print("---- DEBUG: Resolved FoodDefinition for tool", tool.Name)
		local def = nil
		local ok, foodModule = pcall(function() return require(RS.Modules:WaitForChild("FoodDefinitions")) end)
		if ok and foodModule and type(foodModule.resolve) == "function" then
			local ok2, res = pcall(function() return foodModule.resolve(tool:GetAttribute("FoodId") or tool.Name) end)
			if ok2 then def = res end
		end
		if not def then
			print("  Could not resolve food def (module missing or resolve failed).")
			return
		end
		for k,v in pairs(def) do
			print(("  %s = %s"):format(tostring(k), tostring(v)))
		end
	end

	-- attach Equipped listeners for any runtime tools to confirm client sees equip
	local function attachEquipListeners()
		local function hookTool(tool)
			if not tool or not tool:IsA("Tool") then return end
			-- avoid double-binding
			if tool:GetAttribute("_DebugHooked") then return end
			tool:SetAttribute("_DebugHooked", true)
			print("DEBUG: hooking tool events for", tool:GetFullName())
			tool.Equipped:Connect(function()
				print("DEBUG: Tool EQUIPPED (client):", tool:GetFullName(), "parent now", tostring(tool.Parent and tool.Parent:GetFullName() or "<nil>"))
				-- print resolved def when equip happens
				printResolvedDef(tool)
				-- list slimes/distance at equip time
				listSlimes()
				-- show existing prompts
				findProximityPrompts()
			end)
			tool.Unequipped:Connect(function()
				print("DEBUG: Tool UNEQUIPPED (client):", tool:GetFullName())
			end)
		end

		-- hook existing tools
		local bp = player:FindFirstChildOfClass("Backpack")
		if bp then
			for _,t in ipairs(bp:GetChildren()) do if t:IsA("Tool") then hookTool(t) end end
			bp.ChildAdded:Connect(function(c) if c:IsA("Tool") then hookTool(c) end end)
		end
		-- hook tools that might be parented to character
		if player.Character then
			for _,t in ipairs(player.Character:GetChildren()) do if t:IsA("Tool") then hookTool(t) end end
			player.Character.ChildAdded:Connect(function(c) if c:IsA("Tool") then hookTool(c) end end)
		end
		player.CharacterAdded:Connect(function(char)
			char.ChildAdded:Connect(function(c) if c:IsA("Tool") then hookTool(c) end end)
		end)
	end

	-- run checks now
	listTools()
	listSlimes()
	findProximityPrompts()
	attachEquipListeners()

	print("---- DEBUG: Probe complete. Now equip a food tool and watch Client Output for equip-time logs ----")
end)