-- Early startup shim: ensure PlayerProfileService saves won't be rejected for missing coins
-- Usage: require(this module) as early as possible in InitGameServices.

local ServerScriptService = game:GetService("ServerScriptService")
local ModulesRoot = ServerScriptService:WaitForChild("Modules")

local ok, PlayerProfileService = pcall(function() return require(ModulesRoot:WaitForChild("PlayerProfileService")) end)
if not ok or not PlayerProfileService then
	warn("[PPSWrap] PlayerProfileService not available at wrapper init; skipping wrapper")
	return {}
end

local function safeGetProfile(userId)
	local ok, p = pcall(function() return PlayerProfileService.GetProfile and PlayerProfileService.GetProfile(userId) end)
	if ok then return p end
	return nil
end

local function ensureCoinsOnProfile(userId, maybeProfile)
	-- prefer supplied profile (if table) else try to fetch canonical profile
	local prof = maybeProfile
	if (not prof) or type(prof) ~= "table" then
		prof = safeGetProfile(userId) or prof
	end
	if not prof then return end
	-- if profile.core.coins missing/zero, fetch authoritative coins and restore
	local cur = nil
	pcall(function() cur = (prof.core and prof.core.coins) end)
	if not cur or type(cur) ~= "number" or cur == 0 then
		local okc, authoritative = pcall(function()
			return PlayerProfileService.GetCoins and PlayerProfileService.GetCoins(userId)
		end)
		if okc and type(authoritative) == "number" and authoritative > 0 then
			prof.core = prof.core or {}
			prof.core.coins = authoritative
			-- attempt SetCoins (best-effort)
			pcall(function() if PlayerProfileService.SetCoins then PlayerProfileService.SetCoins(userId, authoritative) end end)
			-- record diagnostic marker for auditing
			pcall(function()
				prof.meta = prof.meta or {}
				prof.meta.__coinsRestoredByWrapper = { ts = os.time(), coins = authoritative }
			end)
		end
	end
end

-- Wrap ForceFullSaveNow (if present)
if type(PlayerProfileService.ForceFullSaveNow) == "function" then
	local _orig = PlayerProfileService.ForceFullSaveNow
	PlayerProfileService.ForceFullSaveNow = function(userOrPlayer, reason)
		-- attempt to normalize userId
		local uid = nil
		if type(userOrPlayer) == "number" then uid = userOrPlayer
		elseif type(userOrPlayer) == "table" and userOrPlayer.UserId then uid = userOrPlayer.UserId
		elseif type(userOrPlayer) == "string" then uid = tonumber(userOrPlayer) end

		-- ensure coins on canonical profile before forcing save
		if uid then
			pcall(function() ensureCoinsOnProfile(uid, nil) end)
		end

		-- Call original
		return _orig(userOrPlayer, reason)
	end
end

-- Wrap SaveNowAndWait (if present)
if type(PlayerProfileService.SaveNowAndWait) == "function" then
	local _orig2 = PlayerProfileService.SaveNowAndWait
	PlayerProfileService.SaveNowAndWait = function(userId, timeout, verified)
		if userId then pcall(function() ensureCoinsOnProfile(userId, nil) end) end
		return _orig2(userId, timeout, verified)
	end
end

-- Wrap SaveNow (async) — best-effort
if type(PlayerProfileService.SaveNow) == "function" then
	local _orig3 = PlayerProfileService.SaveNow
	PlayerProfileService.SaveNow = function(userOrPlayer, reason)
		local uid = nil
		if type(userOrPlayer) == "number" then uid = userOrPlayer
		elseif type(userOrPlayer) == "table" and userOrPlayer.UserId then uid = userOrPlayer.UserId
		elseif type(userOrPlayer) == "string" then uid = tonumber(userOrPlayer) end
		if uid then pcall(function() ensureCoinsOnProfile(uid, nil) end) end
		return _orig3(userOrPlayer, reason)
	end
end

return {
	wrapped = true
}