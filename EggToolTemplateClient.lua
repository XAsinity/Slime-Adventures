-- Egg Tool Client (v10.4-nocooldown) - patched to ensure preview is always removed when no egg is held
-- Changes:
--   * destroyPreview now accepts a `force` flag to bypass client-preserve heuristics.
--   * Calls to destroyPreview updated (Unequipped, Destroying, and after placing) use force so preview doesn't linger.
--   * Preserving logic still honored when not forced and tool is actively held.

local tool              = script.Parent
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")
local UIS               = game:GetService("UserInputService")
local HttpService       = game:GetService("HttpService")

local placeRemote       = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("PlaceEgg")
local assets            = ReplicatedStorage:WaitForChild("Assets")
local eggModelTemplate  = assets:WaitForChild("Egg")

local player            = Players.LocalPlayer
local mouse             = player:GetMouse()

----------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------
local MIN_LOCAL_INTERVAL = 0.05   -- purely local anti-spam; set to 0 for none

local GROUND_RAYCAST           = true
local GROUND_RAY_DISTANCE      = 300
local IGNORE_ZONE_IN_GROUND_RAY= true
local TWO_PASS_GROUND_RAY      = true

local PREVIEW_USE_CENTER       = true
local FALLBACK_ZONE_PLANE      = true
local ZONE_PLANE_OFFSET        = 1
local EXTRA_CENTER_OFFSET      = 0
local SEND_PREVIEW_CF          = true

local OBSTRUCTION_CLIENT_CHECK_ENABLED = true
local OBSTRUCTION_CLEAR_RADIUS         = 2.75
local OBSTRUCTION_CHECK_HEIGHT_MULT    = 1.1
local OBSTRUCTION_BLOCK_NAMES          = { "Slime","SlimeEgg","Egg" }
local OBSTRUCTION_IGNORE_ATTRIBUTE     = "Ghost"
local IGNORE_OWN_EGGS_IN_CLIENT_OBSTRUCTION = true

local COLOR_VALID        = Color3.fromRGB(120,255,120)
local COLOR_INVALID      = Color3.fromRGB(255, 80, 80)
local COLOR_OBSTRUCTED   = Color3.fromRGB(255,130, 40)
local ALPHA_VALID        = 0.45
local ALPHA_OTHER        = 0.65
local USE_HIGHLIGHT      = true
local HL_FILL_TRANSP     = 0.80
local HL_OUTLINE_TRANSP  = 0.15
local PREVIEW_HIDE_WHEN_INVALID = false
local PREVIEW_FPS        = 60
local REMOVE_PREVIEW_ON_PLACE = true
local PREVIEW_REAPPEAR_DELAY  = 0.25
local EXPECT_TOOL_DESTROY_TIMEOUT = 1.0

local DEBUG = true
local function dprint(...) if DEBUG then print("[EggToolClient]", ...) end end

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------
local previewModel
local previewHighlight
local previewCFrame
local previewValid      = false
local previewObstructed = false
local lastUpdate        = 0
local lastFire          = 0
local removalPending    = false
local updateConn
local heldDisplay

local blockSet = {}
for _,n in ipairs(OBSTRUCTION_BLOCK_NAMES) do blockSet[n:lower()] = true end

----------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------
local function getZone()
	local idx = player:GetAttribute("PlotIndex")
	if not idx then return nil end
	local plot = workspace:FindFirstChild("Player"..idx)
	if not plot then return nil end
	local z = plot:FindFirstChild("SlimeZone")
	if z and z:IsA("BasePart") then return z end
	for _,d in ipairs(plot:GetDescendants()) do
		if d.Name == "SlimeZone" and d:IsA("BasePart") then return d end
	end
	return nil
end

local function insideZone(pos, zone)
	if not zone then return false end
	local lp = zone.CFrame:PointToObjectSpace(pos)
	local h  = zone.Size * 0.5
	return math.abs(lp.X) <= h.X and math.abs(lp.Z) <= h.Z
end

local function ensureEggMetadata()
	if not tool then return end
	if not tool:GetAttribute("OwnerUserId") then
		tool:SetAttribute("OwnerUserId", player.UserId)
		dprint("Repaired OwnerUserId.")
	end
	if not tool:GetAttribute("ServerIssued") then
		tool:SetAttribute("ServerIssued", true)
		dprint("Repaired ServerIssued.")
	end
	if not tool:GetAttribute("EggId") then
		local id = HttpService:GenerateGUID(false)
		tool:SetAttribute("EggId", id)
		dprint("Generated EggId:", id)
	end
