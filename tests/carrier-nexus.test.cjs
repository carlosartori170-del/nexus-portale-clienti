const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const own={id:'own',nexus_owned:true,shipment_id:null,month:'2026-10-01',reference:'ref',postcode:'00125',shipped_on:'2026-10-05',recipient:'Nexus Srl',transport:5,fuel:0,extras:0};
const open={...own,id:'open',nexus_owned:false},linked={...own,id:'linked',nexus_owned:false,shipment_id:'s1'};
test('Internal Nexus costs stay visible in all costs but leave unmatched and matched filters',()=>{
 const ctx={};vm.createContext(ctx);vm.runInContext(html.slice(html.indexOf('const carrierTableFilters='),html.indexOf('function head(title,desc')),ctx);
 const rows=[own,open,linked],ids=f=>Array.from(ctx.filterCarrierRows(rows,[{id:'s1',client_id:'client'}],'costs',f),r=>r.id);
 assert.deepEqual(ids({matchStatus:'unmatched'}),['open']);assert.deepEqual(ids({matchStatus:'nexus'}),['own']);assert.deepEqual(ids({matchStatus:'matched'}),['linked']);assert.equal(ids({}).length,3);assert.deepEqual(ids({client:'unassigned'}),['open']);
});
test('BRT automatic matching never proposes an internal Nexus row',()=>{
 const ctx={spIsCharge:()=>false,SP_EXCLUDED_CLIENT:'japan'};vm.createContext(ctx);vm.runInContext(html.slice(html.indexOf('function brtAutoPlan('),html.indexOf('async function brtAutoSave(')),ctx);
 assert.equal(ctx.brtAutoPlan([own],[{id:'s1',client_id:'client',reference:'ref',postcode:'00125',shipped_on:'2026-10-05',carrier:'BRT'}],'2026-10').length,0);
});
test('Ownership checkbox disables client assignment and requires explicit removal of existing customer amount',()=>{
 const nodes={carrier_nexus_owned:{checked:true},carrier_assignment:{},carrier_clear_customer:{},carrier_clear_notice:{}};
 const ctx={document:{getElementById:id=>nodes[id]}};vm.createContext(ctx);vm.runInContext(html.slice(html.indexOf('function toggleCarrierOwnership('),html.indexOf('function matchForm(id){')),ctx);
 ctx.toggleCarrierOwnership();assert.equal(nodes.carrier_assignment.disabled,true);assert.equal(nodes.carrier_clear_customer.required,true);assert.equal(nodes.carrier_clear_notice.hidden,false);
 nodes.carrier_nexus_owned.checked=false;ctx.toggleCarrierOwnership();assert.equal(nodes.carrier_assignment.disabled,false);assert.equal(nodes.carrier_clear_customer.required,false);assert.equal(nodes.carrier_clear_notice.hidden,true);
});
test('BRT and Spediamo manual assignments use the same transactional RPC; exports label internal costs',()=>{
 const assignment=html.slice(html.indexOf('function carrierAssignmentForm('),html.indexOf('function toggleCarrierOwnership('));
 assert(assignment.includes("api('rpc/portal_assign_carrier_charge'"));assert(assignment.includes("p_shipment:owned?null:"));assert(html.includes('Nexus · costo interno'));
 assert(html.includes("matchForm=function(id){const c=state.charges.find(c=>c.id===id);return carrierAssignmentForm(id)}"));
});
