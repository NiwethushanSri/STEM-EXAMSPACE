"use client";

import Link from "next/link";
import { useId, useState } from "react";
import { useRouter } from "next/navigation";
import { Badge, Card } from "@/components/AppShell";
import { PageViewer } from "@/components/scripts/PageViewer";
import { scriptRepositoryAction } from "@/app/admin/scripts/[id]/actions";
import { KIND_LABEL, foundInWords, reasonProblem, resolutionLabel } from "@/lib/exception-queue";
import { formatLondon } from "@/lib/money";
import {
  ROLE_LABEL,
  SOURCE_LABEL,
  STATE_TONE,
  actionText,
  beingMarked,
  candidateText,
  handBackBlocked,
  jobText,
  pageLabel,
  pagesEditable,
  picturesToCheckText,
  remaskPending,
  reprocessable,
  reprocessRefusal,
  stateText,
  takenBackReasonText,
  turnText,
  versionReason,
  voidable,
  type DetailPage,
  type DetailUpload,
  type RepoInput,
  type ScriptDetail,
} from "@/lib/script-repository";

const BUTTON = "rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:opacity-50";
const DANGER = "rounded bg-red-700 px-4 py-2 text-sm font-medium text-white hover:bg-red-800 disabled:cursor-not-allowed disabled:opacity-50";
const FIELD = "rounded border border-slate-300 px-2 py-1.5 text-sm";

type Note = { ok: boolean; text: string };

function NoteLine({ note }: { note: Note | null }) {
  return (
    <>
      <div aria-live="polite">{note?.ok && <p className="text-sm text-green-800">{note.text}</p>}</div>
      {note && !note.ok && (
        <p role="alert" className="text-sm text-red-700">
          {note.text}
        </p>
      )}
    </>
  );
}

/** A reason box (3 to 300 characters, audited; it may be left empty when `optional`) and the button that sends the
 * tool with it. With `blocked`, the button is off and says why. */
function ReasonForm({
  scriptId,
  build,
  label,
  hint,
  danger = false,
  optional = false,
  blocked = null,
}: {
  scriptId: string;
  build: (reason: string) => RepoInput;
  label: string;
  hint: string;
  danger?: boolean;
  optional?: boolean;
  blocked?: string | null;
}) {
  const router = useRouter();
  const id = useId();
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<Note | null>(null);

  async function send() {
    const problem = reasonProblem(reason, !optional);
    if (problem) return setNote({ ok: false, text: problem });
    setBusy(true);
    setNote(null);
    const res = await scriptRepositoryAction(scriptId, build(reason)).catch(() => ({ ok: false as const, message: "Something went wrong. Please try again." }));
    setBusy(false);
    setNote({ ok: res.ok, text: res.message });
    if (res.ok) {
      setReason("");
      router.refresh();
    }
  }

  return (
    <div className="space-y-2">
      <label htmlFor={id} className="block text-sm font-medium text-slate-800">
        Reason <span className="font-normal text-slate-500">({hint})</span>
      </label>
      <textarea id={id} value={reason} onChange={(e) => setReason(e.target.value)} maxLength={300} rows={2} className={`${FIELD} w-full`} />
      <button
        type="button"
        className={danger ? DANGER : BUTTON}
        disabled={busy || !!blocked}
        aria-describedby={blocked ? `${id}-blocked` : undefined}
        onClick={send}
      >
        {busy ? "Saving..." : label}
      </button>
      {blocked && (
        <p id={`${id}-blocked`} className="text-sm text-slate-600">
          {blocked}
        </p>
      )}
      <NoteLine note={note} />
    </div>
  );
}

type PageTool = "right" | "left" | "half" | "remove";
const TOOL_LABEL: Record<PageTool, string> = {
  right: "Turn a quarter turn right",
  left: "Turn a quarter turn left",
  half: "Turn a half turn",
  remove: "Take this page out of the script",
};

/** The chosen page: its full picture (staff only) and its marking picture (what markers see) side by side, and the
 * tools that change it. */
