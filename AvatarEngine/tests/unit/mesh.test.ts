import {describe,it,expect} from 'vitest';
import {warpPixels} from '../../src/rendering/mesh';
import {referenceWarp} from '../fixtures/warp-reference';

describe('single-pass image warp',()=>{
  const width=16,height=12,pad=4,W=width+pad*2;
  const source=()=>{const data=new Uint8ClampedArray(width*height*4);for(let i=0;i<data.length;i+=4)data.set([160,200,240,255],i);return data;};
  it('identity sampling has no grid seams or alpha darkening',()=>{
    const output=new Uint8ClampedArray(W*(height+pad*2)*4);warpPixels(source(),width,height,new Float32Array(18),2,2,pad,output);
    for(let y=0;y<height;y++)for(let x=0;x<width;x++)expect([...output.slice(((y+pad)*W+x+pad)*4,((y+pad)*W+x+pad)*4+4)]).toEqual([160,200,240,255]);
  });
  it('translation preserves every texel without alpha accumulation',()=>{
    const field=new Float32Array(18);for(let i=0;i<field.length;i+=2){field[i]=2;field[i+1]=-2;}
    const output=new Uint8ClampedArray(W*(height+pad*2)*4);warpPixels(source(),width,height,field,2,2,pad,output);
    let opaque=0;for(let i=3;i<output.length;i+=4){expect([0,255]).toContain(output[i]);if(output[i])opaque++;}
    expect(opaque).toBe(width*height);
  });
  it('a continuous shear has no internal holes or diagonal grid lines',()=>{
    const field=new Float32Array(18);for(let y=0;y<=2;y++)for(let x=0;x<=2;x++)field[(y*3+x)*2]=y*0.7;
    const output=new Uint8ClampedArray(W*(height+pad*2)*4);warpPixels(source(),width,height,field,2,2,pad,output);
    for(let y=2;y<height-2;y++)for(let x=3;x<width-3;x++)expect(output[((y+pad)*W+x+pad)*4+3]).toBe(255);
  });
});

describe('bounded warp optimization',()=>{
  it('preserves every output byte across deterministic irregular fields',()=>{
    let seed=12345;const random=()=>{seed=(seed*1664525+1013904223)>>>0;return seed/4294967296;};
    const width=100,height=22,pad=16,cols=8,rows=4,source=new Uint8ClampedArray(width*height*4);
    for(let i=0;i<source.length;i++)source[i]=Math.floor(random()*256);
    const samples:{before:number;after:number}[]=[];
    for(let n=0;n<60;n++){
      const field=Float32Array.from({length:(cols+1)*(rows+1)*2},()=>random()*12-6);
      const before=new Uint8ClampedArray((width+pad*2)*(height+pad*2)*4),after=new Uint8ClampedArray(before.length);
      let start=performance.now();referenceWarp(source,width,height,field,cols,rows,pad,before);const oldMs=performance.now()-start;
      start=performance.now();warpPixels(source,width,height,field,cols,rows,pad,after);const newMs=performance.now()-start;
      expect(after).toEqual(before);samples.push({before:oldMs,after:newMs});
    }
  });
});
