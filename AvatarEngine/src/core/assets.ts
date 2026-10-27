import type { Entry, Layer, Manifest } from './types';
import { exteriorResidue } from '../rendering/outline';

declare global { interface Window { MEWPON_MANIFEST?: Manifest; MEWPON_TEXTURES?:Record<string,string> } }

/** Loads the manifest (inline window.MEWPON_MANIFEST for file://, else fetch) and every sprite PNG. */
export class Assets {
  manifest!: Manifest;
  private imgs = new Map<string, HTMLImageElement>();
  private pixels = new Map<string, HTMLCanvasElement>();
  private owners=new Map<string,Entry>();
  private outlines=new Map<string,Uint8Array>();
  /** talk frame indices ordered from closed -> wide open (computed from pixels; identity if unreadable). */
  mouthOrder: number[] = [];
  constructor(public baseUrl = 'assets/spritesheets/') { if (!this.baseUrl.endsWith('/')) this.baseUrl += '/'; }

  async load(onProgress?: (done: number, total: number) => void, manifest?: Manifest): Promise<void> {
    if (manifest) this.manifest = manifest;
    else if (typeof window !== 'undefined' && window.MEWPON_MANIFEST) this.manifest = window.MEWPON_MANIFEST;
    else this.manifest = await (await fetch(this.baseUrl + 'manifest.json')).json();
    const files = new Set<string>();
    const add = (l?: Layer | null) => { if (l) files.add(l.file); };
    const addEntry = (e: Entry) => { add(e.full); add(e.head); add(e.body); add(e.sprout); e.eyes?.forEach(add); e.fx.forEach(add); Object.values(e.props).forEach(add);for(const l of [e.full,e.head,e.body,e.sprout])if(l)this.owners.set(l.file,e); };
    const g = this.manifest.groups;
    [g.expressions, g.actions, g.outfits].forEach((grp) => Object.values(grp).forEach(addEntry));
    Object.values(g.frames).forEach((arr) => arr.forEach(addEntry));
    const list = [...files]; let done = 0;
    await Promise.all(list.map((f) => new Promise<void>((res, reject) => {
      const im = new Image(); im.onload = () => { done++; onProgress?.(done, list.length); res(); };
      im.onerror=()=>reject(new Error(`Missing avatar texture: ${f}`));
      im.src = (typeof window!=='undefined'?window.MEWPON_TEXTURES?.[f]:undefined) ?? this.baseUrl + f; this.imgs.set(f, im);
    })));
    this.analyzeTalk();
  }
  img(l: Layer): HTMLImageElement | undefined { const i = this.imgs.get(l.file); return i && i.complete && i.naturalWidth ? i : undefined; }
  /** Cache exterior cleanup using the whole pose's silhouette. Cleaning a split
   * head/body individually would mistake white fur at the cut for background. */
  pixelSource(l:Layer):CanvasImageSource|undefined {
    const cached=this.pixels.get(l.file);if(cached)return cached;
    const image=this.img(l);if(!image)return;
    const c=document.createElement('canvas');c.width=image.naturalWidth;c.height=image.naturalHeight;
    const ctx=c.getContext('2d',{willReadFrequently:true})!;ctx.drawImage(image,0,0);
    try{
      const data=ctx.getImageData(0,0,c.width,c.height),owner=this.owners.get(l.file);
      const full=owner?.full??l;let mask=this.outlines.get(full.file);
      if(!mask){const image=this.img(full)!;const f=document.createElement('canvas');f.width=full.w;f.height=full.h;const x=f.getContext('2d',{willReadFrequently:true})!;x.drawImage(image,0,0);mask=exteriorResidue(x.getImageData(0,0,f.width,f.height).data,f.width,f.height);this.outlines.set(full.file,mask);}
      for(let y=0;y<c.height;y++)for(let x=0;x<c.width;x++){
        const i=(y*c.width+x)*4,fx=x+l.ox-full.ox,fy=y+l.oy-full.oy;
        if(data.data[i+3]<=16||(fx>=0&&fy>=0&&fx<full.w&&fy<full.h&&mask[fy*full.w+fx]))data.data[i+3]=0;
        // The old extraction removed teal fill but left the original sprout's
        // outer contour inside the head. Erase its full above-dome footprint;
        // only the separately rigged sprout may occupy this region.
        if(l.file==='expressions/neutral__head.png'&&owner?.sprout){const s=owner.sprout,wx=x+l.ox,wy=y+l.oy;if(wx>=s.ox-3&&wx<s.ox+s.w+3&&wy<(owner.domeY??-72))data.data[i+3]=0;}
      }
      const mouth=l.file==='expressions/neutral__body.png'||l.file==='expressions/neutral__head.png'?{x:15,y:-18,rx:6,ry:4}:l.file==='outfits/summer__head.png'?{x:9,y:-31,rx:4,ry:3}:null;
      if(mouth){
        // Remove only the tiny baked mouth. Original neutral eyes were already
        // separated in the source assets; expressive paths now own the face.
        const fullImage=this.img(full)!;const sample=document.createElement('canvas');sample.width=full.w;sample.height=full.h;
        const sc=sample.getContext('2d',{willReadFrequently:true})!;sc.drawImage(fullImage,0,0);const source=sc.getImageData(0,0,full.w,full.h).data;
        for(let y=0;y<c.height;y++)for(let x=0;x<c.width;x++){
          const wx=x+l.ox,wy=y+l.oy,i=(y*c.width+x)*4;
          if(Math.pow((wx-mouth.x)/mouth.rx,2)+Math.pow((wy-mouth.y)/mouth.ry,2)>1||!data.data[i+3])continue;
          let red=0,green=0,blue=0,weight=0;
          for(let dy=-8;dy<=8;dy++)for(let dx=-8;dx<=8;dx++){
            const sx=wx+dx-full.ox,sy=wy+dy-full.oy;if(sx<0||sy<0||sx>=full.w||sy>=full.h)continue;
            const j=(sy*full.w+sx)*4;if(source[j+3]<200||Math.min(source[j],source[j+1],source[j+2])<210||Math.max(source[j],source[j+1],source[j+2])-Math.min(source[j],source[j+1],source[j+2])>40)continue;
            const w=1/(1+dx*dx+dy*dy);red+=source[j]*w;green+=source[j+1]*w;blue+=source[j+2]*w;weight+=w;
          }
          if(weight){data.data[i]=red/weight;data.data[i+1]=green/weight;data.data[i+2]=blue/weight;}
        }
      }
      ctx.putImageData(data,0,0);
    }catch{ /* Restricted embedding origins retain original coverage. */ }
    c.dataset.mewponTexture=l.file;this.pixels.set(l.file,c);return c;
  }

  private analyzeTalk(): void {
    const frames = this.manifest.groups.frames.talk ?? [];
    this.mouthOrder = frames.map((_, i) => i);
    try {
      const scores = frames.map((e) => {
        const im = this.img(e.full); if (!im) return 0;
        const c = document.createElement('canvas'); c.width = im.naturalWidth; c.height = im.naturalHeight;
        const x = c.getContext('2d', { willReadFrequently: true })!; x.drawImage(im, 0, 0);
        const w = c.width, h = c.height, d = x.getImageData(Math.floor(w * 0.3), Math.floor(h * 0.45), Math.floor(w * 0.4), Math.floor(h * 0.4)).data;
        let s = 0; for (let p = 0; p < d.length; p += 4) if (d[p + 3] > 128 && d[p] > 120 && d[p + 1] < 120 && d[p + 2] < 130) s++; // red/pink mouth interior
        return s;
      });
      this.mouthOrder = frames.map((_, i) => i).sort((a, b) => scores[a] - scores[b]);
    } catch { /* tainted canvas on file:// -> keep sheet order */ }
  }
}
