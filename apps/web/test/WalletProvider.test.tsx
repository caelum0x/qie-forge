import { act, cleanup, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { WalletProvider, useWallet } from "../components/WalletProvider";
import type { Eip1193Provider } from "../lib/wallet";

/**
 * Real gap found 2026-10-29: `Eip1193Provider` has always declared the
 * standard `on`/`removeListener` event hooks, but nothing in this app ever
 * subscribed to `accountsChanged`/`chainChanged` — the UI kept using a
 * stale address/assumed chain forever after the user switched accounts or
 * networks inside their wallet, post-connect. This test drives the real
 * `WalletProvider` component (not a reimplementation) against a mock
 * EIP-1193 provider to prove the fix actually wires those events through.
 */
vi.mock("../lib/wallet", async () => {
  const actual = await vi.importActual<typeof import("../lib/wallet")>("../lib/wallet");
  return { ...actual, discoverQieWalletProvider: vi.fn() };
});

function Probe() {
  const { address, error } = useWallet();
  return (
    <div>
      <span data-testid="addr">{address ?? "none"}</span>
      <span data-testid="err">{error ?? "none"}</span>
    </div>
  );
}

function makeMockProvider() {
  const handlers = new Map<string, (...args: unknown[]) => void>();
  const provider: Eip1193Provider = {
    request: vi.fn(async ({ method }: { method: string }) => {
      if (method === "eth_requestAccounts") return ["0xAAA0000000000000000000000000000000AAAA"];
      if (method === "wallet_switchEthereumChain") return null;
      return null;
    }),
    on: (event, handler) => handlers.set(event, handler),
    removeListener: vi.fn((event: string) => handlers.delete(event)),
  };
  return { provider, handlers };
}

describe("WalletProvider account/chain change listeners", () => {
  afterEach(cleanup);

  it("updates address on accountsChanged", async () => {
    const { provider, handlers } = makeMockProvider();
    const { discoverQieWalletProvider } = await import("../lib/wallet");
    (discoverQieWalletProvider as ReturnType<typeof vi.fn>).mockResolvedValue(provider);

    render(
      <WalletProvider>
        <Probe />
      </WalletProvider>,
    );

    await waitFor(() => expect(handlers.has("accountsChanged")).toBe(true));

    act(() => {
      handlers.get("accountsChanged")!(["0xBBB0000000000000000000000000000000BBBB"]);
    });
    await waitFor(() =>
      expect(screen.getByTestId("addr").textContent).toBe("0xBBB0000000000000000000000000000000BBBB"),
    );

    // Wallet-side disconnect (accounts array empties) must clear the stale address too.
    act(() => {
      handlers.get("accountsChanged")!([]);
    });
    await waitFor(() => expect(screen.getByTestId("addr").textContent).toBe("none"));
  });

  it("clears the address and surfaces an error on chainChanged", async () => {
    const { provider, handlers } = makeMockProvider();
    const { discoverQieWalletProvider } = await import("../lib/wallet");
    (discoverQieWalletProvider as ReturnType<typeof vi.fn>).mockResolvedValue(provider);

    render(
      <WalletProvider>
        <Probe />
      </WalletProvider>,
    );

    await waitFor(() => expect(handlers.has("accountsChanged")).toBe(true));
    act(() => {
      handlers.get("accountsChanged")!(["0xAAA0000000000000000000000000000000AAAA"]);
    });
    await waitFor(() => expect(screen.getByTestId("addr").textContent).not.toBe("none"));

    act(() => {
      handlers.get("chainChanged")!("0x1");
    });
    await waitFor(() => expect(screen.getByTestId("addr").textContent).toBe("none"));
    expect(screen.getByTestId("err").textContent).toMatch(/switched networks/i);
  });
});
