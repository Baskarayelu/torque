#!/usr/bin/env python3
"""LP backtest: run TORQUE's vault model over the last 90 days of real NVDA prices.

Prices are every Chainlink RHNVDA/USD print on Robinhood Chain (the feed TORQUE reads), fetched from chain with
batched eth_call getRoundData and cached in research/data/. Knock-outs can only happen at a fresh print, so the print
series is the path the contract would actually have acted on, weekend gaps included.

The contract's own formulas (src/TorqueMarket.sol):
  fee = margin * L * 0.10%;  equity = margin - fee;  notional = equity * L;  borrow = notional - equity
  debt(t) = borrow * (1 + 10% * t / 365d)          knock-out level = debt / q * 1.05
  knock-out at the first fresh print <= level; the market sells q into the pool; the vault is repaid first and
  any shortfall is bad debt (an LP loss). An owner can only close when the sale covers the debt.
  NAV marks each loan at min(debt, q * price * (1 - slippage)), as markedDebt() does.

Demand is an assumption, not a measurement, and it is the one that favours LP income and maximises LP risk:
traders borrow every dollar the vault may lend (utilisation pinned at a target, at most the 80% limit), reopen as
soon as a slot frees up, and close after a holding period. Lower demand scales income down roughly linearly.

  python3 research/lp_backtest.py            # uses the cached prints if present
  RH_RPC_URL=... python3 research/lp_backtest.py --refresh
"""
import bisect, csv, datetime as dt, json, os, statistics, sys, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
ROUNDS_CSV = os.path.join(DATA, "rhnvda_rounds.csv")
RPC = os.environ.get("RH_RPC_URL", "https://rpc.mainnet.chain.robinhood.com")
PROXY = "0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15"

# contract constants
APR, FEE, KO_BUFFER, MAX_FEED_AGE = 0.10, 0.001, 0.05, 12 * 3600
VAULT_CAP, OI_CAP, UTIL_CAP = 20.0, 30.0, 0.80
YEAR = 365 * 86400
SLIPPAGE = 0.002  # pool sale below the print: the fork sandwich runs filled 0.10-0.17% off Chainlink; 0.20% is conservative
WINDOW_DAYS = 90


# ------------------------------------------------------------------ chain reads
def rpc(calls):
    body = json.dumps([{"jsonrpc": "2.0", "id": i, "method": m, "params": p} for i, (m, p) in enumerate(calls)]).encode()
    for attempt in range(8):
        try:
            req = urllib.request.Request(RPC, body, {"Content-Type": "application/json", "User-Agent": "torque-lp-backtest"})
            out = json.load(urllib.request.urlopen(req, timeout=60))
            out = sorted(out, key=lambda r: r["id"])
            if any("error" in r for r in out):
                raise RuntimeError(next(r["error"] for r in out if "error" in r))
            return [r["result"] for r in out]
        except Exception as e:  # throttled public RPC: back off and retry, never return a partial answer
            if attempt == 7:
                raise
            time.sleep(2 * (attempt + 1))
            print(f"  retry {attempt + 1}: {str(e)[:80]}", file=sys.stderr)


def call(to, data):
    return ("eth_call", [{"to": to, "data": data}, "latest"])


