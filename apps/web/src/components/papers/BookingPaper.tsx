"use client";

import { useCallback, useEffect, useState } from "react";
import { downloadPaperCopy } from "@stem/shared";
import { downloadedLine, paperMessage, PAPER_TEXT, type BookingPaperState } from "@/lib/paper-state";
import { createClient } from "@/lib/supabase/client";

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

/** Longest wait before looking again, so a long timer never overflows. */
const MAX_WAIT_MS = 10 * 60_000;

const BUTTON =
  "rounded-lg bg-blue-700 px-3 py-1.5 text-sm font-semibold text-white hover:bg-blue-800 disabled:cursor-not-allowed disabled:opacity-60";

/** The paper section of one paid booking (`label` names the exam, and the child for a parent, so every control is unique on the page): its status in plain words, the download, and the inserts. */
export function BookingPaper({ bookingId, label }: { bookingId: string; label: string }) {
  const [state, setState] = useState<BookingPaperState | null>(null);
  const [loadFailed, setLoadFailed] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<{ key: string; message: string } | null>(null);

  const fetchState = useCallback(async (): Promise<BookingPaperState | null> => {
    const { data, error: e } = await createClient().rpc("booking_paper_state", { p_booking: bookingId });
    const s = data as unknown as (BookingPaperState & { ok?: boolean }) | null;
    return e || !s || s.ok === false ? null : s;
  }, [bookingId]);

  const load = useCallback(async () => {
    const s = await fetchState();
    setLoadFailed(!s);
    if (s) setState(s);
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

  // Before the release, look again when it arrives (the server clock decides what the page then shows).
  const releaseAt = state?.status === "not_yet" ? state.release_at : null;
  useEffect(() => {
    if (!releaseAt) return;
    const wait = Math.min(Math.max(Date.parse(releaseAt) - Date.now() + 1500, 1500), MAX_WAIT_MS);
    const t = setTimeout(() => void load(), wait);
    return () => clearTimeout(t);
  }, [releaseAt, load]);

  async function download(key: string, input: Parameters<typeof downloadPaperCopy>[1]) {
    setBusy(key);
    setError(null);
    const r = await downloadPaperCopy(createClient(), input);
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
