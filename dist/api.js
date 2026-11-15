(function(){
  let session=null;
  const config=window.LAB_CONFIG||{};
  function ready(){return /^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(config.supabaseUrl||'')&&!!config.anonKey;}
  async function request(path,body,authenticated=false){
    if(!ready())throw Error('保存・認証の初期設定がまだ完了していません。教員に確認してください。');
    const response=await fetch(config.supabaseUrl+path,{
      method:'POST',headers:{'Content-Type':'application/json',apikey:config.anonKey,
        ...(authenticated?{Authorization:'Bearer '+(session?.access_token||'')}:config.anonKey.startsWith('eyJ')?{Authorization:'Bearer '+config.anonKey}:{})},body:JSON.stringify(body)});
    const data=await response.json().catch(()=>null);
    if(!response.ok)throw Error(response.status===401?'ログインの有効期限が切れています。再度ログインしてください。':data?.message||data?.msg||data?.error_description||'通信に失敗しました。入力はそのまま残っています。');
    return data;
  }
  window.LabAPI={ready,
    rpc:(name,body={},admin=false)=>request('/rest/v1/rpc/'+name,body,admin),
    async login(email,password){session=null;const s=await request('/auth/v1/token?grant_type=password',{email,password});session=s;
      try{await request('/rest/v1/rpc/lab_admin_groups',{},true);}catch(e){session=null;throw e;}
    },
    async logout(){try{if(session)await request('/auth/v1/logout',{},true);}finally{session=null;}}
  };
})();
