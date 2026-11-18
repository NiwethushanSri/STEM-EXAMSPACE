import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // e2e:local builds into its own directory so local Supabase URLs never land in the normal .next.
  ...(process.env.NEXT_DIST_DIR ? { distDir: process.env.NEXT_DIST_DIR } : {}),
  /* config options here */
  cacheComponents: true,
  partialPrefetching: true,
  // Load pdf.js straight from node_modules so its worker file can be found.
  serverExternalPackages: ["pdfjs-dist"],
};

export default nextConfig;
