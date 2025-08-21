-- MusicPlaylist.lua
-- Simple helper to collect and shuffle music tracks stored in ReplicatedStorage/DefaultSoundTrack

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MusicPlaylist = {}
MusicPlaylist.TracksFolderPath = {"DefaultSoundTrack"} -- relative inside ReplicatedStorage

local function getTracksFolder()
	local current = ReplicatedStorage
	for _,name in ipairs(MusicPlaylist.TracksFolderPath) do
		current = current:FindFirstChild(name)
		if not current then
			warn("[MusicPlaylist] Folder not found:", table.concat(MusicPlaylist.TracksFolderPath, "/"))
			return nil
		end
	end
	return current
end

-- Returns an array of Sound instances (not cloned)
function MusicPlaylist:GetTrackPrototypes()
	local folder = getTracksFolder()
	if not folder then return {} end
	local list = {}
	for _,child in ipairs(folder:GetChildren()) do
		if child:IsA("Sound") then
			table.insert(list, child)
		end
	end
	return list
end

-- Fisher-Yates shuffle
local function shuffle(t)
	for i = #t, 2, -1 do
		local j = math.random(i)
		t[i], t[j] = t[j], t[i]
	end
end

-- Build a shuffled queue (array of Sound prototypes)
function MusicPlaylist:BuildQueue()
	local tracks = self:GetTrackPrototypes()
	shuffle(tracks)
	return tracks
end

return MusicPlaylist