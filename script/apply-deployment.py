# Applies deployment.json to every surface that says where TORQUE runs. See deployment/README.md.
#   python3 script/apply-deployment.py            (LANDING_DIR defaults to ../torque-landing; skipped if absent)
#   SKIP_CHAIN_CHECK=1 python3 script/apply-deployment.py   (offline; mainnet addresses are not checked for code)
import json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
d = json.load(open("deployment.json"))
status = d["status"]
if status not in ("fork-only", "mainnet"):
    sys.exit(f"deployment.json: status must be fork-only or mainnet, not {status!r}")
m, f = d["mainnet"], d["fork"]
ADDR = re.compile(r"^0x[0-9a-fA-F]{40}$")

if status == "mainnet":
    for k in ("MARKET", "VAULT", "deployBlock", "deployedAt", "seedTx"):
        if not m.get(k):
            sys.exit(f"deployment.json: status is mainnet but mainnet.{k} is empty")
    for k in ("MARKET", "VAULT"):
        if not ADDR.match(m[k]):
            sys.exit(f"deployment.json: mainnet.{k} is not an address: {m[k]}")
    if not os.environ.get("SKIP_CHAIN_CHECK"):
        rpc = os.environ.get("RH_RPC_URL", "https://rpc.mainnet.chain.robinhood.com")
        if subprocess.run(["cast", "chain-id", "--rpc-url", rpc], capture_output=True, text=True).stdout.strip() != str(d["chainId"]):
            sys.exit("RPC is not Robinhood Chain mainnet")
        for k in ("MARKET", "VAULT"):
            code = subprocess.run(["cast", "code", m[k], "--rpc-url", rpc], capture_output=True, text=True).stdout.strip()
            if len(code) <= 2:
                sys.exit(f"no contract code at mainnet.{k} {m[k]} on chain {d['chainId']}")

v = {
    "repo": d["repo"], "landing": d["landing"], "dashboard": d["dashboard"], "dashboardHost": d["dashboard"].split("//")[1],
    "explorer": d["explorer"], "chainId": d["chainId"], "MARKET": m["MARKET"] or "", "VAULT": m["VAULT"] or "",
    "deployBlockFmt": f"{m['deployBlock']:,}" if m["deployBlock"] else "", "deployedAt": m["deployedAt"] or "",
    "seedTx": m["seedTx"] or "", "deployer": m.get("deployer") or "", "forkBlockFmt": f"{f['block']:,}", "forkDate": f["date"], "forkLog": f["log"],
}
for k, h in (m.get("txs") or {}).items():
    v[f"tx_{k}"], v[f"tx_{k}_s"] = h, f"{h[:10]}…{h[-6:]}"
if status == "mainnet":
    v["contractField"] = f"Robinhood Chain: {m['MARKET']} — TorqueMarket\nRobinhood Chain: {m['VAULT']} — TorqueVault (USDG LP)"
else:
    v["contractField"] = (f"Not deployed to mainnet. Built and tested against Robinhood Chain mainnet (chain {d['chainId']}) state; "
                          f"fork rehearsal log: {d['repo'].split('//')[1]}/blob/main/{f['log']}")
if len(v["contractField"]) > 300:
    sys.exit(f"contract field is {len(v['contractField'])} characters; HackQuest allows 300")


def render(name):
    t = open(f"deployment/{status}/{name}").read()
    out = re.sub(r"\{\{(\w+)\}\}", lambda x: str(v[x.group(1)]), t)
    assert "{{" not in out, name
    return out.rstrip("\n")


changed = []


def write(path, text):
    old = open(path).read() if os.path.exists(path) else None
    if old != text:
        open(path, "w").write(text)
        changed.append(path)


# README: replace the two marked blocks
readme = open("README.md").read()
for block in ("status", "deployments"):
    pat = re.compile(rf"(<!-- deployment:{block} -->\n)(?:.*?\n)?(<!-- /deployment:{block} -->)", re.S)
    if not pat.search(readme):
        sys.exit(f"README.md is missing the deployment:{block} markers")
    readme = pat.sub(lambda x: x.group(1) + render(f"readme-{block}.md") + "\n" + x.group(2), readme)
