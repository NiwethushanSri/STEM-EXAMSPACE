"use client";

import { useCallback, useEffect, useRef, useState, type KeyboardEvent } from "react";
import { isBlurred, measureBlur, measureFileBlur } from "@/lib/blur-check";
import { UPLOAD_TEXT } from "@/lib/home-upload";

const BUTTON =
  "rounded-lg bg-blue-700 px-3 py-1.5 text-sm font-semibold text-white hover:bg-blue-800 disabled:cursor-not-allowed disabled:opacity-60";
const QUIET = "rounded-lg border border-slate-300 bg-white px-3 py-1.5 text-sm font-semibold text-slate-800 hover:bg-slate-50";
/** A label around a visually hidden file input shows the input's focus. */
const FOCUS_WITHIN = "focus-within:outline focus-within:outline-2 focus-within:outline-offset-2 focus-within:outline-amber-300";

/** A4 portrait: width / height. */
const A4 = 210 / 297;

/** The page-shaped guide inside a frame of w x h: an A4 rectangle as large as fits in 90% of it, centred. */
export function guideRect(w: number, h: number) {
  let gh = h * 0.9;
  let gw = gh * A4;
  if (gw > w * 0.9) {
    gw = w * 0.9;
    gh = gw / A4;
  }
  return { x: (w - gw) / 2, y: (h - gh) / 2, w: gw, h: gh };
}

type VideoLike = { srcObject: unknown; paused: boolean; play(): Promise<void> };

/** Shows the camera in a <video>: the stream is (re)attached to any video element that lacks it, and a paused
 * video (hidden during a review, or new) plays again, so a photo can always be taken. */
export function attachStream(video: VideoLike | null, stream: MediaStream | null): void {
  if (!video || !stream) return;
  if (video.srcObject !== stream) video.srcObject = stream;
  if (video.paused) void video.play().catch(() => undefined);
}

/** Where Tab (or Shift+Tab with `backwards`) must send the focus to stay inside the dialog: the other end at the
 * first or last control, the first (or last) control when the focus is not on one; null to let Tab move as usual. */
export function cycleFocus<T>(focusables: T[], active: unknown, backwards: boolean): T | null {
  if (focusables.length === 0) return null;
  const first = focusables[0];
  const last = focusables[focusables.length - 1];
  const at = focusables.indexOf(active as T);
  if (at < 0) return backwards ? last : first;
  if (backwards && at === 0) return last;
  if (!backwards && at === focusables.length - 1) return first;
  return null;
}

const FOCUSABLE = 'button:not([disabled]), input:not([disabled]):not([type="hidden"]), [href], select, textarea, [tabindex]:not([tabindex="-1"])';

type Review = { file: File; url: string };

/**
 * Takes photos of answer pages one at a time with the rear camera in the browser (getUserMedia), with a page-shaped
 * guide on screen; or, where the browser has no camera access (or it is refused), with the phone's own camera app
 * through a file input. Each photo gets the blur check: a blurred one asks "This photo is blurred. Retake it?"
 * before it is handed on. `onCapture` receives every photo kept; `onClose` ends the session (Done, or Escape), which
 * switches the camera off. The focus stays inside while it is open and goes back where it was after.
 */
