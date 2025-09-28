local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local FeedRemote = Remotes:WaitForChild("FeedSlime")

FeedRemote.OnServerEvent:Connect(function(player, slimeInstance, toolOrNil, maybeUid)
	print("[Server] FeedSlime.OnServerEvent from", player.Name)
	print("  slimeInstance:", tostring(slimeInstance))
	print("  toolOrNil:", tostring(toolOrNil), "class:", (toolOrNil and toolOrNil.ClassName) or "nil")
	print("  maybeUid:", tostring(maybeUid))

	-- basic ownership check example (optional)
	if toolOrNil and typeof(toolOrNil) == "Instance" and toolOrNil:IsA("Tool") then
		local owner = pcall(function() return toolOrNil:GetAttribute("OwnerUserId") end)
		print("  tool OwnerUserId attribute:", owner)
	end

	-- respond back to client (if FeedResult remote exists)
	local feedResult = Remotes:FindFirstChild("FeedResult")
	if feedResult and feedResult:IsA("RemoteEvent") then
		feedResult:FireClient(player, { success = true, message = "Server logged the feed event" })
	end
end)