-- Client-only hatch timers: show hatch timer billboards only for eggs owned by the local player.
-- Place this LocalScript in StarterPlayerScripts (or StarterGui as a LocalScript).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

-- Config (tweak as you like)
local HATCH_TIMER_NAME = "HatchTimer"
local HATCH_GUI_SIZE = UDim2.new(0, 110, 0, 34)
local HATCH_GUI_OFFSET_Y = 2.5
local HATCH_GUI_FONT = Enum.Font.GothamBold
local HATCH_GUI_TEXTCOLOR = Color3.fromRGB(255, 255, 255)
local HATCH_GUI_TEXTSTROKE = Color3.fromRGB(0, 0, 0)
local HATCH_GUI_TEXTSTROKE_T = 0.4
local HATCH_TIME_DECIMALS = 0
local HATCH_LOW_WARN_THRESHOLD = 5
local HATCH_WARN_COLOR = Color3.fromRGB(255, 170, 70)
local HATCH_FLASH_RATE = 4

-- Visibility: how far away (studs) before the billboard stops rendering
local VISIBLE_DISTANCE = 175 -- studs; adjust to taste

-- State: tracked eggs => { billboard = Instance, attrConn = RBXScriptConnection? }
local tracked = {}

-- Try to derive a numeric hatch timestamp (epoch seconds) similar to server logic
local function deriveHatchAt(inst)
	if not inst then return nil end
	local ok, hatchAt = pcall(function() return inst:GetAttribute("HatchAt") end)
	if ok and type(hatchAt) == "number" then return hatchAt end

	local ht = nil
	local pa = nil
	pcall(function() ht = tonumber(inst:GetAttribute("HatchTime")) end)
	pcall(function() pa = tonumber(inst:GetAttribute("PlacedAt")) end)

	if not ht then return nil end
	-- If PlacedAt looks like an epoch seconds timestamp (> ~1e8), use it directly.
	if pa and pa > 1e8 then
		return pa + ht
	end
	-- If PlacedAt looks like tick()-based or small, attempt to approximate using current os.time()
	if pa and pa > 0 then
		local remaining = (pa + ht) - tick()
		return os.time() + math.max(0, remaining)
	end
	-- If only HatchTime is set, assume it's a duration from now (best-effort UI)
	return os.time() + ht
end

local function safePrimary(egg)
	local ok, prim = pcall(function() return egg.PrimaryPart end)
	if ok and prim and prim:IsA("BasePart") then return prim end
	local ok2, fallback = pcall(function() return egg:FindFirstChildWhichIsA("BasePart") end)
	if ok2 and fallback and fallback:IsA("BasePart") then return fallback end
	return nil
end

local function createBillboard(egg)
	if not egg or not egg.Parent then return nil end
	if egg:FindFirstChild(HATCH_TIMER_NAME) then return egg:FindFirstChild(HATCH_TIMER_NAME) end

	local primary = safePrimary(egg)
	if not primary then return nil end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = HATCH_TIMER_NAME
	billboard.Size = HATCH_GUI_SIZE
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = VISIBLE_DISTANCE

	-- place above using the part's up vector so rotated eggs show correctly
	local okUp, upVec = pcall(function() return primary and primary.CFrame and primary.CFrame.UpVector end)
	if not okUp or typeof(upVec) ~= "Vector3" then upVec = Vector3.new(0, 1, 0) end
	local halfHeight = 0
	pcall(function() if primary and primary.Size and primary.Size.Y then halfHeight = tonumber(primary.Size.Y) * 0.5 end end)
	billboard.StudsOffsetWorldSpace = upVec * (halfHeight + HATCH_GUI_OFFSET_Y)

	billboard.Adornee = primary

	local label = Instance.new("TextLabel")
	label.Name = "TimeLabel"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = HATCH_GUI_FONT
	label.TextScaled = true
	label.TextColor3 = HATCH_GUI_TEXTCOLOR
	label.TextStrokeColor3 = HATCH_GUI_TEXTSTROKE
	label.TextStrokeTransparency = HATCH_GUI_TEXTSTROKE_T
	label.Text = ""
	label.Parent = billboard

	billboard.Parent = egg
	return billboard
end

local function destroyBillboard(egg)
	if not egg then return end
	local b = egg:FindFirstChild(HATCH_TIMER_NAME)
	if b then
		pcall(function() b:Destroy() end)
	end
end

