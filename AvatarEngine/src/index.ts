import { Assets } from './core/assets';
import { AnimationController, PRIORITY, type AnimEvents, type AnimType, type Active } from './core/controller';
import { EventBus } from './core/events';
import { LipSync, amplitudeToIndex, envelope, toMono } from './core/lipsync';
import { ONESHOT_DEFS } from './core/oneshots';
import { PetDirector, PET_ACTIONS, type PetAction } from './core/pet';
import { activityPose, movementPose, petPose } from './core/rigmotion';
import { Spring, clamp } from './core/spring';
import { StateMachine, type MewState } from './core/statemachine';
import { ACTIVITIES, EXPRESSIONS, MOVEMENTS, ONESHOTS, OUTFITS, newRig,
  type ActivityName, type Entry, type ExpressionName, type Manifest, type OneShotName, type OutfitName, type Rig } from './core/types';
import {ExpressionDirector,ReactionSequence,type ReactionStage} from './core/expression';
import { ACTIVITY_DEFS } from './activities';
import { Renderer, type Frame } from './rendering/draw';
import { attachInteractions, type InteractionOptions } from './interactions/pointer';

export { EXPRESSIONS, ACTIVITIES, OUTFITS, MOVEMENTS, ONESHOTS, PRIORITY, StateMachine, AnimationController, EventBus, LipSync, envelope, amplitudeToIndex };
export type { ExpressionName, ActivityName, OutfitName, OneShotName, MewState };

export type ReactKind = 'click' | 'doubleClick' | 'poke' | 'pet' | 'dragStart' | 'dragEnd' | 'hover' | ExpressionName;
export interface MewponOptions {
  baseUrl?: string; manifest?: Manifest; scale?: number; speed?: number; transparent?: boolean; background?: string;
  pixelated?: boolean; debug?: boolean; autoStart?: boolean; maxFps?: number; autoBlink?: boolean; idleGlance?: boolean;
  interactions?: boolean | InteractionOptions;
}
export interface MewponEvents {
  animationComplete: { name: string; type: AnimType; interrupted: boolean };
  animationStart: { name: string; type: AnimType };
  expressionChanged: { from: ExpressionName; to: ExpressionName };
  activityChanged: { from: ActivityName | null; to: ActivityName | null };
  outfitChanged: { from: OutfitName; to: OutfitName };
  stateChanged: { from: MewState; to: MewState };
  speechStart: { duration: number }; speechEnd: { interrupted: boolean };
  interaction: { kind: ReactKind; accepted: boolean };
  petChanged: {playing:boolean;action:string|null;following:boolean;awaitingPaw:boolean};
  ready: undefined;
}
const MOVE_DEFS: Record<string, { group: string; fps: number; loop: boolean; duration: number }> = {
  idle: { group: 'idle', fps: 6, loop: true, duration: 4 }, walk: { group: 'walk', fps: 10, loop: true, duration: 3 },
  run: { group: 'run', fps: 14, loop: true, duration: 2.5 }, jump: { group: 'jump', fps: 9, loop: false, duration: 6 / 9 },
  talk: { group: 'talk', fps: 8, loop: true, duration: 3 },
};
const cloneRig = (r: Rig): Rig => ({ ...r, moveProps: r.moveProps ? [...r.moveProps] : null });

