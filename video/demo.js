// Records the TORQUE Demo Video: the landing page, then the dashboard with an injected wallet and real transactions.
// Shots follow video/demo-narration.json (written by script/apply-deployment.py for the current deployment state)
// and are paced by OUT/durations.json. Frames come from the CDP screencast with their real timestamps, so the
// video plays at wall-clock speed and the narration stays in sync.
//   LANDING_URL=... DASH_URL=... RPC=... PK=... OUT=dir node demo.js
// Fork-only runs (the fork dashboard build on a local anvil fork) also set FORK_SCRIPT to ./script/rehearse-fork.sh.
const { chromium } = require("playwright");
const { ethers } = require("ethers");
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const { LANDING_URL, DASH_URL, RPC, OUT, FORK_SCRIPT } = process.env;
const steps = JSON.parse(fs.readFileSync(path.join(__dirname, "demo-narration.json")));
const durations = JSON.parse(fs.readFileSync(path.join(OUT, "durations.json")));
const VAULT_ABI = ["function maxDeposit(address) view returns (uint256)"];
const MARKET_ABI = ["function openPositionIds() view returns (uint256[])", "function barrierOf(uint256) view returns (uint256)", "function getPosition(uint256) view returns (tuple(address owner,uint128 q,uint128 principal,uint128 notional,uint128 margin,uint64 openedAt))"];

