-- ClientSlimeTool.lua
-- Version: v1.1-preview-safe
--
-- Client-side behaviour for the Captured Slime tool.
--
-- Features:
--   * Safe sanitation of the server-attached visual model (SlimeVisual) so it does not
--     interfere with player physics (non-collide, massless, no torque feedback).
--   * Optional light bob + spin animation (disabled by default to avoid any risk of the
--     ?player spinning / launch? bug).
--   * Floating info tag showing weight, value, rarity, growth progress.
--   * Optional hotkey stub (R) for a future ?Release? remote.
--   * Automatic rebuild fallback using SlimePreviewBuilder if the server visual
--     was not present (or removed by another system).
--   * Hex color decoding (BodyColor / AccentColor / EyeColor) if those attributes
--     are stored as strings (e.g., from serializer / capture service).
--
-- Safe Animation Explanation:
--   We DO NOT rotate the welded handle or constantly Pivot the model while welded.
--   If animation is enabled, we detach ONLY the primary part weld (client-side) and
--   manually set its CFrame each frame. The part is Massless & CanCollide=false so
--   no torque / physics feedback hits the Humanoid.
--
-- If you observe any odd player motion, keep EnableAnimation = false or comment
-- out startAnimation().
--
-- Dependencies (optional):
--   ReplicatedStorage.Modules.SlimePreviewBuilder (only used if SlimeVisual missing)
--
-- Place this LocalScript inside the CapturedSlimeTool template so every cloned tool
-- inherits it automatically.
--

----------------------------------------------------------------
-- SERVICES / CONTEXT
----------------------------------------------------------------
local Tool             = script.Parent
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players          = game:GetService("Players")
local ReplicatedStorage= game:GetService("ReplicatedStorage")
local Player           = Players.LocalPlayer

----------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------
local CONFIG = {
	EnableAnimation          = false,    -- Safe bob/spin off by default
	SpinDegreesPerSecond     = 28,
	BobHeight                = 0.35,
	BobCyclesPerSecond       = 1.15,

	ShowFloatingTag          = true,
	TagYOffset               = 2.8,
	TagWidth                 = 190,
	TagHeight                = 50,
	TagColor                 = Color3.fromRGB(255,255,255),
	TagStrokeColor           = Color3.fromRGB(20,20,20),

	ShowGrowthInTag          = true,
	ShowRarityInTag          = true,

	HandleInvisible          = true,
	ForceNoCollide           = true,
	ForceMassless            = true,

	-- Release hotkey (stub only; remote must exist manually)
	ReleaseHotkeyEnabled     = false,
	ReleaseHotkey            = Enum.KeyCode.R,
	ReleaseRemoteName        = "SlimeReleaseRequest",

	-- Fallback build if server forgot / removed SlimeVisual
	EnablePreviewFallback    = true,

	-- If using fallback preview, attempt to rebuild every X seconds while equipped if still missing
	PreviewRecheckInterval   = 4.0,

	-- When animation is enabled we detach the primary weld (client-only) for safe transform
	DetachPrimaryForAnimation= true,

	Debug                    = false,
}

----------------------------------------------------------------
-- INTERNAL STATE
----------------------------------------------------------------
local visualModel            -- Model "SlimeVisual" (server provided)
local visualPrimary          -- Primary part of visual
local animationConn
local equipped = false
local startTime = 0
local tagBillboard
local recheckThread
local detachedOnce = false

----------------------------------------------------------------
-- OPTIONAL DEPENDENCY (preview fallback)
----------------------------------------------------------------
local SlimePreviewBuilder
do
	local ok,mod = pcall(function()
		return require(ReplicatedStorage:FindFirstChild("Modules") and ReplicatedStorage.Modules:FindFirstChild("SlimePreviewBuilder"))
	end)
	if ok then SlimePreviewBuilder = mod end
end

----------------------------------------------------------------
-- UTIL
----------------------------------------------------------------
local function dprint(...)
	if CONFIG.Debug then
		print("[ClientSlimeTool]", ...)
	end
