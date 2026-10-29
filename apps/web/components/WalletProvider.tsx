"use client";

import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from "react";
import { buildAddEthereumChainParams, type QieNetworkName } from "@qie-forge/core";
import { getNetworkConfig } from "@/lib/config";
import { discoverQieWalletProvider, ensureChain, requestAccounts, type Eip1193Provider } from "@/lib/wallet";

interface WalletContextValue {
  provider: Eip1193Provider | undefined;
  address: string | undefined;
  connecting: boolean;
  error: string | undefined;
  connect: () => Promise<void>;
}

/**
 * Real bug fixed here: `connect()` used to take a `chainId` argument and
 * pick `wallet_addEthereumChain` params via `chainId === 1990 ? MAINNET :
 * TESTNET` — a ternary that only ever distinguishes QIE Mainnet from
 * everything else. The live production site today runs on the "demo"
 * network (chainId 31337, the self-hosted anvil devnet — the only network
 * actually deployed, see docs/STATUS.md), so every real visitor without
 * chain 31337 already in their wallet hit the `wallet_addEthereumChain`
 * fallback (switchEthereumChain's 4902 "unrecognized chain") and got
 * offered **QIE Testnet (1983)** instead — the wrong chain, with the wrong
 * RPC URL, where none of this app's deployed contracts exist. The UI would
 * then show "connected" while every subsequent swap/deposit/borrow
 * transaction silently targeted the wrong network. Fixed by building the
 * add-chain params from whichever network is actually configured
 * (`getNetworkConfig()`), not a hardcoded two-network guess — this also
 * means a future real Testnet/Mainnet deployment needs no code change here
 * either.
 */
const NETWORK_DISPLAY_NAMES: Record<QieNetworkName, string> = {
  testnet: "QIE Testnet",
  mainnet: "QIE Mainnet",
  demo: "QIE Forge Demo",
};

const WalletContext = createContext<WalletContextValue | undefined>(undefined);

/**
 * Real gap found 2026-10-29: `Eip1193Provider` (lib/wallet.ts) has always
 * declared the standard optional `on`/`removeListener` event-subscription
 * methods EIP-1193 providers expose — but nothing in this app ever called
 * them. Once `connect()` sets `address`/chain once at connect time, the app
 * never learns about `accountsChanged` (user switches accounts in their
 * wallet) or `chainChanged` (user switches networks in their wallet) after
 * that. Every subsequent read (`/api/vault-position`, `/api/pool-position`)
 * and write (`sendContractCall`'s `from: address`) keeps using the stale
 * address/assumed chain — a real, well-known Web3 dApp correctness gap
 * (every wallet-connector library treats this as a baseline requirement),
 * not a cosmetic one: a user who switches to a different account mid-session
 * would keep seeing (and acting on) the previous account's vault/pool
 * position without any indication anything changed.
 */
export function WalletProvider({ children }: { children: ReactNode }) {
  const [provider, setProvider] = useState<Eip1193Provider | undefined>(undefined);
  const [address, setAddress] = useState<string | undefined>(undefined);
  const [connecting, setConnecting] = useState(false);
  const [error, setError] = useState<string | undefined>(undefined);

  useEffect(() => {
    discoverQieWalletProvider().then(setProvider);
  }, []);

  useEffect(() => {
    if (!provider?.on) return;

    const handleAccountsChanged = (...args: unknown[]) => {
      const accounts = args[0] as string[] | undefined;
      setAddress(accounts && accounts.length > 0 ? accounts[0] : undefined);
    };

    // The wallet switched to a different chain outside this app's control.
    // Since every read/write here is hardwired to one configured network
    // (getNetworkConfig()), the only safe response is to drop the stale
    // `address` and surface an error — forcing the user to click "Connect
    // Wallet" again, which re-runs ensureChain() and re-validates everything,
    // rather than silently continuing to read/write against whatever chain
    // the wallet is now actually on.
    const handleChainChanged = () => {
      setAddress(undefined);
      setError("Wallet switched networks. Reconnect to continue using this app.");
    };

    provider.on("accountsChanged", handleAccountsChanged);
    provider.on("chainChanged", handleChainChanged);
    return () => {
      provider.removeListener?.("accountsChanged", handleAccountsChanged);
      provider.removeListener?.("chainChanged", handleChainChanged);
    };
  }, [provider]);

  const connect = useCallback(async () => {
    if (!provider) {
      setError("No wallet found. Install QIE Wallet or another EVM wallet extension.");
      return;
    }
    setConnecting(true);
    setError(undefined);
    try {
      const accounts = await requestAccounts(provider);
      const network = getNetworkConfig();
      const addChainParams = buildAddEthereumChainParams({
        chainId: network.chainId,
        rpcUrl: network.rpcUrl,
        explorerUrl: network.explorerUrl,
        nativeCurrencySymbol: network.nativeCurrencySymbol,
        displayName: NETWORK_DISPLAY_NAMES[network.name],
      });
      await ensureChain(provider, network.chainId, addChainParams);
      setAddress(accounts[0]);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to connect wallet");
    } finally {
      setConnecting(false);
    }
  }, [provider]);

  return (
    <WalletContext.Provider value={{ provider, address, connecting, error, connect }}>
      {children}
    </WalletContext.Provider>
  );
}

export function useWallet(): WalletContextValue {
  const ctx = useContext(WalletContext);
  if (!ctx) throw new Error("useWallet must be used within WalletProvider");
  return ctx;
}
