import {newRig,type ExpressionName,type Rig} from './types';
import {EXPRESSION_DEFS} from '../expressions';
import {FaceRig,expressionEase} from '../rendering/face';

/** One clock for facial geometry and the accompanying gesture. Interruptions
 * begin at the visible pose, and held expressions always start their own cycle. */
export class ExpressionDirector {
  readonly face=new FaceRig();
  readonly rig=newRig();
  private from=newRig();
  private name:ExpressionName='neutral';
  private age=1;
  step(name:ExpressionName,dt:number,duration=0.32){
    if(name!==this.name){this.from={...this.rig};this.name=name;this.age=0;}
    this.age+=Math.max(0,dt);
    const target=newRig();
    if(name!=='neutral')EXPRESSION_DEFS[name].motion(this.age,this.age,target);
    const k=expressionEase(this.age/duration);
    for(const key of Object.keys(target) as (keyof Rig)[]){
      if(typeof target[key]==='number')(this.rig as any)[key]=k===1?Number(target[key]):Number(this.from[key])+(Number(target[key])-Number(this.from[key]))*k;
    }
    this.face.step(name,dt,duration);
  }
  reset(){this.name='neutral';this.age=1;this.from=newRig();Object.assign(this.rig,newRig());this.face.step('neutral',1);}
}

/** A temporary reaction has explicit stages; no negative-time stage can replace
 * the one which should currently be visible. */
export interface ReactionStage {name:ExpressionName;dur:number;agent:boolean}
export class ReactionSequence {
  private stages:ReactionStage[]=[];
  private age=0;
  get current(){return this.stages[0]??null;}
  start(stages:ReactionStage[]){this.stages=stages.map(x=>({...x}));this.age=0;}
  clear(){this.stages=[];this.age=0;}
  step(dt:number){this.age+=dt;while(this.current&&this.age>=this.current.dur){this.age-=this.current.dur;this.stages.shift();}}
}
