-- SlimeHoverGrowthUI.client.lua
-- Safe version: no GetDebugId, robust detach on slime pickup, ancestry, or timeout.

local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local UserInputService   = game:GetService("UserInputService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local Camera             = workspace.CurrentCamera
local LP                 = Players.LocalPlayer

local THEME = {
	PercentColorLow     = Color3.fromRGB(255, 90, 200),
	PercentColorMid     = Color3.fromRGB(255, 170, 230),
	PercentColorHigh    = Color3.fromRGB(255, 255, 255),
	FontName            = "Comic Neue Angular",
	FontWeight          = Enum.FontWeight.Bold,
	FontStyle           = Enum.FontStyle.Normal,
	TextColor           = Color3.fromRGB(255,255,255),
	TextTransparency    = 0,
	RichText            = true,
	UseStroke           = true,
	StrokeColor         = Color3.fromRGB(0,0,0),
	StrokeThickness     = 2,
	StrokeTransparency  = 0.2,
	UseShadow           = true,
	ShadowOffset        = Vector2.new(2,2),
	ShadowColor         = Color3.fromRGB(0,0,0),
	ShadowTransparency  = 0.65,
	InfoFontWeight      = Enum.FontWeight.Medium,
	InfoFontStyle       = Enum.FontStyle.Normal,
	InfoTextColor       = Color3.fromRGB(230,230,230),
	InfoTextTransparency= 0,
	BarBackgroundColor  = Color3.fromRGB(50,50,50),
	BarBackgroundTransparency = 0.55,
	BarFillColorLeft    = Color3.fromRGB(255,120,215),
	BarFillColorRight   = Color3.fromRGB(255,255,255),
	BarCornerRadiusPx   = 4,
	BarHeightPx         = 6,
	BillboardWidthPx    = 200,
	BillboardHeightPx   = 70,
	BillboardAlwaysOnTop= true,
}

local FEATURES = {
	ShowPrefix            = true,
	PrefixText            = "Growth: ",
	ShowPercentSign       = true,
	ColorizeNumberOnly    = true,
	ShowDecimals          = false,
	RoundNearest          = true,
	UsePercentGradient    = true,
	GradientMidpoint      = 0.5,
	ShowValue             = true,
	ShowProgressBar       = true,

	EnableHunger          = true,
	EnableStage           = true,
	FedAttributeName      = "FedFraction",
	StageAttributeName    = "MutationStage",
	ValueAttributeName    = "CurrentValue",

	HungerDisplayMode     = "Fullness",
	FullnessLabel         = "Fullness: ",
	StarvationLabel       = "Hunger: ",

	UseHungerGradient     = true,
	HungerMidpoint        = 0.5,

	ToggleKey             = Enum.KeyCode.T,
	HoldStageKey          = Enum.KeyCode.LeftAlt,

	SmoothOffset          = true,
	OffsetLerpAlpha       = 0.18,
	ExtraY                = 1.5,
	HoverLoseGrace        = 0.18,
	UpdateHz              = 15,
	MaxRayDistance        = 500,
	MaxViewDistance       = 450,

	Debug                 = false,
}

local FullnessStaticColor = Color3.fromRGB(255, 180, 230)
local STAGE_COLOR         = Color3.fromRGB(255, 255, 255)
local VALUE_COLOR         = Color3.fromRGB(230, 230, 230)
local HUNGER_GRADIENT = {
	FullColor = Color3.fromRGB( 80, 255, 120),
	MidColor  = Color3.fromRGB(255, 220,  90),
	EmptyColor= Color3.fromRGB(255,  70,  70),
}

local function dprint(...) if FEATURES.Debug then print("[HoverGrowthUI]", ...) end end

local function safeDebugId(model)
	if not model then return "nil" end
	local ok, full = pcall(model.GetFullName, model)
	if ok then return full end
	return tostring(model)
end

-- UI ------------------------------------------------------------------------
local billboard = Instance.new("BillboardGui")
billboard.Name = "HoverSlimeBillboard"
billboard.AlwaysOnTop = THEME.BillboardAlwaysOnTop
billboard.Size = UDim2.new(0, THEME.BillboardWidthPx, 0, THEME.BillboardHeightPx)
billboard.LightInfluence = 0
billboard.Enabled = false
billboard.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
billboard.Parent = LP:WaitForChild("PlayerGui")

local rootFrame = Instance.new("Frame")
rootFrame.BackgroundTransparency = 1
rootFrame.Size = UDim2.fromScale(1,1)
rootFrame.Parent = billboard

local mainLabel = Instance.new("TextLabel")
mainLabel.Name = "PercentLabel"
mainLabel.BackgroundTransparency = 1
mainLabel.Size = UDim2.new(1,0,0,36)
mainLabel.TextScaled = true
mainLabel.TextWrapped = true
mainLabel.RichText = THEME.RichText
mainLabel.TextColor3 = THEME.TextColor
mainLabel.Parent = rootFrame

if THEME.UseStroke then
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = THEME.StrokeThickness
	stroke.Color = THEME.StrokeColor
	stroke.Transparency = THEME.StrokeTransparency
	stroke.Parent = mainLabel
end

local shadowLabel
if THEME.UseShadow then
	shadowLabel = mainLabel:Clone()
	shadowLabel.Name = "Shadow"
	local sStroke = shadowLabel:FindFirstChildOfClass("UIStroke")
	if sStroke then sStroke:Destroy() end
	shadowLabel.TextColor3 = THEME.ShadowColor
	shadowLabel.TextTransparency = THEME.ShadowTransparency
	shadowLabel.Position = UDim2.new(0, THEME.ShadowOffset.X, 0, THEME.ShadowOffset.Y)
	shadowLabel.ZIndex = mainLabel.ZIndex - 1
	shadowLabel.Parent = rootFrame
end

local infoLabel = Instance.new("TextLabel")
infoLabel.Name = "InfoLabel"
infoLabel.BackgroundTransparency = 1
infoLabel.Size = UDim2.new(1,0,0,18)
infoLabel.Position = UDim2.new(0,0,0,36)
infoLabel.TextScaled = true
infoLabel.TextWrapped = true
infoLabel.RichText = true
infoLabel.TextColor3 = THEME.InfoTextColor
infoLabel.Parent = rootFrame

local barContainer, barFill
if FEATURES.ShowProgressBar then
	barContainer = Instance.new("Frame")
	barContainer.Name = "BarContainer"
	barContainer.AnchorPoint = Vector2.new(0,1)
	barContainer.Size = UDim2.new(1,-10,0,THEME.BarHeightPx)
	barContainer.Position = UDim2.new(0,5,1,-4)
	barContainer.BackgroundColor3 = THEME.BarBackgroundColor
	barContainer.BackgroundTransparency = THEME.BarBackgroundTransparency
	barContainer.BorderSizePixel = 0
	barContainer.Parent = rootFrame
	if THEME.BarCornerRadiusPx > 0 then
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0,THEME.BarCornerRadiusPx)
		c.Parent = barContainer
	end
	barFill = Instance.new("Frame")
	barFill.Name = "BarFill"
	barFill.Size = UDim2.new(0,0,1,0)
	barFill.BackgroundColor3 = THEME.BarFillColorLeft
	barFill.BorderSizePixel = 0
	barFill.Parent = barContainer
	if THEME.BarCornerRadiusPx > 0 then
		local fc = Instance.new("UICorner")
		fc.CornerRadius = UDim.new(0,THEME.BarCornerRadiusPx)
		fc.Parent = barFill
	end
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new{
		ColorSequenceKeypoint.new(0, THEME.BarFillColorLeft),
		ColorSequenceKeypoint.new(1, THEME.BarFillColorRight)
	}
	grad.Parent = barFill
