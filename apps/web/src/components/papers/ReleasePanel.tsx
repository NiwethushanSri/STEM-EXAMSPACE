"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Badge, Card } from "@/components/AppShell";
import { ReasonDialog } from "@/components/papers/ReasonDialog";
import { releaseAction, saveSettingsAction } from "@/app/admin/exams/[id]/actions";
import { formatLondon } from "@/lib/money";

type Kind = "release" | "hold" | "resume";

const DIALOG = {
  release: { title: "Release the paper now?", confirm: "Release now", tone: "primary" as const, text: "Families can download their copy straight away, before the planned release time." },
  hold: { title: "Hold the release?", confirm: "Hold release", tone: "danger" as const, text: "Every family download, first or repeat, stops until you resume. Families see that the paper is paused." },
  resume: { title: "Resume the release?", confirm: "Resume release", tone: "primary" as const, text: "Families can download their copy again." },
};

/** Release time and status with Release now, Hold and Resume, plus the paper settings (exam code, release minutes, spare pages). */
export function ReleasePanel({
  examId,
  status,
  releaseAt,
  releasedEarlyAt,
  held,
  hasPaper,
  examCode,
  releaseMinutes,
  sparePages,
  codeLocked,
  nowMs,
}: {
  examId: string;
  status: string;
  releaseAt: string;
  releasedEarlyAt: string | null;
  held: boolean;
  hasPaper: boolean;
  examCode: string;
  releaseMinutes: number;
  sparePages: number;
  /** A copy of the paper exists, so the exam code can no longer change. */
  codeLocked: boolean;
  /** The server's time when the page was made. */
  nowMs: number;
}) {
  const router = useRouter();
  const [dialog, setDialog] = useState<Kind | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<{ ok: boolean; message: string } | null>(null);

  const [code, setCode] = useState(examCode);
  const [minutes, setMinutes] = useState(String(releaseMinutes));
  const [spare, setSpare] = useState(String(sparePages));
  const [settingsError, setSettingsError] = useState<string | null>(null);

  const published = status === "published";
  const released = Date.parse(releaseAt) <= nowMs;
  const state = held ? "Held" : released ? "Released" : "Scheduled";
  const tone = held ? "red" : released ? "green" : "blue";

  async function run(kind: Kind, reason: string) {
    setBusy(true);
    setError(null);
    const res = await releaseAction(examId, kind, reason).catch(() => ({ ok: false as const, message: "Something went wrong. Please try again." }));
    setBusy(false);
    if (res.ok) {
      setDialog(null);
      setNotice(res);
      router.refresh();
    } else {
      setError(res.message);
    }
  }

  async function saveSettings(e: React.FormEvent) {
    e.preventDefault();
    setSettingsError(null);
    setNotice(null);
    const m = Number(minutes);
    const s = Number(spare);
    if (!/^[A-Za-z0-9-]{3,40}$/.test(code.trim())) return setSettingsError("The exam code is 3 to 40 letters, numbers or hyphens.");
    if (!Number.isInteger(m) || m < 0 || m > 120) return setSettingsError("Release minutes must be a whole number from 0 to 120.");
    if (!Number.isInteger(s) || s < 0 || s > 6) return setSettingsError("Spare answer pages must be a whole number from 0 to 6.");
    setBusy(true);
    const res = await saveSettingsAction(examId, { examCode: code.trim(), releaseMinutes: m, sparePages: s }).catch(() => ({ ok: false as const, message: "Something went wrong. Please try again." }));
    setBusy(false);
    if (res.ok) {
      setNotice(res);
      router.refresh();
    } else {
      setSettingsError(res.message);
    }
  }

  const canRelease = published && hasPaper && !released && !held;

  return (
    <Card title="Release and settings">
      {notice && (
        <div role="status" className="mb-3 rounded-lg border border-green-200 bg-green-50 p-3 text-sm text-green-900">
          {notice.message}
        </div>
      )}
      <dl className="grid gap-x-8 gap-y-2 text-sm sm:grid-cols-2">
        <div>
          <dt className="text-xs uppercase tracking-wide text-slate-500">Release time (UK time)</dt>
          <dd data-testid="release-time" className="font-medium text-slate-900">
            {formatLondon(releaseAt)}
            {releasedEarlyAt && <span className="ml-2 text-xs font-normal text-slate-500">released early</span>}
          </dd>
        </div>
        <div>
          <dt className="text-xs uppercase tracking-wide text-slate-500">Status</dt>
          <dd data-testid="release-status">
            <Badge tone={tone}>{state}</Badge>
            {!published && <span className="ml-2 text-xs text-slate-500">The exam is not published.</span>}
            {published && !hasPaper && <span className="ml-2 text-xs text-slate-500">No paper uploaded yet.</span>}
          </dd>
        </div>
      </dl>
      <div className="mt-3 flex flex-wrap gap-2">
        <button type="button" disabled={!canRelease} onClick={() => setDialog("release")} className="rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50">
          Release now
        </button>
        <button type="button" disabled={!published || held} onClick={() => setDialog("hold")} className="rounded border border-red-300 px-3 py-1.5 text-sm font-medium text-red-700 hover:bg-red-50 disabled:opacity-50">
          Hold
        </button>
        <button type="button" disabled={!published || !held} onClick={() => setDialog("resume")} className="rounded border border-slate-300 px-3 py-1.5 text-sm hover:bg-slate-50 disabled:opacity-50">
          Resume
        </button>
      </div>

      <form onSubmit={saveSettings} aria-label="Paper settings" className="mt-6 border-t border-slate-100 pt-4">
        <h3 className="mb-3 text-sm font-semibold text-slate-800">Paper settings</h3>
        <div className="grid gap-4 sm:grid-cols-3">
          <label className="block text-sm">
            <span className="font-medium text-slate-700">Exam code</span>
            <input value={code} onChange={(e) => setCode(e.target.value.toUpperCase())} disabled={codeLocked} maxLength={40} className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm disabled:bg-slate-50 disabled:text-slate-500" />
            <span className="text-xs text-slate-500">{codeLocked ? "Locked: copies have been made." : "Can change until the first copy is made."}</span>
          </label>
          <label className="block text-sm">
            <span className="font-medium text-slate-700">Release minutes before the start</span>
            <input type="number" inputMode="numeric" min={0} max={120} value={minutes} onChange={(e) => setMinutes(e.target.value)} className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm" />
            <span className="text-xs text-slate-500">0 to 120.</span>
          </label>
          <label className="block text-sm">
            <span className="font-medium text-slate-700">Spare answer pages</span>
            <input type="number" inputMode="numeric" min={0} max={6} value={spare} onChange={(e) => setSpare(e.target.value)} className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm" />
            <span className="text-xs text-slate-500">0 to 6. Copies already made keep theirs.</span>
          </label>
        </div>
        {settingsError && (
          <p role="alert" className="mt-3 text-sm text-red-700">
            {settingsError}
          </p>
        )}
        <div className="mt-4">
          <button type="submit" disabled={busy} className="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-60">
            Save settings
          </button>
        </div>
      </form>

      {dialog && (
        <ReasonDialog
          title={DIALOG[dialog].title}
          confirmLabel={DIALOG[dialog].confirm}
          tone={DIALOG[dialog].tone}
          busy={busy}
          error={error}
          onConfirm={(reason) => run(dialog, reason)}
          onCancel={() => {
            setDialog(null);
            setError(null);
          }}
        >
          <p>{DIALOG[dialog].text}</p>
        </ReasonDialog>
      )}
    </Card>
  );
}
