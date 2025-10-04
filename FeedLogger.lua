local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local FeedRemote = Remotes:WaitForChild("FeedSlime")
local FeedResultRemote = Remotes:WaitForChild("FeedResult")

local Modules = ServerScriptService:WaitForChild("Modules")
local FoodServiceModule = Modules:WaitForChild("FoodService")

local okRequire, FoodService = pcall(require, FoodServiceModule)
if not okRequire then
	warn("[FeedRemoteHandler] Failed to require FoodService:", FoodService)
	return
end

local DEBUG = true
local function log(...)
	if DEBUG then
		print("[FeedRemoteHandler]", ...)
	end
end

local function respond(player, payload)
	local ok, err = pcall(function()
		FeedResultRemote:FireClient(player, payload)
	end)
	if not ok then
		warn("[FeedRemoteHandler] Failed to send FeedResult:", err)
	end
end

local function resolveSlime(slimeArg)
	if typeof(slimeArg) == "Instance" and slimeArg:IsA("Model") and slimeArg.Name == "Slime" then
		return slimeArg
	end
	return nil
end

local function resolveTool(player, toolArg, toolUid)
	if typeof(toolArg) == "Instance" and toolArg:IsA("Tool") then
		return toolArg
	end
	if toolUid and FoodService.FindToolForPlayerById then
		local ok, found = pcall(FoodService.FindToolForPlayerById, player, toolUid)
		if ok and found then
			return found
		end
	end
	return nil
end

FeedRemote.OnServerEvent:Connect(function(player, slimeArg, toolArg, toolUid)
	log("FeedSlime from", player.Name)
	local slime = resolveSlime(slimeArg)
	if not slime then
		respond(player, { success = false, message = "Invalid slime target" })
		return
	end

	local tool = resolveTool(player, toolArg, toolUid)
	if not tool then
		respond(player, { success = false, message = "No valid food tool" })
		return
	end

	local okCall, success, detailsOrReason = pcall(FoodService.HandleFeed, player, slime, tool)
	if not okCall then
		warn("[FeedRemoteHandler] Error during HandleFeed:", success)
		respond(player, {
			success = false,
			message = "Server error",
			error = tostring(success),
		})
		return
	end

	if success then
		local payload = {
			success = true,
			message = "Fed slime",
			details = detailsOrReason,
		}
		respond(player, payload)
	else
		respond(player, {
			success = false,
			message = tostring(detailsOrReason or "Feed failed"),
		})
	end
end)