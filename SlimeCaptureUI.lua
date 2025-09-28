-- SlimeCaptureUI (v1.4 Feed Button Integration + robust remote handling)
-- Adds "Feed" button to slime click UI: feeds equipped food to slime, consumes item via server.
-- This version:
--  - Sends both the Tool instance and its ToolUniqueId (if present) to the server (covers either server expectation).
--  - Detects RemoteEvent vs RemoteFunction and calls FireServer or InvokeServer accordingly.
--  - Adds client-side diagnostics (prints) to help debug clicks not firing.
--  - Adds a safety timeout so BUSY won't get stuck if the server never responds via FeedResult.
--  - Keeps existing Pickup/Close logic unchanged.

local Players            = game:GetService("Players")
local UserInputService   = game:GetService("UserInputService")
local RunService         = game:GetService("RunService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")

local LP       = Players.LocalPlayer
local Remotes  = ReplicatedStorage:WaitForChild("Remotes")
local PickupRequest = Remotes:WaitForChild("SlimePickupRequest")
local PickupResult  = Remotes:WaitForChild("SlimePickupResult")
local FeedRemote    = Remotes:FindFirstChild("FeedSlime") -- may be nil if not present
local FeedResultEvt = Remotes:FindFirstChild("FeedResult") -- optional server feedback event

local CAMERA
local ACTIVE_SLIME
local UI
local BUSY = false

