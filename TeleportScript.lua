-- HomeAndShopTeleport.client.lua
-- Version: no (practical) cooldown – teleport can be spammed.
-- Place this LocalScript under the HomeandShop ScreenGui.
-- Buttons: "Home" (ImageButton/TextButton), "Shop".
--
-- Plot system (from PlotManager):
--   Plots named Player1..Player6 (adjust MAX_PLOT_INDEX if needed).
--   Each plot has attributes: Occupied (bool), UserId (number), Index (number).
--   Player gets attribute "PlotIndex" when assigned.
--
-- Teleport now uses TELEPORT_COOLDOWN = 0 (and an additional micro throttle constant you can tweak).
-- If you actually want a tiny delay (e.g. 20 ms) set MICRO_THROTTLE to that value in seconds.

local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")

local player  = Players.LocalPlayer
local gui     = script.Parent
local homeBtn = gui:WaitForChild("Home")
local shopBtn = gui:WaitForChild("Shop")

---------------------------------------------------------------------
-- Config
---------------------------------------------------------------------
local SHOP_PART_NAME        = "ShopTeleport"
local HOME_Y_OFFSET         = 3

local TELEPORT_COOLDOWN     = 0          -- removed practical cooldown
local MICRO_THROTTLE        = 0          -- set to e.g. 0.02 for 20ms min spacing if desired

local MAX_PLOT_INDEX        = 6
local PLOT_NAME_PREFIX      = "Player"
local SPAWN_PART_NAME       = "Spawn"
local PLOT_SEARCH_TIMEOUT   = 5
local DEBUG                 = false

---------------------------------------------------------------------
-- Internal state
---------------------------------------------------------------------
local lastTeleport = 0
local cachedPlot   = nil
local cachedSpawn  = nil

local function dprint(...)
	if DEBUG then
		print("[HomeAndShopTeleport]", ...)
	end
end

---------------------------------------------------------------------
-- Character helpers
---------------------------------------------------------------------
local function getCharacter()
	return player.Character or player.CharacterAdded:Wait()
end

local function getHRP()
	local char = getCharacter()
	return char:FindFirstChild("HumanoidRootPart")
end

---------------------------------------------------------------------
-- Plot resolution (matching server PlotManager)
---------------------------------------------------------------------
local function isPlayerPlotModel(model)
	return model
		and model:IsA("Model")
		and model.Name:match("^" .. PLOT_NAME_PREFIX .. "%d+$")
end

local function findSpawnPartInPlot(plotModel)
	if not plotModel then return nil end
	local spawn = plotModel:FindFirstChild(SPAWN_PART_NAME)
	if spawn and spawn:IsA("BasePart") then return spawn end
	for _,desc in ipairs(plotModel:GetDescendants()) do
		if desc:IsA("BasePart") then
			return desc
		end
	end
	return nil
end

local function scanForOwnedPlot()
	for _,child in ipairs(workspace:GetChildren()) do
		if isPlayerPlotModel(child) and child:GetAttribute("UserId") == player.UserId then
			return child
		end
	end
	return nil
end

local function plotByIndex(index)
	if not index or index < 1 or index > MAX_PLOT_INDEX then return nil end
	local model = workspace:FindFirstChild(PLOT_NAME_PREFIX..index)
	if model and isPlayerPlotModel(model) then
		return model
	end
	return nil
end

local function resolvePlayerPlot(waitIfNeeded)
	if cachedPlot and cachedPlot.Parent and cachedPlot:GetAttribute("UserId") == player.UserId then
		return cachedPlot
	end

	local plot = scanForOwnedPlot()
	if plot then
		cachedPlot = plot
		return plot
	end

	local plotIndex = player:GetAttribute("PlotIndex")
	if plotIndex then
		plot = plotByIndex(plotIndex)
		if plot and plot:GetAttribute("UserId") == player.UserId then
			cachedPlot = plot
			return plot
		end
	end

	if waitIfNeeded then
		local start = tick()
		while tick() - start < PLOT_SEARCH_TIMEOUT do
			task.wait(0.15)
			plot = scanForOwnedPlot()
			if plot then
				cachedPlot = plot
				return plot
			end
			plotIndex = player:GetAttribute("PlotIndex")
			if plotIndex then
				local idxPlot = plotByIndex(plotIndex)
				if idxPlot and idxPlot:GetAttribute("UserId") == player.UserId then
					cachedPlot = idxPlot
					return idxPlot
				end
			end
		end
	end

	return nil
end

local function resolveHomeSpawn(waitIfNeeded)
	if cachedSpawn and cachedSpawn.Parent and cachedPlot and cachedPlot.Parent then
		return cachedSpawn
	end
	local plot = resolvePlayerPlot(waitIfNeeded)
	if not plot then return nil end
	local spawnPart = findSpawnPartInPlot(plot)
	if spawnPart then
		cachedSpawn = spawnPart
	end
	return spawnPart
end

local function resolveShopPart()
	local part = workspace:FindFirstChild(SHOP_PART_NAME)
	return (part and part:IsA("BasePart")) and part or nil
end

---------------------------------------------------------------------
-- Teleport (no cooldown)
---------------------------------------------------------------------
local function canTeleport()
	-- Only micro throttle if desired
	return (time() - lastTeleport) >= MICRO_THROTTLE
end

local function doTeleport(part)
	if not part then return end
	if not canTeleport() then return end
	local hrp = getHRP()
	if not hrp then return end
	lastTeleport = time()
	local dest = part.CFrame + Vector3.new(0, HOME_Y_OFFSET, 0)
	-- Preserve facing; remove second arg to face spawn direction instead.
	hrp.CFrame = CFrame.new(dest.Position, dest.Position + hrp.CFrame.LookVector)
end

---------------------------------------------------------------------
-- UI feedback
---------------------------------------------------------------------
local function flash(button)
	local orig = button.BackgroundTransparency
	button.BackgroundTransparency = 0.35
	task.delay(0.08, function()
		if button then
			button.BackgroundTransparency = orig
		end
	end)
end

---------------------------------------------------------------------
-- Button handlers
---------------------------------------------------------------------
homeBtn.MouseButton1Click:Connect(function()
	flash(homeBtn)
	local spawnPart = resolveHomeSpawn(true)
	if not spawnPart then
		warn("[HomeAndShopTeleport] Could not locate your home spawn.")
		return
	end
	doTeleport(spawnPart)
end)

shopBtn.MouseButton1Click:Connect(function()
	flash(shopBtn)
	local shopPart = resolveShopPart()
	if not shopPart then
		warn("[HomeAndShopTeleport] '"..SHOP_PART_NAME.."' not found.")
		return
	end
	doTeleport(shopPart)
end)

---------------------------------------------------------------------
-- Update cache when PlotIndex appears
---------------------------------------------------------------------
player.AttributeChanged:Connect(function(attr)
	if attr == "PlotIndex" then
		resolveHomeSpawn(false)
	end
end)

player.CharacterAdded:Connect(function()
	-- Keep plot cache, clear spawn (if spawn might move per reset)
	cachedSpawn = nil
end)