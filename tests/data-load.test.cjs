const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
function setup(admin=true,discounts=[{client_id:'client',month:'2026-10-01',amount:15}]){
 const calls=[],out={shell:0,error:''},ctx={state:{},session:{user:{email:'test@example.test'}},location:{hash:''},esc:String,shell:()=>{out.shell++},$:()=>({set innerHTML(v){out.error=v}})};
 ctx.api=async(table,{query=''})=>{calls.push({table,query});const params=new URLSearchParams(query),order=params.get('order');
  const columns=table==='portal_invoice_discounts'?['client_id','month','amount','description','updated_at','updated_by']:table==='portal_admins'?['user_id']:['id'];
  if(order)for(const column of order.split(','))if(!columns.includes(column))throw Error('column '+table+'.'+column+' does not exist');
  const rows=table==='portal_admins'?(admin?[{user_id:'admin'}]:[]):table==='portal_clients'?[{id:'client'}]:table==='portal_invoice_discounts'?discounts:[];
  return rows.slice(Number(params.get('offset')||0),Number(params.get('offset')||0)+Number(params.get('limit')||1000));
 };
 vm.createContext(ctx);for(const name of ['all','load'])vm.runInContext(html.split('\n').find(l=>l.startsWith('async function '+name+'(')),ctx);return {ctx,calls,out};
}
test('Discount pagination uses its composite primary key, including multiple pages',async()=>{
 const rows=Array.from({length:1001},(_,i)=>({client_id:'client-'+String(i).padStart(4,'0'),month:'2026-10-01',amount:1})),{ctx,calls}=setup(true,rows),result=await ctx.all('portal_invoice_discounts');
 assert.equal(result.length,1001);assert.equal(result[1000].client_id,'client-1000');assert.equal(calls.length,2);assert(calls.every(c=>new URLSearchParams(c.query).get('order')==='client_id,month'));
});
test('Complete admin startup reaches the application shell with discount data loaded',async()=>{
 const {ctx,out,calls}=setup();await ctx.load();assert.equal(out.shell,1);assert.equal(out.error,'');assert.equal(ctx.state.invoiceDiscounts.length,1);assert(calls.some(c=>c.table==='portal_invoice_documents'));assert(calls.some(c=>c.table==='portal_invoice_issuer'));
});
test('Client startup never requests the admin-only discount settings',async()=>{
 const {ctx,out,calls}=setup(false);await ctx.load();assert.equal(out.shell,1);assert.equal(out.error,'');assert.equal(ctx.state.invoiceDiscounts.length,0);assert(!calls.some(c=>c.table==='portal_invoice_discounts'));
});
