// Runs Playwright against the local Supabase stack (never the hosted project).
// Cross-platform stand-in for cross-env: sets E2E_ENV_FILE, builds the app once into .next-e2e with the
// local Supabase URL and anon key, starts the processing server (docker compose), then hands over to playwright
// (which serves the app with next start) and stops the processing server when it is done (if it started it).
import { spawn, spawnSync } from "node:child_process";
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
// local stack. Started after the build (memory is tight here) unless it is already running. One this script started
// is stopped and removed afterwards, also when the run is interrupted (Ctrl+C) or terminated; one that was already
// running is left as it was.
const compose = resolve(import.meta.dirname, "../../services/processor/docker-compose.yml");
const processor = (args, opts = {}) => spawnSync("docker", ["compose", "-f", compose, ...args], { stdio: "inherit", ...opts });
const ps = processor(["ps", "--status", "running", "-q", "processor"], { stdio: ["ignore", "pipe", "inherit"], encoding: "utf8" });
const wasRunning = ps.status === 0 && (ps.stdout ?? "").trim() !== "";
let stopped = false;
const stop = () => {
  if (wasRunning || stopped) return;
  stopped = true;
  processor(["down"]);
};
if (!wasRunning && processor(["up", "-d", "processor"]).status !== 0) {
  console.error("e2e:local: the processing server did not start; not running tests");
  stop();
  process.exit(1);
}

// Playwright runs as a child process (not spawnSync), so an interrupt or termination reaches this script: it passes it
// on to Playwright and, once Playwright has stopped, stops the processing server (a second signal stops at once).
let child = null;
for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(sig, () => {
    if (child && child.exitCode === null && child.signalCode === null) {
      child.kill(sig);
      return;
    }
    stop();
    process.exit(1);
  });
}
let status = 1;
try {
  status = await new Promise((done) => {
    child = spawn("npx", ["playwright", "test", ...process.argv.slice(2)], { stdio: "inherit", shell: true, env: process.env });
    child.on("error", () => done(1));
    child.on("exit", (code) => done(code ?? 1));
  });
} finally {
  stop();
}
process.exit(status);
