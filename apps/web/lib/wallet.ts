"use client";

import {
  QIE_WALLET_EIP6963_RDNS,
  buildSwitchChainParams,
  type AddEthereumChainParams,
} from "@qie-forge/core";

/** Minimal EIP-1193 provider shape — avoids pulling in a full wallet-connector
 * library for what QIE Wallet's own docs describe as a plain injected
 * provider (window.qie / EIP-6963 / window.ethereum). */
export interface Eip1193Provider {
  request: (args: { method: string; params?: unknown[] }) => Promise<unknown>;
  on?: (event: string, handler: (...args: unknown[]) => void) => void;
  removeListener?: (event: string, handler: (...args: unknown[]) => void) => void;
}

declare global {
  interface Window {
    qie?: Eip1193Provider;
    ethereum?: Eip1193Provider;
  }
}

interface Eip6963ProviderDetail {
  info: { rdns: string; name: string };
  provider: Eip1193Provider;
}

/** Listens briefly for EIP-6963 announcements and returns the QIE Wallet
 * provider if one responds, otherwise falls back to window.qie, then
 * window.ethereum (QIE Wallet docs: "reports isMetaMask = true for
 * compatibility, so use EIP-6963 rdns or window.qie for reliable
 * identification" — this follows that guidance in order). */
export async function discoverQieWalletProvider(timeoutMs = 300): Promise<Eip1193Provider | undefined> {
  if (typeof window === "undefined") return undefined;

  const found = await new Promise<Eip1193Provider | undefined>((resolve) => {
    const providers: Eip6963ProviderDetail[] = [];
    const onAnnounce = (event: Event) => {
      const detail = (event as CustomEvent<Eip6963ProviderDetail>).detail;
      if (detail) providers.push(detail);
    };
    window.addEventListener("eip6963:announceProvider", onAnnounce);
    window.dispatchEvent(new Event("eip6963:requestProvider"));

    setTimeout(() => {
      window.removeEventListener("eip6963:announceProvider", onAnnounce);
      const qie = providers.find((p) => p.info.rdns === QIE_WALLET_EIP6963_RDNS);
      resolve(qie?.provider);
    }, timeoutMs);
  });

  return found ?? window.qie ?? window.ethereum;
}

export async function requestAccounts(provider: Eip1193Provider): Promise<string[]> {
  const accounts = await provider.request({ method: "eth_requestAccounts" });
  return accounts as string[];
}

export async function ensureChain(
  provider: Eip1193Provider,
  chainId: number,
  addChainParams: AddEthereumChainParams,
): Promise<void> {
  try {
    await provider.request({ method: "wallet_switchEthereumChain", params: [buildSwitchChainParams(chainId)] });
  } catch (err) {
    const code = (err as { code?: number })?.code;
    if (code === 4902) {
      await provider.request({ method: "wallet_addEthereumChain", params: [addChainParams] });
    } else {
      throw err;
    }
  }
}
