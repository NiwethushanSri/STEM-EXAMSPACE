/** Authored icons and line drawings for the home page. Icons: one 2px stroke on a 24px grid. */

type P = { className?: string };

const stroke = {
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 2,
  strokeLinecap: "round" as const,
  strokeLinejoin: "round" as const,
};

export function ArrowIcon({ className }: P) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden="true" {...stroke} strokeWidth={2.2}>
      <path d="M4 12h15M13 6l6 6-6 6" />
    </svg>
  );
}

export function TickIcon({ className }: P) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden="true" {...stroke} strokeWidth={2.8}>
      <path d="M5 12.5l4.5 4.5L19 7.5" />
    </svg>
  );
}

export function ParentIcon({ className }: P) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden="true" {...stroke}>
      <circle cx="9" cy="7" r="3" />
      <path d="M3.5 20c0-3.6 2.5-6 5.5-6s5.5 2.4 5.5 6" />
      <circle cx="17" cy="10" r="2.2" />
      <path d="M15.5 14.6c.5-.2 1-.3 1.5-.3 2.2 0 3.8 1.8 3.8 4.7" />
    </svg>
  );
}

export function StudentIcon({ className }: P) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden="true" {...stroke}>
      <path d="M2.5 9L12 4.5 21.5 9 12 13.5z" />
      <path d="M6.5 11v4.5c0 1.5 2.5 3 5.5 3s5.5-1.5 5.5-3V11" />
      <path d="M21.5 9v5" />
    </svg>
  );
}

/** A teacher: an open book. */
export function TeacherIcon({ className }: P) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden="true" {...stroke}>
      <path d="M12 6.5C10 5 7 4.5 3.5 5v13c3.5-.5 6.5 0 8.5 1.5 2-1.5 5-2 8.5-1.5V5C17 4.5 14 5 12 6.5z" />
      <path d="M12 6.5v13" />
    </svg>
  );
}

/** A tutor: a person beside a teaching board. */
export function TutorIcon({ className }: P) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden="true" {...stroke}>
      <rect x="10" y="3.5" width="11" height="8.5" rx="1.5" />
      <path d="M13 6.8h5M13 9.2h3" />
      <circle cx="6" cy="9" r="2.5" />
      <path d="M2.5 20c0-3.4 1.6-5.6 3.5-5.6 1.4 0 2.6 1 3.2 2.6l3.8-3" />
    </svg>
  );
}

/** A light, open, overshooting hand-drawn ring around one word. It draws itself on scroll. */
export function Ring({ className }: P) {
  return (
    <svg viewBox="0 0 200 70" preserveAspectRatio="none" className={className} aria-hidden="true" data-draw="">
      <path
        pathLength={1}
        d="M30 52C10 40 30 13 96 10c64-3 100 10 96 30-4 18-48 24-102 22C40 60 6 52 14 32 20 18 46 10 78 8"
        fill="none"
        stroke="#1f64ae"
        strokeWidth="2.2"
        strokeLinecap="round"
        vectorEffect="non-scaling-stroke"
      />
    </svg>
  );
}

const line = {
  fill: "none",
  stroke: "#10224f",
  strokeWidth: 2.4,
  strokeLinecap: "round" as const,
  strokeLinejoin: "round" as const,
};

/** Step 1: a parent books on a phone; the seat is confirmed. */
export function DoodleBook({ className }: P) {
  return (
    <svg viewBox="0 0 168 128" className={className} aria-hidden="true" data-draw="">
      <path d="M40 124c0-26 13-44 31-44s31 18 31 44" fill="#e3f4ec" />
      <path pathLength={1} {...line} d="M40 124c0-26 13-44 31-44s31 18 31 44" />
      <circle cx="71" cy="54" r="16" fill="#ffffff" />
      <circle pathLength={1} {...line} cx="71" cy="54" r="16" />
      <path d="M55 52c0-12 7-19 17-19 9 0 16 7 15 17-5-6-12-8-19-6-5 1-9 4-13 8z" fill="#10224f" />
      <path pathLength={1} {...line} d="M66 59c3 2 7 2 10 0" />
      <path pathLength={1} {...line} d="M93 102c9-6 15-17 17-30" />
      <rect x="103" y="34" width="26" height="44" rx="5" fill="#ffffff" transform="rotate(8 116 56)" />
      <rect pathLength={1} {...line} x="103" y="34" width="26" height="44" rx="5" transform="rotate(8 116 56)" />
      <path pathLength={1} {...line} stroke="#1f64ae" d="M109 55l5 5 9-10" transform="rotate(8 116 56)" />
      <circle cx="148" cy="24" r="13" fill="#eaf1fb" />
      <circle pathLength={1} {...line} stroke="#1f64ae" cx="148" cy="24" r="13" />
      <path pathLength={1} {...line} stroke="#1f64ae" d="M142 24l4 4 8-9" />
      <path pathLength={1} {...line} stroke="#ee9330" d="M20 46l8 3M16 64h9M22 82l7-4" />
    </svg>
  );
}

