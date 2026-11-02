"use client";

import Link from "next/link";
import { useState, type FormEvent } from "react";
import { AuthLayout, inputClass, labelClass } from "@/components/AuthLayout";
import { subjects, entranceExams } from "@/lib/site-data";

const grades = ["Year 10", "Year 11", "Year 12", "Year 13", "University applicant"];

export default function RegisterPage() {
  const [submitted, setSubmitted] = useState(false);
  const [picked, setPicked] = useState<string[]>([]);

  function toggle(item: string) {
    setPicked((p) => (p.includes(item) ? p.filter((x) => x !== item) : [...p, item]));
  }

  function handleSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    // Mockup: nothing is saved yet. Admin approval happens in the admin portal later.
    setSubmitted(true);
  }

  if (submitted) {
    return (
      <AuthLayout
        title="Registration received"
        subtitle="Thanks for signing up to Stem Examspace."
        footer={<Link href="/login" className="font-semibold text-blue-700 hover:underline">Back to sign in</Link>}
      >
        <div className="rounded-xl bg-green-50 p-5 text-sm text-green-900">
          <p className="font-semibold">Awaiting approval</p>
          <p className="mt-1">
            An admin will check your details and approve your account. You will get an email with your
            index number once it is approved.
          </p>
        </div>
      </AuthLayout>
    );
  }

  return (
    <AuthLayout
      title="Create your account"
      subtitle="Register as a student. Your account is approved by an admin before you can sign in."
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
              <input id="first" required className={inputClass} />
            </div>
            <div>
              <label htmlFor="last" className={labelClass}>Last name</label>
              <input id="last" required className={inputClass} />
            </div>
          </div>
          <div className="grid gap-4 sm:grid-cols-2">
            <div>
              <label htmlFor="dob" className={labelClass}>Date of birth</label>
              <input id="dob" type="date" required className={inputClass} />
            </div>
            <div>
              <label htmlFor="gender" className={labelClass}>Gender</label>
              <select id="gender" className={inputClass} defaultValue="">
                <option value="" disabled>Select</option>
                <option>Female</option>
                <option>Male</option>
                <option>Prefer not to say</option>
              </select>
            </div>
          </div>
          <div className="grid gap-4 sm:grid-cols-2">
            <div>
              <label htmlFor="school" className={labelClass}>School</label>
              <input id="school" required className={inputClass} />
            </div>
            <div>
              <label htmlFor="grade" className={labelClass}>Year group</label>
              <select id="grade" className={inputClass} defaultValue="">
                <option value="" disabled>Select</option>
                {grades.map((g) => (
                  <option key={g}>{g}</option>
                ))}
              </select>
            </div>
          </div>
        </fieldset>

        <fieldset className="space-y-4">
          <legend className="mb-1 text-xs font-semibold uppercase tracking-wide text-blue-700">Parent or guardian</legend>
          <div className="grid gap-4 sm:grid-cols-2">
            <div>
              <label htmlFor="pname" className={labelClass}>Parent name</label>
              <input id="pname" required className={inputClass} />
            </div>
            <div>
              <label htmlFor="pphone" className={labelClass}>Parent phone</label>
              <input id="pphone" type="tel" required className={inputClass} />
            </div>
          </div>
          <div>
            <label htmlFor="pemail" className={labelClass}>Parent email</label>
            <input id="pemail" type="email" required className={inputClass} />
          </div>
        </fieldset>

        <fieldset className="space-y-4">
          <legend className="mb-1 text-xs font-semibold uppercase tracking-wide text-blue-700">Sign-in details</legend>
          <div>
            <label htmlFor="email" className={labelClass}>Your email</label>
            <input id="email" type="email" required className={inputClass} />
          </div>
          <div>
            <label htmlFor="password" className={labelClass}>Password</label>
            <input id="password" type="password" minLength={8} required placeholder="At least 8 characters" className={inputClass} />
          </div>
        </fieldset>

        <fieldset>
          <legend className="mb-2 text-xs font-semibold uppercase tracking-wide text-blue-700">Subjects you plan to sit</legend>
          <div className="flex flex-wrap gap-2">
            {[...subjects, ...entranceExams].map((s) => {
              const on = picked.includes(s);
              return (
                <button
                  key={s}
                  type="button"
                  onClick={() => toggle(s)}
                  aria-pressed={on}
                  className={`rounded-full px-3 py-1.5 text-sm transition ${
                    on ? "bg-blue-600 text-white" : "border border-slate-300 text-slate-700 hover:border-blue-400"
                  }`}
                >
                  {s}
                </button>
              );
            })}
          </div>
        </fieldset>

        <label className="flex items-start gap-2 text-sm text-slate-600">
          <input type="checkbox" required className="mt-1 h-4 w-4 rounded border-slate-300 text-blue-600" />
          <span>I agree to the terms and confirm that the parent details above are correct.</span>
        </label>

        <button type="submit" className="w-full rounded-lg bg-blue-600 px-4 py-3 font-semibold text-white shadow-md transition hover:bg-blue-700">
          Create account
        </button>
      </form>
    </AuthLayout>
  );
}
