# QIE Mainnet Hackathon 3.0 submission notes

See [`../SUBMISSION.md`](../SUBMISSION.md) for the judge-facing summary,
[`DEMO-SCRIPT.md`](DEMO-SCRIPT.md) for the demo-video walkthrough script, and
[`TEAM-PRESENTATION.md`](TEAM-PRESENTATION.md) for the team presentation.
This file stays as internal submission notes.

## Real submission mechanics (re-verified live, 2026-10-28, via `gstack browse` clicking open every FAQ accordion on hackathon.qie.digital — not guessed, not from static HTML which hides the answers behind JS)

- **How to submit**: "Sign in, open the submission form, and provide your
  GitHub repository, live demo URL, deployed contract address, and the
  hackathon track that best fits your project." No separate platform
  (HackerEarth/Devpost/DoraHacks) is named — it's the hackathon site's own
  form, gated behind sign-in. No specific repo tag/branch is required.
- **Mandatory submission elements (verbatim FAQ answer)**: "All submissions
  must include: mainnet deployment, open-source smart contracts, live public
  app, public repository, demo video, documentation, and team presentation."
- **Mainnet deployment is a hard eligibility gate, not just a scoring factor**
  (verbatim FAQ answer to "Do we need to deploy on QIE Mainnet?"): **"Yes.
  Testnet-only projects are not eligible. Judges verify contracts,
  transactions, deployment, and frontend connectivity on QIE Mainnet."** This
  is the single biggest open gap for this repo today — see "Not engaged /
  still open" below.
- **Judging weights (verbatim FAQ answer)**: Innovation 30%, Technical
  Quality 25%, User Experience 15%, Mainnet Integration 15%, Business
  Potential 15%. (Supersedes this file's earlier unweighted five-criterion
  list below, which is still directionally correct — same five criteria,
  this just adds the real numbers.)
- **Payouts (verbatim FAQ answer)**: "Winners receive 50% immediately on Dec
  10, 2026. The remaining 50% is paid after meeting any 3 traction milestones
  within 90 days."
- **AI-assisted development (verbatim FAQ answer)**: "Yes, AI-assisted
  development is encouraged. Teams must fully understand and maintain their
  code and be able to explain architecture to judges."
- **No specific demo-video format/length/hosting-platform requirement, and
  no specific team-presentation template/format requirement are stated
  anywhere on the site** — confirmed by reading the full rendered page text
  after opening every FAQ item, not just the static HTML (which hides
  accordion answers behind client-side JS until clicked). Both are free-form.
- **Deadline**: the page's top banner currently reads "Build window: Aug 1 -
  Dec 10, 2026 · Mainnet only," which could be read as the deadline moving to
  Dec 10 — but the page's own detailed timeline section is internally
  consistent and unchanged: Development Period Aug 1 - Nov 30, **Submission
  deadline Nov 30, 2026**, Demo Week Dec 1-5, Winners announced Dec 10. Treat
  Nov 30 as the real deadline; the banner phrase almost certainly just means
  "the whole event, including demo week and winners, wraps by Dec 10."

- **Live demo URL**: https://qie-forge.vercel.app (Next.js frontend, real live on-chain data, public, no login wall). Re-confirmed live 2026-10-28 after fixing a real outage (see "Infra note" at the bottom of this file).
- **Event**: QIE Mainnet Hackathon 3.0, hackathon.qie.digital. Submission deadline Nov 30, 2026.
- **Track**: DeFi & Financial Infrastructure (the AMM + lending vault is a real financial protocol). Developer Infrastructure & Tooling is a secondary angle — the SDK/CLI in `packages/core`/`packages/cli` is genuinely reusable developer tooling, built and verified as part of this project, but is not the submission's headline.
- **Originality**: clean-room AMM (constant-product, own derivation) + isolated lending vault (own derivation). No existing DEX or lending protocol's source was read or copied while building this — see each contract's NatSpec for where every formula comes from. Built around a real, independently-discovered correction to QIE's own oracle documentation (see README's "Real findings" section) rather than a copy-pasted integration that would have silently failed.
- **Real-world usefulness**: a working DEX + money market is core DeFi infrastructure a new L1 needs; no public DEX contracts/source were found for QIE during this research pass (QIE Dex is listed as an ecosystem component with no discoverable open contracts).
- **Product quality / UX**: contract correctness proven first (65/65 Foundry tests), then a live public frontend shipped and verified end-to-end (https://qie-forge.vercel.app) — real swap quotes and vault positions rendered through the actual UI, not screenshots (see `plans/qie-hackathon.md` in the broader portfolio for the full build history — not published in this repo since it also tracks unrelated internal work).
- **QIE ecosystem integration (bonus)**:
  - **QIE Oracle** — real integration, using the actual deployed `AggregatorV3Interface`-shaped contracts (not QIE's own documented-but-broken `getPrice(string)` signature).
  - **QUSDC** — fail-closed, ready the moment a verified contract address exists (see README).
  - **QIE Wallet** — typed EIP-1193/EIP-6963 connection constants in `packages/core/src/walletConnect.ts`, matching QIE's real wallet-integration docs.
  - **QIE ID** — not integrated; no public API/contract was found for it during this research pass.
- **User-adoption potential**: swap/LP/borrow are the kind of recurring, measurable usage (wallet growth, tx volume, recurring users) the hackathon's own traction milestones reward.
- **Anti-abuse compliance**: this is a new repository with its own commit history, starting from this hackathon's build. No code was forked or ported from any existing project (QIE-specific or otherwise); OpenZeppelin and forge-std are used as standard, publicly-available libraries (the same category as using a language's standard library), not as the protocol being submitted.

## Infra note (2026-10-28) — the public demo RPC was found down, fixed during this pass

`http://130.61.180.42:8647` (the public reverse proxy in front of the
self-hosted anvil demo devnet) was unreachable (`connection refused`) when
first checked this pass. Root cause: the box's Caddy config-management
tooling (`install.sh caddy`) regenerated `/etc/caddy/sites-enabled/` from its
own managed `CADDY_SITES` list at some point after 2026-10-27, and this
site's `.caddy` file — added by hand, outside that managed list, exactly as
its own code comment warned could happen — got moved to
`sites-enabled.prev/` instead of staying enabled. The anvil Docker container
itself (`qie-forge-demo-anvil`) was never down; only the public proxy in
front of it was. Fixed by copying the file back to `sites-enabled/` and
`sudo systemctl reload caddy`. Re-verified end-to-end immediately after:
`eth_chainId` over the public URL, the live Vercel `/api/quote` and
`/api/vault-position` endpoints, and the homepage's rendered oracle/block
data all returned real matching values again. This is now a known fragility
of the manual demo-RPC site file — if `install.sh caddy` is ever run again
on that box, check `/etc/caddy/sites-enabled/qie-forge-demo-rpc.caddy` still
exists afterward.
