import { clamp } from './spring';
import type { Rig } from './types';
import type { PetAction } from './pet';
import { keys } from './spring';

const S = Math.sin;
export const smoothstep = (x: number) => { x = clamp(x, 0, 1); return x*x*(3-2*x); };

/** Continuous joint targets, in the same bottom-centre source-pixel space as the original art. */
export function activityPose(name: string | null, time: number, age: number, r: Rig): void {
  const enter = smoothstep(age / 0.28);
  // Different incommensurate phases prevent a single obvious metronome loop.
  r.sy = 1 + S(time * 1.85) * 0.006;
  r.headDY = S(time * 1.85 + 0.65) * 0.35;
  r.headRot = S(time * 0.71) * 0.65;
  r.sproutRot = S(time * 1.27 + 0.4) * 3.6;
  const twitch = Math.pow(Math.max(0, S(time * 0.49 + 1.2)), 32);
  r.earL = twitch * 1.1; r.earR = Math.pow(Math.max(0, S(time * 0.63 - 1)), 40) * 0.8;
  if (!name) return;
  if (name === 'typing' || name === 'working' || name === 'writing') {
    if(name!=='writing')r.laptopAlpha=1;
    const pause = smoothstep((S(time * 1.1) + 0.65) * 3);
    const tap = time * (name === 'working' ? 9 : 12);
    r.pawLY = -Math.max(0, S(tap)) * 2.3 * pause * enter;
    r.pawRY = -Math.max(0, S(tap + Math.PI)) * 2.3 * pause * enter;
    r.pawLX = S(tap) * 0.3 * enter; r.pawRX = -S(tap) * 0.3 * enter;
    r.headDY += enter * 0.7; r.headRot -= enter * 1.1;
    r.eyeDY += enter * 1.2; r.sproutRot += S(time * 3.4 - 0.4) * 1.3 * pause;
    if(name==='writing'){r.propDX=S(time*5)*1.6;r.propDY=-Math.abs(S(time*10))*0.8;r.propRot=S(time*5)*5;}
  } else if (name === 'searching') {
    const arc = S(time * 1.2) * (0.65 + 0.35 * smoothstep((S(time * 0.35)+1)/2));
    r.pawRX = arc * 1.7 * enter; r.pawRY = (Math.cos(time * 1.2)-1) * 0.65 * enter;
    r.propRot = arc * 8 * enter; r.headRot += arc * 2;
    r.eyeDX += arc * 1.5; r.earR += Math.max(0, arc) * 0.6;
  } else if (name === 'listening') {
    r.headRot += enter * (3 + S(time * 0.9)); r.eyeDX += enter * 0.4;
    r.earL += S(time * 3.2) * 0.55; r.earR += S(time * 3.2 - 0.8) * 0.45;
    r.fxAlpha = 0.7 + S(time * 3.2) * 0.2; r.fxFloat = 0.3;
  } else if (name === 'talking') {
    const syllable = (S(time * 14) + S(time * 9.3 + 0.7) * 0.5) / 1.5;
    const pause = smoothstep((S(time * 1.7) + 0.6) * 3);
    r.mouth = Math.max(0, syllable) * pause * enter;
    r.cheek = S(time * 7) * 0.25 * pause; r.headRot += S(time * 2.4) * 1.1 * pause;
  } else if (name === 'reading') {
    const phase=age%6;
    r.eyeDX+=keys([[0,-1.5],[2,1.5],[2.3,-1.5],[4.5,1.5],[5,0],[6,-1.5]],phase);r.eyeDY+=1.5;
    r.page=Math.sin(smoothstep((phase-4.7)/0.9)*Math.PI);r.pawRY=-r.page*3;r.headRot+=S(time)*1.1;
    r.propDY=5;
  } else if(name==='drinking') {
    const p=age%5, lift=keys([[0,0],[0.6,0],[1.4,1],[2.8,1],[3.6,0],[5,0]],p)*enter;
    r.propScale=0.66;r.propDY=8-lift*3;r.propDX=20-lift*7;r.propRot=-lift*12;r.pawRY=-lift*2;r.pawRX=lift*3;
    r.headRot-=lift*3;r.mouth=lift>0.9?0.15:0;r.eyeSY=1-lift*0.25;
  } else if(name==='cooking') {
    const p=age%3.8,flip=keys([[0,0],[0.8,0],[1,1],[1.5,0],[3.8,0]],p);
    r.pawRY=-flip*5;r.pawRX=S(age*2)*1.1;r.propScale=0.82;r.propDX=17;r.propDY=5-flip*5;r.propRot=S(age*2)*4-flip*20;
    r.food=Math.max(0,Math.sin(Math.min(1,Math.max(0,(p-1)/0.85))*Math.PI))*20;
    r.eyeDY=-r.food*0.055;r.headRot+=S(age*2)*1.5;r.earL+=flip;
  } else if(name==='idea') { r.headRot-=3;r.eyeDY-=1.7;r.sproutRot+=S(age*2)*3; }
  else if(name==='sleeping') {r.sy=1+S(time*0.85)*0.012;r.headRot=S(time*0.6)*0.6;r.eyeSY=0.1;r.headDY=1;r.sproutRot=S(time*0.7)*1.5;}
}

