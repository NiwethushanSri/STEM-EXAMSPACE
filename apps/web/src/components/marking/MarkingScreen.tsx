"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useEffectEvent, useId, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore, type Dispatch, type MouseEvent, type ReactNode, type RefObject, type SetStateAction } from "react";
import { markingScreenMessageFor, type Json } from "@stem/shared";
import { giveBack, nextScript } from "@/app/marking/actions";
import { MarkPanel, focusMarkBox } from "@/components/marking/MarkPanel";
import { PageCanvas } from "@/components/marking/PageCanvas";
import { QuestionList } from "@/components/marking/QuestionList";
import { FOCUS, type ScreenTool } from "@/components/marking/ToolBar";
import { reasonProblem } from "@/lib/exception-queue";
import { keyAction, type Action } from "@/lib/marking-keys";
import { holdText, nextScriptTarget, parseMyWork } from "@/lib/marking-lists";
import { nextQuestionId, unitTotal, validMark } from "@/lib/marking-marks";
import { act, applyOps, fromServer, redo, undo, type MarkingState, type Op, type SavedAnnotation } from "@/lib/marking-model";
import { ZOOM_MAX, ZOOM_MIN, isPhone } from "@/lib/marking-pointer";
import { createSaveQueue, restorePending, type SaveQueue, type SaveResult, type SaveStatus } from "@/lib/marking-save";
import {
  ACCESS_TICK_MS,
  accessCheckDue,
  accessCheckOutcome,
  firstLeaf,
  labelList,
  parseOpened,
  questionPageIndexes,
  zoomStepIn,
  zoomStepOut,
  type OpenedPiece,
  type ScreenQuestion,
} from "@/lib/marking-screen";
import { createClient } from "@/lib/supabase/client";

/** Marking pictures and the mark scheme PDF are shown through signed links that last this long (seconds). */
export const MARKING_URL_SECONDS = 120;

const BUTTON = `inline-flex min-h-11 items-center justify-center rounded px-4 text-sm font-medium disabled:cursor-not-allowed disabled:opacity-50 ${FOCUS}`;
const PRIMARY = `${BUTTON} bg-blue-600 text-white hover:bg-blue-700`;
const QUIET = `${BUTTON} border border-slate-300 bg-white text-slate-900 hover:bg-slate-50`;

const SAVE_WORDS: Partial<Record<SaveStatus, string>> = {
  saved: "Saved",
  saving: "Saving…",
  offline: "Not saved: no connection. Your work is kept on this screen and will be sent when you are back online.",
};
/** Save stops that take the page away until the marker goes back (or the lead releases the hold). */
const COVER_CODES: Partial<Record<SaveStatus, string>> = {
  on_hold: "on_hold",
  pictures_updating: "pictures_updating",
  hold_expired: "hold_expired",
  closed: "marking_closed",
};

/** The longest a save is waited for before the piece leaves the screen; what is not sent by then stays stored. */
const SAVE_FIRST_MS = 3000;
/** Where the questions drawer gives way to the questions column (Tailwind's min-[1200px]). */
const WIDE = "(min-width: 1200px)";
const NEXT_FAILED = "Could not find a script. Check your connection and try again.";
/** A picture's link older than this is asked for again before the picture is shown (links last MARKING_URL_SECONDS). */
const LINK_FRESH_MS = (MARKING_URL_SECONDS - 30) * 1000;
const NO_ANNOTATIONS: SavedAnnotation[] = [];
const NO_URLS: Record<string, string> = {};

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj | null => (v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : null);

const subscribeResize = (cb: () => void) => {
  window.addEventListener("resize", cb);
  return () => window.removeEventListener("resize", cb);
};
const noSubscribe = () => () => {};

/**
 * The marking screen for one piece, full screen with no side menu (Ruling R2). On a phone (under 600 px wide) it says
 * only that marking needs a computer or an iPad, and opens nothing. Otherwise it opens the piece (marking_unit_open)
 * and shows three areas: the questions, the page, and the mark panel (from 600 to 1199 px the questions open from a
 * button). Every change goes through the marking model and the save queue; nothing on it names the candidate.
 */
export function MarkingScreen({ unitId }: { unitId: string }) {
  const width = useSyncExternalStore(subscribeResize, () => window.innerWidth, () => null);
  // Once opened on a big enough screen the piece stays open (hidden) if the window is made narrow, so nothing is lost.
  const [opened, setOpened] = useState(false);
  if (width !== null && !isPhone(width) && !opened) setOpened(true);
  const [visit, setVisit] = useState(0);
  const refusedPaths = useRef(new Set<string>());
  // Next.js keeps a page it leaves, hidden (Activity, with Cache Components), and can show it again (Back). The piece
  // is then opened afresh, with the server's marks and rev and what is stored unsent, never the copy kept from before.
  useLayoutEffect(() => () => setVisit((v) => v + 1), []);
  if (width === null) return <p className="p-6 text-sm text-slate-600">Opening the script...</p>;
  const phone = isPhone(width);
  return (
    <>
      {phone && (
        <main className="mx-auto flex min-h-dvh max-w-md flex-col justify-center gap-4 p-6">
          <h1 className="text-base font-semibold text-slate-900">Marking needs a computer or an iPad.</h1>
          <Link href="/marking" className={`${QUIET} self-start`}>
            Back to Marking
          </Link>
        </main>
      )}
      {opened && <Workspace key={visit} unitId={unitId} active={!phone} onReload={() => setVisit((v) => v + 1)} refusedPaths={refusedPaths} />}
    </>
  );
}

