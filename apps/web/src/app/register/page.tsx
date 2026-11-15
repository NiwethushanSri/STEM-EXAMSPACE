"use client";

import Image from "next/image";
import Link from "next/link";
import { useRef, useState, type FormEvent, type ReactNode } from "react";
import { messageFor, registerStudent } from "@stem/shared";
import { jakarta } from "@/components/home/fonts";
import { checkRegistration, type FieldErrors, type RegisterFields } from "@/lib/register-form";
import { createClient } from "@/lib/supabase/client";
import s from "./register.module.css";

function Tick() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="2.8" strokeLinecap="round" strokeLinejoin="round">
      <path d="M5 12.5l4.5 4.5L19 7.5" />
    </svg>
  );
}

const NEXT = [
  { title: "Confirm the student’s email", body: "We email the student a link to confirm the address and choose a password." },
  { title: "We check the details", body: "An administrator reviews every new registration before the account is opened." },
  { title: "Index number issued", body: "Once approved, the student receives their index number by email, ready for exam day." },
  { title: "Parent account", body: "The parent or guardian is invited to their own account, linked to the student." },
];

const NEEDS = [
  "The student’s full name, date of birth and school",
  "An email address the student uses",
  "The parent or guardian’s own email address and phone number",
];

type FieldProps = {
  id: keyof RegisterFields;
  label: string;
  hint?: string;
  type?: string;
  autoComplete?: string;
  maxLength?: number;
  error?: string;
};

function Field({ id, label, hint, type = "text", autoComplete, maxLength, error }: FieldProps) {
  const described = [hint ? `${id}-hint` : "", error ? `${id}-error` : ""].filter(Boolean).join(" ") || undefined;
  return (
    <div className={s.field}>
      <label htmlFor={id} className={s.label}>
        {label}
      </label>
      {hint ? (
        <span id={`${id}-hint`} className={s.hint}>
          {hint}
        </span>
      ) : null}
      <input
        id={id}
        name={id}
        type={type}
        autoComplete={autoComplete}
        maxLength={maxLength}
        aria-invalid={error ? true : undefined}
        aria-describedby={described}
        className={s.input}
      />
      {error ? (
        <span id={`${id}-error`} className={s.error}>
          {error}
        </span>
      ) : null}
    </div>
  );
}

function Shell({ children }: { children: ReactNode }) {
  return (
    <div className={`${s.page} ${jakarta.variable}`}>
      <header className={s.top}>
        <div className={s.topInner}>
          <Link href="/">
            <Image src="/images/stem-examspace-logo.png" alt="Stem Examspace home" width={1062} height={369} priority />
          </Link>
          <span className={s.signIn}>
            Already registered? <Link href="/login">Sign in</Link>
          </span>
        </div>
      </header>
      <main className={s.wrap}>{children}</main>
    </div>
  );
}

