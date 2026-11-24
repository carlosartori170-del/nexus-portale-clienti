-- Apply proposed DDL and this script in one BEGIN ... ROLLBACK transaction.
do $claims$ begin perform set_config('request.jwt.claim.sub',(select user_id::text from public.portal_admins order by user_id limit 1),true);end $claims$;
set local role authenticated;
do $test$
declare cid uuid; cid2 uuid; source_id uuid:=gen_random_uuid(); out_id uuid:=gen_random_uuid(); out2_id uuid:=gen_random_uuid(); normal_id uuid:=gen_random_uuid();
 src jsonb; result jsonb; old_month jsonb; old_validation jsonb; m public.portal_months%rowtype; failed boolean; claim text; before_count integer;
begin
 claim:=current_setting('request.jwt.claim.sub');
 insert into public.portal_clients(name,billing_quantity_source,billing_daily_shipments,billing_rules,minimum_logistics,vat_rate)
 values('Test giacenza giornaliera '||gen_random_uuid(),'manual',true,'[{"label":"Spedizioni","basis":"billable_shipments","mode":"fixed","rate":2,"category":"logistics"}]',0,22) returning id into cid;
 insert into public.portal_clients(name,billing_quantity_source,billing_daily_shipments,billing_rules)
 values('Test altra giacenza '||gen_random_uuid(),'manual',true,'[]') returning id into cid2;
 result:=public.portal_save_daily_dispatch(source_id,jsonb_build_object('client_id',cid,'shipped_on','2099-10-15','received_on','2099-10-10','supplier','Fornitore test','piece_count',10,'shipment_count',4,'stock_pieces',6,'notes','Bolla TEST'),null,0);
 src:=result;
 assert result->>'stock_pieces'='6';
 assert public.portal_save_daily_dispatch(source_id,jsonb_build_object('client_id',cid,'shipped_on','2099-10-15','received_on','2099-10-10','supplier','Fornitore test','piece_count',10,'shipment_count',4,'stock_pieces',6,'notes','Bolla TEST'),null,0)=src,'Retry initial registration failed';
 result:=public.portal_validate_section(cid,'2099-10-01','shipments');assert result->>'preinvoice_error' is null;
 select * into m from public.portal_months where client_id=cid and month='2099-10-01';
 result:=public.portal_build_preinvoice(cid,'2099-10-01',true,false,m.validation_versions,m.invoice_lines);
 select to_jsonb(x) into old_month from public.portal_months x where client_id=cid and month='2099-10-01';
 select to_jsonb(x) into old_validation from public.portal_section_validations x where client_id=cid and month='2099-10-01' and section='shipments';
 assert (old_month->>'released')::boolean;
 -- A partial shipment in November, then another in December.
 result:=public.portal_dispatch_from_stock(out_id,source_id,'2099-11-05',2,1,'Nota uscita',src,6);
 assert result->>'stock_source_id'=source_id::text and result->>'received_on'='2099-10-10' and result->>'supplier'='Fornitore test';
 assert result->>'piece_count'='2' and result->>'shipment_count'='1';
 assert public.portal_dispatch_from_stock(out_id,source_id,'2099-11-05',2,1,'Nota uscita',src,6)=result,'Duplicate request created another shipment';
 failed:=false;begin perform public.portal_dispatch_from_stock(gen_random_uuid(),source_id,'2099-11-05',1,1,'',src,6);exception when others then failed:=sqlerrm like 'Giacenza modificata da%';end;assert failed,'Stale available count accepted';
 result:=public.portal_dispatch_from_stock(out2_id,source_id,'2099-12-01',3,2,'',src,4);
 assert (select stock_pieces-(select sum(piece_count) from public.portal_daily_dispatches where stock_source_id=source_id) from public.portal_daily_dispatches where id=source_id)=1;
 assert src=(select to_jsonb(x) from public.portal_daily_dispatches x where id=source_id),'Origin changed during linked shipment';
 assert old_month=(select to_jsonb(x) from public.portal_months x where client_id=cid and month='2099-10-01'),'Old confirmed month changed';
 assert old_validation=(select to_jsonb(x) from public.portal_section_validations x where client_id=cid and month='2099-10-01' and section='shipments'),'Old validation invalidated';
 assert (public.portal_section_snapshot(cid,'2099-10-01','shipments')->>'billable_shipments')::integer=4;
 assert (public.portal_section_snapshot(cid,'2099-11-01','shipments')->>'billable_shipments')::integer=1;
 assert (public.portal_section_snapshot(cid,'2099-12-01','shipments')->>'billable_shipments')::integer=2;
 result:=public.portal_validate_section(cid,'2099-11-01','shipments');assert result->>'preinvoice_error' is null;
 select * into m from public.portal_months where client_id=cid and month='2099-11-01';
 assert m.invoice_lines @> '[{"basis":"billable_shipments","quantity":1,"amount":2}]'::jsonb,'New month invoice quantity incorrect';
 -- All write paths, including direct table updates, enforce the reserve.
 failed:=false;begin perform public.portal_dispatch_from_stock(gen_random_uuid(),source_id,'2099-12-02',2,1,'',src,1);exception when others then failed:=sqlerrm like 'Pezzi richiesti superiori%';end;assert failed,'Overship accepted';
 failed:=false;begin perform public.portal_dispatch_from_stock(gen_random_uuid(),source_id,'2099-10-20',1,1,'',src,1);exception when others then failed:=sqlerrm like 'Usa una data%';end;assert failed,'Same-month linked row accepted';
 failed:=false;begin insert into public.portal_daily_dispatches(client_id,shipped_on,received_on,supplier,piece_count,shipment_count,stock_source_id) values(cid2,'2099-12-03','2099-10-10','Fornitore test',1,1,source_id);exception when others then failed:=sqlerrm like 'Cliente, data ricevimento%';end;assert failed,'Cross-client source accepted';
 failed:=false;begin update public.portal_daily_dispatches set piece_count=7 where id=out_id;exception when others then failed:=sqlerrm like 'Pezzi richiesti superiori%';end;assert failed,'Direct overship edit accepted';
 failed:=false;begin update public.portal_daily_dispatches set supplier='Modificato' where id=source_id;exception when others then failed:=sqlerrm like 'Ricevimento, fornitore%';end;assert failed,'Linked receipt changed';
 failed:=false;begin delete from public.portal_daily_dispatches where id=source_id;exception when others then failed:=sqlerrm like 'La registrazione ha spedizioni%';end;assert failed,'Linked origin deleted';
 -- Editing and deleting outgoing rows restores only their consumed stock.
 update public.portal_daily_dispatches set piece_count=1 where id=out_id;
 assert not exists(select 1 from public.portal_section_validations where client_id=cid and month='2099-11-01' and section='shipments'),'Edited month not invalidated';
 delete from public.portal_daily_dispatches where id=out2_id;
 assert (select sum(piece_count) from public.portal_daily_dispatches where stock_source_id=source_id)=1;
 -- Root editor receives remaining stock, not original reserve.
 result:=public.portal_save_daily_dispatch(source_id,jsonb_build_object('client_id',cid,'shipped_on','2099-10-15','received_on','2099-10-10','supplier','Fornitore test','piece_count',10,'shipment_count',4,'stock_pieces',2,'notes','Bolla TEST'),src,1);
 assert result->>'stock_pieces'='3','Remaining stock edit lost already shipped pieces';
 failed:=false;begin perform public.portal_save_daily_dispatch(source_id,jsonb_build_object('client_id',cid,'shipped_on','2099-10-15','received_on','2099-10-10','supplier','Fornitore test','piece_count',10,'shipment_count',4,'stock_pieces',2),src,1);exception when others then failed:=sqlerrm like 'Registrazione modificata:%';end;assert failed,'Stale origin edit accepted';
 -- Simple same-month operation remains a normal row edit.
 result:=public.portal_save_daily_dispatch(normal_id,jsonb_build_object('client_id',cid,'shipped_on','2099-11-10','received_on','2099-11-10','supplier','Altro fornitore','piece_count',5,'shipment_count',3,'stock_pieces',2),null,0);
 result:=public.portal_save_daily_dispatch(normal_id,jsonb_build_object('client_id',cid,'shipped_on','2099-11-10','received_on','2099-11-10','supplier','Altro fornitore','piece_count',5,'shipment_count',5,'stock_pieces',0),result,0);
 assert result->>'stock_pieces'='0' and result->>'shipment_count'='5';
 -- Closed clients and nested stock links cannot create new outgoing rows.
 failed:=false;begin insert into public.portal_daily_dispatches(client_id,shipped_on,received_on,supplier,piece_count,shipment_count,stock_source_id) values(cid,'2100-01-02','2099-10-10','Fornitore test',1,1,out_id);exception when others then failed:=sqlerrm like 'Registrazione di giacenza originale%';end;assert failed,'Nested stock source accepted';
 update public.portal_clients set active_until='2099-12-31' where id=cid;
 select to_jsonb(x) into src from public.portal_daily_dispatches x where id=source_id;
 failed:=false;begin perform public.portal_dispatch_from_stock(gen_random_uuid(),source_id,'2100-01-02',1,1,'',src,2);exception when others then failed:=sqlerrm like 'Cliente non attivo%';end;assert failed,'Inactive-month dispatch accepted';
 -- Existing access model: admin writes; clients read only their rows; anonymous RPC disabled.
 perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 assert not exists(select 1 from public.portal_daily_dispatches where client_id=cid),'Unrelated account can read rows';
 failed:=false;begin perform public.portal_dispatch_from_stock(gen_random_uuid(),source_id,'2099-12-10',1,1,'',src,2);exception when insufficient_privilege then failed:=true;end;assert failed,'Non-admin RPC accepted';
 perform set_config('request.jwt.claim.sub',claim,true);
 assert not has_function_privilege('anon','public.portal_dispatch_from_stock(uuid,uuid,date,bigint,integer,text,jsonb,bigint)','EXECUTE');
 assert not has_function_privilege('anon','public.portal_save_daily_dispatch(uuid,jsonb,jsonb,bigint)','EXECUTE');
 assert (select relrowsecurity from pg_class where oid='public.portal_daily_dispatches'::regclass);
end $test$;
reset role;
select 'Giacenze: parziali, mesi successivi, fatturazione, mese originale, limiti, modifiche, ripristino, retry e RLS verificati' as esito;
