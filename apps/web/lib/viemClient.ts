import { createPublicClient, http, defineChain } from "viem";
import { getNetworkConfig } from "./config";

export function getPublicClient() {
  const config = getNetworkConfig();
  const chain = defineChain({
    id: config.chainId,
    name: `qie-${config.name}`,
    nativeCurrency: { name: "QIE", symbol: "QIE", decimals: 18 },
    rpcUrls: { default: { http: [config.rpcUrl] } },
  });
  return createPublicClient({ chain, transport: http(config.rpcUrl) });
}
