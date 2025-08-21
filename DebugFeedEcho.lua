-- Temporary debug script: echoes ANY FeedSlime remote call BEFORE SlimeFeedService logic.
-- Remove after resolving issue.
local RS = game:GetService("ReplicatedStorage")
local ev = RS:WaitForChild("Remotes"):WaitForChild("FeedSlime")
ev.OnServerEvent:Connect(function(pl, slime, tool)
	print("[DebugFeedEcho] Remote arrived pl=", pl.Name,
		" slime=", slime and slime.Name,
		" tool=", tool and tool.Name,
		" slimeIsModel=", slime and slime:IsA("Model"))
end)