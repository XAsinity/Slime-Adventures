-- MusicController.client.lua
-- Full script; robustly waits on LoadingActive (creates fallback if missing) and crossfades in.

local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local SoundService       = game:GetService("SoundService")
local TweenService       = game:GetService("TweenService")
local UserInputService   = game:GetService("UserInputService")
local RunService         = game:GetService("RunService")

local player = Players.LocalPlayer

-- Optional MusicPlaylist module (graceful fallback if absent or no BuildQueue)
local MusicPlaylist
local playlistOk, playlistErr = pcall(function()
	return require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("MusicPlaylist"))
end)
if playlistOk then
	MusicPlaylist = playlistErr
else
	warn("[MusicController] MusicPlaylist module not available:", playlistErr)
	MusicPlaylist = nil
end

local remotes       = ReplicatedStorage:WaitForChild("Remotes")
local updateEvent   = remotes:WaitForChild("UpdateMusicVolume")

--------------------------------------------------
-- CONFIG
--------------------------------------------------
local FADE_TIME            = 1.5
local DEFAULT_VOLUME       = 0.5

-- UI / title
local TITLE_FADE_TIME      = 0.35
local MARQUEE_SCROLL_SPEED = 60
local MARQUEE_GAP          = 32

-- Dynamic folder scanning
local FOLDER_NAMES = {
	"DefaultSoundTrack", -- primary
	"Music",             -- alternate
}
local RESCAN_ON_QUEUE_REFILL = true

local TRIM_SUFFIXES = {
	" Powered by UDIO Music",
	" - Powered by UDIO Music",
	" (Powered by UDIO Music)",
}

local LOG_PREFIX = "[MusicController]"

--------------------------------------------------
-- STATE
--------------------------------------------------
local musicGroup = SoundService:FindFirstChild("Music")
if not musicGroup then
	musicGroup = Instance.new("SoundGroup")
	musicGroup.Name = "Music"
	musicGroup.Parent = SoundService
end

local currentSound
local queue          = {}
local queueIndex     = 0
local targetVolume   = DEFAULT_VOLUME
local dragging       = false
local suppressRemote = false

-- UI refs
local screenGui
local toggleButton
local panel
local sliderBar
local sliderFill
local sliderKnob
local volumeLabel

-- Title ticker refs
local titleTickerFrame
local titleTextHolder
local titleMarqueeLabels = {}
local currentTrackName   = ""
local marqueeToken       = 0

--------------------------------------------------
-- Utility
--------------------------------------------------
local function dprint(...)
	-- set to true to debug
	-- print(LOG_PREFIX, ...)
end

