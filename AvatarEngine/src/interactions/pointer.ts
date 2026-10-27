import type { Mewpon } from '../index';

export interface InteractionOptions {
  /** called while dragging with the pointer delta (CSS px) and screen coords; overlay shells move the OS window here */
  onDrag?: (dx: number, dy: number, screenX: number, screenY: number) => void;
  /** move the character inside the stage while dragging (web demo). Default true when no onDrag is given. */
  dragMovesStage?: boolean;
  /** pointer events only count when over the character's box (default true) */
  hitTest?: boolean; petAfterMs?: number; doubleClickMs?: number;
}

export function attachInteractions(m: Mewpon, o: InteractionOptions): () => void {
  const c = m.canvas; const hit = o.hitTest !== false; const dbl = o.doubleClickMs ?? 280; const petMs = o.petAfterMs ?? 1600;
  let down: { x: number; y: number; sx: number; sy: number; moved: boolean; head:boolean } | null = null; let lastClick = 0; let clickTimer = 0; let hoverSince = 0; let petted = false;
  const inside = (cx: number, cy: number) => {
    if (!hit) return true; const r = c.getBoundingClientRect(); const b = m.renderer.hitBox; const x = cx - r.left, y = cy - r.top;
    return x >= b.x && x <= b.x + b.w && y >= b.y && y <= b.y + b.h;
  };
  const move = (e: PointerEvent) => {
    m.lookAt(e.clientX, e.clientY);
    if (down) {
      const dx = e.clientX - down.x, dy = e.clientY - down.y;
      if(m.isInPlayMode()&&down.head){m.interact('pet');down.moved=true;return;}
      if (!down.moved && Math.hypot(e.clientX - down.sx, e.clientY - down.sy) > 4) { down.moved = true; m.react('dragStart'); }
      if (down.moved) { if (o.onDrag) o.onDrag(dx, dy, e.screenX, e.screenY); if (o.dragMovesStage ?? !o.onDrag) { m.stage.dx += dx; m.stage.dy += dy; } down.x = e.clientX; down.y = e.clientY; }
      return;
    }
    const h = inside(e.clientX, e.clientY);
    if (h && !hoverSince) { hoverSince = performance.now(); petted = false; m.react('hover'); }
    if (!h && hoverSince) { hoverSince = 0; m.endHover(); }
    if (!m.isInPlayMode() && h && !petted && performance.now() - hoverSince > petMs) { petted = true; m.react('pet'); }
  };
  const downH = (e: PointerEvent) => { if (e.button !== 0 || !inside(e.clientX, e.clientY)) return; down = { x: e.clientX, y: e.clientY, sx: e.clientX, sy: e.clientY, moved: false,head:e.clientY-c.getBoundingClientRect().top<m.renderer.hitBox.y+m.renderer.hitBox.h*0.7 }; try { c.setPointerCapture(e.pointerId); } catch { /* synthetic */ } };
  const up = (e: PointerEvent) => {
    if (!down) return; const d = down; down = null; try { c.releasePointerCapture(e.pointerId); } catch { /* synthetic */ }
    if (d.moved) { if(!m.isInPlayMode()||!d.head)m.react('dragEnd'); return; }
    if(m.isInPlayMode()){const b=m.renderer.hitBox,x=e.clientX-c.getBoundingClientRect().left,y=e.clientY-c.getBoundingClientRect().top;if(m.pet.awaitingPaw&&x>b.x+b.w*0.48&&y>b.y+b.h*0.52){m.hitHighFive();return;}m.interact(d.head?'pet':'poke');return;}
    const now = performance.now();
    if (now - lastClick < dbl) { clearTimeout(clickTimer); lastClick = 0; m.react('doubleClick'); }
    else { lastClick = now; clickTimer = window.setTimeout(() => m.react('click'), dbl); }
  };
  const leave = () => { hoverSince = 0; m.endHover(); m.lookAtNormalized(0, 0); };
  window.addEventListener('pointermove', move); c.addEventListener('pointerdown', downH); window.addEventListener('pointerup', up); c.addEventListener('pointerleave', leave);
  return () => { window.removeEventListener('pointermove', move); c.removeEventListener('pointerdown', downH); window.removeEventListener('pointerup', up); c.removeEventListener('pointerleave', leave); clearTimeout(clickTimer); };
}
