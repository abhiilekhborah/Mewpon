import { describe, it, expect } from 'vitest';
import { AnimationController, PRIORITY } from '../../src/core/controller';
import { StateMachine } from '../../src/core/statemachine';
import { EventBus } from '../../src/core/events';
import { amplitudeToIndex, envelope, LipSync } from '../../src/core/lipsync';
import { keys, Spring } from '../../src/core/spring';
import { EXPRESSIONS, ACTIVITIES, OUTFITS, MOVEMENTS } from '../../src/core/types';
import { EXPRESSION_DEFS } from '../../src/expressions';
import { ACTIVITY_DEFS } from '../../src/activities';
import { newRig } from '../../src/core/types';

const it_ = (name: string, type: any, priority: number, duration: number, extra: any = {}) => ({ name, type, priority, duration, ...extra });

describe('AnimationController', () => {
  it('starts, completes and emits events', () => {
    const c = new AnimationController(); const ev: string[] = [];
    c.bus.on('animationStart', (e) => ev.push('s:' + e.name)); c.bus.on('animationComplete', (e) => ev.push(`c:${e.name}:${e.interrupted}`));
    expect(c.play(it_('jump', 'movement', 30, 0.5))).toBe('started'); c.update(0.3); expect(c.current?.name).toBe('jump'); c.update(0.3);
    expect(c.current).toBeNull(); expect(ev).toEqual(['s:jump', 'c:jump:false']);
  });
  it('higher priority interrupts; lower queues; completion order respects priority', () => {
    const c = new AnimationController(); const done: string[] = []; c.bus.on('animationComplete', (e) => done.push(e.name + (e.interrupted ? '!' : '')));
    c.play(it_('walk', 'movement', 30, 1));
    expect(c.play(it_('bounce', 'oneshot', 20, 0.2))).toBe('queued');
    expect(c.play(it_('talk', 'movement', 35, 0.2))).toBe('interrupted');
    expect(c.current?.name).toBe('talk'); c.update(0.25); expect(c.current?.name).toBe('bounce'); c.update(0.25);
    expect(done).toEqual(['walk!', 'talk', 'bounce']);
  });
  it('rejects when queue:false and cannot preempt', () => {
    const c = new AnimationController(); c.play(it_('typing', 'activity', 50, Infinity));
    expect(c.play(it_('bounce', 'oneshot', 20, 0.5), { queue: false })).toBe('rejected');
  });
  it('replace lets an equal-priority activity swap in', () => {
    const c = new AnimationController(); c.play(it_('typing', 'activity', 50, Infinity, { replace: true }));
    expect(c.play(it_('reading', 'activity', 50, Infinity, { replace: true }))).toBe('interrupted'); expect(c.current?.name).toBe('reading');
  });
  it('non-interruptible items are not preempted', () => {
    const c = new AnimationController(); c.play(it_('a', 'movement', 30, 1, { interruptible: false }));
    expect(c.play(it_('b', 'activity', 90, 1))).toBe('queued');
  });
  it('stop() removes the running item and queued matches', () => {
    const c = new AnimationController(); c.play(it_('x', 'activity', 50, Infinity)); c.play(it_('y', 'oneshot', 20, 1)); c.stop({ type: 'activity' });
    expect(c.current?.name).toBe('y');
  });
});

describe('StateMachine', () => {
  const base = { anim: null, speaking: false, dragging: false, tempExpr: false, exprLocked: false };
  it('derives states and agent lock', () => {
    const act: any = { type: 'activity', priority: 50 };
    expect(StateMachine.derive(base)).toBe('idle'); expect(StateMachine.derive({ ...base, anim: act })).toBe('activity');
    expect(StateMachine.derive({ ...base, speaking: true })).toBe('speaking');
    expect(StateMachine.isAgentLocked({ ...base, anim: act })).toBe(true); expect(StateMachine.isAgentLocked({ ...base, speaking: true })).toBe(true);
    expect(StateMachine.isAgentLocked({ ...base, anim: { type: 'reaction', priority: 20 } as any })).toBe(false);
  });
  it('emits stateChanged once per transition', () => {
    const m = new StateMachine(); let n = 0; m.bus.on('stateChanged', () => n++);
    m.update(base); m.update({ ...base, speaking: true }); m.update({ ...base, speaking: true }); m.update(base); expect(n).toBe(2);
  });
});

describe('lip sync', () => {
  it('envelope is normalised and gated', () => {
    const sr = 8000, s = new Float32Array(sr); for (let i = 0; i < sr / 2; i++) s[i] = Math.sin(i * 0.3) * 0.8;
    const e = envelope(s, sr, 20); expect(Math.max(...e)).toBeLessThanOrEqual(1); expect(e[2]).toBeGreaterThan(0.8); expect(e[40]).toBeLessThan(0.01);
    const l = new LipSync(e, 20); expect(l.duration).toBeCloseTo(1, 1); expect(l.amplitudeAt(0.9)).toBeLessThan(0.05);
  });
  it('maps amplitude to monotonic frame index', () => {
    expect(amplitudeToIndex(0.01, 8)).toBe(0); expect(amplitudeToIndex(1, 8)).toBe(7);
    let p = 0; for (let a = 0; a <= 1; a += 0.05) { const i = amplitudeToIndex(a, 8); expect(i).toBeGreaterThanOrEqual(p); p = i; }
  });
});

describe('helpers & tables', () => {
  it('spring converges', () => { const s = new Spring(); s.target = 1; for (let i = 0; i < 120; i++) s.step(1 / 60); expect(s.x).toBeCloseTo(1, 2); });
  it('keys interpolates', () => { expect(keys([[0, 0], [1, 10]], 0.5)).toBeCloseTo(5); expect(keys([[0, 0], [1, 10]], 2)).toBe(10); });
  it('event bus once/off', () => { const b = new EventBus<{ a: number }>(); let n = 0; b.once('a', () => n++); b.emit('a', 1); b.emit('a', 1); expect(n).toBe(1); });
  it('every spec expression/activity has a definition and motion produces finite numbers', () => {
    expect(EXPRESSIONS.length).toBe(14); expect(ACTIVITIES.length).toBe(11); expect(OUTFITS.length).toBe(10); expect(MOVEMENTS.length).toBe(5);
    for (const e of EXPRESSIONS) for (let t = 0; t < 5; t += 0.37) { const r = newRig(); EXPRESSION_DEFS[e].motion(t, t, r); expect(Object.values(r).every((v) => typeof v !== 'number' || Number.isFinite(v))).toBe(true); }
    for (const a of ACTIVITIES) for (let t = 0; t < 9; t += 0.31) { const r = newRig(); ACTIVITY_DEFS[a].motion(t, r); expect(Object.values(r).every((v) => typeof v !== 'number' || Number.isFinite(v))).toBe(true); }
  });
  it('manifest contains every spec asset', async () => {
    const m = (await import('../../assets/spritesheets/manifest.json', { with: { type: 'json' } })).default as any;
    for (const e of EXPRESSIONS) expect(m.groups.expressions[e]).toBeTruthy(); for (const a of ACTIVITIES) expect(a==='sleeping'?m.groups.outfits.sleepy:m.groups.actions[a]).toBeTruthy();
    for (const o of OUTFITS) expect(m.groups.outfits[o]).toBeTruthy(); for (const f of ['idle', 'walk', 'run', 'jump', 'talk']) expect(m.groups.frames[f].length).toBeGreaterThan(5);
  });
});
