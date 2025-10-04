-- Orion unified-remote dialog (UPDATED with Faction Total + Standing prompts) - FIXED KEYWORDS

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local npc = workspace:WaitForChild("OrionNPC")
local prompt = npc:WaitForChild("ProximityPrompt")

local DialogModule = require(ReplicatedStorage:WaitForChild("DialogModule"))
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local SellRequest = Remotes:WaitForChild("SellSlimesRequest")
local SellResult  = Remotes:WaitForChild("SellSlimesResult")
local StandingRequest = Remotes:FindFirstChild("RequestFactionStanding")

local FACTION = "Orion"

-- Tuning
local USE_REQUEST_TOKEN = true
local MIN_EVAL_TIME = 1.4
local EVAL_TEXT = "Assessing your specimens..."
local INFO_REOPEN_DELAY = 0 -- seconds; >0 to auto reopen main menu after info if no live update

local dialog = DialogModule.new("Commander Vex (Orion)", npc, prompt)

dialog:addDialog(
	"You stand before the Orion Syndicate. We refine raw slime energy. State your intent.",
	{"Sell Slimes", "Who are you?", "Faction total", "My standing", "Leave"}
)

dialog:addDialog(
	"We are Orion. Efficiency. Extraction. Advancement. Slimes are conduits of power, and we will not squander potential. Cooperate, and you profit.",
	{"Back", "Leave"}
)

-- Helpers ----------------------------------------------------

local function formatNumber(n)
	if type(n) ~= "number" then return "?" end
	local left,num,right = tostring(n):match("^([^%d]*%d)(%d*)(.-)$")
	num = num:reverse():gsub("(%d%d%d)","%1,"):reverse():gsub("^,","")
	return left .. num .. right
end

local function fetchFactionTotal()
	-- RemoteFunction approach
	local rf = Remotes:FindFirstChild("RequestFactionTotals")
	if rf and rf:IsA("RemoteFunction") then
		local ok, data = pcall(function() return rf:InvokeServer() end)
		if ok then
			if typeof(data) == "table" then
				local total = data[FACTION] or data.total or data.Total or data[FACTION.."Total"]
				if type(total) == "number" then return total end
			elseif type(data) == "number" then
				return data
			end
		end
	end
	-- Fallback: replicated value container
	local folders = {
		ReplicatedStorage:FindFirstChild("FactionTotals"),
		ReplicatedStorage:FindFirstChild("FactionTotalsUpdate")
	}
	for _,fold in ipairs(folders) do
		if fold then
			local val = fold:FindFirstChild(FACTION)
			if val and val:IsA("ValueBase") then
				return val.Value
			end
		end
	end
	return nil
end

local function getStanding()
	local attrValue = player:GetAttribute("Standing_"..FACTION)
	local rf = StandingRequest or Remotes:FindFirstChild("RequestFactionStanding")
	if rf and rf:IsA("RemoteFunction") then
		StandingRequest = rf
		local ok, result = pcall(function()
			return rf:InvokeServer(FACTION)
		end)
		if ok and type(result) == "number" then
			return result
		end
	end
	return attrValue or 0
end

local function liveUpdate(text)
	if dialog.updateMessage then
		dialog:updateMessage(text)
		return true
	end
	return false
end

local function showInfoMessage(text)
	if liveUpdate(text) then
		-- stays open
	else
		dialog:hideGui(text)
		if INFO_REOPEN_DELAY > 0 then
			task.delay(INFO_REOPEN_DELAY, function()
				if prompt.Parent then
					dialog:triggerDialog(player, 1)
				end
			end)
		end
	end
end

local function finalClose(msg)
	dialog:hideGui(msg)
end

-- Sale state
local evaluating = false
local requestToken = nil
local evalStart = 0

-- Prompt open
prompt.Triggered:Connect(function(plr)
	if plr == player then
		dialog:triggerDialog(player, 1)
	end
end)

dialog.responded:Connect(function(responseNum, dialogNum)
	if dialogNum == 1 then
		if responseNum == 1 then
			-- Sell Slimes
			if evaluating then return end
			evaluating = true
			requestToken = USE_REQUEST_TOKEN and HttpService:GenerateGUID(false) or nil
			evalStart = tick()
			if not liveUpdate(EVAL_TEXT) then
				dialog:hideGui(EVAL_TEXT)
			end
			SellRequest:FireServer(FACTION, nil, requestToken)

		elseif responseNum == 2 then
			-- Who are you?
			dialog:triggerDialog(player, 2)

		elseif responseNum == 3 then
			-- Faction total
			local total = fetchFactionTotal()
			if total then
				showInfoMessage(("Orion cumulative extraction value: %s credits."):format(formatNumber(total)))
			else
				showInfoMessage("Data channel unstable. Total unavailable.")
			end

		elseif responseNum == 4 then
			-- My standing
			showInfoMessage("Calculating alignment metrics...")
			task.spawn(function()
				local s = getStanding()
				showInfoMessage(("Your standing is %.3f (%.0f%% efficiency alignment)."):format(s, s*100))
			end)

		elseif responseNum == 5 then
			-- Leave
			finalClose("Return when you possess value.")
		else
			finalClose("Irrelevant selection.")
		end

	elseif dialogNum == 2 then
		if responseNum == 1 then
			dialog:triggerDialog(player, 1)
		else
			finalClose("Efficiency above all.")
		end
	end
end)

-- Sell result (table or legacy)
SellResult.OnClientEvent:Connect(function(a,b,...)
	local payload
	if typeof(a) == "table" and a.success ~= nil and a.faction then
		payload = a
	else
		payload = {
			success        = a,
			faction        = b,
			message        = select(1, ...) or "",
			totalPayout    = select(2, ...) or 0,
			soldCount      = select(3, ...) or 0,
			details        = select(4, ...) or {},
			standingBefore = select(5, ...) or 0,
			standingAfter  = select(6, ...) or 0,
			requestToken   = select(7, ...),
		}
	end
	if payload.faction ~= FACTION then return end
	if USE_REQUEST_TOKEN and requestToken and payload.requestToken and payload.requestToken ~= requestToken then
		return
	end

	local function finish()
		local gain = (payload.standingAfter - payload.standingBefore)
		if payload.success then
			finalClose(("Transaction complete.\nCoins: %d\nStanding: %.3f -> %.3f (+%.3f)")
				:format(payload.totalPayout, payload.standingBefore, payload.standingAfter, gain))
		else
			finalClose("Rejected: " .. tostring(payload.message or "Unknown"))
		end
		evaluating = false
		requestToken = nil
	end

	if not evaluating then
		finish()
		return
	end

	local elapsed = tick() - evalStart
	if elapsed < MIN_EVAL_TIME then
		task.delay(MIN_EVAL_TIME - elapsed, function()
			if evaluating then finish() end
		end)
	else
		finish()
	end
end)