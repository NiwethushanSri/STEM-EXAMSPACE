import Link from "next/link";
import { notFound } from "next/navigation";
import { Suspense } from "react";
import { reviewMessageFor } from "@stem/shared";
import { ReviewScreen } from "@/components/marking/ReviewScreen";
import { MARKING_ROLES } from "@/lib/marking-lists";
import { parseReviewOpen } from "@/lib/marking-review";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/uuid";

const OPENING = <p className="p-6 text-sm text-slate-600">Opening the review...</p>;

/** The gate (the layout gates too, Ruling R2), then the review as marking_review_open gives it: the database decides
 * whether the caller (an admin, or the subject's lead marker who is not blind to the piece) may see it. Only the parsed
 * review reaches the screen: script and index numbers and the markers' names, never a candidate's name. */
async function Gate({ params }: { params: Promise<{ reviewId: string }> }) {
  await requireStaff(MARKING_ROLES);
  const { reviewId } = await params;
  if (!isUuid(reviewId)) notFound();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("marking_review_open", { p_review: reviewId });
  const r = error ? ({ ok: false, code: "internal" } as const) : parseReviewOpen(data);
  if (!r.ok) {
    return (
      <main className="mx-auto flex min-h-dvh max-w-md flex-col justify-center gap-4 p-6">
        <p role="alert" className="text-sm text-slate-800">
          {reviewMessageFor(r.code)}
        </p>
        <Link href="/marking/review" className="text-sm font-medium text-blue-700 underline">
          Back to Review
        </Link>
      </main>
    );
  }
  // Keyed by the review, so nothing of one review is kept on the next.
  return <ReviewScreen key={reviewId} data={r.review} back={`/marking/review?tab=${TAB_OF[r.review.review.kind]}`} />;
}

const TAB_OF = { difference: "difference", paused_marker: "paused", sample: "sample" } as const;

/** One review: full screen, as the marking screen, with no staff side menu. */
export default function ReviewPage({ params }: { params: Promise<{ reviewId: string }> }) {
  return (
    <Suspense fallback={OPENING}>
      <Gate params={params} />
    </Suspense>
  );
}
