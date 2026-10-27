import type { ExpressionName, Rig } from '../core/types';

export interface ExprDef {
  /** Whether a neutral blink is appropriate while holding this expression. */
  blink: boolean;
  /** secondary motion applied every frame (t and e = seconds since expression began) */
  motion: (t: number, e: number, r: Rig) => void;
  /** one-time impulse when the expression starts (spring kicks, squash pops) */
  fxFloat?: number;
}
const S = Math.sin;
export const EXPRESSION_DEFS: Record<ExpressionName, ExprDef> = {
  neutral:   { blink: true,  motion: (t, e, r) => { r.sy += S(t * 2.2) * 0.008; r.headDY += S(t * 2.2 + 0.6) * 0.5; r.sproutRot += S(t * 1.3) * 5; } },
  happy:     { blink: false, fxFloat: 1, motion: (t, e, r) => { r.bodyDY += -Math.abs(S(t * 4.2)) * 1.2; r.headRot += S(t * 2.1) * 2; r.sproutRot += S(t * 4.2) * 9; } },
  excited:   { blink: false, fxFloat: 1, motion: (t, e, r) => { r.bodyDY += -Math.abs(S(t * 9)) * 3.2; r.sy += S(t * 18) * 0.02; r.sproutRot += S(t * 9) * 14; r.fxScale += S(t * 10) * 0.08; } },
  thinking:  { blink: true,  motion: (t, e, r) => { r.headRot += -4 + S(t * 0.9) * 1.2; r.headDX += -1; r.headDY += S(t * 1.5) * 0.4; r.sproutRot += S(t * 0.7) * 4; r.eyeDX += -1; } },
  confused:  { blink: true,  fxFloat: 1, motion: (t, e, r) => { r.headRot += S(t * 1.7) * 4.5; r.sproutRot += S(t * 2.4) * 10; r.eyeDX += S(t * 1.7) * 0.8; } },
  sad:       { blink: false, motion: (t, e, r) => { r.headDY += 1 + S(t * 0.8) * 0.4; r.headRot += 1.5; r.sproutRot += 14 + S(t * 0.6) * 2; r.sy += S(t * 0.8) * 0.006; } },
  angry:     { blink: true,  motion: (t, e, r) => { r.headRot += -2 + S(t * 1.5) * 0.35; r.headDY += 0.5; r.sproutRot += 5 + S(t * 1.5) * 2; r.sx += 0.015; } },
  sleepy:    { blink: false, motion: (t, e, r) => { r.sy += S(t * 1.3) * 0.016; r.headRot += S(t * 0.55) * 3.5 + 2; r.headDY += 1 + S(t * 1.3) * 0.8; r.sproutRot += S(t * 0.5) * 3 + 6; } },
  wink:      { blink: false, motion: (t, e, r) => { r.bodyDY += -Math.abs(S(t * 3)) * 0.8; r.headRot += 3 + S(t * 2) * 1.5; r.sproutRot += S(t * 3) * 8; } },
  laugh:     { blink: false, fxFloat: 1, motion: (t, e, r) => { r.bodyDY += -Math.abs(S(t * 8)) * 2.2; r.headDX += S(t * 6) * 0.3; r.headRot += S(t * 4) * 1.5; r.sproutRot += S(t * 11) * 12; } },
  surprised: { blink: true,  fxFloat: 1, motion: (t, e, r) => { const k = Math.exp(-e * 5); r.sy += 0.07 * k * S(e * 30); r.bodyDY += -2.5 * k; r.sproutRot += S(t * 20) * 10 * k + 6; } },
  embarrassed: { blink: true, fxFloat: 1, motion: (t, e, r) => { r.headDX += S(t * 1.4) * 0.35; r.headRot += 3 + S(t * 3) * 1.5; r.sproutRot += S(t * 6) * 5; } },
  proud:     { blink: true,  fxFloat: 1, motion: (t, e, r) => { r.headDY += -1 + S(t * 1.8) * 0.5; r.sy += 0.012; r.sproutRot += S(t * 2) * 8; } },
  focused:   { blink: true,  motion: (t, e, r) => { r.headDY += S(t * 2.6) * 0.3; r.sproutRot += S(t * 0.8) * 3; r.eyeDY += 0.3; } },
};
