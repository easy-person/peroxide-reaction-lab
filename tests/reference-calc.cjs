(function(root){
const R=8.31;
function vapor(t){return 10**(8.02754-1705.616/(231.405+t))/760*1.013e5;}
function regress(p){if(p.length<3)return null;let mx=p.reduce((s,p)=>s+p[0],0)/p.length,my=p.reduce((s,p)=>s+p[1],0)/p.length;let xx=0,xy=0,yy=0;for(let [x,y] of p){xx+=(x-mx)**2;xy+=(x-mx)*(y-my);yy+=(y-my)**2;}if(xx<1e-20)return null;let k=xy/xx,b=my-k*mx;return {k,b,c0:b/k,r2:yy?xy*xy/xx/yy:0};}
function calculate(rows,c){
 if(!(c.pressure>0&&c.volume>0))throw Error('大気圧と反応液の全体積は正の数にしてください。');
 const temp=Number(c.temp);if(c.temp===''||c.temp===undefined||!Number.isFinite(temp)||temp<0||temp>60)throw Error('測定温度を0～60 ℃で入力してください。');
 let data=[],sumV=0,sumN=0,prevV=0,prevT=0,pairs=[],initialN=0,initialV=0;
 for(let i=0;i<rows.length;i++){let r=rows[i];if(r.time===''&&r.vol==='')continue;
 if(r.time===''||r.vol==='')throw Error(`${i+1}行目：時間・体積をすべて入力してください。`);
 let t=Number(r.time)*(c.unit==='min'?60:1),v=Number(r.vol);
 if(![t,v,temp].every(Number.isFinite)||(t===0?i!==0:t<=prevT)||v<0)throw Error(`${i+1}行目：時間は前回より大きく、体積は0以上にしてください。`);
 let p=c.pressure-(c.wet?vapor(temp):0);if(p<=0)throw Error('水蒸気圧が大気圧以上です。条件を確認してください。');
 if(t===0){initialV=v;prevV=v;initialN=p*v*1e-6/(R*(temp+273.15));data.push({t:0,v:0,total:0,n:0,d:0,rate:null,x:null,mid:null,temp,reading:v});continue;}
 let dv=c.input==='total'?v-prevV:v;if(dv<0)throw Error(`${i+1}行目：累積体積が前回より小さくなっています。`);
 let previousD=2*sumN/(c.volume/1000),n;
 if(c.input==='total'){sumV=v-initialV;let newN=p*v*1e-6/(R*(temp+273.15))-initialN;n=newN-sumN;if(n< -1e-12)throw Error(`${i+1}行目：温度補正後の累積酸素量が減少しています。温度・体積を確認してください。`);sumN=newN;}else{sumV+=v;n=p*dv*1e-6/(R*(temp+273.15));sumN+=n;}
 let d=2*sumN/(c.volume/1000),rate=(d-previousD)/(t-prevT),x=-(d+previousD)/2;pairs.push([x,rate]);data.push({t,v:dv,total:sumV,n:sumN,d,rate,x,mid:(prevT+t)/2,temp,reading:v});prevT=t;prevV=v;
 }
 let fit=regress(pairs),c0=c.mode==='known'?Number(c.c0):(fit&&fit.k>0&&fit.c0>0&&Number.isFinite(fit.c0)?fit.c0:null);
 if(c.mode==='known'&&(c.c0===''||!Number.isFinite(c0)||c0<=0))throw Error('混合直後の初濃度を正の数で入力してください。');
 return {data:data.map(r=>({...r,c:c0===null?null:c0-r.d,avg:c0===null||r.x===null?null:c0+r.x})),fit,c0};
}
const api={calculate,regress,vapor};if(typeof module!=='undefined')module.exports=api;else root.Chem=api;
})(globalThis);
