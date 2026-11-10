const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const source=fs.readFileSync(path.join(__dirname,'../assets/manual-carrier.js'),'utf8'),html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
function setup(){
 const s={id:'s',client_id:'a',code:'D001',recipient:'Anna',carrier:'BRT',shipped_on:'2026-10-01',tracking:'000123',customer_charge:null},calls=[],out={};
 const ctx={state:{admin:true,clients:[{id:'a',name:'Cliente A'}],shipments:[s],charges:[]},esc:v=>String(v??''),date:x=>x,money:x=>Number(x).toFixed(2)+' €',num:String,clientName:()=> 'Cliente A',spEligible:()=>true,field:(name,label,value)=>label+' value='+value,toast:t=>{out.toast=t},showForm:(title,form,save)=>{Object.assign(out,{title,form,save})},api:async(route,args)=>{calls.push({route,args})}};
 vm.createContext(ctx);vm.runInContext(source,ctx);return {ctx,s,calls,out};
}
test('Manual net amounts support Italian decimals and zero, reject empty, negative and excess precision',()=>{
 const {ctx}=setup();assert.equal(ctx.manualCarrierAmount('5,60'),5.6);assert.equal(ctx.manualCarrierAmount('0'),0);
 for(const v of ['',null,'-1','5.601','NaN','Infinity','1e3'])assert.throws(()=>ctx.manualCarrierAmount(v));
});
test('Save uses existing shipment/client and one atomic RPC for supplier and customer amounts',async()=>{
 const {ctx,s,calls,out}=setup();ctx.manualCarrierCostForm(s.id);assert.match(out.form,/Cliente A/);assert.match(out.form,/IVA esclusa/);assert(!out.form.includes('name="client_id"'));
 await out.save({amount:'5.60'});assert.equal(calls.length,1);assert.equal(calls[0].route,'rpc/portal_save_manual_carrier_cost');
 const b=calls[0].args.body;assert.equal(b.p_shipment,'s');assert.equal(b.p_amount,5.6);assert.equal(b.p_expected_shipment,s);assert.equal(b.p_charge,null);assert.equal(s.customer_charge,null);
});
test('Editing sends both snapshots; non-admins and already matched shipments cannot create costs',()=>{
 const {ctx,s,out}=setup();const c={id:'m',shipment_id:'s',manual_provisional:true,transport:5,fuel:0,extras:0};ctx.state.charges=[c];
 ctx.manualCarrierCostForm(s.id);assert.match(out.toast,/già un costo/);
 ctx.manualCarrierCostForm(s.id,c.id);assert.match(out.title,/Modifica/);assert.match(ctx.manualCarrierActions(c),/Sostituisci con fattura/);assert(!ctx.manualCarrierActions(c).includes('matchForm('));
 out.title=null;ctx.state.admin=false;ctx.manualCarrierCostForm(s.id,c.id);assert.equal(out.title,null);
});
test('Replacement only offers unassigned actual invoices and preserves all three expected snapshots',async()=>{
 const {ctx,s,calls,out}=setup(),c={id:'m',shipment_id:'s',manual_provisional:true,reference:'000123',transport:5,fuel:0,extras:0},a={id:'invoice',reference:'000123',invoice_number:'FATTURA BRT',recipient:'Anna',shipped_on:'2026-10-01',transport:5.5,fuel:.2,extras:0};
 ctx.state.charges=[c,a,{...a,id:'internal',nexus_owned:true},{...a,id:'direct',direct_client_id:'a'},{...a,id:'linked',shipment_id:'other'},{...a,id:'othermanual',manual_provisional:true}];
 assert.deepEqual(Array.from(ctx.manualCarrierReplacementCandidates(c),r=>r.id),['invoice']);
 ctx.replaceManualCarrierForm('m');assert.match(out.form,/senza sommarli/);assert.match(out.form,/PDF archiviati/);
 await out.save({actual_charge:'invoice'});assert.equal(calls[0].route,'rpc/portal_replace_manual_carrier_cost');assert.equal(calls[0].args.body.p_expected_manual,c);assert.equal(calls[0].args.body.p_expected_actual,a);assert.equal(calls[0].args.body.p_expected_shipment,s);
});
test('Saving a manual cost removes the row from pending and includes it in the upper ledger',()=>{
 const {ctx,s}=setup();vm.runInContext(html.split('\n').find(l=>l.startsWith('function unmatchedCarrierShipments(')),ctx);
 assert.equal(ctx.unmatchedCarrierShipments([s],[]).length,1);assert.equal(ctx.unmatchedCarrierShipments([s],[{manual_provisional:true,shipment_id:'s'}]).length,0);
 const section=html.split('\n').find(l=>l.startsWith("if(view==='carriers')"));assert(section.includes('Inserisci importo'));assert(section.includes('manualCarrierActions(c)'));assert(section.includes('Manuale · fattura da ricevere'));
});
