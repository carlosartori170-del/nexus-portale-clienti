const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
function setup(admin=true){
 const out={calls:[],cleanup:[]},d={id:'doc',client_id:'c',invoice_number:'TEST',issue_date:'2099-01-01',object_path:'c/doc.pdf',snapshot:{month:'2099-01-01'},created_at:'2099-01-01'};
 const ctx={state:{admin,invoiceDocuments:[d],view:'billing'},JSON,clientName:()=>'<Cliente>',date:String,esc:s=>String(s).replaceAll('<','&lt;'),money:String,num:String,monthName:String,selected:()=>true,table:(_,rows)=>rows.flat().join(' '),showForm:(title,form,save)=>Object.assign(out,{title,form,save}),$:()=>({}),toast:t=>{out.toast=t},api:async(route,args)=>{out.calls.push({route,args});return d.object_path},storageRequest:async(...args)=>{out.cleanup.push(args)}};
 vm.createContext(ctx);for(const n of ['deleteInvoicePDFForm','documentsTable'])vm.runInContext(html.split('\n').find(l=>l.startsWith('function '+n+'(')),ctx);return {ctx,out,d};
}
test('Delete is admin-only in billing/history tables and requires explicit confirmation',async()=>{
 const {ctx,out}=setup(false);assert(!ctx.documentsTable().includes('>Elimina<'));ctx.deleteInvoicePDFForm('doc');assert.equal(out.form,undefined);
 ctx.state.admin=true;assert(ctx.documentsTable().includes('>Elimina<'));ctx.deleteInvoicePDFForm('doc');assert.match(out.form,/checkbox.*required/);assert.match(out.form,/&lt;Cliente>/);assert.match(out.form,/non annulla una fattura/);await assert.rejects(()=>out.save({}),/Conferma/);assert.equal(out.calls.length,0);
});
test('Deletion sends an immutable snapshot, removes one Storage file and leaves other documents',async()=>{
 const {ctx,out,d}=setup();ctx.state.invoiceDocuments.push({id:'other'});ctx.deleteInvoicePDFForm('doc');const before=JSON.stringify(d);await out.save({confirm_delete:'on'});
 assert.equal(out.calls[0].route,'rpc/portal_delete_invoice_document');assert.equal(JSON.stringify(out.calls[0].args.body.p_expected),before);assert.deepEqual(JSON.parse(JSON.stringify(out.cleanup)),[['object/client-invoices','DELETE',{prefixes:['c/doc.pdf']}]]);assert.equal(ctx.state.invoiceDocuments.length,1);assert.equal(ctx.state.invoiceDocuments[0].id,'other');assert.equal(JSON.stringify(d),before);
});
test('RPC failure never deletes a file; Storage failure permits retry without repeating database deletion',async()=>{
 const {ctx,out}=setup();ctx.api=async()=>{throw Error('Documento modificato')};ctx.deleteInvoicePDFForm('doc');await assert.rejects(()=>out.save({confirm_delete:'on'}),/modificato/);assert.equal(out.cleanup.length,0);assert.equal(ctx.state.invoiceDocuments.length,1);
 ctx.api=async()=>{out.calls.push('rpc');return 'c/doc.pdf'};let attempts=0;ctx.storageRequest=async()=>{if(++attempts===1)throw Error('rete')};ctx.deleteInvoicePDFForm('doc');await assert.rejects(()=>out.save({confirm_delete:'on'}),/pulizia del file non completata/);await out.save({confirm_delete:'on'});assert.equal(out.calls.length,1);assert.equal(attempts,2);assert.equal(ctx.state.invoiceDocuments.length,0);
});
