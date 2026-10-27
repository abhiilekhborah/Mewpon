'use strict';
(() => {
  const send = (message) => window.webkit?.messageHandlers.mewpon.postMessage(message);
  window.addEventListener('error', e => send({kind:'error', message:String(e.message)}));
  const mew = new window.Mewpon(document.getElementById('stage'), {
    baseUrl:'spritesheets/', maxFps:60, pixelated:true, scale:1.25,
    interactions:{dragMovesStage:false,onDrag:(dx,dy)=>send({kind:'drag',dx,dy})}
  });
  window.mewpon=mew;
  document.getElementById('stage').addEventListener('mousedown',e=>e.preventDefault());
  let lastState = '';
  const check = (value, catalog, kind) => {
    if (!catalog.includes(value)) throw new Error(`Unsupported ${kind}: ${value}`);
  };
  window.nativeAvatar = {
    state(expression, activity, attention=false) {
      check(expression, window.MewponLib.EXPRESSIONS, 'expression');
      if(activity !== null) check(activity, window.MewponLib.ACTIVITIES, 'activity');
      const key = expression + '/' + activity+'/'+attention;
      if(key === lastState) return;
      lastState = key;
      // Do not reset(): the original engine's reset would discard the outfit.
      mew.setAssistantState(expression,activity,attention);
    },
    outfit(value) {check(value,window.MewponLib.OUTFITS,'outfit');mew.setOutfit(value);},
    expression(value) {check(value,window.MewponLib.EXPRESSIONS,'expression');mew.stopActivity();mew.setExpression(value);lastState='';},
    activity(value) {check(value,window.MewponLib.ACTIVITIES,'activity');mew.setActivity(value);lastState='';},
    animation(value) {check(value,[...window.MewponLib.MOVEMENTS,...window.MewponLib.ONESHOTS],'animation');mew.stopActivity();mew.stopAnimation();mew.playAnimation(value,{queue:false});},
    play(value){return value?mew.enterPlayMode():(mew.exitPlayMode(),true);},
    interact(value){return mew.interact(value);},
    idle(value){mew.enableAutonomousIdle(value);},
    gaze(x,y){mew.lookAtNormalized(x,y);},
    reset() {mew.reset();lastState='';},
    async metrics() {const start=performance.now(),before=mew.getPerformance().totalDraws;await new Promise(resolve=>setTimeout(resolve,2200));const result=mew.getPerformance();result.observedFPS=(result.totalDraws-before)/((performance.now()-start)/1000);result.visibility=document.visibilityState;return result;},
    meter(value){if(Number.isFinite(value))mew.setSpeechLevel(value);},
    budget(value){check(value,[30,60],'frame budget');mew.maxFps=value;},
    visible(value) {value ? mew.start() : mew.stop();}
  };
  mew.on('petChanged',e=>send({kind:'pet',...e}));
  document.getElementById('stage').addEventListener('contextmenu',e=>{e.preventDefault();send({kind:'activate'});});
  mew.on('interaction',e=>{if(e.kind==='click'||e.kind==='doubleClick')send({kind:'activate'});});
  mew.ready.then(()=>send({kind:'ready'})).catch(error=>send({kind:'error',message:String(error)}));
  document.addEventListener('visibilitychange',()=>window.nativeAvatar.visible(!document.hidden));
})();
