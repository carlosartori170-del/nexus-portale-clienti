const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const source=html.slice(html.indexOf('function brtAutoPlan('),html.indexOf('async function brtAutoMatch('));
const charge=(x={})=>({id:'c1',invoice_number:'626942',reference:'99334',postcode:'00125',shipped_on:'2026-10-05',month:'2026-10-01',shipment_id:null,...x});
const shipment=(x={})=>({id:'s1',reference:'99334',postcode:'00125',shipped_on:'2026-10-05',client_id:'optic',carrier:'BRT',...x});
function setup(charges=[charge()],shipments=[shipment()],api=async()=>[{id:'c1'}]){
 const calls=[],ctx={state:{admin:true},SP_EXCLUDED_CLIENT:'japan',spIsCharge:c=>c.invoice_number==='CSV SPEDIAMO PRO',all:async t=>t==='portal_shipments'?shipments:charges,api:async(t,v)=>{calls.push({t,...v});return api(t,v)}};
 vm.createContext(ctx);vm.runInContext(source,ctx);return{ctx,calls,charges,shipments};
}
test('Unique reference + CAP/date; preserve leading zeros in references',()=>{
 const {ctx}=setup();assert.equal(ctx.brtAutoPlan([charge()],[shipment()],'2026-10')[0].shipment.id,'s1');
 assert.equal(ctx.brtAutoPlan([charge({postcode:'125'})],[shipment()],'2026-10')[0].shipment.id,'s1');
 assert.equal(ctx.brtAutoPlan([charge({reference:'0001'})],[shipment({reference:'1'})],'2026-10')[0].shipment,null);
});
test('Ambiguity, CAP/date mismatch, other carrier, own contract, existing/duplicate costs stay manual',()=>{
 for(const ships of [[shipment(),shipment({id:'s2'})],[shipment({postcode:'20021'})],[shipment({shipped_on:'2026-10-06'})],[shipment({carrier:'SDA'})],[shipment({client_id:'japan'})],[shipment({postcode:''})]]){
  const {ctx}=setup();assert.equal(ctx.brtAutoPlan([charge()],ships,'2026-10')[0].shipment,null);
 }
 const {ctx}=setup();assert.equal(ctx.brtAutoPlan([charge(),charge({id:'linked',shipment_id:'s1'})],[shipment()],'2026-10')[0].shipment,null);
 assert.equal(ctx.brtAutoPlan([charge(),charge({id:'duplicate'})],[shipment()],'2026-10').filter(x=>x.shipment).length,0);
});
test('Month scope; skip Spediamo Pro and already linked BRT',()=>{
 const {ctx}=setup();assert.equal(ctx.brtAutoPlan([charge({month:'2026-09-01'}),charge({invoice_number:'CSV SPEDIAMO PRO'}),charge({shipment_id:'s1'})],[shipment()],'2026-10').length,0);
});
test('Save patches linkage only with null guard; repeat is idempotent',async()=>{
 const {ctx,calls}=setup();const p=ctx.brtAutoPlan([charge()],[shipment()],'2026-10');
 assert.equal(await ctx.brtAutoSave(p,'2026-10'),1);assert.equal(calls.length,1);assert.equal(JSON.stringify(calls[0].body),'{"shipment_id":"s1"}');assert(calls[0].query.includes('shipment_id=is.null'));assert(calls[0].query.includes('reference=eq.99334'));
 assert.equal(await ctx.brtAutoSave(p,'2026-10'),0);assert.equal(calls.length,1);
});
test('Changed rows/admin permissions/empty PATCH response cannot silently succeed',async()=>{
 const {ctx,calls,charges}=setup();const p=ctx.brtAutoPlan([charge()],[shipment()],'2026-10');charges[0].shipment_id='manual';
 await assert.rejects(ctx.brtAutoSave(p,'2026-10'),/Dati modificati/);assert.equal(calls.length,0);
 ctx.state.admin=false;await assert.rejects(ctx.brtAutoSave(p,'2026-10'),/Accesso riservato/);
 const race=setup(undefined,undefined,async()=>[]);const p2=race.ctx.brtAutoPlan([charge()],[shipment()],'2026-10');await assert.rejects(race.ctx.brtAutoSave(p2,'2026-10'),/non aggiornabile/);
});
test('Partial failure reports progress and retains saved linkage',async()=>{
 let n=0;const a=charge(),b=charge({id:'c2',reference:'99335'});const ships=[shipment(),shipment({id:'s2',reference:'99335'})];const {ctx}=setup([a,b],ships,async()=>{if(++n===2)throw Error('Errore di rete');return[{id:'c1'}]});
 const p=ctx.brtAutoPlan([a,b],ships,'2026-10');await assert.rejects(ctx.brtAutoSave(p,'2026-10'),/1 nuovi abbinamenti salvati.*Errore di rete/);assert.equal(a.shipment_id,'s1');assert.equal(b.shipment_id,null);
});
