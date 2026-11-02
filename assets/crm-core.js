/* CRM core: pure helpers shared by the browser and Node checks. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.CRMCore=api})(typeof globalThis!=='undefined'?globalThis:this,function(){
 'use strict';
 const headers='slug,azienda,settore,sito,citta,piattaforma,segnali_crescita,referente,contatto_pubblico,priorita,fonte,messaggio_linkedin,stato,note,assegnato_a'.split(',');
 const states={da_contattare:'Da contattare',contattato:'Contattato',risposto:'Risposto',appuntamento:'Appuntamento',cliente:'Cliente',perso:'Perso'};
 const sectors=['Cosmetica e cura persona','Casa e lifestyle','Pet','Altro'],priorities=['Alta','Media','Bassa'];
 const slugify=v=>String(v||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'');
 const validate=r=>{const e=[];if(!String(r.slug||'').trim())e.push('Slug obbligatorio');if(!String(r.azienda||'').trim())e.push('Azienda obbligatoria');if(!sectors.includes(r.settore))e.push('Settore non valido');if(!priorities.includes(r.priorita))e.push('Priorità non valida');if(!Object.hasOwn(states,r.stato))e.push('Stato non valido');return e};
 function parseCSV(text,Papa){
  text=String(text).replace(/^\uFEFF/,'');let repaired=false;
  // Recover the exact extra semicolon/escaped-cell envelope found in the supplied export.
  if(text.split(/\r?\n/,1)[0]===headers.join(',')+';'){
   const lines=text.split(/\r?\n/);text=lines.map(line=>{if(!line)return '';const r=Papa.parse(line,{delimiter:';',skipEmptyLines:false});if(r.errors.length)throw Error('CSV non recuperabile: '+r.errors[0].message);const cells=r.data[0];if(cells.length>1&&cells[cells.length-1]==='')cells.pop();return cells.join(';')}).join('\n');repaired=true;
  }
  const result=Papa.parse(text,{header:true,delimiter:',',skipEmptyLines:'greedy'});
  if(JSON.stringify(result.meta.fields)!==JSON.stringify(headers))throw Error('Intestazioni non valide. Attese: '+headers.join(','));
  if(result.data.length>5000)throw Error('Massimo 5000 righe per importazione');
  const seen=new Set(),errors=[],valid=[];
  result.data.forEach((r,i)=>{const issues=validate(r);if(seen.has(r.slug))issues.push('Slug duplicato nel file');seen.add(r.slug);for(const e of result.errors.filter(e=>e.row===i))issues.push(e.message);if(issues.length)errors.push({riga:i+2,slug:r.slug||'',motivo:issues.join('; ')});else valid.push(Object.fromEntries(headers.map(k=>[k,String(r[k]??'')])))});
  for(const e of result.errors.filter(e=>!Number.isInteger(e.row)))errors.push({riga:0,slug:'',motivo:e.message});
  return {rows:valid,errors,repaired,total:result.data.length};
 }
 function filtered(leads,filters={}){const term=String(filters.search||'').toLocaleLowerCase('it');return leads.filter(r=>(!filters.status||r.stato===filters.status)&&(!filters.sector||r.settore===filters.sector)&&(!filters.priority||r.priorita===filters.priority)&&(!term||['azienda','citta','referente','segnali_crescita'].some(k=>String(r[k]||'').toLocaleLowerCase('it').includes(term)))).sort((a,b)=>priorities.indexOf(a.priorita)-priorities.indexOf(b.priorita)||String(a.prossimo_followup||'9999-12-31').localeCompare(String(b.prossimo_followup||'9999-12-31'))||a.azienda.localeCompare(b.azienda,'it'))}
 function safeURL(value){if(!value||/da verificare/i.test(value))return '';try{const u=new URL(/^https?:\/\//i.test(value)?value:'https://'+value);return ['http:','https:'].includes(u.protocol)&&!u.username&&!u.password?u.href:''}catch{return ''}}
 function exportCSV(leads,Papa){return '\uFEFF'+Papa.unparse({fields:headers,data:leads.map(r=>headers.map(k=>r[k]??''))},{newline:'\r\n',escapeFormulae:true})}
 return {headers,states,sectors,priorities,slugify,validate,parseCSV,filtered,safeURL,exportCSV};
});
