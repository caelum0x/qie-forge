import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import Link from "next/link";
import "./globals.css";
import { ShieldIcon, SwapIcon } from "@/components/icons";
import { WalletProvider } from "@/components/WalletProvider";
import { WalletConnectButton } from "@/components/WalletConnectButton";
import { getNetworkConfig } from "@/lib/config";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "QIE Forge",
  description: "A clean-room AMM and lending vault for the QIE blockchain.",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  const network = getNetworkConfig();
  return (
    <html lang="en" className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}>
      <body className="min-h-full flex flex-col">
        <WalletProvider>
          <header className="border-b border-border">
            <nav className="mx-auto max-w-5xl flex items-center justify-between px-6 py-4">
              <div className="flex items-center gap-8">
                <Link href="/" className="font-semibold tracking-tight text-foreground">
                  QIE Forge
                </Link>
                <div className="flex items-center gap-6 text-sm text-muted">
                  <Link href="/swap" className="inline-flex items-center gap-1.5 hover:text-foreground">
                    <SwapIcon className="w-4 h-4" /> Swap
                  </Link>
                  <Link href="/vault" className="inline-flex items-center gap-1.5 hover:text-foreground">
                    <ShieldIcon className="w-4 h-4" /> Vault
                  </Link>
                </div>
              </div>
              <div className="flex items-center gap-3">
                <span className="hidden sm:inline text-xs text-muted uppercase tracking-wide">{network.name}</span>
                <WalletConnectButton chainId={network.chainId} />
              </div>
            </nav>
          </header>
          <main className="flex-1">{children}</main>
          <footer className="border-t border-border py-6">
            <div className="mx-auto max-w-5xl px-6 text-xs text-muted flex items-center justify-between">
              <span>QIE Forge — MIT licensed, built for QIE Mainnet Hackathon 3.0</span>
              <a
                href="https://github.com/caelum0x/qie-forge"
                className="hover:text-foreground"
                target="_blank"
                rel="noreferrer"
              >
                Source
              </a>
            </div>
          </footer>
        </WalletProvider>
      </body>
    </html>
  );
}
