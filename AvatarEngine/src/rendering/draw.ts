import type { Assets } from '../core/assets';
import type { Entry, Layer, Rig } from '../core/types';
import { bodyPoint } from '../core/rigmotion';
import { drawMesh } from './mesh';
import { FaceRig, drawFaceRig, type FacePose } from './face';
import type { ExpressionName } from '../core/types';
import { pixelGrid } from './pixelgrid';

export interface DrawOpts {
  baseEntry?: Entry; faceEntry?: Entry; activity?: string | null; outfit?: string; thinking?: boolean;
  time: number; alpha: number; expression?:ExpressionName; facePose?:FacePose; headOverride?: Layer | null; petAction?: string|null;
  extraProps?: Record<string, Layer>; extraFx?: Layer[]; hideProps?: string[]; debug?: boolean;
}
const RAD = Math.PI / 180;

function blit(ctx: CanvasRenderingContext2D, a: Assets, l: Layer): void {
  const im = ctx.imageSmoothingEnabled ? a.img(l) : a.pixelSource(l); if (im) ctx.drawImage(im, l.ox, l.oy, l.w, l.h);
}

/** Draws one pose in anchor space (0,0 = bottom-centre of the body), 1 unit = 1 source pixel. */
export function drawEntry(ctx: CanvasRenderingContext2D, a: Assets, e: Entry, r: Rig, o: DrawOpts): void {
  ctx.save();
  ctx.globalAlpha *= r.alpha * o.alpha;
  ctx.translate(r.x, r.y);
  ctx.translate(0,-35);ctx.rotate(r.rootRot*RAD);ctx.translate(0,35);
  if (r.flip) ctx.scale(-1, 1);
  ctx.translate(0, r.bodyDY); ctx.scale(r.sx, r.sy);
  const base = o.baseEntry ?? e;
  const facialRig=(o.outfit??'default')==='default';
  const pawsMoving = Math.abs(r.pawLY)+Math.abs(r.pawRY)+Math.abs(r.pawLX)+Math.abs(r.pawRX)>0.015;
  if (base.head && base.body) {
    if(pawsMoving) drawMesh(ctx,a,base.body,(x,y)=>bodyPoint(x,y,r)); else blit(ctx,a,base.body);
    ctx.save();
    const headPose=base;
    const [hx,hy]=headPose.headPivot??[0,-20];
    ctx.translate(hx+r.headDX,hy+r.headDY);ctx.rotate(r.headRot*RAD);ctx.translate(-hx,-hy);
    if((o.outfit??'default')==='default' && Math.abs(r.earL)+Math.abs(r.earR)>0.2) {
      drawMesh(ctx,a,headPose.head!,(x,y)=>{
        const upper=Math.max(0,Math.min(1,(-y-48)/18));
        const left=Math.exp(-Math.pow((x+26)/13,2))*upper;
        const right=Math.exp(-Math.pow((x-30)/12,2))*upper;
        return [x+left*r.earL-right*r.earR,y-left*r.earL*0.5-right*r.earR*0.4];
      },8,8);
    } else blit(ctx,a,headPose.head!);
    // A fixed original head; only the small facial geometry changes.
    if(o.outfit==='summer'&&o.facePose)drawFaceRig(ctx,o.facePose,r,{eyes:false,mouthX:9,mouthY:-31,blush:false});
    else if(facialRig&&o.facePose)drawFaceRig(ctx,o.facePose,r);
    else for(const eye of headPose.eyes??[])drawEye(ctx,a,eye,r,0,0);
    if(o.activity==='listening'){ctx.save();ctx.globalAlpha*=0.25+Math.max(0,Math.sin(o.time*3))*0.45;ctx.fillStyle='#9cdcf4';ctx.beginPath();ctx.arc(-29,-27,1,0,Math.PI*2);ctx.fill();ctx.restore();}
    if(headPose.sprout){const s=headPose.sprout;ctx.save();const px=s.px??0,py=s.py??0;ctx.translate(px,py);ctx.rotate(r.sproutRot*RAD);ctx.translate(-px,-py);blit(ctx,a,s);ctx.restore();}
    ctx.restore();
  } else blit(ctx,a,base.full);
  if(r.laptopAlpha>0.01) {
    const source=a.manifest.groups.actions.typing.full;
    ctx.save();ctx.scale(1/r.sx,1/r.sy);ctx.translate(0,-r.bodyDY);ctx.globalAlpha*=r.laptopAlpha;ctx.translate(0,(1-r.laptopAlpha)*3);ctx.beginPath();ctx.moveTo(5,-3);ctx.lineTo(13,-32);ctx.lineTo(53,-37);ctx.lineTo(48,-5);ctx.lineTo(15,1);ctx.closePath();ctx.clip();blit(ctx,a,source);
    ctx.globalAlpha*=0.035+Math.sin(o.time*2.4)*0.02;ctx.fillStyle='#a7dfff';ctx.fillRect(13,-32,39,26);ctx.restore();
    // Foreground hand pass: shared body texture and deformation, constrained to
    // the actual paw regions so the laptop remains pinned in root coordinates.
    if(base.body){ctx.save();ctx.beginPath();ctx.ellipse(-7+r.pawLX,-6+r.pawLY,9,6,0,0,Math.PI*2);ctx.ellipse(20+r.pawRX,-6+r.pawRY,8,6,0,0,Math.PI*2);ctx.clip();drawMesh(ctx,a,base.body,(x,y)=>bodyPoint(x,y,r));ctx.restore();}
  }
  if(o.thinking){ctx.save();ctx.fillStyle='#89bde1';for(let i=0;i<3;i++){ctx.globalAlpha=r.alpha*(0.35+0.4*Math.max(0,Math.sin(o.time*2-i*0.7)));ctx.beginPath();ctx.arc(35+i*5,-73-i*3,1.2+i*0.15,0,Math.PI*2);ctx.fill();}ctx.restore();}

  const fx = [...e.fx, ...(o.extraFx ?? [])].filter((f) => f.kind !== 'shadow');
  fx.forEach((f, i) => {
    ctx.save();
    const cx = f.ox + f.w / 2, cy = f.oy + f.h / 2;
    const fl = Math.sin(o.time * 2.2 + i * 1.7) * 1.8 * r.fxFloat;
    ctx.translate(cx, cy + r.fxDY + fl); ctx.scale(r.fxScale, r.fxScale); ctx.translate(-cx, -cy);
    ctx.globalAlpha *= r.fxAlpha; blit(ctx, a, f); ctx.restore();
  });
  const props = { ...e.props, ...(o.extraProps ?? {}) };
  for (const [name, p] of Object.entries(props)) {
    if (o.hideProps?.includes(name)) continue;
    ctx.save(); ctx.globalAlpha*=r.propAlpha;
    if(name==='hat'){ctx.translate(r.headDX,r.headDY);ctx.translate(0,-20);ctx.rotate(r.headRot*RAD);ctx.translate(0,20);blit(ctx,a,p);ctx.restore();continue;}
    if (!r.moveProps || r.moveProps.includes(name)) {
      const px = p.px ?? p.ox + p.w / 2, py = p.py ?? p.oy + p.h / 2;
      if(name==='hat'){ctx.translate(r.headDX,r.headDY);ctx.translate(0,-20);ctx.rotate(r.headRot*RAD);ctx.translate(0,20);}
      ctx.translate(px + r.propDX + (name==='hat'?0:r.pawRX), py + r.propDY + (name==='hat'?0:r.pawRY)); ctx.rotate(r.propRot * RAD); ctx.scale(r.propScale, r.propScale); ctx.translate(-px, -py);
    }
    if(name==='book'){
      ctx.beginPath();ctx.moveTo(-19,-30);ctx.lineTo(7,-26);ctx.lineTo(29,-30);ctx.lineTo(28,-6);ctx.lineTo(7,0);ctx.lineTo(-19,-4);ctx.closePath();ctx.clip();blit(ctx,a,p);
      if(r.page>0.02){ctx.fillStyle='#c7dcf0';ctx.beginPath();ctx.moveTo(7,-25);ctx.lineTo(7+(1-r.page)*20,-29);ctx.lineTo(7+(1-r.page)*20,-7);ctx.lineTo(7,-2);ctx.fill();}
    }else blit(ctx, a, p); ctx.restore();
  }
  if(o.activity==='cooking'&&r.food>0.1){ctx.save();ctx.fillStyle='#e9c777';ctx.fillRect(59+r.pawRX,-27+r.propDY-r.food,6,3);ctx.fillStyle='#825838';ctx.fillRect(60+r.pawRX,-26+r.propDY-r.food,4,1);ctx.restore();}
  if(o.petAction==='highFive'){ctx.save();ctx.strokeStyle='#8bd4e8';ctx.globalAlpha=0.5+Math.sin(o.time*5)*0.3;ctx.lineWidth=1;ctx.strokeRect(12+r.pawRX,-14+r.pawRY,15,15);ctx.restore();}
  if(r.celebration>0.1){ctx.save();ctx.globalAlpha=r.celebration;for(let i=0;i<7;i++){ctx.fillStyle=i%2?'#efa8c1':'#7ccbdc';ctx.fillRect(Math.cos(i*2.4+o.time)*48,-45+Math.sin(i*2.4+o.time)*29,2,2);}ctx.restore();}
  if (o.debug) {
    ctx.strokeStyle = 'rgba(255,0,80,.9)'; ctx.lineWidth = 0.5; ctx.strokeRect(e.full.ox, e.full.oy, e.full.w, e.full.h);
    const [hx, hy] = e.headPivot ?? [0, -20]; ctx.strokeStyle = 'rgba(0,160,255,.9)';
    ctx.beginPath(); ctx.moveTo(hx - 3, hy); ctx.lineTo(hx + 3, hy); ctx.moveTo(hx, hy - 3); ctx.lineTo(hx, hy + 3); ctx.stroke();
    ctx.strokeStyle = 'rgba(0,200,0,.9)'; ctx.beginPath(); ctx.moveTo(-4, 0); ctx.lineTo(4, 0); ctx.moveTo(0, -4); ctx.lineTo(0, 4); ctx.stroke();
    if (e.sprout) { ctx.fillStyle = 'rgba(255,160,0,.9)'; ctx.fillRect((e.sprout.px ?? 0) - 1, (e.sprout.py ?? 0) - 1, 2, 2); }
    for (const eye of e.eyes ?? []) { ctx.strokeStyle = 'rgba(160,0,255,.9)'; ctx.strokeRect(eye.ox, eye.oy, eye.w, eye.h); }
  }
  ctx.restore();
}

