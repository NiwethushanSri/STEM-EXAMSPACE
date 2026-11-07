// Hand-drawn SVG charts, no chart library needed.

const W = 640;
const H = 260;
const PAD = 44;

export function TrendChart({
  labels,
  actual,
  forecast,
  forecastLabels,
}: {
  labels: string[];
  actual: number[];
  forecast: number[];
  forecastLabels: string[];
}) {
  const total = actual.length + forecast.length;
  const x = (i: number) => PAD + (i * (W - PAD * 2)) / Math.max(total - 1, 1);
  const y = (v: number) => H - PAD - (v / 100) * (H - PAD * 2);

  const actualPts = actual.map((v, i) => `${x(i)},${y(v)}`).join(" ");
  // The forecast line starts from the last real mark so the two lines join.
  const lastIdx = actual.length - 1;
  const forecastPts = [
    `${x(lastIdx)},${y(actual[lastIdx])}`,
    ...forecast.map((v, k) => `${x(actual.length + k)},${y(v)}`),
  ].join(" ");

  const allLabels = [...labels, ...forecastLabels];

  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="w-full" role="img" aria-label="Mark trend with forecast">
      {[0, 25, 50, 75, 100].map((g) => (
        <g key={g}>
          <line x1={PAD} x2={W - PAD} y1={y(g)} y2={y(g)} stroke="#e2e8f0" />
          <text x={PAD - 8} y={y(g) + 4} textAnchor="end" className="fill-slate-400" fontSize="11">
            {g}%
          </text>
        </g>
      ))}

      {allLabels.map((l, i) => (
        <text key={`${l}-${i}`} x={x(i)} y={H - PAD + 18} textAnchor="middle" fontSize="11" className="fill-slate-500">
          {l}
        </text>
      ))}

      {forecast.length > 0 && (
        <polyline points={forecastPts} fill="none" stroke="#f59e0b" strokeWidth="3" strokeDasharray="7 6" />
      )}
      <polyline points={actualPts} fill="none" stroke="#2563eb" strokeWidth="3" />

      {actual.map((v, i) => (
        <g key={`a-${i}`}>
          <circle cx={x(i)} cy={y(v)} r="5" fill="#2563eb" />
          <text x={x(i)} y={y(v) - 10} textAnchor="middle" fontSize="11" className="fill-blue-800" fontWeight="600">
            {v}
          </text>
        </g>
      ))}
      {forecast.map((v, k) => (
        <g key={`f-${k}`}>
          <circle cx={x(actual.length + k)} cy={y(v)} r="5" fill="#fff" stroke="#f59e0b" strokeWidth="2.5" />
          <text x={x(actual.length + k)} y={y(v) - 10} textAnchor="middle" fontSize="11" className="fill-amber-700" fontWeight="600">
            {v}
          </text>
        </g>
      ))}
    </svg>
  );
}

export function ComparisonBars({
  rows,
}: {
  rows: { subject: string; mark: number; classAverage: number }[];
}) {
  return (
    <div className="space-y-4">
      {rows.map((r) => (
        <div key={r.subject}>
          <div className="mb-1 flex justify-between text-sm">
            <span className="font-medium text-slate-800">{r.subject}</span>
            <span className="text-slate-500">
              You {r.mark}% · Class {r.classAverage}%
            </span>
          </div>
          <div className="space-y-1">
            <div className="h-3 w-full overflow-hidden rounded bg-slate-100">
              <div className="h-3 rounded bg-blue-600" style={{ width: `${r.mark}%` }} />
            </div>
            <div className="h-3 w-full overflow-hidden rounded bg-slate-100">
              <div className="h-3 rounded bg-slate-400" style={{ width: `${r.classAverage}%` }} />
            </div>
          </div>
        </div>
      ))}
      <div className="flex gap-4 pt-1 text-xs text-slate-500">
        <span className="flex items-center gap-1.5"><span className="h-2.5 w-2.5 rounded bg-blue-600" />You</span>
        <span className="flex items-center gap-1.5"><span className="h-2.5 w-2.5 rounded bg-slate-400" />Class average</span>
      </div>
    </div>
  );
}
