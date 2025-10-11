-- LocalScript: MutationVFX.client.lua (robust; non-blocking resolution of SlimeMutation)
-- Place: StarterPlayerScripts
-- Listens for ReplicatedStorage.Remotes.SlimeMutation OR ReplicatedStorage.Events.SlimeMutation
-- without infinite-waiting; falls back to watching for creation briefly.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local LOCAL_PLAYER = Players.LocalPlayer
local PLAYER_GUI = LOCAL_PLAYER:WaitForChild("PlayerGui")

local EFFECTS = ReplicatedStorage:FindFirstChild("Effects")
local MUTATION_EFFECT_TEMPLATE = (EFFECTS and EFFECTS:FindFirstChild("MutationEffect")) or nil

-- rate limit map per-model (weak keys)
local lastPopupAt = setmetatable({}, { __mode = "k" })
local RATE_LIMIT_SECONDS = 0.7
local POPUP_DURATION = 1.8

-- attempt to resolve the SlimeMutation RemoteEvent without blocking forever
local function resolveMutationEvent()
	-- quick non-blocking checks first
	local root = ReplicatedStorage:FindFirstChild("Remotes") or ReplicatedStorage:FindFirstChild("Events")
	if root then
		local ev = root:FindFirstChild("SlimeMutation")
		if ev and ev:IsA("RemoteEvent") then return ev end
	end

	-- try each folder with a short timeout
	local function waitInFolder(folderName, timeout)
		-- try existing folder
		local folder = ReplicatedStorage:FindFirstChild(folderName)
		if folder then
			local ev = folder:FindFirstChild("SlimeMutation")
			if ev and ev:IsA("RemoteEvent") then return ev end
			-- short wait for the child
			local ok, got = pcall(function() return folder:WaitForChild("SlimeMutation", timeout) end)
			if ok and got and got:IsA("RemoteEvent") then return got end
			return nil
		end
		-- wait for folder then for event (short)
		local okf, f = pcall(function() return ReplicatedStorage:WaitForChild(folderName, timeout) end)
		if not okf or not f then return nil end
		local oke, e = pcall(function() return f:WaitForChild("SlimeMutation", timeout) end)
		if oke and e and e:IsA("RemoteEvent") then return e end
		return nil
	end

	local ev = waitInFolder("Remotes", 1) or waitInFolder("Events", 1)
	if ev then return ev end

	-- final fallback: listen for child additions for a short window
	local found = nil
	local connRoot
	local connFolderRemotes, connFolderEvents

	local function watchFolder(folder)
		if not folder then return end
		-- immediate check
		local e = folder:FindFirstChild("SlimeMutation")
		if e and e:IsA("RemoteEvent") then
			found = e
			return
		end
		-- listen for added.
		local c = folder.ChildAdded:Connect(function(child)
			if child and child.Name == "SlimeMutation" and child:IsA("RemoteEvent") then
				found = child
			end
		end)
		return c
	end

	-- listen for Remotes/Events folder to appear or changes
	connRoot = ReplicatedStorage.ChildAdded:Connect(function(child)
		if child and (child.Name == "Remotes" or child.Name == "Events") then
			if child.Name == "Remotes" then
				if connFolderRemotes then connFolderRemotes:Disconnect(); connFolderRemotes = nil end
				connFolderRemotes = watchFolder(child)
			elseif child.Name == "Events" then
				if connFolderEvents then connFolderEvents:Disconnect(); connFolderEvents = nil end
				connFolderEvents = watchFolder(child)
			end
		end
	end)

	-- also start watchers on existing folders
	connFolderRemotes = watchFolder(ReplicatedStorage:FindFirstChild("Remotes"))
	connFolderEvents  = watchFolder(ReplicatedStorage:FindFirstChild("Events"))

	-- wait up to a short duration while yielding to Heartbeat
	local start = tick()
	local timeout = 3.0
	while tick() - start < timeout and not found do
		RunService.Heartbeat:Wait()
	end

	-- cleanup
	if connRoot then connRoot:Disconnect() end
	if connFolderRemotes then connFolderRemotes:Disconnect() end
	if connFolderEvents then connFolderEvents:Disconnect() end

	return found
end

local MUTATION_EVENT = resolveMutationEvent()
if not MUTATION_EVENT then
	warn("[MutationVFX] SlimeMutation RemoteEvent not found in ReplicatedStorage.Remotes or ReplicatedStorage.Events; continuing without auto VFX.")
	-- Optionally: return here if you want to stop the script entirely
end

local function slimePrimaryPart(slime)
	if not slime then return nil end
	if slime.PrimaryPart then return slime.PrimaryPart end
	for _,c in ipairs(slime:GetChildren()) do
		if c:IsA("BasePart") then return c end
	end
	return nil
end

local function computeYOffset(slime)
	if not slime then return 3 end
	local minY, maxY = math.huge, -math.huge
	for _,c in ipairs(slime:GetDescendants()) do
		if c:IsA("BasePart") then
			local top = c.Position.Y + c.Size.Y * 0.5
			local bottom = c.Position.Y - c.Size.Y * 0.5
			if top > maxY then maxY = top end
			if bottom < minY then minY = bottom end
		end
	end
	if maxY == -math.huge then return 3 end
	local tall = maxY - minY
	return tall * 0.55 + 1.2
end

