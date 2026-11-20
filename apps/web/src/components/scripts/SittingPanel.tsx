"use client";

import { useCallback, useEffect, useState, type ReactNode } from "react";
import { BookingPaper } from "@/components/papers/BookingPaper";
import { formatLondon } from "@/lib/money";
import {
  DEFAULT_ALLOWED_MATERIALS,
  DEFAULT_HOME_RULES,
  PRINT_AT_ACTUAL_SIZE,
  SITTING_TEXT,
  sittingPhaseText,
  sittingSkewMs,
  type SittingState,
} from "@/lib/sitting-state";
import { createClient } from "@/lib/supabase/client";

const BUTTON =
  "rounded-lg bg-blue-700 px-3 py-1.5 text-sm font-semibold text-white hover:bg-blue-800 disabled:cursor-not-allowed disabled:opacity-60";

const SUBMISSION_LINE: Record<string, string> = {
  draft: "Your upload is not finished yet.",
  checking: "Your answers are being checked.",
  received: "Your answers have been received.",
  needs_attention: "Your answers need attention. The institution will be in touch.",
  rejected: "Your last upload was not accepted. Please upload again.",
};

/** Longest wait before looking at the server again, so a long timer never overflows. */
const MAX_WAIT_MS = 10 * 60_000;

/**
 * The home sitting of one paid booking: the paper download (see BookingPaper), the times, the rules and materials, the
 * acknowledgement, a countdown that follows the database clock, and (after the finish) the place for the upload,
 * which the caller passes as `upload`. `label` names the exam, and the child for a parent, so every control is unique
 * on the page.
 */