end

local function hexToColor(hex)
	if typeof(hex)=="Color3" then return hex end
	if type(hex)~="string" then return nil end
	hex = hex:gsub("^#","")
	if #hex < 6 then return nil end
	local r = tonumber(hex:sub(1,2),16)
	local g = tonumber(hex:sub(3,4),16)
	local b = tonumber(hex:sub(5,6),16)
	if not r or not g or not b then return nil end
	return Color3.fromRGB(r,g,b)
end

local function findPrimary(model)
	if model.PrimaryPart then return model.PrimaryPart end
	for _,c in ipairs(model:GetChildren()) do
		if c:IsA("BasePart") then
			model.PrimaryPart = c
			return c
		end
	end
	return nil
end

local function findSlimeVisual()
	if visualModel and visualModel.Parent == Tool then return visualModel end
	visualModel = Tool:FindFirstChild("SlimeVisual")
	if visualModel and visualModel:IsA("Model") then
		visualPrimary = findPrimary(visualModel)
	end
	return visualModel
end

local function applyHexColorsToVisual()
	local vis = findSlimeVisual()
	if not vis then return end
	local bodyHex = Tool:GetAttribute("BodyColor")
	local accentHex = Tool:GetAttribute("AccentColor")
	local eyeHex = Tool:GetAttribute("EyeColor")

	local bodyC = hexToColor(bodyHex)
	local accentC = hexToColor(accentHex)
	local eyeC = hexToColor(eyeHex)

	-- Simple coloring: body color for all, eye color for eye parts.
	for _,p in ipairs(vis:GetDescendants()) do
		if p:IsA("BasePart") then
			local lname = p.Name:lower()
			if eyeC and (lname:find("eye") or lname:find("pupil")) then
				p.Color = eyeC
			elseif bodyC then
				p.Color = bodyC
			elseif accentC then
				-- accent fallback if body missing
				p.Color = accentC
			end
			p.CanCollide = false
			p.CanTouch   = false
			p.CanQuery   = false
			p.Massless   = true
		end
	end
end

local function sanitizeParts()
	-- Handle
	local handle = Tool:FindFirstChild("Handle")
	if handle then
		if CONFIG.HandleInvisible then
			handle.LocalTransparencyModifier = 1
		end
		if CONFIG.ForceNoCollide then
			handle.CanCollide = false
			handle.CanTouch   = false
			handle.CanQuery   = false
		end
		if CONFIG.ForceMassless then
			handle.Massless = true
		end
	end
	-- Visual
	local vis = findSlimeVisual()
	if vis then
		applyHexColorsToVisual()
	else
		dprint("No server SlimeVisual present.")
	end
end

----------------------------------------------------------------
-- FLOATING TAG
----------------------------------------------------------------
local function destroyTag()
	if tagBillboard then
		tagBillboard:Destroy()
		tagBillboard = nil
	end
end

local function ensureTag()
	if not CONFIG.ShowFloatingTag then
		destroyTag()
		return
	end
	if tagBillboard and tagBillboard.Parent then return tagBillboard end
	local handle = Tool:FindFirstChild("Handle")
	if not handle then return nil end

	tagBillboard = Instance.new("BillboardGui")
	tagBillboard.Name = "SlimeToolInfo"
	tagBillboard.Adornee = handle
	tagBillboard.AlwaysOnTop = true
	tagBillboard.Size = UDim2.fromOffset(CONFIG.TagWidth, CONFIG.TagHeight)
	tagBillboard.StudsOffset = Vector3.new(0, CONFIG.TagYOffset, 0)
	tagBillboard.MaxDistance = 180
	tagBillboard.Parent = Tool

	local bg = Instance.new("Frame")
	bg.Name = "BG"
	bg.BackgroundColor3 = Color3.fromRGB(10,10,10)
	bg.BackgroundTransparency = 0.35
	bg.BorderSizePixel = 0
	bg.Size = UDim2.fromScale(1,1)
	bg.Parent = tagBillboard

	local uiCorner = Instance.new("UICorner")
	uiCorner.CornerRadius = UDim.new(0,8)
	uiCorner.Parent = bg

	local textLabel = Instance.new("TextLabel")
	textLabel.Name = "Label"
	textLabel.BackgroundTransparency = 1
	textLabel.Size = UDim2.fromScale(1,1)
	textLabel.Font = Enum.Font.GothamMedium
	textLabel.TextScaled = true
	textLabel.TextColor3 = CONFIG.TagColor
	textLabel.TextStrokeTransparency = 0.15
	textLabel.TextStrokeColor3 = CONFIG.TagStrokeColor
	textLabel.Parent = bg

	return tagBillboard