export class Mewpon {
  readonly bus = new EventBus<MewponEvents>();
  readonly controller = new AnimationController();
  readonly machine = new StateMachine();
  readonly pet = new PetDirector();
  private assistantState:{expression:ExpressionName;activity:ActivityName|null}={expression:"neutral",activity:null};
  private assistantOwned=false;
  readonly assets: Assets; readonly renderer: Renderer; readonly ready: Promise<void>;
  speed = 1; debug = false; maxFps = 60;
  private expr: ExpressionName = 'neutral'; private exprLocked = false;
  private reactions=new ReactionSequence();
  private expressionDirector=new ExpressionDirector();
  private get temp():ReactionStage|null{return this.reactions.current;}
  private set temp(value:(ReactionStage & {t?:number})|null){if(value)this.reactions.start([value]);else this.reactions.clear();}
  private outfit: OutfitName = 'default';
  private emitted = { expr: 'neutral' as ExpressionName, activity: null as ActivityName | null };
  private time = 0; private ready_ = false;
  look = { x: new Spring(60, 11), y: new Spring(60, 11), ax: 0, ay: 0, last: -99, glance: 0 };
  private hoverS = new Spring(150, 16); private dragRot = new Spring(120, 12); private pop = new Spring(260, 14);
  private hovering = false; private dragging = false; private blinkT = 3; private blinkLeft = 0; private microT=8+Math.random()*7;
  private speech: { lip: LipSync; t: number; src: AudioBufferSourceNode | null; ctx?: AudioContext } | null = null;
  private mouthIdx = 0; mouthLevel = 0;
  private externalSpeech = false;
  setSpeechLevel(value: number): void { this.externalSpeech = value >= 0; this.mouthLevel = value >= 0 ? Math.max(0, Math.min(1, value)) : 0; }
  private travel = { x: 0, dir: 1 };
  private transitionDuration=0.32;
  private lastDt = 1/60; private displayedRig = newRig(); private renderSamples:number[] = []; private totalDraws=0;
  private lastKey = ''; private lastFrame: Frame | null = null; private prev: Frame | null = null; private fade = 1;
  private raf = 0; private lastTs = 0; private fpsEma = 60; private acc = 0; private pendingDt=0; private detach: (() => void) | null = null;
  stage = { dx: 0, dy: 0 };

  constructor(public canvas: HTMLCanvasElement, opts: MewponOptions = {}) {
    this.assets = new Assets(opts.baseUrl ?? 'assets/spritesheets/');
    this.renderer = new Renderer(canvas, this.assets, { pixelated: !!opts.pixelated, transparent: opts.transparent ?? true, background: opts.background ?? '#dfe6f3', scale: opts.scale ?? 1 });
    this.speed = opts.speed ?? 1; this.debug = !!opts.debug; this.maxFps = opts.maxFps ?? 60;
    this.autoBlink = opts.autoBlink ?? true; this.idleGlance = opts.idleGlance ?? true;
    this.controller.bus.on('animationStart', (e) => { this.bus.emit('animationStart', e); this.syncActivity(); });
    this.controller.bus.on('animationComplete', (e) => { this.bus.emit('animationComplete', { name: e.name, type: e.type, interrupted: e.interrupted }); this.syncActivity(); });
    this.machine.bus.on('stateChanged', (e) => this.bus.emit('stateChanged', e));
    this.ready = this.assets.load(undefined, opts.manifest).then(() => { this.ready_ = true; this.bus.emit('ready', undefined); if (opts.autoStart !== false) this.start(); });
    if (opts.interactions !== false) this.detach = attachInteractions(this, typeof opts.interactions === 'object' ? opts.interactions : {});
  }
  autoBlink = true; idleGlance = true;

  enterPlayMode():boolean {
    if(this.assistantOwned)return false;
    this.controller.clear();this.temp=null;this.exprLocked=true;this.pet.enter();this.bus.emit('petChanged',this.getPetState());return true;
  }
  exitPlayMode():void {
    this.pet.exit();this.controller.clear();this.temp=null;this.exprLocked=false;
    this.transitionTo(this.assistantState);this.bus.emit('petChanged',this.getPetState());
  }
  isInPlayMode(){return this.pet.playing;}
  enableAutonomousIdle(value:boolean){this.pet.autonomous=value;}
  setAssistantState(expression:ExpressionName,activity:ActivityName|null,requiresAttention:boolean){
    this.assistantState={expression,activity};this.assistantOwned=requiresAttention;
    if(requiresAttention){this.pet.exit();this.controller.clear();this.temp=null;this.exprLocked=false;}
    if(!this.pet.playing)this.transitionTo({expression,activity});this.bus.emit('petChanged',this.getPetState());
  }
  interact(action:PetAction):boolean {
    if(!PET_ACTIONS.includes(action))throw new Error(`Unknown interaction: ${action}`);
    if(this.assistantOwned)return false;
    this.controller.clear();this.temp=null;
    const chosen=this.pet.start(action);
    if(chosen==='poke')this.temp={name:this.pet.pokes%3===1?'surprised':this.pet.pokes%3===2?'confused':'angry',t:0,dur:1.6,agent:false};
    else if(chosen==='pet'||chosen==='dance')this.temp={name:'happy',t:0,dur:this.pet.duration,agent:false};
    this.bus.emit('petChanged',this.getPetState());return true;
  }
  hitHighFive():boolean {const accepted=this.pet.hitPaw();if(accepted)this.bus.emit('petChanged',this.getPetState());return accepted;}
  getPetState(){return {playing:this.pet.playing,action:this.pet.action,age:this.pet.age,following:this.pet.following,awaitingPaw:this.pet.awaitingPaw,autonomous:this.pet.autonomous,assistantOwned:this.assistantOwned};}