end

-- Mark server-restored tools at startup so client preservation checks run before any preview/cleanup
do
	local ok, err = pcall(function()
		if not tool then return end
		ensureEggMetadata() -- ensure attributes exist (EggId / ServerIssued) immediately
		if tool:GetAttribute("ServerIssued") then
			tool:SetAttribute("ServerRestore", true)
			tool:SetAttribute("PreserveOnClient", true)
			dprint("Marked tool as ServerRestore/PreserveOnClient at startup")
		end
	end)
	if not ok then
		warn("EggTool client startup preserve mark failed:", err)
	end
end

----------------------------------------------------------------
-- PRIMARY / HELD VISUAL
----------------------------------------------------------------
local function ensurePrimary(model)
	if model.PrimaryPart and model.PrimaryPart:IsDescendantOf(model) then return model.PrimaryPart end
	local templatePP = eggModelTemplate.PrimaryPart
	if templatePP then
		local cand = model:FindFirstChild(templatePP.Name)
		if cand then model.PrimaryPart = cand return cand end
	end
	local biggest, vol = nil, -1
	for _,p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			local v = p.Size.X*p.Size.Y*p.Size.Z
			if v>vol then vol=v biggest=p end
		end
	end
	if biggest then model.PrimaryPart=biggest end
	return model.PrimaryPart
end

local function weld(root, part)
	local wc = Instance.new("WeldConstraint")
	wc.Part0 = root
	wc.Part1 = part
	wc.Parent = root
end

local function attachHeld()
	if heldDisplay then heldDisplay:Destroy() end
	local handle = tool:FindFirstChild("Handle")
	if not handle then return end
	local clone = eggModelTemplate:Clone()
	clone.Name = "HeldEggModel"
	for _,b in ipairs(clone:GetDescendants()) do
		if b:IsA("BasePart") then
			b.Anchored = false
			b.CanCollide = false
		end
	end
	local primary = clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart")
	if primary then primary.CFrame = handle.CFrame end
	clone.Parent = tool
	for _,b in ipairs(clone:GetDescendants()) do
		if b:IsA("BasePart") then weld(handle,b) end
	end
	heldDisplay = clone
end

local function removeHeld()
	if heldDisplay then heldDisplay:Destroy() end
	heldDisplay = nil
end

