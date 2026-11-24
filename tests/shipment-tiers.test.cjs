const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const js=fs.readFileSync(path.join(__dirname,'../assets/shipment-tiers.js'),'utf8'),html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
function setup(){
 const tiers=[{min:0,max:100,rate:100},{min:101,max:150,rate:200},{min:151,max:200,rate:300},{min:201,max:250,rate:400}],rule={label:'Preparazione',mode:'tiered',basis:'billable_shipments',category:'logistics',tiers,rate:null,quantity:1,amount:null},c={id:'c',name:'Cliente test',billing_daily_shipments:true,billing_rules:[rule]},m={client_id:'c',month:'2099-10-01',workflow_managed:true,released:false,invoice_lines:[rule],validation_versions:{shipments:'version-1'}},v={payload:{billable_shipments:101,signature:'daily-v1'}},out={},ctx={state:{admin:true,month:'2099-10',client:'c',clients:[c],months:[m],dailyDispatches:[{client_id:'c',shipped_on:'2099-10-20',shipment_count:101},{client_id:'c',shipped_on:'2099-09-20',shipment_count:50},{client_id:'other',shipped_on:'2099-10-20',shipment_count:99}]},money:n=>n==null?'—':Number(n).toFixed(2)+' €',num:String,esc:String,monthName:String,inMonth:d=>d.slice(0,7)==='2099-10',clientVisibleInMonth:()=>true,rulesFor:c=>c.billing_rules,billingValidationCurrent:()=>v,profilePage:()=>'<p>Profilo</p>',field:(n,l,v)=>`<label>${l}</label><input name="${n}" value="${v??''}">`,multiline:()=>'',showForm:(title,form,save)=>Object.assign(out,{title,form,save}),toast:t=>{out.toast=t},api:async(route,args)=>Object.assign(out,{route,args}),table:(h,r)=>h.join('|')+r.flat().join('|')};vm.createContext(ctx);vm.runInContext(js,ctx);return {ctx,c,m,rule,tiers,v,out};
}
test('Inclusive tier boundaries, zero and overflow match exactly one band',()=>{
 const {ctx,tiers}=setup();for(const [q,i] of [[0,0],[100,0],[101,1],[150,1],[151,2],[200,2],[201,3],[250,3],[251,-1],[-1,-1],[1.5,-1]])assert.equal(ctx.shipmentTierMatch(tiers,q),i);
});
test('Tier configuration rejects holes, overlaps, missing zero, invalid quantities and excess price precision',()=>{
 const {ctx}=setup();assert.equal(ctx.shipmentTierValidate([{min:'0',max:'100',rate:'12,50'}])[0].rate,12.5);for(const rows of [[],[{min:1,max:100,rate:10}],[{min:0,max:100,rate:10},{min:100,max:150,rate:20}],[{min:0,max:100,rate:'1.001'}],[{min:0,max:1.5,rate:1}]])assert.throws(()=>ctx.shipmentTierValidate(rows));
});
test('Shipment totals include linked stock outgoing rows in their shipping month and only the selected client',()=>{
 const {ctx,c}=setup();ctx.state.dailyDispatches.push({client_id:'c',shipped_on:'2099-10-21',shipment_count:2,stock_source_id:'receipt'});assert.equal(ctx.shipmentTierCount(c),103);
});
test('Tier choice uses validated counts, explicit confirmation and immutable monthly snapshots',async()=>{
 const {ctx,c,m,out}=setup();ctx.shipmentTierSelectionForm(c.id,0);assert.match(out.form,/101 spedizioni effettive/);assert.match(out.form,/quantità fatturata 1/);await assert.rejects(()=>out.save({tier_index:'1'}),/Conferma/);await assert.rejects(()=>out.save({tier_index:'0',checked:'on'}),/non comprende/);const expected=JSON.stringify(m.invoice_lines);await out.save({tier_index:'1',checked:'on'});assert.equal(out.route,'rpc/portal_select_shipment_tier');assert.equal(out.args.body.p_tier_index,1);assert.equal(out.args.body.p_month,'2099-10-01');assert.equal(JSON.stringify(out.args.body.p_expected_lines),expected);assert.equal(out.args.body.p_expected_versions.shipments,'version-1');assert.equal(JSON.stringify(m.invoice_lines),expected);
});
test('Pending or stale choices block final confirmation, while a current selected tier is ready',()=>{
 const {ctx,c,m,rule,v}=setup();assert(ctx.shipmentTierNeedsSelection(m,c));rule.rate=200;rule.amount=200;rule.selected_tier={index:1,shipments:101,signature:v.payload.signature};assert(!ctx.shipmentTierNeedsSelection(m,c));v.payload.signature='changed';assert(ctx.shipmentTierNeedsSelection(m,c));assert.match(html,/shipmentTierNeedsSelection\(m,c\)/);
});
test('Old confirmed months keep previous tariffs; old drafts offer an explicit refresh without assigning a fee',()=>{
 const {ctx,c,m,out}=setup();m.invoice_lines=[{mode:'unit',basis:'billable_shipments',rate:2,amount:202}];m.released=true;assert.equal(ctx.shipmentTierBillingPanel(c,m),'');m.released=false;assert.match(ctx.shipmentTierBillingPanel(c,m),/Usa tariffe attuali/);ctx.state.dailyDispatches[0].shipment_count=251;m.invoice_lines=c.billing_rules;assert.match(ctx.shipmentTierBillingPanel(c,m),/Nessuno scaglione previsto/);ctx.shipmentTierSelectionForm(c.id,0);assert.match(out.toast,/Nessuno scaglione/);assert.equal(out.form,undefined);
});
test('Configurable plan saves future tariff JSON through a guarded RPC and requires consent',async()=>{
 const {ctx,c,out}=setup();ctx.shipmentTierPlanForm(c.id);const values={label:'Preparazione',tier_min_0:'0',tier_max_0:'100',tier_rate_0:'100',tier_min_1:'101',tier_max_1:'150',tier_rate_1:'200',note:'Condizioni',checked:'on'};await out.save(values);assert.equal(out.route,'rpc/portal_set_shipment_tier_plan');assert.equal(out.args.body.p_tiers.length,2);assert.equal(out.args.body.p_tiers[1].rate,200);assert.equal(out.args.body.p_expected_rules[0].mode,'tiered');await assert.rejects(()=>out.save({...values,checked:''}),/Conferma/);
});
test('Client-side previews never calculate tier prices automatically or multiply a fixed canone',()=>{
 const {ctx,rule}=setup();ctx.billingQuantity=()=>101;vm.runInContext(html.split('\n').find(l=>l.startsWith('function calculatedLines(')),ctx);const preview=ctx.calculatedLines([rule],{billable_shipments:101})[0];assert.equal(preview.quantity,1);assert.equal(preview.amount,null);assert.equal(preview.rate,null);
});
test('Actual billing page renders the tier selector and enables final confirmation only after a current choice',()=>{
 const {ctx,c,m,rule,v}=setup();Object.assign(ctx,{activeClients:()=>[c],head:(a,b,actions)=>a+b+actions,badge:()=>'',billingRequirements:()=>({sections:['shipments'],source:'manual'}),billingSectionSummary:()=> '101 spedizioni',SECTIONS:{shipments:'Spedizioni'},RATE_CATEGORIES:{logistics:'Logistica'},storageInvoiceNeedsRecalculation:()=>false,monthlyLines:()=>m.invoice_lines,invoiceDiscountSetting:()=>null,invoiceQuantityWithUnit:r=>String(r.quantity),kitDescription:()=> '—',invoiceBreakdown:()=>'',invoiceTaxSummary:()=>''});
 vm.runInContext(html.slice(html.indexOf('function billingPage(){'),html.indexOf('async function buildInvoice(')),ctx);
 let rendered=ctx.billingPage();assert.match(rendered,/Scegli e applica scaglione/);assert.match(rendered,/<button disabled onclick="confirmInvoice/);
 Object.assign(rule,{rate:200,amount:200,selected_tier:{index:1,shipments:101,signature:v.payload.signature}});rendered=ctx.billingPage();assert.match(rendered,/Scaglione confermato/);assert.match(rendered,/<button  onclick="confirmInvoice/);
});
