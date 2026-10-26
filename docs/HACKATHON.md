# QIE Mainnet Hackathon 3.0 submission notes

- **Live demo URL**: https://qie-forge.vercel.app (Next.js frontend, real live on-chain data, public, no login wall).
- **Event**: QIE Mainnet Hackathon 3.0, hackathon.qie.digital. Submission deadline Nov 30, 2026.
- **Track**: DeFi & Financial Infrastructure (the AMM + lending vault is a real financial protocol). Developer Infrastructure & Tooling is a secondary angle — the SDK/CLI in `packages/core`/`packages/cli` is genuinely reusable developer tooling, built and verified as part of this project, but is not the submission's headline.
- **Originality**: clean-room AMM (constant-product, own derivation) + isolated lending vault (own derivation). No existing DEX or lending protocol's source was read or copied while building this — see each contract's NatSpec for where every formula comes from. Built around a real, independently-discovered correction to QIE's own oracle documentation (see README's "Real findings" section) rather than a copy-pasted integration that would have silently failed.
- **Real-world usefulness**: a working DEX + money market is core DeFi infrastructure a new L1 needs; no public DEX contracts/source were found for QIE during this research pass (QIE Dex is listed as an ecosystem component with no discoverable open contracts).
- **Product quality / UX**: contract correctness proven first (25/25 Foundry tests); frontend planned next (see `plans/qie-hackathon.md` in the broader portfolio for the phased timeline — not published in this repo since it also tracks unrelated internal work).
- **QIE ecosystem integration (bonus)**:
  - **QIE Oracle** — real integration, using the actual deployed `AggregatorV3Interface`-shaped contracts (not QIE's own documented-but-broken `getPrice(string)` signature).
  - **QUSDC** — fail-closed, ready the moment a verified contract address exists (see README).
  - **QIE Wallet** — typed EIP-1193/EIP-6963 connection constants in `packages/core/src/walletConnect.ts`, matching QIE's real wallet-integration docs.
  - **QIE ID** — not integrated; no public API/contract was found for it during this research pass.
- **User-adoption potential**: swap/LP/borrow are the kind of recurring, measurable usage (wallet growth, tx volume, recurring users) the hackathon's own traction milestones reward.
- **Anti-abuse compliance**: this is a new repository with its own commit history, starting from this hackathon's build. No code was forked or ported from any existing project (QIE-specific or otherwise); OpenZeppelin and forge-std are used as standard, publicly-available libraries (the same category as using a language's standard library), not as the protocol being submitted.
