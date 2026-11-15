(function(root){
  const points=data=>data.filter(p=>Number.isFinite(p[0])&&Number.isFinite(p[1]));
  function linear(data){const p=points(data);if(p.length<2)return null;const mx=p.reduce((s,p)=>s+p[0],0)/p.length,my=p.reduce((s,p)=>s+p[1],0)/p.length;let xx=0,xy=0;for(const[x,y]of p){xx+=(x-mx)**2;xy+=(x-mx)*(y-my);}if(!(xx>0))return null;const slope=xy/xx,intercept=my-slope*mx;if(!Number.isFinite(slope)||!Number.isFinite(intercept))return null;return{kind:'linear',slope,intercept,predict:x=>slope*x+intercept};}
  function minimize(evaluate){const lo=Math.log(1e-5),hi=Math.log(40),steps=100;let best=null,bestIndex=0;for(let i=0;i<=steps;i++){const log=lo+(hi-lo)*i/steps,r=evaluate(Math.exp(log));if(r&&(!best||r.sse<best.sse)){best=r;bestIndex=i;}}if(!best)return null;let a=lo+(hi-lo)*Math.max(0,bestIndex-1)/steps,b=lo+(hi-lo)*Math.min(steps,bestIndex+1)/steps;const phi=(Math.sqrt(5)-1)/2;let c=b-phi*(b-a),d=a+phi*(b-a),fc=evaluate(Math.exp(c)),fd=evaluate(Math.exp(d));for(let i=0;i<85;i++){if((fc?.sse??Infinity)<(fd?.sse??Infinity)){b=d;d=c;fd=fc;c=b-phi*(b-a);fc=evaluate(Math.exp(c));}else{a=c;c=d;fc=fd;d=a+phi*(b-a);fd=evaluate(Math.exp(d));}}for(const r of[fc,fd,evaluate(Math.exp((a+b)/2))])if(r&&r.sse<best.sse)best=r;return best;}
  function fit(data,type){const p=points(data).sort((a,b)=>a[0]-b[0]),fallback=linear(p);if(!fallback)return null;
    const simple=reason=>({...fallback,reason});if(type==='rate')return fallback;
    if(new Set(p.map(p=>p[0])).size<(type==='oxygen'?4:3))return simple('測定点が少ないため直線回帰を表示');
    if(p.some(p=>p[1]<0))return simple('負の値が含まれるため直線回帰を表示');
    if(type==='oxygen'?fallback.slope<=0:fallback.slope>=0)return simple('一次反応モデルの増減傾向に合わないため直線回帰を表示');
    const x0=p[0][0],span=p.at(-1)[0]-x0;if(!(span>0))return null;
    const evalFit=lambda=>{let amplitude,offset=0;if(type==='oxygen'){const r=linear(p.map(([x,y])=>[-Math.expm1(-lambda*(x-x0)/span),y]));if(!r||r.slope<=0)return null;amplitude=r.slope;offset=r.intercept;}else{let ey=0,ee=0;for(const[x,y]of p){const e=Math.exp(-lambda*(x-x0)/span);ey+=e*y;ee+=e*e;}amplitude=ey/ee;if(!(amplitude>0))return null;}
      const k=lambda/span,predict=type==='oxygen'?x=>offset+amplitude*(-Math.expm1(-k*(x-x0))):x=>amplitude*Math.exp(-k*(x-x0));let sse=0;for(const[x,y]of p)sse+=(y-predict(x))**2;return Number.isFinite(sse)?{kind:type==='oxygen'?'saturation':'exponential',lambda,k,amplitude,offset,x0,predict,sse}:null;};
    const best=minimize(evalFit),lineSSE=p.reduce((s,[x,y])=>s+(y-fallback.predict(x))**2,0);
    if(!best||best.lambda<1e-4||best.lambda>35||best.sse>=lineSSE*(1-1e-9))return simple('曲率を十分に推定できないため直線回帰を表示');return best;
  }
  function dataset(record){const cfg=record.settings||{},raw=record.rows||[],conc=record.analysis?.concentrations||[];let total=0;const rows=raw.map((r,i)=>{const time=Number(r.time),v=Number(r.vol);total=cfg.input==='interval'?(i===0?v:total+v):v;const c=conc[i]?.c;return{inputTime:time,t:Number.isFinite(conc[i]?.t)?conc[i].t:time*(cfg.unit==='min'?60:1),raw:v,total,c:Number.isFinite(c)?c:null,average:null,rate:null};});for(let i=1;i<rows.length;i++){const a=rows[i-1],b=rows[i];if(a.c!==null&&b.c!==null&&b.t>a.t){b.average=(a.c+b.c)/2;b.rate=(a.c-b.c)/(b.t-a.t);}}
    return{rows,oxygen:rows.map(r=>[r.t,r.total]),concentration:rows.filter(r=>r.c!==null).map(r=>[r.t,r.c]),rate:rows.filter(r=>r.average!==null).map(r=>[r.average,r.rate])};
  }
  const api={linear,fit,dataset};if(typeof module!=='undefined')module.exports=api;else root.LabRegression=api;
})(globalThis);