/** Opens the piece, then hands it to the desk; a refusal (or a failure) is said in plain words. */
function Workspace({ unitId, active, onReload, refusedPaths }: { unitId: string; active: boolean; onReload: () => void; refusedPaths: RefObject<Set<string>> }) {
  const [result, setResult] = useState<ReturnType<typeof parseOpened> | null>(null);
  useEffect(() => {
    let live = true;
    createClient()
      .rpc("marking_unit_open", { p_unit: unitId })
      .then(
        ({ data, error }) => live && setResult(error ? { ok: false, code: "internal" } : parseOpened(data)),
        () => live && setResult({ ok: false, code: "internal" }),
      );
    return () => {
      live = false;
    };
  }, [unitId]);

  const frame = (body: ReactNode) => (
    <main className={`mx-auto flex min-h-dvh max-w-lg flex-col justify-center gap-4 p-6 ${active ? "" : "hidden"}`}>
      <h1 className="sr-only">Marking</h1>
      {body}
      <div className="flex flex-wrap gap-2">
        <Link href="/marking" className={QUIET}>
          Back to Marking
        </Link>
      </div>
    </main>
  );
  if (!result) return frame(<p className="text-sm text-slate-700">Opening the script...</p>);
  if (!result.ok) {
    return frame(
      <>
        <p role="alert" className="text-base font-medium text-slate-900">
          {markingScreenMessageFor(result.code)}
        </p>
        {result.code === "internal" && (
          <button type="button" className={`${QUIET} self-start`} onClick={onReload}>
            Try again
          </button>
        )}
      </>,
    );
  }
  return <Desk piece={result.piece} active={active} onReload={onReload} refusedPaths={refusedPaths} />;
}

type QueueHooks = {
  markingId: string;
  rev: RefObject<number>;
  last: RefObject<Obj | null>;
  setStatus: Dispatch<SetStateAction<SaveStatus>>;
  setHoldUntil: Dispatch<SetStateAction<string | null>>;
  onReasonRequired: () => void;
  /** The refusal that stopped the queue, in plain words. */
  onRefused: (message: string) => void;
};

/**
 * The save queue of one marking at `atRev`. Its send throws on a network, PostgREST, server or sign-in error (the
 * queue tries again) and otherwise returns marking_save's answer; any refusal is final and stops the queue.
 */
function queueAt(atRev: number, h: QueueHooks): SaveQueue {
  const send = async (rev: number, ops: Op[], activeSeconds: number, reason?: string): Promise<SaveResult> => {
    const { data, error } = await createClient().rpc("marking_save", {
      p_marking: h.markingId,
      p_rev: rev,
      p_ops: ops as unknown as Json,
      p_active_seconds: activeSeconds,
      p_reason: reason,
    });
    if (error) throw new Error(error.message);
    const d = obj(data);
    if (!d) throw new Error("no answer");
    h.last.current = d;
    if (d.ok === true) {
      if (typeof d.rev !== "number") throw new Error("no rev");
      h.rev.current = d.rev;
      h.setHoldUntil(typeof d.hold_until === "string" ? d.hold_until : null);
      return { ok: true, rev: d.rev };
    }
    return {
      ok: false,
      code: typeof d.code === "string" ? d.code : "internal",
      reason: typeof d.reason === "string" ? d.reason : undefined,
      rev: typeof d.rev === "number" ? d.rev : undefined,
    };
  };
  return createSaveQueue({
    markingId: h.markingId,
    rev: atRev,
    send,
    onStatus: (s, code) => {
      h.setStatus(s);
      if (s === "reason_required") h.onReasonRequired();
      if (s === "refused") h.onRefused(markingScreenMessageFor(code ?? null, typeof h.last.current?.reason === "string" ? h.last.current.reason : null));
    },
  });
}

type DialogKind = "name" | "give_back" | "reason" | null;

