import { Suspense } from "react";
import { notFound, redirect } from "next/navigation";
import { bannedMessage, homeFor, roleLabel } from "@stem/shared";
import { AuthLayout } from "@/components/AuthLayout";
import { AccountFooter, ResendConfirmationButton } from "@/components/AccountActions";
import { createClient, getSessionProfile } from "@/lib/supabase/server";

const STATES = ["unconfirmed", "pending", "suspended", "home"] as const;
type State = (typeof STATES)[number];

export function generateStaticParams() {
  return STATES.map((state) => ({ state }));
}

async function Content({ params }: { params: Promise<{ state: string }> }) {
  const { state } = await params;
  if (!(STATES as readonly string[]).includes(state)) notFound();

  // The proxy only checks optimistically; this is the real re-check against the database.
  const me = await getSessionProfile();
  if (!me) redirect("/login");
  const home = homeFor(me.role, me.status, "web-staff");
  if (home !== `/account/${state as State}`) redirect(home);

  const footer = <AccountFooter canDelete={me.role === "student" || me.role === "parent"} />;

  switch (state as State) {
    case "unconfirmed":
      return (
        <AuthLayout title="Confirm your email" subtitle={`Hi ${me.firstName}.`} footer={footer}>
          <div className="rounded-xl bg-amber-50 p-5 text-sm text-amber-900">
            <p className="font-semibold">Check your email to confirm your address</p>
            <p className="mt-1">Open the link we sent you to continue.</p>
            <ResendConfirmationButton />
          </div>
        </AuthLayout>
      );
    case "pending": {
      // Read with the student's own session: row level security lets a student see their own details.
      const supabase = await createClient();
      const { data: details } = await supabase
        .from("student_details")
        .select("signup_parent_email")
        .eq("profile_id", me.id)
        .maybeSingle();
      return (
        <AuthLayout title="Awaiting approval" subtitle={`Hi ${me.firstName}.`} footer={footer}>
          <div className="rounded-xl bg-blue-50 p-5 text-sm text-blue-900">
            <p className="font-semibold">Awaiting approval</p>
            <p className="mt-1">
              An admin is checking your details. You will get an email with your index number once your
              account is approved.
            </p>
            {details?.signup_parent_email && (
              <p className="mt-3">
                Parent email on record: <strong>{details.signup_parent_email}</strong>. Not right? Contact the institution.
              </p>
            )}
          </div>
        </AuthLayout>
      );
    }
    case "suspended":
      return (
        <AuthLayout title="Account suspended" subtitle={`Hi ${me.firstName}.`} footer={footer}>
          <div role="alert" className="rounded-xl bg-red-50 p-5 text-sm text-red-800">
            <p className="font-semibold">{bannedMessage}</p>
          </div>
        </AuthLayout>
      );
    case "home": {
      const supabase = await createClient();
      const { data } = await supabase
        .from("student_details")
        .select("index_number")
        .eq("profile_id", me.id)
        .maybeSingle();
      return (
        <AuthLayout title={`Welcome, ${me.firstName}`} subtitle={roleLabel(me.role)} footer={footer}>
          <dl className="space-y-3 text-sm">
            {data?.index_number && (
              <div>
                <dt className="font-medium text-slate-500">Index number</dt>
                <dd className="mt-0.5 text-lg font-semibold text-slate-900">{data.index_number}</dd>
              </div>
            )}
          </dl>
          <p className="mt-4 rounded-xl bg-slate-50 p-4 text-sm text-slate-600">Your dashboard is coming soon</p>
        </AuthLayout>
      );
    }
  }
}

export default function AccountStatePage({ params }: { params: Promise<{ state: string }> }) {
  return (
    <Suspense>
      <Content params={params} />
    </Suspense>
  );
}
