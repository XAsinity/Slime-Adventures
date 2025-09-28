-- Enhanced FoodClient (for slime feeding prompts, with better default range and extra debug)

local Players      = game:GetService("Players")
local RS           = game:GetService("ReplicatedStorage")
local RunService   = game:GetService("RunService")
local Workspace    = game:GetService("Workspace")
local HttpService  = game:GetService("HttpService")

local player = Players.LocalPlayer
local Remotes = RS:WaitForChild("Remotes")
local FeedRemote = Remotes:WaitForChild("FeedSlime")

local FoodDefinitions = nil
pcall(function()
	FoodDefinitions = require(RS.Modules:WaitForChild("FoodDefinitions"))
end)

local FoodClient = {}

-- --------------- CONFIGURABLE DISTANCES ---------------
local DEFAULT_PROMPT_RADIUS        = 16 -- studs: how close before prompt appears
local DEFAULT_ACTIVATION_RADIUS    = 16 -- studs: how close before feeding is triggered (prompt click)
local DEFAULT_REMOVE_RADIUS_PAD    = 4
local NO_SLIME_WARN_COOLDOWN       = 3

local VERBOSE_DEBUG = true -- set true for extra debug output

local function dprint(...)
	if VERBOSE_DEBUG then print("[FoodClient][DEBUG]", ...) end
end

-- ----------- Utility -----------
local function safeGetAttr(inst, name)
	if not inst or type(inst.GetAttribute) ~= "function" then return nil end
	local ok, v = pcall(function() return inst:GetAttribute(name) end)
	if ok then return v end
	return nil
end
local function safeSetAttr(inst, name, val)
	if not inst or type(inst.SetAttribute) ~= "function" then return end
	pcall(function() inst:SetAttribute(name, val) end)
end
local function isToolInstance(tool)
	if not tool then return false end
	local ok, res = pcall(function() return tool:IsA("Tool") end)
	return ok and res
end
local function ensureToolAttributes(tool)
	if not isToolInstance(tool) then return end
	if safeGetAttr(tool, "FoodItem") == nil then safeSetAttr(tool, "FoodItem", true) end
	if not safeGetAttr(tool, "FoodId") or safeGetAttr(tool, "FoodId") == "" then
		safeSetAttr(tool, "FoodId", tool:GetAttribute("FoodId") or tool.Name or "UnknownFood")
	end
	if safeGetAttr(tool, "Charges") == nil then safeSetAttr(tool, "Charges", 1) end
	if safeGetAttr(tool, "Consumable") == nil then safeSetAttr(tool, "Consumable", true) end
	if safeGetAttr(tool, "RestoreFraction") == nil then safeSetAttr(tool, "RestoreFraction", 0.25) end
	if not safeGetAttr(tool, "ToolUniqueId") or safeGetAttr(tool, "ToolUniqueId") == "" then
		local ok, guid = pcall(function() return HttpService:GenerateGUID(false) end)
		if ok and guid then safeSetAttr(tool, "ToolUniqueId", guid) end
	end
end

local function resolveFoodDefForTool(tool)
	if not tool then return nil end
	local fid = safeGetAttr(tool, "FoodId")
	if not fid then return nil end
	local def = nil
	if FoodDefinitions and type(FoodDefinitions.resolve) == "function" then
		pcall(function() def = FoodDefinitions.resolve(fid) end)
	end
	if not def then
		def = {
			RestoreFraction = 0.25,
			FeedBufferBonus = 15,
			Charges = 1,
			Consumable = true,
			ClientPromptRadius = DEFAULT_PROMPT_RADIUS,
			ClientActivationRadius = DEFAULT_ACTIVATION_RADIUS,
			AutoFeedNearby = false,
			AutoFeedCooldown = 1,
			RequireOwnership = true,
			OnlyWhenNotFull = false,
			FullnessHideThreshold = 0.999,
		}
	end
	if not def.ClientPromptRadius then def.ClientPromptRadius = DEFAULT_PROMPT_RADIUS end
	if not def.ClientActivationRadius then def.ClientActivationRadius = DEFAULT_ACTIVATION_RADIUS end
	if not def.ClientRemoveRadius then
		def.ClientRemoveRadius = def.ClientPromptRadius + DEFAULT_REMOVE_RADIUS_PAD
	else
		local minAllow = def.ClientPromptRadius + DEFAULT_REMOVE_RADIUS_PAD
		if def.ClientRemoveRadius < minAllow then
			dprint(string.format("Adjusting ClientRemoveRadius for FoodId=%s from %.2f -> %.2f", tostring(fid), tonumber(def.ClientRemoveRadius) or 0, minAllow))
			def.ClientRemoveRadius = minAllow
		end
	end
	return def
end

