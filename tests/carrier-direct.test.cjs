const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
test('Direct client costs filter as assigned, not unmatched, and never close a Deagor order',()=>{
 const ctx={};vm.createContext(ctx);vm.runInContext(html.slice(html.indexOf('const carrierTableFilters='),html.indexOf('function head(title,desc')),ctx);
 const row={id:'c1',direct_client_id:'client',shipment_id:null,nexus_owned:false,recipient:'Persona',shipped_on:'2026-10-01'};
 assert.equal(ctx.filterCarrierRows([row],[],'costs',{client:'client',matchStatus:'matched'}).length,1);
 assert.equal(ctx.filterCarrierRows([row],[],'costs',{matchStatus:'unmatched'}).length,0);
 assert.equal(ctx.unmatchedCarrierShipments([{id:'s1'}],[row]).length,1);
});
test('BRT auto matcher excludes direct assignments and InPost documents',()=>{
 const ctx={spIsCharge:()=>false,SP_EXCLUDED_CLIENT:'japan'};vm.createContext(ctx);vm.runInContext(html.slice(html.indexOf('function brtAutoPlan('),html.indexOf('async function brtAutoSave(')),ctx);
 const c={id:'c',invoice_number:'BRT 1',direct_client_id:'client',month:'2026-10-01'};
 assert.equal(ctx.brtAutoPlan([c],[],'2026-10').length,0);assert.equal(ctx.brtAutoPlan([{...c,direct_client_id:null,invoice_number:'INPOST 1'}],[],'2026-10').length,0);
});
test('Manual clients can validate direct carrier totals without manual quantity entry',()=>{
 const start=html.indexOf('function billingValidationCurrent('),end=html.indexOf('function billingAllValid(',start);
 const ctx={state:{sectionValidations:[{client_id:'client',month:'2026-10-01',payload:{source:'direct',carrier_total:4.15}}]},billingRequirements:()=>({source:'manual',fields:['carrier_total']}),BILLING_SECTION_FIELDS:{carriers:['carrier_total']}};vm.createContext(ctx);vm.runInContext(html.slice(start,end),ctx);
 ctx.state.sectionValidations[0].section='carriers';assert(ctx.billingValidationCurrent({id:'client'},'carriers','2026-10'));
 assert(html.includes("if(section!=='carriers'&&state.clients"));assert(html.includes("Contratto diretto"));
});
