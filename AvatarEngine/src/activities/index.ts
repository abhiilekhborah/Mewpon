import { keys } from '../core/spring';
import type { ActivityName, Rig } from '../core/types';

export interface ActivityDef {
  /** actions-sheet pose used as the base; props/fx carved from it are animated */
  pose: ActivityName;
  /** optional multi-frame loop from the frame strips */
  frames?: { group: string; fps: number };
  /** names of carved props the motion moves (null = all) */
  moveProps?: string[];
  /** looping period in seconds, used for completion of one cycle events */
  period: number;
  motion: (a: number, r: Rig) => void;
}
const S = Math.sin, C = Math.cos;
export const ACTIVITY_DEFS: Record<ActivityName, ActivityDef> = {
  sleeping: {pose:'sleeping',period:6,motion:(_a,_r)=>{}},
  typing:   { pose: 'typing', frames: { group: 'typing', fps: 9 }, period: 8 / 9,
              motion: (a, r) => { r.headDY += S(a * 6) * 0.4; r.sproutRot += S(a * 3) * 5; } },
  reading:  { pose: 'reading', period: 6,
              motion: (a, r) => { const p = a % 6; r.eyeDX += keys([[0, -1.6], [2, 1.6], [2.3, 1.6], [2.5, -1.6], [4.5, 1.6], [5.2, 0], [6, -1.6]], p); r.eyeDY += keys([[0, 0], [2.5, 0.8], [5, 0.8], [6, 0]], p) * 0.6; r.headRot += S(a * 0.9) * 1.5; r.headDY += keys([[0, 0], [5, 0], [5.3, 1.2], [6, 0]], p); r.sproutRot += S(a) * 4; } },
  writing:  { pose: 'writing', moveProps: ['pencil'], period: 2.4,
              motion: (a, r) => { r.propDX += S(a * 5) * 1.6 + a % 2.4 * 0.0; r.propDY += Math.abs(C(a * 10)) * -0.6; r.propRot += S(a * 5) * 4; r.headRot += S(a * 1.3) * 2.5; r.headDY += 0.6; r.sproutRot += S(a * 2) * 4; } },
  idea:     { pose: 'idea', moveProps: [], period: 3,
              motion: (a, r) => { const pop = keys([[0, 0], [0.18, 1.25], [0.4, 1]], a % 3 < 0.4 ? a % 3 : 0.4); r.fxScale = (a < 0.4 ? pop : 1) + S(a * 7) * 0.06; r.fxAlpha = 0.85 + 0.15 * S(a * 13); r.fxDY += S(a * 3) * 1.5; r.headDY += -keys([[0, 0], [0.12, 2.4], [0.5, 0.4]], Math.min(a, 0.5)); r.bodyDY += -Math.exp(-a * 6) * 2.5 * Math.abs(S(a * 14)); r.sproutRot += S(a * 8) * 8 * Math.exp(-a * 0.6); } },
  drinking: { pose: 'drinking', moveProps: ['mug'], period: 4.2,
              motion: (a, r) => { const p = a % 4.2;
                r.propDY += keys([[0, 0], [0.9, -6], [1.5, -6.5], [2.1, -6.5], [2.9, 0], [4.2, 0]], p);
                r.propRot += keys([[0, 0], [0.9, -6], [1.5, -20], [2.1, -20], [2.7, -4], [2.9, 0], [4.2, 0]], p);
                r.propDX += keys([[0, 0], [1.5, -2], [2.1, -2], [2.9, 0], [4.2, 0]], p);
                r.headRot += keys([[0, 0], [1.5, -3], [2.1, -3], [2.9, 0], [4.2, 0]], p); r.headDY += keys([[0, 0], [1.5, -0.6], [2.1, -0.6], [2.9, 0]], p);
                r.sproutRot += S(a * 2) * 4; } },
  listening:{ pose: 'listening', frames: { group: 'listening', fps: 5 }, period: 1.2,
              motion: (a, r) => { r.headRot += 3 + S(a * 1.6) * 2; r.fxFloat = 1; r.sproutRot += S(a * 2.4) * 8; } },
  cooking:  { pose: 'cooking', moveProps: ['pan'], period: 2.6,
              motion: (a, r) => { const p = a % 2.6;
                r.propDY += keys([[0, 0], [0.8, 1], [1.0, -9], [1.3, -4], [1.5, 0], [2.6, 0]], p);
                r.propRot += keys([[0, 0], [0.8, 6], [1.0, -18], [1.3, -4], [1.5, 0], [2.6, 0]], p);
                r.bodyDY += -Math.abs(keys([[0, 0], [0.8, 0.8], [1.0, -1.2], [1.5, 0]], p)) * 0.5;
                r.fxScale = 1 + S(a * 11) * 0.08; r.fxAlpha = 0.8 + 0.2 * S(a * 17); r.headRot += S(a * 2.4) * 2; r.sproutRot += S(a * 3) * 6; } },
  searching:{ pose: 'searching', frames: { group: 'searching', fps: 4 }, moveProps: ['magnifier'], period: 6 / 4,
              motion: (a, r) => { r.propDX += S(a * 1.6) * 3; r.propDY += C(a * 1.6) * 1.2; r.propRot += S(a * 1.6) * 6; r.eyeDX += S(a * 1.6) * 1.2; r.headRot += S(a * 1.6) * 2; r.sproutRot += S(a * 2) * 6; } },
  working:  { pose: 'working', period: 2,
              motion: (a, r) => { r.headDY += S(a * 9) * 0.5; r.bodyDY += Math.abs(S(a * 4.5)) * -0.6; r.sproutRot += S(a * 4.5) * 7; r.headDX += S(a * 2.2) * 0.4; } },
  talking:  { pose: 'talking', frames: { group: 'talk', fps: 7 }, period: 8 / 7,
              motion: (a, r) => { r.bodyDY += -Math.abs(S(a * 5)) * 0.5; r.sproutRot += S(a * 5) * 7; r.headRot += S(a * 1.3) * 1.5; } },
};
