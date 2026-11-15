import { Suspense } from "react";
import { redirect } from "next/navigation";
import { homeFor } from "@stem/shared";
import { AuthLayout } from "@/components/AuthLayout";
import { AccountFooter } from "@/components/AccountActions";
import { createClient, getSessionProfile } from "@/lib/supabase/server";
import { ProfileForm } from "./ProfileForm";

async function Content() {
  const me = await getSessionProfile();
  if (!me) redirect("/login");
  if (me.role !== "student" || me.status !== "profile_incomplete") {
    redirect(homeFor(me.role, me.status, "web-staff"));
  }
  const supabase = await createClient();
  const [{ data }, { data: details }] = await Promise.all([
    supabase.from("subjects").select("id, name").eq("active", true).order("id"),
    // Given at registration; the student confirms or corrects it here.
    supabase.from("student_details").select("parent_phone").eq("profile_id", me.id).maybeSingle(),
  ]);
  return (
    <AuthLayout
      title="Complete your profile"
      subtitle={`Welcome, ${me.firstName}. A few details and you are ready to go.`}
      footer={<AccountFooter canDelete />}
    >
      <ProfileForm userId={me.id} subjects={data ?? []} parentPhone={details?.parent_phone ?? ""} />
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