export function petPose(action:PetAction|null,age:number,duration:number,r:Rig,lookX=0):void {
  if(!action)return;
  const enter=smoothstep(age/0.25),end=Number.isFinite(duration)?smoothstep((duration-age)/0.25):1,k=enter*end;
  if(action==='pet'){r.eyeSY=1-k*0.9;r.headRot+=lookX*4*k;r.headDY+=k;r.earL+=S(age*8)*1.4*k;r.earR+=S(age*8-0.5)*1.2*k;r.sproutRot+=S(age*9)*12*k;}
  else if(action==='poke'){r.y-=Math.sin(Math.min(1,age/0.55)*Math.PI)*5;r.earL-=k*2;r.headRot+=S(age*12)*3*k;}
  else if(action==='highFive'||action==='wave'){r.pawRY-=k*(action==='highFive'?13:10);r.pawRX+=k*(action==='wave'?S(age*12)*4:3);r.headRot-=k*2;r.sproutRot+=S(age*4)*5*k;}
  else if(action==='dance'){r.pawLY-=Math.max(0,S(age*8))*8*k;r.pawRY-=Math.max(0,-S(age*8))*8*k;r.pawLX=S(age*4)*3*k;r.pawRX=-S(age*4)*3*k;r.headRot+=S(age*4)*6*k;r.bodyDY-=Math.abs(S(age*8))*2*k;r.sproutRot+=S(age*4-0.8)*12*k;r.celebration=k;}
  else if(action==='jump')movementPose('jump',age,duration,r);
  // An in-plane cartwheel; never a mirrored fake 3D turn.
  else if(action==='spin'){r.rootRot=smoothstep(age/duration)*360;r.y=-Math.sin(age/duration*Math.PI)*8;r.pawLY=r.pawRY=-k*3;r.sproutRot+=S(age*7)*8*k;}
  else if(action==='nap'){activityPose('sleeping',age,age,r);r.bodyDY+=smoothstep(age/0.8)*1.5;}
  else if(action==='wake'){r.pawLY=r.pawRY=-Math.sin(age/duration*Math.PI)*5;r.headDY-=k*2;r.mouth=k*0.5;r.earL+=k*2;}
  else if(action==='followCursor'){r.headRot+=lookX*4*k;r.eyeDX+=lookX*1.5;}
}

export function movementPose(name: string, age: number, duration: number, r: Rig): void {
  const enter = smoothstep(age / 0.18);
  if (name === 'walk' || name === 'run') {
    const run = name === 'run', phase = age * (run ? 15 : 8), reach = run ? 2.8 : 1.8;
    r.pawLX = S(phase) * reach * enter; r.pawRX = -S(phase) * reach * enter;
    r.pawLY = -Math.max(0, Math.cos(phase)) * (run ? 3.6 : 2.2) * enter;
    r.pawRY = -Math.max(0, -Math.cos(phase)) * (run ? 3.6 : 2.2) * enter;
    r.bodyDY = -Math.abs(S(phase)) * (run ? 1.2 : 0.55) * enter;
    r.headRot += S(phase - 0.25) * (run ? 1.6 : 0.8); r.headDX += run ? 1.2 : 0;
    r.sproutRot += S(phase - 0.6) * (run ? 5 : 2.5);
  } else if (name === 'jump') {
    const u = clamp(age / duration, 0, 1);
    if (u < 0.18) { const a = smoothstep(u / 0.18); r.y = a * 1.8; r.sy = 1 - a * 0.025; r.pawLY = r.pawRY = a * 0.5; }
    else if (u < 0.78) { const flight = (u - 0.18) / 0.6; r.y = -Math.sin(flight * Math.PI) * 27; r.pawLY = r.pawRY = -Math.sin(flight * Math.PI) * 2; r.sproutRot += S(flight * Math.PI * 2) * 5; }
    else { const land = Math.sin((u - 0.78) / 0.22 * Math.PI); r.sy = 1 - land * 0.025; r.y = land * 1.3; r.sproutRot += land * 3; }
  } else if (name === 'talk') { activityPose('talking', age, age, r); }
}

/** C1 continuous spatial deformation of an existing texture; no detached cutouts. */
export function bodyPoint(x: number, y: number, r: Rig): [number, number] {
  const lower = smoothstep((y + 19) / 14);
  const left = Math.exp(-Math.pow((x + 7) / 13, 2)) * lower;
  const right = Math.exp(-Math.pow((x - 20) / 13, 2)) * lower;
  return [x + left * r.pawLX + right * r.pawRX, y + left * r.pawLY + right * r.pawRY];
}

/** The original focused drawing faces left and includes its laptop. Move its
 * actual paws without deforming the screen or pulling apart the neck seam. */
export function focusedBodyPoint(x:number,y:number,r:Rig):[number,number]{
  const lower=smoothstep((y+16)/12),keep=smoothstep(-x/6);
  const left=Math.exp(-Math.pow((x+28)/10,2))*lower*keep;
  const right=Math.exp(-Math.pow((x+7)/8,2))*lower*keep;
  return [x+left*r.pawLX+right*r.pawRX,y+left*r.pawLY+right*r.pawRY];
}