function Desk({ piece, active, onReload, refusedPaths }: { piece: OpenedPiece; active: boolean; onReload: () => void; refusedPaths: RefObject<Set<string>> }) {
  const router = useRouter();
  const markingId = piece.marking.id;
  const readOnly = piece.unit.closed;
  const { questions, pages } = piece;
  const leaves = questions.filter((q) => q.leaf);

  const [boot] = useState(() => {
    const base = fromServer(piece.saved);
    const pending = readOnly ? [] : restorePending(markingId, piece.marking.rev);
    const state = pending.length > 0 ? applyOps(base, pending) : base;
    const first = leaves.find((q) => !state.marks[q.id] || (state.marks[q.id].mark === null && !state.marks[q.id].na)) ?? leaves[0] ?? null;
    return { state, pending, first };
  });
  const [model, setModel] = useState<MarkingState>(boot.state);
  const modelRef = useRef(boot.state);
  const [status, setStatus] = useState<SaveStatus>(boot.pending.length > 0 ? "saving" : "saved");
  const [submitted, setSubmitted] = useState(piece.marking.status === "submitted");
  const [refusal, setRefusal] = useState<string | null>(null);
  const [holdUntil, setHoldUntil] = useState(piece.unit.holdUntil);
  const [now, setNow] = useState<number | null>(null);
  const [currentId, setCurrentId] = useState<string | null>(boot.first?.id ?? null);
  const [pageIndex, setPageIndex] = useState(() => questionPageIndexes(boot.first ?? undefined, questions, pages)[0] ?? 0);
  const [tool, setTool] = useState<ScreenTool>("select");
  const [zoom, setZoom] = useState(1);
  const [fingerDraw, setFingerDraw] = useState(false);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [listOpen, setListOpen] = useState(false);
  /** What had focus when the questions drawer opened; it gets focus back when the drawer closes. */
  const listOpener = useRef<HTMLElement | null>(null);
  const [dialog, setDialog] = useState<DialogKind>(null);
  /** Submit is running: input stops until it answers (the ref stops it at once, before the next render). */
  const [busy, setBusy] = useState(false);
  const submitting = useRef(false);
  /** A refusal of Submit that takes the page away (a hold, marking closed, the script no longer the marker's). */
  const [stop, setStop] = useState<{ code: string; reason?: string } | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [schemeMessage, setSchemeMessage] = useState<string | null>(null);
  const [urls, setUrls] = useState<Record<string, string>>({});
  const [failed, setFailed] = useState<Record<string, boolean>>({});
  const tries = useRef<Record<string, number>>({});
  /** When each picture's link was signed, and the pictures whose link is being asked for. */
  const signedAt = useRef<Record<string, number>>({});
  const asking = useRef(new Set<string>());
  const queue = useRef<SaveQueue | null>(null);
  const rev = useRef(piece.marking.rev);
  const last = useRef<Obj | null>(null);
  const touchDevice = useSyncExternalStore(noSubscribe, () => navigator.maxTouchPoints > 0, () => false);

  // A change after submit asks for its reason, unless another box is open (its banner offers the reason then).
  const askReason = () => setDialog((d) => d ?? "reason");
  const hooksFor = (): QueueHooks => ({ markingId, rev, last, setStatus, setHoldUntil, onReasonRequired: askReason, onRefused: setRefusal });

  // The save queue lives as long as the screen; operations left from an earlier visit at this rev are sent first.
  useEffect(() => {
    if (readOnly) return;
    const q = queueAt(piece.marking.rev, { markingId, rev, last, setStatus, setHoldUntil, onReasonRequired: () => setDialog((d) => d ?? "reason"), onRefused: setRefusal });
    queue.current = q;
    if (boot.pending.length > 0) q.push(boot.pending);
    // The queue in use (Submit starts a new one) warns before the tab closes with changes not yet sent.
    const leaving = (e: BeforeUnloadEvent) => {
      if ((queue.current?.pending() ?? 0) > 0) e.preventDefault();
    };
    window.addEventListener("beforeunload", leaving);
    return () => {
      window.removeEventListener("beforeunload", leaving);
      q.dispose();
      queue.current?.dispose();
      queue.current = null;
    };
  }, [readOnly, markingId, piece.marking.rev, boot.pending]);

  // The clock for the hold line.
  useEffect(() => {
    const tick = () => setNow(Date.now());
    const first = setTimeout(tick, 0);
    const every = setInterval(tick, 30_000);
    return () => {
      clearTimeout(first);
      clearInterval(every);
    };
  }, []);

  const page = pages[pageIndex] ?? null;
  const current = questions.find((q) => q.id === currentId) ?? null;
  const entry = current ? model.marks[current.id] : undefined;
  const totals = unitTotal(
    questions.map((q) => ({ id: q.id, parent_id: q.parentId, label: q.label, max_mark: q.maxMark, option_group_id: q.optionGroupId })),
    model.marks,
    piece.optionGroups,
    piece.unit.groupLabel === null,
  );
  const missing = totals.missing.map((id) => questions.find((q) => q.id === id)?.label ?? "");
  const coverCode = stop?.code ?? COVER_CODES[status] ?? null;
  /** The page is taken away (a hold, new pictures, the hold ended, marking closed): no picture is shown or asked for. */
  const covered = readOnly || coverCode !== null;
  const stale = status === "stale";
  const stopped = busy || covered || stale || status === "refused" || status === "reason_required";
  const pageId = page?.pageId ?? null;
  const pageAnnotations = useMemo(() => (pageId ? model.annotations.filter((a) => a.page_id === pageId) : NO_ANNOTATIONS), [model.annotations, pageId]);
  const questionPages = pagesFor(current, questions, pages);

  // ---------------------------------------------------------------------------------------------
  // Pictures: signed links for the marking pictures marking_unit_open returned, and no other, asked for when the page
  // is shown and when its thumbnail appears (a link older than LINK_FRESH_MS is asked for again, and the old one is
  // not shown). A refused link means the picture may have changed: the piece is opened again (once per picture).
  // Under a cover, and read only after marking closed (Ruling R11): none.
  // ---------------------------------------------------------------------------------------------
  const sign = (path: string) => {
    if (asking.current.has(path)) return;
    asking.current.add(path);
    const onSigned = () => {
      signedAt.current[path] = Date.now();
    };
    void signPicture(path, { setUrls, setFailed, refusedPaths, onReload, onSigned }).finally(() => asking.current.delete(path));
  };
  const showPicture = (path: string | null) => {
    if (!path || covered) return;
    const at = signedAt.current[path];
    if (at !== undefined && Date.now() - at < LINK_FRESH_MS) return;
    if (at !== undefined) {
      delete signedAt.current[path];
      setUrls((m) => withoutKey(m, path));
    }
    sign(path);
  };
  const showShownPicture = useEffectEvent(() => showPicture(page?.markingPath ?? null));
  useEffect(() => {
    showShownPicture();
  }, [page?.markingPath, covered]);

  // A page withdrawn while the marker only reads (another marker reported a name, staff pressed "A name still shows",
  // the hold ended) must not stay on screen until their next save. About every minute while the screen is in view (due
  // 55 seconds after the last check, looked at every 15 seconds: at most 70 seconds apart), the link of the shown
  // picture is asked for again: the storage rule answers for the piece as it is now. Given, nothing
  // changes on screen. Refused, the picture is taken off at once and the piece is asked for again (marking_unit_open):
  // its refusal becomes the cover, in its own words; if the piece is still the marker's (the picture itself changed),
  // it is opened afresh.
  /** When the last check ran (the screen's opening counts as one: the piece was just read). */
  const lastAccessCheck = useRef<number | null>(null);
  const checkingAccess = useRef(false);
  const checkAccess = useEffectEvent(async () => {
    const path = page?.markingPath ?? null;
    const now = Date.now();
    if (checkingAccess.current || !active) return;
    if (!path || !accessCheckDue({ visible: document.visibilityState === "visible", covered, path, lastAt: lastAccessCheck.current ?? now, now })) return;
    checkingAccess.current = true;
    lastAccessCheck.current = now;
    try {
      const signed = await createClient().storage.from("script-pages").createSignedUrl(path, MARKING_URL_SECONDS);
      const status = typeof signed.error?.status === "number" ? signed.error.status : null;
      if (accessCheckOutcome({ signed: !signed.error && !!signed.data?.signedUrl, status }) !== "gone") return;
      delete signedAt.current[path];
      setUrls((m) => withoutKey(m, path));
      setFailed((m) => ({ ...m, [path]: true }));
      const again = await createClient().rpc("marking_unit_open", { p_unit: piece.unit.id });
      const answer = again.error ? null : parseOpened(again.data);
      if (answer && !answer.ok) setStop({ code: answer.code });
      else onReload();
    } catch {
      // No connection: nothing is known, and the next check asks again.
    } finally {
      checkingAccess.current = false;
    }
  });
  useEffect(() => {
    lastAccessCheck.current = Date.now();
    const every = setInterval(() => void checkAccess(), ACCESS_TICK_MS);
    const onVisible = () => void checkAccess();
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      clearInterval(every);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, []);

  // ---------------------------------------------------------------------------------------------
  // Changes: each goes through the model (with its undo) and the save queue.
  // ---------------------------------------------------------------------------------------------
  const commit = (next: { state: MarkingState; send: Op[] }) => {
    if (next.send.length === 0) return;
    modelRef.current = next.state;
    setModel(next.state);
    queue.current?.push(next.send);
  };
  /** Input has stopped, or Submit is running: nothing changes. */
  const locked = () => stopped || submitting.current;
  const apply = (ops: Op[]) => {
    if (!locked()) commit(act(modelRef.current, ops));
  };
  const setMark = (questionId: string, mark: number | null, na: boolean) => {
    const prev = modelRef.current.marks[questionId] ?? { mark: null, na: false };
    if (prev.mark === mark && prev.na === na) return;
    apply([{ op: "mark", question_id: questionId, mark, na }]);
  };
  const onUndo = () => {
    if (!locked()) commit(undo(modelRef.current));
  };
  const onRedo = () => {
    if (!locked()) commit(redo(modelRef.current));
  };
  const deleteSelected = () => {
    if (!selectedId) return;
    apply([{ op: "ann_del", id: selectedId }]);
    setSelectedId(null);
  };

  const showPage = (i: number) => {
    const next = Math.max(0, Math.min(pages.length - 1, i));
    if (next !== pageIndex) setSelectedId(null);
    // Its link is asked for now, before the page is drawn, so one that has run out is never shown.
    showPicture(pages[next]?.markingPath ?? null);
    setPageIndex(next);
  };
  const openList = () => {
    listOpener.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    setListOpen(true);
  };
  /** Closes the questions drawer (if open) and gives focus back to what opened it. */
  const closeList = () => {
    if (!listOpen) return;
    setListOpen(false);
    listOpener.current?.focus();
    listOpener.current = null;
  };
  // At 1200 px and wider the drawer is hidden (the questions have their own column), so it is closed: an open drawer
  // that cannot be seen would keep every shortcut off.
  useEffect(() => {
    const wide = window.matchMedia(WIDE);
    const onChange = () => {
      if (wide.matches) setListOpen(false);
    };
    wide.addEventListener("change", onChange);
    return () => wide.removeEventListener("change", onChange);
  }, []);
  /** A question chosen in the list (or with the keys): its first part to mark is current, and its first page shows. */
  const chooseQuestion = (q: ScreenQuestion) => {
    const leaf = firstLeaf(q, questions);
    setCurrentId(leaf.id);
    const first = pagesFor(q, questions, pages)[0];
    if (first !== undefined) showPage(first);
    closeList();
  };

  const run = (a: Action) => {
    const leaf = current;
    const max = leaf?.maxMark ?? 0;
    const step = leaf?.step ?? 1;
    switch (a.type) {
      case "mark":
        if (leaf && validMark(a.value, max, step)) setMark(leaf.id, a.value, false);
        return;
      case "focus_mark":
        focusMarkBox();
        return;
      case "half": {
        if (!leaf) return;
        const value = (entry && !entry.na && entry.mark !== null ? entry.mark : 0) + 0.5;
        if (validMark(value, max, step)) setMark(leaf.id, value, false);
        return;
      }
      case "nr":
        if (leaf) setMark(leaf.id, null, !entry?.na);
        return;
      case "tool":
        setTool(a.tool);
        return;
      case "prev_question":
      case "next_question": {
        if (!leaf) return;
        const id = nextQuestionId(leaves, leaf.id, a.type === "next_question" ? 1 : -1);
        const q = questions.find((x) => x.id === id);
        if (q) chooseQuestion(q);
        return;
      }
      case "prev_page":
        return showPage(pageIndex - 1);
      case "next_page":
        return showPage(pageIndex + 1);
      case "zoom_in":
        return setZoom((z) => zoomStepIn(z));
      case "zoom_out":
        return setZoom((z) => zoomStepOut(z));
      case "fit_width":
        return setZoom(1);
      case "undo":
        return onUndo();
      case "redo":
        return onRedo();
      case "delete":
        return deleteSelected();
    }
  };

  // Keyboard on the whole window, through keyAction. Ctrl+Z inside a text box is the box's own undo.
  const onKey = useEffectEvent((e: KeyboardEvent) => {
    if (!active || dialog !== null || e.defaultPrevented) return;
    // The questions drawer takes the keys while it is open: Escape closes it, nothing else is a shortcut.
    if (listOpen) {
      if (e.key === "Escape") {
        e.preventDefault();
        closeList();
      }
      return;
    }
    // While Submit runs nothing changes, and the keys do nothing.
    if (busy || submitting.current) return;
    const t = e.target instanceof HTMLElement ? e.target : null;
    const typing = !!t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.tagName === "SELECT" || t.isContentEditable);
    const a = keyAction(
      { key: e.key, ctrl: e.ctrlKey, meta: e.metaKey, shift: e.shiftKey, alt: e.altKey, typing },
      { max: current?.maxMark ?? 0, step: current?.step ?? 1 },
    );
    if (!a) return;
    if (typing && (a.type === "undo" || a.type === "redo")) return;
    // Enter on a focused button or link is that control's own.
    if (e.key === "Enter" && t?.closest("button, a, [role='button']")) return;
    // A digit for a question out of more than 9 moves to the mark box and is typed there.
    if (a.type !== "focus_mark") e.preventDefault();
    run(a);
  });
  useEffect(() => {
    const h = (e: KeyboardEvent) => onKey(e);
    window.addEventListener("keydown", h);
    return () => window.removeEventListener("keydown", h);
  }, []);

  // ---------------------------------------------------------------------------------------------
  // Pictures.
  // ---------------------------------------------------------------------------------------------
  // A picture that fails to load is asked for once more; a load counts as a fresh start.
  const pictureError = (path: string) => {
    const n = (tries.current[path] ?? 0) + 1;
    tries.current[path] = n;
    if (n === 1) sign(path);
    else setFailed((m) => ({ ...m, [path]: true }));
  };
  const pictureLoaded = (path: string) => {
    tries.current[path] = 0;
  };
  const retryPicture = (path: string) => {
    tries.current[path] = 0;
    setFailed((m) => ({ ...m, [path]: false }));
    setUrls((m) => withoutKey(m, path));
    sign(path);
  };

  const openScheme = async () => {
    if (!piece.markSchemePath) return;
    setSchemeMessage(null);
    // Opened first, on the press itself, so the browser does not block it; the link follows when signed.
    const tab = window.open("", "_blank");
    const { data, error } = await createClient().storage.from("mark-schemes").createSignedUrl(piece.markSchemePath, MARKING_URL_SECONDS);
    if (error || !data?.signedUrl) {
      tab?.close();
      setSchemeMessage("The mark scheme could not be opened. Try again.");
      return;
    }
    if (!tab) {
      setSchemeMessage("Allow pop-ups for this site to open the mark scheme.");
      return;
    }
    tab.opener = null;
    tab.location.href = data.signedUrl;
  };

  // ---------------------------------------------------------------------------------------------
  // Submit, Give back and Name visible.
  // ---------------------------------------------------------------------------------------------
  const submit = async () => {
    if (busy || stopped || missing.length > 0) return;
    // A note or mark being typed is kept first (its box saves when it loses focus), then input stops until Submit
    // answers, so no change can be made at the rev being submitted.
    if (document.activeElement instanceof HTMLElement) document.activeElement.blur();
    submitting.current = true;
    setBusy(true);
    setNotice(null);
    try {
      await submitNow();
    } finally {
      submitting.current = false;
      setBusy(false);
    }
  };
  const submitNow = async () => {
    const q = queue.current;
    if (q && !(await q.flush())) return;
    const atRev = rev.current;
    const { data, error } = await createClient().rpc("marking_submit", { p_marking: markingId, p_rev: atRev });
    const d = obj(data);
    if (error || !d) return setNotice(markingScreenMessageFor("internal"));
    if (d.ok === true && typeof d.rev === "number") {
      // Submit moves the rev on: the queue starts again from it, with no reason yet for this visit. Anything still
      // waiting in the old queue (input stops while Submit runs, so normally nothing) moves to the new one, and the
      // server asks for its reason. Its stored copy is how it moves; if that cannot be read, the piece is opened again
      // so the screen shows only what is saved.
      rev.current = d.rev;
      const waiting = q?.pending() ?? 0;
      const moved = waiting > 0 ? restorePending(markingId, atRev) : [];
      q?.dispose();
      const next = queueAt(d.rev, hooksFor());
      queue.current = next;
      setStatus("saved");
      setSubmitted(true);
      if (moved.length < waiting) return onReload();
      if (moved.length > 0) next.push(moved);
      return;
    }
    const code = typeof d.code === "string" ? d.code : "internal";
    const reason = typeof d.reason === "string" ? d.reason : undefined;
    if (code === "conflict" && (reason === "rev" || reason === undefined)) return setStatus("stale");
    if (code === "conflict" && reason === "submitted") return setNotice(markingScreenMessageFor(code, reason));
    if (code === "incomplete") {
      const labels = Array.isArray(d.missing) ? d.missing.filter((x): x is string => typeof x === "string") : [];
      return setNotice(`${markingScreenMessageFor(code)}${labels.length ? ` Still to mark: ${labelList(labels)}.` : ""}`);
    }
    if (["on_hold", "pictures_updating", "hold_expired", "marking_closed", "forbidden", "not_found"].includes(code) || code === "conflict") {
      return setStop({ code, reason });
    }
    setNotice(markingScreenMessageFor(code, reason));
  };

  /** Before the piece leaves the screen (Name visible, Give back, Next script, the link to Marking): what is waiting is
   * sent if it can be, waiting at most SAVE_FIRST_MS; anything not sent stays stored and goes when the piece is next
   * opened. */
  const saveFirst = async () => {
    const q = queue.current;
    if (!q || q.pending() === 0) return;
    let timer: ReturnType<typeof setTimeout> | undefined;
    await Promise.race([q.flush(), new Promise<void>((done) => (timer = setTimeout(done, SAVE_FIRST_MS)))]);
    clearTimeout(timer);
  };
  /** The links back to Marking save first, as Give back does (a plain click; a new tab or window is left to the browser). */
  const toMarking = (e: MouseEvent<HTMLAnchorElement>) => {
    if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    if ((queue.current?.pending() ?? 0) === 0) return;
    e.preventDefault();
    void saveFirst().then(() => router.push("/marking"));
  };
  /** Leaves for the marker home once the piece is no longer theirs; what was not saved goes with it. */
  const leave = () => {
    queue.current?.discard();
    queue.current?.dispose();
    queue.current = null;
    router.push("/marking");
  };

  const statusWords = readOnly ? "Read only" : (SAVE_WORDS[status] ?? "Not saved");
  const holdLine = !readOnly && !submitted && now !== null ? holdText(holdUntil, new Date(now)) : null;
  const canGiveBack = !readOnly && !submitted;

  const coverBody = readOnly ? (
    <p>Marking has closed for this exam, so its pages can no longer be shown. Your marks are kept as you submitted them.</p>
  ) : coverCode ? (
    <div className="space-y-4">
      <p role="alert" className="text-base font-medium text-slate-900">
        {markingScreenMessageFor(coverCode, stop?.reason)}
      </p>
      <div className="flex flex-wrap items-start gap-2">
        {/* The words say to press Next script: the hold ended, or the script is no longer the marker's. */}
        {(coverCode === "hold_expired" || (coverCode === "conflict" && stop?.reason === "set_aside")) && (
          <NextScriptButton unitId={piece.unit.id} saveFirst={saveFirst} onSame={onReload} />
        )}
        <Link href="/marking" onClick={toMarking} className={QUIET}>
          Back to Marking
        </Link>
      </div>
    </div>
  ) : null;

  const list = (
    <QuestionList
      questions={questions}
      marks={model.marks}
      currentId={currentId}
      onQuestion={chooseQuestion}
      total={totals.total}
      max={totals.max}
      pages={pages}
      pageIndex={pageIndex}
      questionPages={questionPages}
      onPage={(i) => {
        showPage(i);
        closeList();
      }}
      urls={covered ? NO_URLS : urls}
      onThumb={showPicture}
    />
  );

  return (
    <div className={`flex h-dvh flex-col bg-slate-100 text-slate-900 ${active ? "" : "hidden"}`}>
      <header className="flex flex-wrap items-center gap-x-4 gap-y-2 border-b border-slate-200 bg-white px-3 py-2">
        <Link href="/marking" aria-label="Back to Marking" onClick={toMarking} className={`${BUTTON} -ml-1 px-2 text-blue-800 hover:bg-slate-50`}>
          <svg aria-hidden="true" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M15 18l-6-6 6-6" />
          </svg>
          Marking
        </Link>
        <button type="button" aria-expanded={listOpen} onClick={openList} className={`${QUIET} min-[1200px]:hidden`}>
          Questions
        </button>
        <div className="min-w-0">
          <h1 className="truncate text-sm font-semibold text-slate-900">{piece.unit.examTitle}</h1>
          <p className="truncate text-sm text-slate-600">
            {piece.unit.paper}
            {piece.unit.groupLabel ? ` · ${piece.unit.groupLabel}` : ""}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <span className="text-sm text-slate-600">Index</span>
          <span data-testid="index-number" className="text-sm font-semibold tabular-nums text-slate-900">
            {piece.unit.indexNumber ?? "–"}
          </span>
          <span className="rounded-full border border-slate-300 bg-slate-100 px-2.5 py-0.5 text-sm font-medium text-slate-700">Name hidden</span>
        </div>
        <p data-testid="save-status" role="status" className="max-w-md text-sm text-slate-700">
          {statusWords}
        </p>
        {holdLine && <p className="text-sm text-slate-600">{holdLine}</p>}
        <div className="ml-auto flex flex-wrap items-center gap-2">
          {!readOnly && page && (
            <button type="button" className={QUIET} disabled={busy || covered} onClick={() => setDialog("name")}>
              Name visible
            </button>
          )}
          {canGiveBack && (
            <button type="button" className={QUIET} disabled={busy} onClick={() => setDialog("give_back")}>
              Give back
            </button>
          )}
          {!readOnly && !submitted && (
            <>
              {missing.length > 0 && (
                <span id="marking-missing" className="text-sm text-slate-700">
                  Still to mark: {labelList(missing)}
                </span>
              )}
              <button
                type="button"
                className={PRIMARY}
                disabled={busy || stopped || missing.length > 0}
                aria-describedby={missing.length > 0 ? "marking-missing" : undefined}
                onClick={() => void submit()}
              >
                {busy ? "Submitting…" : "Submit"}
              </button>
            </>
          )}
          {!readOnly && submitted && !covered && <NextScriptButton unitId={piece.unit.id} saveFirst={saveFirst} onSame={onReload} />}
        </div>
      </header>

      <Banners
        submitted={submitted && !readOnly}
        pagesChanged={piece.marking.pagesChanged && !submitted}
        status={status}
        refusal={status === "refused" ? refusal : null}
        notice={notice}
        onReload={onReload}
        onUndoLast={() => {
          queue.current?.discard();
          onReload();
        }}
        onReason={() => setDialog("reason")}
      />

      <div className="relative flex min-h-0 flex-1">
        <aside className="hidden w-60 shrink-0 border-r border-slate-200 bg-white min-[1200px]:block">{list}</aside>
        {listOpen && (
          <div className="fixed inset-0 z-40 flex min-[1200px]:hidden">
            <div role="dialog" aria-modal="true" aria-label="Questions" className="flex h-full w-72 max-w-[85vw] flex-col border-r border-slate-200 bg-white shadow-xl">
              <div className="flex justify-end border-b border-slate-200 p-2">
                <button type="button" autoFocus className={QUIET} onClick={closeList}>
                  Close
                </button>
              </div>
              <div className="min-h-0 flex-1">{list}</div>
            </div>
            <button type="button" aria-label="Close the questions" className={`flex-1 bg-slate-900/30 ${FOCUS}`} onClick={closeList} />
          </div>
        )}
        <main className="flex min-w-0 flex-1 flex-col">
          <PageCanvas
            page={page}
            pageIndex={pageIndex}
            pageCount={pages.length}
            onPage={showPage}
            url={!covered && page?.markingPath && !failed[page.markingPath] ? (urls[page.markingPath] ?? null) : null}
            pictureFailed={!!(page?.markingPath && failed[page.markingPath])}
            onPictureError={() => page?.markingPath && pictureError(page.markingPath)}
            onPictureLoad={() => page?.markingPath && pictureLoaded(page.markingPath)}
            onRetryPicture={() => page?.markingPath && retryPicture(page.markingPath)}
            annotations={pageAnnotations}
            selectedId={selectedId}
            onSelect={setSelectedId}
            onPut={(a: SavedAnnotation) => apply([{ op: "ann_put", ...a }])}
            onErase={(ids) => {
              apply(ids.map((id) => ({ op: "ann_del" as const, id })));
              if (selectedId && ids.includes(selectedId)) setSelectedId(null);
            }}
            questionId={current?.id ?? null}
            tool={tool}
            onTool={setTool}
            touchDevice={touchDevice}
            fingerDraw={fingerDraw}
            onFingerDraw={setFingerDraw}
            zoom={zoom}
            onZoom={(z) => setZoom(Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, z)))}
            onZoomIn={() => setZoom((z) => zoomStepIn(z))}
            onZoomOut={() => setZoom((z) => zoomStepOut(z))}
            onFitWidth={() => setZoom(1)}
            canUndo={model.undo.length > 0}
            canRedo={model.redo.length > 0}
            onUndo={onUndo}
            onRedo={onRedo}
            onDeleteSelected={deleteSelected}
            disabled={stopped}
            cover={coverBody}
          />
        </main>
        <aside className="w-[300px] shrink-0 border-l border-slate-200 bg-white min-[1200px]:w-[340px]">
          <MarkPanel
            question={current}
            entry={entry}
            onMark={(mark, na) => current && setMark(current.id, mark, na)}
            disabled={stopped}
            note={model.note}
            onNote={(text) => apply([{ op: "note", text }])}
            onOpenScheme={piece.markSchemePath ? () => void openScheme() : null}
            schemeMessage={schemeMessage}
          />
        </aside>
      </div>

      {dialog === "name" && page && (
        <NameVisibleDialog
          unitId={piece.unit.id}
          pageId={page.pageId}
          pageNumber={pageIndex + 1}
          pageCount={pages.length}
          saveFirst={saveFirst}
          onClose={() => setDialog(null)}
          onDone={leave}
        />
      )}
      {dialog === "give_back" && <GiveBackDialog unitId={piece.unit.id} saveFirst={saveFirst} onClose={() => setDialog(null)} onDone={leave} />}
      {dialog === "reason" && (
        <ReasonDialog
          onClose={() => setDialog(null)}
          onReason={(reason) => {
            setDialog(null);
            queue.current?.setReason(reason);
            queue.current?.resume();
          }}
          onUndo={() => {
            setDialog(null);
            queue.current?.discard();
            onReload();
          }}
        />
      )}
    </div>
  );
}

