-- FactionSlimeBuyerService
-- Now relays all coin payouts and standing changes through PlayerProfileService for persistence

local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local ServerScriptService= game:GetService("ServerScriptService")
local InventoryService = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("InventoryService"))
local GrandInventorySerializer = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("GrandInventorySerializer"))

----------------------------------------------------------------
-- Remotes (ensure exist)
----------------------------------------------------------------
local RemotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if not RemotesFolder then
	RemotesFolder = Instance.new("Folder")
	RemotesFolder.Name = "Remotes"
	RemotesFolder.Parent = ReplicatedStorage
end

local function ensureRemote(name)
	local r = RemotesFolder:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = RemotesFolder
	end
	return r
end

local SellRequest = ensureRemote("SellSlimesRequest")
local SellResult  = ensureRemote("SellSlimesResult")

----------------------------------------------------------------
-- PlayerProfileService persistence
----------------------------------------------------------------
local PlayerProfileService = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("PlayerProfileService"))

----------------------------------------------------------------
-- CONFIG / ECONOMY TUNING
----------------------------------------------------------------
local DEBUG_REMOTE_LOG = true

local GLOBAL_STANDING_DIVISOR        = 10
local STANDING_CLAMP_MIN             = 0.0
local STANDING_CLAMP_MAX             = 1.0
local USE_COLOR_MULTIPLIER_FOR_TOOLS = false
local TOOL_COLOR_CLAMP               = {0.95, 1.05}

local FACTIONS = {
	Pacifist = {
		ColorMultiplierMin     = 0.90,
		ColorMultiplierMax     = 1.10,
		ColorPreferenceWeight  = 0.30,
		PaletteHex             = { "#FFB6C1","#FFC0CB","#FFD1DC","#FFE4E1","#FFD8E8" },

		StandingInitial         = 0.35,
		StandingAnchor          = 0.50,
		StandingMinMultiplier   = 0.40,
		StandingMaxMultiplier   = 1.50,
		StandingGainPerBase     = 0.00012,
		StandingGainPerPayout   = 0.00005,
		StandingGainDiminish    = 1.7,

		NoItemsMessage          = "You have no slime items.",
		SaleMessageTemplate     = "Sold %d slime%s for %d coins.",

		MinPayout               = 5,
		NormalizeColorDivisor   = 1.2,
		Debug                   = false,
	},

	Orion = {
		ColorMultiplierMin     = 0.90,
		ColorMultiplierMax     = 1.12,
		ColorPreferenceWeight  = 0.35,
		PaletteHex             = { "#7F00FF","#FF003C","#00FFC8","#FF9F00","#18A0FF" },

		StandingInitial         = 0.25,
		StandingAnchor          = 0.50,
		StandingMinMultiplier   = 0.35,
		StandingMaxMultiplier   = 1.60,
		StandingGainPerBase     = 0.00010,
		StandingGainPerPayout   = 0.000045,
		StandingGainDiminish    = 1.9,

		NoItemsMessage          = "You possess no viable specimens.",
		SaleMessageTemplate     = "Processed %d specimen%s. Compensation: %d credits.",

		MinPayout               = 5,
		NormalizeColorDivisor   = 1.3,
		Debug                   = false,
	},
}

----------------------------------------------------------------
-- OPTIONAL TOTALS SERVICE
----------------------------------------------------------------
local FactionTotalsService
do
	local ok, mod = pcall(function()
		return require(ServerScriptService:WaitForChild("Modules"):FindFirstChild("FactionTotalsService"))
	end)
	if ok then
		FactionTotalsService = mod
	end
end

----------------------------------------------------------------
-- UTIL
----------------------------------------------------------------
local function dprint(cfg, ...)
	if DEBUG_REMOTE_LOG or (cfg and cfg.Debug) then
		print("[FactionSlimeBuyerService]", ...)
	end
end

