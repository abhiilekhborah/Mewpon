import { EventBus } from './events';
import { Active, PRIORITY } from './controller';

export type MewState = 'idle' | 'expressing' | 'reacting' | 'moving' | 'speaking' | 'activity' | 'dragging';
export interface StateCtx { anim: Active | null; speaking: boolean; dragging: boolean; tempExpr: boolean; exprLocked: boolean }

/** Derives the high-level state from the primitives and decides whether the agent owns the character. */
export class StateMachine {
  bus = new EventBus<{ stateChanged: { from: MewState; to: MewState } }>();
  state: MewState = 'idle';
  history: MewState[] = ['idle'];
  static derive(c: StateCtx): MewState {
    if (c.anim?.type === 'activity') return 'activity';
    if (c.dragging) return 'dragging';
    if (c.speaking) return 'speaking';
    if (c.anim?.type === 'movement') return 'moving';
    if (c.anim) return 'reacting';
    return c.tempExpr ? 'expressing' : 'idle';
  }
  /** Agent-controlled states cannot be changed by user interaction (click/hover/drag-pose). */
  static isAgentLocked(c: StateCtx): boolean {
    return c.anim?.type === 'activity' || c.speaking || c.exprLocked || (!!c.anim && c.anim.priority >= PRIORITY.speech);
  }
  update(c: StateCtx): MewState {
    const to = StateMachine.derive(c);
    if (to !== this.state) {
      const from = this.state; this.state = to; this.history.push(to); if (this.history.length > 50) this.history.shift();
      this.bus.emit('stateChanged', { from, to });
    }
    return to;
  }
}