end

local okMain, fontMain = pcall(function()
	return Font.new(THEME.FontName, THEME.FontWeight, THEME.FontStyle)
end)
if okMain and fontMain then
	mainLabel.FontFace = fontMain
	if shadowLabel then shadowLabel.FontFace = fontMain end
else
	mainLabel.Font = Enum.Font.GothamBold
	if shadowLabel then shadowLabel.Font = Enum.Font.GothamBold end
end

local okInfo, fontInfo = pcall(function()
	return Font.new(THEME.FontName, THEME.InfoFontWeight, THEME.InfoFontStyle)
end)
if okInfo and fontInfo then
	infoLabel.FontFace = fontInfo
else
	infoLabel.Font = Enum.Font.Gotham
end

-- Helpers -------------------------------------------------------------------
local function clamp01(x) if x < 0 then return 0 elseif x > 1 then return 1 else return x end end

local function gradientColor(p)
	local mid = FEATURES.GradientMidpoint
	if p <= mid then
		local t = mid == 0 and 0 or (p / mid)
		return THEME.PercentColorLow:Lerp(THEME.PercentColorMid, t)
	else
		local t = (p - mid) / (1 - mid)
		return THEME.PercentColorMid:Lerp(THEME.PercentColorHigh, t)
	end
end

local function formatNumber(p)
	local value = p * 100
	if FEATURES.ShowDecimals then
		if FEATURES.RoundNearest then
			value = math.floor(value*10+0.5)/10
		else
			value = math.floor(value*10)/10
		end
	else
		if FEATURES.RoundNearest then
			value = math.floor(value + 0.5)
		else
			value = math.floor(value)
		end
	end
	if value > 100 then value = 100 end
	return value
