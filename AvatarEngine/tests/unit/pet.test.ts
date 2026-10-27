import {describe,it,expect} from 'vitest';
import {PetDirector,PET_ACTIONS} from '../../src/core/pet';
import {petPose,activityPose} from '../../src/core/rigmotion';
import {newRig} from '../../src/core/types';
import {pixelGrid} from '../../src/rendering/pixelgrid';

describe('local pet ownership and motion',()=>{
  it('uses integer texel scaling with correct backing dimensions at fractional display ratios',()=>{
    for(const dpr of [1,1.25,1.5,2,3])for(const size of [[210,158],[300,240],[420,320]]){
      const grid=pixelGrid(size[0],size[1],dpr,1.25,true);
      expect(grid.unit).toBe(Math.floor(grid.unit));expect(grid.unit).toBeGreaterThanOrEqual(1);
      expect(grid.backingWidth).toBe(Math.round(size[0]*dpr));expect(grid.backingHeight).toBe(Math.round(size[1]*dpr));
    }
  });
  it('keeps a nap until explicit interruption and clears follow on exit',()=>{
    const p=new PetDirector();p.enter();p.start('nap');p.step(1000,true);expect(p.action).toBe('nap');
    p.start('followCursor');expect(p.following).toBe(true);p.exit();expect(p.following).toBe(false);expect(p.action).toBe(null);
  });
  it('does not let idle overwrite a manual action',()=>{
    const p=new PetDirector();p.enter();p.start('highFive');p.step(7.5,true);expect(p.action).toBe('highFive');expect(p.awaitingPaw).toBe(true);
    expect(p.hitPaw()).toBe(true);expect(p.action).toBe('dance');expect(p.awaitingPaw).toBe(false);
    p.step(2,true);expect(p.action).toBe(null);
  });
  it('avoids consecutive random repeats',()=>{
    const p=new PetDirector();let previous='';for(let i=0;i<100;i++){const action=p.start('random');expect(action).not.toBe(previous);previous=action;}
  });
  it('counts repeated pokes, and toggles cursor-follow explicitly',()=>{
    const p=new PetDirector();p.start('poke');p.start('poke');p.start('poke');expect(p.pokes).toBe(3);
    p.start('followCursor');p.start('followCursor');expect(p.following).toBe(false);
  });
  it('every interaction has finite observable joint motion',()=>{
    for(const name of PET_ACTIONS.filter(x=>!['random'].includes(x))){const r=newRig();petPose(name,0.7,2.4,r,0.8);expect(Object.values(r).filter(x=>typeof x==='number').every(Number.isFinite)).toBe(true);expect(r).not.toEqual(newRig());}
  });
  it('drinking lifts the cup, cooking tosses food, reading turns a page',()=>{
    const rest=newRig(),drink=newRig();activityPose('drinking',0,0,rest);activityPose('drinking',1.8,1.8,drink);expect(drink.propDY).toBeLessThan(rest.propDY);expect(drink.pawRY).toBeLessThan(-1);expect(drink.propScale).toBe(0.66);expect(drink.propDX).toBeGreaterThan(10);
    const cook=newRig();activityPose('cooking',1.4,1.4,cook);expect(cook.food).toBeGreaterThan(10);
    const read=newRig();activityPose('reading',5.1,5.1,read);expect(read.page).toBeGreaterThan(0.8);
  });
  it('twirl rotates in the image plane and does not mirror the sprite',()=>{
    const r=newRig();petPose('spin',0.8,1.6,r);expect(r.rootRot).toBeCloseTo(180);expect(r.flip).toBe(false);
  });
});
