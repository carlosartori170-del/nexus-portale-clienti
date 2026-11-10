(function(root,factory){if(typeof module==='object'&&module.exports)module.exports=factory();else root.InventoryPDF=factory()})(typeof globalThis!=='undefined'?globalThis:this,function(){
 'use strict';
 const columns=['sku','ean','name','volume','height','width','length','total_qty','integration'];
 const required=['sku','name','volume','height','width','length','total_qty'];
 const key=s=>String(s).trim().toLowerCase().replace(/\s+/g,'');
 function rows(page){
  const items=page.filter(i=>String(i.str??'').trim()).map(i=>({...i,str:String(i.str).trim()}));
  if(items.some(i=>!Number.isFinite(i.x)||!Number.isFinite(i.y)))throw Error('Testo PDF senza coordinate leggibili. Usa il CSV.');
  items.sort((a,b)=>b.y-a.y||a.x-b.x);const groups=[];
  for(const i of items){let g=groups[groups.length-1];if(!g||Math.abs(g.y-i.y)>=1){g={y:i.y,items:[]};groups.push(g)}g.items.push(i)}
  return groups.map(g=>g.items.sort((a,b)=>a.x-b.x));
 }
 function header(row){
  const found=row.filter(i=>columns.includes(key(i.str)));
  if(!required.every(k=>found.some(i=>key(i.str)===k)))return null;
  if(new Set(found.map(i=>key(i.str))).size!==found.length)throw Error('Intestazioni PDF duplicate: verifica il file.');
  return found.map(i=>({name:key(i.str),x:i.x})).sort((a,b)=>a.x-b.x);
 }
 function cells(row,layout){
  const out={};for(const item of row){let col=null;for(const c of layout){if(item.x>=c.x-1)col=c;else break}
   if(!col)throw Error('Testo fuori dalle colonne inventario: '+item.str.slice(0,80));
   out[col.name]=(out[col.name]?out[col.name]+' ':'')+item.str;
  }return out;
 }
 function decimal(value,label,sku){
  if(!/^\d+(?:[.,]\d+)?$/.test(value??''))throw Error(label+' non valido nel PDF per '+sku);
  const n=Number(value.replace(',','.'));if(!Number.isFinite(n))throw Error(label+' non valido nel PDF per '+sku);return n;
 }
 function parse(pages){
  if(!Array.isArray(pages)||!pages.length)throw Error('PDF senza pagine leggibili');
  const items=[],seen=new Set(),integrations=new Set();let layout=null,pending=null,found=false;
  function finish(){
   if(!pending)return;const sku=pending.sku;
   if(!sku||seen.has(sku))throw Error('SKU mancante o duplicato nel PDF: '+sku);
   if(!/^\d+$/.test(pending.total_qty??''))throw Error('Quantità mancante o non valida nel PDF per '+sku);
   const qty=Number(pending.total_qty);if(!Number.isSafeInteger(qty))throw Error('Quantità troppo grande nel PDF per '+sku);
   const volume=decimal(pending.volume,'Volume',sku);for(const k of ['height','width','length'])decimal(pending[k],k,sku);
   if(layout.some(c=>c.name==='integration')){if(!pending.integration)throw Error('Cliente integration mancante nel PDF per '+sku);integrations.add(pending.integration.trim().toUpperCase());if(integrations.size>1)throw Error('Il PDF contiene più clienti integration: importa il CSV per separarli correttamente')}
   seen.add(sku);items.push({sku,name:pending.name||'',volume,qty});pending=null;
   if(items.length>50000)throw Error('Inventario troppo grande: usa il CSV');
  }
  for(const page of pages){
   const groups=rows(page),firstHeader=groups.findIndex(g=>header(g));
   if(!layout&&firstHeader<0)throw Error('Il PDF non contiene la tabella inventario Deagor riconoscibile. Usa il CSV.');
   for(let i=firstHeader>=0?firstHeader:0;i<groups.length;i++){
    const row=groups[i],next=header(row);if(next){if(pending)finish();layout=next;found=true;continue}
    const text=row.map(i=>i.str).join(' ');
    if(/^(?:(?:pagina|page)\s+\d+(?:\s*(?:\/|di|of)\s*\d+)?|\d+\s*\/\s*\d+)$/i.test(text))continue;
    const values=cells(row,layout);
    if(values.sku){finish();pending=values;continue}
    if(!pending)throw Error('Riga PDF senza SKU: '+text.slice(0,100));
    for(const [k,v] of Object.entries(values)){
     if(pending[k]&&['volume','height','width','length','total_qty'].includes(k))throw Error('Valore '+k+' ripetuto o ambiguo nel PDF per '+pending.sku);
     pending[k]=(pending[k]?pending[k]+' ':'')+v;
    }
   }
  }
  finish();if(!found||!items.length)throw Error('Il PDF non contiene la tabella inventario Deagor riconoscibile. Usa il CSV.');
  return {items};
 }
 return {parse};
});
