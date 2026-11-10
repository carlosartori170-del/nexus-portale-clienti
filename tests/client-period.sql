-- Dopo la migrazione; solo fixture sintetiche, rollback completo.
begin;
do $claims$ begin perform set_config('request.jwt.claim.sub',(select user_id::text from public.portal_admins order by user_id limit 1),true);end $claims$;
set local role authenticated;
do $test$
declare c uuid; legacy uuid; result jsonb; failed boolean; month_hash text;
begin
 insert into public.portal_clients(name,billing_rules,minimum_logistics,vat_rate,active_from,active_until)
 values('Test periodo cliente '||gen_random_uuid(),'[{"label":"Fisso","basis":"billable_shipments","mode":"fixed","rate":10}]',0,22,'2099-03-31','2099-09-01') returning id into c;
 insert into public.portal_clients(name,billing_rules) values('Test periodo legacy '||gen_random_uuid(),'[]') returning id into legacy;
 assert not public.portal_client_active_in_month(c,'2099-02-01');
 assert public.portal_client_active_in_month(c,'2099-03-01');
 assert public.portal_client_active_in_month(c,'2099-09-01');
 assert not public.portal_client_active_in_month(c,'2099-10-01');
 assert public.portal_client_active_in_month(legacy,'2000-01-01');
 assert not public.portal_client_active_in_month(c,null);
 failed:=false;begin update public.portal_clients set active_until='2099-02-01' where id=c;exception when check_violation then failed:=true;end;assert failed,'Periodo invertito ammesso';
 failed:=false;begin perform public.portal_build_preinvoice(c,'2099-02-01');exception when others then failed:=sqlerrm like 'Cliente non attivo nel mese selezionato:%';end;assert failed,'Prefattura prima dell’inizio ammessa';
 failed:=false;begin perform public.portal_validate_section(c,'2099-10-01','carriers',null,null,false,true,true);exception when others then failed:=sqlerrm like 'Cliente non attivo nel mese selezionato:%';end;assert failed,'Convalida dopo la fine ammessa';
 result:=public.portal_build_preinvoice(c,'2099-03-01');
 assert (result->>'invoice_total')::numeric=12.20,'Mese iniziale non fatturabile o tariffa riproporzionata';
 result:=public.portal_build_preinvoice(c,'2099-09-01');
 assert (result->>'invoice_total')::numeric=12.20,'Mese finale non fatturabile';
 assert not exists(select 1 from public.portal_months where client_id=c and month in ('2099-02-01','2099-10-01')),'Mesi inattivi creati';
 select md5(jsonb_agg(to_jsonb(m) order by m.id)::text) into month_hash from public.portal_months m where client_id=c;
 update public.portal_clients set active_until=null where id=c;
 assert public.portal_client_active_in_month(c,'2100-01-01');
 assert month_hash=(select md5(jsonb_agg(to_jsonb(m) order by m.id)::text) from public.portal_months m where client_id=c),'La modifica delle date ha cambiato i riepiloghi salvati';
 assert not has_function_privilege('anon','public.portal_client_active_in_month(uuid,date)','EXECUTE');
 assert (select relrowsecurity from pg_class where oid='public.portal_clients'::regclass),'RLS disattivata';
end $test$;
select 'Periodo cliente: confini, date aperte, convalide, prefatture e storico verificati' as esito;
rollback;
