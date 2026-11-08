"use client";

import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { Suspense, useState, type FormEvent } from "react";
import { homeFor, indexLogin, messageFor } from "@stem/shared";
import { AuthLayout, inputClass, labelClass } from "@/components/AuthLayout";
import { createClient } from "@/lib/supabase/client";

function LoginForm() {
  const router = useRouter();
  const params = useSearchParams();
  const linkFailed = params.get("error") === "link";
  const deleted = params.get("notice") === "deleted";
  const [error, setError] = useState<string | null>(
    linkFailed ? "That link is invalid or has expired. Request a new one." : null,
  );
  const [unconfirmedEmail, setUnconfirmedEmail] = useState<string | null>(null);
  const [resent, setResent] = useState(false);
  const [busy, setBusy] = useState(false);

  async function handleSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const form = new FormData(e.currentTarget);
    const identifier = String(form.get("identifier") ?? "").trim();
    const password = String(form.get("password") ?? "");
    const supabase = createClient();
    setBusy(true);
    setError(null);
    setUnconfirmedEmail(null);
    setResent(false);

    const fail = (message: string) => {
      setError(message);
      setBusy(false);
    };

    if (identifier.includes("@")) {
      const { error: err } = await supabase.auth.signInWithPassword({ email: identifier, password });
      if (err) {
        if (err.code === "email_not_confirmed") {
          setUnconfirmedEmail(identifier);
          return fail("Confirm your email first");
        }
        if (err.status === 429 || err.code === "over_request_rate_limit") return fail(messageFor("rate_limited"));
        // A suspended (banned) account gets the same answer as a wrong password, so sign-in never reveals it.
        if (err.code === "user_banned" || /banned/i.test(err.message) || err.code === "invalid_credentials" || err.status === 400) {
          return fail("Email or password is incorrect.");
        }
        return fail(messageFor("internal"));
      }
    } else {
      const res = await indexLogin(supabase, identifier, password);
      if ("error" in res) {
        const { code } = res.error;
        if (code === "invalid_credentials") return fail("Index number or password is incorrect.");
        return fail(messageFor(code));
      }
      const { error: err } = await supabase.auth.setSession({
        access_token: res.data.access_token,
        refresh_token: res.data.refresh_token,
      });
      if (err) return fail(messageFor("internal"));
    }

    const { data: auth } = await supabase.auth.getUser();
    const { data: profile } = auth.user
      ? await supabase.from("profiles").select("role, status").eq("id", auth.user.id).maybeSingle()
      : { data: null };
    if (!profile) return fail(messageFor("internal"));
    router.replace(homeFor(profile.role, profile.status, "web-staff"));
    router.refresh();
  }

  async function resend() {
    if (!unconfirmedEmail) return;
    const { error: err } = await createClient().auth.resend({
      type: "signup",
      email: unconfirmedEmail,
      options: { emailRedirectTo: `${window.location.origin}/auth/callback` },
    });
    if (err?.status === 429) setError(messageFor("rate_limited"));
    else setResent(true);
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-5">
      {deleted && (
        <p role="status" className="rounded-lg bg-green-50 px-3 py-2 text-sm text-green-800">
          Your account and data have been deleted.
        </p>
      )}
      <div>
        <label htmlFor="identifier" className={labelClass}>Email or index number</label>
        <input
          id="identifier"
          name="identifier"
          type="text"
          required
          autoComplete="username"
          placeholder="you@example.com or SE-2026-0142"
          className={inputClass}
        />
      </div>

      <div>
        <div className="flex items-center justify-between">
          <label htmlFor="password" className={labelClass}>Password</label>
          <Link href="/reset-password" className="text-sm font-medium text-blue-700 hover:underline">Forgot password?</Link>
        </div>
        <input id="password" name="password" type="password" required autoComplete="current-password" placeholder="••••••••" className={inputClass} />
      </div>

      {error && (
        <div role="alert" className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">
          <p>{error}</p>
          {unconfirmedEmail && (
            <button type="button" onClick={resend} disabled={resent} className="mt-2 font-semibold underline disabled:opacity-60">
              {resent ? "Confirmation email sent" : "Resend confirmation email"}
            </button>
          )}
        </div>
      )}

      <button
        type="submit"
        disabled={busy}
        className="w-full rounded-lg bg-blue-600 px-4 py-3 font-semibold text-white shadow-md transition hover:bg-blue-700 disabled:opacity-60"
      >
        {busy ? "Signing in..." : "Sign in"}
      </button>
    </form>
  );
}

export default function LoginPage() {
  return (
    <AuthLayout
      title="Welcome back"
      subtitle="Sign in with your email, or your index number if you are a student."
      footer={
        <>
          New student?{" "}
          <Link href="/register" className="font-semibold text-blue-700 hover:underline">
            Create an account
          </Link>
        </>
      }
    >
      <Suspense>
        <LoginForm />
      </Suspense>
    </AuthLayout>
  );
}
