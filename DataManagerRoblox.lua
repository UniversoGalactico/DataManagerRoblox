--!nonstrict
-- DataManager: server-side persistent profiles, one owner per acquisition.
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local DataManager = { VERSION = "3.0.0-rc.1" }

local function integer(n)
	return type(n) == "number" and n == n and math.abs(n) <= 2^50 and n % 1 == 0
end

-- Copy and validate in one traversal. No caller-owned mutable references escape.
-- Limits are conservative structural budgets, not a serialized size guarantee.
local function copyData(root)
	local nodes, bytes, active = 0, 0, {}
	local function copy(value, depth)
		nodes += 1
		if nodes > 20000 or depth > 32 then error("DATA_BUDGET", 0) end
		local kind = type(value)
		if kind == "boolean" then return value end
		if kind == "number" and value == value and math.abs(value) <= 2^50 then return value end
		if kind == "string" then
			bytes += #value
			if bytes > 512*1024 or #value > 65536 or not utf8.len(value) then error("INVALID_STRING",0) end
			return value
		end
		if kind ~= "table" or getmetatable(value) ~= nil or active[value] then error("INVALID_DATA",0) end
		active[value] = true
		local result, strings, numbers, largest = {}, 0, 0, 0
		for key, child in next, value do
			if type(key) == "string" then
				bytes += #key
				if bytes > 512*1024 or #key > 65536 or not utf8.len(key) then error("INVALID_KEY",0) end
				strings += 1
			elseif integer(key) and key >= 1 then
				numbers += 1
				largest = math.max(largest,key)
			else
				error("INVALID_KEY",0)
			end
			if strings > 0 and numbers > 0 then error("MIXED_KEYS",0) end
			result[key] = copy(child,depth+1)
		end
		if largest ~= numbers then error("SPARSE_ARRAY",0) end
		active[value] = nil
		return result
	end
	local ok, result = pcall(copy,root,1)
	if not ok then return nil,result end
	return result
end

local function dictionary(value)
	if type(value) ~= "table" then return false end
	for key in next,value do if type(key) ~= "string" then return false end end
	return true
end

local function validKey(key)
	return type(key) == "string" and #key > 0 and #key <= 50 and utf8.len(key) ~= nil
		and not string.find(key,"%c")
end

local function recordValid(old)
	if type(old) ~= "table" or old.Format ~= 3 or not integer(old.Schema) or old.Schema < 1
		or type(old.Data) ~= "table" or not dictionary(old.Data) then return false end
	if old.Lease ~= nil then
		local lease = old.Lease
		if type(lease) ~= "table" or type(lease.Token) ~= "string" or lease.Token == ""
			or not integer(lease.At) or lease.At < 0 then return false end
	end
	return true
end

-- Preserve Roblox key metadata and associated user IDs on every committed write.
local function keepMetadata(record, keyInfo)
	if keyInfo then return record,keyInfo:GetUserIds(),keyInfo:GetMetadata() end
	return record
end

local function migrate(fn,data,from,to)
	local thread = coroutine.create(fn)
	local ok,result = coroutine.resume(thread,data,from,to)
	if coroutine.status(thread) ~= "dead" then
		pcall(task.cancel,thread)
		pcall(coroutine.close,thread)
		return nil,"MIGRATION_YIELDED"
	end
	if not ok or not dictionary(result) then return nil,"MIGRATION_FAILED" end
	return copyData(result)
end

