const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const source=html.slice(html.indexOf('const carrierTableFilters='),html.indexOf("function head(title,desc"));
const orders=[{id:'s1',client_id:'optic',code:'D001',order_number:'ORD-A',recipient:'Giovanni D’Amico',shipped_on:'2026-10-03',customer_charge:8},{id:'s2',client_id:'norelux',code:'D002',recipient:'Èrika Rossi',shipped_on:'2026-10-01',customer_charge:null}];
const costs=[{id:'c1',shipment_id:'s1',recipient:'Giovanni D’AMICO',shipped_on:'2026-10-03',invoice_number:'626942',reference:'99325',transport:4.4,fuel:.396,extras:0},{id:'c2',shipment_id:'s2',recipient:'Èrika Rossi',shipped_on:'2026-10-01',invoice_number:'SP',transport:8,fuel:0,extras:1},{id:'c3',shipment_id:null,recipient:'Altra persona',shipped_on:'2026-10-02',transport:5,fuel:0,extras:0}];
function setup(){const out={};const ctx={state:{shipments:orders,clients:[{id:'optic',name:'Optic'},{id:'norelux',name:'Norelux'}],client:'all',month:'2026-10'},shipments:()=>orders,charges:()=>costs,render:()=>{out.rendered=true},toast:x=>{out.error=x},clientName:x=>x,downloadCSV:(name,rows)=>{out.csv=rows},esc:x=>String(x??''),money:x=>x.toFixed(2),document:{getElementById:()=>null}};vm.createContext(ctx);vm.runInContext(fs.readFileSync(path.join(__dirname,'../assets/client-period.js'),'utf8'),ctx);vm.runInContext(source,ctx);return{ctx,out}};
const ids=rows=>Array.from(rows,r=>r.id);
test('Date sorting works both ways, is stable and does not mutate underlying billing data',()=>{
 const {ctx}=setup(),original=JSON.stringify(costs);
 assert.deepEqual(ids(ctx.filterCarrierRows(costs,orders,'costs',{})),['c1','c3','c2']);
 assert.deepEqual(ids(ctx.filterCarrierRows(costs,orders,'costs',{sort:'date_asc'})),['c2','c3','c1']);assert.equal(JSON.stringify(costs),original);
});
test('Client/unassigned, recipient accents and inclusive date boundaries combine correctly',()=>{
 const {ctx}=setup(),filter=f=>ctx.filterCarrierRows(costs,orders,'costs',f);
 assert.deepEqual(ids(filter({client:'norelux',recipient:'erika',from:'2026-10-01',to:'2026-10-01'})),['c2']);
 assert.deepEqual(ids(filter({client:'unassigned'})),['c3']);
 assert.deepEqual(ids(filter({client:'optic',recipient:'erika'})),[]);
});
test('Tariff component/amount range and code/order search use their correct values',()=>{
 const {ctx}=setup(),filter=f=>ctx.filterCarrierRows(costs,orders,'costs',f);
 assert.deepEqual(ids(filter({amountKey:'transport',min:'4.4',max:'4.4'})),['c1']);
 assert.deepEqual(ids(filter({amountKey:'fuel',min:'0.396',max:'0.396'})),['c1']);
 assert.deepEqual(ids(filter({min:'5',max:'5'})),['c3']);
 assert.deepEqual(ids(filter({search:'ord-a'})),['c1']);assert.deepEqual(ids(filter({search:'626942'})),['c1']);
});
test('Customer amount filters exclude missing charges even with a zero minimum',()=>{
 const {ctx}=setup();assert.deepEqual(ids(ctx.filterCarrierRows(orders,orders,'customer',{min:'0'})),['s1']);assert.equal(ctx.carrierAmount(orders[1],'customer'),null);
});
test('Filtered customer CSV preserves displayed order; resetting one table preserves the other',()=>{
 const {ctx,out}=setup();vm.runInContext("carrierTableFilters.customer={recipient:'erika',sort:'date_asc'};carrierTableFilters.costs={client:'optic'}",ctx);
 ctx.exportCarrierCustomer();assert.equal(out.csv.length,2);assert.equal(out.csv[1][2],'D002');
 ctx.resetCarrierFilters('costs');assert.equal(out.rendered,true);ctx.exportCarrierCustomer();assert.equal(out.csv.length,2);
 const form={reportValidity:()=>true};ctx.document.getElementById=()=>form;ctx.FormData=class{constructor(){return new Map([['from','2026-10-03'],['to','2026-10-01'],['min',''],['max','']])}};
 ctx.applyCarrierFilters({preventDefault(){}},'costs');assert.match(out.error,/data iniziale/);
});
test('Admin cost CSV uses filtered rows and header exposes date sorting in both tables',()=>{
 const {ctx,out}=setup();ctx.state.admin=true;ctx.state.view='carriers';
 vm.runInContext("carrierTableFilters.costs={recipient:'erika'}",ctx);
 const exporter=html.split('\n').find(l=>l.startsWith('function exportData(){'));vm.runInContext(exporter,ctx);ctx.exportData();assert.equal(out.csv.length,2);assert.equal(out.csv[1][4],'Èrika Rossi');
 assert.match(ctx.carrierDateHeader('costs'),/sortCarrierDate/);assert.match(ctx.carrierFilterBar('costs'),/Importo minimo/);assert.match(ctx.carrierFilterBar('customer'),/Data spedizione dal/);
});

test('Matching status combines with dates, clients and CSV; reset restores all rows',()=>{
 const {ctx,out}=setup();
 assert.deepEqual(ids(ctx.filterCarrierRows(costs,orders,'costs',{matchStatus:'unmatched'})),['c3']);
 assert.deepEqual(ids(ctx.filterCarrierRows(costs,orders,'costs',{matchStatus:'matched',sort:'date_asc'})),['c2','c1']);
 assert.deepEqual(ids(ctx.filterCarrierRows(costs,orders,'costs',{matchStatus:'unmatched',client:'optic'})),[]);
 assert.deepEqual(ids(ctx.filterCarrierRows(costs,orders,'costs',{matchStatus:'unmatched',from:'2026-10-02',to:'2026-10-02'})),['c3']);
 vm.runInContext("carrierTableFilters.costs={matchStatus:'unmatched'}",ctx);
 ctx.state.admin=true;ctx.state.view='carriers';vm.runInContext(html.split('\n').find(l=>l.startsWith('function exportData(){')),ctx);
 ctx.exportData();assert.equal(out.csv.length,2);assert.equal(out.csv[1][4],'Altra persona');
 ctx.resetCarrierFilters('costs');ctx.exportData();assert.equal(out.csv.length,4);
 assert.match(ctx.carrierFilterBar('costs'),/Da abbinare/);assert(!ctx.carrierFilterBar('customer').includes('Stato abbinamento'));
});

