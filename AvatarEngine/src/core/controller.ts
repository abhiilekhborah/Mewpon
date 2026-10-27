import { EventBus } from './events';

export const PRIORITY = { idle: 0, hover: 10, reaction: 20, movement: 30, speech: 40, activity: 50, system: 90 } as const;
export type AnimType = 'activity' | 'movement' | 'reaction' | 'oneshot';
export interface AnimItem {
  name: string; type: AnimType; priority: number; duration: number;
  interruptible?: boolean; /** preempt an equal-priority current item (used for activity replacement) */ replace?: boolean;
  data?: any;
}
export interface Active extends AnimItem { t: number; id: number }
export interface AnimEvents {
  animationStart: { name: string; type: AnimType; id: number };
  animationComplete: { name: string; type: AnimType; id: number; interrupted: boolean };
}
export type PlayResult = 'started' | 'interrupted' | 'queued' | 'rejected';

/** Priority queue with interruption. One item runs at a time; completion events fire for natural end and interruption. */
export class AnimationController {
  bus = new EventBus<AnimEvents>();
  current: Active | null = null;
  queue: AnimItem[] = [];
  maxQueue = 16;
  private nextId = 1;

  play(item: AnimItem, opts: { queue?: boolean } = {}): PlayResult {
    const cur = this.current;
    if (!cur) { this.start(item); return 'started'; }
    const pre = item.priority > cur.priority || (item.replace === true && item.priority >= cur.priority);
    if (pre && cur.interruptible !== false) { this.finish(cur, true); this.start(item); return 'interrupted'; }
    if (opts.queue === false || this.queue.length >= this.maxQueue) return 'rejected';
    let i = this.queue.length; while (i > 0 && this.queue[i - 1].priority < item.priority) i--;
    this.queue.splice(i, 0, item); return 'queued';
  }
  update(dt: number): void {
    const cur = this.current; if (!cur) return;
    cur.t += dt;
    if (cur.t >= cur.duration) { this.finish(cur, false); this.startNext(); }
  }
  /** Stop the running item and/or drop queued ones matching name/type. */
  stop(match: { name?: string; type?: AnimType } = {}): boolean {
    const ok = (a: AnimItem) => (!match.name || a.name === match.name) && (!match.type || a.type === match.type);
    const before = this.queue.length; this.queue = this.queue.filter((q) => !ok(q));
    let stopped = before !== this.queue.length;
    if (this.current && ok(this.current)) { this.finish(this.current, true); this.startNext(); stopped = true; }
    return stopped;
  }
  clear(): void { this.queue = []; if (this.current) this.finish(this.current, true); }
  progress(): number { const c = this.current; return c && isFinite(c.duration) ? Math.min(1, c.t / c.duration) : 0; }

  private start(item: AnimItem): void {
    this.current = { ...item, t: 0, id: this.nextId++ };
    this.bus.emit('animationStart', { name: item.name, type: item.type, id: this.current.id });
  }
  private startNext(): void { if (!this.current && this.queue.length) this.start(this.queue.shift()!); }
  private finish(a: Active, interrupted: boolean): void {
    if (this.current === a) this.current = null;
    this.bus.emit('animationComplete', { name: a.name, type: a.type, id: a.id, interrupted });
  }
}