function PageView({ detail, page, upload }: { detail: ScriptDetail; page: DetailPage; upload: DetailUpload | null }) {
  const editable = pagesEditable(detail.script.state);
  const tools: PageTool[] = page.extra ? ["right", "left", "half"] : ["right", "left", "half", "remove"];
  const [tool, setTool] = useState<PageTool>("right");
  const pending = upload ? remaskPending(upload) : false;
  const label = pageLabel(page);
  const flags = page.flags.filter((f) => f !== "layout_unexpected");

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2 text-sm text-slate-700">
        <span className="font-medium text-slate-900">{label}</span>
        {page.role && <Badge tone="slate">{ROLE_LABEL[page.role] ?? page.role}</Badge>}
        {page.paperVersion !== null && <span>Paper version {page.paperVersion}</span>}
        {page.printedPage !== null && page.printedPage !== page.copyPage && <span>(printed as page {page.printedPage})</span>}
        {flags.length > 0 && <Badge tone="amber">{flags.join(", ").replace(/_/g, " ")}</Badge>}
        {page.flags.includes("layout_unexpected") && <Badge tone="amber">Layout unexpected</Badge>}
      </div>
      <div className="grid gap-4 lg:grid-cols-2">
        <PageViewer
          path={page.fullPath}
          label={`${label}, full page`}
          areas={page.areas}
          caption={
            <>
              Full page, as scanned or photographed. Staff only: it shows the candidate&apos;s name.
              {page.areas.length > 0 && " Dark boxes are the areas staff hid."}
            </>
          }
        />
        {page.markingPath ? (
          <PageViewer
            path={page.markingPath}
            label={`${label}, marking picture`}
            caption={
              <>
                Marking picture: what markers see, with the name hidden. {turnText(page.turn)}
                {pending && " A new one is being made."}
              </>
            }
          />
        ) : (
          <div className="flex min-h-48 items-center justify-center rounded border border-dashed border-slate-300 bg-slate-50 p-4 text-center text-sm text-slate-600">
            {pending
              ? "The marking picture is being made. Refresh the page in a minute."
              : page.role === "answer" || page.role === "spare" || page.extra
                ? "No marking picture yet: the name could not be hidden on this page. Resolve it in the exception queue (hide the name, then accept the page)."
                : "This page is not marked, so it has no marking picture."}
          </div>
        )}
      </div>
      {editable ? (
        <fieldset className="space-y-3 rounded border border-slate-200 p-4">
          <legend className="px-1 text-sm font-semibold text-slate-800">Change this page</legend>
          <label className="flex flex-col gap-1 text-sm">
            What to do
            <select value={tool} onChange={(e) => setTool(e.target.value as PageTool)} className={`${FIELD} max-w-sm`}>
              {tools.map((t) => (
                <option key={t} value={t}>
                  {TOOL_LABEL[t]}
                </option>
              ))}
            </select>
          </label>
          {tool === "remove" ? (
            <p className="text-sm text-slate-600">
              The script gets a new version without this page (the earlier versions and the page itself are kept). Use it for a page of
              another paper version, or one that does not belong here.
            </p>
          ) : (
            <p className="text-sm text-slate-600">
              The full page stays as it was stored. Turning a page takes its marking picture away until it is made again: a page whose
              code reads upright gets one back only when it is turned back; a page without a code needs its name hidden (or &quot;no
              name&quot; said) again in the exception queue.
            </p>
          )}
          <ReasonForm
            key={`${page.pageId}|${tool}`}
            scriptId={detail.script.id}
            label={TOOL_LABEL[tool]}
            hint="3 to 300 characters, kept in the audit log"
            danger={tool === "remove"}
            build={(reason) =>
              tool === "remove"
                ? { action: "remove", copyPage: page.copyPage ?? 0, reason }
                : { action: "rotate", pageId: page.pageId, turns: tool === "right" ? 1 : tool === "left" ? -1 : 2, reason }
            }
          />
        </fieldset>
      ) : beingMarked(detail.script.state) ? (
        <p className="text-sm text-slate-600">This script is being marked. To change its pages, take it back from the markers.</p>
      ) : (
        <p className="text-sm text-slate-600">This script is {stateText(detail.script.state, detail.script.stateReason).toLowerCase()}, so its pages can no longer change.</p>
      )}
    </div>
  );
}

