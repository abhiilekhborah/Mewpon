export type Listener<T = any> = (payload: T) => void;
export class EventBus<E extends Record<string, any>> {
  private m = new Map<keyof E, Set<Listener>>();
  on<K extends keyof E>(k: K, f: Listener<E[K]>): () => void {
    let s = this.m.get(k); if (!s) this.m.set(k, (s = new Set())); s.add(f); return () => this.off(k, f);
  }
  once<K extends keyof E>(k: K, f: Listener<E[K]>): () => void {
    const off = this.on(k, (p) => { off(); f(p); }); return off;
  }
  off<K extends keyof E>(k: K, f: Listener<E[K]>): void { this.m.get(k)?.delete(f); }
  emit<K extends keyof E>(k: K, p: E[K]): void {
    const s = this.m.get(k); if (!s) return;
    for (const f of [...s]) { try { f(p); } catch (e) { console.error('[mewpon] listener error', e); } }
  }
  clear(): void { this.m.clear(); }
}
