import { notFound } from "next/navigation";
import { Suspense } from "react";
import { MarkingScreen } from "@/components/marking/MarkingScreen";
import { MARKING_ROLES } from "@/lib/marking-lists";
import { requireStaff } from "@/lib/staff-gate";
import { isUuid } from "@/lib/uuid";

const OPENING = <p className="p-6 text-sm text-slate-600">Opening the script...</p>;

/** The gate (the layout gates too, Ruling R2), then the screen. The piece itself is opened from the browser: the
 * database functions check the caller (marking_unit_open, marking_save, marking_submit, marking_name_visible). */
async function Gate({ params }: { params: Promise<{ unitId: string }> }) {
  await requireStaff(MARKING_ROLES);
  const { unitId } = await params;
  if (!isUuid(unitId)) notFound();
  // Keyed by the piece, so "Next script" on the screen opens the next piece with nothing kept from this one.
  return <MarkingScreen key={unitId} unitId={unitId} />;
}

/** The marking screen: full screen, with no staff side menu. */
export default function MarkingScreenPage({ params }: { params: Promise<{ unitId: string }> }) {
  return (
    <Suspense fallback={OPENING}>
      <Gate params={params} />
    </Suspense>
  );
}
