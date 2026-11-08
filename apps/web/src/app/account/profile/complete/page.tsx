import { Suspense } from "react";
import { redirect } from "next/navigation";
import { homeFor } from "@stem/shared";
import { AuthLayout } from "@/components/AuthLayout";
import { SignOutButton } from "@/components/AccountActions";
import { createClient, getSessionProfile } from "@/lib/supabase/server";
import { ProfileForm } from "./ProfileForm";

async function Content() {
  const me = await getSessionProfile();
  if (!me) redirect("/login");
  if (me.role !== "student" || me.status !== "profile_incomplete") {
    redirect(homeFor(me.role, me.status, "web-staff"));
  }
  const supabase = await createClient();
  const { data } = await supabase.from("subjects").select("id, name").eq("active", true).order("id");
  return (
    <AuthLayout
      title="Complete your profile"
      subtitle={`Welcome, ${me.firstName}. A few details and you are ready to go.`}
      footer={<SignOutButton />}
    >
      <ProfileForm userId={me.id} subjects={data ?? []} />
    </AuthLayout>
  );
}

export default function ProfileCompletePage() {
  return (
    <Suspense>
      <Content />
    </Suspense>
  );
}
