(function(root,factory){if(typeof module==='object'&&module.exports)module.exports=factory();else root.InPostCore=factory()})(typeof globalThis!=='undefined'?globalThis:this,function(){
 'use strict';
 function restoreZip(input){
  const b=new Uint8Array(input.buffer||input,input.byteOffset||0,input.byteLength),d=new DataView(b.buffer,b.byteOffset,b.byteLength),entries=[];let p=0,total=0;
  while(p+30<=b.length&&d.getUint32(p,true)===0x04034b50){
   const flags=d.getUint16(p+6,true),size=d.getUint32(p+18,true),expanded=d.getUint32(p+22,true),nl=d.getUint16(p+26,true),el=d.getUint16(p+28,true),end=p+30+nl+el+size;
   if(end>b.length)break;if(flags&9)throw Error('Excel incompleto: salva nuovamente il file originale come .xlsx');
   total+=expanded;if(total>50*1024*1024)throw Error('Excel troppo grande dopo la decompressione');
   entries.push({offset:p,name:b.slice(p+30,p+30+nl),header:b.slice(p,p+30)});p=end;
  }
  const names=entries.map(e=>new TextDecoder().decode(e.name));
  if(!names.includes('xl/workbook.xml')||!names.includes('xl/sharedStrings.xml')||!names.some(n=>/^xl\/worksheets\/sheet\d+\.xml$/.test(n)))throw Error('Excel incompleto: mancano dati necessari; salva nuovamente il file originale');
  const cdSize=entries.reduce((n,e)=>n+46+e.name.length,0),out=new Uint8Array(p+cdSize+22);out.set(b.slice(0,p));const v=new DataView(out.buffer);let at=p;
  for(const e of entries){
   v.setUint32(at,0x02014b50,true);v.setUint16(at+4,20,true);out.set(e.header.slice(4,28),at+6);v.setUint16(at+30,0,true);v.setUint16(at+32,0,true);v.setUint32(at+42,e.offset,true);out.set(e.name,at+46);at+=46+e.name.length;
  }
  v.setUint32(at,0x06054b50,true);v.setUint16(at+8,entries.length,true);v.setUint16(at+10,entries.length,true);v.setUint32(at+12,cdSize,true);v.setUint32(at+16,p,true);return out;
 }
 function readExcel(input,X){
  let book,recovered=false;const opts={type:'array',raw:true,sheetRows:5002};
  try{book=X.read(input,opts)}catch(e){book=X.read(restoreZip(input),opts);recovered=true}
  const all=[];let headers=null;
  for(const name of book.SheetNames){
   const sheet=book.Sheets[name];if(!sheet)throw Error('Foglio Excel mancante: '+name);
   const rows=X.utils.sheet_to_json(sheet,{header:1,raw:true,defval:''});if(!rows.some(r=>r.some(v=>v!=='')))continue;
   const h=rows.shift().map(x=>String(x).trim());
   if(!['packcode','price','fuel_surcharge','invoicingMonth','customer_stored_date','delivery_zip_code'].every(x=>h.includes(x)))throw Error('Intestazioni InPost non riconosciute nel foglio '+name);
   if(new Set(h).size!==h.length)throw Error('Intestazioni duplicate nel foglio '+name);
   if(sheet['!fullref']&&X.utils.decode_range(sheet['!fullref']).e.r>5000)throw Error('Massimo 5000 spedizioni per file');
   headers=h;rows.forEach((r,i)=>{if(r.some(v=>v!==''))all.push({sheet:name,row:i+2,values:Object.fromEntries(h.map((k,j)=>[k,r[j]??'']))})});
  }
  if(!headers||!all.length)throw Error('Il file non contiene spedizioni InPost');if(all.length>5000)throw Error('Massimo 5000 spedizioni per file');
  const parsed=parseRows(all);return {...parsed,recovered};
 }
 function day(value){const s=String(value||'').trim().slice(0,10);if(!/^\d{4}-\d{2}-\d{2}$/.test(s)||!Number.isFinite(Date.parse(s+'T12:00:00Z'))||new Date(s+'T12:00:00Z').toISOString().slice(0,10)!==s)throw Error('Data InPost non valida');return s}
 function amount(value,label){if(value==null||String(value).trim()==='')throw Error(label+' mancante');const n=Number(String(value).trim().replace(',','.'));if(!Number.isFinite(n)||n<0||Math.abs(n*10000-Math.round(n*10000))>0.00001)throw Error(label+' non valido');return n}
 function parseRows(input){
  const rows=[],errors=[],seen=new Set();let month=null;
  for(const entry of input){try{
   const r=entry.values,code=r.packcode;if(typeof code!=='string'||!/^\d{12,40}$/.test(code.trim()))throw Error('packcode deve essere testo completo: non usare codici arrotondati o in notazione scientifica');
   const packcode=code.trim(),m=String(r.invoicingMonth).trim();if(!/^\d{4}-(0[1-9]|1[0-2])$/.test(m))throw Error('Mese fattura non valido');if(month&&month!==m)throw Error('Il file contiene più mesi di fatturazione');month=m;
   if(seen.has(packcode))throw Error('packcode duplicato nel file');seen.add(packcode);
   const date=day(r.manifest_date||r.customer_stored_date||r.first_depot_date),transport=amount(r.price,'Trasporto'),fuel=amount(r.fuel_surcharge,'Carburante'),pc=String(r.delivery_zip_code).trim();
   rows.push({row:entry.row,sheet:entry.sheet,packcode,month:m,shipped_on:date,transport,fuel,extras:0,recipient:String(r.delivery_email||r.delivery_point_name||r.delivery_city||packcode).trim(),postcode:/^\d{1,5}$/.test(pc)?pc.padStart(5,'0'):pc});
  }catch(e){errors.push({row:entry.row,sheet:entry.sheet,message:e.message})}}
  return {rows,errors,month,total:Math.round(rows.reduce((n,r)=>n+r.transport+r.fuel,0)*100)/100};
 }
 function plan(rows,shipments,costs){
  const tracking=x=>String(x??'').trim().replace(/\s+/g,'');
  return rows.map(r=>{
   const matches=shipments.filter(s=>tracking(s.tracking)===r.packcode),already=costs.filter(c=>String(c.invoice_number).startsWith('INPOST ')&&c.carrier_code===r.packcode&&String(c.month).slice(0,7)===r.month);
   const p={...r,shipment_id:null,skip:false,reason:''};
   if(already.length){p.skip=true;p.conflict=already.length!==1||Number(already[0].transport)!==r.transport||Number(already[0].fuel)!==r.fuel||Number(already[0].extras)!==0;p.reason=p.conflict?'packcode già presente con costi diversi: verifica senza sovrascrivere':'Già importata';return p}
   if(matches.length===1){const s=matches[0];if(costs.some(c=>c.shipment_id===s.id)){p.reason='Spedizione con costo già collegato: verifica manuale';return p}p.shipment_id=s.id;p.reason='Tracking completo coincidente';return p}
   p.reason=matches.length?'Tracking presente su più spedizioni: verifica manuale':'Tracking non trovato: da abbinare / cliente diretto / Nexus';return p;
  });
 }
 return {restoreZip,readExcel,parseRows,plan};
});
