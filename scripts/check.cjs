const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),path=require('node:path');
const root=path.join(__dirname,'..'),html=fs.readFileSync(path.join(root,'index.html'),'utf8');
let inlineCount=0;for(const match of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)){const src=match[1].match(/src="([^"]+)"/);if(src){if(!/^https?:/.test(src[1]))new vm.Script(fs.readFileSync(path.join(root,src[1]),'utf8'),{filename:src[1]})}else if(match[2].trim()){new vm.Script(match[2],{filename:'index-inline-'+(++inlineCount)+'.js'})}}
assert(inlineCount>0);assert(html.includes("['crm','CRM']"));assert(html.includes("!['manage','imports','crm'].includes(v)"));assert(html.includes('assets/crm.css'));assert(!/sb_secret_[A-Za-z0-9_-]+/.test(html));
console.log('Build statico OK: JavaScript valido, risorse CRM presenti, voce CRM riservata agli amministratori.');
