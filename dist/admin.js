const $=id=>document.getElementById(id);let groups=[],runs=[],selected=null,currentLinkGroup=null;
function status(text,error=false){$('admin-status').textContent=text;$('admin-status').className='message'+(error?' error':'');}
function cell(row,text,tag='td'){const c=document.createElement(tag);c.textContent=text;row.append(c);return c;}
function format(v){return v===null||v===undefined?'推定不可':Number(v).toPrecision(5);}
function showLink(label,token,groupId){currentLinkGroup=groupId;const u=new URL('./',location.href);u.hash=new URLSearchParams({group:token}).toString();$('new-group').textContent=label;$('group-link').value=u.href;$('linkbox').hidden=false;}
async function list(){groups=await LabAPI.rpc('lab_admin_groups',{},true);const box=$('groups');box.replaceChildren();if(!groups.length){box.textContent='まだ班がありません。左のフォームで作成してください。';return;}for(const g of groups){const row=document.createElement('div');row.className='group-row';const name=document.createElement('strong');name.textContent=g.label;const caption=document.createElement('p');caption.className='help';caption.textContent=`${g.active?'受付中':'受付終了'} · 保存 ${g.runs} 件 · ${g.settings.temp} ℃`;row.append(name,caption);const view=document.createElement('button');view.textContent='記録・速度定数を確認';view.onclick=()=>loadRuns(g);const close=document.createElement('button');close.textContent=g.active?'受付を終了':'受付を再開';close.onclick=async()=>{try{await LabAPI.rpc('lab_admin_access',{p_group_id:g.id,p_active:!g.active,p_rotate:false},true);await list();status('受付状態を更新しました。');}catch(e){status(e.message,true);}};const rotate=document.createElement('button');rotate.textContent='リンク再発行';rotate.onclick=async()=>{if(!confirm('以前の班リンクを無効にして、再発行しますか？記録は残ります。'))return;try{const r=await LabAPI.rpc('lab_admin_access',{p_group_id:g.id,p_active:true,p_rotate:true},true);showLink(g.label,r.token,g.id);await list();status('新しいリンクを配布してください。');}catch(e){status(e.message,true);}};const remove=document.createElement('button');remove.textContent='班専用リンクを削除';remove.className='danger';remove.onclick=async()=>{
  if(!confirm('「'+g.label+'」の班専用リンクを削除しますか？配布済みリンクからの閲覧・保存ができなくなります。実験記録は残ります。'))return;
  remove.disabled=true;
  try{
    await LabAPI.rpc('lab_admin_access',{p_group_id:g.id,p_active:false,p_rotate:true},true);
    if(currentLinkGroup===g.id){$('linkbox').hidden=true;$('group-link').value='';$('new-group').textContent='';currentLinkGroup=null;}
    await list();status('班専用リンクを削除しました。実験記録は残っています。再度配布する場合は「リンク再発行」を押してください。');
  }catch(e){status(e.message,true);}finally{remove.disabled=false;}
};const deleteGroup=document.createElement('button');deleteGroup.textContent='班を削除';deleteGroup.className='danger';deleteGroup.title='班と保存済みの実験記録を完全に削除します。';deleteGroup.onclick=async()=>{
  if(!confirm('「'+g.label+'」と保存済みの実験記録 '+g.runs+' 件を完全に削除しますか？\nこの操作は取り消せません。班専用リンクも使えなくなります。'))return;
  deleteGroup.disabled=true;
  try{
    await LabAPI.rpc('lab_admin_delete',{p_group_id:g.id},true);
    if(currentLinkGroup===g.id){$('linkbox').hidden=true;$('group-link').value='';$('new-group').textContent='';currentLinkGroup=null;}
    if(selected?.id===g.id){selected=null;runs=[];$('runsbox').hidden=true;$('runs').replaceChildren();}
    await list();status('「'+g.label+'」と保存済みの実験記録を削除しました。');
  }catch(e){status(e.message.includes('lab_admin_delete')?'班削除機能の初回設定が必要です。GitHubの「データベースの機能を更新」を実行してください。':e.message,true);}
  finally{deleteGroup.disabled=false;}
};const edit=document.createElement('button');edit.textContent='班名を編集';
const editor=document.createElement('form');editor.className='group-editor';editor.hidden=true;
const label=document.createElement('label');label.textContent='新しい班名';const input=document.createElement('input');input.type='text';input.value=g.label;input.maxLength=100;input.required=true;input.setAttribute('aria-label',g.label+' の新しい班名');label.append(input);
const save=document.createElement('button');save.type='submit';save.textContent='班名を保存';save.className='primary';
const cancel=document.createElement('button');cancel.type='button';cancel.textContent='キャンセル';
edit.onclick=()=>{editor.hidden=false;input.value=g.label;input.focus();input.select();};cancel.onclick=()=>{editor.hidden=true;edit.focus();};
editor.onsubmit=async e=>{
  e.preventDefault();const value=input.value.trim();if(!value||Array.from(value).length>100){status('班名は1～100文字で入力してください。',true);input.focus();return;}
  save.disabled=true;cancel.disabled=true;input.disabled=true;edit.disabled=true;
  try{
    const updated=await LabAPI.rpc('lab_admin_rename',{p_group_id:g.id,p_label:value},true);
    if(currentLinkGroup===g.id)$('new-group').textContent=updated.label;
    if(selected?.id===g.id){selected={...selected,label:updated.label};$('run-title').textContent=updated.label+' の保存履歴';}
    await list();status('班名を「'+updated.label+'」に変更しました。配布済みリンクはそのまま使用できます。');
  }catch(error){status(error.message,true);}
  finally{save.disabled=false;cancel.disabled=false;input.disabled=false;edit.disabled=false;}
};editor.append(label,save,cancel);row.append(edit,view,close,rotate,remove,deleteGroup,editor);box.append(row);}}
async function loadRuns(g){try{runs=await LabAPI.rpc('lab_admin_runs',{p_group_id:g.id},true);selected=g;$('runsbox').hidden=false;$('run-title').textContent=g.label+' の保存履歴';const box=$('runs');box.replaceChildren();if(!runs.length){box.textContent='まだ提出されていません。';return;}for(const r of runs){const section=document.createElement('details');const summary=document.createElement('summary');summary.textContent=new Date(r.created_at).toLocaleString('ja-JP')+' ／ k = '+format(r.analysis.k)+' s⁻¹';section.append(summary);const note=document.createElement('p');note.textContent=`初濃度：${format(r.analysis.c0)} mol/L ／ 回帰切片：${format(r.analysis.intercept)} mol/(L·s)`;section.append(note);if(r.analysis.warning){const warning=document.createElement('p');warning.textContent=r.analysis.warning;section.append(warning);}const scroll=document.createElement('div');scroll.className='scroll';const table=document.createElement('table');const head=document.createElement('tr');['時間(s)','入力体積(mL)','濃度(mol/L)','区間平均減少速度(mol/(L·s))'].forEach(s=>cell(head,s,'th'));table.append(head);r.analysis.concentrations.forEach((p,i)=>{const row=document.createElement('tr');[p.t,r.rows[i].vol,format(p.c),i===0?'—':format(r.analysis.rates[i-1]?.rate)].forEach(s=>cell(row,s));table.append(row);});scroll.append(table);section.append(scroll);box.append(section);}status('教員用の解析結果を表示しました。');}catch(e){status(e.message,true);}}
$('mode').onchange=()=>{$('known').hidden=$('mode').value!=='known';$('c0').required=$('mode').value==='known';};
$('login').onsubmit=async e=>{e.preventDefault();const button=e.currentTarget.querySelector('button');button.disabled=true;status('認証しています…');try{await LabAPI.login($('email').value,$('password').value);$('password').value='';$('login').hidden=true;$('admin').hidden=false;await list();status('ログインしました。');}catch(error){$('password').value='';status(error.message,true);}finally{button.disabled=false;}};
$('create').onsubmit=async e=>{e.preventDefault();const button=e.currentTarget.querySelector('button');button.disabled=true;try{const settings={temp:+$('temp').value,pressure:+$('pressure').value,volume:+$('volume').value,unit:$('unit').value,input:$('input').value,mode:$('mode').value,c0:$('c0').value,wet:$('wet').checked};const g=await LabAPI.rpc('lab_admin_create',{p_label:$('label').value,p_settings:settings},true);showLink(g.label,g.token,g.id);await list();status('班を作成しました。専用リンクを控えて配布してください。');}catch(error){status(error.message,true);}finally{button.disabled=false;}};
$('refresh').onclick=()=>list().then(()=>status('一覧を更新しました。')).catch(e=>status(e.message,true));
$('copy-link').onclick=async()=>{try{await navigator.clipboard.writeText($('group-link').value);status('班の専用リンクをコピーしました。');}catch{$('group-link').select();status('リンクを選択しました。手動でコピーしてください。');}};
$('logout').onclick=async()=>{try{await LabAPI.logout();}catch{}groups=[];runs=[];selected=null;currentLinkGroup=null;$('admin').hidden=true;$('login').hidden=false;$('groups').replaceChildren();$('runs').replaceChildren();$('runsbox').hidden=true;$('linkbox').hidden=true;$('group-link').value='';$('new-group').textContent='';status('ログアウトしました。');};
$('export').onclick=()=>{if(!selected||!runs.length)return;const lines=[['班',selected.label],['実験条件',JSON.stringify(selected.settings)],['保存日時','記録ID','時間(s)','入力体積(mL)','濃度(mol/L)','平均減少速度(mol/(L s))','k(s^-1)','初濃度(mol/L)']];for(const r of runs)r.analysis.concentrations.forEach((p,i)=>lines.push([r.created_at,r.id,p.t,r.rows[i].vol,p.c??'',i===0?'':r.analysis.rates[i-1]?.rate??'',r.analysis.k??'',r.analysis.c0??'']));const escape=v=>{let s=String(v);if(/^[=+@\-\t\r\n]/.test(s)&&typeof v==='string')s="'"+s;return '"'+s.replaceAll('"','""')+'"';};const csv='\ufeff'+lines.map(r=>r.map(escape).join(',')).join('\r\n'),url=URL.createObjectURL(new Blob([csv],{type:'text/csv;charset=utf-8'})),a=document.createElement('a');a.href=url;a.download='教員用_実験記録.csv';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);};
if(!LabAPI.ready()){$('login').querySelector('button').disabled=true;status('保存・認証の初期設定がまだ完了していません。SETUP.mdを参照してください。',true);}
