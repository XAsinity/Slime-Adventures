-- Minimal patched attempt (server only) – may not fire in new TextChat.
-- If this does not log [ChatGiveCash][MSG] when you type 'cash', use the Remote approach.

local AMOUNT = 500
local BASE_ALIASES = { "cash", "cash500" }
local ALLOW_ALL_IN_STUDIO = true
local COOLDOWN_SECONDS = 2
local SAVE_IMMEDIATELY = true
local DEBUG = true

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local PlayerDataService
pcall(function()
	local m = game.ServerScriptService:FindFirstChild("Modules")
	if m and m:FindFirstChild("PlayerDataService") then
		PlayerDataService = require(m.PlayerDataService)
	end
end)

local function log(...) if DEBUG then print("[ChatGiveCash]", ...) end end
local function warnf(...) warn("[ChatGiveCash]", ...) end

local ALIASES = {}
for _,b in ipairs(BASE_ALIASES) do
	ALIASES[b]=true; ALIASES["/"..b]=true; ALIASES["!"..b]=true
end

local lastUse = {}

local function isAllowed(player)
	if ALLOW_ALL_IN_STUDIO and RunService:IsStudio() then return true end
	-- Add production allow-list logic here if needed.
	return true
end

local function normalize(msg)
	if not msg then return "" end
	msg = msg:lower():gsub("^%s+",""):gsub("%s+$","")
	return msg
end
local function strip(msg) return msg:gsub("^[/!]","") end

local function getCoins(player)
	if PlayerDataService and PlayerDataService.GetCoins then
		return PlayerDataService.GetCoins(player)
	end
	local ls=player:FindFirstChild("leaderstats")
	local c=ls and ls:FindFirstChild("Coins")
	return c and c.Value or 0
end

local function grant(player)
	local before=getCoins(player)
	if PlayerDataService and PlayerDataService.IncrementCoins then
		PlayerDataService.IncrementCoins(player, AMOUNT)
		if SAVE_IMMEDIATELY and PlayerDataService.SaveImmediately then
			pcall(function() PlayerDataService.SaveImmediately(player,"ChatGiveCash") end)
		end
	else
		local ls=player:FindFirstChild("leaderstats")
		local c=ls and ls:FindFirstChild("Coins")
		if c then c.Value += AMOUNT end
	end
	local after=getCoins(player)
	log(string.format("Granted %d to %s (before=%d after=%d)", AMOUNT, player.Name, before, after))
end

local function handle(player, raw, src)
	local norm=normalize(raw)
	if norm=="" then return end
	log(string.format("[MSG][%s] %s: %s", src or "?", player.Name, raw))
	local key=strip(norm)
	if not (ALIASES[norm] or ALIASES[key]) then return end
	if not isAllowed(player) then return end
	local now=os.clock()
	if lastUse[player] and now-lastUse[player] < COOLDOWN_SECONDS then
		return
	end
	lastUse[player]=now
	grant(player)
end

-- Legacy fallback
Players.PlayerAdded:Connect(function(plr)
	plr.Chatted:Connect(function(msg) handle(plr,msg,"Chatted") end)
end)
for _,plr in ipairs(Players:GetPlayers()) do
	plr.Chatted:Connect(function(msg) handle(plr,msg,"Chatted(init)") end)
end
log("Legacy hook installed.")

-- Try new chat callback (server may not receive messages)
task.spawn(function()
	if not TextChatService then
		log("No TextChatService present.")
		return
	end
	local channelsFolder = TextChatService:FindFirstChild("TextChannels")
	if not channelsFolder then
		log("No TextChannels folder (server).")
		return
	end
	local function hookChannel(ch)
		if not ch:IsA("TextChannel") then return end
		if ch:GetAttribute("__CGC") then return end
		ch:SetAttribute("__CGC", true)
		-- DO NOT read ch.OnIncomingMessage; just assign
		local ok,err=pcall(function()
			ch.OnIncomingMessage = function(message)
				local src = message.TextSource
				if not src then return end
				local player = Players:GetPlayerByUserId(src.UserId)
				if player then
					handle(player, message.Text, "Incoming(Server)")
				end
			end
		end)
		if ok then log("Assigned channel callback: "..ch.Name) else warnf("Failed assign: "..tostring(err)) end
	end
	for _,ch in ipairs(channelsFolder:GetChildren()) do hookChannel(ch) end
	channelsFolder.ChildAdded:Connect(hookChannel)
end)

log("ChatGiveCash minimal server script ready.")