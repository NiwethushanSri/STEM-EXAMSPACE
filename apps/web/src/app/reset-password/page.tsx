"use client";

import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { Suspense, useEffect, useState, type FormEvent } from "react";
import { homeFor, messageFor } from "@stem/shared";
import { AuthLayout, inputClass, labelClass } from "@/components/AuthLayout";
import { createClient } from "@/lib/supabase/client";

const buttonClass =
  "w-full rounded-lg bg-blue-600 px-4 py-3 font-semibold text-white shadow-md transition hover:bg-blue-700 disabled:opacity-60";

function RequestForm() {
  const [sent, setSent] = useState(false);
  const [busy, setBusy] = useState(false);
  const [limited, setLimited] = useState(false);

  async function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const email = String(new FormData(e.currentTarget).get("email") ?? "").trim();
    setBusy(true);
    // The answer never depends on whether the address has an account.
    const { error } = await createClient().auth.resetPasswordForEmail(email, { redirectTo: `${window.location.origin}/auth/callback` });
    setBusy(false);
    if (error?.status === 429) setLimited(true);
    else setSent(true);
  }

  if (sent) {
    return (
      <div className="rounded-xl bg-green-50 p-5 text-sm text-green-900">
        <p className="font-semibold">Check your email</p>
        <p className="mt-1">If an account exists for that address, we have sent a link to reset the password.</p>
      </div>
    );
  }
  return (
    <form onSubmit={submit} className="space-y-5">
      <div>
        <label htmlFor="email" className={labelClass}>Email</label>
        <input id="email" name="email" type="email" required autoComplete="email" className={inputClass} />
      </div>
      {limited && <p role="alert" className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">{messageFor("rate_limited")}</p>}
      <button type="submit" disabled={busy} className={buttonClass}>
        {busy ? "Sending..." : "Send reset link"}
      </button>
    </form>
  );
}

/** Policy errors get a clear message; only genuine failures fall back to the generic one. */
function passwordErrorMessage(err: { code?: string; message?: string } | null): string {
  const code = err?.code ?? "";
  const text = (err?.message ?? "").toLowerCase();
  if (code === "weak_password" || /pwned|breach|leaked|too common|easy to guess/.test(text)) {
    return "Choose a stronger password — this one is too common or has appeared in a data breach.";
  }
  if (code === "same_password") return "Choose a password you have not used before.";
  if (/at least|too short|minimum/.test(text)) return "Use at least 8 characters.";
  if (/72|too long|at most|maximum/.test(text)) return "Use 72 characters or fewer.";
  if (code === "validation_failed" && /password/.test(text)) return "Choose a password of 8 to 72 characters.";
  return messageFor("internal");
}

function SetForm() {
  const router = useRouter();
  const [ready, setReady] = useState<"loading" | "yes" | "no">("loading");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    createClient()
      .auth.getUser()
      .then(({ data }) => setReady(data.user ? "yes" : "no"));
  }, []);

  async function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const form = new FormData(e.currentTarget);
    const password = String(form.get("password") ?? "");
    if (password.length < 8) {
      setError("Use at least 8 characters.");
      return;
    }
    if (password.length > 72) {
      setError("Use 72 characters or fewer.");
      return;
    }
    if (password !== String(form.get("confirm") ?? "")) {
      setError("The two passwords do not match.");
      return;
    }
    const supabase = createClient();
    setBusy(true);
    setError(null);
    const { data, error: err } = await supabase.auth.updateUser({ password });
    if (err || !data.user) {
      setBusy(false);
      setError(passwordErrorMessage(err));
      return;
    }
    // A new password ends every other session (an old password or a stolen session must not outlive it).
    await supabase.auth.signOut({ scope: "others" });
    const { data: profile } = await supabase.from("profiles").select("role, status").eq("id", data.user.id).maybeSingle();
    router.replace(profile ? homeFor(profile.role, profile.status, "web-staff") : "/login");
    router.refresh();
  }

  if (ready === "loading") return <p className="text-sm text-slate-500">Checking your link...</p>;
  if (ready === "no") {
    return (
      <div className="rounded-xl bg-amber-50 p-5 text-sm text-amber-900">
        <p className="font-semibold">This link is invalid or has expired</p>
        <p className="mt-1">
          <Link href="/reset-password" className="font-semibold underline">Request a new link</Link>
        </p>
      </div>
    );
  }
  return (
    <form onSubmit={submit} className="space-y-5">
      <div>
        <label htmlFor="password" className={labelClass}>New password</label>
        <input id="password" name="password" type="password" minLength={8} required autoComplete="new-password" placeholder="8 to 72 characters" className={inputClass} />
      </div>
      <div>
        <label htmlFor="confirm" className={labelClass}>Confirm new password</label>
        <input id="confirm" name="confirm" type="password" minLength={8} required autoComplete="new-password" className={inputClass} />
      </div>
      {error && <p role="alert" className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">{error}</p>}
      <button type="submit" disabled={busy} className={buttonClass}>
        {busy ? "Saving..." : "Set password"}
      </button>
    </form>
  );
}

function Content() {
  const setting = useSearchParams().get("mode") === "set";
  return (
    <AuthLayout
      title={setting ? "Set your password" : "Reset your password"}
      subtitle={setting ? "Choose a password to finish setting up your account." : "Enter your email and we will send you a reset link."}
      footer={<Link href="/login" className="font-semibold text-blue-700 hover:underline">Back to sign in</Link>}
    >
      {setting ? <SetForm /> : <RequestForm />}
    </AuthLayout>
  );
}

export default function ResetPasswordPage() {
  return (
    <Suspense>
      <Content />
    </Suspense>
  );
}
