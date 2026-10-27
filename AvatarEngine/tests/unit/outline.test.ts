import {describe,it,expect} from 'vitest';
import {exteriorResidue} from '../../src/rendering/outline';

describe('exterior matte cleanup',()=>{
  it('removes corners wider than the previous two-pixel edge band',()=>{
    const w=21,d=new Uint8ClampedArray(w*w*4);
    for(let y=1;y<20;y++)for(let x=1;x<20;x++){const ring=(x===6||x===14)&&y>=6&&y<=14||(y===6||y===14)&&x>=6&&x<=14;d.set(ring?[30,50,95,255]:[241,247,255,255],(y*w+x)*4);}
    const mask=exteriorResidue(d,w,w);expect(mask[4*w+4]).toBe(1);expect(mask[10*w+10]).toBe(0);expect(mask[6*w+10]).toBe(0);
  });
  const fixture=()=>{
    const w=13,d=new Uint8ClampedArray(w*w*4);
    for(let y=1;y<12;y++)for(let x=1;x<12;x++){
      const i=(y*w+x)*4,outline=x===3||x===9||y===3||y===9;
      d.set(outline?[35,58,100,255]:[245,248,255,255],i);
    }
    return {w,d};
  };
  it('removes exterior white residue without erasing enclosed white fur',()=>{
    const {w,d}=fixture(),mask=exteriorResidue(d,w,w);
    expect(mask[1*w+6]).toBe(1);expect(mask[6*w+1]).toBe(1);
    expect(mask[6*w+6]).toBe(0);expect(mask[3*w+6]).toBe(0);
  });
  it('does not recolor or mutate the source image',()=>{
    const {w,d}=fixture(),before=d.slice();exteriorResidue(d,w,w);expect(d).toEqual(before);
  });
  it('limits removal depth even when the original outline has a gap',()=>{
    const {w,d}=fixture();d.set([245,248,255,255],(3*w+6)*4);
    const mask=exteriorResidue(d,w,w);expect(mask[6*w+6]).toBe(0);
  });
  it('preserves saturated accessories at a tight crop edge',()=>{
    const d=new Uint8ClampedArray([30,130,150,255,245,248,255,255]);
    expect([...exteriorResidue(d,2,1)]).toEqual([0,1]);
  });
  it('removes blue-white panel residue but keeps the saturated blue outline',()=>{
    const d=new Uint8ClampedArray([210,223,245,255,120,180,220,255]);
    expect([...exteriorResidue(d,2,1)]).toEqual([1,0]);
  });
  it('keeps pale pink ear interiors even where the source outline has a gap',()=>{
    const d=new Uint8ClampedArray([248,208,231,255,245,225,230,255,210,223,245,255]);
    expect([...exteriorResidue(d,3,1)]).toEqual([0,0,1]);
  });
});
