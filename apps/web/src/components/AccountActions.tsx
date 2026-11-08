"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";
import { messageFor } from "@stem/shared";
import { createClient } from "@/lib/supabase/client";

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