(async () => {
  const provider = new ethers.JsonRpcProvider(RPC);
  const wallet = new ethers.Wallet(process.env.PK, provider);
  const cfg = await (await fetch(new URL("config.json", DASH_URL))).json();
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, colorScheme: "light" });
  await ctx.exposeFunction("__rpc", async (method, params) => {
    switch (method) {
      case "eth_requestAccounts": case "eth_accounts": return [wallet.address];
      case "eth_chainId": return "0x" + (await provider.getNetwork()).chainId.toString(16);
      case "wallet_switchEthereumChain": case "wallet_addEthereumChain": return null;
      case "eth_sendTransaction": {
        const t = params[0];
        const tx = await wallet.sendTransaction({ to: t.to, data: t.data, value: t.value ? BigInt(t.value) : 0n, ...(t.gas ? { gasLimit: BigInt(t.gas) } : {}) });
        console.log("tx", tx.hash);
        return tx.hash;
      }
      default:
        try { return await provider.send(method, params); }
        catch (e) { // hand the node's error (with revert data) back to the page, as a real wallet does
          const inner = e.error || e.info?.error || {};
          return { __rpcError: { code: inner.code ?? -32000, message: inner.message || e.shortMessage || e.message, data: inner.data ?? e.data } };
        }
    }
  });
  await ctx.addInitScript(() => {
    window.ethereum = {
      request: async ({ method, params }) => {
        const r = await window.__rpc(method, params || []);
        if (r && r.__rpcError) throw Object.assign(new Error(r.__rpcError.message), r.__rpcError);
        return r;
      },
      on() {}, removeListener() {},
    };
  });
  const page = await ctx.newPage();
  page.on("pageerror", (e) => console.log("pageerror", e.message));

  // screencast: every frame keeps its timestamp; frames.txt (ffmpeg concat) holds each one until the next
  fs.mkdirSync(path.join(OUT, "frames"), { recursive: true });
  const cdp = await ctx.newCDPSession(page);
  const frames = [];
  cdp.on("Page.screencastFrame", async ({ data, metadata, sessionId }) => {
    const file = path.join(OUT, "frames", `${String(frames.length).padStart(6, "0")}.jpg`);
    fs.writeFileSync(file, Buffer.from(data, "base64"));
    frames.push({ file, t: metadata.timestamp });
    await cdp.send("Page.screencastFrameAck", { sessionId }).catch(() => {});
  });
  const wait = (ms) => page.waitForTimeout(ms);
  const msgOf = (sel) => page.evaluate((s) => [...document.querySelectorAll(s)].map((e) => e.textContent).join(" "), sel);
  const confirmed = (sel) => page.waitForFunction((s) => [...document.querySelectorAll(s)].some((e) => /Confirmed/.test(e.textContent)), sel, { timeout: 180000 });
  const scrollTo = (sel) => page.evaluate((s) => document.querySelector(s).scrollIntoView({ behavior: "smooth", block: "start" }), sel);
  const caption = (text) => page.evaluate((t) => {
    let c = document.getElementById("__cap");
    if (!c) { c = document.createElement("div"); c.id = "__cap"; Object.assign(c.style, { position: "fixed", left: "50%", bottom: "28px", transform: "translateX(-50%)", maxWidth: "1100px", padding: "14px 22px", background: "rgba(18,21,27,.9)", color: "#fff", font: "500 20px/1.4 Inter, system-ui", borderRadius: "12px", zIndex: 999, textAlign: "center" }); document.body.appendChild(c); }
    c.textContent = t; c.style.display = t ? "block" : "none";
  }, text);
  const connect = async () => { await page.click(".connect"); await page.waitForFunction(() => /0x/.test(document.querySelector(".connect").textContent), null, { timeout: 30000 }); };

  const fork = cfg.environment === "fork-rehearsal";
  const SHOTS = {
    hero: { cap: fork ? "Not deployed to mainnet. This demo runs on a local fork of Robinhood Chain mainnet." : "TORQUE: knock-out leverage on NVDA, settled in USDG on Robinhood Chain",
      run: async () => { await wait(2500); await page.mouse.wheel(0, 380); } },
    checks: { cap: "Two safety checks: fresh Chainlink price, and the pool's 30-minute average agrees within 1.5%",
      run: async () => { await page.goto(DASH_URL, { waitUntil: "load" }); await page.waitForFunction(() => /\$\d/.test(document.querySelector(".pill, .topbar-status")?.textContent || ""), null, { timeout: 60000 }); await connect(); await page.locator(".topbar-status").hover(); } },
    lp: { cap: "LP vault: fill it to its $20 cap. The contract refuses anything more.",
      run: async () => {
        await scrollTo("#vault"); await wait(700);
        const room = await new ethers.Contract(cfg.VAULT, VAULT_ABI, provider).maxDeposit(wallet.address);
        const loans = (await new ethers.Contract(cfg.MARKET, MARKET_ABI, provider).openPositionIds()).length;
        const amt = Number(loans ? room - 1000n : room) / 1e6; // with loans open, interest accrues every block: leave 0.001
        await page.fill("#lp-amt", amt.toFixed(6)); await wait(500);
        await page.click("#vault .btn-accent"); await confirmed("#vault p.muted.small"); await wait(1500);
        await page.fill("#lp-amt", "0.01"); await wait(400); await page.click("#vault .btn-accent");
        await page.waitForFunction(() => /Not sent/.test(document.querySelector("#vault .card:nth-child(2) p.muted.small").textContent), null, { timeout: 60000 });
        console.log("refusal:", await page.textContent("#vault .card:nth-child(2) p.muted.small"));
        await wait(2500); // hold on the refusal
      } },
    quote: { cap: "$2 margin at 5×: about $10 of real NVDA. Most you can lose: $2.",
      run: async () => { await scrollTo("#open"); await wait(700); await page.fill("#margin", "2"); await page.click("#open .seg button:nth-child(4)"); await wait(500); await page.locator("#open .kv").hover(); } },
    open: { cap: fork ? "Open: the contract buys NVDA in the forked Uniswap pool, within 1% of Chainlink" : "Open: the contract buys real NVDA in the Uniswap pool, within 1% of Chainlink",
      run: async () => { await page.click("#open .btn-accent"); await confirmed("#open p.muted.small"); await wait(1500); } },
    position: { cap: "The position: knock-out level and live P&L",
      run: async () => { await scrollTo("#mine"); await page.waitForSelector("#mine .prow:not(.phead)", { timeout: 60000 }); await page.locator("#mine .prow:not(.phead)").first().hover(); } },
    close: { cap: "Close: the vault is repaid in full; the rest comes back in USDG",
      run: async () => { await page.click("#mine .prow:not(.phead) .btn-line"); await confirmed("#mine p.muted.small"); await page.waitForFunction(() => !document.querySelector("#mine .prow:not(.phead)"), null, { timeout: 60000 }); await wait(1200); } },
    knockout: { cap: "Fork only: a test feed prints below the knock-out. Opens pause; a wallet that owns nothing knocks the position out.",
      run: async () => {
        const market = new ethers.Contract(cfg.MARKET, MARKET_ABI, provider);
        const [id] = await market.openPositionIds();
        const barrier = Number(await market.barrierOf(id)) / 1e6;
        execFileSync(FORK_SCRIPT, ["feed", (Math.floor(barrier) - 2).toFixed(2)], { cwd: path.dirname(path.dirname(FORK_SCRIPT)) });
        await page.reload({ waitUntil: "load" }); await connect();
        await page.waitForSelector("#all .prow.eligible", { timeout: 60000 }); await page.locator(".topbar-status").hover(); await wait(1800);
        await scrollTo("#all"); await wait(900);
        await page.click("#all .prow.eligible .btn-accent"); await confirmed("#all p.muted.small"); await wait(800);
        await scrollTo("#vault"); await wait(1200);
      } },
    end: { cap: fork ? "Built and tested against Robinhood Chain mainnet. Not deployed there. Code, rehearsal log and tests on GitHub." : "No admin key. USDG in, USDG out. Code, spec and tests on GitHub.",
      run: async () => { await scrollTo("#solvency"); } },
  };

  const marks = [];
  let t0;
  try {
    await page.goto(LANDING_URL, { waitUntil: "load" });
    await wait(2500);
    await cdp.send("Page.startScreencast", { format: "jpeg", quality: 85, maxWidth: 1440, maxHeight: 900, everyNthFrame: 1 });
    await wait(300);
    t0 = Date.now() / 1000;
    for (const s of steps) {
      const shot = SHOTS[s.id];
      if (!shot) throw new Error(`no shot for narration id ${s.id}`);
      marks.push({ id: s.id, start: Date.now() / 1000 - t0 });
      await caption(shot.cap);
      const a = Date.now();
      await shot.run();
      await caption(shot.cap); // a reload or navigation drops the caption
      const need = durations[s.id] + 0.6 - (Date.now() - a) / 1000;
      if (need > 0) await wait(need * 1000);
    }
    await wait(1500);
  } catch (e) {
    console.log("FAILED", e.message.split("\n")[0]);
    await page.screenshot({ path: path.join(OUT, "failure.png") });
    console.log("messages:", await msgOf("p.muted.small"));
    process.exitCode = 1;
  }
  await cdp.send("Page.stopScreencast").catch(() => {});
  await wait(300);
  // frames before t0 are the landing page settling; start the video at t0
  const kept = frames.filter((f, i) => f.t >= t0 || (frames[i + 1] && frames[i + 1].t > t0));
  let list = "";
  kept.forEach((f, i) => {
    const start = Math.max(f.t, t0), next = kept[i + 1] ? kept[i + 1].t : Date.now() / 1000;
    list += `file '${f.file}'\nduration ${Math.max(0.001, next - start).toFixed(3)}\n`;
  });
  if (kept.length) list += `file '${kept[kept.length - 1].file}'\n`;
  fs.writeFileSync(path.join(OUT, "frames.txt"), list);
  fs.writeFileSync(path.join(OUT, "marks.json"), JSON.stringify(marks, null, 1));
  await ctx.close(); await browser.close();
  execFileSync("ffmpeg", ["-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", path.join(OUT, "frames.txt"), "-vf", "fps=30,format=yuv420p", "-c:v", "libx264", "-crf", "18", path.join(OUT, "screen.mp4")]);
  console.log("video", path.join(OUT, "screen.mp4"));
})();
