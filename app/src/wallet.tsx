// Wallet connection: RainbowKit's modal on wagmi, for one chain (Robinhood Chain), with an ethers bridge so the
// existing write path (chain.ts writers) is unchanged.
import { connectorsForWallets, darkTheme, lightTheme, RainbowKitProvider, type Theme } from "@rainbow-me/rainbowkit";
import { injectedWallet, metaMaskWallet, rabbyWallet, rainbowWallet, walletConnectWallet } from "@rainbow-me/rainbowkit/wallets";
import "@rainbow-me/rainbowkit/styles.css";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { BrowserProvider, JsonRpcSigner, type Signer } from "ethers";
import type { ReactNode } from "react";
import { defineChain, type Chain } from "viem";
import { createConfig, fallback, http, WagmiProvider, type Config as WagmiConfig } from "wagmi";
import { getConnectorClient, switchChain } from "wagmi/actions";
import { readRpcs, type Config } from "./chain";

// Reown Cloud project for WalletConnect. A public identifier (it ships in every dapp bundle); the project's
// allowed-domains list, not secrecy, is what restricts it.
const WALLETCONNECT_PROJECT_ID = "a8dd711b6da65f89b0b497ad30e617d5";

export function makeChain(cfg: Config): Chain {
  return defineChain({
    id: cfg.chainId,
    name: cfg.chainName,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [cfg.rpc] } },
    blockExplorers: { default: { name: "Blockscout", url: cfg.explorer } },
  });
}

export function makeWagmi(cfg: Config): WagmiConfig {
  const chain = makeChain(cfg);
  // Every option must lead somewhere for a visitor with no extension: MetaMask and Rainbow offer a QR code and an
  // install link, Rabby an install link, WalletConnect a QR code. The generic browser-wallet entry only appears when
  // a wallet is actually injected (otherwise it waits forever on an extension that is not there), and installed
  // wallets that announce themselves (EIP-6963, e.g. Coinbase Wallet) are listed automatically by wagmi.
  const hasInjected = typeof window !== "undefined" && Boolean((window as { ethereum?: unknown }).ethereum);
  const connectors = connectorsForWallets(
    [
      { groupName: "Installed or popular", wallets: [...(hasInjected ? [injectedWallet] : []), metaMaskWallet, rabbyWallet] },
      { groupName: "Mobile, by QR code", wallets: [walletConnectWallet, rainbowWallet] },
    ],
    { appName: "TORQUE", appUrl: "https://app.torque.0xo.in", projectId: WALLETCONNECT_PROJECT_ID },
  );
  // App reads go through the private RPC when one is configured, public as fallback. The chain definition a wallet
  // is offered (makeChain) keeps the public RPC, so a private key never lands in a user's wallet settings.
  return createConfig({ chains: [chain], connectors, transports: { [chain.id]: fallback(readRpcs(cfg).map((u) => http(u))) }, ssr: false });
}

const queryClient = new QueryClient();

export function WalletProviders({ wagmi, children }: { wagmi: WagmiConfig; children: ReactNode }) {
  return (
    <WagmiProvider config={wagmi}>
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    </WagmiProvider>
  );
}

// The modal follows the dashboard's own theme toggle, in TORQUE's colours.
const shared = { borderRadius: "medium", fontStack: "system", overlayBlur: "none" } as const;
const rkDark = darkTheme({ ...shared, accentColor: "#ff6a2b", accentColorForeground: "#0b0b0c" });
const rkLight = lightTheme({ ...shared, accentColor: "#c2410c", accentColorForeground: "#ffffff" });
const withFonts = (t: Theme): Theme => ({ ...t, fonts: { body: "Inter, system-ui, sans-serif" } });

export function ThemedRainbowKit({ dark, chain, children }: { dark: boolean; chain: Chain; children: ReactNode }) {
  return (
    <RainbowKitProvider theme={withFonts(dark ? rkDark : rkLight)} initialChain={chain} modalSize="wide" appInfo={{ appName: "TORQUE", learnMoreUrl: "https://ethereum.org/en/wallets/" }}>
      {children}
    </RainbowKitProvider>
  );
}

/** An ethers signer for the connected wallet, on Robinhood Chain (switching the wallet there first if needed). */
export async function ethersSigner(wagmi: WagmiConfig, chainId: number): Promise<Signer> {
  const client = await getConnectorClient(wagmi).catch(() => null);
  if (!client) throw new Error("Connect a wallet first.");
  if (client.chain.id !== chainId) await switchChain(wagmi, { chainId });
  const c = await getConnectorClient(wagmi, { chainId });
  const provider = new BrowserProvider(c.transport, { chainId: c.chain.id, name: c.chain.name });
  return new JsonRpcSigner(provider, c.account.address);
}
