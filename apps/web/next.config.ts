import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  /* config options here */
  cacheComponents: true,
  partialPrefetching: true,
  // Load pdf.js straight from node_modules so its worker file can be found.
  serverExternalPackages: ["pdfjs-dist"],
};

export default nextConfig;
