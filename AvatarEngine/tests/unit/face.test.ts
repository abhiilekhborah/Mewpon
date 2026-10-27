import {describe,it,expect} from 'vitest';
import {FaceRig,FACE_POSES} from '../../src/rendering/face';
import {EXPRESSIONS} from '../../src/core/types';

describe('continuous facial geometry',()=>{
  it('has a distinct readable target for every expression',()=>{
    expect(new Set(EXPRESSIONS.map(x=>JSON.stringify(FACE_POSES[x]))).size).toBe(14);
  });
  it('moves continuously from the displayed face rather than snapping to a portrait',()=>{
    const rig=new FaceRig(),initial={...rig.pose};rig.step('happy',1/60);
    expect(rig.pose.left).toBeLessThan(initial.left);expect(rig.pose.left).toBeGreaterThan(FACE_POSES.happy.left);
    const before={...rig.pose};rig.step('surprised',1/60);
    expect(Math.abs(rig.pose.left-before.left)).toBeLessThan(0.2);
    for(let i=0;i<120;i++)rig.step('surprised',1/60);
    expect(rig.pose.left).toBeCloseTo(FACE_POSES.surprised.left,5);
  });
  it('stays finite and bounded during rapid interruptions',()=>{
    const rig=new FaceRig();for(let i=0;i<500;i++){rig.step(EXPRESSIONS[i%14],1/120);for(const value of Object.values(rig.pose))expect(Number.isFinite(value)).toBe(true);expect(rig.pose.left).toBeGreaterThan(0);expect(rig.pose.left).toBeLessThan(1.2);}
  });
});
