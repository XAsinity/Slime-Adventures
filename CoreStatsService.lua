-- CoinService.lua
-- Centralized coin & faction standing helper (best-effort, server-side)
-- Place under ServerScriptService.Modules or ReplicatedStorage.Modules as appropriate.
-- Exports:
--   CoinService.GetCoins(player)
--   CoinService.IncrementCoins(player, delta)
--   CoinService.TrySpendCoins(player, amount) -> success, reason
--   CoinService.RefundCoins(player, amount)
--   CoinService.ApplySale(player, cost, opts) -> success, reason   (helper wrapper)
--   CoinService.GetFactionStanding(player, faction) -> number or nil
--   CoinService.AdjustFactionStanding(player, faction, delta) -> number or nil
-- Implementation notes:
--  - Prefers PlayerProfileService functions when available (GetCoins/IncrementCoins/SaveNow/GetProfile).
--  - Best-effort: falls back to leaderstats reads/writes for visibility in Studio.
--  - Emits PlayerProfileService.CoinsChanged event when available (keeps other listeners working).
--  - Not strictly transactional across inventory operations — best-effort atomic via TrySpendCoins when underlying PPS exposes TrySpendCoins or IncrementCoins.
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local CoinService = {}
CoinService.__Version = "v1.0.0-centralized"

-- Safe requires / lookups
local function safeRequireModules()
	local modules = nil
	pcall(function()
		modules = ServerScriptService:FindFirstChild("Modules") or ServerScriptService
	end)
	return modules
end

local Modules = safeRequireModules()

-- Try to require PlayerProfileService (best-effort)
local PlayerProfileService = nil
pcall(function()
	if Modules and Modules:FindFirstChild("PlayerProfileService") then
		PlayerProfileService = require(Modules:FindFirstChild("PlayerProfileService"))
	end
end)

-- Utility: read leaderstats coins fallback
local function readLeaderstatsCoins(player)
	if not player then return 0 end
	local ls = player:FindFirstChild("leaderstats")
	if not ls then return 0 end
	local coinNode = ls:FindFirstChild("Coins") or ls:FindFirstChild("coins") or ls:FindFirstChild("CoinsValue")
	if coinNode and (coinNode:IsA("IntValue") or coinNode:IsA("NumberValue")) then
		return tonumber(coinNode.Value) or 0
	end
	return 0
end

-- Utility: write leaderstats coins fallback
local function writeLeaderstatsCoins(player, value)
	if not player then return end
	local ls = player:FindFirstChild("leaderstats")
	if not ls then return end
	local coinNode = ls:FindFirstChild("Coins") or ls:FindFirstChild("coins") or ls:FindFirstChild("CoinsValue")
	if coinNode and (coinNode:IsA("IntValue") or coinNode:IsA("NumberValue")) then
		pcall(function() coinNode.Value = tonumber(value) or 0 end)
	end
end

-- Public: GetCoins(player)
function CoinService.GetCoins(player)
	-- Prefer PlayerProfileService.GetCoins if available
	if PlayerProfileService and type(PlayerProfileService.GetCoins) == "function" then
		local ok, val = pcall(function() return PlayerProfileService.GetCoins(player) end)
		if ok and tonumber(val) then
			return tonumber(val)
		end
	end

	-- Fallback: try profile table (if GetProfile exists)
	if PlayerProfileService and type(PlayerProfileService.GetProfile) == "function" then
		local ok, prof = pcall(function() return PlayerProfileService.GetProfile(player and player.UserId) end)
		if ok and type(prof) == "table" then
			local ok2, c = pcall(function() return prof.core and prof.core.coins end)
			if ok2 and tonumber(c) then return tonumber(c) end
		end
	end

	-- Last-resort: leaderstats read
	return readLeaderstatsCoins(player)
end

-- Internal helper to fire coins-changed event if available
local function fireCoinsChanged(player, newValue)
	if PlayerProfileService and PlayerProfileService.CoinsChanged and type(PlayerProfileService.CoinsChanged) == "table" and type(PlayerProfileService.CoinsChanged.Connect) == "function" then
		-- if it's a BindableEvent.Event, call Fire via Bindable
		local bindable = PlayerProfileService.CoinsChangedBindable or PlayerProfileService.CoinsChanged
		if bindable and type(bindable.Fire) == "function" then
			pcall(function() bindable:Fire(player, newValue) end)
		elseif PlayerProfileService.CoinsChanged and type(PlayerProfileService.CoinsChanged) == "table" and PlayerProfileService.CoinsChanged.Connect then
			-- no-op: consumers use event Connect; we can't Fire an Event directly here
		end
	end
