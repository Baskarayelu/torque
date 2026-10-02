import { BrowserProvider, Contract, Interface, JsonRpcProvider, type Signer } from "ethers";

export type Config = {
  environment: "mainnet" | "fork-rehearsal";
  chainId: number;
  chainName: string;
  rpc: string;
  explorer: string;
  repo: string;
  landing: string;
  MARKET: string | null;
  VAULT: string | null;
  USDG: string;
  NVDA: string;
  POOL: string;
  FEED: string;
};

export async function loadConfig(): Promise<Config> {
  const res = await fetch("/config.json", { cache: "no-store" });
  return res.json();
}

export const isDeployed = (c: Config) => Boolean(c.MARKET && c.VAULT);

// Contract parameters (TorqueMarket / TorqueVault constants). Used for quotes and labels only.
export const P = {
  VAULT_CAP: 20,
  MAX_OPEN_NOTIONAL: 30,
  MAX_UTILIZATION: 0.8,
  KO_BUFFER: 0.05,
  OPEN_FEE: 0.001,
  APR: 0.1,
  MAX_FEED_AGE: 12 * 3600,
  TWAP_WINDOW: 1800,
  MAX_POOL_DEVIATION_BPS: 150,
  MIN_MARGIN: 1,
};

const ABI = {
  erc20: [
    "function balanceOf(address) view returns (uint256)",
    "function allowance(address,address) view returns (uint256)",
    "function approve(address,uint256) returns (bool)",
  ],
  feed: ["function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)"],
  pool: ["function observe(uint32[]) view returns (int56[],uint160[])"],
  market: [
    "function priceStatus() view returns (uint256,uint256,uint256,uint256,bool,bool)",
    "function openPositionIds() view returns (uint256[])",
    "function getPosition(uint256) view returns ((address owner,uint128 q,uint128 principal,uint128 notional,uint128 margin,uint64 openedAt))",
    "function debtOf(uint256) view returns (uint256)",
    "function barrierOf(uint256) view returns (uint256)",
    "function totalPrincipal() view returns (uint256)",
    "function totalNotional() view returns (uint256)",
    "function totalBadDebt() view returns (uint256)",
    "function claimable(address) view returns (uint256)",
    "function open(uint256,uint256,uint256) returns (uint256)",
    "function close(uint256,uint256) returns (uint256)",
    "function knockOut(uint256) returns (uint256)",
    "function claim() returns (uint256)",
  ],
  vault: [
    "function totalAssets() view returns (uint256)",
    "function idle() view returns (uint256)",
    "function balanceOf(address) view returns (uint256)",
    "function convertToAssets(uint256) view returns (uint256)",
    "function deposit(uint256,address) returns (uint256)",
    "function withdraw(uint256,address,address) returns (uint256)",
  ],
};

export type PriceStatus = {
  feed: number; // USDG per NVDA
  feedAge: number; // seconds
  twap: number; // pool 30-minute average
  deviationBps: number;
  feedFresh: boolean;
  poolAgrees: boolean;
};

export type Position = {
  id: bigint;
  owner: string;
  q: number; // NVDA
  margin: number;
  notional: number;
  debt: number;
  barrier: number;
};

export type Snapshot = {
  price: PriceStatus | null;
  vault: { assets: number; idle: number; lent: number; openNotional: number; badDebt: number } | null;
  nvdaHeld: number | null;
  positions: Position[] | null;
  share: number | null;
  claimable: number | null;
  readAt: number;
};