/** Asks for a picture's 120-second signed link. A link refused by storage (the picture may have changed, or the
 * piece is no longer the marker's to see) opens the piece again, once per picture; any other failure is shown. */
async function signPicture(
  path: string,
  h: {
    setUrls: Dispatch<SetStateAction<Record<string, string>>>;
    setFailed: Dispatch<SetStateAction<Record<string, boolean>>>;
    refusedPaths: RefObject<Set<string>>;
    onReload: () => void;
    onSigned: () => void;
  },
): Promise<void> {
  const { data, error } = await createClient().storage.from("script-pages").createSignedUrl(path, MARKING_URL_SECONDS);
  if (!error && data?.signedUrl) {
    h.onSigned();
    h.setUrls((m) => ({ ...m, [path]: data.signedUrl }));
    h.setFailed((m) => ({ ...m, [path]: false }));
    return;
  }
  const refused = typeof error?.status === "number" && error.status >= 400 && error.status < 500;
  if (refused && !h.refusedPaths.current.has(path)) {
    h.refusedPaths.current.add(path);
    h.onReload();
    return;
  }
  h.setFailed((m) => ({ ...m, [path]: true }));
}

function withoutKey<T>(m: Record<string, T>, key: string): Record<string, T> {
  if (!(key in m)) return m;
  const { [key]: _gone, ...rest } = m;
  void _gone;
  return rest;
}