  // ------------------------------------------------------------------ public API
  on<K extends keyof MewponEvents>(e: K, f: (p: MewponEvents[K]) => void): () => void { return this.bus.on(e, f); }
  off<K extends keyof MewponEvents>(e: K, f: (p: MewponEvents[K]) => void): void { this.bus.off(e, f); }

  setExpression(name: ExpressionName, o: { duration?: number; lock?: boolean } = {}): void {
    if(this.pet.playing)this.pet.clear();
    if (!EXPRESSIONS.includes(name)) throw new Error(`Unknown expression: ${name}`);
    if (o.duration && o.duration > 0) this.temp = { name, t: 0, dur: o.duration, agent: true };
    else { this.expr = name; this.temp = null; }
    this.exprLocked = o.lock ?? this.pet.playing; this.syncExpression();
  }
  getExpression(): ExpressionName { return this.temp?.name ?? this.expr; }

  setActivity(name: ActivityName, o: { duration?: number; priority?: number; queue?: boolean } = {}): 'started' | 'interrupted' | 'queued' | 'rejected' {
    if(this.pet.playing){this.pet.clear();this.temp=null;}
    if (!ACTIVITIES.includes(name)) throw new Error(`Unknown activity: ${name}`);
    const r = this.controller.play({ name, type: 'activity', priority: o.priority ?? PRIORITY.activity, duration: o.duration && o.duration > 0 ? o.duration : Infinity, replace: true, data: { anim0: this.time } }, { queue: o.queue });
    this.syncActivity(); return r;
  }
  stopActivity(): void { this.controller.stop({ type: 'activity' }); this.syncActivity(); }
  getActivity(): ActivityName | null { const c = this.controller.current; return c?.type === 'activity' ? (c.name as ActivityName) : null; }

  setOutfit(name: OutfitName): void {
    if(this.pet.playing){this.pet.clear();if(this.getActivity()==='sleeping')this.stopActivity();}
    if (!OUTFITS.includes(name)) throw new Error(`Unknown outfit: ${name}`);
    if (name === this.outfit) return; const from = this.outfit; this.outfit = name; this.pop.kick(-9); this.bus.emit('outfitChanged', { from, to: name });
  }
  getOutfit(): OutfitName { return this.outfit; }

  /** Movement (idle/walk/run/jump/talk) or one-shot (bounce/nod/shake/squish/hop). */
  playAnimation(name: string, o: { duration?: number; priority?: number; queue?: boolean; travel?: boolean; loops?: number } = {}): 'started' | 'interrupted' | 'queued' | 'rejected' {
    if(['dance','wave','spin'].includes(name)){return this.interact(name as PetAction)?'started':'rejected';}
    if(this.pet.playing)this.pet.clear();
    let item;
    if (name in MOVE_DEFS) {
      const d = MOVE_DEFS[name];
      const dur = o.duration ?? (o.loops && d.loop ? (o.loops * (this.frames(d.group).length || 1)) / d.fps : d.duration);
      item = { name, type: 'movement' as const, priority: o.priority ?? PRIORITY.movement, duration: dur, data: { ...d, travel: !!o.travel } };
    } else if ((ONESHOTS as readonly string[]).includes(name)) {
      item = { name, type: 'oneshot' as const, priority: o.priority ?? PRIORITY.reaction, duration: ONESHOT_DEFS[name as OneShotName].duration, data: {} };
    } else throw new Error(`Unknown animation: ${name}`);
    const r = this.controller.play(item, { queue: o.queue }); this.syncActivity(); return r;
  }
  stopAnimation(name?: string): void { this.controller.stop({ name }); }

