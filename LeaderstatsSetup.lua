-- LeaderstatsSetup.lua
-- Creates leaderstats folder if missing. Does NOT overwrite coins if already managed.
-- PlayerDataService will sync its stored coin value into this IntValue when it initializes.
-- If PlayerDataService loads after this script, it will adopt the starting value you set here
-- for a brand-new profile (then persist it). Adjust STARTING_COINS as needed.

local Players = game:GetService("Players")

local STARTING_COINS = 500  -- Only used if coin value not yet set by PlayerDataService for new players.

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

	-- If PlayerDataService hasn't populated coins yet (attribute "CoinsStored" not present),
	-- give starting amount. PlayerDataService will later read & store it.
	if player:GetAttribute("CoinsStored") == nil and coins.Value == 0 then
		coins.Value = STARTING_COINS
	end
end)