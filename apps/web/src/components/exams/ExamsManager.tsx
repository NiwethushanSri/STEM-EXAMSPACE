"use client";

import { useState, useTransition } from "react";
import { Badge, Card } from "@/components/AppShell";
import { ConfirmDialog } from "@/components/accounts/ConfirmDialog";
import { ExamForm } from "@/components/exams/ExamForm";
import { saveExamAction, setExamStatusAction, type ExamActionResult } from "@/app/admin/exams/actions";
import type { ExamRow, SubjectOption, VenueOption } from "@/lib/exams-staff";
import { formatLondon, formatPence } from "@/lib/money";

const STATUS_TONE = { draft: "slate", published: "green", cancelled: "red", completed: "blue" } as const;
const STATUS_LABEL = { draft: "Draft", published: "Published", cancelled: "Cancelled", completed: "Completed" } as const;

const money = (p: number) => (p === 0 ? "£0.00" : formatPence(p));

type Notice = { ok: boolean; message: string } | null;
type Confirm = { kind: "publish" | "cancel"; exam: ExamRow } | null;

/** The admin exams screen: list with seats and money, create or edit form, publish and cancel. */
export function ExamsManager({ exams, subjects, venues }: { exams: ExamRow[]; subjects: SubjectOption[]; venues: VenueOption[] }) {
  const [editing, setEditing] = useState<ExamRow | "new" | null>(null);
  const [notice, setNotice] = useState<Notice>(null);
  const [formError, setFormError] = useState<string | null>(null);
  const [confirm, setConfirm] = useState<Confirm>(null);
  const [busy, setBusy] = useState(false);
  const [, startTransition] = useTransition();

  function run(fn: () => Promise<ExamActionResult>): Promise<ExamActionResult> {
    setBusy(true);
    return new Promise((resolve) => {
      startTransition(async () => {
        let res: ExamActionResult;
        try {
          res = await fn();
        } catch {
          res = { ok: false, message: "Something went wrong. Please try again." };
        }
        setBusy(false);
        resolve(res);
      });
    });
  }

  async function save(raw: Record<string, string>) {
    setFormError(null);
    setNotice(null);
    const res = await run(() => saveExamAction(raw));
    if (res.ok) {
      setEditing(null);
      setNotice(res);
    } else {
      setFormError(res.message);
    }
  }

  async function changeStatus(kind: "publish" | "cancel", exam: ExamRow) {
    setNotice(null);
    const res = await run(() => setExamStatusAction(exam.id, kind === "publish" ? "published" : "cancelled"));
    setConfirm(null);
    setNotice(res);
  }

  const noSubjects = subjects.length === 0;

  return (
    <div className="space-y-5">
      {notice &&
        (notice.ok ? (
          <div role="status" className="rounded-lg border border-green-200 bg-green-50 p-3 text-sm text-green-900">{notice.message}</div>
        ) : (
          <div role="alert" className="rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-800">{notice.message}</div>
        ))}

      <div className="flex justify-end">
        <button
          type="button"
          disabled={noSubjects}
          onClick={() => {
            setFormError(null);
            setNotice(null);
            setEditing("new");
          }}
          className="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-60"
        >
          New exam
        </button>
      </div>

      {editing && (
        <ExamForm
          key={editing === "new" ? "new" : editing.id}
          withPrice
          subjects={subjects}
          venues={venues}
          exam={editing === "new" ? null : editing}
          busy={busy}
          error={formError}
          onSubmit={save}
          onCancel={() => setEditing(null)}
        />
      )}

      <Card title="All exams">
        {exams.length === 0 ? (
          <p className="text-sm text-slate-500">No exams yet. Create one to get started.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  {["When (UK time)", "Exam", "Where", "Status", "Seats sold", "Price", "Money taken", "Actions"].map((h) => (
                    <th key={h} className="py-2 pr-4 font-medium">{h}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {exams.map((e) => (
                  <ExamTableRow
                    key={e.id}
                    e={e}
                    busy={busy}
                    onEdit={() => {
                      setFormError(null);
                      setNotice(null);
                      setEditing(e);
                    }}
                    onPublish={() => setConfirm({ kind: "publish", exam: e })}
                    onCancel={() => setConfirm({ kind: "cancel", exam: e })}
                  />
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>

      {confirm && (
        <ConfirmDialog
          title={confirm.kind === "publish" ? "Publish this exam?" : "Cancel this exam?"}
          confirmLabel={confirm.kind === "publish" ? "Publish exam" : "Cancel exam"}
          tone={confirm.kind === "publish" ? "primary" : "danger"}
          busy={busy}
          onConfirm={() => changeStatus(confirm.kind, confirm.exam)}
          onCancel={() => setConfirm(null)}
        >
          {confirm.kind === "publish" ? (
            <p>
              <strong>{confirm.exam.title}</strong> will appear on the public timetable and families can book it straight away.
            </p>
          ) : (
            <div className="space-y-2">
              <p>
                <strong>{confirm.exam.title}</strong> will be cancelled and its {confirm.exam.seatsSold} booked seat
                {confirm.exam.seatsSold === 1 ? "" : "s"} released. This cannot be undone.
              </p>
              <p>Unpaid bookings are cancelled. Paid bookings are flagged for a refund, which you then pay back yourself.</p>
            </div>
          )}
        </ConfirmDialog>
      )}
    </div>
  );
}

function ExamTableRow({
  e,
  busy,
  onEdit,
  onPublish,
  onCancel,
}: {
  e: ExamRow;
  busy: boolean;
  onEdit: () => void;
  onPublish: () => void;
  onCancel: () => void;
}) {
  const where = e.format === "online" ? "Online" : [e.venue, e.room].filter(Boolean).join(" · ");
  const canEdit = e.status === "draft" || e.status === "published";
  const refundTotal = e.refundsDue.reduce((s, r) => s + r.pence, 0);
  return (
    <>
      <tr data-testid="exam-row" className="border-b border-slate-100 align-top last:border-0">
        <td className="py-2.5 pr-4 whitespace-nowrap">{formatLondon(e.startsAt)}</td>
        <td className="py-2.5 pr-4">
          <div className="font-medium text-slate-900">{e.title}</div>
          <div className="text-xs text-slate-500">
            {e.subject}
            {e.paper ? ` · ${e.paper}` : ""} · {e.durationMinutes} min
          </div>
        </td>
        <td className="py-2.5 pr-4">{where}</td>
        <td className="py-2.5 pr-4">
          <div className="flex flex-wrap gap-1">
            <Badge tone={STATUS_TONE[e.status]}>{STATUS_LABEL[e.status]}</Badge>
            {e.bookingClosed && <Badge tone="amber">Booking closed</Badge>}
            {e.status === "draft" && !e.priceConfirmed && <Badge tone="amber">Price not confirmed</Badge>}
          </div>
        </td>
        <td className="py-2.5 pr-4 whitespace-nowrap">{e.status === "cancelled" ? "Released" : `${e.seatsSold} / ${e.seatLimit}`}</td>
        <td className="py-2.5 pr-4 whitespace-nowrap">{e.pricePence === null ? "" : formatPence(e.pricePence)}</td>
        <td className="py-2.5 pr-4 whitespace-nowrap">{money(e.moneyPence)}</td>
        <td className="py-2.5">
          <div className="flex flex-wrap gap-2">
            {canEdit && (
              <button type="button" onClick={onEdit} disabled={busy} className="rounded border border-slate-300 px-3 py-1 text-xs hover:bg-slate-50 disabled:opacity-60">
                Edit
              </button>
            )}
            {e.status === "draft" && (
              <button
                type="button"
                onClick={onPublish}
                disabled={busy || !e.priceConfirmed}
                title={e.priceConfirmed ? undefined : "Edit and save the exam to confirm its price first"}
                className="rounded bg-blue-600 px-3 py-1 text-xs font-medium text-white hover:bg-blue-700 disabled:opacity-50"
              >
                Publish
              </button>
            )}
            {e.status === "published" && (
              <button type="button" onClick={onCancel} disabled={busy} className="rounded border border-red-300 px-3 py-1 text-xs font-medium text-red-700 hover:bg-red-50 disabled:opacity-60">
                Cancel exam
              </button>
            )}
          </div>
        </td>
      </tr>
      {e.status === "cancelled" && (
        <tr data-testid="exam-refunds" className="border-b border-slate-100 bg-red-50/50">
          <td colSpan={8} className="px-3 py-2 text-sm">
            {e.refundsDue.length === 0 ? (
              <span className="text-slate-600">Cancelled. No bookings are waiting for a refund.</span>
            ) : (
              <div>
                <p className="font-medium text-red-800">
                  Refunds due: {e.refundsDue.length} booking{e.refundsDue.length === 1 ? "" : "s"}, {money(refundTotal)} in total
                </p>
                <ul className="mt-1 list-disc pl-5 text-slate-700">
                  {e.refundsDue.map((r) => (
                    <li key={r.bookingId}>
                      {r.student}: {money(r.pence)}
                    </li>
                  ))}
                </ul>
              </div>
            )}
          </td>
        </tr>
      )}
    </>
  );
}
