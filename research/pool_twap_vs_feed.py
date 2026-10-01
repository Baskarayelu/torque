import json, bisect, datetime, math
def load(lf, af):
    logs=json.load(open(lf)); anchors=json.load(open(af)); bs=[a[0] for a in anchors]
    def ts(b):
        i=min(max(bisect.bisect_right(bs,b)-1,0),len(bs)-2); (x0,t0),(x1,t1)=anchors[i],anchors[i+1]
        return t0+(t1-t0)*(b-x0)/(x1-x0)
    out=[]
    for l in logs:
        d=l["data"][2:]; tick=int(d[256:320],16)
        if tick>=2**255: tick-=2**256
        out.append((ts(int(l["blockNumber"],16)),tick))
    return out
sw=sorted(load("swaps_weekend.json","anchors_weekend.json")+load("swaps.json","anchors.json"))
times=[s[0] for s in sw]
rounds=json.load(open("nvda_rounds.json")); rt=[r[2] for r in rounds]
def price_of_tick(t): return 1e18/(1.0001**t)/1e6
def twap(t, W=1800):
    # time-weighted mean tick over [t-W, t] using the tick in force after each swap
    a=t-W; i=bisect.bisect_right(times,a)-1
    if i<0: return None
    acc=0; cur=sw[i][1]; last=a; j=i+1
    while j<len(sw) and sw[j][0]<=t:
        acc+=cur*(sw[j][0]-last); last=sw[j][0]; cur=sw[j][1]; j+=1
    acc+=cur*(t-last)
    return price_of_tick(acc/W)
def feed_at(t):
    i=bisect.bisect_right(rt,t)-1
    return rounds[i][1], t-rounds[i][2]
def is_weekend(t):
    d=datetime.datetime.utcfromtimestamp(t)
    return (d.weekday()==4 and d.hour>=20) or d.weekday()==5 or d.weekday()==6
start=times[0]+1800; end=min(times[-1], rt[-1]+3600)
wk=[]; we=[]; series=[]
t=start
while t<end:
    tw=twap(t); fp,age=feed_at(t)
    if tw:
        dev=(tw/fp-1)*100
        (we if is_weekend(t) else wk).append((dev,age,t))
        series.append((t,dev,age))
    t+=300
def stats(name,arr):
    a=sorted(abs(x[0]) for x in arr)
    q=lambda p:a[min(len(a)-1,int(p*len(a)))]
    print(f"{name}: n={len(a)} |twap-feed| p50 {q(.5):.3f}% p95 {q(.95):.3f}% p99 {q(.99):.3f}% max {a[-1]:.3f}%")
    for band in (1.0,1.5,2.0):
        print(f"   share of time outside ±{band}%: {sum(1 for x in a if x>band)/len(a)*100:.1f}%")
stats("WEEKDAY (in session)",wk); stats("WEEKEND (feed frozen)",we)
# weekday: deviation when the feed updated within the last 30 min (TWAP lag during moves)
rec=[x for x in wk if x[1]<=1800]; stats("WEEKDAY, feed updated <30min ago",rec)
print("weekend timeline (hourly):")
for t,dev,age in series:
    d=datetime.datetime.utcfromtimestamp(t)
    if is_weekend(t) and d.minute<5: print(f"  {d:%a %H:%M}  twap vs frozen feed {dev:+.2f}%  feed age {age/3600:.1f}h")
