import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { _renderForTest, sendEmail } from "./email.ts";

/** Runs fn with the given env (undefined deletes), restoring the previous values and silencing console output. */
async function withEnv(env: Record<string, string | undefined>, fn: () => Promise<void>) {
  const saved: Record<string, string | undefined> = {};
  for (const k of Object.keys(env)) saved[k] = Deno.env.get(k);
  const log = console.log, err = console.error;
  console.log = () => {};
  console.error = () => {};
  try {
    for (const [k, v] of Object.entries(env)) v === undefined ? Deno.env.delete(k) : Deno.env.set(k, v);
    await fn();
  } finally {
    console.log = log;
    console.error = err;
    for (const [k, v] of Object.entries(saved)) v === undefined ? Deno.env.delete(k) : Deno.env.set(k, v);
  }
}

const LOCAL = { EMAIL_PROVIDER: "console", SITE_URL: "http://localhost:3005" };

Deno.test("sendEmail: link templates without link or with a bad link -> false", async () => {
  await withEnv(LOCAL, async () => {
    for (const t of ["invite", "child_confirm", "confirm_signup"] as const) {
      assertEquals(await sendEmail("a@example.test", t, {}), false);
      assertEquals(await sendEmail("a@example.test", t, { link: "" }), false);
      assertEquals(await sendEmail("a@example.test", t, { link: "http://x.test/a" }), false);
      assertEquals(await sendEmail("a@example.test", t, { link: "javascript:alert(1)" }), false);
    }
  });
});

Deno.test("sendEmail: https link via console provider on a local site -> true", async () => {
  await withEnv(LOCAL, async () => {
    assertEquals(await sendEmail("a@example.test", "invite", { link: "https://x.test/a" }), true);
    assertEquals(await sendEmail("a@example.test", "confirm_signup", { link: "http://localhost:3005/a" }), true);
    assertEquals(await sendEmail("a@example.test", "approved", {}), true);
  });
});

Deno.test("sendEmail: missing EMAIL_PROVIDER fails closed", async () => {
  await withEnv({ EMAIL_PROVIDER: undefined, SITE_URL: "http://localhost:3005" }, async () => {
    assertEquals(await sendEmail("a@example.test", "approved", {}), false);
    assertEquals(await sendEmail("a@example.test", "invite", { link: "https://x.test/a" }), false);
  });
});

Deno.test("sendEmail: console provider refused unless SITE_URL is localhost or 127.0.0.1", async () => {
  for (const site of ["https://stem-examspace.example", "http://localhost.evil.test", "", undefined]) {
    await withEnv({ EMAIL_PROVIDER: "console", SITE_URL: site }, async () => {
      assertEquals(await sendEmail("a@example.test", "approved", {}), false, `site=${site}`);
    });
  }
  await withEnv({ EMAIL_PROVIDER: "console", SITE_URL: "http://127.0.0.1:3005" }, async () => {
    assertEquals(await sendEmail("a@example.test", "approved", {}), true);
  });
});

Deno.test("sendEmail: resend refuses non-https links and unknown providers fail", async () => {
  await withEnv(
    { EMAIL_PROVIDER: "resend", RESEND_API_KEY: "k", EMAIL_FROM: "x@example.test", SITE_URL: "http://localhost:3005" },
    async () => {
      const f = globalThis.fetch;
      let called = false;
      globalThis.fetch = (() => {
        called = true;
        return Promise.resolve(new Response("{}", { status: 200 }));
      }) as typeof fetch;
      try {
        assertEquals(await sendEmail("a@example.test", "invite", { link: "http://localhost:3005/a" }), false);
        assertEquals(called, false);
      } finally {
        globalThis.fetch = f;
      }
    },
  );
  await withEnv({ EMAIL_PROVIDER: "carrier-pigeon", SITE_URL: "http://localhost:3005" }, async () => {
    assertEquals(await sendEmail("a@example.test", "approved", {}), false);
  });
});

Deno.test("templates: auth link emails state the 1 hour validity and the reset page; names are escaped", async () => {
  await withEnv({ SITE_URL: "https://stem.example/" }, () => {
    for (const t of ["invite", "child_confirm", "confirm_signup"] as const) {
      const { html } = _renderForTest(t, { link: "https://stem.example/auth/callback?a=1&b=2", name: "<b>Bo</b>", parent_name: "<i>P</i>" });
      assertStringIncludes(html, "This link works for 1 hour");
      assertStringIncludes(html, "Forgot password at https://stem.example/reset-password with this email address");
      assertStringIncludes(html, "&lt;b&gt;Bo&lt;/b&gt;");
      assertStringIncludes(html, "a=1&amp;b=2");
      assert(!html.includes("<b>Bo"));
    }
    return Promise.resolve();
  });
});