end

local function updateTag()
	if not tagBillboard then return end
	local label = tagBillboard:FindFirstChild("BG") and tagBillboard.BG:FindFirstChild("Label")
	if not label then return end
	local weight = Tool:GetAttribute("WeightPounds")
	local currentValue = Tool:GetAttribute("CurrentValue")
	local rarity = CONFIG.ShowRarityInTag and Tool:GetAttribute("Rarity") or nil
	local gp = Tool:GetAttribute("GrowthProgress")
	local growthStr = (CONFIG.ShowGrowthInTag and gp) and string.format("G:%.0f%%", math.clamp(gp*100,0,999)) or nil

	local pieces = {}
	if rarity then table.insert(pieces, tostring(rarity)) end
	if weight then table.insert(pieces, string.format("%.1flb", weight)) end
	if currentValue then table.insert(pieces, "V:"..currentValue) end
	if growthStr then table.insert(pieces, growthStr) end
	if #pieces == 0 then
		label.Text = Tool.Name
	else
		label.Text = table.concat(pieces, "  |  ")
	end
end

----------------------------------------------------------------
-- ANIMATION
----------------------------------------------------------------
local originalWeldDestroyed = false

local function detachPrimaryForAnimation()
	if not CONFIG.EnableAnimation or not CONFIG.DetachPrimaryForAnimation then return end
	if detachedOnce then return end
	local handle = Tool:FindFirstChild("Handle")
	local vis = findSlimeVisual()
	if not (handle and vis and visualPrimary) then return end

	-- Destroy weld constraints linking primary to handle (visual only on client)
	for _,w in ipairs(visualPrimary:GetChildren()) do
		if w:IsA("WeldConstraint") or w:IsA("Weld") then
			if (w.Part0 == handle or w.Part1 == handle) or (w.Part0 == visualPrimary or w.Part1 == visualPrimary) then
				w:Destroy()
				originalWeldDestroyed = true
			end
		end
	end
	visualPrimary.Massless = true
	visualPrimary.CanCollide = false
	detachedOnce = true
end

local function startAnimation()
	if animationConn then animationConn:Disconnect() end
	if not CONFIG.EnableAnimation then return end
	local handle = Tool:FindFirstChild("Handle")
	if not handle then return end
	if not findSlimeVisual() then return end
	if not visualPrimary then return end

	detachPrimaryForAnimation()
	startTime = tick()
	local relativeCF = handle.CFrame:ToObjectSpace(visualPrimary.CFrame)

	animationConn = RunService.RenderStepped:Connect(function()
		if not equipped or not visualPrimary or not handle.Parent then return end
		local t = tick() - startTime
		local bob = math.sin(t * math.pi * 2 * CONFIG.BobCyclesPerSecond) * CONFIG.BobHeight
		local spin = math.rad(CONFIG.SpinDegreesPerSecond) * t
		local cf = handle.CFrame * relativeCF * CFrame.new(0,bob,0) * CFrame.Angles(0, spin, 0)
		visualPrimary.CFrame = cf
	end)
end

local function stopAnimation()
	if animationConn then
		animationConn:Disconnect()
		animationConn = nil
	end
end

