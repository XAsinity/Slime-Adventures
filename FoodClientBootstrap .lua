-- LocalScript: FoodClientBootstrap
-- Minimal bootstrap that gets cloned into a Tool by server-side FoodService.
-- It requires the FoodClient module above and attaches it to script.Parent (the Tool).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local localPlayer = Players.LocalPlayer
if not localPlayer then return end

local modulesFolder = ReplicatedStorage:WaitForChild("Modules")

local ok, FoodClient = pcall(function() return require(modulesFolder:WaitForChild("FoodClient")) end)
if not ok or not FoodClient then
	warn("[FoodClientBootstrap] failed to require FoodClient module.")
	return
end

local TOOL = script.Parent
while not TOOL or not TOOL:IsA("Tool") do
	task.wait(0.05)
	TOOL = script.Parent
end

pcall(function()
	FoodClient.Attach(TOOL)
end)

if TOOL and TOOL.Name then
	print("[FoodClientBootstrap] initialized for tool:", TOOL.Name)
end