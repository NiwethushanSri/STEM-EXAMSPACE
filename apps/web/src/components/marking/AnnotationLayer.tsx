import { memo } from "react";
import { Stamp } from "@/components/marking/Stamp";
import { isStamp } from "@/lib/annotations";
import { rulerCm, type SavedAnnotation } from "@/lib/marking-model";

// Examiner marks keep the RM Assessor colours (as Stamp): red pen and notes, yellow highlighter, blue measuring.
const RED = "#dc2626";
const HIGHLIGHT = "#facc15";
const BLUE = "#2563eb";
const SELECTED = "#2563eb";

const points = (list: [number, number][]) => list.map(([x, y]) => `${x},${y}`).join(" ");

/**
 * The marks on one page, drawn over its picture: pen and highlighter strokes and rulers in an SVG whose units are
 * fractions of the page (so they stay in place at any zoom), stamps (Stamp) and text notes placed at their point.
 * The caller passes one page's annotations. Read only (results, Phase 4), nothing takes the pointer; on the marking
 * screen the stamps and notes do, so the select tool can find them, and `selectedId` is outlined.
 */
export const AnnotationLayer = memo(function AnnotationLayer({
  annotations,
  readOnly,
  selectedId = null,
}: {
  annotations: SavedAnnotation[];
  readOnly?: boolean;
  selectedId?: string | null;
}) {
  const strokes = annotations.filter((a) => (a.kind === "pen" || a.kind === "highlight") && a.points && a.points.length > 1);
  const rulers = annotations.filter((a) => a.kind === "ruler" && a.points && a.points.length > 1);
  const placed = annotations.filter((a) => a.kind === "text" || isStamp(a.kind));
  const grab = readOnly ? "pointer-events-none" : "pointer-events-auto";
  return (
    <div className="pointer-events-none absolute inset-0" aria-hidden="true">
      <svg viewBox="0 0 1 1" preserveAspectRatio="none" className="absolute inset-0 h-full w-full overflow-visible">
        {strokes.map((a) => (
          <g key={a.id} data-annotation-id={a.id} data-annotation-kind={a.kind}>
            {a.id === selectedId && (
              <polyline points={points(a.points!)} fill="none" stroke={SELECTED} strokeOpacity={0.35} strokeWidth={10} strokeLinecap="round" strokeLinejoin="round" vectorEffect="non-scaling-stroke" />
            )}
            <polyline
              points={points(a.points!)}
              fill="none"
              stroke={a.kind === "highlight" ? HIGHLIGHT : RED}
              strokeOpacity={a.kind === "highlight" ? 0.4 : 1}
              strokeWidth={a.kind === "highlight" ? 18 : 2.5}
              strokeLinecap="round"
              strokeLinejoin="round"
              vectorEffect="non-scaling-stroke"
            />
          </g>
        ))}
        {rulers.map((a) => {
          const [p, q] = [a.points![0], a.points![a.points!.length - 1]];
          return (
            <g key={a.id} data-annotation-id={a.id} data-annotation-kind="ruler">
              {a.id === selectedId && (
                <line x1={p[0]} y1={p[1]} x2={q[0]} y2={q[1]} stroke={SELECTED} strokeOpacity={0.35} strokeWidth={10} vectorEffect="non-scaling-stroke" />
              )}
              <line x1={p[0]} y1={p[1]} x2={q[0]} y2={q[1]} stroke={BLUE} strokeWidth={1.5} vectorEffect="non-scaling-stroke" />
            </g>
          );
        })}
      </svg>
      {rulers.map((a) => {
        const [p, q] = [a.points![0], a.points![a.points!.length - 1]];
        return (
          <span
            key={`${a.id}-cm`}
            className="absolute -translate-x-1/2 -translate-y-full whitespace-nowrap rounded bg-white/85 px-1 text-sm font-medium"
            style={{ left: `${((p[0] + q[0]) / 2) * 100}%`, top: `${((p[1] + q[1]) / 2) * 100}%`, color: BLUE }}
          >
            {rulerCm(a.points!)} cm
          </span>
        );
      })}
      {placed.map((a) =>
        a.kind === "text" ? (
          <span
            key={a.id}
            data-annotation-id={a.id}
            data-annotation-kind="text"
            className={`${grab} absolute max-w-[45%] whitespace-pre-wrap break-words rounded bg-white/85 px-1 text-sm font-medium ${a.id === selectedId ? "ring-2 ring-blue-600 ring-offset-2" : ""}`}
            style={{ left: `${a.x * 100}%`, top: `${a.y * 100}%`, color: RED }}
          >
            {a.text}
          </span>
        ) : (
          <span
            key={a.id}
            data-annotation-id={a.id}
            data-annotation-kind={a.kind}
            className={`${grab} absolute -translate-x-1/2 -translate-y-1/2 rounded ${a.id === selectedId ? "ring-2 ring-blue-600 ring-offset-2" : ""}`}
            style={{ left: `${a.x * 100}%`, top: `${a.y * 100}%` }}
          >
            <Stamp kind={a.kind} />
          </span>
        ),
      )}
    </div>
  );
});
