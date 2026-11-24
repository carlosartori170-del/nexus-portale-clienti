const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const source=fs.readFileSync(path.join(__dirname,'../assets/daily-stock.js'),'utf8');
function setup(){
 const receipt={id:'source-0001',client_id:'japan',shipped_on:'2099-10-20',received_on:'2099-10-10',supplier:'Fornitore <test>',piece_count:10,shipment_count:4,stock_pieces:6,stock_source_id:null,notes:'Bolla test'},out={calls:[],ids:0,submit:{}},ctx={
  state:{admin:true,month:'2099-11',client:'japan',clients:[{id:'japan',billing_daily_shipments:true,billing_quantity_source:'manual'},{id:'other',billing_daily_shipments:true,billing_quantity_source:'manual'}],dailyDispatches:[receipt]},
  crypto:{randomUUID:()=>`test-${++out.ids}`},localToday:()=> '2099-11-24',esc:s=>String(s??'').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;'),date:s=>s,num:String,clientName:id=>id==='japan'?'Japan Deal Store':'Altro cliente',
  head:(title,subtitle,actions)=>title+' '+subtitle+' '+actions,field:(name,label,value,type,attrs)=>`<label>${label}</label><input name="${name}" value="${value??''}" ${attrs||''}>`,multiline:(name,label,v)=>`<label>${label}</label><textarea name="${name}">${v||''}</textarea>`,table:(headers,rows)=>headers.join('|')+'\n'+rows.map(r=>r.join('|')).join('\n'),billingValidationCurrent:()=>false,
  showForm:(title,form,save)=>Object.assign(out,{title,form,save}),toast:t=>{out.toast=t},$:()=>out.submit,api:async(route,args)=>{out.calls.push({route,args})},downloadCSV:(name,rows)=>Object.assign(out,{csvName:name,csv:rows})
 };
 ctx.visibleClients=()=>ctx.state.clients;ctx.selected=r=>ctx.state.client==='all'||r.client_id===ctx.state.client;ctx.inMonth=d=>d.slice(0,7)===ctx.state.month;
 vm.createContext(ctx);vm.runInContext(source,ctx);return {ctx,out,receipt};
}
test('Legacy rows default to no stock; candidates include all earlier months, scoped by client',()=>{
 const {ctx,receipt}=setup();assert.equal(ctx.dailyStockAvailable({...receipt,stock_pieces:undefined}),0);
 ctx.state.dailyDispatches.push({...receipt,id:'older',shipped_on:'2099-08-01'},{...receipt,id:'other',client_id:'other'},{...receipt,id:'same',shipped_on:'2099-11-01'},{...receipt,id:'future',shipped_on:'2099-12-01'});
 assert.deepEqual(Array.from(ctx.dailyStockSources(),r=>r.id).sort(),['older','source-0001']);
 ctx.state.client='all';assert(ctx.dailyStockSources().some(r=>r.id==='other'));
});
test('Outgoing rows in any month consume the same reserve, without changing original shipment counts',()=>{
 const {ctx,receipt}=setup();ctx.state.dailyDispatches.push({...receipt,id:'out',stock_source_id:receipt.id,stock_pieces:0,shipped_on:'2099-11-05',piece_count:2,shipment_count:1},{...receipt,id:'out2',stock_source_id:receipt.id,stock_pieces:0,shipped_on:'2099-12-01',piece_count:3,shipment_count:2});
 assert.equal(ctx.dailyStockAvailable(receipt),1);assert.equal(ctx.dailyDispatches().reduce((n,r)=>n+r.shipment_count,0),1);ctx.state.month='2099-10';assert.equal(ctx.dailyDispatches().reduce((n,r)=>n+r.shipment_count,0),4);assert.equal(receipt.stock_pieces,6);
 ctx.state.dailyDispatches=ctx.state.dailyDispatches.filter(r=>r.id!=='out2');assert.equal(ctx.dailyStockAvailable(receipt),4);
});
test('New register form includes stock and saves through the guarded RPC with a stable retry id',async()=>{
 const {ctx,out}=setup();ctx.dailyDispatchForm();assert.match(out.form,/Pezzi in giacenza/);
 const values={client_id:'japan',shipped_on:'2099-11-24',received_on:'2099-11-23',supplier:'Test',piece_count:'10',stock_pieces:'2',shipment_count:'4',notes:''};
 await out.save(values);await out.save(values);assert.equal(out.calls[0].route,'rpc/portal_save_daily_dispatch');assert.equal(out.calls[0].args.body.p_values.stock_pieces,2);assert.equal(out.calls[0].args.body.p_expected,null);assert.equal(out.calls[0].args.body.p_id,out.calls[1].args.body.p_id);
 await assert.rejects(()=>out.save({...values,stock_pieces:'11'}),/superare/);await assert.rejects(()=>out.save({...values,stock_pieces:'1.5'}),/intere/);
});
test('Editing a partially used origin displays remaining stock and preserves the consumed snapshot',async()=>{
 const {ctx,out,receipt}=setup();ctx.state.month='2099-10';ctx.state.dailyDispatches.push({...receipt,id:'out',stock_source_id:receipt.id,stock_pieces:0,shipped_on:'2099-11-05',piece_count:4,shipment_count:1});
 ctx.dailyDispatchForm(receipt.id);assert.match(out.form,/name="stock_pieces" value="2"/);assert.match(out.form,/4 pezzi già spediti/);assert.match(out.form,/readonly/);
 await out.save({client_id:'japan',shipped_on:receipt.shipped_on,received_on:receipt.received_on,supplier:receipt.supplier,piece_count:'10',stock_pieces:'1',shipment_count:'4',notes:'Bolla test'});
 const b=out.calls[0].args.body;assert.equal(b.p_values.stock_pieces,1);assert.equal(b.p_expected_used,4);assert.equal(b.p_expected.stock_pieces,6);
 ctx.removeDailyDispatch(receipt.id);assert.match(out.toast,/collegate/);assert(!out.calls.some(c=>c.args.method==='DELETE'));
});
test('Dispatch from stock sends the selected original receipt, quantities and availability with retry protection',async()=>{
 const {ctx,out,receipt}=setup();ctx.dispatchFromStockForm();assert.match(out.form,/Fornitore &lt;test&gt;/);assert.match(out.form,/ricevimento originale/);
 const values={stock_source_id:receipt.id,shipped_on:'2099-11-25',piece_count:'2',shipment_count:'1',notes:'Parziale'};
 await out.save(values);await out.save(values);const b=out.calls[0].args.body;assert.equal(out.calls[0].route,'rpc/portal_dispatch_from_stock');assert.equal(b.p_source,receipt.id);assert.equal(b.p_pieces,2);assert.equal(b.p_shipments,1);assert.equal(b.p_expected_available,6);assert.equal(b.p_expected.supplier,receipt.supplier);assert.equal(b.p_id,out.calls[1].args.body.p_id);
 await assert.rejects(()=>out.save({...values,piece_count:'7'}),/limiti/);await assert.rejects(()=>out.save({...values,shipped_on:'2099-10-25'}),/successivo/);await assert.rejects(()=>out.save({...values,stock_source_id:'other'}),/Seleziona/);
});
test('Linked row notes and CSV retain receipt, supplier and origin even with no optional note',()=>{
 const {ctx,out,receipt}=setup();const child={...receipt,id:'out',stock_source_id:receipt.id,stock_pieces:0,shipped_on:'2099-11-05',piece_count:2,shipment_count:1,notes:''};ctx.state.dailyDispatches.push(child);
 const note=ctx.dailyDispatchNotes(child);assert.match(note,/2099-10-10/);assert.match(note,/Fornitore <test>/);assert.match(note,/#source-0/);
 const html=ctx.dailyShipmentsPage();assert.match(html,/Spedisci da giacenza/);assert.match(html,/Giacenza attuale/);assert.match(html,/Fornitore &lt;test&gt;/);assert(!html.includes('Fornitore <test>'));
 ctx.exportDailyDispatches();assert(out.csv[0].includes('Giacenza attuale (pezzi)'));assert.equal(out.csv[1][out.csv[0].indexOf('Spedizioni effettuate')],1);assert.equal(out.csv[1][out.csv[0].indexOf('Registrazione giacenza originale')],receipt.id);assert.equal(out.csv[1][out.csv[0].indexOf('Note')],note);
});
test('Linked row edits keep origin fields locked and deletion explains stock restoration',async()=>{
 const {ctx,out,receipt}=setup();const child={...receipt,id:'out',stock_source_id:receipt.id,stock_pieces:0,shipped_on:'2099-11-05',piece_count:2,shipment_count:1};ctx.state.dailyDispatches.push(child);ctx.dailyDispatchForm('out');assert.match(out.form,/name="stock_pieces" value="0"/);assert.match(out.form,/Pezzi spediti dalla giacenza/);assert.match(out.form,/ricevimento merce del/);
 await assert.rejects(()=>out.save({client_id:'japan',shipped_on:child.shipped_on,received_on:child.received_on,supplier:child.supplier,piece_count:'0',stock_pieces:'0',shipment_count:'1'}),/limiti/);
 ctx.removeDailyDispatch('out');assert.match(out.form,/torneranno disponibili/);await out.save();assert.equal(out.calls[0].args.method,'DELETE');assert.equal(out.calls[0].args.query,'id=eq.out');
});
test('Stock actions are unavailable for clients and empty stock lists explain what is missing',()=>{
 const {ctx,out}=setup();ctx.state.dailyDispatches=[];ctx.dispatchFromStockForm();assert.match(out.toast,/Nessuna giacenza disponibile/);assert.equal(out.form,undefined);
 ctx.state.admin=false;ctx.dispatchFromStockForm();ctx.dailyDispatchForm();assert.equal(out.form,undefined);assert(!ctx.dailyShipmentsPage().includes('onclick="dispatchFromStockForm()"'));
});