local function hexToColor3(hex)
	if typeof(hex) == "Color3" then return hex end
	if type(hex) ~= "string" then return Color3.new(1,1,1) end
	hex = hex:gsub("#","")
	if #hex < 6 then return Color3.new(1,1,1) end
	local r = tonumber(hex:sub(1,2),16) or 255
	local g = tonumber(hex:sub(3,4),16) or 255
	local b = tonumber(hex:sub(5,6),16) or 255
	return Color3.fromRGB(r,g,b)
end

local function colorDistance(a, b)
	local dr = a.R - b.R
	local dg = a.G - b.G
	local db = a.B - b.B
	return math.sqrt(dr*dr + dg*dg + db*db) * 255
end

local function buildPalette(cfg)
	if cfg._PaletteColors then return end
	cfg._PaletteColors = {}
	for _,hex in ipairs(cfg.PaletteHex or {}) do
		table.insert(cfg._PaletteColors, hexToColor3(hex))
	end
end

-- Standing access (persisted via PlayerProfileService)
local function getStanding(player, faction)
	local profile = PlayerProfileService.GetProfile(player)
	profile.stats = profile.stats or {}
	profile.stats.standing = profile.stats.standing or {}
	if profile.stats.standing[faction] == nil then
		profile.stats.standing[faction] = FACTIONS[faction] and FACTIONS[faction].StandingInitial or 0
	end
	return profile.stats.standing[faction]
end

local function setStanding(player, faction, value)
	value = math.clamp(value, STANDING_CLAMP_MIN, STANDING_CLAMP_MAX)
	local profile = PlayerProfileService.GetProfile(player)
	profile.stats = profile.stats or {}
	profile.stats.standing = profile.stats.standing or {}
	profile.stats.standing[faction] = value
	PlayerProfileService.SaveNow(player, "StandingUpdate")
	return value
end

local function standingMultiplier(cfg, standing)
	return cfg.StandingMinMultiplier +
		(cfg.StandingMaxMultiplier - cfg.StandingMinMultiplier) * standing
end

local function computeStandingGain(cfg, standing, baseGross, finalPayout)
	local raw = baseGross * cfg.StandingGainPerBase + finalPayout * cfg.StandingGainPerPayout
	raw = raw / (1 + standing * cfg.StandingGainDiminish)
	raw = raw / GLOBAL_STANDING_DIVISOR
	return raw
end

local function colorMultiplier(cfg, bodyHex, isTool)
	if isTool and not USE_COLOR_MULTIPLIER_FOR_TOOLS then
		return 1
	end
	buildPalette(cfg)
	if not bodyHex then return 1 end
	local c = hexToColor3(bodyHex)
	local best = math.huge
	for _,pal in ipairs(cfg._PaletteColors) do
		local dist = colorDistance(c, pal)
		if dist < best then best = dist end
	end
	local norm = math.clamp(best / (cfg.NormalizeColorDivisor or 1.0), 0, 1)
	local inv  = 1 - norm
	local raw = cfg.ColorMultiplierMin +
		(cfg.ColorMultiplierMax - cfg.ColorMultiplierMin) *
		(inv ^ (1 - cfg.ColorPreferenceWeight))
	if isTool and USE_COLOR_MULTIPLIER_FOR_TOOLS and TOOL_COLOR_CLAMP then
		raw = math.clamp(raw, TOOL_COLOR_CLAMP[1], TOOL_COLOR_CLAMP[2])
	end
	return raw
end

local function priceTool(tool, cfg, standMult)
	local body         = tool:GetAttribute("BodyColor")
	local currentValue = tool:GetAttribute("CurrentValue")
	local baseGross
	if typeof(currentValue) == "number" then
		baseGross = currentValue
	else
		local base   = tool:GetAttribute("ValueBase") or 50
		local growth = tool:GetAttribute("GrowthProgress") or 0
		local perG   = tool:GetAttribute("ValuePerGrowth") or 0
		baseGross    = base + perG * growth * base
	end
	local colMult       = colorMultiplier(cfg, body, true)
	local standingGross = baseGross * standMult
	local final         = math.floor(math.max(cfg.MinPayout or 1, standingGross * colMult))
	return final, {
		slimeId        = tool:GetAttribute("SlimeId"),
		baseGross      = baseGross,
		standingMult   = standMult,
		colorMult      = colMult,
		currentValue   = currentValue,
		finalPayout    = final,
		bodyColor      = body,
		growthProgress = tool:GetAttribute("GrowthProgress"),
	}
