-- Place this in StarterPlayerScripts (LocalScript)
-- Simple UI: press M to request a mutation on the nearest slime within 40 studs.
-- It finds the nearest Slime model (must have a BasePart PrimaryPart or PrimaryPart-like part),
-- then fires Remotes.RequestMutation with desired mutation type (Color, Physical, Size).
-- This script won't mutate directly — it requests the server to run the mutation.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local LOCAL_PLAYER = Players.LocalPlayer
local MAX_RANGE = 40

-- find remotes folder (do not block indefinitely)
local remotes = ReplicatedStorage:FindFirstChild("Remotes") or ReplicatedStorage:FindFirstChild("Events")
if not remotes then
	remotes = ReplicatedStorage:WaitForChild("Remotes", 3) or ReplicatedStorage:WaitForChild("Events", 3)
end

local requestRemote = remotes and remotes:FindFirstChild("RequestMutation")
if not requestRemote then
	warn("[TriggerMutation] RequestMutation remote not found in ReplicatedStorage.Remotes/Events.")
	return
end

local function findNearestSlime()
	local character = LOCAL_PLAYER.Character or LOCAL_PLAYER.CharacterAdded:Wait()
	local hrp = character:FindFirstChild("HumanoidRootPart") or character:FindFirstChildWhichIsA("BasePart")
	if not hrp then return nil end
	local best, bestDist = nil, math.huge
	for _,inst in ipairs(workspace:GetDescendants()) do
		if inst:IsA("Model") and inst.Name == "Slime" then
			local prim = inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart")
			if prim then
				local dist = (prim.Position - hrp.Position).Magnitude
				if dist < bestDist and dist <= MAX_RANGE then
					best = inst
					bestDist = dist
				end
			end
		end
	end
	return best
end

local function requestMutationForNearest(kind)
	local slime = findNearestSlime()
	if not slime then
		warn("[TriggerMutation] No slime within range ("..tostring(MAX_RANGE).." studs).")
		return
	end
	print(("[TriggerMutation] Requesting %s mutation for slime %s"):format(kind, tostring(slime:GetFullName())))
	requestRemote:FireServer(slime, { forceType = kind })
end

-- Keybinding: M = Color, N = Physical, K = Size
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	local key = input.KeyCode
	if key == Enum.KeyCode.M then
		requestMutationForNearest("Color")
	elseif key == Enum.KeyCode.N then
		requestMutationForNearest("Physical")
	elseif key == Enum.KeyCode.K then
		requestMutationForNearest("Size")
	end
end)

print("[TriggerMutation] Ready. Press M (color), N (physical), K (size) near a slime to request mutation.")