local function trackEgg(egg)
	if not egg or tracked[egg] then return end
	-- Only track eggs that are ManualHatch and owned by the local player
	local okMH, mh = pcall(function() return egg:GetAttribute("ManualHatch") end)
	local okOwner, owner = pcall(function() return egg:GetAttribute("OwnerUserId") end)
	if not okMH or not okOwner then return end
	if not mh then return end
	if tostring(owner) ~= tostring(LocalPlayer.UserId) then return end

	tracked[egg] = { billboard = nil, attrConn = nil }

	-- If attributes change such that we should stop tracking, untrack.
	local function onAttrChanged(attr)
		if attr == "OwnerUserId" or attr == "ManualHatch" or attr == "HatchAt" or attr == "HatchTime" or attr == "PlacedAt" then
			local okMH2, mh2 = pcall(function() return egg:GetAttribute("ManualHatch") end)
			local okOwner2, owner2 = pcall(function() return egg:GetAttribute("OwnerUserId") end)
			if (not okMH2) or (not okOwner2) or (not mh2) or tostring(owner2) ~= tostring(LocalPlayer.UserId) then
				-- no longer owned/valid
				if tracked[egg] and tracked[egg].attrConn then
					pcall(function() tracked[egg].attrConn:Disconnect() end)
				end
				destroyBillboard(egg)
				tracked[egg] = nil
			end
		end
	end

	-- connect attribute changed for this egg model if available
	local suc, conn = pcall(function() return egg.AttributeChanged end)
	if suc and conn then
		local c = egg.AttributeChanged:Connect(onAttrChanged)
		tracked[egg].attrConn = c
	end
end

local function untrackEgg(egg)
	if not egg or not tracked[egg] then return end
	if tracked[egg].attrConn then
		pcall(function() tracked[egg].attrConn:Disconnect() end)
	end
	destroyBillboard(egg)
	tracked[egg] = nil
end

local function scanForOwnedEggs()
	-- add new owned eggs
	for _, desc in ipairs(Workspace:GetDescendants()) do
		if desc:IsA("Model") and desc.Name == "Egg" then
			trackEgg(desc)
		end
	end
	-- remove invalid entries
	for egg, info in pairs(tracked) do
		if not egg or not egg.Parent then
			untrackEgg(egg)
		end
	end
end

local function formatTime(remaining)
	if remaining < 0 then remaining = 0 end
	local m = math.floor(remaining / 60)
	local s = math.floor(remaining % 60)
	if HATCH_TIME_DECIMALS > 0 then
		local d = math.floor((remaining - math.floor(remaining)) * 10)
		return string.format("%02d:%02d.%d", m, s, d)
	else
		return string.format("%02d:%02d", m, s)
	end
end

local function updateTimers()
	local now = os.time()
	for egg, info in pairs(tracked) do
		if not egg or not egg.Parent then
			untrackEgg(egg)
		else
			local hatchAt = deriveHatchAt(egg)
			if not hatchAt then
				-- can't display; ensure billboard is gone
				if info.billboard then
					destroyBillboard(egg)
					info.billboard = nil
				end
				-- still keep tracked (maybe attributes will appear)
			else
				-- Create billboard if missing
				if not info.billboard then
					info.billboard = createBillboard(egg)
				end
				if info.billboard then
					local label = info.billboard:FindFirstChild("TimeLabel")
					if label then
						local remaining = hatchAt - now
						if remaining <= 0 then
							label.Text = "Ready!"
							label.TextColor3 = Color3.fromRGB(120, 255, 120)
						else
							label.Text = formatTime(remaining)
							if remaining <= HATCH_LOW_WARN_THRESHOLD and HATCH_FLASH_RATE then
								local t = (math.sin(now * math.pi * HATCH_FLASH_RATE) + 1) * 0.5
								label.TextColor3 = HATCH_GUI_TEXTCOLOR:Lerp(HATCH_WARN_COLOR, t)
							else
								label.TextColor3 = HATCH_GUI_TEXTCOLOR
							end
						end
					end
				end
			end
		end
	end
end

-- React to new eggs coming into the world
Workspace.DescendantAdded:Connect(function(desc)
	if desc:IsA("Model") and desc.Name == "Egg" then
		-- slight delay to allow attributes to be set
		task.delay(0.01, function() trackEgg(desc) end)
	end
end)

Workspace.DescendantRemoving:Connect(function(desc)
	if tracked[desc] then
		untrackEgg(desc)
	end
end)

-- initial scan and loops
scanForOwnedEggs()
RunService.Heartbeat:Connect(updateTimers)

-- periodic rescan to catch attribute-only adds or late attribute writes
task.spawn(function()
	while true do
		task.wait(1)
		scanForOwnedEggs()
	end
end)