end

local function buildGrowthText(p)
	local num = formatNumber(p)
	local suffix = FEATURES.ShowPercentSign and "%" or ""
	local numberStr = tostring(num)..suffix
	if FEATURES.ColorizeNumberOnly and FEATURES.UsePercentGradient then
		local c = gradientColor(p)
		local r,g,b = math.floor(c.R*255+0.5), math.floor(c.G*255+0.5), math.floor(c.B*255+0.5)
		local prefixPart = FEATURES.ShowPrefix and "<font color=\"#FFFFFF\">" .. FEATURES.PrefixText .. "</font>" or ""
		local numberPart = string.format('<font color="#%02X%02X%02X">%s</font>', r,g,b, numberStr)
		return prefixPart .. numberPart
	else
		if FEATURES.UsePercentGradient then
			local c = gradientColor(p)
			local r,g,b = math.floor(c.R*255+0.5), math.floor(c.G*255+0.5), math.floor(c.B*255+0.5)
			local full = (FEATURES.ShowPrefix and FEATURES.PrefixText or "") .. numberStr
			return string.format('<font color="#%02X%02X%02X">%s</font>', r,g,b, full)
		else
			local full = (FEATURES.ShowPrefix and FEATURES.PrefixText or "") .. numberStr
			return '<font color="#FFFFFF">'..full..'</font>'
		end
	end
end

local function hungerColor(fed)
	if not FEATURES.UseHungerGradient then
		return FullnessStaticColor
	end
	fed = clamp01(fed)
	local fullC = HUNGER_GRADIENT.FullColor
	local midC  = HUNGER_GRADIENT.MidColor
	local emptyC= HUNGER_GRADIENT.EmptyColor
	local mid   = FEATURES.HungerMidpoint
	if not midC then
		return emptyC:Lerp(fullC, fed)
	end
	if fed < mid then
		local t = (mid == 0) and 0 or (fed / mid)
		return emptyC:Lerp(midC, t)
	else
		local t = (fed - mid) / (1 - mid)
		return midC:Lerp(fullC, t)
	end
end

-- State ---------------------------------------------------------------------
local rayParams = RaycastParams.new()
rayParams.FilterDescendantsInstances = {}
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local currentSlime
local attrConnections = {}
local ancestryConn
local lastSeen = 0
local lastUpdate = 0
local currentOffset = 0
local updateInterval = 1 / FEATURES.UpdateHz
local displayMode = "HUNGER"
local holdStageActive = false
local lastValidCheck = 0
local STUCK_FAILSAFE_DELAY = 0.3

-- Unconditional detach on pickup success
local remFolder = ReplicatedStorage:FindFirstChild("Remotes")
if remFolder then
	local evt = remFolder:FindFirstChild("SlimePickupResult")
	if evt and evt:IsA("RemoteEvent") then
		evt.OnClientEvent:Connect(function(payload)
			local success = (type(payload) == "table" and payload.success) or false
			if success then
				dprint("Pickup success -> force detach")
				if currentSlime then
					currentSlime = nil
				end
				billboard.Adornee = nil
				billboard.Enabled = false
				-- Connections cleared in detach, but call for safety:
				for _,c in ipairs(attrConnections) do if c.Connected then c:Disconnect() end end
				attrConnections = {}
				if ancestryConn and ancestryConn.Connected then ancestryConn:Disconnect() end
				ancestryConn = nil
			end
		end)
	end
