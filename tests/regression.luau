local passed=0
local function check(name,fn)
	fn(); passed+=1; print("PASS "..name)
end
local function eq(a,b) assert(a==b,tostring(a).." ~= "..tostring(b)) end
local function clone(v)
	if type(v)~="table" then return v end
	local r={} for k,x in pairs(v) do r[k]=clone(x) end return r
end
local function fake()
	local s={data={},fail=0,after=0,replay=nil,hook=nil}
	function s:UpdateAsync(key,fn)
		if self.fail>0 then self.fail-=1; error("network") end
		local new=fn(clone(self.data[key]))
		if self.replay then
			local cb=self.replay; self.replay=nil; cb(self,key)
			new=fn(clone(self.data[key]))
		end
		if self.hook then local cb=self.hook; self.hook=nil; cb() end
		if new~=nil then self.data[key]=clone(new) end
		if self.after>0 then self.after-=1; error("lost acknowledgement") end
		return clone(new)
	end
	return s
end
local function manager(s,extra)
	local c={Store=s,Template={Coins=0,Items={}},Attempts=3,SessionTimeout=30,AutosaveInterval=5}
	for k,v in pairs(extra or {}) do c[k]=v end
	return DataManager.new(c)
end
check("round trip and isolated copies",function()
	local s=fake(); local m=manager(s); local p=assert(m:Load("a"))
	local items={"x"}; eq(p:Set("Items",items),true); items[1]="bad"
	local a=p:Get("Items"); eq(a[1],"x"); a[1]="bad"
	eq(p:Get("Items")[1],"x"); eq(p:Release(),true)
	local q=assert(manager(s):Load("a")); eq(q:Get("Items")[1],"x"); eq(p:IsActive(),false)
end)
check("foreign session and stale writer",function()
	local s=fake(); local p=assert(manager(s):Load("a"))
	local m=manager(s); local q,err=m:Load("a"); eq(q,nil); eq(err,"SESSION_LOCKED")
	advance(61)
	q=assert(m:Load("a")); eq(q:Set("Coins",99),true); eq(q:Release(),true)
	eq(p:Set("Coins",10),true); local ok,why=p:Save(); eq(ok,false); eq(why,"SESSION_LOST")
	eq(s.data.a.Data.Coins,99)
end)
check("callback replay loses ownership",function()
	local s=fake(); local p=assert(manager(s):Load("a")); p:Set("Coins",5)
	s.replay=function(store,key) store.data[key].Lease.Token="new"; store.data[key].Data.Coins=42 end
	local ok,err=p:Save(); eq(ok,false); eq(err,"SESSION_LOST"); eq(s.data.a.Data.Coins,42)
end)
check("release acknowledgement loss",function()
	local s=fake(); local p=assert(manager(s):Load("a")); p:Set("Coins",9); s.after=1
	eq(p:Release(),true); eq(s.data.a.Lease,nil); eq(s.data.a.Data.Coins,9)
end)
check("ambiguous release freezes handle",function()
	local s=fake(); local p=assert(manager(s):Load("a")); p:Set("Coins",9); s.after=3
	-- First release writes, later callback cancellations also throw.
	local ok=p:Release(); eq(ok,false); eq(p:IsActive(),false); eq(p:Set("Coins",11),false)
	eq(p:Release(),true); eq(s.data.a.Data.Coins,9)
end)
check("load acknowledgement retry",function()
	local s=fake(); s.after=1; local p=assert(manager(s):Load("a")); eq(p:IsActive(),true)
end)
check("old handle cannot touch newer acquisition",function()
	local s=fake(); local m=manager(s); local p=assert(m:Load("a")); eq(p:Release(),true)
	local q=assert(m:Load("a")); eq(p:Release(),false); eq(p:Save(),false); eq(q:IsActive(),true)
end)
check("snapshot mutation during save",function()
	local s=fake(); local p=assert(manager(s):Load("a")); p:Set("Coins",1)
	s.hook=function() eq(p:Set("Coins",2),true); eq(p:Save(),false) end
	eq(p:Save(),true); eq(s.data.a.Data.Coins,1); eq(p:Get("Coins"),2)
	eq(p:Save(),true); eq(s.data.a.Data.Coins,2)
end)
check("reject unknown format and future schema",function()
	local s=fake(); s.data.a={Coins=123}; local p,err=manager(s):Load("a"); eq(p,nil); eq(err,"UNKNOWN_RECORD_FORMAT"); eq(s.data.a.Coins,123)
	s.data.b={Format=3,Schema=2,Data={Coins=42}}; p,err=manager(s):Load("b"); eq(p,nil); eq(err,"NEWER_SCHEMA")
end)
check("migration and repeat safety",function()
	local s=fake(); local p=assert(manager(s):Load("a")); p:Set("Coins",11); p:Release()
	local m=manager(s,{SchemaVersion=2,Migrate=function(d,from,to) eq(from,1); eq(to,2); d.Gems=d.Coins; return d end})
	s.replay=function() end
	local q=assert(m:Load("a")); eq(q:Get("Gems"),11); eq(s.data.a.Schema,2)
end)
check("bad data and invalid migration",function()
	local s=fake(); local p=assert(manager(s):Load("a")); local cycle={}; cycle.self=cycle
	eq(p:Set("x",cycle),false); eq(p:Set("x",{[2]=1}),false); eq(p:Set("x",0/0),false)
	eq(p:Set("x",math.huge),false); eq(p:Set("x",string.char(255)),false)
	eq(p:Set("x",setmetatable({},{ })),false); eq(p:Set("x",function() end),false)
	eq(p:Release(),true)
	local m=manager(s,{SchemaVersion=2,Migrate=function(d) coroutine.yield(); return d end})
	local q,err=m:Load("a"); eq(q,nil); eq(err,"MIGRATION_YIELDED"); eq(s.data.a.Schema,1)
end)
check("future lease is not stolen",function()
	local s=fake(); s.data.a={Format=3,Schema=1,Data={},Lease={Token="future",At=1000000000}}
	local p,err=manager(s):Load("a"); eq(p,nil); eq(err,"SESSION_LOCKED")
end)
check("store failure no false success",function()
	local s=fake(); local p=assert(manager(s):Load("a")); p:Set("Coins",9); s.fail=3
	eq(p:Save(),false); eq(s.data.a.Data.Coins,0); eq(p:Get("Coins"),9)
	eq(p:Save(),true)
end)
print("PASS "..passed.." suites")