export function makeReader(cfg: Config) {
  const provider = new JsonRpcProvider(cfg.rpc, cfg.chainId, { staticNetwork: true });
  const feed = new Contract(cfg.FEED, ABI.feed, provider);
  const pool = new Contract(cfg.POOL, ABI.pool, provider);
  const nvda = new Contract(cfg.NVDA, ABI.erc20, provider);
  const market = cfg.MARKET ? new Contract(cfg.MARKET, ABI.market, provider) : null;
  const vault = cfg.VAULT ? new Contract(cfg.VAULT, ABI.vault, provider) : null;

  async function priceStatus(): Promise<PriceStatus> {
    if (market) {
      const r = await market.priceStatus();
      return {
        feed: Number(r[0]) / 1e6,
        feedAge: Number(r[1]),
        twap: Number(r[2]) / 1e6,
        deviationBps: Number(r[3]),
        feedFresh: r[4],
        poolAgrees: r[5],
      };
    }
    // Not deployed: compute both checks exactly as TorqueMarket.priceStatus() does.
    const [rd, ob, block] = await Promise.all([feed.latestRoundData(), pool.observe([P.TWAP_WINDOW, 0]), provider.getBlock("latest")]);
    const now = block ? block.timestamp : Math.floor(Date.now() / 1000);
    const feedPrice = Number(rd[1]) / 1e8;
    const feedAge = Math.max(0, now - Number(rd[3]));
    const delta = Number(ob[0][1] - ob[0][0]);
    const avgTick = Math.floor(delta / P.TWAP_WINDOW);
    const twap = 1e18 / Math.pow(1.0001, avgTick) / 1e6; // USDG is token0, NVDA token1
    const deviationBps = Math.floor((Math.abs(twap - feedPrice) * 10_000) / feedPrice);
    return {
      feed: feedPrice,
      feedAge,
      twap,
      deviationBps,
      feedFresh: feedPrice > 0 && feedAge <= P.MAX_FEED_AGE,
      poolAgrees: deviationBps <= P.MAX_POOL_DEVIATION_BPS,
    };
  }

  async function snapshot(account: string | null): Promise<Snapshot> {
    const price = await priceStatus().catch(() => null);
    if (!market || !vault) {
      return { price, vault: null, nvdaHeld: null, positions: null, share: null, claimable: null, readAt: Date.now() };
    }
    const [assets, idle, lent, openNotional, badDebt, held, ids] = await Promise.all([
      vault.totalAssets(),
      vault.idle(),
      market.totalPrincipal(),
      market.totalNotional(),
      market.totalBadDebt(),
      nvda.balanceOf(cfg.MARKET),
      market.openPositionIds(),
    ]);
    const positions: Position[] = [];
    for (const id of ids as bigint[]) {
      try {
        const [p, debt, barrier] = await Promise.all([market.getPosition(id), market.debtOf(id), market.barrierOf(id)]);
        positions.push({
          id,
          owner: p.owner,
          q: Number(p.q) / 1e18,
          margin: Number(p.margin) / 1e6,
          notional: Number(p.notional) / 1e6,
          debt: Number(debt) / 1e6,
          barrier: Number(barrier) / 1e6,
        });
      } catch {
        // closed between the list read and this read
      }
    }
    let share: number | null = null;
    let claim: number | null = null;
    if (account) {
      const sh = await vault.balanceOf(account);
      share = sh > 0n ? Number(await vault.convertToAssets(sh)) / 1e6 : 0;
      claim = Number(await market.claimable(account)) / 1e6;
    }
    return {
      price,
      vault: {
        assets: Number(assets) / 1e6,
        idle: Number(idle) / 1e6,
        lent: Number(lent) / 1e6,
        openNotional: Number(openNotional) / 1e6,
        badDebt: Number(badDebt) / 1e6,
      },
      nvdaHeld: Number(held) / 1e18,
      positions,
      share,
      claimable: claim,
      readAt: Date.now(),
    };
  }

  return { snapshot, provider };
}

// ---------------------------------------------------------------- formulas (TorqueMarket._sizes and friends)

export function quote(margin: number, lev: number, price: number) {
  const fee = margin * lev * P.OPEN_FEE;
  const equity = margin - fee;
  const notional = equity * lev;
  const borrow = notional - equity;
  const q = price > 0 ? notional / price : 0;
  const financing = q > 0 ? borrow / q : 0;
  const knockOut = financing * (1 + P.KO_BUFFER);
  return { fee, notional, borrow, q, financing, knockOut };
}

/** Trader P&L at NVDA price x for a fresh position, in USDG. Below the knock-out the position is closed at the
 *  knock-out level (residual returned); the worst case, a gap through the financing level, is -margin. */
export function payoffAt(x: number, margin: number, lev: number, entry: number) {
  const { q, borrow, knockOut } = quote(margin, lev, entry);
  const settle = Math.max(x, knockOut);
  return Math.max(q * settle - borrow, 0) - margin;
}

// ---------------------------------------------------------------- wallet

export async function connectWallet(cfg: Config): Promise<{ signer: Signer; account: string }> {
  const eth = (window as unknown as { ethereum?: { request: (a: { method: string; params?: unknown[] }) => Promise<unknown> } }).ethereum;
  if (!eth) throw new Error("No browser wallet found.");
  const hex = "0x" + cfg.chainId.toString(16);
  try {
    await eth.request({ method: "wallet_switchEthereumChain", params: [{ chainId: hex }] });
  } catch (e) {
    if ((e as { code?: number }).code === 4902) {
      await eth.request({
        method: "wallet_addEthereumChain",
        params: [{ chainId: hex, chainName: cfg.chainName, nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: [cfg.rpc], blockExplorerUrls: [cfg.explorer] }],
      });
    } else throw e;
  }
  const bp = new BrowserProvider(eth);
  const signer = await bp.getSigner();
  return { signer, account: await signer.getAddress() };
}

export function writers(cfg: Config, signer: Signer) {
  const market = new Contract(cfg.MARKET!, ABI.market, signer);
  const vault = new Contract(cfg.VAULT!, ABI.vault, signer);
  const usdg = new Contract(cfg.USDG, ABI.erc20, signer);
  const ensure = async (spender: string, amount: bigint) => {
    const owner = await signer.getAddress();
    if ((await usdg.allowance(owner, spender)) < amount) await (await usdg.approve(spender, amount)).wait();
  };
  return { market, vault, ensure };
}

export const iface = new Interface(ABI.market);
