-- EggHatchUI.client.lua (generic title variant)
-- Changes:
--   * Title no longer displays rarity (always "Egg").
--   * Rarity still fetched & can be used for coloring progress bar optional.
--   * Added flag SHOW_RARITY_IN_TITLE if you later want to re-enable showing it.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local HatchRemote = Remotes:FindFirstChild("HatchEggRequest")

local SHOW_RARITY_IN_TITLE = false -- set true to revert old behavior

local RARITY_COLORS = {
	Common     = Color3.fromRGB(200,200,200),
	Rare       = Color3.fromRGB(120,180,255),
	Epic       = Color3.fromRGB(180,120,255),
	Legendary  = Color3.fromRGB(255,200,60),
}

-- UI ----------------------------------------------------------------
local screen = Instance.new("ScreenGui")
screen.Name = "EggHatchUI"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = false
screen.Parent = LocalPlayer:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Name = "Panel"
frame.AnchorPoint = Vector2.new(0.5,1)
frame.Position = UDim2.new(0.5,0,1,-40)
frame.Size = UDim2.new(0,320,0,170)
frame.BackgroundColor3 = Color3.fromRGB(30,32,40)
frame.BorderSizePixel = 0
frame.Visible = false
frame.Parent = screen
local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0,12); corner.Parent = frame

local title = Instance.new("TextLabel")
title.Name = "Title"
title.BackgroundTransparency = 1
title.Position = UDim2.new(0,16,0,10)
title.Size = UDim2.new(1,-32,0,28)
title.Font = Enum.Font.GothamBold
title.TextSize = 22
title.TextColor3 = Color3.fromRGB(235,235,255)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "Egg"
title.Parent = frame

local closeBtn = Instance.new("TextButton")
closeBtn.Name = "Close"
closeBtn.AnchorPoint = Vector2.new(1,0)
closeBtn.Position = UDim2.new(1,-12,0,12)
closeBtn.Size = UDim2.new(0,28,0,28)
closeBtn.BackgroundColor3 = Color3.fromRGB(55,55,70)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.Text = "X"
closeBtn.TextSize = 16
closeBtn.TextColor3 = Color3.new(1,1,1)
closeBtn.Parent = frame
local cbCorner = Instance.new("UICorner"); cbCorner.CornerRadius = UDim.new(1,0); cbCorner.Parent = closeBtn

local timeLabel = Instance.new("TextLabel")
timeLabel.Name = "Time"
timeLabel.BackgroundTransparency = 1
timeLabel.Position = UDim2.new(0,16,0,50)
timeLabel.Size = UDim2.new(1,-32,0,24)
timeLabel.Font = Enum.Font.GothamSemibold
timeLabel.TextSize = 18
timeLabel.TextColor3 = Color3.fromRGB(210,220,255)
timeLabel.TextXAlignment = Enum.TextXAlignment.Left
timeLabel.Text = "Time: --:--"
timeLabel.Parent = frame

local progressBG = Instance.new("Frame")
progressBG.Name = "ProgressBG"
progressBG.Position = UDim2.new(0,16,0,80)
progressBG.Size = UDim2.new(1,-32,0,20)
progressBG.BackgroundColor3 = Color3.fromRGB(50,55,70)
progressBG.BorderSizePixel = 0
progressBG.Parent = frame
local pbCorner = Instance.new("UICorner"); pbCorner.CornerRadius = UDim.new(0,8); pbCorner.Parent = progressBG

local progressFill = Instance.new("Frame")
progressFill.Name = "Fill"
progressFill.BackgroundColor3 = Color3.fromRGB(90,170,255)
progressFill.BorderSizePixel = 0
progressFill.Size = UDim2.new(0,0,1,0)
progressFill.Parent = progressBG
local pfCorner = Instance.new("UICorner"); pfCorner.CornerRadius = UDim.new(0,8); pfCorner.Parent = progressFill

local hatchBtn = Instance.new("TextButton")
hatchBtn.Name = "HatchButton"
hatchBtn.Position = UDim2.new(0,16,0,110)
hatchBtn.Size = UDim2.new(0,140,0,40)
hatchBtn.BackgroundColor3 = Color3.fromRGB(90,90,90)
hatchBtn.Font = Enum.Font.GothamBold
hatchBtn.TextSize = 20
hatchBtn.TextColor3 = Color3.new(1,1,1)
hatchBtn.Text = "Wait"
hatchBtn.AutoButtonColor = false
hatchBtn.Parent = frame
local hbCorner = Instance.new("UICorner"); hbCorner.CornerRadius = UDim.new(0,10); hbCorner.Parent = hatchBtn

local msgLabel = Instance.new("TextLabel")
msgLabel.Name = "Message"
msgLabel.BackgroundTransparency = 1
msgLabel.Position = UDim2.new(1,-150,0,115)
msgLabel.Size = UDim2.new(0,130,0,30)
msgLabel.Font = Enum.Font.GothamSemibold
msgLabel.TextSize = 14
msgLabel.TextWrapped = true
msgLabel.TextXAlignment = Enum.TextXAlignment.Left
msgLabel.TextColor3 = Color3.fromRGB(255,200,120)
msgLabel.Text = ""
msgLabel.Parent = frame

-- STATE
local selectedEgg : Model? = nil
local hatchDebounce = false
local lastClickTime = 0
local multiList = {}
local multiIndex = 1

-- UTIL
local function fmtTime(sec)
	if sec < 0 then sec = 0 end
	local m = math.floor(sec/60)
	local s = math.floor(sec%60)
	return string.format("%02d:%02d", m, s)
