"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";
import { deleteMyAccount, messageFor } from "@stem/shared";
import { createClient } from "@/lib/supabase/client";
import { ConfirmDialog } from "@/components/accounts/ConfirmDialog";

export function SignOutButton() {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  return (
    <button
      type="button"
      disabled={busy}
      onClick={async () => {
        setBusy(true);
        await createClient().auth.signOut();
        router.replace("/login");
        router.refresh();
      }}
      className="font-semibold text-blue-700 hover:underline disabled:opacity-60"
    >
      Sign out
    </button>
  );
}

export function ResendConfirmationButton() {
  const [state, setState] = useState<"idle" | "busy" | "sent" | "limited">("idle");
  return (
    <>
      <button
        type="button"
        disabled={state === "busy" || state === "sent"}
        onClick={async () => {
          setState("busy");
          const supabase = createClient();
          const { data } = await supabase.auth.getUser();
          if (data.user?.email) {
            const { error } = await supabase.auth.resend({
              type: "signup",
              email: data.user.email,
              options: { emailRedirectTo: `${window.location.origin}/auth/callback` },
            });
            if (error?.status === 429) {
              setState("limited");
              return;
            }
          }
          setState("sent");
        }}
        className="mt-3 rounded-lg bg-blue-600 px-4 py-2 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-60"
      >
        {state === "sent" ? "Confirmation email sent" : "Resend confirmation email"}
      </button>
      {state === "limited" && <p role="alert" className="mt-2 text-sm text-red-700">{messageFor("rate_limited")}</p>}
    </>
  );
}

/** Self-service deletion for students and parents: confirm, delete through the Edge Function, sign out. */
export function DeleteAccountButton() {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function remove() {
    setBusy(true);
    setError(null);
    const supabase = createClient();
    const res = await deleteMyAccount(supabase);
    if ("error" in res) {
      setBusy(false);
      setError(res.error.message || messageFor(res.error.code));
      return;
    }
    // The account is gone; drop the local session and say so on the sign-in page.
    await supabase.auth.signOut({ scope: "local" });
    router.replace("/login?notice=deleted");
    router.refresh();
  }

  return (
    <>
      <button
        type="button"
        onClick={() => {
          setError(null);
          setOpen(true);
        }}
        className="font-semibold text-red-700 hover:underline"
      >
        Delete my account
      </button>
      {open && (
        <ConfirmDialog
          title="Delete my account"
          confirmLabel="Delete my account"
          busy={busy}
          onCancel={() => (busy ? undefined : setOpen(false))}
          onConfirm={remove}
        >
          Permanently delete your account and data? This cannot be undone.
          {error && <span role="alert" className="mt-2 block text-red-700">{error}</span>}
        </ConfirmDialog>
      )}
    </>
  );
}

/** Footer of every /account page: sign out, plus deletion for the roles that may delete themselves. */
export function AccountFooter({ canDelete }: { canDelete: boolean }) {
  return (
    <span className="flex items-center justify-center gap-6">
      <SignOutButton />
      {canDelete && <DeleteAccountButton />}
    </span>
  );
}