export default function RegisterPage() {
  const [sentTo, setSentTo] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [errors, setErrors] = useState<FieldErrors>({});
  const [serverError, setServerError] = useState<string | null>(null);
  const [consentError, setConsentError] = useState(false);
  const summaryRef = useRef<HTMLDivElement>(null);

  async function handleSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const form = new FormData(e.currentTarget);
    const get = (k: keyof RegisterFields) => String(form.get(k) ?? "").trim();
    const fields: RegisterFields = {
      first: get("first"),
      last: get("last"),
      dob: get("dob"),
      school: get("school"),
      email: get("email"),
      pname: get("pname"),
      pemail: get("pemail"),
      pphone: get("pphone"),
    };
    const found = checkRegistration(fields, new Date());
    const agreed = form.get("consent") === "on";
    setErrors(found);
    setConsentError(!agreed);
    setServerError(null);
    const firstBad = Object.keys(found)[0] ?? (agreed ? undefined : "consent");
    if (firstBad) {
      document.getElementById(firstBad)?.focus();
      return;
    }
    setBusy(true);
    // The server creates the account and sends the confirmation link; a new, replaced or already
    // registered address all get the same answer, so the form never reveals which emails exist.
    const res = await registerStudent(createClient(), {
      firstName: fields.first,
      lastName: fields.last,
      email: fields.email,
      dateOfBirth: fields.dob,
      school: fields.school,
      parentName: fields.pname,
      parentEmail: fields.pemail,
      parentPhone: fields.pphone,
    });
    setBusy(false);
    if ("data" in res) {
      setSentTo(fields.email);
      window.scrollTo({ top: 0 });
      return;
    }
    setServerError(res.error.code === "invalid_input" ? res.error.message : messageFor(res.error.code));
    requestAnimationFrame(() => summaryRef.current?.focus());
  }

  if (sentTo) {
    return (
      <Shell>
        <div className={`${s.card} ${s.done}`}>
          <div className={s.doneHead}>
            <span className={s.doneTick}>
              <Tick />
            </span>
            <h1>Registration received</h1>
          </div>
          <p className={s.doneLead} role="status">
            Check your email to confirm your address and choose your password.
            <span>We have sent a link to {sentTo}. It may take a few minutes; check the spam folder if it does not arrive.</span>
          </p>
          <ol className={s.steps}>
            {NEXT.slice(1).map((n, i) => (
              <li key={n.title}>
                <span className={s.tick} aria-hidden="true">
                  {i + 2}
                </span>
                <div>
                  <strong>{n.title}</strong>
                  <span>{n.body}</span>
                </div>
              </li>
            ))}
          </ol>
          <div className={s.doneActions}>
            <Link href="/" className={s.btn}>
              Back to the home page
            </Link>
            <Link href="/login" className={s.btnGhost}>
              Sign in
            </Link>
          </div>
        </div>
      </Shell>
    );
  }

  const count = Object.keys(errors).length + (consentError ? 1 : 0);

  return (
    <Shell>
      <div className={s.intro}>
        <h1>Register a student</h1>
        <p>
          One form for the student and their parent or guardian. It takes about two minutes. Once approved, the parent or guardian receives
          their own account, linked to the student.
        </p>
      </div>

      <div className={s.grid}>
        <form className={s.card} onSubmit={handleSubmit} noValidate aria-describedby="privacy-note">
          <fieldset className={s.fieldset}>
            <legend className={s.legend}>
              <span className={s.stepNo} aria-hidden="true">
                1
              </span>
              Student
            </legend>
            <p className={s.legendNote}>As they should appear on exam registers and results.</p>
            <div className={s.row}>
              <Field id="first" label="First name" autoComplete="given-name" maxLength={80} error={errors.first} />
              <Field id="last" label="Last name" autoComplete="family-name" maxLength={80} error={errors.last} />
            </div>
            <div className={s.row}>
              <Field id="dob" label="Date of birth" type="date" hint="Students aged 8 to 25." error={errors.dob} />
              <Field id="school" label="School" hint="The school the student attends now." maxLength={120} error={errors.school} />
            </div>
            <Field
              id="email"
              label="Student email"
              type="email"
              autoComplete="email"
              hint="The student signs in with this address. We send the confirmation link here."
              error={errors.email}
            />
          </fieldset>

          <fieldset className={s.fieldset}>
            <legend className={s.legend}>
              <span className={s.stepNo} aria-hidden="true">
                2
              </span>
              Parent or guardian
            </legend>
            <p className={s.legendNote}>They receive their own account once the registration is approved.</p>
            <Field id="pname" label="Parent name" hint="Parent or guardian’s full name." maxLength={120} error={errors.pname} />
            <div className={s.row}>
              <Field
                id="pemail"
                label="Parent email"
                type="email"
                hint="Different from the student’s email."
                error={errors.pemail}
              />
              <Field
                id="pphone"
                label="Parent phone"
                type="tel"
                autoComplete="tel"
                hint="A mobile number is best."
                maxLength={30}
                error={errors.pphone}
              />
            </div>
          </fieldset>

          <fieldset className={s.fieldset}>
            <legend className={s.legend}>
              <span className={s.stepNo} aria-hidden="true">
                3
              </span>
              Confirm
            </legend>
            <label className={s.consent}>
              <input
                id="consent"
                name="consent"
                type="checkbox"
                aria-invalid={consentError ? true : undefined}
                aria-describedby={consentError ? "consent-error" : undefined}
              />
              <span>I confirm these details are correct, and that the parent or guardian named above agrees to this registration.</span>
            </label>
            {consentError ? (
              <span id="consent-error" className={s.error}>
                Tick the box to confirm the details.
              </span>
            ) : null}
          </fieldset>

          {count > 0 || serverError ? (
            <div className={s.summary} role="alert" tabIndex={-1} ref={summaryRef}>
              {serverError ? (
                serverError
              ) : (
                <>
                  <strong>
                    {count === 1 ? "One detail needs" : `${count} details need`} attention.
                  </strong>
                  Check the highlighted {count === 1 ? "field" : "fields"} above.
                </>
              )}
            </div>
          ) : null}

          <button type="submit" disabled={busy} className={s.submit}>
            {busy ? "Creating account…" : "Create account"}
          </button>
          <p className={s.fine}>No password needed now: the student chooses one from the email link.</p>
        </form>

        <aside className={s.side}>
          <div className={s.panel}>
            <h2>What happens next</h2>
            <ol className={s.steps}>
              {NEXT.map((n, i) => (
                <li key={n.title}>
                  <span className={s.tick} aria-hidden="true">
                    {i + 1}
                  </span>
                  <div>
                    <strong>{n.title}</strong>
                    <span>{n.body}</span>
                  </div>
                </li>
              ))}
            </ol>
          </div>
          <div className={s.panel}>
            <h2>You will need</h2>
            <ul className={s.needs}>
              {NEEDS.map((n) => (
                <li key={n}>
                  <span className={s.tick}>
                    <Tick />
                  </span>
                  {n}
                </li>
              ))}
            </ul>
          </div>
          <p id="privacy-note" className={s.privacy}>
            We use these details only to run exams and to share bookings and results with the student and their parent or guardian.
          </p>
        </aside>
      </div>
    </Shell>
  );
}
