import argparse,pathlib,subprocess,tempfile
p=argparse.ArgumentParser()
p.add_argument("--luau",required=True)
p.add_argument("--optimization",default="2")
a=p.parse_args()
root=pathlib.Path(__file__).resolve().parents[1]
prelude="""local wall=1000
local tick=0
local count=0
local function advance(n) wall+=n; tick+=n end
local os={time=function() return math.floor(wall) end,clock=function() return tick end}
local scheduling=false
local jobs={}
local function step(thread)
 local ok,delay=coroutine.resume(thread)
 assert(ok,delay)
 if coroutine.status(thread)~="dead" then jobs[thread]=tick+(delay or 0.01) end
end
local function pump(seconds)
 local target=tick+seconds
 local iterations=0
 while true do
  local chosen,due=nil,math.huge
  for thread,at in pairs(jobs) do if at<due then chosen,due=thread,at end end
  if not chosen or due>target then break end
  iterations+=1; assert(iterations<100000,"scheduler runaway")
  if tick<due then advance(due-tick) end
  jobs[chosen]=nil
  step(chosen)
 end
 if tick<target then advance(target-tick) end
end
local function enableScheduler()
 jobs={}; scheduling=true
end
local function disableScheduler()
 scheduling=false; jobs={}
end
local task={}
-- Luau's coroutine.running does not provide Lua 5.4's main flag on every build.
-- Compare against the captured main thread instead.
local mainThread=coroutine.running()
function task.wait(n)
 n=n or 0.01
 if not scheduling then advance(n); return end
 if coroutine.running()==mainThread then pump(n) else coroutine.yield(n) end
end
function task.spawn(fn,...)
 local args=table.pack(...)
 local thread=coroutine.create(function() fn(table.unpack(args,1,args.n)) end)
 if scheduling then step(thread) end
 return thread
end
function task.defer(fn,...)
 local args=table.pack(...)
 local thread=coroutine.create(function() fn(table.unpack(args,1,args.n)) end)
 if scheduling then jobs[thread]=tick+0.01 end
 return thread
end
function task.cancel(thread) jobs[thread]=nil; coroutine.close(thread) end
local function warn(...) end
local game={GetService=function(_,name)
 if name=="HttpService" then return {GenerateGUID=function() count+=1; return "guid-"..count end} end
 return {}
end}
"""
source=(root/"DataManagerRoblox.lua").read_text()
tests=(root/"tests/regression.luau").read_text()
with tempfile.TemporaryDirectory() as tmp:
 path=pathlib.Path(tmp)/"test.luau"
 path.write_text(prelude+"\nlocal DataManager=(function()\n"+source+"\nend)()\n"+tests)
 subprocess.run([a.luau,"-O"+a.optimization,str(path)],check=True)
