import fs from 'node:fs/promises';
import path from 'node:path';
const token=process.env.SUPABASE_ACCESS_TOKEN;
const ref='prugathfqdbvvlkavqeh';
if(!token){
  console.error('SUPABASE_ACCESS_TOKEN が未設定です。GitHub Settings → Secrets and variables → Actionsで登録してください。');
  process.exit(1);
}
const directory=new URL('../supabase/migrations/',import.meta.url);
for(const file of (await fs.readdir(directory)).filter(f=>f.endsWith('.sql')).sort()){
  const sql=await fs.readFile(new URL(file,directory),'utf8');
  const response=await fetch(`https://api.supabase.com/v1/projects/${ref}/database/query`,{
    method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql})
  });
  if(!response.ok){
    console.error(`${file}: 適用失敗（HTTP ${response.status}）。トークンの権限とプロジェクトへのアクセスを確認してください。`);
    process.exit(1);
  }
  console.log(`${file}: 適用完了`);
}
