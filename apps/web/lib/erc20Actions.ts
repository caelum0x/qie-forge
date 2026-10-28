import { encodeFunctionData } from "viem";
import { ERC20_ABI } from "./contracts";
import type { Eip1193Provider } from "./wallet";

/**
 * Shared approve+send helpers for every wallet-signed write in this app
 * (swap, vault deposit/withdraw/borrow/repay, lender supply/withdraw).
 * Extracted once both the swap flow and the vault flow needed the exact
 * same "check allowance, approve if short, then call" sequence, instead of
 * re-deriving it per component.
 */

/**
 * Reads the current on-chain allowance and sends an `approve` transaction
 * first if it is insufficient for `amount`. Returns `true` if an approval
 * transaction was actually sent, so callers can surface a "waiting for
 * approval" status before the follow-up call. Approves the exact amount
 * needed, never an unlimited allowance.
 */
export async function ensureAllowance(
  provider: Eip1193Provider,
  token: `0x${string}`,
  owner: `0x${string}`,
  spender: `0x${string}`,
  amount: bigint,
): Promise<boolean> {
  const allowanceData = encodeFunctionData({
    abi: ERC20_ABI,
    functionName: "allowance",
    args: [owner, spender],
  });
  const allowanceRaw = (await provider.request({
    method: "eth_call",
    params: [{ to: token, data: allowanceData, from: owner }, "latest"],
  })) as string;
  const allowance = BigInt(allowanceRaw);
  if (allowance >= amount) return false;

  const approveData = encodeFunctionData({
    abi: ERC20_ABI,
    functionName: "approve",
    args: [spender, amount],
  });
  await provider.request({
    method: "eth_sendTransaction",
    params: [{ from: owner, to: token, data: approveData }],
  });
  return true;
}

/** Sends a plain `eth_sendTransaction` with pre-encoded call data, returning the tx hash. */
export async function sendContractCall(
  provider: Eip1193Provider,
  from: `0x${string}`,
  to: `0x${string}`,
  data: `0x${string}`,
): Promise<string> {
  const txHash = await provider.request({
    method: "eth_sendTransaction",
    params: [{ from, to, data }],
  });
  return String(txHash);
}
