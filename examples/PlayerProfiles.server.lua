-- Place next to DataManager in ServerScriptService, in a separate test experience.
local Players=game:GetService("Players")
local DataManager=require(script.Parent.DataManager)
local store=DataManager.new({StoreName="ExampleProfiles_v3",Template={Coins=0}})
local active={}
local joining={}
local closing=false

local function joined(player)
	if joining[player] or active[player] or closing then return end
	joining[player]=true
	local profile,err
	for _=1,12 do
		if closing or player.Parent~=Players then break end
		profile,err=store:Load("Player_"..player.UserId)
		if profile then break end
		if err~="SESSION_LOCKED" and err~="ALREADY_LOADED" and err~="ALREADY_LOADING" then break end
		task.wait(2)
	end
	joining[player]=nil
	if not profile then
		if player.Parent==Players and not closing then player:Kick("Data unavailable. Please rejoin.") end
		return
	end
	if player.Parent~=Players or Players:GetPlayerByUserId(player.UserId)~=player or closing then
		profile:Release()
		return
	end
	active[player]=profile
end
local function leaving(player)
	local profile=active[player]
	active[player]=nil
	if not profile then return end
	for _=1,3 do
		local ok,err=profile:Release()
		if ok or err=="PROFILE_INACTIVE" then return end
		task.wait(1)
	end
	warn("Profile release pending",player.UserId)
end
Players.PlayerAdded:Connect(joined)
Players.PlayerRemoving:Connect(leaving)
for _,player in Players:GetPlayers() do task.spawn(joined,player) end
game:BindToClose(function()
	closing=true
	local ok,err=store:Close()
	if not ok then warn(err) end
end)