  /** Drive the mouth from audio. Accepts an AudioBuffer (played unless play:false), or raw mono samples + sampleRate. */
  async speak(audio: AudioBuffer | Float32Array | ArrayBuffer, o: { sampleRate?: number; play?: boolean; windowMs?: number; audioContext?: AudioContext } = {}): Promise<void> {
    this.stopSpeaking(true);
    let samples: Float32Array, rate = o.sampleRate ?? 24000, buf: AudioBuffer | null = null;
    if (typeof AudioBuffer !== 'undefined' && audio instanceof AudioBuffer) { buf = audio; samples = toMono(audio); rate = audio.sampleRate; }
    else if (audio instanceof Float32Array) samples = audio;
    else if (audio instanceof ArrayBuffer) {
      const ctx = o.audioContext ?? new AudioContext(); buf = await ctx.decodeAudioData(audio.slice(0)); samples = toMono(buf); rate = buf.sampleRate;
    } else throw new Error('speak() expects an AudioBuffer, ArrayBuffer or Float32Array');
    const lip = new LipSync(envelope(samples, rate, o.windowMs ?? 20), o.windowMs ?? 20);
    const sp: NonNullable<Mewpon['speech']> = { lip, t: 0, src: null };
    if (buf && o.play !== false && typeof AudioContext !== 'undefined') {
      try {
        const ctx = o.audioContext ?? new AudioContext(); sp.ctx = ctx; const src = ctx.createBufferSource(); src.buffer = buf; src.connect(ctx.destination); src.start(); sp.src = src;
      } catch { /* autoplay blocked: animate silently */ }
    }
    this.speech = sp; this.bus.emit('speechStart', { duration: lip.duration });
    return new Promise<void>((res) => { const off = this.bus.on('speechEnd', () => { off(); res(); }); });
  }
  stopSpeaking(silent = false): void {
    if (!this.speech) return; try { this.speech.src?.stop(); } catch { /* already stopped */ }
    this.speech = null; this.mouthLevel = 0; if (!silent) this.bus.emit('speechEnd', { interrupted: true }); else this.bus.emit('speechEnd', { interrupted: true });
  }
  isSpeaking(): boolean { return !!this.speech; }

  /** Client (viewport) coordinates -> gaze. */
  lookAt(clientX: number, clientY: number): void {
    const r = this.canvas.getBoundingClientRect(); const cx = r.left + r.width / 2 + this.stage.dx, cy = r.top + r.height * 0.9 - 40 + this.stage.dy;
    this.lookAtNormalized((clientX - cx) / (r.width * 0.5), (clientY - cy) / (r.height * 0.5));
  }
  lookAtNormalized(nx: number, ny: number): void { this.look.x.target = clamp(nx, -1, 1); this.look.y.target = clamp(ny, -1, 1); this.look.last = this.time; }

  /** Reaction used by interactions, also callable by the agent. Ignored while the agent owns the character. */
  react(kind: ReactKind): boolean {
    if(this.pet.playing&&(kind==='click'||kind==='pet'||kind==='poke'||kind==='doubleClick'))return this.interact(kind==='doubleClick'?'dance':kind==='click'?'poke':kind);
    const locked = this.isAgentLocked();
    if (kind === 'hover') { this.hovering = true; this.bus.emit('interaction', { kind, accepted: true }); return true; }
    if (locked) { this.bus.emit('interaction', { kind, accepted: false }); return false; }
    const R = (expr: ExpressionName | null, dur: number, anim: OneShotName | null) => {
      if (expr) this.temp = { name: expr, t: 0, dur, agent: false };
      if (anim) this.playAnimation(anim, { priority: PRIORITY.reaction, queue: false });
    };
    switch (kind) {
      case 'click': case 'poke': R('surprised', 0.45, 'squish'); this.reactions.start([{name:'surprised',dur:0.45,agent:false},{name:'happy',dur:1.3,agent:false}]); this.playAnimation('hop', { queue: true, priority: PRIORITY.reaction }); break;
      case 'doubleClick': R('excited', 1.8, 'bounce'); break;
      case 'pet': R('happy', 2.2, 'nod'); break;
      case 'dragStart': this.dragging = true; this.temp = { name: 'surprised', t: 0, dur: 1e9, agent: false }; break;
      case 'dragEnd': this.dragging = false; R('happy', 1, 'bounce'); break;
      default: if ((EXPRESSIONS as readonly string[]).includes(kind)) R(kind as ExpressionName, 2, 'nod');
    }
    this.syncExpression(); this.bus.emit('interaction', { kind, accepted: true }); return true;
  }
  endHover(): void { this.hovering = false; }
  isAgentLocked(): boolean { if(this.pet.playing)return this.assistantOwned;return StateMachine.isAgentLocked(this.ctx()); }
  getState(): MewState { return this.machine.state; }

