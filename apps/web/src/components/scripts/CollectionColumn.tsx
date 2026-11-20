"use client";

import { useState, useTransition } from "react";
import { Card } from "@/components/AppShell";
import { collectionRecordAction, manifestCreateAction } from "@/components/attendance/collection-actions";
import type { CollectionRow } from "@/lib/collection";

const field = "w-20 rounded border border-slate-300 bg-white px-2 py-1 text-sm";

function Row({ row }: { row: CollectionRow }) {
  const [value, setValue] = useState(row.extraSheets === null ? "" : String(row.extraSheets));
  const [saved, setSaved] = useState<number | null>(row.extraSheets);
  const [message, setMessage] = useState("");
  const [pending, start] = useTransition();
  const n = value.trim() === "" ? NaN : Number(value);
  const valid = Number.isInteger(n) && n >= 0 && n <= 50;

  function save() {
    if (!valid) return;
    start(async () => {
      try {
        const r = await collectionRecordAction(row.bookingId, n);
        if (r.ok) {
          setSaved(n);
          setMessage("");
        } else setMessage(r.message);
      } catch {
        setMessage("Something went wrong. Please try again.");
      }
    });
  }

  return (
    <tr data-testid="collection-row" className="border-t border-slate-100">
      <td className="py-2 pr-3 font-mono text-xs">{row.indexNumber}</td>
      <td className="py-2 pr-3">{row.name}</td>
      <td className="py-2 pr-3">{row.attendance === "late" ? "Late" : "Present"}</td>
      <td className="py-2 pr-3" data-testid="sheets-text">
        {saved === null ? "Not counted" : `Booklet + ${saved} extra ${saved === 1 ? "sheet" : "sheets"}`}
      </td>
      <td className="py-2">
        <form
          className="flex flex-wrap items-center gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            save();
          }}
        >
          <label className="sr-only" htmlFor={`extra-${row.bookingId}`}>
            Extra sheets for {row.indexNumber}
          </label>
          <input
            id={`extra-${row.bookingId}`}
            inputMode="numeric"
            value={value}
            onChange={(e) => setValue(e.target.value)}
            maxLength={2}
            className={field}
            placeholder="0"
          />
          <button type="submit" disabled={pending || !valid} className="rounded border border-slate-300 px-3 py-1 text-sm hover:bg-slate-50 disabled:opacity-60">
            Save
          </button>
          {message && (
            <span role="alert" className="text-xs text-red-700">
              {message}
            </span>
          )}
        </form>
      </td>
    </tr>
  );
}

/** The "Sheets" column of a centre: every candidate who sat, the extra sheets counted, and the manifest button. */
export function CollectionColumn({ examId, centreId, rows }: { examId: string; centreId: string; rows: CollectionRow[] }) {
  const [message, setMessage] = useState("");
  const [pending, start] = useTransition();

  function printManifest() {
    setMessage("");
    start(async () => {
      try {
        const r = await manifestCreateAction(examId, centreId);
        if (!r.ok) {
          setMessage(r.message);
          return;
        }
        const { buildManifestPdf } = await import("@/lib/manifest-pdf");
        const bytes = await buildManifestPdf(r.manifest);
        const url = URL.createObjectURL(new Blob([bytes as BlobPart], { type: "application/pdf" }));
        const a = document.createElement("a");
        a.href = url;
        a.download = `${r.manifest.number}.pdf`;
        document.body.appendChild(a);
        a.click();
        a.remove();
        setTimeout(() => URL.revokeObjectURL(url), 60_000);
        setMessage(`Manifest ${r.manifest.number} made.`);
      } catch {
        setMessage("The manifest could not be made. Please try again.");
      }
    });
  }

  return (
    <Card title="Sheets">
      <div className="space-y-4">
        {rows.length === 0 ? (
          <p className="text-sm text-slate-500">Nobody has been marked present yet.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm" data-testid="collection-table">
              <thead className="text-xs text-slate-500">
                <tr>
                  <th className="pb-2 pr-3 font-medium">Index number</th>
                  <th className="pb-2 pr-3 font-medium">Name</th>
                  <th className="pb-2 pr-3 font-medium">Attendance</th>
                  <th className="pb-2 pr-3 font-medium">Sheets</th>
                  <th className="pb-2 font-medium">Extra sheets</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <Row key={r.bookingId} row={r} />
                ))}
              </tbody>
            </table>
          </div>
        )}
        <div className="flex flex-wrap items-center gap-3">
          <button type="button" disabled={pending} onClick={printManifest} className="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-60">
            Print collection manifest
          </button>
          {message && (
            <p role="status" className="text-sm text-slate-700">
              {message}
            </p>
          )}
        </div>
      </div>
    </Card>
  );
}
