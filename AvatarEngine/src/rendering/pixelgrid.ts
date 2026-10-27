export function pixelGrid(width:number,height:number,dpr:number,scale:number,pixelated:boolean){
  const backingWidth=Math.max(1,Math.round(width*dpr)),backingHeight=Math.max(1,Math.round(height*dpr));
  const requested=Math.min(width,height)/190*scale*dpr;
  return {backingWidth,backingHeight,unit:pixelated?Math.max(1,Math.floor(requested)):requested};
}
