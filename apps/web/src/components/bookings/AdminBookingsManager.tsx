"use client";

import { useState, useTransition } from "react";
import { Badge, Card } from "@/components/AppShell";
import { ConfirmDialog } from "@/components/accounts/ConfirmDialog";
import { STATUS_LABEL, STATUS_TONE } from "@/components/bookings/status";
import {
  addBookingAction,
  cancelBookingAction,
  decideCancellationAction,
  markPaidAction,
  searchStudentsAction,
  type BookingActionResult,
} from "@/app/admin/bookings/actions";
import type { AdminBookingRow, ExamOption, StudentOption } from "@/lib/bookings-admin";
import { formatLondon, formatMoney, penceToInput, poundsToPence } from "@/lib/money";

const NOTE_HELP = "Visible to the family, their tutor and the subject's teachers. Don't include personal details.";
const CANCELLED_EXAM_WARNING = "This exam was cancelled — the family is owed a full refund.";
const DELETED_ACCOUNT_WARNING = "This account was deleted — the family is owed a refund.";

type Notice = { ok: boolean; message: string } | null;
type Confirm =
  | { kind: "add"; exam: ExamOption; student: StudentOption; paid: boolean; note: string }
  | { kind: "mark_paid" | "cancel"; row: AdminBookingRow }
  | { kind: "approve"; row: AdminBookingRow; pence: number; refund: string; note: string }
  | { kind: "decline"; row: AdminBookingRow; note: string }
  | null;

/** A cancellation can be declined only while it is a plain request on an exam that still runs. */
function canDecline(r: AdminBookingRow): boolean {
  return r.status === "cancel_requested" && !r.refundDue && r.examStatus !== "cancelled";
}

/** The exam was cancelled, so the family is owed the money back. */
function owedFull(r: AdminBookingRow): boolean {
  return r.refundDue || r.examStatus === "cancelled";
}

function StudentCell({ r }: { r: AdminBookingRow }) {
  return (
    <>
      <div className="font-medium text-slate-900">{r.student}</div>
      {r.indexNumber && <div className="text-xs text-slate-500">{r.indexNumber}</div>}
    </>
  );
}

function ExamCell({ r }: { r: AdminBookingRow }) {
  return (
    <>
      <div>{r.examTitle}</div>
      <div className="text-xs text-slate-500">
        {r.subject}
        {r.startsAt ? ` · ${formatLondon(r.startsAt)}` : ""}
        {r.examStatus === "cancelled" ? " · exam cancelled" : ""}
      </div>
    </>
  );
}

/** One row of "Cancellation requests and refunds due", with its own refund amount and note. */
function DecisionRow({ row, busy, onApprove, onDecline }: {
  row: AdminBookingRow;
  busy: boolean;
  onApprove: (row: AdminBookingRow, refund: string, pence: number, note: string) => void;
  onDecline: (row: AdminBookingRow, note: string) => void;
}) {
  const remaining = row.amountPence - row.refundedPence;
  const [refund, setRefund] = useState(penceToInput(remaining));
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);

  function approve() {
    const p = poundsToPence(refund);
    if (p === null) return setError("Enter the refund in pounds, for example 12.50, or 0 for no refund.");
    if (p > remaining) return setError(`The refund cannot be more than ${formatMoney(remaining)}, the amount not yet refunded.`);
    setError(null);
    onApprove(row, refund, p, note);
  }

  return (
    <li data-testid="decision-row" className="space-y-3 rounded-lg border border-slate-200 p-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <StudentCell r={row} />
          <div className="mt-1 text-sm"><ExamCell r={row} /></div>
        </div>
        <div className="text-right text-sm">
          <Badge tone={STATUS_TONE[row.status]}>{STATUS_LABEL[row.status]}</Badge>
          {row.refundDue && <div className="mt-1 text-xs font-medium text-red-700">Refund due</div>}
          <div className="mt-1 text-slate-700">Paid {formatMoney(row.amountPence)}</div>
          <div className="text-slate-700">Already refunded {formatMoney(row.refundedPence)}</div>
          <div className="font-medium text-slate-900">Still refundable {formatMoney(remaining)}</div>
        </div>
      </div>
      {row.notes && <p className="text-xs text-slate-500">Notes: {row.notes}</p>}
      <div className="flex flex-wrap items-end gap-3 text-sm">
        <label className="flex flex-col gap-1">
          Refund amount (£)
          <input
            inputMode="decimal"
            value={refund}
            onChange={(e) => setRefund(e.target.value)}
            className="w-32 rounded border border-slate-300 px-2 py-1"
          />
        </label>
        <label className="flex min-w-60 flex-1 flex-col gap-1">
          Note (optional)
          <input
            value={note}
            maxLength={500}
            onChange={(e) => setNote(e.target.value)}
            aria-describedby={`note-help-${row.id}`}
            className="rounded border border-slate-300 px-2 py-1"
          />
          <span id={`note-help-${row.id}`} className="text-xs text-slate-500">{NOTE_HELP}</span>
        </label>
        <button
          type="button"
          disabled={busy}
          onClick={approve}
          className="rounded bg-blue-600 px-3 py-1.5 font-medium text-white hover:bg-blue-700 disabled:opacity-60"
        >
          Approve
        </button>
        {canDecline(row) && (
          <button
            type="button"
            disabled={busy}
            onClick={() => onDecline(row, note)}
            className="rounded border border-slate-300 px-3 py-1.5 hover:bg-slate-50 disabled:opacity-60"
          >
            Decline
          </button>
        )}
      </div>
      {error && <p role="alert" className="text-sm text-red-700">{error}</p>}
    </li>
  );
}

