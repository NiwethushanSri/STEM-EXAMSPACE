import { assertEquals } from "jsr:@std/assert@1";
import { sendEmail } from "./email.ts";

Deno.test("sendEmail: invite without link or with non-https link -> false", async () => {
  const orig = console.error;
  console.error = () => {};
  try {
    assertEquals(await sendEmail("a@example.test", "invite", {}), false);
    assertEquals(await sendEmail("a@example.test", "invite", { link: "" }), false);
    assertEquals(await sendEmail("a@example.test", "invite", { link: "http://x.test/a" }), false);
    assertEquals(await sendEmail("a@example.test", "invite", { link: "javascript:alert(1)" }), false);
  } finally {
    console.error = orig;
  }
});

Deno.test("sendEmail: invite with https link via console provider -> true", async () => {
  const orig = console.log;
  console.log = () => {};
  try {
    assertEquals(await sendEmail("a@example.test", "invite", { link: "https://x.test/a" }), true);
  } finally {
    console.log = orig;
  }
});