end

-- Public: IncrementCoins(player, delta)
function CoinService.IncrementCoins(player, delta)
	delta = tonumber(delta) or 0
	if delta == 0 then
		local cur = CoinService.GetCoins(player)
		return cur
	end

	-- Prefer PlayerProfileService.IncrementCoins if available
	if PlayerProfileService and type(PlayerProfileService.IncrementCoins) == "function" then
		local ok, res = pcall(function() return PlayerProfileService.IncrementCoins(player, delta) end)
		if ok then
			-- Update leaderstats for visibility if present
			local cur = CoinService.GetCoins(player)
			writeLeaderstatsCoins(player, cur)
			fireCoinsChanged(player, cur)
			return cur
		end
	end

	-- Fallback: profile table adjust if accessible
	if PlayerProfileService and type(PlayerProfileService.GetProfile) == "function" then
		local ok, prof = pcall(function() return PlayerProfileService.GetProfile(player and player.UserId) end)
		if ok and type(prof) == "table" then
			prof.core = prof.core or {}
			prof.core.coins = tonumber(prof.core.coins or 0) + delta
			-- Best-effort persist
			pcall(function() if type(PlayerProfileService.SaveNow) == "function" then PlayerProfileService.SaveNow(player or prof, "CoinIncrement") end end)
			local cur = tonumber(prof.core.coins) or 0
			writeLeaderstatsCoins(player, cur)
			fireCoinsChanged(player, cur)
			return cur
		end
	end

	-- Last-resort: update leaderstats numeric value (non-persistent)
	local cur = readLeaderstatsCoins(player)
	cur = cur + delta
	writeLeaderstatsCoins(player, cur)
	fireCoinsChanged(player, cur)
	return cur
end

-- Public: TrySpendCoins(player, amount)
-- Returns: (true) on success; (false, reason) on failure.
function CoinService.TrySpendCoins(player, amount)
	amount = tonumber(amount) or 0
	if amount <= 0 then return false, "invalid_amount" end

	-- Preferred atomic API on PlayerProfileService
	if PlayerProfileService and type(PlayerProfileService.TrySpendCoins) == "function" then
		local ok, res, reason = pcall(function() return PlayerProfileService.TrySpendCoins(player, amount) end)
		if ok and res == true then
			-- update leaderstats visibility
			local cur = CoinService.GetCoins(player)
			writeLeaderstatsCoins(player, cur)
			fireCoinsChanged(player, cur)
			return true
		elseif ok and res == false then
			return false, reason or "insufficient"
		end
	end

	-- Fallback: read -> decrement -> persist best-effort
	local cur = CoinService.GetCoins(player) or 0
	if cur < amount then
		return false, "insufficient"
	end

	-- Attempt to decrement via IncrementCoins (may not be perfectly atomic)
	local newVal = nil
	if PlayerProfileService and type(PlayerProfileService.IncrementCoins) == "function" then
		local ok, _ = pcall(function() PlayerProfileService.IncrementCoins(player, -amount) end)
		if ok then
			newVal = CoinService.GetCoins(player)
			writeLeaderstatsCoins(player, newVal)
			fireCoinsChanged(player, newVal)
			-- Best-effort SaveNow
			pcall(function() if type(PlayerProfileService.SaveNow) == "function" then PlayerProfileService.SaveNow(player, "SpendCoins") end end)
			return true
		end
	end

	-- Otherwise modify profile table if possible
	if PlayerProfileService and type(PlayerProfileService.GetProfile) == "function" then
		local ok, prof = pcall(function() return PlayerProfileService.GetProfile(player and player.UserId) end)
		if ok and type(prof) == "table" then
			prof.core = prof.core or {}
			local prev = tonumber(prof.core.coins) or CoinService.GetCoins(player)
			if prev < amount then return false, "insufficient" end
			prof.core.coins = prev - amount
			pcall(function() if type(PlayerProfileService.SaveNow) == "function" then PlayerProfileService.SaveNow(player, "SpendCoins_ProfileFallback") end end)
			newVal = tonumber(prof.core.coins) or 0
			writeLeaderstatsCoins(player, newVal)
			fireCoinsChanged(player, newVal)
			return true
		end
	end

	-- Last-resort leaderstats decrement
	local lsCur = readLeaderstatsCoins(player)
	if lsCur < amount then return false, "insufficient" end
	local after = lsCur - amount
	writeLeaderstatsCoins(player, after)
	fireCoinsChanged(player, after)
	return true