/** A script with the markers is taken back to change its pages; a taken-back script is handed back once it is verified
 * and its marking pictures are made. */
function MarkingCard({ detail }: { detail: ScriptDetail }) {
  const s = detail.script;
  if (s.takenBackAt) {
    const why = takenBackReasonText(s.takenBackReason);
    return (
      <Card title="Marking">
        <div className="space-y-3">
          <p className="text-sm text-slate-700">
            Taken back from the markers on {formatLondon(s.takenBackAt)}.{why ? ` ${why.endsWith(".") ? why : `Reason: ${why}.`}` : ""}
          </p>
          <ReasonForm
            scriptId={s.id}
            label="Hand back to markers"
            hint="optional, 3 to 300 characters, kept in the audit log"
            optional
            blocked={handBackBlocked(detail)}
            build={(reason) => ({ action: "hand_back", reason })}
          />
        </div>
      </Card>
    );
  }
  if (!beingMarked(s.state)) return null;
  return (
    <Card title="Marking">
      <div className="space-y-3">
        <p className="text-sm text-slate-700">This script is being marked. To change its pages, take it back from the markers.</p>
        <ReasonForm
          scriptId={s.id}
          label="Take back from markers"
          hint="3 to 300 characters, kept in the audit log"
          build={(reason) => ({ action: "take_back", reason })}
        />
      </div>
    </Card>
  );
}

/** One script for staff: what it is, its pages (full and marking pictures side by side, with the page tools), the
 * files they came from (process one again), its versions, its exceptions, the centre's custody and what staff did. */
