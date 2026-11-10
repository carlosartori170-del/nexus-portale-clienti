-- Synthetic fixtures only. Run after the proposed migration inside the same transaction.
do $claims$ begin perform set_config('request.jwt.claim.sub',(select user_id::text from public.portal_admins order by user_id limit 1),true);end $claims$;
set local role authenticated;
do $test$
declare cid uuid; mid uuid; did uuid:=gen_random_uuid(); otherid uuid:=gen_random_uuid(); expected jsonb; before_month jsonb; failed boolean; removed text; claim text;
begin
 claim:=current_setting('request.jwt.claim.sub');
 insert into public.portal_clients(name,billing_rules) values('Test elimina PDF '||gen_random_uuid(),'[]') returning id into cid;
 insert into public.portal_months(client_id,month) values(cid,'2099-12-01') returning id into mid;
 select to_jsonb(m) into before_month from public.portal_months m where id=mid;
 insert into public.portal_invoice_documents(id,client_id,month_id,invoice_number,issue_date,due_date,snapshot,net_amount,vat_rate,vat_amount,total_amount,object_path)
 values(did,cid,mid,'TEST-DELETE-'||did,'2099-12-31','2099-12-31','{}',10,22,2.2,12.2,cid::text||'/'||did::text||'.pdf'),
 (otherid,cid,mid,'TEST-KEEP-'||otherid,'2099-12-31','2099-12-31','{}',10,22,2.2,12.2,cid::text||'/'||otherid::text||'.pdf');
 select to_jsonb(d) into expected from public.portal_invoice_documents d where id=did;
 failed:=false;begin perform public.portal_delete_invoice_document(did,expected||'{"invoice_number":"changed"}');exception when others then failed:=sqlerrm like 'Documento modificato:%';end;assert failed,'Stale deletion permitted';
 perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 failed:=false;begin perform public.portal_delete_invoice_document(did,expected);exception when insufficient_privilege then failed:=true;end;assert failed,'Non-admin RPC deletion permitted';
 delete from public.portal_invoice_documents where id=did;
 perform set_config('request.jwt.claim.sub',claim,true);
 assert exists(select 1 from public.portal_invoice_documents where id=did),'Non-admin direct deletion permitted';
 removed:=public.portal_delete_invoice_document(did,expected);
 assert removed=cid::text||'/'||did::text||'.pdf';
 assert not exists(select 1 from public.portal_invoice_documents where id=did),'Document not deleted';
 assert public.portal_delete_invoice_document(did,expected)=removed,'Lost-response retry failed';
 assert exists(select 1 from public.portal_invoice_documents where id=otherid),'Other document deleted';
 assert before_month=(select to_jsonb(m) from public.portal_months m where id=mid),'Monthly billing modified';
 -- Reuse same year/number with a fresh PDF id.
 did:=gen_random_uuid();
 insert into public.portal_invoice_documents(id,client_id,month_id,invoice_number,issue_date,due_date,snapshot,net_amount,vat_rate,vat_amount,total_amount,object_path)
 values(did,cid,mid,expected->>'invoice_number','2099-12-31','2099-12-31','{}',10,22,2.2,12.2,cid::text||'/'||did::text||'.pdf');
 assert not has_function_privilege('anon','public.portal_delete_invoice_document(uuid,jsonb)','EXECUTE');
end $test$;
reset role;
select 'Delete PDF: admin, stale snapshot, RLS, isolated deletion, unchanged billing and invoice number reuse passed' as esito;
