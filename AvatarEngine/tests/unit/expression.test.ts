import {describe,it,expect} from 'vitest';
import {ExpressionDirector,ReactionSequence} from '../../src/core/expression';
import {FACE_POSES} from '../../src/rendering/face';

describe('coordinated expression transitions',()=>{
  it('finishes the face and gesture on the same clock',()=>{
    const d=new ExpressionDirector();d.step('angry',0.16);
    expect(d.face.pose.left).toBeCloseTo((1+FACE_POSES.angry.left)/2);
    expect(d.rig.headDY).toBeCloseTo(0.25);
    d.step('angry',0.16);
    expect(d.face.pose.left).toBe(FACE_POSES.angry.left);
    expect(d.rig.headDY).toBe(0.5);
  });
  it('retargets both parts from their visible pose and returns completely to neutral',()=>{
    const d=new ExpressionDirector();d.step('sad',0.2);
    const beforeFace={...d.face.pose},beforeRig={...d.rig};
    d.step('happy',0);
    expect(d.face.pose).toEqual(beforeFace);expect(d.rig).toEqual(beforeRig);
    d.step('happy',0.4);d.step('neutral',0.32);
    expect(d.face.pose).toEqual(FACE_POSES.neutral);expect(d.rig.headRot).toBe(0);expect(d.rig.bodyDY).toBe(0);
  });
  it('produces the same pose regardless of time spent in another expression',()=>{
    const a=new ExpressionDirector(),b=new ExpressionDirector();
    a.step('neutral',50);b.step('neutral',1);
    for(let i=0;i<60;i++){a.step('confused',1/60);b.step('confused',1/60);}
    expect(a.rig).toEqual(b.rig);expect(a.face.pose).toEqual(b.face.pose);
  });
  it('shows surprise before happiness, then returns, and cancels stale stages',()=>{
    const s=new ReactionSequence();s.start([{name:'surprised',dur:0.45,agent:false},{name:'happy',dur:1.3,agent:false}]);
    s.step(0.44);expect(s.current?.name).toBe('surprised');s.step(0.02);expect(s.current?.name).toBe('happy');
    s.step(1.3);expect(s.current).toBeNull();
    s.start([{name:'surprised',dur:0.45,agent:false},{name:'happy',dur:1.3,agent:false}]);
    s.start([{name:'focused',dur:2,agent:true}]);s.step(0.6);expect(s.current?.name).toBe('focused');
    s.clear();s.step(5);expect(s.current).toBeNull();
  });
});