local function tryPlayEffectOnPart(part, duration)
	if not part or not part.Parent then return end
	if not MUTATION_EFFECT_TEMPLATE then return end
	local ok, cloned = pcall(function() return MUTATION_EFFECT_TEMPLATE:Clone() end)
	if not ok or not cloned then return end

	if cloned:IsA("Model") then
		local innerPart = cloned:FindFirstChildWhichIsA("BasePart") or cloned:FindFirstChild("EmitterPart")
		if innerPart then
			cloned.Parent = part
			pcall(function()
				if cloned.PrimaryPart then
					cloned:SetPrimaryPartCFrame(part.CFrame)
				else
					innerPart.CFrame = part.CFrame
				end
			end)
			task.delay(duration, function() pcall(function() cloned:Destroy() end) end)
			return
		end
		for _,c in ipairs(cloned:GetChildren()) do
			if c:IsA("ParticleEmitter") then
				local pe = c:Clone()
				pe.Parent = part
				pe.Enabled = true
				task.delay(duration, function() pcall(function() pe.Enabled = false; pe:Destroy() end) end)
			elseif c:IsA("Sound") then
				local s = c:Clone()
				s.Parent = part
				s:Play()
				task.delay(duration, function() pcall(function() s:Stop(); s:Destroy() end) end)
			elseif c:IsA("BasePart") then
				local p = c:Clone()
				p.Parent = part
				task.delay(duration, function() p:Destroy() end)
			end
		end
		cloned:Destroy()
		return
	end

	if cloned:IsA("ParticleEmitter") then
		cloned.Parent = part
		cloned.Enabled = true
		task.delay(duration, function() pcall(function() cloned.Enabled = false; cloned:Destroy() end) end)
		return
	elseif cloned:IsA("BasePart") then
		cloned.Parent = part
		task.delay(duration, function() pcall(function() cloned:Destroy() end) end)
		return
	else
		cloned.Parent = part
		task.delay(duration, function() pcall(function() cloned:Destroy() end) end)
	end
end

local function spawnPopupBillboard(part, text, duration)
	if not part or not part.Parent then return end
	local ok, gui = pcall(function()
		local g = Instance.new("BillboardGui")
		g.Name = "MutationPopup"
		g.AlwaysOnTop = true
		g.Size = UDim2.new(0, 220, 0, 36)
		g.LightInfluence = 0
		g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		g.Adornee = part
		g.Parent = PLAYER_GUI

		local frame = Instance.new("Frame")
		frame.Size = UDim2.new(1, 0, 1, 0)
		frame.BackgroundTransparency = 0.25
		frame.BackgroundColor3 = Color3.fromRGB(30, 40, 70)
		frame.BorderSizePixel = 0
		frame.Parent = g
		local corner = Instance.new("UICorner"); corner.Parent = frame

		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, -8, 1, -6)
		label.Position = UDim2.new(0, 4, 0, 3)
		label.BackgroundTransparency = 1
		label.TextColor3 = Color3.fromRGB(200, 235, 255)
		label.RichText = false
		label.TextScaled = true
		label.TextWrapped = true
		label.Font = Enum.Font.GothamBold
		label.Text = text or "Mutation"
		label.Parent = frame

		return g
	end)

	if ok and gui then
		task.delay(duration, function()
			pcall(function() if gui and gui.Parent then gui:Destroy() end end)
		end)
	end
end

local function onMutationReceived(slimeModel, info)
	if not slimeModel or not slimeModel.Parent then return end
	local mutationType = nil
	local valueMult = nil
	if type(info) == "table" then
		mutationType = info.mutationType or info.MutationLastType
		valueMult = info.valueMult
	else
		mutationType = tostring(info)
	end

	local now = tick()
	if lastPopupAt[slimeModel] and (now - lastPopupAt[slimeModel]) < RATE_LIMIT_SECONDS then
		return
	end
	lastPopupAt[slimeModel] = now

	local prim = slimePrimaryPart(slimeModel)
	if not prim or not prim.Parent then return end

	pcall(function() tryPlayEffectOnPart(prim, POPUP_DURATION) end)

	local displayText = "Mutation: " .. tostring(mutationType or "Unknown")
	if valueMult and type(valueMult) == "number" and math.abs(valueMult - 1) > 0.001 then
		displayText = displayText .. string.format("  (x%.2f)", valueMult)
	end
	pcall(function() spawnPopupBillboard(prim, displayText, POPUP_DURATION) end)
end

if MUTATION_EVENT and MUTATION_EVENT:IsA("RemoteEvent") then
	MUTATION_EVENT.OnClientEvent:Connect(function(slimeModel, info)
		task.spawn(function() pcall(function() onMutationReceived(slimeModel, info) end) end)
	end)
else
	-- If not present now, optionally watch for it and connect later
	local conn
	local function childAdded(child)
		if child.Name == "Remotes" or child.Name == "Events" then
			-- try to find SlimeMutation under new folder
			local folder = ReplicatedStorage:FindFirstChild(child.Name)
			if folder then
				local e = folder:FindFirstChild("SlimeMutation")
				if e and e:IsA("RemoteEvent") then
					e.OnClientEvent:Connect(function(slimeModel, info)
						task.spawn(function() pcall(function() onMutationReceived(slimeModel, info) end) end)
					end)
					if conn then conn:Disconnect() end
				end
			end
		elseif child.Name == "SlimeMutation" and child:IsA("RemoteEvent") then
			-- direct SlimeMutation got parented under ReplicatedStorage (unlikely but handle)
			child.OnClientEvent:Connect(function(slimeModel, info)
				task.spawn(function() pcall(function() onMutationReceived(slimeModel, info) end) end)
			end)
			if conn then conn:Disconnect() end
		end
	end
	conn = ReplicatedStorage.ChildAdded:Connect(childAdded)
	-- stop listening after short period to avoid leaking connections
	task.delay(6, function() if conn and conn.Connected then conn:Disconnect() end end)
end