/** The add-offline-booking form. */
function AddForm({ exams, busy, onSubmit }: {
  exams: ExamOption[];
  busy: boolean;
  onSubmit: (exam: ExamOption, student: StudentOption, paid: boolean, note: string) => void;
}) {
  const bookable = exams.filter((e) => e.bookable);
  const [examId, setExamId] = useState("");
  const [query, setQuery] = useState("");
  const [students, setStudents] = useState<StudentOption[] | null>(null);
  const [studentId, setStudentId] = useState("");
  const [searching, setSearching] = useState(false);
  const [paid, setPaid] = useState("unpaid");
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);

  async function search() {
    setError(null);
    if (query.trim().length < 2) return setError("Type at least 2 characters of a name or index number.");
    setSearching(true);
    try {
      const res = await searchStudentsAction(query);
      if (res.ok) {
        setStudents(res.students);
        setStudentId(res.students.length === 1 ? res.students[0].id : "");
      } else {
        setError(res.message);
      }
    } catch {
      setError("Something went wrong. Please try again.");
    }
    setSearching(false);
  }

  function submit(e: React.FormEvent) {
    e.preventDefault();
    const exam = bookable.find((x) => x.id === examId);
    const student = students?.find((s) => s.id === studentId);
    if (!exam) return setError("Choose an exam.");
    if (!student) return setError("Search for the student and choose one.");
    setError(null);
    onSubmit(exam, student, paid === "paid", note);
  }

  return (
    <form aria-label="Add offline booking" onSubmit={submit} className="space-y-3 text-sm">
      <div className="grid gap-3 md:grid-cols-2">
        <label className="flex flex-col gap-1">
          Exam
          <select aria-label="Exam" value={examId} onChange={(e) => setExamId(e.target.value)} className="rounded border border-slate-300 bg-white px-2 py-1.5">
            <option value="">Choose an exam</option>
            {bookable.map((e) => (
              <option key={e.id} value={e.id}>{e.label} — {formatLondon(e.startsAt)}</option>
            ))}
          </select>
        </label>
        <div className="flex flex-col gap-1">
          <label htmlFor="student-search">Find student (name or index number)</label>
          <div className="flex gap-2">
            <input
              id="student-search"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  e.preventDefault();
                  void search();
                }
              }}
              className="min-w-0 flex-1 rounded border border-slate-300 px-2 py-1.5"
            />
            <button type="button" disabled={searching} onClick={() => void search()} className="rounded border border-slate-300 px-3 py-1.5 hover:bg-slate-50 disabled:opacity-60">
              Find student
            </button>
          </div>
        </div>
        <label className="flex flex-col gap-1">
          Student
          <select aria-label="Student" value={studentId} onChange={(e) => setStudentId(e.target.value)} disabled={!students || students.length === 0} className="rounded border border-slate-300 bg-white px-2 py-1.5 disabled:bg-slate-100">
            <option value="">{students === null ? "Search first" : students.length === 0 ? "No active student found" : "Choose a student"}</option>
            {(students ?? []).map((s) => (
              <option key={s.id} value={s.id}>{s.name}{s.indexNumber ? ` — ${s.indexNumber}` : ""}</option>
            ))}
          </select>
        </label>
        <label className="flex flex-col gap-1">
          Payment
          <select value={paid} onChange={(e) => setPaid(e.target.value)} className="rounded border border-slate-300 bg-white px-2 py-1.5">
            <option value="unpaid">Unpaid (awaiting payment)</option>
            <option value="paid">Paid offline</option>
          </select>
        </label>
        <label className="flex flex-col gap-1 md:col-span-2">
          Note (optional)
          <input value={note} maxLength={500} onChange={(e) => setNote(e.target.value)} aria-describedby="add-note-help" className="rounded border border-slate-300 px-2 py-1.5" />
          <span id="add-note-help" className="text-xs text-slate-500">{NOTE_HELP}</span>
        </label>
      </div>
      {error && <p role="alert" className="text-red-700">{error}</p>}
      <button type="submit" disabled={busy} className="rounded bg-blue-600 px-4 py-2 font-medium text-white hover:bg-blue-700 disabled:opacity-60">
        Add booking
      </button>
    </form>
  );
}

