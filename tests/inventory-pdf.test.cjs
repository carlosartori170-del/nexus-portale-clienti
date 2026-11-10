const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path'),core=require('../assets/inventory-pdf.js');
const fields=['sku','ean','name','volume','height','width','length','total_qty','integration'];
const row=(values,y)=>Object.entries(values).filter(([,v])=>v!==null).map(([k,v])=>({str:String(v),x:10+fields.indexOf(k)*100,y}));
const header=(withIntegration=true,y=100)=>row(Object.fromEntries(fields.filter(f=>withIntegration||f!=='integration').map(f=>[f,f])),y);
const item=(sku='SKU-1',qty='12',volume='0.00900000')=>({sku,name:'Articolo con numeri 71 x 41 x 15 e virgole, colore C',volume,height:'40.0000',width:'15.0000',length:'15.0000',total_qty:qty,integration:'Cliente test'});
test('Reads optional integration and EAN as separate columns, preserving spaces in SKU and full descriptions',()=>{
 const p=core.parse([[...header(),...row({...item('SKU con spazi'),ean:'X002TEST123'},90)]]);
 assert.equal(p.items.length,1);assert.equal(p.items[0].sku,'SKU con spazi');assert.equal(p.items[0].name,item().name);assert.equal(p.items[0].volume,.009);assert.equal(p.items[0].qty,12);
});
test('Legacy PDFs without integration retain the same SKU/quantity/volume; repeated page headers are supported',()=>{
 const old=item('SKU-0');delete old.integration;
 const p=core.parse([[...header(false),...row(old,90)],[...header(false),...row({...old,sku:'SKU-1'},90)]]);assert.equal(p.items.length,2);assert.equal(p.items[1].qty,12);
});
test('Description and numeric cells can continue below the SKU without being guessed from text numbers',()=>{
 const first=item();delete first.total_qty;first.name='Prima parte 100 x 50';
 const p=core.parse([[...header(),...row(first,90),...row({name:'descrizione su seconda riga',total_qty:'25'},85),...row(item('SKU-2','0','0'),75)]]);
 assert.equal(p.items[0].name,'Prima parte 100 x 50 descrizione su seconda riga');assert.equal(p.items[0].qty,25);assert.equal(p.items[1].volume,0);
});
test('Never skips corrupt quantities, duplicate SKUs, mixed clients, missing columns or ambiguous numeric continuations',()=>{
 for(const values of [{...item(),volume:'sconosciuto'},{...item(),total_qty:'1,2'},{...item(),total_qty:null},{...item(),height:'-1'}])assert.throws(()=>core.parse([[...header(),...row(values,90)]]));
 assert.throws(()=>core.parse([[...header(),...row(item(),90),...row(item(),80)]]),/duplicato/);
 assert.throws(()=>core.parse([[...header(),...row(item(),90),...row({...item('SKU-2'),integration:'Altro cliente'},80)]]),/più clienti/);
 assert.throws(()=>core.parse([[...header(),...row(item(),90),...row({volume:'1'},85)]]),/ambiguo/);
 assert.throws(()=>core.parse([[{str:'tabella incompleta',x:10,y:100}]]),/tabella/);
});
test('Quantities and volumes flow into the existing precise inventory totals and preview without extra DB fields',()=>{
 const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8'),ctx={InventoryPDF:core};vm.createContext(ctx);
 for(const name of ['inventoryItemsTotal','inventoryPDFData'])vm.runInContext(html.split('\n').find(l=>l.startsWith('function '+name+'(')),ctx);
 const p=ctx.inventoryPDFData([[...header(),...row(item('A','2','0.00900000'),90),...row(item('B','3','0.01070000'),80),...row(item('C','2','0'),70)]]);
 assert.equal(p.volume_m3,.0501);assert.equal(p.total_units,7);assert.equal(p.sku_count,3);assert.equal(p.zero_volume_skus,1);assert(!Object.hasOwn(p,'integration'));
 assert(html.includes('return inventoryPDFData(pages)'));assert(html.includes("finally{await doc.destroy()}"));
});
