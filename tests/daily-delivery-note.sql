-- Only synthetic fixtures, wrapped in BEGIN/ROLLBACK by the test runner.
do $claims$ begin perform set_config('request.jwt.claim.sub',(select user_id::text from public.portal_admins order by user_id limit 1),true);end $claims$;
set local role authenticated;
do $test$
declare cid uuid; rid uuid:=gen_random_uuid(); child_id uuid:=gen_random_uuid(); body jsonb; receipt jsonb; outgoing jsonb; failed boolean;
begin
 insert into public.portal_clients(name,billing_quantity_source,billing_daily_shipments,billing_rules)
 values('Test numero bolla '||gen_random_uuid(),'manual',true,'[]') returning id into cid;
 body:=jsonb_build_object('client_id',cid,'shipped_on','2099-10-20','received_on','2099-10-10','supplier','Fornitore test','piece_count',10,'stock_pieces',6,'shipment_count',4,'notes','','delivery_note',' 0007/A ');
 receipt:=public.portal_save_daily_dispatch(rid,body,null,0);
 assert receipt->>'delivery_note'='0007/A','Delivery note formatting lost';
 assert public.portal_save_daily_dispatch(rid,body,null,0)=receipt,'Create retry failed';
 -- An older caller omitting the optional field must never clear a saved note.
 receipt:=public.portal_save_daily_dispatch(rid,body-'delivery_note',receipt,0);
 assert receipt->>'delivery_note'='0007/A','Old client erased delivery note';
 outgoing:=public.portal_dispatch_from_stock(child_id,rid,'2099-11-05',2,1,'',receipt,6);
 assert outgoing->>'stock_source_id'=rid::text and outgoing->>'delivery_note'='','Linked shipment duplicated the receipt note';
 -- Correct or fill the number on the original receipt even if outgoing rows exist.
 receipt:=public.portal_save_daily_dispatch(rid,(body||jsonb_build_object('delivery_note','0008/B','stock_pieces',4)),receipt,2);
 assert receipt->>'delivery_note'='0008/B';
 assert (select source.delivery_note='0008/B' from public.portal_daily_dispatches child join public.portal_daily_dispatches source on child.stock_source_id=source.id where child.id=child_id),'Linked shipment lost corrected receipt note';
 failed:=false;begin perform public.portal_save_daily_dispatch(rid,body||jsonb_build_object('delivery_note',repeat('A',101),'stock_pieces',4),receipt,2);exception when others then failed:=sqlerrm like 'Il numero bolla può contenere%';end;assert failed,'Oversized delivery note accepted';
 failed:=false;begin update public.portal_daily_dispatches set delivery_note='BOLLA FALSA' where id=child_id;exception when check_violation then failed:=true;end;assert failed,'Child could override origin delivery note';
 receipt:=public.portal_save_daily_dispatch(rid,body||jsonb_build_object('delivery_note','','stock_pieces',4),receipt,2);
 assert receipt->>'delivery_note'='','Optional delivery note could not be cleared';
 assert not has_function_privilege('anon','public.portal_save_daily_dispatch(uuid,jsonb,jsonb,bigint)','EXECUTE');
end $test$;
reset role;
select 'Numero bolla: formato, salvataggio, retry, compatibilità, correzioni con giacenza, vincoli e permessi verificati' as esito;