----------------------------------------------------------------
-- PREVIEW FALLBACK
----------------------------------------------------------------
-- Client-side tool preservation check
local function _clientPreserveTool(tool)
	if not tool then return false end
	local ok, isTool = pcall(function() return tool:IsA("Tool") end)
	if not ok or not isTool then return false end

	if tool:GetAttribute("ServerIssued") then return true end
	if tool:GetAttribute("ServerRestore") then return true end
	if tool:GetAttribute("PreserveOnClient") then return true end
	if tool:GetAttribute("SlimeId") then return true end
	if tool:GetAttribute("ToolUniqueId") then return true end
	return false
end

-- Example usage: avoid rebuilding/falling-back over a server-restored visual
local function buildPreviewFallback()
	if not CONFIG.EnablePreviewFallback or not SlimePreviewBuilder then return end
	if findSlimeVisual() then return end
	-- If the tool is server-restored, avoid aggressive rebuild/replacement
	if _clientPreserveTool(Tool) then
		dprint("Preserving server-restored captured slime tool; skipping fallback preview.")
		return
	end
	dprint("Building fallback preview (no SlimeVisual found).")
	local preview = SlimePreviewBuilder.BuildFromTool(Tool)
	if not preview then
		dprint("Preview builder returned nil.")
		return
	end
	preview.Name = "SlimeVisual"
	preview.Parent = Tool
	visualModel = preview
	visualPrimary = findPrimary(preview)
	sanitizeParts()
end

local function startPreviewRecheck()
	if recheckThread then return end
	if CONFIG.PreviewRecheckInterval <= 0 then return end
	recheckThread = task.spawn(function()
		while equipped do
			task.wait(CONFIG.PreviewRecheckInterval)
			if equipped and not findSlimeVisual() then
				buildPreviewFallback()
			end
		end
	end)
end

----------------------------------------------------------------
-- RELEASE HOTKEY
----------------------------------------------------------------
local function tryRelease()
	if not CONFIG.ReleaseHotkeyEnabled then return end
	local remFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not remFolder then return end
	local remote = remFolder:FindFirstChild(CONFIG.ReleaseRemoteName)
	if remote and remote:IsA("RemoteEvent") then
		remote:FireServer(Tool)
	end
end

----------------------------------------------------------------
-- EQUIP / UNEQUIP
----------------------------------------------------------------
Tool.Equipped:Connect(function()
	equipped = true
	sanitizeParts()
	buildPreviewFallback()
	ensureTag()
	updateTag()
	startAnimation()
	startPreviewRecheck()
end)

Tool.Unequipped:Connect(function()
	equipped = false
	stopAnimation()
	destroyTag()
end)

-- Already in character on join (rare)
if Tool.Parent == Player.Character then
	task.defer(function()
		if not equipped then
			Tool.Equipped:Wait()
		end
	end)
end

----------------------------------------------------------------
-- ATTRIBUTE CHANGE LISTENERS
----------------------------------------------------------------
local watchedAttrs = {
	"WeightPounds","CurrentValue","GrowthProgress","Rarity",
	"BodyColor","AccentColor","EyeColor","CurrentSizeScale","StartSizeScale","MaxSizeScale"
}
for _,a in ipairs(watchedAttrs) do
	Tool:GetAttributeChangedSignal(a):Connect(function()
		updateTag()
		if a=="BodyColor" or a=="AccentColor" or a=="EyeColor" then
			applyHexColorsToVisual()
		end
	end)
end

----------------------------------------------------------------
-- INPUT
----------------------------------------------------------------
UserInputService.InputBegan:Connect(function(input, gp)
	if gp or not equipped then return end
	if CONFIG.ReleaseHotkeyEnabled and input.KeyCode == CONFIG.ReleaseHotkey then
		tryRelease()
	end
end)

----------------------------------------------------------------
-- INIT (in case created while already equipped)
----------------------------------------------------------------
sanitizeParts()
applyHexColorsToVisual()
if equipped then
	ensureTag()
	updateTag()
end

dprint("ClientSlimeTool initialized (animation="..tostring(CONFIG.EnableAnimation)..", previewFallback="..tostring(CONFIG.EnablePreviewFallback)..")")