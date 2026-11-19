import { Card } from "@/components/AppShell";
import { formatLondon } from "@/lib/money";
import type { DownloadEntry } from "@/lib/exam-admin";

const KIND_LABEL: Record<string, string> = {
  home: "Home download",
  print_pack: "Print pack",
  reprint: "Reprint",
  admin_preview: "Admin preview",
};

/** Every download of this exam's copies, newest first: when, who, which candidate, what kind and which paper version. */
export function DownloadLog({ entries, capped }: { entries: DownloadEntry[]; capped: boolean }) {
  return (
    <Card title="Download log">
      {entries.length === 0 ? (
        <p className="text-sm text-slate-500">No copies have been downloaded yet.</p>
      ) : (
        <div className="overflow-x-auto">
          <table aria-label="Download log" className="w-full text-left text-sm">
            <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
              <tr>
                {["When (UK time)", "Who", "Candidate", "Kind", "Version"].map((h) => (
                  <th key={h} className="py-2 pr-4 font-medium">
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {entries.map((d) => (
                <tr key={d.id} data-testid="download-row" className="border-b border-slate-100 last:border-0">
                  <td className="py-2 pr-4 whitespace-nowrap">{formatLondon(d.at)}</td>
                  <td className="py-2 pr-4">{d.by}</td>
                  <td className="py-2 pr-4 whitespace-nowrap">{d.indexNumber}</td>
                  <td className="py-2 pr-4 whitespace-nowrap">{KIND_LABEL[d.kind] ?? d.kind}</td>
                  <td className="py-2 pr-4">v{d.version}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {capped && <p className="mt-2 text-xs text-slate-500">Showing the newest {entries.length} downloads.</p>}
    </Card>
  );
}
