"use client";

import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from "react";
import { QIE_TESTNET_ADD_CHAIN_PARAMS, QIE_MAINNET_ADD_CHAIN_PARAMS } from "@qie-forge/core";
import { discoverQieWalletProvider, ensureChain, requestAccounts, type Eip1193Provider } from "@/lib/wallet";

interface WalletContextValue {
  provider: Eip1193Provider | undefined;
  address: string | undefined;
  connecting: boolean;
  error: string | undefined;
  connect: (chainId: number) => Promise<void>;
}

const WalletContext = createContext<WalletContextValue | undefined>(undefined);

export function WalletProvider({ children }: { children: ReactNode }) {
  const [provider, setProvider] = useState<Eip1193Provider | undefined>(undefined);
  const [address, setAddress] = useState<string | undefined>(undefined);
  const [connecting, setConnecting] = useState(false);
  const [error, setError] = useState<string | undefined>(undefined);

  useEffect(() => {
    discoverQieWalletProvider().then(setProvider);
  }, []);

  const connect = useCallback(
    async (chainId: number) => {
      if (!provider) {
        setError("No wallet found. Install QIE Wallet or another EVM wallet extension.");
        return;
      }
      setConnecting(true);
      setError(undefined);
      try {
        const accounts = await requestAccounts(provider);
        const addChainParams = chainId === 1990 ? QIE_MAINNET_ADD_CHAIN_PARAMS : QIE_TESTNET_ADD_CHAIN_PARAMS;
        await ensureChain(provider, chainId, addChainParams);
        setAddress(accounts[0]);
      } catch (err) {
        setError(err instanceof Error ? err.message : "Failed to connect wallet");
      } finally {
        setConnecting(false);
      }
    },
    [provider],
  );

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
