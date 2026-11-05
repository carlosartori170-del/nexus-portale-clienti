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
 assert.equal(await ctx.brtAutoSave(p,'2026-10'),1);assert.equal(calls.length,1);assert.equal(JSON.stringify(calls[0].body),'{"shipment_id":"s1"}');assert(calls[0].query.includes('shipment_id=is.null'));assert(decodeURIComponent(calls[0].query).includes('reference=eq.99334'));
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

test('No BRT reference: propose unique recipient prefix/CAP/date, never save without review',async()=>{
 const c=charge({recipient:'STEFANIA PIZZ',reference:'99325'}),s=shipment({reference:null,recipient:'Stefania Pizzetti',tracking:'166000000000000001'});
 const {ctx,calls}=setup([c],[s]);const p=ctx.brtAutoPlan([c],[s],'2026-10');
 assert.equal(p[0].shipment.id,'s1');assert.equal(p[0].needsReview,true);
 await assert.rejects(ctx.brtAutoSave(p,'2026-10'),/seleziona esplicitamente/);assert.equal(calls.length,0);
 p[0].reviewConfirmed=true;assert.equal(await ctx.brtAutoSave(p,'2026-10'),1);
});
test('Exact full tracking is a coded match; conflicting reference/tracking never guessed',()=>{
 const c=charge({reference:'missing',carrier_code:'00123456789012'}),s=shipment({reference:null,tracking:'00123456789012'});
 const {ctx}=setup();const p=ctx.brtAutoPlan([c],[s],'2026-10');assert.equal(p[0].shipment.id,'s1');assert.equal(p[0].needsReview,false);
 assert.equal(ctx.brtAutoPlan([c],[shipment({reference:'missing',tracking:'other'}),shipment({...s,id:'s2'})],'2026-10')[0].shipment,null);
 assert.equal(ctx.brtAutoPlan([c],[shipment({...s,tracking:'123456789012'})],'2026-10')[0].shipment,null);
});
test('Fallback rejects ambiguous names, short names, mismatched date/CAP and duplicate target',()=>{
 const c=charge({recipient:'Stefania Pizz',reference:'unknown'}),s=shipment({recipient:'STEFANIA PIZZETTI',reference:null});
 const {ctx}=setup();
 for(const ships of [[s,{...s,id:'s2'}],[{...s,postcode:'20100'}],[{...s,shipped_on:'2026-10-06'}],[{...s,client_id:'japan'}]]){
  assert.equal(ctx.brtAutoPlan([c],ships,'2026-10')[0].shipment,null);
 }
 assert.equal(ctx.brtAutoPlan([{...c,recipient:'Anna'}],[{...s,recipient:'Anna Rossi'}],'2026-10')[0].shipment,null);
 const both=ctx.brtAutoPlan([c,{...c,id:'c2',reference:'another'}],[s],'2026-10');assert.equal(both.filter(x=>x.shipment).length,0);
});
test('Changed Deagor recipient/tracking invalidates reviewed proposal before PATCH',async()=>{
 const c=charge({recipient:'Stefania Pizz',reference:'unknown'}),s=shipment({recipient:'STEFANIA PIZZETTI',reference:null,tracking:'old'}),fresh={...s,tracking:'new'};
 const {ctx,calls}=setup([c],[fresh]);const p=ctx.brtAutoPlan([c],[s],'2026-10');p[0].reviewConfirmed=true;
 await assert.rejects(ctx.brtAutoSave(p,'2026-10'),/Dati modificati/);assert.equal(calls.length,0);
});

test('Preview leaves name-based proposals unchecked; explicit selection enables confirmation',async()=>{
 const c=charge({recipient:'Stefania Pizz',reference:'unknown'}),s=shipment({recipient:'STEFANIA PIZZETTI',reference:null});
 const {ctx,calls}=setup([c],[s]);let boxes=[],closed=false;
 const submit={},button={},form={querySelector:()=>submit,querySelectorAll:selector=>selector.includes('data-proposal')?boxes.filter(x=>x.proposal):boxes.filter(x=>x.checked)};
 Object.assign(ctx,{state:{admin:true,month:'2026-10'},esc:v=>String(v??''),monthName:x=>x,date:x=>x,clientName:()=> 'Cliente prova',table:(heads,rows)=>rows.map(r=>r.join('')).join(''),toast:()=>{},load:async()=>{},FormData:class{get(name){return boxes.find(x=>x.name===name)?.checked?'on':null}},document:{getElementById:id=>id==='brt-auto-match'?button:id==='editform'?form:id==='dialog'?{close:()=>{closed=true}}:{},},showForm:(title,fields)=>{boxes=[...fields.matchAll(/<input type="checkbox" name="(include_[0-9]+)"([^>]+)>/g)].map(m=>({name:m[1],proposal:m[2].includes('data-proposal'),checked:m[2].includes('checked')}))}});
 vm.runInContext(html.slice(html.indexOf('async function brtAutoMatch('),html.indexOf('function matchForm(id){')),ctx);
 await ctx.brtAutoMatch();assert.equal(boxes.length,1);assert.equal(boxes[0].checked,false);assert.equal(submit.disabled,true);
 form.onchange({target:{id:'brt-select-proposals',checked:true}});assert.equal(boxes[0].checked,true);assert.equal(submit.disabled,false);
 await form.onsubmit({preventDefault(){}});assert.equal(calls.length,1);assert.equal(closed,true);
});

test('REST regression: save filters match stored values literally, including punctuation',async()=>{
 const c=charge({recipient:'D\'Angelo, "Mario" & Figli (MI)',reference:'99325',carrier_code:'00123456789012'});
 const s=shipment({reference:'99325',recipient:c.recipient});
 const {ctx,calls}=setup([c],[s],async(table,request)=>{
  const query=new URLSearchParams(request.query);
  for(const k of ['reference','carrier_code','recipient','postcode','shipped_on','month']){
   assert.equal(query.get(k),'eq.'+c[k],k+' must preserve the literal value without extra quotes');
  }
  assert.equal(query.get('id'),'eq.'+c.id);assert.equal(query.get('shipment_id'),'is.null');
  assert.equal(query.size,9);assert.equal(query.get('nexus_owned'),'eq.false');assert.equal(Object.keys(request.body).join(','),'shipment_id');
  return[{id:c.id,shipment_id:s.id}];
 });
 const plan=ctx.brtAutoPlan([c],[s],'2026-10');assert.equal(await ctx.brtAutoSave(plan,'2026-10'),1);assert.equal(calls.length,1);
});

