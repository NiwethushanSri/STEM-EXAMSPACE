// Runs Playwright against the local Supabase stack (never the hosted project).
// Cross-platform stand-in for cross-env: sets E2E_ENV_FILE, builds the app once into .next-e2e with the
// local Supabase URL and anon key, starts the processing server (docker compose), then hands over to playwright
// (which serves the app with next start) and stops the processing server when it is done.
import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
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

// next build rewrites tsconfig.json (adds .next-e2e type globs, reformats); put it back afterwards.
const tsconfigPath = resolve(import.meta.dirname, "tsconfig.json");
const tsconfigBefore = readFileSync(tsconfigPath);
let build;
try {
  build = run(["next", "build", "--webpack"], {
    NEXT_DIST_DIR: ".next-e2e",
    NEXT_PUBLIC_SUPABASE_URL: vars.SUPABASE_URL,
    NEXT_PUBLIC_SUPABASE_ANON_KEY: vars.SUPABASE_ANON_KEY,
  });
} finally {
  writeFileSync(tsconfigPath, tsconfigBefore);
}
if (build !== 0) {
  console.error("e2e:local: next build failed; not running tests");
  process.exit(build);
}

// The processing server (services/processor, in Docker) reads the uploads the browser tests make, against the same
// local stack. Started after the build (memory is tight here), stopped and removed afterwards whatever happens.
const compose = resolve(import.meta.dirname, "../../services/processor/docker-compose.yml");
const processor = (args) => spawnSync("docker", ["compose", "-f", compose, ...args], { stdio: "inherit" }).status ?? 1;
if (processor(["up", "-d", "processor"]) !== 0) {
  console.error("e2e:local: the processing server did not start; not running tests");
  processor(["down"]);
  process.exit(1);
}
let status = 1;
try {
  status = run(["playwright", "test", ...process.argv.slice(2)], {});
} finally {
  processor(["down"]);
}
process.exit(status);