function DataManager.new(config)
	assert(type(config)=="table","CONFIG_REQUIRED")
	local template = assert(copyData(if config.Template == nil then {} else config.Template))
	assert(dictionary(template),"TEMPLATE_MUST_BE_DICTIONARY")
	local schema = config.SchemaVersion or 1
	local leaseSeconds = config.SessionTimeout or 180
	local autosave = config.AutosaveInterval or 60
	local attempts = config.Attempts or 4
	local limit = config.MaxConcurrentSaves or 4
	local migration = config.Migrate
	local notify = config.OnError
	assert(integer(schema) and schema>=1,"INVALID_SCHEMA")
	assert(integer(leaseSeconds) and leaseSeconds>=30 and leaseSeconds<=3600,"INVALID_TIMEOUT")
	assert(integer(autosave) and autosave>=5 and autosave*2<=leaseSeconds,"INVALID_AUTOSAVE")
	assert(integer(attempts) and attempts>=1 and attempts<=8,"INVALID_ATTEMPTS")
	assert(integer(limit) and limit>=1 and limit<=16,"INVALID_CONCURRENCY")
	assert(migration==nil or type(migration)=="function","INVALID_MIGRATION")
	assert(notify==nil or type(notify)=="function","INVALID_ON_ERROR")
	local store = config.Store -- optional dependency injection for tests/custom adapters
	if not store then
		assert(type(config.StoreName)=="string" and #config.StoreName>0,"STORE_NAME_REQUIRED")
		store=DataStoreService:GetDataStore(config.StoreName,config.Scope)
	end
	local profiles, loading = {}, {}
	local closing = false
	local background = 0
	local manager = {}
	local function id() return HttpService:GenerateGUID(false) end
	local function report(key,code)
		if notify then task.defer(function() pcall(notify,key,code) end)
		else warn("[DataManager]",key,code) end
	end
	local function retry(attempt)
		task.wait(math.min(0.35*2^(attempt-1),2)*(0.8+math.random()*0.4))
	end
	local function owns(old,token)
		return recordValid(old) and old.Lease~=nil and old.Lease.Token==token
	end
	local function expired(lease)
		-- A future timestamp is never grounds for takeover.
		return os.time()-lease.At >= leaseSeconds+30
	end
	local function record(data,token,writeId,release)
		local result = {Format=3,Schema=schema,Data=data,WriteId=writeId}
		if release then result.ReleasedToken=token
		else result.Lease={Token=token,At=os.time()} end
		return result
	end
	local function update(key,transform)
		for attempt=1,attempts do
			local status
			local ok,result=pcall(function()
				return store:UpdateAsync(key,function(old,info)
					-- Reset every callback attempt: Roblox can replay the transform.
					status=nil
					local nextValue,code=transform(old)
					status=code
					if nextValue==nil then return nil end
					return keepMetadata(nextValue,info)
				end)
			end)
			if ok then
				if status then return nil,status end
				if type(result)=="table" then return result end
			end
			if attempt<attempts then retry(attempt) end
		end
		return nil,"STORE_FAILED"
	end
	local function acquire(key,token)
		local writeId=id()
		return update(key,function(old)
			local data
			if old==nil then data=assert(copyData(template))
			else
				if not recordValid(old) then return nil,"UNKNOWN_RECORD_FORMAT" end
				if old.Lease and old.Lease.Token~=token and not expired(old.Lease) then return nil,"SESSION_LOCKED" end
				if old.Schema>schema then return nil,"NEWER_SCHEMA" end
				local err
				data,err=copyData(old.Data)
				if not data then return nil,err end
				if old.Schema<schema then
					if not migration then return nil,"MIGRATION_REQUIRED" end
					data,err=migrate(migration,data,old.Schema,schema)
					if not data then return nil,err end
				end
			end
			return record(data,token,writeId,false)
		end)
	end
	local function live(p)
		if profiles[p.Key]~=p or p.Releasing or p.Lost or closing then return false end
		if os.clock()>=p.ValidUntil then
			p.Releasing=true
			p.NextSave=os.clock()
			return false
		end
		return true
	end
	local function discard(p)
		if profiles[p.Key]==p then profiles[p.Key]=nil end
	end
	local function save(p,release)
		if profiles[p.Key]~=p or p.Lost then return false,"PROFILE_INACTIVE" end
		if release and not p.Releasing then p.Releasing=true; p.NextSave=os.clock() end
		if p.Busy then return false,"SAVE_BUSY" end
		if not release and not live(p) then return false,"PROFILE_INACTIVE" end
		p.Busy=true
		-- Private snapshot remains unchanged across retries and callback replay.
		local snapshot=assert(copyData(p.Data))
		local revision=p.Revision
		local writeId=id()
		local operationStart=os.clock()
		local callOk,result,err=pcall(update,p.Key,function(old)
			if release and recordValid(old) and old.Lease==nil and old.ReleasedToken==p.Token then
				return nil,"ALREADY_RELEASED"
			end
			if not owns(old,p.Token) then return nil,"SESSION_LOST" end
			if old.Schema~=schema then return nil,"SESSION_LOST" end
			return record(snapshot,p.Token,writeId,release)
		end)
		p.Busy=false
		if not callOk then result,err=nil,"STORE_FAILED" end
		local confirmed = result and recordValid(result) and result.WriteId==writeId
			and (if release then result.Lease==nil and result.ReleasedToken==p.Token else owns(result,p.Token))
		if confirmed or (release and err=="ALREADY_RELEASED") then
			p.SavedRevision=revision
			if not release then p.ValidUntil=operationStart+leaseSeconds end
			p.NextSave=if p.Releasing then os.clock() else math.min(os.clock()+autosave,p.ValidUntil)
			if release then discard(p) end
			return true
		end
		if err=="SESSION_LOST" then p.Lost=true; discard(p) end
		-- Failed release stays frozen, because the write may have committed.
		-- Retry Release on this same handle; never resume writes after ambiguity.
		p.NextSave=os.clock()+math.min(autosave,5)
		return false,err or "UNCONFIRMED_WRITE"
	end
	local function handle(p)
		local profile={}
		function profile:IsActive() return live(p) end
		function profile:Get(key)
			if not live(p) then return nil,"PROFILE_INACTIVE" end
			if type(key)~="string" then return nil,"INVALID_KEY" end
			local value=p.Data[key]
			if value==nil then return nil end
			return copyData(value)
		end
		function profile:Snapshot()
			if not live(p) then return nil,"PROFILE_INACTIVE" end
			return copyData(p.Data)
		end
		function profile:Set(key,value)
			if not live(p) then return false,"PROFILE_INACTIVE" end
			if type(key)~="string" then return false,"INVALID_KEY" end
			local candidate=table.clone(p.Data)
			candidate[key]=value
			local data,err=copyData(candidate)
			if not data then return false,err end
			p.Data=data
			p.Revision+=1
			return true
		end
		function profile:Save()
			if not live(p) then return false,"PROFILE_INACTIVE" end
			return save(p,false)
		end
		function profile:Release()
			if profiles[p.Key]~=p then return false,"PROFILE_INACTIVE" end
			return save(p,true)
		end
		return table.freeze(profile)
	end
	function manager:Load(key)
		if closing then return nil,"CLOSING" end
		if not validKey(key) then return nil,"INVALID_KEY" end
		if profiles[key] then return nil,"ALREADY_LOADED" end
		if loading[key] then return nil,"ALREADY_LOADING" end
		loading[key]=true
		local token=id()
		local operationStart=os.clock()
		local ok,result,err=pcall(acquire,key,token)
		loading[key]=nil
		if not ok then return nil,"STORE_FAILED" end
		if not result then return nil,err end
		if not owns(result,token) or result.Schema~=schema then return nil,"UNCONFIRMED_LOAD" end
		local data,copyError=copyData(result.Data)
		if not data then return nil,copyError end
		local validUntil=operationStart+leaseSeconds
		local p={Key=key,Token=token,Data=data,Revision=0,SavedRevision=0,ValidUntil=validUntil,NextSave=math.min(os.clock()+autosave,validUntil)}
		profiles[key]=p
		if closing then p.Releasing=true; p.NextSave=os.clock(); return nil,"CLOSING" end
		if not live(p) then return nil,"LEASE_EXPIRED" end
		return handle(p)
	end
	local function schedule(p,release)
		if background>=limit or p.Busy or p.Scheduled then return end
		p.Scheduled=true
		background+=1
		task.spawn(function()
			local ok,saved,err=pcall(save,p,release)
			p.Scheduled=false
			background-=1
			if not ok or not saved then report(p.Key,if ok then err else "INTERNAL_ERROR") end
		end)
	end
	-- One background loop per manager. Due profiles renew even when unchanged.
	-- Spread dispatch over ticks, with a bounded number of concurrent workers.
	task.spawn(function()
		while not closing do
			task.wait(1)
			if closing then break end
			local now=os.clock()
			local due={}
			for _,p in pairs(profiles) do
				live(p) -- freeze expired handles before dispatch
				if not p.Busy and not p.Scheduled and p.NextSave<=now then table.insert(due,p) end
			end
			table.sort(due,function(a,b) return a.NextSave<b.NextSave end)
			for _,p in ipairs(due) do
				if background>=limit then break end
				schedule(p,p.Releasing==true)
			end
		end
	end)
	function manager:Close(seconds)
		local budget=if seconds==nil then 25 else seconds
		if type(budget)~="number" or budget~=budget or budget<0 or budget>25 then return false,"INVALID_DEADLINE" end
		closing=true
		local deadline=os.clock()+budget
		repeat
			for _,p in pairs(profiles) do
				if not p.Releasing then p.Releasing=true; p.NextSave=os.clock() end
				if background<limit and p.NextSave<=os.clock() then schedule(p,true) end
			end
			if next(profiles)==nil and next(loading)==nil and background==0 then return true end
			if os.clock()>=deadline then break end
			task.wait(0.1)
		until os.clock()>=deadline
		return false,"SHUTDOWN_INCOMPLETE"
	end
	return table.freeze(manager)
end

return table.freeze(DataManager)
