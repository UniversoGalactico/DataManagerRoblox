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
local os={time=function() return wall end,clock=function() return tick end}
local task={wait=function(n) advance(n or 0) end,spawn=function(fn) return coroutine.create(fn) end,defer=function(fn) return coroutine.create(fn) end,cancel=function(t) coroutine.close(t) end}
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
