-- LeaderstatsSetup.lua
-- Robust leaderstats initialization and sync with PlayerProfileService.
-- - Waits for profile availability (bounded) to avoid races.
-- - Syncs leaderstats from authoritative profile; does not overwrite existing profile coin values.
-- - Sets STARTING_COINS only if profile truly lacks the coin field (nil).
-- - Updates leaderstats immediately when the CoinsStored attribute changes.
-- - Uses PlayerProfileService API safely (pcall) and passes player/userId (no profile table SaveNow calls).
-----------------------------------------------------------------------

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

local PlayerProfileService = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("PlayerProfileService"))

local STARTING_COINS = 500  -- Used only if profile.core.coins is nil (profile missing the field)

local function safeWaitForProfile(player, timeout)
	if type(PlayerProfileService.WaitForProfile) == "function" then
		local ok, prof = pcall(function() return PlayerProfileService.WaitForProfile(player, timeout) end)
		if ok and type(prof) == "table" then
			return prof
		end
	end
	-- Try a direct GetProfile as a last-ditch (non-blocking)
	local ok2, prof2 = pcall(function() return PlayerProfileService.GetProfile(player) end)
	if ok2 and type(prof2) == "table" then
		return prof2
	end
	return nil
end

local function syncLeaderstatsFromProfile(player, profile, createIfMissing)
	if not player or not player.Parent then return end
	createIfMissing = createIfMissing ~= false

	-- Ensure leaderstats folder + Coins IntValue exist
	local ls = player:FindFirstChild("leaderstats")
	if not ls and createIfMissing then
		ls = Instance.new("Folder")
		ls.Name = "leaderstats"
		ls.Parent = player
	end
	if not ls then return end

	local coinsVal = ls:FindFirstChild("Coins")
	if not coinsVal and createIfMissing then
		coinsVal = Instance.new("IntValue")
		coinsVal.Name = "Coins"
		coinsVal.Parent = ls
	end
	if not coinsVal then return end

	-- Determine authoritative coin value from profile when available
	local coinValue = nil
	if type(profile) == "table" and profile.core and type(profile.core.coins) == "number" then
		coinValue = profile.core.coins
	end

	-- If profile exists but the coins field is nil (profile missing coin field),
	-- initialize it with STARTING_COINS and persist that via PlayerProfileService.SetCoins + SaveNow.
	if profile and type(profile) == "table" and profile.core and profile.core.coins == nil then
		coinValue = STARTING_COINS
		-- Update authoritative profile and persist (non-blocking SaveNow)
		pcall(function()
			PlayerProfileService.SetCoins(player, coinValue)
			PlayerProfileService.SaveNow(player, "LeaderstatsSetup_InitialGrant")
		end)
	end

	-- If no profile or coinValue still nil, fall back to 0 (do not overwrite profile)
	if coinValue == nil then coinValue = 0 end

	-- Apply to leaderstats and attribute (CoinsStored is the cross-service bridge)
	coinsVal.Value = coinValue
	pcall(function() player:SetAttribute("CoinsStored", coinValue) end)
end

local function onProfileReady(userId, profile)
	-- profile-ready event may fire before/after PlayerAdded; update leaderstats for matching player
	local uid = tonumber(userId) or userId
	local ply = Players:GetPlayerByUserId(tonumber(uid) or -1)
	if not ply then
		-- Defensive: sometimes ProfileReady uses player name; try to find by name
		if type(userId) == "string" then
			ply = Players:FindFirstChild(userId)
		end
	end
	if ply and profile then
		-- Sync leaderstats from profile (do not create new leaderstats if none exist)
		syncLeaderstatsFromProfile(ply, profile, true)
	end
end

Players.PlayerAdded:Connect(function(player)
	-- Ensure leaderstats structure exists immediately so UI scripts referencing it don't error.
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

	-- If a coins attribute already exists on the player (persisted by CoreStatsService or others), use it.
	local attrVal = player:GetAttribute("CoinsStored")
	if type(attrVal) == "number" then
		coins.Value = attrVal
	end

	-- Attempt to wait briefly for the profile so we can populate leaderstats from authoritative profile data.
	task.spawn(function()
		-- Short bounded wait to reduce startup race windows.
		local profile = safeWaitForProfile(player, 3)
		if profile then
			syncLeaderstatsFromProfile(player, profile, true)
		else
			-- If profile not available within the window, leave leaderstats at attribute/default and rely on ProfileReady event.
			-- Also set attribute to whatever PlayerProfileService.GetCoins returns if available (best-effort).
			local ok, gv = pcall(function() return PlayerProfileService.GetCoins(player) end)
			if ok and type(gv) == "number" then
				coins.Value = gv
				pcall(function() player:SetAttribute("CoinsStored", gv) end)
			end
		end
	end)

	-- React to CoinsStored attribute changes to keep leaderstats in sync.
	-- Many systems will SetAttribute("CoinsStored", value) on changes; reflect that immediately.
	local attrConn
	attrConn = player:GetAttributeChangedSignal("CoinsStored"):Connect(function()
		if not player or not player.Parent then
			if attrConn and attrConn.Connected then pcall(function() attrConn:Disconnect() end) end
			return
		end
		local updated = player:GetAttribute("CoinsStored")
		if type(updated) == "number" then
			local ls2 = player:FindFirstChild("leaderstats")
			if ls2 then
				local coins2 = ls2:FindFirstChild("Coins")
				if coins2 then coins2.Value = updated end
			end
		end
	end)
end)

-- Listen to PlayerProfileService.ProfileReady to update leaderstats when profiles finish loading.
if PlayerProfileService and PlayerProfileService.ProfileReady and type(PlayerProfileService.ProfileReady.Connect) == "function" then
	pcall(function()
		PlayerProfileService.ProfileReady:Connect(onProfileReady)
	end)
end