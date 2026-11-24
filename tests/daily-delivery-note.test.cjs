const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const js=fs.readFileSync(path.join(__dirname,'../assets/daily-stock.js'),'utf8');
function setup(){
 const root={id:'receipt',client_id:'japan',shipped_on:'2099-10-20',received_on:'2099-10-10',supplier:'Fornitore',piece_count:10,shipment_count:4,stock_pieces:6,delivery_note:'0007/A <test>',notes:''},out={},ctx={state:{admin:true,month:'2099-11',client:'japan',dailyDispatches:[root],clients:[{id:'japan',billing_daily_shipments:true,billing_quantity_source:'manual'}]},crypto:{randomUUID:()=> 'new-id'},esc:s=>String(s??'').replaceAll('<','&lt;').replaceAll('>','&gt;'),date:String,num:String,clientName:()=> 'Japan Deal Store',localToday:()=> '2099-11-24',head:(a,b,c)=>a+b+c,table:(h,r)=>h.join('|')+r.flat().join('|'),billingValidationCurrent:()=>false,field:(n,l,v,t,a)=>`<label>${l}</label><input name="${n}" value="${v||''}" ${a||''}>`,multiline:()=>'',showForm:(title,form,save)=>Object.assign(out,{form,save}),$:()=>({}),api:async(route,args)=>Object.assign(out,{route,args}),downloadCSV:(name,rows)=>{out.csv=rows},toast:t=>{out.toast=t}};
 ctx.visibleClients=()=>ctx.state.clients;ctx.selected=r=>r.client_id==='japan';ctx.inMonth=d=>d.slice(0,7)===ctx.state.month;vm.createContext(ctx);vm.runInContext(js,ctx);return {ctx,root,out};
}
test('Receipt form saves an alphanumeric delivery note with leading zeros and validates its length',async()=>{
 const {ctx,root,out}=setup();ctx.state.month='2099-10';ctx.dailyDispatchForm(root.id);assert.match(out.form,/Numero bolla della consegna/);assert.match(out.form,/name="delivery_note"/);
 const v={client_id:'japan',shipped_on:root.shipped_on,received_on:root.received_on,supplier:root.supplier,piece_count:'10',shipment_count:'4',stock_pieces:'6',delivery_note:'  0007/A  ',notes:''};await out.save(v);assert.equal(out.args.body.p_values.delivery_note,'0007/A');await assert.rejects(()=>out.save({...v,delivery_note:'A'.repeat(101)}),/100 caratteri/);
});
test('Stock selection, outgoing notes, table and CSV share the receipt delivery note safely',()=>{
 const {ctx,root,out}=setup();ctx.dispatchFromStockForm();assert.match(out.form,/0007\/A &lt;test&gt;/);
 const child={...root,id:'outgoing',stock_source_id:root.id,delivery_note:'',stock_pieces:0,piece_count:1,shipment_count:1,shipped_on:'2099-11-02'};ctx.state.dailyDispatches.push(child);
 assert.match(ctx.dailyOriginNote(child),/bolla 0007\/A <test>/);assert.match(ctx.dailyShipmentsPage(),/Numero bolla/);assert.match(ctx.dailyShipmentsPage(),/0007\/A &lt;test&gt;/);
 ctx.exportDailyDispatches();assert.equal(out.csv[1][out.csv[0].indexOf('Numero bolla')],root.delivery_note);
 ctx.dailyDispatchForm(child.id);assert.match(out.form,/name="delivery_note_display".*disabled/);root.delivery_note='0008/B';assert.equal(ctx.dailyDeliveryNote(child),'0008/B');assert.match(ctx.dailyOriginNote(child),/bolla 0008\/B/);
});
test('Existing receipts without a delivery note remain readable and do not invent an origin number',()=>{
 const {ctx,root}=setup();delete root.delivery_note;assert.equal(ctx.dailyDeliveryNote(root),'');assert(!ctx.dailyOriginNote({...root,stock_source_id:root.id}).includes(' · bolla '));
});
