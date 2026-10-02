/* TORQUE site: live reads from Robinhood Chain, quotes, and wallet actions. */
(() => {
  const C = window.TORQUE_CONFIG;
  const E = window.ethers;
  const $ = (id) => document.getElementById(id);
  const read = new E.JsonRpcProvider(C.rpc, C.chainId, { staticNetwork: true });
  const headlineRead = new E.JsonRpcProvider(C.headlineRpc || C.rpc, C.chainId, { staticNetwork: true });
  const deployed = Boolean(C.MARKET && C.VAULT);

  const ABI = {
    erc20: ["function totalSupply() view returns (uint256)", "function balanceOf(address) view returns (uint256)",
      "function allowance(address,address) view returns (uint256)", "function approve(address,uint256) returns (bool)"],
    feed: ["function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)"],
    pool: ["function observe(uint32[]) view returns (int56[],uint160[])"],
    morpho: ["function market(bytes32) view returns (uint128,uint128,uint128,uint128,uint128,uint128)"],
    multicall: ["function aggregate3((address target,bool allowFailure,bytes callData)[]) view returns ((bool success,bytes returnData)[])"],
    market: ["function priceStatus() view returns (uint256,uint256,uint256,uint256,bool,bool)",
      "function openPositionIds() view returns (uint256[])",
      "function getPosition(uint256) view returns ((address owner,uint128 q,uint128 principal,uint128 notional,uint128 margin,uint64 openedAt))",
      "function debtOf(uint256) view returns (uint256)", "function barrierOf(uint256) view returns (uint256)",
      "function totalNotional() view returns (uint256)", "function totalPrincipal() view returns (uint256)",
      "function claimable(address) view returns (uint256)",
      "function open(uint256,uint256,uint256) returns (uint256)", "function close(uint256,uint256) returns (uint256)",
      "function claim() returns (uint256)"],
    vault: ["function totalAssets() view returns (uint256)", "function idle() view returns (uint256)",
      "function balanceOf(address) view returns (uint256)", "function convertToAssets(uint256) view returns (uint256)",
      "function maxWithdraw(address) view returns (uint256)", "function maxDeposit(address) view returns (uint256)",
      "function deposit(uint256,address) returns (uint256)", "function withdraw(uint256,address,address) returns (uint256)"],
  };

  const usd = (x, d = 2) => (Number(x) < 0 ? "−$" : "$") + Math.abs(Number(x)).toLocaleString("en-US", { minimumFractionDigits: d, maximumFractionDigits: d });
  const compactUsd = (x) => x >= 1e6 ? "$" + (x / 1e6).toFixed(x >= 1e8 ? 0 : 2) + "M" : x >= 1e3 ? "$" + (x / 1e3).toFixed(1) + "k" : usd(x);
  const ago = (s) => s < 90 ? `${Math.round(s)}s ago` : s < 5400 ? `${Math.round(s / 60)} min ago` : `${(s / 3600).toFixed(1)} h ago`;

  const state = { price: 0, feedFresh: false, poolAgrees: false, account: null, signer: null, lev: 5 };

  // ------------------------------------------------------------- headline: USDG vs stock-backed lending
  async function loadHeadline() {
    try {
      const usdg = new E.Contract(C.USDG, ABI.erc20, headlineRead);
      const mc = new E.Contract(C.MULTICALL3, ABI.multicall, headlineRead);
      const morphoI = new E.Interface(ABI.morpho);
      const calls = C.STOCK_USDG_MARKETS.map((id) => ({ target: C.MORPHO, allowFailure: true, callData: morphoI.encodeFunctionData("market", [id]) }));
      const [supply, res] = await Promise.all([usdg.totalSupply(), mc.aggregate3(calls)]);
      let lent = 0n, borrowed = 0n;
      for (const r of res) {
        if (!r.success) continue;
        const m = morphoI.decodeFunctionResult("market", r.returnData);
        lent += m[0]; borrowed += m[2];
      }
      const s = Number(supply) / 1e6, l = Number(lent) / 1e6, b = Number(borrowed) / 1e6;
      $("h-usdg").textContent = compactUsd(s);
      $("h-lent").textContent = compactUsd(l);
      $("h-util").textContent = l > 0 ? Math.round((b / l) * 100) + "%" : "—";
      $("h-asof").textContent = `Read live from Robinhood Chain just now: USDG totalSupply, and ${C.STOCK_USDG_MARKETS.length} Morpho markets lending USDG against Robinhood Stock Tokens (${compactUsd(b)} borrowed).`;
    } catch (e) { console.warn("headline", e); }
  }

  // ------------------------------------------------------------- price and safety checks
  async function loadPrice() {
    let feedPrice, age, twap, devBps, fresh, agrees;
    try {
      if (deployed) {
        const m = new E.Contract(C.MARKET, ABI.market, read);
        const r = await m.priceStatus();
        feedPrice = Number(r[0]) / 1e6; age = Number(r[1]); twap = Number(r[2]) / 1e6; devBps = Number(r[3]); fresh = r[4]; agrees = r[5];
      } else {
        const feed = new E.Contract(C.FEED, ABI.feed, read);
        const pool = new E.Contract(C.POOL, ABI.pool, read);
        const [rd, ob] = await Promise.all([feed.latestRoundData(), pool.observe([1800, 0])]);
        feedPrice = Number(rd[1]) / 1e8;
        age = Math.max(0, Date.now() / 1000 - Number(rd[3]));
        const avgTick = Math.floor(Number(ob[0][1] - ob[0][0]) / 1800);
        twap = 1e18 / Math.pow(1.0001, avgTick) / 1e6; // USDG is token0, NVDA token1
        devBps = Math.round(Math.abs(twap / feedPrice - 1) * 1e4);
        fresh = age <= 12 * 3600; agrees = devBps <= 150;
      }
    } catch (e) { console.warn("price", e); return; }
    Object.assign(state, { price: feedPrice, feedFresh: fresh, poolAgrees: agrees });
    $("feed-price").textContent = usd(feedPrice);
    $("feed-age").textContent = `updated ${ago(age)}`;
    setCheck("chk-fresh", fresh, ago(age));
    setCheck("chk-pool", agrees, `${usd(twap)} · ${(devBps / 100).toFixed(2)}% off`);
    const st = $("market-state");
    st.textContent = fresh && agrees ? "Open" : !fresh ? "Paused: waiting for a fresh price" : "Paused: market moved off the price";
    st.className = "pill " + (fresh && agrees ? "pill-ok" : "pill-bad");
    renderQuote();
    renderButtons();
  }

  function setCheck(id, ok, text) {
    const li = $(id); li.classList.toggle("ok", ok); li.classList.toggle("bad", !ok);
    $(id + "-v").textContent = (ok ? "✓ " : "✕ ") + text;
  }

  // ------------------------------------------------------------- quote (same formulas as TorqueMarket)
  function sizes(margin, lev) {
    const fee = margin * lev * 0.001;
    const equity = margin - fee;
    const notional = equity * lev;
    return { fee, notional, borrow: notional - equity };
  }

  function renderQuote() {
    const margin = parseFloat($("margin").value) || 0;
    const { fee, notional, borrow } = sizes(margin, state.lev);
    if (!state.price || margin <= 0) return;
    const q = notional / state.price;
    const fin = borrow / q, ko = fin * 1.05;
    $("q-nvda").textContent = `${q.toFixed(5)} NVDA`;
    $("q-notional").textContent = usd(notional);
    $("q-borrow").textContent = usd(borrow);
    $("q-fee").textContent = usd(fee, 3);
    $("q-fin").textContent = `${usd(fin)} (−${((1 - fin / state.price) * 100).toFixed(1)}%)`;
    $("q-ko").textContent = `${usd(ko)} (−${((1 - ko / state.price) * 100).toFixed(1)}%)`;
    $("q-maxloss").textContent = `${usd(margin)} · your margin`;
  }

  // ------------------------------------------------------------- vault and positions
  async function loadVault() {
    if (!deployed) {
      $("v-assets").textContent = "$0.00"; $("v-lent").textContent = "$0.00"; $("v-oi").textContent = "$0.00";
      return;
    }
    try {
      const v = new E.Contract(C.VAULT, ABI.vault, read);
      const m = new E.Contract(C.MARKET, ABI.market, read);
      const [ta, lent, oi] = await Promise.all([v.totalAssets(), m.totalPrincipal(), m.totalNotional()]);
      const assets = Number(ta) / 1e6;
      $("v-assets").textContent = usd(assets);
      $("v-lent").textContent = usd(Number(lent) / 1e6);
      $("v-oi").textContent = usd(Number(oi) / 1e6);
      $("cap-fill").style.width = Math.min(100, (assets / 20) * 100) + "%";
      if (state.account) {
        const sh = await v.balanceOf(state.account);
        const val = sh > 0n ? Number(await v.convertToAssets(sh)) / 1e6 : 0;
        $("lp-share").textContent = usd(val);
      }
    } catch (e) { console.warn("vault", e); }
  }

  async function loadPositions() {
    if (!deployed || !state.account) return;
    const m = new E.Contract(C.MARKET, ABI.market, read);
    const ids = await m.openPositionIds();
    const mine = [];
    for (const id of ids) {
      try {
        const p = await m.getPosition(id);
        if (p.owner.toLowerCase() === state.account.toLowerCase()) {
          const [debt, barrier] = await Promise.all([m.debtOf(id), m.barrierOf(id)]);
          mine.push({ id, p, debt: Number(debt) / 1e6, barrier: Number(barrier) / 1e6 });
        }
      } catch (e) { /* closed between the list read and this read */ }
    }
    const box = $("positions");
    if (!mine.length) box.innerHTML = `<p class="muted">No open positions.</p>`;
    else box.innerHTML = mine.map(({ id, p, debt, barrier }) => {
      const q = Number(p.q) / 1e18, margin = Number(p.margin) / 1e6;
      const value = Math.max(0, q * state.price - debt);
      const pnl = value - margin;
      return `<div class="pos"><div><b>#${id}</b> · ${q.toFixed(5)} NVDA · margin ${usd(margin)}<br>
        <span class="muted">Knock-out at ${usd(barrier)} · debt ${usd(debt)}</span></div>
        <div style="text-align:right"><span class="${pnl >= 0 ? "pnl-pos" : "pnl-neg"}">${pnl >= 0 ? "+" : ""}${usd(pnl)}</span><br>
        <button class="btn btn-ghost" data-close="${id}">Close</button></div></div>`;
    }).join("");
    box.querySelectorAll("[data-close]").forEach((b) => b.addEventListener("click", () => closePos(b.dataset.close)));
    const cl = Number(await m.claimable(state.account)) / 1e6;
    $("claim-row").hidden = cl <= 0;
    $("claimable").textContent = cl.toFixed(2);
  }

  // ------------------------------------------------------------- buttons
  function renderButtons() {
    const ok = state.feedFresh && state.poolAgrees;
    const why = !deployed ? "Contracts are being deployed to Robinhood Chain mainnet. Live data above is read from the chain now."
      : !state.account ? "Connect a wallet to trade."
      : !ok ? "Paused by TORQUE's safety checks. Opens resume when the price is fresh and the pool agrees."
      : "";
    $("open-btn").disabled = Boolean(why);
    $("open-why").textContent = why;
    $("dep-btn").disabled = $("wd-btn").disabled = Boolean(why);
    $("lp-why").textContent = why;
    $("deploy-note").textContent = deployed
      ? "Real mainnet deployment, real USDG. Testnet has no real stock feeds or stock pools, so a testnet version would prove nothing."
      : "Mainnet deployment in progress; contract addresses will appear below.";
    $("eyebrow").textContent = deployed ? "Live on Robinhood Chain mainnet · settled in USDG" : "Built for Robinhood Chain mainnet · settled in USDG";
  }

  // ------------------------------------------------------------- wallet
  async function connect() {
    if (!window.ethereum) { alert("No browser wallet found."); return; }
    const hex = "0x" + C.chainId.toString(16);
    try {
      await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: hex }] });
    } catch (e) {
      if (e.code === 4902) {
        await window.ethereum.request({ method: "wallet_addEthereumChain", params: [{ chainId: hex, chainName: C.chainName,
          nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: [C.rpc], blockExplorerUrls: [C.explorer] }] });
      } else throw e;
    }
    const bp = new E.BrowserProvider(window.ethereum);
    state.signer = await bp.getSigner();
    state.account = await state.signer.getAddress();
    $("connect").textContent = state.account.slice(0, 6) + "…" + state.account.slice(-4);
    renderButtons(); loadPositions(); loadVault();
  }

  async function ensureAllowance(spender, amount) {
    const t = new E.Contract(C.USDG, ABI.erc20, state.signer);
    if ((await t.allowance(state.account, spender)) < amount) await (await t.approve(spender, amount)).wait();
  }

  async function openPos() {
    const margin = E.parseUnits(String(parseFloat($("margin").value) || 0), 6);
    const lev = BigInt(state.lev * 10_000);
    const { notional } = sizes(Number(margin) / 1e6, state.lev);
    const minOut = E.parseUnits(((notional / state.price) * 0.99).toFixed(18), 18);
    await run("open-why", async () => {
      await ensureAllowance(C.MARKET, margin);
      const m = new E.Contract(C.MARKET, ABI.market, state.signer);
      return m.open(margin, lev, minOut);
    });
  }

  async function closePos(id) {
    const usdg = new E.Contract(C.USDG, ABI.erc20, read);
    const before = await usdg.balanceOf(state.account);
    await run("open-why", () => new E.Contract(C.MARKET, ABI.market, state.signer).close(id, 0), async () => {
      const got = Number((await usdg.balanceOf(state.account)) - before) / 1e6;
      return ` · received ${usd(got)} USDG`;
    });
  }

  async function lp(kind) {
    const amt = E.parseUnits(String(parseFloat($("lp-amt").value) || 0), 6);
    await run("lp-why", async () => {
      const v = new E.Contract(C.VAULT, ABI.vault, state.signer);
      if (kind === "dep") { await ensureAllowance(C.VAULT, amt); return v.deposit(amt, state.account); }
      return v.withdraw(amt, state.account, state.account);
    });
  }

  async function run(msgId, fn, after) {
    const el = $(msgId);
    try {
      el.textContent = "Confirm in your wallet…";
      const tx = await fn();
      el.innerHTML = `Submitted: <a href="${C.explorer}/tx/${tx.hash}" target="_blank" rel="noopener">${tx.hash.slice(0, 10)}…</a>`;
      await tx.wait();
      const extra = after ? await after() : "";
      el.innerHTML = `Confirmed: <a href="${C.explorer}/tx/${tx.hash}" target="_blank" rel="noopener">${tx.hash.slice(0, 10)}…</a>${extra}`;
      refresh();
    } catch (e) {
      el.textContent = "Not sent: " + (e.shortMessage || e.reason || e.message || e);
    }
  }

  // ------------------------------------------------------------- static bits
  function renderContracts() {
    const rows = [
      ["TorqueMarket", C.MARKET], ["TorqueVault (USDG LP)", C.VAULT], ["USDG (Paxos)", C.USDG], ["NVDA Stock Token", C.NVDA],
      ["NVDA/USDG 0.05% pool", C.POOL], ["Chainlink RHNVDA / USD", C.FEED],
    ];
    $("contracts").innerHTML = rows.map(([k, a]) => `<tr><td>${k}</td><td>${a ? `<a href="${C.explorer}/address/${a}" target="_blank" rel="noopener">${a}</a>` : "deploying"}</td></tr>`).join("");
    $("repo-link").href = C.repo;
  }

  function refresh() { loadPrice(); loadVault(); loadPositions(); }

  document.querySelectorAll("#lev button").forEach((b) => b.addEventListener("click", () => {
    document.querySelectorAll("#lev button").forEach((x) => { x.classList.remove("on"); x.setAttribute("aria-checked", "false"); });
    b.classList.add("on"); b.setAttribute("aria-checked", "true");
    state.lev = Number(b.dataset.lev); renderQuote();
  }));
  $("margin").addEventListener("input", renderQuote);
  $("connect").addEventListener("click", () => connect().catch((e) => alert(e.shortMessage || e.message)));
  $("open-btn").addEventListener("click", openPos);
  $("dep-btn").addEventListener("click", () => lp("dep"));
  $("wd-btn").addEventListener("click", () => lp("wd"));
  $("claim-btn").addEventListener("click", () => run("open-why", () => new E.Contract(C.MARKET, ABI.market, state.signer).claim()));

  renderContracts(); renderButtons(); loadHeadline(); refresh();
  setInterval(refresh, 30_000);
})();