export function ScriptDetailView({ detail }: { detail: ScriptDetail }) {
  const s = detail.script;
  const [selected, setSelected] = useState<string | null>(detail.pages[0]?.pageId ?? null);
  const page = detail.pages.find((p) => p.pageId === selected) ?? detail.pages[0] ?? null;
  const uploadOf = (p: DetailPage) => detail.uploads.find((u) => u.id === p.uploadId) ?? null;
  const open = detail.exceptions.filter((e) => e.state === "open");

  return (
    <div className="space-y-5">
      <Card>
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div className="space-y-1">
            <h2 className="flex flex-wrap items-center gap-2 text-lg font-semibold text-slate-900">
              {s.number}
              <Badge tone={s.source === "home" ? "blue" : "slate"}>{SOURCE_LABEL[s.source]}</Badge>
              <Badge tone={STATE_TONE[s.state]}>{stateText(s.state, s.stateReason)}</Badge>
            </h2>
            <p className="text-sm text-slate-700">{candidateText(detail.candidate)}</p>
            <p className="text-sm text-slate-600">
              {s.exam ? `${s.exam.title}${s.exam.paper ? ` (${s.exam.paper})` : ""}` : ""} · Version {s.version} ·{" "}
              {s.complete ? "Complete" : "Not complete"}
              {s.late ? ` · Late${s.lateDecision === "accept" ? " (accepted)" : s.lateDecision === "reject" ? " (not marked)" : ""}` : ""}
              {s.receivedAt ? ` · Received ${formatLondon(s.receivedAt)}` : " · Not received yet"}
            </p>
            {s.bookingStatus && !["paid", "cancel_requested"].includes(s.bookingStatus) && (
              <p className="text-sm text-amber-800">The booking is {s.bookingStatus.replace(/_/g, " ")}.</p>
            )}
          </div>
          <div className="space-y-1 text-sm">
            {open.length > 0 && (
              <Link href={`/admin/scripts/exceptions${s.exam ? `?exam=${s.exam.id}` : ""}`} className="block text-blue-700 underline">
                {open.length} open {open.length === 1 ? "problem" : "problems"} in the exception queue
              </Link>
            )}
            {s.picturesToCheck > 0 && (
              <Link
                href={`/admin/scripts/exceptions?tab=checks${s.exam ? `&exam=${s.exam.id}` : ""}`}
                data-testid="pictures-to-check"
                className="block text-blue-700 underline"
              >
                {picturesToCheckText(s.picturesToCheck)}
              </Link>
            )}
          </div>
        </div>
      </Card>

      <MarkingCard detail={detail} />

      <Card title="Pages">
        {detail.pages.length === 0 ? (
          <p className="text-sm text-slate-600">This script shows no pages.</p>
        ) : (
          <div className="grid gap-4 lg:grid-cols-[14rem_1fr]">
            <ul className="space-y-1" aria-label="Pages of the script">
              {detail.pages.map((p) => (
                <li key={p.pageId}>
                  <button
                    type="button"
                    aria-current={page?.pageId === p.pageId ? "true" : undefined}
                    onClick={() => setSelected(p.pageId)}
                    className={`w-full rounded border px-3 py-2 text-left text-sm ${page?.pageId === p.pageId ? "border-blue-600 bg-blue-50 text-blue-900" : "border-slate-200 hover:bg-slate-50"}`}
                  >
                    <span className="font-medium">{pageLabel(p)}</span>
                    <span className="block text-xs text-slate-500">
                      {p.role ? (ROLE_LABEL[p.role] ?? p.role) : "No code"}
                      {p.markingPath ? "" : " · no marking picture"}
                      {p.turn ? " · turned" : ""}
                    </span>
                  </button>
                </li>
              ))}
            </ul>
            {page && <PageView key={page.pageId} detail={detail} page={page} upload={uploadOf(page)} />}
          </div>
        )}
      </Card>

      <Card title="Files">
        {detail.uploads.length === 0 ? (
          <p className="text-sm text-slate-600">No files.</p>
        ) : (
          <ul className="divide-y divide-slate-100">
            {detail.uploads.map((u) => (
              <li key={u.id} className="space-y-2 py-3 text-sm">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="font-medium text-slate-900">
                    {u.source === "centre" ? `Scan batch ${u.batchNumber ?? ""}` : `Handed in from home (submission ${u.submissionSeq ?? "?"})`}
                  </span>
                  <Badge tone={u.state === "failed" ? "red" : u.state === "processed" ? "green" : "blue"}>{u.state}</Badge>
                  <span className="text-slate-600">
                    {u.pages} {u.pages === 1 ? "page" : "pages"}
                    {u.createdAt ? ` · added ${formatLondon(u.createdAt)}` : ""}
                  </span>
                </div>
                {u.jobs.length > 0 && <p className="text-xs text-slate-500">Latest: {jobText(u.jobs[0])}</p>}
                {reprocessable(u, s.state) && reprocessRefusal(u, s.state) && (
                  <div className="rounded border border-slate-200 p-3">
                    <button type="button" className="cursor-not-allowed text-sm font-medium text-slate-400" disabled aria-describedby={`no-reprocess-${u.id}`}>
                      Process this file again
                    </button>
                    <p id={`no-reprocess-${u.id}`} className="mt-2 text-sm text-slate-600">
                      {reprocessRefusal(u, s.state)}
                    </p>
                  </div>
                )}
                {reprocessable(u, s.state) && !reprocessRefusal(u, s.state) && (
                  <details className="rounded border border-slate-200 p-3">
                    <summary className="cursor-pointer text-sm font-medium text-blue-800">Process this file again</summary>
                    <p className="my-2 text-sm text-slate-600">
                      The file is read again from the original and its pages are replaced; turns of its pages are lost. This is not allowed
                      once staff have worked on its pages (a hidden name, a confirmation, a page placed, moved or taken out, or a page the
                      family added), because it would undo that work.
                    </p>
                    <ReasonForm
                      scriptId={s.id}
                      label="Process the file again"
                      hint="3 to 300 characters, kept in the audit log"
                      build={(reason) => ({ action: "reprocess", uploadId: u.id, reason })}
                    />
                  </details>
                )}
              </li>
            ))}
          </ul>
        )}
      </Card>

      <Card title="Versions">
        <div className="overflow-x-auto">
          <table className="w-full text-left text-sm">
            <caption className="sr-only">Versions of the script</caption>
            <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
              <tr>
                {["Version", "When", "Why", "By", "Pages"].map((h) => (
                  <th key={h} scope="col" className="py-2 pr-4 font-medium">
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {detail.versions.map((v) => (
                <tr key={v.version} className="border-b border-slate-100 last:border-0">
                  <td className="py-2 pr-4">{v.version}</td>
                  <td className="py-2 pr-4">{v.createdAt ? formatLondon(v.createdAt) : ""}</td>
                  <td className="py-2 pr-4">{versionReason(v.reason)}</td>
                  <td className="py-2 pr-4">{v.by ?? (v.submissionSeq !== null ? `Family (submission ${v.submissionSeq})` : "System")}</td>
                  <td className="py-2 pr-4">{v.pages.join(", ") || "None"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Card>

      <Card title="Exceptions">
        {detail.exceptions.length === 0 ? (
          <p className="text-sm text-slate-600">No exceptions.</p>
        ) : (
          <ul className="divide-y divide-slate-100">
            {detail.exceptions.map((e) => (
              <li key={e.id} className="py-2 text-sm">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="font-medium text-slate-900">{KIND_LABEL[e.kind]}</span>
                  <Badge tone={e.state === "open" ? "amber" : "green"}>{e.state === "open" ? "Open" : resolutionLabel(e.resolved?.resolution ?? null)}</Badge>
                  <span className="text-xs text-slate-500">{formatLondon(e.createdAt)}</span>
                </div>
                <p className="text-slate-700">{foundInWords(e).join(" ")}</p>
                {e.resolved?.reason && <p className="text-xs text-slate-500">Reason: {e.resolved.reason}</p>}
              </li>
            ))}
          </ul>
        )}
      </Card>

      {s.source === "centre" && (
        <Card title="Custody">
          {detail.custody.length === 0 ? (
            <p className="text-sm text-slate-600">No custody recorded for this centre yet.</p>
          ) : (
            <ol className="space-y-1 text-sm">
              {detail.custody.map((c, i) => (
                <li key={i}>
                  <span className="font-medium capitalize">{c.step.replace(/_/g, " ")}</span>
                  {c.at ? ` · ${formatLondon(c.at)}` : ""} · {c.location}
                  {c.manifest ? ` · manifest ${c.manifest}` : ""}
                  {c.fromName || c.toName ? ` · ${c.fromName ?? "?"} to ${c.toName ?? "?"}` : ""}
                  {c.byName ? ` · recorded by ${c.byName}` : ""}
                  {c.note ? ` · ${c.note}` : ""}
                </li>
              ))}
            </ol>
          )}
        </Card>
      )}

      <Card title="What staff did">
        {detail.actions.length === 0 ? (
          <p className="text-sm text-slate-600">Nothing yet.</p>
        ) : (
          <ul className="space-y-1 text-sm">
            {detail.actions.map((a, i) => (
              <li key={i}>
                <span className="font-medium">{actionText(a.action)}</span>
                {a.at ? ` · ${formatLondon(a.at)}` : ""}
                {a.by ? ` · ${a.by}` : ""}
                {a.reason ? ` · “${a.reason}”` : ""}
              </li>
            ))}
          </ul>
        )}
      </Card>

      {voidable(s.state) && (
        <Card title="Void this script">
          <p className="mb-3 text-sm text-slate-600">
            A void script is not marked and stays visible as void. Use it for malpractice or a script that must not count. This cannot be
            undone here.
          </p>
          <ReasonForm scriptId={s.id} label="Void the script" hint="3 to 300 characters, kept in the audit log" danger build={(reason) => ({ action: "void", reason })} />
        </Card>
      )}
    </div>
  );
}
