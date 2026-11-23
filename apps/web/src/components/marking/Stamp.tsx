import { isStamp, type Tool } from "@/lib/annotations";

const RED = "#dc2626";
const GREEN = "#16a34a";

// Marks drawn in the same colours as on the RM screen: green tick, red cross, wrong sign,
// red caret and red boxed codes. Tools that are not stamps draw nothing here.
export function Stamp({ kind }: { kind: Tool }) {
  if (!isStamp(kind)) return null;
  if (kind === "tick") {
    return (
      <svg width="34" height="34" viewBox="0 0 24 24" fill="none" stroke={GREEN} strokeWidth="3.2" strokeLinecap="round" strokeLinejoin="round">
        <path d="M4 12.5l5 5L20 6.5" />
      </svg>
    );
  }
  if (kind === "cross") {
    return (
      <svg width="34" height="34" viewBox="0 0 24 24" fill="none" stroke={RED} strokeWidth="3.2" strokeLinecap="round">
        <path d="M5 5l14 14M19 5L5 19" />
      </svg>
    );
  }
  if (kind === "error") {
    return (
      <svg width="34" height="34" viewBox="0 0 24 24" fill="none" stroke={RED} strokeWidth="2.6" strokeLinecap="round">
        <circle cx="12" cy="12" r="9" />
        <path d="M8 12h8" />
      </svg>
    );
  }
  if (kind === "caret") {
    return <span className="block text-3xl font-bold leading-none" style={{ color: RED }}>^</span>;
  }
  return (
    <span
      className="block whitespace-nowrap rounded-sm border-2 bg-white/90 px-1 text-sm font-bold leading-snug"
      style={{ color: RED, borderColor: RED }}
    >
      {kind}
    </span>
  );
}
