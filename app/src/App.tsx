import { useCallback, useEffect, useMemo, useState } from "react";
import { parseUnits, type Signer } from "ethers";
import { connectWallet, isDeployed, makeReader, P, payoffAt, quote, REASONS, revertName, writers, type Config, type Position, type Snapshot } from "./chain";

const DASH = "—";
const usd = (x: number | null | undefined, d = 2) =>
  x === null || x === undefined || Number.isNaN(x) ? DASH : (x < 0 ? "−$" : "$") + Math.abs(x).toLocaleString("en-US", { minimumFractionDigits: d, maximumFractionDigits: d });
const pct = (x: number, d = 1) => (x < 0 ? "−" : "") + Math.abs(x * 100).toFixed(d) + "%";
const short = (a: string) => a.slice(0, 6) + "…" + a.slice(-4);
const ago = (s: number) => (s < 90 ? `${Math.round(s)} s` : s < 5400 ? `${Math.round(s / 60)} min` : `${(s / 3600).toFixed(1)} h`);

const SECTIONS = [
  ["open", "Open a position"],
  ["mine", "My positions"],
  ["vault", "LP vault"],
  ["solvency", "Solvency board"],
  ["all", "All positions"],
] as const;

function Logo() {
  return (
    <svg width="22" height="22" viewBox="0 0 64 64" aria-hidden="true">
      <path fill="currentColor" fillRule="evenodd" d="M62 32 L47 57.98 L17 57.98 L2 32 L17 6.02 L47 6.02 Z M28.8 10.5 L35.2 10.5 L35.2 19.92 A12.5 12.5 0 1 1 28.8 19.92 Z" />
    </svg>
  );
}

