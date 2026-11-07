export type EmailTemplate = "approved" | "rejected" | "invite";

const SUBJECTS: Record<EmailTemplate, string> = {
  approved: "Your Stem Examspace account is approved",
  rejected: "Your Stem Examspace registration",
  invite: "You are invited to Stem Examspace",
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
      }.</p>${data.link ? `<p><a href="${esc(data.link)}">Accept your invitation</a></p>` : ""}`;
      break;
  }
  return { subject: SUBJECTS[template], html };
}

/** Returns false on any failure; never throws. */
export async function sendEmail(
  to: string,
  template: EmailTemplate,
  data: Record<string, string>,
): Promise<boolean> {
  try {
    if (template === "invite") {
      let ok = false;
      try {
        ok = new URL(data.link ?? "").protocol === "https:";
      } catch { /* invalid URL */ }
      if (!ok) {
        console.error(`[email] rejected missing or non-https link template=${template}`);
        return false;
      }
    }
    const provider = Deno.env.get("EMAIL_PROVIDER") ?? "console";
    if (provider === "console") {
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
