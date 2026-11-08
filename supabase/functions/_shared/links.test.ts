import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { buildAuthLink } from "./links.ts";

Deno.test("buildAuthLink: builds the callback URL from SITE_URL and encodes the token", () => {
  Deno.env.set("SITE_URL", "http://localhost:3005/");
  assertEquals(buildAuthLink("abc/+=", "recovery"), "http://localhost:3005/auth/callback?token_hash=abc%2F%2B%3D&type=recovery");
  assertEquals(buildAuthLink("t", "signup"), "http://localhost:3005/auth/callback?token_hash=t&type=signup");
  assertEquals(buildAuthLink("t", "invite"), "http://localhost:3005/auth/callback?token_hash=t&type=invite");
});

Deno.test("buildAuthLink: throws a clear error when SITE_URL is missing", () => {
  Deno.env.delete("SITE_URL");
  assertThrows(() => buildAuthLink("t", "recovery"), Error, "SITE_URL");
});
