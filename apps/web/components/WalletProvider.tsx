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

export function WalletProvider({ children }: { children: ReactNode }) {
  const [provider, setProvider] = useState<Eip1193Provider | undefined>(undefined);
  const [address, setAddress] = useState<string | undefined>(undefined);
  const [connecting, setConnecting] = useState(false);
  const [error, setError] = useState<string | undefined>(undefined);

  useEffect(() => {
    discoverQieWalletProvider().then(setProvider);
  }, []);

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
