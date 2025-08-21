-- SlimeCaptureUI (v1.2 robust-ray)
-- Click a slime -> show pickup billboard with Pickup / Close buttons.
-- Improvements:
--   * Robust raycast with exclusion filters.
--   * Descendant base part discovery (not just direct PrimaryPart).
--   * Optional auto-assign PrimaryPart if missing.
--   * Skip retired/capturing slimes (configurable).
--   * Detailed debug instrumentation.
--   * Re-selection when UI already open on a different slime.
--   * Optional screen-gui overlap check to avoid UI clicks misfiring.
--   * Safe fallback if camera not ready on first frame.

local Players            = game:GetService("Players")
local UserInputService   = game:GetService("UserInputService")
local RunService         = game:GetService("RunService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local StarterGui         = game:GetService("StarterGui")

local LP       = Players.LocalPlayer
local Remotes  = ReplicatedStorage:WaitForChild("Remotes")
local PickupRequest = Remotes:WaitForChild("SlimePickupRequest")
local PickupResult  = Remotes:WaitForChild("SlimePickupResult")

local CAMERA
local ACTIVE_SLIME
local UI
local BUSY = false

local SETTINGS = {
	SelectionInput              = Enum.UserInputType.MouseButton1,
	MaxSelectDistance           = 120,
	BillboardYOffset            = 4.5,
	BillboardSize               = Vector2.new(160, 80),
	Debug                       = false,

	IgnoreRetired               = true,
	IgnoreCapturing             = true,
	AutoAssignPrimaryPart       = true,
	ExcludeCharacterInRay       = true,
	ExcludeLocalToolsInRay      = true,
	SkipIfOverGui               = false, -- set true if you have clickable GUI overlays

	MaxAncestorDepth            = 30,
	RaycastDistance             = 500,

	-- Accept parts even if transparent > this threshold
	TransparencyRejectThreshold = 0.995,
}

----------------------------------------------------------------
-- DEBUG
----------------------------------------------------------------
local function dprint(...)
	if SETTINGS.Debug then
		print("[SlimeCaptureUI]", ...)
	end
end

----------------------------------------------------------------
-- CAMERA
----------------------------------------------------------------
local function ensureCamera()
	CAMERA = workspace.CurrentCamera
	if not CAMERA then
		-- Yield a frame
		RunService.RenderStepped:Wait()
		CAMERA = workspace.CurrentCamera
	end
	return CAMERA
end

----------------------------------------------------------------
-- SLIME MODEL HELPERS
----------------------------------------------------------------
local function findSlimeModelFromInstance(inst)
	local depth = 0
	while inst and depth < SETTINGS.MaxAncestorDepth do
		if inst:IsA("Model") and inst.Name == "Slime" then
			return inst
		end
		inst = inst.Parent
		depth += 1
	end
	return nil
end

local function getAnyBasePart(slime)
	if not slime or not slime:IsA("Model") then return nil end
	for _,desc in ipairs(slime:GetDescendants()) do
		if desc:IsA("BasePart") then
			return desc
		end
	end
	return nil
end

local function slimeIsEligible(slime)
	if not slime or not slime.Parent then return false, "NoParent" end
	if slime.Name ~= "Slime" then return false, "NotSlime" end
	if SETTINGS.IgnoreRetired and slime:GetAttribute("Retired") then return false, "Retired" end
	if SETTINGS.IgnoreCapturing and slime:GetAttribute("Capturing") then return false, "Capturing" end
	return true
end

----------------------------------------------------------------
-- UI CREATION
----------------------------------------------------------------
local function ensureUI()
	if UI then return UI end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "SlimePickupBillboard"
	billboard.Size = UDim2.fromOffset(SETTINGS.BillboardSize.X, SETTINGS.BillboardSize.Y)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.StudsOffset = Vector3.new(0, SETTINGS.BillboardYOffset, 0)
	billboard.Enabled = false
	billboard.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	billboard.Active = true
	billboard.MaxDistance = 300
	billboard.Parent = LP:WaitForChild("PlayerGui")

	local frame = Instance.new("Frame")
	frame.Name = "Container"
	frame.Size = UDim2.fromScale(1,1)
	frame.BackgroundColor3 = Color3.fromRGB(25,25,25)
	frame.BackgroundTransparency = 0.25
	frame.BorderSizePixel = 0
	frame.ZIndex = 1
	frame.Parent = billboard
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0,8)
	corner.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0,6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = frame

	local function makeButton(text, name, order)
		local btn = Instance.new("TextButton")
		btn.Name = name
		btn.Size = UDim2.new(1,-20,0,28)
		btn.BackgroundColor3 = Color3.fromRGB(60,60,60)
		btn.TextColor3 = Color3.new(1,1,1)
		btn.Font = Enum.Font.GothamBold
		btn.TextSize = 14
		btn.Text = text
		btn.AutoButtonColor = true
		btn.ZIndex = 2
		btn.LayoutOrder = order
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0,6)
		c.Parent = btn
		btn.Parent = frame
		return btn
	end

	local messageLabel = Instance.new("TextLabel")
	messageLabel.Name = "MsgLabel"
	messageLabel.Size = UDim2.new(1,-20,0,16)
	messageLabel.BackgroundTransparency = 1
	messageLabel.Text = ""
	messageLabel.TextColor3 = Color3.fromRGB(255,180,180)
	messageLabel.Font = Enum.Font.Gotham
	messageLabel.TextSize = 12
	messageLabel.ZIndex = 2
	messageLabel.Visible = false
	messageLabel.LayoutOrder = 0
	messageLabel.Parent = frame

	local pickupBtn = makeButton("Pickup", "PickupButton", 1)
	local closeBtn  = makeButton("Close",  "CloseButton", 2)

	pickupBtn.MouseButton1Click:Connect(function()
		if BUSY then return end
		if not ACTIVE_SLIME or not ACTIVE_SLIME.Parent then
			return
		end
		BUSY = true
		messageLabel.Visible = false
		PickupRequest:FireServer(ACTIVE_SLIME)
	end)

	closeBtn.MouseButton1Click:Connect(function()
		billboard.Enabled = false
		ACTIVE_SLIME = nil
		BUSY = false
		local hover = LP.PlayerGui:FindFirstChild("HoverSlimeBillboard")
		if hover then
			hover.Enabled = false
			hover.Adornee = nil
		end
	end)

	UI = billboard
	return billboard