  reset(): void {
    this.pet.exit();this.assistantOwned=false;
    this.stopSpeaking(true); this.controller.clear(); this.syncActivity(); this.temp = null; this.expr = 'neutral'; this.exprLocked = false;
    this.outfit !== 'default' && this.bus.emit('outfitChanged', { from: this.outfit, to: 'default' }); this.outfit = 'default';
    this.dragging = false; this.hovering = false; this.travel.x = 0; this.look.x.set(0); this.look.y.set(0); this.stage.dx = this.stage.dy = 0; this.syncExpression(); this.prev = null; this.lastFrame = null; this.fade = 1; this.lastKey = ''; this.displayedRig=newRig(); this.expressionDirector.reset();
  }
  setScale(s: number): void { this.renderer.opts.scale = clamp(s, 0.25, 8); }
  setSpeed(s: number): void { this.speed = clamp(s, 0, 4); }
  setTransparent(v: boolean): void { this.renderer.opts.transparent = v; }
  setBackground(c: string): void { this.renderer.opts.background = c; }
  setPixelated(v: boolean): void { this.renderer.opts.pixelated = v; }
  setDebug(v: boolean): void { this.debug = v; }
  getFps(): number { return Math.round(this.fpsEma); }
  getFrames(): readonly Entry[] { return []; }
  /** Names the engine can currently show (from the manifest). */
  getCatalog() { const g = this.assets.manifest.groups; return { expressions: Object.keys(g.expressions), activities: Object.keys(g.actions), outfits: Object.keys(g.outfits), frames: Object.keys(g.frames) }; }

  start(): void { if (this.raf || typeof requestAnimationFrame === 'undefined') return; this.lastTs = 0;this.acc=0;this.pendingDt=0; const loop = (ts: number) => { this.raf = requestAnimationFrame(loop); this.tick(ts); }; this.raf = requestAnimationFrame(loop); }
  stop(): void { if (this.raf) cancelAnimationFrame(this.raf); this.raf = 0; }
  destroy(): void { this.stop(); this.detach?.(); this.stopSpeaking(true); this.bus.clear(); }

  /** Deterministic step + render, used by tests and screenshot tools. */
  advance(seconds: number, step = 1 / 60): void { for (let t = 0; t < seconds - 1e-9; t += step) { this.step(Math.min(step, seconds - t) * this.speed); this.render(); } }

  // ------------------------------------------------------------------ loop
  private tick(ts: number): void {
    if(!this.lastTs){this.lastTs=ts;return;}
    const dtReal=Math.min(0.1,(ts-this.lastTs)/1000);this.lastTs=ts;
    this.acc+=dtReal;this.pendingDt+=dtReal;
    const active=(!!this.pet.action&&this.pet.action!=='nap')||(!!this.controller.current&&this.getActivity()!=='sleeping')||this.hovering||this.dragging||!!this.speech||this.externalSpeech||this.getExpression()!=='neutral';
    const limit=active?this.maxFps:Math.min(30,this.maxFps);
    if(this.acc<1/limit-0.001)return;
    const dt=this.pendingDt;this.pendingDt=0;this.acc=Math.max(0,this.acc-1/limit);this.fpsEma+=(1/dt-this.fpsEma)*0.08;
    if(!this.ready_)return;this.step(dt*this.speed);this.render();
  }

  private ctx() { return { anim: this.controller.current, speaking: !!this.speech || this.externalSpeech, dragging: this.dragging, tempExpr: !!this.temp, exprLocked: this.exprLocked || !!this.temp?.agent }; }

