#!/usr/bin/env python3
"""Finite differential audit using external LuauProof 3.20, not a formal proof."""
import argparse, ast, hashlib, json, random, subprocess, sys, tempfile, time
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--luauproof',type=Path,required=True);p.add_argument('--seed',type=int,default=32027);p.add_argument('--source',type=Path,default=Path('DataManagerRoblox.lua'));p.add_argument('--runner',type=Path,default=Path('tests/run.py'));p.add_argument('--out',type=Path,required=True)
a=p.parse_args();start=time.monotonic();root=a.luauproof.resolve();sys.path.insert(0,str(root))
from numeric_fuzz320 import generate,expr,eval_ast
from vm_binary64_320 import pairs
from binary64_320 import parts
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
pins={'numeric_fuzz320.py':'5d4cf91db579d2097cac2d13b9a77bef0bbad54878a47ad493a5d502d6f3e4b0','binary64_320.py':'8995a1949fcc910986bcfe38a9b9c406410db3c25929c45233f1a250a6fe8253','runtime/linux/luau':'7741b96bd8fadb340965b7468dc4a2be8fe41247b8219bd8d4a7e80f16b40625','vm_binary64_320.py':'ba264eb5b102209ab0dbacc7c189a8fcd1536f08ed0805d1f88b4647be370af6'}
for path,h in pins.items():assert sha(root/path)==h,path
rng=random.Random(a.seed);pool=pairs(a.seed,10000);ps=rng.sample(pool,128);trees=generate(a.seed,96)
def val(b):
 s,k,x=parts(b);return (-x if s else x) if k in ('finite','zero') else None
def bits(b):return f'{b&0xffffffff},{b>>32}'
def bl(x):return str(bool(x)).lower()
def lit(s):return '"'+''.join('\\%03d'%b for b in s)+'"'
pre=next(ast.literal_eval(n.value) for n in ast.parse(a.runner.read_text()).body if isinstance(n,ast.Assign) and any(isinstance(x,ast.Name) and x.id=='prelude' for x in n.targets))
body=[r'''
local counts,bad={},{}
local function check(group,ok,label)
 counts[group]=(counts[group] or 0)+1
 if not ok then bad[group]=(bad[group] or 0)+1; if bad[group]<=10 then print("DIFF",group,label) end end
end
local function frombits(lo,hi) return string.unpack("<d",string.pack("<I4I4",lo,hi)) end
local function matches(v,e)
 if e~=e then return v~=v end
 if e==0 then return v==0 end
 return string.pack("<d",v)==string.pack("<d",e)
end
local store={data={}}
function store:UpdateAsync(k,fn) local new=fn(self.data[k]);if new~=nil then self.data[k]=new end;return new end
local manager=DataManager.new({Store=store,Template={V=0}})
local profile=assert(manager:Load("numeric"))
local funcs={}
''']
for i,t in enumerate(trees):body.append(f'funcs[{i+1}]=function(a,b) return {expr(t)} end')
body.append(r'''
local function numeric(i,f,al,ah,bl,bh,el,eh,valid)
 local v=funcs[f](frombits(al,ah),frombits(bl,bh));local e=frombits(el,eh)
 check("oracle",matches(v,e),i)
 local before=profile:Get("V")
 local ok=profile:Set("V",v)
 check("number_acceptance",ok==valid,i)
 check("number_value",matches(profile:Get("V"),if valid then e else before),i)
end
local function direct(i,lo,hi,valid)
 local v=frombits(lo,hi);local before=profile:Get("V")
 check("direct_acceptance",profile:Set("V",v)==valid,i)
 check("direct_value",matches(profile:Get("V"),if valid then v else before),i)
end
local function utf(i,s,valid)
 local ok=profile:Set("Text",s);check("utf8",ok==valid,i)
 if ok then check("utf8_roundtrip",profile:Get("Text")==s,i) end
end
local function config(i,v,valid)
 local ok=pcall(DataManager.new,{Store=store,SessionTimeout=v,AutosaveInterval=5})
 check("config_timeout",ok==valid,i)
end
local function lease(i,at,duration,valid,admit)
 local s={data={x={Format=3,Schema=1,Data={V=9},Lease={Token="other",At=at,Duration=duration}}}}
 s.UpdateAsync=store.UpdateAsync
 local m=DataManager.new({Store=s,SessionTimeout=30,AutosaveInterval=5})
 local p,err=m:Load("x")
 check("lease_admission",(p~=nil)==admit,i)
 if not admit then check("lease_error",err==(if valid then "SESSION_LOCKED" else "UNKNOWN_RECORD_FORMAT"),i) end
 if p then check("lease_value",p:Get("V")==9,i) end
end
''')
for i,t in enumerate(trees):
 for j,(x,y) in enumerate(ps):
  b=eval_ast(t,x,y);v=val(b);body.append(f'numeric({i*128+j},{i+1},{bits(x)},{bits(y)},{bits(b)},{bl(v is not None and abs(v)<=2**50)})')