end

-- Public: RefundCoins(player, amount)
function CoinService.RefundCoins(player, amount)
	amount = tonumber(amount) or 0
	if amount == 0 then return CoinService.GetCoins(player) end
	-- Use IncrementCoins which already handles persistence best-effort
	local cur = CoinService.IncrementCoins(player, amount)
	return cur
end

-- Public: ApplySale(player, cost, opts)
-- Convenience wrapper used by purchase flows: deducts coins and optionally invokes a callback to persist inventory.
-- opts = { reason = "", save = true, onFailRefund = true }
function CoinService.ApplySale(player, cost, opts)
	opts = opts or {}
	if not player or not player.UserId then return false, "invalid_player" end
	local amount = tonumber(cost) or 0
	if amount <= 0 then return false, "invalid_cost" end

	local ok, reason = CoinService.TrySpendCoins(player, amount)
	if not ok then
		return false, reason or "insufficient"
	end

	-- At this point coins were deducted (best-effort). Caller should grant inventory, then request verified save.
	-- If caller needs to roll back (e.g., grant failed), they should call CoinService.RefundCoins.

	-- Optionally request SaveNow via PlayerProfileService for durability
	if opts.save and PlayerProfileService and type(PlayerProfileService.SaveNow) == "function" then
		pcall(function() PlayerProfileService.SaveNow(player, opts.reason or "ApplySale") end)
	end

	return true
end

-- Faction standing: single canonical storage on profile.meta.factionStandings (table of faction->number)
local function ensureProfileForFactionOps(player)
	if not PlayerProfileService then return nil end
	if type(PlayerProfileService.GetProfile) == "function" then
		local ok, prof = pcall(function() return PlayerProfileService.GetProfile(player and player.UserId) end)
		if ok and type(prof) == "table" then
			prof.meta = prof.meta or {}
			prof.meta.factionStandings = prof.meta.factionStandings or {}
			return prof
		end
	end
	return nil
end

-- Public: GetFactionStanding(player, faction)
function CoinService.GetFactionStanding(player, faction)
	if not faction then return nil end
	local prof = ensureProfileForFactionOps(player)
	if prof then
		local s = prof.meta.factionStandings[faction]
		return tonumber(s) or 0
	end
	-- Fallback: attribute on Player instance
	if player and type(player.GetAttribute) == "function" then
		local ok, v = pcall(function() return player:GetAttribute("Faction_" .. tostring(faction)) end)
		if ok and v ~= nil then return tonumber(v) or 0 end
	end
	return 0
end

-- Public: AdjustFactionStanding(player, faction, delta)
function CoinService.AdjustFactionStanding(player, faction, delta)
	if not faction or tonumber(delta) == nil then return nil end
	local prof = ensureProfileForFactionOps(player)
	local newVal = nil
	if prof then
		local cur = tonumber(prof.meta.factionStandings[faction] or 0)
		local res = cur + tonumber(delta)
		prof.meta.factionStandings[faction] = res
		-- best-effort persist
		pcall(function() if type(PlayerProfileService.SaveNow) == "function" then PlayerProfileService.SaveNow(player, "AdjustFactionStanding") end end)
		newVal = res
	else
		-- fallback to player attribute
		if player and type(player.SetAttribute) == "function" then
			local ok, cur = pcall(function() return player:GetAttribute("Faction_" .. tostring(faction)) end)
			cur = (ok and tonumber(cur)) or 0
			newVal = cur + tonumber(delta)
			pcall(function() player:SetAttribute("Faction_" .. tostring(faction), newVal) end)
		end
	end
	return newVal
end

return CoinService