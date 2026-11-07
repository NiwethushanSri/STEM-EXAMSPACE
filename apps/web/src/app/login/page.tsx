"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState, type FormEvent } from "react";
import { AuthLayout, inputClass, labelClass } from "@/components/AuthLayout";

const roles = [
  { key: "student", label: "Student", home: "/student", idLabel: "Email or index number", placeholder: "you@example.com or SE-2026-0142" },
  { key: "parent", label: "Parent", home: "/parent", idLabel: "Email address", placeholder: "you@example.com" },
  { key: "examiner", label: "Examiner", home: "/examiner", idLabel: "Examiner email", placeholder: "examiner@stemexamspace.co.uk" },
  { key: "admin", label: "Admin", home: "/admin", idLabel: "Admin email", placeholder: "admin@stemexamspace.co.uk" },
] as const;

export default function LoginPage() {
  const router = useRouter();
  const [roleKey, setRoleKey] = useState<(typeof roles)[number]["key"]>("student");
  const [remember, setRemember] = useState(true);
  const role = roles.find((r) => r.key === roleKey)!;

  function handleSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    // Mockup: no real sign-in yet, so go straight to the chosen role's dashboard.
    router.push(role.home);
  }

  return (
    <AuthLayout
      title="Welcome back"
      subtitle="Sign in to see your results, timetable and notices."
      footer={
        <>
          New student?{" "}
          <Link href="/register" className="font-semibold text-blue-700 hover:underline">
            Create an account
          </Link>
        </>
      }
    >
      <div role="tablist" aria-label="Sign in as" className="grid grid-cols-4 gap-1 rounded-lg bg-slate-100 p-1">
        {roles.map((r) => (
          <button
            key={r.key}
            type="button"
            role="tab"
            aria-selected={r.key === roleKey}
            onClick={() => setRoleKey(r.key)}
            className={`rounded-md px-2 py-2 text-sm font-medium transition ${
              r.key === roleKey ? "bg-white text-blue-700 shadow-sm" : "text-slate-600 hover:text-slate-900"
            }`}
          >
            {r.label}
          </button>
        ))}
      </div>

      <form onSubmit={handleSubmit} className="mt-6 space-y-5">
        <div>
          <label htmlFor="id" className={labelClass}>{role.idLabel}</label>
          <input id="id" type="text" required placeholder={role.placeholder} className={inputClass} />
        </div>

        <div>
          <div className="flex items-center justify-between">
            <label htmlFor="password" className={labelClass}>Password</label>
            <a href="#" className="text-sm font-medium text-blue-700 hover:underline">Forgot password?</a>
          </div>
          <input id="password" type="password" required placeholder="••••••••" className={inputClass} />
        </div>

        <label className="flex items-center gap-2 text-sm text-slate-600">
          <input
            type="checkbox"
            checked={remember}
            onChange={(e) => setRemember(e.target.checked)}
            className="h-4 w-4 rounded border-slate-300 text-blue-600"
          />
          Keep me signed in on this device
        </label>

        <button type="submit" className="w-full rounded-lg bg-blue-600 px-4 py-3 font-semibold text-white shadow-md transition hover:bg-blue-700">
          Sign in as {role.label.toLowerCase()}
        </button>
      </form>

      <p className="mt-6 text-center text-xs text-slate-500">
        Mockup: sign-in does not check passwords yet.
      </p>
    </AuthLayout>
  );
}
