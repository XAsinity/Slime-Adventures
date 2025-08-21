-- FoodRemoteHandler: bridges FeedSlime RemoteEvent to FoodService
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FoodService = require(game.ServerScriptService.Modules.FoodService)

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local feedEvent = remotesFolder:WaitForChild("FeedSlime")

feedEvent.OnServerEvent:Connect(function(player, slime, tool)
	local ok, err = FoodService.HandleFeed(player, slime, tool)
	if not ok then
		-- Optional: send feedback to player with another remote or attribute
		-- print("[FoodRemoteHandler] Feed failed:", err)
	end
end)