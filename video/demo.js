// Records the TORQUE demo: drives the site with an injected wallet and real transactions.
// Usage: SITE_URL=... RPC=... PK=... OUT=dir node demo.js
const { chromium } = require("playwright");
const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

const SITE = process.env.SITE_URL, RPC = process.env.RPC, OUT = process.env.OUT;
const steps = JSON.parse(fs.readFileSync(path.join(__dirname, "demo-narration.json")));
const durations = JSON.parse(fs.readFileSync(path.join(OUT, "durations.json"))); // seconds per narration clip

(async () => {
  const provider = new ethers.JsonRpcProvider(RPC);
  const wallet = new ethers.Wallet(process.env.PK, provider);
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, recordVideo: { dir: OUT, size: { width: 1440, height: 900 } }, colorScheme: "light" });
  await ctx.exposeFunction("__torqueRpc", async (method, params) => {
    switch (method) {
      case "eth_requestAccounts": case "eth_accounts": return [wallet.address];
      case "eth_chainId": return "0x" + (await provider.getNetwork()).chainId.toString(16);
      case "wallet_switchEthereumChain": case "wallet_addEthereumChain": return null;
      case "eth_sendTransaction": {
        const t = params[0];
        const tx = await wallet.sendTransaction({ to: t.to, data: t.data, value: t.value ? BigInt(t.value) : 0n });
        console.log("tx", tx.hash);
        return tx.hash;
      }
      default: return provider.send(method, params);
    }
  });
  await ctx.addInitScript(() => {
    window.ethereum = { isMetaMask: true, request: ({ method, params }) => window.__torqueRpc(method, params || []), on() {}, removeListener() {} };
  });
  const page = await ctx.newPage();
  page.on("pageerror", (e) => console.log("pageerror", e.message));
  const t0 = Date.now();
  const marks = [];
  const caption = (text) => page.evaluate((t) => {
    let c = document.getElementById("__cap");
    if (!c) { c = document.createElement("div"); c.id = "__cap"; Object.assign(c.style, { position: "fixed", left: "50%", bottom: "28px", transform: "translateX(-50%)", maxWidth: "1100px", padding: "14px 22px", background: "rgba(18,21,27,.88)", color: "#fff", font: "500 20px/1.4 Inter, system-ui", borderRadius: "12px", zIndex: 99, textAlign: "center" }); document.body.appendChild(c); }
    c.textContent = t;
  }, text);
  const scrollTo = (sel) => page.evaluate((s) => document.querySelector(s).scrollIntoView({ behavior: "smooth", block: "center" }), sel);
  const wait = (ms) => page.waitForTimeout(ms);

  async function step(i, action, cap) {
    const start = (Date.now() - t0) / 1000;
    marks.push({ id: steps[i].id, start });
    await caption(cap);
    const tStart = Date.now();
    await action();
    const elapsed = (Date.now() - tStart) / 1000;
    const need = durations[steps[i].id] + 0.6 - elapsed;
    if (need > 0) await wait(need * 1000);
  }

  try {
  await page.goto(SITE, { waitUntil: "load" });
  await page.waitForFunction(() => document.getElementById("market-state").textContent === "Open", null, { timeout: 180000 });
  await wait(3000); // let live data settle before the first frame that matters
  const h = await page.evaluate(() => ["h-usdg", "h-lent", "h-util"].map((i) => document.getElementById(i).textContent));
  await step(0, () => wait(500), `${h[0]} of USDG on Robinhood Chain. ${h[1]} lent against stock tokens, ${h[2]} borrowed.`);
  await step(1, async () => { await page.locator(".status").scrollIntoViewIfNeeded(); await page.locator(".status").hover(); }, "Two safety checks: fresh Chainlink price, and the pool's 30-minute average agrees within 1.5%");
  await step(2, async () => {
    await page.click("#connect"); await wait(1200);
    await scrollTo("#liquidity"); await wait(800);
    await page.fill("#lp-amt", "15"); await wait(400);
    await page.click("#dep-btn");
    await page.waitForFunction(() => /Confirmed/.test(document.getElementById("lp-why").textContent), null, { timeout: 120000 });
    await wait(1500);
  }, "Deposit 15 USDG into the LP vault (capped at $20 for the buildathon, in the contract)");
  await step(3, async () => {
    await scrollTo("#trade"); await wait(800);
    await page.fill("#margin", "2"); await page.click('#lev button[data-lev="5"]'); await wait(600);
    await page.locator(".quote").hover();
  }, "$2 margin at 5x: ~$10 of real NVDA. Most you can lose: $2.");
  await step(4, async () => {
    await page.click("#open-btn");
    await page.waitForFunction(() => /Confirmed/.test(document.getElementById("open-why").textContent), null, { timeout: 120000 });
    await wait(1500);
  }, "Open: the contract buys real NVDA in the Uniswap pool, within 1% of Chainlink");
  await step(5, async () => { await page.waitForSelector("[data-close]", { timeout: 60000 }); await page.locator(".pos").first().hover(); }, "Position: knock-out level and live P&L");
  await step(6, async () => {
    await page.evaluate(() => { document.getElementById("open-why").textContent = ""; });
    await page.click("[data-close]");
    await page.waitForFunction(() => /Confirmed/.test(document.getElementById("open-why").textContent), null, { timeout: 120000 });
    await page.waitForFunction(() => !document.querySelector("[data-close]"), null, { timeout: 120000 });
    await wait(1500);
  }, "Close: the vault is repaid in full; the rest comes back in USDG");
  await step(7, async () => { await scrollTo(".contracts"); }, "No admin key. USDG in, USDG out. Code, spec and tests on GitHub.");
  await wait(1500);
  } catch (e) {
    console.log("FAILED", e.message.split("\n")[0]);
    await page.screenshot({ path: path.join(OUT, "failure.png") });
    console.log("why texts:", await page.textContent("#open-why"), "|", await page.textContent("#lp-why"), "|", await page.textContent("#market-state"));
  }
  fs.writeFileSync(path.join(OUT, "marks.json"), JSON.stringify(marks, null, 1));
  const video = page.video();
  await ctx.close(); await browser.close();
  console.log("video", await video.path());
})();