end

local function collectTools(player, explicitList)
	local gathered = {}
	if explicitList and type(explicitList) == "table" and #explicitList > 0 then
		for _,inst in ipairs(explicitList) do
			if typeof(inst) == "Instance"
				and inst:IsA("Tool")
				and inst:GetAttribute("SlimeItem") then
				table.insert(gathered, inst)
			end
		end
		return gathered
	end
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		for _,tool in ipairs(backpack:GetChildren()) do
			if tool:IsA("Tool") and tool:GetAttribute("SlimeItem") then
				table.insert(gathered, tool)
			end
		end
	end
	local char = player.Character
	if char then
		for _,tool in ipairs(char:GetChildren()) do
			if tool:IsA("Tool") and tool:GetAttribute("SlimeItem") then
				table.insert(gathered, tool)
			end
		end
	end
	return gathered
end

local function formatSaleMessage(cfg, soldCount, totalPayout)
	local template = cfg.SaleMessageTemplate or "Sold %d items for %d."
	local plural = (soldCount == 1) and "" or "s"
	local needsPlural = template:find("%%s") ~= nil
	if needsPlural then
		local ok, msg = pcall(string.format, template, soldCount, plural, totalPayout)
		if ok then return msg end
	else
		local ok, msg = pcall(string.format, template, soldCount, totalPayout)
		if ok then return msg end
	end
	return string.format("Sold %d for %d.", soldCount, totalPayout)
end

