const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8'),ctx={};vm.createContext(ctx);
for(const name of ['billingQuantity','calculatedLines','monthlyLines','storageInvoiceNeedsRecalculation'])vm.runInContext(html.split('\n').find(l=>l.startsWith('function '+name+'(')),ctx);
ctx.roundedFee=(q,r)=>q==null||r==null?null:Math.round((q*r+Number.EPSILON)*100)/100;ctx.fee=ctx.roundedFee;
const line=(quantity,amount)=>({basis:'billable_m3',mode:'unit',quantity,rate:25,amount});
test('Regression: 0.3042 m3 at 25 EUR bills 0.30 m3 and 7.50 EUR',()=>{
 const m={billable_m3:.3042},r=ctx.calculatedLines([{basis:'billable_m3',mode:'unit',rate:25}],m)[0];assert.equal(r.quantity,.3);assert.equal(r.amount,7.5);assert.equal(m.billable_m3,.3042);
 const legacy=ctx.monthlyLines({...m,storage_rate:25}).find(r=>r.basis==='billable_m3');assert.equal(legacy.quantity,.3);assert.equal(legacy.amount,7.5);
});
test('Old snapshots are flagged, never silently recalculated for display',()=>{
 for(const r of [line(.3042,7.61),line(.3,7.61)]){const m={invoice_lines:[r]};assert.equal(ctx.storageInvoiceNeedsRecalculation(m),true);assert.equal(ctx.monthlyLines(m)[0].amount,7.61)}
 assert.equal(ctx.storageInvoiceNeedsRecalculation({invoice_lines:[line(.3,7.5)]}),false);
 assert.equal(ctx.storageInvoiceNeedsRecalculation({invoice_lines:[{...line(.3,0),mode:'included'}]}),false);
 assert.equal(ctx.storageInvoiceNeedsRecalculation({invoice_lines:[{basis:'extra_pieces',quantity:1,rate:.85,amount:.85}]}),false);
});
