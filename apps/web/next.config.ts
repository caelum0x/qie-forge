import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  /* config options here */
  // This app reads live on-chain state per-request (chain snapshots, oracle
  // prices); cacheComponents' build-time caching model fights that, so it's
  // off and pages opt into `export const dynamic = "force-dynamic"` instead.
  turbopack: {
    rules: {
      "*.css": {
        loaders: ["@tailwindcss/turbopack"],
        as: "*.css",
      },
    },
  },
};

export default nextConfig;
