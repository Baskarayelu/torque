import subprocess, json, time, sys
R="https://rpc.mainnet.chain.robinhood.com"; M="0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010"
T="0xac4b2400f169220b0c0afdde7a0b32e775ba727ea1cb30b35f935cdaab8683ac"
def run(args, tries=6):
    for a in range(tries):
        r=subprocess.run(args,capture_output=True,text=True)
        if r.returncode==0: return r.stdout
        time.sleep(3+2*a)
    raise SystemExit("FAILED: "+" ".join(args[:4])+" :: "+r.stderr[:200])
B=int(run(["cast","block-number","--rpc-url",R]))
logs=[]
def fetch(a,b):
    for k in range(6):
        r=subprocess.run(["cast","logs","--address",M,T,"--from-block",str(a),"--to-block",str(b),"--rpc-url",R,"--json"],capture_output=True,text=True)
        if r.returncode==0 and r.stdout.strip().startswith("["): return json.loads(r.stdout)
        if "exceeds limit" in r.stderr: m=(a+b)//2; return fetch(a,m)+fetch(m+1,b)
        time.sleep(4+2*k)
    raise SystemExit("log fetch failed %d-%d: %s"%(a,b,r.stderr[:200]))
for st in range(0,B+1,5_000_000):
    logs+=fetch(st,min(st+4_999_999,B)); time.sleep(0.5)
print("CreateMarket events:",len(logs),file=sys.stderr)
cache={}
def tok(addr):
    if addr in cache: return cache[addr]
    if int(addr,16)==0: cache[addr]=("(none)","",0); return cache[addr]
    sym=subprocess.run(["cast","call",addr,"symbol()(string)","--rpc-url",R],capture_output=True,text=True).stdout.strip().strip('"')
    name=subprocess.run(["cast","call",addr,"name()(string)","--rpc-url",R],capture_output=True,text=True).stdout.strip().strip('"')
    dec=subprocess.run(["cast","call",addr,"decimals()(uint8)","--rpc-url",R],capture_output=True,text=True).stdout.strip().split()[:1]
    cache[addr]=(sym,name,int(dec[0]) if dec else 0); time.sleep(0.15); return cache[addr]
rows=[]
for l in logs:
    d=l["data"][2:]; mid=l["topics"][1]
    loan="0x"+d[24:64]; coll="0x"+d[88:128]
    st=run(["cast","call",M,"market(bytes32)(uint128,uint128,uint128,uint128,uint128,uint128)",mid,"--rpc-url",R]).strip().splitlines()
    vals=[int(x.split()[0]) for x in st]
    ls,ln,ld=tok(loan); cs,cn,cd=tok(coll)
    rows.append(dict(id=mid,loan=loan,loanSym=ls,loanDec=ld,coll=coll,collSym=cs,collName=cn,supply=vals[0],borrow=vals[2]))
    time.sleep(0.15)
json.dump(rows,open("morpho_markets.json","w"),indent=1)
print("markets",len(rows))
