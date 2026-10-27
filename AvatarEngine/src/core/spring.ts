/** Critically-ish damped spring, sub-stepped so large dt (tab switches) stay stable. */
export class Spring {
  x = 0; v = 0; target = 0;
  constructor(public k = 120, public c = 14) {}
  step(dt: number): number {
    const n = Math.max(1, Math.ceil(Math.min(dt, 0.1) / 0.008)); const h = Math.min(dt, 0.1) / n;
    for (let i = 0; i < n; i++) { this.v += (this.k * (this.target - this.x) - this.c * this.v) * h; this.x += this.v * h; }
    return this.x;
  }
  set(x: number): void { this.x = x; this.v = 0; this.target = x; }
  kick(v: number): void { this.v += v; }
}
export const clamp = (v: number, a: number, b: number) => Math.max(a, Math.min(b, v));
export const lerp = (a: number, b: number, t: number) => a + (b - a) * t;
export const smooth = (t: number) => { t = clamp(t, 0, 1); return t * t * (3 - 2 * t); };
/** Piecewise smoothstep keyframes [[t,v],...] sampled at t (times ascending). */
export function keys(k: ReadonlyArray<readonly [number, number]>, t: number): number {
  if (t <= k[0][0]) return k[0][1];
  for (let i = 1; i < k.length; i++) if (t <= k[i][0]) {
    const [t0, v0] = k[i - 1], [t1, v1] = k[i]; return lerp(v0, v1, smooth((t - t0) / (t1 - t0 || 1)));
  }
  return k[k.length - 1][1];
}