export function SittingPanel({ bookingId, label, upload }: { bookingId: string; label: string; upload?: ReactNode }) {
  const [state, setState] = useState<SittingState | null>(null);
  const [loadFailed, setLoadFailed] = useState(false);
  const [now, setNow] = useState(() => Date.now());
  const [busy, setBusy] = useState(false);
  const [ackError, setAckError] = useState<string | null>(null);
  /** Counts finished loads, so a failed look still sets the next timer. */
  const [loads, setLoads] = useState(0);
  /** How far the device clock is behind the database clock, from the latest answer. */
  const [skew, setSkew] = useState(0);

  const fetchState = useCallback(async (): Promise<{ state: SittingState; skew: number } | null> => {
    const sentAt = Date.now();
    const { data, error } = await createClient().rpc("booking_sitting_state", { p_booking: bookingId });
    const s = data as unknown as (SittingState & { ok?: boolean }) | null;
    if (error || !s || s.ok === false) return null;
    return { state: s, skew: sittingSkewMs(s, sentAt, Date.now()) };
  }, [bookingId]);

  const load = useCallback(async () => {
    const r = await fetchState();
    setLoadFailed(!r);
    if (r) {
      setState(r.state);
      setSkew(r.skew);
    }
    setLoads((n) => n + 1);
  }, [fetchState]);

  useEffect(() => {
    let live = true;
    void fetchState().then((r) => {
      if (!live) return;
      setLoadFailed(!r);
      if (r) {
        setState(r.state);
        setSkew(r.skew);
      }
    });
    return () => {
      live = false;
    };
  }, [fetchState]);

  const live = state !== null && state.phase !== "closed";
  // The countdown ticks by the second while the sitting can still change.
  useEffect(() => {
    if (!live) return;
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [live]);

  // Look again just after the next boundary (the start, the finish, the end of on-time uploads, the end of late ones)
  // by the database clock, so the answer, the upload and the acknowledgement follow the server; and after a failed look.
  useEffect(() => {
    if (!state || state.phase === "closed") return;
    const t = Date.now() + skew;
    const next = [state.starts_at, state.finish_at, state.on_time_until, state.late_until]
      .map((x) => Date.parse(x))
      .filter((x) => !Number.isNaN(x) && x > t)
      .sort((a, b) => a - b)[0];
    const wait = next === undefined ? MAX_WAIT_MS : Math.min(next - t + 1500, MAX_WAIT_MS);
    const timer = setTimeout(() => void load(), Math.max(wait, 1500));
    return () => clearTimeout(timer);
  }, [state, loads, skew, load]);

  // A tab coming back from the background (or a laptop waking) looks again at once.
  useEffect(() => {
    const onVisible = () => {
      if (document.visibilityState === "visible") void load();
    };
    document.addEventListener("visibilitychange", onVisible);
    return () => document.removeEventListener("visibilitychange", onVisible);
  }, [load]);

  async function acknowledge() {
    setBusy(true);
    setAckError(null);
    const { data, error } = await createClient().rpc("sitting_acknowledge", { p_booking: bookingId });
    const ok = !error && !!data && typeof data === "object" && !Array.isArray(data) && (data as { ok?: unknown }).ok === true;
    if (!ok) setAckError(SITTING_TEXT.ackFailure);
    await load();
    setBusy(false);
  }

  const paper = <BookingPaper bookingId={bookingId} label={label} />;
  if (loadFailed && !state) {
    return (
      <div className="space-y-2">
        {paper}
        <p role="alert" className="text-sm text-red-700">{SITTING_TEXT.failure}</p>
      </div>
    );
  }
  if (!state) return paper;

  const text = sittingPhaseText(state, now, skew);
  const before = text.phase === "before_start";
  const uploading = text.phase === "upload_open" || text.phase === "late_window";
  const rules = state.rules ?? DEFAULT_HOME_RULES;
  const materials = state.materials ?? DEFAULT_ALLOWED_MATERIALS;
  const ack = state.acknowledged;
  const canAcknowledge = !ack && state.ack_as !== null && (text.phase === "before_start" || text.phase === "sitting");
  const submissionLine = state.submission ? SUBMISSION_LINE[state.submission.state] : null;

  return (
    <section aria-label={`Home sitting for ${label}`} data-testid="sitting-panel" className="space-y-3">
      {paper}
      <div className="space-y-1 rounded-lg bg-slate-50 p-3">
        <p data-testid="sitting-title" className="font-semibold text-slate-800">{text.title}</p>
        {text.countdown && (
          <p data-testid="sitting-countdown" role="timer" aria-live="off" className="text-lg font-semibold tabular-nums text-blue-800">
            {text.countdown}
          </p>
        )}
        <dl className="grid grid-cols-[auto_1fr] gap-x-3 text-slate-600">
          <dt>Starts</dt>
          <dd>{formatLondon(state.starts_at)}</dd>
          <dt>Finishes</dt>
          <dd>{formatLondon(state.finish_at)}</dd>
          <dt>Upload on time until</dt>
          <dd>{formatLondon(state.on_time_until)}</dd>
          <dt>Late uploads until</dt>
          <dd>{formatLondon(state.late_until)}</dd>
        </dl>
      </div>

      {before && (
        <div data-testid="sitting-before" className="space-y-1 rounded-lg border border-amber-200 bg-amber-50 p-3 text-amber-900">
          <p>{SITTING_TEXT.earlyWarning}</p>
          <p>{PRINT_AT_ACTUAL_SIZE}</p>
        </div>
      )}

      {text.phase !== "closed" && !uploading && (
        <div className="space-y-2">
          <div>
            <h3 className="font-semibold text-slate-800">Rules</h3>
            <p data-testid="sitting-rules" className="whitespace-pre-line text-slate-700">{rules}</p>
          </div>
          <div>
            <h3 className="font-semibold text-slate-800">Allowed materials</h3>
            <p data-testid="sitting-materials" className="whitespace-pre-line text-slate-700">{materials}</p>
          </div>
        </div>
      )}

      {text.phase !== "closed" && (ack || canAcknowledge || (state.has_parent && state.ack_as === null)) && (
        <div data-testid="sitting-ack" className="space-y-2 rounded-lg border border-slate-200 p-3">
          {ack ? (
            <p aria-live="polite" className="text-slate-700">
              {ack.as_role === "parent" ? "Supervision confirmed" : "Confirmed by the student"}
              {ack.by_name ? ` by ${ack.by_name}` : ""} at {formatLondon(ack.at)}.
            </p>
          ) : canAcknowledge ? (
            <>
              {state.ack_as === "student" && <p className="text-slate-700">{SITTING_TEXT.studentRule}</p>}
              <button type="button" disabled={busy} onClick={() => void acknowledge()} className={BUTTON}>
                {state.ack_as === "parent" ? SITTING_TEXT.parentAck : SITTING_TEXT.studentAck}
                <span className="sr-only"> for {label}</span>
              </button>
              {ackError && <p role="alert" className="text-sm text-red-700">{ackError}</p>}
            </>
          ) : state.has_parent && state.ack_as === null ? (
            <p className="text-slate-600">{SITTING_TEXT.parentOnly}</p>
          ) : null}
        </div>
      )}

      {uploading && <div data-testid="sitting-upload">{upload}</div>}
      {submissionLine && (
        <p data-testid="sitting-submission" aria-live="polite" className="text-slate-700">
          {submissionLine}
          {state.submission?.late ? " It was handed in late." : ""}
        </p>
      )}
    </section>
  );
}