local function processSale(player, faction, toolList)
	local cfg = FACTIONS[faction]
	if not cfg then
		return false, "Unknown faction."
	end
	local standingBefore = getStanding(player, faction)
	local standMult      = standingMultiplier(cfg, standingBefore)

	local tools = collectTools(player, toolList)
	if #tools == 0 then
		return false, cfg.NoItemsMessage or "No items."
	end

	local totalPayout = 0
	local totalBase   = 0
	local details     = {}
	local soldSlimeIds = {}

	for _,tool in ipairs(tools) do
		if tool.Parent then
			local payout, detail = priceTool(tool, cfg, standMult)
			totalPayout += payout
			totalBase   += (detail.baseGross or 0)
			table.insert(details, detail)
			tool:Destroy()
			if detail.slimeId then
				table.insert(soldSlimeIds, detail.slimeId)
			end
		end
	end

	if totalPayout <= 0 then
		return false, "Nothing valuable."
	end

	-- Relay payout to FactionTotalsService if available
	if FactionTotalsService and FactionTotalsService.AddPayout then
		pcall(function()
			FactionTotalsService.AddPayout(faction, totalPayout, player)
		end)
	end

	-- Award coins via PlayerProfileService
	PlayerProfileService.IncrementCoins(player, totalPayout)
	PlayerProfileService.SaveNow(player, "FactionSale")
	PlayerProfileService.ForceFullSaveNow(player, "FactionSaleImmediate")

	-- Update standing via PlayerProfileService
	local standingGain  = computeStandingGain(cfg, standingBefore, totalBase, totalPayout)
	local standingAfter = setStanding(player, faction, standingBefore + standingGain)

	local message = formatSaleMessage(cfg, #details, totalPayout)

	-- Destroy sold slime models in the player's plot
	local plot = workspace:FindFirstChild("Player1") -- or however you get the player's plot
	if plot then
		for _, obj in ipairs(plot:GetChildren()) do
			if obj.Name == "Slime" and obj:FindFirstChild("SlimeId") then
				local slimeId = obj.SlimeId.Value
				for _, soldId in ipairs(soldSlimeIds) do
					if slimeId == soldId then
						obj:Destroy()
						break
					end
				end
			end
		end
	end

	return true, {
		faction        = faction,
		totalPayout    = totalPayout,
		soldCount      = #details,
		details        = details,
		standingBefore = standingBefore,
		standingAfter  = standingAfter,
		message        = message,
	}
end

----------------------------------------------------------------
-- PAYLOAD BUILDING (fixed 'player' global usage)
----------------------------------------------------------------
local function buildPayload(requestingPlayer, success, factionName, dataOrMessage, requestToken)
	if success then
		return {
			success        = true,
			faction        = factionName,
			message        = dataOrMessage.message,
			totalPayout    = dataOrMessage.totalPayout,
			soldCount      = dataOrMessage.soldCount,
			details        = dataOrMessage.details,
			standingBefore = dataOrMessage.standingBefore,
			standingAfter  = dataOrMessage.standingAfter,
			requestToken   = requestToken or dataOrMessage.requestToken,
		}
	else
		local standingNow = 0
		if requestingPlayer then
			standingNow = getStanding(requestingPlayer, factionName)
		end
		return {
			success        = false,
			faction        = factionName,
			message        = tostring(dataOrMessage),
			totalPayout    = 0,
			soldCount      = 0,
			details        = {},
			standingBefore = standingNow,
			standingAfter  = standingNow,
			requestToken   = requestToken,
		}
	end
end

local function fireCompatibility(player, payload)
	SellResult:FireClient(player, payload)
	SellResult:FireClient(
		player,
		payload.success,
		payload.faction,
		payload.message,
		payload.totalPayout,
		payload.soldCount,
		payload.details,
		payload.standingBefore,
		payload.standingAfter,
		payload.requestToken
	)
end

----------------------------------------------------------------
-- REMOTE BINDING
----------------------------------------------------------------
print("[FactionSlimeBuyerService] Remote binding active")

SellRequest.OnServerEvent:Connect(function(player, factionName, toolArray, requestToken)
	factionName = tostring(factionName or "")
	dprint(nil, ("SellSlimesRequest from %s faction=%s token=%s type(toolArray)=%s")
		:format(player.Name, factionName, tostring(requestToken), typeof(toolArray)))

	local success, data = processSale(player, factionName, toolArray)
	local payload = buildPayload(player, success, factionName, data, requestToken)
	fireCompatibility(player, payload)
end)

----------------------------------------------------------------
-- PUBLIC API
----------------------------------------------------------------
local Service = {}

function Service.GetStanding(player, faction)
	return getStanding(player, faction)
end

function Service.GetStandingMultiplier(player, faction)
	local cfg = FACTIONS[faction]
	if not cfg then return 1 end
	local s = getStanding(player, faction)
	return standingMultiplier(cfg, s)
end

function Service.DebugPriceTool(tool, faction, standingOverride)
	local cfg = FACTIONS[faction]
	if not cfg then return nil, "Bad faction" end
	local standing = standingOverride or 0.5
	local sm = standingMultiplier(cfg, standing)
	return priceTool(tool, cfg, sm)
end

function Service.Sell(player, faction, toolArray)
	return processSale(player, faction, toolArray)
end

function Service.GetFactionConfig(faction)
	return FACTIONS[faction]
end

local function sellSlime(player, slimeId)
	-- Remove slime model from player's plot
	local plot = nil
	for _,m in ipairs(workspace:GetChildren()) do
		if m:IsA("Model") and m.Name:match("^Player%d+$") and m:GetAttribute("UserId") == player.UserId then
			plot = m
			break
		end
	end
	if plot then
		for _,obj in ipairs(plot:GetChildren()) do
			if obj:IsA("Model") and obj.Name == "Slime" and obj:GetAttribute("SlimeId") == slimeId then
				obj:SetAttribute("Retired", true) -- Mark as retired for serialization
				obj:Destroy()
				break
			end
		end
	end

	-- No need to clear snapshots or call ClearWorldSlimeCache.
	-- Just force a save so the next scan reflects the change.
	InventoryService.ForceSave(player, "PostSaleCleanup")
end

return Service