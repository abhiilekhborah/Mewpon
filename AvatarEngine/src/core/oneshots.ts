import type { OneShotName, Rig } from './types';
import { keys } from './spring';
/** One-shot procedural reactions. u = progress 0..1 over the item's duration. Offsets are added to the rig. */
export const ONESHOT_DEFS: Record<OneShotName, { duration: number; apply: (u: number, r: Rig) => void }> = {
  bounce: { duration: 0.7, apply: (u, r) => { const h = Math.abs(Math.sin(u * Math.PI * 2)) * (1 - u) * 11; r.bodyDY -= h; r.sy += (h < 1.5 ? -0.08 * (1 - u) : 0.04); r.sx += (h < 1.5 ? 0.06 * (1 - u) : -0.02); r.sproutRot += Math.sin(u * 30) * 12 * (1 - u); } },
  hop:    { duration: 0.45, apply: (u, r) => { r.bodyDY -= Math.sin(u * Math.PI) * 9; r.sy += keys([[0, -0.07], [0.15, 0.05], [0.8, 0.02], [1, -0.06]], u); } },
  nod:    { duration: 0.7, apply: (u, r) => { r.headRot += Math.sin(u * Math.PI * 2) * 7; r.headDY += Math.sin(u * Math.PI * 2) * 1.5; } },
  shake:  { duration: 0.7, apply: (u, r) => { r.headRot += Math.sin(u * Math.PI * 6) * 9 * (1 - u); r.headDX += Math.sin(u * Math.PI * 6) * 1.5 * (1 - u); } },
  squish: { duration: 0.5, apply: (u, r) => { const k = Math.sin(u * Math.PI); r.sy -= 0.14 * k; r.sx += 0.1 * k; } },
};
