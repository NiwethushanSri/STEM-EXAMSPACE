"use client";

import { useEffect, useRef, useState } from "react";
import { isBlurred, measureBlur, measureFileBlur } from "@/lib/blur-check";
import { UPLOAD_TEXT } from "@/lib/home-upload";

const BUTTON =
  "rounded-lg bg-blue-700 px-3 py-1.5 text-sm font-semibold text-white hover:bg-blue-800 disabled:cursor-not-allowed disabled:opacity-60";
const QUIET = "rounded-lg border border-slate-300 bg-white px-3 py-1.5 text-sm font-semibold text-slate-800 hover:bg-slate-50";

/** A4 portrait: width / height. */
const A4 = 210 / 297;

/** The page-shaped guide inside a frame of w x h: an A4 rectangle as large as fits in 90% of it, centred. */
function guideRect(w: number, h: number) {
  let gh = h * 0.9;
  let gw = gh * A4;
  if (gw > w * 0.9) {
    gw = w * 0.9;
    gh = gw / A4;
  }
  return { x: (w - gw) / 2, y: (h - gh) / 2, w: gw, h: gh };
}

type Review = { file: File; url: string };

/**
 * Takes photos of answer pages one at a time with the rear camera in the browser (getUserMedia), with a page-shaped
 * guide on screen; or, where the browser has no camera access (or it is refused), with the phone's own camera app
 * through a file input. Each photo gets the blur check: a blurred one asks "This photo is blurred. Retake it?"
 * before it is handed on. `onCapture` receives every photo kept; `onClose` ends the session.
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
  const videoRef = useRef<HTMLVideoElement>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const [mode, setMode] = useState<"starting" | "camera" | "fallback">(() =>
    typeof navigator !== "undefined" && typeof navigator.mediaDevices?.getUserMedia === "function" ? "starting" : "fallback",
  );
  const [size, setSize] = useState<{ w: number; h: number } | null>(null);
  const [review, setReview] = useState<Review | null>(null);
  const [taken, setTaken] = useState(0);
  const [working, setWorking] = useState(false);

  // Start the rear camera; any failure (no camera, permission refused, insecure page) falls back to the file input.
  useEffect(() => {
    if (mode !== "starting") return;
    let live = true;
    navigator.mediaDevices
      .getUserMedia({ audio: false, video: { facingMode: { ideal: "environment" }, width: { ideal: 4096 }, height: { ideal: 4096 } } })
      .then(async (stream) => {
        if (!live) {
          stream.getTracks().forEach((t) => t.stop());
          return;
        }
        streamRef.current = stream;
        const video = videoRef.current;
        if (!video) return;
        video.srcObject = stream;
        await video.play().catch(() => undefined);
        if (live) setMode("camera");
      })
      .catch(() => {
        if (live) setMode("fallback");
      });
    return () => {
      live = false;
    };
  }, [mode]);

  // The camera is switched off when this closes.
  useEffect(
    () => () => {
      streamRef.current?.getTracks().forEach((t) => t.stop());
      streamRef.current = null;
    },
    [],
  );

  useEffect(() => () => {
    if (review) URL.revokeObjectURL(review.url);
  }, [review]);

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
    const video = videoRef.current;
    if (!video || !video.videoWidth) return;
    setWorking(true);
    const w = video.videoWidth;
    const h = video.videoHeight;
    const canvas = document.createElement("canvas");
    canvas.width = w;
    canvas.height = h;
    canvas.getContext("2d")?.drawImage(video, 0, 0, w, h);
    const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.92));
    setWorking(false);
    if (!blob) return;
    const file = new File([blob], `page-${Date.now()}.jpg`, { type: "image/jpeg", lastModified: Date.now() });
    check(file, measureBlur(canvas, w, h, guideRect(w, h)));
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
    <div role="dialog" aria-modal="true" aria-label={`${UPLOAD_TEXT.photograph} for ${label}`} data-testid="camera-capture"
      className="space-y-3 rounded-lg border border-slate-200 bg-slate-900 p-3 text-white">
      <p className="text-sm">{UPLOAD_TEXT.photoAdvice}</p>

      {review ? (
        <div className="space-y-2">
          {/* eslint-disable-next-line @next/next/no-img-element -- a local photo before it is uploaded */}
          <img src={review.url} alt="The photo just taken" className="mx-auto max-h-[60vh] rounded" />
          <p role="alert" className="font-semibold text-amber-200">{UPLOAD_TEXT.blurred}</p>
          <div className="flex flex-wrap gap-2">
            <button type="button" className={BUTTON} onClick={() => setReview(null)}>{UPLOAD_TEXT.retake}</button>
            <button type="button" className={QUIET} onClick={() => keep(review.file)}>{UPLOAD_TEXT.keep}</button>
          </div>
        </div>
      ) : (
        <>
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
            <label className={mode === "fallback" ? BUTTON : `${QUIET} cursor-pointer`}>
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
        </>
      )}
    </div>
  );
}