/** Step 2: a student writes at a single desk, the clock on the wall. */
export function DoodleSit({ className }: P) {
  return (
    <svg viewBox="0 0 168 128" className={className} aria-hidden="true" data-draw="">
      <circle cx="140" cy="24" r="15" fill="#ffffff" />
      <circle pathLength={1} {...line} cx="140" cy="24" r="15" />
      <path pathLength={1} {...line} stroke="#ee9330" d="M140 15v9l6 4" />
      <path d="M30 88c0-20 9-34 24-34 11 0 19 7 22 17l-4 17z" fill="#e3f4f3" />
      <path pathLength={1} {...line} d="M30 88c0-20 9-34 24-34 11 0 19 7 22 17" />
      <circle cx="56" cy="38" r="13" fill="#ffffff" />
      <circle pathLength={1} {...line} cx="56" cy="38" r="13" />
      <path d="M43 36c1-10 7-15 14-15 8 0 13 6 12 13-4-4-9-5-14-4-5 1-9 3-12 6z" fill="#10224f" />
      <path pathLength={1} {...line} d="M64 70c10 4 20 9 30 11" />
      <path pathLength={1} {...line} stroke="#1f64ae" d="M94 81l12-14" />
      <path d="M78 88l8-11h44l-8 11z" fill="#ffffff" />
      <path pathLength={1} {...line} d="M78 88l8-11h44l-8 11z" />
      <path pathLength={1} {...line} d="M14 88h140M24 88v36M144 88v36" />
      <path pathLength={1} {...line} stroke="#2c9a97" d="M20 30l7 4M18 48h8" />
    </svg>
  );
}

/** Step 3: a marker with a tablet and pen; ticks and the total fly off the page. */
export function DoodleMarks({ className }: P) {
  return (
    <svg viewBox="0 0 168 128" className={className} aria-hidden="true" data-draw="">
      <path d="M22 124c0-26 13-42 30-42s30 16 30 42" fill="#eaf1fb" />
      <path pathLength={1} {...line} d="M22 124c0-26 13-42 30-42s30 16 30 42" />
      <circle cx="52" cy="56" r="15" fill="#ffffff" />
      <circle pathLength={1} {...line} cx="52" cy="56" r="15" />
      <path d="M37 55c0-11 7-18 16-18s15 7 14 16c-5-5-11-7-17-6-5 1-9 4-13 8z" fill="#10224f" />
      <rect x="74" y="60" width="54" height="40" rx="6" fill="#ffffff" transform="rotate(-8 101 80)" />
      <rect pathLength={1} {...line} x="74" y="60" width="54" height="40" rx="6" transform="rotate(-8 101 80)" />
      <path pathLength={1} {...line} d="M84 74h22M84 84h18M84 94h22" transform="rotate(-8 101 80)" />
      <path pathLength={1} {...line} stroke="#c8261b" d="M110 71l3 3 6-7M110 82l3 3 6-7" transform="rotate(-8 101 80)" />
      <path pathLength={1} {...line} d="M70 104l14-12" />
      <path pathLength={1} {...line} stroke="#c8261b" d="M128 22l4 4 9-10" />
      <path pathLength={1} {...line} stroke="#c8261b" d="M146 46l4 4 9-10" />
      <ellipse cx="140" cy="102" rx="20" ry="12" fill="#e3f4ec" />
      <ellipse pathLength={1} {...line} stroke="#1e8f62" cx="140" cy="102" rx="20" ry="12" />
      <path pathLength={1} {...line} stroke="#1e8f62" d="M130 102h20M134 97l-4 5 4 5" strokeWidth="2" />
      <path pathLength={1} {...line} stroke="#ee9330" d="M108 30l5 5M98 40h7" />
    </svg>
  );
}

/** A tablet pen seen from above, docked flat: matte white body, flat charging side, grey tip. */
export function Pencil({ className }: P) {
  return (
    <svg viewBox="0 0 300 20" className={className} aria-hidden="true">
      <rect x="0" y="2" width="250" height="16" rx="8" fill="#f4f5f7" />
      <rect x="18" y="2" width="214" height="4.5" fill="#e2e5ea" />
      <rect x="0" y="2" width="250" height="16" rx="8" fill="none" stroke="#d3d7de" strokeWidth="1" />
      <path d="M249 2.5l40 7a.6.6 0 0 1 0 1L249 17.5z" fill="#eceef1" stroke="#d3d7de" strokeWidth="1" />
      <path d="M279 8.4L293 10l-14 1.6z" fill="#5b616b" />
    </svg>
  );
}

/** The placeholder figure on the example index card (no real photo is shown). */
export function PersonSilhouette({ className }: P) {
  return (
    <svg viewBox="0 0 84 96" className={className} aria-hidden="true">
      <circle cx="42" cy="34" r="17" fill="#c5cede" />
      <path d="M8 96c2-22 16-34 34-34s32 12 34 34z" fill="#c5cede" />
    </svg>
  );
}
