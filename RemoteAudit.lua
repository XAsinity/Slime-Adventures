-- RemoteAudit: lists every instance named FeedSlime; stamps the authoritative one.

local RS = game:GetService("ReplicatedStorage")

local function listAll()
	print("---- SERVER REMOTE AUDIT (FeedSlime) ----")
	local count = 0
	for _,inst in ipairs(game:GetDescendants()) do
		if inst.Name == "FeedSlime" then
			count += 1
			print(string.format("[%d] %s  Class=%s  Parent=%s", count, inst:GetFullName(), inst.ClassName, inst.Parent and inst.Parent.ClassName))
		end
	end
	if count == 0 then
		print("NO FeedSlime instances found at all.")
	end
	print("---- END AUDIT ----")
end

-- Run initial audit after short delay (to allow dynamic creation)
task.delay(1, function()
	listAll()

	-- Choose authoritative remote: ReplicatedStorage.Remotes.FeedSlime
	local remotesFolder = RS:FindFirstChild("Remotes")
	local authoritative = remotesFolder and remotesFolder:FindFirstChild("FeedSlime")
	if authoritative and authoritative:IsA("RemoteEvent") then
		-- Stamp a unique marker
		local guid = game:GetService("HttpService"):GenerateGUID(false)
		authoritative:SetAttribute("ServerGUID", guid)
		print("[RemoteAudit] Stamped ServerGUID =", guid, "on", authoritative:GetFullName())
	else
		warn("[RemoteAudit] Could not find authoritative RemoteEvent at ReplicatedStorage.Remotes.FeedSlime")
	end
end)