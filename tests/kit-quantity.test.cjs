const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8'),ctx={};vm.createContext(ctx);vm.runInContext(html.split('\n').find(l=>l.startsWith('function billingQuantity(')),ctx);
const q=(pieces,orders,basis='extra_pieces',multiple=4,fixed=1)=>ctx.billingQuantity({shipped_pieces:pieces,billable_shipments:orders},basis,multiple,fixed);
test('One card per order: 1/2/3 glasses are 5/9/13 physical pieces',()=>{
 for(const [pieces,glasses] of [[5,1],[9,2],[13,3]]){assert.equal(q(pieces,1,'shipped_pieces'),glasses);assert.equal(q(pieces,1),glasses-1)}
});
test('Monthly mix: 3 orders with 1,2,3 glasses -> 27 physical pieces -> 3 extra glasses',()=>{assert.equal(q(27,3),3);assert.equal(q(27,3,'shipped_pieces'),6);assert.equal(q(0,0),0)});
test('Legacy kit and unrelated quantities retain original calculation',()=>{
 assert.equal(q(15,2,'extra_pieces',5,0),1);
 assert.equal(ctx.billingQuantity({received_pieces:20},'received_pieces',5),4);
 assert.equal(ctx.billingQuantity({stock_pieces:10},'stock_pieces',5),2);
 assert.equal(ctx.billingQuantity({billable_shipments:7},'billable_shipments',5),7);
 assert.equal(ctx.billingQuantity({billable_m3:1.25},'billable_m3'),1.25);
});
test('Missing required quantities return null; inconsistent or nonintegral kits never round',()=>{
 assert.equal(q(null,1),null);assert.equal(q(9,null),null);assert.equal(q(9,null,'shipped_pieces'),null);
 for(const run of [()=>q(8,1),()=>q(0,1),()=>q(2,2),()=>q(9,1,'extra_pieces',4,-1),()=>q(9,1,'extra_pieces',0,1),()=>q(9,1.5),()=>ctx.billingQuantity({stock_pieces:10,billable_shipments:1},'stock_pieces',4,1)])assert.throws(run);
});
