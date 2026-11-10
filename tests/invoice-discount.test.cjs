const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8'),source=fs.readFileSync(path.join(__dirname,'../assets/invoice-discount.js'),'utf8');
function setup(){
 const out={},m={client_id:'c',month:'2026-10-01',workflow_managed:true,released:true,minimum_logistics:100,vat_rate:22,invoice_lines:[{basis:'billable_shipments',category:'logistics',mode:'fixed',quantity:1,rate:100,amount:100},{basis:'carrier_total',category:'carriers',mode:'fixed',quantity:1,rate:40,amount:40}]};
 const ctx={state:{admin:true,month:'2026-10',clients:[{id:'c',name:'Cliente',minimum_logistics:100,vat_rate:22}],months:[m],invoiceDiscounts:[]},inMonth:x=>x.slice(0,7)==='2026-10',esc:String,monthName:String,money:n=>Number(n).toLocaleString('it-IT',{minimumFractionDigits:2,maximumFractionDigits:2})+' €',num:String,billingAllValid:()=>true,field:(n,l,v)=>l+' value='+v,multiline:(n,l,v)=>l+' '+v,showForm:(title,form,save)=>Object.assign(out,{title,form,save}),toast:t=>{out.toast=t},api:async(route,args)=>{out.call={route,args}}};
 vm.createContext(ctx);vm.runInContext(source,ctx);for(const n of ['sumComplete','sumConfigured','monthlyLines','taxTotals','invoiceBreakdown'])vm.runInContext(html.split('\n').find(l=>l.startsWith('function '+n+'(')),ctx);return {ctx,m,out};
}
test('Discount inputs accept zero and Italian decimals, reject negatives and excess precision',()=>{
 const {ctx}=setup();assert.equal(ctx.invoiceDiscountAmount('15,50'),15.5);assert.equal(ctx.invoiceDiscountAmount('0'),0);for(const v of ['',null,'-1','1.001','NaN','1e2'])assert.throws(()=>ctx.invoiceDiscountAmount(v));
});
test('A negative invoice line reduces taxable amount, VAT and total after the logistics minimum',()=>{
 const {ctx,m}=setup();m.invoice_lines.push({basis:'invoice_discount',category:'discount',quantity:1,rate:-15,amount:-15,note:'Sconto test'});const before=JSON.stringify(m);const t=ctx.taxTotals(m);assert.equal(t.net,125);assert.equal(t.vat,27.5);assert.equal(t.total,152.5);assert.match(ctx.invoiceBreakdown(m),/Sconto concordato/);assert.match(ctx.invoiceBreakdown(m),/-15,00/);assert.equal(JSON.stringify(m),before);
});
test('Discount save is month-specific and guarded by both expected lines and existing discount',async()=>{
 const {ctx,m,out}=setup();const d={client_id:'c',month:'2026-10-01',amount:10,description:'Precedente',updated_at:'test'};ctx.state.invoiceDiscounts=[d];ctx.invoiceDiscountForm('c');assert.match(out.form,/IVA esclusa/);assert.match(out.form,/PDF già archiviati/);await out.save({discount_amount:'15',discount_description:'  Accordo test  '});assert.equal(out.call.route,'rpc/portal_set_invoice_discount');const b=out.call.args.body;assert.equal(b.p_amount,15);assert.equal(b.p_description,'Accordo test');assert.equal(b.p_month,'2026-10-01');assert.equal(b.p_expected_lines,m.invoice_lines);assert.equal(b.p_expected_discount,d);
});
test('Oversized discounts never save; zero removes the effect; invalid convalidations block the form',async()=>{
 const {ctx,out}=setup();ctx.invoiceDiscountForm('c');await assert.rejects(()=>out.save({discount_amount:'141'}),/superare/);assert.equal(out.call,undefined);await out.save({discount_amount:'0'});assert.equal(out.call.args.body.p_amount,0);out.form=null;ctx.billingAllValid=()=>false;ctx.invoiceDiscountForm('c');assert.equal(out.form,null);assert.match(out.toast,/Convalida/);
});
test('PDF renderer draws the discount label, reason, negative amount and recalculated totals',async()=>{
 const {ctx}=setup(),drawn=[],pages=[],font={encodeText:s=>s,widthOfTextAtSize:s=>String(s).length*4};
 const doc={addPage:()=>{const p={drawText:t=>drawn.push(t),drawImage(){},drawLine(){},drawRectangle(){}};pages.push(p);return p},getPages:()=>pages,embedJpg:async()=>({}),embedPng:async()=>({}),embedFont:async()=>font,setTitle(){},setAuthor(){},setSubject(){},save:async()=>new Uint8Array([1])};
 Object.assign(ctx,{pdfLibrary:async()=>({PDFDocument:{create:async()=>doc},StandardFonts:{Helvetica:'regular',HelveticaBold:'bold'},rgb:()=>({})}),letterheadAssets:async()=>({header:'',footer:''}),date:String,invoiceQuantity:r=>String(r.quantity),kitDescription:()=>'',monthName:String});
 vm.runInContext(html.slice(html.indexOf('async function createInvoicePDF('),html.indexOf('function monthlyTransports(')),ctx);
 await ctx.createInvoicePDF({issuer:{legal_name:'Nexus test'},customer:{legal_name:'Cliente test'},invoice_number:'TEST',issue_date:'2026-10-31',due_date:'2026-11-30',month:'2026-10-01',client_name:'Cliente test',lines:[{label:'Sconto concordato',basis:'invoice_discount',quantity:1,rate:-15,amount:-15,note:'Accordo commerciale test'}],net_amount:125,vat_rate:22,vat_amount:27.5,total_amount:152.5},true);
 assert(drawn.includes('Sconto concordato'));assert(drawn.includes('Accordo commerciale test'));assert(drawn.some(t=>t.includes('-15,00')));assert(drawn.some(t=>t.includes('125,00')));assert(drawn.some(t=>t.includes('27,50')));assert(drawn.some(t=>t.includes('152,50')));
});