export function CameraCapture({
  label,
  onCapture,
  onClose,
  single = false,
}: {
  label: string;
  onCapture: (file: File) => void;
  onClose: () => void;
  /** One photo only (a retake): the camera closes once it is kept. */
  single?: boolean;
}) {
  const dialogRef = useRef<HTMLDivElement>(null);
  const video = useRef<HTMLVideoElement | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const shot = useRef<HTMLCanvasElement | null>(null);
  const [mode, setMode] = useState<"starting" | "camera" | "fallback">(() =>
    typeof navigator !== "undefined" && typeof navigator.mediaDevices?.getUserMedia === "function" ? "starting" : "fallback",
  );
  const [size, setSize] = useState<{ w: number; h: number } | null>(null);
  const [review, setReview] = useState<Review | null>(null);
  const [taken, setTaken] = useState(0);
  const [working, setWorking] = useState(false);

  // Any <video> this renders gets the camera (a callback ref, so a new element is never left without the stream).
  const videoRef = useCallback((el: HTMLVideoElement | null) => {
    video.current = el;
    attachStream(el, streamRef.current);
  }, []);

  // Start the rear camera; any failure (no camera, permission refused, insecure page) falls back to the file input.
  useEffect(() => {
    if (mode !== "starting") return;
    let live = true;
    navigator.mediaDevices
      .getUserMedia({ audio: false, video: { facingMode: { ideal: "environment" }, width: { ideal: 4096 }, height: { ideal: 4096 } } })
      .then((stream) => {
        if (!live) {
          stream.getTracks().forEach((t) => t.stop());
          return;
        }
        streamRef.current = stream;
        attachStream(video.current, stream);
        setMode("camera");
      })
      .catch(() => {
        if (live) setMode("fallback");
      });
    return () => {
      live = false;
    };
  }, [mode]);

  // After a review the camera shows again, playing.
  useEffect(() => {
    if (!review) attachStream(video.current, streamRef.current);
  }, [review]);

  // The focus goes into the dialog, and back where it was when it closes; the camera is switched off then.
  useEffect(() => {
    const before = document.activeElement as HTMLElement | null;
    dialogRef.current?.focus();
    return () => {
      streamRef.current?.getTracks().forEach((t) => t.stop());
      streamRef.current = null;
      before?.focus?.();
    };
  }, []);

  useEffect(() => () => {
    if (review) URL.revokeObjectURL(review.url);
  }, [review]);

  function onKeyDown(e: KeyboardEvent<HTMLDivElement>) {
    if (e.key === "Escape") {
      e.preventDefault();
      onClose();
      return;
    }
    if (e.key !== "Tab" || !dialogRef.current) return;
    const focusables = Array.from(dialogRef.current.querySelectorAll<HTMLElement>(FOCUSABLE));
    const to = cycleFocus(focusables, document.activeElement, e.shiftKey);
    if (to) {
      e.preventDefault();
      to.focus();
    }
  }

  function keep(file: File) {
    onCapture(file);
    setTaken((n) => n + 1);
    setReview(null);
    if (single) onClose();
  }

  /** The photo goes on unless it is blurred, when the family is asked first. */
  function check(file: File, score: number | null) {
    if (score !== null && isBlurred(score)) setReview({ file, url: URL.createObjectURL(file) });
    else keep(file);
  }

  async function takePhoto() {
    const v = video.current;
    if (!v || !v.videoWidth) {
      attachStream(v, streamRef.current);
      return;
    }
    setWorking(true);
    const w = v.videoWidth;
    const h = v.videoHeight;
    shot.current ??= document.createElement("canvas");
    const canvas = shot.current;
    canvas.width = w;
    canvas.height = h;
    canvas.getContext("2d")?.drawImage(v, 0, 0, w, h);
    const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.92));
    const score = blob ? measureBlur(canvas, w, h, guideRect(w, h)) : null;
    canvas.width = 1; // lets the full-size picture go
    canvas.height = 1;
    setWorking(false);
    if (!blob) return;
    check(new File([blob], `page-${Date.now()}.jpg`, { type: "image/jpeg", lastModified: Date.now() }), score);
  }

  async function picked(list: FileList | null) {
    const file = list?.[0];
    if (!file) return;
    setWorking(true);
    const score = await measureFileBlur(file);
    setWorking(false);
    check(file, score);
  }

  const guide = size ? guideRect(size.w, size.h) : null;

  return (
    <div ref={dialogRef} role="dialog" aria-modal="true" aria-label={`${UPLOAD_TEXT.photograph} for ${label}`} tabIndex={-1}
      onKeyDown={onKeyDown} data-testid="camera-capture"
      className="space-y-3 rounded-lg border border-slate-200 bg-slate-900 p-3 text-white focus:outline-none">
      <p className="text-sm">{UPLOAD_TEXT.photoAdvice}</p>

      {review && (
        <div className="space-y-2">
          {/* eslint-disable-next-line @next/next/no-img-element -- a local photo before it is uploaded */}
          <img src={review.url} alt="The photo just taken" className="mx-auto max-h-[60vh] rounded" />
          <p role="alert" className="font-semibold text-amber-200">{UPLOAD_TEXT.blurred}</p>
          <div className="flex flex-wrap gap-2">
            <button type="button" className={BUTTON} onClick={() => setReview(null)}>{UPLOAD_TEXT.retake}</button>
            <button type="button" className={QUIET} onClick={() => keep(review.file)}>{UPLOAD_TEXT.keep}</button>
          </div>
        </div>
      )}

      {/* The camera stays mounted (hidden during a review), so it keeps its stream. */}
      <div className={review ? "hidden" : "space-y-3"}>
        {mode !== "fallback" && (
          <div className="relative mx-auto w-full max-w-md overflow-hidden rounded bg-black">
            <video ref={videoRef} playsInline muted aria-label="Camera"
              onLoadedMetadata={(e) => setSize({ w: e.currentTarget.videoWidth, h: e.currentTarget.videoHeight })}
              className="block max-h-[65vh] w-full object-contain" />
            {guide && size && (
              <svg aria-hidden="true" viewBox={`0 0 ${size.w} ${size.h}`} preserveAspectRatio="xMidYMid meet"
                className="pointer-events-none absolute inset-0 h-full w-full">
                <rect x={guide.x} y={guide.y} width={guide.w} height={guide.h} fill="none" stroke="white"
                  strokeWidth={Math.max(2, size.w / 200)} strokeDasharray={`${size.w / 40} ${size.w / 80}`} />
              </svg>
            )}
          </div>
        )}
        {mode === "camera" && <p className="text-center text-sm">Line the page up with the frame.</p>}
        <div className="flex flex-wrap items-center gap-2">
          {mode === "camera" && (
            <button type="button" className={BUTTON} disabled={working} onClick={() => void takePhoto()}>
              Take photo<span className="sr-only"> of a page for {label}</span>
            </button>
          )}
          <label className={`${mode === "fallback" ? BUTTON : QUIET} ${FOCUS_WITHIN} cursor-pointer`}>
            {mode === "fallback" ? "Open the camera" : "Use the camera app instead"}
            <input type="file" accept="image/*" capture="environment" className="sr-only" disabled={working}
              onChange={(e) => {
                void picked(e.currentTarget.files);
                e.currentTarget.value = "";
              }} />
          </label>
          <button type="button" className={QUIET} onClick={onClose}>Done</button>
        </div>
        <p aria-live="polite" className="text-sm text-slate-200">
          {taken > 0 ? `${taken} photo${taken === 1 ? "" : "s"} taken. Take the next page, or press Done.` : ""}
        </p>
      </div>
    </div>
  );
}
