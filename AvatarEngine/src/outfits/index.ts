import type { OutfitName } from '../core/types';
export interface OutfitDef { label: string; /** face is baked into the outfit sprite (no expression swap) */ bakedFace: true }
export const OUTFIT_DEFS: Record<OutfitName, OutfitDef> = Object.fromEntries(
  ['default','hoodie','student','gamer','detective','wizard','raincoat','winter','summer','sleepy'].map((n) => [n, { label: n[0].toUpperCase() + n.slice(1), bakedFace: true as const }]),
) as Record<OutfitName, OutfitDef>;