def fetch_rounds():
    """Every round of every phase behind the proxy, as (phase, aggRound, price, updatedAt)."""
    phase = int(rpc([call(PROXY, "0x58303b10")])[0], 16)  # phaseId()
    rows = []
    for ph in range(1, phase + 1):
        agg = "0x" + rpc([call(PROXY, "0xc1597304" + f"{ph:064x}")])[0][-40:]  # phaseAggregators(uint16)
        last = int(rpc([call(agg, "0x668a0f02")])[0], 16)  # latestRound()
        print(f"phase {ph}: aggregator {agg}, {last} rounds", file=sys.stderr)
        for start in range(1, last + 1, 50):
            ids = range(start, min(last, start + 49) + 1)
            res = rpc([call(agg, "0x9a6fc8f5" + f"{r:064x}") for r in ids])  # getRoundData(uint80)
            for r, hexv in zip(ids, res):
                w = [int(hexv[2 + 64 * k: 2 + 64 * (k + 1)], 16) for k in range(5)]
                ans = w[1] - (1 << 256) if w[1] >> 255 else w[1]
                rows.append((ph, r, ans / 1e8, w[3]))
            time.sleep(0.3)
    os.makedirs(DATA, exist_ok=True)
    with open(ROUNDS_CSV, "w", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(["phase", "round", "price_usd", "updated_at"])
        wr.writerows(rows)
    return rows


def load_rounds(refresh):
    if refresh or not os.path.exists(ROUNDS_CSV):
        return fetch_rounds()
    with open(ROUNDS_CSV) as f:
        return [(int(r["phase"]), int(r["round"]), float(r["price_usd"]), int(r["updated_at"])) for r in csv.DictReader(f)]


def clean(rows):
    """Drop prints that are not prices (e.g. an initialisation value), and say which."""
    prices = sorted(r[2] for r in rows)
    med = prices[len(prices) // 2]
    good = [r for r in rows if 0.2 * med < r[2] < 5 * med]
    dropped = [r for r in rows if r not in good]
    good.sort(key=lambda r: r[3])
    return good, dropped


# ------------------------------------------------------------------ model
class Pos:
    __slots__ = ("t0", "q", "borrow", "margin", "notional", "slot")

    def __init__(self, t0, price, margin, lev, slot):
        fee = margin * lev * FEE
        equity = margin - fee
        self.notional = equity * lev
        self.borrow = self.notional - equity
        self.q = self.notional / price
        self.t0, self.margin, self.slot = t0, margin, slot

    def debt(self, t):
        return self.borrow * (1 + APR * (t - self.t0) / YEAR)

    def barrier(self, t):
        return self.debt(t) / self.q * (1 + KO_BUFFER)


def simulate(prints, lev, target_util, hold_days, slots=8, vault=VAULT_CAP, oi_cap=OI_CAP):
    """prints: [(t, price)] sorted. Returns a dict of results and the NAV series."""
    t_start, t_end = prints[0][0], prints[-1][0]
    idle = vault
    lent_target = vault * min(target_util, UTIL_CAP)
    per_slot_borrow = lent_target / slots
    equity_per = per_slot_borrow / (lev - 1)                      # borrow = equity * (L - 1)
    margin_per = equity_per / (1 - lev * FEE)                     # equity = margin - margin * L * fee
    open_pos, events, nav_series = [], [], []
    fees = interest = bad_debt = 0.0
    refused_days, ko_count, close_count, opens = set(), 0, 0, 0
    worst_ko = None
    hold = hold_days * 86400

    def nav(t, price):
        marked = sum(min(p.debt(t), p.q * price * (1 - SLIPPAGE)) for p in open_pos)
        return idle + marked

    for i, (t, price) in enumerate(prints):
        # 1) knock-outs: at a fresh print at or below a position's level, anyone triggers it
        for p in list(open_pos):
            if price <= p.barrier(t):
                d = p.debt(t)
                proceeds = p.q * price * (1 - SLIPPAGE)
                repaid = min(d, proceeds)
                short = d - repaid
                idle += repaid
                interest += repaid - p.borrow if repaid > p.borrow else 0.0
                bad_debt += short
                if short > 0 and (worst_ko is None or short > worst_ko["bad_debt"]):
                    worst_ko = {"time": t, "price": price, "bad_debt": short, "borrow": p.borrow}
                gap = price / prints[i - 1][1] - 1 if i else 0.0
                events.append({"time": t, "kind": "knock-out", "price": price, "gap_from_prev_print": gap, "bad_debt": short})
                open_pos.remove(p)
                ko_count += 1
        # 2) closes after the holding period, only if the sale covers the debt (else the contract reverts Underwater)
        for p in list(open_pos):
            if t - p.t0 >= hold:
                d = p.debt(t)
                proceeds = p.q * price * (1 - SLIPPAGE)
                if proceeds >= d:
                    idle += d
                    interest += d - p.borrow
                    open_pos.remove(p)
                    close_count += 1
        # 3) opens: every free slot reopens at this print (a print is fresh by definition), within the caps
        free = [s for s in range(slots) if s not in {p.slot for p in open_pos}]
        for s in free:
            lent = sum(p.borrow for p in open_pos)
            oi = sum(p.notional for p in open_pos)
            nav_now = nav(t, price)
            fee = margin_per * lev * FEE
            notional = (margin_per - fee) * lev
            borrow = notional - (margin_per - fee)
            if (lent + borrow) > UTIL_CAP * nav_now + 1e-9 or oi + notional > oi_cap * vault / VAULT_CAP + 1e-9 or borrow > idle + 1e-9:
                refused_days.add(dt.datetime.utcfromtimestamp(t).date().isoformat())
                continue
            p = Pos(t, price, margin_per, lev, s)
            idle -= p.borrow
            idle += fee
            fees += fee
            open_pos.append(p)
            opens += 1
        nav_series.append((t, nav(t, price), sum(p.borrow for p in open_pos) / max(nav(t, price), 1e-9)))

    # close the books at the last print (mark-to-market, no forced sale)
    end_nav = nav_series[-1][1]
    days = (t_end - t_start) / 86400
    ret = end_nav / vault - 1
    peak, mdd, mdd_at = -1, 0.0, None
    for t, v, _ in nav_series:
        if v > peak:
            peak, peak_t = v, t
        if peak > 0 and (v / peak - 1) < mdd:
            mdd, mdd_at = v / peak - 1, (peak_t, t)
    # worst calendar day by NAV change (last NAV of the day vs last NAV of the previous day)
    by_day = {}
    for t, v, _ in nav_series:
        by_day[dt.datetime.utcfromtimestamp(t).date()] = v
    days_sorted = sorted(by_day)
    daily = [(d, by_day[d] / by_day[p] - 1) for p, d in zip(days_sorted, days_sorted[1:])]
    worst_day = min(daily, key=lambda x: x[1]) if daily else (None, 0.0)
    utils = [u for _, _, u in nav_series]
    return {
        "leverage": lev, "target_utilisation": target_util, "hold_days": hold_days,
        "opens": opens, "closes": close_count, "knock_outs": ko_count,
        "fees_usdg": fees, "interest_usdg": interest, "bad_debt_usdg": bad_debt,
        "return_pct": ret * 100, "annualised_pct": ((1 + ret) ** (365 / days) - 1) * 100 if days > 0 else 0,
        "max_drawdown_pct": mdd * 100,
        "max_drawdown_window": [dt.datetime.utcfromtimestamp(x).isoformat() + "Z" for x in mdd_at] if mdd_at else None,
        "worst_day": [worst_day[0].isoformat() if worst_day[0] else None, worst_day[1] * 100],
        "mean_utilisation_pct": statistics.mean(utils) * 100,
        "days_an_open_was_refused_by_a_cap": sorted(refused_days),
        "worst_bad_debt_event": worst_ko,
        "knock_out_events": events,
        "nav_series": nav_series,
    }


def stress_table():
    """A single overnight gap straight through the knock-out level, for a fresh position: LP loss per $1 lent."""
    rows = []
    for lev in (2, 3, 4, 5):
        q = quote_q(lev)
        fin_drop = 1 - (q["borrow"] / q["q"]) / 1.0        # entry price normalised to 1
        ko_drop = 1 - (q["borrow"] / q["q"]) * (1 + KO_BUFFER)
        row = {"leverage": lev, "knock_out_drop_pct": ko_drop * 100, "worth_zero_drop_pct": fin_drop * 100, "loss_per_dollar_lent": {}}
        for gap in (0.10, 0.15, 0.20, 0.25, 0.30, 0.40):
            proceeds = q["q"] * (1 - gap) * (1 - SLIPPAGE)
            row["loss_per_dollar_lent"][f"-{int(gap * 100)}%"] = max(0.0, q["borrow"] - proceeds) / q["borrow"]
        rows.append(row)
    return rows


def quote_q(lev, margin=1.0, price=1.0):
    fee = margin * lev * FEE
    equity = margin - fee
    notional = equity * lev
    return {"borrow": notional - equity, "q": notional / price}


# ------------------------------------------------------------------ report
def svg_chart(series, prints, path, title):
    W, H, L, R, T, B = 900, 360, 60, 20, 30, 40
    t0, t1 = series[0][0], series[-1][0]
    vs = [v for _, v, _ in series]
    ps = [p for _, p in prints]
    vmin, vmax = min(vs) * 0.999, max(vs) * 1.001
    pmin, pmax = min(ps) * 0.98, max(ps) * 1.02
    X = lambda t: L + (t - t0) / (t1 - t0) * (W - L - R)
    Y = lambda v: T + (vmax - v) / (vmax - vmin) * (H - T - B)
    Yp = lambda v: T + (pmax - v) / (pmax - pmin) * (H - T - B)
    nav = " ".join(f"{X(t):.1f},{Y(v):.1f}" for t, v, _ in series)
    px = " ".join(f"{X(t):.1f},{Yp(p):.1f}" for t, p in prints if t0 <= t <= t1)
    ticks = []
    d = dt.datetime.utcfromtimestamp(t0).date()
    while True:
        d = d + dt.timedelta(days=1)
        ts = dt.datetime(d.year, d.month, d.day, tzinfo=dt.timezone.utc).timestamp()
        if ts > t1:
            break
        if d.day in (1, 15):
            ticks.append(f'<line x1="{X(ts):.1f}" x2="{X(ts):.1f}" y1="{T}" y2="{H - B}" stroke="#d4d4d8" stroke-dasharray="3 4"/>'
                         f'<text x="{X(ts):.1f}" y="{H - B + 18}" font-size="11" text-anchor="middle" fill="#71717a">{d.strftime("%d %b")}</text>')
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" font-family="Inter, system-ui, sans-serif">
<rect width="{W}" height="{H}" fill="#ffffff"/>
<text x="{L}" y="18" font-size="13" font-weight="700" fill="#0b0b0c">{title}</text>
{''.join(ticks)}
<polyline points="{px}" fill="none" stroke="#a1a1aa" stroke-width="1.2"/>
<polyline points="{nav}" fill="none" stroke="#c2410c" stroke-width="2.4"/>
<text x="{L - 6}" y="{Y(vmax) + 4:.1f}" font-size="11" text-anchor="end" fill="#c2410c">${vmax:.2f}</text>
<text x="{L - 6}" y="{Y(vmin) + 4:.1f}" font-size="11" text-anchor="end" fill="#c2410c">${vmin:.2f}</text>
<text x="{W - R}" y="{H - 6}" font-size="11" text-anchor="end" fill="#71717a">orange: vault NAV (left scale) · grey: NVDA Chainlink price ${pmin:.0f}–${pmax:.0f}</text>
</svg>'''
    with open(path, "w") as f:
        f.write(svg)


def write_report(out, path):
    h, pp, w = out["headline"], out["price_path"], out["window"]
    st = {r["leverage"]: r for r in out["stress_single_gap"]}
    d = lambda iso: iso[:10]
    cap2 = next(g for g in out["grid"] if g["leverage"] == 2 and g["target_utilisation"] == 0.8 and g["hold_days"] == 7)
    lines = [
        "# LP backtest: TORQUE's vault over 90 days of real NVDA prices",
        "",
        f"Generated by `research/lp_backtest.py` on {out['generated'][:10]}. Prices: every Chainlink RHNVDA/USD print on Robinhood Chain "
        f"from {d(w['first_print'])} to {d(w['last_print'])} ({w['prints']} prints, {w['days']:.1f} days), the feed TORQUE reads. "
        "Knock-outs can only fire at a fresh print, so this is the path the contract would have acted on, weekend gaps included.",
        "",
        "**Demand is assumed, not measured.** Traders borrow every dollar the vault may lend, reopen as soon as a position ends, "
        "and close after a holding period. That is the best case for LP income and the most LP money at risk. Lower demand scales "
        "income down roughly in proportion (see the 40% rows).",
        "",
        "## Result: 5x traders, 80% utilisation, 7-day holds",
        "",
        "| Measure | Result |",
        "|---|---|",
        f"| LP return over the window | **{h['return_pct']:+.2f}%** ({h['annualised_pct']:.1f}% a year) |",
        f"| Of which | ${h['interest_usdg']:.3f} interest at 10% APR, ${h['fees_usdg']:.3f} open fees, on a $20 vault |",
        f"| Knock-outs | {h['knock_outs']} |",
        f"| Bad debt (LP loss) | ${h['bad_debt_usdg']:.2f} |",
        f"| Worst drawdown of vault NAV | {h['max_drawdown_pct']:.2f}% |",
        f"| Worst day for vault NAV | {h['worst_day'][1]:+.3f}% ({h['worst_day'][0]}) |",
        f"| Mean utilisation | {h['mean_utilisation_pct']:.1f}% |",
        "",
        "![Vault NAV and NVDA price](lp-backtest-nav.svg)",
        "",
        "## The worst case, as plainly as the average",
        "",
        f"**These {w['days']:.0f} days never tested the floor.** NVDA rose from ${pp['start']:.2f} to ${pp['end']:.2f}. Its worst fall was "
        f"{pp['worst_peak_to_trough_pct']:.1f}% in seven days ({d(pp['worst_peak_to_trough_window'][0])} to {d(pp['worst_peak_to_trough_window'][1])}). "
        f"A 5x position is knocked out at {-st[5]['knock_out_drop_pct']:.0f}% and the LP only loses if one gap goes past {-st[5]['worth_zero_drop_pct']:.0f}%. "
        f"The worst move between two consecutive prints was {pp['worst_move_between_prints_pct']:.2f}%. The feed went quiet for over 12 hours "
        f"{pp['feed_silences_over_12h']} times, so opens would have paused: {pp['silences_weekend_or_holiday']} weekends or holidays (longest {pp['longest_silence_hours']:.0f} h, "
        f"{dt.datetime.fromisoformat(pp['longest_silence']['from'][:19]):%a %d %b} to {dt.datetime.fromisoformat(pp['longest_silence']['to'][:19]):%a %d %b}) and "
        f"{pp['silences_weekday']} quiet weekday stretches when NVDA moved too little to trigger a print (longest {pp['longest_weekday_silence']['silent_hours']:.0f} h). "
        "The biggest price move across any silence was "
        f"{pp['worst_move_across_a_silence']['price_move_pct']:.2f}%.",
        "",
        "So the zero losses above are this window's, not a guarantee. What matters to an LP is a single gap straight through a "
        "position's knock-out level, with no print in between. This table shows the LP loss per $1 lent to a fresh position when that happens "
        f"(sale {out['assumptions']['slippage'] * 100:.1f}% below the print):",
        "",
        "| Leverage | Knocked out at | Worth zero at | " + " | ".join(f"Gap {k}" for k in st[5]["loss_per_dollar_lent"]) + " |",
        "|---|---|---|" + "---|" * len(st[5]["loss_per_dollar_lent"]),
    ]
    for lev in (2, 3, 4, 5):
        r = st[lev]
        lines.append(f"| {lev}x | {-r['knock_out_drop_pct']:.0f}% | {-r['worth_zero_drop_pct']:.0f}% | " +
                     " | ".join(("none" if v == 0 else f"{v * 100:.1f}¢") for v in r["loss_per_dollar_lent"].values()) + " |")
    l5 = st[5]["loss_per_dollar_lent"]
    lines += [
        "",
        f"At 80% utilisation with every loan at 5x, a single gap of -25% would cost the vault {0.8 * l5['-25%'] * 100:.1f}% of its assets, "
        f"-30% would cost {0.8 * l5['-30%'] * 100:.1f}% and -40% would cost {0.8 * l5['-40%'] * 100:.1f}%. "
        "For scale: NVDA's worst day in recent years was a fall of about 17% (27 January 2025). At 5x that knocks positions out "
        "and costs the LP nothing; it takes a gap beyond about 20% to reach LP money.",
        "",
        "## Across leverage, utilisation and holding time",
        "",
        "| Leverage | Utilisation target | Hold | LP return | A year | Knock-outs | Bad debt | Mean utilisation | Days a cap refused an open |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for g in out["grid"]:
        lines.append(f"| {g['leverage']}x | {g['target_utilisation'] * 100:.0f}% | {g['hold_days']} d | {g['return_pct']:+.2f}% | {g['annualised_pct']:.1f}% | "
                     f"{g['knock_outs']} | ${g['bad_debt_usdg']:.2f} | {g['mean_utilisation_pct']:.1f}% | {len(g['days_an_open_was_refused_by_a_cap'])} |")
    lines += [
        "",
        "## When a cap binds",
        "",
        f"At 2x, the $30 open-interest cap binds before the 80% utilisation limit: a 2x position's notional is twice its loan, so lending $16 "
        f"would need $32 of open interest. In the 2x / 80% run the cap refused an open on {len(cap2['days_an_open_was_refused_by_a_cap'])} days "
        f"and utilisation topped out near {cap2['mean_utilisation_pct']:.0f}%. From 3x up the 80% utilisation limit is the only constraint, and it "
        "binds by construction, because demand is assumed to fill it. The $20 vault cap is the buildathon limit; every figure here is a "
        "percentage, so it scales with the vault. The open question is demand, not the cap.",
        "",
        "## What this does not say",
        "",
        "- Demand is assumed (above). Interest is 10% APR on the loan, as the contract charges, and the open fee is 0.10% of notional, paid to the vault.",
        f"- Sales into the pool are taken {out['assumptions']['slippage'] * 100:.1f}% below the print. The mainnet-fork sandwich runs filled 0.10-0.17% from Chainlink.",
        "- The pool check (check 2) is not replayed: opens are only tested against check 1, a print in the last 12 hours.",
        "- An owner can close only when the sale covers the debt, as the contract requires; otherwise the position runs until knocked out.",
        f"- {len(out['dropped_rounds'])} early rounds (22-23 June, before this window) report a different scale and are excluded; they are listed in `lp-backtest.json`.",
        "",
        "## Re-run it",
        "",
        "```sh",
        "python3 research/lp_backtest.py             # uses research/data/rhnvda_rounds.csv",
        "python3 research/lp_backtest.py --refresh   # refetches every round from chain (RH_RPC_URL optional)",
        "```",
        "",
        "Outputs: `research/lp-backtest.json` (every scenario and knock-out event), `research/data/lp_backtest_nav_5x_80pct_7d.csv` (the NAV series), `research/lp-backtest-nav.svg`.",
    ]
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def main():
    refresh = "--refresh" in sys.argv
    rows, dropped = clean(load_rounds(refresh))
    prints_all = [(r[3], r[2]) for r in rows]
    t_end = prints_all[-1][0]
    t_start = t_end - WINDOW_DAYS * 86400
    prints = [p for p in prints_all if p[0] >= t_start]
    first = dt.datetime.utcfromtimestamp(prints[0][0]).isoformat() + "Z"
    last = dt.datetime.utcfromtimestamp(prints[-1][0]).isoformat() + "Z"

    # feed gaps (check 1) inside the window
    gaps = []
    for (ta, pa), (tb, pb) in zip(prints, prints[1:]):
        if tb - ta > MAX_FEED_AGE:
            A, Bt = dt.datetime.utcfromtimestamp(ta), dt.datetime.utcfromtimestamp(tb)
            weekend = (Bt.date() - A.date()).days >= 2 and any((A.date() + dt.timedelta(days=k)).weekday() >= 5 for k in range((Bt.date() - A.date()).days + 1))
            gaps.append({"from": A.isoformat() + "Z", "to": Bt.isoformat() + "Z", "kind": "weekend or holiday" if weekend else "weekday, no print",
                         "silent_hours": (tb - ta) / 3600, "price_move_pct": (pb / pa - 1) * 100})
    biggest_gap_move = min(gaps, key=lambda g: g["price_move_pct"]) if gaps else None
    moves = [(prints[i][0], prints[i][1] / prints[i - 1][1] - 1) for i in range(1, len(prints))]
    worst_print_move = min(moves, key=lambda m: m[1])
    peak, dd, dd_at = prints[0], 0.0, None
    for t, p in prints:
        if p > peak[1]:
            peak = (t, p)
        if p / peak[1] - 1 < dd:
            dd, dd_at = p / peak[1] - 1, (peak[0], t)
    # worst fall over any 7 days (a 7-day position's whole life)
    worst7, worst7_at = 0.0, None
    j = 0
    for i, (t, p) in enumerate(prints):
        while prints[j][0] < t - 7 * 86400:
            j += 1
        hi = max(prints[k][1] for k in range(j, i + 1))
        if p / hi - 1 < worst7:
            worst7, worst7_at = p / hi - 1, t

    grid = []
    for lev in (2, 3, 4, 5):
        for util in (0.4, 0.8):
            for hold in (7, 30):
                r = simulate(prints, lev, util, hold)
                grid.append({k: v for k, v in r.items() if k not in ("nav_series", "knock_out_events")} | {"knock_out_events": r["knock_out_events"][:50]})
    headline = simulate(prints, 5, 0.8, 7)
    svg_chart(headline["nav_series"], prints, os.path.join(HERE, "lp-backtest-nav.svg"),
              "TORQUE vault NAV, 5x traders, 80% utilisation, 7-day holds · Chainlink RHNVDA prints, last 90 days")
    out = {
        "generated": dt.datetime.utcnow().isoformat(timespec="seconds") + "Z",
        "source": f"Chainlink RHNVDA/USD {PROXY} on Robinhood Chain, every round via getRoundData",
        "window": {"first_print": first, "last_print": last, "prints": len(prints), "days": (prints[-1][0] - prints[0][0]) / 86400},
        "dropped_rounds": [{"phase": r[0], "round": r[1], "value": r[2], "updated_at": r[3]} for r in dropped],
        "assumptions": {"slippage": SLIPPAGE, "apr": APR, "open_fee": FEE, "ko_buffer": KO_BUFFER, "vault": VAULT_CAP, "oi_cap": OI_CAP,
                        "utilisation_cap": UTIL_CAP, "demand": "every lendable dollar borrowed, slots reopen at the next print, closes after the holding period"},
        "price_path": {"start": prints[0][1], "end": prints[-1][1], "min": min(p for _, p in prints), "max": max(p for _, p in prints),
                       "worst_move_between_prints_pct": worst_print_move[1] * 100,
                       "worst_move_between_prints_at": dt.datetime.utcfromtimestamp(worst_print_move[0]).isoformat() + "Z",
                       "feed_silences_over_12h": len(gaps), "longest_silence_hours": max((g["silent_hours"] for g in gaps), default=0),
                       "longest_silence": max(gaps, key=lambda g: g["silent_hours"]) if gaps else None,
                       "silences_weekend_or_holiday": sum(g["kind"] == "weekend or holiday" for g in gaps),
                       "silences_weekday": sum(g["kind"] == "weekday, no print" for g in gaps),
                       "longest_weekday_silence": max((g for g in gaps if g["kind"] == "weekday, no print"), key=lambda g: g["silent_hours"], default=None),
                       "worst_move_across_a_silence": biggest_gap_move,
                       "worst_peak_to_trough_pct": dd * 100,
                       "worst_peak_to_trough_window": [dt.datetime.utcfromtimestamp(x).isoformat() + "Z" for x in dd_at] if dd_at else None,
                       "worst_fall_within_7_days_pct": worst7 * 100,
                       "worst_fall_within_7_days_ending": dt.datetime.utcfromtimestamp(worst7_at).isoformat() + "Z" if worst7_at else None},
        "headline": {k: v for k, v in headline.items() if k != "nav_series"},
        "grid": grid,
        "stress_single_gap": stress_table(),
    }
    with open(os.path.join(HERE, "lp-backtest.json"), "w") as f:
        json.dump(out, f, indent=1, default=str)
    with open(os.path.join(DATA, "lp_backtest_nav_5x_80pct_7d.csv"), "w", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(["time_utc", "nav_usdg", "utilisation"])
        for t, v, u in headline["nav_series"]:
            wr.writerow([dt.datetime.utcfromtimestamp(t).isoformat() + "Z", f"{v:.6f}", f"{u:.4f}"])
    write_report(out, os.path.join(HERE, "LP_BACKTEST.md"))
    h = out["headline"]
    print(json.dumps({"window": out["window"], "price_path": out["price_path"], "dropped": out["dropped_rounds"],
                      "headline": {k: h[k] for k in ("return_pct", "annualised_pct", "max_drawdown_pct", "worst_day", "knock_outs", "bad_debt_usdg", "opens", "closes", "mean_utilisation_pct", "fees_usdg", "interest_usdg")},
                      "cap_days": len(h["days_an_open_was_refused_by_a_cap"])}, indent=1, default=str))


if __name__ == "__main__":
    main()
