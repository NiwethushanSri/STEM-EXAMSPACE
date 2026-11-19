"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { downloadPaperCopy } from "@stem/shared";
import { Card } from "@/components/AppShell";
import { buildPrintPack, fetchInOrder, type FetchOutcome } from "@/lib/print-pack";
import { createClient } from "@/lib/supabase/client";
import { formatLondon } from "@/lib/money";
import type { PackCentre } from "@/lib/exam-admin";

/** At most this many copies are being made at once. */
const IN_FLIGHT = 3;

function saveBlob(blob: Blob, fileName: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = fileName;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
}

const fileSafe = (s: string) => s.replace(/[^A-Za-z0-9-]+/g, "-").replace(/^-+|-+$/g, "");

type Run = { centreId: string; done: number; total: number; failedIndex: string | null; finished: boolean };
type Reprint = { busy: boolean; differs: boolean; error: string | null; done: boolean };

/** Print packs per centre, and a reprint for any one candidate. Needs the exam's current paper. */
export function PrintPanel({
  examTitle,
  examCode,
  startsAt,
  paperVersion,
  centres,
}: {
  examTitle: string;
  examCode: string;
  startsAt: string;
  /** Version of the current paper, or null when none is uploaded. */
  paperVersion: number | null;
  centres: PackCentre[];
}) {
  const router = useRouter();
  const [run, setRun] = useState<Run | null>(null);
  const [reprints, setReprints] = useState<Record<string, Reprint>>({});

  const anyRunning = run !== null && !run.finished && run.failedIndex === null;

  async function makePack(centre: PackCentre) {
    if (paperVersion === null || centre.candidates.length === 0 || anyRunning) return;
    setRun({ centreId: centre.id, done: 0, total: centre.candidates.length, failedIndex: null, finished: false });
    const client = createClient();
    const result = await fetchInOrder(
      centre.candidates,
      async (c): Promise<FetchOutcome<Uint8Array>> => {
        const r = await downloadPaperCopy(client, { bookingId: c.bookingId, kind: "print_pack" });
        if ("error" in r) return { ok: false };
        return { ok: true, value: new Uint8Array(await r.data.blob.arrayBuffer()) };
      },
      {
        limit: IN_FLIGHT,
        onProgress: (done) => setRun((r) => (r && r.centreId === centre.id ? { ...r, done } : r)),
      },
    );
    if (!result.ok) {
      // The index number only; no name goes on screen here.
      setRun((r) => ({ centreId: centre.id, done: r?.done ?? 0, total: centre.candidates.length, failedIndex: centre.candidates[result.failedIndex].indexNumber, finished: true }));
      router.refresh();
      return;
    }
    try {
      const bytes = await buildPrintPack(result.values, {
        examTitle,
        examCode,
        centre: centre.venue,
        room: centre.room,
        date: formatLondon(startsAt),
        candidates: centre.candidates.length,
        paperVersion,
        madeAt: formatLondon(new Date().toISOString()),
      });
      saveBlob(new Blob([bytes as BlobPart], { type: "application/pdf" }), `${fileSafe(examCode)}-${fileSafe(centre.venue)}-${fileSafe(centre.room)}-print-pack.pdf`);
      setRun({ centreId: centre.id, done: centre.candidates.length, total: centre.candidates.length, failedIndex: null, finished: true });
    } catch {
      setRun({ centreId: centre.id, done: centre.candidates.length, total: centre.candidates.length, failedIndex: "the pack itself", finished: true });
    }
    router.refresh();
  }

  async function reprint(bookingId: string) {
    setReprints((m) => ({ ...m, [bookingId]: { busy: true, differs: false, error: null, done: false } }));
    const r = await downloadPaperCopy(createClient(), { bookingId, kind: "reprint" });
    if ("error" in r) {
      setReprints((m) => ({ ...m, [bookingId]: { busy: false, differs: false, error: r.error.message, done: false } }));
      return;
    }
    saveBlob(r.data.blob, r.data.fileName);
    setReprints((m) => ({ ...m, [bookingId]: { busy: false, differs: r.data.differs, error: null, done: true } }));
    router.refresh();
  }

  return (
    <Card title="Print packs">
      {paperVersion === null && <p className="mb-3 text-sm text-slate-600">Upload the paper before making print packs.</p>}
      {centres.length === 0 ? (
        <p className="text-sm text-slate-500">This exam has no centres.</p>
      ) : (
        <div className="space-y-5">
          {centres.map((c) => {
            const mine = run?.centreId === c.id ? run : null;
            return (
              <section key={c.id} data-testid="print-centre" aria-label={`${c.venue} · ${c.room}`} className="rounded border border-slate-200 p-4">
                <div className="flex flex-wrap items-center justify-between gap-3">
                  <div>
                    <div className="font-medium text-slate-900">
                      {c.venue} · {c.room}
                    </div>
                    <div className="text-xs text-slate-500">
                      {c.candidates.length} candidate{c.candidates.length === 1 ? "" : "s"} (paid bookings, in index number order)
                    </div>
                  </div>
                  <button
                    type="button"
                    onClick={() => makePack(c)}
                    disabled={paperVersion === null || c.candidates.length === 0 || anyRunning}
                    className="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
                  >
                    Print pack
                  </button>
                </div>

                {mine && (
                  <div className="mt-3" aria-live="polite">
                    {mine.failedIndex === null ? (
                      <>
                        <div
                          role="progressbar"
                          aria-label={`Print pack progress for ${c.venue} ${c.room}`}
                          aria-valuemin={0}
                          aria-valuemax={mine.total}
                          aria-valuenow={mine.done}
                          className="h-2 overflow-hidden rounded bg-slate-200"
                        >
                          <div className="h-full bg-blue-600 transition-[width]" style={{ width: `${Math.round((mine.done / mine.total) * 100)}%` }} />
                        </div>
                        <p className="mt-1 text-xs text-slate-600">
                          {mine.finished ? `Pack saved: ${mine.total} cop${mine.total === 1 ? "y" : "ies"}.` : `Making copy ${Math.min(mine.done + 1, mine.total)} of ${mine.total}...`}
                        </p>
                      </>
                    ) : (
                      <div role="alert" className="rounded border border-red-200 bg-red-50 p-3 text-sm text-red-800">
                        <p>
                          The pack was not made. {mine.failedIndex === "the pack itself" ? "The pack could not be put together." : `The copy for candidate ${mine.failedIndex} could not be prepared.`} Nothing was saved.
                        </p>
                        <button type="button" onClick={() => makePack(c)} className="mt-2 rounded border border-red-300 bg-white px-3 py-1 text-xs font-medium text-red-700 hover:bg-red-50">
                          Retry
                        </button>
                      </div>
                    )}
                  </div>
                )}

                {c.candidates.length > 0 && (
                  <details className="mt-3">
                    <summary className="cursor-pointer text-sm text-blue-700">Candidates and reprints</summary>
                    <ul className="mt-2 divide-y divide-slate-100 text-sm">
                      {c.candidates.map((cand) => {
                        const rp = reprints[cand.bookingId];
                        return (
                          <li key={cand.bookingId} data-testid="candidate-row" className="py-2">
                            <div className="flex flex-wrap items-center justify-between gap-2">
                              <span>
                                <span className="font-medium">{cand.indexNumber}</span> <span className="text-slate-600">{cand.name}</span>
                              </span>
                              <button
                                type="button"
                                onClick={() => reprint(cand.bookingId)}
                                disabled={paperVersion === null || rp?.busy}
                                aria-label={`Reprint ${cand.indexNumber}`}
                                className="rounded border border-slate-300 px-3 py-1 text-xs hover:bg-slate-50 disabled:opacity-50"
                              >
                                {rp?.busy ? "Making..." : "Reprint"}
                              </button>
                            </div>
                            {rp?.error && (
                              <p role="alert" className="mt-1 text-xs text-red-700">
                                {rp.error}
                              </p>
                            )}
                            {rp?.done && rp.differs && paperVersion !== null && (
                              <p role="alert" className="mt-1 rounded border border-amber-200 bg-amber-50 p-2 text-xs text-amber-900">
                                This reprint uses the corrected paper (version {paperVersion}) and differs from the pack you printed.
                              </p>
                            )}
                            {rp?.done && !rp.differs && <p className="mt-1 text-xs text-slate-500">Reprint saved.</p>}
                          </li>
                        );
                      })}
                    </ul>
                  </details>
                )}
              </section>
            );
          })}
        </div>
      )}
    </Card>
  );
}