write("README.md", readme)

# Submission text; blocks headed "(≤300 characters)" are checked and counted
sub = render("submission.md")
def _count(mt):
    body = mt.group(2).strip()
    if len(body) > 300:
        sys.exit(f"submission block '{mt.group(1)}' is {len(body)} characters; the limit is 300")
    return f"{mt.group(1)}\n{body}\n\n({len(body)} of 300 characters)\n\n"
sub = re.sub(r"(## [^\n]*\(≤300 characters\))\n(.*?)\n\n", _count, sub, flags=re.S)
write("submission/SUBMISSION.md", sub + f"\n\n({len(v['contractField'])} of 300 characters)\n")

# Narration: paste-ready ElevenLabs text and the per-shot JSON the build scripts use
for kind in ("demo", "pitch"):
    segs = re.findall(r"^## (\w+)\n(.*?)(?=^## |\Z)", open(f"deployment/{status}/{kind}.txt").read(), re.S | re.M)
    segs = [(i, t.strip()) for i, t in segs]
    write(f"video/narration/{kind}-elevenlabs.txt", "\n\n[long pause]\n\n".join(t for _, t in segs) + "\n")
    write(f"video/{kind}-narration.json", json.dumps([{"id": i, "text": t} for i, t in segs], indent=1, ensure_ascii=False) + "\n")

# Paste-ready text for both states, so either voice track can be generated ahead of the switch
for st in ("fork-only", "mainnet"):
    for kind in ("demo", "pitch"):
        segs = re.findall(r"^## (\w+)\n(.*?)(?=^## |\Z)", open(f"deployment/{st}/{kind}.txt").read(), re.S | re.M)
        write(f"video/narration/{st}/{kind}-elevenlabs.txt", "\n\n[long pause]\n\n".join(t.strip() for _, t in segs) + "\n")

# Dashboard config (public repo) and the fork build's copy of the shared fields
for path in ("app/public/config.json", "app/public/config.fork.json"):
    if not os.path.exists(path):
        continue
    c = json.load(open(path))
    c.update({"repo": d["repo"], "landing": d["landing"], "explorer": d["explorer"], "chainId": d["chainId"]})
    if path.endswith("config.json"):
        c.update({"deployment": status, "MARKET": m["MARKET"] if status == "mainnet" else None, "VAULT": m["VAULT"] if status == "mainnet" else None})
    else:
        c["deployment"] = "fork-only"
    write(path, json.dumps(c, indent=2, ensure_ascii=False) + "\n")

# Landing page config (private repo, sibling checkout)
landing = os.environ.get("LANDING_DIR", os.path.join(os.path.dirname(ROOT), "torque-landing"))
lc_path = os.path.join(landing, "config.json")
if os.path.exists(lc_path):
    lc = json.load(open(lc_path))
    lc.update({"status": status, "MARKET": m["MARKET"] if status == "mainnet" else None, "VAULT": m["VAULT"] if status == "mainnet" else None,
               "deployBlock": m["deployBlock"] if status == "mainnet" else None, "chainId": d["chainId"], "explorer": d["explorer"],
               "dashboard": d["dashboard"], "repo": d["repo"]})
    write(lc_path, json.dumps(lc, indent=2, ensure_ascii=False) + "\n")
else:
    print(f"note: no landing checkout at {landing}; its config.json was not updated")

# A fork-only build must not claim mainnet anywhere it is generated from
if status == "fork-only":
    claims = re.compile(r"live on (robinhood chain )?mainnet|deployed (to|on) (robinhood chain )?mainnet(?! state)|is live", re.I)
    for path in ["README.md", "submission/SUBMISSION.md", "video/narration/demo-elevenlabs.txt", "video/narration/pitch-elevenlabs.txt"]:
        for line in open(path):
            if claims.search(line) and not re.search(r"not deployed|isn't deployed|is not deployed", line, re.I):
                sys.exit(f"fork-only output claims mainnet in {path}: {line.strip()[:120]}")

print(f"status: {status}")
print("changed:", ", ".join(changed) if changed else "nothing (already applied)")
print(f"contract field ({len(v['contractField'])}/300):\n{v['contractField']}")
