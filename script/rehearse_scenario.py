# Runs the full TORQUE lifecycle on the local mainnet fork started by `./script/rehearse-fork.sh up` and logs every
# transaction and state read. Fork only: it talks to 127.0.0.1:8545 and uses anvil's public test keys.
#   python3 script/rehearse_scenario.py > research/fork-rehearsal-<date>.log
import json, subprocess, sys

A = "http://127.0.0.1:8545"
cfg = json.load(open("app/public/config.fork.json"))
MARKET, VAULT, USDG, NVDA, FEED = cfg["MARKET"], cfg["VAULT"], cfg["USDG"], cfg["NVDA"], cfg["FEED"]
K = {  # anvil's well-known public test keys (mnemonic "test test ... junk"); worthless outside a local fork
    "W0": ("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"),
    "W1": ("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d", "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"),
    "W2": ("0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a", "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"),
}
ERRORS = ["StaleFeed()", "PoolPriceMismatch()", "BadLeverage()", "MarginTooSmall()", "OpenInterestCap()", "UtilizationCap()",
          "TooManyPositions()", "Slippage()", "NotOwner()", "NotKnockable()", "Underwater()", "UnknownPosition()", "Unauthorized()",
          "PriceCheckFailed()", "OnlyMarket()", "CapExceeded()", "PartialFill()", "ERC4626ExceededMaxDeposit(address,uint256,uint256)"]


def cast(*a):
    r = subprocess.run(["cast", *map(str, a), "--rpc-url", A], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(r.stderr.strip())
    return r.stdout.strip()


SEL = {subprocess.run(["cast", "sig", e], capture_output=True, text=True).stdout.strip(): e for e in ERRORS}
num = lambda s: int(s.split()[0])
usd = lambda x: f"{x / 1e6:,.6f} USDG"


def send(who, to, sig, *args):
    out = json.loads(cast("send", to, sig, *map(str, args), "--private-key", K[who][0], "--json"))
    assert out["status"] in ("0x1", 1), out
    print(f"  tx {out['transactionHash']}  {who} {sig.split('(')[0]}({', '.join(map(str, args))})  block {int(out['blockNumber'], 16)}")
    return out


def refused(who, to, sig, *args):
    """Simulates a call that must revert and prints the decoded custom error."""
    r = subprocess.run(["cast", "call", to, sig, *map(str, args), "--from", K[who][1], "--rpc-url", A], capture_output=True, text=True)
    assert r.returncode != 0, f"expected a revert from {sig}"
    data = next((w for w in r.stderr.replace('"', " ").split() if w.startswith("0x") and len(w) >= 10), "")
    name = SEL.get(data[:10], data[:10] or r.stderr.strip()[:80])
    print(f"  refused: {who} {sig.split('(')[0]}({', '.join(map(str, args))}) -> {name}")


def state(label):
    held = num(cast("call", NVDA, "balanceOf(address)(uint256)", MARKET))
    ids = cast("call", MARKET, "openPositionIds()(uint256[])")
    owed = sum(num(cast("call", MARKET, "getPosition(uint256)((address,uint128,uint128,uint128,uint128,uint64))", str(i)).strip("()").split(",")[1].strip())
               for i in json.loads(ids.replace(" ", "")) ) if ids != "[]" else 0
    assets = num(cast("call", VAULT, "totalAssets()(uint256)"))
    idle = num(cast("call", VAULT, "idle()(uint256)"))
    bad = num(cast("call", MARKET, "totalBadDebt()(uint256)"))
    print(f"  [{label}] positions {ids}; NVDA held {held / 1e18:.6f} vs owed {owed / 1e18:.6f} ({'1:1' if held >= owed else 'SHORT'}); "
          f"vault assets {usd(assets)}, idle {usd(idle)}, bad debt {usd(bad)}")


def prices(label):
    p, fresh = cast("call", MARKET, "oraclePrice()(uint256,bool)").split("\n")
    twap = num(cast("call", MARKET, "poolTwapPrice()(uint256)"))
    ok = cast("call", MARKET, "isPriceOk()(bool)")
    print(f"  [{label}] feed ${num(p) / 1e6:.2f} ({'fresh' if fresh.strip() == 'true' else 'STALE'}), pool 30-min ${twap / 1e6:.2f}, both checks pass: {ok}")


info = json.loads(cast("rpc", "anvil_nodeInfo"))["forkConfig"]
print(f"TORQUE fork rehearsal. Local anvil fork of Robinhood Chain mainnet (chain {cast('chain-id')}) at block {info['forkBlockNumber']:,}.")
print(f"Fork-only contracts: TorqueMarket {MARKET}, TorqueVault {VAULT}. Not mainnet.")
print(f"Real mainnet contracts as forked: USDG {USDG}, NVDA {NVDA}, pool {cfg['POOL']}, Chainlink RHNVDA/USD {FEED}\n")

print("1. Deployed by script/Deploy.s.sol and seeded with 15 USDG in the same run; positions #1 (W0, $2 at 5x) and #2 (W1, $1 at 2x) opened.")
prices("price checks"); state("after setup")

print("\n2. LP fills the vault to its $20 cap; one more cent is refused by the contract.")
room = num(cast("call", VAULT, "maxDeposit(address)(uint256)", K["W2"][1])) - 1_000  # interest accrues every block
print(f"  maxDeposit less 0.001: {usd(room)} (fees and interest already earned count toward the cap)")
send("W2", USDG, "approve(address,uint256)", VAULT, room)
send("W2", VAULT, "deposit(uint256,address)", room, K["W2"][1])
refused("W2", VAULT, "deposit(uint256,address)", 10_000, K["W2"][1])
state("vault at cap")

print("\n3. Open: W2 opens $1 at 3x. The market buys real NVDA in the pool; the hedge stays 1:1.")
send("W2", USDG, "approve(address,uint256)", MARKET, 1_000_000)
send("W2", MARKET, "open(uint256,uint256,uint256)", 1_000_000, 30_000, 0)
state("after open")

print("\n4. Close: W1 closes #2. The vault is repaid in full and the rest is paid in USDG.")
before = num(cast("call", USDG, "balanceOf(address)(uint256)", K["W1"][1]))
send("W1", MARKET, "close(uint256,uint256)", 2, 0)
print(f"  W1 received {usd(num(cast('call', USDG, 'balanceOf(address)(uint256)', K['W1'][1])) - before)}")
state("after close")

print("\n5. Failed check: the fork's feed is replaced by a test feed printing $195.00 (fork only; the pool is not moved).")
subprocess.run(["./script/rehearse-fork.sh", "feed", "195.00"], check=True, capture_output=True)
prices("price checks")
refused("W2", MARKET, "open(uint256,uint256,uint256)", 1_000_000, 20_000, 0)
refused("W2", VAULT, "deposit(uint256,address)", 10_000, K["W2"][1])

print("\n6. Permissionless knock-out: W2, who does not own #1, knocks it out (knock-out level $%.2f >= feed $195.00)."
      % (num(cast("call", MARKET, "barrierOf(uint256)(uint256)", 1)) / 1e6))
refused("W2", MARKET, "knockOut(uint256)", 3)
send("W2", MARKET, "knockOut(uint256)", 1)
print(f"  W0 can claim {usd(num(cast('call', MARKET, 'claimable(address)(uint256)', K['W0'][1])))} (the pool was not moved, so the sale filled near the pool price)")
state("after knock-out")

print("\n7. Claim: W0 pulls the knock-out residual.")
send("W0", MARKET, "claim()")
print(f"  W0 claimable now {usd(num(cast('call', MARKET, 'claimable(address)(uint256)', K['W0'][1])))}")
state("end")