/** "Next script" on the screen: the piece's exam (and question group) from marking_my_work, then marking_next, as on
 * the marker home. What is waiting is sent first if it can be. The same piece again (a hold renewed) is opened again. */
function NextScriptButton({ unitId, saveFirst, onSame }: { unitId: string; saveFirst: () => Promise<void>; onSame: () => void }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const go = async () => {
    setBusy(true);
    setMessage(null);
    // The button stays busy only while the screen moves to the next script; any failure lets it be pressed again.
    let moving = false;
    try {
      await saveFirst();
      const { data, error } = await createClient().rpc("marking_my_work", {});
      const work = error ? null : parseMyWork(data);
      if (!work) return setMessage(NEXT_FAILED);
      const target = nextScriptTarget(work, unitId);
      // Not in the list any more: the marker home has the exams and their Next script buttons.
      if (!target) {
        moving = true;
        return router.push("/marking");
      }
      const r = await nextScript(target.examId, target.groupId);
      if (!r.ok) return setMessage(r.message);
      moving = true;
      if (r.unitId === unitId) return onSame();
      router.push(`/marking/${r.unitId}`);
    } catch {
      moving = false;
      setMessage(NEXT_FAILED);
    } finally {
      if (!moving) setBusy(false);
    }
  };
  return (
    <span className="inline-flex flex-wrap items-center gap-2">
      <button type="button" className={PRIMARY} disabled={busy} onClick={() => void go()}>
        {busy ? "Finding a script…" : "Next script"}
      </button>
      {message && (
        <span role="alert" className="text-sm text-amber-900">
          {message}
        </span>
      )}
    </span>
  );
}