end

local function clearAttrConnections()
	for _,c in ipairs(attrConnections) do
		if c.Connected then c:Disconnect() end
	end
	attrConnections = {}
	if ancestryConn and ancestryConn.Connected then ancestryConn:Disconnect() end
	ancestryConn = nil
end

local function slimeRefPart(slime)
	if slime and slime.PrimaryPart then return slime.PrimaryPart end
	if slime then
		for _,c in ipairs(slime:GetChildren()) do
			if c:IsA("BasePart") then return c end
		end
	end
end

local function computeYOffset(slime)
	if not slime then return 4 end
	local minY, maxY = math.huge, -math.huge
	for _,c in ipairs(slime:GetDescendants()) do
		if c:IsA("BasePart") then
			local top = c.Position.Y + c.Size.Y*0.5
			local bottom = c.Position.Y - c.Size.Y*0.5
			if top > maxY then maxY = top end
			if bottom < minY then minY = bottom end
		end
	end
	if maxY == -math.huge then return 4 end
	local tall = maxY - minY
	return tall * 0.55 + FEATURES.ExtraY
end

local function detach()
	if not currentSlime and not billboard.Enabled then return end
	dprint("Detach hover UI")
	clearAttrConnections()
	currentSlime = nil
	billboard.Enabled = false
	billboard.Adornee = nil
end

local function attach(slime)
	local part = slimeRefPart(slime)
	if not part then return end
	dprint("Attach to slime", safeDebugId(slime))
	currentSlime = slime
	billboard.Adornee = part
	billboard.Enabled = true
	lastSeen = tick()
	currentOffset = computeYOffset(slime)
	billboard.StudsOffset = Vector3.new(0, currentOffset, 0)

	local function listen(attrName)
		local sig = slime:GetAttributeChangedSignal(attrName):Connect(function()
			lastUpdate = 0
		end)
		table.insert(attrConnections, sig)
	end
	listen("GrowthProgress")
	if FEATURES.EnableStage then listen(FEATURES.StageAttributeName) end
	if FEATURES.EnableHunger then listen(FEATURES.FedAttributeName) end
	if FEATURES.ShowValue then listen(FEATURES.ValueAttributeName) end

	ancestryConn = slime.AncestryChanged:Connect(function(_, parent)
		if parent == nil and currentSlime == slime then
			dprint("AncestryChanged detach", safeDebugId(slime))
			detach()
		end
	end)

	lastUpdate = 0
end

local function buildInfoLine()
	if not currentSlime then return "" end
	local parts = {}
	local effectiveMode = (holdStageActive and FEATURES.EnableStage) and "STAGE" or displayMode

	if effectiveMode == "HUNGER" and FEATURES.EnableHunger then
		local fed = tonumber(currentSlime:GetAttribute(FEATURES.FedAttributeName)) or 0
		fed = clamp01(fed)
		local pct
		local label
		if FEATURES.HungerDisplayMode == "Fullness" then
			pct = math.floor(fed*100 + 0.5)
			label = FEATURES.FullnessLabel
		else
			local hunger = 1 - fed
			pct = math.floor(hunger*100 + 0.5)
			label = FEATURES.StarvationLabel
		end
		local col = hungerColor(fed)
		local r,g,b = math.floor(col.R*255+0.5), math.floor(col.G*255+0.5), math.floor(col.B*255+0.5)
		table.insert(parts, string.format('<font color="#%02X%02X%02X">%s%d%%</font>', r,g,b,label,pct))
	elseif effectiveMode == "STAGE" and FEATURES.EnableStage then
		local stage = currentSlime:GetAttribute(FEATURES.StageAttributeName) or 0
		local r,g,b = math.floor(STAGE_COLOR.R*255+0.5), math.floor(STAGE_COLOR.G*255+0.5), math.floor(STAGE_COLOR.B*255+0.5)
		table.insert(parts, string.format('<font color="#%02X%02X%02X">Stage: %s</font>', r,g,b,tostring(stage)))
	end

	if FEATURES.ShowValue then
		local v = currentSlime:GetAttribute(FEATURES.ValueAttributeName)
		if v then
			local r,g,b = math.floor(VALUE_COLOR.R*255+0.5), math.floor(VALUE_COLOR.G*255+0.5), math.floor(VALUE_COLOR.B*255+0.5)
			table.insert(parts, string.format('<font color="#%02X%02X%02X">Value: %d</font>', r,g,b, math.floor(v + 0.5)))
		end
	end

	if #parts == 0 then return "" end
	return table.concat(parts, "  |  ")