local SETTINGS = {
	SelectionInput              = Enum.UserInputType.MouseButton1,
	MaxSelectDistance           = 120,
	BillboardYOffset            = 4.5,
	BillboardSize               = Vector2.new(160, 108),
	Debug                       = false,

	IgnoreRetired               = true,
	IgnoreCapturing             = true,
	AutoAssignPrimaryPart       = true,
	ExcludeCharacterInRay       = true,
	ExcludeLocalToolsInRay      = true,
	SkipIfOverGui               = false,

	MaxAncestorDepth            = 30,
	RaycastDistance             = 500,

	FeedServerResponseTimeout   = 6, -- seconds before client gives up waiting for FeedResult (safety)
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
-- SAFE ATTRIBUTE HELPERS
----------------------------------------------------------------
local function safeGetAttribute(obj, name)
	if not obj or type(obj.GetAttribute) ~= "function" then return nil end
	local ok, v = pcall(function() return obj:GetAttribute(name) end)
	if ok then return v end
	return nil
end

local function safeSetAttribute(obj, name, value)
	if not obj or type(obj.SetAttribute) ~= "function" then return end
	pcall(function() obj:SetAttribute(name, value) end)
end

----------------------------------------------------------------
-- CAMERA
----------------------------------------------------------------
local function ensureCamera()
	CAMERA = workspace.CurrentCamera
	if not CAMERA then
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
	local feedBtn   = makeButton("Feed", "FeedButton", 2)
	local closeBtn  = makeButton("Close",  "CloseButton", 3)

	-- FEED BUTTON logic (robust + diagnostics)
	feedBtn.MouseButton1Click:Connect(function()
		if BUSY then
			dprint("Ignored feed click: BUSY")
			return
		end
		if not ACTIVE_SLIME or not ACTIVE_SLIME.Parent then
			dprint("Ignored feed click: no active slime")
			return
		end

		-- Find equipped food tool
		local tool = nil
		if LP.Character then
			for _,child in ipairs(LP.Character:GetChildren()) do
				if child:IsA("Tool") and (safeGetAttribute(child, "FoodItem") or safeGetAttribute(child, "FoodId")) then
					tool = child
					break
				end
			end
		end

		if not tool then
			dprint("Feed click: no food tool equipped")
			local msgLabel = UI and UI:FindFirstChild("Container") and UI.Container:FindFirstChild("MsgLabel")
			if msgLabel then
				msgLabel.Text = "Equip a food item to feed!"
				msgLabel.Visible = true
			end
			return
		end

		-- Ensure FeedRemote exists
		if not FeedRemote then
			dprint("FeedRemote not found in ReplicatedStorage.Remotes")
			local msgLabel = UI and UI:FindFirstChild("Container") and UI.Container:FindFirstChild("MsgLabel")
			if msgLabel then
				msgLabel.Text = "Feed action unavailable"
				msgLabel.Visible = true
			end
			return
		end

		-- Diagnostics
		local uid = safeGetAttribute(tool, "ToolUniqueId") or safeGetAttribute(tool, "ToolUid")
		dprint("Firing feed:", "FeedRemoteClass=", FeedRemote.ClassName, "ACTIVE_SLIME=", tostring(ACTIVE_SLIME), "tool=", tostring(tool), "toolUid=", tostring(uid))

		-- Fire or invoke depending on remote type
		BUSY = true
		local responded = false

		-- Safety watchdog: clear BUSY after timeout if server doesn't respond
		local timeoutTask = task.delay(SETTINGS.FeedServerResponseTimeout, function()
			if BUSY and not responded then
				dprint("Feed timeout expired; clearing BUSY")
				BUSY = false
				local msgLabel = UI and UI:FindFirstChild("Container") and UI.Container:FindFirstChild("MsgLabel")
				if msgLabel then
					msgLabel.Text = "No response from server"
					msgLabel.Visible = true
				end
			end
		end)

		if FeedRemote.ClassName == "RemoteFunction" then
			-- synchronous invoke, handle response if any
			local ok, res = pcall(function()
				-- pass both instance and uid (uid may be nil)
				return FeedRemote:InvokeServer(ACTIVE_SLIME, tool, uid)
			end)
			responded = true
			BUSY = false
			if not ok then
				dprint("Feed InvokeServer error:", tostring(res))
				local msgLabel = UI and UI:FindFirstChild("Container") and UI.Container:FindFirstChild("MsgLabel")
				if msgLabel then
					msgLabel.Text = "Feed failed (server error)"
					msgLabel.Visible = true
				end
			else
				-- If server returned a table { success = bool, message = str } handle it
				if type(res) == "table" and res.success ~= nil then
					if res.success then
						if UI then UI.Enabled = false end
						ACTIVE_SLIME = nil
					else
						local msgLabel = UI and UI:FindFirstChild("Container") and UI.Container:FindFirstChild("MsgLabel")
						if msgLabel then
							msgLabel.Text = "Error: " .. tostring(res.message or "unknown")
							msgLabel.Visible = true
						end
					end
				else
					-- No structured response: assume success and close UI
					if UI then UI.Enabled = false end
					ACTIVE_SLIME = nil
				end
			end
		else
			-- RemoteEvent path: FireServer and expect server to reply via FeedResult (optional).
			-- We send both the tool instance and uid (if present).
			local successFire, err = pcall(function()
				FeedRemote:FireServer(ACTIVE_SLIME, tool, uid)
			end)
			if not successFire then
				dprint("Feed FireServer failed:", tostring(err))
				BUSY = false
				responded = true
				local msgLabel = UI and UI:FindFirstChild("Container") and UI.Container:FindFirstChild("MsgLabel")
				if msgLabel then
					msgLabel.Text = "Feed failed (client send)"
					msgLabel.Visible = true
				end
			else
				-- Wait for FeedResult event to clear BUSY; FeedResult handler below does that.
				-- If FeedResult isn't present on the server, the timeoutTask above will clear BUSY after timeout.
				dprint("Feed event fired; awaiting FeedResult (if any)")
			end
		end

		-- ensure timeoutTask won't leak reference if responded quickly
		if responded and timeoutTask then
			-- no-op; the delayed task will still run but checks BUSY/responded
		end
	end)

	-- Pickup button (unchanged)
	pickupBtn.MouseButton1Click:Connect(function()
		if BUSY then return end
		if not ACTIVE_SLIME or not ACTIVE_SLIME.Parent then
			return
		end
		BUSY = true
		messageLabel.Visible = false
		PickupRequest:FireServer(ACTIVE_SLIME)
	end)

	-- Close button (unchanged)
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

	-- Update feedBtn enabled state based on equipped food
	local frame = ui:FindFirstChild("Container")
	local feedBtn = frame and frame:FindFirstChild("FeedButton")
	if feedBtn then
		local tool = nil
		if LP.Character then
			for _,child in ipairs(LP.Character:GetChildren()) do
				if child:IsA("Tool") and (safeGetAttribute(child, "FoodItem") or safeGetAttribute(child, "FoodId")) then
					tool = child
					break
				end
			end
		end
		feedBtn.Active = (tool ~= nil)
		feedBtn.TextTransparency = (tool ~= nil) and 0 or 0.6
		feedBtn.BackgroundColor3 = (tool ~= nil) and Color3.fromRGB(60,60,60) or Color3.fromRGB(40,40,40)
	end

	dprint(("UI shown on slime %s (part %s)"):format(slime:GetAttribute("SlimeId") or "<unknown>", prim.Name))
end

local function showUI(slime)
	if ACTIVE_SLIME and ACTIVE_SLIME ~= slime then
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
	if UserInputService:GetFocusedTextBox() then return true end
	return false
end

----------------------------------------------------------------
-- REMOTE RESULT HANDLERS
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

if FeedResultEvt then
	FeedResultEvt.OnClientEvent:Connect(function(result)
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
end

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