local function prettifyName(name)
	if not name then return "" end
	for _,suffix in ipairs(TRIM_SUFFIXES) do
		if name:sub(-#suffix) == suffix then
			return name:sub(1, #name - #suffix)
		end
	end
	return name
end

--------------------------------------------------
-- Volume UI
--------------------------------------------------
local function setVolumeUI(v)
	if volumeLabel then
		volumeLabel.Text = ("Music Volume: %d%%"):format(math.floor(v*100))
	end
	if sliderBar and sliderFill and sliderKnob then
		local barWidth = sliderBar.AbsoluteSize.X
		local x = v * barWidth
		sliderFill.Size = UDim2.new(0, x, 1, 0)
		if sliderKnob.AbsoluteSize.X > 0 then
			sliderKnob.Position = UDim2.new(0, x - sliderKnob.AbsoluteSize.X/2, 0.5, -sliderKnob.AbsoluteSize.Y/2)
		end
	end
end

local function applyVolume(v, userInitiated)
	targetVolume = math.clamp(v, 0, 1)
	musicGroup.Volume = targetVolume
	setVolumeUI(targetVolume)

	-- Safety: if track is internally silent and user raises volume, normalize track alpha.
	if targetVolume > 0 and currentSound and currentSound.IsPlaying and currentSound.Volume < 0.01 then
		currentSound.Volume = 1
	end

	if userInitiated and not suppressRemote then
		updateEvent:FireServer(targetVolume)
	end
end

--------------------------------------------------
-- Track Collection
--------------------------------------------------
local function findFolderWithSounds()
	for _,name in ipairs(FOLDER_NAMES) do
		local folder = ReplicatedStorage:FindFirstChild(name) or SoundService:FindFirstChild(name)
		if folder then
			return folder
		end
	end
	return nil
end

local function gatherFolderSounds()
	local list = {}
	local folder = findFolderWithSounds()
	if not folder then
		return list
	end
	for _,child in ipairs(folder:GetChildren()) do
		if child:IsA("Sound") then
			table.insert(list, child)
		end
	end
	return list
end

local function shuffle(t)
	for i = #t, 2, -1 do
		local j = math.random(i)
		t[i], t[j] = t[j], t[i]
	end
end

local function refillQueue()
	local newQueue = {}

	-- 1. Module-provided queue
	if MusicPlaylist and typeof(MusicPlaylist.BuildQueue) == "function" then
		local ok, built = pcall(function() return MusicPlaylist:BuildQueue() end)
		if ok and type(built) == "table" then
			for _,v in ipairs(built) do
				if typeof(v) == "Instance" and v:IsA("Sound") then
					table.insert(newQueue, v)
				end
			end
		end
	end

	-- 2. Dynamic folder sounds
	local dyn = gatherFolderSounds()
	local present = {}
	for _,s in ipairs(newQueue) do present[s] = true end
	for _,s in ipairs(dyn) do
		if not present[s] then
			table.insert(newQueue, s)
			present[s] = true
		end
	end

	if #newQueue == 0 then
		warn(LOG_PREFIX, "No tracks found. Add Sounds to DefaultSoundTrack folder or ensure MusicPlaylist returns tracks.")
	end

	shuffle(newQueue)
	queue = newQueue
	queueIndex = 0
	dprint("Refilled queue with", #queue, "tracks.")
end

local function getNextTrack()
	if queueIndex >= #queue then
		if RESCAN_ON_QUEUE_REFILL then
			refillQueue()
		else
			queueIndex = 0
		end
	end
	queueIndex += 1
	return queue[queueIndex]
end

--------------------------------------------------
-- Sound cloning & fades
--------------------------------------------------
local function cloneTrack(proto)
	if not proto or not proto:IsA("Sound") then return nil end
	local s = proto:Clone()
	s.SoundGroup = musicGroup
	s.Volume = 0
	s.Looped = false
	s.Parent = SoundService
	return s
end

local function fadeIn(sound)
	if not sound then return end
	sound.Volume = 0
	local okPlay, err = pcall(function() sound:Play() end)
	if not okPlay then
		warn(LOG_PREFIX, "Failed to play sound", sound.Name, err)
		return
	end
	TweenService:Create(sound, TweenInfo.new(FADE_TIME, Enum.EasingStyle.Linear), {Volume = 1}):Play()
end

local function fadeOut(sound)
	if not sound then return end
	local tween = TweenService:Create(sound, TweenInfo.new(FADE_TIME, Enum.EasingStyle.Linear), {Volume = 0})
	tween:Play()
	tween.Completed:Connect(function()
		if sound ~= currentSound then
			sound:Destroy()
		end
	end)
end

--------------------------------------------------
-- Static Title + Marquee
--------------------------------------------------
local function ensureTitleFrame()
	if titleTickerFrame then return end
	titleTickerFrame = Instance.new("Frame")
	titleTickerFrame.Name = "TitleTicker"
	titleTickerFrame.Size = UDim2.new(1, 0, 0, 16)
	titleTickerFrame.Position = UDim2.new(0, 0, 0, -20)
	titleTickerFrame.BackgroundTransparency = 1
	titleTickerFrame.ClipsDescendants = true
	titleTickerFrame.Visible = true
	titleTickerFrame.Parent = toggleButton

	titleTextHolder = Instance.new("Frame")
	titleTextHolder.Name = "Holder"
	titleTextHolder.Size = UDim2.new(1, 0, 1, 0)
	titleTextHolder.BackgroundTransparency = 1
	titleTextHolder.Parent = titleTickerFrame
end

local function clearMarquee()
	for _,lbl in ipairs(titleMarqueeLabels) do
		lbl:Destroy()
	end
	titleMarqueeLabels = {}
end

local function setupMarqueeLabels(text)
	clearMarquee()
	local base = Instance.new("TextLabel")
	base.Name = "TrackLabel"
	base.Size = UDim2.new(0,0,1,0)
	base.Position = UDim2.new(0,0,0,0)
	base.BackgroundTransparency = 1
	base.Text = text
	base.TextColor3 = Color3.fromRGB(220,230,255)
	base.Font = Enum.Font.GothamSemibold
	base.TextSize = 13
	base.TextXAlignment = Enum.TextXAlignment.Left
	base.Parent = titleTextHolder

	RunService.RenderStepped:Wait()
	local w = base.TextBounds.X
	base.Size = UDim2.new(0,w,1,0)

	local frameW = titleTickerFrame.AbsoluteSize.X
	if w <= frameW then
		base.Position = UDim2.new(0.5, -w/2, 0, 0)
		titleMarqueeLabels = {base}
		return
	end

	local dup = base:Clone()
	dup.Parent = titleTextHolder
	dup.Position = UDim2.new(0, w + MARQUEE_GAP, 0, 0)
	titleMarqueeLabels = {base, dup}
end

local function runMarqueeLoop(localToken)
	task.spawn(function()
		while localToken == marqueeToken do
			if #titleMarqueeLabels < 2 then
				task.wait(0.25)
			else
				local lbl1 = titleMarqueeLabels[1]
				local lbl2 = titleMarqueeLabels[2]
				local width = lbl1.AbsoluteSize.X
				local dist = width + MARQUEE_GAP
				local duration = dist / MARQUEE_SCROLL_SPEED

				local tween1 = TweenService:Create(lbl1, TweenInfo.new(duration, Enum.EasingStyle.Linear), {
					Position = UDim2.new(0, -dist, 0, 0)
				})
				local tween2 = TweenService:Create(lbl2, TweenInfo.new(duration, Enum.EasingStyle.Linear), {
					Position = UDim2.new(0, lbl2.Position.X.Offset - dist, 0, 0)
				})
				tween1:Play(); tween2:Play()
				tween1.Completed:Wait()

				lbl1.Position = UDim2.new(0, lbl2.Position.X.Offset + width + MARQUEE_GAP, 0, 0)
				titleMarqueeLabels[1], titleMarqueeLabels[2] = titleMarqueeLabels[2], titleMarqueeLabels[1]
			end
		end
	end)
end

local function setTrackTitle(name)
	ensureTitleFrame()
	local display = prettifyName(name)
	currentTrackName = display
	marqueeToken += 1
	local localToken = marqueeToken

	if #titleMarqueeLabels > 0 then
		local fades = {}
		for _,lbl in ipairs(titleMarqueeLabels) do
			table.insert(fades, TweenService:Create(lbl, TweenInfo.new(TITLE_FADE_TIME), {TextTransparency = 1}))
		end
		for _,t in ipairs(fades) do t:Play() end
		task.wait(TITLE_FADE_TIME)
	end

	setupMarqueeLabels(display)
	for _,lbl in ipairs(titleMarqueeLabels) do
		lbl.TextTransparency = 1
		TweenService:Create(lbl, TweenInfo.new(TITLE_FADE_TIME), {TextTransparency = 0}):Play()
	end

	runMarqueeLoop(localToken)
end

--------------------------------------------------
-- Playback
--------------------------------------------------
local function playNext()
	local proto = getNextTrack()
	if not proto then
		warn(LOG_PREFIX, "Queue empty; cannot play next.")
		return
	end
	if not proto.Parent then
		dprint("Prototype removed, skipping:", proto.Name)
		return playNext()
	end

	local newSound = cloneTrack(proto)
	if not newSound then
		return playNext()
	end

	newSound.Ended:Connect(function()
		if newSound == currentSound then
			currentSound = nil
			playNext()
		end
	end)
	newSound.Stopped:Connect(function()
		if newSound == currentSound and newSound.TimePosition > 0.05 then
			currentSound = nil
			playNext()
		end
	end)

	local old = currentSound
	currentSound = newSound
	setTrackTitle(newSound.Name)

	fadeIn(newSound)
	if old then fadeOut(old) end
end

--------------------------------------------------
-- UI Creation
--------------------------------------------------
local function createUI()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "MusicUI"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	toggleButton = Instance.new("TextButton")
	toggleButton.Name = "MusicToggle"
	toggleButton.Size = UDim2.new(0,120,0,36)
	toggleButton.Position = UDim2.new(0,20,1,-56)
	toggleButton.AnchorPoint = Vector2.new(0,1)
	toggleButton.BackgroundColor3 = Color3.fromRGB(40,40,55)
	toggleButton.TextColor3 = Color3.fromRGB(230,230,255)
	toggleButton.Font = Enum.Font.GothamBold
	toggleButton.TextSize = 20
	toggleButton.Text = "Music"
	toggleButton.Parent = screenGui

	panel = Instance.new("Frame")
	panel.Name = "MusicPanel"
	panel.Size = UDim2.new(0,340,0,130)
	panel.Position = UDim2.new(0,150,1,-150)
	panel.AnchorPoint = Vector2.new(0,1)
	panel.BackgroundColor3 = Color3.fromRGB(25,25,35)
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.Parent = screenGui
	local pCorner = Instance.new("UICorner"); pCorner.CornerRadius = UDim.new(0,10); pCorner.Parent = panel

	volumeLabel = Instance.new("TextLabel")
	volumeLabel.Size = UDim2.new(1,-20,0,30)
	volumeLabel.Position = UDim2.new(0,10,0,10)
	volumeLabel.BackgroundTransparency = 1
	volumeLabel.TextColor3 = Color3.new(1,1,1)
	volumeLabel.TextXAlignment = Enum.TextXAlignment.Left
	volumeLabel.Font = Enum.Font.GothamBold
	volumeLabel.TextSize = 18
	volumeLabel.Text = "Music Volume:"
	volumeLabel.Parent = panel

	local sliderContainer = Instance.new("Frame")
	sliderContainer.Size = UDim2.new(1,-20,0,40)
	sliderContainer.Position = UDim2.new(0,10,0,50)
	sliderContainer.BackgroundTransparency = 1
	sliderContainer.Parent = panel

	sliderBar = Instance.new("Frame")
	sliderBar.Size = UDim2.new(1,0,0,12)
	sliderBar.Position = UDim2.new(0,0,0.5,-6)
	sliderBar.BackgroundColor3 = Color3.fromRGB(70,70,90)
	sliderBar.BorderSizePixel = 0
	sliderBar.Parent = sliderContainer
	local sbCorner = Instance.new("UICorner"); sbCorner.CornerRadius = UDim.new(0,6); sbCorner.Parent = sliderBar

	sliderFill = Instance.new("Frame")
	sliderFill.Size = UDim2.new(0,0,1,0)
	sliderFill.BackgroundColor3 = Color3.fromRGB(120,180,255)
	sliderFill.BorderSizePixel = 0
	sliderFill.Parent = sliderBar
	local sfCorner = Instance.new("UICorner"); sfCorner.CornerRadius = UDim.new(0,6); sfCorner.Parent = sliderFill

	sliderKnob = Instance.new("Frame")
	sliderKnob.Size = UDim2.new(0,20,0,20)
	sliderKnob.BackgroundColor3 = Color3.fromRGB(200,230,255)
	sliderKnob.BorderSizePixel = 0
	sliderKnob.Parent = sliderBar
	local skCorner = Instance.new("UICorner"); skCorner.CornerRadius = UDim.new(1,0); skCorner.Parent = sliderKnob
	sliderKnob.ZIndex = 2

	local closeBtn = Instance.new("TextButton")
	closeBtn.Size = UDim2.new(0,28,0,28)
	closeBtn.Position = UDim2.new(1,-34,0,6)
	closeBtn.Text = "X"
	closeBtn.BackgroundColor3 = Color3.fromRGB(60,60,80)
	closeBtn.TextColor3 = Color3.new(1,1,1)
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.TextSize = 16
	closeBtn.Parent = panel
	local cCorner = Instance.new("UICorner"); cCorner.CornerRadius = UDim.new(0,6); cCorner.Parent = closeBtn

	toggleButton.MouseButton1Click:Connect(function()
		panel.Visible = not panel.Visible
	end)
	closeBtn.MouseButton1Click:Connect(function()
		panel.Visible = false
	end)
end

--------------------------------------------------
-- Slider Interaction
--------------------------------------------------
local function updateFromX(xPos)
	if not sliderBar then return end
	local absPos = sliderBar.AbsolutePosition.X
	local width  = sliderBar.AbsoluteSize.X
	local alpha  = math.clamp((xPos - absPos)/width, 0, 1)
	applyVolume(alpha, true)
end

local function connectSlider()
	sliderBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			updateFromX(input.Position.X)
		end
	end)
	sliderKnob.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			updateFromX(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
end

--------------------------------------------------
-- Initialization
--------------------------------------------------
math.randomseed(tick())

createUI()
connectSlider()

-- Volume persistence value
local volValue = player:WaitForChild("LocalMusicVolume", 5)
if volValue and typeof(volValue.Value) == "number" then
	suppressRemote = true
	applyVolume(volValue.Value, false)
	suppressRemote = false
	volValue.Changed:Connect(function()
		if not dragging then
			suppressRemote = true
			applyVolume(volValue.Value, false)
			suppressRemote = false
		end
	end)
else
	applyVolume(DEFAULT_VOLUME, true)
end

-- Wait for LoadingActive to exist and be false before starting playback.
-- This is robust to script ordering: Manager.lua creates LoadingActive at start.
local loadingFlag = player:FindFirstChild("LoadingActive")
if not loadingFlag then
	-- wait a bit for Manager to create it
	loadingFlag = player:WaitForChild("LoadingActive", 5)
end

if not loadingFlag then
	-- fallback: if still not created, create a local flag and mark loading as finished so music can start.
	loadingFlag = Instance.new("BoolValue")
	loadingFlag.Name = "LoadingActive"
	loadingFlag.Value = false
	loadingFlag.Parent = player
	dprint(LOG_PREFIX, "No LoadingActive found; created local fallback (false).")
end

-- If loading is active, wait until it becomes false.
if loadingFlag.Value then
	dprint(LOG_PREFIX, "LoadingActive present and true; waiting until false to start music.")
	while loadingFlag.Value do
		loadingFlag:GetPropertyChangedSignal("Value"):Wait()
	end
	-- small safety pause to let Manager start fade
	task.wait(0.02)
end

-- Initial track population & start playback (only after loading finished)
refillQueue()
playNext()

print(LOG_PREFIX, "Initialized. Tracks in queue:", #queue)