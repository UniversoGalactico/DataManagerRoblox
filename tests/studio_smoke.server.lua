-- Separate published test experience only. Enable Studio access to API services.
-- Put this Script next to the DataManager ModuleScript in ServerScriptService.
local RunService=game:GetService("RunService")
assert(RunService:IsStudio(),"Studio test only")
local DataManager=require(script.Parent.DataManager)
local guid=game:GetService("HttpService"):GenerateGUID(false)
local key="Smoke_"..guid
local name="DataManagerSmoke_v3"
local config={StoreName=name,Template={Coins=0}}
local a,b=DataManager.new(config),DataManager.new(config)
local passed=0
local function check(label,condition)
	assert(condition,label)
	passed+=1
	print("[DataManager PASS]",label)
end
local ok,err=pcall(function()
	local p=assert(a:Load(key))
	check("initial template",p:Get("Coins")==0)
	local other,why=b:Load(key)
	check("foreign owner rejected",other==nil and why=="SESSION_LOCKED")
	check("set",p:Set("Coins",123))
	check("confirmed save",p:Save())
	check("confirmed release",p:Release())
	local q=assert(b:Load(key))
	check("durable reload",q:Get("Coins")==123)
	check("stale handle rejected",not p:Set("Coins",999))
	check("second release",q:Release())
end)
local closedA=a:Close()
local closedB=b:Close()
if not ok then warn("[DataManager FAIL]",err); return end
check("both managers closed",closedA and closedB)
print("[DataManager] RESULT: "..passed.."/9 PASS")
-- Deliberately leave this random test record for inspection. No production data is removed.
