const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8'),source=html.slice(html.indexOf('const carrierTableFilters='),html.indexOf('function head(title,desc'));
function setup(){
 const orders=[{id:'brt',client_id:'a',recipient:'Anna Rossi',shipped_on:'2026-10-02',code:'D001',carrier:'BRT'},{id:'sp',client_id:'a',recipient:'Carlo Bianchi',shipped_on:'2026-10-03',code:'D002',carrier:'Spediamo Pro'},{id:'other',client_id:'b',recipient:'Gianni Verdi',shipped_on:'2026-10-01',code:'D003',carrier:'Altro'}];
 const costs=[{shipment_id:'brt',month:'2026-11-01',invoice_number:'BRT futura'},{shipment_id:'sp',month:'2026-10-01',invoice_number:'CSV SPEDIAMO PRO'}],out={};
 const ctx={state:{shipments:orders,charges:costs,month:'2026-10',client:'all',clients:[{id:'a',name:'A'},{id:'b',name:'B'}]},shipments:()=>orders,charges:()=>costs,esc:v=>String(v??''),money:x=>x.toFixed(2),clientName:x=>x,downloadCSV:(name,rows)=>{out.csv=rows},render:()=>{out.rendered=true},toast:x=>{out.error=x}};
 vm.createContext(ctx);vm.runInContext(fs.readFileSync(path.join(__dirname,'../assets/client-period.js'),'utf8'),ctx);vm.runInContext(source,ctx);return {ctx,orders,costs,out};
}
test('Unmatched Deagor list checks every carrier and invoice month, ignoring standalone Nexus costs',()=>{
 const {ctx,orders,costs}=setup();assert.deepEqual(Array.from(ctx.carrierRows('pending'),x=>x.id),['other']);
 costs.push({shipment_id:null,nexus_owned:true});assert.deepEqual(Array.from(ctx.carrierRows('pending'),x=>x.id),['other']);
 costs.push({shipment_id:'other',invoice_number:'UPS'});assert.equal(ctx.carrierRows('pending').length,0);
 assert.equal(orders.length,3);
});
test('Removing a linkage restores the missing shipment; pending CSV follows filters and dates',()=>{
 const {ctx,costs,out}=setup();costs[1].shipment_id=null;
 vm.runInContext("carrierTableFilters.pending={client:'a',recipient:'carlo',sort:'date_asc'}",ctx);
 ctx.exportPendingCarrierShipments();assert.equal(out.csv.length,2);assert.equal(out.csv[1][2],'D002');assert.equal(out.csv[0].includes('Importo cliente'),false);
});
test('Pending filters have no amount fields; Apply works when those fields are absent',()=>{
 const {ctx,out}=setup(),bar=ctx.carrierFilterBar('pending');assert(!bar.includes('Importo minimo'));assert(!bar.includes('Importi al cliente'));assert(bar.includes('spedizioni senza costo abbinato'));
 ctx.document={getElementById:()=>({reportValidity:()=>true})};ctx.FormData=class{constructor(){return new Map([['client','b'],['recipient','gianni'],['sort','date_asc']])}};
 ctx.applyCarrierFilters({preventDefault(){}},'pending');assert.equal(out.error,undefined);assert.equal(out.rendered,true);assert.equal(ctx.carrierRows('pending').length,1);
});
test('Admin Corrieri markup replaces customer price table with missing-cost table',()=>{
 const section=html.split('\n').find(l=>l.startsWith("if(view==='carriers')")),admin=section.slice(0,section.indexOf('}else{'));
 assert(admin.includes('Spedizioni Deagor senza costo corriere abbinato'));assert(admin.includes("carrierRows('pending')"));assert(!admin.includes('Addebiti da fatturare ai clienti'));assert(!admin.includes('money(s.customer_charge)'));
});
