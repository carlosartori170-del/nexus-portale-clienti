const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8'),ctx={num:v=>v==null?'—':String(v)};vm.createContext(ctx);
for(const name of ['billingQuantity','invoiceQuantity','invoiceQuantityWithUnit','calculatedLines'])vm.runInContext(html.split('\n').find(l=>l.startsWith('function '+name+'(')),ctx);
ctx.roundedFee=(q,r)=>q==null||r==null?null:Math.round((q*r+Number.EPSILON)*100)/100;
test('Storage volume rounds before billing while source measurements stay precise',()=>{
 for(const [raw,expected] of [[1.2344,1.23],[1.235,1.24],[1.005,1.01],[0,0]]){
  const month={billable_m3:raw},line=ctx.calculatedLines([{basis:'billable_m3',mode:'unit',rate:25}],month)[0];
  assert.equal(line.quantity,expected);assert.equal(line.amount,ctx.roundedFee(expected,25));assert.equal(month.billable_m3,raw);
 }
 assert.equal(ctx.billingQuantity({billable_m3:null},'billable_m3'),null);
});
test('Invoice quantity has two decimals and cubic metre unit only for storage',()=>{
 assert.equal(ctx.invoiceQuantityWithUnit({basis:'billable_m3',quantity:1.2345}),'1,23 m³');
 assert.equal(ctx.invoiceQuantityWithUnit({basis:'billable_m3',quantity:1}),'1,00 m³');
 assert.equal(ctx.invoiceQuantityWithUnit({basis:'shipped_pieces',quantity:5}),'5');
 assert.match(html,/r.label\+\(r.basis==='billable_m3'\?' \(m³\)'/);
});