-- ----------- Slime helpers -----------
local function findSlimeModelFromPart(part)
	if not part then return nil end
	local node = part
	local depth = 0
	while node and node.Parent and depth < 40 do
		if node:IsA("Model") and node.Name == "Slime" then return node end
		node = node.Parent
		depth = depth + 1
	end
	return nil
end
local function distToSlimeFromPlayer(slime)
	if not slime then return math.huge end
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	local pp = slime.PrimaryPart or slime:FindFirstChildWhichIsA("BasePart")
	if not root or not pp then return math.huge end
	return (pp.Position - root.Position).Magnitude
end
local function isOwnedByLocal(slime)
	if not slime then return false end
	local ok, v = pcall(function() return slime:GetAttribute("OwnerUserId") end)
	if not ok or v == nil then return false end
	local uid = tonumber(v) or nil
	return uid == player.UserId
end
local function slimeEligible(slime, def)
	if not slime or not slime.Parent then return false end
	if def.RequireOwnership and not isOwnedByLocal(slime) then return false end
	if def.OnlyWhenNotFull then
		local fed = slime:GetAttribute("FedFraction")
		if typeof(fed) == "number" and fed >= (def.FullnessHideThreshold or 0.999) then
			return false
		end
	end
	return true
end

local function get_slime_roots()
	local roots = {Workspace}
	local s = Workspace:FindFirstChild("Slimes")
	if s then table.insert(roots, s) end
	return roots
end
local function gatherSlimes(def)
	local list = {}
	for _,root in ipairs(get_slime_roots()) do
		if root and root.Parent then
			for _,desc in ipairs(root:GetDescendants()) do
				if desc:IsA("Model") and desc.Name == "Slime" and slimeEligible(desc, def) then
					table.insert(list, desc)
				end
			end
		end
	end
	return list
end

-- ----------- Prompt management -----------
local function _clientPreserveTool(tool)
	if not tool then return false end
	if not isToolInstance(tool) then return false end
	if safeGetAttr(tool, "ServerIssued") then return true end
	if safeGetAttr(tool, "ServerRestore") then return true end
	if safeGetAttr(tool, "PreserveOnClient") then return true end
	if safeGetAttr(tool, "ToolUniqueId") then return true end
	return false
end

local function createPromptForSlime(slime, def, prompts, tool)
	if not slime or prompts[slime] or not slime.Parent then return end
	local part = slime.PrimaryPart or slime:FindFirstChildWhichIsA("BasePart")
	if not part then
		dprint("No BasePart found to attach prompt for slime:", slime:GetFullName())
		return
	end
	local dist = distToSlimeFromPlayer(slime)
	dprint(string.format("Creating FoodFeedPrompt on slime=%s part=%s dist=%.2f tool=%s promptRadius=%.2f activationRadius=%.2f",
		tostring(slime:GetFullName()), tostring(part:GetFullName()), dist, tostring(tool and tool.Name or "<no-tool>"),
		def.ClientPromptRadius, def.ClientActivationRadius))
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "FoodFeedPrompt"
	prompt.ActionText = "Feed"
	prompt.ObjectText = "Slime"
	prompt.HoldDuration = 0
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = def.ClientPromptRadius
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	prompt.Parent = part
	prompt.Triggered:Connect(function(plr)
		if plr ~= player then return end
		if prompts._isToolStillValid() then
			prompts._fireFeed(slime, "prompt")
		end
	end)
	prompts[slime] = prompt
end

local function destroyPromptForSlime(slime, prompts)
	local p = prompts[slime]
	if not p then return end
	dprint("Destroying prompt for slime:", slime:GetFullName(), "parentPart=", p.Parent and p.Parent:GetFullName() or "<nil>")
	local parentTool = p.Parent and p.Parent.Parent
	if parentTool and _clientPreserveTool(parentTool) then
		-- preserve
	else
		p:Destroy()
	end
	prompts[slime] = nil
end

