import { describe, it, expect } from 'vitest';
import { activityPose, movementPose, bodyPoint, focusedBodyPoint } from '../../src/core/rigmotion';
import { ACTIVITIES, newRig } from '../../src/core/types';

describe('continuous character rig',()=>{
  it('keeps the focused laptop and neck pinned while both original paws move',()=>{
    const r=newRig();r.pawLY=-3;r.pawRY=-2;
    expect(focusedBodyPoint(15,-5,r)).toEqual([15,-5]);
    expect(focusedBodyPoint(-20,-20,r)).toEqual([-20,-20]);
    expect(focusedBodyPoint(-28,-4,r)[1]).toBeLessThan(-6);
    expect(focusedBodyPoint(-7,-4,r)[1]).toBeLessThan(-5);
  });
  it('keeps the neck pinned while independently moving both paws',()=>{
    const rig=newRig();rig.pawLY=-3;rig.pawRY=2;
    expect(bodyPoint(0,-20,rig)).toEqual([0,-20]);
    expect(bodyPoint(-7,-4,rig)[1]).toBeLessThan(-5);
    expect(bodyPoint(20,-4,rig)[1]).toBeGreaterThan(-3);
  });
  it('typing alternates paws without translating the character or laptop',()=>{
    const samples=Array.from({length:90},(_,i)=>{const r=newRig();activityPose('typing',i/60,1,r);return r;});
    expect(samples.some(r=>r.pawLY<r.pawRY-1)).toBe(true);
    expect(samples.some(r=>r.pawRY<r.pawLY-1)).toBe(true);
    expect(samples.every(r=>r.x===0&&r.y===0&&r.laptopAlpha===1)).toBe(true);
  });
  it('all activities produce finite joint targets with restrained proportions',()=>{
    for(const name of ACTIVITIES)for(let t=0;t<20;t+=0.137){const r=newRig();activityPose(name,t,t,r);expect(Object.values(r).every(v=>typeof v!=='number'||Number.isFinite(v))).toBe(true);expect(Math.abs(r.sy-1)).toBeLessThan(0.03);}
  });
  it('jump has anticipation, airborne, landing and recovery phases',()=>{
    const at=(u:number)=>{const r=newRig();movementPose('jump',u,1,r);return r;};
    expect(at(0.12).y).toBeGreaterThan(0);expect(at(0.48).y).toBeLessThan(-20);
    expect(at(0.89).sy).toBeLessThan(1);expect(at(1).y).toBeCloseTo(0);
  });
  it('walking and running change actual paw positions, not just body bob',()=>{
    for(const name of ['walk','run']){const a=newRig(),b=newRig();movementPose(name,0.2,2,a);movementPose(name,0.5,2,b);expect(Math.abs(a.pawLX-b.pawLX)+Math.abs(a.pawRY-b.pawRY)).toBeGreaterThan(1);}
  });
});
