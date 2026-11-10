const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const source=fs.readFileSync(path.join(__dirname,'../assets/client-period.js'),'utf8'),html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const clients=[{id:'legacy',name:'Legacy'},{id:'period',name:'Periodo',active_from:'2026-03-31',active_until:'2026-09-01'},{id:'future',name:'Futuro',active_from:'2027-01-01'}];
function setup(){const ctx={state:{clients:structuredClone(clients),admin:true,client:'all',month:'2026-10',view:'overview'},date:x=>x,field:(n,l,v)=>l+':'+(v||''),esc:String};vm.createContext(ctx);vm.runInContext(source,ctx);return ctx}
test('Month boundaries are inclusive, with no timezone-dependent day arithmetic',()=>{
 const c=setup(),p=clients[1];for(const month of ['2026-03','2026-09'])assert(c.clientActiveInMonth(p,month));for(const month of ['2026-02','2026-10'])assert(!c.clientActiveInMonth(p,month));
 assert(c.clientActiveInMonth({},'2000-01'));assert(c.clientActiveInMonth({active_from:'2026-03-01'},'2027-01'));assert(c.clientActiveInMonth({active_until:'2026-03-01'},'2000-01'));assert(!c.clientActiveInMonth({},'2026-13'));
});
test('Archive is explicit, includes future/closed profiles, and never affects invoice eligibility',()=>{
 const c=setup();assert.deepEqual(Array.from(c.visibleClients(),r=>r.id),['legacy']);c.state.showInactiveClients=true;assert.equal(c.visibleClients().length,3);assert.equal(c.activeClients().length,1);
 c.state.view='billing';assert.equal(c.visibleClients().length,1);c.state.admin=false;c.state.view='profile';assert.equal(c.visibleClients().length,1);
});
test('Inactive selections and carrier subfilters reset; editing a historical record preserves its client',()=>{
 const c=setup();vm.runInContext("const carrierTableFilters={costs:{client:'period'},pending:{client:'unassigned'}}",c);c.state.client='period';c.ensureClientPeriodSelection();assert.equal(c.state.client,'all');assert.equal(vm.runInContext('carrierTableFilters.costs.client',c),'all');assert.equal(vm.runInContext('carrierTableFilters.pending.client',c),'unassigned');
 assert(c.clientsForSelection('period').some(r=>r.id==='period'));assert.equal(c.state.clients.length,3);
});
test('Invoices, shipments and carrier totals share the period filter; unassigned and Nexus costs remain visible',()=>{
 const c=setup();for(const fn of ['selected','inMonth','shipments','months','charges'])vm.runInContext(html.split('\n').find(l=>l.startsWith('function '+fn+'(')),c);
 c.state.shipments=clients.map(r=>({id:r.id,client_id:r.id,shipped_on:'2026-10-05'}));c.state.months=clients.map(r=>({client_id:r.id,month:'2026-10-01'}));c.state.charges=[{shipment_id:'period',month:'2026-10-01'},{direct_client_id:'future',month:'2026-10-01'},{nexus_owned:true,month:'2026-10-01'},{month:'2026-10-01'}];
 assert.equal(c.shipments().length,1);assert.equal(c.months().length,1);assert.equal(c.charges().length,2);c.state.showInactiveClients=true;assert.equal(c.shipments().length,3);assert.equal(c.charges().length,4);
});
test('Date fields validate and blank legacy dates stay unbounded',()=>{
 const c=setup();assert.equal(JSON.stringify(c.clientPeriodValues({})),JSON.stringify({active_from:null,active_until:null}));assert.throws(()=>c.clientPeriodValues({active_from:'2026-03-01',active_until:'2026-02-28'}));assert.throws(()=>c.clientPeriodValues({active_from:'2026-02-30'}));assert.equal(c.clientPeriodValues({active_from:'2028-02-29'}).active_from,'2028-02-29');assert.match(c.clientPeriodFields({}),/Data fine gestione/);
});
test('Billing page excludes inactive clients even with archive enabled; selected month resets the archive',()=>{
 const c=setup();c.state.showInactiveClients=true;c.state.admin=false;c.state.months=[];Object.assign(c,{head:(t,d)=>t+d,monthName:x=>x,billingRequirements:()=>({sections:[]}),SECTIONS:{}});
 vm.runInContext(html.slice(html.indexOf('function billingPage(){'),html.indexOf('async function buildInvoice(')),c);const rendered=c.billingPage();assert(rendered.includes('Legacy'));assert(!rendered.includes('Futuro'));assert(!rendered.includes('Periodo ·'));
 assert(html.includes('state.month=e.target.value;state.showInactiveClients=false;shell()'));
 assert(html.includes("<p>'+esc(clientPeriodSummary(c))+'</p>"));
});
