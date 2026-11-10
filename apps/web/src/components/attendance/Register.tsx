"use client";

import { useEffect, useRef, useState, useTransition } from "react";
import { Card } from "@/components/AppShell";
import { closeRegisterAction, lookupAction, markAction } from "./actions";
import { Scanner } from "./Scanner";

type Mark = "present" | "late" | "absent";
const LABEL: Record<Mark, string> = { present: "Present", late: "Late", absent: "Absent" };

type Shown =
  | { kind: "student"; studentId: string; name: string; photoUrl: string | null; status: Mark | null; justMarked: boolean }
  | { kind: "message"; tone: "error" | "ok"; text: string };

const field = "rounded border border-slate-300 bg-white px-3 py-2 text-sm";

/** The scan / type box, the confirmation card, and the close-register control. Counts and lists are server-rendered around it. */
export function Register({ examId, open, startsAt }: { examId: string; open: boolean; startsAt: string }) {
  const startMs = Date.parse(startsAt);
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 15_000);
    return () => clearInterval(t);
  }, []);
  const canClose = open && now >= startMs;
  const [index, setIndex] = useState("");
  const [shown, setShown] = useState<Shown | null>(null);
  const [confirmClose, setConfirmClose] = useState(false);
  const [closeMessage, setCloseMessage] = useState("");
  const [pending, start] = useTransition();
  // A scan that arrives while another request is running is dropped rather than queued.
  const running = useRef(false);
  const shownIndex = useRef("");

  function lookup(raw: string) {
    const text = raw.trim();
    if (!text || running.current) return;
    running.current = true;
    start(async () => {
      try {
        const r = await lookupAction(examId, text);
        shownIndex.current = r.ok ? text : "";
        setShown(
          r.ok
            ? { kind: "student", studentId: r.studentId, name: r.name, photoUrl: r.photoUrl, status: r.status, justMarked: false }
            : { kind: "message", tone: "error", text: r.message },
        );
      } catch {
        setShown({ kind: "message", tone: "error", text: "Something went wrong. Please try again." });
      } finally {
        running.current = false;
      }
    });
  }

  function mark(studentId: string, name: string, photoUrl: string | null) {
    if (running.current) return;
    running.current = true;
    start(async () => {
      try {
        const r = await markAction(examId, studentId);
        if (!r.ok) setShown({ kind: "message", tone: "error", text: r.message });
        else {
          setShown({ kind: "student", studentId, name, photoUrl, status: r.status, justMarked: !r.already });
          setIndex("");
        }
      } catch {
        setShown({ kind: "message", tone: "error", text: "Something went wrong. Please try again." });
      } finally {
        running.current = false;
      }
    });
  }

  function close() {
    start(async () => {
      try {
        const r = await closeRegisterAction(examId);
        setConfirmClose(false);
        setCloseMessage(r.ok ? `Register closed. ${r.absent} marked absent.` : r.message);
      } catch {
        setCloseMessage("Something went wrong. Please try again.");
      }
    });
  }

  return (
    <div className="space-y-5">
      {open && (
        <Card title="Mark a student">
          <form
            aria-label="Student lookup"
            className="flex flex-wrap items-end gap-3"
            onSubmit={(e) => {
              e.preventDefault();
              lookup(index);
            }}
          >
            <label className="flex flex-col gap-1 text-sm">
              Index number
              <input
                value={index}
                onChange={(e) => setIndex(e.target.value)}
                maxLength={40}
                autoComplete="off"
                autoCapitalize="characters"
                placeholder="SE-2026-0142"
                className={`${field} w-56`}
              />
            </label>
            <button type="submit" disabled={pending || index.trim() === ""} className="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-60">
              Look up
            </button>
            <Scanner
              disabled={pending}
              onCode={(text) => {
                // The student on screen was just looked up or marked: a repeat read must not reset the card.
                if (shownIndex.current === text.trim()) return;
                setIndex(text);
                lookup(text);
              }}
            />
          </form>

          <div role="status" aria-live="polite" className="mt-4" data-testid="lookup-result">
            {shown?.kind === "message" && (
              <p className={`rounded border px-3 py-2 text-sm font-medium ${shown.tone === "error" ? "border-red-200 bg-red-50 text-red-800" : "border-green-200 bg-green-50 text-green-800"}`}>
                {shown.text}
              </p>
            )}
            {shown?.kind === "student" && (
              <div className="flex flex-wrap items-center gap-4 rounded border border-slate-200 p-3">
                {shown.photoUrl ? (
                  // eslint-disable-next-line @next/next/no-img-element -- a 60-second signed URL, not optimisable
                  <img src={shown.photoUrl} alt={`Photo of ${shown.name}`} className="h-28 w-24 rounded object-cover" />
                ) : (
                  <div className="flex h-28 w-24 items-center justify-center rounded bg-slate-100 p-2 text-center text-xs text-slate-500">Photo unavailable</div>
                )}
                <div className="space-y-2">
                  <p className="text-lg font-semibold text-slate-900">{shown.name || "Student"}</p>
                  {shown.status ? (
                    <p className="text-sm font-medium text-slate-700" data-testid="mark-state">
                      {shown.justMarked ? `Marked ${LABEL[shown.status]}` : `Already marked (${LABEL[shown.status]})`}
                    </p>
                  ) : (
                    <button
                      type="button"
                      disabled={pending}
                      onClick={() => mark(shown.studentId, shown.name, shown.photoUrl)}
                      className="rounded bg-green-600 px-4 py-2 text-sm font-medium text-white hover:bg-green-700 disabled:opacity-60"
                    >
                      Mark present
                    </button>
                  )}
                </div>
              </div>
            )}
          </div>
        </Card>
      )}

      {(canClose || closeMessage) && (
        <Card title="Close register">
          {canClose && !confirmClose && (
            <button type="button" disabled={pending} onClick={() => setConfirmClose(true)} className="rounded border border-slate-300 px-4 py-2 text-sm hover:bg-slate-50 disabled:opacity-60">
              Close register
            </button>
          )}
          {canClose && confirmClose && (
            <div role="alertdialog" aria-label="Confirm close register" className="space-y-3 text-sm">
              <p>Close the register? Every booked student not yet marked becomes absent, and the exam is completed. This cannot be undone.</p>
              <div className="flex gap-2">
                <button type="button" disabled={pending} onClick={close} className="rounded bg-red-600 px-4 py-2 font-medium text-white hover:bg-red-700 disabled:opacity-60">
                  Confirm close register
                </button>
                <button type="button" disabled={pending} onClick={() => setConfirmClose(false)} className="rounded border border-slate-300 px-4 py-2 hover:bg-slate-50">
                  Cancel
                </button>
              </div>
            </div>
          )}
          {closeMessage && (
            <p role="status" className="text-sm font-medium text-slate-800">
              {closeMessage}
            </p>
          )}
        </Card>
      )}
    </div>
  );
}
