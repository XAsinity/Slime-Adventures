-- ToolTemplates/FoodToolTemplateClient.lua
-- LocalScript intended to be parented under a Tool template (ReplicatedStorage.ToolTemplates.*)
-- Mirrors the "tool-local" client behavior used by other tool templates (egg tool client).
-- - Ensures attributes exist on the tool
-- - Handles Equip, Activated, and mouse click to FireServer to FeedSlime remote
-- - Plays optional EatSound under Handle
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local localPlayer = Players.LocalPlayer
if not localPlayer then
	-- This script must run on a client; bail gracefully if not present.
	return
end

local TOOL = script.Parent
-- If script isn't parented yet, wait until it is (safe startup)
while not TOOL or not TOOL:IsA("Tool") do
	task.wait(0.05)
	TOOL = script.Parent
end

-- Remote we will use (existing FeedSlime remote used by FoodClientBase)
local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
local FeedRemote = remotesFolder and remotesFolder:FindFirstChild("FeedSlime")

local function safeSetAttr(inst, name, val)
	if not inst or type(inst.SetAttribute) ~= "function" then return end
	pcall(function() inst:SetAttribute(name, val) end)
end

local function safeGetAttr(inst, name)
	if not inst or type(inst.GetAttribute) ~= "function" then return nil end
	local ok, v = pcall(function() return inst:GetAttribute(name) end)
	if ok then return v end
	return nil
end

-- Ensure canonical food attributes exist so tooling and server code see consistent shape
local function ensureToolAttributes(tool)
	-- mark as food item
	if safeGetAttr(tool, "FoodItem") == nil then
		safeSetAttr(tool, "FoodItem", true)
	end
	-- FoodId fallback to tool.Name or a template attribute
	if not safeGetAttr(tool, "FoodId") or safeGetAttr(tool, "FoodId") == "" then
		safeSetAttr(tool, "FoodId", tool:GetAttribute("FoodId") or tool.Name or "UnknownFood")
	end
	-- Charges
	if safeGetAttr(tool, "Charges") == nil then
		safeSetAttr(tool, "Charges", 1)
	end
	-- Consumable default
	if safeGetAttr(tool, "Consumable") == nil then
		safeSetAttr(tool, "Consumable", true)
	end
	-- RestoreFraction (optional)
	if safeGetAttr(tool, "RestoreFraction") == nil then
		-- leave nil if you prefer serializer to set; default to 0.25
		safeSetAttr(tool, "RestoreFraction", 0.25)
	end
	-- ToolUniqueId: generate a GUID client-side for consistent client-local identity (server authoritative assign may still happen)
	if not safeGetAttr(tool, "ToolUniqueId") or safeGetAttr(tool, "ToolUniqueId") == "" then
		local ok, guid = pcall(function() return HttpService:GenerateGUID(false) end)
		if ok and guid then
			safeSetAttr(tool, "ToolUniqueId", guid)
		else
			safeSetAttr(tool, "ToolUniqueId", tostring(tick()) .. "-" .. tostring(math.random(1, 1e6)))
		end
	end
end

-- Helper: find slime model ancestor from a BasePart
local function findSlimeModelFromPart(part)
	if not part then return nil end
	local node = part
	while node and node.Parent do
		if node:IsA("Model") and node.Name == "Slime" then
			return node
		end
		node = node.Parent
	end
	return nil
end

-- Attempt to resolve targeted slime using Mouse.Target or Workspace selection (used on click/activated)
local function resolveTargetedSlime(mouse)
	-- prefer prompt-driven proximity flow (FoodClientBase creates the prompt that directly fires server).
	-- For explicit tool activation, try mouse.Target first
	local target = nil
	if mouse then
		target = mouse.Target
	end
	-- If target is a descendant, try to find slime model ancestor
	if target then
		local slime = findSlimeModelFromPart(target)
		if slime then return slime end
	end
	-- fallback heuristics: if tool has a stored "LastTarget" attribute (some clients may set), try that
	local lastTarget = safeGetAttr(TOOL, "LastTargetInstance")
	if lastTarget and typeof(lastTarget) == "Instance" then
		local slime = findSlimeModelFromPart(lastTarget)
		if slime then return slime end
	end
	return nil
