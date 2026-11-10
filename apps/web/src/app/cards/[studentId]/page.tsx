import { Suspense } from "react";
import type { Metadata } from "next";
import { notFound } from "next/navigation";
import QRCode from "qrcode";
import { PrintButton } from "@/components/attendance/PrintButton";
import { isUuid } from "@/lib/uuid";
import { createClient, getSessionProfile } from "@/lib/supabase/server";

export const metadata: Metadata = { title: "Index card", robots: { index: false } };

const INDEX = /^SE-\d{4}-\d{4,}$/;

/**
 * The printable index card. Owner/admin may open any active student's card; a student only their own.
 * Everyone else (parents, other students, staff of other roles, signed-out visitors) gets a 404, the same
 * as a card that does not exist. The QR holds the index number and nothing else.
 */
async function Card({ params }: { params: Promise<{ studentId: string }> }) {
  const { studentId: raw } = await params;
  if (!isUuid(raw)) notFound();
  const studentId = raw.toLowerCase();
  const me = await getSessionProfile();
  if (!me || me.status !== "active") notFound();
  const isAdmin = me.role === "admin" || me.role === "owner";
  if (!isAdmin && !(me.role === "student" && me.id === studentId)) notFound();

  const supabase = await createClient();
  const { data: profile } = await supabase
    .from("profiles")
    .select("first_name, last_name, role, status")
    .eq("id", studentId)
    .maybeSingle();
  if (!profile || profile.role !== "student" || profile.status !== "active") notFound();
  const { data: details } = await supabase.from("student_details").select("index_number, photo_path").eq("profile_id", studentId).maybeSingle();
  const index = details?.index_number ?? "";
  if (!INDEX.test(index)) notFound();

  const qr = await QRCode.toDataURL(index, { errorCorrectionLevel: "M", margin: 2, width: 480 });
  let photoUrl: string | null = null;
  if (details?.photo_path === `${studentId}/photo.jpg`) {
    const signed = await supabase.storage.from("student-photos").createSignedUrl(details.photo_path, 60);
    photoUrl = signed.error ? null : (signed.data?.signedUrl ?? null);
  }
  const name = `${profile.first_name} ${profile.last_name}`.trim();

  return (
    <main className="flex min-h-screen flex-col items-center gap-4 bg-slate-100 p-6 print:h-[148mm] print:min-h-0 print:overflow-hidden print:bg-white print:p-0">
      <style>{`@page { size: A6; margin: 0; } @media print { * { print-color-adjust: exact; -webkit-print-color-adjust: exact; } html, body { width: 105mm; height: 148mm; margin: 0; background: #fff; } }`}</style>
      <PrintButton />
      <article
        aria-label="Index card"
        className="flex h-[148mm] w-[105mm] flex-col items-center justify-between rounded-lg border border-slate-300 bg-white p-[7mm] text-center text-slate-900 shadow print:rounded-none print:border-0 print:shadow-none"
      >
        <p className="text-xs font-semibold uppercase tracking-widest text-blue-800">Stem Examspace</p>
        {photoUrl ? (
          // eslint-disable-next-line @next/next/no-img-element -- a 60-second signed URL, not optimisable
          <img src={photoUrl} alt={`Photo of ${name}`} className="h-[34mm] w-[28mm] rounded object-cover" />
        ) : (
          <div className="flex h-[34mm] w-[28mm] items-center justify-center rounded bg-slate-100 text-xs text-slate-500">No photo</div>
        )}
        <div>
          <p className="text-lg font-semibold" data-testid="card-name">{name}</p>
          <p className="mt-1 font-mono text-xl font-bold tracking-wide" data-testid="card-index">{index}</p>
        </div>
        {/* eslint-disable-next-line @next/next/no-img-element -- a data URL generated on the server */}
        <img src={qr} alt={`QR code for index number ${index}`} data-testid="card-qr" className="h-[38mm] w-[38mm]" />
        <p className="text-[10px] text-slate-500">Bring this card to your exam.</p>
      </article>
    </main>
  );
}

export default function IndexCardPage({ params }: { params: Promise<{ studentId: string }> }) {
  return (
    <Suspense>
      <Card params={params} />
    </Suspense>
  );
}