/** The admin bookings screen: refund decisions, add an offline booking, and the filtered list with mark paid and cancel. */
export function AdminBookingsManager({ rows, decidable, exams, capped, truncated, cap }: {
  rows: AdminBookingRow[];
  decidable: AdminBookingRow[];
  exams: ExamOption[];
  capped: boolean;
  truncated: boolean;
  cap: number;
}) {
  const [notice, setNotice] = useState<Notice>(null);
  const [confirm, setConfirm] = useState<Confirm>(null);
  const [dialogNote, setDialogNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [formKey, setFormKey] = useState(0);
  const [, startTransition] = useTransition();

  function run(fn: () => Promise<BookingActionResult>): Promise<BookingActionResult> {
    setBusy(true);
    return new Promise((resolve) => {
      startTransition(async () => {
        let res: BookingActionResult;
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

  function open(c: NonNullable<Confirm>) {
    setNotice(null);
    setDialogNote("");
    setConfirm(c);
  }

  async function doConfirm() {
    if (!confirm) return;
    const c = confirm;
    const res = await run(() => {
      switch (c.kind) {
        case "add":
          return addBookingAction(c.exam.id, c.student.id, c.paid, c.note);
        case "mark_paid":
          return markPaidAction(c.row.id, dialogNote);
        case "cancel":
          return cancelBookingAction(c.row.id, dialogNote);
        case "approve":
          return decideCancellationAction(c.row.id, true, c.refund, c.note);
        case "decline":
          return decideCancellationAction(c.row.id, false, "0", c.note);
      }
    });
    setConfirm(null);
    setNotice(res);
    if (res.ok && c.kind === "add") setFormKey((k) => k + 1);
  }

  const dialog = (() => {
    if (!confirm) return null;
    switch (confirm.kind) {
      case "add":
        return {
          title: "Add this booking?",
          label: "Add booking",
          tone: "primary" as const,
          body: (
            <p>
              {confirm.student.name} will be booked on {confirm.exam.label}, {confirm.paid ? "marked as paid offline" : "awaiting payment"}.
            </p>
          ),
        };
      case "mark_paid":
      case "cancel": {
        const paying = confirm.kind === "mark_paid";
        return {
          title: paying ? "Mark as paid?" : "Cancel this booking?",
          label: paying ? "Mark paid" : "Cancel booking",
          tone: paying ? ("primary" as const) : ("danger" as const),
          body: (
            <div className="space-y-3">
              <p>
                {confirm.row.student}, {confirm.row.examTitle}, {formatMoney(confirm.row.amountPence)}.{" "}
                {paying ? "The booking will be recorded as paid offline." : "The seat is released and the booking is cancelled."}
              </p>
              <label className="flex flex-col gap-1">
                Note (optional)
                <input value={dialogNote} maxLength={500} onChange={(e) => setDialogNote(e.target.value)} className="rounded border border-slate-300 px-2 py-1.5" />
                <span className="text-xs text-slate-500">{NOTE_HELP}</span>
              </label>
            </div>
          ),
        };
      }
      case "approve":
        return {
          title: "Approve this cancellation?",
          label: "Approve cancellation",
          tone: "primary" as const,
          body: (
            <div className="space-y-3">
              <p>
                {confirm.row.student}, {confirm.row.examTitle}. Record a refund of {formatMoney(confirm.pence)} out of {formatMoney(confirm.row.amountPence - confirm.row.refundedPence)} still refundable.
                No money is sent from here: pay the family back yourself.
              </p>
              {confirm.pence === 0 && owedFull(confirm.row) && (
                <p role="alert" className="rounded border border-red-200 bg-red-50 p-2 font-medium text-red-800">{confirm.row.examStatus === "cancelled" ? CANCELLED_EXAM_WARNING : DELETED_ACCOUNT_WARNING}</p>
              )}
            </div>
          ),
        };
      case "decline":
        return {
          title: "Decline this cancellation?",
          label: "Decline cancellation",
          tone: "danger" as const,
          body: <p>{confirm.row.student}, {confirm.row.examTitle}. The booking goes back to paid and keeps its seat.</p>,
        };
    }
  })();

  return (
    <div className="space-y-5">
      {notice &&
        (notice.ok ? (
          <div role="status" className="rounded-lg border border-green-200 bg-green-50 p-3 text-sm text-green-900">{notice.message}</div>
        ) : (
          <div role="alert" className="rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-800">{notice.message}</div>
        ))}

      <Card title="Cancellation requests and refunds due">
        {decidable.length === 0 ? (
          <p className="text-sm text-slate-500">Nothing to decide right now.</p>
        ) : (
          <ul className="space-y-3">
            {decidable.map((r) => (
              <DecisionRow
                key={`${r.id}-${r.status}-${r.refundedPence}`}
                row={r}
                busy={busy}
                onApprove={(row, refund, pence, note) => open({ kind: "approve", row, pence, refund, note })}
                onDecline={(row, note) => open({ kind: "decline", row, note })}
              />
            ))}
          </ul>
        )}
      </Card>

      <Card title="Add offline booking">
        <AddForm
          key={formKey}
          exams={exams}
          busy={busy}
          onSubmit={(exam, student, paid, note) => open({ kind: "add", exam, student, paid, note })}
        />
      </Card>

      <Card title="Bookings">
        {truncated && <p className="mb-3 text-xs text-slate-500">Showing the first results — refine your search.</p>}
        {capped && <p className="mb-3 text-xs text-slate-500">Showing the newest {cap} bookings that match. Narrow the filters to see others.</p>}
        {rows.length === 0 ? (
          <p className="text-sm text-slate-500">No bookings match these filters.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="py-2 pr-4 font-medium">Student</th>
                  <th className="py-2 pr-4 font-medium">Exam</th>
                  <th className="py-2 pr-4 font-medium">Amount</th>
                  <th className="py-2 pr-4 font-medium">Refunded</th>
                  <th className="py-2 pr-4 font-medium">Status</th>
                  <th className="py-2 pr-4 font-medium">Notes</th>
                  <th className="py-2 font-medium"><span className="sr-only">Actions</span></th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.id} data-testid="booking-row" className="border-b border-slate-100 align-top last:border-0">
                    <td className="py-2.5 pr-4"><StudentCell r={r} /></td>
                    <td className="py-2.5 pr-4"><ExamCell r={r} /></td>
                    <td className="py-2.5 pr-4">{formatMoney(r.amountPence)}</td>
                    <td className="py-2.5 pr-4">{formatMoney(r.refundedPence)}</td>
                    <td className="py-2.5 pr-4">
                      <Badge tone={STATUS_TONE[r.status]}>{STATUS_LABEL[r.status]}</Badge>
                      {r.refundDue && <div className="mt-1 text-xs font-medium text-red-700">Refund due</div>}
                      {r.paidOffline && <div className="mt-1 text-xs text-slate-500">Paid offline</div>}
                    </td>
                    <td className="max-w-56 whitespace-pre-line py-2.5 pr-4 text-xs text-slate-600">{r.notes}</td>
                    <td className="py-2.5">
                      {r.status === "awaiting_payment" && (
                        <div className="flex gap-2">
                          <button type="button" disabled={busy} onClick={() => open({ kind: "mark_paid", row: r })} className="rounded bg-blue-600 px-2.5 py-1 text-xs font-medium text-white hover:bg-blue-700 disabled:opacity-60">
                            Mark paid
                          </button>
                          <button type="button" disabled={busy} onClick={() => open({ kind: "cancel", row: r })} className="rounded border border-slate-300 px-2.5 py-1 text-xs hover:bg-slate-50 disabled:opacity-60">
                            Cancel booking
                          </button>
                        </div>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>

      {confirm && dialog && (
        <ConfirmDialog title={dialog.title} confirmLabel={dialog.label} tone={dialog.tone} busy={busy} onConfirm={doConfirm} onCancel={() => setConfirm(null)}>
          {dialog.body}
        </ConfirmDialog>
      )}
    </div>
  );
}