end

-- Play local eat sound if present
local function playEatSound(tool)
	local handle = tool:FindFirstChild("Handle")
	if handle then
		local s = handle:FindFirstChild("EatSound")
		if s and s:IsA("Sound") then
			pcall(function() s:Play() end)
		end
	end
end

-- Main feed action: send remote to server. Keep local checks that preserve fast unequip race.
local function doFeed(slime)
	if not slime then return end
	if not TOOL or not TOOL.Parent then return end
	-- Ensure the remote exists
	if not FeedRemote or type(FeedRemote.FireServer) ~= "function" then
		-- Remote missing: warn once
		warn("[FoodToolClient] FeedSlime remote not found; cannot perform client-initiated feed.")
		return
	end
	-- Fire to server with slime model + tool instance (server will validate ownership/attributes)
	pcall(function()
		FeedRemote:FireServer(slime, TOOL)
	end)
	-- Play local audio feedback
	pcall(function() playEatSound(TOOL) end)
end

-- Mouse click handler (left click) while equipped
local mouseConn = nil
local activatedConn = nil
local equipped = false
local mouseRef = nil

local function onEquip(mouse)
	equipped = true
	mouseRef = mouse
	-- ensure attributes every equip (templates may be cloned)
	ensureToolAttributes(TOOL)
	-- connect mouse left click
	if mouse and not mouseConn then
		mouseConn = mouse.Button1Down:Connect(function()
			-- resolve targeted slime and feed
			local slime = resolveTargetedSlime(mouse)
			if slime then
				doFeed(slime)
			end
		end)
	end
	-- connect tool.Activated for gamepad/keyboard activation
	if not activatedConn then
		activatedConn = TOOL.Activated:Connect(function()
			-- if proximity prompt workflow is active it prefers that; here we try to feed the nearest slime under crosshair
			local slime = resolveTargetedSlime(mouseRef)
			if slime then
				doFeed(slime)
			end
		end)
	end
end

local function onUnequip()
	equipped = false
	if mouseConn then
		pcall(function() mouseConn:Disconnect() end)
		mouseConn = nil
	end
	if activatedConn then
		pcall(function() activatedConn:Disconnect() end)
		activatedConn = nil
	end
	mouseRef = nil
end

-- Track ancestry changes to guard against template instances being parented in unusual locations
local function onAncestryChanged(child, parent)
	if not TOOL or not TOOL.Parent then
		-- tool removed or template moved; cleanup
		onUnequip()
	end
end

-- Initial attribute ensure on script load (useful when cloning template into Backpack at runtime)
ensureToolAttributes(TOOL)

-- Connect equip/unequip. For tools in ReplicatedStorage templates, Equipped will fire when the player equips the cloned tool.
TOOL.Equipped:Connect(function()
	-- attempt to get Mouse safely
	local ok, mouse = pcall(function() return localPlayer:GetMouse() end)
	onEquip(ok and mouse and mouse or nil)
end)
TOOL.Unequipped:Connect(onUnequip)
TOOL.AncestryChanged:Connect(onAncestryChanged)

-- If the tool is already parented to the player's character/backpack on script start, treat as equipped
local function seedIfAlreadyEquipped()
	local p = TOOL.Parent
	if p and (p:IsDescendantOf(localPlayer.Character) or p == localPlayer.Backpack) then
		local ok, mouse = pcall(function() return localPlayer:GetMouse() end)
		onEquip(ok and mouse and mouse or nil)
	end
end
task.defer(seedIfAlreadyEquipped)

-- Optional: quick debug print
if TOOL and TOOL.Name then
	print("[FoodToolClient] initialized for tool:", TOOL.Name)
end