-- ----------- Attach lifecycle -----------
function FoodClient.Attach(tool)
	if not isToolInstance(tool) then
		warn("[FoodClient] Attach called with non-Tool", tostring(tool))
		return
	end
	if safeGetAttr(tool, "_FoodClientAttached") then
		dprint("already attached for tool:", tool.Name)
		return
	end
	safeSetAttr(tool, "_FoodClientAttached", true)

	dprint("Attach called for tool:", tool.Name)
	ensureToolAttributes(tool)
	local prompts = {}
	local lastScan = 0
	local lastFireTimes = {}
	local noSlimeWarnAt = 0
	local running = false
	local function isToolStillValid()
		return tool and tool.Parent and safeGetAttr(tool, "FoodItem")
	end
	local function fireFeed(slime, reason)
		if not isToolStillValid() then return end
		if not slime or not slime.Parent then return end
		local now = time()
		if reason == "auto" then
			local def = resolveFoodDefForTool(tool)
			local last = lastFireTimes[slime] or 0
			if now - last < (def.AutoFeedCooldown or 1) then return end
			lastFireTimes[slime] = now
		end
		pcall(function()
			FeedRemote:FireServer(slime, tool)
		end)
	end
	prompts._isToolStillValid = isToolStillValid
	prompts._fireFeed = fireFeed

	local function scanOnce()
		if not isToolStillValid() then
			for s,_ in pairs(prompts) do
				destroyPromptForSlime(s, prompts)
			end
			return
		end
		local def = resolveFoodDefForTool(tool)
		if not def then return end

		for s,_ in pairs(prompts) do
			if not s.Parent then
				destroyPromptForSlime(s, prompts)
			else
				local d = distToSlimeFromPlayer(s)
				if d > def.ClientRemoveRadius or not slimeEligible(s, def) then
					destroyPromptForSlime(s, prompts)
				end
			end
		end

		local slimes = gatherSlimes(def)
		dprint("gatherSlimes returned count=", #slimes)
		for i,s in ipairs(slimes) do
			local pp = s.PrimaryPart or s:FindFirstChildWhichIsA("BasePart")
			local d = distToSlimeFromPlayer(s)
			local eligible = slimeEligible(s, def)
			dprint(string.format("candidate[%d] = %s  PrimaryPart=%s dist=%.2f eligible=%s", i, s:GetFullName(), pp and pp:GetFullName() or "<no-part>", d, tostring(eligible)))
			if eligible and not prompts[s] and d <= def.ClientPromptRadius then
				createPromptForSlime(s, def, prompts, tool)
			end
		end

		if def.AutoFeedNearby then
			for s,_ in pairs(prompts) do
				if distToSlimeFromPlayer(s) <= def.ClientActivationRadius then
					fireFeed(s, "auto")
				end
			end
		end
	end

	local loopConn
	local function startLoop()
		if running then return end
		running = true
		dprint("startLoop for tool:", tool.Name)
		loopConn = RunService.Heartbeat:Connect(function()
			if time() - lastScan >= 0.30 then
				lastScan = time()
				pcall(scanOnce)
			end
		end)
	end
	local function stopLoop()
		if loopConn and loopConn.Connected then
			loopConn:Disconnect()
			loopConn = nil
		end
		for s,_ in pairs(prompts) do
			destroyPromptForSlime(s, prompts)
		end
		running = false
		dprint("stopLoop for tool:", tool.Name)
	end

	local mouseConn, activatedConn
	tool.Equipped:Connect(function()
		dprint("EQUIPPED tool=", tool.Name)
		ensureToolAttributes(tool)
		startLoop()
		local ok, mouse = pcall(function() return player:GetMouse() end)
		if ok and mouse then
			if not mouseConn then
				mouseConn = mouse.Button1Down:Connect(function()
					local target = mouse.Target
					if target then
						local slime = findSlimeModelFromPart(target)
						if slime and slimeEligible(slime, resolveFoodDefForTool(tool)) then
							fireFeed(slime, "click")
						end
					end
				end)
			end
		end
		if not activatedConn then
			activatedConn = tool.Activated:Connect(function()
				local ok2, m = pcall(function() return player:GetMouse() end)
				if ok2 and m and m.Target then
					local slime = findSlimeModelFromPart(m.Target)
					if slime and slimeEligible(slime, resolveFoodDefForTool(tool)) then
						fireFeed(slime, "activate")
					end
				end
			end)
		end
	end)
	tool.Unequipped:Connect(function()
		dprint("UNEQUIPPED tool=", tool.Name)
		if mouseConn then
			pcall(function() mouseConn:Disconnect() end)
			mouseConn = nil
		end
		if activatedConn then
			pcall(function() activatedConn:Disconnect() end)
			activatedConn = nil
		end
		if not (tool.Parent and (tool.Parent:IsDescendantOf(player.Character) or tool.Parent == player.Backpack)) then
			stopLoop()
		else
			task.defer(function()
				if not (tool.Parent and (tool.Parent:IsDescendantOf(player.Character) or tool.Parent == player.Backpack)) then
					stopLoop()
				end
			end)
		end
	end)
	tool.AncestryChanged:Connect(function(_, parent)
		if not parent then
			stopLoop()
		end
	end)
	task.defer(function()
		local p = tool.Parent
		if p and (p:IsDescendantOf(player.Character) or p == player.Backpack) then
			startLoop()
		end
	end)
	dprint("Attach complete for tool:", tool.Name, "FoodId=", safeGetAttr(tool, "FoodId"))
end

return FoodClient