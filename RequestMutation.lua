-- Place this in ServerScriptService (Script)
-- Minimal RPC: listens for Remotes.RequestMutation and calls SlimeCore.SlimeMutation.AttemptMutation(server-side).
-- Safety: only allows requests in Studio or when the requesting player owns the slime (OwnerUserId).
-- For quick testing you can run in Studio where ownership check is bypassed.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Ensure Remotes folder + RequestMutation remote exist
local function ensureFolder(name)
	local f = ReplicatedStorage:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = ReplicatedStorage
	end
	return f
end

local remotesFolder = ensureFolder("Remotes")
local requestRemote = remotesFolder:FindFirstChild("RequestMutation")
if not requestRemote then
	requestRemote = Instance.new("RemoteEvent")
	requestRemote.Name = "RequestMutation"
	requestRemote.Parent = remotesFolder
end

-- Helper to locate SlimeCore ModuleScript like other helper scripts used in this project
local function findModuleScriptByName(name)
	local roots = {
		game:GetService("ServerScriptService"),
		game:GetService("ServerStorage"),
		game:GetService("ReplicatedStorage"),
	}
	for _,root in ipairs(roots) do
		if root and root.Parent then
			for _,desc in ipairs(root:GetDescendants()) do
				if desc:IsA("ModuleScript") and desc.Name == name then
					return desc
				end
			end
		end
	end
	return nil
end

local moduleScript = findModuleScriptByName("SlimeCore")
if not moduleScript then
	warn("[RequestMutation] Could not find SlimeCore ModuleScript; mutation RPC will not function.")
	return
end

local okReq, SlimeCore = pcall(require, moduleScript)
if not okReq or not SlimeCore or not SlimeCore.SlimeMutation then
	warn("[RequestMutation] require(SlimeCore) failed or SlimeMutation missing:", SlimeCore)
	return
end

-- Handler: client fires (player, slimeInstance, optsTable)
requestRemote.OnServerEvent:Connect(function(player, slime, opts)
	if typeof(slime) ~= "Instance" or not slime:IsA("Model") then
		warn("[RequestMutation] Bad slime argument from", player.Name)
		return
	end

	-- Allow in Studio for easy testing; otherwise require ownership
	local allow = RunService:IsStudio()
	local ownerAttr = nil
	local ok, v = pcall(function() return slime:GetAttribute("OwnerUserId") end)
	if ok then ownerAttr = v end
	if not allow then
		if ownerAttr and ownerAttr == player.UserId then
			allow = true
		end
	end

	if not allow then
		warn(("[RequestMutation] Player %s not allowed to mutate slime %s (owner=%s)"):format(player.Name, tostring(slime:GetFullName()), tostring(ownerAttr)))
		return
	end

	-- Normalize opts
	opts = type(opts) == "table" and opts or {}
	-- Force the mutation server-side for testing
	opts.force = true

	local success, err = pcall(function()
		SlimeCore.SlimeMutation.AttemptMutation(slime, nil, opts)
	end)
	if not success then
		warn("[RequestMutation] AttemptMutation error:", err)
	end
end)

print("[RequestMutation] RequestMutation remote ready at ReplicatedStorage.Remotes.RequestMutation")