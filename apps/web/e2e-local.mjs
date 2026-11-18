// Runs Playwright against the local Supabase stack (never the hosted project).
// Cross-platform stand-in for cross-env: sets E2E_ENV_FILE, builds the app once into .next-e2e with the
// local Supabase URL and anon key, then hands over to playwright (which serves it with next start).
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const envFile = "supabase/functions/.env.test.local";
process.env.E2E_ENV_FILE = envFile;

const vars = {};
for (const line of readFileSync(resolve(import.meta.dirname, "../..", envFile), "utf8").split(/\r?\n/)) {
  const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line);
  if (m) vars[m[1]] = m[2].replace(/^["']|["']$/g, "");
}
if (!vars.SUPABASE_URL || !vars.SUPABASE_ANON_KEY) throw new Error(envFile + " must define SUPABASE_URL and SUPABASE_ANON_KEY");
const host = new URL(vars.SUPABASE_URL).hostname;
if (host !== "127.0.0.1" && host !== "localhost") throw new Error(envFile + " must point at a local Supabase, not " + host);

const run = (args, env) => spawnSync("npx", args, { stdio: "inherit", shell: true, env: { ...process.env, ...env } }).status ?? 1;

const build = run(["next", "build", "--webpack"], {
  NEXT_DIST_DIR: ".next-e2e",
  NEXT_PUBLIC_SUPABASE_URL: vars.SUPABASE_URL,
  NEXT_PUBLIC_SUPABASE_ANON_KEY: vars.SUPABASE_ANON_KEY,
});
if (build !== 0) {
  console.error("e2e:local: next build failed; not running tests");
  process.exit(build);
}
process.exit(run(["playwright", "test", ...process.argv.slice(2)], {}));