----------------------------------------------------------------
-- PREVIEW MODEL
----------------------------------------------------------------
local function createPreview()
	if previewModel then return end
	previewModel = eggModelTemplate:Clone()
	previewModel.Name = "_EggPreview"
	previewModel:SetAttribute("Preview", true)
	previewModel:SetAttribute("Ghost", true)
	ensurePrimary(previewModel)
	for _,p in ipairs(previewModel:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = true
			p.CanCollide = false
			p.CanTouch   = false
			p.CanQuery   = false
			p.Transparency = ALPHA_OTHER
		end
	end
	previewModel.Parent = workspace
	if USE_HIGHLIGHT then
		previewHighlight = Instance.new("Highlight")
		previewHighlight.Adornee = previewModel
		previewHighlight.FillTransparency   = HL_FILL_TRANSP
		previewHighlight.OutlineTransparency= HL_OUTLINE_TRANSP
		previewHighlight.Parent = previewModel
	end
end

local function _clientPreserveTool(tool)
	if not tool then return false end
	local ok, isTool = pcall(function() return tool:IsA("Tool") end)
	if not ok or not isTool then return false end

	if tool:GetAttribute("ServerIssued") then return true end
	if tool:GetAttribute("ServerRestore") then return true end
	if tool:GetAttribute("PreserveOnClient") then return true end
	if tool:GetAttribute("EggId") then return true end
	if tool:GetAttribute("ToolUniqueId") then return true end
	return false
end

-- Destroy preview. If `force`==true, bypass _clientPreserveTool checks and always remove preview.
local function destroyPreview(force)
	-- If not forced, allow preservation heuristics when tool is actively held.
	if not force then
		if _clientPreserveTool(tool) and tool.Parent == player.Character then
			dprint("Preserving server-restored egg tool; skipping preview destroy.")
			return
		end
	end

	if previewModel then previewModel:Destroy() end
	previewModel = nil
	previewHighlight = nil
	previewCFrame = nil
end

----------------------------------------------------------------
-- OBSTRUCTION
----------------------------------------------------------------
local function clientIsBlocking(part)
	if not part:IsA("BasePart") then return false end
	local model = part:FindFirstAncestorOfClass("Model")
	if not model then return false end
	if OBSTRUCTION_IGNORE_ATTRIBUTE and model:GetAttribute(OBSTRUCTION_IGNORE_ATTRIBUTE) then return false end
	if IGNORE_OWN_EGGS_IN_CLIENT_OBSTRUCTION and model.Name=="Egg" and model:GetAttribute("Placed") then
		if model:GetAttribute("OwnerUserId")==player.UserId then return false end
	end
	if blockSet[model.Name:lower()] then return true end
	if model:GetAttribute("Placed") then return true end
	return false
end

local function obstructed(cf,size)
	if not OBSTRUCTION_CLIENT_CHECK_ENABLED then return false end
	local half=size*0.5
	local ext=Vector3.new(
		half.X+OBSTRUCTION_CLEAR_RADIUS,
		half.Y*OBSTRUCTION_CHECK_HEIGHT_MULT,
		half.Z+OBSTRUCTION_CLEAR_RADIUS
	)
	local zone=getZone()
	local params=OverlapParams.new()
	params.FilterType=Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances={previewModel,tool,player.Character,zone}
	local parts=Workspace:GetPartBoundsInBox(cf,ext*2,params)
	for _,p in ipairs(parts) do
		if clientIsBlocking(p) then
			dprint("Obstructed by", p:GetFullName())
			return true
		end
	end
	return false
end

----------------------------------------------------------------
-- GROUND RAY
----------------------------------------------------------------
local function groundY(hitPos, eggHeight, zone)
	if not GROUND_RAYCAST then
		return PREVIEW_USE_CENTER and (hitPos.Y+eggHeight*0.5+EXTRA_CENTER_OFFSET) or (hitPos.Y+EXTRA_CENTER_OFFSET)
	end
	local origin = hitPos + Vector3.new(0,GROUND_RAY_DISTANCE*0.5,0)
	local dir    = Vector3.new(0,-GROUND_RAY_DISTANCE,0)

	local params1 = RaycastParams.new()
	params1.FilterType = Enum.RaycastFilterType.Exclude
	local exclude1 = { previewModel, tool, player.Character }
	if IGNORE_ZONE_IN_GROUND_RAY then table.insert(exclude1, zone) end
	params1.FilterDescendantsInstances = exclude1
	local result = Workspace:Raycast(origin, dir, params1)

	if not result and TWO_PASS_GROUND_RAY and IGNORE_ZONE_IN_GROUND_RAY then
		local params2 = RaycastParams.new()
		params2.FilterType = Enum.RaycastFilterType.Exclude
		params2.FilterDescendantsInstances = { previewModel, tool, player.Character }
		result = Workspace:Raycast(origin, dir, params2)
	end

	if result then
		return result.Position.Y + (PREVIEW_USE_CENTER and eggHeight*0.5 or 0) + EXTRA_CENTER_OFFSET
	elseif zone and FALLBACK_ZONE_PLANE then
		return zone.Position.Y + (PREVIEW_USE_CENTER and ZONE_PLANE_OFFSET or (ZONE_PLANE_OFFSET - eggHeight*0.5))
	else
		return hitPos.Y + (PREVIEW_USE_CENTER and eggHeight*0.5 or 0)
	end
end

----------------------------------------------------------------
-- PREVIEW COMPUTE
----------------------------------------------------------------
local function computePreview()
	if not mouse or not mouse.Hit then return nil,false,false end
	local hitPos = mouse.Hit.Position
	local zone = getZone()
	local inside = zone and insideZone(hitPos, zone) or false

	local pp = previewModel and ensurePrimary(previewModel) or nil
	local eggH = (pp and pp.Size.Y) or 2
	local sizeVec = (pp and pp.Size) or Vector3.new(2,2,2)

	local cY = groundY(hitPos, eggH, zone)
	local cf = CFrame.new(hitPos.X, cY, hitPos.Z)
	local ob = inside and obstructed(cf,sizeVec) or false
	return cf, inside, ob
end

----------------------------------------------------------------
-- PREVIEW LOOP
----------------------------------------------------------------
local function updatePreview()
	if not previewModel then return end
	previewCFrame, previewValid, previewObstructed = computePreview()
	if not previewCFrame then
		previewModel.Parent = nil
		return
	end

	-- Preserve the template/model rotation when pivoting the preview into place.
	-- Previously we called previewModel:PivotTo(previewCFrame) which loses the model's authored rotation
	-- and could make eggs lay on their side. Extract the model pivot rotation and compose a pivot with
	-- the desired position + template rotation.
	local okPivot, modelPivot = pcall(function() return previewModel:GetPivot() end)
	if okPivot and typeof(modelPivot) == "CFrame" then
		local rx, ry, rz = modelPivot:ToOrientation()
		local rotOnly = CFrame.fromOrientation(rx, ry, rz)
		local targetPivot = CFrame.new(previewCFrame.Position) * rotOnly
		pcall(function() previewModel:PivotTo(targetPivot) end)
	else
		-- fallback if GetPivot fails
		pcall(function() previewModel:PivotTo(previewCFrame) end)
	end

	local color
	if not previewValid then
		color = COLOR_INVALID
	elseif previewObstructed then
		color = COLOR_OBSTRUCTED
	else
		color = COLOR_VALID
	end
	local show = previewValid or not PREVIEW_HIDE_WHEN_INVALID
	previewModel.Parent = show and workspace or nil
	for _,p in ipairs(previewModel:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Color = color
			p.Transparency = (previewValid and not previewObstructed) and ALPHA_VALID or ALPHA_OTHER
		end
	end
	if previewHighlight then
		previewHighlight.Enabled = show
		previewHighlight.FillColor = color
		previewHighlight.OutlineColor = color
	end
end

local function startLoop()
	if updateConn then return end
	updateConn = RunService.Heartbeat:Connect(function()
		if tool.Parent ~= player.Character then return end
		local now = time()
		if now - lastUpdate >= 1/PREVIEW_FPS then
			lastUpdate = now
			updatePreview()
		end
	end)
end

local function stopLoop()
	if updateConn then updateConn:Disconnect() end
	updateConn = nil
end

----------------------------------------------------------------
-- FIRE
----------------------------------------------------------------
local function fire(reason)
	ensureEggMetadata()
	if MIN_LOCAL_INTERVAL > 0 and (time() - lastFire) < MIN_LOCAL_INTERVAL then
		dprint("Abort: local min interval", reason)
		return
	end
	if not previewCFrame then dprint("Abort: no previewCFrame", reason) return end
	if not previewValid then dprint("Abort: outside zone", reason) return end
	if previewObstructed then dprint("Abort: obstructed", reason) return end

	lastFire = time()
	local sendCF = SEND_PREVIEW_CF and previewCFrame or (mouse and mouse.Hit or previewCFrame)
	dprint("FireServer", reason, "EggId", tool:GetAttribute("EggId"), "at", sendCF.Position)
	placeRemote:FireServer(sendCF, tool)

	if REMOVE_PREVIEW_ON_PLACE then
		removalPending = true
		stopLoop()
		-- Force destroy preview so preserved tools don't leave it around after placement.
		destroyPreview(true)
		task.delay(PREVIEW_REAPPEAR_DELAY, function()
			if removalPending and tool.Parent == player.Character then
				removalPending = false
				createPreview()
				startLoop()
			end
		end)
		task.delay(EXPECT_TOOL_DESTROY_TIMEOUT, function()
			removalPending = false
		end)
	end
end

----------------------------------------------------------------
-- EVENTS
----------------------------------------------------------------
tool.Equipped:Connect(function()
	dprint("Equipped:", tool.Name)
	ensureEggMetadata()
	attachHeld()
	createPreview()
	startLoop()
end)

tool.Unequipped:Connect(function()
	removeHeld()
	stopLoop()
	-- Force preview destruction on unequip so preview doesn't linger if player drops tool or tool is destroyed server-side.
	destroyPreview(true)
end)

tool.Activated:Connect(function()
	fire("Activated")
end)

UIS.InputBegan:Connect(function(input,gp)
	if gp then return end
	if tool.Parent == player.Character and input.UserInputType == Enum.UserInputType.MouseButton1 then
		fire("MouseDown")
	end
end)

tool.Destroying:Connect(function()
	stopLoop()
	-- Tool is being destroyed: force removal of preview & held visuals
	destroyPreview(true)
	removeHeld()
end)

dprint("Client (v10.4-nocooldown) loaded for tool:", tool.Name)