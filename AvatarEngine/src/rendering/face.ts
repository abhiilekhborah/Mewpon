import type { ExpressionName, Rig } from '../core/types';

export interface FacePose {
  left:number;right:number;arch:number;tilt:number;gazeX:number;gazeY:number;
  brow:number;asymmetry:number;smile:number;open:number;mouthWidth:number;blush:number;
}
const neutral:FacePose={left:1,right:1,arch:0,tilt:0,gazeX:0,gazeY:0,brow:0,asymmetry:0,smile:0.2,open:0.08,mouthWidth:1,blush:0};
export const FACE_POSES:Record<ExpressionName,FacePose>={
  neutral,
  happy:{...neutral,left:0.1,right:0.1,arch:-2.1,smile:2,open:0.45},
  excited:{...neutral,left:0.14,right:0.14,arch:-2.7,smile:2.8,open:0.85,mouthWidth:1.2},
  thinking:{...neutral,left:0.9,right:0.9,gazeX:-1.1,gazeY:-1.5,brow:0.7,asymmetry:0.5,smile:-0.2,mouthWidth:0.65},
  confused:{...neutral,left:1,right:0.65,brow:0.9,asymmetry:1.5,smile:-0.6,mouthWidth:0.8},
  sad:{...neutral,left:0.6,right:0.6,arch:1.5,brow:-1.8,gazeY:0.8,smile:-1.8,open:0.05},
  angry:{...neutral,left:0.7,right:0.7,tilt:0.7,brow:2,gazeY:0.3,smile:-1.2,open:0.22},
  sleepy:{...neutral,left:0.08,right:0.08,arch:0.8,gazeY:1,smile:0,open:0.22,mouthWidth:0.55},
  wink:{...neutral,left:1,right:0.08,arch:-1.8,smile:1.6,open:0.18},
  laugh:{...neutral,left:0.08,right:0.08,arch:-2.3,smile:2.4,open:1,mouthWidth:1.15},
  surprised:{...neutral,left:1.18,right:1.18,brow:0.9,smile:0,open:0.85,mouthWidth:0.58},
  embarrassed:{...neutral,left:0.85,right:0.85,gazeX:-0.6,gazeY:0.8,smile:0.6,open:0.08,blush:1},
  proud:{...neutral,left:0.8,right:0.8,gazeY:-0.4,brow:0.5,smile:1.8,open:0.1},
  focused:{...neutral,left:0.7,right:0.7,gazeY:1.1,brow:1.1,smile:0,open:0.03,mouthWidth:0.65},
};

/** Retarget from the currently displayed geometry; never crossfade portraits. */
export const expressionEase=(t:number)=>{const u=Math.max(0,Math.min(1,t));return u*u*u*(10+u*(-15+u*6));};
export class FaceRig {
  readonly pose:FacePose={...neutral};
  private from:FacePose={...neutral};
  private expression:ExpressionName='neutral';
  private age=1;
  step(expression:ExpressionName,dt:number,duration=0.32):FacePose {
    if(expression!==this.expression){this.from={...this.pose};this.expression=expression;this.age=0;}
    this.age+=Math.max(0,dt);
    const target=FACE_POSES[expression],k=expressionEase(this.age/duration);
    for(const key of Object.keys(target) as (keyof FacePose)[])this.pose[key]=k===1?target[key]:this.from[key]+(target[key]-this.from[key])*k;
    return this.pose;
  }
}

/** Small facial paths use the original neutral face's positions and navy/pink
 * palette. The surrounding fur, goggles, ears and head remain original pixels. */
export function drawFaceRig(ctx:CanvasRenderingContext2D,p:FacePose,r:Rig,features:{eyes?:boolean;mouthX?:number;mouthY?:number;blush?:boolean}={}){
  ctx.save();ctx.strokeStyle='#263455';ctx.fillStyle='#263455';ctx.lineCap='round';ctx.lineJoin='round';
  for(let side=0;features.eyes!==false&&side<2;side++){
    const x=(side?27.3:3.3)+r.eyeDX+p.gazeX,y=(side?-26.9:-25.5)+r.eyeDY+p.gazeY;
    const opening=(side?p.right:p.left)*r.eyeSY,closedness=Math.max(0,Math.min(1,(0.6-opening)/0.45));
    const h=0.9+6.1*opening,w=2.25+closedness*1.35;
    const arch=p.arch*(1-Math.min(1,opening)),tilt=p.tilt*(side?-1:1);
    ctx.beginPath();ctx.moveTo(x-w,y+tilt);
    ctx.bezierCurveTo(x-w,y-h+arch,x+w,y-h+arch,x+w,y-tilt);
    ctx.bezierCurveTo(x+w,y+h+arch,x-w,y+h+arch,x-w,y+tilt);ctx.fill();
    if(Math.abs(p.brow)>0.1){
      const by=y-7.2+(side?-1:1)*p.asymmetry;
      ctx.globalAlpha=Math.min(0.8,Math.abs(p.brow)*0.55);ctx.lineWidth=1.1;
      ctx.beginPath();ctx.moveTo(x-3.4,by-(side?-1:1)*p.brow*0.5);ctx.lineTo(x+3.4,by+(side?-1:1)*p.brow*0.5);ctx.stroke();ctx.globalAlpha=1;
    }
  }
  const x=features.mouthX??15,y=features.mouthY??-17.4,w=3.3*p.mouthWidth,open=Math.max(p.open,r.mouth*0.9);
  // One mouth contour for closed, smiling, frowning and open states; switching
  // between stroked/filled primitives at a threshold caused a small snap.
  ctx.beginPath();ctx.moveTo(x-w,y);ctx.quadraticCurveTo(x,y+p.smile*1.3-open*1.8,x+w,y);ctx.quadraticCurveTo(x,y+p.smile*1.3+1+open*7,x-w,y);ctx.fill();
  ctx.save();ctx.clip();ctx.globalAlpha*=Math.max(0,Math.min(1,(open-0.1)/0.3));ctx.fillStyle='#e69ab2';ctx.beginPath();ctx.ellipse(x,y+open*6,Math.max(1,w*0.7),Math.max(0.6,open*2),0,0,Math.PI*2);ctx.fill();ctx.restore();
  if(features.blush!==false&&p.blush>0.03){ctx.globalAlpha=p.blush*0.7;ctx.strokeStyle='#e58ca8';ctx.lineWidth=0.8;for(const cx of [-5,35])for(let i=0;i<3;i++){ctx.beginPath();ctx.moveTo(cx+i*2,-18);ctx.lineTo(cx+i*2-0.7,-15);ctx.stroke();}}
  ctx.restore();
}