end

local function isOwnedEgg(inst)
	if not inst or not inst:IsA("Model") then return false end
	if not inst:GetAttribute("ManualHatch") then return false end
	if inst:GetAttribute("OwnerUserId") ~= LocalPlayer.UserId then return false end
	if not inst:GetAttribute("HatchAt") then return false end
	return true
end

local function collectNearbyOwnedEggs(origin, radius)
	local eggs = {}
	for _,desc in ipairs(workspace:GetDescendants()) do
		if desc:IsA("Model") and desc:GetAttribute("ManualHatch") and desc:GetAttribute("OwnerUserId")==LocalPlayer.UserId then
			local p = desc.PrimaryPart or desc:FindFirstChildWhichIsA("BasePart")
			if p then
				if (p.Position - origin).Magnitude <= radius then
					table.insert(eggs, desc)
				end
			end
		end
	end
	return eggs
end

-- UI Updates
local function updateUI()
	if not selectedEgg or not selectedEgg.Parent then
		frame.Visible = false
		selectedEgg = nil
		return
	end
	local hatchAt = selectedEgg:GetAttribute("HatchAt")
	if type(hatchAt) ~= "number" then
		timeLabel.Text = "Time: --:--"
		hatchBtn.Text = "Err"
		hatchBtn.BackgroundColor3 = Color3.fromRGB(120,50,50)
		hatchBtn.Active = false
		return
	end
	local now = os.time()
	local remaining = hatchAt - now
	local total = selectedEgg:GetAttribute("HatchTime") or 0
	if total <= 0 then total = 1 end
	local elapsed = total - math.max(0, remaining)
	local pct = math.clamp(elapsed / total, 0, 1)

	timeLabel.Text = remaining > 0 and ("Time: "..fmtTime(remaining)) or "Ready!"
	progressFill.Size = UDim2.new(pct, 0, 1, 0)

	if remaining <= 0 then
		hatchBtn.Text = "Hatch"
		hatchBtn.BackgroundColor3 = Color3.fromRGB(70,150,90)
		hatchBtn.Active = true
	else
		hatchBtn.Text = "Wait"
		hatchBtn.BackgroundColor3 = Color3.fromRGB(90,90,90)
		hatchBtn.Active = false
	end
end

local function setSelected(egg)
	selectedEgg = egg
	if not egg then
		frame.Visible = false
		return
	end
	local rarity = egg:GetAttribute("Rarity") or "Common"
	local color = RARITY_COLORS[rarity] or Color3.fromRGB(235,235,255)

	-- ALWAYS generic title; optionally color the text if you still want rarity feedback visually
	title.Text = SHOW_RARITY_IN_TITLE and ("Egg ("..tostring(rarity)..")") or "Egg"
	title.TextColor3 = color

	msgLabel.Text = ""
	frame.Visible = true
	updateUI()
end

-- Interaction
local function handleClick()
	local mouse = LocalPlayer:GetMouse()
	local target = mouse.Target
	if not target then
		setSelected(nil)
		return
	end
	local egg = target:FindFirstAncestorOfClass("Model")
	if egg and isOwnedEgg(egg) then
		local now = tick()
		if now - lastClickTime < 0.3 then
			if selectedEgg == egg then
				multiList = collectNearbyOwnedEggs(egg.PrimaryPart and egg.PrimaryPart.Position or egg:GetPivot().Position, 40)
				table.sort(multiList, function(a,b)
					local ha = a:GetAttribute("HatchAt") or 0
					local hb = b:GetAttribute("HatchAt") or 0
					return ha < hb
				end)
				if #multiList > 1 then
					multiIndex = (multiIndex % #multiList) + 1
					setSelected(multiList[multiIndex])
				else
					setSelected(egg)
				end
			else
				setSelected(egg)
			end
		else
			multiList = { egg }
			multiIndex = 1
			setSelected(egg)
		end
		lastClickTime = now
	else
		setSelected(nil)
	end
end

UserInputService.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		handleClick()
	elseif input.KeyCode == Enum.KeyCode.Escape then
		setSelected(nil)
	elseif input.KeyCode == Enum.KeyCode.Tab and frame.Visible and #multiList > 1 then
		multiIndex = (multiIndex % #multiList) + 1
		setSelected(multiList[multiIndex])
	end
end)

UserInputService.InputBegan:Connect(function(input,gpe)
	if gpe then return end
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		if frame.Visible then
			setSelected(nil)
		end
	end
end)

closeBtn.MouseButton1Click:Connect(function()
	setSelected(nil)
end)

hatchBtn.MouseButton1Click:Connect(function()
	if hatchDebounce then return end
	if not selectedEgg then return end
	local remaining = (selectedEgg:GetAttribute("HatchAt") or os.time()) - os.time()
	if remaining > 0 then
		msgLabel.Text = "Not ready."
		return
	end
	if not HatchRemote then
		msgLabel.Text = "Missing hatch remote."
		return
	end
	hatchDebounce = true
	HatchRemote:FireServer(selectedEgg)
	msgLabel.Text = "Hatching..."
	hatchBtn.Active = false
	task.delay(2, function() hatchDebounce = false end)
end)

RunService.Heartbeat:Connect(function()
	if frame.Visible then
		if not selectedEgg or not selectedEgg.Parent then
			setSelected(nil)
		else
			updateUI()
		end
	end
end)

workspace.DescendantRemoving:Connect(function(inst)
	if inst == selectedEgg then
		setSelected(nil)
	end
end)