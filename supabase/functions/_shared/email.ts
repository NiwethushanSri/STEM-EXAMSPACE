export type EmailTemplate = "approved" | "rejected" | "invite" | "child_confirm" | "confirm_signup" | "paper_released" | "paper_corrected"
  | "script_receipt" | "script_attention" | "script_rejected" | "script_staff_alert" | "script_marking_alert";

/** Templates that carry a one-time sign-in link. */
const LINK_TEMPLATES: readonly EmailTemplate[] = ["invite", "child_confirm", "confirm_signup"];

const SUBJECTS: Record<EmailTemplate, string> = {
  approved: "Your Stem Examspace account is approved",
  rejected: "Your Stem Examspace registration",
  invite: "You are invited to Stem Examspace",
  child_confirm: "Set up your Stem Examspace account",
  confirm_signup: "Confirm your Stem Examspace registration",
  paper_released: "Your paper is ready to download",
  paper_corrected: "A corrected paper is available",
  script_receipt: "We have received your answers",
  script_attention: "Your answers need a little attention",
  script_rejected: "Your answers could not be accepted",
  script_staff_alert: "A script needs staff attention",
  script_marking_alert: "A script being marked needs attention",
};

/** One line, no markup characters that could break a header. */
function plain(s: string | undefined): string {
  return (s ?? "").replace(/[\r\n<>]+/g, " ").trim();
}

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

export interface Mail {
  subject: string;
  html: string;
}

/** What a staff alert says about each kind of exception (never a candidate's name). */
const ALERT_KINDS: Record<string, string> = {
  late: "Handed in late",
  processing_failed: "Processing failed",
  uncoded_family_page: "A page without a code in a family upload",
  not_expected: "A script that was not expected",
  other_exam: "A page from another exam",
  needs_attention: "A home script needs attention",
};

/** One sentence saying how many problems a staff alert is about (the database counts them per file and kind). */
export function staffAlertLine(kind: string, count: number): string {
  const n = Number.isInteger(count) && count > 0 ? count : 1;
  const one = n === 1;
  switch (kind) {
    case "not_expected":
      return one ? "1 page of one file was not expected for this exam." : `${n} pages of one file were not expected for this exam.`;
    case "other_exam":
      return one ? "1 page of one file belongs to another exam." : `${n} pages of one file belong to another exam.`;
    case "uncoded_family_page":
      return one ? "1 page without a code is in a family's hand-in." : `${n} pages without a code are in a family's hand-in.`;
    case "processing_failed":
      return "A file could not be processed.";
    case "late":
      return one ? "1 script was handed in late." : `${n} scripts were handed in late.`;
    case "needs_attention":
      return one ? "1 home script needs attention." : `${n} home scripts need attention.`;
    default:
      return "A script needs staff attention.";
  }
}

/** The one sentence of a marking alert, by its kind (migration 008). Never a candidate's or a marker's name. */
export function markingAlertLine(kind: string): string {
  switch (kind) {
    case "picture_changed":
      return "A page picture of this script changed during marking. The script is on hold until you release it.";
    case "picture_missing":
      return "A page of this script lost its marking picture during marking. The script is on hold until an admin takes it back.";
    case "name_visible":
      return "A marker reported a visible name. Staff must hide it and hand the script back.";
    case "pages_set_aside":
      return "Scanned pages arrived for a script that is being marked. They were set aside.";
    case "pages_changed":
      return "The pages of a script changed while it was with staff. Its marker has been asked to check their marks.";
    default:
      return "A script being marked needs attention.";
  }
}

/** To the subject's lead marker and the owner and admin accounts. The exam, the script number and the kind's sentence
 * only: no candidate name, no marker name. */
export function markingAlertEmail(data: Record<string, string>): Mail {
  const number = plain(data.script_number);
  return {
    subject: `${SUBJECTS.script_marking_alert}: ${plain(data.exam) || "exam"}`,
    html: `<p>${esc(markingAlertLine(data.kind ?? ""))}</p><ul><li>Exam: ${esc(plain(data.exam) || "unknown")}</li><li>Script: ${
      number ? esc(number) : "unknown"
    }</li></ul><p>Sign in to Stem Examspace to see the marking alerts.</p>`,
  };
}

