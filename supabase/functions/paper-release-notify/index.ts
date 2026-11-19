// Called every minute by pg_cron (through pg_net, with the x-cron-secret header). The logic is in handler.ts so
// it can be tested without a server.
import { serviceClient } from "../_shared/auth.ts";
import { sendEmail } from "../_shared/email.ts";
import { handle } from "../_shared/errors.ts";
import { makeHandler } from "./handler.ts";

Deno.serve(handle(makeHandler({
  env: (n) => Deno.env.get(n),
  svc: serviceClient,
  send: sendEmail,
  now: () => Date.now(),
  sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
})));
