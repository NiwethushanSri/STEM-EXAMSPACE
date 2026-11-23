"use client";

import { useEffect, useEffectEvent, useRef, useState } from "react";
import { Badge } from "@/components/AppShell";
import { FOCUS } from "@/components/marking/ToolBar";
import { fetchPictureLinks, PICTURE_LINK_SECONDS } from "@/lib/marking-pictures";
import { accessCheckOutcome } from "@/lib/marking-screen";

const BUTTON = `inline-flex min-h-11 items-center justify-center rounded border border-slate-300 bg-white px-3 text-sm font-medium text-slate-800 hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-50 ${FOCUS}`;
/** A link older than this is asked for again before its page is shown (links last PICTURE_LINK_SECONDS). */
const LINK_FRESH_MS = (PICTURE_LINK_SECONDS - 30) * 1000;

type Problem = "refused" | "failed";

/**
 * A read-only pager through a piece's pages, for the lead marker (or an admin) to look at a changed picture before
 * releasing it. It opens on `highlight` (the changed page, marked "Changed") and asks for each page's link when it is
 * shown, through the marking-pictures function: the database decides, as the signed-in user, whether they may see the
 * pages now. A page with has_picture false has no marking picture yet: it says so, and nothing is asked for it. Nothing
 * on it names the candidate; it draws nothing and changes nothing.
 */
export function PagesViewer({
  unitId,
  pages,
  highlight,
}: {
  unitId: string;
  pages: { n: number; page_id: string; has_picture?: boolean }[];
  highlight?: string;
}) {
  const [index, setIndex] = useState(() => Math.max(0, pages.findIndex((p) => p.page_id === highlight)));
  const [links, setLinks] = useState<Record<string, { url: string; at: number }>>({});
  const [problems, setProblems] = useState<Record<string, Problem>>({});
  const asking = useRef(new Set<string>());
  const page = pages[index] ?? null;
  const noPicture = page?.has_picture === false;
  const pageId = page && !noPicture ? page.page_id : null;

  const ask = async (id: string, again = false) => {
    const known = links[id];
    if (asking.current.has(id) || (!again && known && Date.now() - known.at < LINK_FRESH_MS)) return;
    asking.current.add(id);
    // An old link is not shown while a new one is asked for.
    setLinks((m) => withoutKey(m, id));
    setProblems((m) => withoutKey(m, id));
    try {
      const r = await fetchPictureLinks(unitId, [id]);
      const url = r.ok ? r.urls[id] : undefined;
      if (url) {
        setLinks((m) => ({ ...m, [id]: { url, at: Date.now() } }));
        setProblems((m) => withoutKey(m, id));
      } else setProblems((m) => ({ ...m, [id]: accessCheckOutcome(r) === "gone" ? "refused" : "failed" }));
    } finally {
      asking.current.delete(id);
    }
  };
  const askShown = useEffectEvent(() => {
    if (pageId) void ask(pageId);
  });
  useEffect(() => {
    askShown();
  }, [pageId]);

  if (!page) return <p className="text-sm text-slate-700">This script has no pages to show.</p>;
  const link = links[page.page_id];
  const problem = problems[page.page_id];
  const go = (i: number) => setIndex(Math.max(0, Math.min(pages.length - 1, i)));

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="flex items-center gap-2 text-sm font-medium text-slate-900" aria-live="polite">
          <span>
            Page {page.n} of {pages.length}
          </span>
          {page.page_id === highlight && <Badge tone="amber">Changed</Badge>}
        </p>
        <div className="flex gap-2">
          <button type="button" className={BUTTON} disabled={index === 0} onClick={() => go(index - 1)}>
            Previous page
          </button>
          <button type="button" className={BUTTON} disabled={index === pages.length - 1} onClick={() => go(index + 1)}>
            Next page
          </button>
        </div>
      </div>
      <div data-testid="pages-viewer-page" className="flex h-[65vh] items-center justify-center overflow-hidden rounded border border-slate-200 bg-slate-100">
        {noPicture ? (
          <p className="p-6 text-center text-sm text-slate-700">This page has no marking picture yet.</p>
        ) : link && !problem ? (
          // eslint-disable-next-line @next/next/no-img-element -- a 120-second signed link to a private picture, not optimisable
          <img
            key={link.url}
            src={link.url}
            alt={`Page ${page.n}`}
            draggable={false}
            className="h-full w-full object-contain"
            onError={() => setProblems((m) => ({ ...m, [page.page_id]: "failed" }))}
          />
        ) : (
          <div className="flex flex-col items-center gap-3 p-6 text-center text-sm text-slate-700">
            {problem === "refused" ? (
              "This page cannot be shown now."
            ) : problem === "failed" ? (
              <>
                <span>The page could not be shown.</span>
                <button type="button" className={BUTTON} onClick={() => void ask(page.page_id, true)}>
                  Try again
                </button>
              </>
            ) : (
              "Loading the page..."
            )}
          </div>
        )}
      </div>
      <ul aria-label="Pages" className="flex flex-wrap gap-2">
        {pages.map((p, i) => (
          <li key={p.page_id}>
            <button
              type="button"
              aria-current={i === index ? "page" : undefined}
              aria-label={`Page ${p.n}${p.page_id === highlight ? ", changed" : ""}`}
              onClick={() => go(i)}
              className={`${BUTTON} min-w-11 px-2 ${i === index ? "border-blue-600 ring-2 ring-blue-600" : ""} ${p.page_id === highlight ? "bg-amber-50" : ""}`}
            >
              {p.n}
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}

function withoutKey<T>(m: Record<string, T>, key: string): Record<string, T> {
  if (!(key in m)) return m;
  const { [key]: _gone, ...rest } = m;
  void _gone;
  return rest;
}