for i,(x,y) in enumerate(pool[:4000]):
 v=val(x);body.append(f'direct({i},{bits(x)},{bl(v is not None and abs(v)<=2**50)})')
for i in range(3000):
 s=bytes(rng.randrange(256) for _ in range(rng.randrange(0,15))) if i%3 else chr(rng.choice([rng.randrange(0xd800),rng.randrange(0xe000,0x110000)])).encode()
 if i%100==0:s=bytes.fromhex('eda080')
 try:s.decode('utf-8');valid=True
 except UnicodeDecodeError:valid=False
 body.append(f'utf({i},{lit(s)},{bl(valid)})')
for i,(x,y) in enumerate(pool[:1000]):
 v=val(y);valid=v is not None and v.denominator==1 and 30<=v<=3600
 body.append(f'config({i},frombits({bits(y)}),{bl(valid)})')
body.append('config(1000,false,false)')
for i in range(2000):
 d=rng.choice([29,30,31,60,180,3600,3601,0,30.5]);at=rng.choice([0,999,1000,1001,1000-d-30,1000-d-29,1000-d-31,2**50,2**50+1,-1,999.5]);valid=30<=d<=3600 and int(d)==d and 0<=at<=2**50 and int(at)==at
 body.append(f'lease({i},{at},{d},{bl(valid)},{bl(valid and 1000-at>=d+30)})')
body.append('for group,n in pairs(counts) do print("COUNT",group,n,bad[group] or 0) end')
source=pre+'\nlocal DataManager=(function()\n'+a.source.read_text()+'\nend)()\n'+'\n'.join(body)
runs=[]
with tempfile.TemporaryDirectory() as td:
 path=Path(td)/'audit.luau';path.write_text(source)
 for opt in range(3):
  run=subprocess.run([str(root/'runtime/linux/luau'),f'-O{opt}',str(path)],capture_output=True,text=True,timeout=90)
  if run.returncode:raise RuntimeError(run.stderr+run.stdout[-2000:])
  counts={};diff=[]
  for line in run.stdout.splitlines():
   row=line.split('\t')
   if row[0]=='COUNT':counts[row[1]]={'checks':int(row[2]),'differences':int(row[3])}
   elif row[0]=='DIFF':diff.append(row[1:])
  assert counts.get('oracle',{}).get('checks')==96*128 and counts.get('lease_admission',{}).get('checks')==2000
  runs.append({'optimization':opt,'counts':counts,'witnesses':diff});print(opt,counts,diff[:8],flush=True)
report={'source_sha256':sha(a.source),'runner_sha256':sha(a.runner),'campaign_sha256':sha(Path(__file__)),'tool_pins':pins,'seed':a.seed,'runs':runs,'elapsed_seconds':time.monotonic()-start,'scope':'finite numeric, UTF8, configuration and lease admission checks against simulated store; not production or formal proof'}
a.out.write_text(json.dumps(report,indent=2)+'\n')
