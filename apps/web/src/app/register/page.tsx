"use client";

import Link from "next/link";
import { useState, type FormEvent } from "react";
import { messageFor, registerStudent } from "@stem/shared";
import { AuthLayout, inputClass, labelClass } from "@/components/AuthLayout";
import { createClient } from "@/lib/supabase/client";

export default function RegisterPage() {
  const [done, setDone] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const form = new FormData(e.currentTarget);
    const get = (k: string) => String(form.get(k) ?? "").trim();
    setBusy(true);
    setError(null);
    // The server creates the account and sends the confirmation link; a new, replaced or already
    // registered address all get the same answer, so the form never reveals which emails exist.
    const res = await registerStudent(createClient(), {
      firstName: get("first"),
      lastName: get("last"),
      email: get("email"),
      password: String(form.get("password") ?? ""),
      dateOfBirth: get("dob"),
      school: get("school"),
      parentName: get("pname"),
      parentEmail: get("pemail"),
    });
    setBusy(false);
    if ("data" in res) {
      setDone(true);
      return;
    }
    setError(res.error.code === "invalid_input" ? res.error.message : messageFor(res.error.code));
  }

  if (done) {
    return (
      <AuthLayout
        title="Registration received"
        subtitle="Thanks for signing up to Stem Examspace."
        footer={<Link href="/login" className="font-semibold text-blue-700 hover:underline">Back to sign in</Link>}
      >
        <div className="rounded-xl bg-green-50 p-5 text-sm text-green-900">
          <p className="font-semibold">Check your email to confirm your address</p>
          <p className="mt-1">
            Open the link we sent you. After that an admin will check your details and approve your
            account, and you will get an email with your index number.
          </p>
        </div>
      </AuthLayout>
    );
  }

  return (
    <AuthLayout
      title="Create your account"
      subtitle="Register as a student. Your account is approved by an admin before you can use it."
      footer={
        <>
          Already registered?{" "}
          <Link href="/login" className="font-semibold text-blue-700 hover:underline">
            Sign in
          </Link>
        </>
      }
    >
      <form onSubmit={handleSubmit} className="space-y-6">
        <fieldset className="space-y-4">
          <legend className="mb-1 text-xs font-semibold uppercase tracking-wide text-blue-700">Student details</legend>
          <div className="grid gap-4 sm:grid-cols-2">
            <div>
              <label htmlFor="first" className={labelClass}>First name</label>
              <input id="first" name="first" required className={inputClass} />
            </div>
            <div>
              <label htmlFor="last" className={labelClass}>Last name</label>
              <input id="last" name="last" required className={inputClass} />
            </div>
          </div>
          <div className="grid gap-4 sm:grid-cols-2">
            <div>
              <label htmlFor="dob" className={labelClass}>Date of birth</label>
              <input id="dob" name="dob" type="date" required className={inputClass} />
            </div>
            <div>
              <label htmlFor="school" className={labelClass}>School</label>
              <input id="school" name="school" required className={inputClass} />
            </div>
          </div>
        </fieldset>

        <fieldset className="space-y-4">
          <legend className="mb-1 text-xs font-semibold uppercase tracking-wide text-blue-700">Parent or guardian</legend>
          <div className="grid gap-4 sm:grid-cols-2">
            <div>
              <label htmlFor="pname" className={labelClass}>Parent name</label>
              <input id="pname" name="pname" required className={inputClass} />
            </div>
            <div>
              <label htmlFor="pemail" className={labelClass}>Parent email</label>
              <input id="pemail" name="pemail" type="email" required className={inputClass} />
            </div>
          </div>
        </fieldset>

        <fieldset className="space-y-4">
          <legend className="mb-1 text-xs font-semibold uppercase tracking-wide text-blue-700">Sign-in details</legend>
          <div>
            <label htmlFor="email" className={labelClass}>Your email</label>
            <input id="email" name="email" type="email" required autoComplete="email" className={inputClass} />
          </div>
          <div>
            <label htmlFor="password" className={labelClass}>Password</label>
            <input
              id="password"
              name="password"
              type="password"
              minLength={8}
              required
              autoComplete="new-password"
              placeholder="At least 8 characters"
              className={inputClass}
            />
          </div>
        </fieldset>

        <label className="flex items-start gap-2 text-sm text-slate-600">
          <input type="checkbox" required className="mt-1 h-4 w-4 rounded border-slate-300 text-blue-600" />
          <span>I agree to the terms and confirm that the parent details above are correct.</span>
        </label>

        {error && <p role="alert" className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">{error}</p>}

        <button
          type="submit"
          disabled={busy}
          className="w-full rounded-lg bg-blue-600 px-4 py-3 font-semibold text-white shadow-md transition hover:bg-blue-700 disabled:opacity-60"
        >
          {busy ? "Creating account..." : "Create account"}
        </button>
      </form>
    </AuthLayout>
  );
}
