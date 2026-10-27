import type { Layer } from '../core/types';
import type { Assets } from '../core/assets';

/** Inverse sample a displacement field into one image. Every destination texel
 * is written once: no clipped triangles, overlapping alpha, or diagonal seams. */
export function warpPixels(source:Uint8ClampedArray,width:number,height:number,field:Float32Array,columns:number,rows:number,padding:number,output:Uint8ClampedArray):void {
  const W=width+padding*2,H=height+padding*2;
  output.fill(0);
  // Padding exists for large gestures, but most of it is transparent. Bound
  // sampling by the field extrema without changing any destination coverage.
  let minX=0,maxX=0,minY=0,maxY=0;
  for(let i=0;i<field.length;i+=2){minX=Math.min(minX,field[i]);maxX=Math.max(maxX,field[i]);minY=Math.min(minY,field[i+1]);maxY=Math.max(maxY,field[i+1]);}
  const x0=Math.max(0,Math.floor(padding+minX)-1),x1=Math.min(W,Math.ceil(padding+width+maxX)+1);
  const y0=Math.max(0,Math.floor(padding+minY)-1),y1=Math.min(H,Math.ceil(padding+height+maxY)+1);
  for(let y=y0;y<y1;y++)for(let x=x0;x<x1;x++){
    const targetX=x-padding+0.5,targetY=y-padding+0.5;let sx=targetX,sy=targetY;
    for(let iteration=0;iteration<4;iteration++){
      const gx=Math.max(0,Math.min(columns-0.00001,sx/width*columns)),gy=Math.max(0,Math.min(rows-0.00001,sy/height*rows));
      const ix=Math.floor(gx),iy=Math.floor(gy),u=gx-ix,v=gy-iy,i=(iy*(columns+1)+ix)*2,j=i+(columns+1)*2;
      const dx=(field[i]*(1-u)+field[i+2]*u)*(1-v)+(field[j]*(1-u)+field[j+2]*u)*v;
      const dy=(field[i+1]*(1-u)+field[i+3]*u)*(1-v)+(field[j+1]*(1-u)+field[j+3]*u)*v;
      sx=targetX-dx;sy=targetY-dy;
    }
    const px=Math.floor(sx),py=Math.floor(sy);if(px<0||py<0||px>=width||py>=height)continue;
    const a=(py*width+px)*4,b=(y*W+x)*4;output[b]=source[a];output[b+1]=source[a+1];output[b+2]=source[a+2];output[b+3]=source[a+3];
  }
}
interface Cache {canvas:HTMLCanvasElement;ctx:CanvasRenderingContext2D;source:Uint8ClampedArray;pixels:ImageData;field:Float32Array;columns:number;rows:number}
const cache=new WeakMap<object,Cache>();
export function drawMesh(ctx:CanvasRenderingContext2D,assets:Assets,layer:Layer,deform:(x:number,y:number)=>[number,number],columns=8,rows=4):void {
  const image=ctx.imageSmoothingEnabled?assets.img(layer):assets.pixelSource(layer);if(!image)return;
  const padding=16;let entry=cache.get(image);
  if(!entry||entry.columns!==columns||entry.rows!==rows){
    const source=document.createElement('canvas');source.width=layer.w;source.height=layer.h;const sc=source.getContext('2d',{willReadFrequently:true})!;sc.drawImage(image,0,0,layer.w,layer.h);
    let pixels:Uint8ClampedArray;try{pixels=sc.getImageData(0,0,layer.w,layer.h).data;}catch{ctx.drawImage(image,layer.ox,layer.oy,layer.w,layer.h);return;}
    const canvas=document.createElement('canvas');canvas.width=layer.w+padding*2;canvas.height=layer.h+padding*2;canvas.dataset.mewponTexture=layer.file;
    const c=canvas.getContext('2d')!;entry={canvas,ctx:c,source:pixels,pixels:c.createImageData(canvas.width,canvas.height),field:new Float32Array((columns+1)*(rows+1)*2),columns,rows};cache.set(image,entry);
  }
  for(let y=0;y<=rows;y++)for(let x=0;x<=columns;x++){
    const sx=layer.ox+x/columns*layer.w,sy=layer.oy+y/rows*layer.h,[dx,dy]=deform(sx,sy),i=(y*(columns+1)+x)*2;
    entry.field[i]=dx-sx;entry.field[i+1]=dy-sy;
  }
  warpPixels(entry.source,layer.w,layer.h,entry.field,columns,rows,padding,entry.pixels.data);
  entry.ctx.putImageData(entry.pixels,0,0);ctx.drawImage(entry.canvas,layer.ox-padding,layer.oy-padding);
}
