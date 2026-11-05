-- Dopo la migrazione: solo righe sintetiche, transazione sempre annullata.
begin;
select set_config('request.jwt.claim.sub',(select user_id::text from public.portal_admins order by user_id limit 1),true);
set local role authenticated;
do $test$
declare cid uuid; sid uuid; cost uuid; snapshot jsonb; result jsonb; failure boolean;
begin
 insert into public.portal_clients(name) values('Test Nexus interno '||gen_random_uuid()) returning id into cid;
 insert into public.portal_shipments(client_id,code,shipped_on,recipient,customer_charge)
 values(cid,'TEST-NEXUS-'||gen_random_uuid(),'2099-01-05','Destinatario sintetico',7) returning id into sid;
 insert into public.portal_carrier_charges(invoice_number,month,carrier_code,reference,recipient,shipped_on,transport)
 values('TEST-NEXUS','2099-01-01',gen_random_uuid()::text,'TEST','Destinatario sintetico','2099-01-05',5) returning id into cost;
 select to_jsonb(c) into snapshot from public.portal_carrier_charges c where id=cost;
 result:=public.portal_assign_carrier_charge(cost,true,null,snapshot);
 assert (result->>'nexus_owned')::boolean and result->>'shipment_id' is null;
 failure:=false;
 begin
  perform public.portal_assign_carrier_charge(cost,false,sid,snapshot);
 exception when raise_exception then failure:=true;
 end;
 assert failure,'Snapshot obsoleto non rifiutato';
 result:=public.portal_assign_carrier_charge(cost,false,sid,result);
 assert not (result->>'nexus_owned')::boolean and (result->>'shipment_id')::uuid=sid;
 failure:=false;
 begin
  perform public.portal_assign_carrier_charge(cost,true,null,result,false,7);
 exception when raise_exception then failure:=true;
 end;
 assert failure,'Rimozione importo cliente senza consenso';
 assert (select customer_charge=7 from public.portal_shipments where id=sid);
 result:=public.portal_assign_carrier_charge(cost,true,null,result,true,7);
 assert (result->>'nexus_owned')::boolean and result->>'shipment_id' is null;
 assert (select customer_charge is null from public.portal_shipments where id=sid);
 assert (select transport=5 from public.portal_carrier_charges where id=cost),'Costo Nexus alterato';
 failure:=false;
 begin
  update public.portal_carrier_charges set shipment_id=sid where id=cost;
 exception when check_violation then failure:=true;
 end;
 assert failure,'Il vincolo consente di abbinare una spedizione Nexus';
end $test$;
rollback;
