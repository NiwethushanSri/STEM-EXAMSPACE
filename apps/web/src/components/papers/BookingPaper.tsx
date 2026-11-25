"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { downloadPaperCopy } from "@stem/shared";
import { clockSkewMs, downloadedLine, nextCheckMs, paperMessage, PAPER_TEXT, type BookingPaperState } from "@/lib/paper-state";
import { createClient, functionsEndpoint } from "@/lib/supabase/client";
import { saveBlob } from "@/lib/download";

const BUTTON =
  "rounded-lg bg-blue-700 px-3 py-1.5 text-sm font-semibold text-white hover:bg-blue-800 disabled:cursor-not-allowed disabled:opacity-60";

/** The paper section of one paid booking (`label` names the exam, and the child for a parent, so every control is unique on the page): its status in plain words, the download, and the inserts. */
export function BookingPaper({ bookingId, label }: { bookingId: string; label: string }) {
  const [state, setState] = useState<BookingPaperState | null>(null);
  const [loadFailed, setLoadFailed] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<{ key: string; message: string } | null>(null);
  /** Counts finished loads, so a failed look (same state as before) still sets the next timer. */
  const [loads, setLoads] = useState(0);

  /** How far the device clock is behind the database clock, from the latest answer. */
  const skew = useRef(0);

  const fetchState = useCallback(async (): Promise<BookingPaperState | null> => {
    const sentAt = Date.now();
    const { data, error: e } = await createClient().rpc("booking_paper_state", { p_booking: bookingId });
    const s = data as unknown as (BookingPaperState & { ok?: boolean }) | null;
    if (e || !s || s.ok === false) return null;
    skew.current = clockSkewMs(s, sentAt, Date.now());
    return s;
  }, [bookingId]);

  const load = useCallback(async () => {
    const s = await fetchState();
    setLoadFailed(!s);
    if (s) setState(s);
    setLoads((n) => n + 1);
  }, [fetchState]);

  useEffect(() => {
    let live = true;
    void fetchState().then((s) => {
      if (!live) return;
      setLoadFailed(!s);
      if (s) setState(s);
    });
    return () => {
      live = false;
    };
  }, [fetchState]);

  // Look again while the answer can change by itself: before the release (every 25 s from 15 minutes before it,
  // and just after it by the server's clock), and while held or missing (so a resume or a late upload shows).
  // The timer is set again after every load (`loads`), even when the answer did not change or the look failed.
  useEffect(() => {
    if (!state) return;
    const wait = nextCheckMs(state, Date.now(), skew.current);
    if (wait === null) return;
    const t = setTimeout(() => void load(), wait);
    return () => clearTimeout(t);
  }, [state, loads, load]);

  // A tab coming back from the background (or a laptop waking) looks again at once.
  useEffect(() => {
    const onVisible = () => {
      if (document.visibilityState === "visible") void load();
    };
    document.addEventListener("visibilitychange", onVisible);
    return () => document.removeEventListener("visibilitychange", onVisible);
  }, [load]);

  async function download(key: string, input: Parameters<typeof downloadPaperCopy>[1]) {
    setBusy(key);
    setError(null);
    const r = await downloadPaperCopy(createClient(), input, functionsEndpoint());
    if ("error" in r) {
      setBusy(null);
      setError({ key, message: r.error.message });
      // A refusal may mean the state moved on (held, closed, not released): show what the server says now.
      await load();
      return;
    }
    saveBlob(r.data.blob, r.data.fileName);
    await load();
    setBusy(null);
  }

  if (loadFailed && !state) return <p role="alert" className="text-sm text-red-700">{PAPER_TEXT.failure}</p>;
  if (!state) return null;

  const now = new Date();
  const msg = paperMessage(state, now);
  const line = downloadedLine(state.last_download, now);
  const open = state.status === "open";

  return (
    <section aria-label={`Paper for ${label}`} data-testid="booking-paper" className="space-y-2 rounded-lg bg-slate-50 p-3">
      <p data-testid="paper-message" aria-live="polite" className="text-slate-700">{msg.text}</p>
      {line && <p data-testid="paper-downloaded" aria-live="polite" className="text-slate-600">{line}</p>}
      {msg.action === "download" && (
        <div>
          <button type="button" disabled={busy !== null} aria-label={`${state.corrected ? "Download corrected paper" : line ? "Download again" : "Download paper"} for ${label}`} onClick={() => download("home", { bookingId, kind: "home" })} className={BUTTON}>
            {busy === "home" ? "Preparing your paper..." : state.corrected ? "Download corrected paper" : line ? "Download again" : "Download paper"}
          </button>
          {error?.key === "home" && <p role="alert" className="mt-1 text-sm text-red-700">{error.message}</p>}
        </div>
      )}
      {open && state.inserts.length > 0 && (
        <ul className="space-y-2 border-t border-slate-200 pt-2" aria-label={`Inserts for ${label}`}>
          {state.inserts.map((i) => (
            <li key={i.id} data-testid="paper-insert" className="space-y-1">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <span className="text-slate-700">{i.title}</span>
                <button
                  type="button"
                  disabled={busy !== null}
                  aria-label={`Download ${i.title} for ${label}`}
                  onClick={() => download(i.id, { bookingId, insertId: i.id })}
                  className="rounded-lg border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium hover:bg-slate-100 disabled:cursor-not-allowed disabled:opacity-60"
                >
                  {busy === i.id ? "Preparing..." : "Download"}
                </button>
              </div>
              {error?.key === i.id && <p role="alert" className="text-sm text-red-700">{error.message}</p>}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
