"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";
import { AreaDrawSurface } from "@/components/papers/AreaDrawSurface";
import type { Area } from "@/lib/hidden-areas";
import { PAGE_ASPECT, SIGNED_URL_SECONDS, ZOOMS, rotateView, zoomIn, zoomOut } from "@/lib/page-view";
import { createClient } from "@/lib/supabase/client";

const TOOL = "rounded border border-slate-300 bg-white px-2 py-1 text-xs font-medium text-slate-800 hover:bg-slate-50 disabled:opacity-40";

/**
 * A page picture for staff: the full picture at `path` in the private script-pages bucket (staff admins may read it),
 * shown through a signed link of 300 seconds, asked for again once if the picture fails to load (a link that ran
 * out). Zoom in and out, and turn the view a quarter at a time (the view only: the stored picture does not change).
 * Hidden areas show over the picture; with `onDraw` staff draw new ones on it, upright, as fractions of the picture.
 */
export function PageViewer(props: { path: string; label: string; areas?: Area[]; onDraw?: (a: Area) => void; caption?: ReactNode }) {
  // A new picture starts again: its own link, zoom and view.
  return <Viewer key={props.path} {...props} />;
}

function Viewer({ path, label, areas = [], onDraw, caption }: { path: string; label: string; areas?: Area[]; onDraw?: (a: Area) => void; caption?: ReactNode }) {
  const [url, setUrl] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);
  const [zoom, setZoom] = useState(1);
  const [turned, setTurned] = useState(0);
  /** Bumped to sign the link again (once, after the picture failed to load). */
  const [attempt, setAttempt] = useState(0);
  const retried = useRef(false);
  const rotation = onDraw ? 0 : turned;
  const quarter = rotation === 90 || rotation === 270;

  useEffect(() => {
    let live = true;
    (async () => {
      const { data, error } = await createClient().storage.from("script-pages").createSignedUrl(path, SIGNED_URL_SECONDS);
      if (!live) return;
      if (error || !data?.signedUrl) {
        setFailed(true);
      } else {
        setFailed(false);
        setUrl(data.signedUrl);
      }
    })().catch(() => {
      if (live) setFailed(true);
    });
    return () => {
      live = false;
    };
  }, [path, attempt]);

  const picture = url ? (
    // eslint-disable-next-line @next/next/no-img-element -- a 300-second signed URL of a private picture, not optimisable
    <img
      src={url}
      alt={label}
      draggable={false}
      className="block w-full"
      onLoad={() => {
        retried.current = false;
      }}
      onError={() => {
        if (retried.current) return setFailed(true);
        retried.current = true;
        setAttempt((n) => n + 1);
      }}
    />
  ) : (
    <div className="flex w-full items-center justify-center bg-slate-50 text-sm text-slate-500" style={{ aspectRatio: `${PAGE_ASPECT}` }}>
      {failed ? "The picture could not be shown. Refresh the page to try again." : "Loading the picture..."}
    </div>
  );

  return (
    <figure className="space-y-2">
      <div className="flex flex-wrap items-center gap-2" role="toolbar" aria-label={`View of ${label}`}>
        <button type="button" className={TOOL} onClick={() => setZoom(zoomOut)} disabled={zoom <= ZOOMS[0]}>
          Zoom out
        </button>
        <span className="min-w-[3rem] text-center text-xs text-slate-600" aria-live="polite">
          {Math.round(zoom * 100)}%
        </span>
        <button type="button" className={TOOL} onClick={() => setZoom(zoomIn)} disabled={zoom >= ZOOMS[ZOOMS.length - 1]}>
          Zoom in
        </button>
        <button type="button" className={TOOL} onClick={() => setTurned((r) => rotateView(r, -1))} disabled={!!onDraw}>
          Turn left
        </button>
        <button type="button" className={TOOL} onClick={() => setTurned((r) => rotateView(r))} disabled={!!onDraw}>
          Turn right
        </button>
        {failed && url && (
          <span role="alert" className="text-xs text-red-700">
            The picture could not be shown. Refresh the page to try again.
          </span>
        )}
      </div>
      <div className="max-h-[75vh] overflow-auto rounded border border-slate-200 bg-slate-100 p-2">
        <div className="mx-auto" style={{ width: `${zoom * 100}%` }}>
          {rotation === 0 ? (
            <AreaDrawSurface areas={areas} onAdd={onDraw} testId={onDraw ? "page-draw-surface" : "page-picture"}>
              {picture}
            </AreaDrawSurface>
          ) : (
            <div className="relative" style={{ aspectRatio: `${quarter ? 1 / PAGE_ASPECT : PAGE_ASPECT}` }}>
              <div
                className="absolute left-1/2 top-1/2"
                style={{ width: quarter ? `${PAGE_ASPECT * 100}%` : "100%", transform: `translate(-50%, -50%) rotate(${rotation}deg)` }}
              >
                <AreaDrawSurface areas={areas} testId="page-picture">
                  {picture}
                </AreaDrawSurface>
              </div>
            </div>
          )}
        </div>
      </div>
      {caption && <figcaption className="text-xs text-slate-600">{caption}</figcaption>}
    </figure>
  );
}