export default function App({ cfg }: { cfg: Config }) {
  const deployed = isDeployed(cfg);
  const reader = useMemo(() => makeReader(cfg), [cfg]);
  const [snap, setSnap] = useState<Snapshot | null>(null);
  const [account, setAccount] = useState<string | null>(null);
  const [signer, setSigner] = useState<Signer | null>(null);
  const [drawer, setDrawer] = useState(false);
  const [margin, setMargin] = useState("2");
  const [lev, setLev] = useState(5);
  const [lpAmt, setLpAmt] = useState("5");
  const [msg, setMsg] = useState<Record<string, string>>({});
  const [theme, setTheme] = useState<string | null>(() => document.documentElement.dataset.theme ?? null);

  const refresh = useCallback(async () => {
    try {
      setSnap(await reader.snapshot(account));
    } catch (e) {
      console.warn(e);
    }
  }, [reader, account]);

  useEffect(() => {
    refresh();
    const t = setInterval(refresh, 15_000);
    return () => clearInterval(t);
  }, [refresh]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setDrawer(false);
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const toggleTheme = () => {
    const sysDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
    const current = theme ?? (sysDark ? "dark" : "light");
    const next = current === "dark" ? "light" : "dark";
    document.documentElement.dataset.theme = next;
    try {
      localStorage.setItem("torque-theme", next);
    } catch {
      /* storage unavailable */
    }
    setTheme(next);
  };

  const connect = async () => {
    try {
      const w = await connectWallet(cfg);
      setSigner(w.signer);
      setAccount(w.account);
    } catch (e) {
      setMsg((m) => ({ ...m, wallet: (e as Error).message }));
    }
  };

  const run = async (key: string, fn: () => Promise<{ hash: string; wait: () => Promise<unknown> }>) => {
    try {
      setMsg((m) => ({ ...m, [key]: "Confirm in your wallet…" }));
      const tx = await fn();
      setMsg((m) => ({ ...m, [key]: `Submitted ${tx.hash.slice(0, 10)}…` }));
      await tx.wait();
      setMsg((m) => ({ ...m, [key]: `Confirmed ${tx.hash.slice(0, 10)}…` }));
      refresh();
    } catch (e) {
      const err = e as { shortMessage?: string; reason?: string; message?: string; revert?: { name?: string }; data?: unknown };
      const name = revertName(err);
      const why = (name && REASONS[name]) || err.shortMessage || err.reason || err.message;
      setMsg((m) => ({ ...m, [key]: "Not sent: " + why }));
    }
  };

  const price = snap?.price ?? null;
  const checksOk = !!price && price.feedFresh && price.poolAgrees;
  const m = Math.max(0, parseFloat(margin) || 0);
  const qt = quote(m, lev, price?.feed ?? 0);
  const mine = (snap?.positions ?? []).filter((p) => account && p.owner.toLowerCase() === account.toLowerCase());
  const knockable = (p: Position) =>
    !!price && price.feedFresh && (price.poolAgrees || price.feedAge <= P.TWAP_WINDOW) && price.feed <= p.barrier;

  const blocker = !deployed
    ? "Not deployed to mainnet. Values here are live reads, TORQUE formulas, or placeholders (—)."
    : !price
      ? "Reading the chain…"
      : !price.feedFresh
        ? "Paused by safety check: Chainlink has not printed in 12 hours."
        : !price.poolAgrees
          ? "Paused by safety check: the pool has moved more than 1.5% from the Chainlink price. Opens resume when they agree."
          : !account
            ? "Connect a wallet to trade."
            : "";

  const openPos = () =>
    run("open", async () => {
      const w = writers(cfg, signer!);
      const amount = parseUnits(m.toFixed(6), 6);
      await w.ensure(cfg.MARKET!, amount);
      const minOut = parseUnits(((qt.notional / price!.feed) * 0.995).toFixed(18), 18);
      return w.market.open(amount, BigInt(Math.round(lev * 10_000)), minOut);
    });
  const lp = (kind: "dep" | "wd") =>
    run("lp", async () => {
      const w = writers(cfg, signer!);
      const amount = parseUnits((parseFloat(lpAmt) || 0).toFixed(6), 6);
      if (kind === "dep") {
        await w.ensure(cfg.VAULT!, amount);
        return w.vault.deposit(amount, account!);
      }
      return w.vault.withdraw(amount, account!, account!);
    });

  const pricePill = (
    <div className="pill price-pill">
      <b>NVDA</b>
      <span className="mono">{usd(price?.feed)}</span>
      <span className="muted small hide-mobile">Chainlink RHNVDA / USD</span>
    </div>
  );
  const checkChips = (
    <>
      <CheckChip ok={price?.feedFresh} label="Fresh price" />
      <CheckChip ok={price?.poolAgrees} label="Market agrees" />
    </>
  );
  const nav = (onPick?: () => void) => (
    <nav aria-label="Sections" className="nav">
      {SECTIONS.map(([id, label]) => (
        <a key={id} href={`#${id}`} onClick={onPick}>
          {label}
        </a>
      ))}
    </nav>
  );
  const netCard = (
    <div className="net">
      <b>{cfg.environment === "fork-rehearsal" ? "Local mainnet-fork rehearsal" : deployed ? "Robinhood Chain · mainnet" : "Not deployed to mainnet"}</b>
      <span className="muted">
        {cfg.environment === "fork-rehearsal" ? (
          "Not mainnet. For screenshots and tests."
        ) : deployed ? (
          `Chain ${cfg.chainId}`
        ) : (
          <a href={`${cfg.repo}#fork-rehearsal`}>Tested on a mainnet fork</a>
        )}
      </span>
    </div>
  );

  return (
    <div className="shell">
      <aside className="sidebar">
        <a className="brand" href={cfg.landing}>
          <Logo />
          TORQUE
        </a>
        {nav()}
        <div className="sidebar-foot">
          {netCard}
          <a className="muted small" href={cfg.repo}>
            Docs and source
          </a>
        </div>
      </aside>

      <div className="col">
        <header className="topbar">
          <button type="button" className="icon-btn show-mobile" aria-label="Open menu" aria-expanded={drawer} onClick={() => setDrawer(true)}>
            <svg width="18" height="18" viewBox="0 0 18 18" fill="none" aria-hidden="true">
              <path d="M2 4.5h14M2 9h14M2 13.5h14" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
            </svg>
          </button>
          <a className="brand show-mobile" href={cfg.landing}>
            <Logo />
            TORQUE
          </a>
          <div className="hide-mobile topbar-status">
            {pricePill}
            {checkChips}
          </div>
          <button type="button" className="icon-btn hide-mobile" aria-label="Toggle colour theme" onClick={toggleTheme}>
            <svg width="18" height="18" viewBox="0 0 18 18" fill="none" aria-hidden="true">
              <circle cx="9" cy="9" r="6.5" stroke="currentColor" strokeWidth="1.6" />
              <path d="M9 2.5a6.5 6.5 0 0 1 0 13z" fill="currentColor" />
            </svg>
          </button>
          <button type="button" className="btn btn-solid connect" onClick={connect}>
            {account ? short(account) : "Connect wallet"}
          </button>
        </header>

        {cfg.environment === "fork-rehearsal" && (
          <div className="env-banner" role="note">
            Local mainnet-fork rehearsal. These contracts and positions are not on mainnet.
          </div>
        )}

        <main className="main">
          <div className="card status-card show-mobile">
            <div className="row-between">
              <b>NVDA</b>
              <span className="mono big">{usd(price?.feed)}</span>
            </div>
            <span className="muted small">Chainlink RHNVDA / USD</span>
            <div className="chips-2">{checkChips}</div>
          </div>
          {!deployed && <p className="muted small legend">— marks a TORQUE value. The contracts are not deployed to mainnet, so there is none to read. Quotes use TORQUE's own formulas at the live Chainlink price.</p>}

          <section id="open" aria-labelledby="h-open" className="grid-open">
            <div className="card">
              <h2 id="h-open">Open a long on NVDA</h2>
              <label htmlFor="margin" className="field-label">
                Margin (USDG)
              </label>
              <input id="margin" className="input mono" inputMode="decimal" value={margin} onChange={(e) => setMargin(e.target.value)} />
              <div className="field-label" id="lev-label">
                Leverage
              </div>
              <div role="radiogroup" aria-labelledby="lev-label" className="seg">
                {[2, 3, 4, 5].map((l) => (
                  <button key={l} type="button" role="radio" aria-checked={lev === l} className={lev === l ? "on" : ""} onClick={() => setLev(l)}>
                    {l}×
                  </button>
                ))}
              </div>
              <dl className="kv">
                <div><dt>You buy</dt><dd className="mono">{price ? qt.q.toFixed(5) + " NVDA" : DASH}</dd></div>
                <div><dt>Position size</dt><dd className="mono">{usd(qt.notional)}</dd></div>
                <div><dt>Borrowed from the vault</dt><dd className="mono">{usd(qt.borrow)}</dd></div>
                <div><dt>Open fee</dt><dd className="mono">{usd(qt.fee, 3)}</dd></div>
                <div><dt>Financing level (worth zero)</dt><dd className="mono">{price ? `${usd(qt.financing)} · ${pct(qt.financing / price.feed - 1)}` : DASH}</dd></div>
                <div className="strong"><dt>Knock-out level</dt><dd className="mono accent">{price ? `${usd(qt.knockOut)} · ${pct(qt.knockOut / price.feed - 1)}` : DASH}</dd></div>
                <div className="strong"><dt>Most you can lose</dt><dd className="mono">{usd(m)}</dd></div>
              </dl>
              <button type="button" className="btn btn-accent wide" disabled={!!blocker || m < P.MIN_MARGIN} onClick={openPos}>
                {checksOk || !deployed ? "Open long NVDA" : "Paused by safety check"}
              </button>
              <p className="muted small">{msg.open || blocker || "You confirm two transactions: approve USDG, then open."}</p>
            </div>
            <div className="card">
              <h3>Your payoff</h3>
              <p className="muted small">At the live Chainlink price, from TORQUE's formulas. Interest not included.</p>
              <Payoff margin={m} lev={lev} entry={price?.feed ?? 0} />
            </div>
          </section>

          <section id="mine" aria-labelledby="h-mine" className="card">
            <h2 id="h-mine">My positions</h2>
            {!deployed ? (
              <p className="muted">{DASH} No positions: the contracts are not deployed to mainnet.</p>
            ) : !account ? (
              <p className="muted">Connect a wallet to see your positions.</p>
            ) : mine.length === 0 ? (
              <p className="muted">No open positions.</p>
            ) : (
              <div className="ptable">
                <div className="prow phead" aria-hidden="true">
                  <span>Position</span><span>Size</span><span>Margin</span><span>Debt</span><span>Live P&amp;L</span><span>Knock-out</span><span>Distance</span><span></span>
                </div>
                {mine.map((p) => {
                  const value = price ? Math.max(0, p.q * price.feed - p.debt) : null;
                  const pnl = value === null ? null : value - p.margin;
                  const dist = price ? 1 - p.barrier / price.feed : null;
                  return (
                    <div className="prow" key={String(p.id)}>
                      <span data-label="Position" className="mono strong">#{String(p.id)}</span>
                      <span data-label="Size" className="mono">{p.q.toFixed(5)} NVDA</span>
                      <span data-label="Margin" className="mono">{usd(p.margin)}</span>
                      <span data-label="Debt" className="mono">{usd(p.debt)}</span>
                      <span data-label="Live P&L" className={"mono " + (pnl !== null && pnl < 0 ? "bad" : "good")}>{pnl === null ? DASH : (pnl >= 0 ? "+" : "") + usd(pnl)}</span>
                      <span data-label="Knock-out" className="mono">{usd(p.barrier)}</span>
                      <span data-label="Distance" className="mono">{dist === null ? DASH : pct(dist)}</span>
                      <span className="cell-btn">
                        <button type="button" className="btn btn-line" onClick={() => run("mine", () => writers(cfg, signer!).market.close(p.id, 0))}>Close</button>
                      </span>
                    </div>
                  );
                })}
              </div>
            )}
            <div className="claim-row">
              <span>Knock-out residual to claim: <b className="mono">{usd(snap?.claimable)}</b></span>
              <button type="button" className="btn btn-line" disabled={!deployed || !account || !snap?.claimable} onClick={() => run("mine", () => writers(cfg, signer!).market.claim())}>Claim</button>
            </div>
            {msg.mine && <p className="muted small">{msg.mine}</p>}
          </section>

          <section id="vault" aria-labelledby="h-vault" className="grid-vault">
            <div className="card">
              <h2 id="h-vault">LP vault</h2>
              <p className="strong">LP vault capped at $20 USDG for the buildathon.</p>
              <div className="capbar" aria-hidden="true">
                <span style={{ width: `${Math.min(100, ((snap?.vault?.idle ?? 0) / P.VAULT_CAP) * 100)}%` }} className="fill-fg" />
                <span style={{ width: `${Math.min(100, ((snap?.vault?.lent ?? 0) / P.VAULT_CAP) * 100)}%` }} className="fill-accent" />
              </div>
              <div className="muted small legend-row"><span><b className="fg">■</b> Cash</span><span><b className="accent">■</b> Lent</span><span>Cap $20.00</span></div>
              <div className="tiles">
                <Tile label="Cash (idle)" value={usd(snap?.vault?.idle)} />
                <Tile label="Lent to positions" value={usd(snap?.vault?.lent)} />
                <Tile label="Cap" value="$20.00" />
                <Tile label="Your share" value={usd(snap?.share)} />
              </div>
              <p className="muted small">At $20 the vault can lend up to $16: two $2 positions at 5×, or four $1 positions at 5×. LPs earn 10% APR financing and the 0.10% open fee.</p>
            </div>
            <div className="card">
              <h3>Provide liquidity</h3>
              <label htmlFor="lp-amt" className="field-label">Amount (USDG)</label>
              <input id="lp-amt" className="input mono" inputMode="decimal" value={lpAmt} onChange={(e) => setLpAmt(e.target.value)} />
              <div className="two">
                <button type="button" className="btn btn-accent" disabled={!!blocker} onClick={() => lp("dep")}>Deposit</button>
                <button type="button" className="btn btn-line" disabled={!deployed || !account} onClick={() => lp("wd")}>Withdraw</button>
              </div>
              <p className="muted small">{msg.lp || "Withdrawals come from idle cash. With no open positions you can always withdraw, even if the feed is down."}</p>
            </div>
          </section>

          <section id="solvency" aria-labelledby="h-solv" className="card">
            <div className="row-between wrap">
              <h2 id="h-solv">Solvency board</h2>
              <span className="muted small">{snap ? `Read ${new Date(snap.readAt).toLocaleTimeString()}` : "Reading…"}</span>
            </div>
            <div className="grid-solv">
              <div className="tile-box">
                <span className="muted small">Hedge against notional</span>
                <div className="kv tight">
                  <div><dt>NVDA held by the market</dt><dd className="mono">{snap?.nvdaHeld === null || snap?.nvdaHeld === undefined ? DASH : snap.nvdaHeld.toFixed(6)}</dd></div>
                  <div><dt>NVDA owed to positions</dt><dd className="mono">{snap?.positions ? snap.positions.reduce((a, p) => a + p.q, 0).toFixed(6) : DASH}</dd></div>
                  <div className="strong"><dt>Hedged</dt><dd className="mono">{snap?.positions && snap.nvdaHeld !== null ? (snap.nvdaHeld + 1e-9 >= snap.positions.reduce((a, p) => a + p.q, 0) ? "1 : 1 ✓" : "short ✕") : "1 : 1 required"}</dd></div>
                </div>
              </div>
              <CheckBox title="Check 1 · Fresh price" ok={price?.feedFresh}>
                Chainlink printed <b className="mono">{price ? ago(price.feedAge) : DASH}</b> ago. Limit: 12 h.
              </CheckBox>
              <CheckBox title="Check 2 · Market agrees" ok={price?.poolAgrees}>
                Pool 30-min average <b className="mono">{usd(price?.twap)}</b>, <b className="mono">{price ? (price.deviationBps / 100).toFixed(2) + "%" : DASH}</b> off Chainlink. Band: 1.5%.
              </CheckBox>
              <div className="tile-box">
                <span className="muted small">Exposure</span>
                <div className="kv tight">
                  <div><dt>Open interest</dt><dd className="mono">{usd(snap?.vault?.openNotional)} / $30</dd></div>
                  <div><dt>Utilisation</dt><dd className="mono">{snap?.vault ? pct(snap.vault.lent / Math.max(snap.vault.assets, 1e-9), 0) : DASH} / 80%</dd></div>
                  <div><dt>Bad debt to date</dt><dd className="mono">{usd(snap?.vault?.badDebt)}</dd></div>
                </div>
              </div>
            </div>
          </section>

          <section id="all" aria-labelledby="h-all" className="card">
            <h2 id="h-all">All open positions</h2>
            <p className="muted small">Knock-outs are permissionless. When Chainlink prints at or below a position's knock-out level, anyone can trigger it here. The vault is repaid first; the trader can claim what is left.</p>
            {!snap?.positions ? (
              <p className="muted">{DASH} No positions: the contracts are not deployed to mainnet.</p>
            ) : snap.positions.length === 0 ? (
              <p className="muted">No open positions.</p>
            ) : (
              <div className="ptable all">
                <div className="prow phead" aria-hidden="true">
                  <span>Position</span><span>Owner</span><span>Size</span><span>Knock-out</span><span>Status</span><span></span>
                </div>
                {snap.positions.map((p) => {
                  const ok = knockable(p);
                  const dist = price ? 1 - p.barrier / price.feed : null;
                  return (
                    <div className={"prow" + (ok ? " eligible" : "")} key={String(p.id)}>
                      <span data-label="Position" className="mono strong">#{String(p.id)}</span>
                      <span data-label="Owner" className="mono muted">{short(p.owner)}</span>
                      <span data-label="Size" className="mono">{p.q.toFixed(5)} NVDA</span>
                      <span data-label="Knock-out" className="mono">{usd(p.barrier)}</span>
                      <span data-label="Status" className={ok ? "accent strong" : "muted"}>{ok ? "Eligible: price at or below knock-out" : `Not eligible · ${dist === null ? DASH : pct(dist)} away`}</span>
                      <span className="cell-btn">
                        <button type="button" className={"btn " + (ok ? "btn-accent" : "btn-line")} disabled={!ok || !account} onClick={() => run("all", () => writers(cfg, signer!).market.knockOut(p.id))}>Knock out</button>
                      </span>
                    </div>
                  );
                })}
              </div>
            )}
            {msg.all && <p className="muted small">{msg.all}</p>}
          </section>
          {msg.wallet && <p className="muted small">{msg.wallet}</p>}
        </main>
      </div>

      {drawer && (
        <div className="drawer" role="dialog" aria-modal="true" aria-label="Sections">
          <div className="drawer-panel">
            <div className="row-between drawer-head">
              <span className="brand"><Logo />TORQUE</span>
              <button type="button" className="icon-btn" aria-label="Close menu" onClick={() => setDrawer(false)}>
                <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true"><path d="M3 3l10 10M13 3L3 13" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" /></svg>
              </button>
            </div>
            {nav(() => setDrawer(false))}
            <div className="sidebar-foot">
              {netCard}
              <button type="button" className="btn btn-line" onClick={toggleTheme}>Toggle colour theme</button>
              <a className="muted small" href={cfg.repo}>Docs and source</a>
            </div>
          </div>
          <button type="button" className="drawer-scrim" aria-label="Close menu" onClick={() => setDrawer(false)} />
        </div>
      )}
    </div>
  );
}

function CheckChip({ ok, label }: { ok: boolean | undefined; label: string }) {
  return (
    <span className={"chip " + (ok === undefined ? "" : ok ? "chip-ok" : "chip-bad")}>
      <b>{ok === undefined ? "…" : ok ? "✓" : "✕"}</b> {label}
    </span>
  );
}

function CheckBox({ title, ok, children }: { title: string; ok: boolean | undefined; children: React.ReactNode }) {
  return (
    <div className={"tile-box" + (ok === false ? " box-bad" : "")}>
      <div className="row-between">
        <span className="muted small">{title}</span>
        <b className={ok === undefined ? "muted" : ok ? "good" : "bad"}>{ok === undefined ? "…" : ok ? "✓ Pass" : "✕ Fail"}</b>
      </div>
      <p className="small">{children}</p>
    </div>
  );
}

function Tile({ label, value }: { label: string; value: string }) {
  return (
    <div className="tile-box">
      <span className="muted small">{label}</span>
      <span className="mono tile-num">{value}</span>
    </div>
  );
}

function Payoff({ margin, lev, entry }: { margin: number; lev: number; entry: number }) {
  if (!entry || margin <= 0) return <p className="muted">{DASH}</p>;
  const q = quote(margin, lev, entry);
  const lo = entry * 0.72, hi = entry * 1.2;
  const W = 1000, H = 340, x0 = 60, x1 = 960, y0 = 20, y1 = 320;
  const yMax = payoffAt(hi, margin, lev, entry), yMin = -margin * 1.15;
  const X = (v: number) => x0 + ((v - lo) / (hi - lo)) * (x1 - x0);
  const Y = (v: number) => y0 + ((yMax - v) / (yMax - yMin)) * (y1 - y0);
  const pts = [lo, q.knockOut, hi].map((x) => `${X(x).toFixed(1)},${Y(payoffAt(x, margin, lev, entry)).toFixed(1)}`).join(" ");
  return (
    <>
      <div className="chart-scroll">
        <svg role="img" aria-label={`Payoff at ${lev}x: profit rises with NVDA above the knock-out at ${usd(q.knockOut)}; below it the loss stops at the margin, ${usd(margin)}.`} viewBox={`0 0 ${W} ${H}`} className="chart">
          <line x1={x0} x2={x1} y1={Y(0)} y2={Y(0)} className="axis" />
          <line x1={x0} x2={X(q.knockOut)} y1={Y(-margin)} y2={Y(-margin)} className="floor" />
          <line x1={X(q.knockOut)} x2={X(q.knockOut)} y1={y0} y2={y1} className="ko-line" />
          <line x1={X(q.financing)} x2={X(q.financing)} y1={y0} y2={y1} className="fin-line" />
          <line x1={X(entry)} x2={X(entry)} y1={y0} y2={y1} className="entry-line" />
          <polyline points={pts} className="curve" />
          <circle cx={X(q.knockOut)} cy={Y(payoffAt(q.knockOut, margin, lev, entry))} r="9" className="dot-accent" />
          <circle cx={X(entry)} cy={Y(payoffAt(entry, margin, lev, entry))} r="7" className="dot-fg" />
        </svg>
      </div>
      <p className="muted small show-mobile">Chart scrolls sideways →</p>
      <div className="legend-grid small">
        <span><b className="accent">●</b> Knock-out {usd(q.knockOut)}</span>
        <span>┆ Worth zero {usd(q.financing)}</span>
        <span><b>●</b> Entry {usd(entry)}</span>
        <span><b className="accent">– –</b> Floor: {usd(-margin)}</span>
      </div>
    </>
  );
}