end

----------------------------------------------------------------
-- DISPLAY / SELECTION
----------------------------------------------------------------
local function setBillboard(slime)
	local ui = ensureUI()
	local eligible, reason = slimeIsEligible(slime)
	if not eligible then
		dprint("Slime ineligible: ".. tostring(reason))
		return
	end

	local prim = slime.PrimaryPart
	if not prim then
		prim = getAnyBasePart(slime)
		if prim and SETTINGS.AutoAssignPrimaryPart then
			pcall(function() slime.PrimaryPart = prim end)
		end
	end
	if not prim then
		dprint("No base part for slime; cannot attach UI")
		return
	end

	ui.Adornee = prim
	ui.Enabled = true
	ACTIVE_SLIME = slime
	BUSY = false
	dprint(("UI shown on slime %s (part %s)"):format(slime:GetAttribute("SlimeId") or slime:GetDebugId(), prim.Name))
end

local function showUI(slime)
	if ACTIVE_SLIME and ACTIVE_SLIME ~= slime then
		-- Switch target
		dprint("Switching selection to new slime.")
	end
	setBillboard(slime)
end

----------------------------------------------------------------
-- RAYCAST
----------------------------------------------------------------
local function buildRaycastParams()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude = {}

	if SETTINGS.ExcludeCharacterInRay then
		local char = LP.Character
		if char then table.insert(exclude, char) end
	end
	if SETTINGS.ExcludeLocalToolsInRay then
		local backpack = LP:FindFirstChildOfClass("Backpack")
		if backpack then table.insert(exclude, backpack) end
	end
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = true
	return params
end

local function performRaycast()
	local cam = ensureCamera()
	if not cam then return nil end
	local loc = UserInputService:GetMouseLocation()
	local rayOrigin = cam:ViewportPointToRay(loc.X, loc.Y).Origin
	local rayDir    = cam:ViewportPointToRay(loc.X, loc.Y).Direction * SETTINGS.RaycastDistance
	local result = workspace:Raycast(rayOrigin, rayDir, buildRaycastParams())
	return result and result.Instance or nil
end

----------------------------------------------------------------
-- GUI OVERLAP (optional)
----------------------------------------------------------------
local function isPointerOverGui()
	if not SETTINGS.SkipIfOverGui then return false end
	-- Simple heuristic: Test UserInputService:GetFocusedTextBox() or later add GuiService:GetGuiInset
	if UserInputService:GetFocusedTextBox() then return true end
	-- Could expand to ScreenGui hit test if needed.
	return false
end

----------------------------------------------------------------
-- REMOTE RESULT
----------------------------------------------------------------
PickupResult.OnClientEvent:Connect(function(result)
	BUSY = false
	if not result then return end
	local ui = UI
	if result.success then
		if ui then ui.Enabled = false end
		ACTIVE_SLIME = nil
	else
		if ui and ui.Enabled then
			local frame = ui:FindFirstChild("Container")
			if frame then
				local msgLabel = frame:FindFirstChild("MsgLabel")
				if msgLabel then
					msgLabel.Text = "Error: " .. tostring(result.message)
					msgLabel.Visible = true
				end
			end
		end
	end
end)

----------------------------------------------------------------
-- INPUT HANDLER
----------------------------------------------------------------
UserInputService.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.UserInputType ~= SETTINGS.SelectionInput then return end
	if UI and UI.Enabled and BUSY then
		dprint("Ignoring click; busy.")
		return
	end
	if isPointerOverGui() then
		dprint("Pointer over GUI; selection suppressed.")
		return
	end

	local inst = performRaycast()
	if not inst then
		dprint("Raycast miss.")
		return
	end
	local slime = findSlimeModelFromInstance(inst)
	if not slime then
		dprint("Hit instance "..inst:GetFullName().." but no slime ancestor.")
		return
	end

	-- Distance check
	local char = LP.Character
	if not char then return end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	local prim = slime.PrimaryPart or getAnyBasePart(slime)
	if not prim then
		dprint("Slime has no part for distance check.")
		return
	end
	local dist = (prim.Position - hrp.Position).Magnitude
	if dist > SETTINGS.MaxSelectDistance then
		dprint(("Too far (%.1f > %.1f)"):format(dist, SETTINGS.MaxSelectDistance))
		return
	end

	showUI(slime)
end)

----------------------------------------------------------------
-- CLEANUP IF SLIME VANISHES
----------------------------------------------------------------
RunService.RenderStepped:Connect(function()
	if ACTIVE_SLIME and not ACTIVE_SLIME.Parent then
		if UI then UI.Enabled = false end
		ACTIVE_SLIME = nil
		BUSY = false
	end
end)

return true