end

local function updateUI(force)
	if not currentSlime then return end
	if not currentSlime.Parent then
		detach()
		return
	end
	local now = tick()
	if not force and (now - lastUpdate) < updateInterval then return end
	lastUpdate = now

	local gp = clamp01(currentSlime:GetAttribute("GrowthProgress") or 0)
	mainLabel.Text = buildGrowthText(gp)
	if shadowLabel then shadowLabel.Text = mainLabel.Text:gsub("<.->","") end
	if FEATURES.ShowProgressBar and barFill then
		barFill.Size = UDim2.new(gp,0,1,0)
	end
	local info = buildInfoLine()
	if info ~= "" then
		infoLabel.Visible = true
		infoLabel.Text = info
	else
		infoLabel.Visible = false
		infoLabel.Text = ""
	end
end

-- Raycast helpers -----------------------------------------------------------
local function findSlimeModel(part)
	local n = part
	for _=1,14 do
		if not n then break end
		if n:IsA("Model") and n.Name == "Slime" then return n end
		n = n.Parent
	end
end

local function raycastHover()
	local char = LP.Character
	if char then
		rayParams.FilterDescendantsInstances = { char }
	else
		rayParams.FilterDescendantsInstances = {}
	end
	local mp = UserInputService:GetMouseLocation()
	local ray = Camera:ViewportPointToRay(mp.X, mp.Y)
	local result = workspace:Raycast(ray.Origin, ray.Direction * FEATURES.MaxRayDistance, rayParams)
	local hit = result and result.Instance
	if not hit then return nil end
	return findSlimeModel(hit)
end

-- Input ---------------------------------------------------------------------
local function cycleMode()
	if displayMode == "HUNGER" then
		displayMode = FEATURES.EnableStage and "STAGE" or "HUNGER"
	else
		displayMode = "HUNGER"
	end
end

UserInputService.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.KeyCode == FEATURES.ToggleKey then
		cycleMode()
		lastUpdate = 0
	elseif input.KeyCode == FEATURES.HoldStageKey then
		holdStageActive = true
		lastUpdate = 0
	end
end)

UserInputService.InputEnded:Connect(function(input, gpe)
	if gpe then return end
	if input.KeyCode == FEATURES.HoldStageKey then
		holdStageActive = false
		lastUpdate = 0
	end
end)

-- Main Loop -----------------------------------------------------------------
RunService.RenderStepped:Connect(function()
	if workspace.CurrentCamera ~= Camera then Camera = workspace.CurrentCamera end
	local slime = raycastHover()
	local now = tick()

	if slime and slime.Parent then
		local part = slimeRefPart(slime)
		if part and (part.Position - Camera.CFrame.Position).Magnitude <= FEATURES.MaxViewDistance then
			if slime ~= currentSlime then
				detach()
				attach(slime)
			else
				lastSeen = now
			end
		end
	end

	if currentSlime then
		local adorneeValid = billboard.Adornee ~= nil and billboard.Adornee.Parent ~= nil
		if (now - lastSeen) > FEATURES.HoverLoseGrace or not adorneeValid or not currentSlime.Parent then
			detach()
		end
	end

	if not currentSlime and billboard.Enabled and (now - lastValidCheck) > STUCK_FAILSAFE_DELAY then
		dprint("Failsafe detach (billboard enabled without slime)")
		detach()
	else
		lastValidCheck = now
	end

	if currentSlime and billboard.Enabled and billboard.Adornee then
		local target = computeYOffset(currentSlime)
		if FEATURES.SmoothOffset then
			currentOffset = currentOffset + (target - currentOffset) * FEATURES.OffsetLerpAlpha
		else
			currentOffset = target
		end
		billboard.StudsOffset = Vector3.new(0, currentOffset, 0)
		updateUI(false)
	end
end)