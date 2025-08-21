-- FoodClientBase (updated for neutral slime folder scanning)
-- Version: v1.2-persist-aware
-- Changes from v1.1:
--   * Added IsToolStillValid guard before firing remote (handles fast unequip).
--   * Added tool ancestry change listener to auto-clear prompts sooner.
--   * Minor log throttling for "No eligible slimes found".
--   * Maintains original functionality/scanning.
--
local Players      = game:GetService("Players")
local RS           = game:GetService("ReplicatedStorage")
local RunService   = game:GetService("RunService")
local Workspace    = game:GetService("Workspace")

local player       = Players.LocalPlayer
local FoodDefinitions = require(RS.Modules.FoodDefinitions)
local FeedRemote   = RS:WaitForChild("Remotes"):WaitForChild("FeedSlime")

----------------------------------------------------------------
-- Config
----------------------------------------------------------------
local DEBUG                        = true
local SCAN_INTERVAL                = 0.30
local DEFAULT_PROMPT_RADIUS        = 14
local DEFAULT_ACTIVATION_RADIUS    = 10
local DEFAULT_REMOVE_RADIUS_PAD    = 4
local NO_SLIME_WARN_COOLDOWN       = 3

local SLIME_ROOT_FOLDERS = {
	Workspace;
	Workspace:FindFirstChild("Slimes");
}

----------------------------------------------------------------
-- State
----------------------------------------------------------------
local activeTool
local prompts        = {}   -- [slimeModel] = ProximityPrompt
local lastScan       = 0
local lastFireTimes  = {}
local running        = false
local noSlimeWarnAt  = 0

----------------------------------------------------------------
local function dprint(...) if DEBUG then print("[FoodClientBase]", ...) end end

local function resolveFoodDef()
	if not activeTool then return nil end
	local id = activeTool:GetAttribute("FoodId")
	if not id or id == "" then return nil end
	local def = FoodDefinitions.resolve(id)
	if not def then return nil end
	if not def.ClientPromptRadius    then def.ClientPromptRadius    = DEFAULT_PROMPT_RADIUS end
	if not def.ClientActivationRadius then def.ClientActivationRadius = DEFAULT_ACTIVATION_RADIUS end
	if not def.ClientRemoveRadius then
		def.ClientRemoveRadius = (def.ClientPromptRadius or DEFAULT_PROMPT_RADIUS) + DEFAULT_REMOVE_RADIUS_PAD
	end
	return def
end

local function getRoot()
	return player.Character and player.Character:FindFirstChild("HumanoidRootPart")
end

local function distToSlime(slime)
	local pp   = slime.PrimaryPart or slime:FindFirstChildWhichIsA("BasePart")
	local root = getRoot()
	if not pp or not root then return math.huge end
	return (pp.Position - root.Position).Magnitude
end

local function isOwned(slime)
	return slime:GetAttribute("OwnerUserId") == player.UserId
end

local function slimeEligible(slime, def)
	if def.RequireOwnership and not isOwned(slime) then return false end
	if def.OnlyWhenNotFull then
		local fed = slime:GetAttribute("FedFraction")
		if typeof(fed) == "number" and fed >= (def.FullnessHideThreshold or 0.999) then
			return false
		end
	end
	return true
end

local function gatherSlimes(def)
	local list = {}
	for _,root in ipairs(SLIME_ROOT_FOLDERS) do
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

local function destroyPrompt(slime)
	local p = prompts[slime]
	if p then p:Destroy() end
	prompts[slime] = nil
end
local function clearPrompts()
	for s,_ in pairs(prompts) do destroyPrompt(s) end
end

local function isToolStillValid()
	return activeTool and activeTool.Parent and activeTool:GetAttribute("FoodItem")
end

local function fireFeed(slime, def, reason)
	if not isToolStillValid() then return end
	local now = time()
	if reason == "auto" then
		local last = lastFireTimes[slime] or 0
		if now - last < (def.AutoFeedCooldown or 1) then return end
		lastFireTimes[slime] = now
	end
	dprint(("FeedRemote FireServer reason=%s FoodId=%s dist=%.2f"):format(
		reason, tostring(activeTool:GetAttribute("FoodId")), distToSlime(slime)))
	FeedRemote:FireServer(slime, activeTool)
