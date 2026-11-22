type Pt = [number, number];

function distToSegment(p: Pt, a: Pt, b: Pt): number {
  const dx = b[0] - a[0];
  const dy = b[1] - a[1];
  const len2 = dx * dx + dy * dy;
  if (len2 === 0) return Math.hypot(p[0] - a[0], p[1] - a[1]);
  const t = Math.max(0, Math.min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2));
  return Math.hypot(p[0] - (a[0] + t * dx), p[1] - (a[1] + t * dy));
}

// Ramer–Douglas–Peucker, with an explicit stack so a long stroke cannot overflow the call stack.
function rdp(points: Pt[], epsilon: number): Pt[] {
  const keep = new Uint8Array(points.length);
  keep[0] = 1;
  keep[points.length - 1] = 1;
  const stack: [number, number][] = [[0, points.length - 1]];
  while (stack.length > 0) {
    const [lo, hi] = stack.pop()!;
    let worst = -1;
    let at = -1;
    for (let i = lo + 1; i < hi; i++) {
      const d = distToSegment(points[i], points[lo], points[hi]);
      if (d > worst) {
        worst = d;
        at = i;
      }
    }
    if (at !== -1 && worst > epsilon) {
      keep[at] = 1;
      stack.push([lo, at], [at, hi]);
    }
  }
  return points.filter((_, i) => keep[i] === 1);
}

/** Fewer points for a stroke, keeping both ends; epsilon doubles until no more than `maxPoints` remain. */
export function simplifyStroke(points: [number, number][], epsilon = 0.0008, maxPoints = 1500): [number, number][] {
  if (points.length <= 2) return points.map((p) => [p[0], p[1]]);
  let out = rdp(points, epsilon);
  let e = epsilon;
  while (out.length > maxPoints && out.length > 2) {
    e *= 2;
    out = rdp(points, e);
  }
  return out;
}
