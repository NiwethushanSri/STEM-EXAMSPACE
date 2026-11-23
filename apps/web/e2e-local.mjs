// Runs Playwright against the local Supabase stack (never the hosted project).
// Cross-platform stand-in for cross-env: sets E2E_ENV_FILE, builds the app once into .next-e2e with the
// local Supabase URL and anon key, starts the processing server (docker compose) and the Edge Functions (supabase
// functions serve), then hands over to playwright (which serves the app with next start) and stops the processing
// server and the functions when it is done (each only if it started it).
import { spawn, spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { functionsServed, serveFunctions } from "./e2e-functions.mjs";

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
// The Edge Functions the specs call (marking-pictures; the paper functions), from the same env file. Started after
// the processing server unless they are served already; ones this script started are stopped, and their runtime
// container removed, whenever the processing server would be.
let stopFunctions = null;
let stopped = false;
const stop = () => {
  if (stopped) return;
  stopped = true;
  stopFunctions?.();
  if (!wasRunning) processor(["down"]);
};

// An interrupt (Ctrl+C) or a termination. The handlers are in place before the processing server is started, so one
// that arrives while it starts still stops it (the signal is handled as soon as "docker compose up" returns).
// Playwright runs as a child process (not spawnSync), so a signal during the tests reaches this script too:
//   the first one is passed on to Playwright and, once Playwright has stopped, the processing server is stopped;
//   a second one (or one while Playwright is not running) kills Playwright, stops the processing server and leaves
//   at once.
let child = null;
let passedOn = false;
const running = () => child !== null && child.exitCode === null && child.signalCode === null;
for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(sig, () => {
    if (running() && !passedOn) {
      passedOn = true;
      child.kill(sig);
      return;
    }
    if (running()) child.kill("SIGKILL");
    stop();
    process.exit(1);
  });
}

if (!wasRunning && processor(["up", "-d", "processor"]).status !== 0) {
  console.error("e2e:local: the processing server did not start; not running tests");
  stop();
  process.exit(1);
}

if (!(await functionsServed(vars.SUPABASE_URL))) {
  const functions = serveFunctions({ supabaseUrl: vars.SUPABASE_URL, envFile, cwd: resolve(import.meta.dirname, "../..") });
  stopFunctions = functions.stop;
  if (!(await functions.ready)) {
    console.error(`e2e:local: the Edge Functions did not start (npx supabase functions serve --env-file ${envFile}); not running tests`);
    stop();
    process.exit(1);
  }
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
