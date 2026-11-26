// The Edge Functions for the browser tests (marking-pictures, and the paper functions papers-admin.spec.ts calls),
// served from the local stack's env file by `supabase functions serve`. Used by e2e-local.mjs, which starts them only
// when they are not served already and then stops only what it started: the CLI and this project's
// supabase_edge_runtime_<project id> container (stopping the CLI leaves the container running). The project id is read
// from supabase/config.toml, as scripts/db-test.mjs reads it, so another local project's runtime is never touched.
import { spawn, spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";

/** The functions runtime container of the project in `cwd` (the repo root): supabase_edge_runtime_<project_id>. */
function runtimeContainer(cwd) {
  const line = readFileSync(join(cwd, "supabase", "config.toml"), "utf8").split(/\r?\n/).find((l) => l.startsWith("project_id"));
  const id = line?.split('"')[1];
  if (!id) throw new Error("supabase/config.toml has no project_id");
  return `supabase_edge_runtime_${id}`;
}

/** Whether the local functions answer. Not served, the gateway says 503 ("name resolution failed"); served,
 * marking-pictures refuses a call with no token (401). */
export async function functionsServed(supabaseUrl) {
  try {
    const r = await fetch(new URL("/functions/v1/marking-pictures", supabaseUrl), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
    });
    await r.arrayBuffer();
    return r.status < 500;
  } catch {
    return false;
  }
}

/**
 * Starts `npx supabase functions serve --env-file <envFile>` in `cwd` (the repo root). Returns at once with `stop` (the
 * CLI and the runtime container go; safe to call more than once, and from a signal handler) and `ready`, which is true
 * once the functions answer, or false when they did not within `timeoutMs` or the CLI ended first.
 */
export function serveFunctions({ supabaseUrl, envFile, cwd, timeoutMs = 180_000 }) {
  const container = runtimeContainer(cwd);
  // One command line (the shell finds npx on every platform); the env file is a fixed path in the repo.
  const cli = spawn(`npx supabase functions serve --env-file "${envFile}"`, {
    cwd,
    stdio: "ignore",
    shell: true,
    detached: process.platform !== "win32",
  });
  let stopped = false;
  const stop = () => {
    if (stopped) return;
    stopped = true;
    if (cli.exitCode === null && cli.signalCode === null) {
      if (process.platform === "win32") spawnSync("taskkill", ["/pid", String(cli.pid), "/T", "/F"], { stdio: "ignore" });
      else {
        try {
          process.kill(-cli.pid, "SIGTERM");
        } catch {
          // Already gone.
        }
      }
    }
    // By its exact name (docker's name filter matches any part of a name). When it is already gone, docker says so
    // and nothing else happens.
    spawnSync("docker", ["rm", "-f", container], { stdio: "ignore" });
  };
  const ready = (async () => {
    const until = Date.now() + timeoutMs;
    while (Date.now() < until && cli.exitCode === null && cli.signalCode === null) {
      if (await functionsServed(supabaseUrl)) return true;
      await new Promise((r) => setTimeout(r, 1000));
    }
    return false;
  })();
  return { stop, ready };
}
