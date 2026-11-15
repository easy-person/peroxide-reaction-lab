import fs from 'node:fs/promises';
import {createHash} from 'node:crypto';
const directory=new URL('../dist/',import.meta.url);
for(const file of (await fs.readdir(directory)).filter(name=>name.endsWith('.html'))){
  let source=await fs.readFile(new URL(file,directory),'utf8');
  const references=[...source.matchAll(/(?:src|href)="([^"?]+\.(?:js|css))(?:\?[^\"]*)?"/g)];
  for(const match of references){
    if(match[1].includes(':')||match[1].startsWith('/'))continue;
    const bytes=await fs.readFile(new URL(match[1],directory));
    const version=createHash('sha256').update(bytes).digest('hex').slice(0,12);
    source=source.replace(match[0],match[0].replace(/=".*"$/,`="${match[1]}?v=${version}"`));
  }
  await fs.writeFile(new URL(file,directory),source);
}
