// Linear trend forecast: fits a least-squares line through the marks and extends it.
// It is an estimate from a few tests, not a guarantee, so the UI should say so.

export type Forecast = {
  values: number[];
  slope: number; // marks gained per test, on average
};

export function linearForecast(marks: number[], steps: number): Forecast {
  const n = marks.length;
  if (n < 2) return { values: [], slope: 0 };

  const xMean = (n - 1) / 2;
  const yMean = marks.reduce((s, y) => s + y, 0) / n;

  let num = 0;
  let den = 0;
  marks.forEach((y, i) => {
    num += (i - xMean) * (y - yMean);
    den += (i - xMean) ** 2;
  });

  const slope = den === 0 ? 0 : num / den;
  const intercept = yMean - slope * xMean;

  const values = Array.from({ length: steps }, (_, k) =>
    Math.round(Math.min(100, Math.max(0, intercept + slope * (n + k))))
  );

  return { values, slope: Math.round(slope * 10) / 10 };
}
