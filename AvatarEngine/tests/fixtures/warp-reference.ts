// Frozen pre-optimization sampler used only for pixel equivalence checks.
export function referenceWarp(source:Uint8ClampedArray,width:number,height:number,field:Float32Array,columns:number,rows:number,padding:number,output:Uint8ClampedArray):void {
  const W=width+padding*2,H=height+padding*2;
  output.fill(0);
  for(let y=0;y<H;y++)for(let x=0;x<W;x++){
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
