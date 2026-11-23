// Signed links to the marking pictures of a piece's pages, for the marking screen and the lead's page viewer. The
// logic is in handler.ts so it can be tested without a server.
import { callerClient, requireCaller, serviceClient } from "../_shared/auth.ts";
import { handle } from "../_shared/errors.ts";
import { makeHandler } from "./handler.ts";

Deno.serve(handle(makeHandler({ requireCaller, callerClient, serviceClient })));
