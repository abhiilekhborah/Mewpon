export interface Layer {
  file: string; w: number; h: number; ox: number; oy: number;
  px?: number; py?: number; cx?: number; cy?: number; kind?: string; name?: string;
}
export interface Entry {
  anchor_src: [number, number]; area: number; factor: number;
  full: Layer; fx: Layer[]; props: Record<string, Layer>;
  head?: Layer; body?: Layer; headPivot?: [number, number]; domeY?: number;
  sprout?: Layer | null; eyes?: Layer[];
}
export interface Manifest {
  version: number; source: string;
  groups: {
    expressions: Record<string, Entry>; actions: Record<string, Entry>;
    outfits: Record<string, Entry>; frames: Record<string, Entry[]>;
  };
}
export const EXPRESSIONS = ['neutral','happy','excited','thinking','confused','sad','angry','sleepy','wink','laugh','surprised','embarrassed','proud','focused'] as const;
export const ACTIVITIES = ['typing','reading','writing','idea','drinking','listening','cooking','searching','working','talking','sleeping'] as const;
export const OUTFITS = ['default','hoodie','student','gamer','detective','wizard','raincoat','winter','summer','sleepy'] as const;
export const MOVEMENTS = ['idle','walk','run','jump','talk'] as const;
export const ONESHOTS = ['bounce','nod','shake','squish','hop'] as const;
export type ExpressionName = typeof EXPRESSIONS[number];
export type ActivityName = typeof ACTIVITIES[number];
export type OutfitName = typeof OUTFITS[number];
export type MovementName = typeof MOVEMENTS[number];
export type OneShotName = typeof ONESHOTS[number];

/** Per-frame modifiers applied on top of a pose. Units: source pixels / degrees. */
export interface Rig {
  x: number; y: number; flip: boolean; bodyDY: number; sx: number; sy: number;
  headDX: number; headDY: number; headRot: number; sproutRot: number;
  eyeDX: number; eyeDY: number; eyeSY: number;
  propDX: number; propDY: number; propRot: number; propScale: number; moveProps: string[] | null;
  fxDY: number; fxAlpha: number; fxScale: number; fxFloat: number; alpha: number;
  pawLX: number; pawLY: number; pawRX: number; pawRY: number;
  earL: number; earR: number; mouth: number; cheek: number; laptopAlpha: number; propAlpha: number;
  rootRot: number; page: number; food: number; celebration: number;
}
export const newRig = (): Rig => ({
  x: 0, y: 0, flip: false, bodyDY: 0, sx: 1, sy: 1, headDX: 0, headDY: 0, headRot: 0, sproutRot: 0,
  eyeDX: 0, eyeDY: 0, eyeSY: 1, propDX: 0, propDY: 0, propRot: 0, propScale: 1, moveProps: null,
  fxDY: 0, fxAlpha: 1, fxScale: 1, fxFloat: 0, alpha: 1,
  pawLX: 0, pawLY: 0, pawRX: 0, pawRY: 0, earL: 0, earR: 0, mouth: 0, cheek: 0, laptopAlpha: 0, propAlpha: 0,
  rootRot: 0, page: 0, food: 0, celebration: 0,
});
