// The Edge Functions for the browser tests (marking-pictures, and the paper functions papers-admin.spec.ts calls),
// served from the local stack's env file by `supabase functions serve`. Used by e2e-local.mjs, which starts them only
// when they are not served already and then stops only what it started: the CLI and its supabase_edge_runtime_*
// container (stopping the CLI leaves the container running).
import { spawn, spawnSync } from "node:child_process";

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
    const ids = (spawnSync("docker", ["ps", "-aq", "--filter", "name=supabase_edge_runtime_"], { encoding: "utf8" }).stdout ?? "")
      .split(/\s+/)
      .filter(Boolean);
    if (ids.length) spawnSync("docker", ["rm", "-f", ...ids], { stdio: "ignore" });
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