  private step(dt: number): void {
    this.lastDt=dt; this.time += dt; this.fade = Math.min(1, this.fade + dt * 8);
    this.controller.update(dt); this.syncActivity();
    const beforePet=this.pet.action;
    this.pet.step(dt,!this.assistantOwned&&!this.controller.current&&!this.temp&&this.expr==='neutral'&&(!this.exprLocked||this.pet.playing));
    if(beforePet==='spin'&&!this.pet.action)this.displayedRig.rootRot=0;
    if(beforePet!==this.pet.action)this.bus.emit('petChanged',this.getPetState()); 
    this.reactions.step(dt);
    this.syncExpression();
    const L = this.look; L.x.step(dt); L.y.step(dt);
    if (this.idleGlance && this.getExpression()==='neutral' && this.time - L.last > 5 && !this.dragging) { L.glance -= dt; if (L.glance <= 0) { L.glance = 2 + Math.random() * 3; L.x.target = (Math.random() - 0.5) * 0.9; L.y.target = (Math.random() - 0.5) * 0.4; } }
    this.hoverS.target = this.hovering ? 1 : 0; this.hoverS.step(dt);
    this.dragRot.target = this.dragging ? 1 : 0; this.dragRot.step(dt); this.pop.target = 0; this.pop.step(dt);
    if (this.autoBlink && this.getExpression()==='neutral') { this.blinkT -= dt; if (this.blinkT <= 0) { this.blinkLeft = 0.11; this.blinkT = 2.2 + Math.random() * 4; } }
    if (this.blinkLeft > 0) this.blinkLeft -= dt;
    if(this.pet.autonomous&&this.idleGlance&&!this.pet.action&&!this.controller.current&&!this.temp&&!this.exprLocked&&this.expr==='neutral'){this.microT-=dt;if(this.microT<=0){this.temp={name:Math.random()<0.7?'wink':'happy',t:0,dur:0.7,agent:false};this.microT=9+Math.random()*12;}}
    if (this.speech) {
      const s = this.speech; s.t = s.src && s.ctx && false ? 0 : s.t + dt;
      const a = s.lip.amplitudeAt(s.t); this.mouthLevel += (a - this.mouthLevel) * Math.min(1, dt * (a > this.mouthLevel ? 28 : 14));
      if (s.t >= s.lip.duration) { this.speech = null; this.mouthLevel = 0; this.bus.emit('speechEnd', { interrupted: false }); }
    }
    this.syncExpression();
    this.expressionDirector.step(this.getExpression(),dt,Math.max(0.32,this.transitionDuration));
    this.machine.update(this.ctx());
  }

  private frames(group: string): Entry[] { return this.assets.manifest?.groups.frames[group] ?? []; }
  private syncActivity(): void { const a = this.getActivity(); if (a !== this.emitted.activity) { const from = this.emitted.activity; this.emitted.activity = a; this.bus.emit('activityChanged', { from, to: a }); } }
  private syncExpression(): void {
    const e = this.getExpression(); if (e !== this.emitted.expr) { const from = this.emitted.expr; this.emitted.expr = e; this.bus.emit('expressionChanged', { from, to: e }); }
  }

