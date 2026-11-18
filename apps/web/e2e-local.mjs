// Runs Playwright against the local Supabase stack (never the hosted project).
// Cross-platform stand-in for cross-env: sets E2E_ENV_FILE, then hands over to playwright.
import { spawnSync } from "node:child_process";

process.env.E2E_ENV_FILE = "supabase/functions/.env.test.local";
const r = spawnSync("npx", ["playwright", "test", ...process.argv.slice(2)], {
  stdio: "inherit",
  shell: true,
  env: process.env,
});
process.exit(r.status ?? 1);
