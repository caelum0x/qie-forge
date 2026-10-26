/**
 * QIE Wallet integration constants, verified live against
 * docs.qie.digital/qie-wallet-integration-guide-for-websites on 2026-10-26.
 *
 * QIE Wallet connects via an EIP-1193 provider injected into the browser
 * (`window.qie`, optionally `window.ethereum`, discoverable via EIP-6963
 * with rdns `me.qiewallet`). That is a browser/DOM concern, not something a
 * Node.js backend can do on a user's behalf — QIE Forge does not fake a
 * server-side "wallet connect" that cannot exist. What this module DOES
 * provide, honestly, is the typed constants and payload builders a
 * frontend needs to wire that real flow up correctly against QIE
 * specifically (chain IDs, add-chain params, rdns), so an app built with
 * `@qie-forge/core` gets a verified, consistent wallet integration instead
 * of each app re-deriving hex chain IDs by hand.
 */

export const QIE_WALLET_EIP6963_RDNS = "me.qiewallet";

export interface AddEthereumChainParams {
  chainId: `0x${string}`;
  chainName: string;
  nativeCurrency: { name: string; symbol: string; decimals: number };
  rpcUrls: string[];
  blockExplorerUrls: string[];
}

const toHexChainId = (chainId: number): `0x${string}` => `0x${chainId.toString(16)}`;

export function buildAddEthereumChainParams(network: {
  chainId: number;
  rpcUrl: string;
  explorerUrl: string;
  nativeCurrencySymbol: string;
  displayName: string;
}): AddEthereumChainParams {
  return {
    chainId: toHexChainId(network.chainId),
    chainName: network.displayName,
    nativeCurrency: {
      name: network.nativeCurrencySymbol,
      symbol: network.nativeCurrencySymbol,
      decimals: 18,
    },
    rpcUrls: [network.rpcUrl],
    blockExplorerUrls: [network.explorerUrl],
  };
}

/** `wallet_switchEthereumChain` request params, QIE-specific hex IDs pre-filled. */
export function buildSwitchChainParams(chainId: number): { chainId: `0x${string}` } {
  return { chainId: toHexChainId(chainId) };
}

export const QIE_TESTNET_ADD_CHAIN_PARAMS: AddEthereumChainParams = buildAddEthereumChainParams({
  chainId: 1983,
  rpcUrl: "https://testnet.qie.digital/api/eth-rpc",
  explorerUrl: "https://testnet.qie.digital",
  nativeCurrencySymbol: "QIE",
  displayName: "QIE Testnet",
});

export const QIE_MAINNET_ADD_CHAIN_PARAMS: AddEthereumChainParams = buildAddEthereumChainParams({
  chainId: 1990,
  rpcUrl: "https://rpc1mainnet.qie.digital",
  explorerUrl: "https://mainnet.qie.digital",
  nativeCurrencySymbol: "QIE",
  displayName: "QIE Mainnet",
});