/** "We have received your answers": to the student and linked parents when a home submission is received. */
export function scriptReceiptEmail(data: Record<string, string>): Mail {
  const row = (label: string, v: string | undefined) => (plain(v) ? `<li>${label}: ${esc(plain(v))}</li>` : "");
  return {
    subject: SUBJECTS.script_receipt,
    html: `<p>Hi ${esc(data.name ?? "there")},</p><h2>We have received your answers</h2><ul>${
      row("Exam", data.exam)
    }${row("Script number", data.script_number)}${row("Submission", data.seq)}${row("Received", data.time)}${
      row("Pages", data.page_count)
    }${
      row("Page list", data.pages)
    }</ul><p>Keep this email as your receipt. If anything is missing, sign in to Stem Examspace to see what to do.</p>`,
  };
}

/** Some pages need retaking or placing. */
export function scriptAttentionEmail(data: Record<string, string>): Mail {
  const exam = esc(plain(data.exam) || "your exam");
  const number = plain(data.script_number);
  return {
    subject: SUBJECTS.script_attention,
    html: `<p>Hi ${esc(data.name ?? "there")},</p><p>We checked the pages you handed in for ${exam}${
      number ? ` (script ${esc(number)})` : ""
    } and some need your attention, for example a page to retake or to put in place. Sign in to Stem Examspace and open your booking to see which.</p>`,
  };
}

/** The submission was not accepted. */
export function scriptRejectedEmail(data: Record<string, string>): Mail {
  const exam = esc(plain(data.exam) || "your exam");
  return {
    subject: SUBJECTS.script_rejected,
    html: `<p>Hi ${esc(data.name ?? "there")},</p><p>The pages you handed in for ${exam} could not be accepted. Sign in to Stem Examspace to see why, or contact us if you think this is a mistake.</p>`,
  };
}

/** To owner and admin accounts. Exam, kind and script number only: no candidate name. */
export function scriptStaffAlertEmail(data: Record<string, string>): Mail {
  const kind = esc(ALERT_KINDS[data.kind ?? ""] ?? "Needs attention");
  const count = Number.parseInt(data.count ?? "1", 10);
  // One email may be about many pages or scripts: a script number is only named when it is about one.
  const number = count > 1 ? "" : plain(data.script_number);
  return {
    subject: `${SUBJECTS.script_staff_alert}: ${plain(data.exam) || "exam"}`,
    html: `<p>${esc(staffAlertLine(data.kind ?? "", count))}</p><ul><li>Exam: ${esc(plain(data.exam) || "unknown")}</li><li>Kind: ${kind}</li>${
      count > 1 ? "" : `<li>Script: ${number ? esc(number) : "none yet"}</li>`
    }</ul><p>Sign in to Stem Examspace and open the exceptions list.</p>`,
  };
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
    case "confirm_signup": {
      const row = (label: string, v: string | undefined) => (v ? `<li>${label}: ${esc(v)}</li>` : "");
      const details = [
        row("Student name", data.student_name),
        row("Date of birth", data.date_of_birth),
        row("School", data.school),
        row("Parent email", data.parent_email),
      ].join("");
      html = `<p>Hi ${name},</p><p>Thanks for registering with Stem Examspace. Use this link to confirm your email and choose your password. If you did not register, ignore this email.</p>${
        details ? `<p>This registration was made with these details:</p><ul>${details}</ul><p>If these details are not yours or are wrong, ignore this email and contact the institution.</p>` : ""
      }${data.link ? `<p><a href="${esc(data.link)}">Confirm your email and choose your password</a></p>` : ""}${expiryNote(", or register again")}`;
      break;
    }
    case "paper_released": {
      const exam = esc(plain(data.exam) || "paper");
      html = `<p>Hi ${name},</p><p>Your ${exam} is ready to download. Sign in to Stem Examspace and open your booking to download your paper.</p>`;
      break;
    }
    case "paper_corrected": {
      const exam = esc(plain(data.exam) || "paper");
      html = `<p>Hi ${name},</p><p>The ${exam} has been corrected. Please download it again and use the new copy. Sign in to Stem Examspace and open your booking.</p>`;
      break;
    }
    case "script_receipt":
      return scriptReceiptEmail(data);
    case "script_attention":
      return scriptAttentionEmail(data);
    case "script_rejected":
      return scriptRejectedEmail(data);
    case "script_staff_alert":
      return scriptStaffAlertEmail(data);
    case "script_marking_alert":
      return markingAlertEmail(data);
  }
  const exam = plain(data.exam);
  let subject = SUBJECTS[template];
  if (exam && template === "paper_released") subject = `Your ${exam} is ready to download`;
  if (exam && template === "paper_corrected") subject = `A corrected ${exam} is available`;
  return { subject, html };
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
