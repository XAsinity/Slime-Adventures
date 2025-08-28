-- LeaderstatsSetup.lua
-- Creates leaderstats folder if missing. Syncs coin value from PlayerProfileService.

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local PlayerProfileService = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("PlayerProfileService"))

local STARTING_COINS = 500  -- Only used if coin value not yet set by PlayerProfileService for new players.

Players.PlayerAdded:Connect(function(player)
	local ls = player:FindFirstChild("leaderstats")
	if not ls then
		ls = Instance.new("Folder")
		ls.Name = "leaderstats"
		ls.Parent = player
	end

	local coins = ls:FindFirstChild("Coins")
	if not coins then
		coins = Instance.new("IntValue")
		coins.Name = "Coins"
		coins.Parent = ls
	end

	-- Sync coins from PlayerProfileService
	local profile = PlayerProfileService.GetProfile(player)
	local coinValue = (profile and profile.core and type(profile.core.coins) == "number") and profile.core.coins or nil
	if coinValue and coinValue > 0 then
		coins.Value = coinValue
	else
		coins.Value = STARTING_COINS
		PlayerProfileService.SetCoins(player, STARTING_COINS)
		PlayerProfileService.SaveNow(player, "LeaderstatsSetup")
	end

	-- Listen for coin changes and update leaderstats
	player:GetAttributeChangedSignal("CoinsStored"):Connect(function()
		local updated = player:GetAttribute("CoinsStored")
		if type(updated) == "number" then
			coins.Value = updated
		end
	end)

	-- Always update leaderstats on join
	ls = player:FindFirstChild("leaderstats")
	if ls then
		local coins = ls:FindFirstChild("Coins")
		if coins then
			coins.Value = PlayerProfileService.GetCoins(player)
		end
	end
end)