/** The pages to outline for a question: its own (or its parts'), else those of the question it is part of. */
function pagesFor(q: ScreenQuestion | null, questions: ScreenQuestion[], pages: OpenedPiece["pages"]): number[] {
  let cur: ScreenQuestion | undefined = q ?? undefined;
  while (cur) {
    const found = questionPageIndexes(cur, questions, pages);
    if (found.length > 0) return found;
    cur = cur.parentId ? questions.find((x) => x.id === cur!.parentId) : undefined;
  }
  return [];
}

function Banners({
  submitted,
  pagesChanged,
  status,
  refusal,
  notice,
  onReload,
  onUndoLast,
  onReason,
}: {
  submitted: boolean;
  pagesChanged: boolean;
  status: SaveStatus;
  refusal: string | null;
  notice: string | null;
  onReload: () => void;
  onUndoLast: () => void;
  onReason: () => void;
}) {
  const box = "flex flex-wrap items-center gap-3 border-b px-4 py-2 text-sm";
  return (
    <>
      {submitted && (
        <p role="status" className={`${box} border-blue-200 bg-blue-50 text-blue-900`}>
          Submitted. You can still change it until marking closes.
        </p>
      )}
      {pagesChanged && <p className={`${box} border-amber-200 bg-amber-50 text-amber-900`}>Pages of this script changed. Check your marks and submit again.</p>}
      {status === "stale" && (
        <div role="alert" className={`${box} border-amber-200 bg-amber-50 text-amber-900`}>
          <span>This script was changed on another screen. Reload to carry on.</span>
          <button type="button" className={QUIET} onClick={onReload}>
            Reload
          </button>
        </div>
      )}
      {status === "refused" && refusal && (
        <div role="alert" className={`${box} border-amber-200 bg-amber-50 text-amber-900`}>
          <span>{refusal}</span>
          <button type="button" className={QUIET} onClick={onUndoLast}>
            Undo the last change
          </button>
        </div>
      )}
      {status === "reason_required" && (
        <div role="alert" className={`${box} border-amber-200 bg-amber-50 text-amber-900`}>
          <span>Your change is not saved yet: a change after submitting needs a reason.</span>
          <button type="button" className={QUIET} onClick={onReason}>
            Give a reason
          </button>
          <button type="button" className={QUIET} onClick={onUndoLast}>
            Undo the last change
          </button>
        </div>
      )}
      {notice && (
        <p role="alert" className={`${box} border-amber-200 bg-amber-50 text-amber-900`}>
          {notice}
        </p>
      )}
    </>
  );
}

