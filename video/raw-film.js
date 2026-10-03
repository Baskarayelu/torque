// Raw, unpaced footage of the live mainnet dashboard for a later cut to the final narration. Long holds, one MP4 per
// shot, several takes of everything that needs a live price. Every transaction is real and logged to shots.json.
//   LANDING_URL=... DASH_URL=... RPC=... PK=... OUT=dir TAKES=2 node raw-film.js
const { chromium } = require("playwright");
const { ethers } = require("ethers");
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const { LANDING_URL, DASH_URL, RPC, OUT } = process.env;
const TAKES = Number(process.env.TAKES || 2);
const HOLD = 6000;

(async () => {
  const provider = new ethers.JsonRpcProvider(RPC);
  const wallet = new ethers.Wallet(process.env.PK, provider);
  const browser = await chromium.launch();
  const shots = [];
  const txs = [];

  async function session(theme, fn) {
    const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, colorScheme: theme });
    await ctx.exposeFunction("__rpc", async (method, params) => {
      switch (method) {
        case "eth_requestAccounts": case "eth_accounts": return [wallet.address];
        case "eth_chainId": return "0x" + (await provider.getNetwork()).chainId.toString(16);
        case "wallet_switchEthereumChain": case "wallet_addEthereumChain": return null;
        case "eth_sendTransaction": {
          const t = params[0];
          const tx = await wallet.sendTransaction({ to: t.to, data: t.data, value: t.value ? BigInt(t.value) : 0n, ...(t.gas ? { gasLimit: BigInt(t.gas) } : {}) });
          txs.push({ hash: tx.hash, at: new Date().toISOString(), shot: current });
          console.log("tx", tx.hash);
          return tx.hash;
        }
        default:
          try { return await provider.send(method, params); }
          catch (e) { const inner = e.error || e.info?.error || {}; return { __rpcError: { code: inner.code ?? -32000, message: inner.message || e.shortMessage || e.message, data: inner.data ?? e.data } }; }
      }
    });
    await ctx.addInitScript(() => {
      window.ethereum = {
        request: async ({ method, params }) => { const r = await window.__rpc(method, params || []); if (r && r.__rpcError) throw Object.assign(new Error(r.__rpcError.message), r.__rpcError); return r; },
        on() {}, removeListener() {},
      };
    });
    const page = await ctx.newPage();
    const cdp = await ctx.newCDPSession(page);
    let frames = null;
    cdp.on("Page.screencastFrame", async ({ data, metadata, sessionId }) => {
      if (frames) frames.push({ buf: Buffer.from(data, "base64"), t: metadata.timestamp });
      await cdp.send("Page.screencastFrameAck", { sessionId }).catch(() => {});
    });
    await cdp.send("Page.startScreencast", { format: "jpeg", quality: 88, maxWidth: 1440, maxHeight: 900 });
    const api = {
      page,
      wait: (ms) => page.waitForTimeout(ms),
      async shot(name, run) { // records one clip: frames from start to end of run, at real time
        current = `${theme}-${name}`;
        frames = []; const t0 = Date.now() / 1000;
        await page.mouse.move(1420, 880); await page.waitForTimeout(300);
        let ok = true, err = "";
        try { await run(); } catch (e) { ok = false; err = e.message.split("\n")[0]; }
        const t1 = Date.now() / 1000; const fr = frames; frames = null;
        const dir = path.join(OUT, "tmp", current); fs.mkdirSync(dir, { recursive: true });
        let list = "";
        fr.forEach((f, i) => { const p = path.join(dir, `${String(i).padStart(6, "0")}.jpg`); fs.writeFileSync(p, f.buf);
          const next = fr[i + 1] ? fr[i + 1].t : t1; list += `file '${p}'\nduration ${Math.max(0.001, next - Math.max(f.t, t0)).toFixed(3)}\n`; });
        if (fr.length) list += `file '${path.join(dir, `${String(fr.length - 1).padStart(6, "0")}.jpg`)}'\n`;
        fs.writeFileSync(path.join(dir, "frames.txt"), list);
        const mp4 = path.join(OUT, `${current}.mp4`);
        if (fr.length) execFileSync("ffmpeg", ["-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", path.join(dir, "frames.txt"), "-vf", "fps=30,format=yuv420p", "-c:v", "libx264", "-crf", "17", mp4]);
        shots.push({ clip: path.basename(mp4), seconds: +(t1 - t0).toFixed(1), ok, ...(err ? { error: err } : {}), messages: await page.evaluate(() => [...document.querySelectorAll("p.muted.small")].map((e) => e.textContent).filter((t) => /Confirmed|Not sent|Submitted/.test(t))).catch(() => []) });
        console.log(ok ? "shot" : "SHOT FAILED", current, err);
      },
    };
    await fn(api);
    await cdp.send("Page.stopScreencast").catch(() => {});
    await ctx.close();
  }
  let current = "";
  const connect = async (page) => { await page.click(".connect"); await page.waitForFunction(() => /0x/.test(document.querySelector(".connect").textContent), null, { timeout: 30000 }); };
  const ready = (page) => page.waitForFunction(() => /\$\d/.test(document.querySelector(".price-pill")?.textContent || ""), null, { timeout: 60000 });
  const smooth = (page, sel) => page.evaluate((s) => document.querySelector(s).scrollIntoView({ behavior: "smooth", block: "start" }), sel);
  const confirmed = (page, sel) => page.waitForFunction((s) => [...document.querySelectorAll(s)].some((e) => /Confirmed/.test(e.textContent)), sel, { timeout: 180000 });

  await session("light", async ({ page, wait, shot }) => {
    await page.goto(LANDING_URL, { waitUntil: "networkidle" }); await wait(2500);
    await shot("01-landing-hero", async () => { await wait(HOLD + 2000); await page.mouse.wheel(0, 420); await wait(HOLD); });
    await shot("02-landing-scroll", async () => { for (let i = 0; i < 14; i++) { await page.mouse.wheel(0, 260); await wait(700); } await wait(2000); });
    await page.goto(DASH_URL, { waitUntil: "load" }); await ready(page); await wait(1500);
    await shot("03-dashboard-overview", async () => { await wait(HOLD); await connect(page); await wait(HOLD); });
    await shot("04-safety-checks-green", async () => { await page.locator(".topbar-status").hover(); await wait(HOLD); await smooth(page, "#solvency"); await wait(HOLD + 2000); await smooth(page, "#open"); await wait(1500); });
    for (let k = 1; k <= TAKES; k++) {
      await shot(`05-lp-cap-refusal-take${k}`, async () => {
        await smooth(page, "#vault"); await wait(2500);
        await page.fill("#lp-amt", "0.01"); await wait(1200); await page.click("#vault .btn-accent");
        await page.waitForFunction(() => /Not sent/.test(document.querySelector("#vault .card:nth-child(2) p.muted.small").textContent), null, { timeout: 60000 });
        await wait(HOLD);
      });
    }
    for (let k = 1; k <= TAKES; k++) {
      await shot(`06-quote-take${k}`, async () => { await smooth(page, "#open"); await wait(1500); await page.fill("#margin", "2"); await wait(600); await page.click("#open .seg button:nth-child(4)"); await wait(800); await page.locator("#open .kv").hover(); await wait(HOLD + 2000); });
      await shot(`07-open-take${k}`, async () => { await page.click("#open .btn-accent"); await confirmed(page, "#open p.muted.small"); await wait(HOLD); });
      await shot(`08-position-live-take${k}`, async () => { await smooth(page, "#mine"); await page.waitForSelector("#mine .prow:not(.phead)", { timeout: 60000 }); await wait(1500); await page.locator("#mine .prow:not(.phead)").first().hover(); await wait(HOLD + 4000); await smooth(page, "#solvency"); await wait(HOLD); await smooth(page, "#all"); await wait(HOLD); });
      await shot(`09-close-take${k}`, async () => { await smooth(page, "#mine"); await wait(1500); await page.click("#mine .prow:not(.phead) .btn-line"); await confirmed(page, "#mine p.muted.small"); await page.waitForFunction(() => !document.querySelector("#mine .prow:not(.phead)"), null, { timeout: 60000 }); await wait(HOLD); await smooth(page, "#vault"); await wait(HOLD); });
    }
    await shot("10-solvency-after", async () => { await smooth(page, "#solvency"); await wait(HOLD + 2000); await smooth(page, "#all"); await wait(HOLD); });
  });
  await session("dark", async ({ page, wait, shot }) => {
    await page.goto(DASH_URL, { waitUntil: "load" }); await ready(page); await wait(1500);
    await shot("11-dashboard-dark", async () => { await connect(page); await wait(HOLD); await smooth(page, "#solvency"); await wait(HOLD); await smooth(page, "#vault"); await wait(HOLD); });
  });
  await browser.close();
  fs.rmSync(path.join(OUT, "tmp"), { recursive: true, force: true });
  fs.writeFileSync(path.join(OUT, "shots.json"), JSON.stringify({ shots, txs }, null, 1));
  console.log(JSON.stringify({ shots: shots.map((s) => [s.clip, s.seconds, s.ok]), txs: txs.length }));
})();
