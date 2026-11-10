const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
function setup(){
 const clients=[{id:'japan',name:'Japan Store',billing_rules:[{basis:'billable_shipments',mode:'unit'}]},{id:'storage',name:'Spazio',billing_rules:[{basis:'billable_m3',mode:'unit'}]},{id:'fixed',name:'Spazio fisso',billing_rules:[{basis:'billable_m3',mode:'fixed'}]},{id:'stock',name:'Stock',billing_rules:[{basis:'stock_pieces',mode:'unit'}]}];
 const out={},ctx={state:{client:'all',month:'2026-10',clients,months:[],shipments:[],charges:[],storageDays:clients.map(c=>({client_id:c.id,observed_on:'2026-10-01'}))},visibleClients:()=>clients,rulesFor:c=>c.billing_rules,inMonth:d=>d?.slice(0,7)==='2026-10',downloadCSV:(name,rows)=>{out.rows=rows},clientName:x=>x};
 vm.createContext(ctx);vm.runInContext("const SECTIONS={shipments:'Spedizioni',storage:'Spazio'}; const BILLING_SECTION_FIELDS={shipments:['billable_shipments'],storage:['billable_m3','stock_pieces']};",ctx);
 vm.runInContext(html.slice(html.indexOf('function billingRequirements('),html.indexOf('function billingValidationCurrent(')),ctx);
 for(const n of ['storageClients','storageRows','exportStorage'])vm.runInContext(html.split('\n').find(l=>l.startsWith('function '+n+'(')),ctx);
 return {ctx,clients,out};
}
test('A shipment-only customer is absent from storage summary, daily rows and export even if inventory data exists',()=>{
 const {ctx,out}=setup();assert.deepEqual(Array.from(ctx.storageClients(),c=>c.id),['storage','fixed','stock']);assert(!ctx.storageRows().some(r=>r.client_id==='japan'));ctx.exportStorage();assert(!out.rows.slice(1).some(r=>r[1]==='japan'));
 ctx.state.client='japan';assert.equal(ctx.storageClients().length,0);assert.equal(ctx.storageRows().length,0);assert.equal(ctx.state.storageDays.length,4);
});
test('Monthly tariff snapshots preserve historical applicability without resurrecting a removed storage line',()=>{
 const {ctx,clients}=setup();ctx.state.months=[{client_id:'japan',month:'2026-10-01',workflow_managed:true,invoice_lines:[{basis:'billable_m3',mode:'unit'}]},{client_id:'storage',month:'2026-10-01',workflow_managed:true,invoice_lines:[{basis:'billable_shipments',mode:'unit'}]}];
 assert(ctx.storageClients().some(c=>c.id==='japan'));assert(!ctx.storageClients().some(c=>c.id==='storage'));assert.equal(clients[0].billing_rules.length,1);
});
test('Fixed/included storage can be viewed without asking for a quantity validation; stock billing retains its required section',()=>{
 const {ctx,clients}=setup();clients[2].billing_rules[0].mode='included';assert(ctx.storageClients().some(c=>c.id==='fixed'));assert(!ctx.billingRequirements(clients[2]).sections.includes('storage'));assert(ctx.billingRequirements(clients[3]).sections.includes('storage'));
 assert(html.includes('Convalida non richiesta'));
});