/** A modal box for the screen: Escape and Cancel close it, focus starts on Cancel, every button at least 44 px. */
function ScreenDialog({ title, children, confirmLabel, busy, onConfirm, onCancel, extra }: { title: string; children: ReactNode; confirmLabel: string; busy: boolean; onConfirm: () => void; onCancel: () => void; extra?: ReactNode }) {
  const cancel = useRef<HTMLButtonElement>(null);
  const titleId = useId();
  const close = () => {
    if (!busy) onCancel();
  };
  const onEscape = useEffectEvent(close);
  // Focus goes back to what had it when the box opened (a layout effect: before the box moves focus to Cancel). It
  // moves once the closing render is done, as the opener may be enabled again by that same render.
  useLayoutEffect(() => {
    const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    return () => {
      queueMicrotask(() => {
        if (opener?.isConnected) opener.focus();
      });
    };
  }, []);
  useEffect(() => {
    cancel.current?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onEscape();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/40 p-4" onClick={close}>
      <div role="dialog" aria-modal="true" aria-labelledby={titleId} className="w-full max-w-md rounded-lg bg-white p-6 shadow-xl" onClick={(e) => e.stopPropagation()}>
        <h2 id={titleId} className="text-base font-semibold text-slate-900">
          {title}
        </h2>
        <div className="mt-2 space-y-3 text-sm text-slate-700">{children}</div>
        <div className="mt-5 flex flex-wrap justify-end gap-2">
          <button ref={cancel} type="button" onClick={close} className={QUIET}>
            Cancel
          </button>
          {extra}
          <button type="button" disabled={busy} onClick={onConfirm} className={PRIMARY}>
            {confirmLabel}
          </button>
        </div>
      </div>
    </div>
  );
}

/** "Name visible": the page the marker is looking at, no text box (nothing a name could be typed into). */
function NameVisibleDialog({
  unitId,
  pageId,
  pageNumber,
  pageCount,
  saveFirst,
  onClose,
  onDone,
}: {
  unitId: string;
  pageId: string;
  pageNumber: number;
  pageCount: number;
  saveFirst: () => Promise<void>;
  onClose: () => void;
  onDone: () => void;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  return (
    <ScreenDialog
      title="Name visible"
      confirmLabel="Name visible"
      busy={busy}
      onCancel={onClose}
      onConfirm={async () => {
        setBusy(true);
        setError(null);
        await saveFirst();
        const { data, error: e } = await createClient().rpc("marking_name_visible", { p_unit: unitId, p_page: pageId });
        const d = obj(data);
        if (!e && d?.ok === true) return onDone();
        setBusy(false);
        setError(markingScreenMessageFor(e || !d ? "internal" : typeof d.code === "string" ? d.code : "internal"));
      }}
    >
      <p>Does this page show the candidate&apos;s name? The script will go back to staff and leave your list.</p>
      <p className="font-medium text-slate-900">
        Page {pageNumber} of {pageCount}.
      </p>
      {error && (
        <p role="alert" className="text-amber-900">
          {error}
        </p>
      )}
    </ScreenDialog>
  );
}

/** Giving the script back: an optional reason, then it is free for others to mark. */
function GiveBackDialog({ unitId, saveFirst, onClose, onDone }: { unitId: string; saveFirst: () => Promise<void>; onClose: () => void; onDone: () => void }) {
  const id = useId();
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  return (
    <ScreenDialog
      title="Give back"
      confirmLabel="Give back"
      busy={busy}
      onCancel={onClose}
      onConfirm={async () => {
        setBusy(true);
        setError(null);
        await saveFirst();
        const r = await giveBack(unitId, reason);
        if (r.ok) return onDone();
        setBusy(false);
        setError(r.message);
      }}
    >
      <p>Another marker can then mark it. What you have marked is set aside.</p>
      <label htmlFor={id} className="block font-medium text-slate-800">
        Reason (optional)
      </label>
      <textarea id={id} value={reason} maxLength={300} rows={2} onChange={(e) => setReason(e.target.value)} className={`w-full rounded border border-slate-300 px-3 py-2 text-sm ${FOCUS}`} />
      <p className="text-slate-600">If you give one, 3 to 300 characters.</p>
      {error && (
        <p role="alert" className="text-amber-900">
          {error}
        </p>
      )}
    </ScreenDialog>
  );
}

/** A change after submit carries a reason, asked once a visit; later changes keep it. */
function ReasonDialog({ onClose, onReason, onUndo }: { onClose: () => void; onReason: (reason: string) => void; onUndo: () => void }) {
  const id = useId();
  const [reason, setReason] = useState("");
  const [problem, setProblem] = useState<string | null>(null);
  return (
    <ScreenDialog
      title="Why change a submitted script?"
      confirmLabel="Save the change"
      busy={false}
      onCancel={onClose}
      extra={
        <button type="button" onClick={onUndo} className={QUIET}>
          Undo the change
        </button>
      }
      onConfirm={() => {
        const p = reasonProblem(reason, true);
        if (p) return setProblem(p);
        onReason(reason.trim());
      }}
    >
      <p>This script was submitted. Give a reason for the change; it is kept with the marks. Later changes on this visit use the same reason.</p>
      <label htmlFor={id} className="block font-medium text-slate-800">
        Reason
      </label>
      <textarea
        id={id}
        value={reason}
        maxLength={300}
        rows={2}
        aria-invalid={problem ? true : undefined}
        onChange={(e) => setReason(e.target.value)}
        className={`w-full rounded border border-slate-300 px-3 py-2 text-sm ${FOCUS}`}
      />
      {problem && (
        <p role="alert" className="text-amber-900">
          {problem}
        </p>
      )}
    </ScreenDialog>
  );
}
