import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { defineConfig, devices } from "@playwright/test";

// With E2E_ENV_FILE set (e2e:local), point the dev server at that file's Supabase instead of
// apps/web/.env.local. Process env wins over .env.local in Next.
function webServerEnv(): Record<string, string> {
  const name = process.env.E2E_ENV_FILE;
  if (!name) return {};
  const vars: Record<string, string> = {};
  for (const line of readFileSync(resolve(__dirname, "../..", name), "utf8").split(/\r?\n/)) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line);
    if (m) vars[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
  return {
    NEXT_PUBLIC_SUPABASE_URL: vars.SUPABASE_URL,
    NEXT_PUBLIC_SUPABASE_ANON_KEY: vars.SUPABASE_ANON_KEY,
  };
}

const PORT = 3005;

export default defineConfig({
  testDir: "./e2e",
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 90_000,
  expect: { timeout: 15_000 },
  reporter: "list",
  use: { baseURL: `http://localhost:${PORT}`, trace: "off" },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
  webServer: {
    command: `npx next dev --webpack -p ${PORT}`,
    url: `http://localhost:${PORT}/login`,
    env: webServerEnv(),
    reuseExistingServer: false,
    timeout: 180_000,
    stdout: "ignore",
    stderr: "pipe",
  },
});
