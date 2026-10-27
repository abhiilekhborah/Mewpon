/** Local-only ownership and action clock. No timers, model requests, or desktop polling. */
export const PET_ACTIONS = ['pet','poke','highFive','wave','dance','jump','spin','followCursor','nap','wake','random'] as const;
export type PetAction = typeof PET_ACTIONS[number];
export class PetDirector {
  playing=false; autonomous=true; following=false; awaitingPaw=false;
  action: PetAction|null=null; age=0; duration=0; pokes=0;
  private idleIn=14; private previous:PetAction|null=null;
  enter(){this.playing=true;this.clear();}
  exit(){this.playing=false;this.following=false;this.clear();}
  clear(){this.action=null;this.age=0;this.awaitingPaw=false;this.idleIn=14+Math.random()*16;}
  start(action:PetAction):PetAction {
    if(action==='random'){
      const choices:PetAction[]=['wave','dance','jump','pet','spin'];
      const available=choices.filter(x=>x!==this.previous);action=available[Math.floor(Math.random()*available.length)];
    }
    this.clear(); this.action=action; this.previous=action;
    this.duration=action==='nap'||action==='highFive'?Infinity:action==='dance'?4.8:action==='spin'?1.6:action==='jump'?1.1:2.4;
    if(action==='poke')this.pokes++;
    if(action==='followCursor'){this.following=!this.following;this.duration=1.2;}
    if(action==='wake')this.duration=1.1;
    if(action==='highFive')this.awaitingPaw=true;
    return action;
  }
  hitPaw(){if(!this.awaitingPaw)return false;this.start('dance');this.duration=1.8;return true;}
  step(dt:number,canIdle:boolean){
    if(this.action){this.age+=dt;if(this.age>=this.duration)this.clear();return;}
    if(this.autonomous&&canIdle){this.idleIn-=dt;if(this.idleIn<=0)this.start(Math.random()<0.5?'pet':'wave');}
  }
}
