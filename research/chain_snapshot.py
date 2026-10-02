# Reads the headline numbers at one block: USDG totalSupply, and the Morpho Blue markets that lend USDG against a
# Robinhood Stock Token (from morpho_markets_2026-10-02.json: 171 stock-collateral markets, 167 of them lend USDG,
# the other 4 lend WETH). Output: chain-snapshot-<date>.json. The public RPC is pruned, so old blocks may not be
# readable; run without a block for current values.
#   python3 research/chain_snapshot.py [block]
import json, subprocess, sys, os, datetime, time
R = os.environ.get("RH_RPC_URL", "https://rpc.mainnet.chain.robinhood.com")
USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168"; MORPHO = "0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010"
here = os.path.dirname(os.path.abspath(__file__))
markets = json.load(open(os.path.join(here, "morpho_markets_2026-10-02.json")))
usdg_mkts = [m for m in markets if "Robinhood Token" in (m.get("collName") or "") and m["loan"].lower() == USDG.lower()]
nvda = [max((m for m in usdg_mkts if m["collSym"] == "NVDA"), key=lambda m: m["supply"])]  # "the NVDA market": the largest of 15
def cast(*a):
    for k in range(8):  # the public RPC rate-limits; retry, then fail loudly
        r = subprocess.run(["cast", *a, "--rpc-url", R], capture_output=True, text=True)
        if r.returncode == 0: return r.stdout.strip()
        time.sleep(2 + 2 * k)
    raise SystemExit("RPC failed: " + " ".join(a[:3]) + " :: " + r.stderr[:200])
block = int(sys.argv[1]) if len(sys.argv) > 1 else int(cast("block-number"))
ts = int(cast("block", str(block), "-f", "timestamp"))
supply = int(cast("call", USDG, "totalSupply()(uint256)", "-b", str(block)).split()[0])
lent = bor = nl = nb = 0
for m in usdg_mkts:
    v = cast("call", MORPHO, "market(bytes32)(uint128,uint128,uint128,uint128,uint128,uint128)", m["id"], "-b", str(block)).split("\n")
    s, b = int(v[0].split()[0]), int(v[2].split()[0]); lent += s; bor += b
    if m in nvda: nl += s; nb += b
out = {"block": block, "time": datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
       "usdgSupply": supply / 1e6, "markets": len(usdg_mkts), "lent": lent / 1e6, "borrowed": bor / 1e6, "util": bor / lent,
       "nvdaLent": nl / 1e6, "nvdaBorrowed": nb / 1e6, "nvdaUtil": nb / nl if nl else 0}
print(json.dumps(out, indent=1))