function drawEye(ctx:CanvasRenderingContext2D,a:Assets,l:Layer,r:Rig,dx:number,dy:number){ctx.save();const cx=(l.cx??l.ox+l.w/2)+dx,cy=(l.cy??l.oy+l.h/2)+dy;ctx.translate(cx+r.eyeDX,cy+r.eyeDY);ctx.scale(1,r.eyeSY);ctx.translate(-cx+dx,-cy+dy);blit(ctx,a,l);ctx.restore();}

export interface Frame { entry: Entry; rig: Rig; opts: DrawOpts }

export class Renderer {
  ctx: CanvasRenderingContext2D;
  /** CSS-pixel rectangle of the character on screen (for hit-testing). */
  hitBox = { x: 0, y: 0, w: 0, h: 0 };
  unit = 1; cw = 0; ch = 0; dpr = 1;
  private faceRig=new FaceRig();private faceTime=0;
  private retainedProps:Record<string,Layer>={};
  private pixels:HTMLCanvasElement;private pixelContext:CanvasRenderingContext2D;
  constructor(public canvas: HTMLCanvasElement, public assets: Assets,
              public opts = { pixelated: false, transparent: true, background: '#dfe6f3', scale: 1 }) {
    this.ctx = canvas.getContext('2d')!;
    this.pixels=document.createElement('canvas');this.pixelContext=this.pixels.getContext('2d')!;
    canvas.style.imageRendering=opts.pixelated?'pixelated':'auto';
  }
  resize(): void {
    this.dpr = typeof window !== 'undefined' ? window.devicePixelRatio || 1 : 1;
    const cw = this.canvas.clientWidth || this.cw || 1, ch = this.canvas.clientHeight || this.ch || 1;
    this.cw = cw; this.ch = ch;
    const grid=pixelGrid(cw,ch,this.dpr,this.opts.scale,this.opts.pixelated),W=grid.backingWidth,H=grid.backingHeight;
    if (this.canvas.width !== W || this.canvas.height !== H) { this.canvas.width = W; this.canvas.height = H; }
    this.unit = grid.unit;
  }
  /** Draw prev (crossfade source, optional) then current. */
  render(cur: Frame, prev: Frame | null, fade: number, stageDX = 0, stageDY = 0): void {
    this.resize();
    const { canvas } = this;
    const screen=this.ctx;
    // Rasterize deformed joints once on a logical source-pixel grid. Scaling
    // individual triangles directly on Retina pixels created thin soft seams.
    const pixel=this.opts.pixelated,ctx=pixel?this.pixelContext:screen;
    if(pixel){const w=Math.ceil(canvas.width/this.unit),h=Math.ceil(canvas.height/this.unit);if(this.pixels.width!==w||this.pixels.height!==h){this.pixels.width=w;this.pixels.height=h;}}
    ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.globalAlpha = 1;
    if (this.opts.transparent) ctx.clearRect(0, 0, ctx.canvas.width, ctx.canvas.height);
    else { ctx.fillStyle = this.opts.background; ctx.fillRect(0, 0, ctx.canvas.width, ctx.canvas.height); }
    ctx.imageSmoothingEnabled = !this.opts.pixelated; ctx.imageSmoothingQuality = 'high';
    const ax = Math.round((this.cw / 2 + stageDX) * this.dpr), ay = Math.round((this.ch * 0.9 + stageDY) * this.dpr);
    const rasterUnit=pixel?1:this.unit;
    ctx.setTransform(rasterUnit,0,0,rasterUnit,pixel?Math.round(ax/this.unit):ax,pixel?Math.round(ay/this.unit):ay);
    // soft ground shadow
    const jump = Math.max(0, -cur.rig.y);
    ctx.save(); ctx.globalAlpha = 0.16 / (1 + jump * 0.04); ctx.fillStyle = '#2b3a67';
    ctx.beginPath(); ctx.ellipse(cur.rig.x, 1.5, 30 / (1 + jump * 0.02), 4.5, 0, 0, Math.PI * 2); ctx.fill(); ctx.restore();
    // Joint targets interpolate; the expression art itself is never overlaid
    // with a previous head, even for a single transition frame.
    if(cur.opts.extraProps&&Object.keys(cur.opts.extraProps).length)this.retainedProps=cur.opts.extraProps;
    const face=cur.opts.facePose??this.faceRig.step(cur.opts.expression??'neutral',Math.max(0,cur.opts.time-this.faceTime));this.faceTime=cur.opts.time;
    drawEntry(ctx,this.assets,cur.entry,cur.rig,{...cur.opts,facePose:face,extraProps:this.retainedProps,alpha:1});
    const f = cur.entry.full, s = this.unit / this.dpr;
    const hw = f.w * cur.rig.sx * s, hh = f.h * cur.rig.sy * s;
    this.hitBox = { x: this.cw / 2 + stageDX + cur.rig.x * s + (f.ox * s) * (cur.rig.flip ? -1 : 1) - (cur.rig.flip ? hw : 0), y: this.ch * 0.9 + stageDY + (cur.rig.y + cur.rig.bodyDY + f.oy) * s, w: hw, h: hh };
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    if(pixel){screen.setTransform(1,0,0,1,0,0);screen.clearRect(0,0,canvas.width,canvas.height);screen.imageSmoothingEnabled=false;screen.drawImage(this.pixels,0,0,this.pixels.width*this.unit,this.pixels.height*this.unit);}
  }
}