  private compose(): Frame {
    const g=this.assets.manifest.groups,cur=this.controller.current,r=newRig(),disp=this.getExpression();
    const sleeping=this.pet.action==='nap'||this.getActivity()==='sleeping';
    const visualOutfit=sleeping?'sleepy':this.outfit;
    const face=g.expressions[disp];
    const base=visualOutfit==='default'?g.expressions.neutral:g.outfits[visualOutfit];
    const activity=cur?.type==='activity'?cur.name:null;
    activityPose(activity,this.time,cur?.t??this.time,r);
    const action=activity?g.actions[activity]:undefined;
    const props={...(action?.props??{})};
    if(activity==='reading')props.book=g.actions.reading.full;
    if(activity==='cooking')props.hat={...g.actions.cooking.props.hat};
    if(this.outfit==='detective'&&activity==='searching')delete props.magnifier;
    r.propAlpha=Object.keys(props).length?1:0;
    if(cur?.type==='movement'){
      movementPose(cur.name,cur.t,cur.duration,r);
      const data=cur.data as {travel?:boolean};
      if(data.travel&&(cur.name==='walk'||cur.name==='run')){this.travel.x+=this.travel.dir*(cur.name==='run'?70:36)*this.lastDt;if(Math.abs(this.travel.x)>40)this.travel.dir*=-1;r.flip=this.travel.dir<0;}
    }else if(cur?.type==='oneshot')ONESHOT_DEFS[cur.name as OneShotName].apply(cur.t/cur.duration,r);
    if(!(cur?.type==='movement'&&(cur.data as {travel?:boolean}).travel))this.travel.x*=Math.exp(-this.lastDt*6);
    r.x=this.travel.x;
    petPose(this.pet.action,this.pet.age,this.pet.duration,r,this.look.x.x);
    if(this.pet.following&&!this.assistantOwned){r.x+=this.look.x.x*5;r.pawLY-=Math.max(0,Math.sin(this.time*7))*Math.abs(this.look.x.x);r.pawRY-=Math.max(0,-Math.sin(this.time*7))*Math.abs(this.look.x.x);}
    const attention=disp==='neutral'?1:0;
    const lx=this.look.x.x*attention,ly=this.look.y.x*attention;
    r.headDX+=lx*1.25;r.headDY+=ly*0.8-this.hoverS.x*0.5;
    r.headRot+=lx*1.4+this.dragRot.x*1.5*Math.sin(this.time*5);
    r.eyeDX+=lx*1.1;r.eyeDY+=ly*0.7;
    r.sy=clamp(r.sy+this.pop.x*0.001,0.97,1.03);r.sx=clamp(r.sx-this.pop.x*0.001,0.97,1.03);
    if(disp==='neutral'&&this.blinkLeft>0)r.eyeSY=Math.max(0.12,1-Math.sin((this.blinkLeft/0.11)*Math.PI)*0.88);
    if(this.speech || this.externalSpeech)r.mouth=this.mouthLevel;
    // Continuous joint trajectories: state changes never replace the whole body
    // with a differently scaled flattened activity frame.
    const blended=this.displayedRig;
    for(const key of Object.keys(r) as (keyof Rig)[]){
      if(typeof r[key]==='number'){
        const rate=key==='mouth'||key==='eyeSY'?36:3/this.transitionDuration;
        (blended as any)[key]+=(Number(r[key])-Number(blended[key]))*(1-Math.exp(-this.lastDt*rate));
      }
    }
    blended.flip=r.flip;blended.moveProps=r.moveProps;
    // Add the expression after activity smoothing so its body and face finish
    // together; a second filter here would make the gesture trail the face.
    const coordinated=cloneRig(blended),rest=newRig(),gesture=this.expressionDirector.rig;
    for(const key of Object.keys(gesture) as (keyof Rig)[])if(typeof gesture[key]==='number')(coordinated as any)[key]+=Number(gesture[key])-Number(rest[key]);
    return {entry:base,rig:coordinated,opts:{time:this.time,alpha:1,baseEntry:base,faceEntry:face,expression:disp,facePose:{...this.expressionDirector.face.pose},
      activity,outfit:visualOutfit,petAction:this.pet.action,thinking:disp==='thinking',extraProps:props,
      extraFx:[...(action?.fx??[])],debug:this.debug}};
  }

  render(): void {
    if(!this.ready_)return;
    const start=typeof performance!=='undefined'?performance.now():0;
    const frame=this.compose();this.renderer.render(frame,null,1,this.stage.dx,this.stage.dy);this.totalDraws++;
    if(start){this.renderSamples.push(performance.now()-start);if(this.renderSamples.length>240)this.renderSamples.shift();}
  }
  getPerformance(){const sorted=[...this.renderSamples].sort((a,b)=>a-b);return {totalDraws:this.totalDraws,fps:this.getFps(),renderP50ms:sorted[Math.floor(sorted.length*0.5)]??0,renderP95ms:sorted[Math.floor(sorted.length*0.95)]??0,samples:sorted.length,loops:this.raf?1:0};}
  transitionTo(state:{expression?:ExpressionName;activity?:ActivityName|null;duration?:number}){
    if(state.duration!==undefined)this.transitionDuration=clamp(state.duration/1000,0.08,0.8);
    if(state.expression&&state.expression!==this.getExpression())this.setExpression(state.expression);
    if(state.activity!==undefined&&state.activity!==this.getActivity()){
      if(state.activity===null)this.stopActivity();else this.setActivity(state.activity,{queue:false});
    }
  }

}
export default Mewpon;
