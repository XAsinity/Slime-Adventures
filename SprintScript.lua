-- Sprint.client.lua
-- Simple Shift-to-sprint LocalScript.
-- Place in StarterPlayerScripts.
-- Hold LeftShift (or custom button on mobile) to increase WalkSpeed.
-- Releases / character respawn / humanoid replacement restore original speed.

---------------------------------------------------------------------
-- CONFIG
---------------------------------------------------------------------
local SPRINT_KEY             = Enum.KeyCode.LeftShift
local SPRINT_SPEED           = 26          -- Sprinting WalkSpeed
local AUTO_UPDATE_BASE       = true        -- Track external WalkSpeed changes
local MOBILE_BUTTON_ENABLED  = true        -- Show a sprint hold button on touch
local MOBILE_BUTTON_SIZE     = UDim2.fromOffset(90, 90)
local MOBILE_BUTTON_POSITION = UDim2.fromScale(0.85, 0.75)
local FADE_TIME              = 0.15        -- Tween time when entering/leaving sprint (0 = instant)

---------------------------------------------------------------------
-- SERVICES
---------------------------------------------------------------------
local Players        = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService     = game:GetService("RunService")
local TweenService   = game:GetService("TweenService")
local LocalPlayer    = Players.LocalPlayer

---------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------
local humanoid
local baseWalkSpeed = 16
local sprinting = false
local sprintInputDown = false
local mobileButton -- ImageButton
local lastExplicitBase = baseWalkSpeed

---------------------------------------------------------------------
-- UTIL
---------------------------------------------------------------------
local function getHumanoid()
	local character = LocalPlayer.Character
	if not character then return nil end
	return character:FindFirstChildOfClass("Humanoid")
end

local function setWalkSpeedSmooth(target)
	if not humanoid then return end
	if FADE_TIME <= 0 then
		humanoid.WalkSpeed = target
	else
		-- Tween WalkSpeed (Humanoid properties are tweenable)
		local tween = TweenService:Create(humanoid, TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {WalkSpeed = target})
		tween:Play()
	end
end

local function enterSprint()
	if not humanoid then return end
	if sprinting then return end
	sprinting = true
	setWalkSpeedSmooth(SPRINT_SPEED)
end

local function exitSprint()
	if not humanoid then return end
	if not sprinting then return end
	sprinting = false
	setWalkSpeedSmooth(baseWalkSpeed)
end

local function updateBaseFromHumanoid()
	if not humanoid then return end
	-- If not sprinting, treat any external change as new base
	if not sprinting then
		baseWalkSpeed = humanoid.WalkSpeed
	end
end

local function applySprintState()
	if sprintInputDown then
		enterSprint()
	else
		exitSprint()
	end
end

---------------------------------------------------------------------
-- INPUT HANDLERS
---------------------------------------------------------------------
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == SPRINT_KEY then
		sprintInputDown = true
		applySprintState()
	end
end)

UserInputService.InputEnded:Connect(function(input, gameProcessed)
	if input.KeyCode == SPRINT_KEY then
		sprintInputDown = false
		applySprintState()
	end
end)

---------------------------------------------------------------------
-- MOBILE BUTTON
---------------------------------------------------------------------
local function createMobileButton()
	if not MOBILE_BUTTON_ENABLED or not UserInputService.TouchEnabled then return end
	if mobileButton and mobileButton.Parent then return end

	local gui = LocalPlayer:WaitForChild("PlayerGui")
	local screen = Instance.new("ScreenGui")
	screen.Name = "SprintButtonGui"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.Parent = gui

	local btn = Instance.new("ImageButton")
	btn.Name = "SprintButton"
	btn.Size = MOBILE_BUTTON_SIZE
	btn.Position = MOBILE_BUTTON_POSITION
	btn.AnchorPoint = Vector2.new(0.5,0.5)
	btn.BackgroundTransparency = 0.25
	btn.BackgroundColor3 = Color3.fromRGB(50,50,50)
	btn.Image = "rbxassetid://155615604" -- placeholder lightning icon; replace as desired
	btn.ImageTransparency = 0.1
	btn.AutoButtonColor = true
	btn.Parent = screen

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 18)
	corner.Parent = btn

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(220,220,220)
	stroke.Parent = btn

	btn.MouseButton1Down:Connect(function()
		sprintInputDown = true
		applySprintState()
	end)
	btn.MouseButton1Up:Connect(function()
		sprintInputDown = false
		applySprintState()
	end)
	btn.MouseLeave:Connect(function()
		if UserInputService.TouchEnabled then
			-- On touch leaving the button, stop sprint
			sprintInputDown = false
			applySprintState()
		end
	end)

	mobileButton = btn
end

---------------------------------------------------------------------
-- CHARACTER / HUMANOID TRACKING
---------------------------------------------------------------------
local function bindHumanoid(h)
	humanoid = h
	if not humanoid then return end
	-- Capture baseline (prefer stored lastExplicitBase if we had one)
	baseWalkSpeed = humanoid.WalkSpeed
	lastExplicitBase = baseWalkSpeed

	if AUTO_UPDATE_BASE then
		humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
			if not humanoid then return end
			-- If sprinting, ignore internal sprint speed changes
			if sprinting then return end
			baseWalkSpeed = humanoid.WalkSpeed
			lastExplicitBase = baseWalkSpeed
		end)
	end

	-- State watchers: if humanoid dies, stop sprint
	humanoid.Died:Connect(function()
		sprintInputDown = false
		exitSprint()
	end)
end

local function onCharacterAdded(char)
	-- Slight delay to ensure Humanoid exists
	local h = char:WaitForChild("Humanoid", 5)
	bindHumanoid(h)
	createMobileButton()
end

if LocalPlayer.Character then
	onCharacterAdded(LocalPlayer.Character)
end
LocalPlayer.CharacterAdded:Connect(onCharacterAdded)

---------------------------------------------------------------------
-- Failsafe: if WalkSpeed gets forcibly changed while sprinting by another script,
-- reapply sprint speed each frame (only while key/button held).
---------------------------------------------------------------------
RunService.RenderStepped:Connect(function()
	if sprinting and humanoid and sprintInputDown then
		if humanoid.WalkSpeed < SPRINT_SPEED * 0.95 or humanoid.WalkSpeed > SPRINT_SPEED * 1.05 then
			-- Reassert sprint speed (another script interfered)
			humanoid.WalkSpeed = SPRINT_SPEED
		end
	elseif not sprinting and humanoid and not sprintInputDown then
		-- Ensure base speed is restored if tampered with
		if humanoid.WalkSpeed ~= baseWalkSpeed then
			humanoid.WalkSpeed = baseWalkSpeed
		end
	end
end)

---------------------------------------------------------------------
-- OPTIONAL: Public API exposure (other local scripts can require this script if converted to ModuleScript)
---------------------------------------------------------------------
-- (Convert to ModuleScript and return a table if needed)
-- For now this is a standalone LocalScript; no return value.