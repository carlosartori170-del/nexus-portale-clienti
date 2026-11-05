-- Eseguire dopo la migrazione. Dati sintetici, rollback completo.
begin;
do $claims$ begin perform set_config('request.jwt.claim.sub',(select user_id::text from public.portal_admins order by user_id limit 1),true);end $claims$;
set local role authenticated;
do $test$
declare a uuid; b uuid; cost uuid; expected jsonb; result jsonb; snap jsonb; req jsonb; failed boolean;
begin
 insert into public.portal_clients(name,billing_rules,billing_quantity_source) values('Test contratto diretto A '||gen_random_uuid(),'[]','deagor') returning id into a;
 insert into public.portal_clients(name,billing_rules,billing_quantity_source) values('Test contratto diretto B '||gen_random_uuid(),'[]','manual') returning id into b;
 insert into public.portal_carrier_charges(invoice_number,month,carrier_code,reference,recipient,shipped_on,transport,fuel)
 values('INPOST TEST','2099-10-01',gen_random_uuid()::text,'TRACK-TEST','Destinatario test','2099-09-25',3.95,.2) returning id into cost;
 select to_jsonb(c) into expected from public.portal_carrier_charges c where id=cost;
 result:=public.portal_assign_carrier_destination(cost,false,null,expected,false,null,a);
 assert (result->>'direct_client_id')::uuid=a and result->>'shipment_id' is null;
 req:=public.portal_billing_requirements(a,'2099-10-01');
 assert req->'sections' ? 'carriers';
 snap:=public.portal_section_snapshot(a,'2099-10-01','carriers');
 assert (snap->>'carrier_total')::numeric=4.15 and (snap->>'direct_carrier_count')::integer=1;
 snap:=public.portal_validate_section(a,'2099-10-01','carriers');
 assert snap->>'preinvoice_error' is null, 'Prefattura cliente diretto fallita';
 assert (select carrier_total=4.15 from public.portal_months where client_id=a and month='2099-10-01');
 result:=public.portal_assign_carrier_destination(cost,false,null,result,false,null,b);
 assert not exists(select 1 from public.portal_section_validations where client_id=a and month='2099-10-01' and section='carriers'),'Vecchia convalida non invalidata';
 snap:=public.portal_section_snapshot(b,'2099-10-01','carriers');
 assert snap->>'source'='direct' and (snap->>'carrier_total')::numeric=4.15;
 snap:=public.portal_validate_section(b,'2099-10-01','carriers');
 assert snap->>'preinvoice_error' is null,'Prefattura cliente manuale fallita';
 assert (select carrier_total=4.15 from public.portal_months where client_id=b and month='2099-10-01');
 result:=public.portal_assign_carrier_destination(cost,true,null,result);
 assert result->>'direct_client_id' is null and (result->>'nexus_owned')::boolean;
 snap:=public.portal_section_snapshot(b,'2099-10-01','carriers');
 assert (snap->>'carrier_total')::numeric=0,'Costo Nexus ancora fatturato';
 failed:=false;
 begin update public.portal_carrier_charges set direct_client_id=a where id=cost;exception when check_violation then failed:=true;end;
 assert failed,'Vincolo di esclusione destinazioni non rispettato';
end $test$;
select 'Test contratto diretto superati: prefattura, clienti manuali, cambio destinatario, Nexus e vincolo' as result;
rollback;
