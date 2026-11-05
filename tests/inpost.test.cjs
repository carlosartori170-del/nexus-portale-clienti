const test=require('node:test'),assert=require('node:assert/strict'),C=require('../assets/inpost-core.js'),X=require('../assets/vendor/xlsx-0.20.3.min.js'),vm=require('node:vm'),fs=require('node:fs'),path=require('node:path');
const code='800000000000000000000001';
const row=(x={})=>({sheet:'ToDoor',row:2,values:{packcode:code,price:3.95,fuel_surcharge:.2,invoicingMonth:'2026-10',customer_stored_date:'2026-09-29T10:00:00Z',delivery_zip_code:1033,delivery_email:'destinatario@example.test',...x}});
test('InPost adds euro fuel to net transport, preserves full tracking/CAP and distinct invoice month',()=>{
 const r=C.parseRows([row()]);assert.equal(r.errors.length,0);assert.equal(r.total,4.15);assert.equal(r.rows[0].packcode,code);assert.equal(r.rows[0].postcode,'01033');assert.equal(r.rows[0].month,'2026-10');assert.equal(r.rows[0].shipped_on,'2026-09-29');
});
test('Reject rounded numeric tracking, duplicate codes, invalid dates, prices and mixed invoice months',()=>{
 for(const bad of [{packcode:Number(code)},{price:-1},{fuel_surcharge:''},{customer_stored_date:'2026-02-31'},{invoicingMonth:'ott-26'}])assert.equal(C.parseRows([row(bad)]).errors.length,1);
 assert.equal(C.parseRows([row(),row()]).errors.length,1);assert.equal(C.parseRows([row(),row({packcode:code+'2',invoicingMonth:'2026-11'})]).errors.length,1);
});
function fixture(){
 const data=row().values,heads=Object.keys(data),w=X.utils.book_new();X.utils.book_append_sheet(w,X.utils.aoa_to_sheet([heads,heads.map(h=>data[h])]),'ToDoor');
 return X.write(w,{type:'buffer',bookType:'xlsx',bookSST:true,compression:true});
}
test('Reads genuine XLSX; recovers incomplete ZIP footer while explicitly marking the recovery',()=>{
 const bytes=fixture(),r=C.readExcel(bytes,X);assert.equal(r.rows[0].packcode,code);assert.equal(r.recovered,false);
 const recovered=C.readExcel(bytes.subarray(0,bytes.length-40),X);assert.equal(recovered.rows.length,1);assert.equal(recovered.rows[0].packcode,code);assert.equal(recovered.total,4.15);assert.equal(recovered.recovered,true);
 assert.throws(()=>C.readExcel(bytes.subarray(0,60),X));
});
test('Track matching is unique; imported costs and conflicting reimports are reported',()=>{
 const rows=C.parseRows([row()]).rows,s={id:'s1',tracking:code};
 assert.equal(C.plan(rows,[s],[])[0].shipment_id,'s1');assert.equal(C.plan(rows,[s,{...s,id:'s2'}],[])[0].shipment_id,null);
 assert.equal(C.plan(rows,[s],[{shipment_id:'s1'}])[0].shipment_id,null);
 const old={invoice_number:'INPOST 123',carrier_code:code,month:'2026-10-01',transport:3.95,fuel:.2,extras:0};
 assert.equal(C.plan(rows,[],[old])[0].skip,true);assert.equal(C.plan(rows,[],[{...old,transport:99}])[0].conflict,true);
});
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
function saveContext(costs=[]){
 const parsed=C.parseRows([row()]),plan=C.plan(parsed.rows,[],costs),out={};
 const ctx={state:{admin:true,shipments:[],clients:[{id:'direct',name:'Cliente'}]},all:async t=>t==='portal_shipments'?[]:costs,money:n=>n.toFixed(2),api:async(t,v)=>{out.table=t;out.payload=v.body;return v.body},spEligible:()=>true};
 vm.createContext(ctx);vm.runInContext(html.slice(html.indexOf('async function inpostSave('),html.indexOf('const inpostOriginalRender=')),ctx);
 return{ctx,parsed,plan,out};
}
test('Save direct-client or Nexus destinations atomically; no fabricated Deagor linkage or VAT scorporo',async()=>{
 const {ctx,parsed,plan,out}=saveContext();await ctx.inpostSave(parsed,plan,{invoice:'123',expected_total:'4.15',destination_0:'direct:direct'});
 assert.equal(out.table,'portal_carrier_charges');assert.equal(out.payload[0].direct_client_id,'direct');assert.equal(out.payload[0].shipment_id,null);assert.equal(out.payload[0].transport,3.95);assert.equal(out.payload[0].fuel,.2);assert.equal(out.payload[0].month,'2026-10-01');
 const n=saveContext();await n.ctx.inpostSave(n.parsed,n.plan,{invoice:'124',expected_total:'4.15',destination_0:'nexus'});assert.equal(n.out.payload[0].nexus_owned,true);assert.equal(n.out.payload[0].direct_client_id,null);
});
test('Save blocks unmatched invoice totals, unconfirmed recovery, invalid destinations and duplicates',async()=>{
 const s=saveContext();
 await assert.rejects(s.ctx.inpostSave(s.parsed,s.plan,{invoice:'123',expected_total:'3.95'}),/non coincide/);assert.equal(s.out.payload,undefined);
 await assert.rejects(s.ctx.inpostSave({...s.parsed,recovered:true},s.plan,{invoice:'123',expected_total:'4.15'}),/recuperato/);
 await assert.rejects(s.ctx.inpostSave(s.parsed,s.plan,{invoice:'123',expected_total:'4.15',destination_0:'direct:unknown'}),/Cliente diretto/);
});
