/**
 * Typed error taxonomy for QIE Forge.
 *
 * Design rule (matches this codebase's documentation standard): every
 * client fails CLOSED on missing/unconfirmed configuration. Nothing here
 * ever guesses a contract address, a facilitator URL, or silently falls
 * back to a different network than the caller asked for. If a fact was
 * not independently verified against a live RPC/API call, the code throws
 * one of these typed errors instead of fabricating a result.
 */

export type QieForgeErrorCode =
  | "NETWORK_UNREACHABLE"
  | "UNSUPPORTED_NETWORK"
  | "ORACLE_NOT_DEPLOYED"
  | "ORACLE_ASSET_UNSUPPORTED"
  | "ASSET_NOT_CONFIGURED"
  | "INVALID_ADDRESS"
  | "INVALID_RESPONSE"
  | "EXPLORER_UNAVAILABLE";

export class QieForgeError extends Error {
  readonly code: QieForgeErrorCode;
  readonly details?: Record<string, unknown>;

  constructor(
    code: QieForgeErrorCode,
    message: string,
    details?: Record<string, unknown>,
  ) {
    super(message);
    this.name = "QieForgeError";
    this.code = code;
    this.details = details;
  }
}
