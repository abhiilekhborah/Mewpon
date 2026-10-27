/** Amplitude-envelope lip sync: audio -> per-window loudness -> mouth-openness index. */
export function toMono(buf: { numberOfChannels: number; length: number; getChannelData(c: number): Float32Array }): Float32Array {
  const out = new Float32Array(buf.length);
  for (let c = 0; c < buf.numberOfChannels; c++) { const d = buf.getChannelData(c); for (let i = 0; i < d.length; i++) out[i] += d[i] / buf.numberOfChannels; }
  return out;
}
export function envelope(samples: Float32Array, sampleRate: number, windowMs = 20): Float32Array {
  const win = Math.max(1, Math.round((sampleRate * windowMs) / 1000)); const n = Math.ceil(samples.length / win);
  const env = new Float32Array(n);
  for (let w = 0; w < n; w++) { let s = 0, c = 0; for (let i = w * win; i < Math.min(samples.length, (w + 1) * win); i++) { s += samples[i] * samples[i]; c++; } env[w] = Math.sqrt(s / (c || 1)); }
  const sorted = Array.from(env).sort((a, b) => a - b); const ref = sorted[Math.floor(sorted.length * 0.95)] || sorted[sorted.length - 1] || 1;
  if (ref > 1e-6) for (let i = 0; i < n; i++) env[i] = Math.min(1, env[i] / ref);
  return env;
}
/** Maps amplitude 0..1 to a frame index 0..n-1 (0 = closed). Below the gate the mouth is closed. */
export function amplitudeToIndex(a: number, n: number, gate = 0.08): number {
  if (n <= 1 || a < gate) return 0;
  return Math.min(n - 1, 1 + Math.floor(((a - gate) / (1 - gate)) * (n - 1)));
}
export class LipSync {
  readonly duration: number;
  constructor(public env: Float32Array, public windowMs = 20) { this.duration = (env.length * windowMs) / 1000; }
  amplitudeAt(t: number): number {
    const f = (t * 1000) / this.windowMs; const i = Math.floor(f); if (i < 0 || i >= this.env.length) return 0;
    const j = Math.min(this.env.length - 1, i + 1); return this.env[i] + (this.env[j] - this.env[i]) * (f - i);
  }
}