end

local function createPrompt(slime, def)
	if prompts[slime] or not slime.Parent then return end
	local part = slime.PrimaryPart or slime:FindFirstChildWhichIsA("BasePart")
	if not part then return end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "FoodFeedPrompt"
	prompt.ActionText = "Feed"
	prompt.ObjectText = "Slime"
	prompt.HoldDuration = 0
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = def.ClientActivationRadius
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	prompt.Parent = part
	prompt.Triggered:Connect(function(plr)
		if plr ~= player then return end
		if isToolStillValid() then
			fireFeed(slime, def, "prompt")
		end
	end)
	prompts[slime] = prompt
end

local function scan()
	local def = resolveFoodDef()
	if not def or not isToolStillValid() then
		if next(prompts) ~= nil then clearPrompts() end
		return
	end

	-- Cull / update existing prompts
	for slime,_ in pairs(prompts) do
		if not slime.Parent then
			destroyPrompt(slime)
		else
			local d = distToSlime(slime)
			if d > (def.ClientRemoveRadius or (def.ClientPromptRadius + DEFAULT_REMOVE_RADIUS_PAD))
				or not slimeEligible(slime, def) then
				destroyPrompt(slime)
			end
		end
	end

	-- Discover new slimes
	local slimes = gatherSlimes(def)
	if #slimes == 0 and (time() - noSlimeWarnAt) >= NO_SLIME_WARN_COOLDOWN then
		noSlimeWarnAt = time()
		dprint("No eligible slimes found (ensure neutral folder scanned).")
	end

	for _,slime in ipairs(slimes) do
		if not prompts[slime] then
			local d = distToSlime(slime)
			if d <= def.ClientPromptRadius then
				createPrompt(slime, def)
			end
		end
	end

	-- Auto-feed
	if def.AutoFeedNearby then
		for slime,_ in pairs(prompts) do
			if distToSlime(slime) <= def.ClientActivationRadius then
				fireFeed(slime, def, "auto")
			end
		end
	end
end

local function loop()
	running = true
	while running do
		if time() - lastScan >= SCAN_INTERVAL then
			lastScan = time()
			pcall(scan)
		end
		RunService.Heartbeat:Wait()
	end
end

local function isFoodTool(tool)
	return tool
		and tool:IsA("Tool")
		and tool:GetAttribute("FoodItem") == true
		and tool:GetAttribute("FoodId") ~= nil
end

local function setActiveTool(tool)
	if tool == activeTool then return end
	activeTool = tool
	if activeTool then
		dprint("Active food tool:", activeTool.Name, "FoodId=", activeTool:GetAttribute("FoodId"))
		if not running then task.spawn(loop) end
	else
		clearPrompts()
	end
end

local function hookCharacter(char)
	char.ChildAdded:Connect(function(child)
		if isFoodTool(child) then
			setActiveTool(child)
		end
	end)
	char.ChildRemoved:Connect(function(child)
		if child == activeTool then
			setActiveTool(nil)
		end
	end)
end

player.CharacterAdded:Connect(hookCharacter)
if player.Character then
	hookCharacter(player.Character)
	for _,c in ipairs(player.Character:GetChildren()) do
		if isFoodTool(c) then
			setActiveTool(c)
			break
		end
	end
end

player.Backpack.ChildAdded:Connect(function(child)
	if child:IsA("Tool") and child:GetAttribute("FoodItem") then
		dprint("Backpack food tool added:", child.Name)
	end
end)

player.Backpack.ChildRemoved:Connect(function(child)
	if child == activeTool then
		task.defer(function()
			if player.Character and child.Parent == player.Character then
				setActiveTool(child)
			end
		end)
	end
end)

dprint("FoodClientBase initialized (neutral folder scan enabled)")