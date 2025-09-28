-- Pacifist unified-remote dialog (with Faction Total + Standing prompts)

-- (Your working version already; included only for symmetry. No functional changes.)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local npc = workspace:WaitForChild("PacifistNPC")
local prompt = npc:WaitForChild("ProximityPrompt")

local DialogModule = require(ReplicatedStorage:WaitForChild("DialogModule"))
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local SellRequest = Remotes:WaitForChild("SellSlimesRequest")
local SellResult  = Remotes:WaitForChild("SellSlimesResult")

local FACTION = "Pacifist"

local USE_REQUEST_TOKEN = true
local MIN_EVAL_TIME = 1.2
local EVAL_TEXT = "Evaluating your slimes..."
local INFO_REOPEN_DELAY = 0

local dialog = DialogModule.new("Elaria (Pacifist)", npc, prompt)

dialog:addDialog(
	"Peace be with you. Shall we help your slimes find sanctuary?",
	{"Sell Slimes", "Who are you?", "Faction total", "My standing", "Leave"}
)

dialog:addDialog(
	"I am Elaria, voice of the Pacifists. We offer rest, study, and gentle care. The Adversaries would drain them. Stand with compassion.",
	{"Back", "Leave"}
)

local function formatNumber(n)
	if type(n) ~= "number" then return "?" end
	local left,num,right = tostring(n):match("^([^%d]*%d)(%d*)(.-)$")
	num = num:reverse():gsub("(%d%d%d)","%1,"):reverse():gsub("^,","")
	return left .. num .. right
end

local function fetchFactionTotal()
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
	for _,fold in ipairs({
		ReplicatedStorage:FindFirstChild("FactionTotals"),
		ReplicatedStorage:FindFirstChild("FactionTotalsUpdate")
		}) do
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
	return player:GetAttribute("Standing_"..FACTION) or 0
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

local function finalClose(msg) dialog:hideGui(msg) end

local evaluating = false
local requestToken = nil
local evalStart = 0

prompt.Triggered:Connect(function(plr)
	if plr == player then
		dialog:triggerDialog(player, 1)
	end
end)

dialog.responded:Connect(function(responseNum, dialogNum)
	if dialogNum == 1 then
		if responseNum == 1 then
			if evaluating then return end
			evaluating = true
			requestToken = USE_REQUEST_TOKEN and HttpService:GenerateGUID(false) or nil
			evalStart = tick()
			if not liveUpdate(EVAL_TEXT) then
				dialog:hideGui(EVAL_TEXT)
			end
			SellRequest:FireServer(FACTION, nil, requestToken)
		elseif responseNum == 2 then
			dialog:triggerDialog(player, 2)
		elseif responseNum == 3 then
			local total = fetchFactionTotal()
			if total then
				showInfoMessage(("Pacifist faction total distributed: %s coins."):format(formatNumber(total)))
			else
				showInfoMessage("I cannot sense our full records right now.")
			end
		elseif responseNum == 4 then
			local s = getStanding()
			showInfoMessage(("Your standing with us is %.3f (%.0f%% of maximum compassion)."):format(s, s*100))
		elseif responseNum == 5 then
			finalClose("May harmony guide you.")
		else
			finalClose("Be at peace.")
		end
	elseif dialogNum == 2 then
		if responseNum == 1 then
			dialog:triggerDialog(player, 1)
		else
			finalClose("Farewell, caretaker.")
		end
	end
end)

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
			finalClose(("Your slimes rest now.\nCoins: %d\nStanding: %.3f -> %.3f (+%.3f)")
				:format(payload.totalPayout, payload.standingBefore, payload.standingAfter, gain))
		else
			finalClose("Unable to sell: " .. tostring(payload.message or "Unknown"))
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