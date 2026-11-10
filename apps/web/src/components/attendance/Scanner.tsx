"use client";

import { useEffect, useRef, useState, useSyncExternalStore } from "react";

type Detector = { detect(source: HTMLVideoElement): Promise<{ rawValue: string }[]> };
type DetectorCtor = new (options: { formats: string[] }) => Detector;

/** The same decoded text is ignored for this long after it was last sent. */
export const REPEAT_MS = 3000;
const POLL_MS = 250;

function cameraSupported(): boolean {
  return (
    typeof window !== "undefined" &&
    "BarcodeDetector" in window &&
    typeof navigator !== "undefined" &&
    typeof navigator.mediaDevices?.getUserMedia === "function"
  );
}
const noSubscribe = () => () => {};

/**
 * Optional camera QR reader. It renders nothing unless the browser has BarcodeDetector and a camera API,
 * so the typed input is then the only way in. The only thing it hands on is the decoded text; frames and
 * the video never leave the page.
 */
export function Scanner({ onCode, disabled = false }: { onCode: (text: string) => void; disabled?: boolean }) {
  const supported = useSyncExternalStore(noSubscribe, cameraSupported, () => false);
  const [on, setOn] = useState(false);
  const [problem, setProblem] = useState("");
  const video = useRef<HTMLVideoElement>(null);
  const handler = useRef(onCode);
  useEffect(() => {
    handler.current = onCode;
  });

  useEffect(() => {
    if (!on) return;
    const node = video.current;
    let stopped = false;
    let stream: MediaStream | null = null;
    let timer: ReturnType<typeof setInterval> | undefined;
    const seen = new Map<string, number>();

    (async () => {
      try {
        const Ctor = (window as unknown as { BarcodeDetector: DetectorCtor }).BarcodeDetector;
        const detector = new Ctor({ formats: ["qr_code"] });
        stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" } });
        if (stopped) {
          stream.getTracks().forEach((t) => t.stop());
          return;
        }
        const el = node;
        if (!el) return;
        el.srcObject = stream;
        await el.play().catch(() => undefined);
        let busy = false;
        timer = setInterval(async () => {
          if (busy || stopped || el.readyState < 2) return;
          busy = true;
          try {
            const codes = await detector.detect(el);
            const now = Date.now();
            for (const c of codes) {
              const text = c.rawValue.trim();
              if (!text) continue;
              const last = seen.get(text);
              if (last !== undefined && now - last < REPEAT_MS) continue;
              seen.set(text, now);
              handler.current(text);
            }
          } catch {
            // A frame that cannot be read is skipped.
          } finally {
            busy = false;
          }
        }, POLL_MS);
      } catch {
        if (!stopped) {
          setProblem("The camera could not be started. Type the index number instead.");
          setOn(false);
        }
      }
    })();

    return () => {
      stopped = true;
      if (timer) clearInterval(timer);
      stream?.getTracks().forEach((t) => t.stop());
      if (node) node.srcObject = null;
    };
  }, [on]);

  if (!supported) return null;
  return (
    <div className="space-y-2" data-testid="scanner">
      <button
        type="button"
        disabled={disabled}
        onClick={() => {
          setProblem("");
          setOn((v) => !v);
        }}
        className="rounded border border-slate-300 px-3 py-1.5 text-sm hover:bg-slate-50 disabled:opacity-60"
      >
        {on ? "Stop camera" : "Scan with camera"}
      </button>
      {problem && <p className="text-sm text-red-700">{problem}</p>}
      {on && <video ref={video} muted playsInline aria-label="Camera view" className="aspect-video w-full max-w-sm rounded bg-black" />}
    </div>
  );
}
