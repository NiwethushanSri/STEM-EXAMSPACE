export type EmailTemplate = "approved" | "rejected" | "invite" | "child_confirm" | "confirm_signup";

/** Templates that carry a one-time sign-in link. */
const LINK_TEMPLATES: readonly EmailTemplate[] = ["invite", "child_confirm", "confirm_signup"];

const SUBJECTS: Record<EmailTemplate, string> = {
  approved: "Your Stem Examspace account is approved",
  rejected: "Your Stem Examspace registration",
  invite: "You are invited to Stem Examspace",
  child_confirm: "Set up your Stem Examspace account",
  confirm_signup: "Confirm your Stem Examspace registration",
};

const ESCAPES: Record<string, string> = {
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#39;",
};

function esc(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ESCAPES[c]);
}

/** Every emailed auth link says how long it lasts and what to do afterwards. */
function expiryNote(extra = ""): string {
  const site = (Deno.env.get("SITE_URL") ?? "").replace(/\/+$/, "");
  const where = site ? `${site}/reset-password` : "the sign-in page";
  return `<p>This link works for 1 hour. After that, use Forgot password at ${esc(where)} with this email address${extra}.</p>`;
}

function render(template: EmailTemplate, data: Record<string, string>): { subject: string; html: string } {
  const name = esc(data.name ?? "there");
  let html: string;
  switch (template) {
    case "approved":
      html = `<p>Hi ${name},</p><p>Your registration has been approved.${
        data.index_number ? ` Your index number is <strong>${esc(data.index_number)}</strong>.` : ""
      } Sign in to complete your profile.</p>`;
      break;
    case "rejected":
      html = `<p>Hi ${name},</p><p>We could not approve your registration. Contact us if you think this is a mistake.</p>`;
      break;
    case "invite":
      html = `<p>Hi ${name},</p><p>You have been invited to Stem Examspace${
        data.role ? ` as ${esc(data.role)}` : ""
      }.</p>${data.link ? `<p><a href="${esc(data.link)}">Accept your invitation</a></p>` : ""}${expiryNote()}`;
      break;
    case "child_confirm":
      html = `<p>Hi ${name},</p><p>${esc(data.parent_name ?? "A parent")} registered you for Stem Examspace. Use this link to confirm your email and choose your password. If you did not expect this, ignore this email.</p>${
        data.link ? `<p><a href="${esc(data.link)}">Set up your account</a></p>` : ""
      }${expiryNote()}`;
      break;
    case "confirm_signup":
      html = `<p>Hi ${name},</p><p>Thanks for registering with Stem Examspace. Use this link to confirm your email and choose your password. If you did not register, ignore this email.</p>${
        data.link ? `<p><a href="${esc(data.link)}">Confirm your email and choose your password</a></p>` : ""
      }${expiryNote(", or register again")}`;
      break;
  }
  return { subject: SUBJECTS[template], html };
}

/** Plain-text console output is only for a local development site. */
function localSite(): boolean {
  try {
    const h = new URL(Deno.env.get("SITE_URL") ?? "").hostname;
    return h === "localhost" || h === "127.0.0.1";
  } catch {
    return false;
  }
}

/**
 * Returns false on any failure; never throws. Fails closed: with no EMAIL_PROVIDER nothing is "sent",
 * and the console provider (which sends nothing) is accepted only while SITE_URL is a local site.
 */
export async function sendEmail(
  to: string,
  template: EmailTemplate,
  data: Record<string, string>,
): Promise<boolean> {
  try {
    const provider = Deno.env.get("EMAIL_PROVIDER");
    if (!provider) {
      console.error("[email] missing setting: EMAIL_PROVIDER");
      return false;
    }

    if (LINK_TEMPLATES.includes(template)) {
      let ok = false;
      try {
        const u = new URL(data.link ?? "");
        // https everywhere; plain http only for a local dev site (SITE_URL=http://localhost:...), never with resend.
        ok = u.protocol === "https:" ||
          (provider !== "resend" && u.protocol === "http:" && (u.hostname === "localhost" || u.hostname === "127.0.0.1"));
      } catch { /* invalid URL */ }
      if (!ok) {
        console.error(`[email] rejected missing or non-https link template=${template}`);
        return false;
      }
    }

    if (provider === "console") {
      if (!localSite()) {
        console.error("[email] the console provider is only allowed while SITE_URL is localhost or 127.0.0.1");
        return false;
      }
      // Log only the template and recipient domain: no address, no data (may hold links).
      console.log(`[email:console] template=${template} to=@${to.split("@")[1] ?? "unknown"}`);
      return true;
    }
    if (provider === "resend") {
      const key = Deno.env.get("RESEND_API_KEY");
      const from = Deno.env.get("EMAIL_FROM");
      if (!key || !from) {
        console.error(`[email:resend] missing setting: ${!key ? "RESEND_API_KEY" : "EMAIL_FROM"}`);
        return false;
      }
      const { subject, html } = render(template, data);
      const res = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
        body: JSON.stringify({ from, to: [to], subject, html }),
        signal: AbortSignal.timeout(8000),
      });
      if (!res.ok) console.error(`[email:resend] template=${template} status=${res.status}`);
      await res.body?.cancel();
      return res.ok;
    }
    console.error("[email] unknown EMAIL_PROVIDER");
    return false;
  } catch {
    console.error(`[email] send failed template=${template}`);
    return false;
  }
}

/** Test seam: the HTML a template renders (no sending). */
export const _renderForTest = render;
