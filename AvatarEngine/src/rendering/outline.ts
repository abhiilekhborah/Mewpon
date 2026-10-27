/** Recover the silhouette from the dark/colored outline. Exterior panel color
 * is flood-filled behind a closed ink barrier, protecting enclosed white fur.
 * Unlike a two-pixel trim, this removes larger rectangular matte corners. */
export function exteriorResidue(rgba:Uint8ClampedArray,width:number,height:number):Uint8Array {
  const count=width*height,ink=new Uint8Array(count),dilated=new Uint8Array(count),barrier=new Uint8Array(count),outside=new Uint8Array(count),queue=new Int32Array(count);
  const near=(p:number,fn:(n:number)=>void)=>{const x=p%width,y=Math.floor(p/width);for(let dy=-1;dy<=1;dy++)for(let dx=-1;dx<=1;dx++){const u=x+dx,v=y+dy;if(u>=0&&v>=0&&u<width&&v<height)fn(v*width+u);}};
  const pale=(p:number)=>{const i=p*4,min=Math.min(rgba[i],rgba[i+1],rgba[i+2]),max=Math.max(rgba[i],rgba[i+1],rgba[i+2]);return min>=170&&max-min<65&&rgba[i+2]>=rgba[i]-8;};
  const distance=new Uint8Array(count).fill(5);let dr=0,dw=0;
  for(let p=0;p<count;p++)if(rgba[p*4+3]<=16){distance[p]=0;queue[dw++]=p;}
  for(let p=0;p<count;p++)if((p<width||p>=count-width||p%width===0||p%width===width-1)&&distance[p]===5){distance[p]=1;queue[dw++]=p;}
  while(dr<dw){const p=queue[dr++];if(distance[p]>=4)continue;near(p,n=>{if(distance[n]>distance[p]+1){distance[n]=distance[p]+1;queue[dw++]=n;}});}
  for(let p=0;p<count;p++){const i=p*4,r=rgba[i],g=rgba[i+1],b=rgba[i+2];ink[p]=rgba[i+3]>32&&(r*0.22+g*0.65+b*0.13<170||Math.max(r,g,b)-Math.min(r,g,b)>=90)?1:0;}
  for(let p=0;p<count;p++)if(ink[p])near(p,n=>dilated[n]=1);
  for(let p=0;p<count;p++){let closed=true;near(p,n=>{if(!dilated[n])closed=false;});barrier[p]=ink[p]||closed?1:0;}
  let read=0,write=0;
  for(let p=0;p<count;p++)if(rgba[p*4+3]<=16||((p<width||p>=count-width||p%width===0||p%width===width-1)&&pale(p)&&!ink[p])){outside[p]=1;queue[write++]=p;}
  while(read<write){const p=queue[read++],x=p%width,y=Math.floor(p/width);for(const n of [x?p-1:-1,x+1<width?p+1:-1,y?p-width:-1,y+1<height?p+width:-1])if(n>=0&&!outside[n]&&!barrier[n]&&distance[n]<=4&&pale(n)){outside[n]=1;queue[write++]=n;}}
  // A virtual bridge protects a gap while flood-filling; it must not preserve a
  // bright pixel just outside the real outline as a new white corner.
  for(let p=0;p<count;p++)if(!ink[p]&&barrier[p]&&pale(p)){let boundary=false;near(p,n=>{if(outside[n])boundary=true;});if(boundary)outside[p]=1;}
  return outside;
}
