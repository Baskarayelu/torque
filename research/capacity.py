#!/usr/bin/env python3
"""How big TORQUE's vault would need to be to serve the demand we measured.

Measured (research/chain-snapshot-2026-10-03.json, block 78,677,903): USDG that borrowers have taken from Morpho's
USDG markets that accept Robinhood stock tokens as collateral. TORQUE lends at most 80% of its vault, so serving the
same borrowing needs borrowed / 0.8 of USDG in the vault. Also reads the NVDA/USDG pool's balances now, the venue every
TORQUE position is bought in.

That this borrowing would move to knock-outs is an inference, not a measurement.

  python3 research/capacity.py     (RH_RPC_URL optional)
"""
import json, os, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
RPC = os.environ.get("RH_RPC_URL", "https://rpc.mainnet.chain.robinhood.com")
POOL, USDG, NVDA = "0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3", "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168", "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC"
UTIL_CAP, VAULT_NOW = 0.80, 20.0


def call(method, params):
    req = urllib.request.Request(RPC, json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(), {"Content-Type": "application/json", "User-Agent": "torque-capacity"})
    return json.load(urllib.request.urlopen(req, timeout=30))["result"]


snap = json.load(open(os.path.join(HERE, "chain-snapshot-2026-10-03.json")))
block = int(call("eth_blockNumber", []), 16)
bal = lambda token: int(call("eth_call", [{"to": token, "data": "0x70a08231" + POOL[2:].lower().rjust(64, "0")}, hex(block)]), 16)
pool_usdg, pool_nvda = bal(USDG) / 1e6, bal(NVDA) / 1e18

for label, borrowed in (("all 167 stock-token markets", snap["borrowed"]), ("the NVDA market", snap["nvdaBorrowed"])):
    need = borrowed / UTIL_CAP
    print(f"{label}: ${borrowed:,.0f} borrowed at block {snap['block']:,} -> a TORQUE vault of ${need:,.0f} at 80% utilisation ({need / VAULT_NOW:,.0f}x today's $20)")
print(f"NVDA/USDG pool at block {block:,}: {pool_usdg:,.0f} USDG and {pool_nvda:,.1f} NVDA")

# What a trader does today instead: loop on Morpho. The largest NVDA/USDG market's parameters, read from Morpho Blue.
MORPHO, NVDA_MARKET = "0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010", "8b16891f032a93b771347c9cb470a780e6699dd701553d3402aa3cdba6189c3e"
params = call("eth_call", [{"to": MORPHO, "data": "0x2c3c9157" + NVDA_MARKET}, hex(block)])  # idToMarketParams(bytes32)
lltv = int(params[2 + 64 * 4: 2 + 64 * 5], 16) / 1e18
lif = min(1.15, 1 / (0.3 * lltv + 0.7))  # Morpho's documented liquidation incentive factor
print(f"Morpho NVDA/USDG market 0x{NVDA_MARKET[:8]}…: LLTV {lltv:.1%} -> looping tops out at {1 / (1 - lltv):.2f}x before any safety buffer; "
      f"a liquidation pays the liquidator a {lif - 1:.1%} bonus out of the borrower's collateral")
